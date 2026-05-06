import Foundation
import CoreGraphics

/// 入力イベント送信
/// ローカルの入力イベントをリモートデバイスに送信
class InputTransmitter {
    static let shared = InputTransmitter()

    private let encoder = MessageEncoder.shared
    private var isTransmitting = false
    private var targetPeerId: String?
    private var heartbeatTimer: DispatchSourceTimer?

    // カーソル送信スロットル（360Hz上限、trailing-edge flush）
    // 高DPI/高ポーリングレートマウス(4kHz/8kHz)でもCPU・帯域が飽和しない範囲で
    // 知覚的ラグを最小化する妥協点
    private var lastCursorSendTime: CFAbsoluteTime = 0
    private let cursorSendInterval: CFAbsoluteTime = 1.0 / 360.0
    private var pendingCursorPosition: CGPoint?
    private var cursorFlushScheduled = false

    var currentTargetPeerId: String? { targetPeerId }

    private init() {
        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        let inputCapture = InputCapture.shared

        inputCapture.onCursorMove = { [weak self] position in
            self?.sendCursorMove(position)
        }

        inputCapture.onMouseButton = { [weak self] button, isDown, clickCount in
            self?.sendMouseButton(button: button, isDown: isDown, clickCount: clickCount)
        }

        inputCapture.onScroll = { [weak self] dx, dy in
            self?.sendScroll(dx: Double(dx), dy: Double(dy))
        }

        inputCapture.onKeyEvent = { [weak self] keycode, isDown, modifiers in
            self?.sendKeyEvent(keycode: keycode, isDown: isDown, modifiers: modifiers)
        }

        inputCapture.onEdgeReached = { [weak self] direction, position in
            self?.handleEdgeReached(direction: direction, position: position)
        }
    }

    // MARK: - Transmission Control

    func startTransmitting(to peerId: String, entryPoint: CGPoint = .zero) {
        targetPeerId = peerId
        isTransmitting = true
        InputCapture.shared.enterRemoteMode(entryPoint: entryPoint)
        startHeartbeat()
        print("Started transmitting to \(peerId) at entry \(entryPoint)")
    }

    func stopTransmitting() {
        stopHeartbeat()
        isTransmitting = false
        targetPeerId = nil
        pendingCursorPosition = nil
        cursorFlushScheduled = false
        InputCapture.shared.exitRemoteMode()
        print("Stopped transmitting")
    }

    // MARK: - Heartbeat (ピア生存確認)

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTransmitting, let peerId = self.targetPeerId else { return }
            let ping = "{\"type\":\"ping\",\"timestamp\":\(Date().timeIntervalSince1970)}"
            DiscoveryService.shared.send(ping, to: peerId, encrypt: false)
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Sending Messages

