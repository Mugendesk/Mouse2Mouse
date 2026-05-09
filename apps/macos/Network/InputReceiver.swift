import Foundation
import CoreGraphics
import Cocoa

/// 入力イベント受信
/// リモートデバイスから受信した入力イベントをローカルで実行
class InputReceiver {
    static let shared = InputReceiver()

    private var virtualCursorPosition: CGPoint = .zero

    // スクロール端数の累積（Int32への切り捨てで失われる微小デルタを保持）
    private var scrollResidualX: Double = 0
    private var scrollResidualY: Double = 0

    // ボタン押下状態（押下中の移動はDraggedイベントとして発火させるため必要）
    private var leftButtonDown = false
    private var rightButtonDown = false
    private var otherButtonDown = false

    // AXIsProcessTrusted()キャッシュ（毎フレーム呼ぶと遅いため5秒間隔で更新）
    private var cachedTrusted: Bool = false
    private var cachedTrustedAt: CFAbsoluteTime = 0
    private let trustedCacheTTL: CFAbsoluteTime = 5.0

    // CGWarp / mouseMoved postの絞り込み（Launchpad/Dock/MC等の高負荷UIが
    // 高頻度のhover更新で崩壊するのを防ぐ）。
    // ローカルHWマウスは~125Hzで動くため、それに揃えれば挙動が自然になる。
    // - Warp 120Hz（カーソル位置の追従）
    // - mouseMoved post 60Hz（hover効果・Launchpad highlight等の通知）
    // ドラッグ中は全レート維持（描画/選択精度のため）。
    private var lastWarpTime: CFAbsoluteTime = 0
    private let warpInterval: CFAbsoluteTime = 1.0 / 120.0
    private var pendingWarpPosition: CGPoint?
    private var warpFlushScheduled = false
    private var lastMoveEventPostTime: CFAbsoluteTime = 0
    private let mouseMovedPostInterval: CFAbsoluteTime = 1.0 / 60.0
    // Launchpad/MC等はmouseEventDeltaX/Yで「動いた」を判定するため、
    // delta=0だと「動いてない」と認識されhighlightが付いてこない（カーソル
    // ダブり症状の原因）。前回post位置からのdeltaを必ず設定する。
    private var lastPostedPosition: CGPoint?


    private init() {
        cachedTrusted = AXIsProcessTrusted()
        cachedTrustedAt = CFAbsoluteTimeGetCurrent()
    }

