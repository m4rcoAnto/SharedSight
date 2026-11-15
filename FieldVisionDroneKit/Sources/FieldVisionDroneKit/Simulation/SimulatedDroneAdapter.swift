import Foundation

/// A drone that exists only as numbers. It reacts to the same commands a real adapter would receive and
/// reports timed phases (preflight, hover, return, landing), so the whole mission can be demonstrated
/// and tested without hardware. Nothing here moves anything.
@MainActor
public final class SimulatedDroneAdapter: DroneVehicleAdapter {

    public struct Timing: Sendable {
        public var preflightSeconds = 1.5
        public var returnSeconds = 2.5
        public var landingSeconds = 2.5
        /// Time constant with which the displayed correction follows the commanded one.
        public var correctionResponseSeconds = 0.35
        public init() {}
    }

    public let isSimulation = true
    public var timing: Timing
    public private(set) var telemetry = DroneVehicleTelemetry()
    public private(set) var lastCommand: DroneVehicleCommand?

    private var phaseStart: TimeInterval = 0
    private var lastStep: TimeInterval?
    private var correctionTarget = 0.0
    private var landingStartAltitude = 1.0

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public func handle(_ command: DroneVehicleCommand, at time: TimeInterval) {
        lastCommand = command
        switch command {
        case .prepare:
            guard telemetry.phase == .inactive || telemetry.phase == .landed else { return }
            telemetry = DroneVehicleTelemetry()
            correctionTarget = 0
            enter(.preparing, at: time)
        case let .follow(guidance):
            guard telemetry.phase == .hovering || telemetry.phase == .following else { return }
            telemetry.phase = .following
            let wanted = guidance.isActive && guidance.horizontal != .centered ? guidance.horizontalOffset : 0
            correctionTarget = min(max(wanted, -1), 1)
        case .hold:
            if telemetry.phase == .following { telemetry.phase = .hovering }
            correctionTarget = 0
        case .returnToUser:
            switch telemetry.phase {
            case .preparing, .hovering, .following:
                correctionTarget = 0
                enter(.returning, at: time)
            default:
                break
            }
        case .shutdown:
            telemetry = DroneVehicleTelemetry()
            correctionTarget = 0
            lastStep = nil
        }
    }

    public func advance(to time: TimeInterval) {
        let dt = min(max(time - (lastStep ?? time), 0), 0.5)
        lastStep = time
        let elapsed = max(0, time - phaseStart)
        switch telemetry.phase {
        case .preparing:
            let p = Self.progress(elapsed, timing.preflightSeconds)
            telemetry.phaseProgress = p
            telemetry.altitude = p
            if p >= 1 { enter(.hovering, at: time) }
        case .hovering, .following:
            telemetry.altitude = 1
            approachCorrection(dt)
        case .returning:
            let p = Self.progress(elapsed, timing.returnSeconds)
            telemetry.phaseProgress = p
            approachCorrection(dt)
            if p >= 1 {
                landingStartAltitude = telemetry.altitude
                enter(.landing, at: time)
            }
        case .landing:
            let p = Self.progress(elapsed, timing.landingSeconds)
            telemetry.phaseProgress = p
            telemetry.altitude = landingStartAltitude * (1 - p)
            if p >= 1 {
                telemetry.altitude = 0
                telemetry.correction = 0
                enter(.landed, at: time)
            }
        case .inactive, .landed, .fault:
            break
        }
    }

    /// Test / demo hook: the simulated vehicle reports a failure.
    public func simulateFault(_ message: String) {
        telemetry.phase = .fault(message)
        correctionTarget = 0
    }

    private func enter(_ phase: DroneVehiclePhase, at time: TimeInterval) {
        telemetry.phase = phase
        telemetry.phaseProgress = 0
        phaseStart = time
    }

    private func approachCorrection(_ dt: Double) {
        let tau = max(timing.correctionResponseSeconds, 0.01)
        let alpha = 1 - exp(-dt / tau)
        telemetry.correction += alpha * (correctionTarget - telemetry.correction)
        if abs(telemetry.correction) < 0.001, correctionTarget == 0 { telemetry.correction = 0 }
    }

    private static func progress(_ elapsed: Double, _ duration: Double) -> Double {
        duration <= 0 ? 1 : min(max(elapsed / duration, 0), 1)
    }
}
