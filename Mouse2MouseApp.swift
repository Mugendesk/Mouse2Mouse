import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dockアイコンを非表示
        NSApp.setActivationPolicy(.accessory)

        // メニューバーアイテム設定
        setupMenuBar()

        // 権限チェック
        checkPermissions()

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
        )
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

        // イベント傍受開始
        inputCapture.startCapturing()

        // クリップボード同期開始
        ClipboardSync.shared.startMonitoring()

        print("Mouse2Mouse started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        discoveryService.stop()
        inputCapture.stopCapturing()
        ClipboardSync.shared.stopMonitoring()
    }
}
