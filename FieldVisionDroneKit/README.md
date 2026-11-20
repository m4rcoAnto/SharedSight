# FieldVisionDroneKit

Drone Companion module for FieldVision / Shared Sight (The Big Hack 2026, Mare Group Challenge 03).

A standalone Swift package: mission state machine, owner authorization, target-follow logic, a drone
**simulator**, and ready-made SwiftUI controls. It does not depend on the SharedSight source tree and
does no camera capture, detection, tracking, user storage or speech of its own. The host app tells it
where the registered person is; the kit decides what a following drone would do.

> **Status (0.1.0): written without a Swift toolchain. Not yet compiled, tests not yet run.**
> First thing to do on a Mac: `swift build && swift test` in this folder. See "Verification" below.

## What is real and what is simulated

| Part | Status |
|---|---|
| Mission state machine, transition table, timing rules | Real logic, unit-tested with synthetic input |
| Owner authorization (Face ID / Touch ID / passcode) | Real, through Apple's `LocalAuthentication` |
| Target observations in the app | Real: they come from SharedSight's camera, detector, tracker and marker |
| Follow guidance (left / right / centred, holds) | Real computation; reuses SharedSight's `FollowGuidance` when provided |
| The drone | **Simulated.** `SimulatedDroneAdapter` is numbers and timers. Nothing flies |
| Return and landing | **Simulated**, and always labelled so on screen and in announcements |
| Target observations in the standalone demo | **Synthetic test data**, labelled TEST DATA on screen |
| Landing in the user's hand, docking, any motor command | Not implemented, on purpose |

Face ID confirms who is holding the phone. It is not used to recognise the person being followed, and
no facial data goes anywhere. Who is followed is decided only by the host's registered-target pipeline
(SharedSight: a registered `PersonProfile` and its marker). The kit never picks a person by itself.

## Requirements

iOS 17+, Xcode 15 or newer, Swift 5.9+. No third-party dependencies.
(macOS 14 is listed only so the package builds and tests from the command line on a Mac.)

## Install

Xcode ▸ File ▸ Add Package Dependencies… ▸ paste the repository URL ▸ rule "Up to Next Major" from `0.1.0`
▸ add the `FieldVisionDroneKit` library to the app target.

```swift
// or in a Package.swift
.package(url: "https://github.com/<owner>/FieldVisionDroneKit.git", from: "0.1.0")
```

## Use it in six lines

```swift
import FieldVisionDroneKit

let drone = DroneCompanionController()                 // Face ID + simulated vehicle
drone.onEvent = { event in                             // you decide: speak, vibrate, show
    audio.say(event.announcement(.english))
}
drone.submit(observation)                              // on every perception update

DroneControlButton(controller: drone, targetID: registeredPersonID)   // in your SwiftUI view
```

The step-by-step guide for the SharedSight app, with the adapter files to copy, is in
[INTEGRATION.md](INTEGRATION.md).

## Public API

### `DroneCompanionController` (`@MainActor`, `ObservableObject`)

| Member | Purpose |
|---|---|
| `init(configuration:authorizer:vehicle:clock:)` | All dependencies are injectable. Defaults: `LocalDeviceOwnerAuthorizer`, `SimulatedDroneAdapter`, system uptime |
| `startMission(targetID:) async -> Bool` | Authorize the owner, prepare, search for that person |
| `submit(_ observation:)` | Feed the current target information |
| `stopFollowing()` / `resumeFollowing()` | Emergency stop of guidance; explicit resume (re-acquires from scratch) |
| `requestTermination()` | Stop guidance now, then return and landing |
| `primaryAction(targetID:)` | What the button does (start / end / nothing while busy / reset after error) |
| `reset()` | Back to `off` after `landed` or `error` |
| `state`, `pauseReason` | Published mission state |
| `guidance` | Published `DroneFollowGuidance` (active cue or hold reason) |
| `telemetry` | Published vehicle telemetry (simulated phase, height, correction, progress) |
| `latestObservation`, `observationQuality`, `lastRejection`, `rejectedObservationCount` | Why the kit is or is not following |
| `onEvent`, `eventReceiver`, `events()` | Mission events: closure, delegate, or `AsyncStream` |
| `isSimulation`, `isUsingSyntheticData` | For honest labelling |
| `currentTime` | The clock observations must be stamped with |

### `DroneTargetObservation`

```swift
DroneTargetObservation(
    targetID: UUID,                 // persistent ID of the registered person; must match the mission's
    normalizedCenterX: Double?,     // 0 left … 1 right, upright image; nil = no position
    normalizedCenterY: Double?,     // 0 top … 1 bottom
    boundingBoxArea: Double?,       // fraction of the image; a visual cue, never a distance
    confidence: Double,             // 0 … 1
    isDirectlyObserved: Bool,       // false for predicted positions
    isIdentityVerified: Bool,       // true only with explicit evidence (marker, operator)
    isIdentityAmbiguous: Bool,      // host cannot tell who is who -> following pauses
    timestamp: TimeInterval,        // seconds, same clock as controller.currentTime
    hostGuidance: HostFollowGuidance?, // optional: guidance the host already computed
    origin: .liveHost | .syntheticTestData)
```

Send one per perception update, also when the target is not seen (unverified, no position). Sending
nothing is treated as stale data: following pauses after 0.6 s + 0.3 s and the target is lost after 1.5 s.

