import Combine
import SwiftUI
import UIKit
import SharedSightCore
import FieldVisionDroneKit

// Integration with FieldVisionDroneKit. It needs no change to AppModel:
// it reads `model.$snapshot` (the publisher of the existing @Published property) and uses the existing
// `engine.audio.sayStatus(_:haptic:)`, `startTracking()`, `activeProfileID`, `language`, `trackingOn`.

/// Owner authorization for the app: Face ID / passcode, skipped only while presentation mode is on.
final class PresentationAuthorizer: OwnerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var skip = false

    func setSkip(_ value: Bool) {
        lock.withLock { skip = value }
    }

    func authorizeOwner(reason: String) async -> OwnerAuthorizationResult {
        let skipped = lock.withLock { skip }
        if skipped { return .authorized }
        return await LocalDeviceOwnerAuthorizer().authorizeOwner(reason: reason)
    }
}

/// Connects the drone module to the running SharedSight app:
/// - every perception snapshot is forwarded to the kit as a target observation;
/// - mission events go to SharedSight's own speech and haptics (the kit never speaks by itself);
/// - starting drone mode also starts SharedSight's target tracking, so one button does everything.
///
/// Presentation mode replaces the camera with the kit's labelled test data, so every mission state can
/// be shown and captured without a marker, a second person or Face ID. The screen keeps its
/// SIMULATION and TEST DATA labels.
@MainActor
final class DroneCompanionCoordinator: ObservableObject {
    /// Stands in for a registered person when presentation mode is used with nobody registered.
    static let presentationTargetID = UUID(uuidString: "00000000-0000-4000-8000-0000000D120E") ?? UUID()

    let controller: DroneCompanionController
    @Published private(set) var presentationMode = false
    @Published private(set) var feed: SyntheticTargetFeed?
    /// Longer simulated phases while presenting, so each state stays on screen for a few seconds.
    @Published var slowPhases = true { didSet { applyTimings() } }

    private let vehicle: SimulatedDroneAdapter
    private let authorization: PresentationAuthorizer
    private weak var model: AppModel?
    private var cancellable: AnyCancellable?

    init() {
        let vehicle = SimulatedDroneAdapter()
        let authorization = PresentationAuthorizer()
        self.vehicle = vehicle
        self.authorization = authorization
        controller = DroneCompanionController(authorizer: authorization, vehicle: vehicle)
    }

    func attach(to model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        cancellable = model.$snapshot.sink { [weak self] snapshot in self?.forward(snapshot) }
        controller.onEvent = { [weak self] event in self?.present(event) }
    }

    /// Who the drone button follows: the registered person, or the test target in presentation mode.
    func targetID(activeProfileID: UUID?) -> UUID? {
        presentationMode ? feed?.targetID : activeProfileID
    }

    /// Can only change between missions: a running mission keeps the target it was started with.
    func setPresentationMode(_ on: Bool) {
        guard on != presentationMode, !controller.state.isMissionActive else { return }
        feed?.stop()
        if on {
            let feed = SyntheticTargetFeed(targetID: model?.activeProfileID ?? Self.presentationTargetID)
            feed.start(feeding: controller)
            self.feed = feed
        } else {
            feed = nil
        }
        presentationMode = on
        authorization.setSkip(on)
        applyTimings()
    }

    private func applyTimings() {
        let slow = presentationMode && slowPhases
        let defaults = DroneCompanionConfiguration()
        controller.configuration.settleSeconds = slow ? 4 : defaults.settleSeconds
        controller.configuration.occlusionGraceSeconds = slow ? 8 : defaults.occlusionGraceSeconds
        controller.configuration.ambiguousTimeoutSeconds = slow ? 15 : defaults.ambiguousTimeoutSeconds
        var timing = SimulatedDroneAdapter.Timing()
        if slow {
            timing.preflightSeconds = 4
            timing.returnSeconds = 5
            timing.landingSeconds = 5
        }
        vehicle.timing = timing
    }

    private func forward(_ snapshot: AppModel.Snapshot) {
        guard !presentationMode else { return }          // test data and camera data are never mixed
        let host = SharedSightDroneBridge.snapshot(status: snapshot.target, guidance: snapshot.guidance)
        guard let observation = DroneTargetObservation(host: host, timestamp: controller.currentTime) else { return }
        controller.submit(observation)
    }

    private func present(_ event: DroneMissionEvent) {
        guard let model else { return }
        // Drone mode needs SharedSight to be looking for the registered person's marker.
        if event == .droneModeActivated, !presentationMode, !model.trackingOn { model.startTracking() }
        guard presentationMode || Self.isAnnounced(event) else { return }

        let text = event.announcement(model.language == .italian ? .italian : .english, simulated: controller.isSimulation)
        let haptic: UINotificationFeedbackGenerator.FeedbackType?
        switch event.severity {
        case .success: haptic = .success
        case .warning: haptic = .warning
        case .critical: haptic = .error
        case .info: haptic = nil
        }
        if UIAccessibility.isVoiceOverRunning {
            model.engine.audio.sayStatus("", haptic: haptic)                 // haptic only; VoiceOver speaks
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            model.engine.audio.sayStatus(text, haptic: haptic)               // never interrupts an obstacle alert
        }
    }

    /// SharedSight already announces "target locked / hidden / uncertain / lost" for the same person.
    /// Those kit events are shown on screen but not spoken a second time.
    private static func isAnnounced(_ event: DroneMissionEvent) -> Bool {
        switch event {
        case .targetAcquired, .targetLost, .searchingForTarget, .followingResumed:
            return false
        case let .followingPaused(reason):
            return reason == .stoppedByUser || reason == .staleData
        default:
            return true
        }
    }
}
