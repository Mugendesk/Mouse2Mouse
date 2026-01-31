import Foundation
import Cocoa
import Combine

/// 画面配置管理
/// 各デバイスの画面サイズ・位置を管理し、カーソル移動時の遷移先を決定
class ScreenManager: ObservableObject {
    static let shared = ScreenManager()

    // MARK: - Device Role

    /// デバイスの役割
    /// - host: 入力を送信する側（このMacでマウス/キーボードを操作）
    /// - client: 入力を受信する側（リモートから操作される）
    enum DeviceRole: String, Codable {
        case host   // 親: 入力を送信
        case client // 子: 入力を受信
    }

    // MARK: - Published Properties

    @Published var localScreens: [LocalScreen] = []  // マルチディスプレイ対応
    @Published var remoteScreens: [RemoteScreen] = []
    @Published var currentControlDevice: String = "local"
    @Published var isControllingRemote = false
    @Published var transitionSourceScreen: String?  // 遷移元のローカル画面ID
    @Published var deviceRole: DeviceRole = .host  // デフォルトはホスト（操作元）

    // MARK: - Types

    struct LocalScreen: Identifiable {
        let id: String  // NSScreen の deviceDescription から取得
        let name: String
        let frame: CGRect
        let visibleFrame: CGRect
        let isMain: Bool

        var width: CGFloat { frame.width }
        var height: CGFloat { frame.height }
    }

    struct RemoteScreen: Identifiable, Codable {
        let id: String  // device_id
        var name: String
        var width: CGFloat
        var height: CGFloat

        // 自由配置用の座標（ローカル画面との相対位置）
        var offsetX: CGFloat  // ローカル画面からのX方向オフセット
        var offsetY: CGFloat  // ローカル画面からのY方向オフセット
        var attachedTo: String?  // 接続先のローカル画面ID (nil = メイン画面)
        var attachedEdge: Edge  // どの辺に接続されているか

        enum Edge: String, Codable, CaseIterable {
            case left
            case right
            case top
            case bottom
        }

