import Foundation
import Combine

/// The public facade of the kit: one object that owns the mission state machine, owner authorization,
/// target-follow logic and the vehicle adapter.
///
/// Typical use:
/// ```swift
/// let drone = DroneCompanionController()                       // Face ID + simulated vehicle
/// drone.onEvent = { event in audio.say(event.announcement()) } // host decides how to present events
/// drone.submit(observation)                                    // every perception update
/// DroneControlButton(controller: drone, targetID: registeredPersonID)
/// ```
///
/// Rules it never breaks:
/// - It follows only the `targetID` the mission was started with, and only while the host reports that
///   identity as verified and directly observed. It never picks a person by itself.
/// - Guidance stops the moment the user stops it, the data goes stale, the identity becomes uncertain,
///   or the mission is ended.
/// - Completion is reported only when the vehicle adapter reports that it has landed.
@MainActor
public final class DroneCompanionController: ObservableObject {

    // MARK: Observable state

    @Published public private(set) var state: DroneMissionState = .off
    /// Set only while `state == .paused`.
    @Published public private(set) var pauseReason: DronePauseReason?
    @Published public private(set) var guidance: DroneFollowGuidance = .held(.missionInactive)
    @Published public private(set) var telemetry = DroneVehicleTelemetry()
    /// The last accepted observation of the current mission.
    @Published public private(set) var latestObservation: DroneTargetObservation?
    @Published public private(set) var observationQuality: DroneObservationQuality = .noData
    /// Why the most recent rejected observation was rejected (wrong target, stale, out of order).
    @Published public private(set) var lastRejection: DroneObservationQuality?
    @Published public private(set) var lastEvent: DroneMissionEvent?
    @Published public private(set) var recentEvents: [DroneMissionEvent] = []
    @Published public private(set) var missionError: DroneMissionError?
    /// The registered person this mission follows. Nil when no mission is running.
    @Published public private(set) var targetID: UUID?

    public private(set) var rejectedObservationCount = 0
    /// Transitions refused by the transition table. Stays 0 unless there is a bug in the kit.
    public private(set) var refusedTransitionCount = 0

    public var configuration: DroneCompanionConfiguration
    /// Called on the main actor for every mission event.
    public var onEvent: ((DroneMissionEvent) -> Void)?
    public weak var eventReceiver: (any DroneMissionEventReceiving)?

    /// True when the vehicle adapter moves nothing physical (always, with the adapters in this package).
    public var isSimulation: Bool { vehicle.isSimulation }
    /// True when the current observations are labelled test data.
    public var isUsingSyntheticData: Bool { latestObservation?.origin == .syntheticTestData }
    /// The clock observations must be stamped with.
    public var currentTime: TimeInterval { clock() }
    /// True when the emergency "Stop Following" action would do something.
    public var canStopFollowing: Bool {
        switch state {
        case .searchingForTarget, .targetLocked, .following, .targetLost: return true
        case .paused: return pauseReason != .stoppedByUser
        default: return false
        }
    }
    public var canResumeFollowing: Bool { state == .paused && pauseReason == .stoppedByUser }

    // MARK: Dependencies and private state

