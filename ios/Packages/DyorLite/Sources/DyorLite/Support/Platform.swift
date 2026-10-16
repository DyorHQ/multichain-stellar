import SwiftUI
#if canImport(UIKit)
import CoreImage.CIFilterBuiltins
import UIKit

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel(tr("QR code of your Stellar address"))
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
struct QRCodeView: View {
    let text: String
    var body: some View { Image(systemName: "qrcode").resizable().scaledToFit().accessibilityLabel(tr("QR code of your Stellar address")) }
}
#endif
