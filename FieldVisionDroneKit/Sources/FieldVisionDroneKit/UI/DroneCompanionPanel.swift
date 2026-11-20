import SwiftUI

/// Drop-in block for a host app: simulation, the drone button and the emergency stop, on one card.
/// Use the three views separately when the host wants its own layout.
@MainActor
public struct DroneCompanionPanel: View {
    private let controller: DroneCompanionController
    private let targetID: UUID?
    private let language: DroneKitLanguage

    public init(controller: DroneCompanionController, targetID: UUID?, language: DroneKitLanguage = .english) {
        self.controller = controller
        self.targetID = targetID
        self.language = language
    }

    public var body: some View {
        VStack(spacing: 14) {
            DroneSimulationView(controller: controller, language: language)
            DroneControlButton(controller: controller, targetID: targetID, language: language)
            DroneStopFollowingButton(controller: controller, language: language)
        }
        .padding(16)
        .background(DroneKitTheme.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .foregroundStyle(Color.white)
    }
}
