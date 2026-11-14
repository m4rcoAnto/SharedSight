import Foundation

/// Dense tensor copied out of the inference runtime (row-major, like MLMultiArray with unit strides).
public struct RawTensor: Sendable {
    public var shape: [Int]
    public var data: [Float]
    public init(shape: [Int], data: [Float]) { self.shape = shape; self.data = data }
}

/// Aspect-preserving, centred fit of the camera image into the square network input.
public struct Letterbox: Sendable, Equatable {
    public let contentW: Double, contentH: Double, padX: Double, padY: Double  // fractions of the square input
    public init(imageWidth: Double, imageHeight: Double) {
        let s = max(imageWidth, imageHeight)
        contentW = imageWidth / s; contentH = imageHeight / s
        padX = (1 - contentW) / 2; padY = (1 - contentH) / 2
    }
    /// Square-input normalised point -> image normalised point.
    public func toImage(x: Double, y: Double) -> (x: Double, y: Double) { ((x - padX) / contentW, (y - padY) / contentH) }
}

public struct DecodedDetection: Sendable {
    public var classIndex: Int
    public var confidence: Double
    public var box: NormRect                         // image-normalised
    public var inputBox: (x1: Float, y1: Float, x2: Float, y2: Float) // network-input pixels
    public var maskCoefficients: [Float]
}

public enum DecodeError: Error, Equatable { case unsupportedLayout([Int]) }

/// Decoder for YOLO-family Core ML heads. Two real layouts are supported and auto-detected:
///  * end-to-end / NMS-free (YOLOv10, YOLO26):  [1, N, 6 + nm]  rows = [x1, y1, x2, y2, score, class, coeffs...]
///  * classic (YOLOv8/11):                       [1, 4 + nc + nm, A]  channels = [cx, cy, w, h, class scores..., coeffs...]
/// Anything else is rejected with an explicit error instead of being guessed.
public enum YOLODecoder {
    public static func decode(output: RawTensor, maskChannels nm: Int, inputSize: Int, letterbox: Letterbox,
                              confidenceThreshold: Float, iouThreshold: Float = 0.5, maxDetections: Int = 40) throws -> [DecodedDetection] {
        let dims = output.shape.count == 3 ? Array(output.shape.dropFirst()) : output.shape
        guard dims.count == 2, dims[0] * dims[1] == output.data.count else { throw DecodeError.unsupportedLayout(output.shape) }
        let s = Float(inputSize)
        var out: [DecodedDetection] = []

        func make(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ score: Float, _ cls: Int, _ coeffs: [Float]) -> DecodedDetection? {
            // Some exports emit normalised coordinates; detect by range.
            let scale: Float = max(x2, y2) <= 1.5 ? s : 1
            let a = (x1 * scale, y1 * scale, x2 * scale, y2 * scale)
            let p0 = letterbox.toImage(x: Double(a.0 / s), y: Double(a.1 / s))
            let p1 = letterbox.toImage(x: Double(a.2 / s), y: Double(a.3 / s))
            let box = NormRect(x: p0.x, y: p0.y, w: p1.x - p0.x, h: p1.y - p0.y).clampedToUnit
            guard box.w > 0.01, box.h > 0.01 else { return nil }
            return DecodedDetection(classIndex: cls, confidence: Double(score), box: box, inputBox: a, maskCoefficients: coeffs)
        }

        if dims[1] == 6 + nm && dims[0] != 6 + nm {
            let n = dims[0], c = dims[1]
            for r in 0..<n {
                let o = r * c
                let score = output.data[o + 4]
                guard score >= confidenceThreshold else { continue }
                let coeffs = nm > 0 ? Array(output.data[(o + 6)..<(o + 6 + nm)]) : []
                if let d = make(output.data[o], output.data[o + 1], output.data[o + 2], output.data[o + 3], score,
                                Int(output.data[o + 5].rounded()), coeffs) { out.append(d) }
            }
        } else if dims[0] > 4 + nm && dims[1] > dims[0] {
            let c = dims[0], a = dims[1], nc = c - 4 - nm
            for i in 0..<a {
                var best: Float = 0, bestC = 0
                for k in 0..<nc { let v = output.data[(4 + k) * a + i]; if v > best { best = v; bestC = k } }
                guard best >= confidenceThreshold else { continue }
                let cx = output.data[i], cy = output.data[a + i], w = output.data[2 * a + i], h = output.data[3 * a + i]
                var coeffs: [Float] = []
                if nm > 0 { coeffs = (0..<nm).map { output.data[(4 + nc + $0) * a + i] } }
                if let d = make(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, best, bestC, coeffs) { out.append(d) }
            }
            out = nms(out, iouThreshold: Double(iouThreshold))
        } else {
            throw DecodeError.unsupportedLayout(output.shape)
        }
        out.sort { $0.confidence > $1.confidence }
        return Array(out.prefix(maxDetections))
    }

