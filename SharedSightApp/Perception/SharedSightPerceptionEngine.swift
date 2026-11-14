import Foundation
import QuartzCore
import CoreImage
import SharedSightCore

/// Orchestrates the perception subsystem: camera -> detector -> motion -> tracker -> memory -> relevance ->
/// reliability -> alert decision -> speech, plus the collaboration engine. One frame is processed at a time;
/// frames arriving while busy are skipped (latest-frame-wins), so latency cannot accumulate.
final class SharedSightPerceptionEngine: CameraFrameProviderDelegate {

    struct Metrics {
        var cameraFPS = 0.0, processedFPS = 0.0
        var detectionMs = 0.0, segmentationMs = 0.0, decisionDelayMs = 0.0
        var speechDelayMs: Double?
        var peerObservationAgeMs: Double?
        var droppedFrames = 0, skippedFrames = 0
        var memoryMB = 0.0
        var thermal = "nominal"
    }

    struct Snapshot {
        var cameraState: CameraState = .starting
        var providerName = ""
        var paused = false
        var reliability = ReliabilityReport(features: [:])
        var entries: [MemoryEntry] = []
        var relevance: [Int: RelevanceAssessment] = [:]
        var masks: [Int: ObstacleSegmentationEngine.TrackMask] = [:]
        var peers: [ResolvedPeerObservation] = []
        var linkState: PeerLinkState = .off
        var peerCount = 0
        var anchorReady = false
        var spatialMode = false
        var genericObstruction: RegionKind = .unknown
        var metrics = Metrics()
        var modelID = ""
        var modelError: String?
        var lastInferenceError: String?
        var lastSpoken = ""
        var audioReady = false
        var preview: CGImage?
    }

    // Modules
    let detector = NeuralObjectDetector()
    let segmentation = ObstacleSegmentationEngine()
    let tracker = TemporalObjectTracker()
    let memory = ObstacleMemoryEngine()
    let relevance = SpatialRelevanceEstimator()
    let reliabilityEngine = PerceptionReliabilityEngine()
    let alerts = ObstacleAlertDecisionEngine()
    let motion = CameraMotionEstimator()
    let audio = AudioFeedbackEngine()
    let collaboration = SharedSightCollaborationEngine()
    let transport = MultipeerTransport()
    private var provider: CameraFrameProviding = CameraFrameProvider()

    var onSnapshot: ((Snapshot) -> Void)?
    var previewEnabled = false

    private let work = DispatchQueue(label: "sharedsight.perception", qos: .userInitiated)
    private let busyLock = NSLock()
    private var busy = false
    private var timer: DispatchSourceTimer?
    private let ciContext = CIContext()

    // State owned by `work`
    private var preferences = AlertPreferences()
    private var paused = false
    private var spatialMode = false
    private var entries: [MemoryEntry] = []
    private var assessments: [Int: RelevanceAssessment] = [:]
    private var worldPositions: [Int: (position: Vec3, sigma: Double)] = [:]
    private var masks: [Int: ObstacleSegmentationEngine.TrackMask] = [:]
    private var lastSpatial: SpatialFrameInfo?
    private var lastFrameTime: Timestamp?
    private var lastArrival: Timestamp?
    private var quality: (mean: Double, spread: Double)?
    private var reading: CameraMotionEstimator.Reading?
    private var knownTrackIDs = Set<Int>()
    private var birthRate = 0.0
    private var inferenceFailures = 0
    private var lastInferenceError: String?
    private var metrics = Metrics()
    private var lastShare: Timestamp = 0
    private var lastPublish: Timestamp = 0
    private var lastPreview: Timestamp = 0
    private var preview: CGImage?
    private var anchorWasReady = false
    private var lastSpoken = ""

    // MARK: Lifecycle (call from the main thread)

