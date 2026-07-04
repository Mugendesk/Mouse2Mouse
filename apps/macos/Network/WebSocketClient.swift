import Foundation
import Combine
import Network
import AppKit

/// WebSocketクライアント
/// URLSessionWebSocketTaskを使用したWebSocket接続
class WebSocketClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var connectionTimer: Timer?

    private(set) var isConnected = false
    let serverURL: URL
    private let connectionTimeout: TimeInterval = 10.0

    // JSON-levelでのkeepalive（URLSessionWebSocketTask.sendPingはカスタムサーバー
    // とのpong照合に問題がありタイムアウト誤検知するため、自前でping/pongを扱う）
    private var lastPongAt: CFAbsoluteTime = 0
    private let pingInterval: TimeInterval = 10.0
    private let pongTimeout: CFAbsoluteTime = 30.0

    // Callbacks
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onMessage: ((String) -> Void)?

    init(url: URL) {
        self.serverURL = url
    }

    // MARK: - Connection

    func connect() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = connectionTimeout

        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: serverURL)
        // デフォルトは1MBで、クリップボード画像 (base64で~1.4倍) で簡単に超えて切断する。
        // サーバー側の maxFrameSize と揃えて 16MB に拡張。
        webSocketTask?.maximumMessageSize = 16 * 1024 * 1024

        print("WebSocket connecting to \(serverURL)")

        webSocketTask?.resume()

        // 最初のメッセージ受信で接続確立を確認
        receiveMessage()

        // 接続タイムアウト
        connectionTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected else { return }
            print("WebSocket connection timed out: \(self.serverURL)")
            self.disconnect()
        }

        // 接続確認用ping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webSocketTask?.sendPing { error in
                DispatchQueue.main.async {
                    if error == nil {
                        self?.connectionTimer?.invalidate()
                        self?.connectionTimer = nil
                        self?.isConnected = true
                        self?.onConnected?()
                        self?.startPing()
                        print("WebSocket connected successfully")
                    } else {
                        print("WebSocket connection failed: \(String(describing: error))")
                    }
                }
            }
        }
    }

    func disconnect() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        stopPing()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        onDisconnected?(nil)
        print("WebSocket disconnected")
    }

    // MARK: - Sending

    func send(_ message: String) {
        guard isConnected else { return }

        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        let startTime = CFAbsoluteTimeGetCurrent()
        let byteCount = message.utf8.count
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
                return
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > PerfLogger.slowSendThresholdSec {
                print("[PerfLogger] 🐢 WebSocket send slow: \(String(format: "%.0f", elapsed * 1000))ms (\(byteCount)B)")
            }
        }
    }

    func sendBinary(_ data: Data) {
        guard isConnected else { return }

        let wsMessage = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("WebSocket send binary error: \(error)")
            }
        }
    }

    // MARK: - Receiving

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.onMessage?(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.onMessage?(text)
                    }
                @unknown default:
                    break
                }

                // 次のメッセージを待機
                self?.receiveMessage()

            case .failure(let error):
                self?.isConnected = false
                self?.onDisconnected?(error)
                print("WebSocket receive error: \(error)")
            }
        }
    }

    // MARK: - Ping/Pong (JSON-level keepalive)

    private func startPing() {
        lastPongAt = CFAbsoluteTimeGetCurrent()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// 受信側で `.pong` メッセージを受け取った時に呼ぶ
    func notePong() {
        lastPongAt = CFAbsoluteTimeGetCurrent()
    }

    private func ping() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPongAt > pongTimeout {
            print("[WS] No pong for \(String(format: "%.1f", now - lastPongAt))s — disconnecting")
            disconnect()
            return
        }

        // JSON ping。serverは DiscoveryService case .ping → JSON pong返却
        let json = "{\"type\":\"ping\",\"timestamp\":\(Date().timeIntervalSince1970)}"
        webSocketTask?.send(.string(json)) { [weak self] error in
            if let error = error {
                print("[WS] Ping send failed: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.onDisconnected?(error)
                }
            }
        }
    }
}

