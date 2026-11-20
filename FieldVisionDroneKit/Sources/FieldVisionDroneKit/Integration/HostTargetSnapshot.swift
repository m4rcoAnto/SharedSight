import Foundation

/// The host's own target-tracking state, in neutral terms. SharedSight's `TargetTrackingState` maps
/// onto it one to one (see `IntegrationExamples/SharedSight`).
public enum HostTargetPhase: String, Sendable, Codable, CaseIterable {
    case notTracking
    case searching
    /// Just associated with the registered person; the host is still settling.
    case locked
    case following
    /// Associated, not observed in the current frame; any position is a prediction.
    case occluded
    case ambiguous
    case lost
}

/// Everything a host needs to copy from its tracking pipeline, once per update. The conversion to
/// `DroneTargetObservation` lives in this package so it is tested here, and the host-side adapter
/// stays a few lines of field copying.
public struct HostTargetSnapshot: Sendable, Equatable {
    /// Persistent ID of the registered person being tracked. Nil = nobody selected.
    public var targetID: UUID?
    public var phase: HostTargetPhase
    public var centerX: Double?
    public var centerY: Double?
    public var boundingBoxArea: Double?
    public var confidence: Double
    /// True when the position comes from motion prediction, not from a detection in this frame.
    public var positionIsPredicted: Bool
    public var guidance: HostFollowGuidance?

    public init(targetID: UUID?, phase: HostTargetPhase, centerX: Double? = nil, centerY: Double? = nil,
                boundingBoxArea: Double? = nil, confidence: Double = 0, positionIsPredicted: Bool = false,
                guidance: HostFollowGuidance? = nil) {
        self.targetID = targetID
        self.phase = phase
        self.centerX = centerX
        self.centerY = centerY
        self.boundingBoxArea = boundingBoxArea
        self.confidence = confidence
        self.positionIsPredicted = positionIsPredicted
        self.guidance = guidance
    }
}

public extension DroneTargetObservation {
    /// Converts a host snapshot. Returns nil when the host has no registered target: there is nothing
    /// to report, and the kit must never follow "whoever is there".
    ///
    /// - `locked`, `following`: identity verified; directly observed unless the position is predicted.
    /// - `occluded`: identity still verified, not directly observed, host guidance dropped.
    /// - `ambiguous`: not verified, flagged ambiguous, confidence 0.
    /// - `notTracking`, `searching`, `lost`: not verified, no position, confidence 0.
    init?(host snapshot: HostTargetSnapshot, timestamp: TimeInterval, origin: DroneObservationOrigin = .liveHost) {
        guard let targetID = snapshot.targetID else { return nil }
        switch snapshot.phase {
        case .locked, .following:
            self.init(targetID: targetID, normalizedCenterX: snapshot.centerX, normalizedCenterY: snapshot.centerY,
                      boundingBoxArea: snapshot.boundingBoxArea, confidence: snapshot.confidence,
                      isDirectlyObserved: !snapshot.positionIsPredicted, isIdentityVerified: true,
                      isIdentityAmbiguous: false, timestamp: timestamp,
                      hostGuidance: snapshot.positionIsPredicted ? nil : snapshot.guidance, origin: origin)
        case .occluded:
            self.init(targetID: targetID, normalizedCenterX: snapshot.centerX, normalizedCenterY: snapshot.centerY,
                      boundingBoxArea: snapshot.boundingBoxArea, confidence: snapshot.confidence,
                      isDirectlyObserved: false, isIdentityVerified: true, isIdentityAmbiguous: false,
                      timestamp: timestamp, hostGuidance: nil, origin: origin)
        case .ambiguous:
            self.init(targetID: targetID, normalizedCenterX: snapshot.centerX, normalizedCenterY: snapshot.centerY,
                      boundingBoxArea: snapshot.boundingBoxArea, confidence: 0,
                      isDirectlyObserved: false, isIdentityVerified: false, isIdentityAmbiguous: true,
                      timestamp: timestamp, hostGuidance: nil, origin: origin)
        case .notTracking, .searching, .lost:
            self.init(targetID: targetID, normalizedCenterX: nil, normalizedCenterY: nil, boundingBoxArea: nil,
                      confidence: 0, isDirectlyObserved: false, isIdentityVerified: false, isIdentityAmbiguous: false,
                      timestamp: timestamp, hostGuidance: nil, origin: origin)
        }
    }
}

public enum DroneKitInfo {
    public static let version = "0.1.0"
}
