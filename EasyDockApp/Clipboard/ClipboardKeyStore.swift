import CryptoKit
import EasyDockCore
import Foundation
import Security

/// The clipboard history's encryption key, made on first use and kept in the
/// login Keychain, where only this app's signature reads it without asking.
/// Without it the history on disk can't be read; deleting it (Clear History
/// does) makes anything left over unreadable. The login Keychain ignores the
/// "this device only" class, which only the data protection keychain
/// enforces, and that one needs a provisioning profile this app doesn't have.
enum ClipboardKeyStore {
    private static let service = "com.dangkhoabach.easydock.clipboard"
    private static let account = "history-key"

    /// The key, and whether it was just made.
    static func loadOrCreate() throws -> (key: SymmetricKey, isNew: Bool) {
        if let data = try read() { return (SymmetricKey(data: data), false) }
        let key = ClipboardCrypto.newKey()
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return (key, true)
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }
}
