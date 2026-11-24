import SwiftUI
import AKOpenID4VCI
import AKPresentation

/// OpenID4VP consent: who is asking, what is shared, which credential is used.
struct PresentationConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var flow: PresentationFlow

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Share credentials")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isFinal ? "Done" : "Cancel") { dismiss() }
                    }
                }
        }
        .interactiveDismissDisabled(flow.phase == .sending)
        .onDisappear {
            // Leaving the sheet without a decision declines, so the verifier (or the
            // Interactive Authorization waiting on us) always gets an answer.
            switch flow.phase {
            case .consent, .resolving, .failed: Task { await flow.decline() }
            default: break
            }
        }
    }

    private var isFinal: Bool {
        switch flow.phase {
        case .completed, .declined, .failed: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .resolving:
            StatusView(systemImage: "", title: "Checking the request…", progress: true)
        case .consent:
            consent
        case .sending:
            StatusView(systemImage: "", title: "Sharing…", progress: true)
        case .completed(let redirect):
            VStack {
                StatusView(systemImage: "checkmark.circle.fill", title: "Shared with \(flow.verifierName)", tint: .green)
                if let redirect = redirect {
                    Button("Continue to \(redirect.host() ?? "verifier")") {
                        openURL(redirect)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 32)
                }
            }
        case .declined:
            StatusView(systemImage: "hand.raised", title: "Request declined", tint: .secondary)
        case .failed(let message):
            StatusView(systemImage: "xmark.octagon", title: "The request could not be completed", message: message, tint: .red)
        }
    }

    private var consent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(flow.verifierName).font(.title3.bold())
                    Label(flow.trustLabel, systemImage: flow.isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .font(.subheadline)
                        .foregroundStyle(flow.isTrusted ? .green : .orange)
                    if let id = flow.request?.clientId {
                        Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("wants you to share the information below.")
            }

            if !flow.transactionData.isEmpty {
                Section("You are also confirming") {
                    ForEach(Array(flow.transactionData.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(ClaimFormatter.rows(item).enumerated()), id: \.offset) { _, row in
                                ClaimRow(label: ClaimFormatter.label(row.0), value: row.1)
                            }
                        }
                    }
                }
            }

            ForEach(flow.queryIds, id: \.self) { queryId in
                querySection(queryId)
            }

            if !flow.canShare {
                Section {
                    Label("Your wallet doesn't hold the credentials this request needs.", systemImage: "questionmark.folder")
                        .foregroundStyle(.red)
                    if !flow.missing.isEmpty {
                        Text("Missing: \(flow.missing.joined(separator: ", "))").font(.footnote)
                    }
                }
            }

            Section {
                Button {
                    Task { await flow.approve() }
                } label: {
                    Label("Share", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!flow.canShare)
                .listRowBackground(Color.clear)

                Button(role: .destructive) {
                    Task { await flow.decline() }
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func querySection(_ queryId: String) -> some View {
        let candidates = flow.candidates(for: queryId)
        Section {
            if candidates.isEmpty {
                Text("No matching credential").foregroundStyle(.secondary)
            } else {
                if candidates.count > 1 {
                    Picker("Credential", selection: Binding(
                        get: { flow.chosen[queryId] ?? 0 },
                        set: { flow.chosen[queryId] = $0 })) {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                            Text(flow.stored(for: candidate)?.name ?? candidate.credential.displayName).tag(index)
                        }
                    }
                }
                if let candidate = flow.selectedCandidate(for: queryId) {
                    if let stored = flow.stored(for: candidate) {
                        CredentialCardView(credential: stored)
                            .frame(maxHeight: 120)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    ForEach(flow.requestedClaims(for: candidate), id: \.self) { claim in
                        Label(ClaimFormatter.label(claim), systemImage: "checkmark.circle")
                    }
                }
            }
        } header: {
            Text(queryId)
        }
    }
}
