import Foundation

public enum DroneHorizontalCue: String, Sendable, Codable { case left, centered, right }
public enum DroneVerticalCue: String, Sendable, Codable { case up, centered, down }

/// Why no follow correction is being produced.
public enum DroneGuidanceHold: String, Sendable, Codable, CaseIterable {
    case missionInactive, preparing, searching, settling
    case targetOccluded, lowConfidence, staleData, identityAmbiguous, targetLost
    case stoppedByUser, heldByHost, returning, landing, fault
}

public enum DroneGuidanceSource: String, Sendable, Codable {
    /// Computed by the kit from the observation's position.
    case kit
    /// Taken from `DroneTargetObservation.hostGuidance`.
    case host
}

/// A suggested camera-follow correction. It is not a motor command: it says which way a following
/// camera should turn to keep the target centred. When `hold` is set, every cue is neutral.
public struct DroneFollowGuidance: Sendable, Equatable {
    /// Nil while guidance is active. Otherwise the reason it is held.
    public var hold: DroneGuidanceHold?
    public var horizontal: DroneHorizontalCue
    public var vertical: DroneVerticalCue
    /// Smoothed, -1 (left edge) … +1 (right edge).
    public var horizontalOffset: Double
    /// Smoothed, -1 (top) … +1 (bottom).
    public var verticalOffset: Double
    public var confidence: Double
    public var source: DroneGuidanceSource

    public var isActive: Bool { hold == nil }

    public init(hold: DroneGuidanceHold? = nil, horizontal: DroneHorizontalCue = .centered,
                vertical: DroneVerticalCue = .centered, horizontalOffset: Double = 0, verticalOffset: Double = 0,
                confidence: Double = 0, source: DroneGuidanceSource = .kit) {
        self.hold = hold
        self.horizontal = horizontal
        self.vertical = vertical
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.confidence = confidence
        self.source = source
    }

    /// Neutral guidance with a reason.
    public static func held(_ reason: DroneGuidanceHold, confidence: Double = 0) -> DroneFollowGuidance {
        DroneFollowGuidance(hold: reason, confidence: confidence)
    }
}
