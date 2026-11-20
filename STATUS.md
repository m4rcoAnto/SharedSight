# UPDATE — Drone Companion wired in (14 Nov 2026, 23:50)

- **Not compiled, not run.** Neither `FieldVisionDroneKit` nor this app target has been built since this change.
  First job: `cd FieldVisionDroneKit && swift build && swift test`, then `./Scripts/verify.sh`.
- Added `FieldVisionDroneKit/` (standalone Swift package, local dependency of the app target) and
  `SharedSightApp/Drone/` (3 files: bridge, coordinator, sheet).
- Changed: `SharedSightApp/UI/RootView.swift` (5 lines: coordinator, sheet case, menu item),
  `SharedSight.xcodeproj/project.pbxproj` and `project.yml` (package reference, `NSFaceIDUsageDescription`).
- Nothing else was touched: `SharedSightCore`, `AppModel`, the perception engine, `ServerTransport`, `Server/`.
- Use: More (⋯) ▸ Drone Companion ▸ Start Drone Companion ▸ Face ID. The drone, return and landing are simulated.
- Presentation mode (switch under the drone panel): labelled test data instead of the camera, no Face ID,
  slower phases. For screenshots and demos; works in the Simulator. Added 15 Nov 00:50, not compiled.
- To remove it: delete `SharedSightApp/Drone/`, revert the 5 lines in `RootView.swift`, remove the package in Xcode.

---

# UPDATE — shadow zones, trajectory estimates, fused 3D room (14 Nov 2026, late night)

## Honest headline
- **Hub and dashboard (Node / browser): run and tested here.** 23 Node tests pass, including the simulated demo posted
  through the real HTTP server. The dashboard was looked at in headless Chrome (software rendering).
- **SharedSightCore: compiled and tested here on Linux** (Swift 5.10): **107 tests, 0 failures** (78 earlier + 29 new).
- **App target (`SharedSightApp/`): NOT compiled.** There is no Xcode here. The new blocks of `SharedSightPerceptionEngine`
  and the whole `ServerTransport` were type-checked on Linux against the real core with stand-ins for the Apple-only
  types; `ARFrameProvider`, `DiagnosticsView`, `AppModel` and `AudioFeedbackEngine` edits (a few lines each) were not.
  First job on the Mac: `./Scripts/verify.sh`.
- **Nothing was run on an iPhone.** Everything about behaviour comes from simulated data.

## What was added
- `Server/world.mjs`: late (object-level) fusion on the floor plane, per-phone line of sight (field of view, measured
  walls / doors / windows, tall objects), "seen by another phone" versus "estimated", prediction that cannot cross a
  wall, evidence of absence, furniture memory. `Server/geometry.mjs`, `Server/shared/classes.mjs` (80 classes).
- Protocol v2: the hub answers every frame with advisories; surfaces and previews travel only when they change;
  10 frames/s on one kept-alive connection. v1 clients are still accepted.
- Push stream to the dashboard (30 Hz) instead of 400 ms polling; persistent scene, velocity-driven motion.
- Dashboard redesigned as an illustrated room (walls, parquet, furniture, people, animals, vehicles; translucent
  estimates with their uncertainty; shadow zones on the floor).
- `SharedSightCore`: `SightGeometry`, `GroundTrackMemory` (single-phone prediction), `HiddenObjects` (hub reply,
  resolver), two alert kinds (`hiddenSeenByOther`, `hiddenEstimate`) with IT / EN wording, surroundings summary,
  occlusion-aware tracker (OA-SORT style offset and momentum), `DistanceMeasurement.Method.motionPrediction`.
- App: `ServerTransport` v2, engine wiring, ARKit plane classification (wall / door / window), Diagnostics section.
- Demo: `npm --prefix Server run demo` (3 phones) and `demo:1`.

## "Listen only" evaluation and what it changed
`BlindWalkTests` replays the recorded demo through the real decision and wording code plus a model of the app's speech
queue, and prints what the user would hear (`BLIND_WALK_PRINT=1 swift test --filter BlindWalk`). First run, 3 phones,
75 s: the voice was busy 92 % of the time, 44 decided announcements were never spoken, and the person who walked behind
the door was **not** announced (the voice was describing a dog 5.5 m away). Changes made because of it:

