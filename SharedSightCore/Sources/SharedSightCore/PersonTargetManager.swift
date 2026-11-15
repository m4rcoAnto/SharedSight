import Foundation

public enum TargetTrackingState: String, Codable, Sendable, CaseIterable {
    case unassigned             // no registered person selected, or tracking not started
    case searching              // started, the person's marker has not been seen on anyone yet
    case acquired               // just associated with a track; settling before guidance starts
    case following              // associated, observed in this frame
    case temporarilyOccluded    // associated, not observed; the box is a prediction
    case lost                   // association ended; still looking for the marker
    case ambiguous              // cannot prove which track is the person; following is paused
}

public enum TargetReason: String, Codable, Sendable {
    case markerOnSeveralPeople, duplicateMarker, peopleOverlap, trackerCouldNotProveIdentity
    case hiddenTooLong, trackEnded, perceptionReset, noCandidateLeft
}

public enum VerificationSource: String, Codable, Sendable { case marker, operatorSelection }

/// A decoded target marker seen in one frame (upright image-normalised box, same space as detections).
public struct MarkerSighting: Sendable, Equatable {
    public var token: String
    public var box: NormRect
    public init(token: String, box: NormRect) { self.token = token; self.box = box }
}

public struct TargetConfig: Sendable {
    public var personLabel = "person"
    public var acquireHoldSeconds = 0.4          // acquired -> following
    public var occlusionGraceSeconds = 1.5       // matches TrackerConfig.reassociationWindow: later re-matches are not provable
    public var crossingIoU = 0.25                // another person overlapping the target this much = possible swap
    public var verificationFreshSeconds = 0.6    // a marker read this recent overrules an overlap
    public var resumeAfterCleanCrossing = true   // false: every crossing needs a new marker read
    public var crossingConfidencePenalty = 0.6
    public var verificationHalfLife = 12.0       // association confidence decays between marker reads
    public var markerTieMargin = 0.35            // how much better one box must fit the marker than the next
    public var ambiguousTimeout = 6.0            // ambiguous with nobody left to verify -> lost
    public init() {}
}

/// The relationship registered person <-> current track for one frame. Everything is a measurement or nil.
public struct TargetStatus: Sendable, Equatable {
    public var state: TargetTrackingState = .unassigned
    public var profileID: UUID?
    public var userID: String?
    public var trackID: Int?
    public var box: NormRect?
    /// True when `box` comes from motion prediction, not from a detection in this frame.
    public var boxIsPredicted = false
    public var detectionConfidence = 0.0
    /// Heuristic 0...1: detector confidence x time since the identity was last verified x crossing penalty.
    public var associationConfidence = 0.0
    public var lastObserved: Timestamp?
    public var lastVerified: Timestamp?
    public var verifiedBy: VerificationSource?
    public var stateSince: Timestamp = 0
    public var reason: TargetReason?
    public init() {}

    /// Only a directly observed, associated target may drive follow guidance.
    public var isLocked: Bool { state == .acquired || state == .following }
}

public struct TargetEvent: Sendable, Equatable {
    public var kind: TrackingEvent.Kind
    public var timestamp: Timestamp
    public var userID: String?
    public var trackID: Int?
    public var detail: String?
}

/// Keeps one registered person associated with one temporary track.
///
/// Rules it never breaks:
/// - A track becomes the target only through explicit evidence: the person's marker read inside exactly one
///   person box, or an operator tapping that person. Class "person" alone is never evidence.
/// - It never moves the association to another track by itself. When it cannot prove which track is the
///   person it reports `.ambiguous` or `.lost` and waits for new evidence.
/// - The registered identity (`userID`) is independent of the track number: after a loss the same user is
///   re-associated with whatever new track carries the marker.
///
/// Not thread-safe: call it from the perception queue only.
public final class PersonTargetManager {
    public var config: TargetConfig
    public private(set) var status = TargetStatus()

    private var markerToken: String?
    private var armed = false
    private var hadLock = false
    private var acquiredAt: Timestamp = 0
    private var overlapActive = false
    private var overlapHadMiss = false
    private var crossingPenalty = 1.0
    private var lastUndecidable: Timestamp = -.infinity
    private var events: [TargetEvent] = []

    public init(config: TargetConfig = TargetConfig()) { self.config = config }

    // MARK: Commands

    /// Selects who to look for. Passing nil clears everything. Changing the person always drops the current lock.
    public func assign(_ profile: PersonProfile?, now: Timestamp) {
        let same = profile?.id == status.profileID && profile?.markerToken == markerToken
        if let grace = profile?.preferences.occlusionGraceSeconds { config.occlusionGraceSeconds = grace }
        guard !same else { return }
        if status.state != .unassigned { record(.stopped, now, detail: "target changed") }
        status = TargetStatus()
        status.profileID = profile?.id
        status.userID = profile?.userID
        status.stateSince = now
        markerToken = profile?.markerToken
        resetLock()
        hadLock = false
        if armed, profile != nil { transition(.searching, now, reason: nil) }
        if profile == nil { armed = false }
    }

