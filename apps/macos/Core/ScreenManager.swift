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
    @Published var cornerGuardSize: CGFloat = 6  // コーナーガード（ピクセル、0で無効）

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

    /// リモートピアの物理ディスプレイ1台を表す
    /// idは "<peerId>:<peerDisplayId>" の合成ID（複数ディスプレイを区別するため）
    struct RemoteScreen: Identifiable, Codable {
        let id: String  // 合成ID: "peerId:peerDisplayId"
        let peerId: String           // 所属ピアのdevice_id
        let peerDisplayId: String    // ピア側のローカルscreen id
        var name: String
        var width: CGFloat
        var height: CGFloat

        // ピアunion座標系内のこのディスプレイの原点（Quartz, Y↓）
        var peerOriginX: CGFloat
        var peerOriginY: CGFloat
        var isMain: Bool

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

        static func makeId(peerId: String, peerDisplayId: String) -> String {
            return "\(peerId):\(peerDisplayId)"
        }

        // 計算プロパティ: この画面の仮想座標（ホスト側のレイアウト用）
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

    private var screenChangeObserver: NSObjectProtocol?

    private init() {
        updateScreenInfo()
        loadRole()
        observeScreenChanges()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// ディスプレイの接続/切断/解像度変更を監視
    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("[ScreenManager] Screen configuration changed")
            self.updateScreenInfo()
            // DeviceInfoを再送（相手側に新しい画面サイズを通知）
            DiscoveryService.shared.resendDeviceInfo()
        }
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

    /// 後方互換: 単一画面（union情報のみ）として登録
    /// 新しい呼び出し側はsetRemoteDisplaysを使うこと
    func addRemoteScreen(deviceId: String, name: String, width: CGFloat, height: CGFloat) {
        let display = DisplayInfo(
            id: "main",
            name: name,
            originX: 0,
            originY: 0,
            width: Double(width),
            height: Double(height),
            isMain: true
        )
        setRemoteDisplays(peerId: deviceId, peerName: name, displays: [display])
    }

    /// ピアの全物理ディスプレイを登録（既存はマージして配置設定を保持）
    func setRemoteDisplays(peerId: String, peerName: String, displays: [DisplayInfo]) {
        let mainLocalScreen = localScreens.first(where: { $0.isMain }) ?? localScreens.first

        // このピアの既存エントリを取得（配置設定を保持するため）
        let existing = remoteScreens.filter { $0.peerId == peerId }
        let existingByDisplayId = Dictionary(uniqueKeysWithValues: existing.map { ($0.peerDisplayId, $0) })

        // このピアの既存エントリを削除
        remoteScreens.removeAll { $0.peerId == peerId }

        // 新しいdisplay情報でエントリを構築
        for display in displays {
            let screenId = RemoteScreen.makeId(peerId: peerId, peerDisplayId: display.id)
            let prior = existingByDisplayId[display.id]

            let screen = RemoteScreen(
                id: screenId,
                peerId: peerId,
                peerDisplayId: display.id,
                name: display.name.isEmpty ? "\(peerName) - \(display.id)" : "\(peerName) / \(display.name)",
                width: CGFloat(display.width),
                height: CGFloat(display.height),
                peerOriginX: CGFloat(display.originX),
                peerOriginY: CGFloat(display.originY),
                isMain: display.isMain,
                offsetX: prior?.offsetX ?? 0,
                offsetY: prior?.offsetY ?? 0,
                // 既存設定があれば保持。なければmainディスプレイのみメイン画面右、それ以外は配置なし
                attachedTo: prior?.attachedTo ?? (display.isMain ? mainLocalScreen?.id : nil),
                attachedEdge: prior?.attachedEdge ?? .right
            )
            remoteScreens.append(screen)
        }

        print("[ScreenManager] Set \(displays.count) display(s) for peer \(peerName) [\(peerId)]")
    }

    /// ピアの全ディスプレイを削除
    func removePeer(peerId: String) {
        remoteScreens.removeAll { $0.peerId == peerId }
    }

    /// 後方互換用エイリアス
    func removeRemoteScreen(deviceId: String) {
        removePeer(peerId: deviceId)
    }

    /// 指定ピアの全ディスプレイを返す
    func displays(forPeer peerId: String) -> [RemoteScreen] {
        return remoteScreens.filter { $0.peerId == peerId }
    }

    /// 指定ピアの仮想デスクトップunion矩形（Quartz座標系、原点=union左上）
    func peerUnion(peerId: String) -> CGRect {
        let peerDisplays = displays(forPeer: peerId)
        guard !peerDisplays.isEmpty else { return .zero }
        return peerDisplays.reduce(CGRect.null) { acc, d in
            acc.union(CGRect(x: d.peerOriginX, y: d.peerOriginY, width: d.width, height: d.height))
        }
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
        let entryPosition: CGPoint  // ピアunion座標系でのエントリ位置（Quartz, Y↓）
        let sourceScreenId: String  // どのローカル画面から遷移したか
    }

    /// AppKit座標系(原点左下、Y↑)をQuartz座標系(原点左上、Y↓)に変換
    func appKitToQuartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// 全ローカルディスプレイの和集合（仮想デスクトップ）を返す（AppKit座標系）
    /// 単一画面の場合はそのframe、複数の場合はバウンディングボックス
    func localVirtualDesktopAppKit() -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return union.isNull ? .zero : union
    }

    /// 全ローカルディスプレイの和集合をQuartz座標系で返す
    /// CGEvent.postに渡すカーソル座標の基準として使う
    func localVirtualDesktopQuartz() -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return .zero
        }
        return appKitToQuartz(localVirtualDesktopAppKit(), primaryHeight: primaryHeight)
    }

    /// カーソルが画面端に達したかチェック（マルチディスプレイ対応）
    /// cursorPositionはCGEvent.location（Quartz座標系）を想定
    func checkEdgeReached(cursorPosition: CGPoint) -> EdgeHit? {
        let threshold: CGFloat = 1.0

        // CGEvent.locationはQuartz座標系(原点左上、Y↓)
        // NSScreen.frameはAppKit座標系(原点左下、Y↑)
        // 比較のためAppKitフレームをQuartzに変換
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }

        for localScreen in localScreens {
            let frame = appKitToQuartz(localScreen.visibleFrame, primaryHeight: primaryHeight)

            let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
            guard expandedFrame.contains(cursorPosition) else { continue }

            // コーナーガード: 画面角付近ではエッジ遷移しない（ホットコーナー誤動作防止）
            if cornerGuardSize > 0 {
                let corners = [
                    CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                    CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)
                ]
                let inCorner = corners.contains { abs(cursorPosition.x - $0.x) < cornerGuardSize && abs(cursorPosition.y - $0.y) < cornerGuardSize }
                if inCorner { continue }
            }

            for remoteScreen in remoteScreens {
                guard remoteScreen.attachedTo == localScreen.id ||
                      (remoteScreen.attachedTo == nil && localScreen.isMain) else {
                    continue
                }

                let remoteFrameAppKit = remoteScreen.virtualFrame(relativeTo: localScreen.frame)
                let remoteFrame = appKitToQuartz(remoteFrameAppKit, primaryHeight: primaryHeight)

                // entryPositionはピアunion座標系: ディスプレイローカル座標 + peerOriginX/Y
                let pox = remoteScreen.peerOriginX
                let poy = remoteScreen.peerOriginY

                switch remoteScreen.attachedEdge {
                case .left:
                    if cursorPosition.x <= frame.minX + threshold {
                        if cursorPosition.y >= remoteFrame.minY && cursorPosition.y <= remoteFrame.maxY {
                            let entryY = cursorPosition.y - remoteFrame.minY
                            // ディスプレイの右端から入る（ローカルのleft方向 → リモートの右端）
                            let entryPoint = CGPoint(x: pox + remoteScreen.width - 1, y: poy + entryY)
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
                            let entryPoint = CGPoint(x: pox + 0, y: poy + entryY)
                            return EdgeHit(
                                direction: .right,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }

                case .top:
                    if cursorPosition.y <= frame.minY + threshold {
                        if cursorPosition.x >= remoteFrame.minX && cursorPosition.x <= remoteFrame.maxX {
                            let entryX = cursorPosition.x - remoteFrame.minX
                            let entryPoint = CGPoint(x: pox + entryX, y: poy + remoteScreen.height - 1)
                            return EdgeHit(
                                direction: .top,
                                targetDevice: remoteScreen,
                                entryPosition: entryPoint,
                                sourceScreenId: localScreen.id
                            )
                        }
                    }

                case .bottom:
                    if cursorPosition.y >= frame.maxY - threshold {
                        if cursorPosition.x >= remoteFrame.minX && cursorPosition.x <= remoteFrame.maxX {
                            let entryX = cursorPosition.x - remoteFrame.minX
                            let entryPoint = CGPoint(x: pox + entryX, y: poy + 0)
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

    /// 正規化座標(0-1)を仮想デスクトップ全体上のQuartz座標に変換
    /// 受信側がcontrolTransferでカーソルを配置する際に使用
    func denormalizePosition(x: Double, y: Double, forScreenId: String? = nil) -> CGPoint {
        // 仮想デスクトップ全体に対して正規化されている前提
        let union = localVirtualDesktopQuartz()
        guard union.width > 0, union.height > 0 else {
            return CGPoint(x: 100, y: 100)
        }

        let actualX = union.minX + CGFloat(x) * union.width
        let actualY = union.minY + CGFloat(y) * union.height
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
            // ホスト: listenOnlyで監視開始（エッジ検出用、イベントはブロックしない）
            InputCapture.shared.startCapturing()
            print("[ScreenManager] Host mode: Input capture enabled (listenOnly)")
        } else {
            // クライアント: リモートモードを解除するだけ（タップはlistenOnlyなので止めなくても安全）
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            returnControlToLocal()
            print("[ScreenManager] Client mode: Remote mode disabled")
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
