import Foundation
import AKSecurity
import AKOpenID4VCI

/// Verifies issued credentials against configured trust anchors, with an explicit
/// development fallback that checks signatures and digests but marks the result untrusted.
struct CredentialVerifier: Sendable {

    let issuerAnchors: AKTrustStore?
    let iacaAnchors: AKTrustStore?
    let developmentMode: Bool
    let http: AKHTTPClient

    struct Outcome {
        let verified: AKVerifiedCredential
        let trusted: Bool
        let note: String?
    }

    func verify(_ credential: AKIssuedCredential, configuration: AKCredentialConfiguration) async throws -> Outcome {
        let strict = AKCredentialVerificationOptions(
            issuerKeyResolver: AKDefaultIssuerKeyResolver(trustStore: issuerAnchors, http: http),
            iacaTrustStore: iacaAnchors)
        do {
            return Outcome(verified: try await credential.verify(configuration: configuration, options: strict), trusted: true, note: nil)
        } catch {
            guard developmentMode else { throw error }
            // Development: anchor on the credential's own top certificate so signatures,
            // digests and holder binding are still checked.
            let selfAnchor = try selfAnchoredStore(credential)
            let relaxed = AKCredentialVerificationOptions(
                issuerKeyResolver: AKDefaultIssuerKeyResolver(trustStore: selfAnchor ?? issuerAnchors, http: http),
                iacaTrustStore: selfAnchor ?? iacaAnchors)
            let verified = try await credential.verify(configuration: configuration, options: relaxed)
            return Outcome(verified: verified, trusted: false,
                           note: "Issuer not trusted: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    private func selfAnchoredStore(_ credential: AKIssuedCredential) throws -> AKTrustStore? {
        let chain: [AKCertificate]
        switch try credential.decode() {
        case .sdJWTVC(let sd): chain = try sd.issuerJWT.x5c()
        case .jwtVC(let vc): chain = try vc.jws.x5c()
        case .mdoc(let m): chain = try m.issuerAuth.x5chain()
        case .ldpVC: chain = []
        }
        guard let top = chain.last else { return nil }
        return AKTrustStore(anchors: [top])
    }
}
