import Foundation

public enum EncounterState: String, Sendable, Equatable {
    case notAssessable, noConflictInHorizon, possibleConflict, estimatedImminentConflict
}
public enum EncounterSource: String, Sendable, Equatable { case localMeasurement, remoteMeasurement, prediction }
public enum EncounterUnavailable: String, Sendable, Equatable {
    case missingMotion, missingGeometry, missingPose, stale, uncertainty, outsideEnvelope, insufficientCadence
}

/// A conservative circular bound around a footprint; using the diagonal preserves vehicle LENGTH even without heading.
/// Class defaults are operational assumptions, not measured dimensions or calibrated confidence intervals.
public struct EncounterFootprint: Sendable, Equatable {
    public var length: Double, width: Double
    public var radius: Double { hypot(length, width) / 2 }
    public init(length: Double, width: Double) { self.length = length; self.width = width }
    public static func assumed(for label: String) -> Self? {
        switch label {
        case "car": return Self(length: 5, width: 2.2)
        case "truck", "bus": return Self(length: 12, width: 2.6)
        case "bicycle", "motorcycle": return Self(length: 2.2, width: 0.9)
        case "person": return Self(length: 0.7, width: 0.7)
        case "dog": return Self(length: 1.2, width: 0.6)
        case "cat": return Self(length: 0.6, width: 0.3)
        default: return nil
        }
    }
}

/// All positions/velocities use one metric world frame, never camera/body heading.
public struct EncounterMotion: Sendable, Equatable {
    public var position: Vec3
    public var velocity: Vec3? // nil is UNKNOWN, not stationary
    public var positionSigma: Double
    public var velocitySigma: Double?
    public var stateAt: Timestamp
    public var measurementAge: Double
    public init(position: Vec3, velocity: Vec3?, positionSigma: Double, velocitySigma: Double?, stateAt: Timestamp, measurementAge: Double) {
        self.position = position; self.velocity = velocity; self.positionSigma = positionSigma
        self.velocitySigma = velocitySigma; self.stateAt = stateAt; self.measurementAge = measurementAge
    }
}

public struct EncounterCandidate: Sendable, Equatable {
    public var id: String, label: String
    public var source: EncounterSource
    public var motion: EncounterMotion
    public var footprint: EncounterFootprint?
    public var occluder: OccluderKind?
    public init(id: String, label: String, source: EncounterSource, motion: EncounterMotion,
                footprint: EncounterFootprint?, occluder: OccluderKind? = nil) {
        self.id = id; self.label = label; self.source = source; self.motion = motion; self.footprint = footprint; self.occluder = occluder
    }
}

public struct EncounterResult: Sendable, Equatable {
    public var id: String, label: String, epoch: String
    public var source: EncounterSource
    public var state: EncounterState
    public var reason: EncounterUnavailable?
    public var evaluatedAt: Timestamp
    public var expiresAt: Timestamp
    public var tCPA: Double?, dCPA: Double?
    public var firstConflict: ClosedRange<Double>?
    public var sector: Sector? // explicitly CAMERA-relative, not body-relative
    public var distance: Double?
    public var occluder: OccluderKind?
    public var presenceEvidence = true // notAssessable retains presence, never implies low danger
    public var userMotionIsDeviceProxy: Bool
}

public struct EncounterConfig: Sendable {
    public var horizon = 3.0
    public var interval = 0.1
    public var imminentWithin = 1.5
    public var imminentMaxSigma = 0.75
    public var uncertaintyMultiplier = 2.0 // operational padding, NOT a calibrated probability
    public var accelerationDensity = 0.5
    public var nearZeroRelativeSpeed = 0.05
    public var maxMeasurementAge = 1.0
    /// A mover hidden behind a building is the case this exists for: its prediction stays assessable longer, with an
    /// uncertainty that keeps growing with age. It can be a possible conflict, never an imminent one (needs age ≤ 0.3 s).
    public var maxPredictionAge = 3.0
    public var maxStateAge = 0.5
    public var maxSigma = 2.0
    public var maxSampleInterval = 0.5
    public var validity = 0.6
    public var maxRange = 30.0 // evaluator envelope; app explicitly limits its current ground-plane input to 12 m
    public var userFootprint = EncounterFootprint(length: 0.7, width: 0.7)
    public init() {}
}

