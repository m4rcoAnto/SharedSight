import Foundation

public enum Verbosity: String, Codable, CaseIterable, Sendable { case minimal, normal, detailed }

public struct AlertPreferences: Sendable, Equatable {
    public var verbosity: Verbosity = .normal
    public var announcePeerObservations = true
    public init() {}
}

public enum SystemNotice: Equatable, Sendable {
    case perceptionUnavailable(ReliabilityReason?)
    case perceptionRestored
    case perceptionDegraded(ReliabilityReason)
    case peerConnected, peerLost, peerObservationUnverified
    case collaborationOn, collaborationOff, sharedReferenceReady
}

public enum AlertKind: Equatable, Sendable {
    case obstacle(label: String, count: Int, moving: Bool)
    case peerObstacle(label: String)
    /// A mover this phone cannot see (behind `occluder`, or outside the field of view when nil) that another phone sees now.
    case hiddenSeenByOther(label: String, occluder: OccluderKind?)
    /// A mover nobody sees any more: the position is a prediction and is spoken as such.
    case hiddenEstimate(label: String, occluder: OccluderKind?)
    case encounter(label: String, predicted: Bool, remote: Bool, hidden: Bool, imminent: Bool)
    case localizationLost(label: String)
    case system(SystemNotice)
}

/// A decision to speak. Always traceable to evidence (`source`, `evidenceTimestamp`) or to a system state change.
public struct AlertIntent: Equatable, Sendable {
    public var kind: AlertKind
    public var sector: Sector?
    public var distance: DistanceMeasurement?
    public var source: ObservationSource
    public var priority: Int
    public var interrupts: Bool
    public var evidenceTimestamp: Timestamp
    public var stamp: AlertStamp? = nil

    public init(kind: AlertKind, sector: Sector?, distance: DistanceMeasurement?, source: ObservationSource, priority: Int,
                interrupts: Bool, evidenceTimestamp: Timestamp) {
        self.kind = kind; self.sector = sector; self.distance = distance; self.source = source
        self.priority = priority; self.interrupts = interrupts; self.evidenceTimestamp = evidenceTimestamp
    }
}

public struct LocalCandidate: Sendable {
    public var entry: MemoryEntry
    public var relevance: RelevanceAssessment
    public init(entry: MemoryEntry, relevance: RelevanceAssessment) { self.entry = entry; self.relevance = relevance }
}

public struct AlertConfig: Sendable {
    public var maxEvidenceAge = 0.6
    public var minGapBetweenObstacleAlerts = 1.5
    public var reannounceInterval = 12.0
    public var classSectorCooldown = 4.0
    public var unavailableRepeat = 8.0
    public var unverifiedNoticeInterval = 30.0
    public var peerCooldown = 6.0
    // Hidden objects (another phone's view, or this phone's own prediction)
    public var hiddenCooldown = 12.0          // the same hidden object is not announced again sooner than this
    public var hiddenMinGap = 2.5             // between any two hidden-object announcements
    public var hiddenSectorChangeHold = 4.0   // ...except when it has moved to another direction, after this long
    public var hiddenEstimateRadius = 4.0
    public var hiddenEstimateMaxSigma = 1.2   // a vaguer estimate is not worth the user's attention
    public var hiddenStaticRadius = 2.5       // furniture reported by another phone matters only when close
    // A mover seen only by another phone is worth the user's hearing when it is near, when it is coming nearer, or
    // when this phone was following it and it has just gone out of sight. A stranger far away behind a wall is not.
    public var hiddenNearRadius = 4.0
    public var hiddenApproachSpeed = 0.4      // m/s toward the user...
    public var hiddenApproachRadius = 6.0     // ...and no farther than this
    public var staticClassSectorCooldown = 20.0 // "table on your left" again, for furniture that re-enters a sweeping camera
    // The camera's own detections
    public var sectorChangeHold = 5.0         // an object already announced is not re-announced for changing side sooner than this...
    public var nearAheadMeters = 2.0          // ...unless it is now straight ahead and measured this close
    public var minHitsBeforeFirstAlert = 5    // long enough for its motion to be known, so it is announced once, not twice
    public var movingUpgradeHold = 3.0        // "…, moving" is not appended to an announcement made less than this ago
    // Room to listen. The user's hearing is also how they follow the street: an announcement that is not urgent is
    // decided only once the voice has had time to finish the previous one, plus a pause — not queued behind it to be
    // spoken late. Urgent ones (priority >= urgentPriority: something moving or close straight ahead) never wait.
    public var urgentPriority = 80
    public var pauseAfterSpeech = 0.5         // before an ordinary announcement (priority 60...79)
    public var pauseBeforeMinor = 2.0         // before a minor one (below 60: furniture to the side, estimates)
    public var speechSeconds: (obstacle: Double, estimate: Double, otherDevice: Double) = (2.0, 4.0, 5.5)
    public init() {}
    func threshold(_ v: Verbosity) -> Double { v == .minimal ? 0.55 : (v == .normal ? 0.38 : 0.25) }
}

