import Foundation
import Network

/// WebSocketサーバー
/// 複数クライアントからの接続を管理し、メッセージの送受信を行う
class WebSocketServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [String: WebSocketConnection] = [:]

    /// I/O専用のバックグラウンドキュー（main thread を飽和させない）
    /// userInteractive QoS でカーソル遅延を最小化
    static let ioQueue = DispatchQueue(label: "Mouse2Mouse.WebSocketServer.io", qos: .userInteractive)

    // Callbacks
    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: ((String) -> Void)?
    var onMessageReceived: ((String, String) -> Void)?  // clientId, message

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - Server Control

    func start(bonjourName: String? = nil, txtRecord: NWTXTRecord? = nil) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Nagleアルゴリズム無効化（小さいパケットの送信遅延を回避）
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }

        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

            // Bonjour広告を設定
            if let name = bonjourName {
                listener?.service = NWListener.Service(
                    name: name,
                    type: "_mugendesk._tcp",
                    domain: "local.",
                    txtRecord: txtRecord ?? NWTXTRecord([:])
                )
                print("[WebSocketServer] Bonjour service: \(name)._mugendesk._tcp.local.")
            }

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("WebSocket server ready on port \(self?.port ?? 0)")
                case .failed(let error):
                    print("WebSocket server failed: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: WebSocketServer.ioQueue)

        } catch {
            print("Failed to start WebSocket server: \(error)")
        }
    }

    func stop() {
        stop(completion: nil)
    }

    /// completionは listener の .cancelled state 観測後に呼ばれる。
    /// port再bind前に呼ぶと EADDRINUSE になるので、再起動時は必ず completion を待つ。
    func stop(completion: (() -> Void)?) {
        connections.values.forEach { $0.close() }
        connections.removeAll()

        let toCancel = listener
        listener = nil

        guard let toCancel = toCancel else {
            completion?()
            print("WebSocket server stopped (no listener)")
            return
        }

        toCancel.stateUpdateHandler = { state in
            if case .cancelled = state {
                print("WebSocket server stopped (cancelled)")
                completion?()
            }
        }
        toCancel.cancel()
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let clientId = UUID().uuidString
        let connection = WebSocketConnection(connection: nwConnection, clientId: clientId)

        connection.onMessage = { [weak self] message in
            self?.onMessageReceived?(clientId, message)
        }

        connection.onClose = { [weak self] in
            self?.connections.removeValue(forKey: clientId)
            self?.onClientDisconnected?(clientId)
        }

        connections[clientId] = connection
        connection.start()

        onClientConnected?(clientId)
        print("Client connected: \(clientId)")
    }

    // MARK: - Message Sending

    func broadcast(_ message: String) {
        for connection in connections.values {
            connection.send(message)
        }
    }

    func send(_ message: String, to clientId: String) {
        if let conn = connections[clientId] {
            conn.send(message)  // 1000Hzで呼ばれるのでログ出さない
        }
    }

    /// 指定クライアントを切断（ペアリング拒否時等）
    func disconnect(clientId: String) {
        if let conn = connections[clientId] {
            conn.close()
            connections.removeValue(forKey: clientId)
            print("[WebSocketServer] Disconnected client: \(clientId)")
        }
    }

    func remapClient(from oldId: String, to newId: String) {
        if let connection = connections[oldId] {
            connections.removeValue(forKey: oldId)
            connections[newId] = connection
            print("[WebSocketServer] Remapped client: \(oldId) -> \(newId)")
        }
    }

    /// 指定クライアントの送信元IPを取得（UDPチャネル登録用）
    func remoteHost(for clientId: String) -> NWEndpoint.Host? {
        return connections[clientId]?.remoteHost
    }

    // MARK: - Connection Info

    var connectedClientCount: Int {
        return connections.count
    }

    var connectedClientIds: [String] {
        return Array(connections.keys)
    }
}

// MARK: - WebSocket Connection

class WebSocketConnection {
    private let connection: NWConnection
    let clientId: String

    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var isHandshakeComplete = false
    private var frameBuffer = Data()
    private let maxFrameSize = 10 * 1024 * 1024  // 10MB
    private let maxBufferSize = 20 * 1024 * 1024  // 20MB

