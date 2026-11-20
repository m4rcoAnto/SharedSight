import XCTest
@testable import FieldVisionDroneKit

// Mission activation, authorization, termination, landing, repeated presses, transition table.
// All input is synthetic and time is a manual clock: these tests check the kit's logic, nothing about
// cameras, detection accuracy or aircraft.

@MainActor
final class MissionLifecycleTests: XCTestCase {

    // 1. Mission activation
    func testActivationAuthorizesPreparesThenSearches() async {
        let h = Harness()
        XCTAssertEqual(h.controller.state, .off)

        let started = await h.controller.startMission(targetID: h.targetID)

        XCTAssertTrue(started)
        XCTAssertEqual(h.authorizer.callCount, 1)
        XCTAssertEqual(h.controller.state, .preparing)
        XCTAssertEqual(h.controller.targetID, h.targetID)
        XCTAssertEqual(h.vehicle.telemetry.phase, .preparing)
        XCTAssertEqual(h.controller.guidance.hold, .preparing)

        h.run(2)
        XCTAssertEqual(h.controller.state, .searchingForTarget)
        XCTAssertEqual(h.vehicle.telemetry.phase, .hovering)
        XCTAssertEqual(h.controller.guidance.hold, .searching)
        XCTAssertEqual(h.events, [.droneModeActivated, .searchingForTarget])
    }

    // 2. Authorization failure
    func testAuthorizationFailureLeavesEverythingOff() async {
        let h = Harness(authorization: .denied(.cancelled))

        let started = await h.controller.startMission(targetID: h.targetID)

        XCTAssertFalse(started)
        XCTAssertEqual(h.controller.state, .off)
        XCTAssertNil(h.controller.targetID)
        XCTAssertEqual(h.vehicle.telemetry.phase, .inactive, "the vehicle is never prepared without authorization")
        XCTAssertEqual(h.events, [.authorizationFailed(.cancelled)])

        // A later success works normally.
        h.authorizer.setResult(.authorized)
        let retried = await h.controller.startMission(targetID: h.targetID)
        XCTAssertTrue(retried)
        XCTAssertEqual(h.controller.state, .preparing)
    }

    func testActivationWithoutRegisteredTargetIsRefused() async {
        let h = Harness()
        let started = await h.controller.startMission(targetID: nil)
        XCTAssertFalse(started)
        XCTAssertEqual(h.controller.state, .off)
        XCTAssertEqual(h.authorizer.callCount, 0, "nobody is asked to authenticate for a mission that cannot run")
        XCTAssertEqual(h.events, [.activationRefused(.noRegisteredTarget)])
    }

    func testAuthorizationFailureMapping() {
        func failure(_ code: LAErrorCodeForTest) -> OwnerAuthorizationFailure {
            LocalDeviceOwnerAuthorizer.failure(for: NSError(domain: "com.apple.LocalAuthentication", code: code.rawValue))
        }
        XCTAssertEqual(failure(.userCancel), .cancelled)
        XCTAssertEqual(failure(.passcodeNotSet), .unavailable)
        XCTAssertEqual(failure(.authenticationFailed), .failed)
        XCTAssertEqual(LocalDeviceOwnerAuthorizer.failure(for: nil), .failed)
        XCTAssertEqual(LocalDeviceOwnerAuthorizer.failure(for: NSError(domain: "other", code: -2)), .failed)
    }

    // 11. Return request
    func testReturnRequestStopsGuidanceImmediately() async {
        let h = Harness()
        await h.launchAndFollow()
        h.feedValid(1, x: 0.15)
        XCTAssertTrue(h.controller.guidance.isActive)

        h.controller.requestTermination()

        XCTAssertEqual(h.controller.state, .returnRequested)
        XCTAssertEqual(h.controller.guidance.hold, .returning, "guidance stops in the same call, not on a later tick")
        XCTAssertEqual(h.vehicle.telemetry.phase, .returning)
        XCTAssertEqual(h.events.last, .returnRequested)

        // Observations are ignored from here on.
        h.feedValid(1, x: 0.15)
        XCTAssertFalse(h.controller.guidance.isActive)
        XCTAssertEqual(h.controller.state, .returnRequested)
    }

