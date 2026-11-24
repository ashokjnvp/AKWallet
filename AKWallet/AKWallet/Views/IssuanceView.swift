import SwiftUI
import AKOpenID4VCI

struct IssuanceView: View {
    @Environment(WalletService.self) private var wallet
    @Environment(\.dismiss) private var dismiss
    @Bindable var flow: IssuanceFlow
    @State private var txCode = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add credential")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(flow.phase == .completed ? "Done" : "Close") { dismiss() }
                    }
                }
        }
        .interactiveDismissDisabled(isBusy)
        .sheet(item: $flow.presentationFlow) { presentation in
            PresentationConsentView(flow: presentation)
        }
    }

    private var isBusy: Bool {
        switch flow.phase {
        case .authorizing, .issuing, .waitingDeferred, .presentation: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .resolving:
            StatusView(systemImage: "", title: "Contacting the issuer…", progress: true)
        case .review:
            review
        case .enterTxCode:
            txCodeForm
        case .authorizing(let message), .issuing(let message):
            StatusView(systemImage: "", title: message, progress: true)
        case .presentation:
            StatusView(systemImage: "person.badge.shield.checkmark", title: "The issuer asks you to present a credential",
                       message: "Review the request to continue.")
        case .waitingDeferred(let name):
            StatusView(systemImage: "", title: "Waiting for \(name)",
                       message: "The issuer is still processing your credential. Keep the app open.", progress: true)
        case .completed:
            completed
        case .failed(let message):
            StatusView(systemImage: "xmark.octagon", title: "Issuance failed", message: message, tint: .red)
        }
    }

    @ViewBuilder
    private var review: some View {
        if let summary = flow.summary {
            List {
                Section {
                    LabeledContent("Issuer", value: summary.issuerName)
                    Text(summary.issuer).font(.caption).foregroundStyle(.secondary)
                }
                Section("Credentials offered") {
                    ForEach(summary.items) { item in
                        VStack(alignment: .leading) {
                            Text(item.name).font(.body.weight(.medium))
                            Text(item.format).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if summary.preAuthorized {
                        Button {
                            Task { await flow.usePreAuthorized() }
                        } label: {
                            Label("Accept offer", systemImage: "checkmark.seal")
                        }
                    }
                    if summary.authorizationCode {
                        Button {
                            Task { await flow.useAuthorizationCode() }
                        } label: {
                            Label(summary.interactive ? "Authorize in the wallet" : "Sign in with the issuer",
                                  systemImage: summary.interactive ? "person.badge.key" : "safari")
                        }
                    }
                    if !summary.preAuthorized && !summary.authorizationCode {
                        Text("The issuer offers no grant this wallet supports.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Holder keys are generated on this device (Secure Enclave when possible). The credential is verified and stored encrypted.")
                }
            }
        }
    }

    private var txCodeForm: some View {
        let spec = flow.summary?.txCode
        let numeric = (spec?.inputMode ?? "numeric") == "numeric"
        return Form {
            Section {
                SecureField(numeric ? "Transaction code" : "Code", text: $txCode)
                    .keyboardType(numeric ? .numberPad : .default)
                    .textContentType(.oneTimeCode)
            } header: {
                Text("Transaction code")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec?.description ?? "Enter the code the issuer sent you through another channel.")
                    if let length = spec?.length { Text("\(length) characters") }
                    if let error = wallet.lastError { Text(error).foregroundStyle(.red) }
                }
            }
            Button("Continue") {
                wallet.lastError = nil
                let code = txCode
                Task { await flow.usePreAuthorized(txCode: code) }
            }
            .disabled(txCode.isEmpty || (spec?.length).map { txCode.count != $0 } == true)
        }
    }

    private var completed: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Added to your wallet").font(.headline)
                ForEach(uniqueIssued) { credential in
                    CredentialCardView(credential: credential,
                                       copies: flow.issued.filter { $0.batchGroup == credential.batchGroup }.count)
                    if !credential.trusted, let note = credential.trustNote {
                        Label(note, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .padding()
        }
    }

    private var uniqueIssued: [StoredCredential] {
        var seen = Set<UUID>()
        return flow.issued.filter { seen.insert($0.batchGroup).inserted }
    }
}
