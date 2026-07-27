#if os(macOS)
    import AppKit
    import CoreImage.CIFilterBuiltins
    import SwiftUI

    struct QRCodeView: View {
        let value: String

        var body: some View {
            if let image = makeImage() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .accessibilityLabel("Linking QR code")
                    .accessibilityValue("Ready to scan")
                    .accessibilityHint("On the primary phone, open Linked Devices and scan this code.")
            } else {
                ContentUnavailableView(
                    "Linking code unavailable",
                    systemImage: "qrcode",
                    description: Text("Cancel setup and generate a new code.")
                )
                .accessibilityElement(children: .combine)
            }
        }

        private func makeImage() -> NSImage? {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(value.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else {
                return nil
            }
            let representation = NSCIImageRep(ciImage: output)
            let image = NSImage(size: representation.size)
            image.addRepresentation(representation)
            return image
        }
    }
#endif
