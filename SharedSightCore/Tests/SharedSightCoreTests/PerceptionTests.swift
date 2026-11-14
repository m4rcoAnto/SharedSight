import XCTest
@testable import SharedSightCore

final class TrackerAndMemoryTests: XCTestCase {

    func testHungarianFindsOptimalAssignment() {
        XCTAssertEqual(Hungarian.solve([[4, 1, 3], [2, 0, 5], [3, 2, 2]]), [1, 0, 2])
        XCTAssertEqual(Hungarian.solve([[1, 9], [9, 1], [5, 5]]), [0, 1, -1])
    }

    func testSeparateTrackingIDsForSameClass() {
        let tracker = TemporalObjectTracker()
        var ids: [Set<Int>] = []
        for i in 0..<8 {
            let t = t0 + Double(i) * frame
            let tracks = tracker.update(detections: [det(cx: 0.25, t: t), det(cx: 0.75, t: t)], timestamp: t)
            ids.append(Set(tracks.map(\.id)))
        }
        XCTAssertEqual(ids.last!.count, 2, "two people must be two instances")
        XCTAssertEqual(ids.first, ids.last, "IDs must be stable across frames")
        XCTAssertTrue(tracker.update(detections: [], timestamp: t0 + 8 * frame).allSatisfy { $0.confirmed })
    }

    func testMaskAssociationFollowsMatchedDetection() {
        let tracker = TemporalObjectTracker()
        var last: [TrackSnapshot] = []
        var left = det(cx: 0.25, t: t0), right = det(cx: 0.75, t: t0)
        for i in 0..<5 {
            let t = t0 + Double(i) * frame
            left = det(cx: 0.25, t: t, mask: true); right = det(cx: 0.75, t: t, mask: true)
            last = tracker.update(detections: [right, left], timestamp: t)
        }
        let leftTrack = last.first { $0.box.cx < 0.5 }!, rightTrack = last.first { $0.box.cx > 0.5 }!
        XCTAssertEqual(leftTrack.lastObservationID, left.id)
        XCTAssertEqual(rightTrack.lastObservationID, right.id)
        XCTAssertTrue(leftTrack.hasMask && rightTrack.hasMask)
    }

