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
        // DEBUG: print出力を/tmp/m2m_app.logにリダイレクト（接続デバッグ用）
        #if DEBUG
        let logPath = "/tmp/m2m_app.log"
        freopen(logPath, "w", stdout)
        freopen(logPath, "w", stderr)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        print("=== Mouse2Mouse started at \(Date()) ===")
        #endif

        // クラッシュ時のカーソルロック解除ハンドラー
        installCrashSafetyHandlers()

        // スリープ・スクリーンロック対策
        installSystemEventHandlers()

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
        // あらゆる異常終了でカーソルロック・非表示を解除
        let signals: [Int32] = [SIGINT, SIGTERM, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL]
        for sig in signals {
            signal(sig) { _ in
                CGDisplayShowCursor(CGMainDisplayID())
                CGAssociateMouseAndMouseCursorPosition(1)
                // SIGTERM以外は異常終了
                _exit(1)
            }
        }
        atexit {
            CGDisplayShowCursor(CGMainDisplayID())
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - System Event Handlers (sleep / lock / wake)

    private func installSystemEventHandlers() {
        let nc = NSWorkspace.shared.notificationCenter

        // スリープ前にリモートモード解除（カーソルロック持ち越し防止）
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            print("[System] willSleep - exiting remote mode")
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // 画面ロック前にもリモートモード解除
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            print("[System] screensDidSleep - exiting remote mode")
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // 起床時もカーソル関連付けを念のため復元
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            print("[System] didWake - restoring cursor association")
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
