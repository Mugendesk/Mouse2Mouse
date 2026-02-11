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
    var onMouseButton: ((Int, Bool) -> Void)?  // button, isDown
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

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Capture Control

    func startCapturing() {
        guard !isCapturing else { return }

        var eventMask: CGEventMask = 0
        // マウスイベントのみキャプチャ（キーボードはキャプチャしない = 詰まない）
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        // キーボードイベントはキャプチャしない（ローカルで常に動作）
        // eventMask |= (1 << CGEventType.keyDown.rawValue)
        // eventMask |= (1 << CGEventType.keyUp.rawValue)
        // eventMask |= (1 << CGEventType.flagsChanged.rawValue)

        // 自身へのポインタをuserInfoとして渡す
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: useDefaultTap ? .defaultTap : .listenOnly,  // リモートモード時のみイベント消費可能
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let capture = Unmanaged<InputCapture>.fromOpaque(userInfo).takeUnretainedValue()
                return capture.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("Failed to create event tap - check accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        isCapturing = true
        print("Input capture started")
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
        isRemoteMode = true
        virtualCursorPosition = entryPoint
        // イベントを消費できるようにdefaultTapで再作成
        restartCapturing(withDefaultTap: true)
        // カーソルを固定
        CGAssociateMouseAndMouseCursorPosition(0)
        print("Entered remote mode at \(entryPoint)")
    }

    /// リモートモードを終了
    func exitRemoteMode() {
        guard isRemoteMode else { return }
        isRemoteMode = false
        // カーソル固定を解除
        CGAssociateMouseAndMouseCursorPosition(1)
        // listenOnlyに戻す（安全）
        restartCapturing(withDefaultTap: false)
        print("Exited remote mode")
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

    // MARK: - Event Handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
            handleMouseButton(button: 0, isDown: true)
        case .leftMouseUp:
            handleMouseButton(button: 0, isDown: false)

        case .rightMouseDown:
            handleMouseButton(button: 1, isDown: true)
        case .rightMouseUp:
            handleMouseButton(button: 1, isDown: false)

        case .otherMouseDown:
            handleMouseButton(button: 2, isDown: true)
        case .otherMouseUp:
            handleMouseButton(button: 2, isDown: false)

        case .scrollWheel:
            handleScroll(event: event)

        case .keyDown:
            // Escキーでリモートモードから脱出
            if isRemoteMode && event.getIntegerValueField(.keyboardEventKeycode) == 53 {  // 53 = Escape
                print("Escape pressed, exiting remote mode")
                exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                return nil
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
            // リモートモード: デルタ値で仮想カーソルを移動
            let deltaX = event.getDoubleValueField(.mouseEventDeltaX)
            let deltaY = event.getDoubleValueField(.mouseEventDeltaY)

            virtualCursorPosition.x += CGFloat(deltaX)
            virtualCursorPosition.y += CGFloat(deltaY)

            // リモート画面のサイズを取得
            if let targetId = InputTransmitter.shared.currentTargetPeerId,
               let remoteScreen = ScreenManager.shared.remoteScreens.first(where: { $0.id == targetId }) {
                // リモート画面の接続方向に基づいて戻り判定
                let shouldReturn: Bool
                switch remoteScreen.attachedEdge {
                case .right:
                    shouldReturn = virtualCursorPosition.x < 0
                case .left:
                    shouldReturn = virtualCursorPosition.x > remoteScreen.width
                case .bottom:
                    shouldReturn = virtualCursorPosition.y < 0
                case .top:
                    shouldReturn = virtualCursorPosition.y > remoteScreen.height
                }

                if shouldReturn {
                    print("[InputCapture] Edge reached, returning to local (edge: \(remoteScreen.attachedEdge))")
                    edgeCooldownUntil = Date().addingTimeInterval(0.5)
                    exitRemoteMode()
                    ScreenManager.shared.returnControlToLocal()
                    InputTransmitter.shared.stopTransmitting()
                    return
                }

                // 画面範囲内にクランプ
                virtualCursorPosition.x = max(0, min(virtualCursorPosition.x, remoteScreen.width))
                virtualCursorPosition.y = max(0, min(virtualCursorPosition.y, remoteScreen.height))
            } else {
                // リモート画面が見つからない場合は即座にローカルに戻る
                print("[InputCapture] Remote screen not found, returning to local")
                edgeCooldownUntil = Date().addingTimeInterval(0.5)
                exitRemoteMode()
                ScreenManager.shared.returnControlToLocal()
                InputTransmitter.shared.stopTransmitting()
                return
            }

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

    private func handleMouseButton(button: Int, isDown: Bool) {
        onMouseButton?(button, isDown)
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
}
