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
        let displays: [DisplayInfo]  // 物理ディスプレイ単位の情報
    }

    // MARK: - Lifecycle

    private init() {
        setupLocalDeviceInfo()
    }

    private func setupLocalDeviceInfo() {
        let deviceId = getDeviceId()
        let hostname = Host.current().localizedName ?? "Mac"

        // 仮想デスクトップ全体（全ディスプレイの和集合）のサイズを計算
        let unionAppKit = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let width = Int(unionAppKit.isNull ? 1920 : unionAppKit.width)
        let height = Int(unionAppKit.isNull ? 1080 : unionAppKit.height)

        // 各物理ディスプレイの位置をunion左上原点（Quartz: Y↓）で表現
        // unionAppKit.minX/minY（AppKit, Y↑）を基準にずらす
        var displays: [DisplayInfo] = []
        for screen in NSScreen.screens {
            let displayId: String
            if let displayNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                displayId = "display_\(displayNum)"
            } else {
                displayId = "display_\(displays.count)"
            }
            let isMain = screen == NSScreen.main

            // AppKit座標 → union相対 → Quartz変換
            // AppKit: y軸上向き、原点はprimary左下
            // Union相対AppKit: x = screen.x - union.minX, y = screen.y - union.minY
            let relAppKitX = screen.frame.origin.x - unionAppKit.minX
            let relAppKitY = screen.frame.origin.y - unionAppKit.minY

            // union空間で「画面の上端」のY座標(Quartz, Y↓)
            // unionの高さからAppKitの「画面上端」までの距離
            let appKitTopY = relAppKitY + screen.frame.height
            let quartzOriginY = unionAppKit.height - appKitTopY

            let info = DisplayInfo(
                id: displayId,
                name: isMain ? "メインディスプレイ" : "ディスプレイ \(displays.count + 1)",
                originX: Double(relAppKitX),
                originY: Double(quartzOriginY),
                width: Double(screen.frame.width),
                height: Double(screen.frame.height),
                isMain: isMain
            )
            displays.append(info)
            print("[DeviceInfo]   display \(displayId) at union(\(Int(info.originX)),\(Int(info.originY))) size \(Int(info.width))x\(Int(info.height)) main=\(isMain)")
        }

        print("[DeviceInfo] Virtual desktop size - Points: \(width)x\(height) (screens: \(displays.count), primaryHeight: \(primaryHeight))")

        localDeviceInfo = DeviceInfo(
            deviceId: deviceId,
            hostname: hostname,
            screenWidth: width,
            screenHeight: height,
            displays: displays
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

        // init時にNSScreen.screensが空だった可能性があるので、ここで再取得
        setupLocalDeviceInfo()

        print("[DEBUG] Starting browser...")
        startBrowser()
        print("[DEBUG] Starting WebSocket server (with Bonjour)...")
        startWebSocketServer()
        print("[DEBUG] Starting UDP cursor channel...")
        UDPCursorChannel.shared.start()

        isRunning = true
        print("[DEBUG] DiscoveryService started, isRunning=\(isRunning)")
    }

    func stop() {
        browser?.cancel()
        browser = nil

        webSocketServer?.stop()
        webSocketServer = nil

        UDPCursorChannel.shared.stop()

        ConnectionManager.shared.disconnectAll()
        connectedPeers.removeAll()
        serverClientMapping.removeAll()
        messageRates.removeAll()
        ScreenManager.shared.remoteScreens.removeAll()

        isRunning = false
        print("DiscoveryService stopped")
    }

    /// スリープ復帰用のソフトリスタート。
    /// stop()と違い ScreenManager.remoteScreens（保存レイアウト）は触らない。
    /// listenerのcancel完了(.cancelled state)を待ってからbindし直すことで
    /// EADDRINUSE(Address already in use)を回避する。
    func restartAfterWake() {
        print("[Discovery] restartAfterWake — tearing down stale sockets")

        ConnectionManager.shared.disconnectAll()
        connectedPeers.removeAll()
        serverClientMapping.removeAll()
        messageRates.removeAll()

        browser?.cancel()
        browser = nil

        let oldServer = webSocketServer
        webSocketServer = nil

        // WebSocket listener と UDP listener の両方 cancel 完了を待つ
        let group = DispatchGroup()
        group.enter()
        if let oldServer = oldServer {
            oldServer.stop { group.leave() }
        } else {
            group.leave()
        }
        group.enter()
        UDPCursorChannel.shared.stop { group.leave() }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            print("[Discovery] All listeners cancelled — rebinding")
            self.setupLocalDeviceInfo()
            self.startBrowser()
            self.startWebSocketServer()
            UDPCursorChannel.shared.start()
            print("[Discovery] restartAfterWake complete")
        }
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
        let myDeviceId = localDeviceInfo?.deviceId

        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                // TXTレコードからデバイス情報を取得（自己除外判定にも使う）
                var deviceInfo: DeviceInfoMessage?
                if case .bonjour(let txtRecord) = result.metadata {
                    deviceInfo = parseDeviceInfo(from: txtRecord)
                }

                // 自分自身は device_id で除外（同名Mac対策）
                // TXTが取れない場合のフォールバックとしてhostname比較も併用
                if let theirId = deviceInfo?.deviceId, theirId == myDeviceId {
                    continue
                }
                if deviceInfo == nil && name == localDeviceInfo?.hostname {
                    continue
                }

                let id = "\(name).\(type).\(domain)"
                var peer = Peer(id: id, name: name, endpoint: result.endpoint)
                peer.deviceInfo = deviceInfo

                peers.append(peer)
            }
        }

        DispatchQueue.main.async {
            self.discoveredPeers = peers
            // 自動接続は行わない（手動ペアリング）
            // ユーザーがMenuBarViewから「接続」ボタンをクリックして接続する
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

    // メッセージレート制限（DoS防止）
    // カーソル1000Hz + heartbeat + 余裕で2000/sec
    private var messageRates: [String: (count: Int, resetTime: Date)] = [:]
    private let maxMessagesPerSecond = 2000

    private func startWebSocketServer() {
        webSocketServer = WebSocketServer(port: defaultPort)

        webSocketServer?.onClientConnected = { [weak self] clientId in
            print("[WebSocketServer] Client connected: \(clientId)")
            print("[WebSocketServer] Waiting for deviceInfo from client...")
        }

        webSocketServer?.onClientDisconnected = { [weak self] clientId in
            guard let self = self else { return }
            print("[WebSocketServer] Client disconnected: \(clientId)")
            if let peerId = self.serverClientMapping[clientId] {
                UDPCursorChannel.shared.removePeer(peerId: peerId)
                DispatchQueue.main.async {
                    // リモートモード中なら解除
                    if ScreenManager.shared.isControllingRemote {
                        InputTransmitter.shared.stopTransmitting()
                        ScreenManager.shared.returnControlToLocal()
                    }
                    ScreenManager.shared.removeRemoteScreen(deviceId: peerId)
                    self.connectedPeers.removeAll { $0.id == peerId }
                    self.serverClientMapping.removeValue(forKey: clientId)
                    print("[WebSocketServer] Cleaned up peer: \(peerId)")
                }
            }
        }

        webSocketServer?.onMessageReceived = { [weak self] clientId, rawMessage in
            guard let self = self else { return }

            // ピア無音検知ウォッチドッグのリセット
            InputCapture.shared.peerMessageReceived()

            // レート制限チェック
            let now = Date()
            var rate = self.messageRates[clientId] ?? (count: 0, resetTime: now)
            if now.timeIntervalSince(rate.resetTime) >= 1.0 {
                rate = (count: 1, resetTime: now)
            } else {
                rate.count += 1
                if rate.count > self.maxMessagesPerSecond {
                    // レート超過: メッセージを破棄
                    return
                }
            }
            self.messageRates[clientId] = rate

            // 高頻度パス: 入力イベントは暗号化されていないので直接decode→処理
            // (decodeType×複数回のJSON parseを避ける)
            if let cursorMsg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: rawMessage),
               cursorMsg.type == "cursor_move" {
                InputReceiver.shared.handleCursorMove(x: cursorMsg.x, y: cursorMsg.y)
                return
            }

            // clientIdからpeerIdを解決（暗号化復号に必要）
            let senderPeerId = self.serverClientMapping[clientId] ?? clientId

            // 暗号化メッセージのアンラップを試みる（初回typeデコードを保持して再利用）
            let initialType = MessageEncoder.shared.decodeType(from: rawMessage)
            let message: String
            let type: MessageType?
            if initialType == .encrypted,
               let decrypted = CryptoManager.shared.unwrapMessage(rawMessage, from: senderPeerId) {
                message = decrypted
                type = MessageEncoder.shared.decodeType(from: message)
            } else {
                message = rawMessage
                type = initialType
            }

            guard let type = type else { return }

            switch type {
            case .ping:
                // pongで即応答（ピア生存確認用）
                let pong = "{\"type\":\"pong\",\"timestamp\":\(Date().timeIntervalSince1970)}"
                self.webSocketServer?.send(pong, to: clientId)
                return
            case .pong:
                return
            case .deviceInfo:
                if let msg = MessageEncoder.shared.decode(DeviceInfoMessage.self, from: message) {
                    // ペアリング承認ゲート：未ペアならユーザー確認を待つ
                    if PairingManager.shared.isPaired(deviceId: msg.deviceId) {
                        self.proceedDeviceInfo(msg, clientId: clientId)
                    } else {
                        let publicKeyData = msg.publicKey.flatMap { Data(base64Encoded: $0) } ?? Data()
                        print("[Pairing] Approval requested for \(msg.hostname) [\(msg.deviceId)]")
                        PairingManager.shared.requestApproval(
                            deviceId: msg.deviceId,
                            hostname: msg.hostname,
                            publicKey: publicKeyData
                        ) { [weak self] approved in
                            guard let self = self else { return }
                            if approved {
                                self.proceedDeviceInfo(msg, clientId: clientId)
                            } else {
                                let response = PairingResponseMessage(accepted: false)
                                if let json = MessageEncoder.shared.encode(response) {
                                    self.webSocketServer?.send(json, to: clientId)
                                }
                                // 拒否メッセージ送信を待ってから切断
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    self.webSocketServer?.disconnect(clientId: clientId)
                                }
                            }
                        }
                    }
                }
            case .screenLayout:
                if let msg = MessageEncoder.shared.decode(ScreenLayoutMessage.self, from: message) {
                    // clientIdからpeerIdを取得
                    let peerId = self.serverClientMapping[clientId] ?? clientId

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
            case .roleChange:
                let peerId = self.serverClientMapping[clientId] ?? clientId
                if let msg = MessageEncoder.shared.decode(RoleChangeMessage.self, from: message) {
                    print("[DiscoveryService] Received roleChange from \(peerId): \(msg.role)")
                    DispatchQueue.main.async {
                        ScreenManager.shared.handleRemoteRoleChange(role: msg.role, fromDeviceId: msg.deviceId)
                    }
                }

            case .cursorMove, .mouseButton, .scroll, .key, .controlTransfer, .clipboard:
                // clientIdからpeerIdを取得
                let peerId = self.serverClientMapping[clientId] ?? clientId

                // WebSocketClientのメッセージハンドラーを呼び出す
                ConnectionManager.shared.handleIncomingMessage(message, from: peerId)

            case .filePrepare:
                let peerId = self.serverClientMapping[clientId] ?? clientId
                if let msg = MessageEncoder.shared.decode(FilePrepareMessage.self, from: message) {
                    FileTransfer.shared.prepareReceive(
                        transferId: msg.transferId,
                        fileName: msg.fileName,
                        fileSize: msg.fileSize,
                        from: peerId
                    )
                }

            case .fileRequest:
                let peerId = self.serverClientMapping[clientId] ?? clientId
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

    // MARK: - DeviceInfo Processing (post-approval)

    /// 承認後の deviceInfo 受け入れ処理（ペア済み or 承認直後の共通フロー）
    fileprivate func proceedDeviceInfo(_ msg: DeviceInfoMessage, clientId: String) {
        // peerIdを取得（discoveredPeersから、またはhostnameベース）
        let peerId = self.discoveredPeers.first(where: { $0.deviceInfo?.hostname == msg.hostname })?.id ?? "\(msg.hostname)._mugendesk._tcp.local."

        // マッピングを保存
        self.serverClientMapping[clientId] = peerId
        print("[DeviceInfo] Mapped clientId \(clientId) -> peerId \(peerId)")

        // UDPカーソルチャネルにピアIP登録
        if let host = self.webSocketServer?.remoteHost(for: clientId) {
            UDPCursorChannel.shared.setPeerEndpoint(peerId: peerId, host: host)
        }

        if let screens = msg.screens, !screens.isEmpty {
            ScreenManager.shared.setRemoteDisplays(peerId: peerId, peerName: msg.hostname, displays: screens)
        } else {
            // 後方互換: screensが無ければunion情報のみで単一ディスプレイ扱い
            ScreenManager.shared.addRemoteScreen(
                deviceId: peerId,
                name: msg.hostname,
                width: CGFloat(msg.screenWidth),
                height: CGFloat(msg.screenHeight)
            )
        }
        print("[DeviceInfo] Added \(msg.screens?.count ?? 1) display(s) for peer \(msg.hostname) [\(peerId)]")

        // 接続完了をconnectedPeersに追加
        if let peer = self.discoveredPeers.first(where: { $0.id == peerId }) {
            var updated = peer
            updated.isConnected = true
            DispatchQueue.main.async {
                if !DiscoveryService.shared.connectedPeers.contains(where: { $0.id == peerId }) {
                    DiscoveryService.shared.connectedPeers.append(updated)
                }
            }
        }

        // TOFU: 相手の公開鍵からセッション鍵を導出
        if let peerKey = msg.publicKey {
            if CryptoManager.shared.deriveSessionKey(peerPublicKeyBase64: peerKey, peerId: peerId) {
                print("[TOFU] Session key derived for \(peerId) (server side)")
            }
        }

        // 自分のdeviceInfoを返信（鍵交換に使うので暗号化しない）
        if let responseMsg = self.buildLocalDeviceInfoMessage(),
           let json = MessageEncoder.shared.encode(responseMsg) {
            self.webSocketServer?.send(json, to: clientId)
            print("[DeviceInfo] Sent deviceInfo response to clientId: \(clientId)")
        }
    }

    // MARK: - Message Sending

    func broadcast(_ message: String) {
        webSocketServer?.broadcast(message)
    }

    func send(_ message: String, to peerId: String, encrypt: Bool = true) {
        // TOFU: セッション鍵がある場合は暗号化
        let payload: String
        if encrypt,
           CryptoManager.shared.hasSessionKey(for: peerId),
           let wrapped = CryptoManager.shared.wrapMessage(message, for: peerId) {
            payload = wrapped
        } else {
            payload = message
        }

        // WebSocketClient経由で送信を試みる
        if ConnectionManager.shared.activeConnections[peerId] != nil {
            ConnectionManager.shared.send(payload, to: peerId)
        } else {
            // WebSocketServer経由で送信（逆マッピングを使う）
            if let clientId = serverClientMapping.first(where: { $0.value == peerId })?.key {
                webSocketServer?.send(payload, to: clientId)
            } else {
                print("[DiscoveryService] No route to peerId: \(peerId)")
            }
        }
    }

    /// localDeviceInfoからDeviceInfoMessage（公開鍵付き）を生成
    func buildLocalDeviceInfoMessage() -> DeviceInfoMessage? {
        guard let info = localDeviceInfo else { return nil }
        return DeviceInfoMessage(
            deviceId: info.deviceId,
            hostname: info.hostname,
            deviceType: .mac,
            screenWidth: info.screenWidth,
            screenHeight: info.screenHeight,
            screens: info.displays,
            publicKey: CryptoManager.shared.publicKeyBase64
        )
    }

    /// 全接続ピアにブロードキャスト（WebSocketClient/Server両経路を使用）
    func broadcastToAllPeers(_ message: String) {
        for peer in connectedPeers {
            send(message, to: peer.id)
        }
    }

    /// DeviceInfoを更新して全ピアに再送（画面構成変更時）
    func resendDeviceInfo() {
        setupLocalDeviceInfo()
        guard let message = buildLocalDeviceInfoMessage(),
              let json = MessageEncoder.shared.encode(message) else { return }
        for peer in connectedPeers {
            send(json, to: peer.id, encrypt: false)
        }
        print("[DiscoveryService] Resent deviceInfo to \(connectedPeers.count) peer(s)")
    }
}
