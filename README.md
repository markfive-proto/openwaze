# OpenWaze

Open-source, crowd-sourced navigation for iOS, built on OpenStreetMap.
Your reports stay open data (ODbL), not locked in someone else's map.

Status: bootstrapping. See the sprint issues to contribute.

## Develop

Needs Xcode 26+ and Homebrew.

    make bootstrap   # brew bundle + generate OpenWaze.xcodeproj (not committed)
    make test        # unit tests on the first available iPhone simulator
    make lint        # swiftlint + swiftformat --lint

The map uses the keyless [OpenFreeMap](https://openfreemap.org) Liberty style, so no API key is needed.
