import Foundation
import CoreGraphics

/// 入力イベント送信
/// ローカルの入力イベントをリモートデバイスに送信
class InputTransmitter {
    static let shared = InputTransmitter()

    private let encoder = MessageEncoder.shared
    private var isTransmitting = false
    private var targetPeerId: String?

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

        inputCapture.onMouseButton = { [weak self] button, isDown in
            self?.sendMouseButton(button: button, isDown: isDown)
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
        print("Started transmitting to \(peerId) at entry \(entryPoint)")
    }

    func stopTransmitting() {
        isTransmitting = false
        targetPeerId = nil
        InputCapture.shared.exitRemoteMode()
        print("Stopped transmitting")
    }

    // MARK: - Sending Messages

    private func sendCursorMove(_ position: CGPoint) {
        guard isTransmitting, let peerId = targetPeerId else {
            print("[InputTransmitter] Not transmitting or no target")
            return
        }

        // リモート画面の座標に変換
        guard let remoteScreen = ScreenManager.shared.remoteScreens.first(where: { $0.id == peerId }) else {
            print("[InputTransmitter] Remote screen not found for \(peerId)")
            print("[InputTransmitter] Available screens: \(ScreenManager.shared.remoteScreens.map { $0.id })")
            return
        }

        // 正規化座標を計算（0.0-1.0の範囲）
        let normalizedX = position.x / remoteScreen.width
        let normalizedY = position.y / remoteScreen.height

        let message = CursorMoveMessage(x: Double(normalizedX), y: Double(normalizedY))

        if let json = encoder.encode(message) {
            sendToTarget(json)
            // 10回に1回だけログ出力（パフォーマンス対策）
            if Int.random(in: 0..<10) == 0 {
                print("[InputTransmitter] Sending cursor: (\(String(format: "%.2f", normalizedX)), \(String(format: "%.2f", normalizedY)))")
            }
        }
    }

    private func sendMouseButton(button: Int, isDown: Bool) {
        guard isTransmitting else { return }

        let message = MouseButtonMessage(button: button, state: isDown ? .down : .up)

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

        // 制御権を移譲
        let entryX = Double(edgeHit.entryPosition.x / targetScreen.width)
        let entryY = Double(edgeHit.entryPosition.y / targetScreen.height)
        let message = ControlTransferMessage(to: targetScreen.id, entryX: entryX, entryY: entryY)

        if let json = encoder.encode(message) {
            DiscoveryService.shared.send(json, to: targetScreen.id)
        }

        // リモートモードに入る（エントリーポイントを渡す）
        startTransmitting(to: targetScreen.id, entryPoint: edgeHit.entryPosition)
        ScreenManager.shared.transferControlTo(deviceId: targetScreen.id, sourceScreenId: edgeHit.sourceScreenId)
    }

    // MARK: - Helpers

    private func sendToTarget(_ message: String) {
        if let peerId = targetPeerId {
            DiscoveryService.shared.send(message, to: peerId)
        }
    }

    // MARK: - Device Info

    func sendDeviceInfo() {
        guard let info = DiscoveryService.shared.localDeviceInfo else { return }

        let message = DeviceInfoMessage(
            deviceId: info.deviceId,
            hostname: info.hostname,
            deviceType: .mac,
            screenWidth: info.screenWidth,
            screenHeight: info.screenHeight
        )

        if let json = encoder.encode(message) {
            ConnectionManager.shared.broadcast(json)
        }
    }
}
