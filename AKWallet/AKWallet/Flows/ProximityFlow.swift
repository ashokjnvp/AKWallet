import Foundation
import Observation
import AKSecurity
import AKOpenID4VCI
import AKPresentation

/// In-person presentation (ISO/IEC 18013-5): QR or NFC engagement, BLE, consent, DeviceResponse.
@MainActor
@Observable
final class ProximityFlow {

    enum Phase: Equatable {
        case idle
        case showingQR(String)
        case nfcReady
        case waitingForReader
        case connected
        case consent
        case sending
        case done
        case failed(String)
    }

    struct ElementItem: Identifiable, Hashable {
        var id: String { namespace + "/" + name }
        let namespace: String
        let name: String
        let intentToRetain: Bool
        let available: Bool
        var selected: Bool
    }

    struct DocumentItem: Identifiable {
        var id: String { docType }
        let docType: String
        let credential: StoredCredential?
        let held: AKHeldCredential?
        var elements: [ElementItem]
    }

    var phase: Phase = .idle
    var documents: [DocumentItem] = []
    private(set) var readerTrust: AKReaderTrust = .anonymous
    /// mdoc central client mode instead of peripheral server mode.
    var centralClientMode = false

    private let wallet: WalletService
    @ObservationIgnored private var presentation: AKProximityPresentation?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(wallet: WalletService) { self.wallet = wallet }

    static var nfcConfigured: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "AKNFCEngagementEnabled") as? Bool) == true
    }

    static func nfcAvailable() async -> Bool {
        guard nfcConfigured else { return false }
        if #available(iOS 17.4, *) { return await AKNFCEngagementSession.isAvailable() }
        return false
    }

    var readerLabel: String {
        switch readerTrust {
        case .anonymous: return "Reader did not identify itself"
        case .trusted(let cn): return "Verified reader: \(cn ?? "unknown")"
        case .untrusted(let cn): return "Unverified reader: \(cn ?? "unknown")"
        case .invalid(let reason): return "Invalid reader authentication: \(reason)"
        }
    }

    // MARK: Lifecycle

    func start(nfc: Bool) {
        stop()
        guard !wallet.heldCredentials(formats: [AKCredentialFormat.msoMdoc]).isEmpty else {
            phase = .failed("There are no mdoc credentials in the wallet.")
            return
        }
        let p = AKProximityPresentation(bleMode: centralClientMode ? .centralClient : .peripheralServer,
                                        engagementMethod: nfc ? .nfc : .qrCode,
                                        readerTrustStore: wallet.trust.trustStore(.reader))
        presentation = p
        eventsTask = Task { [weak self] in
            for await event in p.events { self?.handle(event) }
        }
        do { try p.start() } catch { phase = .failed(Self.message(error)) }
    }

    func stop() {
        presentation?.stop()
        presentation = nil
        eventsTask?.cancel()
        eventsTask = nil
        documents = []
        if phase != .done { phase = .idle }
    }

    private func handle(_ event: AKProximityEvent) {
        switch event {
        case .engagementReady(let qr): phase = .showingQR(qr)
        case .nfcReady: phase = .nfcReady
        case .waitingForReader:
            // Keep the QR code / NFC prompt on screen while the reader connects.
            switch phase {
            case .showingQR, .nfcReady: break
            default: phase = .waitingForReader
            }
        case .readerConnected: phase = .connected
        case .requestReceived(let request, let trust):
            readerTrust = trust
            documents = buildItems(request)
            phase = .consent
        case .responseSent: phase = .done
        case .finished:
            switch phase {
            case .done, .failed: break
            case .sending: phase = .done
            default: phase = .idle
            }
        case .failed(let message): phase = .failed(message)
        }
    }

    private func buildItems(_ request: AKMDocDeviceRequest) -> [DocumentItem] {
        request.docRequests.map { doc in
            let match = wallet.mdocCredentials(docType: doc.docType).first
            let claims = match?.0.claims
            var elements: [ElementItem] = []
            for (ns, items) in doc.nameSpaces.sorted(by: { $0.key < $1.key }) {
                for (name, retain) in items.sorted(by: { $0.key < $1.key }) {
                    let available = claims?[ns]?[name] != nil
                    elements.append(ElementItem(namespace: ns, name: name, intentToRetain: retain, available: available, selected: available))
                }
            }
            return DocumentItem(docType: doc.docType, credential: match?.1, held: match?.0, elements: elements)
        }
    }

    // MARK: Consent

    func approve() async {
        guard let presentation = presentation else { return }
        if wallet.trust.requireUserAuthentication {
            guard await UserAuthentication.confirm(reason: "Share your document with the reader") else { return }
        }
        phase = .sending
        do {
            var disclosures: [AKMDocDisclosure] = []
            var notReturned: [String] = []
            var used: [UUID] = []
            for doc in documents {
                let selected = doc.elements.filter { $0.selected && $0.available }
                guard let held = doc.held, let mdoc = held.mdoc, let signer = held.signer, !selected.isEmpty else {
                    notReturned.append(doc.docType)
                    continue
                }
                var map: [String: Set<String>] = [:]
                for e in selected { map[e.namespace, default: []].insert(e.name) }
                disclosures.append(AKMDocDisclosure(credential: mdoc, docType: doc.docType, elements: map, signer: signer))
                if let id = doc.credential?.id { used.append(id) }
            }
            try presentation.respond(disclosures, notReturned: notReturned)
            wallet.markPresented(used)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func decline() {
        presentation?.decline()
        presentation = nil
        phase = .idle
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
