import Cocoa
import ApplicationServices

/// 権限管理
class PermissionManager {

    // MARK: - Accessibility Permission

    /// アクセシビリティ権限をチェック
    static func checkAccessibility() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// アクセシビリティ権限をリクエスト（システム設定を開く）
    static func requestPermission() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限が必要です"
        alert.informativeText = """
        Mouse2Mouseがマウスとキーボードを操作するには、
        システム設定でアクセシビリティ権限を許可してください。

        1. システム設定を開く
        2. プライバシーとセキュリティ > アクセシビリティ
        3. Mouse2Mouseにチェックを入れる
        """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Input Monitoring Permission

    /// 入力監視権限をチェック
    static func checkInputMonitoring() -> Bool {
        // CGEventTapの作成を試みることで権限をチェック
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            return false
        }

        // テスト成功したらすぐに無効化
        CFMachPortInvalidate(tap)
        return true
    }

    /// 入力監視権限をリクエスト
    static func requestInputMonitoring() {
        let alert = NSAlert()
        alert.messageText = "入力監視権限が必要です"
        alert.informativeText = """
        Mouse2Mouseがマウスとキーボードの入力を検知するには、
        入力監視権限を許可してください。

        1. システム設定を開く
        2. プライバシーとセキュリティ > 入力監視
        3. Mouse2Mouseにチェックを入れる
        """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")

        if alert.runModal() == .alertFirstButtonReturn {
            openInputMonitoringSettings()
        }
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - All Permissions

    /// 全ての必要な権限があるかチェック
    static func hasAllPermissions() -> Bool {
        return checkAccessibility() && checkInputMonitoring()
    }
}