    static func nms(_ dets: [DecodedDetection], iouThreshold: Double) -> [DecodedDetection] {
        var kept: [DecodedDetection] = []
        for d in dets.sorted(by: { $0.confidence > $1.confidence }) {
            if !kept.contains(where: { $0.classIndex == d.classIndex && $0.box.iou(d.box) > iouThreshold }) { kept.append(d) }
        }
        return kept
    }

    /// Parses the class-name dictionary Ultralytics stores in Core ML metadata: "{0: 'person', 1: 'bicycle', ...}".
    public static func parseClassNames(_ metadata: String) -> [Int: String] {
        var names: [Int: String] = [:]
        let body = metadata.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n"))
        for part in body.components(separatedBy: ",") {
            let kv = part.components(separatedBy: ":")
            guard kv.count >= 2, let idx = Int(kv[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = kv[1...].joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if !name.isEmpty { names[idx] = name }
        }
        return names
    }
}

/// Binary instance mask cropped to its detection box, in prototype-grid pixels.
public struct InstanceMask: Sendable, Equatable {
    public let originX: Int, originY: Int, width: Int, height: Int
    public let gridWidth: Int, gridHeight: Int
    public let bits: [Bool]
    public var pixelCount: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Silhouette polygon (left edge top-to-bottom, then right edge bottom-to-top) in image-normalised
    /// coordinates. Exact for row-convex shapes; concavities inside a row are bridged.
    public func outline(letterbox: Letterbox) -> [(x: Double, y: Double)] {
        var left: [(Double, Double)] = [], right: [(Double, Double)] = []
        for r in 0..<height {
            var first = -1, last = -1
            for c in 0..<width where bits[r * width + c] { if first < 0 { first = c }; last = c }
            guard first >= 0 else { continue }
            let y = (Double(originY + r) + 0.5) / Double(gridHeight)
            left.append(letterbox.toImage(x: Double(originX + first) / Double(gridWidth), y: y))
            right.append(letterbox.toImage(x: Double(originX + last + 1) / Double(gridWidth), y: y))
        }
        return (left + right.reversed()).map { (x: min(max($0.0, 0), 1), y: min(max($0.1, 0), 1)) }
    }
}

/// YOLACT-style mask assembly used by YOLO segmentation heads: mask = sigmoid(coeffs · prototypes) > 0.5,
/// evaluated only inside the detection box. Produces nothing when the model provides no prototypes.
public enum MaskDecoder {
    public static func decode(coefficients: [Float], prototypes: RawTensor,
                              inputBox: (x1: Float, y1: Float, x2: Float, y2: Float), inputSize: Int) -> InstanceMask? {
        let dims = prototypes.shape.count == 4 ? Array(prototypes.shape.dropFirst()) : prototypes.shape
        guard dims.count == 3, dims[0] == coefficients.count, !coefficients.isEmpty else { return nil }
        let nm = dims[0], gh = dims[1], gw = dims[2]
        let k = Float(gw) / Float(inputSize)
        let x0 = max(0, Int((inputBox.x1 * k).rounded(.down))), y0 = max(0, Int((inputBox.y1 * k).rounded(.down)))
        let x1 = min(gw, Int((inputBox.x2 * k).rounded(.up))), y1 = min(gh, Int((inputBox.y2 * k).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let w = x1 - x0, h = y1 - y0, plane = gh * gw
        var bits = [Bool](repeating: false, count: w * h)
        prototypes.data.withUnsafeBufferPointer { p in
            for r in 0..<h {
                for c in 0..<w {
                    let idx = (y0 + r) * gw + (x0 + c)
                    var acc: Float = 0
                    for m in 0..<nm { acc += coefficients[m] * p[m * plane + idx] }
                    bits[r * w + c] = acc > 0   // sigmoid(acc) > 0.5
                }
            }
        }
        return InstanceMask(originX: x0, originY: y0, width: w, height: h, gridWidth: gw, gridHeight: gh, bits: bits)
    }
}
