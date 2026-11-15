import Foundation
import SharedSightCore
import FieldVisionDroneKit

// Copy this file into the SharedSight app target (for example SharedSightApp/Drone/).
// It is the only place where SharedSightCore types meet FieldVisionDroneKit types, so the package itself
// never depends on the SharedSight source tree. Nothing in SharedSightCore has to change.

/// Thin field-copying adapter: SharedSight's `TargetStatus` + `FollowGuidance` -> `HostTargetSnapshot`.
/// The decisions (what counts as verified, observed, ambiguous) are made and unit-tested inside the kit,
/// in `DroneTargetObservation.init?(host:timestamp:origin:)`.
enum SharedSightDroneBridge {

    static func snapshot(status: TargetStatus, guidance: FollowGuidance) -> HostTargetSnapshot {
        HostTargetSnapshot(
            targetID: status.profileID,                       // PersonProfile.id, the persistent UUID
            phase: phase(status.state),
            centerX: status.box?.cx,
            centerY: status.box?.cy,
            boundingBoxArea: guidance.boundingBoxArea,
            confidence: status.associationConfidence,
            positionIsPredicted: status.boxIsPredicted,
            guidance: hostGuidance(guidance))
    }

    static func phase(_ state: TargetTrackingState) -> HostTargetPhase {
        switch state {
        case .unassigned: return .notTracking
        case .searching: return .searching
        case .acquired: return .locked
        case .following: return .following
        case .temporarilyOccluded: return .occluded
        case .ambiguous: return .ambiguous
        case .lost: return .lost
        }
    }

    /// Reuses SharedSight's own smoothed, dead-zoned, confidence-gated guidance instead of recomputing it.
    static func hostGuidance(_ guidance: FollowGuidance) -> HostFollowGuidance {
        let horizontal: DroneHorizontalCue
        switch guidance.horizontal {
        case .left: horizontal = .left
        case .centered: horizontal = .centered
        case .right: horizontal = .right
        }
        let vertical: DroneVerticalCue
        switch guidance.vertical {
        case .up: vertical = .up
        case .centered: vertical = .centered
        case .down: vertical = .down
        }
        return HostFollowGuidance(isActive: guidance.active, horizontal: horizontal, vertical: vertical,
                                  horizontalOffset: guidance.horizontalOffset, verticalOffset: guidance.verticalOffset)
    }
}
