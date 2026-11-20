import Foundation

/// Thresholds and timings. The defaults are engineering starting points, not values tuned in flight.
public struct DroneCompanionConfiguration: Sendable {
    // Observation acceptance
    /// Observations with a lower `confidence` never start or keep guidance.
    public var minimumConfidence = 0.35
    /// An observation older than this (against `currentTime`) is rejected, and following pauses when
    /// no newer one arrives.
    public var staleAfterSeconds = 0.6

    // Lock and follow timing
    /// A verified, directly observed target must be reported continuously for this long before lock.
    public var lockHoldSeconds = 0.3
    /// Time in TARGET_LOCKED before guidance starts (FOLLOWING).
    public var settleSeconds = 0.5
    /// How long invalid observations are tolerated before the state becomes PAUSED.
    /// Guidance itself is held from the first invalid observation.
    public var pauseDelaySeconds = 0.3
    /// Total time without a valid observation before TARGET_LOST.
    public var occlusionGraceSeconds = 1.5
    /// How long an ambiguous identity may last before TARGET_LOST.
    public var ambiguousTimeoutSeconds = 6.0

    // Kit guidance (used when the host sends no guidance of its own)
    public var deadZoneX = 0.16
    public var deadZoneY = 0.24
    public var hysteresis = 0.05
    public var smoothingSeconds = 0.25
    /// Reuse `DroneTargetObservation.hostGuidance` when present.
    public var prefersHostGuidance = true

    // Runtime
    /// The controller advances itself on a timer. Turn off to drive it with `advance(to:)` (unit tests).
    public var runsInternalTicker = true
    public var tickInterval = 0.05
    /// Text shown by the system authentication prompt.
    public var authorizationReason = "Authorize Drone Companion"

    public init() {}
}
