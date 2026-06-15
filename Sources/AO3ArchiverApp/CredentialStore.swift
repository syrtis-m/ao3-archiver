import Foundation
import Security

/// Stores the AO3 username + `_otwarchive_session` cookie in the macOS **Keychain** — never
/// in the database, UserDefaults, or logs. The cookie is sent only to AO3 by `AO3Client`.
///
/// (Generic-password items keyed by the app's bundle id. For an ad-hoc-signed dev build the
/// signing identity isn't stable across rebuilds, so macOS may prompt for Keychain access
/// after a rebuild — acceptable for a personal tool; a Developer-ID-signed app wouldn't.)
enum CredentialStore {
    private static let service = "info.sysd.ao3archiver"
    static let usernameAccount = "username"
    static let cookieAccount = "session_cookie"

    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // Local to this device, readable only after first unlock — never synced to iCloud
        // Keychain and never available while the device is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static var username: String? { read(account: usernameAccount) }
    static var cookie: String? { read(account: cookieAccount) }
    static var hasCookie: Bool { cookie?.isEmpty == false }
}
