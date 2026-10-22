# Contributing to OpenWaze

Thanks for helping. This page takes you from clone to first PR. The full rulebook is
[AGENTS.md](AGENTS.md); it applies to people and AI agents alike. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Get running (about 5 minutes)

You need macOS, Xcode 26+ and [Homebrew](https://brew.sh). No API keys.

```sh
git clone https://github.com/markfive-proto/openwaze.git
cd openwaze
make bootstrap   # installs xcodegen, swiftlint, swiftformat; generates the Xcode project
make test        # unit tests on a simulator
```

Open `OpenWaze.xcodeproj` in Xcode and run the `OpenWaze` scheme. To fake a location:
`make sim-klcc` (KLCC, Kuala Lumpur) or `make sim-drive` (a test drive). See the README.

Working on the server only? You need Node 22.18+:

```sh
cd server && npm ci && npm test
```

## First PR

1. Pick an issue labelled [`agent-ready`](https://github.com/markfive-proto/openwaze/issues?q=is%3Aopen+label%3Aagent-ready)
   and comment that you are taking it. No fitting issue? Open one first.
2. Branch from `main`: `git checkout -b fix/short-name`.
3. Make the change. Keep it small. One issue per PR.
4. Add tests for any logic change. The test must fail without your change.
5. Run `make lint` and `make test` (or `npm test` in `server/`).
6. Push and open a PR. The template asks for what, why, how you tested, and screenshots
   for UI changes. Write `Closes #N`.
7. Wait for the `ci-ok` check to go green. A maintainer reviews and merges.

Do not commit the generated `.xcodeproj`. It is in `.gitignore` on purpose.

## What reviewers check

- `ci-ok` is green and the branch is up to date with `main`.
- Tests cover the change. See the delivery gate in [AGENTS.md](AGENTS.md).
- No secrets, no new unpinned dependencies, no precise user location sent to third parties.

## Map data

OpenWaze uses OpenStreetMap data. If the map is wrong, fix it at
[openstreetmap.org](https://www.openstreetmap.org), not here.

## License

By contributing you agree your code is released under the [MIT License](LICENSE).
