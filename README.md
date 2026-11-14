# Shared Sight — Many Eyes. Fewer Blind Spots.

FieldVision · The Big Hack 2026 · Mare Group Challenge 03

Native iOS app for blind and low-vision users. Each iPhone detects and tracks people and objects with its own
camera and speaks relevant ones. Two consenting phones can exchange observations; a peer's observation is
turned into a spoken warning only when both phones share a validated spatial reference.

**Experimental awareness aid. Not a navigation device. It never replaces a white cane, a guide dog or
orientation-and-mobility practice, and it never says that a path is clear.**

## Layout

| Path | What |
|---|---|
| `SharedSightCore/` | Swift package, Foundation only: tracker, memory, relevance, reliability, alert decision, phrases, YOLO/mask decoding, collaboration + spatial alignment. Unit-tested. |
| `SharedSightApp/Perception` | `CameraFrameProvider` (AVFoundation), `NeuralObjectDetector` + `ObstacleSegmentationEngine` (Core ML), `CameraMotionEstimator` (CoreMotion), `SharedSightPerceptionEngine` (orchestrator) |
| `SharedSightApp/Audio` | `AudioFeedbackEngine` (AVSpeechSynthesizer, haptics) |
| `SharedSightApp/Collaboration` | `MultipeerTransport` (encrypted local P2P), `ARFrameProvider` (ARKit pose, floor raycast, shared marker) |
| `SharedSightApp/UI` | Accessible SwiftUI app + separate Diagnostics screen |
| `SharedSightApp/Resources` | `SharedSightDetector.mlpackage` (YOLO26n-seg, real weights), `AnchorMarker.png` |
| `Docs/AnchorMarker.png` | Marker to print for the shared spatial reference |
| `RESEARCH.md` · `STATUS.md` | Literature behind each module · implementation / test status and handoff notes |

## Build

1. Xcode 16 or newer. Open `SharedSight.xcodeproj` (if it fails to open: `brew install xcodegen && xcodegen`).
2. Target *SharedSight* → Signing & Capabilities → pick your Team (bundle id `com.fieldvision.sharedsight`, change if taken).
3. Select a real iPhone (iOS 17+) and Run. The camera does not exist in the Simulator: there the app reports
   "Perception unavailable: camera unavailable", which is the intended behaviour.
4. For the demo use the **Release** configuration (Product → Scheme → Edit Scheme → Run → Release): Debug builds
   run the decoding loops unoptimised.

Checks from Terminal: `./Scripts/verify.sh` (unit tests on the Mac + simulator compile check; logs in `Logs/`).

## Two-phone demo (controlled, supervised setting only)

1. Print `Docs/AnchorMarker.png`, measure its printed width, enter it in Settings on both phones, lay it flat on the floor.
2. Both phones: start the app (Phase A — each speaks its own detections).
3. Both phones: *Collaboration → Share* with the same session code (Phase B). Spatial mode switches on automatically.
4. Point each phone once at the marker until "Shared spatial reference ready" is spoken.
5. Put a chair where only phone A sees it (Phase C/D). Phone B says "Obstacle reported by another device: chair, …" only
   if the chair's floor position could be measured and the marker fix is valid (Phase E). Otherwise Diagnostics shows
   `SHARED_LOCATION_UNVERIFIED` and nothing directional is spoken.
6. Quit A or turn its collaboration off: B says the connection was lost, shared observations show `SHARED_OBSERVATION_EXPIRED`,
   B keeps working alone (Phase F).
7. Cover B's camera: "Camera perception unavailable. The camera may be covered, or it is too dark." (Phase G).

## Licence note

The bundled detector is Ultralytics YOLO26n-seg (AGPL-3.0 weights and export code). Fine for a hackathon prototype; a
closed-source product needs an Ultralytics licence or an Apache-licensed detector (RF-DETR, D-FINE) behind the same
`NeuralObjectDetector` interface. The model was converted with `ModelBuild/` weights → Core ML (FP16, 640×640, NMS-free head).
