import Foundation
import AKSecurity

/// Encrypted local credential storage.
///
/// Credentials are serialized to JSON, sealed with AES-256-GCM under a random key kept in the
/// Keychain (this device only), and written with complete file protection.
final class CredentialStore: @unchecked Sendable {

    private let keychain = AKKeychainStore(service: "com.toppansecurity.akwallet.store")
    private let keyAccount = "credential-store-key"
    private let fileURL: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("credentials.sealed")
    }

    private func encryptionKey() throws -> Data {
        do {
            return try keychain.get(keyAccount)
        } catch AKError.itemNotFound {
            let key = try AKSymmetricCipher.generateKey(bits: 256)
            try keychain.set(key, for: keyAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
            return key
        }
    }

    func load() throws -> [StoredCredential] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let sealed = try Data(contentsOf: fileURL)
        let box = try AKSealedBox(combined: sealed)
        let json = try AKSymmetricCipher.open(box, key: try encryptionKey(), aad: Data("akwallet.credentials.v1".utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredCredential].self, from: json)
    }

    func save(_ credentials: [StoredCredential]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(credentials)
        let box = try AKSymmetricCipher.seal(json, key: try encryptionKey(), aad: Data("akwallet.credentials.v1".utf8))
        try box.combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    /// Remove everything (file and key).
    func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        try? keychain.delete(keyAccount)
    }
}
