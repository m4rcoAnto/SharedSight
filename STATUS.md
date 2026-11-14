# STATUS — Shared Sight (written 14 Nov 2026, evening) — HANDOFF NOTES FOR THE NEXT AGENT / ENGINEER

## Honest headline
All source code for P0–P3 is written and wired together. **Nothing has been compiled or run yet**: no Swift toolchain was
available where the code was written. The first job is `./Scripts/verify.sh` on the Mac, then fixing whatever the compiler reports.

## IMPLEMENTED (code written, connected to the running app path)
- CameraFrameProvider (AVFoundation, native YCbCr buffers, late-frame discard, permission / interruption / runtime-error states, drop counter)
- NeuralObjectDetector (Core ML via Vision, real YOLO26n-seg weights bundled, labels from model metadata only, explicit load errors, no fallback detector)
- ObstacleSegmentationEngine (instance masks from real prototypes, top-K + every-Nth-frame scheduling, box fallback labelled BOUNDING_BOX)
- TemporalObjectTracker, ObstacleMemoryEngine (OBSERVED / TEMPORARILY_HIDDEN / PREDICTED / UNKNOWN / REACQUIRED / LOST), CameraMotionEstimator (gyro)
- SpatialRelevanceEstimator, PerceptionReliabilityEngine (per-feature states), ObstacleAlertDecisionEngine, AlertPhraseBuilder (IT/EN)
- AudioFeedbackEngine (AVSpeechSynthesizer, priority / interruption / pending policy, mute, haptics, speech-delay measurement)
- SharedSightCollaborationEngine (consent, hello/ping clock sync, attribution, expiry, anchor-based localisation) + MultipeerTransport (encrypted, session code)
- ARFrameProvider (ARKit pose, floor raycast distance, printed-marker shared anchor)
- SwiftUI app: onboarding, one-tap pause, speech toggle, consent dialog, settings, separate Diagnostics screen with live metrics

## TESTED ON REAL IPHONE
- Nothing.

## SOFTWARE-TESTED ONLY
- Nothing has been executed. 33 unit tests exist in `SharedSightCore/Tests` (tracking IDs, mask association, stationary / moving, camera-motion
  compensation, occlusion, prediction expiry, identity ambiguity, decoder layouts, camera / model failure, freshness, de-duplication, priority,
  local vs peer attribution, connection, consent withdrawal, expiry, alignment failure, direction suppression, reconnection, independent operation).
- Verified outside Swift: the Core ML export succeeded and its output shapes / metadata were read back from the model file.

## EXPERIMENTAL (needs device validation before it is trusted)
- Vision `.scaleFit` letterbox is assumed centred → check box alignment in Diagnostics. If boxes are offset, fix `Letterbox`.
- Gyro camera-motion compensation sign convention (portrait, rear camera) → pan the phone at a static chair; track velocity should stay ≈ 0.
- ARKit raycast point mapping portrait→landscape `(x, y) → (y, 1 − x)` and the floor-contact assumption (wrong for tables / occluded bases).
- Position uncertainty `0.15 m + 5 %` is a heuristic, not a calibration. Relevance weights and alert thresholds are untuned.
- Italian voice availability depends on the voices installed on the phone.

## NOT IMPLEMENTED
- Unknown / class-agnostic obstacle sensing (3.4): only the taxonomy and the capability gate exist; it always reports UNKNOWN_REGION.
- Optical-flow / image-registration motion estimation; translation parallax compensation.
- App-level XCTest target (real-model initialisation test on device); thermal-driven resolution adaptation; battery measurement.
- More than the minimal handling of >2 peers (protocol allows it, untested). No raw-video sharing by design.

## PERFORMANCE MEASUREMENTS
- None yet. Diagnostics shows camera fps, detection / segmentation latency, capture→decision, capture→speech, dropped / skipped frames, memory,
  thermal state and peer observation age once the app runs on a phone. Do not quote real-time performance before reading them there.

## REMAINING BLOCKERS (in order)
1. Compile: run `./Scripts/verify.sh`, fix errors (most likely spots: SwiftUI views, Vision / ARKit API details, the hand-written project file — fallback `xcodegen`).
2. Signing team, install on iPhone 1, confirm live detections + speech (P0), then iPhone 2 (P1).
3. Validate the three EXPERIMENTAL geometry assumptions above.
4. Two-phone session: connection, observation exchange, expiry (P2); marker fix on both phones, one spatially justified peer warning (P3).
