import Foundation

/// One locally tracked object, reduced to what may be spoken about it.
public struct SurroundingsItem: Sendable, Equatable {
    public var label: String
    public var state: MemoryState
    public var sector: Sector?
    public var distance: DistanceMeasurement?
    public init(label: String, state: MemoryState, sector: Sector?, distance: DistanceMeasurement?) {
        self.label = label; self.state = state; self.sector = sector; self.distance = distance
    }
}

/// One observation received from another device, reduced to what may be spoken about it.
public struct PeerSurroundingsItem: Sendable, Equatable {
    public var label: String
    public var status: PeerObservationStatus
    public var sector: Sector?
    public var distance: DistanceMeasurement?
    public init(label: String, status: PeerObservationStatus, sector: Sector?, distance: DistanceMeasurement?) {
        self.label = label; self.status = status; self.sector = sector; self.distance = distance
    }
}

/// On-demand spoken summary ("What is around me?").
///
/// Rules, in order of importance:
/// 1. If perception is unavailable, say so and say nothing else about the scene.
/// 2. An empty scene is reported as "nothing recognised", followed by an explicit statement that this is not a clear path.
/// 3. Things seen now, things only remembered, and things reported by another device are spoken as three separate groups.
/// 4. A direction or distance is spoken only when the item carries one. Expired peer observations are never spoken.
extension AlertPhraseBuilder {
    public func surroundings(perception: ReliabilityState, local: [SurroundingsItem], peers: [PeerSurroundingsItem],
                             hidden: [HiddenReport] = [], maxItems: Int = 4) -> String {
        let en = language == .english
        // People, animals and vehicles first, then the nearest; furniture another phone sees matters only when close.
        let located = hidden.filter { $0.sector != nil && ($0.isMover || $0.distance.meters <= 4) }
            .sorted { ($0.isMover ? 0 : 1, $0.distance.meters) < ($1.isMover ? 0 : 1, $1.distance.meters) }
        let hiddenSeen = located.filter { !$0.isPrediction }, hiddenGuess = located.filter { $0.isPrediction && $0.isMover }
        // The heading already says these are out of sight: only a real obstruction (wall, door, object) is named per item.
        func item(_ r: HiddenReport) -> String { describe(r.label, r.sector, r.distance, place: r.occluder.map { place($0) }) }
        func hiddenSentences() -> [String] {
            var s: [String] = []
            if !hiddenSeen.isEmpty {
                let head = en ? "Not visible from here, according to another device: " : "Non visibile da qui, secondo un altro dispositivo: "
                s.append(head + list(hiddenSeen.prefix(maxItems).map(item), extra: hiddenSeen.count - maxItems) + ".")
            }
            if !hiddenGuess.isEmpty {
                let head = en ? "Estimated position, not confirmed: " : "Posizione stimata, non confermata: "
                s.append(head + list(hiddenGuess.prefix(maxItems).map(item), extra: hiddenGuess.count - maxItems) + ".")
            }
            return s
        }
        if perception == .unavailable {
            // This phone's camera cannot help, but what another phone sees is still true and is still said.
            let head = en ? "Camera perception unavailable. I cannot tell what is around you from this camera."
                          : "Percezione della fotocamera non disponibile. Da questa fotocamera non posso dirti cosa c'è intorno a te."
            return ([hiddenSeen.isEmpty ? (en ? "Camera perception unavailable. I cannot tell what is around you."
                                              : "Percezione della fotocamera non disponibile. Non posso dirti cosa c'è intorno a te.") : head]
                    + (hiddenSeen.isEmpty ? [] : [hiddenSentences()[0]])).joined(separator: " ")
        }
        var sentences: [String] = []
        if perception == .degraded {
            sentences.append(en ? "Perception is degraded, so I may miss things." : "La percezione è ridotta, potrei non vedere tutto.")
        }

        let seen = local.filter { $0.state == .observed || $0.state == .reacquired }
        let remembered = local.filter { $0.state == .temporarilyHidden || $0.state == .predicted }
        let verifiedPeers = peers.filter { $0.status == .spatiallyRelevant }
        let unverifiedPeers = peers.filter { $0.status == .received || $0.status == .locationUnverified }

        if !seen.isEmpty {
            let head = en ? "In view now: " : "In vista ora: "
            sentences.append(head + list(seen.prefix(maxItems).map { describe($0.label, $0.sector, $0.distance) }, extra: seen.count - maxItems) + ".")
        }
        if !remembered.isEmpty {
            let head = en ? "Seen a moment ago, not confirmed now: " : "Visto poco fa, non confermato ora: "
            sentences.append(head + list(remembered.prefix(maxItems).map { describe($0.label, $0.sector, nil) }, extra: remembered.count - maxItems) + ".")
        }
        if !verifiedPeers.isEmpty {
            let head = en ? "Reported by another device: " : "Segnalato da un altro dispositivo: "
            sentences.append(head + list(verifiedPeers.prefix(maxItems).map { describe($0.label, $0.sector, $0.distance) }, extra: verifiedPeers.count - maxItems) + ".")
        }
        if !unverifiedPeers.isEmpty {
            let head = en ? "Reported by another device, position not verified: " : "Segnalato da un altro dispositivo, posizione non verificata: "
            sentences.append(head + list(unverifiedPeers.prefix(maxItems).map { noun($0.label) }, extra: unverifiedPeers.count - maxItems) + ".")
        }

        sentences.append(contentsOf: hiddenSentences())

        if seen.isEmpty && remembered.isEmpty && verifiedPeers.isEmpty && unverifiedPeers.isEmpty && hiddenSeen.isEmpty && hiddenGuess.isEmpty {
            sentences.append(en ? "Nothing I recognise is in view right now. This does not mean the way is clear."
                                : "In questo momento non riconosco nulla nel campo visivo. Questo non significa che la via sia libera.")
        }
        return sentences.joined(separator: " ")
    }

    private func describe(_ label: String, _ sector: Sector?, _ dist: DistanceMeasurement?, place: String? = nil) -> String {
        var parts = [noun(label)]
        if let dir = direction(sector) { parts[0] += " " + dir }
        if let place { parts.append(place) }
        if let d = distance(dist) { parts.append(d) }
        return parts.joined(separator: ", ")
    }

    private func list(_ items: [String], extra: Int) -> String {
        var text = items.joined(separator: "; ")
        if extra > 0 { text += language == .english ? "; and \(extra) more" : "; e altri \(extra)" }
        return text
    }
}
