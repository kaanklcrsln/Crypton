import Foundation
import Security

/// Stores vault passwords in the login Keychain, guarded by the user's own
/// macOS credentials. Crypton never writes a password to disk in any other form.
///
/// Saving the password is OPTIONAL and off by default: it buys convenience at the
/// cost of binding vault access to the logged-in account. When the user declines,
/// the password exists only transiently in memory during an operation.
public enum KeychainStore {
    private static let service = "com.crypton.vault"

    public static func savePassword(_ password: String, vaultID: UUID) throws {
        let account = vaultID.uuidString
        // Remove any prior entry so we never accumulate stale credentials.
        try? deletePassword(vaultID: vaultID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            // Never syncs to iCloud; unavailable until the device is unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptonError.keychainFailure(status) }
    }

    public static func loadPassword(vaultID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func deletePassword(vaultID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptonError.keychainFailure(status)
        }
    }
}
