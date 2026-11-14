// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SharedSightCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SharedSightCore", targets: ["SharedSightCore"])],
    targets: [
        .target(name: "SharedSightCore"),
        .testTarget(name: "SharedSightCoreTests", dependencies: ["SharedSightCore"]),
    ]
)