        // 計算プロパティ: この画面の仮想座標
        func virtualFrame(relativeTo localFrame: CGRect) -> CGRect {
            let x: CGFloat
            let y: CGFloat

            switch attachedEdge {
            case .left:
                x = localFrame.minX - width
                y = localFrame.minY + offsetY
            case .right:
                x = localFrame.maxX
                y = localFrame.minY + offsetY
            case .top:
                x = localFrame.minX + offsetX
                y = localFrame.maxY
            case .bottom:
                x = localFrame.minX + offsetX
                y = localFrame.minY - height
            }

            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct ScreenInfo {
        let width: CGFloat
        let height: CGFloat
        let visibleFrame: CGRect
        let fullFrame: CGRect
    }

    // MARK: - Deprecated (互換性のため残す)
    var localScreen: ScreenInfo? {
        guard let main = localScreens.first(where: { $0.isMain }) ?? localScreens.first else {
            return nil
        }
        return ScreenInfo(
            width: main.width,
            height: main.height,
            visibleFrame: main.visibleFrame,
            fullFrame: main.frame
        )
    }

    // MARK: - Lifecycle

    private init() {
        updateScreenInfo()
        loadRole()
    }

    // MARK: - Screen Info

    func updateScreenInfo() {
        localScreens = NSScreen.screens.enumerated().map { index, screen in
            let id = getScreenId(screen) ?? "screen_\(index)"
            let isMain = screen == NSScreen.main

            // スクリーン名を取得（外部ディスプレイ名など）
            let displayName = isMain ? "メインディスプレイ" : "ディスプレイ \(index + 1)"

            // 実際のピクセルサイズを取得（Retina対応）
            let backingScale = screen.backingScaleFactor
            let pixelWidth = screen.frame.width * backingScale
            let pixelHeight = screen.frame.height * backingScale

            print("  DEBUG: screen \(index) - points: \(screen.frame.width)x\(screen.frame.height), scale: \(backingScale), pixels: \(pixelWidth)x\(pixelHeight)")

            return LocalScreen(
                id: id,
                name: displayName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: isMain
            )
        }

        print("Detected \(localScreens.count) local screen(s)")
        for screen in localScreens {
            print("  - \(screen.name): \(Int(screen.width))x\(Int(screen.height)) \(screen.isMain ? "(main)" : "")")
            print("    Frame: \(screen.frame)")
        }
    }

    private func getScreenId(_ screen: NSScreen) -> String? {
        guard let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return "display_\(displayId)"
    }

    // MARK: - Remote Screen Management

    func addRemoteScreen(deviceId: String, name: String, width: CGFloat, height: CGFloat) {
        // デフォルトはメイン画面の右側に配置
        let mainScreen = localScreens.first(where: { $0.isMain }) ?? localScreens.first

        let screen = RemoteScreen(
            id: deviceId,
            name: name,
            width: width,
            height: height,
            offsetX: 0,
            offsetY: 0,
            attachedTo: mainScreen?.id,
            attachedEdge: .right
        )

        if let index = remoteScreens.firstIndex(where: { $0.id == deviceId }) {
            // 既存の配置設定を保持しつつ更新
            var existing = remoteScreens[index]
            existing.name = name
            existing.width = width
            existing.height = height
            remoteScreens[index] = existing
        } else {
            remoteScreens.append(screen)
        }

        print("Added/Updated remote screen: \(name) (\(Int(width))x\(Int(height)))")
    }

    func removeRemoteScreen(deviceId: String) {
        remoteScreens.removeAll { $0.id == deviceId }
    }

    func updateRemoteScreenPosition(
        deviceId: String,
        attachedTo: String?,
        edge: RemoteScreen.Edge,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0
    ) {
        print("[ScreenManager] updateRemoteScreenPosition called for deviceId: \(deviceId)")
        if let index = remoteScreens.firstIndex(where: { $0.id == deviceId }) {
            remoteScreens[index].attachedTo = attachedTo
            remoteScreens[index].attachedEdge = edge
            remoteScreens[index].offsetX = offsetX
            remoteScreens[index].offsetY = offsetY

            // 相手に画面配置を通知
            notifyScreenLayout(to: deviceId, edge: edge, offsetX: offsetX, offsetY: offsetY)
        } else {
            print("[ScreenManager] Remote screen not found for deviceId: \(deviceId)")
            print("[ScreenManager] Available remoteScreens: \(remoteScreens.map { $0.id })")
        }
        saveLayout()
    }

    private func notifyScreenLayout(to deviceId: String, edge: RemoteScreen.Edge, offsetX: CGFloat, offsetY: CGFloat) {
        guard let localScreen = localScreens.first(where: { $0.isMain }) else {
            print("[ScreenLayout] No main screen found")
            return
        }

        let edgeString: String
        switch edge {
        case .left:
            edgeString = "left"
        case .right:
            edgeString = "right"
        case .top:
            edgeString = "top"
        case .bottom:
            edgeString = "bottom"
        }

        let message = ScreenLayoutMessage(
            localDeviceId: localScreen.id,
            edge: edgeString,
            offsetX: Double(offsetX),
            offsetY: Double(offsetY)
        )

        if let json = MessageEncoder.shared.encode(message) {
            print("[ScreenLayout] Sending to \(deviceId): edge=\(edgeString), offset=(\(offsetX), \(offsetY))")
            DiscoveryService.shared.send(json, to: deviceId)
        }
    }

    // MARK: - Edge Detection (改良版)

    struct EdgeHit {
        let direction: RemoteScreen.Edge
        let targetDevice: RemoteScreen
        let entryPosition: CGPoint  // 遷移先での開始位置（実座標）
        let sourceScreenId: String  // どのローカル画面から遷移したか
    }

    /// カーソルが画面端に達したかチェック（マルチディスプレイ対応）
    func checkEdgeReached(cursorPosition: CGPoint) -> EdgeHit? {
        let threshold: CGFloat = 1.0

        // 全てのローカル画面をチェック
        for localScreen in localScreens {
            let frame = localScreen.visibleFrame

            // この画面内にカーソルがあるかチェック
            let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
            guard expandedFrame.contains(cursorPosition) else { continue }

            // この画面に接続されているリモート画面をチェック
            for remoteScreen in remoteScreens {
                guard remoteScreen.attachedTo == localScreen.id ||
                      (remoteScreen.attachedTo == nil && localScreen.isMain) else {
                    continue
                }

                let remoteFrame = remoteScreen.virtualFrame(relativeTo: localScreen.frame)

                // 各辺をチェック
                switch remoteScreen.attachedEdge {
                case .left:
                    if cursorPosition.x <= frame.minX + threshold {
                        // Y座標がリモート画面の範囲内か
                        if cursorPosition.y >= remoteFrame.minY && cursorPosition.y <= remoteFrame.maxY {
                            let entryY = cursorPosition.y - remoteFrame.minY
                            let entryPoint = CGPoint(x: remoteScreen.width - 1, y: entryY)
                            return EdgeHit(
                                direction: .left,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }

                case .right:
                    if cursorPosition.x >= frame.maxX - threshold {
                        if cursorPosition.y >= remoteFrame.minY && cursorPosition.y <= remoteFrame.maxY {
                            let entryY = cursorPosition.y - remoteFrame.minY
                            let entryPoint = CGPoint(x: 0, y: entryY)
                            return EdgeHit(
                                direction: .right,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }

                case .top:
                    if cursorPosition.y >= frame.maxY - threshold {
                        if cursorPosition.x >= remoteFrame.minX && cursorPosition.x <= remoteFrame.maxX {
                            let entryX = cursorPosition.x - remoteFrame.minX
                            let entryPoint = CGPoint(x: entryX, y: 0)
                            return EdgeHit(
                                direction: .top,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }

                case .bottom:
                    if cursorPosition.y <= frame.minY + threshold {
                        if cursorPosition.x >= remoteFrame.minX && cursorPosition.x <= remoteFrame.maxX {
                            let entryX = cursorPosition.x - remoteFrame.minX
                            let entryPoint = CGPoint(x: entryX, y: remoteScreen.height - 1)
                            return EdgeHit(
                                direction: .bottom,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }
                }
            }
        }

        return nil
    }

    /// 正規化座標から実座標に変換（遷移元画面を考慮）
    func denormalizePosition(x: Double, y: Double, forScreenId: String? = nil) -> CGPoint {
        let screenId = forScreenId ?? transitionSourceScreen
        let screen = localScreens.first(where: { $0.id == screenId })
                  ?? localScreens.first(where: { $0.isMain })
                  ?? localScreens.first

        guard let screen = screen else {
            return CGPoint(x: 100, y: 100)
        }

        let actualX = screen.visibleFrame.minX + CGFloat(x) * screen.visibleFrame.width
        let actualY = screen.visibleFrame.minY + CGFloat(y) * screen.visibleFrame.height

        return CGPoint(x: actualX, y: actualY)
    }

    // MARK: - Control State

    func transferControlTo(deviceId: String, sourceScreenId: String) {
        currentControlDevice = deviceId
        transitionSourceScreen = sourceScreenId
        isControllingRemote = true
        print("Control transferred to: \(deviceId) from screen: \(sourceScreenId)")
    }

    func returnControlToLocal() {
        currentControlDevice = "local"
        isControllingRemote = false
        print("Control returned to local")
    }

    // MARK: - Role Management

    /// 役割を切り替える
    /// - Parameter role: 新しい役割
    /// - Parameter notifyPeers: 接続中のピアに通知するか
    func setRole(_ role: DeviceRole, notifyPeers: Bool = true) {
        let oldRole = deviceRole
        deviceRole = role
        print("[ScreenManager] Role changed: \(oldRole.rawValue) -> \(role.rawValue)")

        // 役割に応じて入力キャプチャの状態を調整
        if role == .host {
            // ホスト: 入力をキャプチャして送信する準備
            print("[ScreenManager] Host mode: Ready to send input")
        } else {
            // クライアント: 入力を受信する準備
            print("[ScreenManager] Client mode: Ready to receive input")
            // 必ずリモートモードを解除（ローカル操作を可能にする）
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            returnControlToLocal()
        }

        // 接続中のピアに通知
        if notifyPeers {
            notifyRoleChange(to: role)
        }

        // 設定を保存
        saveRole()
    }

    /// 役割変更を接続中のピアに通知
    private func notifyRoleChange(to role: DeviceRole) {
        guard let localInfo = DiscoveryService.shared.localDeviceInfo else { return }

        let message = RoleChangeMessage(
            role: role.rawValue,
            deviceId: localInfo.deviceId
        )

        if let json = MessageEncoder.shared.encode(message) {
            for peer in DiscoveryService.shared.connectedPeers {
                DiscoveryService.shared.send(json, to: peer.id)
            }
            print("[ScreenManager] Notified \(DiscoveryService.shared.connectedPeers.count) peer(s) of role change")
        }
    }

    /// 相手からの役割変更通知を処理
    func handleRemoteRoleChange(role: String, fromDeviceId: String) {
        print("[ScreenManager] Remote device \(fromDeviceId) changed role to: \(role)")
        // 必要に応じてUIを更新（相手がhostになったら自分はclient的な挙動になる可能性）
        // ただし自動で切り替えず、UIで表示するのみ
    }

    /// 役割をUserDefaultsに保存
    func saveRole() {
        UserDefaults.standard.set(deviceRole.rawValue, forKey: "Mouse2Mouse.DeviceRole")
        print("[ScreenManager] Role saved: \(deviceRole.rawValue)")
    }

    /// 役割をUserDefaultsから読み込み
    func loadRole() {
        if let roleString = UserDefaults.standard.string(forKey: "Mouse2Mouse.DeviceRole"),
           let role = DeviceRole(rawValue: roleString) {
            deviceRole = role
            print("[ScreenManager] Role loaded: \(role.rawValue)")
        }
    }

    // MARK: - Layout Persistence

    func saveLayout() {
        guard let data = try? JSONEncoder().encode(remoteScreens) else { return }
        UserDefaults.standard.set(data, forKey: "Mouse2Mouse.ScreenLayout")
        print("Screen layout saved")
    }

    func loadLayout() {
        guard let data = UserDefaults.standard.data(forKey: "Mouse2Mouse.ScreenLayout"),
              let screens = try? JSONDecoder().decode([RemoteScreen].self, from: data) else {
            return
        }
        remoteScreens = screens
        print("Screen layout loaded: \(screens.count) remote screen(s)")
    }

    // MARK: - Legacy Compatibility

    enum EdgeDirection {
        case left, right, top, bottom, none
    }

    func checkEdgeReached(cursorPosition: CGPoint) -> (direction: EdgeDirection, targetDevice: RemoteScreen?) {
        if let hit = checkEdgeReached(cursorPosition: cursorPosition) as EdgeHit? {
            let dir: EdgeDirection
            switch hit.direction {
            case .left: dir = .left
            case .right: dir = .right
            case .top: dir = .top
            case .bottom: dir = .bottom
            }
            return (dir, hit.targetDevice)
        }
        return (.none, nil)
    }

    func calculateEntryPosition(from direction: EdgeDirection, cursorPosition: CGPoint) -> (x: Double, y: Double) {
        // 新しいcheckEdgeReachedを使用
        if let hit = checkEdgeReached(cursorPosition: cursorPosition) as EdgeHit? {
            return (
                Double(hit.entryPosition.x / hit.targetDevice.width),
                Double(hit.entryPosition.y / hit.targetDevice.height)
            )
        }
        return (0.5, 0.5)
    }
}
