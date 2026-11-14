import ARKit
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
    private(set) var droppedFrames = 0
    private(set) var state: CameraState = .starting {
        didSet { if state != oldValue { delegate?.frameProvider(didChangeState: state) } }
    }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "sharedsight.ar", qos: .userInitiated)
    private var worldFromAnchor: Pose?
    private var anchorFixTime: Timestamp?
    private let hasSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal]
        if let marker = Self.referenceImage() {
            config.detectionImages = [marker]
            config.maximumNumberOfTrackedImages = 1
        }
        worldFromAnchor = nil
        anchorFixTime = nil
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
        let info = SpatialFrameInfo(
            worldFromCamera: Pose(camera.transform), trackingNormal: normal,
            anchorID: worldFromAnchor != nil ? Self.anchorID : nil, worldFromAnchor: worldFromAnchor,
            anchorFixTime: anchorFixTime, hasSceneDepth: hasSceneDepth,
            groundPoint: { [weak session] x, y in
                guard let session else { return nil }
                // Upright-portrait normalised point -> normalised point in the landscape captured image.
                let p = CGPoint(x: y, y: 1 - x)
                for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
                    let query = frame.raycastQuery(from: p, allowing: target, alignment: .horizontal)
                    if let hit = session.raycast(query).first {
                        let t = hit.worldTransform.columns.3
                        return Vec3(Double(t.x), Double(t.y), Double(t.z))
                    }
                }
                return nil
            })
        delegate?.frameProvider(didOutput: CameraFrame(pixelBuffer: image, timestamp: frame.timestamp, orientation: .right,
                                                       uprightSize: CGSize(width: h, height: w), horizontalFOVDeg: fov, spatial: info))
    }

    private func ingest(_ anchors: [ARAnchor]) {
        for case let marker as ARImageAnchor in anchors where marker.referenceImage.name == Self.anchorID && marker.isTracked {
            worldFromAnchor = Pose(marker.transform)
            anchorFixTime = CACurrentMediaTime()
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { ingest(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { ingest(anchors) }

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
