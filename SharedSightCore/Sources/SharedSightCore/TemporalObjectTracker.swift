import Foundation

public struct TrackerConfig: Sendable {
    public var highScore = 0.45            // ByteTrack first-stage detections
    public var lowScore = 0.15             // ByteTrack second-stage detections
    public var newTrackScore = 0.5
    public var maxCostHigh = 0.75          // 1 - IoU (+ class penalty)
    public var maxCostLow = 0.6
    public var classMismatchPenalty = 0.35
    public var confirmHits = 3
    public var maxCoastSeconds = 5.0       // tracks are kept (unobserved) this long for ObstacleMemoryEngine
    public var reassociationWindow = 1.5   // older coasting tracks are never re-matched: identity is not provable
    public var ambiguityMargin = 0.15
    public var accelSigmaPosition = 0.6    // normalised units / s^2
    public var accelSigmaSize = 0.3
    public var measurementSigma = 0.02
    public var uncompensatedMotionSigma = 0.25 // extra position sigma per second when camera motion is unknown
    public init() {}
}

/// Public, immutable view of one track for one frame.
public struct TrackSnapshot: Sendable, Identifiable, Equatable {
    public let id: Int                 // temporary, session-local, never derived from appearance or identity
    public var classIndex: Int
    public var label: String
    public var box: NormRect           // filtered (observed) or predicted (unobserved) box
    public var velocityX: Double       // normalised units / s, after camera-motion compensation
    public var velocityY: Double
    public var scaleRate: Double       // relative size growth per second (visual cue, not a distance)
    public var confidence: Double
    public var hits: Int
    public var consecutiveMisses: Int
    public var firstSeen: Timestamp
    public var lastObserved: Timestamp
    public var observedThisFrame: Bool
    public var confirmed: Bool
    public var identityAmbiguous: Bool
    public var positionSigma: Double
    public var lastObservationID: UUID? // detection (and therefore mask) this track was last updated from
    public var hasMask: Bool
    public var speed: Double { (velocityX * velocityX + velocityY * velocityY).squareRoot() }
}

/// Tracking-by-detection: Kalman prediction + camera-motion compensation + two-stage (BYTE) association
/// with Hungarian matching, observation-centric velocity reset after occlusion (OC-SORT ORU idea),
/// confidence-scaled measurement noise (NSA Kalman), and explicit identity-ambiguity flags.
/// Association is purely geometric; class equality alone never links two observations.
public final class TemporalObjectTracker {
    public var config: TrackerConfig
    private var tracks: [Core] = []
    private var nextID = 1
    private var lastTimestamp: Timestamp?

    private struct Core {
        let id: Int
        var kf: BoxKalmanFilter
        var classVotes: [Int: Double]
        var labels: [Int: String]
        var classIndex: Int
        var hits = 1
        var consecutiveMisses = 0
        var firstSeen: Timestamp
        var lastObserved: Timestamp
        var lastObservedBox: NormRect
        var lastObservationID: UUID?
        var hasMask: Bool
        var confidence: Double
        var confirmed = false
        var identityAmbiguous = false
        var observedThisFrame = true
    }

    public init(config: TrackerConfig = TrackerConfig()) { self.config = config }

    public func reset() { tracks.removeAll(); lastTimestamp = nil }

    @discardableResult
    public func update(detections: [Detection], timestamp: Timestamp, cameraMotion: FrameMotion? = nil) -> [TrackSnapshot] {
        let dt = min(max(timestamp - (lastTimestamp ?? timestamp), 0), 1.0)
        lastTimestamp = timestamp

        // 1. Predict + camera-motion compensation.
        for i in tracks.indices {
            tracks[i].kf.predict(dt: dt, accelPosition: config.accelSigmaPosition, accelSize: config.accelSigmaSize)
            if let m = cameraMotion {
                tracks[i].kf.shift(dx: m.dx, dy: m.dy)
                tracks[i].lastObservedBox.x += m.dx
                tracks[i].lastObservedBox.y += m.dy
                if !m.reliable { tracks[i].kf.inflatePosition(sigma: config.uncompensatedMotionSigma * dt) }
            }
            tracks[i].observedThisFrame = false
        }

        let high = detections.indices.filter { detections[$0].confidence >= config.highScore }
        let low = detections.indices.filter { detections[$0].confidence >= config.lowScore && detections[$0].confidence < config.highScore }
        let eligible = tracks.indices.filter { timestamp - tracks[$0].lastObserved <= config.reassociationWindow }

        // 2. Stage one: all eligible tracks vs high-score detections.
        var matchedTracks = Set<Int>(), matchedDets = Set<Int>()
        let first = associate(trackIdx: eligible, detIdx: high, detections: detections, maxCost: config.maxCostHigh)
        for (ti, di, amb) in first {
            apply(ti, detections[di], timestamp: timestamp, ambiguous: amb)
            matchedTracks.insert(ti); matchedDets.insert(di)
        }

        // 3. Stage two: remaining confirmed tracks vs low-score detections (recovers occluded / blurred objects).
        let remaining = eligible.filter { !matchedTracks.contains($0) && tracks[$0].confirmed }
        let second = associate(trackIdx: remaining, detIdx: low, detections: detections, maxCost: config.maxCostLow)
        for (ti, di, amb) in second {
            apply(ti, detections[di], timestamp: timestamp, ambiguous: amb)
            matchedTracks.insert(ti); matchedDets.insert(di)
        }

        // 4. Unmatched tracks coast.
        for i in tracks.indices where !matchedTracks.contains(i) { tracks[i].consecutiveMisses += 1 }

        // 5. Births from unmatched high-score detections.
        for di in high where !matchedDets.contains(di) && detections[di].confidence >= config.newTrackScore {
            let d = detections[di]
            tracks.append(Core(id: nextID, kf: BoxKalmanFilter(box: d.box, measurementSigma: config.measurementSigma),
                               classVotes: [d.classIndex: d.confidence], labels: [d.classIndex: d.label],
                               classIndex: d.classIndex, firstSeen: timestamp, lastObserved: timestamp,
                               lastObservedBox: d.box, lastObservationID: d.id, hasMask: d.hasMask, confidence: d.confidence))
            nextID += 1
        }

        // 6. Deaths: unconfirmed tracks die on the second miss; confirmed ones after maxCoastSeconds.
        tracks.removeAll { t in
            (!t.confirmed && t.consecutiveMisses >= 2) || (timestamp - t.lastObserved > config.maxCoastSeconds)
        }
        return tracks.map(snapshot)
    }

