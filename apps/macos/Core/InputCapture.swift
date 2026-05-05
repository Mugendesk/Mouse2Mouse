import Foundation
import Cocoa
import CoreGraphics
import Combine

/// 入力イベント傍受
/// CGEventタップを使用してマウス/キーボードイベントを傍受・転送
class InputCapture: ObservableObject {
    static let shared = InputCapture()

    // MARK: - Published Properties

    @Published var isCapturing = false
    @Published var isRemoteMode = false  // リモートデバイスに入力を転送中

    // MARK: - Callbacks

    var onCursorMove: ((CGPoint) -> Void)?
    var onMouseButton: ((Int, Bool, Int) -> Void)?  // button, isDown, clickCount
    var onScroll: ((CGFloat, CGFloat) -> Void)?  // dx, dy
    var onKeyEvent: ((Int, Bool, [String]) -> Void)?  // keycode, isDown, modifiers
    var onEdgeReached: ((ScreenManager.EdgeDirection, CGPoint) -> Void)?

    // MARK: - Private Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastMousePosition: CGPoint = .zero
    private var virtualCursorPosition: CGPoint = .zero  // リモートモード用の仮想カーソル位置
    private var useDefaultTap = false  // true: イベント消費可能（リモートモード用）、false: listenOnly（安全）
    private var edgeCooldownUntil: Date = .distantPast  // エッジ検出クールダウン（バウンスバック防止）

    // パニック脱出: 600ms以内に3回Esc連打で強制リセット
    private var escPressTimestamps: [CFAbsoluteTime] = []
    private let panicWindow: CFAbsoluteTime = 0.6
    private let panicCount = 3

    // ウォッチドッグ:
    // - 入力イベント途絶3秒 → 自動解除（ユーザーが離席）
    // - ピア無音2秒 → 自動解除（ネットワーク死亡 / ピアクラッシュ）
    private var watchdogTimer: DispatchSourceTimer?
    private var lastEventTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastPeerMessageTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private let inputWatchdogTimeout: CFAbsoluteTime = 3.0
    private let peerWatchdogTimeout: CFAbsoluteTime = 2.0

