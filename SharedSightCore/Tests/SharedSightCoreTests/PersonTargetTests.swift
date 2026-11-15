import XCTest
@testable import SharedSightCore

// Persistent identity, target association, follow guidance. Everything here is synthetic input into real logic:
// these tests say nothing about detection accuracy, marker readability at distance, or behaviour on a phone.

private func person(_ id: Int, cx: Double, cy: Double = 0.5, w: Double = 0.2, h: Double = 0.4, observed: Bool = true,
                    conf: Double = 0.9, t: Double, label: String = "person", ambiguousAt: Double? = nil) -> TrackSnapshot {
    TrackSnapshot(id: id, classIndex: label == "person" ? 0 : 56, label: label, box: NormRect(cx: cx, cy: cy, w: w, h: h),
                  velocityX: 0, velocityY: 0, scaleRate: 0, confidence: conf, hits: 10, consecutiveMisses: observed ? 0 : 3,
                  firstSeen: t0, lastObserved: t, observedThisFrame: observed, confirmed: true,
                  identityAmbiguous: ambiguousAt != nil, positionSigma: 0.01, lastObservationID: nil, hasMask: false,
                  lastAmbiguousAt: ambiguousAt)
}

private func marker(_ profile: PersonProfile, cx: Double, cy: Double = 0.45) -> MarkerSighting {
    MarkerSighting(token: profile.markerToken ?? "", box: NormRect(cx: cx, cy: cy, w: 0.04, h: 0.04))
}

private func makeRegistry(_ store: BlobPersistence = InMemoryPersistence()) -> PersonRegistry {
    // swiftlint:disable:next force_try
    try! PersonRegistry(persistence: store)
}

/// A started manager looking for a freshly registered "Marco".
private func armed(config: TargetConfig = TargetConfig()) -> (PersonTargetManager, PersonProfile) {
    let profile = try! makeRegistry().create(nickname: "Marco")
    let m = PersonTargetManager(config: config)
    m.assign(profile, now: t0)
    m.startAcquisition(now: t0)
    return (m, profile)
}

/// Locks track 1 (centre of the image) with the marker at `t0`, then follows it marker-less until `t0 + 1`.
private func lockedAndFollowing(config: TargetConfig = TargetConfig()) -> (PersonTargetManager, PersonProfile, Double) {
    let (m, profile) = armed(config: config)
    m.update(tracks: [person(1, cx: 0.5, t: t0)], markers: [marker(profile, cx: 0.5)], now: t0)
    var t = t0
    while t < t0 + 1 { t += frame; m.update(tracks: [person(1, cx: 0.5, t: t)], markers: [], now: t) }
    return (m, profile, t)
}

final class PersonRegistryTests: XCTestCase {

    func testCreateAndRetrieveProfile() throws {
        let registry = makeRegistry()
        let p = try registry.create(nickname: "  Marco ")
        XCTAssertEqual(p.userID, "USER-0001")
        XCTAssertEqual(p.nickname, "Marco")
        XCTAssertEqual(p.role, .assistedPerson)
        XCTAssertEqual(p.status, .active)
        XCTAssertEqual(registry.profile(id: p.id), p)
        XCTAssertEqual(registry.profile(markerToken: p.markerToken!), p)
        XCTAssertEqual(registry.activeProfileID, p.id, "the first registered person becomes the active one")
    }

