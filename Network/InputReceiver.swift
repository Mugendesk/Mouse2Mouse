import Foundation
import CoreGraphics
import Cocoa

/// 入力イベント受信
/// リモートデバイスから受信した入力イベントをローカルで実行
class InputReceiver {
    static let shared = InputReceiver()

    private var virtualCursorPosition: CGPoint = .zero

    private init() {}

    // MARK: - Role Check

    /// Hostモードの場合は入力を受け付けない
    private var shouldReceiveInput: Bool {
        // Hostモードでも、リモートからの戻りカーソルは受け付ける必要がある
        // ただし通常の入力操作はClientモードのみ
        return ScreenManager.shared.deviceRole == .client
    }

    // MARK: - Cursor Movement

    func handleCursorMove(x: Double, y: Double) {
        // 注意: カーソル移動は役割に関係なく処理する
        // （Hostからの戻り操作のため）
        print("[InputReceiver] handleCursorMove called: (\(x), \(y))")

        guard let screen = NSScreen.main else {
            print("[InputReceiver] ERROR: No main screen")
            return
        }

        // 正規化座標(0-1)から画面座標に変換
        let actualX = CGFloat(x) * screen.frame.width
        let actualY = CGFloat(y) * screen.frame.height

        let cgPoint = CGPoint(x: actualX, y: actualY)
        virtualCursorPosition = cgPoint

        print("[InputReceiver] Moving cursor to: (\(Int(actualX)), \(Int(actualY)))")

        // カーソルを移動
        moveCursor(to: cgPoint)
    }

    private func moveCursor(to point: CGPoint) {
        // 権限チェック
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[InputReceiver] ERROR: Accessibility permission not granted!")
            return
        }

        // CGEventはすでに左上原点の座標系
        guard let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            print("[InputReceiver] ERROR: Failed to create CGEvent")
            return
        }
        moveEvent.post(tap: .cghidEventTap)

        // 実際のカーソル位置を確認
        if let currentPos = CGEvent(source: nil)?.location {
            print("[InputReceiver] Cursor now at: (\(Int(currentPos.x)), \(Int(currentPos.y)))")
        }
    }

    // MARK: - Mouse Button

    func handleMouseButton(button: Int, isDown: Bool) {
        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case 0:  // Left
            mouseButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case 1:  // Right
            mouseButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case 2:  // Middle
            mouseButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        default:
            return
        }

        let eventType = isDown ? downType : upType

        // virtualCursorPositionはNSScreen座標(左下原点)で保存されている
        // CGEventは左上原点なので、現在のマウス位置を取得して使用
        guard let currentPosition = CGEvent(source: nil)?.location else { return }
        let position = currentPosition

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: position,
            mouseButton: mouseButton
        )
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    func handleScroll(dx: Double, dy: Double) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
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