`DroneTargetObservation(host: HostTargetSnapshot, timestamp:)` converts a host's own tracking state
(`notTracking / searching / locked / following / occluded / ambiguous / lost`) and is the recommended way in.

### Mission states

```
OFF ─▶ AUTHORIZATION_REQUIRED ─▶ PREPARING ─▶ SEARCHING_FOR_TARGET ─▶ TARGET_LOCKED ─▶ FOLLOWING
                │ denied / cancelled                  ▲      ▲               │              │
                ▼                                     │      └── TARGET_LOST ◀──────────────┤
               OFF                                    │              ▲                      ▼
                                                      └──────────── PAUSED ◀────────────────┘
any active state ─▶ RETURN_REQUESTED ─▶ LANDING ─▶ LANDED ─▶ (start again | reset ─▶ OFF)
any active state ─▶ ERROR ─▶ reset ─▶ OFF
```

- **Lock**: a verified, directly observed, confident observation of the mission's `targetID`, held for 0.3 s.
- **Following**: after 0.5 s in TARGET_LOCKED. Only this state produces active guidance.
- **Paused**: occlusion, low confidence, stale data or ambiguous identity (automatic, resumes when valid
  again), or the user's Stop Following (resumes only with `resumeFollowing()`).
- **Target lost**: invalid for 1.5 s, ambiguous for 6 s, or the host says the identity is gone. Guidance
  stops; only a verified observation of the same person locks again. Nobody else is ever selected.
- The whole table is `DroneMissionState.allowedNextStates`; the controller refuses anything else.

All thresholds are in `DroneCompanionConfiguration`.

### Events

`droneModeActivated`, `searchingForTarget`, `targetAcquired`, `followingActive`, `followingPaused(reason)`,
`followingResumed`, `targetLost`, `returnRequested`, `landingStarted`, `missionCompleted`,
`missionCancelled`, `missionFailed(error)`, `authorizationFailed(reason)`, `activationRefused(reason)`.

Each has `severity` (info / success / warning / critical) and `announcement(.english | .italian)`.
The kit contains no speech synthesizer and no haptics: the host presents events.

### SwiftUI

| View | Use |
|---|---|
| `DroneControlButton(controller:targetID:language:)` | The two-action button. Disabled without a registered target and while busy |
| `DroneStopFollowingButton(controller:language:)` | Separate emergency stop; becomes "Resume Following" |
| `DroneSimulationView(controller:language:)` | The simulated drone and the camera strip |
| `DroneCompanionPanel(controller:targetID:language:)` | The three above on one card |
| `DroneCompanionDemoView()` | Standalone harness with labelled synthetic data |

All controls have VoiceOver labels, values and hints, scale with Dynamic Type, state everything in
words (not colour alone), and respect Reduce Motion.

### Extension points

- `OwnerAuthorizing` — replace the authentication (tests use a mock; `PreapprovedOwnerAuthorizer` exists
  for previews and demos and is never the default).
- `DroneVehicleAdapter` — where a real aircraft SDK would attach. A hardware adapter must bring its own
  independently validated safety layer (geofence, altitude and speed limits, link-loss failsafe,
  obstacle avoidance, manual override, landing procedure). None of that exists here.

## Demo

See [Demo/README.md](Demo/README.md): a runnable demo app (`Demo/FieldVisionDroneDemo.swiftpm`) or the
interactive Xcode preview of `DroneCompanionDemoView`.

## Verification

```bash
swift build          # independent compilation, no SharedSight needed
swift test           # 40 unit tests, no hardware, no camera
```

The tests cover: mission activation, authorization success and failure, target acquisition, following,
low confidence, temporary occlusion, target loss, stale observations, wrong or unverified target,
stop-follow, return request, simulated landing completion, repeated button presses, invalid transitions,
integration mapping, and use of the public API alone.

Not verified by any test: behaviour on an iPhone, Face ID prompts, VoiceOver, animation quality, and
everything about real aircraft.

## Layout

```
Package.swift
Sources/FieldVisionDroneKit/
  Models/        observation, guidance, states, events, configuration
  Mission/       DroneCompanionController, owner authorization
  Tracking/      observation assessment, guidance filter
  Simulation/    vehicle adapter protocol, SimulatedDroneAdapter, SyntheticTargetFeed
  UI/            button, stop action, simulation view, panel, demo view
  Integration/   HostTargetSnapshot and its conversion
Tests/FieldVisionDroneKitTests/
Demo/                         standalone demo app + instructions
IntegrationExamples/SharedSight/   adapter, coordinator and sheet to copy into the SharedSight app
INTEGRATION.md  CHANGELOG.md
```

## Releases

Semantic versioning with Git tags (`0.1.0`, `0.1.1`, …). Record changes in `CHANGELOG.md`, then:

```bash
git tag 0.1.1 && git push origin 0.1.1
```

## Publishing this folder as its own repository

```bash
cd FieldVisionDroneKit
git init -b main
git add .
git commit -m "FieldVisionDroneKit 0.1.0"
gh repo create FieldVisionDroneKit --public --source=. --push      # GitHub CLI
git tag 0.1.0 && git push origin 0.1.0
```

Without the GitHub CLI: create an empty repository named `FieldVisionDroneKit` on github.com, then

```bash
git remote add origin https://github.com/<owner>/FieldVisionDroneKit.git
git push -u origin main
git tag 0.1.0 && git push origin 0.1.0
```
