# Demo harness

Runs the drone module without SharedSight. Target observations come from `SyntheticTargetFeed` and are
labelled **TEST DATA** on screen; the mission logic, owner authorization and simulator are the real package code.

## Option A — demo app (iPhone or Simulator)

1. Open the folder `Demo/FieldVisionDroneDemo.swiftpm` in Xcode 15 or newer (File ▸ Open).
2. Pick an iPhone or a Simulator and press Run.
3. Tap **Start Drone Companion**. In the Simulator, enrol Face ID first (Features ▸ Face ID ▸ Enrolled) and
   answer the prompt with Features ▸ Face ID ▸ Matching Face — or switch off "Ask for Face ID or passcode".

## Option B — Xcode Previews (no app needed)

1. Open the repository's root `Package.swift` in Xcode.
2. Open `Sources/FieldVisionDroneKit/UI/DroneCompanionDemoView.swift`, choose an iOS Simulator destination
   and show the canvas. The preview is interactive and skips the Face ID prompt.

## Option C — your own app

New iOS App project ▸ add this package as a local package ▸ replace the root view with
`DroneCompanionDemoView()`. Add `NSFaceIDUsageDescription` to the app's Info.plist.

## What to try

| Scenario | Shows |
|---|---|
| Walking | search → target locked → following, left / right corrections |
| Occlusion | following paused while the target is hidden, resumed when it is back |
| Crossing | paused while the identity is ambiguous |
| Leaves | target lost, guidance stopped, reacquired only when verified again |
| Manual | drive position, confidence and the three flags yourself |

Second tap on the button: guidance stops at once, then simulated return, simulated landing, mission complete.
