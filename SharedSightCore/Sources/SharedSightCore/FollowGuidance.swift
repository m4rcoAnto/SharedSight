import Foundation

// Camera-based following. Everything here is computed from the target's position in the image.
// No drone exists in this project: the output is a *suggested camera correction* shown on screen, and the
// adapter protocol at the bottom is the seam where a real vehicle could be attached later.

public struct FollowConfig: Sendable {
    public var deadZoneX = 0.16          // |horizontalOffset| below this = centred (offset range is -1...1)
    public var deadZoneY = 0.24
    public var hysteresis = 0.05         // must come back this far inside the dead zone before "centred" again
    public var smoothingSeconds = 0.25   // time constant of the exponential filter on the offsets
    public var minConfidence = 0.35      // association confidence below this pauses guidance
    public var sizeBand = 0.30           // relative apparent-size change tolerated before a range cue
    public init() {}
}

public enum HorizontalCue: String, Sendable { case left, centered, right }
public enum VerticalCue: String, Sendable { case up, centered, down }
/// Apparent size against the size when guidance started. A visual cue only — never a distance.
public enum ApparentSizeCue: String, Sendable { case smaller, steady, larger }

public enum GuidanceHold: String, Sendable {
    case notTracking, searching, settling, predictedOnly, ambiguous, targetLost, lowConfidence
}

public struct FollowGuidance: Sendable, Equatable {
    public var targetVisible = false
    public var targetCenterX: Double?            // 0...1, upright image
    public var targetCenterY: Double?
    public var horizontalOffset = 0.0            // smoothed, -1 (left edge) ... +1 (right edge)
    public var verticalOffset = 0.0              // smoothed, -1 (top) ... +1 (bottom)
    public var boundingBoxArea: Double?          // fraction of the image
    public var relativeSize: Double?             // boundingBoxArea / area when guidance started
    public var trackingConfidence = 0.0
    /// Nil = guidance is being produced. Otherwise the reason it is paused; all cues are then neutral.
    public var hold: GuidanceHold? = .notTracking
    public var horizontal: HorizontalCue = .centered
    public var vertical: VerticalCue = .centered
    public var size: ApparentSizeCue = .steady
    public init() {}

    public var active: Bool { hold == nil }
}

/// Turns the target status into smoothed, dead-zoned, confidence-gated follow cues.
/// Guidance is produced only for a target that is associated *and observed in this frame*.
public final class FollowGuidanceController {
    public var config: FollowConfig
    private var lastTime: Timestamp?
    private var smoothX: Double?
    private var smoothY: Double?
    private var referenceArea: Double?
    private var horizontal: HorizontalCue = .centered
    private var vertical: VerticalCue = .centered

    public init(config: FollowConfig = FollowConfig()) { self.config = config }

    public func reset() {
        lastTime = nil; smoothX = nil; smoothY = nil; referenceArea = nil
        horizontal = .centered; vertical = .centered
    }

