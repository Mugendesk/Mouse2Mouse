import SwiftUI
import UniformTypeIdentifiers

/// ファイル転送UI
struct FileTransferView: View {
    @ObservedObject var fileTransfer = FileTransfer.shared
    @State private var isDragging = false
    @State private var selectedPeerId: String?

    let connectedPeers: [DiscoveryService.Peer]

    var body: some View {
        VStack(spacing: 16) {
            // Header
            headerView

            // Drop Zone
            dropZone

            // Active Transfers
            if !fileTransfer.activeTransfers.isEmpty {
                activeTransfersView
            }

            // Completed Transfers
            if !fileTransfer.completedTransfers.isEmpty {
                completedTransfersView
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.title)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text("ファイル転送")
                    .font(.headline)
                Text("ドラッグ&ドロップでファイルを送信")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 送信先選択
            if !connectedPeers.isEmpty {
                Picker("送信先", selection: $selectedPeerId) {
                    Text("選択...").tag(nil as String?)
                    ForEach(connectedPeers) { peer in
                        Text(peer.name).tag(peer.id as String?)
                    }
                }
                .frame(width: 150)
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .foregroundColor(isDragging ? .accentColor : .secondary.opacity(0.3))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
                )

            VStack(spacing: 12) {
                Image(systemName: isDragging ? "arrow.down.circle.fill" : "doc.fill.badge.plus")
                    .font(.system(size: 40))
                    .foregroundColor(isDragging ? .accentColor : .secondary)

                Text(isDragging ? "ドロップして送信" : "ファイルをドラッグ")
                    .font(.headline)
                    .foregroundColor(isDragging ? .accentColor : .secondary)

                if selectedPeerId == nil && !connectedPeers.isEmpty {
                    Text("送信先を選択してください")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(height: 150)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Active Transfers

    private var activeTransfersView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("転送中")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(fileTransfer.activeTransfers) { transfer in
                TransferRow(transfer: transfer, showProgress: true)
            }
        }
    }

    // MARK: - Completed Transfers

    private var completedTransfersView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("完了")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Button("クリア") {
                    fileTransfer.clearCompletedTransfers()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
            }

            ForEach(fileTransfer.completedTransfers.prefix(5)) { transfer in
                TransferRow(transfer: transfer, showProgress: false)
            }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let peerId = selectedPeerId else { return false }

        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            self.fileTransfer.sendFile(url: url, to: peerId)
                        }
                    }
                }
            }
        }

        return true
    }
}

// MARK: - Transfer Row

struct TransferRow: View {
    let transfer: FileTransfer.Transfer
    let showProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            // File Icon
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(.secondary)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if showProgress {
                        Text("•")
                            .foregroundColor(.secondary)

                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(statusColor)
                    }
                }
            }

            Spacer()

            // Progress or Status
            if showProgress {
                if case .transferring = transfer.status {
                    ProgressView(value: transfer.progress)
                        .frame(width: 60)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            // Direction
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var fileIcon: String {
        let ext = (transfer.fileName as NSString).pathExtension.lowercased()

        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic":
            return "photo"
        case "mp4", "mov", "avi":
            return "film"
        case "mp3", "m4a", "wav":
            return "music.note"
        case "pdf":
            return "doc.fill"
        case "zip", "tar", "gz":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private var statusText: String {
        switch transfer.status {
        case .pending:
            return "待機中"
        case .transferring:
            return "\(Int(transfer.progress * 100))%"
        case .completed:
            return "完了"
        case .failed:
            return "失敗"
        case .cancelled:
            return "キャンセル"
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .pending:
            return .secondary
        case .transferring:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var statusIcon: String {
        switch transfer.status {
        case .pending:
            return "clock"
        case .transferring:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "slash.circle"
        }
    }

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - Preview

#Preview {
    FileTransferView(connectedPeers: [])
}