    func testCancellingDuringAuthorizationReturnsToOff() async {
        let h = Harness(yields: 20)
        async let started = h.controller.startMission(targetID: h.targetID)
        await Task.yield()
        // Either the prompt is still up (cancel applies) or it already finished (then this ends the mission).
        if h.controller.state == .authorizationRequired {
            h.controller.requestTermination()
            let result = await started
            XCTAssertFalse(result)
            XCTAssertEqual(h.controller.state, .off)
            XCTAssertEqual(h.vehicle.telemetry.phase, .inactive)
            XCTAssertEqual(h.events, [.missionCancelled])
        } else {
            _ = await started
        }
    }

    // 12. Simulated landing completion
    func testCompletionIsReportedOnlyWhenTheSimulatorHasLanded() async {
        let h = Harness()
        await h.launchAndFollow()
        h.controller.requestTermination()

        h.run(1)
        XCTAssertEqual(h.controller.state, .returnRequested)
        XCTAssertFalse(h.events.contains(.missionCompleted))

        h.run(2)
        XCTAssertEqual(h.controller.state, .landing)
        XCTAssertEqual(h.vehicle.telemetry.phase, .landing)
        XCTAssertFalse(h.events.contains(.missionCompleted), "still descending: not complete")

        h.run(3)
        XCTAssertEqual(h.controller.state, .landed)
        XCTAssertEqual(h.vehicle.telemetry.phase, .landed)
        XCTAssertEqual(h.vehicle.telemetry.altitude, 0)
        XCTAssertEqual(Array(h.events.suffix(3)), [.returnRequested, .landingStarted, .missionCompleted])
        XCTAssertEqual(h.count(of: .missionCompleted), 1)
    }

    // 13. Repeated button presses
    func testRepeatedPressesStartAndEndTheMissionOnlyOnce() async {
        let h = Harness(yields: 5)

        async let first = h.controller.startMission(targetID: h.targetID)
        async let second = h.controller.startMission(targetID: h.targetID)
        async let third = h.controller.startMission(targetID: h.targetID)
        let results = await [first, second, third]

        XCTAssertEqual(results.filter { $0 }.count, 1, "exactly one start wins")
        XCTAssertEqual(h.authorizer.callCount, 1, "the owner is asked once")
        XCTAssertEqual(h.count(of: .droneModeActivated), 1)

        h.run(2)
        h.feedValid(1.5)
        XCTAssertEqual(h.controller.state, .following)

        // Second activation, pressed four times.
        for _ in 0..<4 { h.controller.primaryAction(targetID: h.targetID) }
        XCTAssertEqual(h.controller.state, .returnRequested)
        XCTAssertEqual(h.count(of: .returnRequested), 1)

        // Presses while returning and landing change nothing.
        h.run(3)
        h.controller.primaryAction(targetID: h.targetID)
        XCTAssertEqual(h.controller.state, .landing)
        h.run(3)
        XCTAssertEqual(h.controller.state, .landed)

        // After completion the button starts a new mission, with a new authorization.
        await h.controller.performPrimaryAction(targetID: h.targetID)
        XCTAssertEqual(h.controller.state, .preparing)
        XCTAssertEqual(h.authorizer.callCount, 2)
        XCTAssertEqual(h.controller.refusedTransitionCount, 0)
    }

