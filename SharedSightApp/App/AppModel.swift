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
    @Published var spatialMode = false { didSet { engine.setSpatialMode(spatialMode) } }
    @Published var sessionCode: String { didSet { defaults.set(sessionCode, forKey: "sessionCode") } }
    @Published var markerWidthCm: Double { didSet { defaults.set(markerWidthCm, forKey: "markerWidthCm") } }
    @Published var diagnosticsVisible = false { didSet { engine.previewEnabled = diagnosticsVisible } }

    let engine = SharedSightPerceptionEngine()
    private let defaults = UserDefaults.standard
    private var started = false
    private var pausedByBackground = false
    private var lastSemanticState: ReliabilityState?

    init() {
        let d = UserDefaults.standard
        onboarded = d.bool(forKey: "onboarded")
        audioOn = d.object(forKey: "audioOn") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        let preferredItalian = Locale.preferredLanguages.first?.hasPrefix("it") ?? false
        language = SpeechLanguage(rawValue: d.string(forKey: "language") ?? "") ?? (preferredItalian ? .italian : .english)
        verbosity = Verbosity(rawValue: d.string(forKey: "verbosity") ?? "") ?? .normal
        sessionCode = d.string(forKey: "sessionCode") ?? "1234"
        let width = d.double(forKey: "markerWidthCm")
        markerWidthCm = width > 0 ? width : 15
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
        pushPreferences()
        engine.onSnapshot = { [weak self] s in self?.receive(s) }
        engine.start()
        UIApplication.shared.isIdleTimerDisabled = true
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
    }

    func togglePause() {
        paused.toggle()
        engine.setPaused(paused)
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
