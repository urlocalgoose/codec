import CryptoKit
import Foundation
import Security

enum DeviceKeyStore {
    private static let service = "sh.codie.loud.mobile.device-key"
    private static let account = "primary"
    private static let simulatorFallbackKey = "loud.debug.simulator.device-key"

    static func loadOrCreatePrivateKey() throws -> P256.Signing.PrivateKey {
        if let stored = try loadPrivateKeyData() {
            return try P256.Signing.PrivateKey(rawRepresentation: stored)
        }

        let key = P256.Signing.PrivateKey()
        try savePrivateKeyData(key.rawRepresentation)
        return key
    }

    private static func loadPrivateKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        #if DEBUG && targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            return UserDefaults.standard.data(forKey: simulatorFallbackKey)
        }
        #endif
        guard status == errSecSuccess else {
            throw DeviceKeyStoreError.keychain(status)
        }
        return item as? Data
    }

    private static func savePrivateKeyData(_ data: Data) throws {
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        #if DEBUG && targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            UserDefaults.standard.set(data, forKey: simulatorFallbackKey)
            return
        }
        #endif
        guard status == errSecSuccess else {
            throw DeviceKeyStoreError.keychain(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum DeviceKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
}
