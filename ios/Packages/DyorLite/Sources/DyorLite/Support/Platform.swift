import SwiftUI
#if canImport(UIKit)
import CoreImage.CIFilterBuiltins
import SafariServices
import UIKit

/// In-app browser for anchors' interactive flows (SEP-24 asks wallets to show them in a web view or popup).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR code of your Stellar address")
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#else
struct SafariView: View {
    let url: URL
    var body: some View { Link(url.absoluteString, destination: url) }
}

struct QRCodeView: View {
    let text: String
    var body: some View { Image(systemName: "qrcode").resizable().scaledToFit() }
}
#endif