    func testUserIDsAreUniqueAndNeverReused() throws {
        let registry = makeRegistry()
        let a = try registry.create(nickname: "A"), b = try registry.create(nickname: "B")
        XCTAssertEqual([a.userID, b.userID], ["USER-0001", "USER-0002"])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.markerToken, b.markerToken)
        try registry.delete(id: b.id)
        let c = try registry.create(nickname: "C")
        XCTAssertEqual(c.userID, "USER-0003", "a deleted person's ID must not be given to someone else")
        XCTAssertEqual(Set(registry.profiles.map(\.userID)).count, registry.profiles.count)
    }

    func testProfilesSurviveRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharedsight-test-\(UUID().uuidString)/people.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try PersonRegistry(persistence: FilePersistence(url: url))
        let marco = try first.create(nickname: "Marco")
        let anna = try first.create(nickname: "Anna")
        try first.update(id: anna.id) { $0.preferences.occlusionGraceSeconds = 2.5 }
        try first.select(id: anna.id)

        // "Restart": a new registry object reading the same file.
        let second = try PersonRegistry(persistence: FilePersistence(url: url))
        XCTAssertEqual(second.profiles.map(\.userID), ["USER-0001", "USER-0002"])
        XCTAssertEqual(second.profile(id: marco.id), marco, "UUID, user ID, token and date are restored unchanged")
        XCTAssertEqual(second.activeProfileID, anna.id)
        XCTAssertEqual(second.activeProfile?.preferences.occlusionGraceSeconds, 2.5)
        XCTAssertEqual(try second.create(nickname: "New").userID, "USER-0003", "the serial counter is restored too")
    }

    func testCorruptStoreIsReportedNotOverwritten() {
        let store = InMemoryPersistence(data: Data("not json".utf8))
        XCTAssertThrowsError(try PersonRegistry(persistence: store))
        XCTAssertEqual(store.saveCount, 0)
    }

    func testEditAndMarkerRegeneration() throws {
        let registry = makeRegistry()
        let p = try registry.create(nickname: "Marco")
        let edited = try registry.update(id: p.id) { $0.nickname = "Marco R." }
        XCTAssertEqual(edited.userID, p.userID)
        XCTAssertEqual(edited.id, p.id)
        let renewed = try registry.regenerateMarker(id: p.id)
        XCTAssertNotEqual(renewed.markerToken, p.markerToken)
        XCTAssertNil(registry.profile(markerToken: p.markerToken!), "the old marker no longer matches anyone")
        XCTAssertThrowsError(try registry.update(id: UUID()) { _ in })
    }

    func testMarkerPayloadCarriesNoPersonalData() throws {
        let p = try makeRegistry().create(nickname: "Marco")
        let payload = MarkerPayload.encode(token: p.markerToken!)
        XCTAssertFalse(payload.contains("Marco"))
        XCTAssertFalse(payload.contains(p.userID))
        XCTAssertFalse(payload.lowercased().contains(p.id.uuidString.lowercased()))
        XCTAssertEqual(MarkerPayload.decode(payload), p.markerToken)
        XCTAssertNil(MarkerPayload.decode("https://example.com"))
        XCTAssertNil(MarkerPayload.decode("SSGT1:short"))
        XCTAssertNil(MarkerPayload.decode("SSGT1:" + String(repeating: "z", count: 32)))
    }

    func testDeletingProfileCleansUpAssociatedData() throws {
        let registry = makeRegistry()
        let marco = try registry.create(nickname: "Marco"), anna = try registry.create(nickname: "Anna")
        let logStore = InMemoryPersistence()
        let log = TrackingEventLog(persistence: logStore)
        let now = Date()
        log.append(TrackingEvent(date: now, kind: .acquired, userID: marco.userID, trackID: 3))
        log.append(TrackingEvent(date: now, kind: .acquired, userID: anna.userID, trackID: 4))
        log.flush()
        let manager = PersonTargetManager()
        manager.assign(marco, now: t0)
        manager.startAcquisition(now: t0)
        manager.update(tracks: [person(3, cx: 0.5, t: t0)], markers: [marker(marco, cx: 0.5)], now: t0)
        XCTAssertEqual(manager.status.trackID, 3)

        // What the app does on delete: registry, then everything that referred to the person.
        let removed = try registry.delete(id: marco.id)
        log.purge(userID: removed.userID)
        log.flush()
        manager.assign(registry.activeProfile, now: t0 + 1)

        XCTAssertNil(registry.profile(id: marco.id))
        XCTAssertNil(registry.activeProfileID, "the deleted person was the active one")
        XCTAssertEqual(log.events.map(\.userID), [anna.userID])
        XCTAssertFalse(String(data: logStore.data ?? Data(), encoding: .utf8)!.contains(marco.userID))
        XCTAssertEqual(manager.status.state, .unassigned)
        XCTAssertNil(manager.status.trackID)
        XCTAssertNil(manager.status.userID)
        // The old marker must no longer lock anything.
        manager.update(tracks: [person(3, cx: 0.5, t: t0 + 1)], markers: [marker(marco, cx: 0.5)], now: t0 + 1)
        XCTAssertEqual(manager.status.state, .unassigned)
    }

    func testEventLogRetention() {
        let now = Date()
        let log = TrackingEventLog(persistence: InMemoryPersistence(), policy: RetentionPolicy(maxAgeDays: 1, maxEvents: 3), now: now)
        log.append(TrackingEvent(date: now.addingTimeInterval(-2 * 86_400), kind: .lost, userID: "USER-0001", trackID: 1))
        XCTAssertTrue(log.events.isEmpty, "older than the retention period")
        for i in 0..<5 { log.append(TrackingEvent(date: now, kind: .following, userID: "USER-0001", trackID: i)) }
        XCTAssertEqual(log.events.map(\.trackID), [2, 3, 4])
    }
}

