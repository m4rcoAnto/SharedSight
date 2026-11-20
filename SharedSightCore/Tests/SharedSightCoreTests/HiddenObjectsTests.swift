import XCTest
@testable import SharedSightCore

/// Objects this phone's camera cannot see: line of sight on the floor plan, this phone's own prediction,
/// the hub's reply, and what finally gets spoken.
final class HiddenObjectsTests: XCTestCase {
    private let en = AlertPhraseBuilder(language: .english)
    private let it = AlertPhraseBuilder(language: .italian)

    // Camera at the origin, 1.4 m up, looking along -Z. A wall 3 m ahead covers x in [0, 3].
    private let camera = FloorCamera(x: 0, y: 1.4, z: 0, headingX: 0, headingZ: -1)
    private let wall = WallSegment(ax: 0, az: -3, bx: 3, bz: -3, y0: 0, y1: 2.7)
    private func person(_ x: Double, _ z: Double, id: Int? = nil) -> SightTarget {
        SightTarget(id: id, x: x, z: z, floorY: 0, height: 1.7, radius: 0.25)
    }
    private func relation(_ target: SightTarget, walls: [WallSegment], blockers: [SightTarget] = []) -> SightRelation {
        SightGeometry.relation(camera: camera, fovDeg: 60, range: 10, target: target, walls: walls, blockers: blockers).relation
    }
    private func hiddenIntents(_ intents: [AlertIntent]) -> [AlertIntent] {
        intents.filter {
            switch $0.kind { case .hiddenSeenByOther, .hiddenEstimate: return true; default: return false }
        }
    }

    // MARK: Line of sight

    func testWallHidesWindowDoesNotAndFieldOfViewHasEdges() {
        XCTAssertEqual(relation(person(-1, -4), walls: [wall]), .visible)
        XCTAssertEqual(relation(person(1, -4), walls: [wall]), .occluded(.wall))
        var door = wall; door.kind = .door
        XCTAssertEqual(relation(person(1, -4), walls: [door]), .occluded(.door))
        var glass = wall; glass.kind = .window
        XCTAssertEqual(relation(person(1, -4), walls: [glass]), .visible, "a camera sees through glass")
        XCTAssertEqual(relation(person(5, -1), walls: []), .outOfView)
        XCTAssertEqual(relation(person(0, -12), walls: []), .outOfRange)
    }

    func testLowFurnitureHidesOnlyPartOfAStandingPersonAndAPersonHidesAPerson() {
        let couch = SightTarget(id: 9, x: 0, z: -2, floorY: 0, height: 0.8, radius: 0.9)
        XCTAssertNotEqual(relation(person(0, -4), walls: [], blockers: [couch]), .occluded(.object),
                          "the head is above the couch: a detector can still see the person")
        let other = person(0, -2, id: 5)
        XCTAssertEqual(relation(person(0, -4, id: 6), walls: [], blockers: [other]), .occluded(.object))
        XCTAssertEqual(relation(person(0, -2, id: 5), walls: [], blockers: [other]), .visible, "an object does not hide itself")
    }

