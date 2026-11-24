import Foundation
import Observation
import AKSecurity
import AKOpenID4VCI
import AKPresentation

/// What an incoming URL / scanned QR code is.
enum IncomingRequest: Identifiable, Equatable {
    case credentialOffer(String)
    case presentation(String)
    case authorizationCallback(URL)
    case unknown(String)

    var id: String {
        switch self {
        case .credentialOffer(let s), .presentation(let s), .unknown(let s): return s
        case .authorizationCallback(let u): return u.absoluteString
        }
    }

    static func classify(_ text: String) -> IncomingRequest {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(WebAuthenticator.callbackScheme + "://"), let url = URL(string: s) { return .authorizationCallback(url) }
        if s.contains("credential_offer") { return .credentialOffer(s) }
        if AKVPRequestResolver.isPresentationRequest(s) { return .presentation(s) }
        return .unknown(s)
    }
}

/// Central wallet state: stored credentials, keys, trust, and factories for protocol clients.
@MainActor
@Observable
final class WalletService {

    private(set) var credentials: [StoredCredential] = []
    var lastError: String?
    var pendingRequest: IncomingRequest?

    let trust = TrustSettings()
    let keys = HolderKeyManager()
    private let store = CredentialStore()
    let http: AKHTTPClient = AKURLSessionHTTPClient()
    /// Issuance sessions kept for this app run (deferred polling, re-issuance).
    @ObservationIgnored var sessions: [String: AKIssuanceSession] = [:]

    init() {
        do { credentials = try store.load() } catch { lastError = "Could not open the credential store: \(error.localizedDescription)" }
    }

    // MARK: Grouping

    var groups: [CredentialGroup] {
        Dictionary(grouping: credentials, by: \.batchGroup)
            .map { CredentialGroup(id: $0.key, copies: $0.value.sorted { $0.issuedAt < $1.issuedAt }) }
            .sorted { $0.primary.issuedAt > $1.primary.issuedAt }
    }

    // MARK: Persistence

    func add(_ new: [StoredCredential]) throws {
        credentials.append(contentsOf: new)
        try store.save(credentials)
    }

    func delete(group: CredentialGroup) {
        for c in group.copies { if let k = c.holderKey { keys.delete(k) } }
        credentials.removeAll { $0.batchGroup == group.id }
        try? store.save(credentials)
    }

    func markPresented(_ ids: [UUID]) {
        for i in credentials.indices where ids.contains(credentials[i].id) {
            credentials[i].presentationCount += 1
            credentials[i].lastPresentedAt = Date()
        }
        try? store.save(credentials)
    }

    func wipe() {
        for c in credentials { if let k = c.holderKey { keys.delete(k) } }
        credentials = []
        store.wipe()
    }

    // MARK: Factories

    func vciWallet() -> AKOpenID4VCIWallet {
        AKOpenID4VCIWallet(configuration: AKWalletConfiguration(
            clientId: trust.clientId, redirectURI: WebAuthenticator.redirectURI, http: http,
            encryption: AKCredentialEncryption(preferEncryption: true),
            languages: Locale.preferredLanguages))
    }

    func credentialVerifier() -> CredentialVerifier {
        CredentialVerifier(issuerAnchors: trust.trustStore(.issuer), iacaAnchors: trust.trustStore(.iaca),
                           developmentMode: trust.developmentMode, http: http)
    }

    func vpResolver() -> AKVPRequestResolver {
        AKVPRequestResolver(http: http, configuration: AKVPConfiguration(
            trustedVerifierAnchors: trust.trustStore(.verifier),
            allowUntrustedVerifiers: trust.developmentMode,
            allowUnsignedRequests: true,
            holderAlgorithms: ["ES256", "ES384", "ES512", "EdDSA"]))
    }

    /// Held credentials for presentation: one (least-used) copy per batch, with its holder key.
    func heldCredentials(formats: Set<String>? = nil) -> [(AKHeldCredential, StoredCredential)] {
        groups.compactMap { group in
            let copy = group.nextCopy
            if let f = formats, !f.contains(copy.format) { return nil }
            let signer = copy.holderKey.flatMap { try? keys.signer(for: $0) }
            guard let held = try? AKHeldCredential(id: copy.id.uuidString, format: copy.format, raw: copy.credential,
                                                   signer: signer, displayName: copy.name) else { return nil }
            return (held, copy)
        }
    }

    func storedCredential(id: String) -> StoredCredential? {
        credentials.first { $0.id.uuidString == id }
    }

    func mdocCredentials(docType: String) -> [(AKHeldCredential, StoredCredential)] {
        heldCredentials(formats: [AKCredentialFormat.msoMdoc]).filter { $0.0.docType == docType }
    }
}