    // MARK: - Internals

    private func cost(_ t: Core, _ d: Detection) -> Double {
        1 - t.kf.box.iou(d.box) + (t.classIndex == d.classIndex ? 0 : config.classMismatchPenalty)
    }

    /// Returns (trackIndex, detectionIndex, identityAmbiguous).
    private func associate(trackIdx: [Int], detIdx: [Int], detections: [Detection], maxCost: Double) -> [(Int, Int, Bool)] {
        guard !trackIdx.isEmpty, !detIdx.isEmpty else { return [] }
        let matrix = trackIdx.map { ti in detIdx.map { di in cost(tracks[ti], detections[di]) } }
        let assignment = Hungarian.solve(matrix)
        var out: [(Int, Int, Bool)] = []
        for (r, c) in assignment.enumerated() where c >= 0 && matrix[r][c] <= maxCost {
            var ambiguous = false
            // After an observation gap, a near-tie with another candidate means identity cannot be proven.
            if tracks[trackIdx[r]].consecutiveMisses >= 2 {
                let limit = min(matrix[r][c] + config.ambiguityMargin, maxCost)
                for c2 in matrix[r].indices where c2 != c && matrix[r][c2] <= limit { ambiguous = true }
                for r2 in matrix.indices where r2 != r && matrix[r2][c] <= limit { ambiguous = true }
            }
            out.append((trackIdx[r], detIdx[c], ambiguous))
        }
        return out
    }

    private func apply(_ ti: Int, _ d: Detection, timestamp: Timestamp, ambiguous: Bool) {
        var t = tracks[ti]
        let gap = timestamp - t.lastObserved
        let prev = t.lastObservedBox
        let sigma = config.measurementSigma * (1.5 - min(max(d.confidence, 0), 1)) // NSA: trust confident boxes more
        t.kf.update(box: d.box, r: sigma * sigma)
        if t.consecutiveMisses >= 2, gap > 0 {
            // Observation-centric re-update: velocity from the two real observations, not from drifted prediction.
            t.kf.setVelocity(vx: (d.box.cx - prev.cx) / gap, vy: (d.box.cy - prev.cy) / gap)
        }
        t.hits += 1
        t.consecutiveMisses = 0
        t.lastObserved = timestamp
        t.lastObservedBox = d.box
        t.lastObservationID = d.id
        t.hasMask = d.hasMask
        t.confidence = d.confidence
        t.observedThisFrame = true
        t.classVotes[d.classIndex, default: 0] += d.confidence
        t.labels[d.classIndex] = d.label
        if let best = t.classVotes.max(by: { $0.value < $1.value }) { t.classIndex = best.key }
        if ambiguous { t.identityAmbiguous = true }
        if t.hits >= config.confirmHits { t.confirmed = true }
        tracks[ti] = t
    }

    private func snapshot(_ t: Core) -> TrackSnapshot {
        TrackSnapshot(id: t.id, classIndex: t.classIndex, label: t.labels[t.classIndex] ?? "object", box: t.kf.box,
                      velocityX: t.kf.cx.v, velocityY: t.kf.cy.v, scaleRate: t.kf.scaleRate, confidence: t.confidence,
                      hits: t.hits, consecutiveMisses: t.consecutiveMisses, firstSeen: t.firstSeen,
                      lastObserved: t.lastObserved, observedThisFrame: t.observedThisFrame, confirmed: t.confirmed,
                      identityAmbiguous: t.identityAmbiguous, positionSigma: t.kf.positionSigma,
                      lastObservationID: t.lastObservationID, hasMask: t.hasMask)
    }
}
