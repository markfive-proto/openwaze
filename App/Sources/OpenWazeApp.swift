import SwiftUI

@main
struct OpenWazeApp: App {
    @State private var location = LocationAuthorization()

    var body: some Scene {
        WindowGroup {
            MapView()
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    if location.isDenied {
                        LocationHint()
                    }
                }
                .onAppear { location.request() }
        }
    }
}
