import Foundation
import Combine
import Cocoa
import UniformTypeIdentifiers

/// クリップボード同期
/// テキスト・画像・ファイル参照を他のデバイスと同期
class ClipboardSync: ObservableObject {
    static let shared = ClipboardSync()

    // MARK: - Published Properties

    @Published var isEnabled = true
    @Published var lastSyncTime: Date?
    @Published var syncedItemType: ClipboardFormat?

    // MARK: - Private Properties

    private var changeCount: Int = 0
    private var monitorTimer: Timer?
    private let pasteboard = NSPasteboard.general

    // MARK: - Constants

    private let maxImageSize = 10 * 1024 * 1024  // 10MB
    private let maxTextSize = 1024 * 1024  // 1MB

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Monitoring

    func startMonitoring() {
        changeCount = pasteboard.changeCount
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }
        print("Clipboard monitoring started")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        print("Clipboard monitoring stopped")
    }

    private func checkClipboardChange() {
        guard isEnabled else { return }

        let currentCount = pasteboard.changeCount

        if currentCount != changeCount {
            changeCount = currentCount
            handleClipboardChange()
        }
    }

    // MARK: - Clipboard Change Handling

    private func handleClipboardChange() {
        // ファイル参照をチェック
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            sendFileReferences(urls)
            return
        }

        // 画像をチェック
        if let image = NSImage(pasteboard: pasteboard) {
            sendImage(image)
            return
        }

        // テキストをチェック
        if let text = pasteboard.string(forType: .string) {
            sendText(text)
            return
        }
    }

    // MARK: - Sending

    private func sendText(_ text: String) {
        guard text.utf8.count <= maxTextSize else {
            print("Text too large for clipboard sync: \(text.utf8.count) bytes")
            return
        }
        let message = ClipboardMessage(format: .text, data: text)

        if let json = MessageEncoder.shared.encode(message) {
            DiscoveryService.shared.broadcastToAllPeers(json)
            syncedItemType = .text
            lastSyncTime = Date()
            print("Clipboard text synced: \(text.prefix(50))...")
        }
    }

    private func sendImage(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        // サイズチェック
        guard pngData.count <= maxImageSize else {
            print("Image too large for clipboard sync: \(pngData.count) bytes")
            return
        }

        let base64 = pngData.base64EncodedString()
        let message = ClipboardMessage(format: .image, data: base64)

        if let json = MessageEncoder.shared.encode(message) {
            DiscoveryService.shared.broadcastToAllPeers(json)
            syncedItemType = .image
            lastSyncTime = Date()
            print("Clipboard image synced: \(pngData.count) bytes")
        }
    }

    private func sendFileReferences(_ urls: [URL]) {
        let paths = urls.map { $0.path }.joined(separator: "\n")
        let message = ClipboardMessage(format: .fileReference, data: paths)

        if let json = MessageEncoder.shared.encode(message) {
            DiscoveryService.shared.broadcastToAllPeers(json)
            syncedItemType = .fileReference
            lastSyncTime = Date()
            print("Clipboard file references synced: \(urls.count) files")
        }
    }

    // MARK: - Receiving

    func receiveClipboard(format: ClipboardFormat, data: String) {
        guard isEnabled else { return }

        // 変更カウントを更新して自分の変更を無視
        changeCount = pasteboard.changeCount + 1

        switch format {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(data, forType: .string)
            print("Received clipboard text")

        case .image:
            if let imageData = Data(base64Encoded: data),
               let image = NSImage(data: imageData) {
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                print("Received clipboard image")
            }

        case .fileReference:
            // ファイル参照を受信した場合、ファイル転送をリクエスト
            let paths = data.components(separatedBy: "\n")
            print("Received file references, requesting transfer: \(paths)")
            requestFileTransfer(paths: paths)
        }

        changeCount = pasteboard.changeCount
        syncedItemType = format
        lastSyncTime = Date()
    }

    private func requestFileTransfer(paths: [String]) {
        // FileTransferにリクエストを送る
        for path in paths {
            FileTransfer.shared.requestFile(remotePath: path)
        }
    }
}

// MARK: - Clipboard History (Optional)

class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    @Published var items: [ClipboardItem] = []

    struct ClipboardItem: Identifiable {
        let id = UUID()
        let format: ClipboardFormat
        let preview: String
        let timestamp: Date
        let data: String
    }

    private let maxItems = 50

    private init() {}

    func addItem(format: ClipboardFormat, data: String) {
        let preview: String
        switch format {
        case .text:
            preview = String(data.prefix(100))
        case .image:
            preview = "[画像]"
        case .fileReference:
            let files = data.components(separatedBy: "\n")
            preview = files.first ?? "[ファイル]"
        }

        let item = ClipboardItem(format: format, preview: preview, timestamp: Date(), data: data)

        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            if self.items.count > self.maxItems {
                self.items.removeLast()
            }
        }
    }

    func applyItem(_ item: ClipboardItem) {
        ClipboardSync.shared.receiveClipboard(format: item.format, data: item.data)
    }

    func clearHistory() {
        items.removeAll()
    }
}
