import Foundation
import Security

enum CredentialStore {
    private static let service = "org.readck.ReadeckMac"

    static func save(_ token: String, for server: ServerAddress) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.root.absoluteString
        ]
        let data = Data(token.utf8)
        try upsert(update: {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }, add: {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil)
        })
    }

    /// Retain the existing item's access controls instead of deleting it.
    static func upsert(update: () -> OSStatus, add: () -> OSStatus) throws {
        let status = update()
        let result = status == errSecItemNotFound ? add() : status
        guard result == errSecSuccess else { throw KeychainError(status: result) }
    }

    static func load(for server: ServerAddress) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.root.absoluteString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for server: ServerAddress) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.root.absoluteString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法保存登录凭据（Keychain 错误 \(status)）。" }
}
