import Foundation
import Network
import Combine
import Cocoa

/// mDNS発見サービス
/// Bonjour を使用してLAN内のMouse2Mouseピアを発見・接続管理
class DiscoveryService: ObservableObject {
    static let shared = DiscoveryService()

    // MARK: - Published Properties

    @Published var isRunning = false
    @Published var discoveredPeers: [Peer] = []
    @Published var connectedPeers: [Peer] = []
    @Published var localDeviceInfo: DeviceInfo?

    // MARK: - Constants

    private let serviceType = "_mugendesk._tcp"
    private let serviceDomain = "local."
    private let defaultPort: UInt16 = 24800

    // MARK: - Private Properties

    private var browser: NWBrowser?
    private var webSocketServer: WebSocketServer?

    // MARK: - Types

    struct Peer: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        var deviceInfo: DeviceInfoMessage?
        var isConnected: Bool = false

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: Peer, rhs: Peer) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct DeviceInfo {
        let deviceId: String
        let hostname: String
        let screenWidth: Int
        let screenHeight: Int
    }

    // MARK: - Lifecycle

    private init() {
        setupLocalDeviceInfo()
    }

    private func setupLocalDeviceInfo() {
        let deviceId = getDeviceId()
        let hostname = Host.current().localizedName ?? "Mac"
        let screen = NSScreen.main

        // 実際のピクセルサイズを取得（Retina対応）
        let backingScale = screen?.backingScaleFactor ?? 1.0
        let width = Int((screen?.frame.width ?? 1920) * backingScale)
        let height = Int((screen?.frame.height ?? 1080) * backingScale)

        print("[DeviceInfo] Screen size - Points: \(Int(screen?.frame.width ?? 0))x\(Int(screen?.frame.height ?? 0)), Scale: \(backingScale), Pixels: \(width)x\(height)")

        localDeviceInfo = DeviceInfo(
            deviceId: deviceId,
            hostname: hostname,
            screenWidth: width,
            screenHeight: height
        )
    }

    private func getDeviceId() -> String {
        // UUIDをKeychainまたはUserDefaultsに保存して一貫性を保つ
        let key = "Mouse2Mouse.DeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: - Service Management

    func start() {
        print("[DEBUG] start() called, isRunning=\(isRunning)")
        guard !isRunning else {
            print("[DEBUG] Already running, skipping start")
            return
        }

        print("[DEBUG] Starting browser...")
        startBrowser()
        print("[DEBUG] Starting WebSocket server (with Bonjour)...")
        startWebSocketServer()

        isRunning = true
        print("[DEBUG] DiscoveryService started, isRunning=\(isRunning)")
    }

    func stop() {
        browser?.cancel()
        browser = nil

        webSocketServer?.stop()
        webSocketServer = nil

        ConnectionManager.shared.disconnectAll()
        connectedPeers.removeAll()

        isRunning = false
        print("DiscoveryService stopped")
    }

    // MARK: - Browser (Peer Discovery)

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: serviceDomain), using: parameters)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Browser ready")
            case .failed(let error):
                print("Browser failed: \(error)")
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResults(results)
        }

        browser?.start(queue: .main)
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var peers: [Peer] = []

        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                // 自分自身は除外
                if name == localDeviceInfo?.hostname {
                    continue
                }

                let id = "\(name).\(type).\(domain)"
                var peer = Peer(id: id, name: name, endpoint: result.endpoint)

                // TXTレコードからデバイス情報を取得
                if case .bonjour(let txtRecord) = result.metadata {
                    peer.deviceInfo = parseDeviceInfo(from: txtRecord)
                }

                peers.append(peer)
            }
        }

        DispatchQueue.main.async {
            let oldPeerIds = Set(self.discoveredPeers.map { $0.id })
            self.discoveredPeers = peers

            // 新しいピアを発見したら自動接続
            for peer in peers {
                if !oldPeerIds.contains(peer.id) && !self.connectedPeers.contains(where: { $0.id == peer.id }) {
                    print("[AutoConnect] New peer discovered: \(peer.name), connecting...")
                    self.connect(to: peer)
                }
            }
        }
    }

    private func parseDeviceInfo(from txtRecord: NWTXTRecord) -> DeviceInfoMessage? {
        guard let deviceId = txtRecord["device_id"],
              let hostname = txtRecord["hostname"],
              let deviceTypeStr = txtRecord["device_type"],
              let widthStr = txtRecord["screen_width"],
              let heightStr = txtRecord["screen_height"],
              let width = Int(widthStr),
              let height = Int(heightStr) else {
            return nil
        }

        let deviceType: DeviceType = deviceTypeStr == "ios" ? .ios : .mac

        return DeviceInfoMessage(
            deviceId: deviceId,
            hostname: hostname,
            deviceType: deviceType,
            screenWidth: width,
            screenHeight: height
        )
    }

    // MARK: - Connection Management

    func connect(to peer: Peer) {
        // WebSocket接続を使用
        ConnectionManager.shared.connect(to: peer)
    }

    func disconnect(from peer: Peer) {
        ConnectionManager.shared.disconnect(from: peer.id)
        connectedPeers.removeAll { $0.id == peer.id }
    }

    // MARK: - WebSocket Server

    // WebSocketServerのクライアントID → peerIDのマッピング
    private var serverClientMapping: [String: String] = [:]

    private func startWebSocketServer() {
        webSocketServer = WebSocketServer(port: defaultPort)

        webSocketServer?.onClientConnected = { [weak self] clientId in
            print("[WebSocketServer] Client connected: \(clientId)")
            print("[WebSocketServer] Waiting for deviceInfo from client...")
        }

        webSocketServer?.onMessageReceived = { [weak self] clientId, message in
            // サーバー経由で受信したメッセージを処理
            guard let type = MessageEncoder.shared.decodeType(from: message) else {
                return
            }

            switch type {
            case .deviceInfo:
                if let msg = MessageEncoder.shared.decode(DeviceInfoMessage.self, from: message) {
                    // peerIdを取得（discoveredPeersから、またはhostnameベース）
                    let peerId = self?.discoveredPeers.first(where: { $0.deviceInfo?.hostname == msg.hostname })?.id ?? "\(msg.hostname)._mugendesk._tcp.local."

                    // マッピングを保存
                    self?.serverClientMapping[clientId] = peerId
                    print("[DeviceInfo] Mapped clientId \(clientId) -> peerId \(peerId)")

                    ScreenManager.shared.addRemoteScreen(
                        deviceId: peerId,
                        name: msg.hostname,
                        width: CGFloat(msg.screenWidth),
                        height: CGFloat(msg.screenHeight)
                    )
                    print("[DeviceInfo] Added remote screen (server side) with peerId: \(peerId), hostname: \(msg.hostname)")

                    // 接続完了をconnectedPeersに追加
                    if let peer = self?.discoveredPeers.first(where: { $0.id == peerId }) {
                        var updated = peer
                        updated.isConnected = true
                        DispatchQueue.main.async {
                            if !DiscoveryService.shared.connectedPeers.contains(where: { $0.id == peerId }) {
                                DiscoveryService.shared.connectedPeers.append(updated)
                            }
                        }
                    }

                    // 自分のdeviceInfoを返信
                    if let localInfo = self?.localDeviceInfo {
                        let responseMsg = DeviceInfoMessage(
                            deviceId: localInfo.deviceId,
                            hostname: localInfo.hostname,
                            deviceType: .mac,
                            screenWidth: localInfo.screenWidth,
                            screenHeight: localInfo.screenHeight
                        )
                        if let json = MessageEncoder.shared.encode(responseMsg) {
                            self?.webSocketServer?.send(json, to: clientId)
                            print("[DeviceInfo] Sent deviceInfo response to clientId: \(clientId)")
                        }
                    }
                }
            case .screenLayout:
                if let msg = MessageEncoder.shared.decode(ScreenLayoutMessage.self, from: message) {
                    // clientIdからpeerIdを取得
                    let peerId = self?.serverClientMapping[clientId] ?? clientId

                    let reverseEdge: ScreenManager.RemoteScreen.Edge
                    switch msg.edge {
                    case "left": reverseEdge = .right
                    case "right": reverseEdge = .left
                    case "top": reverseEdge = .bottom
                    case "bottom": reverseEdge = .top
                    default: reverseEdge = .right
                    }

                    if let index = ScreenManager.shared.remoteScreens.firstIndex(where: { $0.id == peerId }) {
                        DispatchQueue.main.async {
                            ScreenManager.shared.remoteScreens[index].attachedTo = msg.localDeviceId
                            ScreenManager.shared.remoteScreens[index].attachedEdge = reverseEdge
                            ScreenManager.shared.remoteScreens[index].offsetX = -CGFloat(msg.offsetX)
                            ScreenManager.shared.remoteScreens[index].offsetY = -CGFloat(msg.offsetY)
                            ScreenManager.shared.objectWillChange.send()
                            ScreenManager.shared.saveLayout()
                            print("[ScreenLayout] Updated layout for peerId: \(peerId)")
                        }
                    }
                }
            case .cursorMove, .mouseButton, .scroll, .key, .controlTransfer, .clipboard:
                // clientIdからpeerIdを取得
                let peerId = self?.serverClientMapping[clientId] ?? clientId

                if type == .cursorMove {
                    print("[DiscoveryService] Received cursorMove from \(peerId)")
                }

                // WebSocketClientのメッセージハンドラーを呼び出す
                ConnectionManager.shared.handleIncomingMessage(message, from: peerId)

            case .filePrepare:
                let peerId = self?.serverClientMapping[clientId] ?? clientId
                if let msg = MessageEncoder.shared.decode(FilePrepareMessage.self, from: message) {
                    FileTransfer.shared.prepareReceive(
                        transferId: msg.transferId,
                        fileName: msg.fileName,
                        fileSize: msg.fileSize,
                        from: peerId
                    )
                }

            case .fileRequest:
                let peerId = self?.serverClientMapping[clientId] ?? clientId
                if let msg = MessageEncoder.shared.decode(FileRequestMessage.self, from: message) {
                    FileTransfer.shared.handleFileRequest(path: msg.path, requestId: msg.requestId, to: peerId)
                }

            case .fileData:
                if let msg = MessageEncoder.shared.decode(FileDataMessage.self, from: message) {
                    FileTransfer.shared.receiveChunk(
                        transferId: msg.transferId,
                        chunkIndex: msg.chunkIndex,
                        totalChunks: msg.totalChunks,
                        data: msg.data
                    )
                }

            case .fileComplete:
                if let msg = MessageEncoder.shared.decode(FileCompleteMessage.self, from: message) {
                    FileTransfer.shared.completeTransfer(transferId: msg.transferId, success: msg.success)
                }

            default:
                break
            }
        }

        // Bonjour広告付きでWebSocketサーバーを開始
        if let info = localDeviceInfo {
            let txtRecord = NWTXTRecord([
                "version": "1",
                "hostname": info.hostname,
                "device_type": "mac",
                "screen_width": String(info.screenWidth),
                "screen_height": String(info.screenHeight),
                "device_id": info.deviceId
            ])
            webSocketServer?.start(bonjourName: info.hostname, txtRecord: txtRecord)
        } else {
            webSocketServer?.start()
        }
    }

    // MARK: - Message Sending

    func broadcast(_ message: String) {
        webSocketServer?.broadcast(message)
    }

    func send(_ message: String, to peerId: String) {
        print("[DiscoveryService] Trying to send to \(peerId)")
        print("[DiscoveryService] Active connections: \(ConnectionManager.shared.activeConnections.keys)")
        print("[DiscoveryService] Server mappings: \(serverClientMapping)")

        // WebSocketClient経由で送信を試みる
        if ConnectionManager.shared.activeConnections[peerId] != nil {
            ConnectionManager.shared.send(message, to: peerId)
            print("[DiscoveryService] Sent via WebSocketClient to \(peerId)")
        } else {
            // WebSocketServer経由で送信（逆マッピングを使う）
            if let clientId = serverClientMapping.first(where: { $0.value == peerId })?.key {
                webSocketServer?.send(message, to: clientId)
                print("[DiscoveryService] Sent via WebSocketServer to clientId: \(clientId) (peerId: \(peerId))")
            } else {
                print("[DiscoveryService] No route to peerId: \(peerId)")
            }
        }
    }
}