    private let authorizer: any OwnerAuthorizing
    private let vehicle: any DroneVehicleAdapter
    private let clock: @Sendable () -> TimeInterval
    private var filter = FollowGuidanceFilter()
    private var lockCandidateSince: TimeInterval?
    private var lockedAt: TimeInterval = 0
    private var invalidSince: TimeInterval?
    private var pausedAt: TimeInterval = 0
    private var missionToken = 0
    private var ticker: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<DroneMissionEvent>.Continuation] = [:]

    /// - Parameters:
    ///   - authorizer: owner authentication. Default: `LocalDeviceOwnerAuthorizer` (Face ID / passcode).
    ///   - vehicle: default `SimulatedDroneAdapter`.
    ///   - clock: monotonic seconds. Default `ProcessInfo.processInfo.systemUptime`.
    public init(configuration: DroneCompanionConfiguration = DroneCompanionConfiguration(),
                authorizer: (any OwnerAuthorizing)? = nil,
                vehicle: (any DroneVehicleAdapter)? = nil,
                clock: (@Sendable () -> TimeInterval)? = nil) {
        self.configuration = configuration
        self.authorizer = authorizer ?? LocalDeviceOwnerAuthorizer()
        self.vehicle = vehicle ?? SimulatedDroneAdapter()
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
    }

    // MARK: Mission commands

    /// First activation: authorize the owner, prepare, then search for `targetID`.
    /// Returns true when the mission started. Does nothing unless the state is `off` or `landed`.
    @discardableResult
    public func startMission(targetID: UUID?) async -> Bool {
        guard state == .off || state == .landed else { return false }
        guard let targetID else {
            emit(.activationRefused(.noRegisteredTarget))
            return false
        }
        missionToken += 1
        let token = missionToken
        clearMission()
        self.targetID = targetID
        guard transition(to: .authorizationRequired) else { return false }
        setGuidance(.held(.preparing))

        let result = await authorizer.authorizeOwner(reason: configuration.authorizationReason)

        // The user may have cancelled while the system prompt was up.
        guard token == missionToken, state == .authorizationRequired else { return false }
        switch result {
        case .authorized:
            let now = clock()
            transition(to: .preparing)
            emit(.droneModeActivated)
            vehicle.handle(.prepare, at: now)
            startTicker()
            advance(to: now)
            return true
        case let .denied(failure):
            self.targetID = nil
            transition(to: .off)
            standDown()
            emit(.authorizationFailed(failure))
            return false
        }
    }

    /// Feed the controller with what the host currently knows about the registered target.
    /// Ignored outside the states that read observations.
    public func submit(_ observation: DroneTargetObservation) {
        guard state.acceptsObservations else { return }
        let now = clock()
        let quality = ObservationAssessor.assess(observation, expectedTarget: targetID, now: now, configuration: configuration)
        if quality == .wrongTarget || quality == .stale {
            reject(quality)
            return
        }
        if let latest = latestObservation, observation.timestamp < latest.timestamp {
            reject(.outOfOrder)
            return
        }
        latestObservation = observation
        evaluate(now)
    }

    /// Emergency action: stop follow guidance now. The mission stays up (the simulated vehicle holds
    /// position) until `resumeFollowing()` or `requestTermination()`.
    public func stopFollowing() {
        guard canStopFollowing else { return }
        let now = clock()
        pause(.stoppedByUser, now)
        setGuidance(.held(.stoppedByUser))
        vehicle.handle(.hold, at: now)
        publishTelemetry()
    }

    /// Leaves a user stop. The target has to be acquired again from scratch.
    public func resumeFollowing() {
        guard canResumeFollowing else { return }
        lockCandidateSince = nil
        invalidSince = nil
        filter.reset()
        transition(to: .searchingForTarget)
        emit(.searchingForTarget)
        evaluate(clock())
    }

    /// Second activation: stop guidance immediately and end the mission (return, landing).
    public func requestTermination() {
        let now = clock()
        switch state {
        case .authorizationRequired:
            missionToken += 1            // invalidates the pending authorization
            targetID = nil
            transition(to: .off)
            standDown()
            emit(.missionCancelled)
        case .preparing, .searchingForTarget, .targetLocked, .following, .targetLost, .paused:
            setGuidance(.held(.returning))
            transition(to: .returnRequested)
            emit(.returnRequested)
            vehicle.handle(.returnToUser, at: now)
            advance(to: now)
        case .off, .returnRequested, .landing, .landed, .error:
            break
        }
    }

    /// Back to `off` after a completed or failed mission.
    public func reset() {
        guard state == .landed || state == .error else { return }
        clearMission()
        targetID = nil
        transition(to: .off)
        standDown()
    }

    /// What `DroneControlButton` does: start when idle, end the mission when one is running,
    /// nothing while authorizing, returning or landing, reset after an error.
    public func primaryAction(targetID: UUID?) {
        switch state {
        case .off, .landed:
            Task { await self.startMission(targetID: targetID) }
        case .error:
            reset()
        case .authorizationRequired, .returnRequested, .landing:
            break
        case .preparing, .searchingForTarget, .targetLocked, .following, .targetLost, .paused:
            requestTermination()
        }
    }

    /// Same as `primaryAction(targetID:)`, but returns after a start attempt has finished.
    public func performPrimaryAction(targetID: UUID?) async {
        if state == .off || state == .landed {
            await startMission(targetID: targetID)
        } else {
            primaryAction(targetID: targetID)
        }
    }

    /// Advances the mission to `time` (default: now). Called by the internal ticker; call it yourself
    /// only when `configuration.runsInternalTicker` is false.
    public func advance(to time: TimeInterval? = nil) {
        guard state != .off else { return }
        let now = time ?? clock()
        vehicle.advance(to: now)
        syncWithVehicle(now)
        evaluate(now)
        publishTelemetry()
        if !state.isMissionActive { stopTicker() }
    }

    /// Mission events as an async sequence. Each call returns an independent stream.
    public func events() -> AsyncStream<DroneMissionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DroneMissionEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    // MARK: Vehicle

    private func syncWithVehicle(_ now: TimeInterval) {
        let vehiclePhase = vehicle.telemetry.phase
        if case let .fault(message) = vehiclePhase {
            if state.isMissionActive { fail(.vehicleFault(message)) }
            return
        }
        if state == .preparing, vehiclePhase == .hovering {
            transition(to: .searchingForTarget)
            emit(.searchingForTarget)
        }
        if state == .returnRequested, vehiclePhase == .landing || vehiclePhase == .landed {
            transition(to: .landing)
            emit(.landingStarted)
        }
        if state == .landing, vehiclePhase == .landed {
            transition(to: .landed)
            emit(.missionCompleted)
        }
    }

    private func fail(_ error: DroneMissionError) {
        missionError = error
        transition(to: .error)
        setGuidance(.held(.fault))
        emit(.missionFailed(error))
    }

    // MARK: Target logic

    private func evaluate(_ now: TimeInterval) {
        guard state.acceptsObservations else {
            setGuidance(.held(inactiveHold))
            return
        }
        let quality = ObservationAssessor.assess(latestObservation, expectedTarget: targetID, now: now, configuration: configuration)
        if quality != observationQuality { observationQuality = quality }

        switch state {
        case .searchingForTarget, .targetLost:
            if quality == .valid {
                let since = lockCandidateSince ?? now
                lockCandidateSince = since
                if now - since >= configuration.lockHoldSeconds { lock(now) }
            } else {
                lockCandidateSince = nil
            }
        case .targetLocked:
            if quality == .valid {
                invalidSince = nil
                if now - lockedAt >= configuration.settleSeconds {
                    transition(to: .following)
                    emit(.followingActive)
                }
            } else {
                degrade(quality, now)
            }
        case .following:
            if quality == .valid { invalidSince = nil } else { degrade(quality, now) }
        case .paused:
            recoverOrExpire(quality, now)
        default:
            break
        }
        updateGuidance(quality, now)
    }

    private func lock(_ now: TimeInterval) {
        lockCandidateSince = nil
        invalidSince = nil
        lockedAt = now
        filter.reset()
        transition(to: .targetLocked)
        emit(.targetAcquired)
    }

    /// TARGET_LOCKED / FOLLOWING with an observation that is not valid.
    private func degrade(_ quality: DroneObservationQuality, _ now: TimeInterval) {
        let since = invalidSince ?? now
        invalidSince = since
        switch quality {
        case .identityUnverified:
            lose()                                   // the host no longer vouches for the identity
        case .identityAmbiguous:
            pause(.identityAmbiguous, now)
        default:
            if now - since >= configuration.occlusionGraceSeconds {
                lose()
            } else if now - since >= configuration.pauseDelaySeconds {
                pause(Self.pauseReason(for: quality), now)
            }
        }
    }

    /// PAUSED for a reason other than a user stop: resume on a valid observation, give up after the grace time.
    private func recoverOrExpire(_ quality: DroneObservationQuality, _ now: TimeInterval) {
        guard let reason = pauseReason, reason != .stoppedByUser else { return }
        switch quality {
        case .valid:
            invalidSince = nil
            filter.reset()
            transition(to: .following)
            emit(.followingResumed)
        case .identityUnverified:
            lose()
        case .identityAmbiguous:
            if reason != .identityAmbiguous {
                pause(.identityAmbiguous, now)
            } else if now - pausedAt >= configuration.ambiguousTimeoutSeconds {
                lose()
            }
        default:
            let since = invalidSince ?? pausedAt
            let limit = reason == .identityAmbiguous ? configuration.ambiguousTimeoutSeconds : configuration.occlusionGraceSeconds
            if now - since >= limit { lose() }
        }
    }

    private func pause(_ reason: DronePauseReason, _ now: TimeInterval) {
        if state == .paused {
            guard pauseReason != reason else { return }
            pauseReason = reason
        } else {
            guard transition(to: .paused, pause: reason) else { return }
        }
        pausedAt = now
        emit(.followingPaused(reason))
    }

    private func lose() {
        invalidSince = nil
        lockCandidateSince = nil
        filter.reset()
        transition(to: .targetLost)
        emit(.targetLost)
    }

    private func updateGuidance(_ quality: DroneObservationQuality, _ now: TimeInterval) {
        guard state == .following, quality == .valid, let observation = latestObservation,
              let x = observation.normalizedCenterX, let y = observation.normalizedCenterY else {
            let reason: DroneGuidanceHold = state == .following ? Self.hold(for: quality) : inactiveHold
            setGuidance(.held(reason, confidence: latestObservation?.confidence ?? 0))
            if state.acceptsObservations { vehicle.handle(.hold, at: now) }
            return
        }
        let next: DroneFollowGuidance
        if configuration.prefersHostGuidance, let host = observation.hostGuidance {
            next = host.isActive
                ? DroneFollowGuidance(hold: nil, horizontal: host.horizontal, vertical: host.vertical,
                                      horizontalOffset: host.horizontalOffset, verticalOffset: host.verticalOffset,
                                      confidence: observation.confidence, source: .host)
                : .held(.heldByHost, confidence: observation.confidence)
        } else {
            next = filter.update(centerX: x, centerY: y, confidence: observation.confidence, now: now, configuration: configuration)
        }
        setGuidance(next)
        vehicle.handle(next.isActive ? .follow(next) : .hold, at: now)
    }

    /// The hold reason for every state in which guidance is never active.
    private var inactiveHold: DroneGuidanceHold {
        switch state {
        case .off, .landed: return .missionInactive
        case .authorizationRequired, .preparing: return .preparing
        case .searchingForTarget: return .searching
        case .targetLocked: return .settling
        case .following: return .targetOccluded
        case .targetLost: return .targetLost
        case .returnRequested: return .returning
        case .landing: return .landing
        case .error: return .fault
        case .paused:
            switch pauseReason {
            case .stoppedByUser?: return .stoppedByUser
            case .lowConfidence?: return .lowConfidence
            case .staleData?: return .staleData
            case .identityAmbiguous?: return .identityAmbiguous
            case .targetOccluded?, nil: return .targetOccluded
            }
        }
    }

    private static func hold(for quality: DroneObservationQuality) -> DroneGuidanceHold {
        switch quality {
        case .identityAmbiguous: return .identityAmbiguous
        case .lowConfidence: return .lowConfidence
        case .stale, .noData, .outOfOrder, .wrongTarget: return .staleData
        case .notDirectlyObserved, .noPosition, .identityUnverified, .valid: return .targetOccluded
        }
    }

    private static func pauseReason(for quality: DroneObservationQuality) -> DronePauseReason {
        switch quality {
        case .identityAmbiguous: return .identityAmbiguous
        case .lowConfidence: return .lowConfidence
        case .stale, .noData, .outOfOrder, .wrongTarget: return .staleData
        case .notDirectlyObserved, .noPosition, .identityUnverified, .valid: return .targetOccluded
        }
    }

    // MARK: Plumbing

    @discardableResult
    private func transition(to next: DroneMissionState, pause reason: DronePauseReason? = nil) -> Bool {
        guard state.canTransition(to: next) else {
            refusedTransitionCount += 1
            return false
        }
        state = next
        pauseReason = next == .paused ? reason : nil
        return true
    }

    private func reject(_ quality: DroneObservationQuality) {
        rejectedObservationCount += 1
        if lastRejection != quality { lastRejection = quality }
    }

    private func clearMission() {
        latestObservation = nil
        observationQuality = .noData
        lastRejection = nil
        missionError = nil
        lockCandidateSince = nil
        invalidSince = nil
        filter.reset()
    }

    /// Everything back to idle: vehicle released, guidance neutral, timer stopped.
    private func standDown() {
        stopTicker()
        vehicle.handle(.shutdown, at: clock())
        setGuidance(.held(.missionInactive))
        publishTelemetry()
    }

    private func setGuidance(_ next: DroneFollowGuidance) {
        if next != guidance { guidance = next }
    }

    private func publishTelemetry() {
        let next = vehicle.telemetry
        if next != telemetry { telemetry = next }
    }

    private func emit(_ event: DroneMissionEvent) {
        lastEvent = event
        recentEvents.append(event)
        if recentEvents.count > 50 { recentEvents.removeFirst(recentEvents.count - 50) }
        onEvent?(event)
        eventReceiver?.droneCompanion(self, didEmit: event)
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func startTicker() {
        guard configuration.runsInternalTicker, ticker == nil else { return }
        let nanoseconds = UInt64(max(configuration.tickInterval, 0.01) * 1_000_000_000)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.advance()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
