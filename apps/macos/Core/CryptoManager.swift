import Foundation
import CryptoKit

/// 暗号化管理
/// X25519鍵交換 + ChaCha20-Poly1305暗号化
class CryptoManager {
    static let shared = CryptoManager()

    // MARK: - Properties

    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    private(set) var publicKey: Curve25519.KeyAgreement.PublicKey

    // セッションキー（ペアごとに異なる）
    private var sessionKeys: [String: SymmetricKey] = [:]

    // リプレイ防止: ピア毎の送信シーケンス番号
    private var outgoingSeq: [String: UInt64] = [:]
    // リプレイ防止: ピア毎の最後に受信したシーケンス番号
    private var lastIncomingSeq: [String: UInt64] = [:]
    // リプレイ防止: タイムスタンプ許容ウィンドウ (秒)
    private let timestampWindow: TimeInterval = 60.0

    // MARK: - Lifecycle

    private init() {
        // 保存されたキーがあれば読み込み、なければ生成
        if let savedKeyData = PairingManager.shared.loadPrivateKey(),
           let savedKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: savedKeyData) {
            privateKey = savedKey
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            _ = PairingManager.shared.savePrivateKey(privateKey.rawRepresentation)
        }

        publicKey = privateKey.publicKey
    }

    // MARK: - Key Exchange

    /// 公開鍵をBase64エンコードで取得
    var publicKeyBase64: String {
        return publicKey.rawRepresentation.base64EncodedString()
    }

    /// Base64エンコードされた公開鍵からセッションキーを導出
    func deriveSessionKey(peerPublicKeyBase64: String, peerId: String) -> Bool {
        guard let peerKeyData = Data(base64Encoded: peerPublicKeyBase64),
              let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData) else {
            print("Invalid peer public key")
            return false
        }

        return deriveSessionKey(peerPublicKey: peerPublicKey, peerId: peerId)
    }

    /// 公開鍵からセッションキーを導出（既存キーがある場合は上書きしない：TOFU原則）
    func deriveSessionKey(peerPublicKey: Curve25519.KeyAgreement.PublicKey, peerId: String) -> Bool {
        if sessionKeys[peerId] != nil {
            print("Session key already exists for peer: \(peerId) (TOFU: keeping existing)")
            return true
        }
        do {
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

            // HKDF で対称鍵を導出
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: "Mouse2Mouse".data(using: .utf8)!,
                sharedInfo: "session".data(using: .utf8)!,
                outputByteCount: 32
            )

            sessionKeys[peerId] = symmetricKey
            print("Session key derived for peer: \(peerId)")
            return true

        } catch {
            print("Failed to derive session key: \(error)")
            return false
        }
    }

    // MARK: - Encryption

    /// メッセージを暗号化
    func encrypt(_ message: String, for peerId: String) -> String? {
        guard let sessionKey = sessionKeys[peerId],
              let messageData = message.data(using: .utf8) else {
            return nil
        }

        do {
            let sealedBox = try ChaChaPoly.seal(messageData, using: sessionKey)
            let combined = sealedBox.combined

            return combined.base64EncodedString()

        } catch {
            print("Encryption failed: \(error)")
            return nil
        }
    }

    /// メッセージを復号
    func decrypt(_ encryptedBase64: String, from peerId: String) -> String? {
        guard let sessionKey = sessionKeys[peerId],
              let combinedData = Data(base64Encoded: encryptedBase64) else {
            return nil
        }

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: combinedData)
            let decryptedData = try ChaChaPoly.open(sealedBox, using: sessionKey)

            return String(data: decryptedData, encoding: .utf8)

        } catch {
            print("Decryption failed: \(error)")
            return nil
        }
    }

    // MARK: - Session Management

    /// セッションキーが存在するか確認
    func hasSessionKey(for peerId: String) -> Bool {
        return sessionKeys[peerId] != nil
    }

    /// セッションキーを削除
    func removeSessionKey(for peerId: String) {
        sessionKeys.removeValue(forKey: peerId)
        resetReplayState(for: peerId)
    }

    /// 全てのセッションキーを削除
    func clearAllSessionKeys() {
        sessionKeys.removeAll()
        outgoingSeq.removeAll()
        lastIncomingSeq.removeAll()
    }

    // MARK: - Secure Message Wrapper

    /// 暗号化されたメッセージラッパー（typeフィールドのみ必須）
    struct EncryptedMessage: Codable {
        let type: String
        let data: String  // Base64 encoded encrypted data
        let timestamp: Double
        let seq: UInt64

        init(data: String, seq: UInt64) {
            self.type = "encrypted"
            self.data = data
            self.timestamp = Date().timeIntervalSince1970
            self.seq = seq
        }
    }

    /// メッセージを暗号化してラップ
    func wrapMessage(_ message: String, for peerId: String) -> String? {
        guard let encrypted = encrypt(message, for: peerId) else { return nil }

        // 送信シーケンスをインクリメント (1始まり、0は未使用センチネル)
        let nextSeq = (outgoingSeq[peerId] ?? 0) &+ 1
        outgoingSeq[peerId] = nextSeq

        let wrapper = EncryptedMessage(data: encrypted, seq: nextSeq)

        guard let data = try? JSONEncoder().encode(wrapper),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return json
    }

    /// ラップされたメッセージを復号（接続コンテキストから既知のpeerIdを使用）
    /// リプレイ攻撃対策: シーケンス番号とタイムスタンプを検証
    func unwrapMessage(_ json: String, from peerId: String) -> String? {
        guard let data = json.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(EncryptedMessage.self, from: data) else {
            return nil
        }

        // タイムスタンプ検証 (時計ズレ ±timestampWindow 秒まで許容)
        let now = Date().timeIntervalSince1970
        if abs(now - wrapper.timestamp) > timestampWindow {
            print("Replay protection: timestamp out of window for peer \(peerId) (delta=\(now - wrapper.timestamp)s)")
            return nil
        }

        // シーケンス番号検証 (厳密に単調増加)
        if let lastSeq = lastIncomingSeq[peerId], wrapper.seq <= lastSeq {
            print("Replay protection: stale/duplicate seq \(wrapper.seq) <= \(lastSeq) for peer \(peerId)")
            return nil
        }

        guard let decrypted = decrypt(wrapper.data, from: peerId) else {
            // 復号失敗時はseqを進めない (改竄や鍵不一致を意味するため)
            return nil
        }

        lastIncomingSeq[peerId] = wrapper.seq
        return decrypted
    }

    // MARK: - Replay Protection State

    /// 切断・再接続時にリプレイ防止状態をリセット
    func resetReplayState(for peerId: String) {
        outgoingSeq.removeValue(forKey: peerId)
        lastIncomingSeq.removeValue(forKey: peerId)
    }
}

// MARK: - Encrypted Connection Manager Extension

extension ConnectionManager {
    /// 暗号化されたメッセージを送信
    func sendEncrypted(_ message: String, to peerId: String) {
        guard CryptoManager.shared.hasSessionKey(for: peerId) else {
            print("No session key for peer: \(peerId)")
            return
        }

        guard let encrypted = CryptoManager.shared.wrapMessage(message, for: peerId) else {
            print("Failed to encrypt message")
            return
        }

        send(encrypted, to: peerId)
    }

    /// 暗号化されたメッセージをブロードキャスト
    func broadcastEncrypted(_ message: String) {
        for peerId in activeConnections.keys {
            sendEncrypted(message, to: peerId)
        }
    }
}
