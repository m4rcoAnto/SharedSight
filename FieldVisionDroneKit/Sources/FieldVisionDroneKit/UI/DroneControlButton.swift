import SwiftUI

/// The one button of Drone Companion.
///
/// First activation: authorize the owner, prepare, search for the registered person, follow once locked.
/// Second activation: stop guidance at once, then simulated return and landing. Completion is shown
/// only when the simulator reports it. Disabled while authorizing, returning and landing, so repeated
/// taps cannot start or end a mission twice.
@MainActor
public struct DroneControlButton: View {
    @ObservedObject private var controller: DroneCompanionController
    private let targetID: UUID?
    private let language: DroneKitLanguage
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 58

    /// - Parameter targetID: persistent ID of the registered person (SharedSight: `activeProfileID`).
    ///   With nil the button is disabled: the kit never chooses a person by itself.
    public init(controller: DroneCompanionController, targetID: UUID?, language: DroneKitLanguage = .english) {
        _controller = ObservedObject(wrappedValue: controller)
        self.targetID = targetID
        self.language = language
    }

    public var body: some View {
        let strings = DroneKitStrings(language: language)
        let content = strings.primaryButton(state: controller.state, hasTarget: targetID != nil)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {
            controller.primaryAction(targetID: targetID)
        } label: {
            HStack(spacing: 12) {
                if content.busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: content.symbol).font(.headline)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.headline)
                    Text(content.subtitle).font(.footnote).opacity(0.8)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .foregroundStyle(Color.white)
            .background(content.prominent ? DroneKitTheme.accent : Color.white.opacity(0.14), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!content.enabled)
        .opacity(content.enabled || content.busy ? 1 : 0.55)
        .accessibilityLabel(content.title)
        .accessibilityValue(content.subtitle)
        .accessibilityHint(content.hint)
    }
}

/// Separate emergency action: stops follow guidance immediately without ending the mission.
/// After a stop it turns into "Resume Following", which searches for the registered person again.
@MainActor
public struct DroneStopFollowingButton: View {
    @ObservedObject private var controller: DroneCompanionController
    private let language: DroneKitLanguage
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 50

    public init(controller: DroneCompanionController, language: DroneKitLanguage = .english) {
        _controller = ObservedObject(wrappedValue: controller)
        self.language = language
    }

    public var body: some View {
        let strings = DroneKitStrings(language: language)
        let resumable = controller.canResumeFollowing
        let enabled = resumable || controller.canStopFollowing
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {
            if resumable { controller.resumeFollowing() } else { controller.stopFollowing() }
        } label: {
            Label(resumable ? strings.resumeFollowing : strings.stopFollowing,
                  systemImage: resumable ? "play.fill" : "hand.raised.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .padding(.horizontal, 16)
                .foregroundStyle(resumable ? Color.white : DroneKitTheme.alert)
                .background(Color.white.opacity(0.08), in: shape)
                .overlay(shape.strokeBorder(resumable ? Color.white.opacity(0.3) : DroneKitTheme.alert.opacity(0.7), lineWidth: 1.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityHint(resumable ? strings.resumeFollowingHint : strings.stopFollowingHint)
    }
}
