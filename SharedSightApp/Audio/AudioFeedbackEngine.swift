import AVFoundation
import UIKit
import QuartzCore
import SharedSightCore

/// Real text-to-speech for alert intents. Main-thread only.
/// Policy: one utterance at a time; only an interrupting, higher-priority intent cuts speech off;
/// at most one pending utterance is kept and it is discarded if it becomes stale; other audio is mixed, not silenced.
final class AudioFeedbackEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AlertIntent?
    private var pending: (text: String, intent: AlertIntent, queuedAt: Timestamp)?
    private var startTimes: [ObjectIdentifier: AlertIntent] = [:]

    var language: SpeechLanguage = .english { didSet { refreshReadiness() } }
    var hapticsEnabled = true
    var muted = false {
        didSet { if muted { synthesizer.stopSpeaking(at: .immediate); pending = nil; current = nil }; refreshReadiness() }
    }
    private(set) var ready = false
    private(set) var sessionError: String?
    private(set) var lastSpeechDelay: Double?      // evidence capture -> first audio, seconds
    private(set) var lastSpoken = ""
    var onSpoken: ((String) -> Void)?
    var maxPendingAge = 2.0
    /// Multiplier on the system default speech rate, set by the user (0.8 ... 1.6).
    /// Ignored while VoiceOver is running: then the utterance follows the user's own VoiceOver voice and rate.
    var rateMultiplier: Float = 1.12

    // Generators are kept and prepared so the tap arrives with the first syllable, not after it.
    private let notificationHaptic = UINotificationFeedbackGenerator()
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks free text the user explicitly asked for (surroundings summary, repeat, voice test).
    /// Spoken even when alerts are muted, because it is an answer to a direct request. Low priority:
    /// any interrupting obstacle alert cuts it off.
    func sayRequested(_ text: String) {
        guard sessionError == nil, !text.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        pending = nil
        speak(text, AlertIntent(kind: .system(.perceptionRestored), sector: nil, distance: nil, source: .localCamera,
                                priority: 1, interrupts: false, evidenceTimestamp: CACurrentMediaTime()),
              remember: false)
    }

    func prepare() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            try session.setActive(true)
            sessionError = nil
        } catch {
            sessionError = String(describing: error)
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        ready = sessionError == nil && !muted && AVSpeechSynthesisVoice(language: language.rawValue) != nil
    }

    /// `intents` must be sorted by descending priority (as returned by ObstacleAlertDecisionEngine).
    func handle(_ intents: [AlertIntent]) {
        guard !muted else { return }
        let builder = AlertPhraseBuilder(language: language)
        for intent in intents {
            let text = builder.phrase(for: intent)
            if synthesizer.isSpeaking, let cur = current {
                if intent.interrupts && intent.priority > cur.priority {
                    synthesizer.stopSpeaking(at: .immediate)
                    speak(text, intent)
                } else if pending == nil || intent.priority > pending!.intent.priority {
                    pending = (text, intent, CACurrentMediaTime())
                }
            } else {
                speak(text, intent)
            }
        }
    }

    /// Speaks a status sentence that is not an obstacle alert (onboarding, settings confirmation).
    func say(_ notice: SystemNotice) {
        handle([AlertIntent(kind: .system(notice), sector: nil, distance: nil, source: .localCamera, priority: 60,
                            interrupts: false, evidenceTimestamp: CACurrentMediaTime())])
    }

    private func speak(_ text: String, _ intent: AlertIntent, remember: Bool = true) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * rateMultiplier, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        // A VoiceOver user has already chosen a voice and a rate they can follow. Use those instead of ours.
        utterance.prefersAssistiveTechnologySettings = UIAccessibility.isVoiceOverRunning
        current = intent
        startTimes[ObjectIdentifier(utterance)] = intent
        if remember {
            lastSpoken = text
            onSpoken?(text)
        }
        synthesizer.speak(utterance)
        guard hapticsEnabled, remember else { return }
        // Three distinct patterns: failure, own camera straight ahead, another device.
        switch intent.kind {
        case .system(.perceptionUnavailable): notificationHaptic.notificationOccurred(.error)
        case .obstacle where intent.sector == .ahead: heavyHaptic.impactOccurred()
        case .peerObstacle: mediumHaptic.impactOccurred()
        default: break
        }
        notificationHaptic.prepare(); heavyHaptic.prepare(); mediumHaptic.prepare()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let intent = startTimes.removeValue(forKey: ObjectIdentifier(utterance)) {
            lastSpeechDelay = CACurrentMediaTime() - intent.evidenceTimestamp
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { advance() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        startTimes.removeValue(forKey: ObjectIdentifier(utterance))
    }

    private func advance() {
        current = nil
        guard let p = pending else { return }
        pending = nil
        if CACurrentMediaTime() - p.queuedAt <= maxPendingAge { speak(p.text, p.intent) }   // never speak a stale warning
    }
}
