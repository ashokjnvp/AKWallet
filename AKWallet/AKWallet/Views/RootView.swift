import SwiftUI

struct RootView: View {
    @Environment(WalletService.self) private var wallet

    enum Tab: Hashable { case wallet, scan, share, settings }

    @State private var tab: Tab = .wallet
    @State private var issuance: IssuanceFlow?
    @State private var presentation: PresentationFlow?
    @State private var unknownInput: String?

    var body: some View {
        TabView(selection: $tab) {
            WalletView(onAdd: { tab = .scan }, onReissue: reissue)
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }
                .tag(Tab.wallet)
            ScanView { wallet.pendingRequest = IncomingRequest.classify($0) }
                .tabItem { Label("Scan", systemImage: "qrcode.viewfinder") }
                .tag(Tab.scan)
            ProximityView()
                .tabItem { Label("Share", systemImage: "person.crop.rectangle.badge.plus") }
                .tag(Tab.share)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: wallet.pendingRequest) { _, request in
            guard let request = request else { return }
            wallet.pendingRequest = nil
            route(request)
        }
        .onAppear {
            if let request = wallet.pendingRequest {
                wallet.pendingRequest = nil
                route(request)
            }
        }
        .sheet(item: $issuance) { flow in
            IssuanceView(flow: flow)
        }
        .sheet(item: $presentation) { flow in
            PresentationConsentView(flow: flow)
        }
        .alert("Unsupported code", isPresented: Binding(get: { unknownInput != nil }, set: { if !$0 { unknownInput = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This is neither a credential offer nor a presentation request.\n\n\(unknownInput ?? "")")
        }
    }

    private func route(_ request: IncomingRequest) {
        switch request {
        case .credentialOffer(let uri):
            let flow = IssuanceFlow(wallet: wallet)
            issuance = flow
            tab = .wallet
            Task { await flow.start(offerURI: uri) }
        case .presentation(let uri):
            let flow = PresentationFlow(wallet: wallet)
            presentation = flow
            Task { await flow.start(uri: uri) }
        case .authorizationCallback:
            break
        case .unknown(let text):
            if let url = URL(string: text), url.scheme == "https", url.query == nil {
                // A bare https URL: treat as a Credential Issuer identifier (wallet-initiated issuance).
                startIssuance(issuer: text)
            } else {
                unknownInput = text
            }
        }
    }

    private func startIssuance(issuer: String) {
        let flow = IssuanceFlow(wallet: wallet)
        issuance = flow
        Task { await flow.start(issuer: issuer) }
    }

    private func reissue(_ credential: StoredCredential) {
        let flow = IssuanceFlow(wallet: wallet)
        issuance = flow
        Task { await flow.reissue(credential) }
    }
}
