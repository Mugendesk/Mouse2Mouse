import SwiftUI
import AppKit
import UserNotifications
import Combine

@main
struct Mouse2MouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    // Core Services
    let discoveryService = DiscoveryService.shared
    let screenManager = ScreenManager.shared
    let inputCapture = InputCapture.shared
    let inputTransmitter = InputTransmitter.shared
    let connectionManager = ConnectionManager.shared
    let hotkeyManager = HotkeyManager.shared
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // クラッシュ時のカーソルロック解除ハンドラー
        installCrashSafetyHandlers()

        // Dockアイコンを非表示
        NSApp.setActivationPolicy(.accessory)

        // メニューバーアイテム設定
        setupMenuBar()

        // 権限チェック
        checkPermissions()

        // 権限の定期チェック（実行中に取り消された場合の対応）
        startPermissionMonitoring()

        // 通知権限リクエスト
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // サービス起動
        startServices()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Mouse2Mouse")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(discoveryService)
                .environmentObject(screenManager)
                .environmentObject(hotkeyManager)
        )

        // メニューバーアイコンを共有状態に連動
        hotkeyManager.$isSharingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                let iconName = enabled ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash"
                self?.statusItem.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Mouse2Mouse")
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func checkPermissions() {
        if !PermissionManager.checkAccessibility() {
            PermissionManager.requestPermission()
        }

        if !PermissionManager.checkInputMonitoring() {
            PermissionManager.requestInputMonitoring()
        }
    }

    private func startServices() {
        // mDNS発見サービス開始
        discoveryService.start()

        // 画面情報初期化
        screenManager.updateScreenInfo()

        // Hostモード時のみイベント傍受開始（listenOnlyで安全）
        if screenManager.deviceRole == .host {
            inputCapture.startCapturing()
        }

        // クリップボード同期開始
        ClipboardSync.shared.startMonitoring()

        // ファイル転送サーバー開始
        FileTransferServer.shared.start()

        print("Mouse2Mouse started (role: \(screenManager.deviceRole.rawValue))")
    }

    // MARK: - Crash Safety

    private func installCrashSafetyHandlers() {
        // あらゆる異常終了でカーソルロックを解除
        let signals: [Int32] = [SIGINT, SIGTERM, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL]
        for sig in signals {
            signal(sig) { _ in
                CGAssociateMouseAndMouseCursorPosition(1)
                // SIGTERM以外は異常終了
                _exit(1)
            }
        }
        atexit {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - Permission Monitoring

    private var permissionTimer: Timer?

    private func startPermissionMonitoring() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            if !PermissionManager.hasAllPermissions() {
                print("[Permission] Permissions revoked, disabling input capture")
                InputCapture.shared.exitRemoteMode()
                InputCapture.shared.stopCapturing()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        // リモートモードを解除（カーソル固定を確実に解除）
        inputCapture.exitRemoteMode()
        inputCapture.stopCapturing()
        inputTransmitter.stopTransmitting()
        discoveryService.stop()
        ClipboardSync.shared.stopMonitoring()
        // カーソル関連付けを確実に復元（フェイルセーフ）
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