    /// 送信元IPアドレス（UDPチャネルへのピア登録に使う）
    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.endpoint {
            return host
        }
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint ?? .unix(path: "") {
            return host
        }
        return nil
    }

    init(connection: NWConnection, clientId: String) {
        self.connection = connection
        self.clientId = clientId
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }

        // バックグラウンドキューでI/O。CGEvent等メイン要件はコールバック先で個別dispatchする
        connection.start(queue: WebSocketServer.ioQueue)
    }

    func close() {
        // Close frameを送信してから切断
        if isHandshakeComplete {
            var frame = Data()
            frame.append(0x88)  // Close frame
            frame.append(0x00)  // No payload
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        } else {
            connection.cancel()
        }
    }

    func send(_ message: String) {
        guard isHandshakeComplete else { return }

        let frame = createWebSocketFrame(text: message)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            }
        })
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleReceivedData(data)
            }

            if isComplete || error != nil {
                self?.onClose?()
                return
            }

            self?.receive()
        }
    }

    private func handleReceivedData(_ data: Data) {
        if !isHandshakeComplete {
            handleHandshake(data)
        } else {
            handleWebSocketFrame(data)
        }
    }

    // MARK: - WebSocket Handshake

    private func handleHandshake(_ data: Data) {
        guard let request = String(data: data, encoding: .utf8) else { return }

        // WebSocket キーを抽出
        let lines = request.components(separatedBy: "\r\n")
        var webSocketKey: String?

        for line in lines {
            if line.lowercased().hasPrefix("sec-websocket-key:") {
                webSocketKey = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard let key = webSocketKey else {
            close()
            return
        }

        // Accept キーを生成
        let acceptKey = generateAcceptKey(from: key)

        // ハンドシェイクレスポンスを送信
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r

        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if error == nil {
                self?.isHandshakeComplete = true
                print("WebSocket handshake complete for \(self?.clientId ?? "")")
            }
        })
    }

    private func generateAcceptKey(from key: String) -> String {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicString

        guard let data = combined.data(using: .utf8) else { return "" }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &hash)
        }

        return Data(hash).base64EncodedString()
    }

    // MARK: - WebSocket Frame Handling

    private func handleWebSocketFrame(_ data: Data) {
        frameBuffer.append(data)

        // バッファサイズ上限チェック（メモリ枯渇防止）
        guard frameBuffer.count <= maxBufferSize else {
            print("[WebSocket] Buffer overflow (\(frameBuffer.count) bytes), closing connection")
            close()
            return
        }

        while frameBuffer.count >= 2 {
            // 安全にバイト配列として取得
            let bufferBytes = [UInt8](frameBuffer)
            guard bufferBytes.count >= 2 else { return }

            let byte0 = bufferBytes[0]
            let byte1 = bufferBytes[1]

            let opcode = byte0 & 0x0F
            let isMasked = (byte1 & 0x80) != 0
            var payloadLength = Int(byte1 & 0x7F)
            var offset = 2

            // 拡張ペイロード長
            if payloadLength == 126 {
                guard bufferBytes.count >= 4 else { return }
                payloadLength = Int(bufferBytes[2]) << 8 | Int(bufferBytes[3])
                offset = 4
            } else if payloadLength == 127 {
                guard bufferBytes.count >= 10 else { return }
                payloadLength = 0
                for i in 0..<8 {
                    payloadLength = payloadLength << 8 | Int(bufferBytes[2 + i])
                }
                offset = 10
            }

            // フレームサイズ上限チェック
            guard payloadLength <= maxFrameSize else {
                print("[WebSocket] Frame too large: \(payloadLength) bytes, closing connection")
                close()
                return
            }

            // マスクキー
            var maskKey: [UInt8] = []
            if isMasked {
                guard bufferBytes.count >= offset + 4 else { return }
                maskKey = Array(bufferBytes[offset..<offset + 4])
                offset += 4
            }

            // ペイロード
            guard bufferBytes.count >= offset + payloadLength else { return }
            var payload = Array(bufferBytes[offset..<offset + payloadLength])

            // マスク解除
            if isMasked {
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i % 4]
                }
            }

            // フレームを処理
            switch opcode {
            case 0x1:  // Text frame
                if let text = String(bytes: payload, encoding: .utf8) {
                    onMessage?(text)
                }

            case 0x8:  // Close frame
                close()
                return

            case 0x9:  // Ping
                sendPong(payload: Data(payload))

            case 0xA:  // Pong
                break

            default:
                break
            }

            // 処理済みデータを削除
            frameBuffer.removeFirst(offset + payloadLength)
        }
    }

    private func sendPong(payload: Data) {
        var frame = Data()
        frame.append(0x8A)  // Pong opcode
        frame.append(UInt8(payload.count))
        frame.append(payload)

        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func createWebSocketFrame(text: String) -> Data {
        guard let payload = text.data(using: .utf8) else { return Data() }

        var frame = Data()
        frame.append(0x81)  // Text frame, FIN

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}

// SHA1用のインポート
import CommonCrypto
