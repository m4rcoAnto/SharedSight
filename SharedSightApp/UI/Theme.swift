import ARKit
import SceneKit
import SwiftUI
import AVFoundation
import SharedSightCore

/// One place for the visual language: near-black, white type, a single accent, translucent surfaces.
/// State is always written in words as well; colour only repeats it.
enum Theme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)            // electric blue: the only accent
    static let background = Color(red: 0.043, green: 0.047, blue: 0.055)    // deep charcoal
    static let caution = Color(red: 1.0, green: 0.74, blue: 0.28)           // status only: uncertain / predicted
    static let alert = Color(red: 1.0, green: 0.36, blue: 0.33)             // status only: lost / unavailable
    static let radius: CGFloat = 26
    static let innerRadius: CGFloat = 16

    static func color(_ tone: TargetPresentation.Tone) -> Color {
        switch tone {
        case .neutral: return .white
        case .accent: return accent
        case .caution: return caution
        case .alert: return alert
        }
    }
}

/// Translucent panel. With Increase Contrast it becomes opaque black with a white outline.
private struct Glass: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if contrast == .increased {
            content.background(Color.black, in: shape).overlay(shape.strokeBorder(Color.white, lineWidth: 2))
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func glass(radius: CGFloat = Theme.radius) -> some View { modifier(Glass(radius: radius)) }
}

/// The single prominent action on a screen.
struct PrimaryButton: View {
    enum Kind { case accent, quiet }
    let title: String
    let systemImage: String
    var kind: Kind = .accent
    var hint: String?
    let action: () -> Void
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 54

    init(title: String, systemImage: String, kind: Kind = .accent, hint: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.kind = kind; self.hint = hint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 16)
                .foregroundStyle(.white)
                .background(kind == .accent ? Theme.accent : Color.white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint ?? "")
    }
}

/// Round icon used for secondary controls. 52 pt, above the 44 pt minimum; grows with Dynamic Type.
struct CircleIcon: View {
    let systemImage: String
    var active = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 52
    @Environment(\.colorSchemeContrast) private var contrast

    init(systemImage: String, active: Bool = false) { self.systemImage = systemImage; self.active = active }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active ? Color.black : Color.white)
            .background(active ? Color.white : Color.white.opacity(contrast == .increased ? 0.3 : 0.14), in: Circle())
            .contentShape(Circle())
    }
}

struct CircleButton: View {
    let systemImage: String
    let label: String
    var value: String?
    var hint: String?
    var active = false
    var isToggle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { CircleIcon(systemImage: systemImage, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(isToggle ? .isToggle : [])
    }
}

/// Small capsule in the top bar: icon + one or two words.
struct StatusChip: View {
    let text: String
    let systemImage: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(radius: 14)
    }
}

// MARK: - Camera preview and image-to-view mapping

/// Live camera picture in ARKit mode: ARKit's own view of the running session (GPU, full frame rate). Before this
/// the screen showed frames re-encoded by the detector, a few per second, which looked frozen.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session                      // same session: no second camera, the engine keeps its delegate
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.rendersMotionBlur = false
        view.isUserInteractionEnabled = false       // taps go to the overlay (target selection)
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
    }
}

/// Live camera picture straight from the capture session (GPU path, no per-frame work in SwiftUI).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        // The app is portrait-only; the connection appears once the session has been configured.
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}

/// Maps upright image-normalised coordinates (what detections use) to view points for an aspect-fill picture,
/// which is how both the preview layer and the fallback image are shown. Also maps a tap back to the image.
struct AspectFillMap: Equatable {
    let origin: CGPoint
    let size: CGSize

    init(viewSize: CGSize, imageAspect: Double) {
        let aspect = CGFloat(max(imageAspect, 0.01))
        let scale = max(viewSize.width / aspect, viewSize.height)
        size = CGSize(width: aspect * scale, height: scale)
        origin = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
    }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) * size.width, y: origin.y + CGFloat(y) * size.height)
    }

    func rect(_ b: NormRect) -> CGRect {
        CGRect(x: origin.x + CGFloat(b.x) * size.width, y: origin.y + CGFloat(b.y) * size.height,
               width: CGFloat(b.w) * size.width, height: CGFloat(b.h) * size.height)
    }

    func normalized(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double((p.x - origin.x) / max(size.width, 1)), Double((p.y - origin.y) / max(size.height, 1)))
    }
}
