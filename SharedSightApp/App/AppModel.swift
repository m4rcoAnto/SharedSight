import SwiftUI
import UIKit
import SharedSightCore

/// Main-thread view model: user settings + the latest engine snapshot. All mutation happens on the main thread.
final class AppModel: ObservableObject {
    typealias Snapshot = SharedSightPerceptionEngine.Snapshot

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var paused = false
    @Published private(set) var collaborationOn = false     // never persisted: consent is given per session
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded"); if onboarded { begin() } } }
    @Published var audioOn: Bool { didSet { defaults.set(audioOn, forKey: "audioOn"); engine.audio.muted = !audioOn } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics"); engine.audio.hapticsEnabled = haptics } }
    @Published var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: "language"); engine.audio.language = language } }
    @Published var verbosity: Verbosity { didSet { defaults.set(verbosity.rawValue, forKey: "verbosity"); pushPreferences() } }
    /// Multiplier on the system default speech rate (0.8 ... 1.6). VoiceOver users get their own VoiceOver rate instead.
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate"); engine.audio.rateMultiplier = Float(speechRate) } }
    // Remembered between launches: a blind user should not have to type a 32-character key every morning.
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://192.168.1.10:8080"
    @Published var serverToken = UserDefaults.standard.string(forKey: "serverToken") ?? ""
    @Published var serverPreviews = UserDefaults.standard.object(forKey: "serverPreviews") as? Bool ?? true
    @Published private(set) var serverOn = false
    func toggleServer() {
        serverOn.toggle()
        if serverOn && ARFrameProvider.isSupported { spatialMode = true }
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        serverToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(serverToken, forKey: "serverToken")
        defaults.set(serverPreviews, forKey: "serverPreviews")
        defaults.set(serverOn, forKey: "serverOn")      // reconnects by itself at the next launch
        engine.configureServer(url: serverOn ? serverURL : nil, token: serverToken,
                               session: sessionCode, previews: serverPreviews)
    }

    /// ARKit world tracking: distances, positions on the floor, hidden-object estimates and encounter risk all need it.
    /// On by default wherever it is supported; the choice is remembered.
    @Published var spatialMode: Bool {
        didSet { defaults.set(spatialMode, forKey: "spatialMode"); engine.setSpatialMode(spatialMode); updatePreviewMode() }
    }
    @Published var sessionCode: String { didSet { defaults.set(sessionCode, forKey: "sessionCode") } }
    @Published var markerWidthCm: Double { didSet { defaults.set(markerWidthCm, forKey: "markerWidthCm") } }
    @Published var diagnosticsVisible = false { didSet { updatePreviewMode() } }
    @Published var showOutlines: Bool { didSet { defaults.set(showOutlines, forKey: "showOutlines"); updatePreviewMode() } }
    /// How long target-tracking events are kept on this phone (diagnostics only).
    @Published var eventRetentionDays: Double {
        didSet { defaults.set(eventRetentionDays, forKey: "eventRetentionDays"); eventLog.policy.maxAgeDays = eventRetentionDays; eventLog.flush() }
    }

    // Registered people (persistent) and the live target (per session)
    @Published private(set) var profiles: [PersonProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var trackingOn = false          // never persisted: following is started explicitly each session
    @Published private(set) var storeError: String?
    @Published private(set) var trackingEvents: [TrackingEvent] = []

    let engine = SharedSightPerceptionEngine()
    private let defaults = UserDefaults.standard
    private var started = false
    private var pausedByBackground = false
    private var lastSemanticState: ReliabilityState?
    private var lastLinkState: PeerLinkState?
    private var lastTargetState: TargetTrackingState = .unassigned
    private var registry: PersonRegistry?
    private let eventLog: TrackingEventLog

    init() {
        let d = UserDefaults.standard
        onboarded = d.bool(forKey: "onboarded")
        spatialMode = (d.object(forKey: "spatialMode") as? Bool ?? true) && ARFrameProvider.isSupported
        audioOn = d.object(forKey: "audioOn") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        let preferredItalian = Locale.preferredLanguages.first?.hasPrefix("it") ?? false
        language = SpeechLanguage(rawValue: d.string(forKey: "language") ?? "") ?? (preferredItalian ? .italian : .english)
        verbosity = Verbosity(rawValue: d.string(forKey: "verbosity") ?? "") ?? .normal
        let rate = d.double(forKey: "speechRate")
        speechRate = rate > 0 ? min(max(rate, 0.8), 1.6) : 1.12
        sessionCode = d.string(forKey: "sessionCode") ?? "1234"
        let width = d.double(forKey: "markerWidthCm")
        markerWidthCm = width > 0 ? width : 15
        showOutlines = d.object(forKey: "showOutlines") as? Bool ?? false
        let days = d.double(forKey: "eventRetentionDays")
        eventRetentionDays = days > 0 ? days : 7

        // Local-only storage in the app's private container (Application Support), encrypted while the phone is locked.
        let folder = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                      ?? FileManager.default.temporaryDirectory).appendingPathComponent("SharedSight", isDirectory: true)
        eventLog = TrackingEventLog(persistence: FilePersistence(url: folder.appendingPathComponent("tracking-events.json")),
                                    policy: RetentionPolicy(maxAgeDays: days > 0 ? days : 7))
        do {
            registry = try PersonRegistry(persistence: FilePersistence(url: folder.appendingPathComponent("people.json")))
        } catch {
            // Never start from an empty registry over an unreadable file: that would overwrite the user's people.
            registry = nil
            storeError = String(describing: error)
        }
        syncProfiles()
        trackingEvents = eventLog.events
        if onboarded { begin() }
    }

    /// Two-language UI text without a strings catalogue (keeps the build self-contained).
    func tr(_ en: String, _ it: String) -> String { language == .italian ? it : en }

    private func begin() {
        guard !started else { return }
        started = true
        engine.audio.language = language
        engine.audio.muted = !audioOn
        engine.audio.hapticsEnabled = haptics
        engine.audio.rateMultiplier = Float(speechRate)
        pushPreferences()
        engine.onSnapshot = { [weak self] s in self?.receive(s) }
        engine.onTargetEvents = { [weak self] events in self?.log(events) }
        engine.setTargetProfile(activeProfile)
        engine.setSpatialMode(spatialMode)      // didSet does not run for the value restored in init
        updatePreviewMode()
        engine.start()
        UIApplication.shared.isIdleTimerDisabled = true
        if defaults.bool(forKey: "serverOn"), !serverToken.isEmpty, !serverOn { toggleServer() }
    }

    private func pushPreferences() {
        var p = AlertPreferences()
        p.verbosity = verbosity
        engine.setPreferences(p)
    }

    private func receive(_ s: Snapshot) {
        snapshot = s
        // When speech is muted, VoiceOver users still get perception state changes.
        let state = s.reliability.status(.semanticDetection).state
        if state != lastSemanticState, lastSemanticState != nil, !audioOn, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: perceptionStatusText)
        }
        lastSemanticState = state
        // Same for the link to the other device: connecting and, above all, losing it must never be silent.
        if s.linkState != lastLinkState, lastLinkState != nil, !audioOn, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: collaborationStatusText)
        }
        lastLinkState = s.linkState
        announceTargetChange(s)
    }

    // MARK: Registered people

    var activeProfile: PersonProfile? { profiles.first { $0.id == activeProfileID } }

    var targetPresentation: TargetPresentation {
        TargetPresentation.make(snapshot.target, guidance: snapshot.guidance, language: language)
    }

    private func syncProfiles() {
        profiles = registry?.profiles ?? []
        activeProfileID = registry?.activeProfileID
    }

    /// Runs a registry change, republishes the list and tells the engine who the target is now.
    private func mutate(_ change: (PersonRegistry) throws -> Void) {
        guard let registry else { return }
        do { try change(registry); storeError = nil } catch { storeError = String(describing: error) }
        syncProfiles()
        if activeProfile == nil, trackingOn { stopTracking() }
        engine.setTargetProfile(activeProfile)
    }

    func createProfile(nickname: String) {
        mutate { registry in
            let created = try registry.create(nickname: nickname)
            try registry.select(id: created.id)
        }
    }

    func renameProfile(_ id: UUID, nickname: String) {
        mutate { try $0.update(id: id) { $0.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    func selectProfile(_ id: UUID) { mutate { try $0.select(id: id) } }

    /// New random token: every marker printed or shared before stops matching.
    func regenerateMarker(_ id: UUID) { mutate { try $0.regenerateMarker(id: id) } }

    func setOcclusionGrace(_ seconds: Double) {
        guard let id = activeProfileID else { return }
        mutate { try $0.update(id: id) { $0.preferences.occlusionGraceSeconds = seconds } }
    }

    /// Deletes the profile and everything stored about that person: tracking events and the live association.
    func deleteProfile(_ id: UUID) {
        mutate { registry in
            let removed = try registry.delete(id: id)
            eventLog.purge(userID: removed.userID)
            eventLog.flush()
        }
        trackingEvents = eventLog.events
    }

    func clearTrackingEvents() {
        eventLog.clear()
        eventLog.flush()
        trackingEvents = []
    }

    // MARK: Target following

    func startTracking() {
        guard activeProfile != nil, !paused else { return }
        trackingOn = true
        engine.setTracking(true)
    }

    func stopTracking() {
        trackingOn = false
        engine.setTracking(false)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: tr("Tracking stopped.", "Tracciamento fermato."))
        }
    }

    /// The operator points at a detected person: "this is the registered person". Starts tracking if needed.
    func selectTarget(trackID: Int) {
        guard activeProfile != nil, !paused else { return }
        if !trackingOn { startTracking() }
        engine.selectTarget(trackID: trackID)
    }

    private func log(_ events: [TargetEvent]) {
        let now = Date()
        for e in events {
            eventLog.append(TrackingEvent(date: now, kind: e.kind, userID: e.userID, trackID: e.trackID, detail: e.detail))
        }
        eventLog.flush()            // state changes are rare (a few per minute), so writing each batch is cheap
        trackingEvents = eventLog.events
    }

    /// Speech + haptic + VoiceOver for target state changes. Lost and uncertain are never silent.
    private func announceTargetChange(_ s: Snapshot) {
        let state = s.target.state
        guard state != lastTargetState else { return }
        lastTargetState = state
        guard trackingOn, activeProfile?.preferences.announceStateChanges ?? true,
              let text = targetPresentation.announcement else { return }
        let haptic: UINotificationFeedbackGenerator.FeedbackType?
        switch state {
        case .acquired: haptic = .success
        case .lost: haptic = .error
        case .ambiguous, .temporarilyOccluded: haptic = .warning
        default: haptic = nil
        }
        if UIAccessibility.isVoiceOverRunning {
            engine.audio.sayStatus("", haptic: haptic)                 // haptic only; VoiceOver speaks
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            engine.audio.sayStatus(text, haptic: haptic)
        }
    }

    private func updatePreviewMode() {
        engine.previewEnabled = diagnosticsVisible || spatialMode   // ARKit mode has no preview layer: frames from the engine
        engine.masksWanted = diagnosticsVisible || showOutlines
    }

    // MARK: Things the user asks for directly

    /// Answers a direct request. With VoiceOver running the text goes through VoiceOver, so it never talks over
    /// VoiceOver reading the button that was just activated; otherwise the app's own voice speaks it.
    private func answer(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            engine.audio.sayRequested(text)
        }
    }

    /// Text of the on-demand summary, built only from the current snapshot.
    var surroundingsText: String {
        let local = snapshot.entries.filter { $0.track.confirmed }.map { e in
            SurroundingsItem(label: e.track.label, state: e.state, sector: snapshot.relevance[e.id]?.sector,
                             distance: snapshot.relevance[e.id]?.distance)
        }
        let peers = snapshot.peers.map {
            PeerSurroundingsItem(label: $0.observation.label, status: $0.status, sector: $0.sector, distance: $0.distance)
        }
        let state: ReliabilityState = paused ? .unavailable : snapshot.reliability.status(.semanticDetection).state
        if paused { return tr("Perception is paused. I cannot tell what is around you.", "La percezione è in pausa. Non posso dirti cosa c'è intorno a te.") }
        return AlertPhraseBuilder(language: language).surroundings(perception: state, local: local, peers: peers,
                                                                   hidden: snapshot.hidden)
    }

    func describeSurroundings() { answer(surroundingsText) }

    func repeatLastAnnouncement() {
        engine.audio.repeatLastAnnouncement()
    }

    func testVoice() {
        engine.audio.sayRequested(tr("This is how fast Shared Sight speaks.", "Questa è la velocità con cui parla Shared Sight."))
    }

    func togglePause() {
        paused.toggle()
        if paused, trackingOn { stopTracking() }     // a paused camera cannot follow anyone
        engine.setPaused(paused)
        // Confirm the change when the app's own voice is off, so a Magic Tap is never left unanswered.
        if !audioOn, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: paused ? tr("Perception paused.", "Percezione in pausa.") : tr("Perception resumed.", "Percezione ripresa."))
        }
    }

    func setCollaboration(_ on: Bool) {
        collaborationOn = on
        if on && !spatialMode && ARFrameProvider.isSupported { spatialMode = true }   // positions need the spatial provider
        engine.setCollaboration(on, sessionCode: sessionCode)
    }

    func scenePhaseChanged(active: Bool) {
        guard started else { return }
        if !active && !paused { pausedByBackground = true; engine.setPaused(true) }
        else if active && pausedByBackground { pausedByBackground = false; if !paused { engine.setPaused(false) } }
    }

    // MARK: Derived, spoken-friendly status text

    func reasonText(_ r: ReliabilityReason) -> String {
        switch r {
        case .cameraPermissionDenied: return tr("camera access not allowed", "accesso alla fotocamera non consentito")
        case .cameraUnavailable: return tr("camera unavailable", "fotocamera non disponibile")
        case .cameraInterrupted: return tr("camera interrupted", "fotocamera interrotta")
        case .cameraStarting: return tr("camera starting", "avvio della fotocamera")
        case .paused: return tr("paused", "in pausa")
        case .framesStale: return tr("no recent camera frames", "nessun fotogramma recente")
        case .modelNotLoaded: return tr("detection model not loaded", "modello di rilevamento non caricato")
        case .inferenceFailing: return tr("detection failing", "rilevamento in errore")
        case .inferenceSlow, .processingDelayHigh: return tr("processing is slow", "elaborazione lenta")
        case .lensCoveredOrDark: return tr("camera covered or too dark", "fotocamera coperta o troppo buio")
        case .lowLight: return tr("low light", "poca luce")
        case .motionBlur: return tr("camera moving fast", "fotocamera in rapido movimento")
        case .cameraOrientation: return tr("camera not level", "fotocamera non orizzontale")
        case .orientationUnknown: return tr("orientation unknown", "orientamento sconosciuto")
        case .trackingUnstable: return tr("tracking unstable", "tracciamento instabile")
        case .segmentationUnsupported: return tr("outlines not supported by the model", "contorni non supportati dal modello")
        case .noDepthSource: return tr("no distance measurement", "nessuna misura di distanza")
        case .depthSensorMissing: return tr("not available on this device", "non disponibile su questo dispositivo")
        case .collaborationOff: return tr("collaboration off", "collaborazione disattivata")
        case .noPeer: return tr("no other device connected", "nessun altro dispositivo connesso")
        case .peerLinkStale: return tr("other device not responding", "l'altro dispositivo non risponde")
        case .noSharedAnchor: return tr("shared marker not seen yet", "marcatore condiviso non ancora visto")
        case .worldTrackingLimited: return tr("position tracking limited", "tracciamento della posizione limitato")
        case .audioMuted: return tr("speech off", "voce disattivata")
        case .audioNotReady: return tr("speech not ready", "voce non pronta")
        case .thermalThrottling: return tr("device is hot", "dispositivo caldo")
        }
    }

    var perceptionStatusText: String {
        let s = snapshot.reliability.status(.semanticDetection)
        let reasons = s.reasons.map(reasonText).joined(separator: ", ")
        switch s.state {
        case .reliable: return tr("Perception active.", "Percezione attiva.")
        case .degraded: return tr("Perception degraded: \(reasons).", "Percezione ridotta: \(reasons).")
        case .unavailable: return tr("Perception unavailable: \(reasons).", "Percezione non disponibile: \(reasons).")
        }
    }

    var collaborationStatusText: String {
        switch snapshot.linkState {
        case .off: return tr("Collaboration off. Nothing is shared.", "Collaborazione disattivata. Nessun dato condiviso.")
        case .searching: return tr("Collaboration on. Searching for another device with code \(sessionCode).",
                                   "Collaborazione attiva. Ricerca di un altro dispositivo con codice \(sessionCode).")
        case .connected:
            let spatial = snapshot.reliability.status(.sharedSpatialReference)
            let detail = spatial.state == .unavailable
                ? tr("Position of shared observations not verified: \(spatial.reasons.map(reasonText).joined(separator: ", ")).",
                     "Posizione delle osservazioni condivise non verificata: \(spatial.reasons.map(reasonText).joined(separator: ", ")).")
                : tr("Shared spatial reference valid.", "Riferimento spaziale condiviso valido.")
            return tr("Connected to another device. ", "Connesso a un altro dispositivo. ") + detail
        }
    }

    func stateText(_ s: ReliabilityState) -> String {
        switch s {
        case .reliable: return tr("reliable", "affidabile")
        case .degraded: return tr("degraded", "ridotta")
        case .unavailable: return tr("unavailable", "non disponibile")
        }
    }
}
