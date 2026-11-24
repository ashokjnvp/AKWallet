import Foundation
import Observation
import AKSecurity
import AKOpenID4VCI
import AKPresentation

/// Summary of an offer for the consent screen.
struct OfferSummary: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let name: String
        let format: String
    }
    let issuer: String
    let issuerName: String
    let items: [Item]
    let preAuthorized: Bool
    let authorizationCode: Bool
    let interactive: Bool
    let txCode: AKTxCode?
}

/// OpenID4VCI issuance: Pre-Authorized Code, Authorization Code (browser), Interactive Authorization.
@MainActor
@Observable
final class IssuanceFlow: Identifiable {

    enum Phase: Equatable {
        case resolving
        case review
        case enterTxCode
        case authorizing(String)
        case presentation
        case issuing(String)
        case waitingDeferred(String)
        case completed
        case failed(String)
    }

    let id = UUID()
    var phase: Phase = .resolving
    private(set) var summary: OfferSummary?
    private(set) var issued: [StoredCredential] = []
    /// Set while an Interactive Authorization asks for a presentation.
    var presentationFlow: PresentationFlow?

    private let wallet: WalletService
    private let vci: AKOpenID4VCIWallet
    private let web = WebAuthenticator()
    @ObservationIgnored private var resolved: AKResolvedIssuer?

    init(wallet: WalletService) {
        self.wallet = wallet
        self.vci = wallet.vciWallet()
    }

    // MARK: Start

    func start(offerURI: String) async {
        phase = .resolving
        do {
            let resolved = try await vci.resolveOffer(offerURI)
            prepare(resolved)
        } catch {
            fail(error)
        }
    }

    /// Wallet-initiated issuance from an issuer URL.
    func start(issuer: String) async {
        phase = .resolving
        do {
            let resolved = try await vci.resolve(credentialIssuer: issuer)
            prepare(resolved)
        } catch {
            fail(error)
        }
    }

    private func prepare(_ resolved: AKResolvedIssuer) {
        self.resolved = resolved
        let meta = resolved.issuerMetadata
        let items = resolved.configurationIds.compactMap { id -> OfferSummary.Item? in
            guard let c = meta.credentialConfigurationsSupported[id] else { return nil }
            return OfferSummary.Item(id: id, name: Self.display(c.credentialMetadata?.display)?.name ?? id, format: c.format)
        }
        summary = OfferSummary(
            issuer: meta.credentialIssuer,
            issuerName: Self.display(meta.display)?.name ?? URL(string: meta.credentialIssuer)?.host ?? meta.credentialIssuer,
            items: items,
            preAuthorized: resolved.supportsPreAuthorizedCode,
            authorizationCode: resolved.offer == nil || resolved.offer?.grants?.authorizationCode != nil || resolved.offer?.grants == nil,
            interactive: resolved.supportsInteractiveAuthorization,
            txCode: resolved.transactionCode)
        phase = .review
    }

    // MARK: Flows

    /// Pre-Authorized Code flow. Prompts for the transaction code when needed.
    func usePreAuthorized(txCode: String? = nil) async {
        guard let resolved = resolved else { return }
        if resolved.transactionCode != nil, txCode == nil { phase = .enterTxCode; return }
        phase = .authorizing("Redeeming the pre-authorized code…")
        do {
            let session = try await vci.authorizeWithPreAuthorizedCode(resolved, txCode: txCode)
            try await issueAll(session)
        } catch AKVCIError.server(_, let e) where e.error == AKOAuthErrorCode.invalidTxCode {
            phase = .enterTxCode
            wallet.lastError = "The transaction code is not correct."
        } catch {
            fail(error)
        }
    }

    /// Authorization Code flow: Interactive Authorization when the AS supports it, otherwise the browser.
    func useAuthorizationCode() async {
        guard let resolved = resolved else { return }
        do {
            let session: AKIssuanceSession
            if resolved.supportsInteractiveAuthorization {
                session = try await interactive(resolved)
            } else {
                session = try await browser(resolved)
            }
            try await issueAll(session)
        } catch {
            fail(error)
        }
    }

