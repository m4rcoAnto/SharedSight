import Foundation

/// A floor position that was actually measured for a locally tracked object (ARKit raycast / depth), world frame.
public struct GroundObservation: Sendable, Equatable {
    public var trackID: Int
    public var label: String
    public var position: Vec3
    public var sigma: Double
    public init(trackID: Int, label: String, position: Vec3, sigma: Double) {
        self.trackID = trackID; self.label = label; self.position = position; self.sigma = sigma
    }
}

/// Where a mover that this phone was tracking probably is now that it cannot be seen. An estimate, never evidence.
public struct HiddenEstimate: Sendable, Equatable, Identifiable {
    public var id: Int { trackID }
    public var trackID: Int
    public var label: String
    public var position: Vec3          // world frame
    public var sigma: Double           // metres, grows while unobserved
    public var speed: Double           // m/s of the estimate
    public var occluder: OccluderKind? // nil = it left the field of view
    public var age: Double             // seconds since it was last measured
    public var velocity: Vec3? = nil    // world-frame m/s; nil for legacy callers without a vector
}

public struct GroundMemoryConfig: Sendable {
    public var observedHold = 0.45        // seconds an object counts as seen after its last measurement
    public var range = 10.0
    public var noiseObserved = 0.22       // x acceleration^2 = continuous process-noise density
    public var noiseHidden = 0.1          // use max of both densities for every interval, independent of visibility
    public var hiddenMaxAge = 8.0
    public var hiddenMaxSigma = 2.0
    public var missGrace = 0.9            // in clear view but undetected this long => the estimate is dropped
    public var reacquireRadius = 0.8      // + 2 sigma: a new track this close to an estimate replaces it
    public var minMovingSpeed = 0.3       // m/s: slower estimated motion is not applied (a still person does not drift)
    public init() {}
}

/// Metric memory is separate from 2D detection and report validity. Predictions use constant velocity,
/// continuous process noise and the complete elapsed interval. A wall conflict invalidates the estimate;
/// absence of a detection never invents a turn or a hiding place.
public final class GroundTrackMemory {
    public var config: GroundMemoryConfig

    private struct Entry {
        var label: String
        var x: ScalarCVFilter
        var z: ScalarCVFilter
        var floorY: Double
        var measurements = 1
        var firstMeasured: Timestamp = 0
        var lastObserved: Timestamp
        var lastStep: Timestamp
        var missSince: Timestamp?
        var occluder: OccluderKind?
        var outOfView = false
        var hiddenValid = false
        /// Significant motion at the last measurement. Decided there, not on the covariance that grows while
        /// predicting, so the result does not depend on how many steps the prediction is split into.
        var moving = false
    }
    private var entries: [Int: Entry] = [:]
    /// Retained until a new valid metric measurement or reset; expiration does not mean danger has ended.
    public private(set) var invalidations: [Int: HiddenInvalidationReason] = [:]
    private var lastUpdate: Timestamp?

    private func invalidate(_ id: Int, _ reason: HiddenInvalidationReason) {
        // Report invalidation does not erase the filter: a later measurement must see the same
        // covariance regardless of intermediate display/update calls. Discard only unusable geometry/time.
        if ![HiddenInvalidationReason.age, .uncertainty, .unconfirmed, .missingPose].contains(reason) { entries[id] = nil }
        invalidations[id] = reason
    }

    public init(config: GroundMemoryConfig = GroundMemoryConfig()) { self.config = config }

    public func reset() { entries.removeAll(); invalidations.removeAll(); lastUpdate = nil }

    /// Current filtered floor position of a tracked object, if this memory has one.
    public func position(of trackID: Int) -> (position: Vec3, sigma: Double)? {
        guard let e = entries[trackID], invalidations[trackID] == nil else { return nil }
        return (Vec3(e.x.p, e.floorY, e.z.p), sigma(e))
    }