final class PersonTargetManagerTests: XCTestCase {

    func testNothingHappensUntilStarted() throws {
        let profile = try makeRegistry().create(nickname: "Marco")
        let m = PersonTargetManager()
        m.assign(profile, now: t0)
        m.update(tracks: [person(1, cx: 0.5, t: t0)], markers: [marker(profile, cx: 0.5)], now: t0)
        XCTAssertEqual(m.status.state, .unassigned)
        XCTAssertNil(m.status.trackID)
    }

    func testPersonClassAloneIsNeverEvidence() {
        let (m, _) = armed()
        var t = t0
        for _ in 0..<90 { t += frame; m.update(tracks: [person(1, cx: 0.5, w: 0.5, h: 0.9, t: t)], markers: [], now: t) }
        XCTAssertEqual(m.status.state, .searching, "one large, central person and no marker: still searching")
        XCTAssertNil(m.status.trackID)
    }

    func testPersistentUserMapsToTemporaryTrack() {
        let (m, profile) = armed()
        let s = m.update(tracks: [person(4, cx: 0.3, t: t0), person(5, cx: 0.7, t: t0)], markers: [marker(profile, cx: 0.3)], now: t0)
        XCTAssertEqual(s.state, .acquired)
        XCTAssertEqual(s.trackID, 4)
        XCTAssertEqual(s.userID, profile.userID)
        XCTAssertEqual(s.profileID, profile.id)
        XCTAssertEqual(s.verifiedBy, .marker)
        XCTAssertFalse(s.boxIsPredicted)
        XCTAssertNotEqual(s.userID, PersonRegistry.formatUserID(serial: 4), "the track number is not the user ID")
        let later = m.update(tracks: [person(4, cx: 0.3, t: t0 + 1), person(5, cx: 0.7, t: t0 + 1)], markers: [], now: t0 + 1)
        XCTAssertEqual(later.state, .following)
        XCTAssertEqual(later.trackID, 4)
        XCTAssertEqual(m.drainEvents().map(\.kind), [.acquisitionStarted, .acquired, .following])
    }

    func testMarkerOfAnotherPersonIsIgnored() throws {
        let (m, _) = armed()
        let stranger = try makeRegistry().create(nickname: "Other")
        m.update(tracks: [person(1, cx: 0.5, t: t0)], markers: [marker(stranger, cx: 0.5)], now: t0)
        XCTAssertEqual(m.status.state, .searching)
    }

