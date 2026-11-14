import XCTest
@testable import SharedSightCore

final class SurroundingsSummaryTests: XCTestCase {
    private let en = AlertPhraseBuilder(language: .english)
    private let it = AlertPhraseBuilder(language: .italian)
    private let twoMeters = DistanceMeasurement(meters: 2.0, sigma: 0.2, method: .groundPlaneRaycast)

    func testUnavailablePerceptionSaysNothingAboutTheScene() {
        let text = en.surroundings(perception: .unavailable,
                                   local: [SurroundingsItem(label: "chair", state: .observed, sector: .ahead, distance: twoMeters)],
                                   peers: [])
        XCTAssertTrue(text.contains("unavailable"))
        XCTAssertFalse(text.contains("chair"))
    }

    func testEmptySceneNeverClaimsAClearPath() {
        let text = en.surroundings(perception: .reliable, local: [], peers: [])
        XCTAssertTrue(text.contains("does not mean the way is clear"))
        let italian = it.surroundings(perception: .reliable, local: [], peers: [])
        XCTAssertTrue(italian.contains("non significa che la via sia libera"))
    }

    func testSeenItemCarriesDirectionAndMeasuredDistance() {
        let text = en.surroundings(perception: .reliable,
                                   local: [SurroundingsItem(label: "chair", state: .observed, sector: .ahead, distance: twoMeters)],
                                   peers: [])
        XCTAssertEqual(text, "In view now: chair ahead, about 2 meters.")
    }

    func testNoDirectionOrDistanceIsInventedWhenMissing() {
        let text = en.surroundings(perception: .reliable,
                                   local: [SurroundingsItem(label: "chair", state: .observed, sector: nil, distance: nil)],
                                   peers: [])
        XCTAssertEqual(text, "In view now: chair.")
    }

    func testRememberedItemsAreSeparateAndCarryNoDistance() {
        let text = en.surroundings(perception: .reliable,
                                   local: [SurroundingsItem(label: "person", state: .temporarilyHidden, sector: .left, distance: twoMeters)],
                                   peers: [])
        XCTAssertEqual(text, "Seen a moment ago, not confirmed now: person on your left.")
    }

    func testLostAndUnknownItemsAreNotSpoken() {
        let text = en.surroundings(perception: .reliable,
                                   local: [SurroundingsItem(label: "person", state: .lost, sector: .left, distance: nil),
                                           SurroundingsItem(label: "chair", state: .unknown, sector: .ahead, distance: nil)],
                                   peers: [])
        XCTAssertFalse(text.contains("person"))
        XCTAssertFalse(text.contains("chair"))
        XCTAssertTrue(text.contains("does not mean the way is clear"))
    }

    func testPeerItemsKeepTheirSourceAndVerificationState() {
        let text = en.surroundings(perception: .reliable, local: [], peers: [
            PeerSurroundingsItem(label: "chair", status: .spatiallyRelevant, sector: .right, distance: twoMeters),
            PeerSurroundingsItem(label: "person", status: .locationUnverified, sector: .ahead, distance: twoMeters),
        ])
        XCTAssertTrue(text.contains("Reported by another device: chair on your right, about 2 meters."))
        XCTAssertTrue(text.contains("Reported by another device, position not verified: person."))
        XCTAssertFalse(text.contains("person ahead"))
    }

    func testExpiredPeerObservationsAreNeverSpoken() {
        let text = en.surroundings(perception: .reliable, local: [], peers: [
            PeerSurroundingsItem(label: "chair", status: .expired, sector: .ahead, distance: twoMeters),
        ])
        XCTAssertFalse(text.contains("chair"))
    }

    func testDegradedPerceptionIsStatedFirst() {
        let text = en.surroundings(perception: .degraded,
                                   local: [SurroundingsItem(label: "chair", state: .observed, sector: .ahead, distance: nil)],
                                   peers: [])
        XCTAssertTrue(text.hasPrefix("Perception is degraded"))
        XCTAssertTrue(text.contains("chair ahead"))
    }

    func testLongListsAreCapped() {
        let many = (0..<6).map { _ in SurroundingsItem(label: "chair", state: .observed, sector: nil, distance: nil) }
        let text = en.surroundings(perception: .reliable, local: many, peers: [], maxItems: 4)
        XCTAssertTrue(text.contains("and 2 more"))
    }
}
