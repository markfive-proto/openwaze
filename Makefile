PROJECT := OpenWaze.xcodeproj
SCHEME  := OpenWaze
# First available iPhone simulator, by UDID, so no device name is hardcoded.
SIM_LINE = $(shell xcrun simctl list devices available | grep -m1 -E "^ +iPhone")
SIM_ID   = $(shell echo "$(SIM_LINE)" | grep -oE "[0-9A-F-]{36}")
SIM_NAME = $(shell echo "$(SIM_LINE)" | sed -E "s/^ *//; s/ *[(].*[)] *$$//")

.PHONY: bootstrap project test lint

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
