import SwiftUI
import SharedSightCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.onboarded { LiveVisionView() } else { OnboardingView() }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
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
                    .foregroundStyle(.white.opacity(0.75))
                Picker(model.tr("Language", "Lingua"), selection: $model.language) {
                    Text("English").tag(SpeechLanguage.english)
                    Text("Italiano").tag(SpeechLanguage.italian)
                }
                .pickerStyle(.segmented)
                PrimaryButton(title: model.tr("I understand. Start.", "Ho capito. Avvia."), systemImage: "play.fill",
                              hint: model.tr("Starts the camera. You will be asked to allow camera access.",
                                             "Avvia la fotocamera. Ti verrà chiesto di consentire l'accesso alla fotocamera.")) {
                    model.onboarded = true
                }
            }
            .font(.body)
            .padding(24)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear { titleFocused = true }
    }
}

// MARK: - Live Vision (main screen)

/// The camera fills the screen; only what is needed to act sits on top of it.
/// Hierarchy: Live Vision -> Target -> Settings. Diagnostics is separate, for engineers.
struct LiveVisionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sheet: Sheet?
    @State private var askConsent = false
    @StateObject private var drone = DroneCompanionCoordinator()

    enum Sheet: String, Identifiable {
        case target, settings, diagnostics, drone
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { stacked } else { layered }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(Theme.accent)
        // VoiceOver's Magic Tap (two-finger double tap) is the conventional "main action" gesture: here, silence or resume.
        .accessibilityAction(.magicTap) { model.togglePause() }
        .onAppear { drone.attach(to: model) }
        .alert(model.tr("Share observations?", "Condividere le osservazioni?"), isPresented: $askConsent) {
            Button(model.tr("Share", "Condividi")) { model.setCollaboration(true) }
            Button(model.tr("Cancel", "Annulla"), role: .cancel) {}
        } message: {
            Text(model.tr(
                "Your phone will exchange obstacle observations with nearby Shared Sight devices that use session code \(model.sessionCode): object type, time and, when measured, position. No video, no photos, no face recognition. You can stop at any time.",
                "Il telefono scambierà osservazioni sugli ostacoli con i dispositivi Shared Sight vicini che usano il codice sessione \(model.sessionCode): tipo di oggetto, orario e, se misurata, posizione. Nessun video, nessuna foto, nessun riconoscimento facciale. Puoi interrompere in qualsiasi momento."))
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .target: TargetView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                case .drone: DroneCompanionSheet(coordinator: drone)
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
    }

    /// Ordinary text sizes: full-screen camera, floating chrome.
    private var layered: some View {
        ZStack {
            CameraStage().ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                Spacer(minLength: 0)
                ControlPanel(sheet: $sheet, askConsent: $askConsent)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    /// Accessibility text sizes: the camera keeps the top of the screen and the controls scroll below it,
    /// so nothing is clipped and nothing covers the picture.
    private var stacked: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                CameraStage()
                    .frame(height: geo.size.height * 0.36)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                ScrollView {
                    VStack(spacing: 12) {
                        TopBar()
                        ControlPanel(sheet: $sheet, askConsent: $askConsent)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct TopBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let state = model.paused ? ReliabilityState.unavailable : model.snapshot.reliability.status(.semanticDetection).state
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { title; Spacer(minLength: 8); chips(state) }
            VStack(alignment: .leading, spacing: 8) { title; HStack(spacing: 8) { chips(state) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        Text("Shared Sight")
            .font(.subheadline.weight(.semibold))
            .shadow(color: .black.opacity(0.6), radius: 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func chips(_ state: ReliabilityState) -> some View {
        StatusChip(text: cameraText(state), systemImage: cameraIcon(state),
                   tint: state == .reliable ? Theme.accent : (state == .degraded ? Theme.caution : Theme.alert))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.tr("Camera", "Fotocamera"))
            .accessibilityValue(model.paused ? model.tr("Perception paused.", "Percezione in pausa.") : model.perceptionStatusText)
        StatusChip(text: model.trackingOn ? model.tr("Follow", "Segui") : model.tr("Awareness", "Vigilanza"),
                   systemImage: model.trackingOn ? "scope" : "eye")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.tr("Mode", "Modalità"))
            .accessibilityValue(model.trackingOn ? model.tr("Following a registered person", "Segue una persona registrata")
                                                 : model.tr("Obstacle awareness only", "Solo rilevamento ostacoli"))
        if model.collaborationOn {
            StatusChip(text: "\(model.snapshot.peerCount)", systemImage: "person.2.wave.2",
                       tint: model.snapshot.linkState == .connected ? Theme.accent : .white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.tr("Other devices", "Altri dispositivi"))
                .accessibilityValue(model.collaborationStatusText)
        }
    }

    private func cameraText(_ s: ReliabilityState) -> String {
        if model.paused { return model.tr("Paused", "In pausa") }
        switch s {
        case .reliable: return model.tr("Live", "Attiva")
        case .degraded: return model.tr("Degraded", "Ridotta")
        case .unavailable: return model.tr("No vision", "Non vede")
        }
    }

    private func cameraIcon(_ s: ReliabilityState) -> String {
        switch s {
        case .reliable: return "circle.fill"
        case .degraded: return "exclamationmark.circle.fill"
        case .unavailable: return "eye.slash.fill"
        }
    }
}

/// Bottom panel: who is being followed, the simulated follow cue, one primary action, a row of small controls.
private struct ControlPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var sheet: LiveVisionView.Sheet?
    @Binding var askConsent: Bool

    var body: some View {
        let p = model.targetPresentation
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: p.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.color(p.tone))
                    .frame(width: 30)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.footnote.weight(.bold)).tracking(1.1).foregroundStyle(Theme.color(p.tone))
                    Text(detail(p)).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.snapshot.target.isLocked {
                    Text("\(Int((model.snapshot.target.associationConfidence * 100).rounded()))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .accessibilityLabel(model.tr("Tracking confidence", "Confidenza del tracciamento"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .animation(.easeInOut(duration: 0.2), value: p.title)

            if model.trackingOn { FollowCue(guidance: model.snapshot.guidance) }

            primary

            HStack(spacing: 0) {
                CircleButton(systemImage: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                             label: model.tr("Spoken alerts", "Avvisi vocali"),
                             value: model.audioOn ? model.tr("On", "Attivo") : model.tr("Off", "Disattivato"),
                             hint: model.tr("When off, obstacle alerts are not spoken. Camera failures are still announced by VoiceOver.",
                                            "Se disattivati, gli avvisi sugli ostacoli non vengono pronunciati. I guasti della fotocamera sono comunque annunciati da VoiceOver."),
                             active: model.audioOn, isToggle: true) { model.audioOn.toggle() }
                Spacer(minLength: 4)
                CircleButton(systemImage: "person.crop.circle.badge.checkmark",
                             label: model.tr("Target", "Bersaglio"),
                             hint: model.tr("Register a person, show their marker, choose who to follow.",
                                            "Registra una persona, mostra il suo marcatore, scegli chi seguire.")) { sheet = .target }
                Spacer(minLength: 4)
                CircleButton(systemImage: "eye.fill",
                             label: model.tr("What is around me?", "Cosa c'è intorno a me?"),
                             hint: model.tr("Speaks what the camera sees now, what it saw a moment ago, and what another device reported.",
                                            "Dice cosa vede ora la fotocamera, cosa ha visto poco fa e cosa ha segnalato un altro dispositivo.")) {
                    model.describeSurroundings()
                }
                Spacer(minLength: 4)
                CircleButton(systemImage: model.paused ? "play.fill" : "pause.fill",
                             label: model.paused ? model.tr("Resume perception", "Riprendi percezione") : model.tr("Pause perception", "Metti in pausa"),
                             hint: model.tr("Stops or restarts the camera and all announcements. A two-finger double tap does the same.",
                                            "Ferma o riavvia la fotocamera e tutti gli annunci. Un doppio tocco con due dita fa lo stesso."),
                             active: model.paused) { model.togglePause() }
                Spacer(minLength: 4)
                Menu {
                    Button { model.repeatLastAnnouncement() } label: {
                        Label(model.tr("Repeat last announcement", "Ripeti l'ultimo annuncio"), systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        if model.collaborationOn { model.setCollaboration(false) } else { askConsent = true }
                    } label: {
                        Label(model.collaborationOn ? model.tr("Stop sharing with other devices", "Interrompi la condivisione")
                                                    : model.tr("Share with another device", "Condividi con un altro dispositivo"),
                              systemImage: model.collaborationOn ? "person.2.slash" : "person.2.fill")
                    }
                    Button { sheet = .drone } label: { Label("Drone Companion", systemImage: "airplane") }
                    Divider()
                    Button { sheet = .settings } label: { Label(model.tr("Settings", "Impostazioni"), systemImage: "gearshape") }
                    Button { sheet = .diagnostics } label: { Label(model.tr("Diagnostics", "Diagnostica"), systemImage: "waveform.path.ecg") }
                } label: {
                    CircleIcon(systemImage: "ellipsis")
                }
                .accessibilityLabel(model.tr("More", "Altro"))
                .accessibilityHint(model.tr("Repeat, sharing, settings, diagnostics.", "Ripeti, condivisione, impostazioni, diagnostica."))
            }
        }
        .padding(16)
        .glass()
    }

    private func detail(_ p: TargetPresentation) -> String {
        guard model.activeProfile != nil else { return model.tr("Register a person to follow", "Registra una persona da seguire") }
        if let name = model.activeProfile?.nickname, !name.isEmpty, model.snapshot.target.state == .unassigned {
            return "\(name) · \(p.detail)"
        }
        return p.detail
    }

    @ViewBuilder private var primary: some View {
        if model.activeProfile == nil {
            PrimaryButton(title: model.tr("Register Person", "Registra persona"), systemImage: "person.badge.plus") { sheet = .target }
        } else if model.trackingOn {
            PrimaryButton(title: model.tr("Stop Tracking", "Ferma tracciamento"), systemImage: "stop.fill", kind: .quiet,
                          hint: model.tr("Stops following. Obstacle alerts continue.", "Smette di seguire. Gli avvisi sugli ostacoli continuano.")) {
                withAnimation(.easeInOut(duration: 0.25)) { model.stopTracking() }
            }
        } else {
            PrimaryButton(title: model.tr("Start Tracking", "Avvia tracciamento"), systemImage: "scope",
                          hint: model.tr("Looks for the registered person's marker and follows only that person.",
                                         "Cerca il marcatore della persona registrata e segue solo quella persona.")) {
                withAnimation(.easeInOut(duration: 0.25)) { model.startTracking() }
            }
            .disabled(model.paused)
            .opacity(model.paused ? 0.5 : 1)
        }
    }
}

/// Suggested camera correction to keep the target centred. This is what a following drone would be asked
/// to do; here it only tells the person holding the phone which way to turn. Always labelled as simulated.
private struct FollowCue: View {
    @EnvironmentObject var model: AppModel
    let guidance: FollowGuidance

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                arrow("chevron.left", on: guidance.active && guidance.horizontal == .left)
                Image(systemName: guidance.active && guidance.horizontal == .centered ? "circle.inset.filled" : "circle")
                    .font(.footnote)
                    .foregroundStyle(guidance.active && guidance.horizontal == .centered ? Theme.accent : .white.opacity(0.35))
                arrow("chevron.right", on: guidance.active && guidance.horizontal == .right)
            }
            .accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(model.tr("SIMULATED", "SIMULATO"))
                .font(.caption2.weight(.bold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: guidance.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.tr("Simulated drone follow guidance", "Guida di inseguimento del drone simulato"))
        .accessibilityValue(text)
    }

    private func arrow(_ name: String, on: Bool) -> some View {
        Image(systemName: name)
            .font(.headline.weight(.bold))
            .foregroundStyle(on ? Theme.accent : .white.opacity(0.25))
            .scaleEffect(on ? 1.15 : 1)
    }

    private var text: String {
        if let hold = guidance.hold {
            switch hold {
            case .notTracking: return model.tr("Not following", "Inseguimento non attivo")
            case .searching: return model.tr("Waiting for target", "In attesa del bersaglio")
            case .settling: return model.tr("Locking on", "Aggancio in corso")
            case .predictedOnly: return model.tr("Paused · position is predicted", "In pausa · posizione prevista")
            case .ambiguous: return model.tr("Paused · target uncertain", "In pausa · bersaglio incerto")
            case .targetLost: return model.tr("Stopped · target lost", "Fermo · bersaglio perso")
            case .lowConfidence: return model.tr("Paused · low confidence", "In pausa · confidenza bassa")
            }
        }
        var parts: [String]
        switch guidance.horizontal {
        case .left: parts = [model.tr("Follow left", "Segui a sinistra")]
        case .right: parts = [model.tr("Follow right", "Segui a destra")]
        case .centered: parts = [model.tr("Aligned", "Allineato")]
        }
        switch guidance.vertical {
        case .up: parts.append(model.tr("tilt up", "inclina in su"))
        case .down: parts.append(model.tr("tilt down", "inclina in giù"))
        case .centered: break
        }
        // Apparent size only. It is not a distance and is never worded as one.
        switch guidance.size {
        case .smaller: parts.append(model.tr("target looks smaller", "bersaglio più piccolo"))
        case .larger: parts.append(model.tr("target looks larger", "bersaglio più grande"))
        case .steady: break
        }
        return parts.joined(separator: " · ")
    }
}
