import Foundation

/// The kit's verdict on the most recent observation. Only `valid` can start a lock or keep guidance active.
public enum DroneObservationQuality: String, Sendable, Codable, CaseIterable {
    case valid
    case noData
    case stale
    case outOfOrder
    case wrongTarget
    case identityAmbiguous
    case identityUnverified
    case notDirectlyObserved
    case noPosition
    case lowConfidence
}

enum ObservationAssessor {
    /// Timestamps further in the future than this mean the host uses a different clock: treated as stale.
    static let futureTolerance = 0.5

    static func assess(_ observation: DroneTargetObservation?, expectedTarget: UUID?, now: TimeInterval,
                       configuration: DroneCompanionConfiguration) -> DroneObservationQuality {
        guard let o = observation else { return .noData }
        guard let expectedTarget, o.targetID == expectedTarget else { return .wrongTarget }
        guard o.timestamp.isFinite,
              now - o.timestamp <= configuration.staleAfterSeconds,
              o.timestamp - now <= futureTolerance else { return .stale }
        if o.isIdentityAmbiguous { return .identityAmbiguous }
        guard o.isIdentityVerified else { return .identityUnverified }
        guard o.isDirectlyObserved else { return .notDirectlyObserved }
        guard let x = o.normalizedCenterX, let y = o.normalizedCenterY, x.isFinite, y.isFinite,
              x >= 0, x <= 1, y >= 0, y <= 1 else { return .noPosition }
        guard o.confidence.isFinite, o.confidence >= configuration.minimumConfidence else { return .lowConfidence }
        return .valid
    }
}
