import Foundation
import Combine
import Cocoa

/// ファイル転送
/// LocalSend互換REST APIでファイルを転送
class FileTransfer: ObservableObject {
    static let shared = FileTransfer()

    // MARK: - Published Properties

    @Published var activeTransfers: [Transfer] = []
    @Published var completedTransfers: [Transfer] = []

    // MARK: - Types

    struct Transfer: Identifiable {
        let id: String
        let fileName: String
        let fileSize: Int64
        var bytesTransferred: Int64 = 0
        var status: Status = .pending
        let direction: Direction
        let peerId: String
        let startTime: Date

        enum Status {
            case pending
            case transferring
            case completed
            case failed(Error)
            case cancelled
        }

        enum Direction {
            case upload
            case download
        }

        var progress: Double {
            guard fileSize > 0 else { return 0 }
            return Double(bytesTransferred) / Double(fileSize)
        }
    }

    // MARK: - Constants

    private let downloadDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let mouse2mouse = downloads.appendingPathComponent("Mouse2Mouse")
        try? FileManager.default.createDirectory(at: mouse2mouse, withIntermediateDirectories: true)
        return mouse2mouse
    }()

    // MARK: - Private Properties

    private var pendingRequests: [String: FileRequest] = [:]

    struct FileRequest {
        let remotePath: String
        let peerId: String
        let requestTime: Date
    }

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Send File

    /// ファイルを送信
    func sendFile(url: URL, to peerId: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("File not found: \(url.path)")
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let transferId = UUID().uuidString

        var transfer = Transfer(
            id: transferId,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            direction: .upload,
            peerId: peerId,
            startTime: Date()
        )

        activeTransfers.append(transfer)

        // LocalSend互換のprepare-upload APIを呼び出す
        prepareUpload(url: url, transferId: transferId, to: peerId)
    }

    private func prepareUpload(url: URL, transferId: String, to peerId: String) {
        guard let client = ConnectionManager.shared.activeConnections[peerId] else { return }

        // LocalSend prepare-upload リクエスト
        let prepareRequest: [String: Any] = [
            "info": [
                "alias": DiscoveryService.shared.localDeviceInfo?.hostname ?? "Mac",
                "version": "2.0",
                "deviceType": "desktop"
            ],
            "files": [
                [
                    "id": transferId,
                    "fileName": url.lastPathComponent,
                    "size": (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                    "fileType": url.pathExtension
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: prepareRequest),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let message = """
        {"type":"file_prepare","data":\(jsonString)}
        """

        client.send(message)
    }

    /// ファイル転送を続行
    func continueUpload(transferId: String, to peerId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }),
              let client = ConnectionManager.shared.activeConnections[peerId] else { return }

        activeTransfers[index].status = .transferring

        // TODO: 実際のファイルデータをチャンク送信
        // ここではWebSocket経由でBase64エンコードしたデータを送信
        // 本格的な実装ではHTTPS REST APIを使用
    }

    // MARK: - Receive File

    /// ファイルをリクエスト
    func requestFile(remotePath: String) {
        // 全ての接続先にリクエスト
        let request: [String: Any] = [
            "type": "file_request",
            "path": remotePath,
            "requestId": UUID().uuidString
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        ConnectionManager.shared.broadcast(jsonString)
    }

    /// ファイルを受信
    func receiveFile(fileName: String, data: Data, from peerId: String) {
        let destinationURL = downloadDirectory.appendingPathComponent(fileName)

        // 同名ファイルがある場合はリネーム
        let finalURL = uniqueFileURL(for: destinationURL)

        do {
            try data.write(to: finalURL)
            print("File saved: \(finalURL.path)")

            // 完了通知
            showNotification(title: "ファイル受信完了", body: fileName)

            // Finderで表示するか確認
            NSWorkspace.shared.activateFileViewerSelecting([finalURL])

        } catch {
            print("Failed to save file: \(error)")
        }
    }

    private func uniqueFileURL(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        while FileManager.default.fileExists(atPath: finalURL.path) {
            let newName = "\(name) (\(counter))"
            finalURL = directory.appendingPathComponent(newName).appendingPathExtension(ext)
            counter += 1
        }

        return finalURL
    }

    // MARK: - Transfer Management

    func cancelTransfer(id: String) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[index].status = .cancelled
            let transfer = activeTransfers.remove(at: index)
            completedTransfers.append(transfer)
        }
    }

    func clearCompletedTransfers() {
        completedTransfers.removeAll()
    }

    // MARK: - Progress Updates

    func updateProgress(transferId: String, bytesTransferred: Int64) {
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index].bytesTransferred = bytesTransferred

            // 完了チェック
            if activeTransfers[index].bytesTransferred >= activeTransfers[index].fileSize {
                activeTransfers[index].status = .completed
                let transfer = activeTransfers.remove(at: index)
                completedTransfers.insert(transfer, at: 0)
            }
        }
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Receive File (Protocol-based)

    private var receivingFiles: [String: ReceivingFile] = [:]

    private struct ReceivingFile {
        let transferId: String
        let fileName: String
        let fileSize: Int64
        let peerId: String
        var chunks: [Int: Data]
        var totalChunks: Int
    }

    /// 受信準備
    func prepareReceive(transferId: String, fileName: String, fileSize: Int64, from peerId: String) {
        let receiving = ReceivingFile(
            transferId: transferId,
            fileName: fileName,
            fileSize: fileSize,
            peerId: peerId,
            chunks: [:],
            totalChunks: 0
        )
        receivingFiles[transferId] = receiving

        let transfer = Transfer(
            id: transferId,
            fileName: fileName,
            fileSize: fileSize,
            direction: .download,
            peerId: peerId,
            startTime: Date()
        )
        DispatchQueue.main.async {
            self.activeTransfers.append(transfer)
        }
        print("[FileTransfer] Prepared to receive: \(fileName)")
    }

    /// チャンク受信
    func receiveChunk(transferId: String, chunkIndex: Int, totalChunks: Int, data: String) {
        guard var receiving = receivingFiles[transferId],
              let chunkData = Data(base64Encoded: data) else {
            return
        }

        receiving.chunks[chunkIndex] = chunkData
        receiving.totalChunks = totalChunks
        receivingFiles[transferId] = receiving

        // 進捗更新
        let bytesReceived = Int64(receiving.chunks.values.reduce(0) { $0 + $1.count })
        updateProgress(transferId: transferId, bytesTransferred: bytesReceived)

        // 全チャンク受信完了チェック
        if receiving.chunks.count == totalChunks {
            assembleFile(receiving)
        }
    }

    private func assembleFile(_ receiving: ReceivingFile) {
        // チャンクを順番に結合
        var fileData = Data()
        for i in 0..<receiving.totalChunks {
            if let chunk = receiving.chunks[i] {
                fileData.append(chunk)
            }
        }

        // ファイル保存
        receiveFile(fileName: receiving.fileName, data: fileData, from: receiving.peerId)
        receivingFiles.removeValue(forKey: receiving.transferId)

        // 完了メッセージ送信
        let completeMsg = FileCompleteMessage(transferId: receiving.transferId, success: true)
        if let json = MessageEncoder.shared.encode(completeMsg) {
            ConnectionManager.shared.send(json, to: receiving.peerId)
        }
    }

    /// 転送完了処理
    func completeTransfer(transferId: String, success: Bool) {
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            DispatchQueue.main.async {
                self.activeTransfers[index].status = success ? .completed : .failed(NSError(domain: "FileTransfer", code: -1))
                let transfer = self.activeTransfers.remove(at: index)
                self.completedTransfers.insert(transfer, at: 0)
            }
        }
    }

    /// ファイルリクエスト処理
    func handleFileRequest(path: String, requestId: String, to peerId: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("[FileTransfer] File not found: \(path)")
            return
        }

        // ファイルを送信
        sendFileWithChunks(url: url, transferId: requestId, to: peerId)
    }

    /// チャンク分割してファイル送信
    private func sendFileWithChunks(url: URL, transferId: String, to peerId: String) {
        guard let fileData = try? Data(contentsOf: url) else { return }

        let chunkSize = 64 * 1024  // 64KB chunks
        let totalChunks = (fileData.count + chunkSize - 1) / chunkSize

        // prepare送信
        let prepareMsg = FilePrepareMessage(
            transferId: transferId,
            fileName: url.lastPathComponent,
            fileSize: Int64(fileData.count),
            fileType: url.pathExtension
        )
        if let json = MessageEncoder.shared.encode(prepareMsg) {
            ConnectionManager.shared.send(json, to: peerId)
        }

        // チャンク送信
        for i in 0..<totalChunks {
            let start = i * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let chunk = fileData[start..<end]
            let base64 = chunk.base64EncodedString()

            let dataMsg = FileDataMessage(
                transferId: transferId,
                chunkIndex: i,
                totalChunks: totalChunks,
                data: base64
            )
            if let json = MessageEncoder.shared.encode(dataMsg) {
                ConnectionManager.shared.send(json, to: peerId)
            }
        }
    }
}

// MARK: - File Drop Handler

extension FileTransfer {
    /// ドラッグ&ドロップされたファイルを処理
    func handleFileDrop(urls: [URL], to peerId: String) {
        for url in urls {
            sendFile(url: url, to: peerId)
        }
    }

    /// 複数ファイルを一括送信
    func sendFiles(urls: [URL], to peerId: String) {
        for url in urls {
            sendFile(url: url, to: peerId)
        }
    }
}

// MARK: - LocalSend Compatibility

extension FileTransfer {
    /// LocalSend互換ポート
    static let localSendPort: UInt16 = 53317

    /// LocalSendデバイスとして広告
    func advertiseAsLocalSend() {
        // LocalSend互換のmDNSサービスを公開
        // _localsend._tcp で公開することで、LocalSendアプリからも見える
    }
}