    func testStationaryObstacleHasNoMotion() {
        let tracker = TemporalObjectTracker()
        var last: [TrackSnapshot] = []
        for i in 0..<30 { let t = t0 + Double(i) * frame; last = tracker.update(detections: [det(56, "chair", cx: 0.5, t: t)], timestamp: t) }
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].hits, 30)
        XCTAssertLessThan(last[0].speed, 0.02)
        let e = ObstacleMemoryEngine().update(tracks: last, now: t0 + 29 * frame)[0]
        XCTAssertFalse(SpatialRelevanceEstimator().assess(e, camera: levelCamera).moving)
    }

    func testMovingObstacleIsDetectedOnlyWithSteadyCamera() {
        let tracker = TemporalObjectTracker()
        var last: [TrackSnapshot] = []
        var now = t0
        for i in 0..<30 { now = t0 + Double(i) * frame; last = tracker.update(detections: [det(cx: 0.2 + 0.01 * Double(i), t: now)], timestamp: now) }
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].velocityX, 0.3, accuracy: 0.1)
        let e = ObstacleMemoryEngine().update(tracks: last, now: now)[0]
        XCTAssertTrue(SpatialRelevanceEstimator().assess(e, camera: levelCamera).moving)
        var walking = levelCamera; walking.steady = false
        XCTAssertFalse(SpatialRelevanceEstimator().assess(e, camera: walking).moving, "no motion claim while the camera itself moves")
    }

    func testCameraMotionCompensationRemovesApparentMotion() {
        let tracker = TemporalObjectTracker()
        var last: [TrackSnapshot] = []
        for i in 0..<30 {
            let t = t0 + Double(i) * frame
            last = tracker.update(detections: [det(56, "chair", cx: 0.2 + 0.01 * Double(i), t: t)], timestamp: t,
                                  cameraMotion: FrameMotion(dx: i == 0 ? 0 : 0.01, dy: 0, reliable: true))
        }
        XCTAssertEqual(last.count, 1)
        XCTAssertLessThan(abs(last[0].velocityX), 0.05, "a static object seen by a panning camera must not look like a moving object")
    }

    func testOcclusionThenReacquisitionKeepsIdentity() {
        let tracker = TemporalObjectTracker(), memory = ObstacleMemoryEngine()
        var now = t0, id = -1
        for i in 0..<30 {
            now = t0 + Double(i) * frame
            let tracks = tracker.update(detections: [det(56, "chair", cx: 0.5, t: now)], timestamp: now)
            id = tracks[0].id
            _ = memory.update(tracks: tracks, now: now)
        }
        for _ in 0..<6 { now += frame; let m = memory.update(tracks: tracker.update(detections: [], timestamp: now), now: now)
            XCTAssertEqual(m[0].state, .temporarilyHidden); XCTAssertFalse(m[0].isCurrentEvidence) }
        now += frame
        let m = memory.update(tracks: tracker.update(detections: [det(56, "chair", cx: 0.5, t: now)], timestamp: now), now: now)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].id, id)
        XCTAssertEqual(m[0].state, .reacquired)
    }

    func testPredictionGrowsUncertainAndExpires() {
        let tracker = TemporalObjectTracker(), memory = ObstacleMemoryEngine()
        var now = t0
        for i in 0..<45 { now = t0 + Double(i) * frame; _ = memory.update(tracks: tracker.update(detections: [det(56, "chair", cx: 0.5, t: now)], timestamp: now), now: now) }
        let lastSeen = now
        var states: [Int: MemoryEntry] = [:]   // key = tenths of a second since last observation
        var lostCount = 0
        while now < lastSeen + 6 {
            now += frame
            let m = memory.update(tracks: tracker.update(detections: [], timestamp: now), now: now)
            lostCount += m.filter { $0.state == .lost }.count
            if let e = m.first(where: { $0.state != .lost }) { states[Int(((now - lastSeen) * 10).rounded())] = e }
        }
        XCTAssertEqual(states[2]?.state, .temporarilyHidden)
        XCTAssertEqual(states[8]?.state, .predicted)
        XCTAssertEqual(states[25]?.state, .unknown, "old predictions must stop being offered")
        XCTAssertGreaterThan(states[25]!.track.positionSigma, states[2]!.track.positionSigma, "uncertainty must grow")
        XCTAssertNil(states[55], "memory must expire")
        XCTAssertEqual(lostCount, 1, "LOST is reported exactly once")
        XCTAssertTrue(states.values.allSatisfy { !$0.isCurrentEvidence }, "a remembered obstacle is never current evidence")
    }

    func testClassEqualityIsNotIdentity() {
        let tracker = TemporalObjectTracker()
        var now = t0, first = -1
        for i in 0..<10 { now = t0 + Double(i) * frame; first = tracker.update(detections: [det(cx: 0.2, t: now)], timestamp: now)[0].id }
        // Same class appears somewhere else: must not inherit the identity.
        now += frame
        let moved = tracker.update(detections: [det(cx: 0.8, t: now)], timestamp: now)
        XCTAssertTrue(moved.contains { $0.id != first && $0.observedThisFrame })
        XCTAssertFalse(moved.first { $0.id == first }!.observedThisFrame)
        // Same class, same place, but after a long unobserved gap: identity is not provable => new ID.
        now += 2.0
        let later = tracker.update(detections: [det(cx: 0.2, t: now)], timestamp: now)
        XCTAssertFalse(later.first { $0.id == first }?.observedThisFrame ?? false)
    }

    func testIdentityAmbiguityIsFlagged() {
        let tracker = TemporalObjectTracker()
        var now = t0
        for i in 0..<10 { now = t0 + Double(i) * frame; tracker.update(detections: [det(cx: 0.45, t: now), det(cx: 0.55, t: now)], timestamp: now) }
        for _ in 0..<5 { now += frame; tracker.update(detections: [], timestamp: now) }
        now += frame
        let tracks = tracker.update(detections: [det(cx: 0.5, t: now)], timestamp: now)
        let matched = tracks.filter { $0.observedThisFrame }
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(matched[0].identityAmbiguous, "two equally plausible candidates => identity must be marked ambiguous")
    }
}

final class DecodingTests: XCTestCase {

