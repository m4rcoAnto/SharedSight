import Foundation

/// Seconds on the device's monotonic media clock (CACurrentMediaTime / capture presentation time).
public typealias Timestamp = Double

/// One direct neural observation in one frame. Never fabricated: produced only by NeuralObjectDetector.
public struct Detection: Identifiable, Sendable, Equatable {
    public let id: UUID            // local observation identifier
    public let classIndex: Int
    public let label: String       // label exactly as published by the model
    public let confidence: Double
    public let box: NormRect
    public let timestamp: Timestamp // capture time of the frame
    public let modelID: String
    public let hasMask: Bool

    public init(id: UUID = UUID(), classIndex: Int, label: String, confidence: Double, box: NormRect,
                timestamp: Timestamp, modelID: String, hasMask: Bool = false) {
        self.id = id; self.classIndex = classIndex; self.label = label; self.confidence = confidence
        self.box = box; self.timestamp = timestamp; self.modelID = modelID; self.hasMask = hasMask
    }
}

public enum ObservationSource: Equatable, Sendable {
    case localCamera
    case peer(cameraID: String)
}

/// Short-term memory state of an obstacle hypothesis (spec 3.6).
public enum MemoryState: String, Codable, Sendable {
    case observed = "OBSERVED"
    case temporarilyHidden = "TEMPORARILY_HIDDEN"
    case predicted = "PREDICTED"
    case unknown = "UNKNOWN"
    case reacquired = "REACQUIRED"
    case lost = "LOST"
}

/// Camera-relative sector. `behind` is only ever produced from validated 3D geometry (peer observations).
public enum Sector: String, Codable, Sendable { case left, ahead, right, behind }

/// A distance that was actually measured — or, when `method` says so, predicted. Bounding-box size is never a source.
public struct DistanceMeasurement: Codable, Equatable, Sendable {
    /// `motionPrediction` is not a measurement of where the object is now: it is where the motion model puts it.
    public enum Method: String, Codable, Sendable { case lidarDepth, groundPlaneRaycast, sharedAnchor, motionPrediction, surfaceRaycast }
    public var meters: Double
    public var sigma: Double
    public var method: Method
    public init(meters: Double, sigma: Double, method: Method) { self.meters = meters; self.sigma = sigma; self.method = method }
}

/// Scene region semantics kept strictly separate (spec 3.4). "No detection" maps to `unknown`, never to free space.
public enum RegionKind: String, Codable, Sendable {
    case knownSemanticObject = "KNOWN_SEMANTIC_OBJECT"
    case potentialObstruction = "POTENTIAL_OBSTRUCTION"
    case observedFloor = "OBSERVED_FLOOR_REGION"
    case unknown = "UNKNOWN_REGION"
}

/// Global image shift of static scene content between two frames, from CameraMotionEstimator.
public struct FrameMotion: Sendable, Equatable {
    public var dx: Double
    public var dy: Double
    public var reliable: Bool
    public init(dx: Double, dy: Double, reliable: Bool) { self.dx = dx; self.dy = dy; self.reliable = reliable }
}
