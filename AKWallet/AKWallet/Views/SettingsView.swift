import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(WalletService.self) private var wallet
    @State private var addingKind: TrustSettings.AnchorKind?
    @State private var confirmWipe = false

    var body: some View {
        @Bindable var trust = wallet.trust
        NavigationStack {
            Form {
                Section {
                    Toggle("Require Face ID to share", isOn: $trust.requireUserAuthentication)
                    Stepper("Copies per credential: \(trust.batchSize)", value: $trust.batchSize, in: 1...10)
                    LabeledContent("Client ID") {
                        TextField("client_id", text: $trust.clientId)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Wallet")
                } footer: {
                    Text("Several copies of a credential are requested (batch issuance) so that different verifiers receive different copies.")
                }

                Section {
                    Toggle("Development mode", isOn: $trust.developmentMode)
                } header: {
                    Text("Trust")
                } footer: {
                    Text("In development mode, credentials whose issuer isn't in a trust list are still accepted (signatures are always checked) and requests from unregistered verifiers are allowed. Turn it off for production.")
                }

                ForEach(TrustSettings.AnchorKind.allCases) { kind in
                    Section {
                        let anchors = trust.anchors.filter { $0.kind == kind }
                        if anchors.isEmpty {
                            Text("No trust anchors").foregroundStyle(.secondary)
                        }
                        ForEach(anchors) { anchor in
                            Text(anchor.subject).font(.footnote).lineLimit(3)
                        }
                        .onDelete { offsets in
                            offsets.map { anchors[$0] }.forEach(wallet.trust.remove)
                        }
                        Button("Add certificate…") { addingKind = kind }
                    } header: {
                        Text(kind.rawValue)
                    }
                }

                Section {
                    LabeledContent("Credentials", value: "\(wallet.credentials.count)")
                    LabeledContent("Secure Enclave", value: HolderKeyManager.secureEnclaveAvailable ? "Available" : "Not available")
                    Button("Delete all credentials and keys", role: .destructive) { confirmWipe = true }
                } header: {
                    Text("Storage")
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $addingKind) { kind in
                AddAnchorView(kind: kind)
            }
            .confirmationDialog("Delete everything?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { wallet.wipe() }
            } message: {
                Text("All credentials and holder keys are removed from this device. This can't be undone.")
            }
        }
    }
}

/// Paste or import a PEM certificate (bundle) as a trust anchor.
private struct AddAnchorView: View {
    @Environment(WalletService.self) private var wallet
    @Environment(\.dismiss) private var dismiss
    let kind: TrustSettings.AnchorKind
    @State private var pem = ""
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pem)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("PEM certificate(s)")
                } footer: {
                    Text("Paste one or more -----BEGIN CERTIFICATE----- blocks.")
                }
                Button("Import from Files…") { importing = true }
                if let error = error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do {
                            try wallet.trust.add(pem: pem, kind: kind)
                            dismiss()
                        } catch {
                            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                    .disabled(pem.isEmpty)
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.x509Certificate, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    pem = text
                } else if let der = try? Data(contentsOf: url) {
                    pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END CERTIFICATE-----\n"
                }
            }
        }
    }
}