    public func update(_ status: TargetStatus, now: Timestamp) -> FollowGuidance {
        var g = FollowGuidance()
        g.trackingConfidence = status.associationConfidence
        if let box = status.box {
            // Reported for display even while paused, but flagged: `targetVisible` is false for a prediction.
            g.targetCenterX = box.cx
            g.targetCenterY = box.cy
            g.boundingBoxArea = box.clampedToUnit.area
            g.targetVisible = !status.boxIsPredicted && status.isLocked
        }

        let hold: GuidanceHold?
        switch status.state {
        case .unassigned: hold = .notTracking
        case .searching: hold = .searching
        case .acquired: hold = .settling
        case .temporarilyOccluded: hold = .predictedOnly
        case .ambiguous: hold = .ambiguous
        case .lost: hold = .targetLost
        case .following:
            hold = status.boxIsPredicted || status.box == nil ? .predictedOnly
                : (status.associationConfidence < config.minConfidence ? .lowConfidence : nil)
        }
        g.hold = hold

        // The association is gone or unproven: forget the filter so stale motion cannot leak into the next lock.
        if status.state == .lost || status.state == .ambiguous || status.state == .unassigned || status.state == .searching {
            reset()
            return g
        }
        guard hold == nil, let box = status.box else {
            // Settling / occluded / low confidence: keep the filter state, emit neutral cues.
            lastTime = now
            g.horizontalOffset = smoothX ?? 0
            g.verticalOffset = smoothY ?? 0
            if let reference = referenceArea, let area = g.boundingBoxArea { g.relativeSize = area / reference }
            return g
        }

        let rawX = min(max((box.cx - 0.5) * 2, -1), 1)
        let rawY = min(max((box.cy - 0.5) * 2, -1), 1)
        let dt = max(0, now - (lastTime ?? now))
        let alpha = lastTime == nil || config.smoothingSeconds <= 0 ? 1 : 1 - exp(-dt / config.smoothingSeconds)
        let x = (smoothX ?? rawX) + alpha * (rawX - (smoothX ?? rawX))
        let y = (smoothY ?? rawY) + alpha * (rawY - (smoothY ?? rawY))
        smoothX = x; smoothY = y; lastTime = now

        horizontal = Self.cue(x, current: horizontal, zone: config.deadZoneX, hysteresis: config.hysteresis,
                              negative: .left, neutral: .centered, positive: .right)
        vertical = Self.cue(y, current: vertical, zone: config.deadZoneY, hysteresis: config.hysteresis,
                            negative: .up, neutral: .centered, positive: .down)

        let area = box.clampedToUnit.area
        if referenceArea == nil, area > 0 { referenceArea = area }
        let ratio = referenceArea.map { area / $0 }
        g.horizontalOffset = x
        g.verticalOffset = y
        g.relativeSize = ratio
        g.horizontal = horizontal
        g.vertical = vertical
        // A box cut by the frame edge says nothing reliable about apparent size.
        let cut = box.x <= 0.01 || box.y <= 0.01 || box.maxX >= 0.99 || box.maxY >= 0.99
        if let ratio, !cut {
            g.size = ratio < 1 - config.sizeBand ? .smaller : (ratio > 1 + config.sizeBand ? .larger : .steady)
        }
        return g
    }

    /// Dead zone with hysteresis: leaves "centred" at `zone`, returns to it at `zone - hysteresis`.
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

// MARK: - Seam for a real vehicle (not implemented, on purpose)

/// Normalised intent derived from `FollowGuidance`. Not a motor command: units, limits, rates and safety
/// envelopes belong to the adapter of a specific aircraft and must be validated in flight tests.
public struct FollowSetpoint: Sendable, Equatable {
    public var yaw: Double       // -1 (turn left) ... +1 (turn right); 0 inside the dead zone
    public var tilt: Double      // -1 (up) ... +1 (down)
    public var valid: Bool       // false = hold position / hover; never extrapolate from the last valid value
    public var hold: GuidanceHold?

    public init(_ g: FollowGuidance) {
        valid = g.active
        hold = g.hold
        yaw = g.active && g.horizontal != .centered ? g.horizontalOffset : 0
        tilt = g.active && g.vertical != .centered ? g.verticalOffset : 0
    }
}

/// What a real drone integration would implement. It must add its own, independent safety layer:
/// geofence, altitude and speed limits, link-loss failsafe, obstacle avoidance, manual override.
public protocol FollowVehicleAdapter: AnyObject {
    var isSimulation: Bool { get }
    func apply(_ setpoint: FollowSetpoint, at time: Timestamp)
}

/// The only adapter in this project. It moves nothing; it keeps the last setpoint so the UI can show
/// what a vehicle *would* be asked to do.
public final class SimulatedVehicleAdapter: FollowVehicleAdapter {
    public let isSimulation = true
    public private(set) var last: FollowSetpoint?
    public private(set) var lastTime: Timestamp?
    public init() {}
    public func apply(_ setpoint: FollowSetpoint, at time: Timestamp) { last = setpoint; lastTime = time }
}

// MARK: - Presentation (pure, so the UI mapping can be unit-tested)

public struct TargetPresentation: Equatable, Sendable {
    public enum Tone: String, Sendable { case neutral, accent, caution, alert }
    public var title: String          // short, upper-case status line
    public var detail: String         // one line under it
    public var symbol: String         // SF Symbol name
    public var tone: Tone
    public var showsLockedBox: Bool   // draw the target box in the accent colour
    public var boxIsPredicted: Bool   // draw it dashed and label it as a prediction
    public var announcement: String?  // spoken once when the state is entered