public struct EncounterRiskEvaluator: Sendable {
    public var config: EncounterConfig
    public init(config: EncounterConfig = EncounterConfig()) { self.config = config }
    public func evaluate(_ object: EncounterCandidate, user: EncounterMotion?, worldFromCamera: Pose?, epoch: String,
                         now: Timestamp, sampleInterval: Double, userMotionIsDeviceProxy: Bool = false) -> EncounterResult {
        var result = EncounterResult(id: object.id, label: object.label, epoch: epoch, source: object.source, state: .notAssessable,
            evaluatedAt: now, expiresAt: now + config.validity, occluder: object.occluder, userMotionIsDeviceProxy: userMotionIsDeviceProxy)
        func unavailable(_ reason: EncounterUnavailable) -> EncounterResult { var r = result; r.reason = reason; return r }
        guard let pose = worldFromCamera else { return unavailable(.missingPose) }
        guard let footprint = object.footprint, footprint.length.isFinite, footprint.width.isFinite,
              footprint.length > 0, footprint.width > 0 else { return unavailable(.missingGeometry) }
        guard let user, let uv = user.velocity, let ov = object.motion.velocity,
              let us = user.velocitySigma, let os = object.motion.velocitySigma else { return unavailable(.missingMotion) }
        let o = object.motion
        let numbers = [now, o.stateAt, user.stateAt, o.measurementAge, user.measurementAge, us, os,
                       o.positionSigma, user.positionSigma, uv.x, uv.z, ov.x, ov.z,
                       o.position.x, o.position.z, user.position.x, user.position.z]
        guard numbers.allSatisfy(\.isFinite), us >= 0, os >= 0, o.positionSigma >= 0, user.positionSigma >= 0 else { return unavailable(.uncertainty) }
        let odt = now - o.stateAt, udt = now - user.stateAt
        guard odt >= 0, udt >= 0, odt <= config.maxStateAge, udt <= config.maxStateAge,
              o.measurementAge >= 0, user.measurementAge >= 0,
              o.measurementAge <= (object.source == .prediction ? config.maxPredictionAge : config.maxMeasurementAge),
              user.measurementAge <= config.maxMeasurementAge else { return unavailable(.stale) }
        guard sampleInterval.isFinite, sampleInterval > 0, sampleInterval <= config.maxSampleInterval else { return unavailable(.insufficientCadence) }
        guard o.positionSigma <= config.maxSigma, user.positionSigma <= config.maxSigma else { return unavailable(.uncertainty) }
        let op = o.position + ov * odt, up = user.position + uv * udt
        let r = op - up, v = ov - uv, vv = v.x * v.x + v.z * v.z
        let distance = hypot(r.x, r.z)
        result.distance = distance
        guard distance <= config.maxRange else { return unavailable(.outsideEnvelope) }
        result.sector = HiddenObjectResolver.locate(op, from: pose, aheadHalfAngleDeg: 25)?.sector
        // Near-zero relative speed has no unique time of closest approach; do not manufacture one.
        if vv >= config.nearZeroRelativeSpeed * config.nearZeroRelativeSpeed {
            let t = min(max(-(r.x * v.x + r.z * v.z) / vv, 0), config.horizon)
            result.tCPA = t; result.dCPA = hypot(r.x + v.x * t, r.z + v.z * t)
        } else { result.tCPA = nil; result.dCPA = distance }
        // Each interval compares BOTH bodies at the SAME time. Midpoint motion padding bounds the swept
        // segment between samples, so a fast crossing between sample times cannot be silently missed.
        let step = max(0.01, config.interval), h = max(0, config.horizon)
        var t = 0.0
        while t < h {
            let end = min(t + step, h), mid = (t + end) / 2
            func sigma(_ p: Double, _ velocity: Double, _ age: Double) -> Double {
                p + velocity * age + sqrt(max(0, config.accelerationDensity) * age * age * age / 3)
            }
            let combinedSigma = sigma(o.positionSigma, os, odt + end) + sigma(user.positionSigma, us, udt + end)
            let radius = footprint.radius + config.userFootprint.radius + config.uncertaintyMultiplier * combinedSigma
            let lowerSeparation = hypot(r.x + v.x * mid, r.z + v.z * mid) - sqrt(vv) * (end - t) / 2
            if lowerSeparation <= radius {
                result.firstConflict = t...end
                result.state = .possibleConflict
                // Deliberately strict, configurable heuristic: near-term overlap with bounded input uncertainty.
                if end <= config.imminentWithin, combinedSigma <= config.imminentMaxSigma,
                   o.measurementAge <= 0.3, user.measurementAge <= 0.3 {
                    result.state = .estimatedImminentConflict
                }
                return result
            }
            t = end
        }
        result.state = .noConflictInHorizon
        return result
    }
}

/// AR camera translation is a measured DEVICE proxy, not a body heading/trajectory sensor.
/// No velocity is supplied until a tracked pair is available; rotation never enters this calculation.
public struct DeviceMotionProxy: Sendable {
    /// Positions over the last ~0.6 s. Velocity is the displacement across at least 0.2 s of them: it works at any
    /// frame rate (two frames 1/30 s apart are too close to measure walking) and averages out the sway of each step.
    private var samples: [(position: Vec3, time: Timestamp)] = []
    public private(set) var motion: EncounterMotion?
    public private(set) var interval: Double = .infinity
    public var window = 0.6, minimumSpan = 0.2, maximumGap = 0.5
    public init() {}
    public mutating func reset() { samples = []; motion = nil; interval = .infinity }
    public mutating func update(pose: Pose?, time: Timestamp) {
        guard let pose, time.isFinite else { reset(); return }
        if let last = samples.last {
            let dt = time - last.time
            guard dt > 0 else { return }                       // the same frame twice
            interval = dt
            if dt > maximumGap { samples = []; motion = nil }   // a gap: older positions say nothing about now
        }
        samples.append((pose.translation, time))
        samples.removeAll { time - $0.time > window }
        guard let first = samples.first, time - first.time >= minimumSpan else { motion = nil; return }
        let v = (pose.translation - first.position) * (1 / (time - first.time))
        guard v.length.isFinite, v.length <= 4 else { motion = nil; return }
        motion = EncounterMotion(position: pose.translation, velocity: Vec3(v.x, 0, v.z), positionSigma: 0.35,
                                 velocitySigma: 0.5, stateAt: time, measurementAge: 0)
    }
}
