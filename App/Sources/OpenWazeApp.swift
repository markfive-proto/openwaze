import SwiftUI

@main
struct OpenWazeApp: App {
    @State private var location = LocationAuthorization()
    @State private var destination: Destination?

    var body: some Scene {
        WindowGroup {
            MapView(destination: destination)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    SearchView(destination: $destination, near: { location.coordinate })
                }
                .overlay(alignment: .bottom) {
                    if let destination {
                        DestinationCard(destination: destination, onGo: onGo) {
                            self.destination = nil
                        }
                    } else if location.isDenied {
                        LocationHint()
                    }
                }
                .onAppear { location.request() }
        }
    }

    /// Start navigating to `destination`. Routing (#10) hooks in here.
    private func onGo(_: Destination) {}
}