    public func startAcquisition(now: Timestamp) {
        guard status.profileID != nil, !armed else { return }
        armed = true
        hadLock = false
        transition(.searching, now, reason: nil)
        record(.acquisitionStarted, now)
    }

    public func stop(now: Timestamp) {
        guard armed else { return }
        armed = false
        resetLock()
        hadLock = false
        transition(.unassigned, now, reason: nil)
        record(.stopped, now)
    }

    public var isArmed: Bool { armed }

    /// Explicit operator confirmation ("this one is Marco"). Only accepted for a person track seen in the last update.
    @discardableResult
    public func selectByOperator(trackID: Int, tracks: [TrackSnapshot], now: Timestamp) -> Bool {
        guard armed, status.profileID != nil,
              let t = tracks.first(where: { $0.id == trackID && $0.label == config.personLabel && $0.observedThisFrame })
        else { return false }
        bind(t, by: .operatorSelection, now: now)
        return true
    }

    /// The tracker was reset (pause, camera switch): track numbers no longer refer to anything.
    public func perceptionReset(now: Timestamp) {
        guard armed else { return }
        if status.trackID != nil || status.state == .ambiguous { lose(.perceptionReset, now) }
    }

    public func drainEvents() -> [TargetEvent] { defer { events.removeAll() }; return events }

    // MARK: Per-frame update

    @discardableResult
    public func update(tracks: [TrackSnapshot], markers: [MarkerSighting], now: Timestamp) -> TargetStatus {
        guard armed, status.profileID != nil else { return status }
        let people = tracks.filter { $0.label == config.personLabel }
        let observed = people.filter { $0.observedThisFrame }

        // 1. New evidence: the registered person's marker.
        var verifiedThisFrame = false
        switch locateMarker(markers, in: observed) {
        case let .on(track):
            if status.trackID != track.id || !status.isLocked || status.verifiedBy != .marker {
                bind(track, by: .marker, now: now)
            } else {
                status.lastVerified = now
                crossingPenalty = 1
            }
            verifiedThisFrame = true
        case let .undecidable(reason):
            // Evidence exists but does not single out one person. Without a lock this is an ambiguous scene;
            // with a lock it adds nothing and the overlap logic below decides.
            if status.trackID == nil { lastUndecidable = now; transition(.ambiguous, now, reason: reason) }
        case .none:
            break
        }

        // 2. No association: keep reporting why, keep waiting for evidence. Never pick someone.
        guard let trackID = status.trackID else {
            if status.state == .ambiguous, !verifiedThisFrame,
               now - max(status.stateSince, lastUndecidable) > config.ambiguousTimeout {
                // Nobody left to verify. Before any lock this is simply "still searching".
                if hadLock { lose(.noCandidateLeft, now) } else { transition(.searching, now, reason: nil) }
            }
            return status
        }

        // 3. The associated track must still exist.
        guard let t = people.first(where: { $0.id == trackID }) else {
            lose(.trackEnded, now)
            return status
        }

        // 4. The tracker itself says a re-match after a gap was not unique, and nothing re-verified it since.
        if let ambiguousAt = t.lastAmbiguousAt, ambiguousAt > (status.lastVerified ?? -.infinity) {
            unbind(.ambiguous, reason: .trackerCouldNotProveIdentity, now)
            return status
        }

        // 5. Another person overlaps the target and the marker has not been read just now.
        let fresh = status.lastVerified.map { now - $0 <= config.verificationFreshSeconds } ?? false
        let overlapping = observed.contains { $0.id != t.id && $0.box.iou(t.box) >= config.crossingIoU }
        if overlapping && !fresh {
            overlapActive = true
            if !t.observedThisFrame { overlapHadMiss = true }
            describe(t, now)
            status.associationConfidence = 0
            transition(.ambiguous, now, reason: .peopleOverlap)
            return status
        }
        if overlapActive {
            let hadMiss = overlapHadMiss
            overlapActive = false
            overlapHadMiss = false
            if fresh {
                crossingPenalty = 1
            } else if hadMiss || !config.resumeAfterCleanCrossing || !t.observedThisFrame {
                // The target was hidden while someone was on top of it: the track may now be the other person.
                unbind(.ambiguous, reason: .peopleOverlap, now)
                return status
            } else {
                crossingPenalty = config.crossingConfidencePenalty
                record(.resumedAfterCrossing, now, detail: "observed in every frame of the crossing; marker not re-read")
            }
        }

        // 6. Observed -> acquired/following. Not observed -> predicted for a short time, then lost.
        describe(t, now)
        if t.observedThisFrame {
            let next: TargetTrackingState = now - acquiredAt >= config.acquireHoldSeconds ? .following : .acquired
            transition(next, now, reason: nil)
        } else {
            let gap = now - (status.lastObserved ?? t.lastObserved)
            if gap <= config.occlusionGraceSeconds {
                status.associationConfidence *= max(0, 1 - gap / max(config.occlusionGraceSeconds, 1e-6))
                transition(.temporarilyOccluded, now, reason: nil)
            } else {
                lose(.hiddenTooLong, now)
            }
        }
        return status
    }

