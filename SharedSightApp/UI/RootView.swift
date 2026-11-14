import SwiftUI
import SharedSightCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.onboarded { MainView() } else { OnboardingView() }
    }
}

/// Large, high-contrast, label-first button used everywhere. State is always in the text, never only in colour.
struct BigButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: prominent ? 120 : 76)
                .padding(.horizontal, 12)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(prominent ? Color.yellow : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: prominent ? 0 : 2))
        }
        .buttonStyle(.plain)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Shared Sight").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(model.tr(
                    "Shared Sight uses the rear camera to tell you about people and objects it recognises. Hold the phone upright with the camera facing forward.",
                    "Shared Sight usa la fotocamera posteriore per descriverti persone e oggetti che riconosce. Tieni il telefono in verticale con la fotocamera rivolta in avanti."))
                Text(model.tr(
                    "This is an experimental awareness aid. It does not see everything, it can be wrong, and it never tells you that a path is free. Keep using your white cane, guide dog and usual mobility techniques.",
                    "È un aiuto sperimentale alla consapevolezza. Non vede tutto, può sbagliare e non ti dirà mai che un percorso è libero. Continua a usare il bastone bianco, il cane guida e le tue tecniche di mobilità."))
                    .fontWeight(.semibold)
                Picker(model.tr("Language", "Lingua"), selection: $model.language) {
                    Text("English").tag(SpeechLanguage.english)
                    Text("Italiano").tag(SpeechLanguage.italian)
                }
                .pickerStyle(.segmented)
                BigButton(title: model.tr("I understand. Start.", "Ho capito. Avvia."), systemImage: "play.fill", prominent: true) {
                    model.onboarded = true
                }
            }
            .font(.title3)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var askConsent = false
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.perceptionStatusText, systemImage: perceptionIcon).font(.title3.weight(.semibold))
                Label(model.collaborationStatusText, systemImage: "person.2.wave.2").font(.body)
                if !model.snapshot.lastSpoken.isEmpty {
                    Text(model.tr("Last announcement: ", "Ultimo annuncio: ") + model.snapshot.lastSpoken).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(model.tr("Status", "Stato"))
            .accessibilityValue(model.perceptionStatusText + " " + model.collaborationStatusText)

            Spacer(minLength: 0)

            BigButton(title: model.paused ? model.tr("Resume perception", "Riprendi percezione") : model.tr("Pause perception", "Metti in pausa"),
                      systemImage: model.paused ? "play.fill" : "pause.fill", prominent: true) { model.togglePause() }
                .accessibilityHint(model.tr("Stops or restarts the camera and all announcements.", "Ferma o riavvia la fotocamera e tutti gli annunci."))

            BigButton(title: model.audioOn ? model.tr("Speech is on. Turn off.", "Voce attiva. Disattiva.") : model.tr("Speech is off. Turn on.", "Voce disattivata. Attiva."),
                      systemImage: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill") { model.audioOn.toggle() }

            BigButton(title: model.collaborationOn ? model.tr("Collaboration is on. Stop sharing.", "Collaborazione attiva. Interrompi condivisione.")
                                                   : model.tr("Collaboration is off. Turn on.", "Collaborazione disattivata. Attiva."),
                      systemImage: model.collaborationOn ? "person.2.fill" : "person.2.slash") {
                if model.collaborationOn { model.setCollaboration(false) } else { askConsent = true }
            }

            HStack(spacing: 12) {
                BigButton(title: model.tr("Settings", "Impostazioni"), systemImage: "gearshape") { showSettings = true }
                BigButton(title: model.tr("Diagnostics", "Diagnostica"), systemImage: "waveform.path.ecg") { showDiagnostics = true }
            }
        }
        .padding(18)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .alert(model.tr("Share observations?", "Condividere le osservazioni?"), isPresented: $askConsent) {
            Button(model.tr("Share", "Condividi")) { model.setCollaboration(true) }
            Button(model.tr("Cancel", "Annulla"), role: .cancel) {}
        } message: {
            Text(model.tr(
                "Your phone will exchange obstacle observations with nearby Shared Sight devices that use session code \(model.sessionCode): object type, time and, when measured, position. No video, no photos, no face recognition. You can stop at any time.",
                "Il telefono scambierà osservazioni sugli ostacoli con i dispositivi Shared Sight vicini che usano il codice sessione \(model.sessionCode): tipo di oggetto, orario e, se misurata, posizione. Nessun video, nessuna foto, nessun riconoscimento facciale. Puoi interrompere in qualsiasi momento."))
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView().environmentObject(model) }
    }

    private var perceptionIcon: String {
        switch model.snapshot.reliability.status(.semanticDetection).state {
        case .reliable: return "eye.fill"
        case .degraded: return "eye.trianglebadge.exclamationmark"
        case .unavailable: return "eye.slash.fill"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(model.tr("Speech", "Voce")) {
                    Picker(model.tr("Language", "Lingua"), selection: $model.language) {
                        Text("English").tag(SpeechLanguage.english)
                        Text("Italiano").tag(SpeechLanguage.italian)
                    }
                    Picker(model.tr("Detail level", "Livello di dettaglio"), selection: $model.verbosity) {
                        Text(model.tr("Minimal", "Minimo")).tag(Verbosity.minimal)
                        Text(model.tr("Normal", "Normale")).tag(Verbosity.normal)
                        Text(model.tr("Detailed", "Dettagliato")).tag(Verbosity.detailed)
                    }
                    Toggle(model.tr("Vibration", "Vibrazione"), isOn: $model.haptics)
                }
                Section {
                    Toggle(model.tr("Spatial mode", "Modalità spaziale"), isOn: $model.spatialMode)
                        .disabled(!ARFrameProvider.isSupported)
                    TextField(model.tr("Session code", "Codice sessione"), text: $model.sessionCode)
                        .keyboardType(.numberPad)
                        .accessibilityLabel(model.tr("Session code", "Codice sessione"))
                    Stepper(value: $model.markerWidthCm, in: 5...60, step: 0.5) {
                        Text(model.tr("Printed marker width: ", "Larghezza del marcatore stampato: ") + String(format: "%.1f cm", model.markerWidthCm))
                    }
                } header: {
                    Text(model.tr("Collaboration", "Collaborazione"))
                } footer: {
                    Text(model.tr(
                        "Spatial mode measures distances from the floor geometry and is required to locate another device's observations. Both phones must look once at the same printed marker; restart spatial mode after changing the marker width.",
                        "La modalità spaziale misura le distanze dalla geometria del pavimento ed è necessaria per localizzare le osservazioni di un altro dispositivo. Entrambi i telefoni devono inquadrare una volta lo stesso marcatore stampato; riavvia la modalità spaziale dopo aver cambiato la larghezza del marcatore."))
                }
            }
            .navigationTitle(model.tr("Settings", "Impostazioni"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.tr("Done", "Fine")) { dismiss() } } }
        }
    }
}
