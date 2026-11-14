import CoreMotion
import SharedSightCore

/// Inertial camera-motion estimate. Integrates the gyroscope between frames to predict the global image
/// shift caused by camera rotation (the dominant term for a hand-held or chest-worn phone), and derives
/// camera pitch / roll from gravity. Translation parallax is NOT compensated; when the device is not
/// measured as steady, object-motion claims are disabled downstream.
final class CameraMotionEstimator {
    struct Reading {
        var motion: FrameMotion
        var pitchDeg: Double?
        var rollDeg: Double?
        var angularRate: Double?
        var steady: Bool
    }

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var yaw = 0.0, pitch = 0.0
    private var lastSample: TimeInterval?
    private var gravity: CMAcceleration?
    private var rate = 0.0
    private var accel = 0.0
    private var samples = 0

    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard available, !manager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            self.lock.lock()
            if let last = self.lastSample {
                let dt = min(max(m.timestamp - last, 0), 0.1)
                self.yaw += m.rotationRate.y * dt
                self.pitch += m.rotationRate.x * dt
            }
            self.lastSample = m.timestamp
            self.gravity = m.gravity
            let r = m.rotationRate, a = m.userAcceleration
            self.rate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            self.accel = 0.9 * self.accel + 0.1 * (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.samples += 1
            self.lock.unlock()
        }
    }

    func stop() { manager.stopDeviceMotionUpdates(); lock.lock(); lastSample = nil; samples = 0; lock.unlock() }

    /// Returns the motion accumulated since the previous call (portrait device, rear camera).
    func consume(horizontalFOVDeg: Double, aspect: Double) -> Reading {
        lock.lock()
        let dYaw = yaw, dPitch = pitch, g = gravity, w = rate, a = accel, have = samples > 0
        yaw = 0; pitch = 0; samples = 0
        lock.unlock()
        guard have, let g else {
            return Reading(motion: FrameMotion(dx: 0, dy: 0, reliable: false), pitchDeg: nil, rollDeg: nil, angularRate: nil, steady: false)
        }
        // Focal length in units of image width. Turning left (+yaw about device Y) moves the scene right (+x);
        // tilting the camera up (+rotation about device X) moves the scene down (+y).
        let f = 0.5 / tan(horizontalFOVDeg * .pi / 360)
        let motion = FrameMotion(dx: tan(dYaw) * f, dy: tan(dPitch) * f * aspect, reliable: abs(dYaw) < 0.5 && abs(dPitch) < 0.5)
        let pitchDeg = asin(min(max(g.z, -1), 1)) * 180 / .pi      // optical axis (-Z) above the horizon
        let rollDeg = atan2(g.x, -g.y) * 180 / .pi
        return Reading(motion: motion, pitchDeg: pitchDeg, rollDeg: rollDeg, angularRate: w, steady: w < 0.25 && a < 0.06)
    }
}
