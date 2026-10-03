SCHEME := MagicBoxie
PROJECT := MagicBoxie.xcodeproj
BUNDLE_ID := com.alexv.magicboxie.app
DERIVED_DATA := build
SIMULATOR_NAME ?= iPhone 17 Pro
DEVICE ?=

.PHONY: all setup dev build publish clean _resign

all: setup dev

# Install/verify tooling and (re)generate the .xcodeproj from project.yml.
setup:
	@command -v xcodegen >/dev/null || { echo "xcodegen not found - install with: brew install xcodegen"; exit 1; }
	xcodegen generate

# Build for development and run it in the Simulator.
# xcodebuild/simctl install replace prior build output in place, so there's
# nothing to manually delete between runs.
#
# The Simulator has no real Bluetooth radio, so `xcrun simctl launch` here
# forces direct-API dev mode (hitting the device's HTTP API, e.g. the Docker
# container on this Mac, instead of BLE) - otherwise the app just shows
# "Bluetooth is unavailable". Note this only affects `simctl launch`: the
# Xcode scheme's own environment variables (project.yml) are a separate
# defaults-when-run-from-Xcode setting and don't apply to this path at all.
dev: setup
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME)' \
		-derivedDataPath $(DERIVED_DATA) \
		build
	$(MAKE) _resign
	@if [ -d "$$(xcode-select -p)/Applications/Simulator.app" ]; then \
		open -a "$$(xcode-select -p)/Applications/Simulator.app"; \
	else \
		open -a Simulator || echo "Simulator UI unavailable; continuing with simctl."; \
	fi
	xcrun simctl bootstatus '$(SIMULATOR_NAME)' -b
	xcrun simctl install '$(SIMULATOR_NAME)' \
		"$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(SCHEME).app"
	SIMCTL_CHILD_MAGICBOXIE_DIRECT_API=1 \
	SIMCTL_CHILD_MAGICBOXIE_DEVICE_URL=http://localhost:8000 \
		xcrun simctl launch --terminate-running-process '$(SIMULATOR_NAME)' $(BUNDLE_ID)

# xcodebuild's Simulator code-signing pass silently drops entitlements that
# need a provisioning profile (App Groups, used for the Share Extension
# hand-off) even with a real DEVELOPMENT_TEAM set - it only carries them
# through properly when Xcode itself drives the build/run. Re-signing by hand
# with the same (already-generated) entitlements files afterward fixes it for
# our own build+simctl-install path.
_resign:
	codesign --force --sign - \
		--entitlements Sources/MagicBoxieShareExtension/ShareExtension.entitlements \
		"$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(SCHEME).app/PlugIns/MagicBoxieShareExtension.appex"
	codesign --force --sign - \
		--entitlements Sources/MagicBoxie/MagicBoxie.entitlements \
		"$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(SCHEME).app"

# Release-configuration build for the Simulator. Archiving for a physical
# device or the App Store may additionally need entitlements/provisioning
# set up properly in Xcode's Signing & Capabilities beyond what's here.
build: setup
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) \
		build

publish: setup
	@echo "Building production app (Direct API disabled)..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-sdk iphoneos \
		-derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates \
		archive \
		-archivePath $(DERIVED_DATA)/$(SCHEME).xcarchive
	mkdir -p $(DERIVED_DATA)/Publish
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>compileBitcode</key>' \
		'  <false/>' \
		'  <key>method</key>' \
		'  <string>development</string>' \
		'  <key>signingStyle</key>' \
		'  <string>automatic</string>' \
		'  <key>stripSwiftSymbols</key>' \
		'  <true/>' \
		'  <key>thinning</key>' \
		'  <string>&lt;none&gt;</string>' \
		'</dict>' \
		'</plist>' \
	> $(DERIVED_DATA)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(DERIVED_DATA)/$(SCHEME).xcarchive \
		-exportPath $(DERIVED_DATA)/Publish \
		-exportOptionsPlist $(DERIVED_DATA)/ExportOptions.plist
	@echo "Installing on connected device..."
	@if [ -n "$(DEVICE)" ]; then \
		xcrun devicectl device install app --device "$(DEVICE)" \
			"$(DERIVED_DATA)/$(SCHEME).xcarchive/Products/Applications/$(SCHEME).app"; \
	else \
		device_count=$$(xcrun xcdevice list 2>/dev/null | plutil -convert json -o - -- - | \
			/usr/bin/ruby -rjson -e 'devices = JSON.parse(STDIN.read).select { |d| d["platform"] == "com.apple.platform.iphoneos" && d["available"] != false && !d["simulator"] }; puts devices.length'); \
		if [ "$$device_count" -ne 1 ]; then \
			echo "Expected exactly one connected iOS device, found $$device_count."; \
			echo "Run: make publish DEVICE='<device name or identifier>'"; \
			exit 1; \
		fi; \
		device_id=$$(xcrun xcdevice list 2>/dev/null | plutil -convert json -o - -- - | \
			/usr/bin/ruby -rjson -e 'device = JSON.parse(STDIN.read).find { |d| d["platform"] == "com.apple.platform.iphoneos" && d["available"] != false && !d["simulator"] }; puts device["identifier"]'); \
		xcrun devicectl device install app --device "$$device_id" \
			"$(DERIVED_DATA)/$(SCHEME).xcarchive/Products/Applications/$(SCHEME).app"; \
	fi

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	rm -rf $(DERIVED_DATA)
