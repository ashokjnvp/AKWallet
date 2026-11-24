import SwiftUI
import AVFoundation

/// Scans credential offers, OpenID4VP requests and issuer URLs; also accepts pasted links.
struct ScanView: View {
    var onCode: (String) -> Void

    @State private var manual = ""
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var scanning = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if authorized && scanning {
                        QRScannerView { code in
                            scanning = false
                            onCode(code)
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                scanning = true
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 20).fill(.black.opacity(0.85))
                        if !authorized {
                            Text("Camera access is needed to scan QR codes.")
                                .foregroundStyle(.white).padding()
                        }
                    }
                    RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.8), lineWidth: 3).padding(40)
                }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                Text("Scan a credential offer, a presentation request, or an issuer QR code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste a link / Credential Issuer URL").font(.subheadline.weight(.medium))
                    HStack {
                        TextField("openid-credential-offer://… or https://issuer.example", text: $manual)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Go") {
                            onCode(manual)
                            manual = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Paste from clipboard") {
                        if let s = UIPasteboard.general.string { onCode(s) }
                    }
                    .font(.footnote)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Scan")
            .task {
                if !authorized { authorized = await AVCaptureDevice.requestAccess(for: .video) }
            }
        }
    }
}

/// AVFoundation QR code scanner.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            delivered = false
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            // The delegate queue is the main queue.
            MainActor.assumeIsolated {
                guard !delivered else { return }
                delivered = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode?(value)
            }
        }
    }
}
