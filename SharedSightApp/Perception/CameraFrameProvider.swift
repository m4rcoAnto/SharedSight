import AVFoundation
import ImageIO
import SharedSightCore

/// Spatial data that only exists in ARKit mode. Every member is a measurement or nil.
struct SpatialFrameInfo {
    var worldFromCamera: Pose
    var trackingNormal: Bool
    var anchorID: String?
    var worldFromAnchor: Pose?
    var anchorFixTime: Timestamp?
    var hasSceneDepth: Bool
    /// Intersects the ray through an upright-normalised image point with detected horizontal surfaces.
    var groundPoint: (_ x: Double, _ y: Double) -> Vec3?
}

struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Timestamp                       // capture time on the media clock (CACurrentMediaTime base)
    let orientation: CGImagePropertyOrientation    // how to read the buffer upright
    let uprightSize: CGSize
    let horizontalFOVDeg: Double                   // of the upright image
    var spatial: SpatialFrameInfo?
}

protocol CameraFrameProviderDelegate: AnyObject {
    func frameProvider(didOutput frame: CameraFrame)
    func frameProvider(didChangeState state: CameraState)
}

protocol CameraFrameProviding: AnyObject {
    var delegate: CameraFrameProviderDelegate? { get set }
    var state: CameraState { get }
    var droppedFrames: Int { get }
    var name: String { get }
    func start()
    func stop()
}

/// Rear-camera acquisition with AVFoundation. Delivers native bi-planar YCbCr buffers (no conversion),
/// drops late frames instead of queueing them, and reports permission, interruption and runtime failures.
final class CameraFrameProvider: NSObject, CameraFrameProviding, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: CameraFrameProviderDelegate?
    let name = "AVFoundation"
    private(set) var droppedFrames = 0
    private(set) var state: CameraState = .starting {
        didSet { if state != oldValue { delegate?.frameProvider(didChangeState: state) } }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sharedsight.camera.session")
    private let videoQueue = DispatchQueue(label: "sharedsight.camera.frames", qos: .userInitiated)
    private var configured = false
    private var wantsRunning = false
    private var fovDeg = 42.0
    private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() {
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.sessionQueue.async { if granted { self.configureAndRun() } else { self.state = .permissionDenied } }
            }
        default:
            state = .permissionDenied
        }
    }

    func stop() {
        wantsRunning = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.state = .paused
        }
    }

    private func configureAndRun() {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                state = .unavailable
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true   // bounded: never queue stale frames
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                state = .unavailable
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                device.unlockForConfiguration()
            } catch { /* keep the format's default frame rate */ }
            // The sensor image is landscape; the upright portrait image's horizontal extent is the sensor's short side.
            let sensorFOV = Double(device.activeFormat.videoFieldOfView)
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            fovDeg = 2 * atan(tan(sensorFOV * .pi / 360) * Double(dims.height) / Double(dims.width)) * 180 / .pi
            registerObservers()
            configured = true
        }
        if wantsRunning && !session.isRunning { session.startRunning() }
        state = session.isRunning ? .running : (wantsRunning ? .unavailable : .paused)
    }

    private func registerObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.state = .interrupted
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async { self.state = self.session.isRunning ? .running : .unavailable }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.state = .unavailable
            self.sessionQueue.async { if self.wantsRunning { self.session.startRunning(); self.state = self.session.isRunning ? .running : .unavailable } }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        delegate?.frameProvider(didOutput: CameraFrame(
            pixelBuffer: buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            orientation: .right, uprightSize: CGSize(width: h, height: w), horizontalFOVDeg: fovDeg, spatial: nil))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedFrames += 1
    }
}

/// Cheap image-condition measurement on the luma plane (sparse sampling, no conversion).
enum ImageQualityProbe {
    static func measure(_ buffer: CVPixelBuffer) -> (mean: Double, spread: Double)? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                let v = Double(p[y * rowBytes + x]) / 255
                sum += v; sumSq += v * v; n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return (mean, max(0, sumSq / n - mean * mean).squareRoot())
    }
}