    private func sendCursorMove(_ position: CGPoint) {
        guard isTransmitting, targetPeerId != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastCursorSendTime

        if elapsed >= cursorSendInterval {
            // すぐに送信
            lastCursorSendTime = now
            pendingCursorPosition = nil
            cursorFlushScheduled = false
            actuallySendCursor(position)
        } else {
            // レート制限中: 最新位置を保持し、間隔到達時にflush
            pendingCursorPosition = position
            if !cursorFlushScheduled {
                cursorFlushScheduled = true
                let delay = cursorSendInterval - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.flushPendingCursor()
                }
            }
        }
    }

    private func flushPendingCursor() {
        cursorFlushScheduled = false
        guard isTransmitting, let pending = pendingCursorPosition else { return }
        pendingCursorPosition = nil
        lastCursorSendTime = CFAbsoluteTimeGetCurrent()
        actuallySendCursor(pending)
    }

    private func actuallySendCursor(_ position: CGPoint) {
        guard let peerId = targetPeerId else { return }

        let peerUnion = ScreenManager.shared.peerUnion(peerId: peerId)
        guard peerUnion.width > 0, peerUnion.height > 0 else { return }

        let normalizedX = (position.x - peerUnion.minX) / peerUnion.width
        let normalizedY = (position.y - peerUnion.minY) / peerUnion.height

        let message = CursorMoveMessage(x: Double(normalizedX), y: Double(normalizedY))
        if let json = encoder.encode(message) {
            sendToTarget(json)
        }
    }

    private func sendMouseButton(button: Int, isDown: Bool, clickCount: Int = 1) {
        guard isTransmitting else { return }

        let message = MouseButtonMessage(button: button, state: isDown ? .down : .up, clickCount: clickCount)

        if let json = encoder.encode(message) {
            sendToTarget(json)
        }
    }

    private func sendScroll(dx: Double, dy: Double) {
        guard isTransmitting else { return }

        let message = ScrollMessage(dx: dx, dy: dy)

        if let json = encoder.encode(message) {
            sendToTarget(json)
        }
    }

    private func sendKeyEvent(keycode: Int, isDown: Bool, modifiers: [String]) {
        guard isTransmitting else { return }

        let message = KeyMessage(keycode: keycode, state: isDown ? .down : .up, modifiers: modifiers)

        if let json = encoder.encode(message) {
            sendToTarget(json)
        }
    }

    // MARK: - Edge Handling

    private func handleEdgeReached(direction: ScreenManager.EdgeDirection, position: CGPoint) {
        // Clientモードの場合は画面遷移しない
        guard ScreenManager.shared.deviceRole == .host else {
            print("[InputTransmitter] Ignoring edge - device is in client mode")
            return
        }

        // 共有ロック中はエッジ遷移しない（Barrierの「Scroll Lock」相当）
        guard HotkeyManager.shared.isSharingEnabled else {
            print("[InputTransmitter] Sharing disabled (locked to screen)")
            return
        }

        print("[InputTransmitter] handleEdgeReached: direction=\(direction), position=\(position)")

        // 明示的に EdgeHit? 型を指定してオーバーロードを解決
        guard let edgeHit: ScreenManager.EdgeHit = ScreenManager.shared.checkEdgeReached(cursorPosition: position) else {
            print("[InputTransmitter] No edge hit found")
            print("[InputTransmitter] remoteScreens count: \(ScreenManager.shared.remoteScreens.count)")
            for screen in ScreenManager.shared.remoteScreens {
                print("[InputTransmitter]   - \(screen.id): edge=\(screen.attachedEdge), attachedTo=\(screen.attachedTo ?? "nil")")
            }
            return
        }
        print("[InputTransmitter] Edge hit: target=\(edgeHit.targetDevice.id), entry=\(edgeHit.entryPosition)")

        let targetScreen = edgeHit.targetDevice
        let peerId = targetScreen.peerId

        // 制御権を移譲（entryPositionはピアunion座標、unionサイズで正規化）
        let peerUnion = ScreenManager.shared.peerUnion(peerId: peerId)
        guard peerUnion.width > 0, peerUnion.height > 0 else {
            print("[InputTransmitter] Empty peer union for \(peerId)")
            return
        }
        let entryX = Double((edgeHit.entryPosition.x - peerUnion.minX) / peerUnion.width)
        let entryY = Double((edgeHit.entryPosition.y - peerUnion.minY) / peerUnion.height)
        let message = ControlTransferMessage(to: peerId, entryX: entryX, entryY: entryY)

        if let json = encoder.encode(message) {
            DiscoveryService.shared.send(json, to: peerId)
        }

        // リモートモードに入る（エントリーポイントはピアunion座標）
        startTransmitting(to: peerId, entryPoint: edgeHit.entryPosition)
        ScreenManager.shared.transferControlTo(deviceId: peerId, sourceScreenId: edgeHit.sourceScreenId)
    }

    // MARK: - Helpers

    private func sendToTarget(_ message: String) {
        if let peerId = targetPeerId {
            DiscoveryService.shared.send(message, to: peerId)
        }
    }

}
