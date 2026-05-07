import Foundation
import Network

/// カーソル位置の高速UDPチャネル
/// WebSocket(TCP)ではパケットロス時にhead-of-line blockingで固まるため、
/// 損失許容のカーソル送信のみUDPで分離。
/// click/key/clipboard等の信頼性が必要なメッセージは引き続きWebSocketを使う。
final class UDPCursorChannel {
    static let shared = UDPCursorChannel()
    static let port: NWEndpoint.Port = 24801

    private static let queue = DispatchQueue(label: "Mouse2Mouse.UDPCursor", qos: .userInteractive)

    private var listener: NWListener?
    // ピアごとの送信用UDPコネクション（peerId → connection）
    private var sendConnections: [String: NWConnection] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters, on: Self.port)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleIncomingConnection(conn)
            }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[UDP] Cursor listener ready on port \(Self.port.rawValue)")
                case .failed(let error):
                    print("[UDP] Listener failed: \(error)")
                default:
                    break
                }
            }
            listener?.start(queue: Self.queue)
        } catch {
            print("[UDP] Failed to start listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in sendConnections.values { c.cancel() }
        sendConnections.removeAll()
    }

    // MARK: - Receive Path

    private func handleIncomingConnection(_ conn: NWConnection) {
        conn.start(queue: Self.queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.handleData(data)
            }
            if error == nil, conn.state != .cancelled {
                self?.receive(on: conn)
            }
        }
    }

    private func handleData(_ data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        if let msg = MessageEncoder.shared.decode(CursorMoveMessage.self, from: str) {
            InputCapture.shared.peerMessageReceived()
            InputReceiver.shared.handleCursorMove(x: msg.x, y: msg.y)
        }
    }

    // MARK: - Send Path

    /// ピアのUDPエンドポイントを登録（WebSocket接続確立時に呼ぶ）
    /// peerId → IPアドレスのマッピングをこちらが保持し、UDPコネクションを起動
    func setPeerEndpoint(peerId: String, host: NWEndpoint.Host) {
        sendConnections[peerId]?.cancel()
        let endpoint = NWEndpoint.hostPort(host: host, port: Self.port)
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[UDP] Send connection to \(peerId) failed: \(error)")
            }
        }
        conn.start(queue: Self.queue)
        sendConnections[peerId] = conn
        print("[UDP] Registered peer \(peerId) at \(host):\(Self.port.rawValue)")
    }

    func removePeer(peerId: String) {
        sendConnections[peerId]?.cancel()
        sendConnections.removeValue(forKey: peerId)
    }

    /// UDPでカーソルメッセージを送信
    /// パケット損失は許容（次のメッセージで上書きされる）
    func sendCursor(_ message: String, to peerId: String) {
        guard let conn = sendConnections[peerId],
              let data = message.data(using: .utf8) else { return }
        conn.send(content: data, completion: .idempotent)
    }
}
