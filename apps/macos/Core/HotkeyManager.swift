import Foundation
import Cocoa
import Combine

/// グローバルホットキー管理（Barrierの「Scroll Lock」相当）
/// Ctrl+Option+S で画面共有のON/OFFを切り替え
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    // MARK: - Published Properties

    @Published var isSharingEnabled = true

    // MARK: - Constants

    private let hotkeyKeyCode: UInt16 = 1  // 'S' key
    private let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]

    // MARK: - Private Properties

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // 二重発火デバウンス: 複数経路(NSEventモニタ + CGEventTap)から同一押下で
    // toggle()が連続呼び出しされても1回だけ効かせる
    private var lastToggleTime: CFAbsoluteTime = 0
    private let toggleDebounce: CFAbsoluteTime = 0.15

    // MARK: - Lifecycle

    private init() {
        setupMonitors()
    }

    deinit {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Setup

    private func setupMonitors() {
        // グローバルモニター（アプリ非フォーカス時）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // ローカルモニター（アプリフォーカス時）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    // MARK: - Event Handling

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(hotkeyModifiers) && event.keyCode == hotkeyKeyCode {
            toggle()
        }
    }

    /// リモートモード中のCGEventからホットキーを検出
    func checkHotkey(keycode: Int, modifiers: [String]) -> Bool {
        guard keycode == Int(hotkeyKeyCode) else { return false }
        return modifiers.contains("ctrl") && modifiers.contains("alt")
    }

    // MARK: - Toggle

    func toggle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // デバウンス: 同一押下が複数経路から来ても最初の1回だけ処理
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastToggleTime > self.toggleDebounce else {
                print("[HotkeyManager] Toggle debounced (duplicate within \(self.toggleDebounce)s)")
                return
            }
            self.lastToggleTime = now

            self.isSharingEnabled.toggle()

            if !self.isSharingEnabled {
                // 画面ロック: リモートモードを終了してローカルに復帰
                InputCapture.shared.exitRemoteMode()
                InputTransmitter.shared.stopTransmitting()
                ScreenManager.shared.returnControlToLocal()
            }

            print("[HotkeyManager] Sharing \(self.isSharingEnabled ? "enabled" : "disabled")")
        }
    }
}
