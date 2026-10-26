import Foundation
import NutritionCore
import Security

struct KeychainStore: Sendable {
    private let service = Bundle.main.bundleIdentifier ?? "dev.local.NutritionTracker"
    let account: String
    init(account: String = "openrouter-api-key") { self.account = account }
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    func read() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else { throw CredentialError.storage }
        return key
    }
    func write(_ key: String) throws {
        if key.isEmpty {
            try delete()
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(values) { _, new in new }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw CredentialError.storage
            }
        } else if status != errSecSuccess {
            throw CredentialError.storage
        }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.storage
        }
    }
    enum CredentialError: Error { case storage }
}

extension KeychainStore: TokenVault {}