    func testWallFootprintFromMeasuredVerticesAndBearingConvention() {
        let w = WallSegment(vertices: [Vec3(1, 0, -2), Vec3(1, 2.5, -2), Vec3(4, 2.5, -2), Vec3(4, 0, -2), Vec3(2, 1, -2)])
        XCTAssertNotNil(w)
        XCTAssertEqual(min(w!.ax, w!.bx), 1, accuracy: 1e-9); XCTAssertEqual(max(w!.ax, w!.bx), 4, accuracy: 1e-9)
        XCTAssertEqual(w!.y1, 2.5, accuracy: 1e-9)
        XCTAssertNil(WallSegment(vertices: [Vec3(0, 0, 0), Vec3(0.05, 1, 0), Vec3(0, 2, 0)]), "a 5 cm sliver is noise, not a wall")
        // Same convention as the rest of the app: positive bearing is to the right of where the camera looks.
        XCTAssertGreaterThan(camera.locate(x: 2, z: -2).bearingDeg, 0)
        XCTAssertLessThan(camera.locate(x: -2, z: -2).bearingDeg, 0)
        XCTAssertNil(FloorCamera(pose: Pose(columnMajor: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 1.4, 0, 1])),
                     "pointing straight down there is no heading on the floor")
    }

    func testMovementStopsAtAWallButPassesUnderALintel() {
        let stopped = SightGeometry.move(x: 1, z: -2, dx: 0, dz: -2, walls: [wall], floorY: 0)
        XCTAssertNotNil(stopped.hit)
        XCTAssertGreaterThan(stopped.z, -3, "never on the far side of the wall")
        let lintel = WallSegment(ax: 0, az: -3, bx: 3, bz: -3, y0: 2.1, y1: 2.7)
        XCTAssertNil(SightGeometry.move(x: 1, z: -2, dx: 0, dz: -2, walls: [lintel], floorY: 0).hit)
    }

    // MARK: One phone alone: prediction

    /// A person walks to the right at 1 m/s along z = -4 and passes behind the wall at x = 0.
    private func walkBehindWall(_ memory: GroundTrackMemory, until end: Double, stopObservingAt hide: Double = 1.0,
                                walls: [WallSegment]? = nil, step: Double = 0.1) -> [(t: Double, estimates: [HiddenEstimate])] {
        var out: [(Double, [HiddenEstimate])] = []
        var t = 0.0
        while t <= end + 1e-9 {
            let x = -1 + t
            let seen = t < hide
            let obs = seen ? [GroundObservation(trackID: 1, label: "person", position: Vec3(x, 0, -4), sigma: 0.2)] : []
            out.append((t, memory.update(observations: obs, observedTrackIDs: seen ? [1] : [], camera: camera, fovDeg: 60,
                                         walls: walls ?? [wall], now: 100 + t)))
            t += step
        }
        return out
    }

    func testPersonWalkingBehindAWallIsPredictedWithGrowingUncertaintyThenAbandoned() {
        let memory = GroundTrackMemory()
        let run = walkBehindWall(memory, until: 12)
        XCTAssertTrue(run.filter { $0.t < 1.0 }.allSatisfy { $0.estimates.isEmpty }, "nothing is estimated while it is seen")
        let hidden = run.filter { !$0.estimates.isEmpty }
        XCTAssertFalse(hidden.isEmpty)
        let first = hidden.first!.estimates[0], later = hidden.last!.estimates[0]
        XCTAssertEqual(first.occluder, .wall)
        XCTAssertEqual(first.label, "person")
        XCTAssertGreaterThan(later.position.x, first.position.x, "it keeps moving the way it was going")
        XCTAssertGreaterThan(later.sigma, first.sigma, "and the uncertainty grows")
        XCTAssertGreaterThan(later.age, first.age)
        // No braking is inferred solely from occlusion.
        XCTAssertEqual(later.velocity!.x, first.velocity!.x, accuracy: 1e-9)
        XCTAssertEqual(later.position.x, first.position.x + first.velocity!.x * (later.age - first.age), accuracy: 1e-9)
        XCTAssertTrue(run.last!.estimates.isEmpty, "an old estimate is dropped, not kept forever")
        XCTAssertNil(memory.position(of: 1))
    }

    func testPredictionInPlainViewIsEvidenceOfAbsence() {
        // No wall at all: the person simply stops being detected in the middle of the picture.
        let memory = GroundTrackMemory()
        let run = walkBehindWall(memory, until: 3.5, walls: [])
        XCTAssertTrue(run.allSatisfy { $0.estimates.isEmpty },
                      "an object that should be visible and is not detected is never shown as an estimate")
        XCTAssertNil(memory.position(of: 1), "and it is forgotten after the detector-dropout grace period")
    }

    func testEstimateNeverCrossesAMeasuredWall() {
        // The person walks straight at a side wall at x = 2 behind the occluding wall.
        let side = WallSegment(ax: 2, az: -6, bx: 2, bz: -3, y0: 0, y1: 2.7)
        let memory = GroundTrackMemory()
        let run = walkBehindWall(memory, until: 8, walls: [wall, side])
        let xs = run.flatMap { $0.estimates.map(\.position.x) }
        XCTAssertFalse(xs.isEmpty)
        XCTAssertLessThan(xs.max()!, 2.0, "the estimate stops at the wall")
    }

    func testFurnitureIsNeverPredictedAndDetectedWithoutPositionIsNotHidden() {
        let memory = GroundTrackMemory()
        for i in 0..<10 {
            _ = memory.update(observations: [GroundObservation(trackID: 2, label: "chair", position: Vec3(1, 0, -4), sigma: 0.2)],
                              observedTrackIDs: [2], camera: camera, fovDeg: 60, walls: [wall], now: 100 + Double(i) * 0.1)
        }
        let afterChair = memory.update(observations: [], observedTrackIDs: [], camera: camera, fovDeg: 60, walls: [wall], now: 103)
        XCTAssertTrue(afterChair.isEmpty, "a chair does not walk: nothing to predict")

        let close = GroundTrackMemory()
        _ = close.update(observations: [GroundObservation(trackID: 3, label: "person", position: Vec3(1, 0, -4), sigma: 0.2)],
                         observedTrackIDs: [3], camera: camera, fovDeg: 60, walls: [wall], now: 100)
        // Still detected (feet outside the picture, so no floor point): known to be there, not "hidden".
        let stillSeen = close.update(observations: [], observedTrackIDs: [3], camera: camera, fovDeg: 60, walls: [wall], now: 102)
        XCTAssertTrue(stillSeen.isEmpty)
    }

    func testNoPoseNoEstimateAndReappearanceReplacesTheEstimate() {
        let memory = GroundTrackMemory()
        _ = walkBehindWall(memory, until: 2)
        let blind = memory.update(observations: [], observedTrackIDs: [], camera: nil, fovDeg: 60, walls: [wall], now: 102.2)
        XCTAssertTrue(blind.isEmpty, "without a tracked pose there is no direction to give")
        // The person comes out on the far side of the wall as a NEW local track (id 7), close to the estimate.
        let back = memory.update(observations: [GroundObservation(trackID: 7, label: "person", position: Vec3(1.6, 0, -4), sigma: 0.2)],
                                 observedTrackIDs: [7], camera: camera, fovDeg: 60, walls: [], now: 102.4)
        XCTAssertTrue(back.isEmpty, "the estimate is retired as soon as the object is seen again")
        XCTAssertNil(memory.position(of: 1))
        XCTAssertNotNil(memory.position(of: 7))
    }

    // MARK: Hub reply fixtures: simulated geometry with explicit v3 timing bounds

    private let seenReply = #"{"v":3,"epoch":"test","sequence":1,"receiptToken":"token","now":7667,"advisories":[{"id":"W7","kind":"seen","label":"dog","position":{"x":2.679,"y":0,"z":-1.651},"velocity":{"x":-0.119,"z":-1.094},"sigma":0.202,"relation":"outOfView","occluder":null,"seenBy":1,"localID":3,"moving":true,"distance":5.433,"ageUncertaintyMs":20,"ageMs":67},{"id":"W6","kind":"seen","label":"person","position":{"x":4.468,"y":0,"z":0.735},"velocity":{"x":0.34,"z":-0.513},"sigma":0.189,"relation":"occluded","occluder":"door","seenBy":1,"localID":2,"moving":true,"distance":6.336,"ageUncertaintyMs":20,"ageMs":67},{"id":"W5","kind":"seen","label":"dining table","position":{"x":0.121,"y":0,"z":-0.424},"velocity":{"x":0,"z":0},"sigma":0.137,"relation":"outOfView","occluder":null,"seenBy":1,"localID":null,"moving":false,"distance":2.656,"ageUncertaintyMs":20,"ageMs":67}],"devices":3}"#
    private let estimatedReply = #"{"v":3,"epoch":"test","sequence":1,"receiptToken":"token","now":6400,"advisories":[{"id":"W3","kind":"estimated","label":"dog","position":{"x":3.01,"y":0,"z":0.171},"velocity":{"x":0.38,"z":-0.98},"sigma":0.371,"relation":"occluded","occluder":"wall","seenBy":0,"localID":3,"moving":true,"distance":5.026,"ageUncertaintyMs":20,"ageMs":467}],"devices":1}"#

    func testHubReplyDecodesAndMalformedRepliesAreIgnoredWhole() {
        let reply = ServerReply.decode(Data(seenReply.utf8))
        XCTAssertEqual(reply?.advisories.count, 3)
        XCTAssertEqual(reply?.devices, 3)
        XCTAssertEqual(reply?.advisories[1].occluder, "door")
        XCTAssertEqual(reply?.advisories[1].localID, 2)
        XCTAssertNil(reply?.advisories[0].occluder)
        XCTAssertNil(ServerReply.decode(Data(#"{"v":1,"advisories":[]}"#.utf8)), "another protocol version")
        XCTAssertNil(ServerReply.decode(Data(#"{"v":2,"advisories":[{"id":"W1"}]}"#.utf8)), "one bad entry voids the reply")
        XCTAssertNil(ServerReply.decode(Data("not json".utf8)))
    }

    // The simulated user's phone: at (-2.1, 1.35, 1.25), looking along +X (yaw -90 about +Y turns -Z into +X).
    private let userPose = Pose.yaw(-90, translation: Vec3(-2.1, 1.35, 1.25))

    func testAdvisoriesBecomeCameraRelativeReports() {
        let reply = ServerReply.decode(Data(seenReply.utf8))!
        let reports = HiddenObjectResolver().resolve(advisories: reply.advisories, advisoryAge: 0.1, worldFromReference: .identity,
                                                     estimates: [], worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(reports.count, 3)
        let person = reports.first { $0.label == "person" }!
        XCTAssertEqual(person.source, .otherDevice(count: 1))
        XCTAssertEqual(person.occluder, .door)
        XCTAssertEqual(person.sector, .ahead)                       // through the doorway, straight ahead of the user
        XCTAssertEqual(person.distance.meters, 6.6, accuracy: 0.2)
        XCTAssertEqual(person.distance.method, .sharedAnchor)
        XCTAssertEqual(person.localTrackID, 2)
        let dog = reports.first { $0.label == "dog" }!
        XCTAssertNil(dog.occluder, "outside the field of view, not behind something")
        XCTAssertEqual(dog.sector, .left, "the dog is at -Z, which is on the left of a camera looking along +X")
        XCTAssertEqual(reports.map(\.distance.meters), reports.map(\.distance.meters).sorted(), "nearest first")
    }

    func testAdvisoriesInTheMarkerFrameAreMappedThroughThisPhonesOwnFix() {
        // This phone's world is the marker frame shifted by (10, 0, 0): the same advisory must land 10 m further along x.
        let reply = ServerReply.decode(Data(seenReply.utf8))!
        let worldFromAnchor = Pose.yaw(0, translation: Vec3(10, 0, 0))
        let cameraInWorld = Pose.yaw(-90, translation: Vec3(10 - 2.1, 1.35, 1.25))
        let shifted = HiddenObjectResolver().resolve(advisories: reply.advisories, advisoryAge: 0.1, worldFromReference: worldFromAnchor,
                                                     estimates: [], worldFromCamera: cameraInWorld, trackingNormal: true)
        let plain = HiddenObjectResolver().resolve(advisories: reply.advisories, advisoryAge: 0.1, worldFromReference: .identity,
                                                   estimates: [], worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(shifted.map(\.sector), plain.map(\.sector))
        for (a, b) in zip(shifted, plain) { XCTAssertEqual(a.distance.meters, b.distance.meters, accuracy: 1e-6) }
    }

    func testStaleReplyLostTrackingAndVagueEstimatesGiveNothing() {
        let reply = ServerReply.decode(Data(seenReply.utf8))!
        let resolver = HiddenObjectResolver()
        XCTAssertTrue(resolver.resolve(advisories: reply.advisories, advisoryAge: 1.5, worldFromReference: .identity, estimates: [],
                                       worldFromCamera: userPose, trackingNormal: true).isEmpty, "the hub has gone quiet")
        XCTAssertTrue(resolver.resolve(advisories: reply.advisories, advisoryAge: nil, worldFromReference: .identity, estimates: [],
                                       worldFromCamera: userPose, trackingNormal: true).isEmpty)
        XCTAssertTrue(resolver.resolve(advisories: reply.advisories, advisoryAge: 0.1, worldFromReference: .identity, estimates: [],
                                       worldFromCamera: userPose, trackingNormal: false).isEmpty, "no pose, no direction, no claim")
        XCTAssertTrue(resolver.resolve(advisories: reply.advisories, advisoryAge: 0.1, worldFromReference: .identity, estimates: [],
                                       worldFromCamera: nil, trackingNormal: true).isEmpty)
        let vague = HiddenEstimate(trackID: 4, label: "person", position: Vec3(1, 0, 1), sigma: 1.9, speed: 0.5, occluder: .wall, age: 6)
        XCTAssertTrue(resolver.resolve(advisories: [], advisoryAge: nil, worldFromReference: .identity, estimates: [vague],
                                       worldFromCamera: userPose, trackingNormal: true).isEmpty)
    }

    func testTheSameObjectIsNeverReportedTwice() {
        let resolver = HiddenObjectResolver()
        // The phone predicts its own lost track 3 (the dog). The hub says another phone SEES that same track: the
        // measurement wins and the phone's own guess is dropped.
        let own = HiddenEstimate(trackID: 3, label: "dog", position: Vec3(2.5, 0, -1.2), sigma: 0.5, speed: 1, occluder: nil, age: 1)
        let seen = ServerReply.decode(Data(seenReply.utf8))!
        let a = resolver.resolve(advisories: seen.advisories, advisoryAge: 0.1, worldFromReference: .identity, estimates: [own],
                                 worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(a.filter { $0.label == "dog" }.count, 1)
        XCTAssertEqual(a.first { $0.label == "dog" }?.source, .otherDevice(count: 1))
        // The hub only estimates that track too: the phone keeps its own estimate (it works without the hub) and skips the hub's.
        let estimated = ServerReply.decode(Data(estimatedReply.utf8))!
        let b = resolver.resolve(advisories: estimated.advisories, advisoryAge: 0.1, worldFromReference: .identity, estimates: [own],
                                 worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].id, "L:3")
        XCTAssertTrue(b[0].isPrediction)
        XCTAssertEqual(b[0].distance.method, .motionPrediction)
        // Without an own estimate the hub's is used.
        let c = resolver.resolve(advisories: estimated.advisories, advisoryAge: 0.1, worldFromReference: .identity, estimates: [],
                                 worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(c.map(\.id), ["S:W3"])
    }

    // MARK: What gets spoken

    private func report(_ id: String = "S:W6", _ label: String = "person", source: HiddenReport.Source = .otherDevice(count: 1),
                        occluder: OccluderKind? = .door, sector: Sector? = .ahead, meters: Double = 3, sigma: Double = 0.2,
                        local: Int? = nil, moving: Bool = true) -> HiddenReport {
        HiddenReport(id: id, label: label, source: source, occluder: occluder, sector: sector, bearingDeg: 0,
                     distance: DistanceMeasurement(meters: meters, sigma: sigma, method: source == .prediction ? .motionPrediction : .sharedAnchor),
                     localTrackID: local, moving: moving, age: 0.1)
    }

    func testPhrasesSayWhatWhereAndHowItIsKnown() {
        let seen = AlertIntent(kind: .hiddenSeenByOther(label: "person", occluder: .door), sector: .left,
                               distance: DistanceMeasurement(meters: 3.2, sigma: 0.2, method: .sharedAnchor),
                               source: .peer(cameraID: "hub"), priority: 60, interrupts: false, evidenceTimestamp: 0)
        XCTAssertEqual(it.phrase(for: seen), "Persona a sinistra, dietro una porta, 3 metri, da un altro telefono.")
        XCTAssertEqual(en.phrase(for: seen), "Person on your left, behind a door, 3 meters, from another phone.")
        let guess = AlertIntent(kind: .hiddenEstimate(label: "dog", occluder: nil), sector: .right,
                                distance: DistanceMeasurement(meters: 2, sigma: 0.6, method: .motionPrediction),
                                source: .localCamera, priority: 46, interrupts: false, evidenceTimestamp: 0)
        XCTAssertEqual(it.phrase(for: guess), "Cane non più visibile, forse a destra, 2 metri.")
        XCTAssertEqual(en.phrase(for: guess), "Dog no longer visible, maybe on your right, 2 meters.")
        // Outside the picture is not "behind" anything: the direction is the whole explanation. Far distances in whole metres.
        let side = AlertIntent(kind: .hiddenSeenByOther(label: "dog", occluder: nil), sector: .right,
                               distance: DistanceMeasurement(meters: 6.4, sigma: 0.3, method: .sharedAnchor),
                               source: .peer(cameraID: "hub"), priority: 60, interrupts: false, evidenceTimestamp: 0)
        XCTAssertEqual(it.phrase(for: side), "Cane a destra, 6 metri, da un altro telefono.")
        XCTAssertEqual(en.phrase(for: side), "Dog on your right, 6 meters, from another phone.")
        for text in [it.phrase(for: seen), it.phrase(for: guess), en.phrase(for: seen), en.phrase(for: guess), it.phrase(for: side)] {
            XCTAssertFalse(text.lowercased().contains("clear")); XCTAssertFalse(text.lowercased().contains("libera"))
        }
    }

    func testAPersonSeenByAnotherPhoneIsAnnouncedOnceThenLeftAlone() {
        let engine = SpokenAlerts()
        let first = hiddenIntents(engine.decide(local: [], hidden: [report()], reliability: healthyReport(), now: t0))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.kind, .hiddenSeenByOther(label: "person", occluder: .door))
        XCTAssertEqual(first.first?.source, .peer(cameraID: "hub"))
        XCTAssertEqual(first.first?.interrupts, false)
        var again = 0
        for i in 1...80 { again += hiddenIntents(engine.decide(local: [], hidden: [report()], reliability: healthyReport(), now: t0 + Double(i) * 0.1)).count }
        XCTAssertEqual(again, 0, "eight seconds of the same information: said once")
        let later = hiddenIntents(engine.decide(local: [], hidden: [report()], reliability: healthyReport(), now: t0 + 13))
        XCTAssertEqual(later.count, 1, "after the cooldown it is worth a reminder")
    }

    func testMovingToAnotherDirectionIsNewInformationButNotInstantly() {
        let engine = SpokenAlerts()
        _ = engine.decide(local: [], hidden: [report(sector: .ahead)], reliability: healthyReport(), now: t0)
        XCTAssertTrue(hiddenIntents(engine.decide(local: [], hidden: [report(sector: .left)], reliability: healthyReport(), now: t0 + 1)).isEmpty)
        // Not while the first sentence is still being spoken, either: it is decided when the voice is free again.
        XCTAssertTrue(hiddenIntents(engine.decide(local: [], hidden: [report(sector: .left)], reliability: healthyReport(), now: t0 + 4.5)).isEmpty)
        let moved = hiddenIntents(engine.decide(local: [], hidden: [report(sector: .left)], reliability: healthyReport(), now: t0 + 6.5))
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.sector, .left)
    }

    func testAnEstimateThatAnotherPhoneThenConfirmsIsSaidAgainAsConfirmed() {
        let engine = SpokenAlerts()
        let guess = report("L:4", source: .prediction, occluder: .wall, sigma: 0.5, local: 4)
        let a = hiddenIntents(engine.decide(local: [], hidden: [guess], reliability: healthyReport(), now: t0))
        XCTAssertEqual(a.first?.kind, .hiddenEstimate(label: "person", occluder: .wall))
        XCTAssertEqual(a.first?.source, .localCamera)
        // Same object (local track 4), now measured by another phone: an upgrade, announced after the minimum gap.
        let confirmed = report("S:W9", occluder: .wall, local: 4)
        XCTAssertTrue(hiddenIntents(engine.decide(local: [], hidden: [confirmed], reliability: healthyReport(), now: t0 + 1)).isEmpty)
        let b = hiddenIntents(engine.decide(local: [], hidden: [confirmed], reliability: healthyReport(), now: t0 + 5))
        XCTAssertEqual(b.first?.kind, .hiddenSeenByOther(label: "person", occluder: .wall))
        // ...but a confirmation that degrades back to an estimate is not repeated.
        XCTAssertTrue(hiddenIntents(engine.decide(local: [], hidden: [guess], reliability: healthyReport(), now: t0 + 13)).isEmpty)
    }

    func testEstimatesAreOptionalMeasurementsAreNot() {
        let guess = report("L:4", source: .prediction, occluder: .wall, sigma: 0.5, local: 4)
        var minimal = AlertPreferences(); minimal.verbosity = .minimal
        XCTAssertTrue(hiddenIntents(SpokenAlerts().decide(local: [], hidden: [guess], reliability: healthyReport(),
                                                                         preferences: minimal, now: t0)).isEmpty)
        XCTAssertEqual(hiddenIntents(SpokenAlerts().decide(local: [], hidden: [report()], reliability: healthyReport(),
                                                                          preferences: minimal, now: t0)).count, 1)
        // Too vague or too far: an estimate is not worth the user's attention.
        let vague = report("L:5", source: .prediction, sigma: 1.4, local: 5), far = report("L:6", source: .prediction, meters: 7, sigma: 0.4, local: 6)
        XCTAssertTrue(hiddenIntents(SpokenAlerts().decide(local: [], hidden: [vague, far], reliability: healthyReport(), now: t0)).isEmpty)
        // No direction, no announcement.
        XCTAssertTrue(hiddenIntents(SpokenAlerts().decide(local: [], hidden: [report(sector: nil)], reliability: healthyReport(), now: t0)).isEmpty)
        // The user turned other devices' observations off: measurements from them are not spoken, own estimates still are.
        var noPeers = AlertPreferences(); noPeers.announcePeerObservations = false
        let quiet = hiddenIntents(SpokenAlerts().decide(local: [], hidden: [report(), guess], reliability: healthyReport(),
                                                                       preferences: noPeers, now: t0))
        XCTAssertEqual(quiet.map(\.kind), [.hiddenEstimate(label: "person", occluder: .wall)])
    }

    func testNearestMovingPersonComesFirstAndFurnitureFromAnotherPhoneIsAPlainObstacle() {
        let engine = SpokenAlerts()
        let near = report("S:W1", meters: 2, moving: true), farther = report("S:W2", "dog", meters: 5, moving: true)
        let table = report("S:W3", "dining table", occluder: nil, sector: .right, meters: 2.5, moving: false)
        let first = engine.decide(local: [], hidden: [farther, table, near], reliability: healthyReport(), now: t0)
        XCTAssertEqual(hiddenIntents(first).first?.kind, .hiddenSeenByOther(label: "person", occluder: .door))
        XCTAssertEqual(first.count, 1, "one thing at a time")
        XCTAssertTrue(engine.decide(local: [], hidden: [farther, table, near], reliability: healthyReport(), now: t0 + 3).isEmpty,
                      "the table can wait until the first sentence has been heard and a pause has followed")
        let second = engine.decide(local: [], hidden: [farther, table, near], reliability: healthyReport(), now: t0 + 8)
        XCTAssertEqual(peerIntents(second).count, 1, "a table reported by another phone is an obstacle, worded as before")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first.map { it.phrase(for: $0) }, "Ostacolo segnalato da un altro dispositivo: tavolo, a destra, 2,5 metri.")
        let third = engine.decide(local: [], hidden: [farther, table, near], reliability: healthyReport(), now: t0 + 11)
        XCTAssertTrue(third.isEmpty, "a dog five metres away that this phone never followed and that is not coming nearer is not announced")
        let distant = report("S:W4", "couch", occluder: nil, sector: .left, meters: 3.5, moving: false)
        XCTAssertTrue(SpokenAlerts().decide(local: [], hidden: [distant], reliability: healthyReport(), now: t0).isEmpty,
                      "furniture metres away in another phone's view is not this user's business")
    }

    func testFarHiddenMoversAreAnnouncedOnlyWhenApproachingOrWhenThisPhoneLostThemBehindSomething() {
        func said(_ r: HiddenReport) -> Bool { !hiddenIntents(SpokenAlerts().decide(local: [], hidden: [r], reliability: healthyReport(), now: t0)).isEmpty }
        XCTAssertFalse(said(report(meters: 7)), "a stranger seven metres away behind a door")
        XCTAssertTrue(said(report(meters: 3.5)), "near")
        var coming = report(meters: 5.5); coming.closingSpeed = 0.9
        XCTAssertTrue(said(coming), "coming nearer")
        var comingFromFar = report(meters: 7.5); comingFromFar.closingSpeed = 0.9
        XCTAssertFalse(said(comingFromFar))
        var behindCouch = report(occluder: .object, meters: 5.5); behindCouch.closingSpeed = 0.9
        XCTAssertTrue(said(behindCouch), "approaching behind an object (a parked car, a couch) is not suppressed: the object may hide it until it is close (P03)")
        XCTAssertFalse(said(report(occluder: .object, meters: 5.5, local: 3)), "a small thing behind furniture metres away")
        var leaving = report(meters: 5.5); leaving.closingSpeed = -0.9
        XCTAssertFalse(said(leaving))
        XCTAssertTrue(said(report(meters: 7, local: 2)), "the person this phone was following is now behind a door")
        XCTAssertFalse(said(report(occluder: nil, sector: .left, meters: 5.5, local: 3)), "left the picture sideways, far away: turning finds it again")
        XCTAssertTrue(said(report(occluder: nil, sector: .left, meters: 1.5, local: 3)), "left the picture but is right there")
    }

    func testApproachSpeedComesFromTheHubsVelocityInThisPhonesFrame() {
        // Object 4 m straight ahead of the user (user looks along +X), walking toward the user at 1 m/s.
        let toward = ServerAdvisory(id: "W1", kind: "seen", label: "person", position: Vec3(1.9, 0, 1.25), sigma: 0.2, relation: "occluded",
                                    occluder: "wall", seenBy: 1, ageMs: 0, ageUncertaintyMs: 0, velocity: .init(x: -1, z: 0))
        var away = toward; away.velocity = .init(x: 1, z: 0)
        var across = toward; across.velocity = .init(x: 0, z: 1)
        let r = HiddenObjectResolver().resolve(advisories: [toward], advisoryAge: 0, worldFromReference: .identity, estimates: [],
                                               worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(r[0].closingSpeed, 1, accuracy: 1e-6)
        XCTAssertEqual(HiddenObjectResolver().resolve(advisories: [away], advisoryAge: 0, worldFromReference: .identity, estimates: [],
                                                      worldFromCamera: userPose, trackingNormal: true)[0].closingSpeed, -1, accuracy: 1e-6)
        XCTAssertEqual(HiddenObjectResolver().resolve(advisories: [across], advisoryAge: 0, worldFromReference: .identity, estimates: [],
                                                      worldFromCamera: userPose, trackingNormal: true)[0].closingSpeed, 0, accuracy: 1e-6)
        // The same situation seen through a marker frame rotated by 90 degrees and shifted: same answer.
        let worldFromAnchor = Pose.yaw(90, translation: Vec3(3, 0, -2)), anchorFromWorld = worldFromAnchor.inverseRigid()
        let p = anchorFromWorld.transform(toward.position), tip = anchorFromWorld.transform(Vec3(toward.position.x - 1, 0, toward.position.z))
        let inAnchor = ServerAdvisory(id: "W1", kind: "seen", label: "person", position: p, sigma: 0.2, relation: "occluded", occluder: "wall",
                                      seenBy: 1, ageMs: 0, ageUncertaintyMs: 0, velocity: .init(x: tip.x - p.x, z: tip.z - p.z))
        let viaAnchor = HiddenObjectResolver().resolve(advisories: [inAnchor], advisoryAge: 0, worldFromReference: worldFromAnchor, estimates: [],
                                                       worldFromCamera: userPose, trackingNormal: true)
        XCTAssertEqual(viaAnchor[0].closingSpeed, 1, accuracy: 1e-6)
        XCTAssertEqual(viaAnchor[0].sector, .ahead)
    }

    func testHiddenObjectsAreStillSaidWhenThisCameraIsCovered() {
        var inputs = healthyInputs(); inputs.meanLuma = 0.01; inputs.lumaSpread = 0.005
        let covered = PerceptionReliabilityEngine().evaluate(inputs)
        let intents = SpokenAlerts().decide(local: [], hidden: [report()], reliability: covered, now: t0)
        XCTAssertEqual(hiddenIntents(intents).count, 1, "another phone's eyes matter most when this one cannot see")
        XCTAssertTrue(intents.contains { if case .system(.perceptionUnavailable) = $0.kind { return true }; return false })
        XCTAssertGreaterThan(intents.first?.priority ?? 0, hiddenIntents(intents).first?.priority ?? 999, "the failure of this camera is said first")
    }

    func testSurroundingsSummaryKeepsMeasuredAndEstimatedApart() {
        let text = it.surroundings(perception: .reliable, local: [], peers: [],
                                   hidden: [report(sector: .left, meters: 3), report("L:4", "dog", source: .prediction, occluder: nil, sector: .right, meters: 2, sigma: 0.5)])
        XCTAssertEqual(text, "Non visibile da qui, secondo un altro dispositivo: persona a sinistra, dietro una porta, a circa 3 metri. "
                           + "Posizione stimata, non confermata: cane a destra, a circa 2 metri.")
        XCTAssertFalse(text.contains("via sia libera"))
        let dark = en.surroundings(perception: .unavailable, local: [], peers: [], hidden: [report(sector: .left, meters: 3)])
        XCTAssertTrue(dark.hasPrefix("Camera perception unavailable."))
        XCTAssertTrue(dark.contains("according to another device: person on your left, behind a door, about 3 meters"))
        let nothing = en.surroundings(perception: .reliable, local: [], peers: [], hidden: [report(sector: nil)])
        XCTAssertTrue(nothing.contains("does not mean the way is clear"), "a report without a direction is not spoken")
    }

    // MARK: Tracker occlusion awareness (image space)

    func testPersonHiddenBehindANearerPersonKeepsItsIdentityBeyondTheNormalWindow() {
        let tracker = TemporalObjectTracker()
        var t = t0
        // A (far, higher in the picture) stands at cx 0.5; B (near, bottom edge lower) stands in front of it from the start.
        func far(_ t: Double) -> Detection { det(cx: 0.5, cy: 0.45, w: 0.12, h: 0.3, t: t) }
        func near(_ t: Double) -> Detection { det(cx: 0.5, cy: 0.6, w: 0.26, h: 0.7, t: t) }
        var idA = -1
        for i in 0..<10 { let tracks = tracker.update(detections: [far(t)], timestamp: t, cameraMotion: FrameMotion(dx: 0, dy: 0, reliable: true)); if i == 9 { idA = tracks[0].id }; t += frame }
        // B walks in front and A is not detected for 2.2 s (longer than the 1.5 s re-association window).
        var occlusion = 0.0
        for _ in 0..<66 {
            let tracks = tracker.update(detections: [near(t)], timestamp: t, cameraMotion: FrameMotion(dx: 0, dy: 0, reliable: true))
            occlusion = max(occlusion, tracks.first { $0.id == idA }?.occlusion ?? 0)
            t += frame
        }
        XCTAssertGreaterThanOrEqual(occlusion, 0.5, "the tracker knows A is behind something nearer")
        let after = tracker.update(detections: [far(t), near(t)], timestamp: t, cameraMotion: FrameMotion(dx: 0, dy: 0, reliable: true))
        XCTAssertTrue(after.contains { $0.id == idA && $0.observedThisFrame }, "A is picked up again under the same number")
    }
}