    func testEveryPersonGetsAStableTrackIDAndOnlyOneIsTheTarget() {
        let tracker = TemporalObjectTracker()
        let (m, profile) = armed()
        var idsPerFrame: [[Int]] = []
        for i in 0..<30 {
            let t = t0 + Double(i) * frame
            let tracks = tracker.update(detections: [det(cx: 0.2, w: 0.15, t: t), det(cx: 0.5, w: 0.15, t: t), det(cx: 0.8, w: 0.15, t: t)],
                                        timestamp: t)
            idsPerFrame.append(tracks.sorted { $0.box.cx < $1.box.cx }.map(\.id))
            m.update(tracks: tracks, markers: i == 5 ? [marker(profile, cx: 0.5)] : [], now: t)
        }
        XCTAssertEqual(Set(idsPerFrame[0]).count, 3, "three people, three different temporary IDs")
        XCTAssertTrue(idsPerFrame.allSatisfy { $0 == idsPerFrame[0] }, "IDs stay with the same trajectories")
        XCTAssertEqual(m.status.state, .following)
        XCTAssertEqual(m.status.trackID, idsPerFrame[0][1], "only the marked person in the middle is the target")
    }

    func testOperatorSelectionAndNoAutomaticSwitching() {
        let (m, _) = armed()
        let scene = { (t: Double) in [person(1, cx: 0.25, t: t), person(2, cx: 0.75, w: 0.3, h: 0.8, t: t), person(9, cx: 0.5, t: t, label: "chair")] }
        m.update(tracks: scene(t0), markers: [], now: t0)
        XCTAssertFalse(m.selectByOperator(trackID: 9, tracks: scene(t0), now: t0), "a chair cannot be the target")
        XCTAssertFalse(m.selectByOperator(trackID: 77, tracks: scene(t0), now: t0), "unknown track")
        XCTAssertTrue(m.selectByOperator(trackID: 1, tracks: scene(t0), now: t0))
        XCTAssertEqual(m.status.verifiedBy, .operatorSelection)
        var t = t0
        for _ in 0..<60 { t += frame; m.update(tracks: scene(t), markers: [], now: t) }
        XCTAssertEqual(m.status.state, .following)
        XCTAssertEqual(m.status.trackID, 1, "the larger, closer-looking person 2 never takes over")
    }

