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

    func direction(_ s: Sector?) -> String? {
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

    /// Spoken alerts drop "about": every distance is already rounded, and the voice must stay short.
    /// The on-request summary keeps the longer form.
    func distance(_ d: DistanceMeasurement?, short: Bool) -> String? {
        guard let full = distance(d) else { return nil }
        guard short else { return full }
        return full.replacingOccurrences(of: "a circa ", with: "").replacingOccurrences(of: "about ", with: "")
    }

    func distance(_ d: DistanceMeasurement?) -> String? {
        guard let d else { return nil }
        // Half metres up close; whole metres from three metres on, where half a metre is below what is measured
        // and "six point five" only makes the sentence longer.
        let rounded = d.meters < 2.75 ? max(0.5, (d.meters * 2).rounded() / 2) : d.meters.rounded()
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        switch language {
        case .english: return "about \(text) " + (rounded == 1 ? "meter" : "meters")
        case .italian: return "a circa \(text.replacingOccurrences(of: ".", with: ",")) " + (rounded == 1 ? "metro" : "metri")
        }
    }

    func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    public func phrase(for intent: AlertIntent) -> String {
        switch intent.kind {
        case let .obstacle(label, count, moving):
            var parts: [String] = [count > 1 ? "\(count) \(noun(label, count: count))" : noun(label)]
            if let dir = direction(intent.sector) { parts[0] += " " + dir }
            else { parts[0] += language == .english ? " in view" : " nel campo visivo" }
            if let dist = distance(intent.distance, short: true) { parts.append(dist) }
            if moving { parts.append(language == .english ? "moving" : "in movimento") }
            return capitalised(parts.joined(separator: ", ")) + "."
        case let .peerObstacle(label):
            let head = language == .english ? "Obstacle reported by another device" : "Ostacolo segnalato da un altro dispositivo"
            var parts = [noun(label)]
            if let dir = direction(intent.sector) { parts.append(dir) }
            if let dist = distance(intent.distance, short: true) { parts.append(dist) }
            return head + ": " + parts.joined(separator: ", ") + "."
        case let .hiddenSeenByOther(label, occluder):
            // Heard in this order because a sentence may be cut off: what, which way, why it cannot be seen, how far,
            // and last who says so. "Secondo" keeps the sentence free of grammatical gender.
            // An object that is simply outside the picture needs no reason: "on your right" already is the reason.
            var parts = [noun(label)]
            if let dir = direction(intent.sector) { parts[0] += " " + dir }
            if occluder != nil || intent.sector == nil { parts.append(place(occluder)) }
            if let dist = distance(intent.distance, short: true) { parts.append(dist) }
            return capitalised(parts.joined(separator: ", ")) + (language == .english ? ", from another phone." : ", da un altro telefono.")
        case let .hiddenEstimate(label, _):
            // Short on purpose: an estimate must not hold the voice for long. "Maybe" marks every part of it as a guess.
            let head = capitalised(noun(label)) + (language == .english ? " no longer visible" : " non più visibile")
            var parts: [String] = []
            if let dir = direction(intent.sector) { parts.append(dir) }
            if let dist = distance(intent.distance, short: true) { parts.append(dist) }
            guard !parts.isEmpty else { return head + "." }
            return head + (language == .english ? ", maybe " : ", forse ") + parts.joined(separator: ", ") + "."
        case let .encounter(label, predicted, remote, hidden, imminent):
            let vehicle = ["car", "truck", "bus", "motorcycle"].contains(label)
            let name = vehicle ? (language == .italian ? "veicolo" : "vehicle") : noun(label)
            // The most urgent sentence is the shortest one. Directions are those of the camera, like every other alert.
            let dir: String
            switch (language, intent.sector) {
            case (.italian, .left?): dir = " da sinistra"
            case (.italian, .right?): dir = " da destra"
            case (.italian, .ahead?): dir = " davanti"
            case (.italian, .behind?): dir = " da dietro"
            case (.english, .left?): dir = " from the left"
            case (.english, .right?): dir = " from the right"
            case (.english, .ahead?): dir = " ahead"
            case (.english, .behind?): dir = " from behind"
            default: dir = ""
            }
            // "Not visible" already says the position is an estimate; a remote measurement says who measured it.
            if language == .italian {
                return (imminent ? "Attenzione, " : "Possibile ") + name + " in arrivo" + dir +
                    (hidden || predicted ? ", non visibile." : (remote ? ", da un altro telefono." : "."))
            }
            return (imminent ? "Warning, " : "Possible ") + name + " approaching" + dir +
                (hidden || predicted ? ", not visible." : (remote ? ", from another phone." : "."))
        case let .localizationLost(label):
            let vehicle = ["car", "truck", "bus", "motorcycle"].contains(label)
            if language == .italian {
                return "Non riesco più a localizzare " + (vehicle ? "il veicolo" : noun(label)) + ". Il rischio non è escluso."
            }
            return "I can no longer locate the " + (vehicle ? "vehicle" : noun(label)) + ". Risk is not ruled out."
        case let .system(notice):
            return systemPhrase(notice)
        }
    }

    /// Where a hidden object is with respect to the camera's view. Nil occluder = outside the field of view.
    func place(_ occluder: OccluderKind?) -> String {
        switch (language, occluder) {
        case (.english, .wall?): return "behind a wall"
        case (.english, .door?): return "behind a door"
        case (.english, .object?): return "behind an object"
        case (.english, nil): return "outside the camera's view"
        case (.italian, .wall?): return "dietro una parete"
        case (.italian, .door?): return "dietro una porta"
        case (.italian, .object?): return "dietro un oggetto"
        case (.italian, nil): return "fuori dal campo visivo"
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
