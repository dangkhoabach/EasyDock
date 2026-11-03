import CryptoKit
import Foundation

/// Seals what the history keeps on disk. AES-GCM with a 256-bit key the app
/// keeps in the Keychain, so the database file alone gives nothing away;
/// repeats are found through an HMAC of the content under a key derived from
/// the same one, which tells equal copies apart without storing them in clear.
public struct ClipboardCrypto: Sendable {
    private let key: SymmetricKey
    private let hashKey: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
        hashKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Data("easydock clipboard identity".utf8), outputByteCount: 32)
    }

    public static func newKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public func seal<T: Encodable>(_ value: T) throws -> Data {
        guard let combined = try AES.GCM.seal(JSONEncoder().encode(value), using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    public func open<T: Decodable>(_ type: T.Type, from sealed: Data) throws -> T {
        try JSONDecoder().decode(type, from: AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key))
    }

    func identity(of content: ClipboardContent) -> String {
        HMAC<SHA256>.authenticationCode(for: content.identity, using: hashKey)
            .map { String(format: "%02x", $0) }.joined()
    }
}