    func testCrossingWithVisibleMarkerKeepsTarget() {
        let (m, profile, start) = lockedAndFollowing()
        var t = start
        for _ in 0..<30 {
            t += frame
            let s = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.55, t: t)], markers: [marker(profile, cx: 0.43)], now: t)
            XCTAssertEqual(s.trackID, 1)
            XCTAssertTrue(s.isLocked, "the marker sits clearly on track 1, so the overlap does not pause following")
        }
    }

    func testCleanCrossingPausesThenResumesSameTrackWithLowerConfidence() {
        let (m, _, start) = lockedAndFollowing()
        let controller = FollowGuidanceController()
        let before = m.status.associationConfidence
        var t = start
        for _ in 0..<15 {
            t += frame
            let s = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.55, t: t)], markers: [], now: t)
            XCTAssertEqual(s.state, .ambiguous)
            XCTAssertEqual(s.reason, .peopleOverlap)
            XCTAssertNotEqual(s.trackID, 2)
            XCTAssertEqual(controller.update(s, now: t).hold, .ambiguous, "no follow guidance while identity is uncertain")
        }
        t += frame
        let after = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.9, t: t)], markers: [], now: t)
        XCTAssertEqual(after.state, .following)
        XCTAssertEqual(after.trackID, 1)
        XCTAssertLessThan(after.associationConfidence, before, "resumed without a marker read: confidence is reduced")
        XCTAssertTrue(m.drainEvents().contains { $0.kind == .resumedAfterCrossing })
    }

    func testCrossingThatHidesTheTargetNeedsNewEvidence() {
        let (m, profile, start) = lockedAndFollowing()
        var t = start
        // Person 2 walks in front: the target is not detected for a few frames while they overlap.
        for i in 0..<12 {
            t += frame
            m.update(tracks: [person(1, cx: 0.5, observed: i < 3, t: t), person(2, cx: 0.52, t: t)], markers: [], now: t)
            XCTAssertEqual(m.status.state, .ambiguous)
        }
        // They separate. Track 1 is observed again, but it may now be the other person.
        for _ in 0..<30 {
            t += frame
            let s = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.9, t: t)], markers: [], now: t)
            XCTAssertEqual(s.state, .ambiguous)
            XCTAssertNil(s.trackID, "neither track is followed until the marker is read again")
        }
        t += frame
        let s = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.9, t: t)], markers: [marker(profile, cx: 0.9)], now: t)
        XCTAssertEqual(s.state, .acquired)
        XCTAssertEqual(s.trackID, 2, "the marker, not the old track number, decides")
        XCTAssertEqual(s.userID, profile.userID)
    }

    func testStrictModeRequiresMarkerAfterEveryCrossing() {
        var config = TargetConfig()
        config.resumeAfterCleanCrossing = false
        let (m, _, start) = lockedAndFollowing(config: config)
        var t = start + frame
        m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.55, t: t)], markers: [], now: t)
        t += frame
        let s = m.update(tracks: [person(1, cx: 0.5, t: t), person(2, cx: 0.9, t: t)], markers: [], now: t)
        XCTAssertEqual(s.state, .ambiguous)
        XCTAssertNil(s.trackID)
    }

    func testTrackerAmbiguityAfterGapPausesFollowing() {
        let (m, _, start) = lockedAndFollowing()
        let t = start + frame
        let s = m.update(tracks: [person(1, cx: 0.5, t: t, ambiguousAt: t)], markers: [], now: t)
        XCTAssertEqual(s.state, .ambiguous)
        XCTAssertEqual(s.reason, .trackerCouldNotProveIdentity)
        XCTAssertNil(s.trackID)
    }

    func testCrossingWithRealTrackerNeverFollowsTheOtherPerson() {
        let tracker = TemporalObjectTracker()
        let (m, profile) = armed()
        var targetID: Int?
        for i in 0..<150 {
            let t = t0 + Double(i) * frame
            let walkerX = 0.1 + 0.8 * Double(i) / 149           // walks left to right, passing in front of the target
            let tracks = tracker.update(detections: [det(cx: 0.5, cy: 0.5, w: 0.12, t: t), det(cx: walkerX, cy: 0.56, w: 0.12, t: t)],
                                        timestamp: t)
            let s = m.update(tracks: tracks, markers: i == 6 ? [marker(profile, cx: 0.5)] : [], now: t)
            if i == 6 { targetID = s.trackID; XCTAssertNotNil(targetID) }
            if i > 6, let followed = s.trackID, s.isLocked {
                XCTAssertEqual(followed, targetID, "frame \(i)")
                let box = tracks.first { $0.id == followed }!.box
                XCTAssertEqual(box.cx, 0.5, accuracy: 0.06, "frame \(i): the followed track is still the standing person")
            }
        }
    }

    func testTemporaryOcclusionIsPredictedNotConfirmed() {
        let (m, _, start) = lockedAndFollowing()
        let controller = FollowGuidanceController()
        var t = start
        for _ in 0..<15 {       // 0.5 s hidden
            t += frame
            let s = m.update(tracks: [person(1, cx: 0.5, observed: false, t: start)], markers: [], now: t)
            XCTAssertEqual(s.state, .temporarilyOccluded)
            XCTAssertTrue(s.boxIsPredicted)
            XCTAssertEqual(s.trackID, 1)
            let g = controller.update(s, now: t)
            XCTAssertEqual(g.hold, .predictedOnly)
            XCTAssertFalse(g.targetVisible)
            XCTAssertFalse(FollowSetpoint(g).valid)
        }
        XCTAssertLessThan(m.status.associationConfidence, 0.9)
        t += frame
        let back = m.update(tracks: [person(1, cx: 0.52, t: t)], markers: [], now: t)
        XCTAssertEqual(back.state, .following)
        XCTAssertFalse(back.boxIsPredicted)
        XCTAssertEqual(back.trackID, 1)
    }

    func testTargetLostStopsGuidanceAndNeverPicksSomeoneElse() {
        let (m, profile, start) = lockedAndFollowing()
        let controller = FollowGuidanceController()
        var t = start
        while t < start + 2 { t += frame; m.update(tracks: [person(1, cx: 0.5, observed: false, t: start)], markers: [], now: t) }
        XCTAssertEqual(m.status.state, .lost)
        XCTAssertEqual(m.status.reason, .hiddenTooLong)
        XCTAssertNil(m.status.trackID)
        XCTAssertNil(m.status.box)
        XCTAssertEqual(m.status.userID, profile.userID, "still the same registered person being searched for")
        // A different person now stands in the middle of the image for three seconds.
        for _ in 0..<90 {
            t += frame
            let s = m.update(tracks: [person(2, cx: 0.5, w: 0.4, h: 0.8, t: t)], markers: [], now: t)
            XCTAssertEqual(s.state, .lost)
            XCTAssertNil(s.trackID)
            let g = controller.update(s, now: t)
            XCTAssertEqual(g.hold, .targetLost)
            XCTAssertEqual(g.horizontal, .centered)
            XCTAssertFalse(FollowSetpoint(g).valid)
        }
        XCTAssertTrue(m.drainEvents().contains { $0.kind == .lost })
    }

    func testReacquisitionWithVerifiedMarkerOnNewTrack() {
        let (m, profile, start) = lockedAndFollowing()
        var t = start
        while t < start + 2 { t += frame; m.update(tracks: [], markers: [], now: t) }
        XCTAssertEqual(m.status.state, .lost)
        _ = m.drainEvents()
        t += frame
        let s = m.update(tracks: [person(12, cx: 0.3, t: t), person(13, cx: 0.7, t: t)], markers: [marker(profile, cx: 0.7)], now: t)
        XCTAssertEqual(s.state, .acquired)
        XCTAssertEqual(s.trackID, 13, "a new temporary track")
        XCTAssertEqual(s.userID, profile.userID, "the same persistent user")
        XCTAssertEqual(m.drainEvents().map(\.kind), [.reassociated])
    }

    func testAmbiguousMarkerAssociationsAreRejected() {
        let (m, profile) = armed()
        // The marker lies inside two overlapping person boxes, equally far from both centre lines.
        let two = [person(1, cx: 0.45, w: 0.3, t: t0), person(2, cx: 0.55, w: 0.3, t: t0)]
        var s = m.update(tracks: two, markers: [marker(profile, cx: 0.5)], now: t0)
        XCTAssertEqual(s.state, .ambiguous)
        XCTAssertEqual(s.reason, .markerOnSeveralPeople)
        XCTAssertNil(s.trackID)

        // The same code seen twice in one frame: one of them is a copy.
        let apart = [person(1, cx: 0.2, t: t0 + 1), person(2, cx: 0.8, t: t0 + 1)]
        s = m.update(tracks: apart, markers: [marker(profile, cx: 0.2), marker(profile, cx: 0.8)], now: t0 + 1)
        XCTAssertEqual(s.state, .ambiguous)
        XCTAssertEqual(s.reason, .duplicateMarker)
        XCTAssertNil(s.trackID)

        // A marker that is not on any detected person proves nothing.
        s = m.update(tracks: apart, markers: [marker(profile, cx: 0.5)], now: t0 + 1.1)
        XCTAssertNil(s.trackID)

        // Clearly on one of two overlapping boxes: accepted.
        let overlapping = [person(1, cx: 0.4, w: 0.3, t: t0 + 2), person(2, cx: 0.6, w: 0.3, t: t0 + 2)]
        s = m.update(tracks: overlapping, markers: [marker(profile, cx: 0.47)], now: t0 + 2)
        XCTAssertEqual(s.state, .acquired)
        XCTAssertEqual(s.trackID, 1)
    }

    func testChangingOrStoppingTargetDropsTheLock() throws {
        let (m, _, start) = lockedAndFollowing()
        let other = try makeRegistry().create(nickname: "Anna")
        m.assign(other, now: start)
        XCTAssertEqual(m.status.state, .searching)
        XCTAssertNil(m.status.trackID)
        XCTAssertEqual(m.status.userID, other.userID)
        m.stop(now: start)
        XCTAssertEqual(m.status.state, .unassigned)
        XCTAssertFalse(m.isArmed)
    }

    func testPerceptionResetLosesTarget() {
        let (m, _, start) = lockedAndFollowing()
        m.perceptionReset(now: start)
        XCTAssertEqual(m.status.state, .lost)
        XCTAssertEqual(m.status.reason, .perceptionReset)
    }
}

