import XCTest
@testable import SharedSightCore

final class HubLinkTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"

    func testParsesFullPayload() {
        let link = HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F192.168.1.20%3A8080&token=\(token)&session=4821")
        XCTAssertEqual(link, HubLink(url: "http://192.168.1.20:8080", token: token, session: "4821"))
    }

    func testSessionIsOptionalAndHttpsIsAccepted() {
        let link = HubLinkPayload.parse("  sharedsight://hub?url=https%3A%2F%2Fhub.local%3A8443&token=\(token)\n")
        XCTAssertEqual(link, HubLink(url: "https://hub.local:8443", token: token, session: nil))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F10.0.0.2%3A8080&token=\(token)&session=")?.session)
    }

    func testRejectsOtherSchemesAndHosts() {
        XCTAssertNil(HubLinkPayload.parse("https://example.com/?url=http%3A%2F%2F10.0.0.2%3A8080&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://other?url=http%3A%2F%2F10.0.0.2%3A8080&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("SSGT1:\(token)"))
        XCTAssertNil(HubLinkPayload.parse(""))
        XCTAssertNil(HubLinkPayload.parse("not a link at all"))
    }

    func testRejectsNonHttpHubAddress() {
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=ftp%3A%2F%2F10.0.0.2%3A8080&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=javascript%3Aalert(1)&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=10.0.0.2%3A8080&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2Fuser%3Apw%4010.0.0.2%3A8080&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F10.0.0.2%3A8080%2F%3Fa%3Db&token=\(token)"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?token=\(token)"))
    }

    func testRejectsEmptyOrMissingToken() {
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F10.0.0.2%3A8080&token="))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F10.0.0.2%3A8080"))
        XCTAssertNil(HubLinkPayload.parse("sharedsight://hub?url=http%3A%2F%2F10.0.0.2%3A8080&token=ab%20cd"))
    }
}

final class WallProximityTests: XCTestCase {
    /// Feeds forward distances every 0.1 s starting at `t0`; returns (time, alert) for every alert.
    private func run(_ monitor: inout WallProximityMonitor, _ distances: [Double?], from t0: Double = 0,
                     left: Double? = nil, right: Double? = nil, planes: Bool = false) -> [(t: Double, alert: WallAlert)] {
        var out: [(Double, WallAlert)] = []
        for (i, d) in distances.enumerated() {
            let t = t0 + 0.1 * Double(i)
            if let a = monitor.update(WallReading(forward: d, left: left, right: right, planesTracked: planes), now: t) { out.append((t, a)) }
        }
        return out
    }
    /// Walks from `from` to `to` metres at `speed` m/s, sampled every 0.1 s.
    private func walk(from: Double, to: Double, speed: Double = 1.0) -> [Double?] {
        var out: [Double?] = [], d = from
        while d > to { out.append(d); d -= speed * 0.1 }
        return out
    }

    func testNothingWithoutAForwardMeasurement() {
        var m = WallProximityMonitor()
        XCTAssertTrue(run(&m, Array(repeating: nil, count: 80), left: 0.5, right: 0.5, planes: true).isEmpty)
    }

    func testFarWallIsSilent() {
        var m = WallProximityMonitor()
        XCTAssertTrue(run(&m, walk(from: 5, to: 1.6)).isEmpty)
    }

    func testAlertsWhenClosingInsideOneAndAHalfMetres() {
        var m = WallProximityMonitor()
        let alerts = run(&m, walk(from: 3, to: 1.05))
        XCTAssertEqual(alerts.count, 1)
        guard alerts.count == 1 else { return }
        XCTAssertLessThanOrEqual(alerts[0].alert.meters, 1.5)
        XCTAssertGreaterThan(alerts[0].alert.meters, 1.2)
        XCTAssertFalse(alerts[0].alert.stop)
    }

    func testStandingBetweenOneAndOneAndAHalfMetresIsSilent() {
        var m = WallProximityMonitor()
        XCTAssertTrue(run(&m, Array(repeating: 1.3, count: 100)).isEmpty)
    }

    func testAlertsWithinOneMetreEvenWhenNotClosing() {
        var m = WallProximityMonitor()
        let alerts = run(&m, Array(repeating: 0.9, count: 30))
        XCTAssertEqual(alerts.count, 1)
        guard alerts.count == 1 else { return }
        XCTAssertEqual(alerts[0].t, 0.1, accuracy: 1e-9)      // second consecutive measurement, not the first
        XCTAssertFalse(alerts[0].alert.stop)
    }

    func testSingleIsolatedHitIsIgnored() {
        var m = WallProximityMonitor()
        XCTAssertTrue(run(&m, [nil, 0.8, nil, nil, 0.8, nil]).isEmpty)
    }

