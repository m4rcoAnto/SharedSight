import XCTest
@testable import SharedSightCore

final class PredictionConsistencyTests: XCTestCase {
    private let camera = FloorCamera(x: 0, y: 1.4, z: 4, headingX: 0, headingZ: 1)
    private func trained(_ config: GroundMemoryConfig = GroundMemoryConfig(), label: String = "person") -> GroundTrackMemory {
        let m = GroundTrackMemory(config: config)
        for i in 0...25 {
            _ = m.update(observations: [GroundObservation(trackID: 1, label: label, position: Vec3(-2 + Double(i) * 0.1, 0, 0), sigma: 0.2)],
                         observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: Double(i) * 0.1)
        }
        return m
    }
    private func advance(_ m: GroundTrackMemory, _ t: Double, walls: [WallSegment] = []) -> [HiddenEstimate] {
        m.update(observations: [], observedTrackIDs: [], camera: camera, fovDeg: 60, walls: walls, now: t)
    }
    func testSigmaFiveIsRejectedRatherThanArtificiallyImproved() {
        let m = GroundTrackMemory()
        _ = m.update(observations: [GroundObservation(trackID: 1, label: "person", position: Vec3(1, 0, 0), sigma: 5)],
                     observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: 0)
        XCTAssertNil(m.position(of: 1)); XCTAssertEqual(m.invalidations[1], .uncertainty)
    }
    func testOneVersusTwentyStepsConsumeTwoSecondsWithToleranceOneEMinusNine() throws {
        var config = GroundMemoryConfig(); config.hiddenMaxSigma = 100 // inspect covariance beyond report cutoff
        let a = trained(config), b = trained(config)
        let one = try XCTUnwrap(advance(a, 4.5).first)
        var many: [HiddenEstimate] = []
        for i in 1...20 { many = advance(b, 2.5 + Double(i) * 0.1) }
        let twenty = try XCTUnwrap(many.first)
        XCTAssertEqual(one.position.x, twenty.position.x, accuracy: 1e-9)
        XCTAssertEqual(one.sigma, twenty.sigma, accuracy: 1e-9)
        XCTAssertEqual(one.velocity!.x, twenty.velocity!.x, accuracy: 1e-9)
        XCTAssertEqual(one.age, twenty.age, accuracy: 1e-9)
        let c = trained(), d = trained()
        let cReports = advance(c, 4.5)
        var dReports: [HiddenEstimate] = []
        for i in 1...20 { dReports = advance(d, 2.5 + Double(i) * 0.1) }
        XCTAssertEqual(cReports.isEmpty, dReports.isEmpty)
        XCTAssertEqual(c.invalidations[1], d.invalidations[1])
    }
    func testMeasurementAfterReportExpirationDoesNotDependOnIntermediateUpdates() throws {
        let a = trained(), b = trained()
        for i in 1...40 { _ = advance(b, 2.5 + Double(i) * 0.1) }
        let observation = GroundObservation(trackID: 1, label: "person", position: Vec3(4.5, 0, 0), sigma: 0.2)
        for memory in [a, b] {
            _ = memory.update(observations: [observation], observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: 6.5)
        }
        let x = try XCTUnwrap(a.position(of: 1)), y = try XCTUnwrap(b.position(of: 1))
        XCTAssertEqual(x.position.x, y.position.x, accuracy: 1e-9)
        XCTAssertEqual(x.sigma, y.sigma, accuracy: 1e-9)
    }

