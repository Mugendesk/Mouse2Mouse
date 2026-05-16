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
    /// CGEventTap専用のバックグラウンドスレッドとそのRunLoop。
    /// メインスレッドのUI更新（@Published, AppKit描画など）と隔離することで
    /// 他アプリ（matcha等）がWindowServerを酷使してもイベント取りこぼしを最小化する。
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tapKeepAliveSource: CFRunLoopSource?
    private var lastMousePosition: CGPoint = .zero
    private var virtualCursorPosition: CGPoint = .zero  // リモートモード用の仮想カーソル位置
    private var useDefaultTap = false  // true: イベント消費可能（リモートモード用）、false: listenOnly（安全）
    private var edgeCooldownUntil: Date = .distantPast  // エッジ検出クールダウン（バウンスバック防止）

    // パニック脱出: 600ms以内に3回Esc連打で強制リセット
    private var escPressTimestamps: [CFAbsoluteTime] = []
    private let panicWindow: CFAbsoluteTime = 0.6
    private let panicCount = 3

    // ウォッチドッグ:
    // - 入力イベント途絶30秒 → 自動解除（ユーザー離席・読み中の自然な待機を許容）
    // - ピア無音5秒 → 自動解除（WiFiジッター許容、それでも死亡時は確実に脱出）
    private var watchdogTimer: DispatchSourceTimer?
    private var lastEventTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastPeerMessageTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private let inputWatchdogTimeout: CFAbsoluteTime = 30.0
    private let peerWatchdogTimeout: CFAbsoluteTime = 5.0

    // CGDisplayHideCursorは内部で参照カウントを持つので、hide回数だけshowしないと残ハイドになる。
    private var hideCursorCount: Int = 0

    /// ピアからメッセージ受信時に呼ぶ（無音検知のリセット）
    func peerMessageReceived() {
        lastPeerMessageTimestamp = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Capture Control

    /// キーボードイベントがキャプチャできているか（Input Monitoring権限依存）
    private(set) var hasKeyboardCapture = false

    /// CGEventTap 専用スレッドを起動して RunLoop の参照を保持する。
    /// 二度目以降の呼び出しは何もしない（idempotent）。
    /// keep-alive source を1つ入れておかないと、source追加前にRunLoopが終了することがある。
    private func ensureTapThread() {
        guard tapThread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            // RunLoopが空回り→exit するのを防ぐためのダミーsource
            var ctx = CFRunLoopSourceContext()
            ctx.version = 0
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
            if let keepAlive = keepAlive {
                CFRunLoopAddSource(rl, keepAlive, .commonModes)
                self?.tapKeepAliveSource = keepAlive
            }
            self?.tapRunLoop = rl
            ready.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "M2M.InputCaptureTap"
        thread.start()
        ready.wait()
        tapThread = thread
    }

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

        // 専用バックグラウンドスレッドのRunLoopに付けることで、メインスレッドの
        // UI更新（SwiftUI再描画、@Published通知、外部アプリ起因のWindowServer負荷）と
        // イベント配信を切り離す。
        ensureTapThread()
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopAddSource(rl, source, .commonModes)
            CFRunLoopWakeUp(rl)
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        isCapturing = true
        let inputMonitoring = PermissionManager.checkInputMonitoring()
        let accessibility = PermissionManager.checkAccessibility()
        print("[InputCapture] Started (keyboard: \(hasKeyboardCapture), defaultTap: \(useDefaultTap), accessibility: \(accessibility), inputMonitoring: \(inputMonitoring))")
        if !inputMonitoring {
            print("[InputCapture] WARN: Input Monitoring permission denied — keyboard events will be silently dropped by macOS")
        }
    }

    func stopCapturing() {
        guard isCapturing else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopWakeUp(rl)
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

        // CGDisplayHideCursorは「呼び出しアプリがactiveでないと実質hideしない」仕様の罠あり。
        // menubarアプリ(.accessory)は普通active扱いされず、行き来後に解除される。
        // 自分をactiveにしてからhide+disassociateを行い、確実に効かせる。
        // ただしactivateは開いてる他ウィンドウ（画面配置等）を前面に持ち上げる副作用があるので即引っ込める。
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            ScreenLayoutWindowController.shared?.orderOut(nil)
            TrustedDevicesWindowController.shared?.orderOut(nil)
        }

        // タップ再生成"前"にカーソルを切り離す（タップ再生成で関連付けが
        // リセットされる経験的バグを避けるため、freeze→tap restartの順）
        let assocErr = CGAssociateMouseAndMouseCursorPosition(0)
        let hideErr = CGDisplayHideCursor(CGMainDisplayID())
        hideCursorCount += 1

        // イベントを消費できるようにdefaultTapで再作成
        restartCapturing(withDefaultTap: true)

        // ウォッチドッグ開始（イベント途絶で自動解除）
        startWatchdog()

        print("[InputCapture] Entered remote mode at \(entryPoint) assocErr=\(assocErr.rawValue) hideErr=\(hideErr.rawValue)")
    }

    /// リモートモードを終了
    func exitRemoteMode() {
        guard isRemoteMode else { return }
        isRemoteMode = false
        // ウォッチドッグ停止
        stopWatchdog()
        // カーソル復元（hideした回数だけshowを呼ぶ。残ハイド防止）
        while hideCursorCount > 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            hideCursorCount -= 1
        }
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

    /// スリープ→起床後にタップを作り直す（CGEventTapがwake後にkeyboard capture片肺になる症状対策）
    /// 現在のuseDefaultTap状態を維持して再作成する
    func rebuildTapAfterWake() {
        guard isCapturing else { return }
        print("[InputCapture] Rebuilding tap after wake (defaultTap=\(useDefaultTap))")
        restartCapturing(withDefaultTap: useDefaultTap)
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
        let handleStart = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - handleStart
            if elapsed > PerfLogger.slowOperationThresholdSec {
                print("[PerfLogger] ⏱ InputCapture.handleEvent(\(type.rawValue)): \(String(format: "%.1f", elapsed * 1000))ms")
            }
        }

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
                // toggle() は @Published を変更する可能性があるためメインで実行
                DispatchQueue.main.async {
                    HotkeyManager.shared.toggle()
                }
                return nil
            }
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == 53 {  // Escape
                // パニック脱出: 600ms以内に3回Esc連打 → 全状態を強制リセット（最終手段として残す）
                let now = CFAbsoluteTimeGetCurrent()
                escPressTimestamps.append(now)
                escPressTimestamps.removeAll { now - $0 > panicWindow }
                if escPressTimestamps.count >= panicCount {
                    print("[Panic] Triple-Esc detected — emergency reset")
                    escPressTimestamps.removeAll()
                    // panicReset() は @Published を変更し UI 状態も触るためメインで実行
                    DispatchQueue.main.async { [weak self] in
                        self?.panicReset()
                    }
                    return nil
                }
                // 単発Escはリモートに透過（Vim/MC等で必要）。脱出はCtrl+Opt+S または triple-Esc で。
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

            let prevPos = virtualCursorPosition
            var newPos = prevPos
            newPos.x += CGFloat(deltaX)
            newPos.y += CGFloat(deltaY)

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

            // 直前位置がいたディスプレイを特定（attachedToがあるもののみ戻り判定対象）
            let sourceDisplay = peerDisplays.first { d in
                CGRect(x: d.peerOriginX, y: d.peerOriginY, width: d.width, height: d.height)
                    .contains(prevPos)
            }

            // 戻り判定: ソースディスプレイの貼り付け辺と「逆方向」に新位置が抜けたら戻る
            // attachedEdge=右 = devが右側にある → 戻り = 左方向に脱出 (newPos.x < dRect.minX)
            var shouldReturn = false
            var returnEdge: ScreenManager.RemoteScreen.Edge?
            if let source = sourceDisplay, source.attachedTo != nil {
                let dRect = CGRect(x: source.peerOriginX, y: source.peerOriginY,
                                   width: source.width, height: source.height)
                switch source.attachedEdge {
                case .right:
                    if newPos.x < dRect.minX { shouldReturn = true }
                case .left:
                    if newPos.x >= dRect.maxX { shouldReturn = true }
                case .top:
                    if newPos.y >= dRect.maxY { shouldReturn = true }
                case .bottom:
                    if newPos.y < dRect.minY { shouldReturn = true }
                }
                if shouldReturn { returnEdge = source.attachedEdge }
            }

            if shouldReturn {
                print("[InputCapture] Returning to local via \(returnEdge?.rawValue ?? "?") edge of \(sourceDisplay?.name ?? "?")")
                edgeCooldownUntil = Date().addingTimeInterval(0.5)
                exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                InputTransmitter.shared.stopTransmitting()

                // カーソルをエッジから内側に戻して再トリガー防止
                let inset: CGFloat = 10
                if let primaryHeight = ScreenManager.shared.localScreens.first?.frame.height,
                   let sourceId = ScreenManager.shared.transitionSourceScreen,
                   let sourceScreen = ScreenManager.shared.localScreens.first(where: { $0.id == sourceId }) {
                    let frame = ScreenManager.shared.appKitToQuartz(sourceScreen.frame, primaryHeight: primaryHeight)
                    var returnPos = lastMousePosition
                    switch returnEdge ?? .right {
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

            // 戻り判定にかからなかったらピアunion矩形にクランプ
            // (ピア内ディスプレイ間の遷移はクランプ範囲内で許容される)
            let peerUnion = ScreenManager.shared.peerUnion(peerId: targetPeerId)
            newPos.x = max(peerUnion.minX, min(newPos.x, peerUnion.maxX - 0.001))
            newPos.y = max(peerUnion.minY, min(newPos.y, peerUnion.maxY - 0.001))

            virtualCursorPosition = newPos
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

    /// 緊急時にローカルに戻る共通処理。
    /// CGEventTapコールバック（バックグラウンドスレッド）から呼ばれることがあるため
    /// @Published 更新と AppKit 操作はメインに切り替える。
    private func forceReturnToLocal() {
        edgeCooldownUntil = Date().addingTimeInterval(0.5)
        DispatchQueue.main.async { [weak self] in
            self?.exitRemoteMode()
            ScreenManager.shared.returnControlToLocal()
            InputTransmitter.shared.stopTransmitting()
        }
    }

    /// パニック脱出: あらゆる状態を強制リセットしてカーソルを解放
    /// 通常のexitRemoteMode経路が失敗していても確実にロックを解除する最終手段
    func panicReset() {
        // 1. カーソル表示と関連付けを最優先で復元（hideカウンタ分Show、念押しで余分にも実行）
        for _ in 0..<max(1, hideCursorCount) {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        // カウンタが食い違ってる可能性に備えて余分にもShow（macOSは0未満にならないので無害）
        for _ in 0..<5 { CGDisplayShowCursor(CGMainDisplayID()) }
        hideCursorCount = 0
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
        CGDisplayShowCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(1)

        // 通知音（ユーザーへのフィードバック）
        NSSound(named: "Submarine")?.play()

        print("[Panic] Reset complete — cursor released, remote mode disabled")
    }
}
