import XCTest
@testable import FieldVisionDroneKit

// Target acquisition, following, confidence, occlusion, loss, stale data, wrong / unverified target, stop.

@MainActor
final class TargetFollowingTests: XCTestCase {

    // 3. Target acquisition
    func testAcquisitionNeedsAVerifiedTargetHeldForAMoment() async {
        let h = Harness()
        await h.launch()

        h.feedValid(0.2)
        XCTAssertEqual(h.controller.state, .searchingForTarget, "one glimpse is not a lock")

        h.feedValid(0.3)
        XCTAssertEqual(h.controller.state, .targetLocked)
        XCTAssertEqual(h.events.last, .targetAcquired)
        XCTAssertEqual(h.controller.guidance.hold, .settling, "locked, but guidance has not started yet")

        h.feedValid(1)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertEqual(h.events.last, .followingActive)
    }

    func testAnInterruptedGlimpseRestartsTheLockTimer() async {
        let h = Harness()
        await h.launch()
        h.feedValid(0.2)
        h.run(0.1) { time in h.observation(observed: false, at: time) }
        h.feedValid(0.2)
        XCTAssertEqual(h.controller.state, .searchingForTarget)
    }

    // 4. Target following
    func testFollowingProducesLeftRightAndCentredGuidance() async {
        let h = Harness()
        await h.launchAndFollow()

        XCTAssertTrue(h.controller.guidance.isActive)
        XCTAssertEqual(h.controller.guidance.horizontal, .centered)
        XCTAssertEqual(h.controller.guidance.source, .kit)
        XCTAssertEqual(h.vehicle.telemetry.phase, .following)

        h.feedValid(2, x: 0.15)
        XCTAssertEqual(h.controller.guidance.horizontal, .left)
        XCTAssertEqual(h.controller.guidance.horizontalOffset, -0.7, accuracy: 0.02)
        XCTAssertLessThan(h.vehicle.telemetry.correction, -0.3, "the simulated drone leans into the correction")

        h.feedValid(2, x: 0.85)
        XCTAssertEqual(h.controller.guidance.horizontal, .right)
        XCTAssertGreaterThan(h.vehicle.telemetry.correction, 0.3)

        h.feedValid(2, x: 0.5)
        XCTAssertEqual(h.controller.guidance.horizontal, .centered)
    }

    func testASingleJumpIsSmoothedAway() async {
        let h = Harness()
        await h.launchAndFollow()
        h.feedValid(0.05, x: 0.85)      // raw offset 0.7 for one frame
        XCTAssertEqual(h.controller.guidance.horizontal, .centered)
        XCTAssertLessThan(h.controller.guidance.horizontalOffset, 0.16)
        XCTAssertGreaterThan(h.controller.guidance.horizontalOffset, 0)
    }

    func testHostGuidanceIsReusedWhenProvided() async {
        let h = Harness()
        await h.launchAndFollow()

        // The host says "right" although the raw position is on the left: the host's guidance wins.
        let hostRight = HostFollowGuidance(isActive: true, horizontal: .right, horizontalOffset: 0.4)
        h.run(0.5) { time in h.observation(x: 0.2, host: hostRight, at: time) }
        XCTAssertEqual(h.controller.guidance.source, .host)
        XCTAssertEqual(h.controller.guidance.horizontal, .right)
        XCTAssertEqual(h.controller.guidance.horizontalOffset, 0.4, accuracy: 1e-9)

        // The host holds its guidance: the kit holds too and does not substitute its own.
        let hostHold = HostFollowGuidance(isActive: false)
        h.run(0.5) { time in h.observation(x: 0.2, host: hostHold, at: time) }
        XCTAssertEqual(h.controller.guidance.hold, .heldByHost)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertEqual(h.vehicle.lastCommand, .hold)
    }

