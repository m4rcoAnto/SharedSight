import SwiftUI
import Combine

/// Owner authorization for the demo: the real system prompt, or an explicit skip for devices and
/// previews without a passcode. The skip exists only in the demo harness.
final class DemoAuthorizationSwitch: OwnerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var requiresDeviceOwner: Bool

    init(requiresDeviceOwner: Bool) {
        self.requiresDeviceOwner = requiresDeviceOwner
    }

    func set(requiresDeviceOwner value: Bool) {
        lock.withLock { requiresDeviceOwner = value }
    }

    func authorizeOwner(reason: String) async -> OwnerAuthorizationResult {
        let required = lock.withLock { requiresDeviceOwner }
        guard required else { return .authorized }
        return await LocalDeviceOwnerAuthorizer().authorizeOwner(reason: reason)
    }
}

/// Everything the standalone demo owns: a controller with the simulated vehicle and a synthetic feed.
@MainActor
final class DroneDemoSession: ObservableObject {
    let controller: DroneCompanionController
    let feed: SyntheticTargetFeed
    private let authorization: DemoAuthorizationSwitch

    @Published var requiresOwnerAuthentication: Bool {
        didSet { authorization.set(requiresDeviceOwner: requiresOwnerAuthentication) }
    }

    init(requiresOwnerAuthentication: Bool) {
        let authorization = DemoAuthorizationSwitch(requiresDeviceOwner: requiresOwnerAuthentication)
        self.authorization = authorization
        _requiresOwnerAuthentication = Published(initialValue: requiresOwnerAuthentication)
        controller = DroneCompanionController(authorizer: authorization)
        feed = SyntheticTargetFeed()
    }
}

/// Standalone demonstration harness. It runs without SharedSight: the target observations come from
/// `SyntheticTargetFeed` and are labelled TEST DATA on screen. The mission logic, authorization and
/// simulator are the same code the host app uses.
@MainActor
public struct DroneCompanionDemoView: View {
    @StateObject private var session: DroneDemoSession
    private let language: DroneKitLanguage

    /// - Parameter requiresOwnerAuthentication: start with the Face ID / passcode prompt on (default)
    ///   or skipped. It can be switched on screen.
    public init(requiresOwnerAuthentication: Bool = true, language: DroneKitLanguage = .english) {
        _session = StateObject(wrappedValue: DroneDemoSession(requiresOwnerAuthentication: requiresOwnerAuthentication))
        self.language = language
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FieldVision Drone Companion")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Standalone demo. No drone is connected and none is flying. Target data below is synthetic test data.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                DroneCompanionPanel(controller: session.controller, targetID: session.feed.targetID, language: language)

                DemoFeedControls(feed: session.feed)

                Toggle("Ask for Face ID or passcode", isOn: $session.requiresOwnerAuthentication)
                    .padding(14)
                    .background(DroneKitTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                DemoEventLog(controller: session.controller, language: language)
            }
            .padding(18)
        }
        .background(DroneKitTheme.background.ignoresSafeArea())
        .foregroundStyle(Color.white)
        .tint(DroneKitTheme.accent)
        .onAppear { session.feed.start(feeding: session.controller) }
        .onDisappear { session.feed.stop() }
    }
}

/// Manual and scripted control of the synthetic target.
private struct DemoFeedControls: View {
    @ObservedObject var feed: SyntheticTargetFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Test target").font(.headline)
                Spacer()
                DroneBadge(text: "TEST DATA", color: DroneKitTheme.caution)
            }
            Picker("Scenario", selection: $feed.script) {
                Text("Manual").tag(SyntheticTargetFeed.Script.manual)
                Text("Walking").tag(SyntheticTargetFeed.Script.walking)
                Text("Occlusion").tag(SyntheticTargetFeed.Script.occlusion)
                Text("Crossing").tag(SyntheticTargetFeed.Script.crossing)
                Text("Leaves").tag(SyntheticTargetFeed.Script.leaves)
            }
            .pickerStyle(.menu)

            let manual = feed.script == .manual
            VStack(alignment: .leading, spacing: 4) {
                Text("Position in the image").font(.footnote).foregroundStyle(Color.white.opacity(0.65))
                Slider(value: $feed.centerX, in: 0...1) { Text("Position in the image") }
                    .accessibilityValue("\(Int((feed.centerX * 100).rounded())) percent from the left")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Confidence").font(.footnote).foregroundStyle(Color.white.opacity(0.65))
                Slider(value: $feed.confidence, in: 0...1) { Text("Confidence") }
                    .accessibilityValue("\(Int((feed.confidence * 100).rounded())) percent")
            }
            Toggle("Directly observed", isOn: $feed.isDirectlyObserved).disabled(!manual)
            Toggle("Identity verified", isOn: $feed.isIdentityVerified).disabled(!manual)
            Toggle("Identity ambiguous", isOn: $feed.isIdentityAmbiguous).disabled(!manual)
            if !manual {
                Text("The scenario drives position and the three switches. Choose Manual to set them yourself.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(DroneKitTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The mission events exactly as a host app would receive them, with the suggested announcement.
private struct DemoEventLog: View {
    @ObservedObject var controller: DroneCompanionController
    let language: DroneKitLanguage

    var body: some View {
        let events = Array(controller.recentEvents.suffix(8).reversed())
        VStack(alignment: .leading, spacing: 8) {
            Text("Mission events").font(.headline)
            if events.isEmpty {
                Text("None yet").font(.footnote).foregroundStyle(Color.white.opacity(0.65))
            }
            ForEach(Array(events.enumerated()), id: \.offset) { item in
                let event = item.element
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.name).font(.caption.monospaced()).foregroundStyle(DroneKitTheme.accent)
                    Text(event.announcement(language, simulated: controller.isSimulation)).font(.footnote)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DroneKitTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct DroneCompanionDemoView_Previews: PreviewProvider {
    static var previews: some View {
        DroneCompanionDemoView(requiresOwnerAuthentication: false)
            .preferredColorScheme(.dark)
    }
}
