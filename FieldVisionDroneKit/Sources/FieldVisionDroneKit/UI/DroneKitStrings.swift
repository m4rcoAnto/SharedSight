import SwiftUI

/// Colours shared by the kit's views: near-black surfaces, white type, one accent.
/// State is always written in words as well; colour only repeats it.
enum DroneKitTheme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let caution = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let alert = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let background = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let panel = Color(red: 0.09, green: 0.095, blue: 0.11)

    static func tone(for state: DroneMissionState) -> Color {
        switch state {
        case .off, .authorizationRequired, .preparing, .searchingForTarget, .returnRequested, .landing: return .white
        case .targetLocked, .following, .landed: return accent
        case .paused: return caution
        case .targetLost, .error: return alert
        }
    }

    static func symbol(for state: DroneMissionState) -> String {
        switch state {
        case .off: return "power"
        case .authorizationRequired: return "faceid"
        case .preparing: return "gearshape.2"
        case .searchingForTarget: return "dot.radiowaves.left.and.right"
        case .targetLocked: return "lock.fill"
        case .following: return "scope"
        case .targetLost: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .returnRequested: return "arrow.uturn.backward.circle"
        case .landing: return "arrow.down.to.line"
        case .landed: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct DronePrimaryButtonContent {
    var title: String
    var subtitle: String
    var symbol: String
    var hint: String
    var enabled: Bool
    var busy: Bool
    var prominent: Bool
}

/// All user-facing text of the kit's views, English and Italian.
struct DroneKitStrings {
    let language: DroneKitLanguage

    func t(_ en: String, _ it: String) -> String { language == .italian ? it : en }

    var simulation: String { t("SIMULATION", "SIMULAZIONE") }
    var testData: String { t("TEST DATA", "DATI DI PROVA") }
    var simulationLabel: String { t("Drone simulation", "Simulazione del drone") }
    var stopFollowing: String { t("Stop Following", "Ferma inseguimento") }
    var resumeFollowing: String { t("Resume Following", "Riprendi inseguimento") }
    var stopFollowingHint: String {
        t("Stops follow guidance immediately. The mission stays on until you end it.",
          "Ferma subito la guida di inseguimento. La missione resta attiva finché non la termini.")
    }
    var resumeFollowingHint: String {
        t("Searches for the registered person again.", "Cerca di nuovo la persona registrata.")
    }

    func stateTitle(_ state: DroneMissionState) -> String {
        switch state {
        case .off: return t("DRONE OFF", "DRONE SPENTO")
        case .authorizationRequired: return t("AUTHORIZATION REQUIRED", "AUTORIZZAZIONE RICHIESTA")
        case .preparing: return t("PREPARING", "PREPARAZIONE")
        case .searchingForTarget: return t("SEARCHING FOR TARGET", "RICERCA BERSAGLIO")
        case .targetLocked: return t("TARGET LOCKED", "BERSAGLIO AGGANCIATO")
        case .following: return t("FOLLOWING", "INSEGUIMENTO")
        case .targetLost: return t("TARGET LOST", "BERSAGLIO PERSO")
        case .paused: return t("FOLLOWING PAUSED", "INSEGUIMENTO IN PAUSA")
        case .returnRequested: return t("RETURNING", "RIENTRO")
        case .landing: return t("LANDING", "ATTERRAGGIO")
        case .landed: return t("MISSION COMPLETE", "MISSIONE COMPLETATA")
        case .error: return t("ERROR", "ERRORE")
        }
    }

    func guidanceText(_ g: DroneFollowGuidance) -> String {
        if let hold = g.hold {
            switch hold {
            case .missionInactive: return t("No mission running", "Nessuna missione in corso")
            case .preparing: return t("Getting ready", "Preparazione in corso")
            case .searching: return t("Waiting for the registered person", "In attesa della persona registrata")
            case .settling: return t("Locking on", "Aggancio in corso")
            case .targetOccluded: return t("Holding · target hidden", "In attesa · bersaglio nascosto")
            case .lowConfidence: return t("Holding · low confidence", "In attesa · confidenza bassa")
            case .staleData: return t("Holding · no recent target data", "In attesa · nessun dato recente")
            case .identityAmbiguous: return t("Holding · target uncertain", "In attesa · bersaglio incerto")
            case .targetLost: return t("Stopped · target lost", "Fermo · bersaglio perso")
            case .stoppedByUser: return t("Stopped by you", "Fermato da te")
            case .heldByHost: return t("Holding · tracker is settling", "In attesa · il tracciamento si stabilizza")
            case .returning: return t("Returning to you", "Rientro verso di te")
            case .landing: return t("Landing", "Atterraggio")
            case .fault: return t("Stopped · error", "Fermo · errore")
            }
        }
        var parts: [String]
        switch g.horizontal {
        case .left: parts = [t("Follow left", "Segui a sinistra")]
        case .right: parts = [t("Follow right", "Segui a destra")]
        case .centered: parts = [t("Aligned", "Allineato")]
        }
        switch g.vertical {
        case .up: parts.append(t("tilt up", "inclina in su"))
        case .down: parts.append(t("tilt down", "inclina in giù"))
        case .centered: break
        }
        return parts.joined(separator: " · ")
    }

    func primaryButton(state: DroneMissionState, hasTarget: Bool) -> DronePrimaryButtonContent {
        let endHint = t("Stops following at once, then the simulated drone returns and lands.",
                        "Ferma subito l'inseguimento, poi il drone simulato rientra e atterra.")
        switch state {
        case .off:
            return DronePrimaryButtonContent(
                title: t("Start Drone Companion", "Avvia Drone Companion"),
                subtitle: hasTarget ? t("Simulated · asks for Face ID or passcode", "Simulato · chiede Face ID o codice")
                                    : t("Register a person first", "Registra prima una persona"),
                symbol: "airplane.departure",
                hint: t("Confirms you are the owner of this iPhone, then searches for the registered person.",
                        "Conferma che sei il proprietario di questo iPhone, poi cerca la persona registrata."),
                enabled: hasTarget, busy: false, prominent: true)
        case .authorizationRequired:
            return DronePrimaryButtonContent(
                title: t("Authorizing…", "Autorizzazione…"),
                subtitle: t("Confirm with Face ID or passcode", "Conferma con Face ID o codice"),
                symbol: "faceid", hint: "", enabled: false, busy: true, prominent: false)
        case .preparing, .searchingForTarget, .targetLocked, .following, .targetLost, .paused:
            return DronePrimaryButtonContent(
                title: t("End Mission", "Termina missione"),
                subtitle: t("Stop, return and land (simulated)", "Ferma, rientra e atterra (simulato)"),
                symbol: "arrow.uturn.backward", hint: endHint, enabled: true, busy: false, prominent: false)
        case .returnRequested:
            return DronePrimaryButtonContent(
                title: t("Returning…", "Rientro…"),
                subtitle: t("Simulated return in progress", "Rientro simulato in corso"),
                symbol: "arrow.uturn.backward", hint: "", enabled: false, busy: true, prominent: false)
        case .landing:
            return DronePrimaryButtonContent(
                title: t("Landing…", "Atterraggio…"),
                subtitle: t("Simulated landing in progress", "Atterraggio simulato in corso"),
                symbol: "arrow.down.to.line", hint: "", enabled: false, busy: true, prominent: false)
        case .landed:
            return DronePrimaryButtonContent(
                title: t("Start Again", "Avvia di nuovo"),
                subtitle: hasTarget ? t("Simulated mission completed", "Missione simulata completata")
                                    : t("Register a person first", "Registra prima una persona"),
                symbol: "airplane.departure",
                hint: t("Starts a new simulated mission.", "Avvia una nuova missione simulata."),
                enabled: hasTarget, busy: false, prominent: true)
        case .error:
            return DronePrimaryButtonContent(
                title: t("Reset Drone Mode", "Reimposta modalità drone"),
                subtitle: t("The simulated vehicle reported an error", "Il veicolo simulato ha segnalato un errore"),
                symbol: "arrow.counterclockwise",
                hint: t("Returns to off.", "Torna a spento."),
                enabled: true, busy: false, prominent: false)
        }
    }
}
