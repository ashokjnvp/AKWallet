import Foundation
import AKOpenID4VCI

/// Reference to a holder key kept in the Keychain / Secure Enclave.
struct HolderKeyRef: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case secureEnclave, software }
    let id: String
    let kind: Kind
    let algorithm: String
}

/// A credential stored in the wallet.
struct StoredCredential: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// Copies issued together in one batch share a group (shown as one card, presented one copy at a time).
    let batchGroup: UUID
    let format: String
    let configurationId: String
    let issuer: String
    var issuerName: String?
    var name: String
    var description: String?
    var backgroundColor: String?
    var textColor: String?
    /// The credential exactly as issued.
    let credential: AKJSONValue
    let holderKey: HolderKeyRef?
    let issuedAt: Date
    var expiresAt: Date?
    /// Verified claims snapshot for display.
    var claims: AKJSONValue
    /// Issuer signature verified and chained to a trusted anchor.
    var trusted: Bool
    var trustNote: String?
    var presentationCount: Int = 0
    var lastPresentedAt: Date?

    var formatLabel: String {
        switch format {
        case AKCredentialFormat.sdJWTVC, AKCredentialFormat.sdJWTVCLegacy: return "SD-JWT VC"
        case AKCredentialFormat.msoMdoc: return "mdoc"
        case AKCredentialFormat.jwtVCJSON: return "W3C VC (JWT)"
        case AKCredentialFormat.jwtVCJSONLD: return "W3C VC (JWT, JSON-LD)"
        case AKCredentialFormat.ldpVC: return "W3C VC (Data Integrity)"
        default: return format
        }
    }

    var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }
}

/// One card in the wallet: a batch of copies of the same credential.
struct CredentialGroup: Identifiable, Hashable {
    let id: UUID
    let copies: [StoredCredential]
    var primary: StoredCredential { copies[0] }
    var name: String { primary.name }
    /// Least-used copy, to reduce linkability across verifiers.
    var nextCopy: StoredCredential {
        copies.min { ($0.presentationCount, $0.issuedAt) < ($1.presentationCount, $1.issuedAt) } ?? primary
    }
    var remainingFreshCopies: Int { copies.filter { $0.presentationCount == 0 }.count }
}

/// Flatten claims for display: ("address.street_address", "1 Main St").
enum ClaimFormatter {
    static func rows(_ value: AKJSONValue, prefix: String = "") -> [(String, String)] {
        switch value {
        case .object(let o):
            return o.keys.sorted().flatMap { key -> [(String, String)] in
                guard !["cnf", "_sd", "_sd_alg", "status", "iss", "iat", "nbf", "exp", "vct", "@context", "jti"].contains(key) || !prefix.isEmpty else { return [] }
                return rows(o[key]!, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        case .array(let a):
            if a.allSatisfy({ $0.objectValue == nil && $0.arrayValue == nil }) {
                return [(prefix, a.map(display).joined(separator: ", "))]
            }
            return a.enumerated().flatMap { rows($0.element, prefix: "\(prefix)[\($0.offset)]") }
        default:
            return [(prefix, display(value))]
        }
    }

    static func display(_ value: AKJSONValue) -> String {
        switch value {
        case .string(let s): return s.count > 120 ? String(s.prefix(117)) + "…" : s
        case .bool(let b): return b ? "Yes" : "No"
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .null: return "—"
        default: return (try? String(decoding: value.jsonData(), as: UTF8.self)) ?? ""
        }
    }

    static func label(_ path: String) -> String {
        path.split(separator: ".").last.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? path
    }
}
