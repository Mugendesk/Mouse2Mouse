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

        // ペアリング承認ダイアログの監視
        installPairingApprovalHandler()
        installKeyChangeWarningHandler()

        // サービス起動
        startServices()
    }

    // MARK: - Pairing Approval

    private func installPairingApprovalHandler() {
        PairingManager.shared.$pendingApproval
            .receive(on: DispatchQueue.main)
            .sink { pending in
                guard let pending = pending else { return }
                let fingerprint = PairingManager.fingerprint(of: pending.publicKey)
                let alert = NSAlert()
                alert.messageText = "\(pending.hostname) からの接続要求"
                alert.informativeText = """
                このデバイスとペアリングして接続を許可しますか？
                一度許可すると以降は自動的に承認されます。

                鍵フィンガープリント:
                \(fingerprint)
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "許可")
                alert.addButton(withTitle: "拒否")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                let approved = response == .alertFirstButtonReturn
                PairingManager.shared.respondToApproval(approved: approved)
                print("[Pairing] User \(approved ? "approved" : "rejected") \(pending.hostname)")
            }
            .store(in: &cancellables)
    }

    /// TOFU鍵ローテーション検知時の警告ダイアログ
    private func installKeyChangeWarningHandler() {
        PairingManager.shared.$pendingKeyChangeWarning
            .receive(on: DispatchQueue.main)
            .sink { warning in
                guard let warning = warning else { return }
                let oldFp = PairingManager.fingerprint(of: warning.oldPublicKey)
                let newFp = PairingManager.fingerprint(of: warning.newPublicKey)
                let alert = NSAlert()
                alert.messageText = "⚠️ \(warning.hostname) の鍵が変わりました"
                alert.informativeText = """
                このデバイスの公開鍵が前回と異なります。
                相手が再インストールした場合はあり得ますが、中間者攻撃の可能性もあります。

                以前の鍵:
                \(oldFp)

                新しい鍵:
                \(newFp)

                相手と直接確認できる場合のみ「信頼」してください。
                """
                alert.alertStyle = .critical
                alert.addButton(withTitle: "拒否")
                alert.addButton(withTitle: "新しい鍵を信頼")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                // alertFirstButtonReturn = 拒否, alertSecondButtonReturn = 信頼
                let trusted = response == .alertSecondButtonReturn
                PairingManager.shared.respondToKeyChange(trustNewKey: trusted)
                print("[Pairing] User \(trusted ? "trusted" : "rejected") new key for \(warning.hostname)")
            }
            .store(in: &cancellables)
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
        // パフォーマンス計測（メインスレッドハング検知）開始
        PerfLogger.startHangDetector()

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

    // GCDシグナルソースの保持用（解放されるとキャンセルされるため強参照で保持）
    private var signalSources: [DispatchSourceSignal] = []

    private func installCrashSafetyHandlers() {
        // --- 正常な終了シグナル (kill / Ctrl-C など) ---
        // GCDのシグナルソース経由で処理する。イベントハンドラは通常の実行コンテキスト
        // (グローバルキュー)で動くため、CGDisplayShowCursor / CGAssociate... を安全に呼べる。
        // ※シグナルハンドラ内で直接これらを呼ぶとMach IPC/ロックを伴うため
        //   デッドロックし、プロセスがカーネルで固着して kill -9 でも落ちなくなる。
        // ※メインスレッドがハングしていても確実に後処理→終了できるよう .global() を使う。
        let gracefulSignals: [Int32] = [SIGTERM, SIGINT]
        for sig in gracefulSignals {
            signal(sig, SIG_IGN)  // デフォルトの即時終了を抑止し、ソースに委ねる
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                CGDisplayShowCursor(CGMainDisplayID())
                CGAssociateMouseAndMouseCursorPosition(1)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // --- 異常終了シグナル (真のクラッシュ) ---
        // 非同期シグナルコンテキストではasync-signal-safeな処理しか行えないため、
        // CG呼び出しは行わずデフォルト処理に戻して再raiseする。
        // プロセス死亡時にWindowServerがカーソル表示・関連付けを自動復元する。
        let crashSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL]
        for sig in crashSignals {
            signal(sig) { s in
                signal(s, SIG_DFL)
                raise(s)
            }
        }

        // 正常な exit() 時のフェイルセーフ。atexitは通常コンテキストのためCG呼び出しは安全。
        atexit {
            CGDisplayShowCursor(CGMainDisplayID())
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - System Event Handlers (sleep / lock / wake)

    private func installSystemEventHandlers() {
        let nc = NSWorkspace.shared.notificationCenter

        // スリープ前にリモートモード解除 + WebSocket全切断
        // (半開放TCP接続を残すと復帰後に30秒近く「死んだ接続」を使い続けるため)
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            print("[System] willSleep - exiting remote mode and disconnecting all peers")
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
            CGAssociateMouseAndMouseCursorPosition(1)
            ConnectionManager.shared.disconnectAll()
        }

        // 画面ロック前にもリモートモード解除
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            print("[System] screensDidSleep - exiting remote mode")
            InputCapture.shared.exitRemoteMode()
            InputTransmitter.shared.stopTransmitting()
            ScreenManager.shared.returnControlToLocal()
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // 起床時: カーソル関連付け復元 + tap再構築 + Discovery再起動
        // (Bonjour browser/serverもwakeで止まるので作り直す)
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            print("[System] didWake - restoring services")
            CGAssociateMouseAndMouseCursorPosition(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                InputCapture.shared.rebuildTapAfterWake()
                DiscoveryService.shared.restartAfterWake()
            }
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
