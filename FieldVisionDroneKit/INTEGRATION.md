# Integrating FieldVisionDroneKit into SharedSight

For the SharedSight team. About ten minutes. Nothing in `SharedSightCore`, `AppModel`, the perception
pipeline or the collaboration engine changes. You add one package, copy three files, and add five lines
to `RootView.swift`.

The drone module does not open the camera, run the model, track people, store users or speak.
It reads what SharedSight already publishes (`snapshot.target`, `snapshot.guidance`) and sends its
events to SharedSight's existing `AudioFeedbackEngine`.

## 1. Add the package

Xcode ▸ File ▸ Add Package Dependencies… ▸ `https://github.com/<owner>/FieldVisionDroneKit.git`
▸ Up to Next Major from `0.1.0` ▸ add library **FieldVisionDroneKit** to target **SharedSight**.

If you regenerate the project with XcodeGen, add to `project.yml`:

```yaml
packages:
  SharedSightCore: { path: SharedSightCore }
  FieldVisionDroneKit: { url: https://github.com/<owner>/FieldVisionDroneKit.git, from: 0.1.0 }
targets:
  SharedSight:
    dependencies: [{ package: SharedSightCore }, { package: FieldVisionDroneKit }]
```

## 2. Copy three files into the app target

From `IntegrationExamples/SharedSight/` into, for example, `SharedSightApp/Drone/`
(the app target uses a synchronized folder, so new files are picked up automatically):

| File | What it does |
|---|---|
| `SharedSightDroneBridge.swift` | Maps `TargetStatus` + `FollowGuidance` to the kit's `HostTargetSnapshot` |
| `DroneCompanionCoordinator.swift` | Forwards every snapshot to the kit; sends mission events to `engine.audio.sayStatus` |
| `DroneCompanionSheet.swift` | The drone screen (simulation, drone button, emergency stop) |

They compile against the current SharedSight types: `TargetStatus`, `TargetTrackingState`,
`FollowGuidance`, `AppModel.snapshot`, `AppModel.activeProfileID`, `AppModel.trackingOn`,
`AppModel.startTracking()`, `AppModel.language`, `engine.audio.sayStatus(_:haptic:)`, `Theme.background`.
If one of those is renamed, the compiler points at the single line to fix.

## 3. Five lines in `SharedSightApp/UI/RootView.swift`

```swift
struct LiveVisionView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var drone = DroneCompanionCoordinator()        // 1 (new)
    …
    enum Sheet: String, Identifiable {
        case target, settings, diagnostics, drone                        // 2 (add `drone`)
        …
    }
    …
        .accessibilityAction(.magicTap) { model.togglePause() }
        .onAppear { drone.attach(to: model) }                            // 3 (new)
    …
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .target: TargetView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                case .drone: DroneCompanionSheet(coordinator: drone)     // 4 (new)
                }
            }
```

and in `ControlPanel`, inside the existing `Menu { … }`, above `Divider()`:

```swift
Button { sheet = .drone } label: { Label("Drone Companion", systemImage: "airplane") }   // 5 (new)
```

Prefer the button on the main screen instead of a sheet? Put this anywhere in `ControlPanel`
(pass the coordinator down), nothing else is needed:

```swift
DroneControlButton(controller: drone.controller, targetID: model.activeProfileID)
```

## 4. One Info.plist key

Target SharedSight ▸ Info ▸ add **Privacy - Face ID Usage Description** (`NSFaceIDUsageDescription`):
"Confirms that the owner of this iPhone is starting Drone Companion."

With generated Info.plist that is the build setting `INFOPLIST_KEY_NSFaceIDUsageDescription`.
Without the key the kit refuses to start (`authorizationFailed(.missingUsageDescription)`) instead of
letting iOS terminate the app.

## What the user gets

1. Target ▸ register a person (existing SharedSight flow).
2. More ▸ Drone Companion ▸ **Start Drone Companion** ▸ Face ID.
3. The coordinator starts SharedSight's tracking if it is not running. When SharedSight locks the
   registered person through the marker, the kit goes TARGET LOCKED → FOLLOWING and the simulated drone
   leans left or right with SharedSight's own follow guidance.
4. Hidden, uncertain or lost in SharedSight means paused or lost in the kit. It never follows anyone else.
5. **Stop Following** stops guidance at once. **End Mission** stops, then simulated return and landing.

## Presentation mode (screenshots and demos without a camera)

The drone screen has a **Presentation mode** switch under the panel. With it on:

- the target comes from the kit's `SyntheticTargetFeed` instead of SharedSight's camera, so it works in
  the Simulator and with nobody registered;
- Face ID is skipped;
- "Slow phases" stretches preparing, target locked, return and landing to a few seconds each.

The panel keeps its SIMULATION and TEST DATA labels. The switch can only change between missions.
Scenario **Manual** holds any state: "Identity verified" off = searching / target lost, "Visible" off =
paused, the slider = follow left / right.

## How the data flows

```
SharedSightPerceptionEngine ──▶ AppModel.snapshot (15 Hz, existing)
                                      │  model.$snapshot  (no change to AppModel)
                                      ▼
                         DroneCompanionCoordinator
              SharedSightDroneBridge.snapshot(status:guidance:)
                                      ▼
                 DroneTargetObservation(host:timestamp:)  ── kit ──▶ DroneCompanionController
                                                                           │ events
              engine.audio.sayStatus(text, haptic:)  ◀─────────────────────┘
```

Mapping (unit-tested inside the kit):

| SharedSight `TargetTrackingState` | Kit observation |
|---|---|
| `acquired`, `following` | identity verified, directly observed (unless `boxIsPredicted`), SharedSight guidance reused |
| `temporarilyOccluded` | identity verified, not observed → guidance held, then paused |
| `ambiguous` | ambiguous → paused at once |
| `lost`, `searching`, `unassigned` | not verified → target lost / keeps searching |
| no active profile | nothing is submitted; the drone button is disabled |

## Speech

The kit has no synthesizer. `DroneCompanionCoordinator.present` sends each event's
`announcement(_:)` through `sayStatus`, which never interrupts an obstacle alert. Events that SharedSight
already announces for the same person (target locked, hidden, uncertain, lost) are not spoken twice;
edit `isAnnounced` to change that.

## If something does not work

| Symptom | Cause |
|---|---|
| Button stays disabled | No registered person selected (`model.activeProfileID == nil`) |
| "Face ID is not configured" | Step 4 missing |
| Stays in SEARCHING FOR TARGET | SharedSight has not locked the person yet (marker not read). Check the Target sheet |
| `controller.lastRejection == .stale` | Observations stamped with a different clock. Use `controller.currentTime` |
| `controller.lastRejection == .wrongTarget` | The active profile changed during a mission. End the mission and start again |

## Keeping up with SharedSight changes

The package has no knowledge of SharedSight. Only the three copied files do, and only
`SharedSightDroneBridge.swift` touches `SharedSightCore` types. If the tracking model changes, that
one file changes; the package version does not.
