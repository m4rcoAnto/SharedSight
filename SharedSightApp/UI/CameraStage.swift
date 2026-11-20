import SwiftUI
import SharedSightCore

/// Live camera picture with real detections drawn on it. Meant for sighted assistants, testers and
/// audiences; a VoiceOver user gets the same information from one summarising element and from speech.
struct CameraStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        let p = model.targetPresentation
        GeometryReader { geo in
            let map = AspectFillMap(viewSize: geo.size, imageAspect: s.imageAspect)
            ZStack {
                Color.black
                if let session = s.captureSession {
                    CameraPreviewView(session: session)
                } else if let image = s.preview {   // ARKit mode: frames from the engine (ARSCNView would take the session's frames away)
                    // ARKit mode has no preview layer: show the engine's down-scaled frames, same aspect-fill framing.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                if !model.paused {
                    DetectionOverlay(snapshot: s, map: map, showOutlines: model.showOutlines,
                                     targetTrackID: s.target.trackID)
                    if let box = s.target.box, s.target.trackID != nil {
                        TargetReticle(rect: map.rect(box), predicted: s.target.boxIsPredicted,
                                      uncertain: s.target.state == .ambiguous, label: reticleLabel(s.target),
                                      lockKey: s.target.trackID ?? 0)
                    }
                }

                if let message = blockingMessage(s) {
                    VStack(spacing: 10) {
                        Image(systemName: model.paused ? "pause.circle" : "eye.slash").font(.largeTitle)
                        Text(message).font(.headline).multilineTextAlignment(.center)
                    }
                    .padding(22)
                    .glass()
                    .padding(30)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in select(at: location, map: map, snapshot: s) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.tr("Camera view", "Vista della fotocamera"))
        .accessibilityValue(summary(s, p))
        .accessibilityHint(model.tr("To choose a person without sight of the screen, open Target.",
                                    "Per scegliere una persona senza guardare lo schermo, apri Bersaglio."))
    }

    private func reticleLabel(_ t: TargetStatus) -> String {
        let id = t.userID ?? ""
        if t.boxIsPredicted { return id + " · " + model.tr("PREDICTED", "PREVISTO") }
        if t.state == .ambiguous { return id + " ?" }
        return id
    }

    private func blockingMessage(_ s: AppModel.Snapshot) -> String? {
        if model.paused { return model.tr("Perception paused", "Percezione in pausa") }
        let status = s.reliability.status(.semanticDetection)
        guard status.state == .unavailable else { return nil }
        return model.perceptionStatusText
    }

    /// Sighted-operator shortcut: tap a detected person to confirm "this is the registered person".
    /// The smallest box under the finger wins, so a person in front of another can be picked.
    private func select(at location: CGPoint, map: AspectFillMap, snapshot s: AppModel.Snapshot) {
        guard model.activeProfile != nil, !model.paused else { return }
        let n = map.normalized(location)
        let hit = s.entries
            .filter { $0.track.label == "person" && $0.isCurrentEvidence }
            .filter { n.x >= $0.track.box.x && n.x <= $0.track.box.maxX && n.y >= $0.track.box.y && n.y <= $0.track.box.maxY }
            .min { $0.track.box.area < $1.track.box.area }
        guard let hit, hit.id != s.target.trackID || !s.target.isLocked else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.selectTarget(trackID: hit.id) }
    }

    private func summary(_ s: AppModel.Snapshot, _ p: TargetPresentation) -> String {
        let people = s.entries.filter { $0.track.label == "person" && $0.isCurrentEvidence }.count
        let count = model.tr("\(people) people in view.", "\(people) persone inquadrate.")
        return model.trackingOn ? "\(p.title). \(p.detail). \(count)" : count
    }
}

/// Everything that is *not* the target: other people (neutral, with their temporary track tag) and
/// obstacles (subtle, class label only). Drawn from real tracks; dashed = not observed in this frame.
struct DetectionOverlay: View {
    let snapshot: AppModel.Snapshot
    let map: AspectFillMap
    let showOutlines: Bool
    let targetTrackID: Int?

    var body: some View {
        Canvas { ctx, _ in
            for e in snapshot.entries where e.id != targetTrackID {
                let rect = map.rect(e.track.box)
                let observed = e.isCurrentEvidence
                let isPerson = e.track.label == "person"
                let opacity = (isPerson ? 0.75 : 0.4) * (observed ? 1 : 0.6)
                let color = Color.white.opacity(opacity)
                let style = StrokeStyle(lineWidth: isPerson ? 1.5 : 1, dash: observed ? [] : [5, 4])

                if showOutlines, observed, let mask = snapshot.masks[e.id], mask.outline.count >= 3 {
                    var path = Path()
                    path.addLines(mask.outline.map { map.point(Double($0.x), Double($0.y)) })
                    path.closeSubpath()
                    ctx.fill(path, with: .color(Color.white.opacity(0.10)))
                    ctx.stroke(path, with: .color(color), lineWidth: 1)
                } else {
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 8, style: .continuous), with: .color(color), style: style)
                }
                let text = isPerson ? e.track.trackTag : e.track.label
                ctx.draw(Text(text).font(.caption2.weight(.semibold).monospacedDigit()).foregroundColor(color),
                         at: CGPoint(x: rect.minX + 4, y: max(rect.minY - 9, 8)), anchor: .leading)
            }
            // The target's outline, when outlines are on and one exists for this frame.
            if showOutlines, let id = targetTrackID, let mask = snapshot.masks[id], mask.outline.count >= 3,
               !snapshot.target.boxIsPredicted {
                var path = Path()
                path.addLines(mask.outline.map { map.point(Double($0.x), Double($0.y)) })
                path.closeSubpath()
                ctx.fill(path, with: .color(Theme.accent.opacity(0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The followed person: accent corner brackets when observed; dashed amber when the position is only
/// predicted or the identity is uncertain. Moves smoothly between updates and pulses once on lock.
struct TargetReticle: View {
    let rect: CGRect
    let predicted: Bool
    let uncertain: Bool
    let label: String
    let lockKey: Int          // the track being followed; a change means a new lock
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let soft = predicted || uncertain
        let color = soft ? Theme.caution : Theme.accent
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(soft ? 0.95 : 0.3), style: StrokeStyle(lineWidth: soft ? 2 : 1, dash: soft ? [8, 6] : []))
            if !soft {
                CornerBrackets().stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            Text(label)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color, in: Capsule())
                .fixedSize()
                .offset(y: -26)
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .scaleEffect(pulse ? 1.14 : 1)
        .position(x: rect.midX, y: rect.midY)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: rect)
        .animation(.easeInOut(duration: 0.2), value: soft)
        .onAppear { runPulse() }
        .onChange(of: lockKey) { _, _ in runPulse() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension TargetReticle {
    /// One short "snap" when a lock is made: starts slightly large, springs to size.
    func runPulse() {
        guard !reduceMotion else { return }
        pulse = true
        DispatchQueue.main.async { withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { pulse = false } }
    }
}

private struct CornerBrackets: Shape {
    func path(in r: CGRect) -> Path {
        let l = max(min(r.width, r.height) * 0.2, 10), c: CGFloat = 12
        var p = Path()
        // top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        // top-right
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        // bottom-left
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}
