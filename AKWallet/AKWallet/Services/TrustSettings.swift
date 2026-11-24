import Foundation
import Observation
import AKSecurity

/// User-managed trust anchors and policies (persisted in UserDefaults; certificates are public data).
@MainActor
@Observable
final class TrustSettings {

    enum AnchorKind: String, CaseIterable, Codable, Identifiable {
        case issuer = "Credential issuers"
        case iaca = "mdoc IACA"
        case verifier = "Verifiers (OpenID4VP)"
        case reader = "mdoc readers"
        var id: String { rawValue }
    }

    struct Anchor: Codable, Identifiable, Hashable {
        let id: UUID
        let kind: AnchorKind
        let pem: String
        let subject: String
    }

    private(set) var anchors: [Anchor] = []
    /// Accept credentials / verifiers that are correctly signed but not anchored (development only).
    var developmentMode: Bool { didSet { persist() } }
    /// Require Face ID / passcode before sharing.
    var requireUserAuthentication: Bool { didSet { persist() } }
    var clientId: String { didSet { persist() } }
    var batchSize: Int { didSet { persist() } }

    private let defaults = UserDefaults.standard

    init() {
        developmentMode = defaults.object(forKey: "dev") as? Bool ?? true
        requireUserAuthentication = defaults.object(forKey: "auth") as? Bool ?? true
        clientId = defaults.string(forKey: "clientId") ?? "akwallet-ios"
        batchSize = defaults.object(forKey: "batch") as? Int ?? 3
        if let data = defaults.data(forKey: "anchors"), let list = try? JSONDecoder().decode([Anchor].self, from: data) {
            anchors = list
        }
    }

    private func persist() {
        defaults.set(developmentMode, forKey: "dev")
        defaults.set(requireUserAuthentication, forKey: "auth")
        defaults.set(clientId, forKey: "clientId")
        defaults.set(batchSize, forKey: "batch")
        defaults.set(try? JSONEncoder().encode(anchors), forKey: "anchors")
    }

    /// Add every certificate from a PEM bundle. Returns how many were added.
    @discardableResult
    func add(pem: String, kind: AnchorKind) throws -> Int {
        let certs = try AKCertificate.certificates(fromPEM: pem)
        guard !certs.isEmpty else { throw AKError.decodingFailed("no CERTIFICATE block found") }
        for c in certs where !anchors.contains(where: { $0.kind == kind && $0.pem == c.pem }) {
            anchors.append(Anchor(id: UUID(), kind: kind, pem: c.pem, subject: c.subject.description))
        }
        persist()
        return certs.count
    }

    func remove(_ anchor: Anchor) {
        anchors.removeAll { $0.id == anchor.id }
        persist()
    }

    func trustStore(_ kind: AnchorKind) -> AKTrustStore? {
        let certs = anchors.filter { $0.kind == kind }.compactMap { try? AKCertificate(pem: $0.pem) }
        return certs.isEmpty ? nil : AKTrustStore(anchors: certs)
    }
}