    private func browser(_ resolved: AKResolvedIssuer) async throws -> AKIssuanceSession {
        phase = .authorizing("Sign in with \(summary?.issuerName ?? "the issuer")…")
        let (flow, state) = try await vci.beginAuthorization(resolved)
        let callback = try await web.authenticate(url: state.authorizationURL)
        phase = .authorizing("Completing authorization…")
        return try await vci.completeAuthorization(resolved, flow: flow, callback: callback, state: state)
    }

    private func interactive(_ resolved: AKResolvedIssuer) async throws -> AKIssuanceSession {
        phase = .authorizing("Contacting the authorization server…")
        guard let endpoint = try resolved.authorizationServer.authorizationChallengeEndpointURL else {
            return try await browser(resolved)
        }
        let ia = try vci.interactiveAuthorization(resolved)
        var step = try await ia.start(configurationIds: resolved.configurationIds,
                                      issuerState: resolved.offer?.grants?.authorizationCode?.issuerState)
        while true {
            switch step {
            case .completed:
                phase = .authorizing("Completing authorization…")
                return try await vci.completeInteractiveAuthorization(resolved, interactive: ia, step: step)
            case .presentationRequired(let request):
                let response = try await presentForAuthorization(request, endpoint: endpoint)
                phase = .authorizing("Verifying your presentation…")
                step = try await ia.submitPresentation(response)
            case .webAuthorizationRequired(let url, _):
                phase = .authorizing("Continue in the browser…")
                step = try await ia.resume(callback: try await web.authenticate(url: url))
            case .custom(let type, _):
                throw AKVCIError.interactionNotSupported(type)
            }
        }
    }

    /// Show the presentation consent UI and wait for the OpenID4VP response object.
    private func presentForAuthorization(_ request: AKJSONValue, endpoint: URL) async throws -> AKJSONValue {
        let box = ResumeOnce()
        let response: AKJSONValue = try await withCheckedThrowingContinuation { continuation in
            let flow = PresentationFlow(wallet: wallet) { response in
                if box.claim() { continuation.resume(returning: response) }
            }
            self.presentationFlow = flow
            self.phase = .presentation
            Task { await flow.start(interactiveRequest: request, endpoint: endpoint) }
        }
        presentationFlow = nil
        if response["error"] != nil { throw AKVCIError.authorizationFailed("presentation declined") }
        return response
    }

    // MARK: Issuance

    private func issueAll(_ session: AKIssuanceSession) async throws {
        guard let resolved = resolved else { return }
        wallet.sessions[resolved.issuerMetadata.credentialIssuer] = session
        let ids = resolved.offer?.credentialConfigurationIds ?? session.authorizedConfigurationIds
        for id in ids {
            issued.append(contentsOf: try await issue(configurationId: id, session: session))
        }
        phase = .completed
    }

    /// Request (batch) credentials for one configuration, verify them and store them.
    func issue(configurationId id: String, session: AKIssuanceSession) async throws -> [StoredCredential] {
        let configuration = try session.issuerMetadata.configuration(id)
        let name = Self.display(configuration.credentialMetadata?.display)?.name ?? id
        phase = .issuing("Requesting \(name)…")

        var refs: [HolderKeyRef] = []
        var signers: [AKJWTSigner] = []
        if configuration.requiresKeyBinding {
            let algorithm = HolderKeyManager.preferredAlgorithm(for: configuration)
            let count = max(1, min(wallet.trust.batchSize, session.issuerMetadata.batchCredentialIssuance?.batchSize ?? 1))
            for _ in 0..<count {
                let (ref, signer) = try wallet.keys.createKey(algorithm: algorithm)
                refs.append(ref)
                signers.append(signer)
            }
        }
        do {
            var result = try await session.requestCredential(configurationId: id, holderKeys: signers)
            if case .deferred(let pending) = result {
                phase = .waitingDeferred(name)
                result = .issued(try await session.waitForDeferred(pending, maxAttempts: 30))
            }
            guard case .issued(let batch) = result else { throw AKVCIError.invalidResponse("no credential issued") }
            let stored = try await store(batch, configuration: configuration, session: session, refs: refs, signers: signers)
            if let n = batch.notificationId { try? await session.notify(n, event: .credentialAccepted) }
            return stored
        } catch {
            refs.forEach(wallet.keys.delete)
            throw error
        }
    }

