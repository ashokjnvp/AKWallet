import SwiftUI

/// ISO/IEC 18013-5 in-person presentation: QR / NFC engagement, BLE transfer, consent.
struct ProximityView: View {
    @Environment(WalletService.self) private var wallet
    @State private var flow: ProximityFlow?
    @State private var nfcAvailable = false

    var body: some View {
        NavigationStack {
            Group {
                if let flow = flow {
                    ProximitySessionView(flow: flow, nfcAvailable: nfcAvailable)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Share in person")
        }
        .task {
            if flow == nil { flow = ProximityFlow(wallet: wallet) }
            nfcAvailable = await ProximityFlow.nfcAvailable()
        }
        .onDisappear { flow?.stop() }
    }
}

private struct ProximitySessionView: View {
    @Environment(WalletService.self) private var wallet
    @Bindable var flow: ProximityFlow
    let nfcAvailable: Bool

    var body: some View {
        switch flow.phase {
        case .idle, .done, .failed:
            start
        case .showingQR(let qr):
            VStack(spacing: 20) {
                Text("Show this code to the reader").font(.headline)
                QRCodeView(text: qr)
                    .frame(maxWidth: 280)
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                Text("Bluetooth stays on until the reader connects.").font(.footnote).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { flow.stop() }
            }
            .padding()
        case .nfcReady:
            VStack(spacing: 20) {
                StatusView(systemImage: "wave.3.right.circle", title: "Hold your iPhone near the reader")
                Button("Cancel", role: .cancel) { flow.stop() }
            }
        case .waitingForReader, .connected:
            VStack {
                StatusView(systemImage: "", title: flow.phase == .connected ? "Reader connected, waiting for its request…" : "Waiting for the reader…", progress: true)
                Button("Cancel", role: .cancel) { flow.stop() }.padding(.bottom, 32)
            }
        case .consent:
            consent
        case .sending:
            StatusView(systemImage: "", title: "Sending…", progress: true)
        }
    }

    private var start: some View {
        let mdocCount = wallet.groups.filter { $0.primary.format == "mso_mdoc" }.count
        return List {
            switch flow.phase {
            case .done:
                Section {
                    Label("Document shared", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            default:
                EmptyView()
            }
            Section {
                Button {
                    flow.start(nfc: false)
                } label: {
                    Label("Show QR code", systemImage: "qrcode")
                }
                if nfcAvailable {
                    Button {
                        flow.start(nfc: true)
                    } label: {
                        Label("Tap to share (NFC)", systemImage: "wave.3.right")
                    }
                }
            } footer: {
                Text(mdocCount == 0
                     ? "Add an mdoc credential (for example a mobile driving licence) to share it in person."
                     : "\(mdocCount) mdoc credential(s) available. The reader's request is shown for approval before anything is sent.")
            }
            Section("Connection") {
                Toggle("mdoc central client mode", isOn: $flow.centralClientMode)
                if !nfcAvailable {
                    Text("NFC engagement needs iOS 17.4, the HCE entitlement and AKNFCEngagementEnabled in Info.plist.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var consent: some View {
        List {
            Section {
                Label(flow.readerLabel, systemImage: trustIcon)
                    .foregroundStyle(trustColor)
            } header: {
                Text("Reader")
            }
            ForEach($flow.documents) { $doc in
                Section {
                    if doc.credential == nil {
                        Text("You don't have this document.").foregroundStyle(.secondary)
                    }
                    ForEach($doc.elements) { $element in
                        Toggle(isOn: $element.selected) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ClaimFormatter.label(element.name))
                                HStack(spacing: 6) {
                                    if element.intentToRetain {
                                        Label("Reader will keep this", systemImage: "tray.and.arrow.down")
                                    }
                                    if !element.available { Text("Not in your document") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!element.available)
                    }
                } header: {
                    Text(doc.credential?.name ?? doc.docType)
                }
            }
            Section {
                Button {
                    Task { await flow.approve() }
                } label: {
                    Label("Share", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canShare)
                .listRowBackground(Color.clear)
                Button(role: .destructive) { flow.decline() } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private var canShare: Bool {
        if case .invalid = flow.readerTrust { return false }
        return flow.documents.contains { $0.elements.contains { $0.selected && $0.available } }
    }

    private var trustIcon: String {
        switch flow.readerTrust {
        case .trusted: return "checkmark.shield.fill"
        case .invalid: return "xmark.shield.fill"
        default: return "exclamationmark.shield"
        }
    }

    private var trustColor: Color {
        switch flow.readerTrust {
        case .trusted: return .green
        case .invalid: return .red
        default: return .orange
        }
    }
}