    // 5. Low-confidence observations
    func testLowConfidenceHoldsGuidanceThenPauses() async {
        let h = Harness()
        await h.launchAndFollow()

        h.run(0.2) { time in h.observation(x: 0.1, confidence: 0.1, at: time) }
        XCTAssertEqual(h.controller.guidance.hold, .lowConfidence, "held from the first weak observation")
        XCTAssertEqual(h.controller.state, .following)

        h.run(0.5) { time in h.observation(x: 0.1, confidence: 0.1, at: time) }
        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertEqual(h.controller.pauseReason, .lowConfidence)
        XCTAssertTrue(h.events.contains(.followingPaused(.lowConfidence)))

        h.feedValid(0.5)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertTrue(h.events.contains(.followingResumed))
    }

    func testLowConfidenceNeverStartsALock() async {
        let h = Harness()
        await h.launch()
        h.run(2) { time in h.observation(confidence: 0.2, at: time) }
        XCTAssertEqual(h.controller.state, .searchingForTarget)
    }

    // 6. Temporary occlusion
    func testTemporaryOcclusionPausesAndThenResumes() async {
        let h = Harness()
        await h.launchAndFollow()

        h.run(1) { time in h.observation(observed: false, at: time) }
        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertEqual(h.controller.pauseReason, .targetOccluded)
        XCTAssertFalse(h.controller.guidance.isActive, "a predicted position never drives guidance")
        XCTAssertEqual(h.vehicle.lastCommand, .hold)
        XCTAssertEqual(h.vehicle.telemetry.phase, .hovering)

        h.feedValid(0.3)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertTrue(h.controller.guidance.isActive)
        XCTAssertFalse(h.events.contains(.targetLost))
    }

    // 7. Target loss
    func testTargetLossStopsGuidanceAndOnlyAVerifiedTargetIsReacquired() async {
        let h = Harness()
        await h.launchAndFollow()

        h.run(2) { time in h.observation(observed: false, at: time) }
        XCTAssertEqual(h.controller.state, .targetLost)
        XCTAssertEqual(h.controller.guidance.hold, .targetLost)
        XCTAssertEqual(h.count(of: .targetLost), 1)

        // Someone is in the middle of the image, but the host does not verify the identity.
        h.run(2) { time in h.observation(x: 0.5, verified: false, at: time) }
        XCTAssertEqual(h.controller.state, .targetLost)
        XCTAssertFalse(h.controller.guidance.isActive)

        h.feedValid(1.5)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertEqual(h.count(of: .targetAcquired), 2)
    }

    func testHostReportingTheIdentityGoneLosesTheTargetAtOnce() async {
        let h = Harness()
        await h.launchAndFollow()
        h.run(0.05) { time in h.observation(x: nil, y: nil, confidence: 0, observed: false, verified: false, at: time) }
        XCTAssertEqual(h.controller.state, .targetLost)
    }

    // 8. Stale observations
    func testStaleObservationsAreRejected() async {
        let h = Harness()
        await h.launch()

        h.controller.submit(h.observation(at: h.clock.now - 2))
        XCTAssertNil(h.controller.latestObservation)
        XCTAssertEqual(h.controller.rejectedObservationCount, 1)
        XCTAssertEqual(h.controller.lastRejection, .stale)

        // A timestamp far in the future means a different clock: also rejected.
        h.controller.submit(h.observation(at: h.clock.now + 30))
        XCTAssertEqual(h.controller.rejectedObservationCount, 2)

        // Older than the one already accepted.
        h.controller.submit(h.observation(at: h.clock.now))
        h.controller.submit(h.observation(at: h.clock.now - 0.1))
        XCTAssertEqual(h.controller.lastRejection, .outOfOrder)
        XCTAssertEqual(h.controller.state, .searchingForTarget)
    }

    func testFollowingPausesAndIsLostWhenDataStopsArriving() async {
        let h = Harness()
        await h.launchAndFollow()
        h.feedValid(1, x: 0.15)
        XCTAssertTrue(h.controller.guidance.isActive)

        h.run(1)        // the host goes silent
        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertEqual(h.controller.pauseReason, .staleData)
        XCTAssertEqual(h.controller.guidance.hold, .staleData)

        h.run(1.5)
        XCTAssertEqual(h.controller.state, .targetLost)
    }