final class FollowGuidanceTests: XCTestCase {

    private func following(cx: Double, cy: Double = 0.5, confidence: Double = 0.9, w: Double = 0.2, h: Double = 0.4) -> TargetStatus {
        var s = TargetStatus()
        s.state = .following
        s.trackID = 1
        s.box = NormRect(cx: cx, cy: cy, w: w, h: h)
        s.associationConfidence = confidence
        return s
    }

    func testLeftRightCenteredAndNormalisedValues() {
        var g = FollowGuidanceController().update(following(cx: 0.5), now: t0)
        XCTAssertTrue(g.active)
        XCTAssertEqual(g.horizontal, .centered)
        XCTAssertEqual(g.horizontalOffset, 0, accuracy: 1e-9)
        XCTAssertEqual(g.targetCenterX!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.boundingBoxArea!, 0.08, accuracy: 1e-9)
        XCTAssertTrue(g.targetVisible)

        g = FollowGuidanceController().update(following(cx: 0.2), now: t0)
        XCTAssertEqual(g.horizontal, .left)
        XCTAssertEqual(g.horizontalOffset, -0.6, accuracy: 1e-9)

        g = FollowGuidanceController().update(following(cx: 0.8, cy: 0.8), now: t0)
        XCTAssertEqual(g.horizontal, .right)
        XCTAssertEqual(g.vertical, .down)
    }