    // MARK: Internals

    private enum MarkerResult { case none, on(TrackSnapshot), undecidable(TargetReason) }

    /// Which observed person carries this profile's marker? Only markers with the right token count;
    /// other tokens (other profiles, unknown codes) are ignored.
    private func locateMarker(_ markers: [MarkerSighting], in observed: [TrackSnapshot]) -> MarkerResult {
        guard let token = markerToken else { return .none }
        let mine = markers.filter { $0.token == token }
        guard let marker = mine.first else { return .none }
        if mine.count > 1 { return .undecidable(.duplicateMarker) }      // the same code twice: one of them is a copy
        let mx = marker.box.cx, my = marker.box.cy
        // How far from the box's vertical axis the marker sits, in half-widths (0 = on the axis, 1 = on the edge).
        let fits = observed.compactMap { t -> (track: TrackSnapshot, offset: Double)? in
            guard mx >= t.box.x, mx <= t.box.maxX, my >= t.box.y, my <= t.box.maxY, t.box.w > 0 else { return nil }
            return (track: t, offset: abs(mx - t.box.cx) / (t.box.w / 2))
        }
        .sorted { $0.offset < $1.offset }
        guard let best = fits.first else { return .none }                // marker visible, but not on a detected person
        if fits.count > 1, fits[1].offset - best.offset < config.markerTieMargin { return .undecidable(.markerOnSeveralPeople) }
        return .on(best.track)
    }

    private func bind(_ t: TrackSnapshot, by source: VerificationSource, now: Timestamp) {
        let previous = status.trackID
        let wasLocked = status.isLocked || status.state == .temporarilyOccluded
        status.trackID = t.id
        status.lastVerified = now
        status.verifiedBy = source
        overlapActive = false
        overlapHadMiss = false
        crossingPenalty = 1
        describe(t, now)
        if wasLocked, previous == t.id { return }                        // same track, evidence refreshed
        acquiredAt = now
        let kind: TrackingEvent.Kind = hadLock ? .reassociated : .acquired
        hadLock = true
        transition(.acquired, now, reason: nil, log: false)
        record(kind, now, detail: "by \(source.rawValue)" + (previous.map { ", previous track \($0)" } ?? ""))
    }

    private func describe(_ t: TrackSnapshot, _ now: Timestamp) {
        status.box = t.box
        status.boxIsPredicted = !t.observedThisFrame
        status.detectionConfidence = t.confidence
        if t.observedThisFrame { status.lastObserved = now }
        let sinceVerified = max(0, now - (status.lastVerified ?? now))
        let verification = 0.5 + 0.5 * pow(0.5, sinceVerified / max(config.verificationHalfLife, 1e-6))
        status.associationConfidence = min(max(t.confidence * verification * crossingPenalty, 0), 1)
    }

    private func resetLock() {
        status.trackID = nil
        status.box = nil
        status.boxIsPredicted = false
        status.detectionConfidence = 0
        status.associationConfidence = 0
        overlapActive = false
        overlapHadMiss = false
        crossingPenalty = 1
    }

    private func unbind(_ state: TargetTrackingState, reason: TargetReason, _ now: Timestamp) {
        let track = status.trackID
        resetLock()
        transition(state, now, reason: reason, log: false)
        record(state == .lost ? .lost : .ambiguous, now, trackID: track, detail: reason.rawValue)
    }

    private func lose(_ reason: TargetReason, _ now: Timestamp) { unbind(.lost, reason: reason, now) }

    private func transition(_ state: TargetTrackingState, _ now: Timestamp, reason: TargetReason?, log: Bool = true) {
        status.reason = reason
        guard state != status.state else { return }
        status.state = state
        status.stateSince = now
        guard log else { return }
        switch state {
        case .following: record(.following, now)
        case .temporarilyOccluded: record(.occluded, now)
        case .ambiguous: record(.ambiguous, now, detail: reason?.rawValue)
        case .lost: record(.lost, now, detail: reason?.rawValue)
        case .unassigned, .searching, .acquired: break
        }
    }

    private func record(_ kind: TrackingEvent.Kind, _ now: Timestamp, trackID: Int? = nil, detail: String? = nil) {
        events.append(TargetEvent(kind: kind, timestamp: now, userID: status.userID, trackID: trackID ?? status.trackID, detail: detail))
    }
}