    private func store(_ batch: AKIssuedCredentialBatch, configuration: AKCredentialConfiguration, session: AKIssuanceSession,
                       refs: [HolderKeyRef], signers: [AKJWTSigner]) async throws -> [StoredCredential] {
        let verifier = wallet.credentialVerifier()
        let display = Self.display(batch.credentialMetadata?.display ?? configuration.credentialMetadata?.display)
        let issuerName = Self.display(session.issuerMetadata.display)?.name
        let thumbprints = signers.map { try? $0.publicJWK().thumbprint() }
        let group = UUID()
        var out: [StoredCredential] = []
        do {
            for credential in batch.credentials {
                let outcome = try await verifier.verify(credential, configuration: configuration)
                var ref: HolderKeyRef?
                if let bound = try? outcome.verified.holderKey?.publicJWK().thumbprint(), let i = thumbprints.firstIndex(of: bound) {
                    ref = refs[i]
                }
                out.append(StoredCredential(
                    id: UUID(), batchGroup: group, format: batch.format, configurationId: batch.configurationId,
                    issuer: session.issuerMetadata.credentialIssuer, issuerName: issuerName,
                    name: display?.name ?? batch.configurationId, description: display?.description,
                    backgroundColor: display?.backgroundColor, textColor: display?.textColor,
                    credential: credential.value, holderKey: ref, issuedAt: Date(),
                    expiresAt: outcome.verified.claims["exp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                    claims: outcome.verified.claims, trusted: outcome.trusted && outcome.verified.signatureVerified,
                    trustNote: outcome.note ?? (outcome.verified.signatureVerified ? nil : "Data Integrity proof not verified")))
            }
            try wallet.add(out)
            return out
        } catch {
            if let n = batch.notificationId {
                try? await session.notify(n, event: .credentialFailure, description: "verification failed")
            }
            throw error
        }
    }

    /// Request a fresh batch of an already-held credential with the session kept from this app run
    /// (the session refreshes its access token when needed).
    func reissue(_ credential: StoredCredential) async {
        guard let session = wallet.sessions[credential.issuer] else {
            phase = .failed("Re-issuance needs an active session with \(credential.issuerName ?? credential.issuer). Request the credential again from the issuer.")
            return
        }
        summary = OfferSummary(issuer: credential.issuer, issuerName: credential.issuerName ?? credential.issuer,
                               items: [.init(id: credential.configurationId, name: credential.name, format: credential.format)],
                               preAuthorized: false, authorizationCode: false, interactive: false, txCode: nil)
        do {
            issued = try await issue(configurationId: credential.configurationId, session: session)
            phase = .completed
        } catch {
            fail(error)
        }
    }

    // MARK: Helpers

    private func fail(_ error: Error) {
        phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Best display entry for the user's language.
    static func display(_ list: [AKDisplay]?) -> AKDisplay? {
        guard let list = list, !list.isEmpty else { return nil }
        for lang in Locale.preferredLanguages {
            let code = lang.prefix(2)
            if let d = list.first(where: { $0.locale?.hasPrefix(code) ?? false }) { return d }
        }
        return list.first { $0.locale == nil } ?? list.first
    }
}

/// Ensures a continuation is resumed at most once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
