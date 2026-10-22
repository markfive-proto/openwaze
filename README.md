# OpenWaze

Open-source, crowd-sourced navigation for iOS, built on OpenStreetMap.
Your reports stay open data (ODbL), not locked in someone else's map.

Status: bootstrapping. See the sprint issues to contribute.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md). The rules for people and AI agents are in
[AGENTS.md](AGENTS.md). Pick an open issue labelled `agent-ready`. Code is MIT licensed
([LICENSE](LICENSE)); please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Map data

The app uses OpenStreetMap data. © OpenStreetMap contributors, available under the
[ODbL](https://www.openstreetmap.org/copyright). If the map is wrong, fix it in
[OpenStreetMap](https://www.openstreetmap.org) so everyone benefits.

## Develop

Needs Xcode 26+ and Homebrew.

    make bootstrap   # brew bundle + generate OpenWaze.xcodeproj (not committed)
    make test        # unit tests on the first available iPhone simulator
    make lint        # swiftlint + swiftformat --lint

### Simulated location and test drives

Tests and examples use Kuala Lumpur: KLCC, `3.1579, 101.7116`. On the booted simulator:

    make sim-klcc                                         # park at KLCC
    make sim-drive                                        # drive App/TestData/PJ-city-drive.gpx at 12 m/s
    make sim-drive GPX=App/TestData/KLCC-to-KLIA.gpx SPEED=25
    make sim-stop                                         # clear the simulated location

`sim-drive` wraps `xcrun simctl location booted start --speed=<m/s> -`, which reads `lat,lon`
waypoints from stdin, so any GPX works. To replay a GPX at its own recorded timestamps instead,
run from Xcode and pick the file under Product > Scheme > Edit Scheme > Run > Options > Default
Location (add it to the scheme with "Add GPX File to Workspace...").

Drives in `App/TestData/`, generated from OSRM route geometry with OSRM's per-segment timings:

- `KLCC-to-KLIA.gpx`: KLCC to KLIA by expressway, ~61 km, ~68 min.
- `PJ-city-drive.gpx`: Petaling Jaya, Amcorp Mall to SS2, ~3.2 km with a roundabout and several turns.

To try navigation: `xcrun simctl location booted set 3.103637,101.640633` (the PJ drive's start),
search "Jalan SS 2/60", tap Go, then Start, and run `make sim-drive`. To test rerouting, run
`make sim-stop` mid-drive and `xcrun simctl location booted set 3.1110,101.6330` (about 200 m off the
route); a new route is fetched after 5 s.

Routing uses the public OSRM demo server (`Router.baseURL`), which is for development only.

The map uses the keyless [OpenFreeMap](https://openfreemap.org) Liberty style, so no API key is needed.
