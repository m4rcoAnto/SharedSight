import Foundation

/// Position -> follow cue, used only when the host did not send guidance of its own:
/// exponential smoothing of the offsets, then a dead zone with hysteresis so the cue does not flicker
/// at the edge of "centred".
struct FollowGuidanceFilter {
    private var smoothX: Double?
    private var smoothY: Double?
    private var lastTime: TimeInterval?
    private var horizontal: DroneHorizontalCue = .centered
    private var vertical: DroneVerticalCue = .centered

    mutating func reset() { self = FollowGuidanceFilter() }

    mutating func update(centerX: Double, centerY: Double, confidence: Double, now: TimeInterval,
                         configuration c: DroneCompanionConfiguration) -> DroneFollowGuidance {
        let rawX = min(max((centerX - 0.5) * 2, -1), 1)
        let rawY = min(max((centerY - 0.5) * 2, -1), 1)
        let dt = max(0, now - (lastTime ?? now))
        let alpha: Double = (lastTime == nil || c.smoothingSeconds <= 0) ? 1 : 1 - exp(-dt / c.smoothingSeconds)
        let previousX = smoothX ?? rawX
        let previousY = smoothY ?? rawY
        let x = previousX + alpha * (rawX - previousX)
        let y = previousY + alpha * (rawY - previousY)
        smoothX = x
        smoothY = y
        lastTime = now

        horizontal = Self.cue(x, current: horizontal, zone: c.deadZoneX, hysteresis: c.hysteresis,
                              negative: .left, neutral: .centered, positive: .right)
        vertical = Self.cue(y, current: vertical, zone: c.deadZoneY, hysteresis: c.hysteresis,
                            negative: .up, neutral: .centered, positive: .down)
        return DroneFollowGuidance(hold: nil, horizontal: horizontal, vertical: vertical, horizontalOffset: x,
                                   verticalOffset: y, confidence: confidence, source: .kit)
    }

    /// Leaves "centred" at `zone`, returns to it at `zone - hysteresis`.
    private static func cue<C: Equatable>(_ value: Double, current: C, zone: Double, hysteresis: Double,
                                          negative: C, neutral: C, positive: C) -> C {
        let inner = max(0, zone - hysteresis)
        if value <= -zone { return negative }
        if value >= zone { return positive }
        if current == negative, value <= -inner { return negative }
        if current == positive, value >= inner { return positive }
        return neutral
    }
}
