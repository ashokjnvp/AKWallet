import SwiftUI

@main
struct AKWalletApp: App {
    @State private var wallet = WalletService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(wallet)
                .onOpenURL { url in
                    switch IncomingRequest.classify(url.absoluteString) {
                    case .authorizationCallback:
                        // ASWebAuthenticationSession receives its own callback; nothing to do.
                        break
                    case let request:
                        wallet.pendingRequest = request
                    }
                }
        }
    }
}
