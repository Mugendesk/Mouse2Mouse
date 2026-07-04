import Foundation
import Network
import Mugenlink

/// カーソル位置のバイナリパケット形式
/// JSON(~70bytes)よりも小さく(25bytes)、parse/encodeも高速
/// レイアウト（little-endian）:
///   byte 0:    magic 'M' (0x4D)
///   byte 1:    version (0x01)
///   byte 2-9:  timestamp (Float64)
///   byte 10-17: x (Float64, normalized 0.0-1.0)
///   byte 18-25: y (Float64, normalized 0.0-1.0)
private struct CursorPacket {
    static let size = 26
    static let magic: UInt8 = 0x4D
    static let version: UInt8 = 0x01

    let timestamp: Double
    let x: Double
    let y: Double

    func encode() -> Data {
        var data = Data(capacity: Self.size)
        data.append(Self.magic)
        data.append(Self.version)
        var ts = timestamp.bitPattern.littleEndian
        var bx = x.bitPattern.littleEndian
        var by = y.bitPattern.littleEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &bx) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &by) { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> CursorPacket? {
        guard data.count >= size else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> CursorPacket? in
            guard buf.count >= size,
                  buf[0] == magic,
                  buf[1] == version else { return nil }
            // loadUnalignedで非整列アクセス安全に読み取る (offset 2,10,18は8byte非整列)
            let ts = buf.loadUnaligned(fromByteOffset: 2, as: UInt64.self)
            let bx = buf.loadUnaligned(fromByteOffset: 10, as: UInt64.self)
            let by = buf.loadUnaligned(fromByteOffset: 18, as: UInt64.self)
            return CursorPacket(
                timestamp: Double(bitPattern: UInt64(littleEndian: ts)),
                x: Double(bitPattern: UInt64(littleEndian: bx)),
                y: Double(bitPattern: UInt64(littleEndian: by))
            )
        }
    }
}

/// カーソル位置の高速UDPチャネル
/// WebSocket(TCP)ではパケットロス時にhead-of-line blockingで固まるため、
/// 損失許容のカーソル送信のみUDPで分離。
/// click/key/clipboard等の信頼性が必要なメッセージは引き続きWebSocketを使う。
final class UDPCursorChannel {
    static let shared = UDPCursorChannel()
    static let port: NWEndpoint.Port = 24801

    private static let queue = DispatchQueue(label: "Mouse2Mouse.UDPCursor", qos: .userInteractive)

    private var listener: NWListener?
    // ピアごとの送信用UDPコネクション（peerId → connection）
    private var sendConnections: [String: NWConnection] = [:]

    // ピアごとの Noise Datagram チャネル (双方向)。カーソルパケットの暗号化に使う。
    // ハンドシェイクは確立済みWS上をトンネルし、データ本体だけUDPで流す。
    private var dgramChannels: [String: Mugenlink.Channel] = [:]
    private var dgramReady: Set<String> = []
    // dgramChannels/dgramReady 保護 (送信はcaller thread、受信/駆動はUDP queue から触るため)
    private let dgramLock = NSLock()

    // 受信側: 受信済みtimestampを記録して重複/古いパケットを弾く
    private var lastReceivedTimestamp: Double = 0

    // 送信冗長度（パケット損失対策）
    // 3でWiFi 1%損失でも実効損失~0.0001%。LANでは帯域無視できる
    private let redundancy: Int = 3

    // ジッタ計測（受信側に集約）:
    // - sendJitter: パケット内timestamp間隔 = ホストでの送信間隔（送信側ジッタ）
    // - recvJitter: 実際の到着時刻間隔 = ネットワーク経由後の受信ジッタ
    // 両者を比較すればネットワーク区間のジッタが分かる
    private let sendJitter = IntervalStats(name: "Cursor send")
    private let recvJitter = IntervalStats(name: "Cursor recv")