    private func isAccessibilityTrusted() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedTrustedAt >= trustedCacheTTL {
            cachedTrusted = AXIsProcessTrusted()
            cachedTrustedAt = now
        }
        return cachedTrusted
    }

    /// 外部からカーソル位置を設定（controlTransfer受信時に初期位置を同期）
    func setVirtualCursorPosition(_ position: CGPoint) {
        virtualCursorPosition = position
    }

    // MARK: - Role Check

    /// Hostモードの場合は入力を受け付けない
    private var shouldReceiveInput: Bool {
        // Hostモードでも、リモートからの戻りカーソルは受け付ける必要がある
        // ただし通常の入力操作はClientモードのみ
        return ScreenManager.shared.deviceRole == .client
    }

    // MARK: - Cursor Movement

    func handleCursorMove(x: Double, y: Double) {
        // 仮想デスクトップ全体（全ディスプレイの和集合）を基準に正規化座標を解釈
        let union = ScreenManager.shared.localVirtualDesktopQuartz()
        guard union.width > 0, union.height > 0 else { return }

        let actualX = union.minX + CGFloat(x) * union.width
        let actualY = union.minY + CGFloat(y) * union.height
        let newPos = CGPoint(x: actualX, y: actualY)
        virtualCursorPosition = newPos
        moveCursor(to: newPos)
    }

    private func moveCursor(to point: CGPoint) {
        // 権限チェック（5秒キャッシュ）
        if !isAccessibilityTrusted() {
            print("[InputReceiver] ERROR: Accessibility permission not granted!")
            return
        }

        let isDragging = leftButtonDown || rightButtonDown || otherButtonDown

        // ドラッグ中はWarp/post全レートで実行（描画・選択精度のため）。
        // hover中はWarpを120Hzに絞ってLaunchpad等の高負荷UIの暴走を防ぐ。
        if isDragging {
            CGWarpMouseCursorPosition(point)
        } else {
            // hover時: 120Hz throttleでwarp。trailing-edge flushで最終位置は確実に到達
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastWarpTime >= warpInterval {
                lastWarpTime = now
                CGWarpMouseCursorPosition(point)
                pendingWarpPosition = nil
            } else {
                pendingWarpPosition = point
                if !warpFlushScheduled {
                    warpFlushScheduled = true
                    let delay = warpInterval - (now - lastWarpTime)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        self.warpFlushScheduled = false
                        if let pending = self.pendingWarpPosition {
                            self.pendingWarpPosition = nil
                            self.lastWarpTime = CFAbsoluteTimeGetCurrent()
                            CGWarpMouseCursorPosition(pending)
                        }
                    }
                }
            }
        }

        // イベントタイプ決定
        let (eventType, button): (CGEventType, CGMouseButton)
        if leftButtonDown {
            (eventType, button) = (.leftMouseDragged, .left)
        } else if rightButtonDown {
            (eventType, button) = (.rightMouseDragged, .right)
        } else if otherButtonDown {
            (eventType, button) = (.otherMouseDragged, .center)
        } else {
            // hover: 60Hzに絞ってpost（local HWマウスと同程度。Dock magnification・
            // Launchpad highlight等のhover効果を維持しつつ高負荷UIの暴走を防ぐ）。
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastMoveEventPostTime < mouseMovedPostInterval { return }
            lastMoveEventPostTime = now
            (eventType, button) = (.mouseMoved, .left)
        }

        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: button
        ) {
            // delta値を設定（Launchpad/MC等の「動いた」検知に必要）
            let prev = lastPostedPosition ?? point
            let dx = Int64((point.x - prev.x).rounded())
            let dy = Int64((point.y - prev.y).rounded())
            moveEvent.setIntegerValueField(.mouseEventDeltaX, value: dx)
            moveEvent.setIntegerValueField(.mouseEventDeltaY, value: dy)
            lastPostedPosition = point
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse Button

    func handleMouseButton(button: Int, isDown: Bool, clickCount: Int = 1) {
        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case 0:  // Left
            mouseButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
            leftButtonDown = isDown
        case 1:  // Right
            mouseButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
            rightButtonDown = isDown
        case 2:  // Middle
            mouseButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
            otherButtonDown = isDown
        default:
            return
        }

        let eventType = isDown ? downType : upType

        let position = virtualCursorPosition

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: position,
            mouseButton: mouseButton
        )
        // clickCountを設定（macOSアプリがクリックを認識するために必須）
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    func handleScroll(dx: Double, dy: Double) {
        // 端数を累積して切り捨てによる精度ロスを防ぐ（トラックパッドの慣性スクロール対応）
        scrollResidualX += dx
        scrollResidualY += dy

        let intDx = Int32(scrollResidualX.rounded(.towardZero))
        let intDy = Int32(scrollResidualY.rounded(.towardZero))

        // 整数化した分だけ累積から差し引く（端数は次回に持ち越し）
        scrollResidualX -= Double(intDx)
        scrollResidualY -= Double(intDy)

        // 両軸とも0なら発火しない（無駄なイベントを避ける）
        guard intDx != 0 || intDy != 0 else { return }

        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: intDy,
            wheel2: intDx,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func handleKeyEvent(keycode: Int, isDown: Bool, modifiers: [String]) {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keycode),
            keyDown: isDown
        )
        if event == nil {
            print("[Key←] ERROR: Failed to create CGEvent for keycode=\(keycode)")
            return
        }

        // 修飾キーを設定
        var flags: CGEventFlags = []

        for modifier in modifiers {
            switch modifier {
            case "cmd":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt":
                flags.insert(.maskAlternate)
            case "ctrl":
                flags.insert(.maskControl)
            case "fn":
                flags.insert(.maskSecondaryFn)
            default:
                break
            }
        }

        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Modifier Keys

    func handleModifierChange(modifier: String, isDown: Bool) {
        let keycode: CGKeyCode

        switch modifier {
        case "cmd":
            keycode = 55  // Left Command
        case "shift":
            keycode = 56  // Left Shift
        case "alt":
            keycode = 58  // Left Option
        case "ctrl":
            keycode = 59  // Left Control
        case "fn":
            keycode = 63  // Fn
        default:
            return
        }

        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keycode,
            keyDown: isDown
        )
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Convenience Methods

    /// キーボードショートカットを実行
    func executeShortcut(keys: [String]) {
        var modifiers: [String] = []
        var keycode: Int?

        for key in keys {
            switch key.lowercased() {
            case "cmd", "command":
                modifiers.append("cmd")
            case "shift":
                modifiers.append("shift")
            case "alt", "option":
                modifiers.append("alt")
            case "ctrl", "control":
                modifiers.append("ctrl")
            default:
                // 通常のキー
                keycode = keycodeForCharacter(key)
            }
        }

        guard let code = keycode else { return }

        // キーダウン
        handleKeyEvent(keycode: code, isDown: true, modifiers: modifiers)

        // 少し遅延してキーアップ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.handleKeyEvent(keycode: code, isDown: false, modifiers: modifiers)
        }
    }

    private func keycodeForCharacter(_ char: String) -> Int? {
        // 主要なキーコードマッピング
        let keycodes: [String: Int] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14,
            "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
            "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
            "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
            "space": 49, "return": 36, "tab": 48,
            "delete": 51, "escape": 53,
            "left": 123, "right": 124, "up": 126, "down": 125
        ]

        return keycodes[char.lowercased()]
    }
}
