import Foundation
import Network

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

    // 受信側: 受信済みtimestampを記録して重複/古いパケットを弾く
    private var lastReceivedTimestamp: Double = 0

    // 送信冗長度（パケット損失対策）
    // 3でWiFi 1%損失でも実効損失~0.0001%。LANでは帯域無視できる
    private let redundancy: Int = 3

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
        listener?.cancel()
        listener = nil
        for c in sendConnections.values { c.cancel() }
        sendConnections.removeAll()
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
        guard let pkt = CursorPacket.decode(data) else { return }
        // timestamp比較で重複/古いパケットを破棄（triple-sendでも一度だけ処理）
        guard pkt.timestamp > lastReceivedTimestamp else { return }
        // WS接続中のピアが居なければドロップ（WS切断後のゾンビ動作と同一LANスプーフィング両方を遮断）
        guard !DiscoveryService.shared.connectedPeers.isEmpty else { return }
        lastReceivedTimestamp = pkt.timestamp
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
    }

    /// UDPでカーソル位置を送信（バイナリ26byte）
    /// 同じパケットをredundancy回送る。受信側はtimestampで重複を弾く
    /// (1パケット連続損失耐性: 1-(loss^N) → 1%損失でも~0.000001%実効損失)
    func sendCursor(x: Double, y: Double, to peerId: String) {
        guard let conn = sendConnections[peerId] else { return }
        let pkt = CursorPacket(timestamp: CFAbsoluteTimeGetCurrent(), x: x, y: y)
        let data = pkt.encode()
        for _ in 0..<redundancy {
            conn.send(content: data, completion: .idempotent)
        }
    }
}
