import Foundation

public enum PeerObservationStatus: String, Codable, Sendable {
    case received = "PEER_OBSERVATION_RECEIVED"
    case locationUnverified = "SHARED_LOCATION_UNVERIFIED"
    case spatiallyRelevant = "SPATIALLY_RELEVANT_OBSERVATION"
    case expired = "SHARED_OBSERVATION_EXPIRED"
}

public enum PeerLinkState: String, Codable, Sendable {
    case off = "COLLABORATION_OFF"
    case searching = "SEARCHING_FOR_PEER"
    case connected = "PEER_CONNECTED"
}

/// Structured metadata only — never pixels, never identity. Positions are present only when the sender
/// measured them and expressed them in the shared anchor frame.
public struct SharedObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var cameraID: String          // temporary, random per session
    public var label: String
    public var classIndex: Int
    public var confidence: Double
    public var captureTime: Double       // sender's monotonic clock
    public var bearingDeg: Double?       // sender-camera-relative; informational only
    public var anchorID: String?
    public var anchorPosition: Vec3?     // metres, in the shared anchor frame
    public var positionSigma: Double?

    public init(id: UUID, cameraID: String, label: String, classIndex: Int, confidence: Double, captureTime: Double,
                bearingDeg: Double?, anchorID: String?, anchorPosition: Vec3?, positionSigma: Double?) {
        self.id = id; self.cameraID = cameraID; self.label = label; self.classIndex = classIndex
        self.confidence = confidence; self.captureTime = captureTime; self.bearingDeg = bearingDeg
        self.anchorID = anchorID; self.anchorPosition = anchorPosition; self.positionSigma = positionSigma
    }
}

public enum PeerMessage: Codable, Equatable, Sendable {
    case hello(cameraID: String, protocolVersion: Int)
    case observations([SharedObservation])
    case ping(t0: Double)
    case pong(t0: Double, t1: Double)
    case consentWithdrawn
}

/// The receiving device's own spatial knowledge. All optional: absence means "cannot align".
public struct LocalSpatialState: Sendable, Equatable {
    public var anchorID: String?
    public var worldFromAnchor: Pose?
    public var anchorFixTime: Timestamp?
    public var worldFromCamera: Pose?
    public var trackingNormal: Bool
    public init(anchorID: String? = nil, worldFromAnchor: Pose? = nil, anchorFixTime: Timestamp? = nil,
                worldFromCamera: Pose? = nil, trackingNormal: Bool = false) {
        self.anchorID = anchorID; self.worldFromAnchor = worldFromAnchor; self.anchorFixTime = anchorFixTime
        self.worldFromCamera = worldFromCamera; self.trackingNormal = trackingNormal
    }
    public static let none = LocalSpatialState()
}

public struct OutgoingObservation: Sendable {
    public var entry: MemoryEntry
    public var bearingDeg: Double?
    public var worldPosition: Vec3?   // measured (depth / ground raycast) in the sender's world frame
    public var positionSigma: Double?
    public init(entry: MemoryEntry, bearingDeg: Double?, worldPosition: Vec3?, positionSigma: Double?) {
        self.entry = entry; self.bearingDeg = bearingDeg; self.worldPosition = worldPosition; self.positionSigma = positionSigma
    }
}

public struct ResolvedPeerObservation: Sendable, Equatable, Identifiable {
    public var id: UUID { observation.id }
    public var observation: SharedObservation
    public var status: PeerObservationStatus
    public var sector: Sector?
    public var bearingDeg: Double?
    public var distance: DistanceMeasurement?
    public var captureAge: Double
    public var unverifiedReason: String?
}

public struct CollaborationConfig: Sendable {
    public var protocolVersion = 1
    public var observationTTL = 2.5          // seconds after capture during which an observation may be acted upon
    public var retention = 8.0               // expired observations stay visible (as expired) this long
    public var assumedLatencyWithoutClockSync = 0.5
    public var maxFutureSkew = 0.5
    public var anchorMaxAge = 180.0
    public var maxPositionSigma = 0.6
    public var relevanceRadius = 6.0
    public var pingInterval = 2.0
    public init() {}
}

/// Transport-agnostic collaboration logic (late / object-level fusion). The engine never merges a peer's
/// observation into local detections: peer data keeps its source and is only localised through a shared,
/// validated anchor. A network link alone yields SHARED_LOCATION_UNVERIFIED.
public final class SharedSightCollaborationEngine {
    public var config: CollaborationConfig
    public let cameraID: String
    public private(set) var consentGiven = false

