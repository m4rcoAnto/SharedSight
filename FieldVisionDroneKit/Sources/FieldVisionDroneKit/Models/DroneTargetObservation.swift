import Foundation

/// Where an observation came from. Synthetic data is always labelled, so no screen can present it as real.
public enum DroneObservationOrigin: String, Sendable, Codable {
    /// Produced by the host application's real perception pipeline.
    case liveHost
    /// Produced by `SyntheticTargetFeed` or any other manual test source.
    case syntheticTestData
}

/// Follow guidance the host application already computed (for example SharedSight's `FollowGuidance`).
/// When an observation carries one, the kit reuses it instead of running its own smoothing and dead zones.
public struct HostFollowGuidance: Sendable, Equatable {
    /// False when the host is holding its guidance (settling, low confidence, prediction only…).
    public var isActive: Bool
    public var horizontal: DroneHorizontalCue
    public var vertical: DroneVerticalCue
    /// Smoothed offset of the target from the image centre, -1 (left edge) … +1 (right edge).
    public var horizontalOffset: Double
    /// -1 (top) … +1 (bottom).
    public var verticalOffset: Double

    public init(isActive: Bool, horizontal: DroneHorizontalCue = .centered, vertical: DroneVerticalCue = .centered,
                horizontalOffset: Double = 0, verticalOffset: Double = 0) {
        self.isActive = isActive
        self.horizontal = horizontal
        self.vertical = vertical
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
    }
}

/// One statement by the host about the registered target at one moment.
///
/// The kit never looks at camera frames and never chooses a person. It only reacts to what the host
/// reports here. Send one observation per perception update (10–30 Hz), including when the target is
/// *not* seen: an observation with `isIdentityVerified == false` means "fresh data, target not confirmed",
/// which is different from sending nothing (stale data).
public struct DroneTargetObservation: Sendable, Equatable {
    /// Persistent identifier of the registered person (SharedSight: `PersonProfile.id`).
    /// Must equal the `targetID` the mission was started with, otherwise the observation is rejected.
    public let targetID: UUID
    /// Target centre in the upright camera image, 0 (left) … 1 (right). Nil when no position is known.
    public let normalizedCenterX: Double?
    /// 0 (top) … 1 (bottom).
    public let normalizedCenterY: Double?
    /// Fraction of the image covered by the target's box. A visual cue only: never a distance.
    public let boundingBoxArea: Double?
    /// 0 … 1. How much the host trusts the association between the registered person and this position.
    public let confidence: Double
    /// True only when the position comes from a detection in the current frame. False for predictions.
    public let isDirectlyObserved: Bool
    /// True only when the host has explicit evidence that this is the registered person
    /// (SharedSight: marker read or operator confirmation, target state acquired / following / occluded).
    public let isIdentityVerified: Bool
    /// True when the host cannot tell which person is the target. Following pauses until this clears.
    public let isIdentityAmbiguous: Bool
    /// Seconds on the same monotonic clock as `DroneCompanionController.currentTime`
    /// (default `ProcessInfo.processInfo.systemUptime`, the same base as `CACurrentMediaTime()`).
    public let timestamp: TimeInterval
    /// Optional guidance already computed by the host.
    public let hostGuidance: HostFollowGuidance?
    public let origin: DroneObservationOrigin

    public init(targetID: UUID,
                normalizedCenterX: Double?,
                normalizedCenterY: Double?,
                boundingBoxArea: Double? = nil,
                confidence: Double,
                isDirectlyObserved: Bool,
                isIdentityVerified: Bool,
                isIdentityAmbiguous: Bool = false,
                timestamp: TimeInterval,
                hostGuidance: HostFollowGuidance? = nil,
                origin: DroneObservationOrigin = .liveHost) {
        self.targetID = targetID
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.boundingBoxArea = boundingBoxArea
        self.confidence = confidence
        self.isDirectlyObserved = isDirectlyObserved
        self.isIdentityVerified = isIdentityVerified
        self.isIdentityAmbiguous = isIdentityAmbiguous
        self.timestamp = timestamp
        self.hostGuidance = hostGuidance
        self.origin = origin
    }
}
