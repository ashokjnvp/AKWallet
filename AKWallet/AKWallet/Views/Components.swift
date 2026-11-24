import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code (used for ISO 18013-5 device engagement).
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("QR code")
        } else {
            Image(systemName: "xmark.octagon").font(.largeTitle)
        }
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension Color {
    /// "#RRGGBB" / "#RGB" as used by OpenID4VCI display metadata.
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct CredentialCardView: View {
    let credential: StoredCredential
    var copies: Int = 1

    var body: some View {
        let background = Color(hex: credential.backgroundColor) ?? .indigo
        let foreground = Color(hex: credential.textColor) ?? .white
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(credential.formatLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(foreground.opacity(0.2), in: Capsule())
                Spacer()
                if !credential.trusted {
                    Image(systemName: "exclamationmark.shield").accessibilityLabel("Issuer not trusted")
                }
                if credential.isExpired {
                    Text("Expired").font(.caption.bold())
                }
            }
            Spacer(minLength: 12)
            Text(credential.name).font(.title3.bold()).lineLimit(2)
            Text(credential.issuerName ?? credential.issuer).font(.footnote).opacity(0.85).lineLimit(1)
            if copies > 1 {
                Text("\(copies) copies").font(.caption2).opacity(0.75)
            }
        }
        .foregroundStyle(foreground)
        .padding()
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(background.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}

struct ClaimRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct StatusView: View {
    let systemImage: String
    let title: String
    var message: String?
    var tint: Color = .accentColor
    var progress = false

    var body: some View {
        VStack(spacing: 14) {
            if progress {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: systemImage).font(.system(size: 52)).foregroundStyle(tint)
            }
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let message = message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