    func testGuidancePausesWhenConfidenceIsInsufficient() {
        let c = FollowGuidanceController()
        let g = c.update(following(cx: 0.1, confidence: 0.2), now: t0)
        XCTAssertEqual(g.hold, .lowConfidence)
        XCTAssertFalse(g.active)
        XCTAssertEqual(g.horizontal, .centered, "no correction is suggested from an unreliable association")
        XCTAssertFalse(FollowSetpoint(g).valid)
        XCTAssertEqual(FollowSetpoint(g).yaw, 0)
        XCTAssertTrue(c.update(following(cx: 0.1, confidence: 0.8), now: t0 + 1).active)
    }

    func testSmoothingIgnoresASingleJump() {
        let c = FollowGuidanceController()
        _ = c.update(following(cx: 0.5), now: t0)
        let jump = c.update(following(cx: 0.9), now: t0 + 0.01)
        XCTAssertEqual(jump.horizontal, .centered)
        XCTAssertLessThan(jump.horizontalOffset, 0.1)
        let settled = c.update(following(cx: 0.9), now: t0 + 2)
        XCTAssertEqual(settled.horizontal, .right)
    }

    func testDeadZoneHysteresis() {
        var config = FollowConfig()
        config.smoothingSeconds = 0
        let c = FollowGuidanceController(config: config)
        XCTAssertEqual(c.update(following(cx: 0.565), now: t0).horizontal, .centered, "0.13 is inside the dead zone")
        XCTAssertEqual(c.update(following(cx: 0.6), now: t0 + 0.1).horizontal, .right)
        XCTAssertEqual(c.update(following(cx: 0.565), now: t0 + 0.2).horizontal, .right, "stays until clearly back inside")
        XCTAssertEqual(c.update(following(cx: 0.52), now: t0 + 0.3).horizontal, .centered)
    }

