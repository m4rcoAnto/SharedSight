import Foundation

public enum AlertDeliveryPhase: String, Sendable { case decided, queued, started, finished, discarded }
public struct AlertStamp: Sendable, Equatable {
    public var deliveryID = UUID()
    public var identity: String
    public var epoch: String
    public var version: Int
    public var evaluatedAt: Timestamp
    public var expiresAt: Timestamp
    public init(identity: String, epoch: String, version: Int, evaluatedAt: Timestamp, expiresAt: Timestamp) {
        self.identity = identity; self.epoch = epoch; self.version = version
        self.evaluatedAt = evaluatedAt; self.expiresAt = expiresAt
    }
}
public struct AlertValidationSnapshot: Sendable {
    public var epoch: String
    public var evaluatedAt: Timestamp
    public var versions: [String: Int]
    public init(epoch: String, evaluatedAt: Timestamp, versions: [String: Int]) {
        self.epoch = epoch; self.evaluatedAt = evaluatedAt; self.versions = versions
    }
    public func permits(_ intent: AlertIntent, now: Timestamp, alreadyStarted: Bool = false) -> Bool {
        guard let stamp = intent.stamp else { return true } // only explicit manual/status messages are unstamped
        return now.isFinite && now >= evaluatedAt && now - evaluatedAt <= 0.75 && stamp.epoch == epoch &&
            versions[stamp.identity] == stamp.version && (alreadyStarted || (now >= stamp.evaluatedAt && now <= stamp.expiresAt))
    }
}
public struct SpeechItem: Sendable, Equatable {
    public var id = UUID()
    public var text: String
    public var intent: AlertIntent
    public var requested: Bool
    public var queuedAt: Timestamp
    public init(text: String, intent: AlertIntent, requested: Bool = false, now: Timestamp) {
        self.text = text; self.intent = intent; self.requested = requested; self.queuedAt = now
    }
}
public enum SpeechQueueAction: Sendable {
    case speak(SpeechItem), stop(UUID), lifecycle(AlertIntent, AlertDeliveryPhase)
}

/// Deterministic queue model. Real synthesizer callbacks own started/finished state; no guessed speech duration.
public struct RevocableSpeechQueue: Sendable {
    public private(set) var current: SpeechItem?
    public private(set) var pending: SpeechItem?
    public private(set) var started = false
    private var stopping = false
    public var maxPendingAge = 1.2
    public var urgentPriority = 100
    public init() {}
    public mutating func submit(_ item: SpeechItem, now: Timestamp, validation: AlertValidationSnapshot) -> [SpeechQueueAction] {
        guard validation.permits(item.intent, now: now) else { return [.lifecycle(item.intent, .discarded)] }
        var actions: [SpeechQueueAction] = [.lifecycle(item.intent, .queued)]
        guard let current else {
            self.current = item; started = false
            actions.append(.speak(item)); return actions
        }
        // Manual requests wait behind urgent speech, and never interrupt it.
        let preempt = !item.requested && item.intent.interrupts && item.intent.priority > current.intent.priority
        if pending == nil || item.intent.priority >= pending!.intent.priority {
            if let pending { actions.append(.lifecycle(pending.intent, .discarded)) }
            pending = item
        } else { actions.append(.lifecycle(item.intent, .discarded)) }
        if preempt && !stopping { stopping = true; actions.append(.stop(current.id)) }
        return actions
    }
    public mutating func revalidate(now: Timestamp, validation: AlertValidationSnapshot) -> [SpeechQueueAction] {
        var actions: [SpeechQueueAction] = []
        if let pending, !validation.permits(pending.intent, now: now) || now - pending.queuedAt > maxPendingAge {
            actions.append(.lifecycle(pending.intent, .discarded)); self.pending = nil
        }
        // Validity is checked before speaking. A sentence already under way is finished (cut mid-word it means nothing)
        // unless its coordinate epoch is gone; urgent news preempts it through submit().
        if let current, !stopping {
            let epochGone = current.intent.stamp.map { $0.epoch != validation.epoch } ?? false
            if started ? epochGone : !validation.permits(current.intent, now: now) { stopping = true; actions.append(.stop(current.id)) }
        }
        return actions
    }
    public mutating func didStart(_ id: UUID, now: Timestamp, validation: AlertValidationSnapshot) -> [SpeechQueueAction] {
        guard let current, current.id == id else { return [] }
        guard !stopping, validation.permits(current.intent, now: now) else {
            stopping = true; return [.stop(id)]
        }
        started = true; return [.lifecycle(current.intent, .started)]
    }
    public mutating func didEnd(_ id: UUID, cancelled: Bool, now: Timestamp, validation: AlertValidationSnapshot) -> [SpeechQueueAction] {
        guard let current, current.id == id else { return [] } // stale callbacks cannot clear a new utterance
        var actions: [SpeechQueueAction] = [.lifecycle(current.intent, cancelled || !started ? .discarded : .finished)]
        self.current = nil; started = false; stopping = false
        if let next = pending {
            pending = nil
            if validation.permits(next.intent, now: now), now - next.queuedAt <= maxPendingAge {
                self.current = next; actions.append(.speak(next))
            } else { actions.append(.lifecycle(next.intent, .discarded)) }
        }
        return actions
    }
    public mutating func mute() -> [SpeechQueueAction] {
        var actions: [SpeechQueueAction] = []
        if let pending { actions.append(.lifecycle(pending.intent, .discarded)); self.pending = nil }
        if let current, !stopping { stopping = true; actions.append(.stop(current.id)) }
        return actions
    }
}