/// Decides what deserves the user's attention. A detection event alone is never enough: the observation must be
/// current, direct, confirmed over several frames, relevant, not already announced, and the perception state
/// must support it. The engine can never emit a "path clear" statement — there is no such alert kind.
public final class ObstacleAlertDecisionEngine {
    public var config: AlertConfig
    private var lastSemantic: ReliabilityState?
    private var lastUnavailableAnnounce: Timestamp = -.infinity
    private var announced: [Int: (time: Timestamp, sector: Sector?, moving: Bool)] = [:]
    private var classSectorLast: [String: Timestamp] = [:]
    private var lastObstacleTime: Timestamp = -.infinity
    private var announcedPeer: [UUID: Timestamp] = [:]
    private var peerKeyLast: [String: Timestamp] = [:]
    private var lastUnverifiedNotice: Timestamp = -.infinity
    private var announcedHidden: [String: (time: Timestamp, sector: Sector?, prediction: Bool)] = [:]
    private var lastHiddenTime: Timestamp = -.infinity
    private var speechActive: Set<UUID> = []
    private var speechEndedAt: Timestamp = -.infinity
    private struct Context {
        var local: [LocalCandidate]; var peers: [ResolvedPeerObservation]; var hidden: [HiddenReport]
        var encounters: [EncounterResult]; var semantic: ReliabilityState; var now: Timestamp
    }
    private var pending: [UUID: (key: String, commit: (Timestamp) -> Void)] = [:]
    private var pendingKeys: [String: UUID] = [:]
    private var live: [String: (stamp: AlertStamp, check: (Context) -> Bool)] = [:]
    private var versions: [String: Int] = [:]
    private var epoch = "local"
    private var validatedAt: Timestamp = 0
    private var riskDelivered: [String: (time: Timestamp, state: EncounterState, firstConflict: Double, label: String, predicted: Bool)] = [:]
    private var riskLastUrgent: [String: Timestamp] = [:]
    private var lossDelivered: Set<String> = []
    public var riskCooldown = 8.0
    public var riskHysteresis = 1.0

