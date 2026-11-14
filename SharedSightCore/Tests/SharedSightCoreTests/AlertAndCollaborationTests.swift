import XCTest
@testable import SharedSightCore

final class ReliabilityAndAlertTests: XCTestCase {

    func testCameraFailureSuppressesObstaclesAndIsAnnounced() {
        var i = healthyInputs(); i.camera = .unavailable
        let report = PerceptionReliabilityEngine().evaluate(i)
        XCTAssertEqual(report.status(.semanticDetection).state, .unavailable)
        XCTAssertEqual(report.status(.tracking).state, .unavailable)
        let engine = ObstacleAlertDecisionEngine()
        let first = engine.decide(local: [candidate(1, now: t0)], reliability: report, now: t0)
        XCTAssertEqual(first.first?.kind, .system(.perceptionUnavailable(.cameraUnavailable)))
        XCTAssertTrue(first.first!.interrupts)
        XCTAssertTrue(obstacleIntents(first).isEmpty, "no obstacle guidance without perception")
        XCTAssertTrue(engine.decide(local: [], reliability: report, now: t0 + 1).isEmpty, "no spam")
        XCTAssertEqual(engine.decide(local: [], reliability: report, now: t0 + 9).count, 1, "periodic reminder while blind")
        let restored = engine.decide(local: [], reliability: healthyReport(), now: t0 + 10)
        XCTAssertEqual(restored.first?.kind, .system(.perceptionRestored))
    }

