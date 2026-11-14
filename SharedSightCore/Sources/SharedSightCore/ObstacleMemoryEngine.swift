import Foundation

public struct MemoryConfig: Sendable {
    public var hiddenGrace = 0.4         // a just-missed object is assumed briefly hidden
    public var hiddenMax = 3.0           // maximum time an occlusion hypothesis is kept
    public var occlusionCover = 0.5      // predicted box covered this much by an observed object => plausible occlusion
    public var predictionHorizon = 1.5   // motion-model prediction is only offered this long
    public var sigmaLimit = 0.12         // ...and only while positional sigma stays below this (normalised units)
    public var reacquiredHold = 0.6
    public init() {}
}

public struct MemoryEntry: Sendable, Identifiable, Equatable {
    public var id: Int { track.id }
    public var track: TrackSnapshot
    public var state: MemoryState
    public var stateSince: Timestamp
    public var ageSinceObserved: Double
    /// True only for direct, current visual evidence. Predictions and memories are never current evidence.
    public var isCurrentEvidence: Bool { state == .observed || state == .reacquired }
}

/// Short-term perceptual memory. An object that leaves view is not assumed removed, but a remembered
/// position is never promoted to a confirmed current position: uncertainty grows and entries expire.
public final class ObstacleMemoryEngine {
    public var config: MemoryConfig
    private var states: [Int: (state: MemoryState, since: Timestamp, last: TrackSnapshot)] = [:]

    public init(config: MemoryConfig = MemoryConfig()) { self.config = config }

    public func reset() { states.removeAll() }

    /// - Parameter cameraMotionReliable: when false, image-space prediction is not trustworthy and is not offered.
    public func update(tracks: [TrackSnapshot], now: Timestamp, cameraMotionReliable: Bool = true) -> [MemoryEntry] {
        var out: [MemoryEntry] = []
        let confirmed = tracks.filter { $0.confirmed }
        let observedBoxes = confirmed.filter { $0.observedThisFrame }
        var seen = Set<Int>()

        for t in confirmed {
            seen.insert(t.id)
            let previous = states[t.id]
            let age = max(0, now - t.lastObserved)
            var state: MemoryState
            if t.observedThisFrame {
                let wasAway = previous.map { [.temporarilyHidden, .predicted, .unknown].contains($0.state) } ?? false
                let holding = previous.map { $0.state == .reacquired && now - $0.since < config.reacquiredHold } ?? false
                state = (wasAway || holding) ? .reacquired : .observed
            } else {
                let occluded = observedBoxes.contains { $0.id != t.id && t.box.coveredFraction(by: $0.box) >= config.occlusionCover }
                let inFrame = (0.0...1.0).contains(t.box.cx) && (0.0...1.0).contains(t.box.cy)
                if age <= config.hiddenGrace || (occluded && age <= config.hiddenMax) {
                    state = .temporarilyHidden
                } else if inFrame && cameraMotionReliable && age <= config.predictionHorizon && t.positionSigma <= config.sigmaLimit {
                    state = .predicted
                } else {
                    state = .unknown   // out of view, too uncertain, or too old to predict: we simply do not know
                }
            }
            let since = (previous?.state == state) ? previous!.since : now
            states[t.id] = (state, since, t)
            out.append(MemoryEntry(track: t, state: state, stateSince: since, ageSinceObserved: age))
        }

        // Tracks dropped by the tracker are reported once as LOST, then forgotten.
        for (id, s) in states where !seen.contains(id) {
            out.append(MemoryEntry(track: s.last, state: .lost, stateSince: now, ageSinceObserved: max(0, now - s.last.lastObserved)))
            states[id] = nil
        }
        return out
    }
}