    // 片道遅延の「変動」を見るための統計。
    // 送受信間のクロックずれで絶対値はオフセットされるが、変動分（p99 - p50など）が
    // 大きくなれば「matcha起動時に遅延が増えた」ことを検出できる。
    private let oneWayLatency = LatencyStats(name: "Cursor latency")

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters, on: Self.port)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleIncomingConnection(conn)
            }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[UDP] Cursor listener ready on port \(Self.port.rawValue)")
                case .failed(let error):
                    print("[UDP] Listener failed: \(error)")
                default:
                    break
                }
            }
            listener?.start(queue: Self.queue)
        } catch {
            print("[UDP] Failed to start listener: \(error)")
        }
    }

    func stop() {
        stop(completion: nil)
    }

    /// completionは listener の .cancelled state 観測後に呼ばれる。
    /// port再bind前に呼ぶと EADDRINUSE になるので、再起動時は必ず completion を待つ。
    func stop(completion: (() -> Void)?) {
        for c in sendConnections.values { c.cancel() }
        sendConnections.removeAll()

        let toCancel = listener
        listener = nil

        guard let toCancel = toCancel else {
            completion?()
            return
        }

        toCancel.stateUpdateHandler = { state in
            if case .cancelled = state {
                print("[UDP] Listener cancelled")
                completion?()
            }
        }
        toCancel.cancel()
    }

    // MARK: - Receive Path

    private func handleIncomingConnection(_ conn: NWConnection) {
        conn.start(queue: Self.queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.handleData(data)
            }
            if error == nil, conn.state != .cancelled {
                self?.receive(on: conn)
            }
        }
    }

    private func handleData(_ data: Data) {
        // 暗号化された Datagram フレーム。送信元 peerId が不明なので、確立済み各チャネルで
        // 復号を試す。AEAD 認証で正しい 1 本のみ Message を返す (他は Rejected で無害)。
        dgramLock.lock()
        let channels = dgramChannels.filter { dgramReady.contains($0.key) }
        dgramLock.unlock()
        for (peerId, ch) in channels {
            let evs = ch.onMessage(frame: data)
            if evs.contains(where: { if case .message = $0 { return true }; return false }) {
                drive(evs, peerId: peerId)
                return
            }
        }
    }

    /// 復号済みカーソルパケットを処理する。
    private func handleDecryptedCursor(_ plaintext: Data) {
        guard let pkt = CursorPacket.decode(plaintext) else { return }
        // timestamp比較で古いパケットを破棄 (nonce窓の二次防御)
        guard pkt.timestamp > lastReceivedTimestamp else { return }
        // WS接続中のピアが居なければドロップ
        guard !DiscoveryService.shared.connectedPeers.isEmpty else { return }
        lastReceivedTimestamp = pkt.timestamp
        let recvTime = CFAbsoluteTimeGetCurrent()
        sendJitter.tick(at: pkt.timestamp)
        recvJitter.tick()
        oneWayLatency.record(recvTime - pkt.timestamp)
        InputCapture.shared.peerMessageReceived()
        InputReceiver.shared.handleCursorMove(x: pkt.x, y: pkt.y)
    }

    // MARK: - Send Path

    /// ピアのUDPエンドポイントを登録（WebSocket接続確立時に呼ぶ）
    /// peerId → IPアドレスのマッピングをこちらが保持し、UDPコネクションを起動
    func setPeerEndpoint(peerId: String, host: NWEndpoint.Host) {
        sendConnections[peerId]?.cancel()
        let endpoint = NWEndpoint.hostPort(host: host, port: Self.port)
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[UDP] Send connection to \(peerId) failed: \(error)")
            }
        }
        conn.start(queue: Self.queue)
        sendConnections[peerId] = conn
        print("[UDP] Registered peer \(peerId) at \(host):\(Self.port.rawValue)")
    }

    func removePeer(peerId: String) {
        sendConnections[peerId]?.cancel()
        sendConnections.removeValue(forKey: peerId)
        dgramLock.lock()
        dgramChannels.removeValue(forKey: peerId)
        dgramReady.remove(peerId)
        dgramLock.unlock()
    }

    // MARK: - Secure Datagram Session (Noise over UDP)

    /// WS 接続確立後に呼ぶ。UDP 用の Noise Datagram チャネルを張り始める。
    /// `isInitiator`: WS で接続を仕掛けた側 (client) が true。responder(server) は
    /// トンネルされてきた最初のフレームで遅延生成するので呼ばなくてよい。
    func beginSecureSession(peerId: String, isInitiator: Bool) {
        Self.queue.async { [weak self] in
            guard let self = self else { return }
            self.dgramLock.lock()
            let exists = self.dgramChannels[peerId] != nil
            let ch = exists ? nil : Self.makeChannel(initiator: isInitiator)
            if let ch = ch { self.dgramChannels[peerId] = ch }
            self.dgramLock.unlock()
            if isInitiator, let ch = ch {
                self.drive(ch.open(), peerId: peerId)
            }
        }
    }

    /// WS 上でトンネルされてきた Datagram ハンドシェイクフレームを投入する。
    func receiveTunneledHandshake(peerId: String, frameBase64: String) {
        guard let frame = Data(base64Encoded: frameBase64) else { return }
        Self.queue.async { [weak self] in
            guard let self = self else { return }
            self.dgramLock.lock()
            if self.dgramChannels[peerId] == nil {
                // responder 側: 最初のフレームで遅延生成
                self.dgramChannels[peerId] = Self.makeChannel(initiator: false)
            }
            let ch = self.dgramChannels[peerId]
            self.dgramLock.unlock()
            guard let ch = ch else { return }
            self.drive(ch.onMessage(frame: frame), peerId: peerId)
        }
    }

    private static func makeChannel(initiator: Bool) -> Mugenlink.Channel? {
        // ハンドシェイクは認証済みWS上をトンネルするので MITM 不可。allowUnknown=true でよい。
        let id = NoiseIdentityStore.shared.identity
        if initiator {
            return try? Mugenlink.Channel.newInitiator(
                local: id, psk: nil, transport: .datagram, authorizedKeys: [], allowUnknown: true)
        } else {
            return try? Mugenlink.Channel.newResponder(
                local: id, psk: nil, transport: .datagram, authorizedKeys: [], allowUnknown: true)
        }
    }

    /// Channel のイベントを処理する。ハンドシェイクフレームは暗号化WS上でトンネル送出、
    /// Message は復号済みカーソルとして処理。すべて Self.queue 上で呼ぶこと。
    private func drive(_ events: [ChannelEvent], peerId: String) {
        for ev in events {
            switch ev {
            case .send(let frame):
                let b64 = frame.base64EncodedString()
                DiscoveryService.shared.send(
                    "{\"type\":\"udp_handshake\",\"frame\":\"\(b64)\"}", to: peerId)
            case .established:
                dgramLock.lock()
                dgramReady.insert(peerId)
                dgramLock.unlock()
                print("[UDP] Secure cursor session established with \(peerId)")
            case .message(let plaintext):
                handleDecryptedCursor(plaintext)
            case .rejected:
                break  // UDP は不正/リプレイ常態。破棄のみ (クローズしない)
            case .closed:
                dgramLock.lock()
                dgramChannels.removeValue(forKey: peerId)
                dgramReady.remove(peerId)
                dgramLock.unlock()
            }
        }
    }

    /// UDPでカーソル位置を送信（バイナリ26byte）
    /// 同じパケットをredundancy回送る。受信側はtimestampで重複を弾く
    /// (1パケット連続損失耐性: 1-(loss^N) → 1%損失でも~0.000001%実効損失)
    func sendCursor(x: Double, y: Double, to peerId: String) {
        guard let conn = sendConnections[peerId] else { return }
        // セキュアチャネル確立前は送らない (カーソルを平文でUDPに出さない)。
        dgramLock.lock()
        let ch = dgramReady.contains(peerId) ? dgramChannels[peerId] : nil
        dgramLock.unlock()
        guard let ch = ch else { return }

        let pkt = CursorPacket(timestamp: CFAbsoluteTimeGetCurrent(), x: x, y: y).encode()
        // 一度だけ暗号化 (nonce 1消費) し、同じフレームを redundancy 回送る。
        // 受信側は nonce スライディングウィンドウで重複を弾く。
        guard let frame = try? ch.send(plaintext: pkt) else { return }
        for _ in 0..<redundancy {
            conn.send(content: frame, completion: .idempotent)
        }
    }
}

