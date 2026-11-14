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

    public init(config: AlertConfig = AlertConfig()) { self.config = config }

    public func reset() {
        announced.removeAll(); classSectorLast.removeAll(); announcedPeer.removeAll(); peerKeyLast.removeAll()
        lastObstacleTime = -.infinity
    }

    public func decide(local: [LocalCandidate], peers: [ResolvedPeerObservation] = [], reliability: ReliabilityReport,
                       events: [SystemNotice] = [], preferences: AlertPreferences = AlertPreferences(),
                       now: Timestamp) -> [AlertIntent] {
        var out: [AlertIntent] = []
        func system(_ n: SystemNotice, _ priority: Int, interrupts: Bool = false) {
            out.append(AlertIntent(kind: .system(n), sector: nil, distance: nil, source: .localCamera, priority: priority,
                                   interrupts: interrupts, evidenceTimestamp: now))
        }

        // 1. Perception state changes outrank everything: the user must know when the system cannot see.
        let semantic = reliability.status(.semanticDetection)
        if semantic.state == .unavailable {
            // A deliberate pause is announced once; a real perception failure is repeated while it lasts.
            let repeatDue = semantic.reasons.first != .paused && now - lastUnavailableAnnounce >= config.unavailableRepeat
            if lastSemantic != .unavailable || repeatDue {
                system(.perceptionUnavailable(semantic.reasons.first), 100, interrupts: true)
                lastUnavailableAnnounce = now
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
                $0.entry.isCurrentEvidence && $0.entry.track.confirmed && $0.entry.ageSinceObserved <= config.maxEvidenceAge
                    && $0.relevance.score >= threshold
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
                    return a.sector != sector || (nowMoving && !a.moving) || now - a.time >= config.reannounceInterval
                }
                if fresh.isEmpty { continue }
                let newlyMoving = fresh.contains { m in
                    (m.relevance.moving || m.relevance.approachCue) && !(announced[m.entry.track.id]?.moving ?? false)
                }
                if let t = classSectorLast[key], now - t < config.classSectorCooldown, !newlyMoving { continue }
                let top = members.max { $0.relevance.score < $1.relevance.score }!
                var priority = sector == .ahead ? 60 : (sector == nil ? 35 : 40)
                if moving { priority += 20 }
                priority += Int(10 * top.relevance.score)
                let intent = AlertIntent(kind: .obstacle(label: top.entry.track.label, count: members.count, moving: moving),
                                         sector: sector, distance: distanceOK ? top.relevance.distance : nil,
                                         source: .localCamera, priority: priority, interrupts: false,
                                         evidenceTimestamp: top.entry.track.lastObserved)
                if best == nil || priority > best!.intent.priority { best = (intent, key, members, sector, moving) }
            }
            if let b = best, now - lastObstacleTime >= config.minGapBetweenObstacleAlerts || b.intent.priority >= 80 {
                out.append(b.intent)
                lastObstacleTime = now
                classSectorLast[b.key] = now
                for m in b.members {
                    announced[m.entry.track.id] = (now, b.sector, m.relevance.moving || m.relevance.approachCue)
                }
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
                    out.append(AlertIntent(kind: .peerObstacle(label: p.observation.label), sector: p.sector, distance: p.distance,
                                           source: .peer(cameraID: p.observation.cameraID),
                                           priority: (p.distance?.meters ?? 99) < 2 ? 65 : 55, interrupts: false,
                                           evidenceTimestamp: now - p.captureAge))
                    announcedPeer[p.observation.id] = now
                    peerKeyLast[key] = now
                }
            }
            // Unaligned observations never become a warning; at most an occasional, clearly non-directional status.
            if preferences.verbosity == .detailed, peers.contains(where: { $0.status == .locationUnverified }),
               now - lastUnverifiedNotice >= config.unverifiedNoticeInterval {
                system(.peerObservationUnverified, 20)
                lastUnverifiedNotice = now
            }
        }

        // 4. Housekeeping.
        announced = announced.filter { now - $0.value.time < 60 }
        announcedPeer = announcedPeer.filter { now - $0.value < 60 }
        return out.sorted { $0.priority > $1.priority }
    }
}
