import SwiftUI
import FieldVisionDroneKit

/// The whole demo app: one screen from the package, driven by labelled synthetic target data.
@main
struct FieldVisionDroneDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DroneCompanionDemoView()
                .preferredColorScheme(.dark)
        }
    }
}
