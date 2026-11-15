import ARKit
import AVFoundation
import QuartzCore
import SharedSightCore

extension Pose {
    init(_ m: simd_float4x4) {
        let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        self.init(columnMajor: c.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] })
    }
}

/// Camera provider used when spatial claims are needed. ARKit world tracking supplies the camera pose,
/// detected floor planes (for ground-contact raycasts) and the pose of the printed anchor marker that two
/// phones use as their common spatial reference. Without a detected marker there is NO shared frame.
final class ARFrameProvider: NSObject, CameraFrameProviding, ARSessionDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static let anchorID = "SHAREDSIGHT-ANCHOR-01"
    /// Printed width of Docs/AnchorMarker.png in metres. Must match the real print or distances will be wrong.
    static var markerWidthMeters: Double {
        let v = UserDefaults.standard.double(forKey: "markerWidthCm")
        return (v > 0 ? v : 15) / 100
    }

    weak var delegate: CameraFrameProviderDelegate?
    let name = "ARKit"
    let captureSession: AVCaptureSession? = nil   // ARKit owns the camera
    /// The live camera view draws this session's own feed (GPU, full frame rate): no per-frame work for the UI.
    var arSession: ARSession? { session }
    private(set) var droppedFrames = 0
    private(set) var state: CameraState = .starting {
        didSet { if state != oldValue { delegate?.frameProvider(didChangeState: state) } }
    }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "sharedsight.ar", qos: .userInitiated)
    private var worldFromAnchor: Pose?
    private var anchorFixTime: Timestamp?
    private let hasSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    /// Floor and wall surfaces, rebuilt only when ARKit adds, updates or removes a plane (not 60 times a second).
    private var planeCache: [UUID: RoomPlane] = [:]
    private var planeList: [RoomPlane] = []

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        // LiDAR depth (Pro models): measures the distance of whatever the detector boxed, not only where its base
        // meets a detected floor. Without LiDAR the floor raycast stays the only metric source.
        if hasSceneDepth { config.frameSemantics.insert(.sceneDepth) }
        // 30 frames/s is more than the detector processes; 60 only heats the phone, and heat slows the detector down.
        // Smallest such format of at least 1280 px: never the 4K one, which only costs time.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 && $0.imageResolution.width >= 1280 })
            .min(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            config.videoFormat = format
        }
        if let marker = Self.referenceImage() {
            config.detectionImages = [marker]
            config.maximumNumberOfTrackedImages = 1
        }
        worldFromAnchor = nil
        anchorFixTime = nil
        queue.async { self.planeCache = [:]; self.planeList = [] }
        session.delegate = self
        session.delegateQueue = queue
        state = .starting
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        state = .paused
    }

    private static func referenceImage() -> ARReferenceImage? {
        guard let url = Bundle.main.url(forResource: "AnchorMarker", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: CGFloat(markerWidthMeters))
        reference.name = anchorID
        return reference
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        state = .running
        let camera = frame.camera
        var normal = false
        if case .normal = camera.trackingState { normal = true }
        let image = frame.capturedImage
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        // Upright (portrait) horizontal FOV spans the sensor's short side.
        let fy = Double(camera.intrinsics[1][1])
        let fov = fy > 0 ? 2 * atan(Double(h) / (2 * fy)) * 180 / .pi : 42
        let horizontals = planeList.filter { !$0.vertical }
        let floors = horizontals.filter { $0.kind == "floor" }
        let floorY = (floors.isEmpty ? horizontals : floors).compactMap { p -> Double? in
            p.vertices.isEmpty ? nil : p.vertices.reduce(0.0) { $0 + $1.y } / Double(p.vertices.count)
        }.min()
        let depthReader: ((Double, Double) -> Vec3?)? = frame.sceneDepth == nil ? nil : { x, y in Self.depthPoint(frame, x, y) }
        let info = SpatialFrameInfo(
            worldFromCamera: Pose(camera.transform), trackingNormal: normal,
            anchorID: worldFromAnchor != nil ? Self.anchorID : nil, worldFromAnchor: worldFromAnchor,
            anchorFixTime: anchorFixTime,
            planes: planeList, hasSceneDepth: hasSceneDepth,
            groundPoint: { [weak session] x, y in
                guard let session else { return nil }
                // Upright-portrait normalised point -> normalised point in the landscape captured image.
                let p = CGPoint(x: y, y: 1 - x)
                // Detected floor first; then the same floor continued beyond its mapped edge (so the base of something
                // far away still gets a position); then ARKit's own estimate.
                for target in [ARRaycastQuery.Target.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane] {
                    let query = frame.raycastQuery(from: p, allowing: target, alignment: .horizontal)
                    if let hit = session.raycast(query).first {
                        let t = hit.worldTransform.columns.3
                        return Vec3(Double(t.x), Double(t.y), Double(t.z))
                    }
                }
                return nil
            },
            depthPoint: depthReader,
            surfacePoint: { [weak self] (x: Double, y: Double) -> (point: Vec3, normal: Vec3)? in
                guard let self else { return nil }
                let query = frame.raycastQuery(from: CGPoint(x: y, y: 1 - x), allowing: .estimatedPlane, alignment: .vertical)
                guard let hit = self.session.raycast(query).first else { return nil }
                let t = hit.worldTransform.columns.3, n = hit.worldTransform.columns.1      // y axis = surface normal
                return (Vec3(Double(t.x), Double(t.y), Double(t.z)), Vec3(Double(n.x), Double(n.y), Double(n.z)))
            },
            floorY: floorY,
            wallDistance: { [weak session] offsetDeg in
                guard let session else { return nil }
                let t = camera.transform
                let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                // The camera looks along its -Z. Flattened to the floor plane it is the heading; with the phone
                // pointing at the floor or the ceiling there is no heading, and nothing is measured.
                var heading = simd_float3(-t.columns.2.x, 0, -t.columns.2.z)
                let length = simd_length(heading)
                guard length > 0.35 else { return nil }
                heading /= length
                let a = Float(offsetDeg * .pi / 180), c = cos(a), s = sin(a)
                let direction = simd_float3(heading.x * c + heading.z * s, 0, -heading.x * s + heading.z * c)
                // Real plane geometry first, then ARKit's estimate. Never a plane continued beyond its mapped edge:
                // that would put a wall across a doorway.
                for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
                    let query = ARRaycastQuery(origin: origin, direction: direction, allowing: target, alignment: .vertical)
                    guard let hit = session.raycast(query).first else { continue }
                    let p = hit.worldTransform.columns.3, n = hit.worldTransform.columns.1
                    guard abs(n.y) < 0.35 else { continue }
                    let d = Double(simd_length(simd_float3(p.x - origin.x, 0, p.z - origin.z)))
                    if d > 0.15, d < 8 { return d }
                }
                return nil
            })
        delegate?.frameProvider(didOutput: CameraFrame(pixelBuffer: image, timestamp: frame.timestamp, orientation: .right,
                                                       uprightSize: CGSize(width: h, height: w), horizontalFOVDeg: fov, spatial: info))
    }

    /// Back-projects the LiDAR depth at an upright-normalised point. Camera space: +x right, +y up, looking along -z
    /// in the sensor's (landscape) orientation; depth is the distance along the optical axis.
    private static func depthPoint(_ frame: ARFrame, _ x: Double, _ y: Double) -> Vec3? {
        guard let depth = frame.sceneDepth else { return nil }
        let map = depth.depthMap, confidence = depth.confidenceMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        // Upright portrait (x, y) -> normalised point in the landscape sensor image (same mapping as the raycast).
        let px = y, py = 1 - x
        let u = min(max(Int(px * Double(w)), 0), w - 1), v = min(max(Int(py * Double(h)), 0), h - 1)
        var samples: [Float] = []
        samples.reserveCapacity(25)
        for dv in -2...2 {
            for du in -2...2 {
                let uu = min(max(u + du, 0), w - 1), vv = min(max(v + dv, 0), h - 1)
                if let confidence, let cbase = CVPixelBufferGetBaseAddress(confidence) {
                    let c = cbase.advanced(by: vv * CVPixelBufferGetBytesPerRow(confidence) + uu).assumingMemoryBound(to: UInt8.self).pointee
                    if Int(c) < ARConfidenceLevel.medium.rawValue { continue }
                }
                let d = base.advanced(by: vv * row + uu * MemoryLayout<Float32>.size).assumingMemoryBound(to: Float32.self).pointee
                if d.isFinite, d > 0.15, d < 5 { samples.append(d) }
            }
        }
        guard samples.count >= 6 else { return nil }
        samples.sort()
        let d = Double(samples[samples.count / 2])
        let k = frame.camera.intrinsics
        let image = frame.capturedImage
        let ix = px * Double(CVPixelBufferGetWidth(image)), iy = py * Double(CVPixelBufferGetHeight(image))
        let fx = Double(k[0][0]), fy = Double(k[1][1]), cx = Double(k[2][0]), cy = Double(k[2][1])
        guard fx > 0, fy > 0 else { return nil }
        let local = simd_float4(Float((ix - cx) / fx * d), Float(-(iy - cy) / fy * d), Float(-d), 1)
        let world = frame.camera.transform * local
        return Vec3(Double(world.x), Double(world.y), Double(world.z))
    }

    /// ARKit's surface classification, where the device supports it. A door or a window is not a wall: a window does
    /// not hide what is behind it, and a door is named as a door when something is hidden behind it.
    private static func kind(of plane: ARPlaneAnchor) -> String? {
        guard ARPlaneAnchor.isClassificationSupported else { return nil }
        switch plane.classification {
        case .wall: return "wall"
        case .door: return "door"
        case .window: return "window"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .table: return "table"
        case .seat: return "seat"
        default: return nil
        }
    }

    private func ingest(_ anchors: [ARAnchor]) {
        var planesChanged = false
        for anchor in anchors {
            if let marker = anchor as? ARImageAnchor, marker.referenceImage.name == Self.anchorID, marker.isTracked {
                worldFromAnchor = Pose(marker.transform)
                anchorFixTime = CACurrentMediaTime()
            } else if let plane = anchor as? ARPlaneAnchor {
                let transform = Pose(plane.transform)
                planeCache[plane.identifier] = RoomPlane(id: plane.identifier.uuidString,
                    vertices: plane.geometry.vertices.map { transform.transform(Vec3(Double($0.x), Double($0.y), Double($0.z))) },
                    triangles: plane.geometry.triangleIndices.map { Int($0) }, vertical: plane.alignment == .vertical,
                    kind: Self.kind(of: plane))
                planesChanged = true
            }
        }
        if planesChanged { planeList = planeCache.values.sorted { $0.id < $1.id } }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { ingest(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { ingest(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        var changed = false
        for case let plane as ARPlaneAnchor in anchors { if planeCache.removeValue(forKey: plane.identifier) != nil { changed = true } }
        if changed { planeList = planeCache.values.sorted { $0.id < $1.id } }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        state = (error as? ARError)?.code == .cameraUnauthorized ? .permissionDenied : .unavailable
    }

    func sessionWasInterrupted(_ session: ARSession) { state = .interrupted }

    func sessionInterruptionEnded(_ session: ARSession) {
        // The world map may have shifted: the shared reference must be re-observed before it is trusted again.
        worldFromAnchor = nil
        anchorFixTime = nil
    }
}