| Problem heard | Change |
|---|---|
| Far strangers behind walls announced again and again | A mover seen only by another phone is announced when near (≤ 4 m), approaching (≥ 0.4 m/s within 6 m), or when this phone was following it and it went behind a wall or door |
| The key hand-off lost in the queue | Hand-offs outrank other far reports; one announcement per decision |
| Sentences of six seconds | Estimates shortened ("…, forse a destra, a circa 2 metri."); no "outside the camera's view" when the direction says it; whole metres from 3 m; direction before the reason |
| A dog trotting about narrated at every change of side | Side change re-announced after 5 s, or at once if close and straight ahead |
| "Table on your left" at every sweep of the camera | Same furniture class and side not repeated for 20 s |
| "Person ahead." then "Person ahead, moving." one second later | First announcement waits 5 detections; "moving" appended only after 3 s (an approach is still immediate) |
| Directions spoken up to 2 s late | Pending speech older than 1.2 s is dropped; non-urgent announcements are decided only when the voice is expected to be free, plus a pause |
| "Ahead" meant ±11° for the camera and ±25° for hidden objects | One definition |
| A chair measured 1.5 m straight ahead ranked below a moving dog far away | Close and straight ahead is urgent |
| Summary listed "outside the camera's view" per item, plants 6 m away first | Movers first, furniture only within 4 m, reason only when it is a wall / door / object |

After: voice busy 68 % (3 phones) and 50 % (1 phone) in a deliberately crowded scene, 4 and 2 announcements never
spoken, nothing waited more than 1.2 s, every hand-off announced (typically within about a second, 4.6 s worst case).
**These are simulated numbers with an assumed speaking rate of 15 characters per second.** They are not a user study.
VoiceOver itself was not run.

## Not verified
1. App target compilation (see headline). Likely spots: `ARPlaneAnchor.classification` switch, the Diagnostics section.
2. ARKit: do vertical planes really stop at door openings, is the plane classification reliable, how noisy is the floor
   raycast for people at 5–8 m. The line-of-sight reasoning is only as good as these.
3. Marker alignment error between phones (assumed 12 cm); fusion gates were tuned on simulated noise.
4. Real speaking rate and whether 68 % voice occupancy in a busy room is acceptable to a blind user.
5. End-to-end latency on real Wi-Fi (the dashboard shows it live: "cattura→server").

---

# UPDATE — persistent person ID, target following, Live Vision redesign (14 Nov 2026, night)

## Honest headline
**None of the code in this update has been compiled or run.** It was written where no Swift toolchain exists.
The 43 tests and the Simulator build reported in the section below describe the code *before* this update.
First job on the Mac: `./Scripts/verify.sh`, then fix whatever the compiler and the 35 new tests report.

## What was added
- **Persistent identity** (`SharedSightCore/PersonIdentity.swift`): `PersonProfile` (UUID, `USER-0001`-style ID that is never
  reused, nickname, registration date, random marker token, status, preferences), `PersonRegistry` (create / edit / select /
  delete / new marker), stored as one JSON file in Application Support with complete file protection. `TrackingEventLog`
  keeps target state changes (text only) with a retention period.
- **Target association** (`PersonTargetManager.swift`): state machine unassigned / searching / acquired / following /
  temporarilyOccluded / lost / ambiguous. A track becomes the target only when the person's QR marker is read inside
  exactly one person box, or when the operator picks that person by hand. It never moves to another track by itself.
- **Marker** (`SharedSightApp/Identity`): QR generation (Core Image) and reading (Vision `VNDetectBarcodesRequest`) on the
  same camera frame the detector uses. Payload = prefix + 128 random bits. Other QR codes are ignored.
- **Follow guidance** (`FollowGuidance.swift`): normalised target centre, smoothed offsets, dead zone with hysteresis,
  confidence gate, apparent-size cue. Output is a suggested camera correction shown as SIMULATED. `FollowVehicleAdapter`
  is the seam for a real drone; the only implementation records setpoints and moves nothing.
- **Tracker**: `TrackSnapshot.lastAmbiguousAt` added so a consumer can see a *new* identity ambiguity after re-verifying.
- **UI**: Live Vision (full-screen camera, real boxes, `TRACK-nnn` tags, target reticle, compact bottom panel),
  Target sheet (register, marker, start / stop, people in view), Settings (existing options + tracking), Diagnostics
  (target, guidance values, event log). Camera picture comes from an `AVCaptureVideoPreviewLayer` on the existing session.
