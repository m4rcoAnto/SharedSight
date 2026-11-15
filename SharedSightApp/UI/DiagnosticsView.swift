import SwiftUI
import SharedSightCore

/// Engineer-facing screen, deliberately separate from the user interface.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    static func tag(_ t: TrackSnapshot) -> String { "\(t.label.uppercased())-\(String(format: "%03d", t.id))" }

    var body: some View {
        let s = model.snapshot
        NavigationStack {
            List {
                Section("Camera — \(s.providerName) — \(s.cameraState.rawValue)") {
                    if let image = s.preview {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .overlay(OverlayCanvas(snapshot: s))
                            .accessibilityHidden(true)
                    } else {
                        Text("No preview frame")
                    }
                }
                Section("Reliability (per feature)") {
                    ForEach(Feature.allCases, id: \.self) { f in
                        let st = s.reliability.status(f)
                        row(f.rawValue, st.state.rawValue + (st.reasons.isEmpty ? "" : " — " + st.reasons.map(\.rawValue).joined(separator: ", ")))
                    }
                    row("genericObstruction", s.genericObstruction.rawValue)
                }
                Section("Tracks (\(s.entries.count))") {
                    ForEach(s.entries) { e in
                        let a = s.relevance[e.id]
                        let dist = a?.distance.map { String(format: " %.1fm±%.1f", $0.meters, $0.sigma) } ?? ""
                        row(Self.tag(e.track) + (e.track.identityAmbiguous ? " (identity ambiguous)" : ""),
                            "\(e.state.rawValue) \(a?.sector?.rawValue ?? "no-direction")\(dist) conf \(String(format: "%.2f", e.track.confidence)) rel \(String(format: "%.2f", a?.score ?? 0)) \(s.masks[e.id] != nil ? "INSTANCE_MASK" : "BOUNDING_BOX")")
                    }
                }
                Section("Collaboration — \(s.linkState.rawValue) — peers: \(s.peerCount) — anchor: \(s.anchorReady ? "VALID" : "NONE")") {
                    ForEach(s.peers) { p in
                        let where_ = p.distance.map { String(format: " %.1fm", $0.meters) } ?? ""
                        row("\(p.observation.label) from \(p.observation.cameraID)",
                            "\(p.status.rawValue) \(p.sector?.rawValue ?? "")\(where_) age \(String(format: "%.1fs", p.captureAge)) \(p.unverifiedReason ?? "")")
                    }
                }
                Section("Out of sight (\(s.hidden.count)) — hub: \(s.serverStatus) — phones on hub: \(s.hubDevices)") {
                    ForEach(s.hidden) { h in
                        let source: String = {
                            if case let .otherDevice(count) = h.source { return "SEEN_BY_OTHER_DEVICE x\(count)" }
                            return "ESTIMATE (seen by nobody)"
                        }()
                        row("\(h.label) \(h.occluder.map { "behind " + $0.rawValue } ?? "outside view")",
                            "\(source) \(h.sector?.rawValue ?? "no-direction") \(String(format: "%.1fm±%.1f", h.distance.meters, h.distance.sigma)) age \(String(format: "%.1fs", h.age))")
                    }
                    row("Hub round trip", s.hubRoundTripMs.map { String(format: "%.0f ms", $0) } ?? "not connected")
                }
                Section("Target — \(s.target.state.rawValue)\(s.trackingArmed ? "" : " (not started)")") {
                    let t = s.target, g = s.guidance
                    row("Registered user", t.userID ?? "none")
                    row("Track", t.trackID.map { String(format: "TRACK-%03d", $0) } ?? "none")
                    row("Box", t.box == nil ? "none" : (t.boxIsPredicted ? "PREDICTED (not observed)" : "OBSERVED"))
                    row("Reason", t.reason?.rawValue ?? "none")
                    row("Verified by", t.verifiedBy?.rawValue ?? "none")
                    row("Detection / association confidence (heuristic)", String(format: "%.2f / %.2f", t.detectionConfidence, t.associationConfidence))
                    row("targetVisible", g.targetVisible ? "true" : "false")
                    row("targetCenterX / Y", g.targetCenterX.map { x in String(format: "%.3f / %.3f", x, g.targetCenterY ?? 0) } ?? "none")
                    row("horizontalOffset / verticalOffset (smoothed)", String(format: "%+.3f / %+.3f", g.horizontalOffset, g.verticalOffset))
                    row("boundingBoxArea / relative to lock", g.boundingBoxArea.map { a in String(format: "%.4f / %@", a, g.relativeSize.map { String(format: "%.2f", $0) } ?? "n/a") } ?? "none")
                    row("Follow cue (SIMULATED, no vehicle)", g.hold.map { "HOLD: \($0.rawValue)" } ?? "\(g.horizontal.rawValue) / \(g.vertical.rawValue) / size \(g.size.rawValue)")
                    row("Marker read latency", String(format: "%.1f ms", s.metrics.markerMs))
                    row("Wall distance", s.wallSource)
                    row("Marker read error", s.markerError ?? "none")
                }
                Section("Target events (stored locally, \(model.trackingEvents.count))") {
                    ForEach(model.trackingEvents.suffix(25).reversed()) { e in
                        row("\(e.date.formatted(date: .omitted, time: .standard))  \(e.kind.rawValue)",
                            "\(e.userID ?? "-") \(e.trackID.map { String(format: "TRACK-%03d", $0) } ?? "-") \(e.detail ?? "")")
                    }
                }
                Section("Performance (measured on this device, this session)") {
                    let m = s.metrics
                    row("Camera frame rate", String(format: "%.1f fps", m.cameraFPS))
                    row("Processed / tracking rate", String(format: "%.1f Hz", m.processedFPS))
                    row("Detection latency", String(format: "%.1f ms", m.detectionMs))
                    row("Segmentation latency", String(format: "%.1f ms", m.segmentationMs))
                    row("Capture to decision", String(format: "%.0f ms", m.decisionDelayMs))
                    row("Capture to speech start", m.speechDelayMs.map { String(format: "%.0f ms", $0) } ?? "not measured yet")
                    row("Peer observation age", m.peerObservationAgeMs.map { String(format: "%.0f ms", $0) } ?? "no peer data")
                    row("Dropped / skipped frames", "\(m.droppedFrames) / \(m.skippedFrames)")
                    row("Memory", String(format: "%.0f MB", m.memoryMB))
                    row("Thermal state", m.thermal)
                }
                Section("Model") {
                    row("Model", s.modelID)
                    row("Load error", s.modelError ?? "none")
                    row("Last inference error", s.lastInferenceError ?? "none")
                    row("Speech ready", s.audioReady ? "yes" : "no")
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { model.diagnosticsVisible = true }
        .onDisappear { model.diagnosticsVisible = false }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(value).font(.footnote.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}

/// Draws real detections only: mask outline when one exists, otherwise the bounding box; dashed = not currently observed.
struct OverlayCanvas: View {
    let snapshot: SharedSightPerceptionEngine.Snapshot
    var body: some View {
        Canvas { ctx, size in
            for e in snapshot.entries {
                let b = e.track.box
                let rect = CGRect(x: b.x * size.width, y: b.y * size.height, width: b.w * size.width, height: b.h * size.height)
                let observed = e.isCurrentEvidence
                let color: Color = observed ? .yellow : .gray
                if observed, let mask = snapshot.masks[e.id], mask.outline.count >= 3 {
                    var path = Path()
                    path.addLines(mask.outline.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                    path.closeSubpath()
                    ctx.fill(path, with: .color(color.opacity(0.25)))
                    ctx.stroke(path, with: .color(color), lineWidth: 2)
                } else {
                    ctx.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 2, dash: observed ? [] : [6, 4]))
                }
                ctx.draw(Text(DiagnosticsView.tag(e.track) + " " + e.state.rawValue).font(.caption2.bold()).foregroundColor(color),
                         at: CGPoint(x: rect.minX + 2, y: max(rect.minY - 8, 6)), anchor: .leading)
            }
        }
    }
}