    /// Metric input for encounter evaluation, including directly observed tracks; no audio/radius filtering here.
    public func encounterCandidates(now: Timestamp, observedIDs: Set<Int>) -> [EncounterCandidate] {
        entries.compactMap { id, e in
            guard invalidations[id] == nil, now >= e.lastObserved else { return nil }
            let known = e.measurements >= 3 && e.lastObserved - e.firstMeasured >= 0.2
            return EncounterCandidate(id: "L:\(id)", label: e.label,
                source: observedIDs.contains(id) ? .localMeasurement : .prediction,
                motion: EncounterMotion(position: Vec3(e.x.p, e.floorY, e.z.p),
                    velocity: known ? Vec3(e.x.v, 0, e.z.v) : nil, positionSigma: sigma(e),
                    velocitySigma: known ? sqrt(max(e.x.c22, e.z.c22)) : nil,
                    stateAt: e.lastStep, measurementAge: now - e.lastObserved),
                footprint: .assumed(for: e.label), occluder: e.occluder)
        }
    }

    private func sigma(_ e: Entry) -> Double { max(e.x.c11, e.z.c11).squareRoot() }
    private func speed(_ e: Entry) -> Double { (e.x.v * e.x.v + e.z.v * e.z.v).squareRoot() }
    /// Velocity significantly different from zero: at least `minMovingSpeed` and two standard deviations.
    private func isMoving(_ e: Entry) -> Bool {
        let v = speed(e), sv = max(e.x.c22, e.z.c22, 0).squareRoot()
        return v >= config.minMovingSpeed && v >= 2 * sv
    }
    private func target(_ id: Int?, _ e: Entry, x: Double? = nil, z: Double? = nil) -> SightTarget {
        SightTarget(id: id, x: x ?? e.x.p, z: z ?? e.z.p, floorY: e.floorY, height: NominalSize.height(e.label),
                    radius: NominalSize.width(e.label) / 2)
    }

