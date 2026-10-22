import SwiftUI

@main
struct OpenWazeApp: App {
    var body: some Scene {
        WindowGroup {
            MapView().ignoresSafeArea()
        }
    }
}
