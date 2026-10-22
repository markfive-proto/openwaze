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

.PHONY: bootstrap project test lint sim-klcc sim-drive sim-stop device testflight

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

# TestFlight upload. Needs an App Store Connect API key (App Store Connect > Users and Access >
# Integrations > Team Keys, role App Manager) and an app record for org.openwaze.app.
#   make testflight TEAM=<team id> ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> ASC_KEY=~/AuthKey_<id>.p8
# Build number is the UTC timestamp so every upload is unique. Nothing here is committed.
ASC_KEY_ID   ?=
ASC_ISSUER_ID ?=
ASC_KEY      ?=
BUILD_NUMBER  = $(shell date -u +%Y%m%d%H%M)

testflight: project
	@test -n "$(TEAM)" && test -n "$(ASC_KEY_ID)" && test -n "$(ASC_ISSUER_ID)" && test -f "$(ASC_KEY)" \
		|| { echo "Usage: make testflight TEAM=... ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY=path/to/AuthKey.p8"; exit 1; }
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) -destination "generic/platform=iOS" \
		-archivePath build/OpenWaze.xcarchive -allowProvisioningUpdates \
		-authenticationKeyPath "$(abspath $(ASC_KEY))" -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID) \
		DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n<key>method</key><string>app-store-connect</string>\n<key>destination</key><string>upload</string>\n<key>teamID</key><string>$(TEAM)</string>\n</dict></plist>\n' > build/ExportOptions.plist
	xcodebuild -exportArchive -archivePath build/OpenWaze.xcarchive -exportOptionsPlist build/ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates \
		-authenticationKeyPath "$(abspath $(ASC_KEY))" -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
	@echo "Uploaded build $(BUILD_NUMBER). It appears in App Store Connect > TestFlight after processing (5-15 min)."
