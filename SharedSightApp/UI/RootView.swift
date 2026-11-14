import SwiftUI
import SharedSightCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.onboarded { MainView() } else { OnboardingView() }
    }
}

/// Large, high-contrast, label-first button used everywhere.
///
/// Sighted and low-vision users read the full `title`, which always states the current state in words (never colour alone).
/// VoiceOver users hear a short `spokenLabel`, the state as a separate value, and a hint: the same way system switches read.
/// Height grows with Dynamic Type; the text wraps instead of truncating.
struct BigButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var spokenLabel: String?
    var spokenValue: String?
    var hint: String?
    var isToggle = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var regularHeight: CGFloat = 76
    @ScaledMetric(relativeTo: .title2) private var prominentHeight: CGFloat = 120
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: prominent ? prominentHeight : regularHeight)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(prominent ? Color.yellow : Color(white: contrast == .increased ? 0.0 : 0.16),
                            in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: prominent ? 0 : (contrast == .increased ? 3 : 2)))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel ?? title)
        .accessibilityValue(spokenValue ?? "")
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isToggle ? .isToggle : [])
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Shared Sight").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(model.tr(
                    "Shared Sight uses the rear camera to tell you about people and objects it recognises. Hold the phone upright with the camera facing forward, or wear it on your chest so your hands stay free.",
                    "Shared Sight usa la fotocamera posteriore per descriverti persone e oggetti che riconosce. Tieni il telefono in verticale con la fotocamera rivolta in avanti, oppure indossalo sul petto per avere le mani libere."))
                Text(model.tr(
                    "This is an experimental awareness aid. It does not see everything, it can be wrong, and it never tells you that a path is free. Keep using your white cane, guide dog and usual mobility techniques.",
                    "È un aiuto sperimentale alla consapevolezza. Non vede tutto, può sbagliare e non ti dirà mai che un percorso è libero. Continua a usare il bastone bianco, il cane guida e le tue tecniche di mobilità."))
                    .fontWeight(.semibold)
                Text(model.tr(
                    "It tells you when it cannot see: if the camera is covered or it is too dark, you will hear it. With VoiceOver, a two-finger double tap anywhere pauses or resumes.",
                    "Ti avvisa quando non riesce a vedere: se la fotocamera è coperta o è troppo buio, lo sentirai. Con VoiceOver, un doppio tocco con due dita in qualsiasi punto mette in pausa o riprende."))
                Picker(model.tr("Language", "Lingua"), selection: $model.language) {
                    Text("English").tag(SpeechLanguage.english)
                    Text("Italiano").tag(SpeechLanguage.italian)
                }
                .pickerStyle(.segmented)
                BigButton(title: model.tr("I understand. Start.", "Ho capito. Avvia."), systemImage: "play.fill", prominent: true,
                          hint: model.tr("Starts the camera. You will be asked to allow camera access.",
                                         "Avvia la fotocamera. Ti verrà chiesto di consentire l'accesso alla fotocamera.")) {
                    model.onboarded = true
                }
            }
            .font(.title3)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear { titleFocused = true }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var askConsent = false
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        // Scrolls, so nothing is cut off at the largest accessibility text sizes.
        ScrollView {
            VStack(spacing: 14) {
                status

                BigButton(title: model.tr("What is around me?", "Cosa c'è intorno a me?"), systemImage: "eye.fill", prominent: true,
                          hint: model.tr("Speaks what the camera sees now, what it saw a moment ago, and what another device reported.",
                                         "Dice cosa vede ora la fotocamera, cosa ha visto poco fa e cosa ha segnalato un altro dispositivo.")) {
                    model.describeSurroundings()
                }

                BigButton(title: model.paused ? model.tr("Paused. Resume perception.", "In pausa. Riprendi percezione.")
                                              : model.tr("Pause perception", "Metti in pausa"),
                          systemImage: model.paused ? "play.fill" : "pause.fill",
                          spokenLabel: model.paused ? model.tr("Resume perception", "Riprendi percezione") : model.tr("Pause perception", "Metti in pausa"),
                          hint: model.tr("Stops or restarts the camera and all announcements. A two-finger double tap does the same.",
                                         "Ferma o riavvia la fotocamera e tutti gli annunci. Un doppio tocco con due dita fa lo stesso.")) {
                    model.togglePause()
                }

                BigButton(title: model.tr("Repeat last announcement", "Ripeti l'ultimo annuncio"), systemImage: "arrow.counterclockwise") {
                    model.repeatLastAnnouncement()
                }

                BigButton(title: model.audioOn ? model.tr("Speech is on. Turn off.", "Voce attiva. Disattiva.") : model.tr("Speech is off. Turn on.", "Voce disattivata. Attiva."),
                          systemImage: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          spokenLabel: model.tr("Spoken alerts", "Avvisi vocali"),
                          spokenValue: onOff(model.audioOn),
                          hint: model.tr("When off, obstacle alerts are not spoken. Camera failures are still announced by VoiceOver.",
                                         "Se disattivati, gli avvisi sugli ostacoli non vengono pronunciati. I guasti della fotocamera sono comunque annunciati da VoiceOver."),
                          isToggle: true) { model.audioOn.toggle() }

                BigButton(title: model.collaborationOn ? model.tr("Sharing is on. Stop sharing.", "Condivisione attiva. Interrompi.")
                                                       : model.tr("Sharing is off. Turn on.", "Condivisione disattivata. Attiva."),
                          systemImage: model.collaborationOn ? "person.2.fill" : "person.2.slash",
                          spokenLabel: model.tr("Share with another device", "Condividi con un altro dispositivo"),
                          spokenValue: onOff(model.collaborationOn),
                          hint: model.tr("Exchanges obstacle observations with another phone. Never video. You will be asked to confirm.",
                                         "Scambia osservazioni sugli ostacoli con un altro telefono. Mai video. Ti verrà chiesta conferma."),
                          isToggle: true) {
                    if model.collaborationOn { model.setCollaboration(false) } else { askConsent = true }
                }

                // Side by side at ordinary sizes, stacked when the text is large enough that two columns would wrap badly.
                let secondary = Group {
                    BigButton(title: model.tr("Settings", "Impostazioni"), systemImage: "gearshape") { showSettings = true }
                    BigButton(title: model.tr("Diagnostics", "Diagnostica"), systemImage: "waveform.path.ecg",
                              hint: model.tr("Technical screen for engineers.", "Schermata tecnica per gli sviluppatori.")) { showDiagnostics = true }
                }
                if typeSize.isAccessibilitySize { VStack(spacing: 14) { secondary } } else { HStack(spacing: 12) { secondary } }
            }
            .padding(18)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        // VoiceOver's Magic Tap (two-finger double tap) is the conventional "main action" gesture: here, silence or resume.
        .accessibilityAction(.magicTap) { model.togglePause() }
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

    /// Three separate, individually focusable lines. Each one states its meaning in words; the icon only repeats it.
    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.tr("Status", "Stato")).font(.headline).accessibilityAddTraits(.isHeader)
            Label(model.perceptionStatusText, systemImage: perceptionIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(perceptionOK ? Color.white : Color.yellow)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.tr("Camera", "Fotocamera"))
                .accessibilityValue(model.perceptionStatusText)
            Label(model.collaborationStatusText, systemImage: "person.2.wave.2")
                .font(.body)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.tr("Other devices", "Altri dispositivi"))
                .accessibilityValue(model.collaborationStatusText)
            if !model.snapshot.lastSpoken.isEmpty {
                Text(model.tr("Last announcement: ", "Ultimo annuncio: ") + model.snapshot.lastSpoken)
                    .font(.body)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onOff(_ on: Bool) -> String { on ? model.tr("On", "Attivo") : model.tr("Off", "Disattivato") }

    private var perceptionOK: Bool { model.snapshot.reliability.status(.semanticDetection).state == .reliable && !model.paused }

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
                    Toggle(model.tr("Spatial mode", "Modalità spaziale"), isOn: $model.spatialMode)
                        .disabled(!ARFrameProvider.isSupported)
                    LabeledContent(model.tr("Session code", "Codice sessione")) {
                        TextField(model.tr("Session code", "Codice sessione"), text: $model.sessionCode)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($codeFocused)
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
            .navigationTitle(model.tr("Settings", "Impostazioni"))
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
