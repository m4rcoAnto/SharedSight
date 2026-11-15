import Foundation
import Combine

/// Manual test data for the standalone demo and for development without a camera.
///
/// Every observation it produces is stamped `origin: .syntheticTestData`, and `DroneSimulationView`
/// shows a TEST DATA badge while such observations are in use. It is never a substitute for the host's
/// real perception: in the app, observations come from SharedSight.
@MainActor
public final class SyntheticTargetFeed: ObservableObject {

    public enum Script: String, CaseIterable, Identifiable, Sendable {
        /// Nothing moves by itself: the published properties below are the input.
        case manual
        /// The target walks left and right, always visible and verified.
        case walking
        /// As `walking`, hidden for about a second every few seconds (temporary occlusion).
        case occlusion
        /// As `walking`, with periods where the identity is ambiguous (someone crossing).
        case crossing
        /// The target leaves the view for several seconds and comes back (target lost, reacquired).
        case leaves

        public var id: String { rawValue }
    }

    @Published public var script: Script = .walking { didSet { scriptTime = 0 } }
    /// 0 (left) … 1 (right).
    @Published public var centerX = 0.5
    @Published public var confidence = 0.9
    /// False = the position is only a prediction (occluded).
    @Published public var isDirectlyObserved = true
    @Published public var isIdentityVerified = true
    @Published public var isIdentityAmbiguous = false
    @Published public private(set) var isRunning = false

    /// Stands in for the registered person's persistent ID.
    public let targetID: UUID

    private var scriptTime = 0.0
    private var task: Task<Void, Never>?

    public init(targetID: UUID = UUID()) {
        self.targetID = targetID
    }

    /// Starts submitting labelled test observations to `controller` about 15 times a second.
    public func start(feeding controller: DroneCompanionController) {
        stop()
        isRunning = true
        task = Task { [weak self, weak controller] in
            var last: TimeInterval?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 66_000_000)
                guard let self, let controller, !Task.isCancelled else { return }
                let now = controller.currentTime
                self.step(by: min(max(now - (last ?? now), 0), 0.25))
                last = now
                controller.submit(self.makeObservation(at: now))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// The observation for the current property values.
    public func makeObservation(at timestamp: TimeInterval) -> DroneTargetObservation {
        let known = isIdentityVerified || isIdentityAmbiguous
        return DroneTargetObservation(
            targetID: targetID,
            normalizedCenterX: known ? centerX : nil,
            normalizedCenterY: known ? 0.5 : nil,
            boundingBoxArea: known ? 0.08 : nil,
            confidence: isIdentityVerified ? confidence : 0,
            isDirectlyObserved: isDirectlyObserved && isIdentityVerified,
            isIdentityVerified: isIdentityVerified && !isIdentityAmbiguous,
            isIdentityAmbiguous: isIdentityAmbiguous,
            timestamp: timestamp,
            hostGuidance: nil,
            origin: .syntheticTestData)
    }

    /// Advances the selected script. Public so tests can drive it without a timer.
    public func step(by dt: TimeInterval) {
        guard script != .manual else { return }
        scriptTime += dt
        let t = scriptTime
        centerX = 0.5 + 0.36 * sin(t * 0.7)
        var observed = true, verified = true, ambiguous = false
        switch script {
        case .manual, .walking:
            break
        case .occlusion:
            observed = t.truncatingRemainder(dividingBy: 7) < 6          // hidden 1 s out of every 7
        case .crossing:
            ambiguous = t.truncatingRemainder(dividingBy: 9) >= 6.5      // uncertain 2.5 s out of every 9
        case .leaves:
            verified = t.truncatingRemainder(dividingBy: 12) < 7         // gone 5 s out of every 12
        }
        if isDirectlyObserved != observed { isDirectlyObserved = observed }
        if isIdentityVerified != verified { isIdentityVerified = verified }
        if isIdentityAmbiguous != ambiguous { isIdentityAmbiguous = ambiguous }
    }
}
