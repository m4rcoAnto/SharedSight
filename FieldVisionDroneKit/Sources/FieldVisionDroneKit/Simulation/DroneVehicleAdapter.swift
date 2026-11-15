import Foundation

/// What the mission controller asks of a vehicle. These are intents, not motor commands: units, limits,
/// rates and every safety envelope belong to the adapter of a specific aircraft.
public enum DroneVehicleCommand: Sendable, Equatable {
    case prepare
    /// Keep the target centred. Sent only while guidance is active.
    case follow(DroneFollowGuidance)
    /// Stop correcting and hold position.
    case hold
    /// End the mission: come back to the user and land.
    case returnToUser
    /// Mission is over or was reset: release everything.
    case shutdown
}

public enum DroneVehiclePhase: Sendable, Equatable {
    case inactive
    case preparing
    case hovering
    case following
    case returning
    case landing
    case landed
    case fault(String)
}

public struct DroneVehicleTelemetry: Sendable, Equatable {
    public var phase: DroneVehiclePhase = .inactive
    /// 0 (ground) … 1 (working height). Unitless in the simulator.
    public var altitude = 0.0
    /// -1 … +1: the follow correction currently applied (left negative).
    public var correction = 0.0
    /// 0 … 1 inside `preparing`, `returning` and `landing`.
    public var phaseProgress = 0.0

    public init() {}
}

/// The seam for a vehicle. `SimulatedDroneAdapter` is the only implementation in this package.
///
/// A hardware adapter must bring its own, independently validated safety layer: geofence, altitude and
/// speed limits, link-loss failsafe, obstacle avoidance, manual override, and a landing / docking
/// procedure. The controller assumes none of that and never claims it exists.
@MainActor
public protocol DroneVehicleAdapter: AnyObject {
    /// True when nothing physical moves. The UI and announcements label everything as simulated.
    var isSimulation: Bool { get }
    var telemetry: DroneVehicleTelemetry { get }
    func handle(_ command: DroneVehicleCommand, at time: TimeInterval)
    /// Called by the controller on every tick so the vehicle can update `telemetry`.
    func advance(to time: TimeInterval)
}