    func testRepeatsNoSoonerThanFourSecondsWhileClosing() {
        var config = WallProximityConfig()
        config.stopDistance = 0.2            // keep the immediate "Stop" out of this test
        var m = WallProximityMonitor(config: config)
        // A slow, steady approach (0.25 m/s) from 1.45 m to 0.25 m: closing for almost five seconds.
        let alerts = run(&m, walk(from: 1.45, to: 0.25, speed: 0.25))
        XCTAssertEqual(alerts.count, 2)
        guard alerts.count == 2 else { return }
        for (a, b) in zip(alerts, alerts.dropFirst()) { XCTAssertGreaterThanOrEqual(b.t - a.t, 4.0 - 1e-9) }
        XCTAssertLessThan(alerts[1].t - alerts[0].t, 5.0)
    }

    func testStandingAtAWallRepeatsLessOften() {
        var m = WallProximityMonitor()
        let alerts = run(&m, Array(repeating: 0.9, count: 250))     // 25 s
        XCTAssertEqual(alerts.count, 3)
        for (a, b) in zip(alerts, alerts.dropFirst()) { XCTAssertGreaterThanOrEqual(b.t - a.t, 10.0 - 1e-9) }
    }

    func testCrossingBelowSeventyCentimetresSaysStopAtOnce() {
        var m = WallProximityMonitor()
        let alerts = run(&m, walk(from: 2.5, to: 0.4))
        XCTAssertEqual(alerts.count, 2)
        guard alerts.count == 2 else { return }
        XCTAssertFalse(alerts[0].alert.stop)
        XCTAssertTrue(alerts[1].alert.stop)
        XCTAssertLessThan(alerts[1].alert.meters, 0.7)
        XCTAssertLessThan(alerts[1].t - alerts[0].t, 4.0)           // did not wait for the repeat interval
        // Staying there does not repeat "Stop" immediately.
        XCTAssertTrue(run(&m, Array(repeating: 0.4, count: 30), from: alerts[1].t + 0.1).isEmpty)
    }

    func testRearmsAfterGoingBackAboveTwoMetres() {
        var m = WallProximityMonitor()
        XCTAssertEqual(run(&m, walk(from: 2.5, to: 1.2)).count, 1)
        // Half a second later the user has stepped back beyond two metres and approaches again: alert at once.
        XCTAssertTrue(run(&m, [2.2, 2.2, 2.2], from: 1.5).isEmpty)
        let again = run(&m, walk(from: 2.1, to: 1.2), from: 1.8)
        XCTAssertEqual(again.count, 1)
        guard again.count == 1 else { return }
        XCTAssertLessThan(again[0].t, 4.0)
    }

    func testWithoutRearmTheSecondApproachWaits() {
        var m = WallProximityMonitor()
        XCTAssertEqual(run(&m, walk(from: 2.5, to: 1.2)).count, 1)
        // Back only to 1.9 m (below the re-arm distance) and forward again within four seconds: no second alert.
        XCTAssertTrue(run(&m, [1.9, 1.9] + walk(from: 1.8, to: 1.2), from: 1.5).isEmpty)
    }

    func testResetForgetsEverything() {
        var m = WallProximityMonitor()
        XCTAssertEqual(run(&m, [0.9, 0.9]).count, 1)
        m.reset()
        XCTAssertEqual(run(&m, [0.9, 0.9], from: 0.3).count, 1)
    }

    // MARK: Side hint

    private func side(left: Double?, right: Double?, planes: Bool) -> Sector? {
        var m = WallProximityMonitor()
        return run(&m, [0.9, 0.9], left: left, right: right, planes: planes).first?.alert.roomSide
    }

    func testSideNamedOnlyWhenClearlyMoreRoomWasMeasured() {
        XCTAssertEqual(side(left: 3.0, right: 1.2, planes: true), .left)
        XCTAssertEqual(side(left: 1.0, right: 2.5, planes: false), .right)
        XCTAssertNil(side(left: 2.4, right: 1.8, planes: true))      // less than a metre more
        XCTAssertNil(side(left: 1.9, right: 0.6, planes: true))      // more, but under two metres
    }

    func testSideThatHitNothingCountsOnlyWithTrackedPlanesAndAHitOnTheOtherSide() {
        XCTAssertEqual(side(left: nil, right: 1.0, planes: true), .left)
        XCTAssertEqual(side(left: 1.4, right: nil, planes: true), .right)
        XCTAssertNil(side(left: nil, right: 1.0, planes: false))     // nothing tracked: a miss means nothing
        XCTAssertNil(side(left: nil, right: 5.0, planes: true))      // the other side is itself far away
    }