    func start() {
        audio.prepare()
        audio.onSpoken = { [weak self] text in self?.work.async { self?.lastSpoken = text } }
        transport.onPeerConnected = { [weak self] pid in self?.work.async { self?.peerConnected(pid) } }
        transport.onPeerDisconnected = { [weak self] pid in self?.work.async { self?.collaboration.peerDisconnected(pid, now: CACurrentMediaTime()) } }
        transport.onMessage = { [weak self] message, pid in self?.work.async { self?.received(message, from: pid) } }
        work.async {
            self.detector.load()
            self.motion.start()
            self.provider.delegate = self
            self.provider.start()
            let t = DispatchSource.makeTimerSource(queue: self.work)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [weak self] in self?.watchdog() }
            t.resume()
            self.timer = t
        }
    }

    func setPaused(_ on: Bool) {
        work.async {
            guard on != self.paused else { return }
            self.paused = on
            if on { self.provider.stop(); self.motion.stop() } else { self.resetPerception(); self.motion.start(); self.provider.start() }
        }
    }

    func setPreferences(_ p: AlertPreferences) { work.async { self.preferences = p } }

    /// Switches between the AVFoundation provider and the ARKit provider (needed for any metric / shared-space claim).
    func setSpatialMode(_ on: Bool) {
        work.async {
            guard on != self.spatialMode else { return }
            self.provider.stop()
            self.provider.delegate = nil
            self.spatialMode = on && ARFrameProvider.isSupported
            self.provider = self.spatialMode ? ARFrameProvider() : CameraFrameProvider()
            self.provider.delegate = self
            self.resetPerception()
            if !self.paused { self.provider.start() }
        }
    }

    /// Collaboration is opt-in. Turning it off stops the transport and drops peer data immediately.
    func setCollaboration(_ on: Bool, sessionCode: String) {
        work.async {
            let farewell = self.collaboration.setConsent(on)
            if on { self.transport.start(sessionCode: sessionCode, displayName: self.collaboration.cameraID) }
            else { self.transport.send(farewell); self.transport.stop() }
        }
    }

    private func resetPerception() {
        tracker.reset(); memory.reset(); alerts.reset()
        entries = []; assessments = [:]; worldPositions = [:]; masks = [:]; knownTrackIDs = []
        lastFrameTime = nil; lastSpatial = nil; quality = nil; reading = nil
    }

    // MARK: Collaboration plumbing (on `work`)

    private func peerConnected(_ pid: String) { transport.send(collaboration.peerConnected(pid, now: CACurrentMediaTime()), to: pid) }

    private func received(_ message: PeerMessage, from pid: String) {
        transport.send(collaboration.receive(message, from: pid, now: CACurrentMediaTime()), to: pid)
    }

    // MARK: CameraFrameProviderDelegate

    func frameProvider(didChangeState state: CameraState) { work.async { self.decideAndPublish(now: CACurrentMediaTime()) } }

    func frameProvider(didOutput frame: CameraFrame) {
        busyLock.lock()
        if busy { metrics.skippedFrames += 1; busyLock.unlock(); return }
        busy = true
        busyLock.unlock()
        work.async {
            self.process(frame)
            self.busyLock.lock(); self.busy = false; self.busyLock.unlock()
        }
    }

    // MARK: Per-frame pipeline

    private func process(_ frame: CameraFrame) {
        guard !paused else { return }
        let arrival = CACurrentMediaTime()
        if let last = lastArrival, arrival > last { metrics.processedFPS = ema(metrics.processedFPS, 1 / (arrival - last)) }
        lastArrival = arrival
        if let last = lastFrameTime, frame.timestamp > last { metrics.cameraFPS = ema(metrics.cameraFPS, 1 / (frame.timestamp - last)) }

        quality = ImageQualityProbe.measure(frame.pixelBuffer)
        let r = motion.consume(horizontalFOVDeg: frame.horizontalFOVDeg, aspect: Double(frame.uprightSize.width / frame.uprightSize.height))
        reading = r

        var output: NeuralObjectDetector.Output?
        if detector.isLoaded {
            do {
                let o = try detector.detect(frame)
                output = o
                inferenceFailures = 0
                metrics.detectionMs = ema(metrics.detectionMs, o.latency * 1000)
            } catch {
                inferenceFailures += 1
                lastInferenceError = String(describing: error)
            }
        }
        // A covered / black image yields no trustworthy detections; nothing is fed to the tracker.
        let covered = quality.map { $0.mean < reliabilityEngine.config.coveredLuma && $0.spread < reliabilityEngine.config.coveredSpread } ?? false
        let detections = covered ? [] : (output?.detections ?? [])

        let tracks = tracker.update(detections: detections, timestamp: frame.timestamp, cameraMotion: r.motion)
        let ids = Set(tracks.map(\.id))
        let dt = max(frame.timestamp - (lastFrameTime ?? frame.timestamp), 1e-3)
        birthRate = ema(birthRate, Double(ids.subtracting(knownTrackIDs).count) / dt, 0.1)
        knownTrackIDs = ids

        entries = memory.update(tracks: tracks, now: frame.timestamp, cameraMotionReliable: r.motion.reliable)
        let camera = CameraContext(horizontalFOVDeg: frame.horizontalFOVDeg, pitchDeg: r.pitchDeg, rollDeg: r.rollDeg,
                                   angularRate: r.angularRate, steady: r.steady)
        assessments = [:]
        worldPositions = [:]
        for e in entries where e.state != .lost { assessments[e.id] = relevance.assess(e, camera: camera) }

        // Metric position only from real geometry: ray through the box's ground-contact point onto a detected floor plane.
        if let spatial = frame.spatial, spatial.trackingNormal {
            let top = entries.filter { $0.isCurrentEvidence }.sorted { (assessments[$0.id]?.score ?? 0) > (assessments[$1.id]?.score ?? 0) }.prefix(4)
            for e in top where e.track.box.maxY < 0.97 {   // bottom edge cut off by the frame => contact point not visible
                guard let p = spatial.groundPoint(e.track.box.cx, e.track.box.maxY) else { continue }
                var d = p - spatial.worldFromCamera.translation
                d.y = 0
                let meters = d.length
                guard meters > 0.2, meters < 12 else { continue }
                let sigma = 0.15 + 0.05 * meters   // heuristic uncertainty model, not a calibrated one
                worldPositions[e.id] = (p, sigma)
                assessments[e.id] = relevance.assess(e, camera: camera, distance: DistanceMeasurement(meters: meters, sigma: sigma, method: .groundPlaneRaycast))
            }
        }
        // Keep poses only: the raycast closure references the ARFrame and must not outlive this frame.
        var kept = frame.spatial
        kept?.groundPoint = { _, _ in nil }
        lastSpatial = kept

        if let o = output, !covered {
            masks = segmentation.update(tracks: tracks, priority: assessments.mapValues(\.score), output: o, now: frame.timestamp)
            metrics.segmentationMs = ema(metrics.segmentationMs, segmentation.lastLatency * 1000)
        } else { masks = [:] }

        lastFrameTime = frame.timestamp
        let now = CACurrentMediaTime()
        metrics.decisionDelayMs = ema(metrics.decisionDelayMs, (now - frame.timestamp) * 1000)

        if previewEnabled, now - lastPreview > 0.15 {
            lastPreview = now
            let image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
                .transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
            preview = ciContext.createCGImage(image, from: image.extent)
        } else if !previewEnabled { preview = nil }

        decideAndPublish(now: now)
    }

    /// Runs when no frame is being processed, so that camera loss is noticed even though no frames arrive.
    private func watchdog() {
        let now = CACurrentMediaTime()
        if lastFrameTime == nil || now - (lastFrameTime ?? 0) > 0.4 { decideAndPublish(now: now) }
    }

    private func decideAndPublish(now: Timestamp) {
        var i = ReliabilityInputs()
        i.camera = paused ? .paused : provider.state
        i.frameAge = lastFrameTime.map { now - $0 }
        i.modelLoaded = detector.isLoaded
        i.modelSupportsMasks = detector.supportsMasks
        i.recentInferenceFailures = inferenceFailures
        i.inferenceLatency = metrics.detectionMs > 0 ? metrics.detectionMs / 1000 : nil
        i.processingDelay = metrics.decisionDelayMs > 0 ? metrics.decisionDelayMs / 1000 : nil
        i.meanLuma = quality?.mean
        i.lumaSpread = quality?.spread
        i.angularRate = reading?.angularRate
        i.pitchDeg = reading?.pitchDeg
        i.rollDeg = reading?.rollDeg
        i.trackBirthsPerSecond = birthRate
        i.depthSourceAvailable = lastSpatial != nil          // ARKit plane raycast (LiDAR-assisted when present)
        i.deviceHasDepthSensor = false                       // generic obstruction sensing is not implemented: stays UNKNOWN
        i.worldTrackingNormal = lastSpatial?.trackingNormal ?? false
        i.collaborationEnabled = collaboration.consentGiven
        i.peerConnected = collaboration.connectedPeerCount > 0
        i.peerLastHeardAge = collaboration.lastHeardAge(now: now)
        let anchorReady = lastSpatial?.worldFromAnchor != nil && (lastSpatial?.trackingNormal ?? false)
        i.sharedAnchorValid = anchorReady
        i.audioReady = audio.ready
        i.audioMuted = audio.muted
        let thermal = ProcessInfo.processInfo.thermalState
        i.thermalSerious = thermal == .serious || thermal == .critical
        let report = reliabilityEngine.evaluate(i)

        let spatialState = LocalSpatialState(anchorID: lastSpatial?.anchorID, worldFromAnchor: lastSpatial?.worldFromAnchor,
                                             anchorFixTime: lastSpatial?.anchorFixTime, worldFromCamera: lastSpatial?.worldFromCamera,
                                             trackingNormal: lastSpatial?.trackingNormal ?? false)
        let peers = collaboration.resolve(spatial: spatialState, now: now)

        // Ages are re-based to `now` so that a stalled camera cannot keep old observations "fresh".
        let stall = max(0, now - (lastFrameTime ?? now))
        let candidates: [LocalCandidate] = paused ? [] : entries.compactMap { e -> LocalCandidate? in
            guard let a = assessments[e.id] else { return nil }
            var aged = e
            aged.ageSinceObserved += stall
            return LocalCandidate(entry: aged, relevance: a)
        }
        var events = collaboration.drainEvents()
        if anchorReady && !anchorWasReady { events.append(.sharedReferenceReady) }
        anchorWasReady = anchorReady

        let intents = alerts.decide(local: candidates, peers: peers, reliability: report, events: events, preferences: preferences, now: now)
        if !intents.isEmpty { DispatchQueue.main.async { self.audio.handle(intents) } }

        // Share direct observations (metadata only) at most 5 times per second.
        if collaboration.consentGiven, now - lastShare >= 0.2, !paused {
            lastShare = now
            let outgoing = entries.filter { $0.isCurrentEvidence && $0.ageSinceObserved + stall < 0.5 }.map { e in
                OutgoingObservation(entry: e, bearingDeg: assessments[e.id]?.bearingDeg,
                                    worldPosition: worldPositions[e.id]?.position, positionSigma: worldPositions[e.id]?.sigma)
            }
            transport.send(collaboration.makeOutgoing(outgoing, spatial: spatialState, now: now))
        }

        guard now - lastPublish >= 0.12 else { return }
        lastPublish = now
        metrics.droppedFrames = provider.droppedFrames
        metrics.memoryMB = Self.residentMemoryMB()
        metrics.thermal = ["nominal", "fair", "serious", "critical"][min(max(thermal.rawValue, 0), 3)]
        metrics.speechDelayMs = audio.lastSpeechDelay.map { $0 * 1000 }
        metrics.peerObservationAgeMs = peers.filter { $0.status != .expired }.map { $0.captureAge * 1000 }.min()
        var s = Snapshot()
        s.cameraState = i.camera; s.providerName = provider.name; s.paused = paused; s.reliability = report
        s.entries = entries.filter { $0.state != .lost }; s.relevance = assessments; s.masks = masks; s.peers = peers
        s.linkState = collaboration.linkState; s.peerCount = collaboration.connectedPeerCount
        s.anchorReady = anchorReady; s.spatialMode = spatialMode; s.metrics = metrics
        s.modelID = detector.modelID; s.modelError = detector.loadError; s.lastInferenceError = lastInferenceError
        s.lastSpoken = lastSpoken; s.audioReady = audio.ready; s.preview = preview
        DispatchQueue.main.async { self.onSnapshot?(s) }
    }

    // MARK: Helpers

    private func ema(_ old: Double, _ new: Double, _ alpha: Double = 0.2) -> Double { old == 0 ? new : old + alpha * (new - old) }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