    private struct Peer {
        var cameraID: String?
        var connected = true
        var lastHeard: Timestamp
        var clockOffset: Double?      // peerClock - localClock
        var bestRTT = Double.infinity
        var observations: [UUID: (obs: SharedObservation, receivedAt: Timestamp)] = [:]
    }
    private var peers: [String: Peer] = [:]
    private var shareIDs: [Int: UUID] = [:]
    private var lastPing: Timestamp = -.infinity
    private var pendingEvents: [SystemNotice] = []

    public init(config: CollaborationConfig = CollaborationConfig(), cameraID: String = "cam-" + UUID().uuidString.prefix(8).lowercased()) {
        self.config = config; self.cameraID = cameraID
    }

    public var connectedPeerCount: Int { peers.values.filter { $0.connected }.count }
    public var linkState: PeerLinkState { !consentGiven ? .off : (connectedPeerCount > 0 ? .connected : .searching) }
    public func lastHeardAge(now: Timestamp) -> Double? { peers.values.filter { $0.connected }.map { now - $0.lastHeard }.min() }
    public func clockOffsetKnown() -> Bool { peers.values.contains { $0.connected && $0.clockOffset != nil } }
    public func drainEvents() -> [SystemNotice] { defer { pendingEvents.removeAll() }; return pendingEvents }

    /// Turning consent off takes effect immediately: stored peer data is dropped and nothing further is sent or accepted.
    public func setConsent(_ on: Bool) -> [PeerMessage] {
        guard on != consentGiven else { return [] }
        consentGiven = on
        if on { pendingEvents.append(.collaborationOn); return [] }
        let hadPeers = connectedPeerCount > 0
        peers.removeAll(); shareIDs.removeAll()
        pendingEvents.append(.collaborationOff)
        return hadPeers ? [.consentWithdrawn] : []
    }

    public func peerConnected(_ pid: String, now: Timestamp) -> [PeerMessage] {
        guard consentGiven else { return [] }
        peers[pid] = Peer(lastHeard: now)
        pendingEvents.append(.peerConnected)
        lastPing = now
        return [.hello(cameraID: cameraID, protocolVersion: config.protocolVersion), .ping(t0: now)]
    }

    /// A lost sensor's observations expire at once; they are kept only to be displayed as expired.
    public func peerDisconnected(_ pid: String, now: Timestamp) {
        guard var p = peers[pid], p.connected else { return }
        p.connected = false
        peers[pid] = p
        pendingEvents.append(.peerLost)
    }

    public func receive(_ message: PeerMessage, from pid: String, now: Timestamp) -> [PeerMessage] {
        guard consentGiven, var p = peers[pid], p.connected else { return [] }
        p.lastHeard = now
        var replies: [PeerMessage] = []
        switch message {
        case let .hello(cam, version):
            if version == config.protocolVersion { p.cameraID = cam }
        case let .ping(t0):
            replies.append(.pong(t0: t0, t1: now))
        case let .pong(t0, t1):
            let rtt = now - t0
            if rtt >= 0, rtt < p.bestRTT { p.bestRTT = rtt; p.clockOffset = t1 - (t0 + rtt / 2) }
        case let .observations(list):
            guard p.cameraID != nil else { break }   // no attribution, no acceptance
            for o in list where o.cameraID == p.cameraID {
                let age = captureAge(o, receivedAt: now, peer: p, now: now)
                if age < -config.maxFutureSkew || age > config.retention { continue }  // implausible timestamp
                p.observations[o.id] = (o, now)
            }
        case .consentWithdrawn:
            p.observations.removeAll()
            p.connected = false
            pendingEvents.append(.peerLost)
        }
        peers[pid] = p
        return replies
    }

