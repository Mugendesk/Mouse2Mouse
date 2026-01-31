import Foundation
import Combine
import Network

/// WebSocketクライアント
/// URLSessionWebSocketTaskを使用したWebSocket接続
class WebSocketClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?

    private(set) var isConnected = false
    let serverURL: URL

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
        config.waitsForConnectivity = true

        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: serverURL)

        print("WebSocket connecting to \(serverURL)")

        webSocketTask?.resume()

        // 最初のメッセージ受信で接続確立を確認
        receiveMessage()

        // 接続確認用ping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webSocketTask?.sendPing { error in
                if error == nil {
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

    func disconnect() {
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
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
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

    // MARK: - Ping/Pong

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func ping() {
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                print("Ping failed: \(error)")
                self?.isConnected = false
                self?.onDisconnected?(error)
            }
        }
    }
}

// MARK: - Connection Manager

/// 複数のピアへの接続を管理
class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    @Published var activeConnections: [String: WebSocketClient] = [:]

    private init() {}

    // MARK: - Connection Management

    func connect(to peer: DiscoveryService.Peer) {
        guard activeConnections[peer.id] == nil else { return }

        // エンドポイントからURLを構築
        guard let url = buildWebSocketURL(from: peer.endpoint) else {
            print("Failed to build WebSocket URL for \(peer.name)")
            return
        }

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

                // 接続後に自分のdeviceInfoを送信
                if let info = DiscoveryService.shared.localDeviceInfo {
                    let message = DeviceInfoMessage(
                        deviceId: info.deviceId,
                        hostname: info.hostname,
                        deviceType: .mac,
                        screenWidth: info.screenWidth,
                        screenHeight: info.screenHeight
                    )
                    if let json = MessageEncoder.shared.encode(message) {
                        client.send(json)
                        print("[ConnectionManager] Sent deviceInfo to \(peer.name)")
                    }
                }
            }
        }

        client.onDisconnected = { [weak self] error in
            print("Disconnected from \(peer.name): \(error?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async {
                self?.activeConnections.removeValue(forKey: peer.id)
                DiscoveryService.shared.connectedPeers.removeAll { $0.id == peer.id }

                // 接続切れ時にリモートモードを終了してフリーズ防止
                if ScreenManager.shared.isControllingRemote {
                    InputTransmitter.shared.stopTransmitting()
                    ScreenManager.shared.returnControlToLocal()
                    print("[ConnectionManager] Auto-exited remote mode due to disconnect")
                }
            }
        }

        client.onMessage = { [weak self] message in
            self?.handleMessage(message, from: peer.id)
        }

        client.connect()
    }

    func disconnect(from peerId: String) {
        activeConnections[peerId]?.disconnect()
        activeConnections.removeValue(forKey: peerId)
    }

    func disconnectAll() {
        for client in activeConnections.values {
            client.disconnect()
        }
        activeConnections.removeAll()
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: String, from peerId: String) {
        guard let type = MessageEncoder.shared.decodeType(from: message) else {
            print("Unknown message type from \(peerId)")
            return
        }

        switch type {
        case .cursorMove:
            if let msg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: message) {
                InputReceiver.shared.handleCursorMove(x: msg.x, y: msg.y)
            }

        case .mouseButton:
            if let msg = MessageEncoder.shared.decode(MouseButtonMessage.self, from: message) {
                InputReceiver.shared.handleMouseButton(button: msg.button, isDown: msg.state == .down)
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
        if message.to == DiscoveryService.shared.localDeviceInfo?.deviceId {
            // 自分宛ての制御権移譲
            let position = ScreenManager.shared.denormalizePosition(x: message.entryX, y: message.entryY)
            InputCapture.shared.moveCursor(to: position)
            InputCapture.shared.exitRemoteMode()
            ScreenManager.shared.returnControlToLocal()
        }
    }

    private func handleDeviceInfo(_ message: DeviceInfoMessage, from peerId: String) {
        // リモート画面として追加（デフォルトはメイン画面の右側）
        // peerIdを使用して一貫性を保つ
        ScreenManager.shared.addRemoteScreen(
            deviceId: peerId,
            name: message.hostname,
            width: CGFloat(message.screenWidth),
            height: CGFloat(message.screenHeight)
        )
        print("[DeviceInfo] Added remote screen with peerId: \(peerId), hostname: \(message.hostname)")
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
        // WebSocketServerから転送されたメッセージを処理
        guard let type = MessageEncoder.shared.decodeType(from: message) else {
            return
        }

        switch type {
        case .cursorMove:
            if let msg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: message) {
                print("[ConnectionManager] Received cursorMove from \(peerId): (\(msg.x), \(msg.y))")
                InputReceiver.shared.handleCursorMove(x: msg.x, y: msg.y)
            }
        case .mouseButton:
            if let msg = MessageEncoder.shared.decode(MouseButtonMessage.self, from: message) {
                InputReceiver.shared.handleMouseButton(button: msg.button, isDown: msg.state == .down)
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
                if msg.to == DiscoveryService.shared.localDeviceInfo?.deviceId {
                    let position = ScreenManager.shared.denormalizePosition(x: msg.entryX, y: msg.entryY)
                    InputCapture.shared.moveCursor(to: position)
                    InputCapture.shared.exitRemoteMode()
                    ScreenManager.shared.returnControlToLocal()
                }
            }
        case .clipboard:
            if let msg = MessageEncoder.shared.decode(ClipboardMessage.self, from: message) {
                ClipboardSync.shared.receiveClipboard(format: msg.format, data: msg.data)
            }
        case .roleChange:
            if let msg = MessageEncoder.shared.decode(RoleChangeMessage.self, from: message) {
                DispatchQueue.main.async {
                    ScreenManager.shared.handleRemoteRoleChange(role: msg.role, fromDeviceId: msg.deviceId)
                }
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func buildWebSocketURL(from endpoint: NWEndpoint) -> URL? {
        switch endpoint {
        case .hostPort(let host, let port):
            return URL(string: "ws://\(host):\(port)")
        case .service(let name, _, let domain, _):
            return URL(string: "ws://\(name).\(domain):24800")
        default:
            return nil
        }
    }
}
