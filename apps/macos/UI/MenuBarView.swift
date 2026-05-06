import SwiftUI
import CoreGraphics

/// メニューバーポップオーバーUI
struct MenuBarView: View {
    @EnvironmentObject var discoveryService: DiscoveryService
    @EnvironmentObject var screenManager: ScreenManager
    @EnvironmentObject var hotkeyManager: HotkeyManager

    @State private var showingScreenLayout = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Connection Status
            statusSection

            Divider()

            // Discovered Peers
            peersSection

            Divider()

            // Actions
            actionsSection

            Divider()

            // Footer
            footerSection
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mouse2Mouse")
                    .font(.headline)
                Text(discoveryService.localDeviceInfo?.hostname ?? "Mac")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 接続状態インジケーター
            Circle()
                .fill(discoveryService.connectedPeers.isEmpty ? Color.orange : Color.green)
                .frame(width: 10, height: 10)
        }
        .padding()
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: discoveryService.isRunning ? "wifi" : "wifi.slash")
                    .foregroundColor(discoveryService.isRunning ? .green : .red)

                Text(discoveryService.isRunning ? "サービス実行中" : "サービス停止中")
                    .font(.subheadline)

                Spacer()

                if screenManager.isControllingRemote {
                    Label("リモート操作中", systemImage: "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            // 共有トグル（Barrierの「Scroll Lock」相当）
            sharingToggleSection

            // 親子役割切り替え
            roleToggleSection

            if let info = discoveryService.localDeviceInfo {
                HStack {
                    Text("画面: \(info.screenWidth) × \(info.screenHeight)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("ポート: 24800")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Sharing Toggle

    private var sharingToggleSection: some View {
        HStack {
            Image(systemName: hotkeyManager.isSharingEnabled ? "lock.open.fill" : "lock.fill")
                .foregroundColor(hotkeyManager.isSharingEnabled ? .green : .red)

            Text(hotkeyManager.isSharingEnabled ? "共有: ON" : "共有: OFF")
                .font(.subheadline)

            Spacer()

            Text("Ctrl+Opt+S")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)

            Toggle("", isOn: Binding(
                get: { hotkeyManager.isSharingEnabled },
                set: { newValue in
                    if newValue != hotkeyManager.isSharingEnabled {
                        hotkeyManager.toggle()
                    }
                }
            ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Role Toggle

    private var roleToggleSection: some View {
        HStack {
            Image(systemName: screenManager.deviceRole == .host ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill")
                .foregroundColor(screenManager.deviceRole == .host ? .blue : .orange)

            Text(screenManager.deviceRole == .host ? "操作元（Host）" : "操作先（Client）")
                .font(.subheadline)

            Spacer()

            Picker("", selection: Binding(
                get: { screenManager.deviceRole },
                set: { screenManager.setRole($0) }
            )) {
                Text("Host").tag(ScreenManager.DeviceRole.host)
                Text("Client").tag(ScreenManager.DeviceRole.client)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Peers List

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("デバイス")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(discoveryService.discoveredPeers.count) 発見")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if discoveryService.discoveredPeers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("デバイスを探しています...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ForEach(discoveryService.discoveredPeers) { peer in
                    PeerRow(peer: peer)
                }
            }

            // 接続中のデバイス
            if !discoveryService.connectedPeers.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("接続中")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(discoveryService.connectedPeers) { peer in
                    ConnectedPeerRow(peer: peer)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 8) {
            Button(action: { showingScreenLayout = true }) {
                Label("画面配置", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .sheet(isPresented: $showingScreenLayout) {
                ScreenLayoutView()
                    .environmentObject(screenManager)
            }

            HStack(spacing: 8) {
                Button(action: toggleService) {
                    Label(
                        discoveryService.isRunning ? "停止" : "開始",
                        systemImage: discoveryService.isRunning ? "stop.circle" : "play.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: openPreferences) {
                    Label("設定", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // 権限状態
            HStack(spacing: 4) {
                Image(systemName: PermissionManager.hasAllPermissions() ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundColor(PermissionManager.hasAllPermissions() ? .green : .orange)
                    .font(.caption)

                Text("権限")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onTapGesture {
                if !PermissionManager.hasAllPermissions() {
                    PermissionManager.openAccessibilitySettings()
                }
            }

            Spacer()

            Button("終了") {
                // カーソル固定を最初に解除してから全クリーンアップ
                CGAssociateMouseAndMouseCursorPosition(1)
                InputTransmitter.shared.stopTransmitting()
                InputCapture.shared.exitRemoteMode()
                InputCapture.shared.stopCapturing()
                DiscoveryService.shared.stop()
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func toggleService() {
        if discoveryService.isRunning {
            // カーソル固定を最初に解除（フェイルセーフ）
            CGAssociateMouseAndMouseCursorPosition(1)
            InputTransmitter.shared.stopTransmitting()
            InputCapture.shared.exitRemoteMode()
            InputCapture.shared.stopCapturing()
            screenManager.returnControlToLocal()
            discoveryService.stop()
        } else {
            discoveryService.start()
            if screenManager.deviceRole == .host {
                InputCapture.shared.startCapturing()
            }
        }
    }

    private func openPreferences() {
        // 設定ウィンドウを開く
    }
}

// MARK: - Peer Row

struct PeerRow: View {
    let peer: DiscoveryService.Peer
    @EnvironmentObject var discoveryService: DiscoveryService
    @EnvironmentObject var screenManager: ScreenManager
    @State private var showingRoleDialog = false

    var body: some View {
        HStack {
            Image(systemName: peer.deviceInfo?.deviceType == .ios ? "iphone" : "desktopcomputer")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.subheadline)

                if let info = peer.deviceInfo {
                    Text("\(info.screenWidth) × \(info.screenHeight)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(peer.isConnected ? "切断" : "接続") {
                if peer.isConnected {
                    discoveryService.disconnect(from: peer)
                } else {
                    showingRoleDialog = true
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingRoleDialog) {
            roleSelectionSheet
        }
    }

    private var roleSelectionSheet: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("接続設定")
                    .font(.headline)
                Text("\(peer.name) と接続します。\nこのMacの役割を選択してください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                Button {
                    screenManager.setRole(.host)
                    discoveryService.connect(to: peer)
                    showingRoleDialog = false
                } label: {
                    Label("このMacが操作元（Host）", systemImage: "cursorarrow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    screenManager.setRole(.client)
                    discoveryService.connect(to: peer)
                    showingRoleDialog = false
                } label: {
                    Label("このMacが操作先（Client）", systemImage: "display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button("キャンセル") {
                showingRoleDialog = false
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 4)
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Connected Peer Row

struct ConnectedPeerRow: View {
    let peer: DiscoveryService.Peer
    @EnvironmentObject var discoveryService: DiscoveryService
    @EnvironmentObject var screenManager: ScreenManager

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

            Text(peer.name)
                .font(.subheadline)

            Spacer()

            // 配置方向
            if let remote = screenManager.remoteScreens.first(where: { $0.id == peer.id }) {
                Text(positionLabel(remote.attachedEdge))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            Button("切断") {
                discoveryService.disconnect(from: peer)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }

    private func positionLabel(_ edge: ScreenManager.RemoteScreen.Edge) -> String {
        switch edge {
        case .left: return "左"
        case .right: return "右"
        case .top: return "上"
        case .bottom: return "下"
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView()
        .environmentObject(DiscoveryService.shared)
        .environmentObject(ScreenManager.shared)
        .environmentObject(HotkeyManager.shared)
}
