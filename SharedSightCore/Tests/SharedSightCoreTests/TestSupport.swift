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

/// The decision engine together with the app's real speech queue and a simulated voice (about 15 characters per
/// second), wired exactly like AudioFeedbackEngine: cooldowns are committed only when speech really starts.
/// Unit tests that check "said once" or "said again later" must run against this, not against the bare engine.
final class SpokenAlerts {
    let engine: ObstacleAlertDecisionEngine
    private var queue = RevocableSpeechQueue()
    private var current: (id: UUID, end: Double)?
    private let builder = AlertPhraseBuilder(language: .italian)
    init(config: AlertConfig = AlertConfig()) { engine = ObstacleAlertDecisionEngine(config: config) }
    var config: AlertConfig { get { engine.config } set { engine.config = newValue } }
    func reset() { engine.reset(); queue = RevocableSpeechQueue(); current = nil }

    private func perform(_ actions: [SpeechQueueAction], at t: Double) {
        for action in actions {
            switch action {
            case let .lifecycle(intent, phase): engine.delivery(intent, phase: phase, at: t)
            case let .stop(id):
                guard current?.id == id else { continue }
                current = nil
                perform(queue.didEnd(id, cancelled: true, now: t, validation: engine.validationSnapshot), at: t)
            case let .speak(item):
                current = (item.id, t + 0.25 + Double(item.text.count) / 15)
                perform(queue.didStart(item.id, now: t, validation: engine.validationSnapshot), at: t)
            }
        }
    }
    private func advance(to now: Double) {
        while let c = current, c.end <= now {
            current = nil
            perform(queue.didEnd(c.id, cancelled: false, now: c.end, validation: engine.validationSnapshot), at: c.end)
        }
    }

    func decide(local: [LocalCandidate], peers: [ResolvedPeerObservation] = [], hidden: [HiddenReport] = [],
                reliability: ReliabilityReport, events: [SystemNotice] = [],
                preferences: AlertPreferences = AlertPreferences(), encounters: [EncounterResult] = [], epoch: String = "local",
                now: Timestamp) -> [AlertIntent] {
        advance(to: now)
        let intents = engine.decide(local: local, peers: peers, hidden: hidden, reliability: reliability, events: events,
                                    preferences: preferences, encounters: encounters, epoch: epoch, now: now)
        perform(queue.revalidate(now: now, validation: engine.validationSnapshot), at: now)
        for intent in intents {
            perform(queue.submit(SpeechItem(text: builder.phrase(for: intent), intent: intent, now: now), now: now,
                                 validation: engine.validationSnapshot), at: now)
        }
        return intents
    }
}
