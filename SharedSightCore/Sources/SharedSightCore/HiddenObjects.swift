import Foundation

/// One entry of the hub's reply to a posted frame (protocol v3): something this phone cannot see itself.
/// `position` is in the same frame the phone posts in (shared marker frame when aligned, its own world otherwise).
public struct ServerAdvisory: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String            // "seen": measured now by another phone · "estimated": predicted, seen by nobody
    public var label: String
    public var position: Vec3
    public var sigma: Double
    public var relation: String        // "occluded" | "outOfView"
    public var occluder: String?       // "wall" | "door" | "object"
    public var seenBy: Int
    public var localID: Int?           // this phone's own track number, when it was following the object before
    public var moving: Bool?
    /// Additional age uncertainty; nil means no finite upper bound is known.
    public var ageUncertaintyMs: Double?
    /// Lower bound on age at server reply generation.
    public var ageMs: Double?
    public var velocitySigma: Double?
    public var stateAgeUpperMs: Double?
    public var velocity: FloorVelocity? // metres per second on the floor, same frame as `position`

    public struct FloorVelocity: Codable, Equatable, Sendable {
        public var x: Double, z: Double
        public init(x: Double, z: Double) { self.x = x; self.z = z }
    }

    public init(id: String, kind: String, label: String, position: Vec3, sigma: Double, relation: String, occluder: String? = nil,
                seenBy: Int, localID: Int? = nil, moving: Bool? = nil, ageMs: Double? = nil, ageUncertaintyMs: Double? = nil, velocity: FloorVelocity? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.position = position; self.sigma = sigma; self.relation = relation
        self.occluder = occluder; self.seenBy = seenBy; self.localID = localID; self.moving = moving; self.ageMs = ageMs
        self.velocity = velocity; self.ageUncertaintyMs = ageUncertaintyMs
    }
}

public struct ServerReply: Codable, Equatable, Sendable {
    public var v: Int
    public var advisories: [ServerAdvisory]
    public var devices: Int?
    public var epoch: String?
    public var sequence: Int?
    public var receiptToken: String?
    public init(v: Int = 3, advisories: [ServerAdvisory], devices: Int? = nil,
                epoch: String? = nil, sequence: Int? = nil, receiptToken: String? = nil) {
        self.v = v; self.advisories = advisories; self.devices = devices
        self.epoch = epoch; self.sequence = sequence; self.receiptToken = receiptToken
    }

    public func matches(epoch: String, sequence: Int) -> Bool {
        self.epoch == epoch && self.sequence == sequence
    }

    public func atReceipt(roundTrip: Double) -> [ServerAdvisory] {
        guard roundTrip.isFinite, roundTrip >= 0 else { return [] }
        return advisories.map { advisory in
            var result = advisory
            result.stateAgeUpperMs = roundTrip * 1000
            if let uncertainty = result.ageUncertaintyMs { result.ageUncertaintyMs = uncertainty + roundTrip * 1000 }
            return result
        }
    }

    /// Old protocols have no bounded-age contract and are explicitly incompatible.
    public static func decode(_ data: Data) -> ServerReply? {
        guard let reply = try? JSONDecoder().decode(ServerReply.self, from: data), reply.v == 3,
              let epoch = reply.epoch, !epoch.isEmpty, let sequence = reply.sequence, sequence >= 0,
              let token = reply.receiptToken, !token.isEmpty else { return nil }
        return reply
    }
}

/// Reasons for withholding/expiring a report, never a declaration that danger has ended.
public enum HiddenInvalidationReason: String, Sendable, Equatable {
    case age, uncertainty, unknownAge, missingPose, unconfirmed, barrierConflict
    case invalidTime, excessiveGap, invalidMeasurement, outOfRange, unsupported, superseded
}

public struct HiddenResolution: Sendable {
    public var reports: [HiddenReport]
    public var invalidations: [String: HiddenInvalidationReason]
}

/// Something that exists near the user but that this phone's camera cannot see right now.
public struct HiddenReport: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case otherDevice(count: Int)   // measured now by that many other phones
        case prediction                // nobody sees it: motion-model estimate
    }
    public var id: String              // "S:<hub id>" or "L:<local track>"
    public var label: String
    public var source: Source
    public var occluder: OccluderKind? // nil = outside the field of view
    public var sector: Sector?
    public var bearingDeg: Double?
    public var distance: DistanceMeasurement
    public var localTrackID: Int?      // set when this phone was following it before it disappeared
    public var moving: Bool
    public var age: Double             // seconds since anybody measured it
    /// Metres per second at which it is getting nearer to the user (negative = moving away). Zero when unknown.
    public var closingSpeed: Double = 0
    public var velocity: Vec3? = nil // world-frame m/s, preserved for both measured and predicted reports
    public var isMover: Bool { NominalSize.isMover(label) }
    public var isPrediction: Bool { source == .prediction }
}

