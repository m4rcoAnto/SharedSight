import Foundation

/// Horizontal distances, in metres, from the camera to the nearest vertical surface along three rays: straight
/// ahead and about 35 degrees to each side. Nil = that ray measured nothing (which is NOT the same as free space).
public struct WallReading: Sendable, Equatable {
    public var forward: Double?
    public var left: Double?
    public var right: Double?
    /// At least one vertical surface is currently being tracked, so a side ray that hits nothing is informative.
    public var planesTracked: Bool
    public init(forward: Double?, left: Double? = nil, right: Double? = nil, planesTracked: Bool = false) {
        self.forward = forward; self.left = left; self.right = right; self.planesTracked = planesTracked
    }
}

/// A decision to say "wall ahead". `roomSide` is only ever set from the side measurements; it is not an instruction.
public struct WallAlert: Sendable, Equatable {
    public var meters: Double
    public var stop: Bool
    public var roomSide: Sector?
    public init(meters: Double, stop: Bool, roomSide: Sector?) { self.meters = meters; self.stop = stop; self.roomSide = roomSide }
}

public struct WallProximityConfig: Sendable {
    public var alertDistance = 1.5            // alert at or below this while the distance is closing
    public var nearDistance = 1.0             // alert at or below this even when standing still
    public var stopDistance = 0.7             // below this: "Stop." and no waiting for the repeat interval
    public var stopResetDistance = 1.0        // the immediate "Stop." can fire again once back above this
    public var rearmDistance = 2.0            // above this the episode is over: the next approach alerts at once
    public var repeatInterval = 4.0           // between two alerts while still closing
    public var stationaryRepeatInterval = 10.0 // between two alerts while not closing (standing at a wall)
    public var closingDrop = 0.1              // metres nearer than the reference sample = closing
    public var closingWindow = 0.5            // the reference sample is renewed this often
    public var referenceMaxAge = 2.0
    public var minConsecutive = 2             // one isolated ray hit is not enough
    public var lostRearm = 3.0                // no forward measurement for this long also ends the episode
    public var sideMargin = 1.0               // a side is named only when it measured this much more than the other...
    public var sideMinRoom = 2.0              // ...and at least this much
    public var sideOtherMax = 3.0             // "hit nothing" counts only when the other side hit this near
    public init() {}
}

/// Pure decision logic for the wall warning. Fed with measurements only; without a forward measurement it emits
/// nothing. It can never state that a direction is clear, free or safe: there is no such output.
public struct WallProximityMonitor: Sendable {
    public var config: WallProximityConfig
    private var reference: (distance: Double, time: Timestamp)?
    private var consecutive = 0
    private var lastAlert: Timestamp?
    private var stopLatched = false
    private var lastMeasured: Timestamp?
    private var lastClosing: Timestamp?

    public init(config: WallProximityConfig = WallProximityConfig()) { self.config = config }

    public mutating func reset() {
        reference = nil; consecutive = 0; lastAlert = nil; stopLatched = false; lastMeasured = nil; lastClosing = nil
    }

    private mutating func rearm() { lastAlert = nil; stopLatched = false }

    public mutating func update(_ reading: WallReading, now: Timestamp) -> WallAlert? {
        guard let d = reading.forward, d.isFinite, d > 0 else {
            consecutive = 0; reference = nil; lastClosing = nil
            if let seen = lastMeasured, now - seen >= config.lostRearm { rearm() }
            return nil
        }
        lastMeasured = now
        consecutive += 1
        var closing = false
        if let ref = reference, now >= ref.time, now - ref.time <= config.referenceMaxAge {
            if ref.distance - d >= config.closingDrop { lastClosing = now }
            if now - ref.time >= config.closingWindow { reference = (d, now) }
        } else {
            reference = (d, now)
        }
        // "Closing" stays true for one window after the last measured approach, so it does not flicker between samples.
        if let t = lastClosing, now >= t, now - t <= config.closingWindow { closing = true }
        if d > config.rearmDistance { rearm(); return nil }
        if d > config.stopResetDistance { stopLatched = false }
        guard consecutive >= config.minConsecutive else { return nil }
        guard d <= config.nearDistance || (d <= config.alertDistance && closing) else { return nil }
        let stop = d < config.stopDistance
        let crossing = stop && !stopLatched
        if let last = lastAlert, !crossing {
            guard now - last >= (closing ? config.repeatInterval : config.stationaryRepeatInterval) else { return nil }
        }
        lastAlert = now
        if stop { stopLatched = true }
        return WallAlert(meters: d, stop: stop, roomSide: roomSide(reading))
    }

    /// The side that measured clearly more room, or nil. Never derived from a side that was not measured against.
    func roomSide(_ r: WallReading) -> Sector? {
        func more(_ side: Double?, than other: Double?) -> Bool {
            guard let other else { return false }           // nothing to compare with: say nothing
            if let side { return side >= config.sideMinRoom && side - other >= config.sideMargin }
            return r.planesTracked && other <= config.sideOtherMax
        }
        if more(r.left, than: r.right) { return .left }
        if more(r.right, than: r.left) { return .right }
        return nil
    }
}
