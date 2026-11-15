import XCTest
@testable import SharedSightCore

/// "Listen only" walk-through. The recorded, SYNTHETIC scenario of the demo (Server/sim/record.mjs) is replayed through
/// the same decision and wording code the iPhone runs, and through a model of the app's speech queue. What comes out is
/// what a user who cannot see the screen would hear, with the times at which they would hear it. The simulated truth is
/// used only to judge it. Set BLIND_WALK_PRINT=1 to print the whole transcript.
final class BlindWalkTests: XCTestCase {

    // MARK: Recording format

    private struct Walk: Decodable {
        struct Wall: Decodable { var ax, az, bx, bz, y0, y1: Double; var kind: String }
        struct Object: Decodable { var id: Int; var label: String; var c: Double; var box: [Double]; var p: [Double]?; var s: Double? }
        struct Truth: Decodable { var key: String; var label: String; var x: Double; var z: Double; var user: Bool; var other: Bool }
        struct Frame: Decodable { var t: Double; var m: [Double]; var fov: Double; var objects: [Object]; var advisories: [ServerAdvisory]; var truth: [Truth] }
        var phones: Int
        var rate: Double
        var walls: [Wall]
        var frames: [Frame]
    }

    private func load(_ name: String) throws -> Walk {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("recording \(name).json not present (node Server/sim/record.mjs)") }
        return try JSONDecoder().decode(Walk.self, from: data)
    }

    // MARK: The app's speech queue (same policy as AudioFeedbackEngine: one voice, one pending slot, nothing stale)

    private struct Utterance { var start: Double; var end: Double; var text: String; var intent: AlertIntent; var queuedFor: Double }

    /// The app's real speech queue (RevocableSpeechQueue) driving a simulated synthesizer, with the same lifecycle
    /// callbacks the app sends back to the decision engine. Only the speaking rate is modelled.
    private final class Listener {
        var heard: [Utterance] = []
        var neverSaid: [(t: Double, text: String, why: String)] = []
        private var queue = RevocableSpeechQueue()
        private let builder: AlertPhraseBuilder
        private let alerts: ObstacleAlertDecisionEngine
        private let origin: Double
        private var current: (item: SpeechItem, end: Double, index: Int?)?
        private var startedIDs = Set<UUID>(), startedDeliveries = Set<UUID>()
        private var texts: [UUID: String] = [:]
        private var dropped: [(t: Double, text: String, identity: String)] = []
        private var startedIdentities: [(t: Double, identity: String)] = []
        init(language: SpeechLanguage, alerts: ObstacleAlertDecisionEngine, origin: Double) {
            builder = AlertPhraseBuilder(language: language); self.alerts = alerts; self.origin = origin
        }

        /// About 15 characters per second: the app's default rate (1.12 x the system default) for Italian and English voices.
        static func duration(_ text: String) -> Double { 0.25 + Double(text.count) / 15 }

        private func perform(_ actions: [SpeechQueueAction], at t: Double) {
            for action in actions {
                switch action {
                case let .lifecycle(intent, phase):
                    alerts.delivery(intent, phase: phase, at: t)
                    if phase == .discarded, let stamp = intent.stamp, !startedDeliveries.contains(stamp.deliveryID), let text = texts[stamp.deliveryID] {
                        dropped.append((t, text, stamp.identity))
                    }
                case let .stop(id):
                    guard let c = current, c.item.id == id else { continue }
                    if let i = c.index { heard[i].end = t - origin }
                    current = nil
                    perform(queue.didEnd(id, cancelled: true, now: t, validation: alerts.validationSnapshot), at: t)
                case let .speak(item):
                    current = (item, t + Self.duration(item.text), nil)
                    let before = queue.started
                    perform(queue.didStart(item.id, now: t, validation: alerts.validationSnapshot), at: t)
                    if queue.started && !before, current?.item.id == item.id {
                        startedIDs.insert(item.id)
                        if let stamp = item.intent.stamp { startedDeliveries.insert(stamp.deliveryID); startedIdentities.append((t, stamp.identity)) }
                        heard.append(Utterance(start: t - origin, end: t - origin + Self.duration(item.text), text: item.text,
                                               intent: item.intent, queuedFor: t - item.queuedAt))
                        current?.index = heard.count - 1
                    }
                }
            }
        }
        /// Lets the simulated voice finish whatever ends before `now`.
        func advance(to now: Double) {
            while let c = current, c.end <= now {
                current = nil
                perform(queue.didEnd(c.item.id, cancelled: false, now: c.end, validation: alerts.validationSnapshot), at: c.end)
            }
        }
        func handle(_ intents: [AlertIntent], now: Double) {
            perform(queue.revalidate(now: now, validation: alerts.validationSnapshot), at: now)
            for intent in intents {
                let item = SpeechItem(text: builder.phrase(for: intent), intent: intent, now: now)
                if let d = intent.stamp?.deliveryID { texts[d] = item.text }
                let actions = queue.submit(item, now: now, validation: alerts.validationSnapshot)
                perform(actions, at: now)
            }
        }
        /// A pending sentence replaced by a newer version of the same alert, spoken soon after, was not lost.
        func finish(at now: Double) {
            advance(to: now + 60)
            for d in dropped where !startedIdentities.contains(where: { $0.identity == d.identity && $0.t >= d.t && $0.t - d.t <= 2 }) {
                neverSaid.append((d.t - origin, d.text, "dropped by the queue"))
            }
        }
    }

    // MARK: Replay

    private struct Result {
        var walk: Walk
        var heard: [Utterance]
        var neverSaid: [(t: Double, text: String, why: String)]
        var summaries: [(t: Double, text: String)]        // "What is around me?" asked every 15 s
    }

    private func replay(_ name: String, language: SpeechLanguage = .italian, verbosity: Verbosity = .normal) throws -> Result {
        let walk = try load(name)
        let builder = AlertPhraseBuilder(language: language)
        let memory = ObstacleMemoryEngine(), relevance = SpatialRelevanceEstimator(), ground = GroundTrackMemory()
        let resolver = HiddenObjectResolver(), alerts = ObstacleAlertDecisionEngine(), listener = Listener(language: language, alerts: alerts, origin: 1000)
        let reliability = healthyReport()
        var preferences = AlertPreferences(); preferences.verbosity = verbosity
        let walls = walk.walls.map { WallSegment(ax: $0.ax, az: $0.az, bx: $0.bx, bz: $0.bz, y0: $0.y0, y1: $0.y1, kind: WallSegment.Kind(rawValue: $0.kind) ?? .wall) }
        var known: [Int: (snapshot: TrackSnapshot, first: Double, hits: Int)] = [:]
        var summaries: [(Double, String)] = []
        var nextSummary = 15.0

        for f in walk.frames {
            let now = 1000 + f.t
            let pose = Pose(columnMajor: f.m)
            // Local tracks exactly as the phone's tracker would hand them over (the tracker itself is tested elsewhere).
            var tracks: [TrackSnapshot] = []
            var positions: [GroundObservation] = []
            var seen = Set<Int>()
            for o in f.objects {
                seen.insert(o.id)
                let box = NormRect(x: o.box[0], y: o.box[1], w: o.box[2], h: o.box[3])
                let previous = known[o.id]
                let dt = previous.map { now - $0.snapshot.lastObserved } ?? 0
                let vx = dt > 0 ? (box.cx - previous!.snapshot.box.cx) / dt : 0, vy = dt > 0 ? (box.cy - previous!.snapshot.box.cy) / dt : 0
                let scale = dt > 0 ? (box.w / max(previous!.snapshot.box.w, 0.01) - 1 + box.h / max(previous!.snapshot.box.h, 0.01) - 1) / dt : 0
                let hits = (previous?.hits ?? 0) + 1
                let snapshot = TrackSnapshot(id: o.id, classIndex: 0, label: o.label, box: box, velocityX: vx, velocityY: vy, scaleRate: scale,
                                             confidence: o.c, hits: hits, consecutiveMisses: 0, firstSeen: previous?.first ?? now, lastObserved: now,
                                             observedThisFrame: true, confirmed: hits >= 3, identityAmbiguous: false, positionSigma: 0.01,
                                             lastObservationID: nil, hasMask: false)
                known[o.id] = (snapshot, previous?.first ?? now, hits)
                tracks.append(snapshot)
                if let p = o.p, let s = o.s { positions.append(GroundObservation(trackID: o.id, label: o.label, position: Vec3(p[0], p[1], p[2]), sigma: s)) }
            }
            for (id, k) in known where !seen.contains(id) {
                if now - k.snapshot.lastObserved > 1.5 { known[id] = nil; continue }       // the tracker drops it
                var s = k.snapshot; s.observedThisFrame = false; s.consecutiveMisses += 1
                tracks.append(s)
            }
            let entries = memory.update(tracks: tracks, now: now)
            let camera = CameraContext(horizontalFOVDeg: f.fov, pitchDeg: 0, rollDeg: 0, angularRate: 0.03, steady: true)
            var candidates: [LocalCandidate] = []
            var items: [SurroundingsItem] = []
            for e in entries where e.state != .lost {
                var distance: DistanceMeasurement?
                if let p = positions.first(where: { $0.trackID == e.id }) {
                    var d = p.position - pose.translation; d.y = 0
                    distance = DistanceMeasurement(meters: d.length, sigma: p.sigma, method: .groundPlaneRaycast)
                }
                let a = relevance.assess(e, camera: camera, distance: distance)
                candidates.append(LocalCandidate(entry: e, relevance: a))
                if e.track.confirmed { items.append(SurroundingsItem(label: e.track.label, state: e.state, sector: a.sector, distance: a.distance)) }
            }
            let estimates = ground.update(observations: positions, observedTrackIDs: seen, camera: FloorCamera(pose: pose), fovDeg: f.fov, walls: walls, now: now)
            // Same path as the app: the reply is stamped with its round trip (30 ms on a LAN) when it arrives.
            let received = ServerReply(advisories: f.advisories).atReceipt(roundTrip: 0.03)
            let hidden = resolver.resolve(advisories: received, advisoryAge: 0.07, worldFromReference: .identity, estimates: estimates,
                                          worldFromCamera: pose, trackingNormal: true,
                                          aheadHalfAngleDeg: relevance.aheadHalfAngle(horizontalFOVDeg: f.fov))
            listener.advance(to: now)
            let intents = alerts.decide(local: candidates, hidden: hidden, reliability: reliability, preferences: preferences, now: now)
            listener.handle(intents, now: now)
            if f.t >= nextSummary {
                nextSummary += 15
                summaries.append((f.t, builder.surroundings(perception: .reliable, local: items, peers: [], hidden: hidden)))
            }
        }
        listener.finish(at: 1000 + (walk.frames.last?.t ?? 0))
        return Result(walk: walk, heard: listener.heard, neverSaid: listener.neverSaid, summaries: summaries)
    }

    // MARK: Judging against the simulated truth

    private func place(_ t: Walk.Truth, in f: Walk.Frame) -> (meters: Double, bearing: Double, sector: Sector) {
        let located = HiddenObjectResolver.locate(Vec3(t.x, 0, t.z), from: Pose(columnMajor: f.m),
                                                  aheadHalfAngleDeg: SpatialRelevanceEstimator().aheadHalfAngle(horizontalFOVDeg: f.fov))!
        return (located.meters, located.bearing ?? 0, located.sector ?? .ahead)
    }
    private func frame(_ walk: Walk, at t: Double) -> Walk.Frame { walk.frames[min(max(Int((t * walk.rate).rounded()), 0), walk.frames.count - 1)] }
    private func spokenSector(_ u: Utterance) -> Sector? { u.intent.sector }
    private func isHiddenKind(_ u: Utterance) -> (label: String, measured: Bool)? {
        switch u.intent.kind {
        case let .hiddenSeenByOther(label, _): return (label, true)
        case let .hiddenEstimate(label, _): return (label, false)
        default: return nil
        }
    }

    private func transcript(_ r: Result) -> String {
        var lines: [String] = []
        let total = r.walk.frames.last?.t ?? 0
        lines.append("=== \(r.walk.phones) phone(s), \(Int(total)) s — what the user hears ===")
        for u in r.heard {
            let f = frame(r.walk, at: u.start)
            let truth = f.truth.map { t -> String in
                let p = place(t, in: f)
                return "\(t.key) \(String(format: "%.1f", p.meters))m \(p.sector.rawValue)\(t.user ? " [own camera]" : t.other ? " [other phone]" : " [nobody]")"
            }.joined(separator: "; ")
            lines.append(String(format: "%5.1f–%4.1f  %@%@", u.start, u.end, u.text, u.queuedFor > 0.05 ? String(format: "   (waited %.1f s)", u.queuedFor) : ""))
            lines.append("             truth: \(truth)")
        }
        let speaking = r.heard.reduce(0) { $0 + ($1.end - $1.start) }
        for n in r.neverSaid { lines.append(String(format: "  (never said at %5.1f: %@ — %@)", n.t, n.text, n.why)) }
        lines.append(String(format: "--- %d utterances, voice busy %.0f %% of the time; %d never said (%@)", r.heard.count, 100 * speaking / max(total, 1), r.neverSaid.count,
                            Dictionary(grouping: r.neverSaid, by: \.why).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")))
        for s in r.summaries { lines.append(String(format: "%5.1f  [asked: what is around me?] %@", s.t, s.text)) }
        return lines.joined(separator: "\n")
    }

    private func report(_ r: Result) { if ProcessInfo.processInfo.environment["BLIND_WALK_PRINT"] != nil { print(transcript(r)) } }

    /// Common expectations for any walk: wording never promises a clear way, and the voice leaves room to listen.
    private func checkListenability(_ r: Result, maxVoiceShare: Double, file: StaticString = #filePath, line: UInt = #line) {
        let total = r.walk.frames.last?.t ?? 1
        for u in r.heard {
            let lower = u.text.lowercased()
            XCTAssertFalse(lower.contains("via libera") || lower.contains("way is clear") || lower.contains("path is clear"), u.text, file: file, line: line)
            XCTAssertLessThan(u.queuedFor, 1.2 + 1e-6, "nothing that waited longer than 1.2 seconds is spoken", file: file, line: line)
        }
        let speaking = r.heard.reduce(0) { $0 + ($1.end - $1.start) }
        // The recorded scene is deliberately crowded (two people and a dog passing the user every few seconds).
        XCTAssertLessThan(speaking / total, maxVoiceShare, "the voice must leave room to hear the surroundings", file: file, line: line)
        let decided = r.heard.count + r.neverSaid.count
        XCTAssertLessThanOrEqual(Double(r.neverSaid.count), 0.25 * Double(decided), "what is decided is, almost always, also heard", file: file, line: line)
        for start in stride(from: 0.0, to: total, by: 1.0) {
            let n = r.heard.filter { $0.start >= start && $0.start < start + 10 }.count
            XCTAssertLessThanOrEqual(n, 4, "at most four announcements in any ten seconds (window at \(start) s)", file: file, line: line)
        }
        // The same sentence is never said twice within four seconds of silence.
        for (i, u) in r.heard.enumerated() {
            for v in r.heard[(i + 1)...] where v.start - u.end < 4 { XCTAssertNotEqual(u.text, v.text, "repeated at \(v.start) s", file: file, line: line) }
        }
    }

    // MARK: The walks

    func testThreePhonesThePersonBehindTheDoorIsAnnouncedFromTheOtherPhonesView() throws {
        let r = try replay("walk-3")
        report(r)
        checkListenability(r, maxVoiceShare: 0.72)

        // Every time Anna leaves the user's own view while another phone keeps seeing her, the user is told promptly.
        var handoffs: [Double] = []
        for (i, f) in r.walk.frames.enumerated() where i > 0 {
            let before = r.walk.frames[i - 1].truth.first { $0.key == "anna" }!, after = f.truth.first { $0.key == "anna" }!
            if before.user && !after.user && after.other { handoffs.append(f.t) }
        }
        XCTAssertFalse(handoffs.isEmpty)
        var delays: [Double] = []
        for t in handoffs {
            // Skip a blink: she must stay out of the user's view for at least two seconds for it to matter.
            let stillHidden = r.walk.frames.filter { $0.t > t && $0.t <= t + 2 }.allSatisfy { !($0.truth.first { $0.key == "anna" }!.user) }
            guard stillHidden else { continue }
            let told = r.heard.first { u in u.start >= t - 0.5 && u.start <= t + 6 && isHiddenKind(u)?.label == "person" && isHiddenKind(u)?.measured == true }
            XCTAssertNotNil(told, "person hidden from the user at \(t) s but seen by another phone: must be announced")
            if let told { delays.append(told.start - t) }
        }
        XCTAssertFalse(delays.isEmpty)
        let sorted = delays.sorted()
        XCTAssertLessThan(sorted[sorted.count / 2], 1.5, "usually said within a second and a half of losing sight (measured \(delays))")
        XCTAssertLessThan(sorted.last ?? 99, 5.0, "and never later than five seconds, even when the voice is busy with something nearer")

        // What is said about a measured hidden object points the right way.
        var checked = 0, right = 0
        for u in r.heard {
            guard let kind = isHiddenKind(u), kind.measured, let said = spokenSector(u) else { continue }
            let f = frame(r.walk, at: u.start)
            let candidates = f.truth.filter { $0.label == kind.label && !$0.user }.map { place($0, in: f) }
            guard !candidates.isEmpty else { continue }
            checked += 1
            // Right if some hidden object of that kind is in the spoken sector, allowing 12 degrees at the sector borders.
            let ok = candidates.contains { c in
                if c.sector == said { return true }
                let border: [Double] = [11, -11, 135, -135]
                return border.contains { abs(c.bearing - $0) <= 12 }
            }
            if ok { right += 1 }
        }
        XCTAssertGreaterThan(checked, 2)
        XCTAssertEqual(right, checked, "every spoken direction of a measured hidden object matches the simulated truth")
    }

    func testOnePhoneHiddenMoversAreSpokenAsEstimatesNeverAsFacts() throws {
        let r = try replay("walk-1")
        report(r)
        checkListenability(r, maxVoiceShare: 0.55)
        let hidden = r.heard.filter { isHiddenKind($0) != nil }
        XCTAssertFalse(hidden.isEmpty, "a mover that walks out of sight is not silently forgotten")
        for u in hidden {
            XCTAssertEqual(isHiddenKind(u)?.measured, false, "with one phone nothing can be 'seen by another device'")
            XCTAssertTrue(u.text.contains("forse") || !u.text.contains("metr"), "a distance is only ever given as a guess: \(u.text)")
            XCTAssertTrue(u.text.contains("non più visibile"), u.text)
        }
        // An estimate is never spoken about something the user's own camera is looking at.
        for u in hidden {
            let f = frame(r.walk, at: u.start - u.queuedFor)
            let label = isHiddenKind(u)!.label
            XCTAssertTrue(f.truth.contains { $0.label == label && !$0.user }, "\(u.text) at \(u.start) s")
        }
    }

    func testMinimalVerbosityKeepsMeasurementsAndDropsEstimates() throws {
        let one = try replay("walk-1", verbosity: .minimal)
        XCTAssertTrue(one.heard.allSatisfy { isHiddenKind($0) == nil }, "estimates are optional")
        let three = try replay("walk-3", verbosity: .minimal)
        XCTAssertTrue(three.heard.contains { isHiddenKind($0)?.measured == true }, "what another phone measures is not")
        XCTAssertTrue(three.heard.allSatisfy { isHiddenKind($0)?.measured != false })
    }

    func testEnglishWalkReadsTheSameWay() throws {
        let r = try replay("walk-3", language: .english)
        checkListenability(r, maxVoiceShare: 0.72)
        XCTAssertTrue(r.heard.contains { $0.text.contains("from another phone") })
    }
}