// MARK: - Interval Statistics (ジッタ計測用)

/// イベント間隔をp50/p95/p99/maxで定期ログ出力する診断ヘルパー。
/// tick() が呼ばれるたびに前回からの経過を記録し、reportInterval毎にprint。
final class IntervalStats {
    private let name: String
    private let lock = NSLock()
    private var lastTimestamp: CFAbsoluteTime = 0
    private var intervals: [Double] = []
    private var lastReport: CFAbsoluteTime = 0
    private let reportInterval: Double = 5.0
    private let minSamplesToReport = 20

    init(name: String) {
        self.name = name
    }

    func tick() {
        tick(at: CFAbsoluteTimeGetCurrent())
    }

    /// 任意のtimestampでtick（パケット内タイムスタンプから送信側jitterを計算する用途）
    func tick(at timestamp: CFAbsoluteTime) {
        let nowReal = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if lastTimestamp > 0 {
            intervals.append(timestamp - lastTimestamp)
        }
        lastTimestamp = timestamp
        let shouldReport = (nowReal - lastReport > reportInterval) && (intervals.count >= minSamplesToReport)
        let toReport = shouldReport ? intervals : []
        if shouldReport {
            intervals.removeAll(keepingCapacity: true)
            lastReport = nowReal
        }
        lock.unlock()
        if !toReport.isEmpty {
            report(toReport)
        }
    }