- One inference per frame is still the only model run: person targeting reuses the tracker output.

## Design decisions worth knowing
- JSON file instead of SwiftData: the registry lives in `SharedSightCore` so it can be unit-tested with `swift test`
  on macOS 13; SwiftData would force macOS 14 and move the model into the app target.
- Crossing rule: while another person overlaps the target (IoU >= 0.25) and the marker was not read in the last 0.6 s,
  following is paused (`ambiguous`). If the target was detected in every frame of the crossing it resumes on the same
  track with confidence x0.6; if it was hidden at any point, the association is dropped until the marker is read again.
  `TargetConfig.resumeAfterCleanCrossing = false` makes every crossing require the marker.
- Hidden-target time is capped at 1.5 s because the tracker never re-matches a track after `reassociationWindow` (1.5 s).

## Not verified (needs a Mac, then iPhones)
1. Compilation of everything above. Most likely trouble spots: SwiftUI type-checking in `RootView.swift` / `TargetView.swift`,
   and `AppModel.init` property-initialisation order.
2. The 35 new unit tests in `PersonTargetTests.swift` (never executed). `testCrossingWithRealTrackerNeverFollowsTheOtherPerson`
   depends on real tracker behaviour and is the one most likely to need attention.
3. Overlay alignment: boxes are mapped onto the preview with an aspect-fill transform. If they are offset, check
   `AspectFillMap` and the older `Letterbox` note below.
4. From how far the QR marker is readable at 1280x720. Expect a 15 cm marker to work at a few metres at best. Beyond
   that, use the manual "Set as target" path. This has not been measured.
5. Vision bounding-box orientation for barcodes with `orientation: .right` (assumed: normalised, bottom-left origin, upright image).
6. VoiceOver on the new screens, Dynamic Type at accessibility sizes, speech overlap between target announcements and obstacle alerts.

---

# UPDATE — branch `accessibility-hig` (14 Nov 2026, late evening)

## What was checked on this branch
- `swift test` in `SharedSightCore` on a Mac: **43 tests, 0 failures** (the 33 original tests plus 10 new ones).
- `xcodebuild` for the iOS Simulator (Debug, no signing): **BUILD SUCCEEDED**. This is the first time the app has been compiled.
- Not done: the app has not been launched, in the Simulator or on an iPhone. No screen has been looked at, VoiceOver has not been
  run against it, and no speech has been heard. Everything under "TESTED ON REAL IPHONE" below is still "Nothing".

## What changed (accessibility and Human Interface Guidelines pass, driven by RESEARCH.md "Need, existing products…")
- **"What is around me?"** button: on-demand spoken summary in three separate groups (in view now / seen a moment ago, not confirmed /
  reported by another device, with or without verified position). Empty scene ends with "This does not mean the way is clear".
  Logic in `SharedSightCore/SurroundingsSummary.swift`, 10 unit tests.
- **"Repeat last announcement"** button.
- **VoiceOver:** short label + separate value + hint on every control; state buttons carry the toggle trait; status is three separately
  focusable lines; Magic Tap (two-finger double tap) pauses or resumes; first-launch focus lands on the title; link changes are announced
  through VoiceOver when the app's own speech is off; answers to direct requests go through VoiceOver so they do not talk over it.
- **Speech:** adjustable speaking speed with a test button; when VoiceOver is on, alerts use the user's VoiceOver voice and speed
  (`prefersAssistiveTechnologySettings`).
- **Dynamic Type / low vision:** main screen scrolls, button heights scale, text wraps, the two secondary buttons stack at accessibility
  sizes, Increase Contrast is honoured.
- **Settings:** number pad can be closed (keyboard toolbar button); stepper and slider read a proper value.
- **Haptics:** generators are reused and prepared; the three patterns are explained in Settings.

## Needs a person with an iPhone (cannot be verified from a Mac)
1. VoiceOver pass over every screen: reading order, labels, Magic Tap, the consent alert, the keyboard button.
2. Whether app speech and VoiceOver speech overlap in practice, and whether the VoiceOver-voice setting sounds right.
3. Largest Dynamic Type size on a small iPhone: nothing clipped.
4. Everything already listed under EXPERIMENTAL and REMAINING BLOCKERS below.

---

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
