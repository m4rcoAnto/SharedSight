import Foundation

public enum Feature: String, CaseIterable, Codable, Sendable {
    case semanticDetection, segmentation, tracking, directionCues, metricDistance, unknownObstacleSensing
    case peerLink, sharedSpatialReference, audio
}

public enum ReliabilityState: String, Codable, Sendable {
    case reliable = "RELIABLE_FOR_ENABLED_FEATURES"
    case degraded = "DEGRADED"
    case unavailable = "UNAVAILABLE"
}

public enum ReliabilityReason: String, Codable, Sendable {
    case cameraPermissionDenied, cameraUnavailable, cameraInterrupted, cameraStarting, paused, framesStale
    case modelNotLoaded, inferenceFailing, inferenceSlow, processingDelayHigh
    case lensCoveredOrDark, lowLight, motionBlur, cameraOrientation, orientationUnknown
    case trackingUnstable, segmentationUnsupported, noDepthSource, depthSensorMissing
    case collaborationOff, noPeer, peerLinkStale, noSharedAnchor, worldTrackingLimited
    case audioMuted, audioNotReady, thermalThrottling
}

public struct FeatureStatus: Equatable, Sendable {
    public var state: ReliabilityState
    public var reasons: [ReliabilityReason]
    public init(_ state: ReliabilityState, _ reasons: [ReliabilityReason] = []) { self.state = state; self.reasons = reasons }
}

public enum CameraState: String, Sendable { case running, starting, paused, interrupted, unavailable, permissionDenied }

/// Measurements only. Optional values mean "not measurable on this device/frame".
public struct ReliabilityInputs: Sendable {
    public var camera: CameraState = .starting
    public var frameAge: Double? = nil
    public var modelLoaded = false
    public var modelSupportsMasks = false
    public var recentInferenceFailures = 0
    public var inferenceLatency: Double? = nil
    public var processingDelay: Double? = nil      // capture -> decision
    public var meanLuma: Double? = nil             // 0...1
    public var lumaSpread: Double? = nil           // std-dev of luma, 0...1
    public var angularRate: Double? = nil          // rad/s
    public var pitchDeg: Double? = nil
    public var rollDeg: Double? = nil
    public var trackBirthsPerSecond: Double = 0
    public var depthSourceAvailable = false
    public var deviceHasDepthSensor = false
    public var worldTrackingNormal = false
    public var collaborationEnabled = false
    public var peerConnected = false
    public var peerLastHeardAge: Double? = nil
    public var sharedAnchorValid = false
    public var audioReady = false
    public var audioMuted = false
    public var thermalSerious = false
    public init() {}
}

public struct ReliabilityConfig: Sendable {
    public var staleFrame = 0.5, deadFrame = 1.5
    public var slowInference = 0.25, highDelay = 0.6
    public var coveredLuma = 0.035, coveredSpread = 0.02, lowLightLuma = 0.10
    public var blurAngularRate = 2.0
    public var churnBirths = 6.0
    public var peerStale = 3.0
    public init() {}
}

public struct ReliabilityReport: Equatable, Sendable {
    public var features: [Feature: FeatureStatus]
    public init(features: [Feature: FeatureStatus]) { self.features = features }
    public func status(_ f: Feature) -> FeatureStatus { features[f] ?? FeatureStatus(.unavailable) }
    public var perceptionLost: Bool { status(.semanticDetection).state == .unavailable }
}

/// Feature-specific reliability. A working detector never implies working distance, direction or navigation.
public struct PerceptionReliabilityEngine: Sendable {
    public var config: ReliabilityConfig
    public init(config: ReliabilityConfig = ReliabilityConfig()) { self.config = config }

