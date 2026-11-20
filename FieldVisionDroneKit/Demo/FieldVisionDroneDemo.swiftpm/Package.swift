// swift-tools-version: 5.9
// Standalone demo app (Swift Playgrounds app format). Open this folder in Xcode 15+ or Swift Playgrounds
// and run it on an iPhone or the Simulator. It uses the package two folders up; nothing from SharedSight.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "FieldVisionDroneDemo",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "FieldVisionDroneDemo",
            targets: ["AppModule"],
            bundleIdentifier: "com.fieldvision.dronedemo",
            teamIdentifier: "",
            displayVersion: "0.1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .paperPlane),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.phone, .pad],
            supportedInterfaceOrientations: [.portrait],
            capabilities: [
                .faceID(purposeString: "Confirms that the owner of this iPhone is starting Drone Companion.")
            ]
        )
    ],
    dependencies: [
        .package(name: "FieldVisionDroneKit", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "FieldVisionDroneKit", package: "FieldVisionDroneKit")],
            path: "."
        )
    ]
)
