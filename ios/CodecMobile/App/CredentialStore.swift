import Foundation
import Security
import CryptoKit

/// App-identity scoped secrets; Codec Test has a different bundle and service.
enum CredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "sh.codie.codec.mobile") + ".credentials.v2" }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account,
                                  kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func migrate(account: String, legacyKeys: [String]) -> String {
        let defaults = UserDefaults.standard
        let value = read(account) ?? legacyKeys.compactMap { defaults.string(forKey: $0) }.first ?? ""
        if write(value, account: account) { legacyKeys.forEach(defaults.removeObject(forKey:)) }
        return value
    }

    static func cacheScope(server: String, principal: String) -> String {
        SHA256.hash(data: Data((server + "\u{0}" + principal).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
