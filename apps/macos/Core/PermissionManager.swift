import Cocoa
import ApplicationServices
import IOKit.hid

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
    /// IOHIDCheckAccess(.listenEvent)が信頼できる唯一の判定方法。
    /// CGEventTap創建だけだとマウスマスクは権限なしでも通ってしまい、
    /// キーボードイベントのみサイレントドロップされる罠がある。
    static func checkInputMonitoring() -> Bool {
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 入力監視権限をリクエスト
    /// IOHIDRequestAccessでシステムプロンプトを直接トリガーする。
    /// 拒否済みの場合は alert を出して設定画面に誘導。
    static func requestInputMonitoring() {
        // IOHIDRequestAccessは権限が未決定ならシステムダイアログを出してくれる。
        // 既に拒否されている場合は false を返すので、その時だけ alert を出す。
        if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            return
        }

        let alert = NSAlert()
        alert.messageText = "入力監視権限が必要です"
        alert.informativeText = """
        キーボード共有を使うには「入力監視」権限が必須です。
        マウスだけならこの権限なしでも動きますが、キーは送れません。

        1. システム設定を開く
        2. プライバシーとセキュリティ > 入力監視
        3. Mouse2Mouseにチェックを入れる
        4. アプリを再起動
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
