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

    /// 公開鍵からセッションキーを導出
    func deriveSessionKey(peerPublicKey: Curve25519.KeyAgreement.PublicKey, peerId: String) -> Bool {
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
    }

    /// 全てのセッションキーを削除
    func clearAllSessionKeys() {
        sessionKeys.removeAll()
    }

    // MARK: - Secure Message Wrapper

    /// 暗号化されたメッセージラッパー
    struct EncryptedMessage: Codable {
        let type: String = "encrypted"
        let peerId: String
        let data: String  // Base64 encoded encrypted data
        let timestamp: Double

        init(peerId: String, data: String) {
            self.peerId = peerId
            self.data = data
            self.timestamp = Date().timeIntervalSince1970
        }
    }

    /// メッセージを暗号化してラップ
    func wrapMessage(_ message: String, for peerId: String) -> String? {
        guard let encrypted = encrypt(message, for: peerId) else { return nil }

        let wrapper = EncryptedMessage(peerId: peerId, data: encrypted)

        guard let data = try? JSONEncoder().encode(wrapper),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return json
    }

    /// ラップされたメッセージを復号
    func unwrapMessage(_ json: String) -> (peerId: String, message: String)? {
        guard let data = json.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(EncryptedMessage.self, from: data) else {
            return nil
        }

        guard let decrypted = decrypt(wrapper.data, from: wrapper.peerId) else {
            return nil
        }

        return (wrapper.peerId, decrypted)
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
