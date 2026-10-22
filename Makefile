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

# Real iPhone: plug it in, trust this Mac, enable Settings > Privacy & Security > Developer Mode,
# then `make device TEAM=<your Apple Developer team ID>`. The team ID stays out of the repo.
TEAM      ?=
DEVICE_ID  = $(shell xcrun devicectl list devices 2>/dev/null | grep -m1 -oE "[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-Fa-f-]{36}")

.PHONY: bootstrap project test lint sim-klcc sim-drive sim-stop device

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

device: project
	@test -n "$(TEAM)" || { echo "Usage: make device TEAM=<Apple Developer team ID>"; exit 1; }
	@test -n "$(DEVICE_ID)" || { echo "No iPhone found. Plug it in, unlock it, tap Trust, enable Developer Mode."; exit 1; }
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination "id=$(DEVICE_ID)" \
		-derivedDataPath build -allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic
	xcrun devicectl device install app --device $(DEVICE_ID) build/Build/Products/Debug-iphoneos/OpenWaze.app
	xcrun devicectl device process launch --device $(DEVICE_ID) org.openwaze.app
