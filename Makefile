PROJECT := OpenWaze.xcodeproj
SCHEME  := OpenWaze
# First available iPhone simulator, by UDID, so no device name is hardcoded.
SIM_ID   = $(shell xcrun simctl list devices available | grep -m1 -E "^ +iPhone" | grep -oE "[0-9A-F-]{36}")

.PHONY: bootstrap project test lint

bootstrap:
	brew bundle
	$(MAKE) project

project:
	xcodegen generate

test: project
	@test -n "$(SIM_ID)" || { echo "No available iPhone simulator; install one in Xcode > Settings > Components."; exit 1; }
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination "id=$(SIM_ID)" -derivedDataPath build

lint:
	swiftlint lint --strict
	swiftformat --lint App
