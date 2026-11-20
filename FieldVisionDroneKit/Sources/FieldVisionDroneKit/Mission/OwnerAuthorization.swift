import Foundation
import LocalAuthentication

public enum OwnerAuthorizationFailure: String, Sendable, Codable {
    case cancelled
    case failed
    /// No passcode / biometry on this device, so the owner cannot be authenticated.
    case unavailable
    case lockedOut
    /// The host app has Face ID but no `NSFaceIDUsageDescription` in its Info.plist.
    /// The kit refuses instead of letting the system terminate the app.
    case missingUsageDescription
}

public enum OwnerAuthorizationResult: Sendable, Equatable {
    case authorized
    case denied(OwnerAuthorizationFailure)
}

/// Confirms that the person activating Drone Companion is the owner of this device.
///
/// This is *not* target identification. Face ID proves who is holding the phone; it gives no facial
/// data to any camera or drone. Who the drone follows is decided only by the host's registered-target
/// pipeline, reported through `DroneTargetObservation.isIdentityVerified`.
public protocol OwnerAuthorizing: Sendable {
    func authorizeOwner(reason: String) async -> OwnerAuthorizationResult
}

/// Face ID / Touch ID with the system fallback (device passcode), through `LocalAuthentication`.
public struct LocalDeviceOwnerAuthorizer: OwnerAuthorizing {
    public var allowsPasscodeFallback: Bool

    public init(allowsPasscodeFallback: Bool = true) {
        self.allowsPasscodeFallback = allowsPasscodeFallback
    }

    public func authorizeOwner(reason: String) async -> OwnerAuthorizationResult {
        let context = LAContext()
        let policy: LAPolicy = allowsPasscodeFallback ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            return .denied(Self.failure(for: evaluationError))
        }
        if context.biometryType == .faceID,
           Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") == nil {
            return .denied(.missingUsageDescription)
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? .authorized : .denied(Self.failure(for: error as NSError?)))
            }
        }
    }

    static func failure(for error: NSError?) -> OwnerAuthorizationFailure {
        guard let error, error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) else {
            return .failed
        }
        switch code {
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .biometryLockout: return .lockedOut
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet: return .unavailable
        default: return .failed
        }
    }
}

/// Approves without asking. For unit tests, previews, and demos on a device with no passcode.
/// It is never the default: a host has to choose it explicitly.
public struct PreapprovedOwnerAuthorizer: OwnerAuthorizing {
    public init() {}
    public func authorizeOwner(reason: String) async -> OwnerAuthorizationResult { .authorized }
}
