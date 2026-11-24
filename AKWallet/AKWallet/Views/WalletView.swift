import SwiftUI

struct WalletView: View {
    @Environment(WalletService.self) private var wallet
    var onAdd: () -> Void
    var onReissue: (StoredCredential) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if wallet.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No credentials yet", systemImage: "wallet.pass")
                    } description: {
                        Text("Scan a credential offer QR code from an issuer to add your first credential.")
                    } actions: {
                        Button("Scan offer", action: onAdd).buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(wallet.groups) { group in
                                NavigationLink(value: group) {
                                    CredentialCardView(credential: group.primary, copies: group.copies.count)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Wallet")
            .navigationDestination(for: CredentialGroup.self) { group in
                CredentialDetailView(group: group, onReissue: onReissue)
            }
            .toolbar {
                Button(action: onAdd) { Image(systemName: "plus") }.accessibilityLabel("Add credential")
            }
        }
    }
}

struct CredentialDetailView: View {
    @Environment(WalletService.self) private var wallet
    @Environment(\.dismiss) private var dismiss
    let group: CredentialGroup
    var onReissue: (StoredCredential) -> Void
    @State private var confirmDelete = false
    @State private var showRaw = false

    private var credential: StoredCredential { group.primary }

    var body: some View {
        List {
            Section {
                CredentialCardView(credential: credential, copies: group.copies.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let description = credential.description {
                Section { Text(description) }
            }
            Section("Claims") {
                let rows = ClaimFormatter.rows(credential.claims)
                if rows.isEmpty { Text("No claims").foregroundStyle(.secondary) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ClaimRow(label: ClaimFormatter.label(row.0), value: row.1)
                }
            }
            Section("Details") {
                LabeledContent("Format", value: credential.formatLabel)
                LabeledContent("Issuer", value: credential.issuerName ?? credential.issuer)
                LabeledContent("Issued", value: credential.issuedAt.formatted(date: .abbreviated, time: .shortened))
                if let exp = credential.expiresAt {
                    LabeledContent("Expires", value: exp.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Copies", value: "\(group.copies.count) (\(group.remainingFreshCopies) unused)")
                LabeledContent("Holder key", value: credential.holderKey.map { $0.kind == .secureEnclave ? "Secure Enclave (\($0.algorithm))" : "Software (\($0.algorithm))" } ?? "None")
                LabeledContent("Presented", value: "\(group.copies.map(\.presentationCount).reduce(0, +)) times")
            }
            Section("Trust") {
                Label(credential.trusted ? "Issuer verified against a trust anchor" : "Issuer not anchored in a trust list",
                      systemImage: credential.trusted ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(credential.trusted ? .green : .orange)
                if let note = credential.trustNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Button("Request fresh copies") { onReissue(credential) }
                    .disabled(wallet.sessions[credential.issuer] == nil)
                Button(showRaw ? "Hide raw credential" : "Show raw credential") { showRaw.toggle() }
                if showRaw {
                    Text(rawText).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Delete credential", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(credential.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(credential.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all \(group.copies.count) copies", role: .destructive) {
                wallet.delete(group: group)
                dismiss()
            }
        } message: {
            Text("The credential and its holder keys are removed from this device.")
        }
    }

    private var rawText: String {
        if let s = credential.credential.stringValue { return s }
        return (try? credential.credential.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
