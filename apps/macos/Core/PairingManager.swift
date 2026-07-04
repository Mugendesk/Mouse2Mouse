import Foundation
import Combine
import CryptoKit
import Security

/// ペアリング認証管理
/// 6桁コードによる認証とデバイス情報の永続化
class PairingManager: ObservableObject {
    static let shared = PairingManager()

    // MARK: - Published Properties

    @Published var pairedDevices: [PairedDevice] = []
    @Published var pendingPairingRequest: PairingRequest?
    @Published var pendingApproval: PendingApproval?
    @Published var pendingKeyChangeWarning: KeyChangeWarning?

    // MARK: - Types

    struct PairedDevice: Codable, Identifiable {
        let id: String  // device_id
        let hostname: String
        let publicKey: Data  // X25519 public key
        let pairedAt: Date
    }

    struct PairingRequest {
        let deviceId: String
        let hostname: String
        let publicKey: Data
        let code: String
        let expiresAt: Date
    }

    /// AirDrop風の承認待ち要求（コード不要、即許可/拒否）
    struct PendingApproval: Identifiable {
        let id = UUID()
        let deviceId: String
        let hostname: String
        let publicKey: Data
        let callback: (Bool) -> Void
    }

    /// 既存ペアと公開鍵が異なる場合の警告（TOFU鍵ローテーション検知）
    struct KeyChangeWarning: Identifiable {
        let id = UUID()
        let deviceId: String
        let hostname: String
        let oldPublicKey: Data
        let newPublicKey: Data
        let callback: (Bool) -> Void  // true=新しい鍵を信頼, false=拒否
    }

    /// 鍵の照合結果
    enum KeyCheckResult {
        case match            // 既存鍵と一致
        case mismatch         // 既存鍵と不一致 (警告すべき)
        case unknown          // 未ペアリング (新規)
    }

    // MARK: - Constants

    private let pairedDevicesKey = "Mouse2Mouse.PairedDevices"
    private let codeValidityDuration: TimeInterval = 120  // 2分間有効

    // MARK: - Lifecycle

    private init() {
        loadPairedDevices()
    }

    // MARK: - Pairing Code Generation

