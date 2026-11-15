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
| `SharedSightCore/` | Swift package, Foundation only: tracker, memory, relevance, reliability, alert decision, phrases, YOLO/mask decoding, collaboration + spatial alignment, registered-person registry, target association state machine, follow guidance. Unit-tested. |
| `SharedSightApp/Perception` | `CameraFrameProvider` (AVFoundation), `NeuralObjectDetector` + `ObstacleSegmentationEngine` (Core ML), `CameraMotionEstimator` (CoreMotion), `SharedSightPerceptionEngine` (orchestrator) |
| `SharedSightApp/Audio` | `AudioFeedbackEngine` (AVSpeechSynthesizer, haptics) |
| `SharedSightApp/Collaboration` | `MultipeerTransport` (encrypted local P2P), `ARFrameProvider` (ARKit pose, floor raycast, shared marker) |
| `SharedSightApp/Identity` | `TargetMarkerDetector` (Vision QR reading), `MarkerImage` (QR generation) |
| `SharedSightApp/UI` | Live Vision (camera + overlays), Target, Settings, separate Diagnostics screen |
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

## Using it without sight

- Works with VoiceOver: every control has a label, a value and a hint.
- **Two-finger double tap** anywhere on the main screen pauses or resumes (VoiceOver Magic Tap).
- **What is around me?** speaks what is in view now, what was seen a moment ago, and what another device reported.
- **Repeat last announcement** says the last alert again.
- Speaking speed and detail level are in Settings. With VoiceOver on, alerts use your VoiceOver voice and speed.
- If the camera is covered or it is too dark, the app says so. It never says a path is clear.

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

## Following a registered person (prototype)

Flow: **register a person → show their marker → Start Tracking → the marked person is locked and followed → Target Lost stops guidance.**

1. Live Vision → Target (person icon) → type a name → Register. The person gets a permanent ID (`USER-0001`).
2. Target → Identification marker → Share or print. Print it about 15 cm wide, or AirDrop the image to the assisted
   person's phone and show it full screen, worn on the back or chest.
3. Live Vision → Start Tracking. Point the camera at the person. When the marker is read inside one person box the
   panel shows TARGET LOCKED and the box turns blue. Other people keep neutral boxes with temporary `TRACK-nnn` tags.
4. If the marker is too far to read, tap the person on screen (or Target → People in view now → Set as target).
5. The SIMULATED row shows which way a following camera would turn. No drone is connected and none is commanded.

What it does not do: face recognition, identity proof (a visible marker can be copied), metric distance from box size,
flight. See STATUS.md for what has and has not been tested.

## Local hub, shadow zones and the 3D room

**Settings → Stanza 3D · Server locale** connects the app to the Node hub in `Server/`. The phone posts its measured
detections, ARKit surfaces and camera pose; the hub fuses every connected phone into one model of the space and answers
each phone with what that phone cannot see:

- **Another phone sees it** (one phone's shadow is another phone's light): spoken as
  *"Persona davanti, dietro una porta, a circa 6 metri, secondo un altro dispositivo."*
- **Nobody sees it**: the phone itself (and the hub) predicts where a person, animal or vehicle that walked out of
  sight probably is. Spoken as a guess — *"Cane non più visibile, forse a destra, a circa 2 metri."* — with growing
  uncertainty, and dropped after a few seconds. This works with a single phone and without any server.

The browser dashboard shows the same model as an illustrated 3D room, pushed at 30 Hz.
See [Server/README.md](Server/README.md) for start-up, the simulated demo, the protocol and the measurements.

```sh
npm --prefix Server ci
npm --prefix Server start        # real phones
npm --prefix Server run demo     # simulated room with three virtual iPhones
```
