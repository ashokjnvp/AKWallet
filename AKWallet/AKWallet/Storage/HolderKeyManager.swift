import Foundation
import AKSecurity
import AKOpenID4VCI

/// Creates and loads holder keys. P-256 keys live in the Secure Enclave when available;
/// other algorithms (and the Simulator) use software keys stored in the Keychain.
final class HolderKeyManager: @unchecked Sendable {

    private let store = AKKeychainStore(service: "com.toppansecurity.akwallet.holder-keys")

    static var secureEnclaveAvailable: Bool { AKSecureEnclaveKey.isAvailable }

    func createKey(algorithm: String) throws -> (HolderKeyRef, AKJWTSigner) {
        let id = UUID().uuidString
        if algorithm == "ES256", AKSecureEnclaveKey.isAvailable {
            let key = try AKSecureEnclaveKey.generate(purpose: .signing, accessibility: .whenUnlockedThisDeviceOnly)
            try store.set(key.dataRepresentation, for: id)
            return (HolderKeyRef(id: id, kind: .secureEnclave, algorithm: algorithm), AKSecureEnclaveJWTSigner(key: key))
        }
        let signer = try AKSoftwareJWTSigner.generate(algorithm: algorithm)
        try store.setPrivateKey(signer.privateKey, for: id)
        return (HolderKeyRef(id: id, kind: .software, algorithm: algorithm), signer)
    }

    func signer(for ref: HolderKeyRef) throws -> AKJWTSigner {
        switch ref.kind {
        case .secureEnclave:
            return AKSecureEnclaveJWTSigner(key: try AKSecureEnclaveKey(dataRepresentation: try store.get(ref.id)))
        case .software:
            return try AKSoftwareJWTSigner(privateKey: try store.privateKey(ref.id), algorithm: ref.algorithm)
        }
    }

    func delete(_ ref: HolderKeyRef) {
        try? store.delete(ref.id)
    }

    /// Pick a proof algorithm the issuer accepts, preferring hardware-backed ES256.
    static func preferredAlgorithm(for configuration: AKCredentialConfiguration) -> String {
        let supported = configuration.proofTypesSupported?.values.flatMap(\.proofSigningAlgValuesSupported) ?? []
        if supported.isEmpty || supported.contains("ES256") { return "ES256" }
        return ["ES384", "ES512", "BP256R1", "BP384R1", "BP512R1", "EdDSA", "PS256"].first(where: supported.contains) ?? supported[0]
    }
}
