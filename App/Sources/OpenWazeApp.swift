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
                        // Routing (#10) hooks in by passing onGo: { destination in ... }.
                        DestinationCard(destination: destination, onGo: nil) {
                            self.destination = nil
                        }
                    } else if location.isDenied {
                        LocationHint()
                    }
                }
                .onAppear { location.request() }
        }
    }
}
