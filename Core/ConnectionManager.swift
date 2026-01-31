import Foundation
import Combine

/// 接続管理（自動再接続機能付き）
/// Phase 2: 安定化のための接続管理拡張
class ReconnectionManager: ObservableObject {
    static let shared = ReconnectionManager()

    // MARK: - Published Properties

    @Published var connectionStates: [String: ConnectionState] = [:]

    // MARK: - Types

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Constants

    private let maxReconnectAttempts = 5
    private let baseReconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0

    // MARK: - Private Properties

    private var reconnectTimers: [String: Timer] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    private init() {
        setupObservers()
    }

    // MARK: - Setup

    private func setupObservers() {
        // 接続状態の監視
        ConnectionManager.shared.$activeConnections
            .sink { [weak self] connections in
                self?.updateConnectionStates(connections)
            }
            .store(in: &cancellables)
    }

    private func updateConnectionStates(_ connections: [String: WebSocketClient]) {
        for (peerId, client) in connections {
            if client.isConnected {
                connectionStates[peerId] = .connected
                cancelReconnect(for: peerId)
            }
        }
    }

    // MARK: - Auto Reconnect

    func enableAutoReconnect(for peerId: String, peer: DiscoveryService.Peer) {
        // 切断時のコールバックを設定
        ConnectionManager.shared.activeConnections[peerId]?.onDisconnected = { [weak self] error in
            self?.handleDisconnection(peerId: peerId, peer: peer, error: error)
        }
    }

    private func handleDisconnection(peerId: String, peer: DiscoveryService.Peer, error: Error?) {
        guard reconnectAttempts[peerId] ?? 0 < maxReconnectAttempts else {
            print("Max reconnect attempts reached for \(peer.name)")
            connectionStates[peerId] = .disconnected
            return
        }

        let attempt = (reconnectAttempts[peerId] ?? 0) + 1
        reconnectAttempts[peerId] = attempt
        connectionStates[peerId] = .reconnecting(attempt: attempt)

        // 指数バックオフで再接続を試みる
        let delay = min(baseReconnectDelay * pow(2, Double(attempt - 1)), maxReconnectDelay)

        print("Scheduling reconnect to \(peer.name) in \(delay)s (attempt \(attempt))")

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptReconnect(peerId: peerId, peer: peer)
        }
        reconnectTimers[peerId] = timer
    }

    private func attemptReconnect(peerId: String, peer: DiscoveryService.Peer) {
        connectionStates[peerId] = .connecting
        ConnectionManager.shared.connect(to: peer)
    }

    func cancelReconnect(for peerId: String) {
        reconnectTimers[peerId]?.invalidate()
        reconnectTimers.removeValue(forKey: peerId)
        reconnectAttempts.removeValue(forKey: peerId)
    }

    func cancelAllReconnects() {
        for timer in reconnectTimers.values {
            timer.invalidate()
        }
        reconnectTimers.removeAll()
        reconnectAttempts.removeAll()
    }

    // MARK: - Manual Reconnect

    func reconnect(peerId: String, peer: DiscoveryService.Peer) {
        cancelReconnect(for: peerId)
        reconnectAttempts[peerId] = 0
        connectionStates[peerId] = .connecting
        ConnectionManager.shared.connect(to: peer)
    }

    // MARK: - Connection Health

    func startHealthCheck(for peerId: String, interval: TimeInterval = 30) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard let client = ConnectionManager.shared.activeConnections[peerId],
                  client.isConnected else {
                return
            }

            // Ping送信
            let pingMessage = """
            {"type":"ping","timestamp":\(Date().timeIntervalSince1970)}
            """
            client.send(pingMessage)
        }
    }
}

// MARK: - Network Monitor

import Network

/// ネットワーク状態監視
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .unknown

    enum ConnectionType {
        case wifi
        case ethernet
        case cellular
        case unknown
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        startMonitoring()
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied

                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self?.connectionType = .ethernet
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = .cellular
                } else {
                    self?.connectionType = .unknown
                }
            }
        }

        monitor.start(queue: queue)
    }

    func stopMonitoring() {
        monitor.cancel()
    }
}