    func testCarOcclusionKeepsVectorAndGrowingSigmaUntilExpiration() throws {
        let m = trained(label: "car")
        let first = try XCTUnwrap(advance(m, 3).first)
        let next = try XCTUnwrap(advance(m, 3.2).first)
        XCTAssertGreaterThan(first.velocity!.x, 0.5)
        XCTAssertEqual(first.velocity!.x, next.velocity!.x, accuracy: 1e-9)
        XCTAssertEqual(next.position.x, first.position.x + first.velocity!.x * 0.2, accuracy: 1e-9)
        XCTAssertGreaterThan(next.sigma, first.sigma)
        XCTAssertTrue(advance(m, 10).isEmpty)
        XCTAssertEqual(m.invalidations[1], .uncertainty)
    }
    func testBarrierInvalidatesWithoutCrossingAndRetainsReason() {
        var config = GroundMemoryConfig(); config.hiddenMaxSigma = 100
        let m = trained(config)
        let wall = WallSegment(ax: 1, az: -2, bx: 1, bz: 2, y0: 0, y1: 3)
        XCTAssertFalse(advance(m, 3, walls: [wall]).contains { $0.position.x >= 1 })
        XCTAssertTrue(advance(m, 4.5, walls: [wall]).isEmpty)
        XCTAssertNil(m.position(of: 1)); XCTAssertEqual(m.invalidations[1], .barrierConflict)
        _ = advance(m, 5); XCTAssertEqual(m.invalidations[1], .barrierConflict)
    }
    func testResolverExpiresAgeSigmaAndPoseAndPreservesVector() {
        let resolver = HiddenObjectResolver()
        var e = HiddenEstimate(trackID: 1, label: "car", position: Vec3(0, 0, -2), sigma: 0.3, speed: 2, occluder: .wall,
                               age: 1, velocity: Vec3(2, 0, 0))
        func resolve(_ e: HiddenEstimate, pose: Pose? = .identity) -> HiddenResolution {
            resolver.resolveDetailed(advisories: [], advisoryAge: nil, worldFromReference: .identity, estimates: [e],
                                     worldFromCamera: pose, trackingNormal: true)
        }
        XCTAssertEqual(resolve(e).reports.first?.velocity, Vec3(2, 0, 0))
        XCTAssertEqual(resolve(e, pose: nil).invalidations["L:1"], .missingPose)
        e.age = 9; XCTAssertEqual(resolve(e).invalidations["L:1"], .age)
        e.age = 1; e.sigma = 5; XCTAssertEqual(resolve(e).invalidations["L:1"], .uncertainty)
    }
    func testContinuousFilterCovarianceIsPartitionInvariant() {
        var one = ScalarCVFilter(position: 0, positionVariance: 0.04, velocityVariance: 1)
        one.v = 2
        var many = one
        one.predict(dt: 2, density: 0.22)
        for _ in 0..<20 { many.predict(dt: 0.1, density: 0.22) }
        XCTAssertEqual(one.p, many.p, accuracy: 1e-12)
        XCTAssertEqual(one.c11, many.c11, accuracy: 1e-12)
        XCTAssertEqual(one.c12, many.c12, accuracy: 1e-12)
        XCTAssertEqual(one.c22, many.c22, accuracy: 1e-12)
    }
    /// A person standing still, measured with noise, then hidden: stays put; only the uncertainty grows.
    func testStillPersonDoesNotDriftWhileHidden() throws {
        let m = GroundTrackMemory()
        var seed = 7.0
        func noise() -> Double { seed = (seed * 16807).truncatingRemainder(dividingBy: 2147483647); return (seed / 2147483647 - 0.5) * 0.24 }
        for i in 0...20 {
            _ = m.update(observations: [GroundObservation(trackID: 1, label: "person", position: Vec3(0.5 + noise(), 0, noise()), sigma: 0.2)],
                         observedTrackIDs: [1], camera: camera, fovDeg: 60, walls: [], now: Double(i) * 0.1)
        }
        let start = try XCTUnwrap(m.position(of: 1)).position
        let wall = WallSegment(ax: -3, az: 2, bx: 3, bz: 2, y0: 0, y1: 2.5, kind: .wall)   // hides her from the camera
        let later = try XCTUnwrap(advance(m, 3.5, walls: [wall]).first)
        XCTAssertEqual(later.position.x, start.x, accuracy: 1e-9); XCTAssertEqual(later.position.z, start.z, accuracy: 1e-9)
        XCTAssertEqual(later.speed, 0); XCTAssertEqual(later.velocity?.length ?? 0, 0, accuracy: 1e-12)
    }
}
