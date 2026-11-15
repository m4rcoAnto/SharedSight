import XCTest
@testable import SharedSightCore

/// SYNTHETIC fixtures: mathematical contract, not camera range/road-safety validation.
final class EncounterRiskTests: XCTestCase {
    func motion(_ x: Double, _ z: Double, _ vx: Double?, _ vz: Double?, sigma: Double = 0.05) -> EncounterMotion {
        EncounterMotion(position: Vec3(x, 0, z), velocity: vx.flatMap { x in vz.map { Vec3(x, 0, $0) } },
                        positionSigma: sigma, velocitySigma: 0.02, stateAt: 10, measurementAge: 0.1)
    }
    func candidate(_ motion: EncounterMotion, source: EncounterSource = .prediction) -> EncounterCandidate {
        EncounterCandidate(id: "car-1", label: "car", source: source, motion: motion, footprint: .assumed(for: "car"), occluder: .object)
    }
    func evaluate(_ c: EncounterCandidate, _ u: EncounterMotion?, pose: Pose = .identity) -> EncounterResult {
        EncounterRiskEvaluator().evaluate(c, user: u, worldFromCamera: pose, epoch: "test", now: 10, sampleInterval: 0.1)
    }
    func testSyntheticCrossingAtTwentyMetersHasCPAAtTwoSeconds() {
        let r = evaluate(candidate(motion(-20, 0, 10, 0)), motion(0, -2, 0, 1))
        XCTAssertEqual(r.tCPA!, 2, accuracy: 1e-9); XCTAssertEqual(r.dCPA!, 0, accuracy: 1e-9)
        XCTAssertNotEqual(r.state, .noConflictInHorizon); XCTAssertNotEqual(r.state, .notAssessable)
        XCTAssertNotNil(r.firstConflict); XCTAssertEqual(r.source, .prediction)
    }
    func testParallelEqualVelocityAndSeparatedFootprintsDoNotConflict() {
        let r = evaluate(candidate(motion(0, 15, 2, 0)), motion(0, 0, 2, 0))
        XCTAssertEqual(r.state, .noConflictInHorizon); XCTAssertNil(r.tCPA)
    }
    func testUnknownUserVelocityIsNotStationaryOrLowRisk() {
        let r = evaluate(candidate(motion(-20, 0, 10, 0)), motion(0, -2, nil, nil))
        XCTAssertEqual(r.state, .notAssessable); XCTAssertEqual(r.reason, .missingMotion)
        XCTAssertNil(r.tCPA); XCTAssertTrue(r.presenceEvidence)
    }
    func testCameraRotationDoesNotRotateBodyMotionOrPromotePrediction() {
        let c = candidate(motion(-20, 0, 10, 0)), u = motion(0, -2, 0, 1)
        let a = evaluate(c, u), b = evaluate(c, u, pose: .yaw(90, translation: Vec3(0, 0, 0)))
        XCTAssertEqual(a.tCPA, b.tCPA); XCTAssertEqual(a.dCPA, b.dCPA); XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(b.source, .prediction); XCTAssertEqual(b.occluder, .object)
        var proxy = DeviceMotionProxy()
        proxy.update(pose: .identity, time: 10); proxy.update(pose: .yaw(90, translation: Vec3(0, 0, 0)), time: 10.25)
        XCTAssertEqual(proxy.motion?.velocity, Vec3(0, 0, 0))
    }
    /// Regression: with two frames closer than 50 ms the user's velocity used to be always unknown, so at
    /// 30 or 60 processed frames per second the encounter risk was never assessable on a real phone.
    func testWalkingUserVelocityIsMeasuredAtHighFrameRatesDespiteStepSway() {
        for fps in [30.0, 60.0] {
            var proxy = DeviceMotionProxy()
            var t = 0.0
            while t < 1.5 {
                let sway = 0.05 * sin(2 * .pi * 2 * t)                 // side-to-side sway of each step, 2 Hz
                proxy.update(pose: .yaw(0, translation: Vec3(sway, 1.4, -1.0 * t)), time: t)
                t += 1 / fps
            }
            let v = proxy.motion?.velocity
            XCTAssertNotNil(v, "\(fps) frames/s: velocity measured")
            XCTAssertEqual(v?.z ?? 0, -1.0, accuracy: 0.05, "\(fps) frames/s: walking speed")
            XCTAssertLessThan(abs(v?.x ?? 9), 0.6, "\(fps) frames/s: sway stays within the stated velocity sigma")
            XCTAssertLessThanOrEqual(proxy.interval, 0.5)
        }
        var gap = DeviceMotionProxy()
        gap.update(pose: .identity, time: 0); gap.update(pose: .identity, time: 0.3)
        XCTAssertNotNil(gap.motion)
        gap.update(pose: .identity, time: 1.2)
        XCTAssertNil(gap.motion, "after a 0.9 s gap older positions are not used")
    }
    func testVehicleLengthAndSameTimeSweepsMatter() {
        var c = candidate(motion(3, 0, 0, 0))
        let u = motion(0, 0, 0, 0)
        var config = EncounterConfig(); config.accelerationDensity = 0; config.horizon = 0.5
        let evaluator = EncounterRiskEvaluator(config: config)
        let long = evaluator.evaluate(c, user: u, worldFromCamera: .identity, epoch: "test", now: 10, sampleInterval: 0.1)
        c.footprint = EncounterFootprint(length: 0.2, width: 0.2)
        let small = evaluator.evaluate(c, user: u, worldFromCamera: .identity, epoch: "test", now: 10, sampleInterval: 0.1)
        XCTAssertNotEqual(long.state, .noConflictInHorizon); XCTAssertEqual(small.state, .noConflictInHorizon)
        // Paths cross spatially but at different times; no false nominal CPA at the intersection.
        let asynchronous = evaluate(candidate(motion(-20, 0, 10, 0)), motion(0, -20, 0, 1))
        XCTAssertGreaterThan(asynchronous.dCPA!, 10)
    }
    func testReducedCadenceIsOutsideSupportedEnvelope() {
        let r = EncounterRiskEvaluator().evaluate(candidate(motion(-20, 0, 10, 0)), user: motion(0, -2, 0, 1),
            worldFromCamera: .identity, epoch: "test", now: 10, sampleInterval: 1)
        XCTAssertEqual(r.state, .notAssessable); XCTAssertEqual(r.reason, .insufficientCadence)
    }
    /// The bridge case: a car seen at 10 m/s, then hidden for 2 s, is still a possible (not imminent) conflict.
    func testHiddenCarPredictionStaysAssessableForAFewSecondsButNeverImminent() {
        var hidden = candidate(motion(-12, 0, 10, 0))
        hidden.source = .prediction; hidden.motion.measurementAge = 2.0; hidden.motion.positionSigma = 0.8
        let r = evaluate(hidden, motion(0, -1, 0, 0))
        XCTAssertEqual(r.state, .possibleConflict)
        hidden.motion.measurementAge = 3.5
        XCTAssertEqual(evaluate(hidden, motion(0, -1, 0, 0)).state, .notAssessable, "beyond the prediction age it is not assessed")
        var seen = candidate(motion(-12, 0, 10, 0)); seen.source = .localMeasurement; seen.motion.measurementAge = 2.0
        XCTAssertEqual(evaluate(seen, motion(0, -1, 0, 0)).state, .notAssessable, "a measurement is not trusted that long")
    }
}
