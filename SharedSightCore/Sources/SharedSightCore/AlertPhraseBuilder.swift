import Foundation

public enum SpeechLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en-US", italian = "it-IT"
}

/// Turns alert intents into short spoken phrases. Wording never contains a direction or a distance
/// that the intent does not carry, and never states that a path is clear or safe.
public struct AlertPhraseBuilder: Sendable {
    public var language: SpeechLanguage
    public init(language: SpeechLanguage) { self.language = language }

    // model label -> (Italian singular, Italian plural, English plural)
    private static let table: [String: (String, String, String)] = [
        "person": ("persona", "persone", "people"), "bicycle": ("bicicletta", "biciclette", "bicycles"),
        "car": ("auto", "auto", "cars"), "motorcycle": ("moto", "moto", "motorcycles"),
        "bus": ("autobus", "autobus", "buses"), "truck": ("camion", "camion", "trucks"),
        "bench": ("panchina", "panchine", "benches"), "backpack": ("zaino", "zaini", "backpacks"),
        "umbrella": ("ombrello", "ombrelli", "umbrellas"), "handbag": ("borsa", "borse", "handbags"),
        "suitcase": ("valigia", "valigie", "suitcases"), "chair": ("sedia", "sedie", "chairs"),
        "couch": ("divano", "divani", "couches"), "potted plant": ("pianta in vaso", "piante in vaso", "potted plants"),
        "bed": ("letto", "letti", "beds"), "dining table": ("tavolo", "tavoli", "tables"),
        "tv": ("televisore", "televisori", "TVs"), "laptop": ("computer portatile", "computer portatili", "laptops"),
        "refrigerator": ("frigorifero", "frigoriferi", "refrigerators"), "dog": ("cane", "cani", "dogs"),
        "cat": ("gatto", "gatti", "cats"), "bottle": ("bottiglia", "bottiglie", "bottles"),
        "traffic light": ("semaforo", "semafori", "traffic lights"), "stop sign": ("segnale di stop", "segnali di stop", "stop signs"),
        "fire hydrant": ("idrante", "idranti", "fire hydrants"), "skateboard": ("skateboard", "skateboard", "skateboards"),
        "sink": ("lavandino", "lavandini", "sinks"), "toilet": ("water", "water", "toilets"),
    ]

    public func noun(_ label: String, count: Int = 1) -> String {
        let entry = Self.table[label]
        switch language {
        case .english:
            let single = label == "dining table" ? "table" : label
            return count > 1 ? (entry?.2 ?? single + "s") : single
        case .italian:
            return count > 1 ? (entry?.1 ?? label) : (entry?.0 ?? label)
        }
    }

    private func direction(_ s: Sector?) -> String? {
        guard let s else { return nil }
        switch (language, s) {
        case (.english, .ahead): return "ahead"
        case (.english, .left): return "on your left"
        case (.english, .right): return "on your right"
        case (.english, .behind): return "behind you"
        case (.italian, .ahead): return "davanti"
        case (.italian, .left): return "a sinistra"
        case (.italian, .right): return "a destra"
        case (.italian, .behind): return "dietro"
        }
    }

    private func distance(_ d: DistanceMeasurement?) -> String? {
        guard let d else { return nil }
        let rounded = max(0.5, (d.meters * 2).rounded() / 2)
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        switch language {
        case .english: return "about \(text) " + (rounded == 1 ? "meter" : "meters")
        case .italian: return "a circa \(text.replacingOccurrences(of: ".", with: ",")) " + (rounded == 1 ? "metro" : "metri")
        }
    }

    private func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    public func phrase(for intent: AlertIntent) -> String {
        switch intent.kind {
        case let .obstacle(label, count, moving):
            var parts: [String] = [count > 1 ? "\(count) \(noun(label, count: count))" : noun(label)]
            if let dir = direction(intent.sector) { parts[0] += " " + dir }
            else { parts[0] += language == .english ? " in view" : " nel campo visivo" }
            if let dist = distance(intent.distance) { parts.append(dist) }
            if moving { parts.append(language == .english ? "moving" : "in movimento") }
            return capitalised(parts.joined(separator: ", ")) + "."
        case let .peerObstacle(label):
            let head = language == .english ? "Obstacle reported by another device" : "Ostacolo segnalato da un altro dispositivo"
            var parts = [noun(label)]
            if let dir = direction(intent.sector) { parts.append(dir) }
            if let dist = distance(intent.distance) { parts.append(dist) }
            return head + ": " + parts.joined(separator: ", ") + "."
        case let .system(notice):
            return systemPhrase(notice)
        }
    }

    public func systemPhrase(_ n: SystemNotice) -> String {
        let en = language == .english
        switch n {
        case let .perceptionUnavailable(reason):
            let head = en ? "Camera perception unavailable." : "Percezione della fotocamera non disponibile."
            switch reason {
            case .lensCoveredOrDark?: return head + (en ? " The camera may be covered, or it is too dark." : " La fotocamera potrebbe essere coperta, oppure è troppo buio.")
            case .cameraPermissionDenied?: return head + (en ? " Camera access is not allowed." : " Accesso alla fotocamera non consentito.")
            case .modelNotLoaded?: return head + (en ? " The detection model is not loaded." : " Il modello di rilevamento non è caricato.")
            case .cameraInterrupted?: return head + (en ? " The camera was interrupted." : " La fotocamera è stata interrotta.")
            case .paused?: return en ? "Perception paused." : "Percezione in pausa."
            default: return head
            }
        case .perceptionRestored: return en ? "Camera perception restored." : "Percezione della fotocamera ripristinata."
        case let .perceptionDegraded(reason):
            switch reason {
            case .lowLight: return en ? "Perception degraded: low light." : "Percezione ridotta: poca luce."
            case .motionBlur: return en ? "Perception degraded: the camera is moving fast." : "Percezione ridotta: la fotocamera si muove velocemente."
            default: return en ? "Perception degraded." : "Percezione ridotta."
            }
        case .peerConnected: return en ? "Another device connected." : "Altro dispositivo connesso."
        case .peerLost: return en ? "Connection to the other device lost. Its observations have expired." : "Connessione con l'altro dispositivo persa. Le sue osservazioni sono scadute."
        case .peerObservationUnverified: return en ? "Observation received from another device. Its position cannot be verified." : "Osservazione ricevuta da un altro dispositivo. La posizione non è verificabile."
        case .collaborationOff: return en ? "Collaboration off. Nothing is shared." : "Collaborazione disattivata. Nessun dato condiviso."
        case .collaborationOn: return en ? "Collaboration on. Sharing observations, not video." : "Collaborazione attiva. Condivisione di osservazioni, non di video."
        case .sharedReferenceReady: return en ? "Shared spatial reference ready." : "Riferimento spaziale condiviso pronto."
        }
    }
}
