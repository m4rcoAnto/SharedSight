import Foundation

/// The mission state machine. Raw values are the names used in the project brief.
public enum DroneMissionState: String, Sendable, Codable, CaseIterable {
    case off = "OFF"
    case preparing = "PREPARING"
    case authorizationRequired = "AUTHORIZATION_REQUIRED"
    case searchingForTarget = "SEARCHING_FOR_TARGET"
    case targetLocked = "TARGET_LOCKED"
    case following = "FOLLOWING"
    case targetLost = "TARGET_LOST"
    case paused = "PAUSED"
    case returnRequested = "RETURN_REQUESTED"
    case landing = "LANDING"
    case landed = "LANDED"
    case error = "ERROR"

    /// The complete transition table. Anything not listed here is refused by the controller.
    public var allowedNextStates: Set<DroneMissionState> {
        switch self {
        case .off: return [.authorizationRequired]
        case .authorizationRequired: return [.preparing, .off, .error]
        case .preparing: return [.searchingForTarget, .returnRequested, .error]
        case .searchingForTarget: return [.targetLocked, .paused, .returnRequested, .error]
        case .targetLocked: return [.following, .paused, .targetLost, .returnRequested, .error]
        case .following: return [.paused, .targetLost, .returnRequested, .error]
        case .paused: return [.following, .searchingForTarget, .targetLost, .returnRequested, .error]
        case .targetLost: return [.targetLocked, .paused, .returnRequested, .error]
        case .returnRequested: return [.landing, .error]
        case .landing: return [.landed, .error]
        case .landed: return [.off, .authorizationRequired]
        case .error: return [.off]
        }
    }

    public func canTransition(to next: DroneMissionState) -> Bool { allowedNextStates.contains(next) }

    /// States in which target observations are read. In every other state they are ignored.
    public var acceptsObservations: Bool {
        switch self {
        case .searchingForTarget, .targetLocked, .following, .paused, .targetLost: return true
        default: return false
        }
    }

    /// False for `off`, `landed` and `error`.
    public var isMissionActive: Bool {
        switch self {
        case .off, .landed, .error: return false
        default: return true
        }
    }
}

public enum DronePauseReason: String, Sendable, Codable, CaseIterable {
    /// The emergency "Stop Following" action. Only `resumeFollowing()` leaves this pause.
    case stoppedByUser
    case targetOccluded
    case lowConfidence
    case staleData
    case identityAmbiguous
}

public enum DroneMissionError: Sendable, Equatable {
    case vehicleFault(String)
}

public enum DroneActivationRefusal: String, Sendable, Codable {
    /// The host has no registered person to follow. The kit never picks someone by itself.
    case noRegisteredTarget
}