    /// 6桁のペアリングコードを生成
    func generatePairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999999))
        return code
    }

    // MARK: - Pairing Flow

    /// ペアリングリクエストを開始（リクエストを受け取った側）
    func startPairingRequest(deviceId: String, hostname: String, publicKeyData: Data) -> String {
        let code = generatePairingCode()

        pendingPairingRequest = PairingRequest(
            deviceId: deviceId,
            hostname: hostname,
            publicKey: publicKeyData,
            code: code,
            expiresAt: Date().addingTimeInterval(codeValidityDuration)
        )

        print("Pairing request started for \(hostname), code: \(code)")
        return code
    }

    /// ペアリングコードを検証
    func verifyPairingCode(_ inputCode: String) -> Bool {
        guard let request = pendingPairingRequest else { return false }

        // 有効期限チェック
        guard Date() < request.expiresAt else {
            pendingPairingRequest = nil
            return false
        }

        // コード検証
        guard inputCode == request.code else { return false }

        // ペアリング完了
        completePairing(request)
        return true
    }

    /// ペアリング完了処理
    private func completePairing(_ request: PairingRequest) {
        let device = PairedDevice(
            id: request.deviceId,
            hostname: request.hostname,
            publicKey: request.publicKey,
            pairedAt: Date()
        )

        // 既存のペアリングを更新または追加
        if let index = pairedDevices.firstIndex(where: { $0.id == device.id }) {
            pairedDevices[index] = device
        } else {
            pairedDevices.append(device)
        }

        savePairedDevices()
        pendingPairingRequest = nil

        print("Paired with \(device.hostname)")
    }

    /// ペアリングリクエストをキャンセル
    func cancelPairingRequest() {
        pendingPairingRequest = nil
    }

    // MARK: - Approval-based Pairing (AirDrop style)

    /// 承認を要求（受け側UIでダイアログを出すため）
    /// completion はメインスレッドで呼び出される
    func requestApproval(
        deviceId: String,
        hostname: String,
        publicKey: Data,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            self.pendingApproval = PendingApproval(
                deviceId: deviceId,
                hostname: hostname,
                publicKey: publicKey,
                callback: completion
            )
        }
    }

    /// 承認ダイアログのユーザー応答を反映
    func respondToApproval(approved: Bool) {
        guard let pending = pendingApproval else { return }
        if approved {
            recordTrust(deviceId: pending.deviceId, hostname: pending.hostname, publicKey: pending.publicKey)
        }
        pending.callback(approved)
        pendingApproval = nil
    }

    /// ペアリング情報を信頼済みに追加（クライアント側の接続成功時にも使用）
    func recordTrust(deviceId: String, hostname: String, publicKey: Data) {
        let device = PairedDevice(
            id: deviceId,
            hostname: hostname,
            publicKey: publicKey,
            pairedAt: Date()
        )
        DispatchQueue.main.async {
            if let index = self.pairedDevices.firstIndex(where: { $0.id == device.id }) {
                self.pairedDevices[index] = device
            } else {
                self.pairedDevices.append(device)
            }
            self.savePairedDevices()
            print("[PairingManager] Trust recorded: \(hostname) [\(deviceId)]")
        }
    }

    // MARK: - Fingerprint & Key Change Detection

    /// 公開鍵から人間可読なfingerprintを生成 (SHA256の先頭16バイトを4組のhex)
    /// 例: "A1B2:C3D4:E5F6:0708:..." (8グループ、16文字×4=ID用)
    static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        // 4文字毎に区切って先頭32文字 (16バイト分) を採用
        let prefix = String(hex.prefix(32))
        return stride(from: 0, to: prefix.count, by: 4).map {
            let start = prefix.index(prefix.startIndex, offsetBy: $0)
            let end = prefix.index(start, offsetBy: 4)
            return String(prefix[start..<end])
        }.joined(separator: ":")
    }

    /// 接続時に受信した公開鍵と保存済みの鍵を照合
    func checkKey(deviceId: String, incomingPublicKey: Data) -> KeyCheckResult {
        guard let stored = getPublicKey(for: deviceId) else { return .unknown }
        return stored == incomingPublicKey ? .match : .mismatch
    }

    /// 鍵変更警告をUIに提示 (ユーザーが新しい鍵を信頼するか拒否するかを待つ)
    func requestKeyChangeApproval(
        deviceId: String,
        hostname: String,
        oldPublicKey: Data,
        newPublicKey: Data,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            self.pendingKeyChangeWarning = KeyChangeWarning(
                deviceId: deviceId,
                hostname: hostname,
                oldPublicKey: oldPublicKey,
                newPublicKey: newPublicKey,
                callback: completion
            )
        }
    }

    /// 鍵変更警告のユーザー応答を反映
    func respondToKeyChange(trustNewKey: Bool) {
        guard let warning = pendingKeyChangeWarning else { return }
        if trustNewKey {
            recordTrust(deviceId: warning.deviceId, hostname: warning.hostname, publicKey: warning.newPublicKey)
            print("[Pairing] User trusted new key for \(warning.hostname) — re-trust recorded")
        } else {
            print("[Pairing] User rejected key change for \(warning.hostname)")
        }
        warning.callback(trustNewKey)
        pendingKeyChangeWarning = nil
    }

    // MARK: - Device Management

    /// デバイスがペアリング済みかチェック
    func isPaired(deviceId: String) -> Bool {
        return pairedDevices.contains { $0.id == deviceId }
    }

    /// ペアリング済みデバイスの公開鍵を取得
    func getPublicKey(for deviceId: String) -> Data? {
        return pairedDevices.first { $0.id == deviceId }?.publicKey
    }

    /// ペアリングを解除
    func unpair(deviceId: String) {
        pairedDevices.removeAll { $0.id == deviceId }
        savePairedDevices()
        print("Unpaired device: \(deviceId)")
    }

    /// 全てのペアリングを解除
    func unpairAll() {
        pairedDevices.removeAll()
        savePairedDevices()
        print("All devices unpaired")
    }

    // MARK: - Persistence

    private func savePairedDevices() {
        guard let data = try? JSONEncoder().encode(pairedDevices) else { return }
        UserDefaults.standard.set(data, forKey: pairedDevicesKey)
    }

    private func loadPairedDevices() {
        guard let data = UserDefaults.standard.data(forKey: pairedDevicesKey),
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return
        }
        pairedDevices = devices
    }

    // MARK: - Keychain Operations

    /// 自分の秘密鍵をKeychainに保存
    func savePrivateKey(_ key: Data) -> Bool {
        return KeychainItem.privateKey.save(key)
    }

    /// Keychainから秘密鍵を取得
    func loadPrivateKey() -> Data? {
        return KeychainItem.privateKey.load()
    }
}
