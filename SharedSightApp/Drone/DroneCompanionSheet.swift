import SwiftUI
import SharedSightCore
import FieldVisionDroneKit

// Integration with FieldVisionDroneKit. Uses the app's existing `Theme` and `AppModel.tr`.

/// The drone screen: simulation, the drone button and the emergency stop. Closing the sheet does not
/// end the mission; the coordinator lives in LiveVisionView.
struct DroneCompanionSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coordinator: DroneCompanionCoordinator
    @Environment(\.dismiss) private var dismiss
    /// Shows the presentation controls. Off = only the drone panel, a one-line note and this switch.
    /// Turning it off hides the controls; it does not turn presentation mode off.
    @AppStorage("droneDebugMode") private var debugMode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DroneCompanionPanel(controller: coordinator.controller,
                                        targetID: coordinator.targetID(activeProfileID: model.activeProfileID),
                                        language: model.language == .italian ? .italian : .english)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if debugMode {
                        PresentationModeCard(coordinator: coordinator, controller: coordinator.controller)
                        if let feed = coordinator.feed {
                            PresentationTargetCard(feed: feed)
                        }
                    }

                    Toggle(model.tr("Debug mode", "Modalità debug"), isOn: $debugMode)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .accessibilityHint(model.tr("Shows or hides the presentation controls.",
                                                    "Mostra o nasconde i controlli di presentazione."))
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Drone Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.tr("Done", "Fine")) { dismiss() } }
            }
        }
    }

    /// One line under the panel. It never describes test data as coming from the camera.
    private var note: String {
        if coordinator.presentationMode {
            return debugMode
                ? model.tr("Presentation mode. No drone is connected and the target is test data, not the camera.",
                           "Modalità presentazione. Nessun drone è collegato e il bersaglio è un dato di prova, non la fotocamera.")
                : model.tr("Simulation. No drone is connected.", "Simulazione. Nessun drone è collegato.")
        }
        return model.tr("Simulation. No drone is connected. The target is the registered person, identified by Shared Sight's marker; Face ID only confirms the owner of this iPhone.",
                        "Simulazione. Nessun drone è collegato. Il bersaglio è la persona registrata, identificata dal marcatore di Shared Sight; Face ID conferma solo il proprietario di questo iPhone.")
    }
}

/// Switches between the camera (SharedSight) and labelled test data. Placed under the drone panel so
/// the panel itself can be captured cleanly.
private struct PresentationModeCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coordinator: DroneCompanionCoordinator
    @ObservedObject var controller: DroneCompanionController

    var body: some View {
        let busy = controller.state.isMissionActive
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { coordinator.presentationMode },
                                 set: { coordinator.setPresentationMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.tr("Presentation mode", "Modalità presentazione")).font(.headline)
                    Text(model.tr("Test data instead of the camera, no Face ID.",
                                  "Dati di prova al posto della fotocamera, senza Face ID."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(busy)
            if busy {
                Text(model.tr("End the mission to change mode.", "Termina la missione per cambiare modalità."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if coordinator.presentationMode {
                Toggle(model.tr("Slow phases (easier screenshots)", "Fasi lente (screenshot più facili)"),
                       isOn: $coordinator.slowPhases)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The test target: a scripted scenario, or manual control to hold any state for as long as needed.
private struct PresentationTargetCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var feed: SyntheticTargetFeed

    var body: some View {
        let manual = feed.script == .manual
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.tr("Test target", "Bersaglio di prova")).font(.headline)
                Spacer()
                Picker(model.tr("Scenario", "Scenario"), selection: $feed.script) {
                    Text(model.tr("Walking", "Cammina")).tag(SyntheticTargetFeed.Script.walking)
                    Text(model.tr("Manual", "Manuale")).tag(SyntheticTargetFeed.Script.manual)
                    Text(model.tr("Hidden briefly", "Nascosto per poco")).tag(SyntheticTargetFeed.Script.occlusion)
                    Text(model.tr("Someone crossing", "Qualcuno attraversa")).tag(SyntheticTargetFeed.Script.crossing)
                    Text(model.tr("Leaves and returns", "Esce e rientra")).tag(SyntheticTargetFeed.Script.leaves)
                }
                .pickerStyle(.menu)
            }
            if manual {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.tr("Position (left to right)", "Posizione (da sinistra a destra)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Slider(value: $feed.centerX, in: 0.05...0.95)
                        .accessibilityLabel(model.tr("Target position", "Posizione del bersaglio"))
                }
                Toggle(model.tr("Visible", "Visibile"), isOn: $feed.isDirectlyObserved)
                Toggle(model.tr("Identity verified", "Identità verificata"), isOn: $feed.isIdentityVerified)
                Toggle(model.tr("Identity uncertain", "Identità incerta"), isOn: $feed.isIdentityAmbiguous)
            } else {
                Text(model.tr("Choose Manual to hold a state for a screenshot.",
                              "Scegli Manuale per tenere fermo uno stato per lo screenshot."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
