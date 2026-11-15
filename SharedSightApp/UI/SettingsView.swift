import SwiftUI
import SharedSightCore

/// Everything that is not needed while walking: speech, tracking options, collaboration.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(model.tr("Language", "Lingua"), selection: $model.language) {
                        Text("English").tag(SpeechLanguage.english)
                        Text("Italiano").tag(SpeechLanguage.italian)
                    }
                    Picker(model.tr("Detail level", "Livello di dettaglio"), selection: $model.verbosity) {
                        Text(model.tr("Minimal", "Minimo")).tag(Verbosity.minimal)
                        Text(model.tr("Normal", "Normale")).tag(Verbosity.normal)
                        Text(model.tr("Detailed", "Dettagliato")).tag(Verbosity.detailed)
                    }
                    VStack(alignment: .leading) {
                        Text(model.tr("Speaking speed", "Velocità della voce"))
                        Slider(value: $model.speechRate, in: 0.8...1.6, step: 0.1) {
                            Text(model.tr("Speaking speed", "Velocità della voce"))
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "hare").accessibilityHidden(true)
                        }
                        .accessibilityValue(String(format: "%d%%", Int((model.speechRate * 100).rounded())))
                    }
                    Button(model.tr("Test the voice", "Prova la voce")) { model.testVoice() }
                    Toggle(model.tr("Vibration", "Vibrazione"), isOn: $model.haptics)
                } header: {
                    Text(model.tr("Speech", "Voce"))
                } footer: {
                    Text(model.tr(
                        "While VoiceOver is on, Shared Sight speaks with your VoiceOver voice and speed instead of this setting. Vibration: a strong tap for an obstacle ahead, a lighter tap for one reported by another device, a distinct error buzz when the camera cannot see.",
                        "Con VoiceOver attivo, Shared Sight parla con la voce e la velocità di VoiceOver invece di questa impostazione. Vibrazione: un colpo forte per un ostacolo davanti, uno più leggero per uno segnalato da un altro dispositivo, una vibrazione di errore distinta quando la fotocamera non vede."))
                }
                Section {
                    Toggle(model.tr("Show outlines", "Mostra contorni"), isOn: $model.showOutlines)
                    if let person = model.activeProfile {
                        Stepper(value: Binding(get: { person.preferences.occlusionGraceSeconds },
                                               set: { model.setOcclusionGrace($0) }), in: 0.5...1.5, step: 0.25) {
                            Text(model.tr("Keep hidden target for: ", "Mantieni bersaglio nascosto per: ")
                                 + String(format: "%.2f s", person.preferences.occlusionGraceSeconds))
                        }
                        .accessibilityLabel(model.tr("Keep hidden target for", "Mantieni bersaglio nascosto per"))
                        .accessibilityValue(String(format: model.tr("%.2f seconds", "%.2f secondi"), person.preferences.occlusionGraceSeconds))
                    }
                    Stepper(value: $model.eventRetentionDays, in: 1...30, step: 1) {
                        Text(model.tr("Keep tracking log: ", "Conserva registro: ") + String(format: model.tr("%.0f days", "%.0f giorni"), model.eventRetentionDays))
                    }
                    .accessibilityLabel(model.tr("Keep tracking log", "Conserva registro di tracciamento"))
                    .accessibilityValue(String(format: model.tr("%.0f days", "%.0f giorni"), model.eventRetentionDays))
                    Button(model.tr("Delete tracking log", "Elimina registro di tracciamento"), role: .destructive) { model.clearTrackingEvents() }
                        .disabled(model.trackingEvents.isEmpty)
                } header: {
                    Text(model.tr("Tracking", "Tracciamento"))
                } footer: {
                    Text(model.tr(
                        "While the target is hidden its box is a prediction, shown dashed, and following is paused. After this time it is reported lost. The log holds target state changes only (text, no images) and is stored on this iPhone.",
                        "Mentre il bersaglio è nascosto il suo riquadro è una previsione, mostrata tratteggiata, e l'inseguimento è in pausa. Dopo questo tempo viene dichiarato perso. Il registro contiene solo i cambi di stato del bersaglio (testo, nessuna immagine) ed è salvato su questo iPhone."))
                }
                Section {
                    TextField("URL server (http://IP-MAC:8080)", text: $model.serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.serverOn)
                    SecureField(model.tr("Server key", "Chiave server"), text: $model.serverToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.serverOn)
                    Toggle(model.tr("Send camera previews", "Invia anteprime fotocamera"), isOn: $model.serverPreviews)
                        .disabled(model.serverOn)
                    LabeledContent(model.tr("Status", "Stato"), value: model.snapshot.serverStatus)
                    Button(model.serverOn ? model.tr("Disconnect server", "Disconnetti server") : model.tr("Connect server", "Connetti al server")) {
                        model.toggleServer()
                    }
                    .disabled(!model.serverOn && model.serverToken.isEmpty)
                } header: { Text(model.tr("3D room · Local server", "Stanza 3D · Server locale"))
                } footer: {
                    Text(model.tr("Use the Mac's LAN address and the key printed by the server. Sends detections, surfaces and optional camera images while active. Point every iPhone at the same floor marker to align them.", "Usa l'indirizzo LAN del Mac e la chiave mostrata dal server. Invia rilevamenti, superfici e immagini opzionali mentre è attivo. Inquadra lo stesso marcatore sul pavimento con ogni iPhone per allinearli."))
                }
                Section {
                    Toggle(model.tr("Spatial mode", "Modalità spaziale"), isOn: $model.spatialMode)
                        .disabled(!ARFrameProvider.isSupported || model.serverOn)
                    LabeledContent(model.tr("Session code", "Codice sessione")) {
                        TextField(model.tr("Session code", "Codice sessione"), text: $model.sessionCode)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($codeFocused)
                            .disabled(model.serverOn)
                            .accessibilityLabel(model.tr("Session code", "Codice sessione"))
                            .accessibilityHint(model.tr("Both phones must use the same code.", "Entrambi i telefoni devono usare lo stesso codice."))
                    }
                    Stepper(value: $model.markerWidthCm, in: 5...60, step: 0.5) {
                        Text(model.tr("Printed marker width: ", "Larghezza del marcatore stampato: ") + String(format: "%.1f cm", model.markerWidthCm))
                    }
                    .accessibilityLabel(model.tr("Printed marker width", "Larghezza del marcatore stampato"))
                    .accessibilityValue(String(format: model.tr("%.1f centimeters", "%.1f centimetri"), model.markerWidthCm))
                } header: {
                    Text(model.tr("Collaboration", "Collaborazione"))
                } footer: {
                    Text(model.tr(
                        "Spatial mode measures distances from the floor geometry and is required to locate another device's observations. Both phones must look once at the same printed marker; restart spatial mode after changing the marker width.",
                        "La modalità spaziale misura le distanze dalla geometria del pavimento ed è necessaria per localizzare le osservazioni di un altro dispositivo. Entrambi i telefoni devono inquadrare una volta lo stesso marcatore stampato; riavvia la modalità spaziale dopo aver cambiato la larghezza del marcatore."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(model.tr("Settings", "Impostazioni"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.tr("Done", "Fine")) { dismiss() } }
                // The number pad has no return key; without this a VoiceOver user cannot dismiss it.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(model.tr("Close keyboard", "Chiudi tastiera")) { codeFocused = false }
                }
            }
        }
    }
}