    public func evaluate(_ i: ReliabilityInputs) -> ReliabilityReport {
        var f: [Feature: FeatureStatus] = [:]

        // --- Semantic detection
        var hard: [ReliabilityReason] = []
        var soft: [ReliabilityReason] = []
        switch i.camera {
        case .running: break
        case .starting: hard.append(.cameraStarting)
        case .paused: hard.append(.paused)
        case .interrupted: hard.append(.cameraInterrupted)
        case .unavailable: hard.append(.cameraUnavailable)
        case .permissionDenied: hard.append(.cameraPermissionDenied)
        }
        if !i.modelLoaded { hard.append(.modelNotLoaded) }
        if i.camera == .running {
            if let a = i.frameAge {
                if a > config.deadFrame { hard.append(.framesStale) } else if a > config.staleFrame { soft.append(.framesStale) }
            } else { hard.append(.framesStale) }
        }
        if i.recentInferenceFailures >= 3 { hard.append(.inferenceFailing) }
        if let luma = i.meanLuma, let spread = i.lumaSpread {
            if luma < config.coveredLuma && spread < config.coveredSpread { hard.append(.lensCoveredOrDark) }
            else if luma < config.lowLightLuma { soft.append(.lowLight) }
        }
        if let w = i.angularRate, w > config.blurAngularRate { soft.append(.motionBlur) }
        if let l = i.inferenceLatency, l > config.slowInference { soft.append(.inferenceSlow) }
        if let d = i.processingDelay, d > config.highDelay { soft.append(.processingDelayHigh) }
        if i.thermalSerious { soft.append(.thermalThrottling) }
        let semantic: FeatureStatus = !hard.isEmpty ? FeatureStatus(.unavailable, hard)
            : (!soft.isEmpty ? FeatureStatus(.degraded, soft) : FeatureStatus(.reliable))
        f[.semanticDetection] = semantic

        // --- Segmentation
        if semantic.state == .unavailable { f[.segmentation] = FeatureStatus(.unavailable, hard) }
        else if !i.modelSupportsMasks { f[.segmentation] = FeatureStatus(.unavailable, [.segmentationUnsupported]) }
        else { f[.segmentation] = semantic }

        // --- Tracking
        if semantic.state == .unavailable { f[.tracking] = FeatureStatus(.unavailable, hard) }
        else {
            var r = soft
            if i.trackBirthsPerSecond > config.churnBirths { r.append(.trackingUnstable) }
            if i.angularRate == nil { r.append(.orientationUnknown) }
            f[.tracking] = r.isEmpty ? FeatureStatus(.reliable) : FeatureStatus(.degraded, r)
        }

        // --- Direction cues (left / ahead / right)
        if semantic.state == .unavailable { f[.directionCues] = FeatureStatus(.unavailable, hard) }
        else if let p = i.pitchDeg, let r = i.rollDeg {
            f[.directionCues] = (abs(p) <= 40 && abs(r) <= 25) ? FeatureStatus(.reliable) : FeatureStatus(.unavailable, [.cameraOrientation])
        } else { f[.directionCues] = FeatureStatus(.unavailable, [.orientationUnknown]) }

        // --- Metric distance: only with a real depth / geometric source and normal world tracking.
        if semantic.state == .unavailable { f[.metricDistance] = FeatureStatus(.unavailable, hard) }
        else if !i.depthSourceAvailable { f[.metricDistance] = FeatureStatus(.unavailable, [.noDepthSource]) }
        else if !i.worldTrackingNormal { f[.metricDistance] = FeatureStatus(.unavailable, [.worldTrackingLimited]) }
        else { f[.metricDistance] = FeatureStatus(.reliable) }

        // --- Generic (class-agnostic) obstruction sensing is capability-gated on a depth sensor.
        if !i.deviceHasDepthSensor { f[.unknownObstacleSensing] = FeatureStatus(.unavailable, [.depthSensorMissing]) }
        else if !i.depthSourceAvailable || !i.worldTrackingNormal { f[.unknownObstacleSensing] = FeatureStatus(.unavailable, [.noDepthSource]) }
        else { f[.unknownObstacleSensing] = semantic.state == .unavailable ? FeatureStatus(.unavailable, hard) : FeatureStatus(.reliable) }

        // --- Peer link
        if !i.collaborationEnabled { f[.peerLink] = FeatureStatus(.unavailable, [.collaborationOff]) }
        else if !i.peerConnected { f[.peerLink] = FeatureStatus(.unavailable, [.noPeer]) }
        else if let a = i.peerLastHeardAge, a > config.peerStale { f[.peerLink] = FeatureStatus(.degraded, [.peerLinkStale]) }
        else { f[.peerLink] = FeatureStatus(.reliable) }

        // --- Shared spatial reference: a network link alone is never spatial fusion.
        let link = f[.peerLink]!
        if link.state == .unavailable { f[.sharedSpatialReference] = FeatureStatus(.unavailable, link.reasons) }
        else if !i.sharedAnchorValid { f[.sharedSpatialReference] = FeatureStatus(.unavailable, [.noSharedAnchor]) }
        else if !i.worldTrackingNormal { f[.sharedSpatialReference] = FeatureStatus(.unavailable, [.worldTrackingLimited]) }
        else { f[.sharedSpatialReference] = link.state == .degraded ? FeatureStatus(.degraded, link.reasons) : FeatureStatus(.reliable) }

        // --- Audio
        if i.audioMuted { f[.audio] = FeatureStatus(.unavailable, [.audioMuted]) }
        else { f[.audio] = i.audioReady ? FeatureStatus(.reliable) : FeatureStatus(.unavailable, [.audioNotReady]) }

        return ReliabilityReport(features: f)
    }
}
