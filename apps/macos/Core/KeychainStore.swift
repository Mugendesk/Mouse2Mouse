import Foundation
import Security

/// Keychainアイテム種別 (service + account を一元管理)
enum KeychainItem {
    case privateKey
    /// mugenlink Noise Identity (64byte: private32||public32)。旧 privateKey を置き換える。
    case noiseIdentity

    private static let service = "com.mugendesk.mouse2mouse.pairing"

    var account: String {
        switch self {
        case .privateKey: return "privateKey"
        case .noiseIdentity: return "noiseIdentity"
        }
    }

    var service: String { Self.service }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// アイテムを保存 (既存があれば置き換え)
    @discardableResult
    func save(_ data: Data) -> Bool {
        var query = baseQuery
        // 既存削除→新規追加 (最も単純で確実)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// アイテムを取得
    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// アイテムを削除
    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
