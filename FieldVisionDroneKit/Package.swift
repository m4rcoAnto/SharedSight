// swift-tools-version: 5.9
import PackageDescription

// Standalone package: Foundation, Combine, SwiftUI and LocalAuthentication only.
// It does not depend on SharedSight. macOS is listed so `swift build` / `swift test` run on a Mac.
let package = Package(
    name: "FieldVisionDroneKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FieldVisionDroneKit", targets: ["FieldVisionDroneKit"]),
    ],
    targets: [
        .target(
            name: "FieldVisionDroneKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "FieldVisionDroneKitTests",
            dependencies: ["FieldVisionDroneKit"]
        ),
    ]
)
