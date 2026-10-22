import SwiftUI

@main
struct OpenWazeApp: App {
    @State private var location = LocationAuthorization()
    @State private var destination: Destination?
    @State private var navigator = Navigator()

    private var guiding: Bool {
        [.navigating, .arrived].contains(navigator.phase)
    }

    var body: some Scene {
        WindowGroup {
            MapView(destination: destination, route: navigator.route, navigating: navigator.phase == .navigating)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if guiding {
                        if let step = navigator.nextStep, let progress = navigator.progress {
                            ManeuverBanner(step: step, distance: progress.distanceToManeuver)
                        }
                    } else {
                        SearchView(destination: $destination, near: { location.coordinate })
                    }
                }
                .overlay(alignment: .bottom) {
                    if navigator.phase != .idle {
                        TripCard(navigator: navigator) {
                            if guiding {
                                destination = nil
                            }
                            navigator.end()
                        }
                    } else if let destination {
                        DestinationCard(destination: destination, onGo: { destination in
                            Task { await navigator.preview(to: destination, from: location.coordinate) }
                        }, onClose: {
                            self.destination = nil
                        })
                    } else if location.isDenied {
                        LocationHint()
                    }
                }
                .onChange(of: destination) { navigator.end() } // a new search cancels the trip
                .onAppear { location.request() }
        }
    }
}