    func testNoSideNamedWhenUnmeasured() {
        XCTAssertNil(side(left: nil, right: nil, planes: true))
        XCTAssertNil(side(left: nil, right: nil, planes: false))
        XCTAssertNil(side(left: 4.0, right: nil, planes: false))
    }

    // MARK: Wording

    private func phrase(_ language: SpeechLanguage, meters: Double, stop: Bool = false, side: Sector? = nil) -> String {
        let intent = AlertIntent(kind: .wallAhead(stop: stop, roomSide: side), sector: .ahead,
                                 distance: DistanceMeasurement(meters: meters, sigma: 0.2, method: .surfaceRaycast),
                                 source: .localCamera, priority: 95, interrupts: true, evidenceTimestamp: 0)
        return AlertPhraseBuilder(language: language).phrase(for: intent)
    }

    func testWording() {
        XCTAssertEqual(phrase(.english, meters: 1.1), "Wall ahead, about 1 meter.")
        XCTAssertEqual(phrase(.italian, meters: 1.1), "Parete davanti, a circa 1 metro.")
        XCTAssertEqual(phrase(.english, meters: 0.6, stop: true), "Stop. Wall ahead, about 0.5 meters.")
        XCTAssertEqual(phrase(.italian, meters: 0.6, stop: true), "Fermati. Parete davanti, a circa 0,5 metri.")
        XCTAssertEqual(phrase(.english, meters: 1.4, side: .left), "Wall ahead, about 1.5 meters. More room measured on the left.")
        XCTAssertEqual(phrase(.italian, meters: 1.4, side: .right), "Parete davanti, a circa 1,5 metri. Più spazio misurato a destra.")
    }

    func testWordingNeverClaimsClearFreeOrSafeNorGivesAnOrder() {
        for language in SpeechLanguage.allCases {
            for side in [Sector.left, .right, nil] {
                let text = phrase(language, meters: 0.9, stop: true, side: side).lowercased()
                for banned in ["clear", "free", "safe", "go ", "libero", "libera", "sicur", "vai "] {
                    XCTAssertFalse(text.contains(banned), "\(text) contains \(banned)")
                }
                if side == nil { XCTAssertFalse(text.contains("room") || text.contains("spazio")) }
            }
        }
    }

    // MARK: Alert path

    func testWallAlertIsStagedUrgentAndInterrupting() {
        let engine = ObstacleAlertDecisionEngine()
        let intents = engine.decide(local: [], reliability: healthyReport(),
                                    wall: WallAlert(meters: 1.2, stop: false, roomSide: nil), now: 10)
        let wall = intents.first { if case .wallAhead = $0.kind { return true } else { return false } }
        XCTAssertNotNil(wall)
        XCTAssertEqual(wall?.sector, .ahead)
        XCTAssertEqual(wall?.distance?.meters, 1.2)
        XCTAssertTrue(wall?.interrupts ?? false)
        XCTAssertGreaterThanOrEqual(wall?.priority ?? 0, engine.config.urgentPriority)
        XCTAssertNotNil(wall?.stamp)
        XCTAssertTrue(engine.validationSnapshot.permits(wall!, now: 10.1))
        // No wall measurement, no wall intent; and the old one stops being valid.
        let later = engine.decide(local: [], reliability: healthyReport(), now: 12)
        XCTAssertFalse(later.contains { if case .wallAhead = $0.kind { return true } else { return false } })
        XCTAssertFalse(engine.validationSnapshot.permits(wall!, now: 12))
    }

    func testWallAlertPreemptsAnOrdinaryAnnouncementInTheSpeechQueue() {
        let engine = ObstacleAlertDecisionEngine()
        var queue = RevocableSpeechQueue()
        let ordinary = AlertIntent(kind: .obstacle(label: "chair", count: 1, moving: false), sector: .left, distance: nil,
                                   source: .localCamera, priority: 60, interrupts: false, evidenceTimestamp: 10)
        let first = SpeechItem(text: "Chair on your left.", intent: ordinary, now: 10)
        _ = queue.submit(first, now: 10, validation: engine.validationSnapshot)
        _ = queue.didStart(first.id, now: 10, validation: engine.validationSnapshot)
        let wall = engine.decide(local: [], reliability: healthyReport(), wall: WallAlert(meters: 0.6, stop: true, roomSide: nil), now: 10.2)
            .first { if case .wallAhead = $0.kind { return true } else { return false } }!
        let actions = queue.submit(SpeechItem(text: "Stop.", intent: wall, now: 10.2), now: 10.2, validation: engine.validationSnapshot)
        XCTAssertTrue(actions.contains { if case .stop(let id) = $0 { return id == first.id } else { return false } })
    }
}
