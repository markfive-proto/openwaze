PROJECT := OpenWaze.xcodeproj
SCHEME  := OpenWaze
# First available iPhone simulator, by UDID, so no device name is hardcoded.
SIM_LINE = $(shell xcrun simctl list devices available | grep -m1 -E "^ +iPhone")
SIM_ID   = $(shell echo "$(SIM_LINE)" | grep -oE "[0-9A-F-]{36}")
SIM_NAME = $(shell echo "$(SIM_LINE)" | sed -E "s/^ *//; s/ *[(].*[)] *$$//")

# Simulator location (#29): KLCC by default; GPX drives live in App/TestData.
KLCC  := 3.1579,101.7116
GPX   ?= App/TestData/PJ-city-drive.gpx
SPEED ?= 12

.PHONY: bootstrap project test lint sim-klcc sim-drive sim-stop demo

bootstrap:
	git config core.hooksPath scripts/githooks
	brew bundle
	$(MAKE) project

project:
	xcodegen generate

test: project
	@test -n "$(SIM_ID)" || { echo "No available iPhone simulator; install one in Xcode > Settings > Components."; exit 1; }
	@echo "Testing on simulator: $(SIM_NAME) ($(SIM_ID))"
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination "id=$(SIM_ID)" -derivedDataPath build

lint:
	swiftlint lint --strict
	swiftformat --lint App

sim-klcc:
	xcrun simctl location booted set $(KLCC)

# Replays a GPX file's points at a constant SPEED (m/s) on the booted simulator.
# For the GPX's own timestamps, pick the file in Xcode's scheme (Options > Location) instead.
sim-drive:
	grep -oE 'lat="[^"]+" lon="[^"]+"' $(GPX) | sed -E 's/lat="([^"]+)" lon="([^"]+)"/\1,\2/' \
		| xcrun simctl location booted start --speed=$(SPEED) -

sim-stop:
	xcrun simctl location booted clear

# Records the demo walkthrough video to demo/openwaze-demo.mp4 (#52).
demo: project
	scripts/demo/record.sh
