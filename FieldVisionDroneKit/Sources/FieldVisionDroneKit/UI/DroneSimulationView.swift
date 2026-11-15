import SwiftUI

/// Visual simulation of the mission: a drone glyph that powers up, rises, leans into follow
/// corrections, returns and lands, plus a strip showing where the target is in the camera image.
/// It is always labelled SIMULATION, and TEST DATA while the observations are synthetic.
/// VoiceOver reads it as a single element: state, then what the simulated drone is doing.
@MainActor
public struct DroneSimulationView: View {
    @ObservedObject private var controller: DroneCompanionController
    private let language: DroneKitLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(controller: DroneCompanionController, language: DroneKitLanguage = .english) {
        _controller = ObservedObject(wrappedValue: controller)
        self.language = language
    }

    public var body: some View {
        let strings = DroneKitStrings(language: language)
        let tone = DroneKitTheme.tone(for: controller.state)
        let stateTitle = strings.stateTitle(controller.state)
        let guidanceText = strings.guidanceText(controller.guidance)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: DroneKitTheme.symbol(for: controller.state))
                    .foregroundStyle(tone)
                Text(stateTitle)
                    .font(.footnote.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(tone)
                Spacer(minLength: 4)
                if controller.isUsingSyntheticData {
                    DroneBadge(text: strings.testData, color: DroneKitTheme.caution)
                }
                DroneBadge(text: strings.simulation, color: Color.white.opacity(0.65))
            }

            DroneStage(telemetry: controller.telemetry, tone: tone, animate: !reduceMotion)
                .frame(height: 170)

            if showsProgress {
                ProgressView(value: controller.telemetry.phaseProgress)
                    .tint(tone)
            }

            DroneCameraStrip(centerX: stripCenter, directlyObserved: controller.latestObservation?.isDirectlyObserved ?? false,
                             guidance: controller.guidance, deadZone: controller.configuration.deadZoneX)

            Text(guidanceText)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: controller.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.simulationLabel)
        .accessibilityValue("\(stateTitle). \(guidanceText)")
    }

    private var showsProgress: Bool {
        switch controller.telemetry.phase {
        case .preparing, .returning, .landing: return true
        default: return false
        }
    }

    /// The target dot is drawn only while the mission is reading observations and a position is known.
    private var stripCenter: Double? {
        guard controller.state.acceptsObservations, controller.observationQuality != .stale,
              controller.observationQuality != .noData else { return nil }
        return controller.latestObservation?.normalizedCenterX
    }
}

struct DroneBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .fixedSize()
    }
}

/// Ground line, landing pad, shadow and the drone at its simulated height and lean.
struct DroneStage: View {
    let telemetry: DroneVehicleTelemetry
    let tone: Color
    let animate: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let altitude = CGFloat(min(max(telemetry.altitude, 0), 1))
            let correction = CGFloat(min(max(telemetry.correction, -1), 1))
            let padY = height - 16
            let groundY = padY - 30
            let hoverY: CGFloat = 46
            let droneY = groundY - (groundY - hoverY) * altitude
            let droneX = width / 2 + correction * width * 0.22
            let airborne = altitude > 0.02

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: max(width - 32, 0), height: 1)
                    .position(x: width / 2, y: padY)
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 64, height: 5)
                    .position(x: width / 2, y: padY)
                Ellipse()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 66 - 30 * altitude, height: 8)
                    .position(x: droneX, y: padY)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(animate && airborne))) { context in
                    DroneGlyph(tint: airborne ? tone : Color.white.opacity(0.45),
                               rotorAngle: airborne ? context.date.timeIntervalSinceReferenceDate * 16 : 0.6)
                }
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(Double(correction) * 12))
                .position(x: droneX, y: droneY)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Top-down quadcopter drawn with paths: four arms, four rotors with one blade each, a body.
struct DroneGlyph: View {
    let tint: Color
    let rotorAngle: Double

    var body: some View {
        Canvas { context, size in
            let cx = Double(size.width) / 2
            let cy = Double(size.height) / 2
            let arm = Double(min(size.width, size.height)) * 0.33
            let radius = arm * 0.44
            for index in 0..<4 {
                let direction = Double.pi / 4 + Double(index) * Double.pi / 2
                let px = cx + cos(direction) * arm
                let py = cy + sin(direction) * arm

                var armPath = Path()
                armPath.move(to: CGPoint(x: cx, y: cy))
                armPath.addLine(to: CGPoint(x: px, y: py))
                context.stroke(armPath, with: .color(tint.opacity(0.9)), lineWidth: 3)

                let rotor = CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rotor), with: .color(tint.opacity(0.5)), lineWidth: 1.5)

                let blade = rotorAngle * (index % 2 == 0 ? 1.0 : -1.0) + Double(index)
                var bladePath = Path()
                bladePath.move(to: CGPoint(x: px - cos(blade) * radius * 0.85, y: py - sin(blade) * radius * 0.85))
                bladePath.addLine(to: CGPoint(x: px + cos(blade) * radius * 0.85, y: py + sin(blade) * radius * 0.85))
                context.stroke(bladePath, with: .color(tint), lineWidth: 2)
            }
            let half = arm * 0.3
            let body = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
            context.fill(Path(roundedRect: body, cornerRadius: CGFloat(half * 0.5)), with: .color(tint))
        }
    }
}

/// What the camera sees, reduced to one axis: the dead zone in the middle, the target as a dot,
/// and the correction arrows. A dashed dot means the position is predicted, not observed.
struct DroneCameraStrip: View {
    let centerX: Double?
    let directlyObserved: Bool
    let guidance: DroneFollowGuidance
    let deadZone: Double

    var body: some View {
        HStack(spacing: 10) {
            arrow("chevron.left", lit: guidance.isActive && guidance.horizontal == .left)
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                ZStack {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(DroneKitTheme.accent.opacity(0.22))
                        .frame(width: max(width * CGFloat(min(max(deadZone, 0), 1)), 8))
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: height * 0.6)
                    if let centerX {
                        Circle()
                            .fill(directlyObserved ? Color.white : Color.clear)
                            .overlay(Circle().strokeBorder(directlyObserved ? Color.clear : DroneKitTheme.caution,
                                                           style: StrokeStyle(lineWidth: 2, dash: [3, 3])))
                            .frame(width: 16, height: 16)
                            .position(x: width * CGFloat(min(max(centerX, 0), 1)), y: height / 2)
                    }
                }
            }
            .frame(height: 28)
            arrow("chevron.right", lit: guidance.isActive && guidance.horizontal == .right)
        }
        .animation(.easeOut(duration: 0.12), value: centerX)
        .animation(.easeInOut(duration: 0.18), value: guidance.horizontal)
        .accessibilityHidden(true)
    }

    private func arrow(_ name: String, lit: Bool) -> some View {
        Image(systemName: name)
            .font(.headline.weight(.bold))
            .foregroundStyle(lit ? DroneKitTheme.accent : Color.white.opacity(0.25))
            .scaleEffect(lit ? 1.2 : 1)
    }
}