public struct HiddenResolverConfig: Sendable {
    public var advisoryTTL = 1.0             // a hub reply older than this is not acted upon
    public var maxPositionSigma = 1.5        // beyond this an estimate is too vague to be given a direction
    public var radius = 8.0
    public var localMaxAge = 8.0
    public init() {}
}

/// Turns hub advisories and this phone's own estimates into camera-relative reports. Directions need a tracked pose:
/// without one nothing is reported, because a hidden object without a direction is noise, not help.
public struct HiddenObjectResolver: Sendable {
    public var config: HiddenResolverConfig
    public init(config: HiddenResolverConfig = HiddenResolverConfig()) { self.config = config }

    /// - Parameters:
    ///   - worldFromReference: maps the frame advisories are expressed in to this phone's world frame
    ///     (worldFromAnchor when the phone posts in the shared marker frame, identity otherwise).
    ///   - aheadHalfAngleDeg: half-width of "ahead". Pass the same value the camera's own detections use
    ///     (`SpatialRelevanceEstimator.aheadHalfAngle`) so that "ahead" means one thing to the listener.
    public func resolve(advisories: [ServerAdvisory], advisoryAge: Double?, worldFromReference: Pose,
                        estimates: [HiddenEstimate], worldFromCamera: Pose?, trackingNormal: Bool,
                        aheadHalfAngleDeg: Double = 25) -> [HiddenReport] {
        resolveDetailed(advisories: advisories, advisoryAge: advisoryAge, worldFromReference: worldFromReference,
                        estimates: estimates, worldFromCamera: worldFromCamera, trackingNormal: trackingNormal,
                        aheadHalfAngleDeg: aheadHalfAngleDeg).reports
    }

    public func resolveDetailed(advisories: [ServerAdvisory], advisoryAge: Double?, worldFromReference: Pose,
                        estimates: [HiddenEstimate], worldFromCamera: Pose?, trackingNormal: Bool,
                        aheadHalfAngleDeg: Double = 25) -> HiddenResolution {
        var invalidations: [String: HiddenInvalidationReason] = [:]
        guard trackingNormal, let worldFromCamera else {
            for a in advisories { invalidations["S:" + a.id] = .missingPose }
            for e in estimates { invalidations["L:\(e.trackID)"] = .missingPose }
            return HiddenResolution(reports: [], invalidations: invalidations)
        }
        let residence = advisoryAge ?? .infinity
        var out: [HiddenReport] = []
        let ownEstimates = Set(estimates.filter {
            $0.age.isFinite && $0.age >= 0 && $0.age <= config.localMaxAge &&
            $0.sigma.isFinite && $0.sigma >= 0 && $0.sigma <= config.maxPositionSigma
        }.map(\.trackID))
        var seenByOthers = Set<Int>()

        for a in advisories {
            let id = "S:" + a.id
            guard residence.isFinite, residence >= 0, residence <= config.advisoryTTL else {
                invalidations[id] = .age; continue
            }
            guard let lower = a.ageMs, lower.isFinite, lower >= 0,
                  let uncertainty = a.ageUncertaintyMs, uncertainty.isFinite, uncertainty >= 0 else { invalidations[id] = .unknownAge; continue }
            let ageUpper = (lower + uncertainty) / 1000 + residence
            guard ageUpper <= config.advisoryTTL else { invalidations[id] = .age; continue }
            let occluder = a.relation == "occluded" ? (OccluderKind(rawValue: a.occluder ?? "") ?? .object) : nil
            guard a.relation == "occluded" || a.relation == "outOfView" else { invalidations[id] = .unsupported; continue }
            let source: HiddenReport.Source
            switch a.kind {
            case "seen" where a.seenBy > 0: source = .otherDevice(count: a.seenBy)
            case "estimated":
                // This phone predicts its own lost tracks itself (it works without the hub too): avoid saying it twice.
                if let local = a.localID, ownEstimates.contains(local) { invalidations[id] = .superseded; continue }
                source = .prediction
            default: invalidations[id] = .unsupported; continue
            }
            guard a.sigma.isFinite, a.sigma >= 0, a.sigma <= config.maxPositionSigma else { invalidations[id] = .uncertainty; continue }
            let world = worldFromReference.transform(a.position)
            guard let place = Self.locate(world, from: worldFromCamera, aheadHalfAngleDeg: aheadHalfAngleDeg),
                  place.meters <= config.radius else { invalidations[id] = .outOfRange; continue }
            if case .otherDevice = source, let local = a.localID { seenByOthers.insert(local) }
            // Approach speed: the measured velocity projected on the line from the object to the user.
            var closing = 0.0
            var velocity: Vec3?
            if let v = a.velocity, v.x.isFinite, v.z.isFinite {
                velocity = worldFromReference.transform(Vec3(a.position.x + v.x, a.position.y, a.position.z + v.z)) - world
            }
            if case .otherDevice = source, let v = a.velocity, v.x.isFinite, v.z.isFinite, place.meters > 0.3 {
                // The velocity is turned into this phone's frame like the position (a direction ignores the translation).
                let tip = worldFromReference.transform(Vec3(a.position.x + v.x, a.position.y, a.position.z + v.z))
                let toUser = worldFromCamera.translation - world
                closing = ((tip.x - world.x) * toUser.x + (tip.z - world.z) * toUser.z) / place.meters
            }
            out.append(HiddenReport(id: "S:" + a.id, label: a.label, source: source, occluder: occluder, sector: place.sector,
                                    bearingDeg: place.bearing,
                                    distance: DistanceMeasurement(meters: place.meters, sigma: a.sigma,
                                                                  method: source == .prediction ? .motionPrediction : .sharedAnchor),
                                    localTrackID: a.localID, moving: a.moving ?? false, age: ageUpper,
                                    closingSpeed: closing, velocity: velocity))
        }
        for e in estimates {
            let id = "L:\(e.trackID)"
            if seenByOthers.contains(e.trackID) { invalidations[id] = .superseded; continue }
            guard e.age.isFinite, e.age >= 0, e.age <= config.localMaxAge else { invalidations[id] = .age; continue }
            guard e.sigma.isFinite, e.sigma >= 0, e.sigma <= config.maxPositionSigma else { invalidations[id] = .uncertainty; continue }
            guard let place = Self.locate(e.position, from: worldFromCamera, aheadHalfAngleDeg: aheadHalfAngleDeg),
                  place.meters <= config.radius else { invalidations[id] = .outOfRange; continue }
            out.append(HiddenReport(id: "L:\(e.trackID)", label: e.label, source: .prediction, occluder: e.occluder, sector: place.sector,
                                    bearingDeg: place.bearing,
                                    distance: DistanceMeasurement(meters: place.meters, sigma: e.sigma, method: .motionPrediction),
                                    localTrackID: e.trackID, moving: e.speed > 0.3, age: e.age, velocity: e.velocity))
        }
        return HiddenResolution(reports: out.sorted { $0.distance.meters < $1.distance.meters }, invalidations: invalidations)
    }

