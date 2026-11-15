import Foundation

public enum DroneKitLanguage: String, Sendable, CaseIterable { case english, italian }

public enum DroneEventSeverity: String, Sendable { case info, success, warning, critical }

/// Semantic mission events. The kit never speaks or vibrates: the host decides what to do with each
/// event (speech, haptics, VoiceOver announcement, UI). `announcement(_:simulated:)` offers ready wording.
public enum DroneMissionEvent: Sendable, Equatable {
    case activationRefused(DroneActivationRefusal)
    case authorizationFailed(OwnerAuthorizationFailure)
    case droneModeActivated
    case searchingForTarget
    case targetAcquired
    case followingActive
    case followingPaused(DronePauseReason)
    case followingResumed
    case targetLost
    case returnRequested
    case landingStarted
    case missionCompleted
    case missionCancelled
    case missionFailed(DroneMissionError)
}

public extension DroneMissionEvent {

    var severity: DroneEventSeverity {
        switch self {
        case .targetAcquired, .missionCompleted: return .success
        case .followingPaused, .authorizationFailed, .activationRefused: return .warning
        case .targetLost, .missionFailed: return .critical
        default: return .info
        }
    }

    /// Stable identifier for logging and analytics.
    var name: String {
        switch self {
        case .activationRefused: return "activationRefused"
        case .authorizationFailed: return "authorizationFailed"
        case .droneModeActivated: return "droneModeActivated"
        case .searchingForTarget: return "searchingForTarget"
        case .targetAcquired: return "targetAcquired"
        case .followingActive: return "followingActive"
        case .followingPaused: return "followingPaused"
        case .followingResumed: return "followingResumed"
        case .targetLost: return "targetLost"
        case .returnRequested: return "returnRequested"
        case .landingStarted: return "landingStarted"
        case .missionCompleted: return "missionCompleted"
        case .missionCancelled: return "missionCancelled"
        case .missionFailed: return "missionFailed"
        }
    }

    /// Short sentence for the host's speech engine or a VoiceOver announcement.
    /// With `simulated == true` (the only vehicle in this package) return, landing and completion are
    /// always worded as simulated, so the app can never say that a real drone flew or landed.
    func announcement(_ language: DroneKitLanguage = .english, simulated: Bool = true) -> String {
        func t(_ en: String, _ it: String) -> String { language == .italian ? it : en }
        switch self {
        case .activationRefused:
            return t("Register a person before starting drone mode.", "Registra una persona prima di avviare la modalità drone.")
        case let .authorizationFailed(failure):
            switch failure {
            case .cancelled: return t("Authorization cancelled. Drone mode not started.", "Autorizzazione annullata. Modalità drone non avviata.")
            case .unavailable: return t("Device authentication is not available. Drone mode not started.", "Autenticazione del dispositivo non disponibile. Modalità drone non avviata.")
            case .lockedOut: return t("Authentication is locked. Drone mode not started.", "Autenticazione bloccata. Modalità drone non avviata.")
            case .missingUsageDescription: return t("Face ID is not configured in this app. Drone mode not started.", "Face ID non è configurato in questa app. Modalità drone non avviata.")
            case .failed: return t("Authorization failed. Drone mode not started.", "Autorizzazione non riuscita. Modalità drone non avviata.")
            }
        case .droneModeActivated:
            return simulated ? t("Drone mode activated. Simulation.", "Modalità drone attivata. Simulazione.")
                             : t("Drone mode activated.", "Modalità drone attivata.")
        case .searchingForTarget:
            return t("Drone searching for the target.", "Il drone cerca il bersaglio.")
        case .targetAcquired:
            return t("Drone target acquired.", "Bersaglio del drone acquisito.")
        case .followingActive:
            return simulated ? t("Simulated following active.", "Inseguimento simulato attivo.")
                             : t("Following active.", "Inseguimento attivo.")
        case let .followingPaused(reason):
            switch reason {
            case .stoppedByUser: return t("Following stopped.", "Inseguimento fermato.")
            case .targetOccluded: return t("Following paused. Target hidden.", "Inseguimento in pausa. Bersaglio nascosto.")
            case .lowConfidence: return t("Following paused. Low confidence.", "Inseguimento in pausa. Confidenza bassa.")
            case .staleData: return t("Following paused. No recent target data.", "Inseguimento in pausa. Nessun dato recente sul bersaglio.")
            case .identityAmbiguous: return t("Following paused. Target uncertain.", "Inseguimento in pausa. Bersaglio incerto.")
            }
        case .followingResumed:
            return t("Following resumed.", "Inseguimento ripreso.")
        case .targetLost:
            return t("Drone target lost. Following stopped.", "Bersaglio del drone perso. Inseguimento fermo.")
        case .returnRequested:
            return simulated ? t("Simulated return started.", "Rientro simulato avviato.")
                             : t("Return requested.", "Rientro richiesto.")
        case .landingStarted:
            return simulated ? t("Simulated landing.", "Atterraggio simulato.")
                             : t("Landing.", "Atterraggio.")
        case .missionCompleted:
            return simulated ? t("Simulated mission completed.", "Missione simulata completata.")
                             : t("Mission completed.", "Missione completata.")
        case .missionCancelled:
            return t("Drone mode cancelled.", "Modalità drone annullata.")
        case .missionFailed:
            return t("Drone mode error. Following stopped.", "Errore della modalità drone. Inseguimento fermo.")
        }
    }
}

/// Delegate-style alternative to `DroneCompanionController.onEvent` and `events()`.
@MainActor
public protocol DroneMissionEventReceiving: AnyObject {
    func droneCompanion(_ controller: DroneCompanionController, didEmit event: DroneMissionEvent)
}
