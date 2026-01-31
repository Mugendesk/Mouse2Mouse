import Foundation
import Network

/// LocalSend互換ファイル転送サーバー
/// HTTPS REST APIでファイルを送受信
class FileTransferServer {
    static let shared = FileTransferServer()

    // MARK: - Properties

    private var listener: NWListener?
    private let port: UInt16 = 53317  // LocalSend標準ポート

    private var pendingUploads: [String: PendingUpload] = [:]

    struct PendingUpload {
        let fileId: String
        let fileName: String
        let fileSize: Int64
        var receivedData: Data
        let expectedSender: String
    }

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Server Control

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

            // LocalSend互換のBonjour広告
            listener?.service = NWListener.Service(
                name: DiscoveryService.shared.localDeviceInfo?.hostname ?? "Mac",
                type: "_localsend._tcp",
                txtRecord: NWTXTRecord([
                    "alias": DiscoveryService.shared.localDeviceInfo?.hostname ?? "Mac",
                    "version": "2.0",
                    "deviceType": "desktop",
                    "fingerprint": UUID().uuidString
                ])
            )

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("FileTransfer server ready on port \(self.port)")
                case .failed(let error):
                    print("FileTransfer server failed: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .main)

        } catch {
            print("Failed to start FileTransfer server: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let data = data, let request = String(data: data, encoding: .utf8) else { return }
            self?.handleRequest(request, connection: connection)
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else { return }

        let method = components[0]
        let path = components[1]

        // ルーティング
        switch (method, path) {
        case ("POST", "/api/localsend/v2/prepare-upload"):
            handlePrepareUpload(request, connection: connection)

        case ("POST", let p) where p.hasPrefix("/api/localsend/v2/upload"):
            handleUpload(request, connection: connection)

        case ("GET", let p) where p.hasPrefix("/api/localsend/v2/info"):
            handleInfo(connection: connection)

        default:
            sendResponse(statusCode: 404, body: "Not Found", connection: connection)
        }
    }

    // MARK: - API Handlers

    private func handleInfo(connection: NWConnection) {
        let info: [String: Any] = [
            "alias": DiscoveryService.shared.localDeviceInfo?.hostname ?? "Mac",
            "version": "2.0",
            "deviceType": "desktop",
            "fingerprint": UUID().uuidString,
            "download": false
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: info),
              let body = String(data: jsonData, encoding: .utf8) else { return }

        sendResponse(statusCode: 200, body: body, contentType: "application/json", connection: connection)
    }

    private func handlePrepareUpload(_ request: String, connection: NWConnection) {
        // JSONボディをパース
        guard let bodyStart = request.range(of: "\r\n\r\n")?.upperBound else { return }
        let body = String(request[bodyStart...])

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            sendResponse(statusCode: 400, body: "Invalid request", connection: connection)
            return
        }

        var acceptedFiles: [String: String] = [:]

        for file in files {
            guard let fileId = file["id"] as? String,
                  let fileName = file["fileName"] as? String,
                  let fileSize = file["size"] as? Int64 else { continue }

            // 転送を承認
            pendingUploads[fileId] = PendingUpload(
                fileId: fileId,
                fileName: fileName,
                fileSize: fileSize,
                receivedData: Data(),
                expectedSender: ""
            )

            acceptedFiles[fileId] = "finished"  // トークンとして使用
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: acceptedFiles),
              let responseBody = String(data: responseData, encoding: .utf8) else { return }

        sendResponse(statusCode: 200, body: responseBody, contentType: "application/json", connection: connection)
    }

    private func handleUpload(_ request: String, connection: NWConnection) {
        // URLからfileIdを抽出
        let components = request.components(separatedBy: " ")
        guard components.count >= 2 else { return }

        let path = components[1]
        guard let fileIdStart = path.range(of: "fileId=")?.upperBound else {
            sendResponse(statusCode: 400, body: "Missing fileId", connection: connection)
            return
        }

        var fileId = String(path[fileIdStart...])
        if let ampersandIndex = fileId.firstIndex(of: "&") {
            fileId = String(fileId[..<ampersandIndex])
        }

        // ファイルデータを受信
        connection.receive(minimumIncompleteLength: 1, maximumLength: 10 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data else { return }

            if var pending = self.pendingUploads[fileId] {
                pending.receivedData.append(data)

                if isComplete || pending.receivedData.count >= pending.fileSize {
                    // 転送完了
                    FileTransfer.shared.receiveFile(
                        fileName: pending.fileName,
                        data: pending.receivedData,
                        from: pending.expectedSender
                    )
                    self.pendingUploads.removeValue(forKey: fileId)
                    self.sendResponse(statusCode: 200, body: "OK", connection: connection)
                } else {
                    self.pendingUploads[fileId] = pending
                }
            } else {
                self.sendResponse(statusCode: 404, body: "Unknown fileId", connection: connection)
            }
        }
    }

    // MARK: - Response

    private func sendResponse(statusCode: Int, body: String, contentType: String = "text/plain", connection: NWConnection) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
