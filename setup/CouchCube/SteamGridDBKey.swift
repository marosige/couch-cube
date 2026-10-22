import Foundation
import Security

/// The user's own SteamGridDB API key, kept in the login Keychain (never in UserDefaults or on disk).
enum SteamGridDBKey {
    private static let service = "me.marosi.couchcube.steamgriddb"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }

    static func read() -> String? {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { return nil }
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return false }
        let data = Data(key.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        guard !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        SecItemDelete(query as CFDictionary)
    }
}
