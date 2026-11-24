import Foundation
import Observation
import AKSecurity
import AKOpenID4VCI
import AKPresentation

/// Remote presentation with OpenID4VP (also used for the presentation step of Interactive Authorization).
@MainActor
@Observable
final class PresentationFlow: Identifiable {

    enum Phase: Equatable {
        case resolving
        case consent
        case sending
        case completed(redirect: URL?)
        case declined
        case failed(String)
    }

    let id = UUID()
    var phase: Phase = .resolving
    private(set) var request: AKVPAuthorizationRequest?
    private(set) var match: AKDCQLMatch?
    /// credential query id → index of the chosen candidate.
    var chosen: [String: Int] = [:]

    private let wallet: WalletService
    @ObservationIgnored private var storedById: [String: StoredCredential] = [:]
    private let interactiveSubmit: ((AKJSONValue) async throws -> Void)?

    /// Remote OpenID4VP.
    init(wallet: WalletService) {
        self.wallet = wallet
        self.interactiveSubmit = nil
    }

    /// Interactive Authorization: the response object is handed back instead of being posted.
    init(wallet: WalletService, interactiveSubmit: @escaping (AKJSONValue) async throws -> Void) {
        self.wallet = wallet
        self.interactiveSubmit = interactiveSubmit
    }

    // MARK: Start

    func start(uri: String) async {
        await run { try await self.wallet.vpResolver().resolve(uri) }
    }

    func start(interactiveRequest: AKJSONValue, endpoint: URL) async {
        await run { try await self.wallet.vpResolver().resolveInteractive(interactiveRequest, endpoint: endpoint) }
    }

    private func run(_ resolve: () async throws -> AKVPAuthorizationRequest) async {
        phase = .resolving
        do {
            let request = try await resolve()
            self.request = request
            guard let query = request.dcqlQuery else {
                throw AKPresentationError.unsupported("scope-based requests (\(request.scope ?? "")) are not supported")
            }
            let held = wallet.heldCredentials()
            storedById = Dictionary(uniqueKeysWithValues: held.map { ($0.0.id, $0.1) })
            let match = try AKDCQLMatcher.match(query, credentials: held.map(\.0))
            self.match = match
            chosen = Dictionary(uniqueKeysWithValues: query.credentials.map { ($0.id, 0) })
            phase = .consent
        } catch {
            phase = .failed(Self.message(error))
            if let submit = interactiveSubmit {
                let code = (error as? AKPresentationError)?.oauthErrorCode ?? "invalid_request"
                try? await submit(["error": .string(code), "error_description": .string(Self.message(error))])
            } else if let request = request {
                let code = (error as? AKPresentationError)?.oauthErrorCode ?? "invalid_request"
                _ = try? await AKVPResponder(http: wallet.http).submitError(code, description: Self.message(error), for: request)
            }
        }
    }

    // MARK: Consent model

    var verifierName: String { request?.verifierName ?? "Unknown verifier" }

    var trustLabel: String {
        switch request?.trust {
        case .trusted: return "Verified relying party"
        case .signatureOnly: return "Signed, but not from a trusted provider"
        case .unsigned: return "Unverified (unsigned request)"
        case .none: return ""
        }
    }

    var isTrusted: Bool { request?.trust == .trusted }

    var queryIds: [String] { match?.selectedQueryIds ?? request?.dcqlQuery?.credentials.map(\.id) ?? [] }
    var canShare: Bool { match?.isSatisfiable ?? false }
    var missing: [String] { match?.unmatchedQueryIds ?? [] }

    func candidates(for queryId: String) -> [AKCredentialCandidate] { match?.candidates[queryId] ?? [] }

    func selectedCandidate(for queryId: String) -> AKCredentialCandidate? {
        let list = candidates(for: queryId)
        guard !list.isEmpty else { return nil }
        return list[min(chosen[queryId] ?? 0, list.count - 1)]
    }

    func stored(for candidate: AKCredentialCandidate) -> StoredCredential? { storedById[candidate.credential.id] }

    func requestedClaims(for candidate: AKCredentialCandidate) -> [String] {
        if candidate.disclosesAll { return ["All claims in this credential"] }
        return candidate.claimPaths.map { path in
            path.map { component -> String in
                switch component {
                case .string(let s): return s
                case .number(let n): return "[\(Int(n))]"
                case .null: return "[*]"
                default: return "?"
                }
            }.joined(separator: " › ")
        }
    }

    var transactionData: [AKJSONValue] { request?.decodedTransactionData ?? [] }

    // MARK: Actions

    func approve() async {
        guard let request = request else { return }
        if wallet.trust.requireUserAuthentication {
            guard await UserAuthentication.confirm(reason: "Share credentials with \(verifierName)") else { return }
        }
        phase = .sending
        do {
            let selections = queryIds.compactMap { id in selectedCandidate(for: id).map { AKVPSelection(queryId: id, candidate: $0) } }
            let token = try AKVPPresenter.vpToken(for: request, selections: selections)
            var redirect: URL?
            if let submit = interactiveSubmit {
                try await submit(try AKVPResponder.interactiveResponse(vpToken: token, for: request))
            } else {
                redirect = try await AKVPResponder(http: wallet.http).submit(vpToken: token, for: request)
            }
            wallet.markPresented(selections.compactMap { UUID(uuidString: $0.candidate.credential.id) })
            phase = .completed(redirect: redirect)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func decline() async {
        let wasConsent = phase == .consent
        phase = .declined
        if let submit = interactiveSubmit {
            // Always answer, so the waiting Interactive Authorization never hangs.
            try? await submit(["error": "access_denied"])
        } else if wasConsent, let request = request {
            _ = try? await AKVPResponder(http: wallet.http).submitError("access_denied", description: "The user declined", for: request)
        }
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