    public var validationSnapshot: AlertValidationSnapshot {
        AlertValidationSnapshot(epoch: epoch, evaluatedAt: validatedAt, versions: live.mapValues { $0.stamp.version })
    }
    public func delivery(_ intent: AlertIntent, phase: AlertDeliveryPhase, at time: Timestamp) {
        guard let stamp = intent.stamp, stamp.epoch == epoch else { return }
        switch phase {
        case .started:
            guard live[stamp.identity]?.stamp.version == stamp.version else { return }
            if let decision = pending.removeValue(forKey: stamp.deliveryID) {
                if pendingKeys[decision.key] == stamp.deliveryID { pendingKeys[decision.key] = nil }
                decision.commit(time)
            }
            speechActive.insert(stamp.deliveryID)
        case .finished, .discarded:
            if speechActive.remove(stamp.deliveryID) != nil { speechEndedAt = time }
            if let decision = pending.removeValue(forKey: stamp.deliveryID), pendingKeys[decision.key] == stamp.deliveryID { pendingKeys[decision.key] = nil }
        case .decided, .queued: break
        }
    }
    private func stage(_ intent: AlertIntent, key: String, now: Timestamp, lifetime: Double = 0.8, replace: Bool = false,
                       check: @escaping (Context) -> Bool, commit: @escaping (Timestamp) -> Void) -> AlertIntent? {
        if let old = pendingKeys[key] {
            guard replace else { return nil }
            pending[old] = nil
        }
        let version = (versions[key] ?? 0) + 1; versions[key] = version
        var intent = intent
        let stamp = AlertStamp(identity: key, epoch: epoch, version: version, evaluatedAt: now, expiresAt: now + lifetime)
        intent.stamp = stamp
        live[key] = (stamp, check); pending[stamp.deliveryID] = (key, commit); pendingKeys[key] = stamp.deliveryID
        return intent
    }

    public init(config: AlertConfig = AlertConfig()) { self.config = config }

    /// An object already announced as still has started to move. An approach is said at once; plain movement only
    /// when the earlier announcement is not still fresh in the listener's ear.
    private func startedMoving(_ m: LocalCandidate, _ a: (time: Timestamp, sector: Sector?, moving: Bool), _ now: Timestamp) -> Bool {
        guard !a.moving else { return false }
        return m.relevance.approachCue || (m.relevance.moving && now - a.time >= config.movingUpgradeHold)
    }

    public func reset() {
        announced.removeAll(); classSectorLast.removeAll(); announcedPeer.removeAll(); peerKeyLast.removeAll()
        announcedHidden.removeAll()
        lastObstacleTime = -.infinity; lastHiddenTime = -.infinity; speechEndedAt = -.infinity
        pending.removeAll(); pendingKeys.removeAll(); live.removeAll(); versions.removeAll(); speechActive.removeAll()
        riskDelivered.removeAll(); riskLastUrgent.removeAll(); lossDelivered.removeAll()
        lastSemantic = nil; lastUnavailableAnnounce = -.infinity
    }

    /// Whether an announcement of this priority may be decided now, given what the voice is still expected to be saying.
    private func hasRoom(_ priority: Int, _ now: Timestamp) -> Bool {
        if priority >= config.urgentPriority { return true }
        return speechActive.isEmpty && now >= speechEndedAt + (priority >= 60 ? config.pauseAfterSpeech : config.pauseBeforeMinor)
    }