    /// ピアからメッセージ受信時に呼ぶ（無音検知のリセット）
    func peerMessageReceived() {
        lastPeerMessageTimestamp = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Capture Control

    /// キーボードイベントがキャプチャできているか（Input Monitoring権限依存）
    private(set) var hasKeyboardCapture = false

    func startCapturing() {
        guard !isCapturing else { return }

        let mouseTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]

        let mouseMask = mouseTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let keyboardMask = keyboardTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tapOption: CGEventTapOptions = useDefaultTap ? .defaultTap : .listenOnly
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passRetained(event)
            }
            let capture = Unmanaged<InputCapture>.fromOpaque(userInfo).takeUnretainedValue()
            return capture.handleEvent(proxy: proxy, type: type, event: event)
        }

        // まずキーボード込みで試行、失敗したらマウスのみでフォールバック
        var tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: tapOption,
            eventsOfInterest: mouseMask | keyboardMask,
            callback: callback,
            userInfo: userInfo
        )

        if tap != nil {
            hasKeyboardCapture = true
        } else {
            // Input Monitoring権限なし → マウスのみで再試行
            print("[InputCapture] Keyboard capture failed, falling back to mouse-only")
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: tapOption,
                eventsOfInterest: mouseMask,
                callback: callback,
                userInfo: userInfo
            )
            hasKeyboardCapture = false
        }

        guard let tap = tap else {
            print("[InputCapture] Failed to create event tap - check accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        isCapturing = true
        print("[InputCapture] Started (keyboard: \(hasKeyboardCapture), defaultTap: \(useDefaultTap))")
    }

    func stopCapturing() {
        guard isCapturing else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isCapturing = false

        print("Input capture stopped")
    }

    // MARK: - Remote Mode

    /// リモートモードを開始（ローカル入力をブロックしてリモートに転送）
    func enterRemoteMode(entryPoint: CGPoint = .zero) {
        // 権限チェック（なければリモートモードに入らない）
        guard PermissionManager.hasAllPermissions() else {
            print("[InputCapture] Cannot enter remote mode: permissions not granted")
            return
        }
        isRemoteMode = true
        virtualCursorPosition = entryPoint
        // イベントを消費できるようにdefaultTapで再作成
        restartCapturing(withDefaultTap: true)
        // カーソルを固定
        CGAssociateMouseAndMouseCursorPosition(0)
        // ウォッチドッグ開始（イベント途絶で自動解除）
        startWatchdog()
        print("[InputCapture] Entered remote mode at \(entryPoint)")
    }

    /// リモートモードを終了
    func exitRemoteMode() {
        guard isRemoteMode else { return }
        isRemoteMode = false
        // ウォッチドッグ停止
        stopWatchdog()
        // カーソル固定を最初に解除（他の処理が失敗してもロックされない）
        CGAssociateMouseAndMouseCursorPosition(1)
        // listenOnlyに戻す（安全 — フォールバックでマウスのみになっても入力はブロックされない）
        restartCapturing(withDefaultTap: false)
        print("[InputCapture] Exited remote mode (keyboard: \(hasKeyboardCapture))")
    }

    /// タップを再作成（listenOnly <-> defaultTap の切り替え）
    private func restartCapturing(withDefaultTap: Bool) {
        let wasCapturing = isCapturing
        if wasCapturing {
            stopCapturing()
        }
        useDefaultTap = withDefaultTap
        if wasCapturing {
            startCapturing()
        }
    }

    // MARK: - Watchdog (リモートモードの安全装置)

    private func startWatchdog() {
        stopWatchdog()
        let now = CFAbsoluteTimeGetCurrent()
        lastEventTimestamp = now
        lastPeerMessageTimestamp = now

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRemoteMode else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let inputElapsed = now - self.lastEventTimestamp
            let peerElapsed = now - self.lastPeerMessageTimestamp

            if inputElapsed > self.inputWatchdogTimeout {
                print("[Watchdog] No local input for \(String(format: "%.1f", inputElapsed))s — force exiting remote mode")
                self.exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                InputTransmitter.shared.stopTransmitting()
            } else if peerElapsed > self.peerWatchdogTimeout {
                print("[Watchdog] No peer messages for \(String(format: "%.1f", peerElapsed))s — peer unresponsive, exiting remote mode")
                self.exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                InputTransmitter.shared.stopTransmitting()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Event Handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTimestamp = CFAbsoluteTimeGetCurrent()

        // タップが無効になった場合は再有効化
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            handleMouseMove(event: event)

        case .leftMouseDown:
            handleMouseButton(button: 0, isDown: true, event: event)
        case .leftMouseUp:
            handleMouseButton(button: 0, isDown: false, event: event)

        case .rightMouseDown:
            handleMouseButton(button: 1, isDown: true, event: event)
        case .rightMouseUp:
            handleMouseButton(button: 1, isDown: false, event: event)

        case .otherMouseDown:
            handleMouseButton(button: 2, isDown: true, event: event)
        case .otherMouseUp:
            handleMouseButton(button: 2, isDown: false, event: event)

        case .scrollWheel:
            handleScroll(event: event)

        case .keyDown:
            // ホットキーチェック（共有トグル: Ctrl+Option+S）
            let hkKeycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let hkModifiers = getModifiers(from: event.flags)
            if HotkeyManager.shared.checkHotkey(keycode: hkKeycode, modifiers: hkModifiers) {
                HotkeyManager.shared.toggle()
                return nil
            }
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == 53 {  // Escape
                // パニック脱出: 600ms以内に3回Esc連打 → 全状態を強制リセット（リモートモード外でも有効）
                let now = CFAbsoluteTimeGetCurrent()
                escPressTimestamps.append(now)
                escPressTimestamps.removeAll { now - $0 > panicWindow }
                if escPressTimestamps.count >= panicCount {
                    print("[Panic] Triple-Esc detected — emergency reset")
                    escPressTimestamps.removeAll()
                    panicReset()
                    return nil
                }
                // 通常Escでもリモートモードから脱出
                if isRemoteMode {
                    print("Escape pressed, exiting remote mode")
                    exitRemoteMode()
                    ScreenManager.shared.returnControlToLocal()
                    InputTransmitter.shared.stopTransmitting()
                    return nil
                }
            }
            handleKeyEvent(event: event, isDown: true)
        case .keyUp:
            handleKeyEvent(event: event, isDown: false)

        case .flagsChanged:
            handleFlagsChanged(event: event)

        default:
            break
        }

        // リモートモード時はイベントを消費（ローカルに伝播させない）
        if isRemoteMode {
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Mouse Events

    private func handleMouseMove(event: CGEvent) {
        if isRemoteMode {
            // リモートモード: デルタ値でピアunion座標系の仮想カーソルを移動
            let deltaX = event.getDoubleValueField(.mouseEventDeltaX)
            let deltaY = event.getDoubleValueField(.mouseEventDeltaY)

            virtualCursorPosition.x += CGFloat(deltaX)
            virtualCursorPosition.y += CGFloat(deltaY)

            guard let targetPeerId = InputTransmitter.shared.currentTargetPeerId else {
                print("[InputCapture] No target peer, returning to local")
                forceReturnToLocal()
                return
            }

            let peerDisplays = ScreenManager.shared.displays(forPeer: targetPeerId)
            guard !peerDisplays.isEmpty else {
                print("[InputCapture] No displays for peer \(targetPeerId), returning to local")
                forceReturnToLocal()
                return
            }

            // 仮想カーソルが「貼り付き辺を越えてピアの範囲外に出たか」を判定
            // 各ディスプレイの貼り付け辺を超えたら、その辺の方向に出たとみなす
            var returnEdge: ScreenManager.RemoteScreen.Edge?
            for d in peerDisplays {
                let dRect = CGRect(x: d.peerOriginX, y: d.peerOriginY, width: d.width, height: d.height)
                guard dRect.contains(virtualCursorPosition) else { continue }
                // このディスプレイ内にいる時、貼り付き辺を超えたら戻る
                switch d.attachedEdge {
                case .right:  // ホストの右にリモート → 戻りはリモートの左方向
                    if virtualCursorPosition.x < dRect.minX + 0.5 { returnEdge = d.attachedEdge }
                case .left:
                    if virtualCursorPosition.x > dRect.maxX - 0.5 { returnEdge = d.attachedEdge }
                case .bottom:
                    if virtualCursorPosition.y < dRect.minY + 0.5 { returnEdge = d.attachedEdge }
                case .top:
                    if virtualCursorPosition.y > dRect.maxY - 0.5 { returnEdge = d.attachedEdge }
                }
                if returnEdge != nil { break }
            }

            // どのディスプレイにも属さない位置 = ピア画面外 → 即座に戻る
            // （各ディスプレイのcontains判定はattachedTo設定に関係なく実行する）
            let inAnyDisplay = peerDisplays.contains { d in
                CGRect(x: d.peerOriginX, y: d.peerOriginY, width: d.width, height: d.height).contains(virtualCursorPosition)
            }

            if returnEdge != nil || !inAnyDisplay {
                print("[InputCapture] Edge reached or out of peer bounds, returning to local")
                let edge = returnEdge
                edgeCooldownUntil = Date().addingTimeInterval(0.5)
                exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                InputTransmitter.shared.stopTransmitting()

                // カーソルをエッジから内側に戻して再トリガー防止
                let inset: CGFloat = 10
                if let primaryHeight = NSScreen.screens.first?.frame.height,
                   let sourceId = ScreenManager.shared.transitionSourceScreen,
                   let sourceScreen = ScreenManager.shared.localScreens.first(where: { $0.id == sourceId }) {
                    let frame = ScreenManager.shared.appKitToQuartz(sourceScreen.frame, primaryHeight: primaryHeight)
                    var returnPos = lastMousePosition
                    switch edge ?? .right {
                    case .right:
                        returnPos.x = frame.maxX - inset
                    case .left:
                        returnPos.x = frame.minX + inset
                    case .bottom:
                        returnPos.y = frame.maxY - inset
                    case .top:
                        returnPos.y = frame.minY + inset
                    }
                    moveCursor(to: returnPos)
                }
                return
            }

            // ピアunionの矩形範囲にクランプ
            let peerUnion = ScreenManager.shared.peerUnion(peerId: targetPeerId)
            virtualCursorPosition.x = max(peerUnion.minX, min(virtualCursorPosition.x, peerUnion.maxX))
            virtualCursorPosition.y = max(peerUnion.minY, min(virtualCursorPosition.y, peerUnion.maxY))

            onCursorMove?(virtualCursorPosition)
        } else {
            // 通常モード: 実際のカーソル位置を使用
            let location = event.location
            lastMousePosition = location

            onCursorMove?(location)

            // クールダウン中はエッジ検出しない（バウンスバック防止）
            guard Date() > edgeCooldownUntil else { return }

            // 画面端チェック
            let (direction, _) = ScreenManager.shared.checkEdgeReached(cursorPosition: location)
            if direction != .none {
                onEdgeReached?(direction, location)
            }
        }
    }

    private func handleMouseButton(button: Int, isDown: Bool, event: CGEvent) {
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        onMouseButton?(button, isDown, clickCount)
    }

    private func handleScroll(event: CGEvent) {
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        onScroll?(CGFloat(dx), CGFloat(dy))
    }

    // MARK: - Keyboard Events

    private func handleKeyEvent(event: CGEvent, isDown: Bool) {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = getModifiers(from: event.flags)

        onKeyEvent?(keycode, isDown, modifiers)
    }

    private func handleFlagsChanged(event: CGEvent) {
        // 修飾キーの状態変化
        let flags = event.flags
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // 修飾キーが押されたか離されたかを判定
        let isDown = flags.contains(flagForKeycode(keycode))
        let modifiers = getModifiers(from: flags)

        onKeyEvent?(keycode, isDown, modifiers)
    }

    private func getModifiers(from flags: CGEventFlags) -> [String] {
        var modifiers: [String] = []

        if flags.contains(.maskCommand) { modifiers.append("cmd") }
        if flags.contains(.maskShift) { modifiers.append("shift") }
        if flags.contains(.maskAlternate) { modifiers.append("alt") }
        if flags.contains(.maskControl) { modifiers.append("ctrl") }
        if flags.contains(.maskSecondaryFn) { modifiers.append("fn") }

        return modifiers
    }

    private func flagForKeycode(_ keycode: Int) -> CGEventFlags {
        switch keycode {
        case 55, 54: return .maskCommand  // Left/Right Command
        case 56, 60: return .maskShift    // Left/Right Shift
        case 58, 61: return .maskAlternate // Left/Right Option
        case 59, 62: return .maskControl  // Left/Right Control
        case 63: return .maskSecondaryFn  // Fn
        default: return []
        }
    }

    // MARK: - Cursor Control

    /// カーソルを指定位置に移動
    func moveCursor(to point: CGPoint) {
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }

    /// カーソル位置を取得
    func getCursorPosition() -> CGPoint {
        return lastMousePosition
    }

    /// 緊急時にローカルに戻る共通処理
    private func forceReturnToLocal() {
        edgeCooldownUntil = Date().addingTimeInterval(0.5)
        exitRemoteMode()
        ScreenManager.shared.returnControlToLocal()
        InputTransmitter.shared.stopTransmitting()
    }

    /// パニック脱出: あらゆる状態を強制リセットしてカーソルを解放
    /// 通常のexitRemoteMode経路が失敗していても確実にロックを解除する最終手段
    func panicReset() {
        // 1. カーソル関連付けを最優先で復元（他の処理が失敗しても確実に解除）
        CGAssociateMouseAndMouseCursorPosition(1)

        // 2. 全状態をクリア
        isRemoteMode = false
        stopWatchdog()
        InputTransmitter.shared.stopTransmitting()
        ScreenManager.shared.returnControlToLocal()

        // 3. listenOnlyタップで再起動（イベント消費しない安全モード）
        let wasCapturing = isCapturing
        if wasCapturing {
            stopCapturing()
        }
        useDefaultTap = false
        if wasCapturing {
            startCapturing()
        }

        // 4. 念押しでもう一度
        CGAssociateMouseAndMouseCursorPosition(1)

        // 通知音（ユーザーへのフィードバック）
        NSSound(named: "Submarine")?.play()

        print("[Panic] Reset complete — cursor released, remote mode disabled")
    }
}