    private func report(_ data: [Double]) {
        let sorted = data.sorted()
        let count = sorted.count
        let total = data.reduce(0, +)
        let rate = total > 0 ? Double(count) / total : 0
        let p50 = sorted[count / 2] * 1000
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))] * 1000
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))] * 1000
        let minMs = (sorted.first ?? 0) * 1000
        let maxMs = (sorted.last ?? 0) * 1000
        print(String(format: "[%@] n=%d rate=%dHz min=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms",
                     name, count, Int(rate), minMs, p50, p95, p99, maxMs))
    }
}

/// 片道遅延を p50/p95/p99/max + spread (p99-p50) で定期ログ出力する。
/// 送受信機のクロックがズレてるので絶対値は意味がないが、
/// spread (= p99 - p50) や p50 そのものの**時系列変動** は意味がある。
/// matcha起動の前後で spread が10ms→100ms に増えれば「matchaの影響」が確定する。
final class LatencyStats {
    private let name: String
    private let lock = NSLock()
    private var samples: [Double] = []  // 秒
    private var lastReport: CFAbsoluteTime = 0
    private let reportInterval: Double = 5.0
    private let minSamplesToReport = 20

    init(name: String) {
        self.name = name
    }

    func record(_ latency: Double) {
        let nowReal = CFAbsoluteTimeGetCurrent()
        lock.lock()
        samples.append(latency)
        let shouldReport = (nowReal - lastReport > reportInterval) && (samples.count >= minSamplesToReport)
        let toReport = shouldReport ? samples : []
        if shouldReport {
            samples.removeAll(keepingCapacity: true)
            lastReport = nowReal
        }
        lock.unlock()
        if !toReport.isEmpty {
            report(toReport)
        }
    }

    private func report(_ data: [Double]) {
        let sorted = data.sorted()
        let count = sorted.count
        let p50 = sorted[count / 2] * 1000
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))] * 1000
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))] * 1000
        let minMs = (sorted.first ?? 0) * 1000
        let maxMs = (sorted.last ?? 0) * 1000
        let spread = p99 - p50  // 変動の大きさ。これが膨らんだら詰まってる
        print(String(format: "[%@] n=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms min=%.1fms spread=%.1fms",
                     name, count, p50, p95, p99, maxMs, minMs, spread))
    }
}