    public func decide(local: [LocalCandidate], peers: [ResolvedPeerObservation] = [], hidden: [HiddenReport] = [],
                       reliability: ReliabilityReport, events: [SystemNotice] = [],
                       preferences: AlertPreferences = AlertPreferences(), encounters: [EncounterResult] = [], epoch: String = "local", now: Timestamp) -> [AlertIntent] {
        if self.epoch != epoch { reset(); self.epoch = epoch }
        validatedAt = now
        let context = Context(local: local, peers: peers, hidden: hidden, encounters: encounters,
                              semantic: reliability.status(.semanticDetection).state, now: now)
        for key in Array(live.keys) {
            guard let record = live[key] else { continue }
            if !record.check(context) {
                live[key] = nil
                if let id = pendingKeys.removeValue(forKey: key) { pending[id] = nil }
            } else if let id = pendingKeys[key], now > record.stamp.expiresAt {
                pending[id] = nil; pendingKeys[key] = nil
            }
        }
        let conflictIDs = Set(encounters.filter { $0.state == .possibleConflict || $0.state == .estimatedImminentConflict }.map(\.id))
        var out: [AlertIntent] = []
        func system(_ n: SystemNotice, _ priority: Int, interrupts: Bool = false) {
            let intent = AlertIntent(kind: .system(n), sector: nil, distance: nil, source: .localCamera, priority: priority,
                                     interrupts: interrupts, evidenceTimestamp: now)
            if let staged = stage(intent, key: "system:\(n)", now: now, check: { c in
                if case .perceptionUnavailable = n { return c.semantic == .unavailable }
                if case .perceptionRestored = n { return c.semantic != .unavailable }
                return c.now - now <= 1
            }, commit: { [weak self] time in
                if case .perceptionUnavailable = n { self?.lastUnavailableAnnounce = time }
            }) { out.append(staged) }
        }

        // 1. Perception state changes outrank everything: the user must know when the system cannot see.
        let semantic = reliability.status(.semanticDetection)
        if semantic.state == .unavailable {
            // A deliberate pause is announced once; a real perception failure is repeated while it lasts.
            let repeatDue = semantic.reasons.first != .paused && now - lastUnavailableAnnounce >= config.unavailableRepeat
            if lastSemantic != .unavailable || repeatDue {
                system(.perceptionUnavailable(semantic.reasons.first), 100, interrupts: true)
            }
        } else if lastSemantic == .unavailable {
            system(.perceptionRestored, 90)
        } else if semantic.state == .degraded, lastSemantic == .reliable, preferences.verbosity != .minimal, let r = semantic.reasons.first {
            system(.perceptionDegraded(r), 70)
        }
        lastSemantic = semantic.state
        for e in events { system(e, e == .peerLost ? 75 : 65) }

        // 2. Local, directly observed obstacles. Suppressed entirely while perception is unavailable.
        if semantic.state != .unavailable {
            let directionOK = reliability.status(.directionCues).state == .reliable
            let distanceOK = reliability.status(.metricDistance).state == .reliable
            let threshold = config.threshold(preferences.verbosity) + (semantic.state == .degraded ? 0.1 : 0)
            let eligible = local.filter {
                !conflictIDs.contains("L:\($0.entry.id)") && $0.entry.isCurrentEvidence && $0.entry.track.confirmed && $0.entry.ageSinceObserved <= config.maxEvidenceAge
                    && $0.relevance.score >= threshold
                    && ($0.entry.track.hits >= config.minHitsBeforeFirstAlert || announced[$0.entry.track.id] != nil)
            }
            var groups: [String: [LocalCandidate]] = [:]
            for c in eligible {
                let sector = directionOK ? c.relevance.sector : nil
                groups["\(c.entry.track.label)|\(sector?.rawValue ?? "-")", default: []].append(c)
            }
            var best: (intent: AlertIntent, key: String, members: [LocalCandidate], sector: Sector?, moving: Bool)?
            for (key, members) in groups {
                let sector = directionOK ? members[0].relevance.sector : nil
                let moving = members.contains { $0.relevance.moving || $0.relevance.approachCue }
                let fresh = members.filter { m in
                    guard let a = announced[m.entry.track.id] else { return true }
                    let nowMoving = m.relevance.moving || m.relevance.approachCue
                    // Something that keeps crossing the picture (a dog trotting about) must not narrate every step:
                    // a change of side is news only after a while, or at once when it is now close and straight ahead.
                    let nearAhead = sector == .ahead && (m.relevance.distance?.meters ?? .infinity) <= config.nearAheadMeters
                    let sideChanged = a.sector != sector && (now - a.time >= config.sectorChangeHold || nearAhead)
                    return sideChanged || startedMoving(m, a, now) || now - a.time >= config.reannounceInterval
                }
                if fresh.isEmpty { continue }
                let newlyMoving = fresh.contains { m in
                    guard let a = announced[m.entry.track.id] else { return m.relevance.moving || m.relevance.approachCue }
                    return startedMoving(m, a, now)
                }
                let cooldown = NominalSize.isMover(members[0].entry.track.label) ? config.classSectorCooldown : config.staticClassSectorCooldown
                if let t = classSectorLast[key], now - t < cooldown, !newlyMoving { continue }
                let top = members.max { $0.relevance.score < $1.relevance.score }!
                var priority = sector == .ahead ? 60 : (sector == nil ? 35 : 40)
                if moving { priority += 20 }
                // Measured close and straight ahead: as urgent as something that moves, even if it is a chair.
                else if sector == .ahead, distanceOK, let d = top.relevance.distance, d.meters <= config.nearAheadMeters { priority += 20 }
                priority += Int(10 * top.relevance.score)
                // Measured within reach, or visibly coming closer, straight ahead: may cut a less important sentence (a far report, an estimate).
                let closeAhead = sector == .ahead && ((distanceOK && (top.relevance.distance?.meters ?? .infinity) <= config.nearAheadMeters) || top.relevance.approachCue)
                let intent = AlertIntent(kind: .obstacle(label: top.entry.track.label, count: members.count, moving: moving),
                                         sector: sector, distance: distanceOK ? top.relevance.distance : nil,
                                         source: .localCamera, priority: priority, interrupts: closeAhead,
                                         evidenceTimestamp: top.entry.track.lastObserved)
                if best == nil || priority > best!.intent.priority { best = (intent, key, members, sector, moving) }
            }
            if let b = best, now - lastObstacleTime >= config.minGapBetweenObstacleAlerts || b.intent.priority >= config.urgentPriority,
               hasRoom(b.intent.priority, now) {
                let ids = Set(b.members.map { $0.entry.id }), label = b.members[0].entry.track.label
                if let intent = stage(b.intent, key: "local:" + b.key, now: now, check: { c in
                    c.semantic != .unavailable && ids.allSatisfy { id in c.local.contains {
                        $0.entry.id == id && $0.entry.track.label == label && $0.entry.isCurrentEvidence &&
                        $0.entry.ageSinceObserved <= 0.6 && $0.relevance.sector == b.sector
                    } }
                }, commit: { [weak self] time in
                    guard let self else { return }
                    self.lastObstacleTime = time; self.classSectorLast[b.key] = time
                    for m in b.members { self.announced[m.entry.id] = (time, b.sector, m.relevance.moving || m.relevance.approachCue) }
                }) { out.append(intent) }
            }
        }

        // 3. Peer observations: spoken as warnings only when spatially justified, always attributed.
        if preferences.announcePeerObservations {
            let spatialOK = reliability.status(.sharedSpatialReference).state != .unavailable
            let relevant = peers.filter { $0.status == .spatiallyRelevant && announcedPeer[$0.observation.id] == nil }
                .sorted { ($0.distance?.meters ?? 99) < ($1.distance?.meters ?? 99) }
            if spatialOK, let p = relevant.first {
                let key = "\(p.observation.cameraID)|\(p.observation.label)|\(p.sector?.rawValue ?? "-")"
                if now - (peerKeyLast[key] ?? -.infinity) >= config.peerCooldown {
                    let intent = AlertIntent(kind: .peerObstacle(label: p.observation.label), sector: p.sector, distance: p.distance,
                        source: .peer(cameraID: p.observation.cameraID), priority: (p.distance?.meters ?? 99) < 2 ? 65 : 55,
                        interrupts: false, evidenceTimestamp: now - p.captureAge)
                    if let staged = stage(intent, key: "peer:" + key, now: now, check: { c in
                        c.peers.contains { $0.observation.id == p.observation.id && $0.status == .spatiallyRelevant && $0.sector == p.sector }
                    }, commit: { [weak self] time in
                        self?.announcedPeer[p.observation.id] = time; self?.peerKeyLast[key] = time
                    }) { out.append(staged) }
                }
            }
            // Unaligned observations never become a warning; at most an occasional, clearly non-directional status.
            if preferences.verbosity == .detailed, peers.contains(where: { $0.status == .locationUnverified }),
               now - lastUnverifiedNotice >= config.unverifiedNoticeInterval {
                system(.peerObservationUnverified, 20)
                lastUnverifiedNotice = now
            }
        }

        // 3b. Hidden objects. Another phone's light in this phone's shadow, or — when nobody sees the object — this
        //     phone's own prediction, always worded as an estimate. A report needs a direction or it is not spoken.
        if now - lastHiddenTime >= config.hiddenMinGap {
            var best: (intent: AlertIntent, report: HiddenReport)?
            for r in hidden where r.sector != nil {
                if conflictIDs.contains(r.localTrackID.map { "L:\($0)" } ?? r.id) { continue }
                let fromOther = !r.isPrediction
                if fromOther && !preferences.announcePeerObservations { continue }
                let kind: AlertKind
                var priority: Int
                let near = r.distance.meters <= config.hiddenNearRadius
                // Coming nearer from outside the picture or from behind a wall or door. From behind furniture it will be
                // in this camera's own view in a moment, and announced then.
                let approaching = r.closingSpeed >= config.hiddenApproachSpeed && r.distance.meters <= config.hiddenApproachRadius
                // "Followed": this phone was announcing it and it has gone behind a wall or a door — into another room,
                // from which it can come back. Something that merely left the picture sideways is found again by
                // turning, and a small thing behind furniture metres away is not news: those count only when near.
                let followedBehind = r.localTrackID != nil && (r.occluder == .wall || r.occluder == .door)
                if r.isMover {
                    if fromOther {
                        guard near || approaching || followedBehind else { continue }
                        kind = .hiddenSeenByOther(label: r.label, occluder: r.occluder)
                        priority = (r.distance.meters < 3 ? 72 : 58) + (approaching ? 10 : (r.moving ? 4 : 0)) + (followedBehind ? 8 : 0)
                    } else {
                        guard r.distance.meters <= config.hiddenEstimateRadius, r.distance.sigma <= config.hiddenEstimateMaxSigma,
                              preferences.verbosity != .minimal else { continue }
                        kind = .hiddenEstimate(label: r.label, occluder: r.occluder)
                        priority = 46
                    }
                } else {
                    // Furniture is never predicted; reported by another phone it is an obstacle like any peer obstacle.
                    guard fromOther, r.distance.meters <= config.hiddenStaticRadius else { continue }
                    kind = .peerObstacle(label: r.label)
                    priority = r.distance.meters < 2 ? 65 : 55
                }
                // The same object under another name (a prediction that another phone then confirms) counts as new
                // information; the same information again does not.
                // The hub's object number survives this phone's own track numbers, so an object that keeps slipping
                // behind the same thing is one object, said once per cooldown. The local number links a phone's own
                // estimate with the hub's later confirmation of the same track.
                let key = r.localTrackID.map { "T:\($0)" } ?? r.id
                let earlier = [announcedHidden[r.id], announcedHidden[key]].compactMap { $0 }.max { $0.time < $1.time }
                if let a = earlier {
                    let upgraded = a.prediction && fromOther
                    let moved = a.sector != r.sector && now - a.time >= config.hiddenSectorChangeHold && r.isMover && fromOther
                        && (near || approaching)
                    if !upgraded && !moved && now - a.time < config.hiddenCooldown { continue }
                }
                if !r.isMover, now - (peerKeyLast["hub|\(r.label)|\(r.sector?.rawValue ?? "-")"] ?? -.infinity) < config.peerCooldown { continue }
                let intent = AlertIntent(kind: kind, sector: r.sector, distance: r.distance,
                                         source: fromOther ? .peer(cameraID: "hub") : .localCamera, priority: priority,
                                         interrupts: false, evidenceTimestamp: now - r.age)
                if best == nil || priority > best!.intent.priority { best = (intent, r) }
            }
            if let b = best, hasRoom(b.intent.priority, now) {
                let key = b.report.localTrackID.map { "T:\($0)" } ?? b.report.id
                if let intent = stage(b.intent, key: "hidden:" + key, now: now, check: { c in
                    c.hidden.contains { $0.id == b.report.id && $0.source == b.report.source && $0.sector == b.report.sector }
                }, commit: { [weak self] time in
                    guard let self else { return }
                    self.lastHiddenTime = time
                    self.announcedHidden[key] = (time, b.report.sector, b.report.isPrediction)
                    self.announcedHidden[b.report.id] = (time, b.report.sector, b.report.isPrediction)
                    if !b.report.isMover { self.peerKeyLast["hub|\(b.report.label)|\(b.report.sector?.rawValue ?? "-")"] = time }
                }) { out.append(intent) }
            }
        }

        // Encounter risk bypasses the old radius/verbosity gates; the evaluator owns its metric envelope.
        out += encounterIntents(encounters, preferences: preferences, now: now)

        // 4. Housekeeping.
        announcedHidden = announcedHidden.filter { now - $0.value.time < 60 }
        announced = announced.filter { now - $0.value.time < 60 }
        announcedPeer = announcedPeer.filter { now - $0.value < 60 }
        return out.sorted { $0.priority > $1.priority }
    }
    private func encounterIntents(_ results: [EncounterResult], preferences: AlertPreferences, now: Timestamp) -> [AlertIntent] {
        var out: [AlertIntent] = []
        let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for r in results where r.state == .possibleConflict || r.state == .estimatedImminentConflict {
            if r.source == .remoteMeasurement && !preferences.announcePeerObservations { continue }
            guard r.epoch == epoch, r.expiresAt >= now else { continue }
            let imminent = r.state == .estimatedImminentConflict
            if imminent { riskLastUrgent[r.id] = now }
            // Downward hysteresis: do not narrate a temporary drop immediately after an urgent estimate.
            if !imminent, now - (riskLastUrgent[r.id] ?? -.infinity) < riskHysteresis { continue }
            let first = r.firstConflict?.lowerBound ?? .infinity
            let earlier = riskDelivered[r.id]
            let increased = earlier.map { (imminent && $0.state != .estimatedImminentConflict) || first < $0.firstConflict - 0.75 } ?? false
            if let earlier, !increased, now - earlier.time < riskCooldown { continue }
            if increased, let earlier, now - earlier.time < 0.5 { continue }
            let intent = AlertIntent(kind: .encounter(label: r.label, predicted: r.source == .prediction,
                remote: r.source == .remoteMeasurement, hidden: r.source == .prediction || r.occluder != nil, imminent: imminent),
                sector: r.sector, distance: nil, source: r.source == .remoteMeasurement ? .peer(cameraID: "hub") : .localCamera,
                priority: imminent ? 110 : 85, interrupts: imminent, evidenceTimestamp: r.evaluatedAt)
            if let staged = stage(intent, key: "risk:" + r.id, now: now, lifetime: max(0, r.expiresAt - now), replace: increased,
                check: { c in c.encounters.contains { $0.id == r.id && $0.state == r.state && $0.source == r.source &&
                    $0.sector == r.sector && $0.epoch == r.epoch && $0.expiresAt >= c.now } },
                commit: { [weak self] time in
                    self?.riskDelivered[r.id] = (time, r.state, first, r.label, r.source == .prediction)
                    self?.lossDelivered.remove(r.id)
                }) { out.append(staged) }
        }
        for (id, delivered) in riskDelivered where delivered.predicted && !lossDelivered.contains(id) {
            if let r = byID[id], r.state != .notAssessable { continue }
            let intent = AlertIntent(kind: .localizationLost(label: delivered.label), sector: nil, distance: nil, source: .localCamera,
                                     priority: 90, interrupts: false, evidenceTimestamp: now)
            if let staged = stage(intent, key: "loss:" + id, now: now, lifetime: 1.2,
                check: { c in !c.encounters.contains { $0.id == id && $0.state != .notAssessable } },
                commit: { [weak self] _ in self?.lossDelivered.insert(id) }) { out.append(staged) }
        }
        return out
    }

}