    func testCoveredLensIsReportedAndNeverCalledClear() {
        var i = healthyInputs(); i.meanLuma = 0.01; i.lumaSpread = 0.004
        let status = PerceptionReliabilityEngine().evaluate(i).status(.semanticDetection)
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.reasons, [.lensCoveredOrDark])
        // No phrase the system can produce may claim a clear or safe path.
        let notices: [SystemNotice] = [.perceptionUnavailable(nil), .perceptionUnavailable(.lensCoveredOrDark), .perceptionRestored,
                                       .perceptionDegraded(.lowLight), .peerConnected, .peerLost, .peerObservationUnverified,
                                       .collaborationOn, .collaborationOff, .sharedReferenceReady]
        for language in SpeechLanguage.allCases {
            for n in notices {
                let p = AlertPhraseBuilder(language: language).systemPhrase(n).lowercased()
                for forbidden in ["clear", "safe", "libero", "libera", "sicuro", "sicura"] { XCTAssertFalse(p.contains(forbidden), p) }
            }
        }
    }

    func testModelFailureIsExplicit() {
        var i = healthyInputs(); i.modelLoaded = false
        let s = PerceptionReliabilityEngine().evaluate(i).status(.semanticDetection)
        XCTAssertEqual(s.state, .unavailable)
        XCTAssertTrue(s.reasons.contains(.modelNotLoaded))
    }

    func testReliabilityIsFeatureSpecific() {
        let report = healthyReport()
        XCTAssertEqual(report.status(.semanticDetection).state, .reliable)
        XCTAssertEqual(report.status(.metricDistance).state, .unavailable, "a working detector does not provide distance")
        XCTAssertEqual(report.status(.unknownObstacleSensing).state, .unavailable)
        XCTAssertEqual(report.status(.sharedSpatialReference).state, .unavailable)
        // A distance attached to a candidate is not spoken while the distance feature is unavailable.
        let d = DistanceMeasurement(meters: 2, sigma: 0.2, method: .groundPlaneRaycast)
        let intents = ObstacleAlertDecisionEngine().decide(local: [candidate(1, now: t0, distance: d)], reliability: report, now: t0)
        XCTAssertNil(obstacleIntents(intents).first?.distance)
        var i = healthyInputs(); i.depthSourceAvailable = true; i.worldTrackingNormal = true
        let withDepth = ObstacleAlertDecisionEngine().decide(local: [candidate(1, now: t0, distance: d)],
                                                             reliability: PerceptionReliabilityEngine().evaluate(i), now: t0)
        XCTAssertEqual(obstacleIntents(withDepth).first?.distance, d)
    }

    func testStaleOrPredictedObservationsAreNeverAnnounced() {
        let engine = ObstacleAlertDecisionEngine(), report = healthyReport()
        XCTAssertTrue(obstacleIntents(engine.decide(local: [candidate(1, now: t0, age: 1.0)], reliability: report, now: t0)).isEmpty)
        for state in [MemoryState.predicted, .temporarilyHidden, .unknown, .lost] {
            let intents = engine.decide(local: [candidate(2, now: t0 + 1, state: state, age: 0.2)], reliability: report, now: t0 + 1)
            XCTAssertTrue(obstacleIntents(intents).isEmpty, "\(state) must not be spoken as an observation")
        }
        XCTAssertEqual(obstacleIntents(engine.decide(local: [candidate(3, now: t0 + 2)], reliability: report, now: t0 + 2)).count, 1)
    }

    func testAudioDeduplication() {
        let engine = ObstacleAlertDecisionEngine(), report = healthyReport()
        var spoken = 0
        for step in 0..<50 {
            let now = t0 + Double(step) * 0.1
            var local = [candidate(1, now: now)]
            if step >= 20 { local.append(candidate(2, now: now)) }   // tracker re-issued an ID for the same thing
            spoken += obstacleIntents(engine.decide(local: local, reliability: report, now: now)).count
        }
        XCTAssertEqual(spoken, 2, "one announcement, plus at most one after the class/sector cooldown for the new ID")
        let single = ObstacleAlertDecisionEngine()
        var count = 0
        for step in 0..<50 { let now = t0 + Double(step) * 0.1; count += obstacleIntents(single.decide(local: [candidate(1, now: now)], reliability: report, now: now)).count }
        XCTAssertEqual(count, 1)
    }

    func testAlertPriorityAndQueueing() {
        let engine = ObstacleAlertDecisionEngine(), report = healthyReport()
        let ahead = candidate(1, "chair", cx: 0.5, now: t0), side = candidate(2, "person", cx: 0.15, now: t0)
        XCTAssertEqual(ahead.relevance.sector, .ahead); XCTAssertEqual(side.relevance.sector, .left)
        let first = obstacleIntents(engine.decide(local: [side, ahead], reliability: report, now: t0))
        XCTAssertEqual(first.count, 1, "one obstacle alert at a time")
        XCTAssertEqual(first[0].kind, .obstacle(label: "chair", count: 1, moving: false))
        let later = t0 + 2
        let second = obstacleIntents(engine.decide(local: [candidate(2, "person", cx: 0.15, now: later), candidate(1, "chair", cx: 0.5, now: later)],
                                                   reliability: report, now: later))
        XCTAssertEqual(second.first?.kind, .obstacle(label: "person", count: 1, moving: false))
        XCTAssertEqual(second.first?.sector, .left)
    }

    func testUnsupportedDirectionIsSuppressed() {
        let unknownOrientation = CameraContext(horizontalFOVDeg: 42, pitchDeg: nil, rollDeg: nil, angularRate: nil, steady: false)
        let c = candidate(1, cx: 0.1, now: t0, camera: unknownOrientation)
        XCTAssertNil(c.relevance.sector)
        var down = levelCamera; down.pitchDeg = -70
        XCTAssertNil(candidate(1, cx: 0.1, now: t0, camera: down).relevance.sector, "camera pointing at the floor: no left/right wording")
        // Even if a sector was estimated, an unavailable direction feature strips it.
        var i = healthyInputs(); i.pitchDeg = nil
        let intents = obstacleIntents(ObstacleAlertDecisionEngine().decide(local: [candidate(1, cx: 0.5, now: t0)],
                                                                           reliability: PerceptionReliabilityEngine().evaluate(i),
                                                                           preferences: AlertPreferences(), now: t0))
        XCTAssertEqual(intents.count, 1)
        XCTAssertNil(intents[0].sector)
        let phrase = AlertPhraseBuilder(language: .english).phrase(for: intents[0])
        XCTAssertEqual(phrase, "Chair in view.")
    }

    func testPhrasesInBothLanguages() {
        func intent(_ kind: AlertKind, _ sector: Sector?, _ d: Double? = nil) -> AlertIntent {
            AlertIntent(kind: kind, sector: sector, distance: d.map { DistanceMeasurement(meters: $0, sigma: 0.2, method: .groundPlaneRaycast) },
                        source: .localCamera, priority: 50, interrupts: false, evidenceTimestamp: t0)
        }
        let it = AlertPhraseBuilder(language: .italian), en = AlertPhraseBuilder(language: .english)
        XCTAssertEqual(en.phrase(for: intent(.obstacle(label: "chair", count: 1, moving: false), .ahead)), "Chair ahead.")
        XCTAssertEqual(en.phrase(for: intent(.obstacle(label: "person", count: 1, moving: false), .right)), "Person on your right.")
        XCTAssertEqual(it.phrase(for: intent(.obstacle(label: "chair", count: 1, moving: false), .ahead)), "Sedia davanti.")
        XCTAssertEqual(it.phrase(for: intent(.obstacle(label: "person", count: 2, moving: false), .right)), "2 persone a destra.")
        XCTAssertEqual(it.phrase(for: intent(.obstacle(label: "chair", count: 1, moving: true), .ahead, 2.1)), "Sedia davanti, a circa 2 metri, in movimento.")
        XCTAssertEqual(en.phrase(for: intent(.peerObstacle(label: "chair"), .left, 1.4)),
                       "Obstacle reported by another device: chair, on your left, about 1.5 meters.")
        XCTAssertEqual(en.phrase(for: intent(.peerObstacle(label: "chair"), nil)), "Obstacle reported by another device: chair.")
    }
}

