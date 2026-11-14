import XCTest
@testable import SharedSightCore

let t0 = 100.0
let frame = 1.0 / 30.0
let levelCamera = CameraContext(horizontalFOVDeg: 42, pitchDeg: 0, rollDeg: 0, angularRate: 0.05, steady: true)

func det(_ cls: Int = 0, _ label: String = "person", cx: Double, cy: Double = 0.5, w: Double = 0.2, h: Double = 0.4,
         conf: Double = 0.9, t: Double, mask: Bool = false) -> Detection {
    Detection(classIndex: cls, label: label, confidence: conf, box: NormRect(cx: cx, cy: cy, w: w, h: h),
              timestamp: t, modelID: "test", hasMask: mask)
}

func snap(_ id: Int, _ label: String = "chair", cx: Double = 0.5, observed: Bool = true, last: Double) -> TrackSnapshot {
    TrackSnapshot(id: id, classIndex: 56, label: label, box: NormRect(cx: cx, cy: 0.6, w: 0.3, h: 0.5), velocityX: 0,
                  velocityY: 0, scaleRate: 0, confidence: 0.9, hits: 10, consecutiveMisses: observed ? 0 : 3,
                  firstSeen: last - 1, lastObserved: last, observedThisFrame: observed, confirmed: true,
                  identityAmbiguous: false, positionSigma: 0.01, lastObservationID: nil, hasMask: false)
}

func entry(_ id: Int, _ label: String = "chair", cx: Double = 0.5, now: Double, state: MemoryState = .observed, age: Double = 0) -> MemoryEntry {
    MemoryEntry(track: snap(id, label, cx: cx, observed: state == .observed, last: now - age), state: state,
                stateSince: now - age, ageSinceObserved: age)
}

func candidate(_ id: Int, _ label: String = "chair", cx: Double = 0.5, now: Double, state: MemoryState = .observed,
               age: Double = 0, camera: CameraContext = levelCamera, distance: DistanceMeasurement? = nil) -> LocalCandidate {
    let e = entry(id, label, cx: cx, now: now, state: state, age: age)
    return LocalCandidate(entry: e, relevance: SpatialRelevanceEstimator().assess(e, camera: camera, distance: distance))
}

func healthyInputs() -> ReliabilityInputs {
    var i = ReliabilityInputs()
    i.camera = .running; i.frameAge = 0.03; i.modelLoaded = true; i.modelSupportsMasks = true
    i.meanLuma = 0.4; i.lumaSpread = 0.2; i.angularRate = 0.1; i.pitchDeg = 0; i.rollDeg = 0; i.audioReady = true
    return i
}

func healthyReport() -> ReliabilityReport { PerceptionReliabilityEngine().evaluate(healthyInputs()) }

func obstacleIntents(_ intents: [AlertIntent]) -> [AlertIntent] {
    intents.filter { if case .obstacle = $0.kind { return true }; return false }
}
func peerIntents(_ intents: [AlertIntent]) -> [AlertIntent] {
    intents.filter { if case .peerObstacle = $0.kind { return true }; return false }
}

func deliver(_ msgs: [PeerMessage], from: String, to engine: SharedSightCollaborationEngine, now: Double) -> [PeerMessage] {
    msgs.flatMap { engine.receive($0, from: from, now: now) }
}

/// Simulates the transport handshake between two engines sharing one test clock.
func connect(_ a: SharedSightCollaborationEngine, _ b: SharedSightCollaborationEngine, now: Double) {
    _ = a.setConsent(true); _ = b.setConsent(true)
    let fromA = a.peerConnected("B", now: now), fromB = b.peerConnected("A", now: now)
    let repliesB = deliver(fromA, from: "A", to: b, now: now + 0.01)
    let repliesA = deliver(fromB, from: "B", to: a, now: now + 0.01)
    _ = deliver(repliesB, from: "B", to: a, now: now + 0.02)
    _ = deliver(repliesA, from: "A", to: b, now: now + 0.02)
}

func anchored(camera: Pose = .identity, worldFromAnchor: Pose = .identity, now: Double) -> LocalSpatialState {
    LocalSpatialState(anchorID: "marker-01", worldFromAnchor: worldFromAnchor, anchorFixTime: now,
                      worldFromCamera: camera, trackingNormal: true)
}
