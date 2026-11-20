import AVFoundation
import UIKit
import QuartzCore
import SharedSightCore

/// Main-thread adapter. Queue decisions are deterministic Core code; speech lifecycle comes from AV callbacks.
final class AudioFeedbackEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue = RevocableSpeechQueue()
    private var utterances: [ObjectIdentifier: SpeechItem] = [:]
    private var validation = AlertValidationSnapshot(epoch: "", evaluatedAt: 0, versions: [:])
    private var lastDelivered: SpeechItem?
    private var monitor: Timer?
    var onDelivery: ((AlertIntent, AlertDeliveryPhase, Timestamp) -> Void)?
    var language: SpeechLanguage = .english { didSet { refreshReadiness() } }
    var hapticsEnabled = true
    var muted = false {
        didSet { if muted { perform(queue.mute()) }; refreshReadiness() }
    }
    private(set) var ready = false
    private(set) var sessionError: String?
    private(set) var lastSpeechDelay: Double?
    private(set) var lastSpoken = ""
    var onSpoken: ((String) -> Void)?
    var maxPendingAge: Double { get { queue.maxPendingAge } set { queue.maxPendingAge = newValue } }
    var rateMultiplier: Float = 1.12
    private let notificationHaptic = UINotificationFeedbackGenerator()
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init() {
        super.init(); synthesizer.delegate = self
    }
    func updateValidation(_ snapshot: AlertValidationSnapshot) {
        validation = snapshot
        perform(queue.revalidate(now: CACurrentMediaTime(), validation: validation))
    }
    func sayRequested(_ text: String) {
        guard !muted, sessionError == nil, !text.isEmpty else { return }
        let now = CACurrentMediaTime()
        let intent = AlertIntent(kind: .system(.perceptionRestored), sector: nil, distance: nil, source: .localCamera,
                                 priority: 1, interrupts: false, evidenceTimestamp: now)
        perform(queue.submit(SpeechItem(text: text, intent: intent, requested: true, now: now), now: now, validation: validation))
    }
    /// Revalidate the original identity/direction against the latest evidence, never replay stale text blindly.
    func repeatLastAnnouncement() {
        let now = CACurrentMediaTime()
        guard let last = lastDelivered, last.intent.stamp != nil,
              validation.permits(last.intent, now: now, alreadyStarted: true), !muted else {
            sayRequested(language == .italian ? "L'ultimo avviso non è più attuale." : "The last warning is no longer current.")
            return
        }
        var intent = last.intent
        intent.priority = 1; intent.interrupts = false
        // Repeat is a manual read, not a second delivery/cooldown commit of the original decision.
        intent.stamp?.deliveryID = UUID(); intent.stamp?.evaluatedAt = now; intent.stamp?.expiresAt = now + 0.6
        perform(queue.submit(SpeechItem(text: last.text, intent: intent, requested: true, now: now), now: now, validation: validation))
    }
    func sayStatus(_ text: String, haptic: UINotificationFeedbackGenerator.FeedbackType?) {
        guard !muted, sessionError == nil, !text.isEmpty else { return }
        if hapticsEnabled, let haptic { notificationHaptic.notificationOccurred(haptic); notificationHaptic.prepare() }
        let now = CACurrentMediaTime()
        let intent = AlertIntent(kind: .system(.perceptionRestored), sector: nil, distance: nil, source: .localCamera,
                                 priority: 30, interrupts: false, evidenceTimestamp: now)
        perform(queue.submit(SpeechItem(text: text, intent: intent, now: now), now: now, validation: validation))
    }
    func prepare() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            try session.setActive(true); sessionError = nil
        } catch { sessionError = String(describing: error) }
        if monitor == nil {
            monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.perform(self.queue.revalidate(now: CACurrentMediaTime(), validation: self.validation))
            }
        }
        refreshReadiness()
    }
    private func refreshReadiness() { ready = sessionError == nil && !muted && AVSpeechSynthesisVoice(language: language.rawValue) != nil }
    func handle(_ intents: [AlertIntent]) {
        let now = CACurrentMediaTime(), builder = AlertPhraseBuilder(language: language)
        for intent in intents {
            guard !muted, ready else { onDelivery?(intent, .discarded, now); continue }
            perform(queue.submit(SpeechItem(text: builder.phrase(for: intent), intent: intent, now: now), now: now, validation: validation))
        }
    }
    func say(_ notice: SystemNotice) {
        handle([AlertIntent(kind: .system(notice), sector: nil, distance: nil, source: .localCamera,
                            priority: 60, interrupts: false, evidenceTimestamp: CACurrentMediaTime())])
    }
    private func perform(_ actions: [SpeechQueueAction]) {
        for action in actions {
            switch action {
            case let .lifecycle(intent, phase): onDelivery?(intent, phase, CACurrentMediaTime())
            case let .stop(id):
                // didCancel/didFinish own the transition to the waiting utterance; old callbacks cannot clear a new one.
                if !synthesizer.stopSpeaking(at: .immediate) {
                    perform(queue.didEnd(id, cancelled: true, now: CACurrentMediaTime(), validation: validation))
                }
            case let .speak(item):
                guard !muted, validation.permits(item.intent, now: CACurrentMediaTime()) else {
                    perform(queue.didEnd(item.id, cancelled: true, now: CACurrentMediaTime(), validation: validation)); continue
                }
                let utterance = AVSpeechUtterance(string: item.text)
                utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
                utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * rateMultiplier, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
                utterance.prefersAssistiveTechnologySettings = UIAccessibility.isVoiceOverRunning
                utterances[ObjectIdentifier(utterance)] = item
                synthesizer.speak(utterance)
            }
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let item = utterances[ObjectIdentifier(utterance)] else { return }
        let now = CACurrentMediaTime()
        perform(queue.didStart(item.id, now: now, validation: validation))
        guard queue.started else { return }
        lastSpeechDelay = now - item.intent.evidenceTimestamp
        if !item.requested {
            lastDelivered = item; lastSpoken = item.text; onSpoken?(item.text)
        }
        guard hapticsEnabled, !muted, !item.requested else { return }
        if item.intent.priority >= 100 { heavyHaptic.impactOccurred() }
        else {
            switch item.intent.kind {
            case .system(.perceptionUnavailable): notificationHaptic.notificationOccurred(.error)
            case .obstacle where item.intent.sector == .ahead: heavyHaptic.impactOccurred()
            case .wallAhead: heavyHaptic.impactOccurred()
            case .peerObstacle, .hiddenSeenByOther, .encounter: mediumHaptic.impactOccurred()
            default: break
            }
        }
        notificationHaptic.prepare(); heavyHaptic.prepare(); mediumHaptic.prepare()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { end(utterance, cancelled: false) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { end(utterance, cancelled: true) }
    private func end(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        guard let item = utterances.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        perform(queue.didEnd(item.id, cancelled: cancelled, now: CACurrentMediaTime(), validation: validation))
    }
}
