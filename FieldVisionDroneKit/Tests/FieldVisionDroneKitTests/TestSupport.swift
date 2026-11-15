import XCTest
@testable import FieldVisionDroneKit

/// Test clock: time moves only when a test says so.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ start: TimeInterval = 1_000) { value = start }

    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Owner authorization with a scripted answer. `yields` makes it suspend, so concurrent callers interleave.
final class MockAuthorizer: OwnerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var result: OwnerAuthorizationResult
    private var calls = 0
    private let yields: Int

    init(result: OwnerAuthorizationResult = .authorized, yields: Int = 0) {
        self.result = result
        self.yields = yields
    }

    var callCount: Int { lock.withLock { calls } }

    func setResult(_ newValue: OwnerAuthorizationResult) { lock.withLock { result = newValue } }

    func authorizeOwner(reason: String) async -> OwnerAuthorizationResult {
        let answer: OwnerAuthorizationResult = lock.withLock {
            calls += 1
            return result
        }
        for _ in 0..<yields { await Task.yield() }
        return answer
    }
}

/// A controller with a manual clock, a scripted authorizer and the real simulated vehicle.
/// No timers run: tests move time with `run`.
@MainActor
final class Harness {
    let targetID = UUID()
    let clock: ManualClock
    let authorizer: MockAuthorizer
    let vehicle: SimulatedDroneAdapter
    let controller: DroneCompanionController
    private(set) var events: [DroneMissionEvent] = []

    init(authorization: OwnerAuthorizationResult = .authorized, yields: Int = 0,
         configure: (inout DroneCompanionConfiguration) -> Void = { _ in }) {
        var configuration = DroneCompanionConfiguration()
        configuration.runsInternalTicker = false
        configure(&configuration)
        let clock = ManualClock()
        let authorizer = MockAuthorizer(result: authorization, yields: yields)
        let vehicle = SimulatedDroneAdapter()
        self.clock = clock
        self.authorizer = authorizer
        self.vehicle = vehicle
        controller = DroneCompanionController(configuration: configuration, authorizer: authorizer, vehicle: vehicle,
                                              clock: { clock.now })
        controller.onEvent = { [weak self] event in self?.events.append(event) }
    }

    func observation(x: Double? = 0.5, y: Double? = 0.5, confidence: Double = 0.9, observed: Bool = true,
                     verified: Bool = true, ambiguous: Bool = false, target: UUID? = nil,
                     host: HostFollowGuidance? = nil, at time: TimeInterval? = nil) -> DroneTargetObservation {
        DroneTargetObservation(targetID: target ?? targetID, normalizedCenterX: x, normalizedCenterY: y,
                               boundingBoxArea: 0.08, confidence: confidence, isDirectlyObserved: observed,
                               isIdentityVerified: verified, isIdentityAmbiguous: ambiguous,
                               timestamp: time ?? clock.now, hostGuidance: host)
    }

    /// Moves time forward in steps. With `feeding`, one observation is submitted per step.
    func run(_ seconds: TimeInterval, step: TimeInterval = 0.05,
             feeding make: ((TimeInterval) -> DroneTargetObservation?)? = nil) {
        let steps = Int((seconds / step).rounded())
        for _ in 0..<steps {
            clock.now += step
            if let observation = make?(clock.now) { controller.submit(observation) }
            controller.advance(to: clock.now)
        }
    }

    /// Valid, verified, directly observed target at `x` for `seconds`.
    func feedValid(_ seconds: TimeInterval, x: Double = 0.5) {
        run(seconds) { time in self.observation(x: x, at: time) }
    }

    /// Start the mission and wait for the simulated preflight: ends in SEARCHING_FOR_TARGET.
    func launch() async {
        await controller.startMission(targetID: targetID)
        run(2)
    }

    /// `launch()` plus a valid target long enough to reach FOLLOWING.
    func launchAndFollow() async {
        await launch()
        feedValid(1.5)
    }

    func count(of event: DroneMissionEvent) -> Int { events.filter { $0 == event }.count }
}
