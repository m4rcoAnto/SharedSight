// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SharedSightCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SharedSightCore", targets: ["SharedSightCore"])],
    targets: [
        .target(name: "SharedSightCore"),
        // Fixtures are recordings read from disk by path (BlindWalkTests); they are not bundle resources.
        .testTarget(name: "SharedSightCoreTests", dependencies: ["SharedSightCore"], exclude: ["Fixtures"]),
    ]
)