    func testApparentSizeCueIsRelativeAndSkippedAtFrameEdges() {
        var config = FollowConfig()
        config.smoothingSeconds = 0
        let c = FollowGuidanceController(config: config)
        XCTAssertEqual(c.update(following(cx: 0.5), now: t0).size, .steady)
        let smaller = c.update(following(cx: 0.5, w: 0.1, h: 0.2), now: t0 + 0.1)
        XCTAssertEqual(smaller.size, .smaller)
        XCTAssertEqual(smaller.relativeSize!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.update(following(cx: 0.5, w: 0.4, h: 1.0), now: t0 + 0.2).size, .steady, "box cut by the frame: no size claim")
    }

    func testEveryNonFollowingStateHoldsGuidance() {
        let c = FollowGuidanceController()
        let expected: [TargetTrackingState: GuidanceHold] = [
            .unassigned: .notTracking, .searching: .searching, .acquired: .settling,
            .temporarilyOccluded: .predictedOnly, .ambiguous: .ambiguous, .lost: .targetLost]
        for (state, hold) in expected {
            var s = following(cx: 0.1)
            s.state = state
            s.boxIsPredicted = state == .temporarilyOccluded
            let g = c.update(s, now: t0)
            XCTAssertEqual(g.hold, hold, state.rawValue)
            XCTAssertEqual(g.horizontal, .centered, state.rawValue)
        }
    }

    func testSimulatedAdapterIsLabelledAsSimulation() {
        let adapter = SimulatedVehicleAdapter()
        XCTAssertTrue(adapter.isSimulation)
        adapter.apply(FollowSetpoint(FollowGuidanceController().update(following(cx: 0.2), now: t0)), at: t0)
        XCTAssertEqual(adapter.last?.valid, true)
        XCTAssertLessThan(adapter.last!.yaw, 0)
    }
}

final class TargetPresentationTests: XCTestCase {

    private func present(_ state: TargetTrackingState, hold: GuidanceHold? = nil, language: SpeechLanguage = .english) -> TargetPresentation {
        var s = TargetStatus()
        s.state = state
        s.userID = "USER-0001"
        var g = FollowGuidance()
        g.hold = hold
        return TargetPresentation.make(s, guidance: g, language: language)
    }

    func testUIReflectsEveryTrackingState() {
        XCTAssertEqual(present(.acquired).title, "TARGET LOCKED")
        XCTAssertTrue(present(.acquired).detail.contains("USER-0001"))
        XCTAssertEqual(present(.following).title, "TARGET LOCKED")
        XCTAssertTrue(present(.following).detail.contains("tracking active"))
        XCTAssertEqual(present(.lost).title, "TARGET LOST")
        XCTAssertEqual(present(.lost).tone, .alert)
        XCTAssertEqual(present(.lost, language: .italian).title, "BERSAGLIO PERSO")

        // The accent-coloured target box is drawn only while there is an association to draw.
        let locked = TargetTrackingState.allCases.filter { present($0).showsLockedBox }
        XCTAssertEqual(Set(locked), [.acquired, .following, .temporarilyOccluded])
        // Only the occluded state shows a predicted box, and it says so.
        let predicted = TargetTrackingState.allCases.filter { present($0).boxIsPredicted }
        XCTAssertEqual(predicted, [.temporarilyOccluded])
        XCTAssertTrue(present(.temporarilyOccluded).detail.contains("not confirmed"))
        // Lost and uncertain are announced; steady following is not repeated.
        XCTAssertNotNil(present(.lost).announcement)
        XCTAssertNotNil(present(.ambiguous).announcement)
        XCTAssertNotNil(present(.acquired).announcement)
        XCTAssertNil(present(.following).announcement)
        XCTAssertEqual(present(.following, hold: .lowConfidence).tone, .caution)
        // Titles are distinct in words, never by colour alone.
        XCTAssertEqual(Set(TargetTrackingState.allCases.map { present($0).title }).count, 6)
    }

    func testTrackTagFormat() {
        XCTAssertEqual(person(7, cx: 0.5, t: t0).trackTag, "TRACK-007")
    }
}
