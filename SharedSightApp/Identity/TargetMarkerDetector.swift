import Vision
import QuartzCore
import SharedSightCore

/// Reads Shared Sight target markers (QR codes) in a camera frame with Apple's Vision framework.
///
/// Only codes whose payload has the Shared Sight marker format are returned; any other QR code in view
/// (a poster, a menu) is discarded here and never stored or logged. The result is a random token and where
/// it was seen — it is evidence that *this marker* is in the image, not proof of who is carrying it.
/// Call from the perception queue only.
final class TargetMarkerDetector {
    private let request: VNDetectBarcodesRequest
    private(set) var lastLatency = 0.0
    private(set) var lastError: String?

    init() {
        request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
    }

    func detect(_ frame: CameraFrame) -> [MarkerSighting] {
        let start = CACurrentMediaTime()
        defer { lastLatency = CACurrentMediaTime() - start }
        do {
            try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation, options: [:]).perform([request])
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return []
        }
        return (request.results ?? []).compactMap { observation -> MarkerSighting? in
            guard let payload = observation.payloadStringValue, let token = MarkerPayload.decode(payload) else { return nil }
            // Vision: normalised, origin bottom-left, in the upright image. Detections: origin top-left.
            let b = observation.boundingBox
            return MarkerSighting(token: token, box: NormRect(x: Double(b.minX), y: Double(1 - b.maxY),
                                                              w: Double(b.width), h: Double(b.height)))
        }
    }
}