    /// - Parameters:
    ///   - observations: floor positions measured in this frame.
    ///   - observedTrackIDs: every track detected in this frame, including those whose position could not be measured
    ///     (for example feet outside the picture). They are known to be there, so they are not "hidden".
    ///   - camera: nil when ARKit is not tracking or the phone has no heading on the floor; no estimate is offered then.
    public func update(observations: [GroundObservation], observedTrackIDs: Set<Int>, camera: FloorCamera?, fovDeg: Double,
                       walls: [WallSegment], now: Timestamp) -> [HiddenEstimate] {
        guard now.isFinite, lastUpdate.map({ now >= $0 }) ?? true else {
            for id in Array(entries.keys) { invalidate(id, .invalidTime) }; return []
        }
        lastUpdate = now
        // 1. Predict the entire interval. Constant density makes subdivision immaterial.
        for id in Array(entries.keys) {
            guard var e = entries[id] else { continue }
            let dt = now - e.lastStep
            guard dt > 0 else { continue }
            if now - e.lastObserved > 30 { invalidate(id, .excessiveGap); continue }
            e.lastStep = now
            let mover = NominalSize.isMover(e.label), a = NominalSize.acceleration(e.label)
            let density = a * a * max(config.noiseObserved, config.noiseHidden)
            let px = e.x.p, pz = e.z.p
            if mover {
                let still = !e.moving
                e.x.predict(dt: dt, density: density); e.z.predict(dt: dt, density: density)
                // A still person's velocity estimate is never exactly zero: moving them by it makes them drift.
                // Motion is applied only when significant; otherwise only the uncertainty grows.
                if still { e.x.p = px; e.z.p = pz }
                if SightGeometry.move(x: px, z: pz, dx: e.x.p - px, dz: e.z.p - pz,
                                      walls: walls, floorY: e.floorY).hit != nil {
                    invalidate(id, .barrierConflict); continue
                }
            } else {
                // Static random walk: no invented velocity and no covariance clamp.
                e.x.c11 += a * a * dt; e.z.c11 += a * a * dt
            }
            entries[id] = e
        }

        // 2. Correct with this frame's measurements.
        for o in observations {
            guard o.sigma.isFinite, o.sigma >= 0,
                  o.position.x.isFinite, o.position.y.isFinite, o.position.z.isFinite else {
                invalidate(o.trackID, .invalidMeasurement); continue
            }
            // Reject a measurement that cannot support this metric memory, never sharpen it by clamping.
            guard o.sigma <= config.hiddenMaxSigma else { invalidate(o.trackID, .uncertainty); continue }
            let r = max(o.sigma, 0.05)
            invalidations[o.trackID] = nil
            if var e = entries[o.trackID] {
                e.x.update(z: o.position.x, r: r * r); e.z.update(z: o.position.z, r: r * r)
                e.floorY += (o.position.y - e.floorY) * 0.3
                e.label = o.label; e.measurements += 1; e.lastObserved = now; e.missSince = nil; e.occluder = nil; e.outOfView = false; e.hiddenValid = false
                e.moving = isMoving(e)
                entries[o.trackID] = e
            } else {
                // A new track right where an estimate was waiting: the estimate has served its purpose.
                for (id, h) in entries where h.label == o.label && now - h.lastObserved > config.observedHold {
                    let d = ((h.x.p - o.position.x) * (h.x.p - o.position.x) + (h.z.p - o.position.z) * (h.z.p - o.position.z)).squareRoot()
                    if d <= min(config.reacquireRadius + 2 * sigma(h), 3) { invalidate(id, .superseded) }
                }
                let vv = NominalSize.isMover(o.label) ? 1.0 : 0.0004
                entries[o.trackID] = Entry(label: o.label,
                                           x: ScalarCVFilter(position: o.position.x, positionVariance: r * r, velocityVariance: vv),
                                           z: ScalarCVFilter(position: o.position.z, positionVariance: r * r, velocityVariance: vv),
                                           floorY: o.position.y, firstMeasured: now, lastObserved: now, lastStep: now)
            }
        }
        // Detected without a measurable floor point: still there, simply not located this frame.
        for id in observedTrackIDs where entries[id] != nil && !observations.contains(where: { $0.trackID == id }) {
            entries[id]!.missSince = nil; entries[id]!.hiddenValid = false // 2D evidence does not date a metric measurement
        }

        // 3. Why is each unobserved mover not detected?
        let seen = entries.filter { now - $0.value.lastObserved <= config.observedHold }
        let blockers = seen.map { target($0.key, $0.value) }
        var out: [HiddenEstimate] = []
        for id in Array(entries.keys).sorted() {
            guard var e = entries[id], now - e.lastObserved > config.observedHold else { continue }
            let age = now - e.lastObserved
            guard NominalSize.isMover(e.label) else { if age > 30 { invalidate(id, .excessiveGap) }; continue }   // furniture: nothing to predict
            if age > config.hiddenMaxAge { invalidate(id, .age); continue }
            if sigma(e) > config.hiddenMaxSigma { invalidate(id, .uncertainty); continue }
            if invalidations[id] == .unconfirmed && age > config.missGrace { continue } // a new metric measurement is required
            if observedTrackIDs.contains(id) { continue } // visible in 2D, without renewing metric age
            guard let camera else { e.hiddenValid = false; entries[id] = e; invalidations[id] = .missingPose; continue }
            invalidations[id] = nil
            let rel = SightGeometry.relation(camera: camera, fovDeg: fovDeg, range: config.range, target: target(id, e),
                                             walls: walls, blockers: blockers).relation
            switch rel {
            case .visible:
                e.hiddenValid = false
                invalidations[id] = .unconfirmed
                if age > config.missGrace { invalidate(id, .unconfirmed); continue }
            case .partial, .occluded:
                e.missSince = nil; e.hiddenValid = true; e.outOfView = false
                if case let .occluded(kind) = rel { e.occluder = kind } else { e.occluder = e.occluder ?? .object }
            case .outOfView, .outOfRange:
                e.missSince = nil; e.hiddenValid = true; e.outOfView = true; e.occluder = nil
            }
            entries[id] = e
            if e.hiddenValid {
                let moving = e.moving
                out.append(HiddenEstimate(trackID: id, label: e.label, position: Vec3(e.x.p, e.floorY, e.z.p), sigma: sigma(e),
                                          speed: moving ? speed(e) : 0, occluder: e.outOfView ? nil : e.occluder, age: age,
                                          velocity: moving ? Vec3(e.x.v, 0, e.z.v) : Vec3(0, 0, 0)))
            }
        }
        return out
    }

}
