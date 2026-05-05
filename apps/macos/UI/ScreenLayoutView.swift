import SwiftUI

/// 画面配置UI（macOS純正風）
/// ドラッグで自由に配置、オフセット調整可能
struct ScreenLayoutView: View {
    @EnvironmentObject var screenManager: ScreenManager
    @Environment(\.dismiss) private var dismiss

    // ビューのスケール（実際の画面サイズを縮小表示）
    private let scale: CGFloat = 0.06

    // ドラッグ状態
    @State private var draggedRemoteId: String?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            // Header
            headerView

            // 配置キャンバス
            layoutCanvas
                .frame(height: 400)
                .background(Color.black.opacity(0.05))
                .cornerRadius(12)
                .clipped()

            // 選択中の画面の設定
            selectedScreenSettings

            // 未配置デバイス
            unplacedDevicesSection

            Spacer()
                .frame(maxHeight: 20)

            // フッター
            footerView
        }
        .padding(20)
        .frame(width: 600, height: 650)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("ディスプレイ配置")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("ドラッグしてディスプレイの配置を調整")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Layout Canvas

    private var layoutCanvas: some View {
        GeometryReader { geometry in
            let canvasCenter = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                // ローカル画面を描画
                ForEach(screenManager.localScreens) { screen in
                    LocalScreenView(
                        screen: screen,
                        scale: scale,
                        canvasCenter: canvasCenter
                    )
                }

                // リモート画面を描画
                ForEach(screenManager.remoteScreens) { remote in
                    RemoteScreenView(
                        remote: remote,
                        localScreens: screenManager.localScreens,
                        scale: scale,
                        canvasCenter: canvasCenter,
                        isDragging: draggedRemoteId == remote.id,
                        dragOffset: draggedRemoteId == remote.id ? dragOffset : .zero
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                draggedRemoteId = remote.id
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                handleDragEnd(
                                    remoteId: remote.id,
                                    translation: value.translation,
                                    canvasCenter: canvasCenter
                                )
                                draggedRemoteId = nil
                                dragOffset = .zero
                            }
                    )
                }
            }
        }
    }

    // MARK: - Selected Screen Settings

    @State private var selectedRemoteId: String?

    private var selectedScreenSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedId = selectedRemoteId ?? screenManager.remoteScreens.first?.id,
               let remote = screenManager.remoteScreens.first(where: { $0.id == selectedId }) {

                HStack {
                    Text(remote.name)
                        .font(.headline)

                    Spacer()

                    Text("\(Int(remote.width)) × \(Int(remote.height))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // 接続先ディスプレイ選択
                HStack {
                    Text("接続先:")
                        .font(.subheadline)

                    Picker("", selection: Binding(
                        get: { remote.attachedTo ?? screenManager.localScreens.first(where: { $0.isMain })?.id ?? "" },
                        set: { newValue in
                            updateAttachment(remoteId: selectedId, attachedTo: newValue)
                        }
                    )) {
                        ForEach(screenManager.localScreens) { screen in
                            Text(screen.name).tag(screen.id)
                        }
                    }
                    .frame(width: 180)
                }

                // 接続辺の選択
                HStack {
                    Text("接続位置:")
                        .font(.subheadline)

                    Picker("", selection: Binding(
                        get: { remote.attachedEdge },
                        set: { newEdge in
                            updateEdge(remoteId: selectedId, edge: newEdge)
                        }
                    )) {
                        Text("左").tag(ScreenManager.RemoteScreen.Edge.left)
                        Text("右").tag(ScreenManager.RemoteScreen.Edge.right)
                        Text("上").tag(ScreenManager.RemoteScreen.Edge.top)
                        Text("下").tag(ScreenManager.RemoteScreen.Edge.bottom)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                // オフセット調整
                HStack {
                    Text("オフセット:")
                        .font(.subheadline)

                    let isHorizontalEdge = remote.attachedEdge == .left || remote.attachedEdge == .right

                    Slider(
                        value: Binding(
                            get: { isHorizontalEdge ? remote.offsetY : remote.offsetX },
                            set: { newValue in
                                updateOffset(remoteId: selectedId, isHorizontal: isHorizontalEdge, value: newValue)
                            }
                        ),
                        in: -500...500
                    )
                    .frame(width: 200)

                    Text("\(Int(isHorizontalEdge ? remote.offsetY : remote.offsetX)) px")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 60)
                }
            } else {
                Text("リモートディスプレイを選択してください")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Unplaced Devices

    private var unplacedDevicesSection: some View {
        let connectedPeers = DiscoveryService.shared.connectedPeers
        let placedIds = Set(screenManager.remoteScreens.map { $0.id })
        let unplaced = connectedPeers.filter { !placedIds.contains($0.id) }

        return Group {
            if !unplaced.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("未配置のデバイス")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        ForEach(unplaced) { peer in
                            Button(action: {
                                addRemoteScreen(peer: peer)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                    Text(peer.name)
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("リセット") {
                resetLayout()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("キャンセル") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("完了") {
                screenManager.saveLayout()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func handleDragEnd(remoteId: String, translation: CGSize, canvasCenter: CGPoint) {
        guard let index = screenManager.remoteScreens.firstIndex(where: { $0.id == remoteId }) else { return }

        let remote = screenManager.remoteScreens[index]

        // ドラッグ量をオフセットに変換
        let scaledDx = translation.width / scale
        let scaledDy = translation.height / scale

        // 現在のオフセットに加算
        let isHorizontalEdge = remote.attachedEdge == .left || remote.attachedEdge == .right
        let newOffset: CGFloat

        if isHorizontalEdge {
            newOffset = remote.offsetY + scaledDy
        } else {
            newOffset = remote.offsetX + scaledDx
        }

        DispatchQueue.main.async {
            screenManager.updateRemoteScreenPosition(
                deviceId: remoteId,
                attachedTo: remote.attachedTo,
                edge: remote.attachedEdge,
                offsetX: isHorizontalEdge ? remote.offsetX : newOffset,
                offsetY: isHorizontalEdge ? newOffset : remote.offsetY
            )
        }
    }

    private func updateAttachment(remoteId: String, attachedTo: String) {
        guard let remote = screenManager.remoteScreens.first(where: { $0.id == remoteId }) else { return }
        DispatchQueue.main.async {
            screenManager.updateRemoteScreenPosition(
                deviceId: remoteId,
                attachedTo: attachedTo,
                edge: remote.attachedEdge,
                offsetX: remote.offsetX,
                offsetY: remote.offsetY
            )
        }
    }

    private func updateEdge(remoteId: String, edge: ScreenManager.RemoteScreen.Edge) {
        guard let remote = screenManager.remoteScreens.first(where: { $0.id == remoteId }) else { return }
        DispatchQueue.main.async {
            screenManager.updateRemoteScreenPosition(
                deviceId: remoteId,
                attachedTo: remote.attachedTo,
                edge: edge,
                offsetX: 0,  // 辺を変更したらオフセットはリセット
                offsetY: 0
            )
        }
    }

    private func updateOffset(remoteId: String, isHorizontal: Bool, value: CGFloat) {
        guard let remote = screenManager.remoteScreens.first(where: { $0.id == remoteId }) else { return }
        DispatchQueue.main.async {
            screenManager.updateRemoteScreenPosition(
                deviceId: remoteId,
                attachedTo: remote.attachedTo,
                edge: remote.attachedEdge,
                offsetX: isHorizontal ? remote.offsetX : value,
                offsetY: isHorizontal ? value : remote.offsetY
            )
        }
    }

    private func addRemoteScreen(peer: DiscoveryService.Peer) {
        let width = CGFloat(peer.deviceInfo?.screenWidth ?? 1920)
        let height = CGFloat(peer.deviceInfo?.screenHeight ?? 1080)
        screenManager.addRemoteScreen(deviceId: peer.id, name: peer.name, width: width, height: height)
    }

    private func resetLayout() {
        for remote in screenManager.remoteScreens {
            screenManager.updateRemoteScreenPosition(
                deviceId: remote.id,
                attachedTo: screenManager.localScreens.first(where: { $0.isMain })?.id,
                edge: .right,
                offsetX: 0,
                offsetY: 0
            )
        }
    }
}

// MARK: - Local Screen View

struct LocalScreenView: View {
    let screen: ScreenManager.LocalScreen
    let scale: CGFloat
    let canvasCenter: CGPoint

    var body: some View {
        let scaledWidth = screen.width * scale
        let scaledHeight = screen.height * scale

        // ローカル画面はキャンバス中央に配置（frameは無視）
        let x = canvasCenter.x - scaledWidth / 2
        let y = canvasCenter.y - scaledHeight / 2

        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
            )
            .overlay(
                VStack(spacing: 2) {
                    if screen.isMain {
                        Image(systemName: "menubar.rectangle")
                            .font(.caption)
                    }
                    Text(screen.name)
                        .font(.caption2)
                        .lineLimit(1)
                    Text("\(Int(screen.width))×\(Int(screen.height))")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            )
            .frame(width: scaledWidth, height: scaledHeight)
            .position(x: x + scaledWidth / 2, y: y + scaledHeight / 2)
    }
}

// MARK: - Remote Screen View

struct RemoteScreenView: View {
    let remote: ScreenManager.RemoteScreen
    let localScreens: [ScreenManager.LocalScreen]
    let scale: CGFloat
    let canvasCenter: CGPoint
    let isDragging: Bool
    let dragOffset: CGSize

    var body: some View {
        let scaledWidth = remote.width * scale
        let scaledHeight = remote.height * scale

        // 接続先のローカル画面を取得
        let attachedScreen = localScreens.first(where: { $0.id == remote.attachedTo })
                          ?? localScreens.first(where: { $0.isMain })
                          ?? localScreens.first

        guard let localScreen = attachedScreen else {
            return AnyView(EmptyView())
        }

        let localScaledWidth = localScreen.width * scale
        let localScaledHeight = localScreen.height * scale

        // エッジに基づいて配置
        var x = canvasCenter.x - localScaledWidth / 2
        var y = canvasCenter.y - localScaledHeight / 2

        switch remote.attachedEdge {
        case .left:
            x -= scaledWidth
            y += remote.offsetY * scale
        case .right:
            x += localScaledWidth
            y += remote.offsetY * scale
        case .top:
            y -= scaledHeight
            x += remote.offsetX * scale
        case .bottom:
            y += localScaledHeight
            x += remote.offsetX * scale
        }

        x += dragOffset.width
        y += dragOffset.height

        return AnyView(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.orange.opacity(isDragging ? 0.4 : 0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.orange, lineWidth: isDragging ? 3 : 2)
                )
                .overlay(
                    VStack(spacing: 2) {
                        Image(systemName: "desktopcomputer")
                            .font(.caption)
                        Text(remote.name)
                            .font(.caption2)
                            .lineLimit(1)
                        Text("\(Int(remote.width))×\(Int(remote.height))")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                )
                .frame(width: scaledWidth, height: scaledHeight)
                .position(x: x + scaledWidth / 2, y: y + scaledHeight / 2)
                .shadow(color: isDragging ? .orange.opacity(0.5) : .clear, radius: 10)
        )
    }
}

// MARK: - Preview

#Preview {
    ScreenLayoutView()
        .environmentObject(ScreenManager.shared)
}