    /// Builds the outgoing batch from *direct, current* observations only. Predictions and memories are never shared.
    public func makeOutgoing(_ items: [OutgoingObservation], spatial: LocalSpatialState, now: Timestamp) -> [PeerMessage] {
        guard consentGiven, connectedPeerCount > 0 else { return [] }
        var messages: [PeerMessage] = []
        if now - lastPing >= config.pingInterval { messages.append(.ping(t0: now)); lastPing = now }
        let anchorUsable = spatial.trackingNormal && spatial.worldFromAnchor != nil && spatial.anchorID != nil
            && spatial.anchorFixTime.map { now - $0 <= config.anchorMaxAge } == true
        let anchorFromWorld = anchorUsable ? spatial.worldFromAnchor!.inverseRigid() : nil
        let observations: [SharedObservation] = items.filter { $0.entry.isCurrentEvidence && $0.entry.track.confirmed }.map { item in
            let t = item.entry.track
            let sid = shareIDs[t.id] ?? UUID()
            shareIDs[t.id] = sid
            var position: Vec3?
            if let afw = anchorFromWorld, let wp = item.worldPosition { position = afw.transform(wp) }
            return SharedObservation(id: sid, cameraID: cameraID, label: t.label, classIndex: t.classIndex, confidence: t.confidence,
                                     captureTime: t.lastObserved, bearingDeg: item.bearingDeg,
                                     anchorID: position != nil ? spatial.anchorID : nil, anchorPosition: position,
                                     positionSigma: position != nil ? item.positionSigma : nil)
        }
        if !observations.isEmpty { messages.append(.observations(observations)) }
        return messages
    }

    private func captureAge(_ o: SharedObservation, receivedAt: Timestamp, peer: Peer, now: Timestamp) -> Double {
        if let offset = peer.clockOffset { return now - (o.captureTime - offset) }
        return (now - receivedAt) + config.assumedLatencyWithoutClockSync
    }

    /// Classifies every stored peer observation for the current instant and the receiver's own spatial state.
    public func resolve(spatial: LocalSpatialState, now: Timestamp) -> [ResolvedPeerObservation] {
        guard consentGiven else { return [] }
        var out: [ResolvedPeerObservation] = []
        for (pid, peer) in peers {
            var kept = peer.observations
            for (id, rec) in peer.observations {
                let age = captureAge(rec.obs, receivedAt: rec.receivedAt, peer: peer, now: now)
                if age > config.retention { kept[id] = nil; continue }
                if !peer.connected || age > config.observationTTL {
                    out.append(ResolvedPeerObservation(observation: rec.obs, status: .expired, sector: nil, bearingDeg: nil,
                                                       distance: nil, captureAge: age, unverifiedReason: nil))
                    continue
                }
                out.append(localise(rec.obs, age: age, spatial: spatial, now: now))
            }
            peers[pid]?.observations = kept
        }
        return out
    }

    private func localise(_ o: SharedObservation, age: Double, spatial: LocalSpatialState, now: Timestamp) -> ResolvedPeerObservation {
        func unverified(_ reason: String) -> ResolvedPeerObservation {
            ResolvedPeerObservation(observation: o, status: .locationUnverified, sector: nil, bearingDeg: nil, distance: nil,
                                    captureAge: age, unverifiedReason: reason)
        }
        guard let pa = o.anchorPosition, let senderAnchor = o.anchorID else { return unverified("sender has no measured position") }
        guard let sigma = o.positionSigma, sigma <= config.maxPositionSigma else { return unverified("sender position too uncertain") }
        guard let anchorID = spatial.anchorID, let worldFromAnchor = spatial.worldFromAnchor else { return unverified("no shared anchor on this device") }
        guard anchorID == senderAnchor else { return unverified("different anchors") }
        guard let fix = spatial.anchorFixTime, now - fix <= config.anchorMaxAge else { return unverified("anchor fix too old") }
        guard spatial.trackingNormal, let worldFromCamera = spatial.worldFromCamera else { return unverified("world tracking not normal") }

        let world = worldFromAnchor.transform(pa)
        var d = world - worldFromCamera.translation
        d.y = 0
        let dist = d.length
        let measurement = DistanceMeasurement(meters: dist, sigma: sigma, method: .sharedAnchor)
        guard dist <= config.relevanceRadius else {
            return ResolvedPeerObservation(observation: o, status: .received, sector: nil, bearingDeg: nil, distance: measurement,
                                           captureAge: age, unverifiedReason: nil)
        }
        // Heading = horizontal projection of the camera's viewing direction (-Z). Undefined when pointing up/down.
        var f = worldFromCamera.axis(2) * -1
        f.y = 0
        var sector: Sector?
        var bearing: Double?
        if f.length >= 0.35, dist > 0.05 {
            f = f * (1 / f.length)
            let right = f.cross(Vec3(0, 1, 0))
            let b = atan2(d.dot(right), d.dot(f)) * 180 / .pi
            bearing = b
            sector = abs(b) <= 25 ? .ahead : (abs(b) >= 135 ? .behind : (b < 0 ? .left : .right))
        }
        return ResolvedPeerObservation(observation: o, status: .spatiallyRelevant, sector: sector, bearingDeg: bearing,
                                       distance: measurement, captureAge: age, unverifiedReason: nil)
    }
}
