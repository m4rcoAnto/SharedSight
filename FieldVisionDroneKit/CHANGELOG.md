# Changelog

All notable changes to this package. Versions follow semantic versioning and match the Git tags.

## 0.1.0 — 2026-11-14

First version. Written without a Swift toolchain: not yet compiled, tests not yet run.

- `DroneCompanionController`: mission state machine (12 states), owner authorization, target-follow
  logic, event delivery (closure, delegate, `AsyncStream`).
- `DroneTargetObservation`, `HostTargetSnapshot` and their conversion.
- `LocalDeviceOwnerAuthorizer` (LocalAuthentication), `PreapprovedOwnerAuthorizer` for tests and demos.
- `DroneVehicleAdapter` protocol and `SimulatedDroneAdapter`. No hardware adapter.
- `SyntheticTargetFeed`: labelled test data with five scripts.
- SwiftUI: `DroneControlButton`, `DroneStopFollowingButton`, `DroneSimulationView`,
  `DroneCompanionPanel`, `DroneCompanionDemoView`. English and Italian.
- Unit tests, demo app, SharedSight integration example.