    // 14. Invalid transitions
    func testTransitionTableRejectsUnsafeMoves() {
        let all = DroneMissionState.allCases
        for state in all {
            XCTAssertFalse(state.canTransition(to: state), "\(state) -> itself")
        }
        XCTAssertFalse(DroneMissionState.off.canTransition(to: .following))
        XCTAssertFalse(DroneMissionState.off.canTransition(to: .preparing), "no mission without authorization")
        XCTAssertFalse(DroneMissionState.searchingForTarget.canTransition(to: .following), "no following without a lock")
        XCTAssertFalse(DroneMissionState.targetLost.canTransition(to: .following), "a lost target must be locked again")
        XCTAssertFalse(DroneMissionState.returnRequested.canTransition(to: .following))
        XCTAssertFalse(DroneMissionState.landing.canTransition(to: .following))
        XCTAssertFalse(DroneMissionState.landed.canTransition(to: .following))
        XCTAssertFalse(DroneMissionState.error.canTransition(to: .following))

        XCTAssertEqual(all.filter { $0.canTransition(to: .landed) }, [.landing], "landed only after landing")
        XCTAssertEqual(all.filter { $0.canTransition(to: .landing) }, [.returnRequested])
        XCTAssertEqual(Set(all.filter { $0.canTransition(to: .following) }), [.targetLocked, .paused])
        XCTAssertEqual(Set(all.filter { $0.canTransition(to: .preparing) }), [.authorizationRequired])
        XCTAssertEqual(DroneMissionState.error.allowedNextStates, [.off])
    }

    func testCommandsInTheWrongStateAreIgnored() async {
        let h = Harness()
        h.controller.stopFollowing()
        h.controller.resumeFollowing()
        h.controller.requestTermination()
        h.controller.reset()
        h.controller.submit(h.observation())
        h.controller.advance(to: h.clock.now)
        XCTAssertEqual(h.controller.state, .off)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertNil(h.controller.latestObservation)

        await h.launchAndFollow()
        let secondStart = await h.controller.startMission(targetID: h.targetID)
        XCTAssertFalse(secondStart, "a running mission cannot be started again")
        h.controller.reset()
        XCTAssertEqual(h.controller.state, .following, "reset is not a way to drop a flying mission")

        h.controller.requestTermination()
        h.controller.stopFollowing()
        h.controller.resumeFollowing()
        XCTAssertEqual(h.controller.state, .returnRequested)
        XCTAssertEqual(h.controller.refusedTransitionCount, 0)
    }

    func testVehicleFaultMovesToErrorAndResetReturnsToOff() async {
        let h = Harness()
        await h.launchAndFollow()

        h.vehicle.simulateFault("link lost")
        h.run(0.1)

        XCTAssertEqual(h.controller.state, .error)
        XCTAssertEqual(h.controller.missionError, .vehicleFault("link lost"))
        XCTAssertEqual(h.controller.guidance.hold, .fault)
        XCTAssertEqual(h.events.last, .missionFailed(.vehicleFault("link lost")))

        h.controller.reset()
        XCTAssertEqual(h.controller.state, .off)
        XCTAssertEqual(h.vehicle.telemetry.phase, .inactive)
    }

    func testEventStreamDeliversMissionEvents() async {
        let h = Harness()
        let stream = h.controller.events()
        let collector = Task { () -> [DroneMissionEvent] in
            var received: [DroneMissionEvent] = []
            for await event in stream {
                received.append(event)
                if event == .searchingForTarget { break }
            }
            return received
        }
        await h.launch()
        let received = await collector.value
        XCTAssertEqual(received, [.droneModeActivated, .searchingForTarget])
    }

    func testAnnouncementsNeverClaimARealFlight() {
        let flightEvents: [DroneMissionEvent] = [.droneModeActivated, .followingActive, .returnRequested, .landingStarted, .missionCompleted]
        for event in flightEvents {
            XCTAssertTrue(event.announcement(.english).lowercased().contains("simulat"), event.name)
            XCTAssertTrue(event.announcement(.italian).lowercased().contains("simulaz") || event.announcement(.italian).lowercased().contains("simulat"), event.name)
        }
        XCTAssertTrue(SimulatedDroneAdapter().isSimulation)
        XCTAssertTrue(DroneCompanionController().isSimulation)
    }
}

/// The LocalAuthentication error codes used above, by value, so the test does not need the framework.
enum LAErrorCodeForTest: Int {
    case authenticationFailed = -1
    case userCancel = -2
    case passcodeNotSet = -5
}
