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

    override init() {
        super.init()
        synthesizer.delegate = self
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

    private func speak(_ text: String, _ intent: AlertIntent) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = min(AVSpeechUtteranceDefaultSpeechRate * 1.12, AVSpeechUtteranceMaximumSpeechRate)
        current = intent
        startTimes[ObjectIdentifier(utterance)] = intent
        lastSpoken = text
        onSpoken?(text)
        synthesizer.speak(utterance)
        guard hapticsEnabled else { return }
        switch intent.kind {
        case .system(.perceptionUnavailable): UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .obstacle where intent.sector == .ahead: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .peerObstacle: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: break
        }
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
