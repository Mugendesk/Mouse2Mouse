import SwiftUI
import AppKit

/// 信頼済みデバイス（ペアリング済み）の一覧と解除UI
struct PairedDevicesView: View {
    @ObservedObject var pairingManager = PairingManager.shared
    @State private var confirmingUnpairAll = false

    fileprivate static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "person.2.badge.key.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("信頼済みデバイス")
                    .font(.headline)
                Text("一度許可したデバイスは自動的に承認されます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if pairingManager.pairedDevices.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "lock.open")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("信頼済みデバイスはありません")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("他のデバイスから接続を許可するとここに表示されます")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pairingManager.pairedDevices) { device in
                        PairedDeviceRow(device: device)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(pairingManager.pairedDevices.count) 件")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if !pairingManager.pairedDevices.isEmpty {
                Button("全て解除") {
                    confirmingUnpairAll = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .confirmationDialog(
                    "全ての信頼を解除しますか？",
                    isPresented: $confirmingUnpairAll,
                    titleVisibility: .visible
                ) {
                    Button("全て解除", role: .destructive) {
                        pairingManager.unpairAll()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("次回以降、これらのデバイスから接続する際は再度承認が必要になります。")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

private struct PairedDeviceRow: View {
    let device: PairingManager.PairedDevice
    @ObservedObject var pairingManager = PairingManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.hostname)
                    .font(.subheadline)
                Text("ペアリング: \(formatted(device.pairedAt))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("解除") {
                pairingManager.unpair(deviceId: device.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func formatted(_ date: Date) -> String {
        PairedDevicesView.dateFormatter.string(from: date)
    }
}

// MARK: - Window Controller

/// 信頼済みデバイス一覧を独立NSWindowで開く
final class PairedDevicesWindowController {
    static var shared: NSWindow?

    static func show() {
        if let existing = shared {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PairedDevicesView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "信頼済みデバイス"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        window.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            shared = nil
        }

        shared = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Preview

#Preview {
    PairedDevicesView()
}
