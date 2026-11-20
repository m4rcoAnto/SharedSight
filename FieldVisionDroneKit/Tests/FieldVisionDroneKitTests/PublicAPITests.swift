import XCTest
import SwiftUI
import FieldVisionDroneKit   // deliberately not @testable: this file may use the public API only

// 16. Independent compilation: everything a host needs is reachable through the public interface,
// with no access to SharedSight or to the kit's internals. If this file builds, the facade is complete.

@MainActor
final class PublicAPITests: XCTestCase {

    func testAHostCanDriveAMissionThroughThePublicFacadeOnly() async {
        var configuration = DroneCompanionConfiguration()
        configuration.runsInternalTicker = false
        let vehicle = SimulatedDroneAdapter()
        let controller = DroneCompanionController(configuration: configuration,
                                                  authorizer: PreapprovedOwnerAuthorizer(),
                                                  vehicle: vehicle)
        var events: [DroneMissionEvent] = []
        controller.onEvent = { events.append($0) }
        let person = UUID()

        let started = await controller.startMission(targetID: person)
        XCTAssertTrue(started)

        // Real time here: wait for the simulated preflight, feeding nothing.
        let deadline = controller.currentTime + 5
        while controller.state == .preparing, controller.currentTime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            controller.advance()
        }
        XCTAssertEqual(controller.state, .searchingForTarget)

        let observation = DroneTargetObservation(targetID: person, normalizedCenterX: 0.5, normalizedCenterY: 0.5,
                                                 boundingBoxArea: 0.1, confidence: 0.9, isDirectlyObserved: true,
                                                 isIdentityVerified: true, timestamp: controller.currentTime)
        controller.submit(observation)
        XCTAssertEqual(controller.latestObservation, observation)
        XCTAssertEqual(controller.observationQuality, .valid)

        controller.stopFollowing()
        XCTAssertTrue(controller.canResumeFollowing)
        controller.requestTermination()
        XCTAssertEqual(controller.state, .returnRequested)
        XCTAssertFalse(controller.guidance.isActive)
        XCTAssertTrue(controller.isSimulation)
        XCTAssertEqual(events.first, .droneModeActivated)
        XCTAssertFalse(events.last?.announcement(.italian).isEmpty ?? true)
        XCTAssertFalse(DroneKitInfo.version.isEmpty)
    }

    func testPublicViewsCanBeConstructedByAHost() {
        let controller = DroneCompanionController(authorizer: PreapprovedOwnerAuthorizer())
        let person: UUID? = UUID()
        _ = DroneControlButton(controller: controller, targetID: person)
        _ = DroneControlButton(controller: controller, targetID: nil, language: .italian)
        _ = DroneStopFollowingButton(controller: controller)
        _ = DroneSimulationView(controller: controller)
        _ = DroneCompanionPanel(controller: controller, targetID: person)
        _ = DroneCompanionDemoView(requiresOwnerAuthentication: false)
        _ = SyntheticTargetFeed()
        XCTAssertEqual(controller.state, .off)
    }

    func testACustomVehicleAdapterCanBeInjected() async {
        @MainActor final class RecordingVehicle: DroneVehicleAdapter {
            let isSimulation = true
            var telemetry = DroneVehicleTelemetry()
            var commands: [DroneVehicleCommand] = []
            func handle(_ command: DroneVehicleCommand, at time: TimeInterval) {
                commands.append(command)
                if command == .prepare { telemetry.phase = .hovering }
            }
            func advance(to time: TimeInterval) {}
        }
        var configuration = DroneCompanionConfiguration()
        configuration.runsInternalTicker = false
        let vehicle = RecordingVehicle()
        let controller = DroneCompanionController(configuration: configuration, authorizer: PreapprovedOwnerAuthorizer(), vehicle: vehicle)
        await controller.startMission(targetID: UUID())
        XCTAssertEqual(vehicle.commands.first, .prepare)
        XCTAssertEqual(controller.state, .searchingForTarget)
    }
}
