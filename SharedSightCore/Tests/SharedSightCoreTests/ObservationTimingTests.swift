import XCTest
@testable import SharedSightCore

final class ObservationTimingTests: XCTestCase {
    func testBearingOnlyEvidenceDoesNotRenewLocalMetricAge() {
        let memory = GroundTrackMemory()
        let camera = FloorCamera(x: 0, y: 1.4, z: 0, headingX: 0, headingZ: -1)
        _ = memory.update(observations: [GroundObservation(trackID: 1, label: "person", position: Vec3(2, 0, 0), sigma: 0.2)],
                          observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: 100)
        XCTAssertTrue(memory.update(observations: [], observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: 101).isEmpty)
        let hidden = memory.update(observations: [], observedTrackIDs: [], camera: camera, fovDeg: 60, walls: [], now: 101.1)
        XCTAssertEqual(hidden.first!.age, 1.1, accuracy: 1e-9)
    }

    func testReturnTripAndLocalResidenceAreCountedOnceAndExpireReport() {
        let a = ServerAdvisory(id: "W1", kind: "seen", label: "person", position: Vec3(0, 0, -2), sigma: 0.2,
                               relation: "outOfView", seenBy: 1, ageMs: 100, ageUncertaintyMs: 50)
        let reply = ServerReply(advisories: [a], epoch: "new", sequence: 4, receiptToken: "token")
        func resolve(_ advisories: [ServerAdvisory], _ residence: Double) -> [HiddenReport] {
            HiddenObjectResolver().resolve(advisories: advisories, advisoryAge: residence, worldFromReference: .identity,
                estimates: [], worldFromCamera: .identity, trackingNormal: true)
        }
        let received = reply.atReceipt(roundTrip: 0.2)
        XCTAssertEqual(received[0].ageMs, 100)
        XCTAssertEqual(received[0].ageUncertaintyMs, 250)
        XCTAssertEqual(resolve(received, 0.1).first!.age, 0.45, accuracy: 1e-9)
        XCTAssertTrue(resolve(reply.atReceipt(roundTrip: 0.9), 0).isEmpty)
        XCTAssertTrue(resolve(received, 0.7).isEmpty)
        XCTAssertTrue(resolve(received, -0.1).isEmpty)
        var unknown = a; unknown.ageUncertaintyMs = nil
        XCTAssertTrue(resolve([unknown], 0).isEmpty)
        unknown = a; unknown.ageMs = nil
        XCTAssertTrue(resolve([unknown], 0).isEmpty)
        XCTAssertFalse(reply.matches(epoch: "old", sequence: 4))
        XCTAssertFalse(reply.matches(epoch: "new", sequence: 3))
        XCTAssertTrue(reply.matches(epoch: "new", sequence: 4))
        XCTAssertNil(ServerReply.decode(Data(#"{"v":2,"advisories":[]}"#.utf8)))
    }
}