final class CollaborationTests: XCTestCase {
    let chairWorld = Vec3(1, 0, -2)

    private func share(from a: SharedSightCollaborationEngine, to b: SharedSightCollaborationEngine, spatial: LocalSpatialState,
                       position: Vec3?, now: Double) {
        let out = a.makeOutgoing([OutgoingObservation(entry: entry(7, "chair", now: now), bearingDeg: 0, worldPosition: position, positionSigma: 0.2)],
                                 spatial: spatial, now: now)
        XCTAssertTrue(out.contains { if case .observations = $0 { return true }; return false })
        _ = deliver(out, from: "A", to: b, now: now + 0.03)
    }

    func testPeerConnectionAndClockSync() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        XCTAssertEqual(a.linkState, .off)
        connect(a, b, now: t0)
        XCTAssertEqual(a.linkState, .connected); XCTAssertEqual(b.linkState, .connected)
        XCTAssertTrue(a.clockOffsetKnown() && b.clockOffsetKnown())
        XCTAssertTrue(b.drainEvents().contains(.peerConnected))
    }

    func testNothingIsSharedWithoutConsentAndWithdrawalIsImmediate() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        XCTAssertTrue(a.peerConnected("B", now: t0).isEmpty, "no consent, no handshake")
        XCTAssertTrue(a.makeOutgoing([OutgoingObservation(entry: entry(7, now: t0), bearingDeg: 0, worldPosition: nil, positionSigma: nil)],
                                     spatial: .none, now: t0).isEmpty)
        connect(a, b, now: t0)
        share(from: a, to: b, spatial: .none, position: nil, now: t0 + 0.1)
        XCTAssertEqual(b.resolve(spatial: .none, now: t0 + 0.2).count, 1)
        XCTAssertEqual(b.setConsent(false), [.consentWithdrawn])
        XCTAssertEqual(b.linkState, .off)
        XCTAssertTrue(b.resolve(spatial: .none, now: t0 + 0.3).isEmpty, "peer data is dropped at once")
        XCTAssertTrue(b.receive(.observations([]), from: "A", now: t0 + 0.4).isEmpty)
        _ = a.receive(.consentWithdrawn, from: "B", now: t0 + 0.4)
        XCTAssertEqual(a.linkState, .searching)
        XCTAssertTrue(a.makeOutgoing([OutgoingObservation(entry: entry(7, now: t0 + 0.5), bearingDeg: 0, worldPosition: nil, positionSigma: nil)],
                                     spatial: .none, now: t0 + 0.5).isEmpty, "nothing is sent to a peer that withdrew")
    }

    func testOnlyDirectObservationsAreShared() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        let predicted = OutgoingObservation(entry: entry(8, now: t0 + 1, state: .predicted, age: 0.8), bearingDeg: 0, worldPosition: nil, positionSigma: nil)
        let out = a.makeOutgoing([predicted], spatial: .none, now: t0 + 1)
        XCTAssertFalse(out.contains { if case .observations = $0 { return true }; return false })
    }

    func testAlignmentFailureYieldsUnverifiedAndNoWarning() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        // Sender measured a position, receiver has no anchor: a network link is not spatial fusion.
        share(from: a, to: b, spatial: anchored(now: t0), position: chairWorld, now: t0 + 0.1)
        let r = b.resolve(spatial: .none, now: t0 + 0.2)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].status, .locationUnverified)
        XCTAssertNil(r[0].sector); XCTAssertNil(r[0].distance); XCTAssertNil(r[0].bearingDeg)
        var i = healthyInputs(); i.collaborationEnabled = true; i.peerConnected = true; i.peerLastHeardAge = 0.1
        let report = PerceptionReliabilityEngine().evaluate(i)
        XCTAssertEqual(report.status(.peerLink).state, .reliable)
        XCTAssertEqual(report.status(.sharedSpatialReference).state, .unavailable)
        XCTAssertTrue(peerIntents(ObstacleAlertDecisionEngine().decide(local: [], peers: r, reliability: report, now: t0 + 0.2)).isEmpty)
        // Different anchors and sender-without-position are also unverified.
        var other = anchored(now: t0); other.anchorID = "marker-02"
        XCTAssertEqual(b.resolve(spatial: other, now: t0 + 0.2)[0].status, .locationUnverified)
        let c = SharedSightCollaborationEngine(cameraID: "cam-c"), d = SharedSightCollaborationEngine(cameraID: "cam-d")
        connect(c, d, now: t0)
        share(from: c, to: d, spatial: .none, position: chairWorld, now: t0 + 0.1)
        XCTAssertEqual(d.resolve(spatial: anchored(now: t0), now: t0 + 0.2)[0].status, .locationUnverified)
    }

    func testSpatiallyJustifiedPeerWarningIsAttributed() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        share(from: a, to: b, spatial: anchored(now: t0), position: chairWorld, now: t0 + 0.1)
        // B uses a different world frame: its anchor pose differs, but relative geometry must be preserved.
        let bWorldFromAnchor = Pose.yaw(90, translation: Vec3(3, 0, 1))
        let bCameraInAnchor = Pose.yaw(0, translation: Vec3(0, 1.4, 0))   // 1.4 m above the anchor, looking along anchor -Z
        let spatialB = anchored(camera: bWorldFromAnchor * bCameraInAnchor, worldFromAnchor: bWorldFromAnchor, now: t0)
        let r = b.resolve(spatial: spatialB, now: t0 + 0.2)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].status, .spatiallyRelevant)
        XCTAssertEqual(r[0].distance!.meters, 5.0.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(r[0].bearingDeg!, atan2(1, 2) * 180 / .pi, accuracy: 1e-6)
        XCTAssertEqual(r[0].sector, .right)
        var i = healthyInputs(); i.collaborationEnabled = true; i.peerConnected = true; i.peerLastHeardAge = 0.1
        i.sharedAnchorValid = true; i.worldTrackingNormal = true
        let engine = ObstacleAlertDecisionEngine()
        let intents = peerIntents(engine.decide(local: [], peers: r, reliability: PerceptionReliabilityEngine().evaluate(i), now: t0 + 0.2))
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].source, .peer(cameraID: "cam-a"), "a peer observation is never presented as a local detection")
        XCTAssertTrue(AlertPhraseBuilder(language: .english).phrase(for: intents[0]).hasPrefix("Obstacle reported by another device"))
        XCTAssertTrue(peerIntents(engine.decide(local: [], peers: r, reliability: PerceptionReliabilityEngine().evaluate(i), now: t0 + 0.4)).isEmpty, "announced once")
    }

    func testSharedObservationsExpire() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        share(from: a, to: b, spatial: .none, position: nil, now: t0 + 0.1)
        XCTAssertEqual(b.resolve(spatial: .none, now: t0 + 1.0).first?.status, .locationUnverified)
        XCTAssertEqual(b.resolve(spatial: .none, now: t0 + 3.0).first?.status, .expired)
        XCTAssertTrue(b.resolve(spatial: .none, now: t0 + 9.0).isEmpty)
    }

    func testPeerLossExpiresSharedDataAndLocalPerceptionContinues() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        share(from: a, to: b, spatial: anchored(now: t0), position: chairWorld, now: t0 + 0.1)
        _ = b.drainEvents()
        b.peerDisconnected("A", now: t0 + 0.2)
        XCTAssertEqual(b.linkState, .searching)
        XCTAssertEqual(b.drainEvents(), [.peerLost])
        let r = b.resolve(spatial: anchored(now: t0), now: t0 + 0.3)
        XCTAssertTrue(r.allSatisfy { $0.status == .expired })
        let intents = ObstacleAlertDecisionEngine().decide(local: [candidate(1, now: t0 + 0.3)], peers: r, reliability: healthyReport(),
                                                           events: [.peerLost], now: t0 + 0.3)
        XCTAssertTrue(peerIntents(intents).isEmpty)
        XCTAssertEqual(obstacleIntents(intents).count, 1, "the phone keeps working alone with its own camera")
        XCTAssertTrue(intents.contains { $0.kind == .system(.peerLost) })
    }

    func testReconnection() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        a.peerDisconnected("B", now: t0 + 1); b.peerDisconnected("A", now: t0 + 1)
        XCTAssertEqual(b.linkState, .searching)
        connect(a, b, now: t0 + 5)
        XCTAssertEqual(b.linkState, .connected)
        share(from: a, to: b, spatial: .none, position: nil, now: t0 + 5.1)
        XCTAssertEqual(b.resolve(spatial: .none, now: t0 + 5.2).first?.status, .locationUnverified)
    }

    func testImplausibleTimestampsAndUnattributedDataAreRejected() {
        let a = SharedSightCollaborationEngine(cameraID: "cam-a"), b = SharedSightCollaborationEngine(cameraID: "cam-b")
        connect(a, b, now: t0)
        func obs(_ cam: String, _ time: Double) -> SharedObservation {
            SharedObservation(id: UUID(), cameraID: cam, label: "chair", classIndex: 56, confidence: 0.9, captureTime: time,
                              bearingDeg: nil, anchorID: nil, anchorPosition: nil, positionSigma: nil)
        }
        _ = b.receive(.observations([obs("cam-a", t0 + 60), obs("cam-a", t0 - 60), obs("someone-else", t0)]), from: "A", now: t0 + 0.1)
        XCTAssertTrue(b.resolve(spatial: .none, now: t0 + 0.2).isEmpty)
    }
}