// MARK: - Connection Manager

/// 複数のピアへの接続を管理
class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    @Published var activeConnections: [String: WebSocketClient] = [:]

    /// ピアごとの Noise セキュアチャネル (initiator)。activeConnections と同じ peerId で対応。
    private var secureChannels: [String: SecureChannel] = [:]

    private init() {}

    /// 暗号化してアプリメッセージを送る (client 経路)。確立前・未接続は false。
    @discardableResult
    func sendSecure(_ message: String, to peerId: String) -> Bool {
        return secureChannels[peerId]?.sendApp(message) ?? false
    }

    // MARK: - Connection Management

    func connect(to peer: DiscoveryService.Peer) {
        guard activeConnections[peer.id] == nil else { return }

        // Bonjourサービスエンドポイントを解決してからWebSocket接続
        resolveEndpoint(peer.endpoint) { [weak self] url, host in
            guard let self = self, let url = url else {
                print("Failed to resolve endpoint for \(peer.name)")
                return
            }
            // UDPカーソルチャネルにピアIPを登録（同じIPの別ポート24801へ送信）
            if let host = host {
                UDPCursorChannel.shared.setPeerEndpoint(peerId: peer.id, host: host)
            }
            self.connectWebSocket(url: url, peer: peer)
        }
    }

    /// NWEndpointをWebSocket URLに解決（Bonjour名にスペース等が含まれていても安全）
    /// completion: (URL, NWEndpoint.Host) - 解決したIPもUDPチャネル用に返す
    private func resolveEndpoint(_ endpoint: NWEndpoint, completion: @escaping (URL?, NWEndpoint.Host?) -> Void) {
        switch endpoint {
        case .hostPort(let host, let port):
            completion(buildWebSocketURL(host: host, port: port), host)

        case .service:
            // NWConnectionでBonjourサービスをIPアドレスに解決
            let connection = NWConnection(to: endpoint, using: .tcp)
            var completed = false

            connection.stateUpdateHandler = { state in
                guard !completed else { return }
                switch state {
                case .ready:
                    completed = true
                    if let resolved = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = resolved {
                        let url = self.buildWebSocketURL(host: host, port: port)
                        print("[ConnectionManager] Resolved endpoint: \(host):\(port) -> \(url?.absoluteString ?? "nil")")
                        completion(url, host)
                    } else {
                        completion(nil, nil)
                    }
                    connection.cancel()
                case .failed:
                    completed = true
                    completion(nil, nil)
                    connection.cancel()
                case .cancelled:
                    if !completed {
                        completed = true
                        completion(nil, nil)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .main)

            // 解決タイムアウト
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !completed else { return }
                completed = true
                print("[ConnectionManager] Endpoint resolution timed out")
                connection.cancel()
                completion(nil, nil)
            }

        default:
            completion(nil, nil)
        }
    }

    /// NWEndpoint.Host + Port から ws:// URL を構築
    /// IPv6リンクローカル（例: fe80::1%en0）は[brackets]で囲み%は%25にエンコード
    private func buildWebSocketURL(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let hostStr: String
        switch host {
        case .ipv4(let v4):
            hostStr = "\(v4)"
        case .ipv6(let v6):
            // IPv6 → "[fe80::1%25en0]" 形式
            let raw = "\(v6)"
            // raw は "fe80::...%en0" のような形式。%をパーセントエンコード
            let encoded = raw.replacingOccurrences(of: "%", with: "%25")
            hostStr = "[\(encoded)]"
        case .name(let name, _):
            hostStr = name
        @unknown default:
            return nil
        }
        return URL(string: "ws://\(hostStr):\(port.rawValue)")
    }

    private func connectWebSocket(url: URL, peer: DiscoveryService.Peer) {
        let client = WebSocketClient(url: url)

        client.onConnected = { [weak self] in
            print("Connected to \(peer.name)")
            DispatchQueue.main.async {
                self?.activeConnections[peer.id] = client
                print("[ConnectionManager] Added connection for peerId: \(peer.id)")
                print("[ConnectionManager] Total connections: \(self?.activeConnections.count ?? 0)")

                // connectedPeersに追加
                var connectedPeer = peer
                connectedPeer.isConnected = true
                if !DiscoveryService.shared.connectedPeers.contains(where: { $0.id == peer.id }) {
                    DiscoveryService.shared.connectedPeers.append(connectedPeer)
                }

                // Noise セキュアチャネルを張る (initiator)。ハンドシェイク完了後に
                // 自分の deviceInfo を暗号化して送る (旧来の平文 deviceInfo 送信は廃止)。
                let sc = SecureChannel.initiator(sendFrame: { [weak client] frame in
                    client?.send(frame)
                })
                sc.onEstablished = { [weak sc] _, _, _, _ in
                    guard let sc = sc else { return }
                    if let message = DiscoveryService.shared.buildLocalDeviceInfoMessage(),
                       let json = MessageEncoder.shared.encode(message) {
                        sc.sendApp(json)
                        print("[ConnectionManager] Sent encrypted deviceInfo to \(peer.name)")
                    }
                }
                sc.onMessage = { [weak self] plaintext in
                    DispatchQueue.main.async { self?.handleMessage(plaintext, from: peer.id) }
                }
                sc.onClosed = { [weak self] in
                    DispatchQueue.main.async { self?.disconnect(from: peer.id) }
                }
                self?.secureChannels[peer.id] = sc
                sc.start()
            }
        }

        client.onDisconnected = { [weak self] error in
            print("Disconnected from \(peer.name): \(error?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async {
                self?.activeConnections.removeValue(forKey: peer.id)
                self?.secureChannels.removeValue(forKey: peer.id)
                DiscoveryService.shared.connectedPeers.removeAll { $0.id == peer.id }

                // 接続切れ時にリモートモードを終了してフリーズ防止
                if ScreenManager.shared.isControllingRemote {
                    InputTransmitter.shared.stopTransmitting()
                    ScreenManager.shared.returnControlToLocal()
                    print("[ConnectionManager] Auto-exited remote mode due to disconnect")
                }
            }
        }

        client.onMessage = { [weak self] raw in
            // URLSession completionはバックグラウンドスレッドの可能性あり → メインスレッドへ
            DispatchQueue.main.async {
                self?.routeRawMessage(raw, from: peer.id, client: client)
            }
        }

        client.connect()
    }

    func disconnect(from peerId: String) {
        // リモートモード中なら先に解除（カーソル固定防止）
        if ScreenManager.shared.isControllingRemote {
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
        }
        activeConnections[peerId]?.disconnect()
        activeConnections.removeValue(forKey: peerId)
        secureChannels.removeValue(forKey: peerId)
        UDPCursorChannel.shared.removePeer(peerId: peerId)
        ScreenManager.shared.removeRemoteScreen(deviceId: peerId)
    }

    func disconnectAll() {
        // リモートモード中なら先に解除
        if ScreenManager.shared.isControllingRemote {
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
        }
        for peerId in activeConnections.keys {
            UDPCursorChannel.shared.removePeer(peerId: peerId)
        }
        for client in activeConnections.values {
            client.disconnect()
        }
        activeConnections.removeAll()
        secureChannels.removeAll()
    }

    // MARK: - Message Handling

    /// WebSocket から来た生テキストを振り分ける。
    /// noise envelope は SecureChannel へ、それ以外は keepalive(ping/pong) のみ許可。
    /// 平文のアプリメッセージは一切処理しない (fail-open 防止)。
    private func routeRawMessage(_ raw: String, from peerId: String, client: WebSocketClient) {
        InputCapture.shared.peerMessageReceived()
        if let frame = SecureChannel.decodeEnvelope(raw) {
            secureChannels[peerId]?.receiveFrame(frame)
            return
        }
        switch MessageEncoder.shared.decodeType(from: raw) {
        case .ping:
            let pong = "{\"type\":\"pong\",\"timestamp\":\(Date().timeIntervalSince1970)}"
            client.send(pong)
        case .pong:
            client.notePong()
        default:
            break  // 平文アプリメッセージは破棄 (暗号チャネル外は信用しない)
        }
    }

    /// SecureChannel から復号済みのアプリメッセージを処理する。
    private func handleMessage(_ message: String, from peerId: String) {
        // ピア無音検知ウォッチドッグのリセット（リモートモード中の生存確認）
        InputCapture.shared.peerMessageReceived()

        guard let type = MessageEncoder.shared.decodeType(from: message) else {
            print("Unknown message type from \(peerId)")
            return
        }

        switch type {
        case .ping:
            // pingにはpongで即応答（ピア生存確認用）
            let pong = "{\"type\":\"pong\",\"timestamp\":\(Date().timeIntervalSince1970)}"
            DiscoveryService.shared.send(pong, to: peerId, encrypt: false)
            return

        case .pong:
            // WebSocketClient側のkeepaliveタイマーをリセット（接続生存確認）
            activeConnections[peerId]?.notePong()
            return

        case .cursorMove:
            if let msg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: message) {
                InputReceiver.shared.handleCursorMove(x: msg.x, y: msg.y)
            }

        case .mouseButton:
            if let msg = MessageEncoder.shared.decode(MouseButtonMessage.self, from: message) {
                InputReceiver.shared.handleMouseButton(button: msg.button, isDown: msg.state == .down, clickCount: msg.clickCount)
            }

        case .scroll:
            if let msg = MessageEncoder.shared.decode(ScrollMessage.self, from: message) {
                InputReceiver.shared.handleScroll(dx: msg.dx, dy: msg.dy)
            }

        case .key:
            if let msg = MessageEncoder.shared.decode(KeyMessage.self, from: message) {
                InputReceiver.shared.handleKeyEvent(keycode: msg.keycode, isDown: msg.state == .down, modifiers: msg.modifiers)
            }

        case .controlTransfer:
            if let msg = MessageEncoder.shared.decode(ControlTransferMessage.self, from: message) {
                handleControlTransfer(msg)
            }

        case .clipboard:
            if let msg = MessageEncoder.shared.decode(ClipboardMessage.self, from: message) {
                ClipboardSync.shared.receiveClipboard(format: msg.format, data: msg.data)
            }

        case .deviceInfo:
            if let msg = MessageEncoder.shared.decode(DeviceInfoMessage.self, from: message) {
                handleDeviceInfo(msg, from: peerId)
            }

        case .udpHandshake:
            if let d = message.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let b64 = obj["frame"] as? String {
                UDPCursorChannel.shared.receiveTunneledHandshake(peerId: peerId, frameBase64: b64)
            }

        case .pairingResponse:
            if let msg = MessageEncoder.shared.decode(PairingResponseMessage.self, from: message) {
                handlePairingResponse(msg, from: peerId)
            }

        case .screenLayout:
            if let msg = MessageEncoder.shared.decode(ScreenLayoutMessage.self, from: message) {
                handleScreenLayout(msg, from: peerId)
            }

        case .roleChange:
            if let msg = MessageEncoder.shared.decode(RoleChangeMessage.self, from: message) {
                DispatchQueue.main.async {
                    ScreenManager.shared.handleRemoteRoleChange(role: msg.role, fromDeviceId: msg.deviceId)
                }
            }

        case .filePrepare:
            if let msg = MessageEncoder.shared.decode(FilePrepareMessage.self, from: message) {
                handleFilePrepare(msg, from: peerId)
            }

        case .fileRequest:
            if let msg = MessageEncoder.shared.decode(FileRequestMessage.self, from: message) {
                handleFileRequest(msg, from: peerId)
            }

        case .fileData:
            if let msg = MessageEncoder.shared.decode(FileDataMessage.self, from: message) {
                handleFileData(msg, from: peerId)
            }

        case .fileComplete:
            if let msg = MessageEncoder.shared.decode(FileCompleteMessage.self, from: message) {
                handleFileComplete(msg, from: peerId)
            }

        default:
            break
        }
    }

    private func handleControlTransfer(_ message: ControlTransferMessage) {
        // 受信した時点で自分宛て（WebSocket接続経由で直接受信するため）
        print("[ConnectionManager] Received controlTransfer: to=\(message.to), entry=(\(message.entryX), \(message.entryY))")
        let position = ScreenManager.shared.denormalizePosition(x: message.entryX, y: message.entryY)
        InputReceiver.shared.setVirtualCursorPosition(position)
        InputCapture.shared.moveCursor(to: position)
        InputCapture.shared.exitRemoteMode()
        ScreenManager.shared.returnControlToLocal()
    }

    private func handleDeviceInfo(_ message: DeviceInfoMessage, from peerId: String) {
        // 鍵交換は Noise ハンドシェイクで完了済み。ここでは画面情報の取り込みと
        // 信頼記録のみ行う (相手の static key は SecureChannel が保持している)。

        // リモート画面として追加（screens配列があればディスプレイ単位で追加）
        if let screens = message.screens, !screens.isEmpty {
            ScreenManager.shared.setRemoteDisplays(peerId: peerId, peerName: message.hostname, displays: screens)
        } else {
            ScreenManager.shared.addRemoteScreen(
                deviceId: peerId,
                name: message.hostname,
                width: CGFloat(message.screenWidth),
                height: CGFloat(message.screenHeight)
            )
        }
        print("[DeviceInfo] Added \(message.screens?.count ?? 1) display(s) for peer \(message.hostname) [\(peerId)]")

        // 接続成功 = サーバー側が受諾した = 信頼を記録（次回以降は相互ペア済み扱い）。
        // 記録する鍵は Noise ハンドシェイクで PoP 済みの相手 static key を使う。
        let staticKey = secureChannels[peerId]?.remoteStaticKey ?? Data()
        PairingManager.shared.recordTrust(
            deviceId: message.deviceId,
            hostname: message.hostname,
            publicKey: staticKey
        )

        // サーバーが受諾 = 接続確立。UDP カーソル用のセキュア Datagram セッションを開始
        // (client=initiator。ハンドシェイクは暗号化済み WS 上をトンネルする)。
        UDPCursorChannel.shared.beginSecureSession(peerId: peerId, isInitiator: true)
    }

    private func handlePairingResponse(_ message: PairingResponseMessage, from peerId: String) {
        if !message.accepted {
            print("[Pairing] Connection rejected by \(peerId)")
            DispatchQueue.main.async {
                ConnectionManager.shared.disconnect(from: peerId)
                let alert = NSAlert()
                alert.messageText = "接続が拒否されました"
                alert.informativeText = "相手のデバイスでペアリングが拒否されました。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func handleScreenLayout(_ message: ScreenLayoutMessage, from peerId: String) {
        print("[ScreenLayout] Received from \(peerId): edge=\(message.edge), offset=(\(message.offsetX), \(message.offsetY))")

        // 相手から受信したエッジを逆にして適用
        let reverseEdge: ScreenManager.RemoteScreen.Edge
        switch message.edge {
        case "left":
            reverseEdge = .right
        case "right":
            reverseEdge = .left
        case "top":
            reverseEdge = .bottom
        case "bottom":
            reverseEdge = .top
        default:
            reverseEdge = .right
        }

        print("[ScreenLayout] Applying reverse edge: \(reverseEdge)")

        // リモート画面の配置を更新
        if let index = ScreenManager.shared.remoteScreens.firstIndex(where: { $0.id == peerId }) {
            // 無限ループ防止：通知を送信しないバージョンを使う
            DispatchQueue.main.async {
                ScreenManager.shared.remoteScreens[index].attachedTo = message.localDeviceId
                ScreenManager.shared.remoteScreens[index].attachedEdge = reverseEdge
                ScreenManager.shared.remoteScreens[index].offsetX = -CGFloat(message.offsetX)
                ScreenManager.shared.remoteScreens[index].offsetY = -CGFloat(message.offsetY)
                ScreenManager.shared.objectWillChange.send()
                ScreenManager.shared.saveLayout()
                print("[ScreenLayout] Updated remote screen position")
            }
        } else {
            print("[ScreenLayout] Remote screen not found for peerId: \(peerId)")
        }
    }

    // MARK: - File Transfer Handlers

    private func handleFilePrepare(_ message: FilePrepareMessage, from peerId: String) {
        print("[FileTransfer] Received file prepare: \(message.fileName) (\(message.fileSize) bytes)")
        // 受信準備を開始
        FileTransfer.shared.prepareReceive(
            transferId: message.transferId,
            fileName: message.fileName,
            fileSize: message.fileSize,
            from: peerId
        )
    }

    private func handleFileRequest(_ message: FileRequestMessage, from peerId: String) {
        print("[FileTransfer] Received file request: \(message.path)")
        // リクエストされたファイルを送信
        FileTransfer.shared.handleFileRequest(path: message.path, requestId: message.requestId, to: peerId)
    }

    private func handleFileData(_ message: FileDataMessage, from peerId: String) {
        // チャンクデータを受信
        FileTransfer.shared.receiveChunk(
            transferId: message.transferId,
            chunkIndex: message.chunkIndex,
            totalChunks: message.totalChunks,
            data: message.data
        )
    }

    private func handleFileComplete(_ message: FileCompleteMessage, from peerId: String) {
        print("[FileTransfer] Transfer complete: \(message.transferId), success: \(message.success)")
        FileTransfer.shared.completeTransfer(transferId: message.transferId, success: message.success)
    }

    // MARK: - Message Sending

    func broadcast(_ message: String) {
        for client in activeConnections.values {
            client.send(message)
        }
    }

    func send(_ message: String, to peerId: String) {
        activeConnections[peerId]?.send(message)
    }

    func handleIncomingMessage(_ message: String, from peerId: String) {
        guard let type = MessageEncoder.shared.decodeType(from: message) else {
            return
        }

        // 高頻度パス: CGEvent系は呼び出し元キュー(ioQueue)のままで実行
        // (CGEvent.post はthread-safe、ScreenManagerのlocalScreensはキャッシュ済み)
        switch type {
        case .cursorMove:
            if let msg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: message) {
                InputReceiver.shared.handleCursorMove(x: msg.x, y: msg.y)
            }
            return
        case .mouseButton:
            if let msg = MessageEncoder.shared.decode(MouseButtonMessage.self, from: message) {
                InputReceiver.shared.handleMouseButton(button: msg.button, isDown: msg.state == .down, clickCount: msg.clickCount)
            }
            return
        case .scroll:
            if let msg = MessageEncoder.shared.decode(ScrollMessage.self, from: message) {
                InputReceiver.shared.handleScroll(dx: msg.dx, dy: msg.dy)
            }
            return
        case .key:
            if let msg = MessageEncoder.shared.decode(KeyMessage.self, from: message) {
                InputReceiver.shared.handleKeyEvent(keycode: msg.keycode, isDown: msg.state == .down, modifiers: msg.modifiers)
            }
            return
        default:
            break
        }

        // それ以外（状態変更を伴う）はmainで処理
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.handleIncomingMessage(message, from: peerId) }
            return
        }

        switch type {
        case .controlTransfer:
            if let msg = MessageEncoder.shared.decode(ControlTransferMessage.self, from: message) {
                print("[ConnectionManager] Received controlTransfer (incoming): to=\(msg.to)")
                let position = ScreenManager.shared.denormalizePosition(x: msg.entryX, y: msg.entryY)
                InputReceiver.shared.setVirtualCursorPosition(position)
                InputCapture.shared.moveCursor(to: position)
                InputCapture.shared.exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
            }
        case .clipboard:
            if let msg = MessageEncoder.shared.decode(ClipboardMessage.self, from: message) {
                ClipboardSync.shared.receiveClipboard(format: msg.format, data: msg.data)
            }
        case .roleChange:
            if let msg = MessageEncoder.shared.decode(RoleChangeMessage.self, from: message) {
                ScreenManager.shared.handleRemoteRoleChange(role: msg.role, fromDeviceId: msg.deviceId)
            }
        default:
            break
        }
    }

}