    /// Remote metric candidates bypass the presentation radius. Missing protocol fields keep motion unknown.
    public func encounterCandidates(advisories: [ServerAdvisory], residence: Double, worldFromReference: Pose,
                                    now: Timestamp) -> [EncounterCandidate] {
        guard residence.isFinite, residence >= 0 else { return [] }
        return advisories.compactMap { a in
            guard let lower = a.ageMs, let uncertainty = a.ageUncertaintyMs,
                  lower.isFinite, uncertainty.isFinite, lower >= 0, uncertainty >= 0,
                  let stateAge = a.stateAgeUpperMs, stateAge.isFinite, stateAge >= 0,
                  a.sigma.isFinite, a.sigma >= 0 else { return nil }
            let p = worldFromReference.transform(a.position)
            var v: Vec3?
            if let velocity = a.velocity, velocity.x.isFinite, velocity.z.isFinite {
                v = worldFromReference.transform(Vec3(a.position.x + velocity.x, a.position.y, a.position.z + velocity.z)) - p
            }
            let stateLag = stateAge / 1000 + residence
            // Arrival time is uncertain: keep the position, bound displacement instead of guessing a precise timestamp.
            return EncounterCandidate(id: a.localID.map { "L:\($0)" } ?? "S:" + a.id, label: a.label,
                source: a.kind == "seen" ? .remoteMeasurement : .prediction,
                motion: EncounterMotion(position: p, velocity: v, positionSigma: a.sigma + (v?.length ?? 0) * stateLag,
                    velocitySigma: a.velocitySigma, stateAt: now, measurementAge: (lower + uncertainty) / 1000 + residence),
                footprint: .assumed(for: a.label), occluder: a.occluder.flatMap(OccluderKind.init(rawValue:)))
        }
    }

    /// Camera-relative direction of a world point. Sector is nil when the phone points up or down (no heading).
    static func locate(_ world: Vec3, from worldFromCamera: Pose, aheadHalfAngleDeg: Double = 25)
        -> (meters: Double, bearing: Double?, sector: Sector?)? {
        var d = world - worldFromCamera.translation
        d.y = 0
        let dist = d.length
        guard dist.isFinite else { return nil }
        var f = worldFromCamera.axis(2) * -1
        f.y = 0
        guard f.length >= 0.35, dist > 0.05 else { return (dist, nil, nil) }
        f = f * (1 / f.length)
        let right = f.cross(Vec3(0, 1, 0))
        let b = atan2(d.dot(right), d.dot(f)) * 180 / .pi
        return (dist, b, abs(b) <= aheadHalfAngleDeg ? .ahead : (abs(b) >= 135 ? .behind : (b < 0 ? .left : .right)))
    }
}
