import XCTest
@testable import FieldVisionDroneKit

// 15. Integration adapter mapping: host tracking state -> DroneTargetObservation.
// The SharedSight-side adapter only copies fields into HostTargetSnapshot; the decisions are tested here.

final class IntegrationMappingTests: XCTestCase {
    private let person = UUID()
    private let activeGuidance = HostFollowGuidance(isActive: true, horizontal: .left, horizontalOffset: -0.4)

    private func snapshot(_ phase: HostTargetPhase, predicted: Bool = false) -> HostTargetSnapshot {
        HostTargetSnapshot(targetID: person, phase: phase, centerX: 0.3, centerY: 0.6, boundingBoxArea: 0.07,
                           confidence: 0.8, positionIsPredicted: predicted, guidance: activeGuidance)
    }

    func testNoRegisteredTargetProducesNoObservation() {
        let nobody = HostTargetSnapshot(targetID: nil, phase: .following, centerX: 0.5, centerY: 0.5, confidence: 0.9)
        XCTAssertNil(DroneTargetObservation(host: nobody, timestamp: 1))
    }

    func testLockedAndFollowingAreVerifiedAndObserved() throws {
        for phase in [HostTargetPhase.locked, .following] {
            let o = try XCTUnwrap(DroneTargetObservation(host: snapshot(phase), timestamp: 5))
            XCTAssertEqual(o.targetID, person)
            XCTAssertTrue(o.isIdentityVerified, phase.rawValue)
            XCTAssertTrue(o.isDirectlyObserved, phase.rawValue)
            XCTAssertFalse(o.isIdentityAmbiguous)
            XCTAssertEqual(o.normalizedCenterX, 0.3)
            XCTAssertEqual(o.normalizedCenterY, 0.6)
            XCTAssertEqual(o.boundingBoxArea, 0.07)
            XCTAssertEqual(o.confidence, 0.8)
            XCTAssertEqual(o.timestamp, 5)
            XCTAssertEqual(o.hostGuidance, activeGuidance)
            XCTAssertEqual(o.origin, .liveHost)
        }
    }

    func testPredictedPositionIsNeverReportedAsObserved() throws {
        let predicted = try XCTUnwrap(DroneTargetObservation(host: snapshot(.following, predicted: true), timestamp: 1))
        XCTAssertFalse(predicted.isDirectlyObserved)
        XCTAssertNil(predicted.hostGuidance)

        let occluded = try XCTUnwrap(DroneTargetObservation(host: snapshot(.occluded), timestamp: 1))
        XCTAssertTrue(occluded.isIdentityVerified, "the association is still held")
        XCTAssertFalse(occluded.isDirectlyObserved)
        XCTAssertNil(occluded.hostGuidance)
    }

    func testAmbiguousIsFlaggedAndUnverified() throws {
        let o = try XCTUnwrap(DroneTargetObservation(host: snapshot(.ambiguous), timestamp: 1))
        XCTAssertTrue(o.isIdentityAmbiguous)
        XCTAssertFalse(o.isIdentityVerified)
        XCTAssertFalse(o.isDirectlyObserved)
        XCTAssertEqual(o.confidence, 0)
        XCTAssertNil(o.hostGuidance)
    }

    func testSearchingLostAndNotTrackingCarryNoPosition() throws {
        for phase in [HostTargetPhase.notTracking, .searching, .lost] {
            let o = try XCTUnwrap(DroneTargetObservation(host: snapshot(phase), timestamp: 1))
            XCTAssertFalse(o.isIdentityVerified, phase.rawValue)
            XCTAssertFalse(o.isIdentityAmbiguous, phase.rawValue)
            XCTAssertFalse(o.isDirectlyObserved, phase.rawValue)
            XCTAssertNil(o.normalizedCenterX, phase.rawValue)
            XCTAssertNil(o.normalizedCenterY, phase.rawValue)
            XCTAssertEqual(o.confidence, 0)
        }
    }

    func testEveryHostPhaseMapsToTheExpectedQuality() throws {
        let configuration = DroneCompanionConfiguration()
        let expected: [HostTargetPhase: DroneObservationQuality] = [
            .notTracking: .identityUnverified, .searching: .identityUnverified, .lost: .identityUnverified,
            .locked: .valid, .following: .valid, .occluded: .notDirectlyObserved, .ambiguous: .identityAmbiguous,
        ]
        XCTAssertEqual(Set(expected.keys), Set(HostTargetPhase.allCases))
        for (phase, quality) in expected {
            let o = try XCTUnwrap(DroneTargetObservation(host: snapshot(phase), timestamp: 10))
            XCTAssertEqual(ObservationAssessor.assess(o, expectedTarget: person, now: 10.05, configuration: configuration),
                           quality, phase.rawValue)
        }
    }

    @MainActor
    func testAHostSnapshotStreamDrivesAMission() async {
        let h = Harness()
        await h.launch()
        func feed(_ phase: HostTargetPhase, _ seconds: TimeInterval) {
            h.run(seconds) { time in
                DroneTargetObservation(host: HostTargetSnapshot(targetID: h.targetID, phase: phase, centerX: 0.2, centerY: 0.5,
                                                                boundingBoxArea: 0.06, confidence: 0.85),
                                       timestamp: time)
            }
        }
        feed(.searching, 1)
        XCTAssertEqual(h.controller.state, .searchingForTarget)
        feed(.locked, 0.4)
        XCTAssertEqual(h.controller.state, .targetLocked)
        feed(.following, 2)
        XCTAssertEqual(h.controller.state, .following)
        XCTAssertEqual(h.controller.guidance.horizontal, .left)
        feed(.ambiguous, 0.5)
        XCTAssertEqual(h.controller.state, .paused)
        feed(.following, 0.5)
        XCTAssertEqual(h.controller.state, .following)
        feed(.lost, 0.1)
        XCTAssertEqual(h.controller.state, .targetLost)
    }
}