    func testEndToEndLayoutDecodesMultipleDetections() throws {
        var data = [Float](repeating: 0, count: 3 * 38)
        func row(_ r: Int, _ v: [Float]) { for (i, x) in v.enumerated() { data[r * 38 + i] = x } }
        row(0, [200, 100, 440, 540, 0.9, 0])
        row(1, [300, 300, 360, 400, 0.6, 56])
        row(2, [10, 10, 50, 50, 0.05, 2])    // below threshold
        let lb = Letterbox(imageWidth: 720, imageHeight: 1280)
        let d = try YOLODecoder.decode(output: RawTensor(shape: [1, 3, 38], data: data), maskChannels: 32, inputSize: 640,
                                       letterbox: lb, confidenceThreshold: 0.25)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].classIndex, 0)
        XCTAssertEqual(d[0].box.x, (200.0 / 640 - 0.21875) / 0.5625, accuracy: 1e-4)
        XCTAssertEqual(d[0].box.maxX, (440.0 / 640 - 0.21875) / 0.5625, accuracy: 1e-4)
        XCTAssertEqual(d[0].box.y, 100.0 / 640, accuracy: 1e-4)
        XCTAssertEqual(d[0].maskCoefficients.count, 32)
        XCTAssertEqual(d[1].classIndex, 56)
    }

    func testClassicLayoutAppliesNMS() throws {
        // [1, 4 + 2 classes, 8 anchors]; anchors 0 and 1 overlap heavily (same class), anchor 2 is another class.
        let a = 8
        var data = [Float](repeating: 0, count: 6 * a)
        func anchor(_ i: Int, _ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ c0: Float, _ c1: Float) {
            for (k, v) in [cx, cy, w, h, c0, c1].enumerated() { data[k * a + i] = v }
        }
        anchor(0, 320, 320, 100, 100, 0.9, 0); anchor(1, 324, 320, 100, 100, 0.8, 0); anchor(2, 100, 100, 60, 60, 0, 0.7)
        let d = try YOLODecoder.decode(output: RawTensor(shape: [1, 6, a], data: data), maskChannels: 0, inputSize: 640,
                                       letterbox: Letterbox(imageWidth: 640, imageHeight: 640), confidenceThreshold: 0.25)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(Set(d.map(\.classIndex)), [0, 1])
    }

    func testUnknownLayoutIsRejectedNotGuessed() {
        XCTAssertThrowsError(try YOLODecoder.decode(output: RawTensor(shape: [1, 7, 7], data: [Float](repeating: 0, count: 49)),
                                                    maskChannels: 32, inputSize: 640, letterbox: Letterbox(imageWidth: 1, imageHeight: 1),
                                                    confidenceThreshold: 0.25))
    }

    func testMaskAssemblyAndOutline() {
        // One prototype, 8x8 grid: positive inside a 3x3 block (rows 2...4, cols 3...5), negative elsewhere.
        var proto = [Float](repeating: -1, count: 64)
        for r in 2...4 { for c in 3...5 { proto[r * 8 + c] = 1 } }
        let mask = MaskDecoder.decode(coefficients: [2], prototypes: RawTensor(shape: [1, 1, 8, 8], data: proto),
                                      inputBox: (0, 0, 32, 32), inputSize: 32)!
        XCTAssertEqual(mask.pixelCount, 9)
        let outline = mask.outline(letterbox: Letterbox(imageWidth: 1, imageHeight: 1))
        XCTAssertEqual(outline.count, 6)
        XCTAssertEqual(outline.map(\.x).min()!, 3.0 / 8, accuracy: 1e-9)
        XCTAssertEqual(outline.map(\.x).max()!, 6.0 / 8, accuracy: 1e-9)
        XCTAssertNil(MaskDecoder.decode(coefficients: [], prototypes: RawTensor(shape: [1, 1, 8, 8], data: proto), inputBox: (0, 0, 32, 32), inputSize: 32),
                     "no coefficients => no mask; masks are never invented")
    }

    func testClassNameMetadataParsing() {
        let names = YOLODecoder.parseClassNames("{0: 'person', 1: 'bicycle', 56: 'chair', 60: 'dining table'}")
        XCTAssertEqual(names[0], "person"); XCTAssertEqual(names[56], "chair"); XCTAssertEqual(names[60], "dining table")
    }
}