    // 9. Wrong or unverified target
    func testWrongOrUnverifiedTargetNeverLocks() async {
        let h = Harness()
        await h.launch()
        let stranger = UUID()

        h.run(2) { time in h.observation(target: stranger, at: time) }
        XCTAssertEqual(h.controller.state, .searchingForTarget, "another registered person is not this mission's target")
        XCTAssertGreaterThan(h.controller.rejectedObservationCount, 0)
        XCTAssertEqual(h.controller.lastRejection, .wrongTarget)
        XCTAssertNil(h.controller.latestObservation)

        h.run(2) { time in h.observation(verified: false, at: time) }
        XCTAssertEqual(h.controller.state, .searchingForTarget, "a visible, central, unverified person is never chosen")

        h.run(2) { time in h.observation(verified: false, ambiguous: true, at: time) }
        XCTAssertEqual(h.controller.state, .searchingForTarget)
        XCTAssertFalse(h.events.contains(.targetAcquired))
    }

    func testWrongTargetObservationsDoNotKeepAMissionAlive() async {
        let h = Harness()
        await h.launchAndFollow()
        let stranger = UUID()
        h.run(2.5) { time in h.observation(target: stranger, at: time) }
        XCTAssertEqual(h.controller.state, .targetLost)
    }

    func testAmbiguousIdentityPausesUntilVerifiedAgain() async {
        let h = Harness()
        await h.launchAndFollow()

        h.run(0.05) { time in h.observation(verified: false, ambiguous: true, at: time) }
        XCTAssertEqual(h.controller.state, .paused, "ambiguity pauses at once")
        XCTAssertEqual(h.controller.pauseReason, .identityAmbiguous)
        XCTAssertEqual(h.controller.guidance.hold, .identityAmbiguous)

        h.feedValid(0.2)
        XCTAssertEqual(h.controller.state, .following)

        h.run(7) { time in h.observation(verified: false, ambiguous: true, at: time) }
        XCTAssertEqual(h.controller.state, .targetLost, "ambiguity that never clears ends in target lost")
    }

    // 10. Stop-follow behaviour
    func testStopFollowingIsImmediateAndNeedsAnExplicitResume() async {
        let h = Harness()
        await h.launchAndFollow()
        h.feedValid(1, x: 0.15)
        XCTAssertTrue(h.controller.guidance.isActive)

        h.controller.stopFollowing()

        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertEqual(h.controller.pauseReason, .stoppedByUser)
        XCTAssertEqual(h.controller.guidance.hold, .stoppedByUser, "stopped in the same call")
        XCTAssertEqual(h.vehicle.lastCommand, .hold)
        XCTAssertEqual(h.events.last, .followingPaused(.stoppedByUser))

        // A perfectly valid target does not restart following by itself.
        h.feedValid(2, x: 0.15)
        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertFalse(h.controller.guidance.isActive)

        h.controller.resumeFollowing()
        XCTAssertEqual(h.controller.state, .searchingForTarget)
        h.feedValid(1.5)
        XCTAssertEqual(h.controller.state, .following)

        // The mission can still be ended from a user stop.
        h.controller.stopFollowing()
        h.controller.requestTermination()
        XCTAssertEqual(h.controller.state, .returnRequested)
    }

    func testSyntheticFeedLabelsItsData() async {
        let feed = SyntheticTargetFeed()
        let observation = feed.makeObservation(at: 10)
        XCTAssertEqual(observation.origin, .syntheticTestData)
        XCTAssertEqual(observation.targetID, feed.targetID)

        feed.script = .leaves
        feed.step(by: 8)        // inside the "gone" part of the script
        let gone = feed.makeObservation(at: 18)
        XCTAssertFalse(gone.isIdentityVerified)
        XCTAssertNil(gone.normalizedCenterX)

        let h = Harness()
        await h.controller.startMission(targetID: feed.targetID)
        h.run(2)
        feed.script = .walking
        h.run(1.5) { time in feed.step(by: 0.05); return feed.makeObservation(at: time) }
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertTrue(h.controller.isUsingSyntheticData)
    }
}