    public static func make(_ s: TargetStatus, guidance: FollowGuidance, language: SpeechLanguage) -> TargetPresentation {
        func tr(_ en: String, _ it: String) -> String { language == .italian ? it : en }
        let who = s.userID ?? tr("nobody", "nessuno")
        switch s.state {
        case .unassigned:
            return .init(title: tr("NOT TRACKING", "NON ATTIVO"),
                         detail: s.userID == nil ? tr("No person selected", "Nessuna persona selezionata") : who,
                         symbol: "scope", tone: .neutral, showsLockedBox: false, boxIsPredicted: false, announcement: nil)
        case .searching:
            return .init(title: tr("SEARCHING", "RICERCA"),
                         detail: tr("Looking for \(who)'s marker", "Cerco il marcatore di \(who)"),
                         symbol: "qrcode.viewfinder", tone: .neutral, showsLockedBox: false, boxIsPredicted: false,
                         announcement: tr("Searching for \(who).", "Ricerca di \(who)."))
        case .acquired:
            return .init(title: tr("TARGET LOCKED", "BERSAGLIO AGGANCIATO"), detail: who,
                         symbol: "lock.fill", tone: .accent, showsLockedBox: true, boxIsPredicted: false,
                         announcement: tr("Target locked. \(who).", "Bersaglio agganciato. \(who)."))
        case .following:
            let detail: String
            switch guidance.hold {
            case .lowConfidence?: detail = tr("\(who) · low confidence, guidance paused", "\(who) · confidenza bassa, guida in pausa")
            default: detail = tr("\(who) · tracking active", "\(who) · tracciamento attivo")
            }
            return .init(title: tr("TARGET LOCKED", "BERSAGLIO AGGANCIATO"), detail: detail,
                         symbol: "lock.fill", tone: guidance.hold == .lowConfidence ? .caution : .accent,
                         showsLockedBox: true, boxIsPredicted: false, announcement: nil)
        case .temporarilyOccluded:
            return .init(title: tr("TARGET HIDDEN", "BERSAGLIO NASCOSTO"),
                         detail: tr("\(who) · predicted position, not confirmed", "\(who) · posizione prevista, non confermata"),
                         symbol: "eye.slash", tone: .caution, showsLockedBox: true, boxIsPredicted: true,
                         announcement: tr("Target hidden.", "Bersaglio nascosto."))
        case .ambiguous:
            return .init(title: tr("TARGET UNCERTAIN", "BERSAGLIO INCERTO"),
                         detail: tr("Following paused · show \(who)'s marker", "Guida in pausa · mostra il marcatore di \(who)"),
                         symbol: "questionmark.circle", tone: .caution, showsLockedBox: false, boxIsPredicted: false,
                         announcement: tr("Target uncertain. Following paused.", "Bersaglio incerto. Guida in pausa."))
        case .lost:
            return .init(title: tr("TARGET LOST", "BERSAGLIO PERSO"),
                         detail: tr("Following stopped · searching for \(who)", "Guida ferma · ricerca di \(who)"),
                         symbol: "exclamationmark.triangle.fill", tone: .alert, showsLockedBox: false, boxIsPredicted: false,
                         announcement: tr("Target lost. Following stopped.", "Bersaglio perso. Guida ferma."))
        }
    }
}

public extension TrackSnapshot {
    /// Display tag of a temporary trajectory, e.g. TRACK-007. Session-local; says nothing about who the person is.
    var trackTag: String { String(format: "TRACK-%03d", id) }
}
