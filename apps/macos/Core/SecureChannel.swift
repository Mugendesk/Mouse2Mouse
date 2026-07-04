import Foundation
import Mugenlink

/// このデバイスの永続 Noise Identity (static 鍵)。
/// 旧 `CryptoManager` の CryptoKit X25519 鍵を置き換える。Keychain に 64byte で保存。
/// 旧鍵とは別物なので、移行後は再ペアリングが必要 (クリーンブレイク)。
///
/// `nonisolated`: プロジェクト既定の MainActor 隔離だと deinit が executor をホップし
/// (`swift_task_deinitOnExecutorImpl`)、uniffi の Rust ハンドル解放と干渉してヒープ破壊
/// (二重 free) を起こすため、隔離しない。
nonisolated final class NoiseIdentityStore {
    static let shared = NoiseIdentityStore()

    let identity: Mugenlink.Identity

    private init() {
        if let data = KeychainItem.noiseIdentity.load(),
           let restored = try? Mugenlink.Identity.fromBytes(bytes: data) {
            identity = restored
        } else {
            guard let fresh = try? Mugenlink.Identity.generate() else {
                fatalError("Noise Identity の生成に失敗しました")
            }
            KeychainItem.noiseIdentity.save(fresh.toBytes())
            identity = fresh
        }
    }

    /// 自分の static public key (deviceInfo/roster 用)。
    var publicKey: Data { identity.`public`() }

    /// 自分の fingerprint (PoP 済みの相手 fp と目視照合する場合に使う)。
    var fingerprint: String { identity.fingerprint() }
}

extension PairingManager {
    /// 既知 (ペア済み) デバイスの Noise static public key 集合。
    /// `Channel` の未知判定 (`authorized`) に渡す。
    func authorizedNoiseKeys() -> [Data] {
        return pairedDevices.map { $0.publicKey }
    }
}

/// mugenlink `Channel` を Mouse2Mouse のトランスポート/メッセージ層へ橋渡しする薄いラッパー。
///
/// - フレームは `{"type":"noise","frame":<base64>}` の JSON envelope でテキスト送受信する
///   (既存の WebSocket テキストフレーム経路をそのまま使える)。
/// - **fail-open 不可**: 平文は `Channel` を経由せず出入りできない。復号失敗・確立前の
///   app-data は `Channel` 側で破棄され、ここには `onMessage` として上がってこない。
///
/// `nonisolated`: MainActor 隔離だと deinit が executor をホップして uniffi の Rust
/// ハンドル解放と干渉し二重 free を起こすため隔離しない。内部状態の更新は呼び出し側
/// (WS I/O とメインスレッド) が直列化する前提で、暗号本体は Rust 側の Mutex が保護する。
nonisolated final class SecureChannel {
    private let channel: Mugenlink.Channel
    /// envelope 済み JSON テキストをトランスポートへ書き出すクロージャ。
    private let sendFrame: (String) -> Void

    /// ハンドシェイク完了。`authorized` は相手が既知鍵集合に含まれるか。
    var onEstablished: ((_ fp: String, _ staticKey: Data, _ authorized: Bool, _ pairedViaPsk: Bool) -> Void)?
    /// 復号・認証済みのアプリ層メッセージ (JSON 文字列)。
    var onMessage: ((String) -> Void)?
    /// 不正入力を破棄した (理由はログ用)。
    var onRejected: ((String) -> Void)?
    /// チャネルが閉じた。
    var onClosed: (() -> Void)?

    private(set) var remoteFingerprint: String?
    private(set) var remoteStaticKey: Data?
    /// 相手が既知 (authorized_keys に含まれる) デバイスか。未知なら承認が要る。
    private(set) var authorized = false
    private(set) var isEstablished = false

    private init(channel: Mugenlink.Channel, sendFrame: @escaping (String) -> Void) {
        self.channel = channel
        self.sendFrame = sendFrame
    }

    /// initiator (接続を仕掛ける側) を作る。承認TOFU: 未知の相手も確立させアプリが承認判断。
    static func initiator(sendFrame: @escaping (String) -> Void) -> SecureChannel {
        let ch = try! Mugenlink.Channel.newInitiator(
            local: NoiseIdentityStore.shared.identity,
            psk: nil,
            transport: .reliable,
            authorizedKeys: PairingManager.shared.authorizedNoiseKeys(),
            allowUnknown: true
        )
        return SecureChannel(channel: ch, sendFrame: sendFrame)
    }

    /// responder (接続を受ける側) を作る。
    static func responder(sendFrame: @escaping (String) -> Void) -> SecureChannel {
        let ch = try! Mugenlink.Channel.newResponder(
            local: NoiseIdentityStore.shared.identity,
            psk: nil,
            transport: .reliable,
            authorizedKeys: PairingManager.shared.authorizedNoiseKeys(),
            allowUnknown: true
        )
        return SecureChannel(channel: ch, sendFrame: sendFrame)
    }

    /// initiator が最初のハンドシェイクフレームを送出する。
    func start() {
        process(channel.open())
    }

    /// トランスポートで受け取った envelope の frame (base64 復号済み Data) を投入する。
    func receiveFrame(_ frame: Data) {
        process(channel.onMessage(frame: frame))
    }

    /// アプリ層メッセージ (JSON 文字列) を暗号化して送る。確立前は何もせず false。
    @discardableResult
    func sendApp(_ message: String) -> Bool {
        guard isEstablished, let data = message.data(using: .utf8) else { return false }
        do {
            let ct = try channel.send(plaintext: data)
            sendFrame(SecureChannel.encodeEnvelope(ct))
            return true
        } catch {
            return false
        }
    }

    private func process(_ events: [ChannelEvent]) {
        for ev in events {
            switch ev {
            case .send(let frame):
                sendFrame(SecureChannel.encodeEnvelope(frame))
            case .established(let fp, let key, let authorized, let paired):
                isEstablished = true
                remoteFingerprint = fp
                remoteStaticKey = key
                self.authorized = authorized
                onEstablished?(fp, key, authorized, paired)
            case .message(let plaintext):
                if let s = String(data: plaintext, encoding: .utf8) {
                    onMessage?(s)
                }
            case .rejected(let reason):
                print("[SecureChannel] rejected: \(reason)")
                onRejected?(reason)
            case .closed:
                onClosed?()
            }
        }
    }

    // MARK: - Envelope

    /// noise フレームを包む JSON envelope の type。
    static let envelopeType = "noise"

    /// バイナリフレームを `{"type":"noise","frame":<base64>}` のテキストにする。
    static func encodeEnvelope(_ frame: Data) -> String {
        return "{\"type\":\"\(envelopeType)\",\"frame\":\"\(frame.base64EncodedString())\"}"
    }

    /// raw テキストが noise envelope なら frame (Data) を取り出す。違えば nil。
    static func decodeEnvelope(_ raw: String) -> Data? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == envelopeType,
              let b64 = json["frame"] as? String else {
            return nil
        }
        return Data(base64Encoded: b64)
    }
}
