import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SharedSightCore

/// Renders a profile's wearable marker as a QR code. The code contains only `MarkerPayload` (a version
/// prefix and a random token): no name, no user ID.
enum MarkerImage {
    private static let context = CIContext()

    /// - Parameter pixelsPerModule: integer up-scaling, so the modules stay sharp when printed or shown full screen.
    static func make(token: String, pixelsPerModule: CGFloat = 16) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(MarkerPayload.encode(token: token).utf8)
        filter.correctionLevel = "H"      // highest redundancy: the marker moves, folds and is partly covered
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        // White quiet zone of four modules around the code, required for reliable reading.
        let margin = 4 * pixelsPerModule
        let canvas = scaled.extent.insetBy(dx: -margin, dy: -margin)
        let background = CIImage(color: .white).cropped(to: canvas)
        guard let cg = context.createCGImage(scaled.composited(over: background), from: canvas) else { return nil }
        return UIImage(cgImage: cg)
    }
}
