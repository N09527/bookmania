import Foundation
import Security

/// The WebDAV password, kept in the keychain: for this device only (not in backups of the device, not synced to other
/// devices), and readable after the first unlock so a sync can finish while the app is in the background.
enum SyncKeychain {
    private static let service = "io.github.n09527.bookmania.webdav"
    private static let account = "password"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func password() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored password; an empty one removes it. False when the keychain refused it.
    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
