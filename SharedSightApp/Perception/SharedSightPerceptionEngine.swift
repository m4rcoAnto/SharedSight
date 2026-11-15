import Foundation
import AVFoundation
import ARKit
import QuartzCore
import CoreImage
import UIKit
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
        var markerMs = 0.0
        var droppedFrames = 0, skippedFrames = 0
        var memoryMB = 0.0
        var thermal = "nominal"
    }

    struct Snapshot {
        var serverStatus = "Disconnesso"
        var cameraState: CameraState = .starting
        var providerName = ""
        var paused = false
        var reliability = ReliabilityReport(features: [:])
        var entries: [MemoryEntry] = []
        var relevance: [Int: RelevanceAssessment] = [:]
        var masks: [Int: ObstacleSegmentationEngine.TrackMask] = [:]
        var peers: [ResolvedPeerObservation] = []
        /// Things near the user that this camera cannot see: measured now by another phone (through the hub),
        /// or — when nobody sees them — a motion-model estimate. Never mixed with `entries`.
        var hidden: [HiddenReport] = []
        var hubDevices = 0
        var hubRoundTripMs: Double?
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
        // Person targeting (all produced by the same inference pass as obstacle detection)
        var target = TargetStatus()
        var guidance = FollowGuidance()
        var trackingArmed = false
        var markerError: String?
        var captureSession: AVCaptureSession?
        var arSession: ARSession?
        var imageAspect = 9.0 / 16.0          // width / height of the upright camera image
        /// Where the wall-ahead distance currently comes from: "LiDAR depth", "plane raycast" or "not measured".
        var wallSource = "not measured"
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
    /// Floor-plan memory of this phone's own tracks: where a mover that walked out of sight probably is now.
    let groundMemory = GroundTrackMemory()
    let hiddenResolver = HiddenObjectResolver()
    private var userMotion = DeviceMotionProxy()
    private let encounterEvaluator: EncounterRiskEvaluator = {
        var c = EncounterConfig(); c.maxRange = 20 // current ground-plane input limit, not a sensor range guarantee
        return EncounterRiskEvaluator(config: c)
    }()
    private var encounters: [EncounterResult] = []
    private let server = ServerTransport()
    private var serverSession = "1234"
    private var serverPreview = true
    private var serverEpoch = UUID().uuidString
    private var serverSequence = 0
    private let serverDeviceID: String = {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "serverDeviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "serverDeviceID")
        return id
    }()
    let markerDetector = TargetMarkerDetector()
    let targetManager = PersonTargetManager()
    let followController = FollowGuidanceController()
    /// Simulation only: records what a vehicle would be asked to do. Nothing is commanded.
    let vehicle: FollowVehicleAdapter = SimulatedVehicleAdapter()
    private var provider: CameraFrameProviding = CameraFrameProvider()

    var onSnapshot: ((Snapshot) -> Void)?
    /// Target state changes, delivered on the main thread, for the local diagnostics log.
    var onTargetEvents: (([TargetEvent]) -> Void)?
    /// A hub connection code was read while scanning was on. Delivered once, on the main thread; scanning then stops.
    var onHubLink: ((HubLink) -> Void)?
    var previewEnabled = false
    /// Instance masks are only drawn (outlines, Diagnostics). When nobody shows them they are not decoded at all.
    var masksWanted = false

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
    private var lastTracks: [TrackSnapshot] = []
    private var targetStatus = TargetStatus()
    private var guidance = FollowGuidance()
    private var frameIndex = 0
    private var imageAspect = 9.0 / 16.0
    private var hiddenEstimates: [HiddenEstimate] = []
    private var hidden: [HiddenReport] = []
    private var hiddenInvalidations: [String: HiddenInvalidationReason] = [:]
    private var planeSignature = 0
    private var postedAligned: Bool?
    private var lastFOV = 55.0
    private var lastScan: Timestamp = -.infinity
    private var hubScan = false
    private var wallMonitor = WallProximityMonitor()
    private var pendingWall: WallAlert?
    private var lastWallProbe: Timestamp = -.infinity
    private var wallSource = "not measured"

    // MARK: Lifecycle (call from the main thread)

    func start() {
        audio.prepare()
        audio.onDelivery = { [weak self] intent, phase, time in
            self?.work.async { self?.alerts.delivery(intent, phase: phase, at: time) }
        }
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

    func configureServer(url: String?, token: String, session: String, previews: Bool) {
        work.async {
            self.serverSession = session
            self.serverPreview = previews
            self.server.configure(url: url, token: token)
        }
    }

    func setPreferences(_ p: AlertPreferences) { work.async { self.preferences = p } }

    /// While on, the frames the app already receives are also searched for the hub's QR code. No second camera.
    func setHubScan(_ on: Bool) { work.async { self.hubScan = on } }

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
            // Before start() the provider is started by start() itself: never run the camera twice.
            if !self.paused && self.timer != nil { self.provider.start() }
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

    // MARK: Person targeting (call from the main thread)

    /// Who to look for. Nil clears the target. The profile is copied; persistence stays on the main thread.
    func setTargetProfile(_ profile: PersonProfile?) {
        work.async {
            self.targetManager.assign(profile, now: CACurrentMediaTime())
            self.refreshTarget(now: CACurrentMediaTime())
        }
    }

    func setTracking(_ on: Bool) {
        work.async {
            let now = CACurrentMediaTime()
            if on { self.targetManager.startAcquisition(now: now) } else { self.targetManager.stop(now: now) }
            self.refreshTarget(now: now)
        }
    }

    /// Operator confirmation: "this detected person is the registered one". Ignored unless that track is a
    /// person observed in the latest frame.
    func selectTarget(trackID: Int) {
        work.async {
            let now = CACurrentMediaTime()
            _ = self.targetManager.selectByOperator(trackID: trackID, tracks: self.lastTracks, now: now)
            self.refreshTarget(now: now)
        }
    }

    /// Re-derives guidance from the manager's current status and forwards state-change events.
    private func refreshTarget(now: Timestamp) {
        targetStatus = targetManager.status
        guidance = followController.update(targetStatus, now: now)
        vehicle.apply(FollowSetpoint(guidance), at: now)
        let events = targetManager.drainEvents()
        if !events.isEmpty { DispatchQueue.main.async { self.onTargetEvents?(events) } }
    }

    private func resetPerception() {
        targetManager.perceptionReset(now: CACurrentMediaTime())
        lastTracks = []
        refreshTarget(now: CACurrentMediaTime())
        userMotion.reset(); encounters = []
        server.resetEpoch()
        serverEpoch = UUID().uuidString
        tracker.reset(); memory.reset(); alerts.reset()
        entries = []; assessments = [:]; worldPositions = [:]; masks = [:]; knownTrackIDs = []
        lastFrameTime = nil; lastSpatial = nil; quality = nil; reading = nil
        groundMemory.reset(); hiddenEstimates = []; hidden = []; hiddenInvalidations = [:]
        planeSignature = 0; postedAligned = nil; server.forcePlanes()
        wallMonitor.reset(); pendingWall = nil; wallSource = "not measured"
    }

    /// LiDAR only: horizontal distance to what the depth map shows at about camera height in the given image
    /// columns (upright, 0 = left edge). Floor and ceiling points are left out; nil when too few samples remain.
    private func depthDistance(_ spatial: SpatialFrameInfo, columns: [Double]) -> Double? {
        guard let depth = spatial.depthPoint else { return nil }
        let eye = spatial.worldFromCamera.translation
        // A person or a vehicle is not a wall: depth inside a tracked mover's box (as of the previous frame) is left out.
        let movers = entries.filter { $0.isCurrentEvidence && NominalSize.isMover($0.track.label) }.map(\.track.box)
        var values: [Double] = []
        for x in columns {
            for y in [0.42, 0.5] {
                if movers.contains(where: { x >= $0.x && x <= $0.maxX && y >= $0.y && y <= $0.maxY }) { continue }
                guard let p = depth(x, y), abs(p.y - eye.y) < 0.6 else { continue }
                var d = p - eye; d.y = 0
                if d.length > 0.15 { values.append(d.length) }
            }
        }
        guard values.count >= 2 else { return nil }
        values.sort()
        return values[(values.count - 1) / 2]
    }

    /// Wall ahead, from measurements only. LiDAR depth where the phone has it (an opening is where the depth is
    /// greater than beside it); otherwise level rays against vertical planes. No tracking, no claim.
    private func probeWalls(_ frame: CameraFrame) {
        guard let spatial = frame.spatial, spatial.trackingNormal else {
            wallMonitor.reset(); pendingWall = nil; wallSource = "not measured"
            return
        }
        guard frame.timestamp - lastWallProbe >= 0.1 else { return }
        lastWallProbe = frame.timestamp
        var reading = WallReading(forward: nil, planesTracked: spatial.planes.contains(where: \.vertical))
        if let forward = depthDistance(spatial, columns: [0.4, 0.5, 0.6]) {
            reading.forward = forward
            wallSource = "LiDAR depth"
            if forward <= 2.5 {     // the sides matter only near a wall; as wide as the picture allows
                reading.left = depthDistance(spatial, columns: [0.08, 0.18])
                reading.right = depthDistance(spatial, columns: [0.82, 0.92])
            }
        } else if let ray = spatial.wallDistance, let forward = ray(0) {
            reading.forward = forward
            wallSource = "plane raycast"
            if forward <= 2.5 { reading.left = ray(35); reading.right = ray(-35) }
        } else {
            wallSource = "not measured"
        }
        pendingWall = wallMonitor.update(reading, now: frame.timestamp)
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
                let o = try detector.detect(frame, decodeMasks: masksWanted && segmentation.runsNextFrame)
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
        // Only what can move, or is big enough to walk into, is tracked: bottles, cups and bags never enter the tracker.
        let detections = covered ? [] : (output?.detections ?? []).filter { NominalSize.isRelevant($0.label) }

        let tracks = tracker.update(detections: detections, timestamp: frame.timestamp, cameraMotion: r.motion)
        // Person targeting shares this frame's detections and tracks: no second model, no second inference.
        // Only the QR read is extra, and only while tracking is started (every frame while searching,
        // every third frame once locked).
        frameIndex += 1
        imageAspect = Double(frame.uprightSize.width / max(frame.uprightSize.height, 1))
        var sightings: [MarkerSighting] = []
        if targetManager.isArmed, !covered, !targetStatus.isLocked || frameIndex % 3 == 0 {
            sightings = markerDetector.detect(frame)
            metrics.markerMs = ema(metrics.markerMs, markerDetector.lastLatency * 1000)
        }
        if hubScan, !covered, frameIndex % 2 == 0, let link = markerDetector.hubLinks(frame).first {
            hubScan = false
            DispatchQueue.main.async { self.onHubLink?(link) }
        }
        probeWalls(frame)
        userMotion.update(pose: frame.spatial?.trackingNormal == true ? frame.spatial?.worldFromCamera : nil, time: frame.timestamp)
        lastTracks = tracks
        targetManager.update(tracks: tracks, markers: sightings, now: frame.timestamp)
        refreshTarget(now: frame.timestamp)

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
            let top = entries.filter { $0.isCurrentEvidence }.sorted { (assessments[$0.id]?.score ?? 0) > (assessments[$1.id]?.score ?? 0) }.prefix(server.enabled ? 32 : 8)
            for e in top {
                let box = e.track.box
                // 1. LiDAR, when present: depth of the object itself (lower-middle of its box, where the object is and
                //    not the floor behind it), up to 5 m. Works even when its base is out of the picture or no floor
                //    plane has been found yet. 2. Otherwise the ray through the box's ground contact onto the floor.
                var point: Vec3?, sigma = 0.0, method = DistanceMeasurement.Method.groundPlaneRaycast
                if let depth = spatial.depthPoint?(box.cx, box.y + 0.65 * box.h), let floorY = spatial.floorY {
                    point = Vec3(depth.x, floorY, depth.z)
                    var d = depth - spatial.worldFromCamera.translation; d.y = 0
                    sigma = 0.08 + 0.03 * d.length      // heuristic: LiDAR is centimetric, the box point is not the centre
                    method = .lidarDepth
                } else if box.maxY < 0.97, let p = spatial.groundPoint(box.cx, box.maxY) {   // bottom cut off => no contact point
                    point = p
                    var d = p - spatial.worldFromCamera.translation; d.y = 0
                    sigma = 0.15 + 0.05 * d.length      // heuristic uncertainty model, not a calibrated one
                }
                guard let p = point else { continue }
                var d = p - spatial.worldFromCamera.translation
                d.y = 0
                let meters = d.length
                guard meters > 0.2, meters < 20 else { continue }    // the uncertainty grows with distance and is sent along
                worldPositions[e.id] = (p, sigma)
                assessments[e.id] = relevance.assess(e, camera: camera, distance: DistanceMeasurement(meters: meters, sigma: sigma, method: method))
            }
        }
        // Floor-plan memory: a mover that leaves this camera's sight is predicted (and labelled as predicted) instead
        // of being forgotten. Needs a tracked pose and a heading on the floor; without them nothing is estimated.
        let seenNow = Set(entries.filter { $0.isCurrentEvidence }.map(\.id))
        lastFOV = frame.horizontalFOVDeg
        if let spatial = frame.spatial, spatial.trackingNormal {
            let labels = Dictionary(entries.map { ($0.id, $0.track.label) }, uniquingKeysWith: { a, _ in a })
            let measured = worldPositions.compactMap { id, value in
                labels[id].map { GroundObservation(trackID: id, label: $0, position: value.position, sigma: value.sigma) }
            }
            let walls = spatial.planes.filter(\.vertical).compactMap { plane in
                WallSegment(vertices: plane.vertices, kind: WallSegment.Kind(rawValue: plane.kind ?? "") ?? .wall)
            }
            hiddenEstimates = groundMemory.update(observations: measured, observedTrackIDs: seenNow,
                                                  camera: FloorCamera(pose: spatial.worldFromCamera),
                                                  fovDeg: frame.horizontalFOVDeg, walls: walls, now: frame.timestamp)
        } else {
            hiddenEstimates = groundMemory.update(observations: [], observedTrackIDs: seenNow, camera: nil,
                                                  fovDeg: frame.horizontalFOVDeg, walls: [], now: frame.timestamp)
        }
        // Keep poses only: the raycast closure references the ARFrame and must not outlive this frame.
        var kept = frame.spatial
        kept?.groundPoint = { _, _ in nil }
        kept?.depthPoint = nil
        kept?.surfacePoint = nil
        kept?.wallDistance = nil
        lastSpatial = kept

        if let o = output, !covered {
            masks = segmentation.update(tracks: tracks, priority: assessments.mapValues(\.score), output: o, now: frame.timestamp)
            metrics.segmentationMs = ema(metrics.segmentationMs, segmentation.lastLatency * 1000)
        } else { masks = [:] }

        lastFrameTime = frame.timestamp
        let now = CACurrentMediaTime()
        metrics.decisionDelayMs = ema(metrics.decisionDelayMs, (now - frame.timestamp) * 1000)

        // Down-scaled frames are produced only for Diagnostics or when no preview layer exists (ARKit mode).
        if previewEnabled, now - lastPreview > (provider.captureSession == nil ? 0.066 : 0.15) {
            lastPreview = now
            let image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
                .transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
            preview = ciContext.createCGImage(image, from: image.extent)
        } else if !previewEnabled { preview = nil }

        streamToServer(frame: frame)
        decideAndPublish(now: now)
    }

    private func streamToServer(frame: CameraFrame) {
        guard server.ready, !paused else { return }
        let spatial = frame.spatial
        let tracking = spatial?.trackingNormal ?? false
        // A fix older than 30 seconds is no longer used to fuse independent devices.
        let aligned = tracking && spatial?.worldFromAnchor != nil &&
            frame.timestamp - (spatial?.anchorFixTime ?? -1e9) < 30
        let reference = aligned ? spatial!.worldFromAnchor!.inverseRigid() : Pose.identity
        // Apparent size = box extent x measured distance along the optical axis. Only for boxes fully inside the picture.
        let tanH = tan(frame.horizontalFOVDeg * .pi / 360), tanV = tanH / max(imageAspect, 0.1)
        let forwardAxis = spatial.map { $0.worldFromCamera.axis(2) * -1 }
        let cameraPosition = spatial?.worldFromCamera.translation
        let objects = entries.filter { $0.isCurrentEvidence }.prefix(64).map { e -> ServerObservation in
            let box = e.track.box
            let measured = tracking ? worldPositions[e.id] : nil
            var size: ObservedSize?
            if let measured, let forwardAxis, let cameraPosition, box.x > 0.01, box.y > 0.01, box.maxX < 0.99, box.maxY < 0.99 {
                let forward = (measured.position - cameraPosition).dot(forwardAxis)
                if forward > 0.3 { size = ObservedSize(w: box.w * 2 * tanH * forward, h: box.h * 2 * tanV * forward) }
            }
            return ServerObservation(id: e.id, label: e.track.label, confidence: e.track.confidence, box: box.clampedToUnit,
                position: measured.map { reference.transform($0.position) }, sigma: measured?.sigma, size: size,
                evidence: measured == nil ? "bearing" : "measurement", measuredAt: measured == nil ? nil : frame.timestamp)
        }
        // Surfaces travel only when they changed (5 cm resolution), when the frame of reference changed, or as a
        // periodic refresh: most frames are a few hundred bytes.
        var planes: [RoomPlane]?
        let surfaces = tracking ? Array((spatial?.planes ?? []).prefix(128)) : []
        var hasher = Hasher()
        hasher.combine(aligned)
        for plane in surfaces {
            hasher.combine(plane.id); hasher.combine(plane.kind); hasher.combine(plane.triangles.count)
            for v in plane.vertices {
                hasher.combine(Int((v.x * 20).rounded())); hasher.combine(Int((v.y * 20).rounded())); hasher.combine(Int((v.z * 20).rounded()))
            }
        }
        let signature = hasher.finalize()
        if postedAligned != aligned { server.forcePlanes() }
        if server.planesDue(changed: signature != planeSignature, now: frame.timestamp) {
            planes = surfaces.map { plane in
                RoomPlane(id: plane.id, vertices: plane.vertices.map { reference.transform($0) },
                          triangles: plane.triangles, vertical: plane.vertical, kind: plane.kind)
            }
            planeSignature = signature
            postedAligned = aligned
        }
        var jpeg: String?
        if serverPreview, server.previewDue(now: frame.timestamp) {
            let image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(small, from: small.extent) {
                jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.55)?.base64EncodedString()
            }
        }
        // Depth scan, a few times a second: nine rays across the picture a little above its middle. Where one meets a
        // vertical surface 0.4–8 m away the hub learns of a wall there, long before ARKit has built a plane.
        var scan: [ScanHit]?
        if tracking, let spatial, let surface = spatial.surfacePoint, frame.timestamp - lastScan >= 0.4 {
            lastScan = frame.timestamp
            let movers = entries.filter { $0.isCurrentEvidence && NominalSize.isMover($0.track.label) }.map(\.track.box)
            var hits: [ScanHit] = []
            for i in 0..<9 {
                let x = 0.1 + 0.1 * Double(i), y = 0.42
                if movers.contains(where: { x >= $0.x && x <= $0.maxX && y >= $0.y && y <= $0.maxY }) { continue }   // a person is not a wall
                guard let hit = surface(x, y), abs(hit.normal.y) < 0.35 else { continue }
                var d = hit.point - spatial.worldFromCamera.translation; d.y = 0
                guard d.length > 0.4, d.length < 8 else { continue }
                let p = reference.transform(hit.point), q = reference.transform(hit.point + hit.normal)
                let nx = q.x - p.x, nz = q.z - p.z, l = (nx * nx + nz * nz).squareRoot()
                guard l > 0.5 else { continue }
                hits.append(ScanHit(x: p.x, z: p.z, nx: nx / l, nz: nz / l))
            }
            if !hits.isEmpty { scan = hits }
        }
        serverSequence += 1
        server.send(ServerFrame(deviceID: serverDeviceID, name: "iPhone-" + String(serverDeviceID.prefix(4)),
            session: serverSession, epoch: serverEpoch, sequence: serverSequence, tracking: tracking,
            anchorID: aligned ? spatial?.anchorID : nil,
            camera: tracking ? spatial.map { reference * $0.worldFromCamera } : nil,
            fov: frame.horizontalFOVDeg, t: frame.timestamp, sent: nil,
            planes: planes, objects: objects, jpeg: jpeg, scan: scan), queue: work)
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
        // No frames are arriving: the target is not being observed. Feed that to the manager so a frozen
        // camera turns into "hidden" and then "lost" instead of a lock that looks alive.
        if stall > 0.4, targetManager.isArmed, targetStatus.trackID != nil {
            let unobserved = lastTracks.map { t -> TrackSnapshot in var u = t; u.observedThisFrame = false; return u }
            targetManager.update(tracks: unobserved, markers: [], now: now)
            refreshTarget(now: now)
        }
        let candidates: [LocalCandidate] = paused ? [] : entries.compactMap { e -> LocalCandidate? in
            guard let a = assessments[e.id] else { return nil }
            var aged = e
            aged.ageSinceObserved += stall
            return LocalCandidate(entry: aged, relevance: a)
        }
        var events = collaboration.drainEvents()
        if anchorReady && !anchorWasReady { events.append(.sharedReferenceReady) }
        anchorWasReady = anchorReady

        // What this camera cannot see. A direction needs a current pose: with a stalled camera nothing is claimed.
        for report in hidden { hiddenInvalidations[report.id] = .missingPose }
        for (id, reason) in groundMemory.invalidations { hiddenInvalidations["L:\(id)"] = reason }
        hidden = []
        if !paused, stall <= 0.5, let spatial = lastSpatial {
            let advice = server.advice
            // The hub answers in the frame the phone posted in: the shared marker frame, or this phone's own world.
            let reference: Pose? = advice?.anchored == true ? spatial.worldFromAnchor : Pose.identity
            let resolution = hiddenResolver.resolveDetailed(advisories: reference == nil ? [] : (advice?.advisories ?? []),
                                            advisoryAge: advice.map { now - $0.receivedAt },
                                            worldFromReference: reference ?? .identity,
                                            estimates: hiddenEstimates.map { estimate in
                                                var aged = estimate; aged.age += stall; return aged
                                            },
                                            worldFromCamera: spatial.worldFromCamera, trackingNormal: spatial.trackingNormal,
                                            aheadHalfAngleDeg: relevance.aheadHalfAngle(horizontalFOVDeg: lastFOV))
            hidden = resolution.reports
            hiddenInvalidations.merge(resolution.invalidations, uniquingKeysWith: { _, latest in latest })
            for report in hidden { hiddenInvalidations[report.id] = nil }
        }

        let observedIDs = Set(entries.filter(\.isCurrentEvidence).map(\.id))
        var metricCandidates = groundMemory.encounterCandidates(now: now, observedIDs: observedIDs)
        if let advice = server.advice, let spatial = lastSpatial,
           let reference = advice.anchored ? spatial.worldFromAnchor : Pose.identity {
            let remote = hiddenResolver.encounterCandidates(advisories: advice.advisories, residence: now - advice.receivedAt,
                                                             worldFromReference: reference, now: now)
            for candidate in remote where !metricCandidates.contains(where: { $0.id == candidate.id }) { metricCandidates.append(candidate) }
        }
        var user = userMotion.motion
        if let stateAt = user?.stateAt { user?.measurementAge = max(0, now - stateAt) }
        encounters = metricCandidates.map {
            encounterEvaluator.evaluate($0, user: user,
                worldFromCamera: !paused && stall <= 0.5 && lastSpatial?.trackingNormal == true ? lastSpatial?.worldFromCamera : nil,
                epoch: serverEpoch, now: now, sampleInterval: userMotion.interval, userMotionIsDeviceProxy: true)
        }

        let intents = alerts.decide(local: candidates, peers: peers, hidden: hidden, reliability: report, events: events,
                                    preferences: preferences, encounters: encounters, wall: paused ? nil : pendingWall,
                                    epoch: serverEpoch, now: now)
        pendingWall = nil
        let validation = alerts.validationSnapshot
        DispatchQueue.main.async {
            self.audio.updateValidation(validation)
            self.audio.handle(intents)
        }

        // Share direct observations (metadata only) at most 5 times per second.
        if collaboration.consentGiven, now - lastShare >= 0.2, !paused {
            lastShare = now
            let outgoing = entries.filter { $0.isCurrentEvidence && $0.ageSinceObserved + stall < 0.5 }.map { e in
                OutgoingObservation(entry: e, bearingDeg: assessments[e.id]?.bearingDeg,
                                    worldPosition: worldPositions[e.id]?.position, positionSigma: worldPositions[e.id]?.sigma)
            }
            transport.send(collaboration.makeOutgoing(outgoing, spatial: spatialState, now: now))
        }

        guard now - lastPublish >= 0.06 else { return }   // ~15 Hz: overlays must keep up with the live preview
        lastPublish = now
        metrics.droppedFrames = provider.droppedFrames
        metrics.memoryMB = Self.residentMemoryMB()
        metrics.thermal = ["nominal", "fair", "serious", "critical"][min(max(thermal.rawValue, 0), 3)]
        metrics.speechDelayMs = audio.lastSpeechDelay.map { $0 * 1000 }
        metrics.peerObservationAgeMs = peers.filter { $0.status != .expired }.map { $0.captureAge * 1000 }.min()
        var s = Snapshot()
        s.serverStatus = server.status
        s.cameraState = i.camera; s.providerName = provider.name; s.paused = paused; s.reliability = report
        s.entries = entries.filter { $0.state != .lost }; s.relevance = assessments; s.masks = masks; s.peers = peers
        s.hidden = hidden; s.hubDevices = server.advice?.devices ?? 0; s.hubRoundTripMs = server.roundTrip.map { $0 * 1000 }
        s.linkState = collaboration.linkState; s.peerCount = collaboration.connectedPeerCount
        s.anchorReady = anchorReady; s.spatialMode = spatialMode; s.metrics = metrics
        s.modelID = detector.modelID; s.modelError = detector.loadError; s.lastInferenceError = lastInferenceError
        s.lastSpoken = lastSpoken; s.audioReady = audio.ready; s.preview = preview
        s.target = targetStatus; s.guidance = guidance; s.trackingArmed = targetManager.isArmed
        s.markerError = markerDetector.lastError
        s.wallSource = wallSource
        s.captureSession = provider.captureSession; s.arSession = provider.arSession; s.imageAspect = imageAspect
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
