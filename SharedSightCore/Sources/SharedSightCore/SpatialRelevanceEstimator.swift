import Foundation

/// What is known about the camera for the current frame. Nil means "not measured", never a default.
public struct CameraContext: Sendable, Equatable {
    public var horizontalFOVDeg: Double   // of the upright image actually analysed
    public var pitchDeg: Double?          // optical axis above (+) / below (-) the horizon
    public var rollDeg: Double?           // rotation about the optical axis relative to upright
    public var angularRate: Double?       // rad/s
    public var steady: Bool               // camera measured as nearly stationary => object-motion cues allowed

    public init(horizontalFOVDeg: Double, pitchDeg: Double?, rollDeg: Double?, angularRate: Double?, steady: Bool) {
        self.horizontalFOVDeg = horizontalFOVDeg; self.pitchDeg = pitchDeg; self.rollDeg = rollDeg
        self.angularRate = angularRate; self.steady = steady
    }

    /// Left/ahead/right wording is only meaningful when the camera is roughly upright and level.
    public var orientationSupportsDirection: Bool {
        guard let p = pitchDeg, let r = rollDeg else { return false }
        return abs(p) <= 40 && abs(r) <= 25
    }
}

public struct RelevanceConfig: Sendable {
    public var aheadFraction = 0.4        // central fraction of the half field of view called "ahead"
    public var maxFreshAge = 0.5
    public var approachScaleRate = 0.35   // relative size growth per second treated as an approach cue
    public var movingSpeed = 0.08         // normalised units / s
    public var minHitsForMotion = 5
    public var interestRadiusMeters = 5.0 // only used when a real distance measurement exists
    public init() {}
}

public struct RelevanceAssessment: Sendable, Equatable {
    public var trackID: Int
    public var bearingDeg: Double          // camera-relative, + right
    public var sector: Sector?             // nil when direction wording is not supported
    public var prominence: Double          // visual size cue (0...1), explicitly NOT a distance
    public var moving: Bool                // only true when the camera was measured steady
    public var approachCue: Bool
    public var distance: DistanceMeasurement?
    public var freshness: Double
    public var score: Double
}

/// Decides whether an observation may matter for the user's immediate surroundings.
/// Uses camera-relative image evidence only; metric statements require an injected measurement.
public struct SpatialRelevanceEstimator: Sendable {
    public var config: RelevanceConfig
    public init(config: RelevanceConfig = RelevanceConfig()) { self.config = config }

    public func bearing(forNormalizedX x: Double, horizontalFOVDeg: Double) -> Double {
        let half = horizontalFOVDeg * .pi / 360
        return atan((x - 0.5) * 2 * tan(half)) * 180 / .pi
    }

    /// Half-width in degrees of what is called "ahead" for a camera with this field of view.
    public func aheadHalfAngle(horizontalFOVDeg: Double) -> Double { max(6, config.aheadFraction * max(horizontalFOVDeg / 2, 1)) }

    public func assess(_ entry: MemoryEntry, camera: CameraContext, distance: DistanceMeasurement? = nil) -> RelevanceAssessment {
        let t = entry.track
        let halfFOV = max(camera.horizontalFOVDeg / 2, 1)
        let b = bearing(forNormalizedX: t.box.cx, horizontalFOVDeg: camera.horizontalFOVDeg)
        var sector: Sector?
        if camera.orientationSupportsDirection {
            let aheadLimit = aheadHalfAngle(horizontalFOVDeg: camera.horizontalFOVDeg)
            sector = abs(b) <= aheadLimit ? .ahead : (b < 0 ? .left : .right)
        }
        let motionAllowed = camera.steady && t.hits >= config.minHitsForMotion && t.observedThisFrame
        let moving = motionAllowed && t.speed >= config.movingSpeed
        let approach = motionAllowed && t.scaleRate >= config.approachScaleRate
        let freshness = entry.isCurrentEvidence ? max(0, 1 - entry.ageSinceObserved / config.maxFreshAge) : 0
        let centrality = 1 - min(1, abs(b) / halfFOV)
        let prominence = min(1, t.box.clampedToUnit.area.squareRoot() / 0.6)
        let lowerFrame = min(max((t.box.maxY - 0.4) / 0.6, 0), 1)
        var base = 0.35 * centrality + 0.30 * prominence + 0.20 * lowerFrame + 0.15 * ((moving || approach) ? 1 : 0)
        if let d = distance {
            let proximity = min(max(1 - (d.meters - 1) / max(config.interestRadiusMeters - 1, 0.1), 0), 1)
            base = 0.5 * base + 0.5 * proximity
        }
        return RelevanceAssessment(trackID: t.id, bearingDeg: b, sector: sector, prominence: prominence, moving: moving,
                                   approachCue: approach, distance: distance, freshness: freshness,
                                   score: freshness > 0 ? base : 0)
    }
}
