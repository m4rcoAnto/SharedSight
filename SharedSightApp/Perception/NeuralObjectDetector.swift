import CoreML
import Vision
import QuartzCore
import SharedSightCore

/// Real on-device inference with the bundled Core ML network (YOLO26n-seg, COCO classes).
/// There is no fallback detector: when the model is missing or fails, the error is surfaced and
/// perception is reported UNAVAILABLE.
final class NeuralObjectDetector {
    struct Output {
        let detections: [Detection]
        let decoded: [UUID: DecodedDetection]
        let prototypes: RawTensor?
        let letterbox: Letterbox
        let inputSize: Int
        let latency: Double
    }

    enum DetectorError: Error, CustomStringConvertible {
        case modelMissing, unexpectedOutputs(String)
        var description: String {
            switch self {
            case .modelMissing: return "SharedSightDetector model is not in the app bundle"
            case let .unexpectedOutputs(s): return "Unexpected model outputs: \(s)"
            }
        }
    }

    private(set) var modelID = "none"
    private(set) var supportsMasks = false
    private(set) var loadError: String?
    private(set) var classNames: [Int: String] = [:]
    private var request: VNCoreMLRequest?
    private var inputSize = 640
    /// Low on purpose: low-score boxes feed the tracker's second association stage, they are never announced by themselves.
    var confidenceThreshold: Float = 0.15

    var isLoaded: Bool { request != nil }

    func load() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: try Self.locateModel(), configuration: config)
            let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            let names = YOLODecoder.parseClassNames(meta["names"] ?? "")
            guard !names.isEmpty else { throw DetectorError.unexpectedOutputs("no class-name metadata") }
            if let c = model.modelDescription.inputDescriptionsByName.values.first?.imageConstraint { inputSize = c.pixelsWide }
            supportsMasks = model.modelDescription.outputDescriptionsByName.values.contains { ($0.multiArrayConstraint?.shape.count ?? 0) == 4 }
            let r = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            r.imageCropAndScaleOption = .scaleFit   // aspect-preserving letterbox, undone by `Letterbox`
            classNames = names
            modelID = "yolo26n-seg " + (meta["date"] ?? "")
            request = r
            loadError = nil
        } catch {
            request = nil
            loadError = String(describing: error)
        }
    }

    private static func locateModel() throws -> URL {
        if let compiled = Bundle.main.url(forResource: "SharedSightDetector", withExtension: "mlmodelc") { return compiled }
        if let package = Bundle.main.url(forResource: "SharedSightDetector", withExtension: "mlpackage") {
            return try MLModel.compileModel(at: package)
        }
        throw DetectorError.modelMissing
    }

    /// `decodeMasks == false` skips copying the mask prototypes (about 800 000 values) when nobody will draw them.
    /// The mask channel count is still read from the tensor shape: the box tensor's layout depends on it.
    func detect(_ frame: CameraFrame, decodeMasks: Bool = true) throws -> Output {
        guard let request else { throw DetectorError.modelMissing }
        let start = CACurrentMediaTime()
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation, options: [:]).perform([request])
        guard let results = request.results as? [VNCoreMLFeatureValueObservation] else {
            throw DetectorError.unexpectedOutputs("no feature values")
        }
        var boxes: RawTensor?, prototypes: RawTensor?, maskChannels = 0
        for r in results {
            guard let array = r.featureValue.multiArrayValue else { continue }
            let shape = array.shape.map(\.intValue)
            if shape.count == 4 {
                maskChannels = shape[1]
                if decodeMasks { prototypes = RawTensor(shape: shape, data: MLShapedArray<Float>(converting: array).scalars) }
            } else if shape.count == 3 {
                boxes = RawTensor(shape: shape, data: MLShapedArray<Float>(converting: array).scalars)
            }
        }
        guard let boxes else { throw DetectorError.unexpectedOutputs(results.map { $0.featureName }.joined(separator: ",")) }
        let letterbox = Letterbox(imageWidth: frame.uprightSize.width, imageHeight: frame.uprightSize.height)
        let decoded = try YOLODecoder.decode(output: boxes, maskChannels: maskChannels, inputSize: inputSize,
                                             letterbox: letterbox, confidenceThreshold: confidenceThreshold)
        var detections: [Detection] = [], byID: [UUID: DecodedDetection] = [:]
        for d in decoded {
            guard let label = classNames[d.classIndex] else { continue }   // never emit a label the model does not define
            let det = Detection(classIndex: d.classIndex, label: label, confidence: d.confidence, box: d.box,
                                timestamp: frame.timestamp, modelID: modelID, hasMask: prototypes != nil)
            detections.append(det)
            byID[det.id] = d
        }
        return Output(detections: detections, decoded: byID, prototypes: prototypes, letterbox: letterbox,
                      inputSize: inputSize, latency: CACurrentMediaTime() - start)
    }
}

/// Instance segmentation from the detector's real mask prototypes. Scheduled: only the most relevant
/// observed tracks, only every Nth frame. Tracks without a current mask fall back to their bounding box
/// and are labelled as such — masks are never synthesised.
final class ObstacleSegmentationEngine {
    struct TrackMask {
        let trackID: Int
        let outline: [CGPoint]      // upright image-normalised polygon
        let pixelCount: Int
        let timestamp: Timestamp
    }

    var maxInstances = 6
    var everyNthFrame = 2
    private(set) var lastLatency = 0.0
    private var frameIndex = 0
    private var cache: [Int: TrackMask] = [:]
    /// Whether the next call to `update` will compute masks (so the detector knows whether to decode prototypes).
    var runsNextFrame: Bool { (frameIndex + 1) % everyNthFrame == 0 }

    func update(tracks: [TrackSnapshot], priority: [Int: Double], output: NeuralObjectDetector.Output, now: Timestamp) -> [Int: TrackMask] {
        frameIndex += 1
        cache = cache.filter { now - $0.value.timestamp < 0.4 }   // a mask older than this is not shown as current
        guard let prototypes = output.prototypes, frameIndex % everyNthFrame == 0 else { return cache }
        let start = CACurrentMediaTime()
        let chosen = tracks.filter { $0.observedThisFrame && $0.confirmed }
            .sorted { (priority[$0.id] ?? 0) > (priority[$1.id] ?? 0) }.prefix(maxInstances)
        for t in chosen {
            guard let oid = t.lastObservationID, let d = output.decoded[oid],
                  let mask = MaskDecoder.decode(coefficients: d.maskCoefficients, prototypes: prototypes, inputBox: d.inputBox,
                                                inputSize: output.inputSize) else { continue }
            let outline = mask.outline(letterbox: output.letterbox).map { CGPoint(x: $0.x, y: $0.y) }
            if outline.count >= 3 { cache[t.id] = TrackMask(trackID: t.id, outline: outline, pixelCount: mask.pixelCount, timestamp: now) }
        }
        lastLatency = CACurrentMediaTime() - start
        return cache
    }
}
