# Only if the caller hasn't already chosen a toolchain (`$DEVELOPER_DIR`, or
# `sudo xcode-select -s`) and the standard path actually exists - exporting a
# path that isn't there breaks every target with `xcrun: missing DEVELOPER_DIR`
# on a machine that only has the Command Line Tools installed.
ifeq (,$(DEVELOPER_DIR))
ifneq (,$(wildcard /Applications/Xcode.app/Contents/Developer))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

PROJECT := Notchd.xcodeproj
SCHEME  := Notchd
DEST    := platform=macOS,arch=arm64

# Which identity Debug builds are signed with, most preferred first:
#
#   1. Developer ID Application - project.yml's own setting, left alone.
#   2. Apple Development - any local development certificate.
#   3. Ad-hoc, when the machine has no certificate at all.
#
# The order exists for one reason, and it is not cosmetic. The keychain ACL
# remembers *which signed binary* was granted access to Claude Code's
# credentials, and an ad-hoc signature has no identity beyond its own code
# hash - which changes on every single build. Signing ad-hoc therefore
# discards the "Always Allow" grant on each rebuild and brings the keychain
# password prompt back every time. Any real certificate is stable across
# rebuilds, so the grant is given once and then survives.
#
# Ad-hoc remains the last resort rather than an error: it still builds, still
# tests, and still runs, per CONTRIBUTING.md. It just cannot keep the grant.
DEV_ID_CERT   := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
APPLE_DEV_CERT := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')

ifneq (,$(DEV_ID_CERT))
DEV_SIGN :=
else ifneq (,$(APPLE_DEV_CERT))
# DEVELOPMENT_TEAM has to be passed too: the identity and the team must agree
# or codesign refuses the pair. The team is the certificate's OU, read from the
# certificate itself - *not* the parenthesised suffix of its common name, which
# looks like a team id, is not one, and fails with "No certificate for team ...
# matching ..." that names the very certificate it was asked to use.
APPLE_DEV_TEAM := $(shell security find-certificate -c "$(APPLE_DEV_CERT)" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | tr ',' '\n' | sed -nE 's/.*OU=([A-Za-z0-9]+).*/\1/p' | head -1)
DEV_SIGN := CODE_SIGN_IDENTITY="$(APPLE_DEV_CERT)" DEVELOPMENT_TEAM="$(APPLE_DEV_TEAM)" CODE_SIGN_STYLE=Manual
else
DEV_SIGN := CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic
endif

.PHONY: signing
signing:
	@echo "Debug builds sign as: $(if $(DEV_ID_CERT),$(DEV_ID_CERT) (project.yml default),$(if $(APPLE_DEV_CERT),$(APPLE_DEV_CERT),ad-hoc (no stable identity for update signing)))"

.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) build

# `make test ONLY=NotchdTests/SomeSuite` runs one suite or one test.
ONLY ?=
test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) $(if $(ONLY),-only-testing:$(ONLY),) test

# Retried, because `open` can answer -600 (procNotFound) on a bundle the build
# has just rewritten. A test build injects XCTest frameworks into the app host;
# the next plain build strips them and re-registers with LaunchServices, and an
# open racing that registration fails. It is transient and a second attempt a
# moment later succeeds.
run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Notchd.app; \
	pkill -x Notchd 2>/dev/null || true; \
	for _ in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -x Notchd >/dev/null 2>&1 || break; sleep 0.1; \
	done; \
	for attempt in 1 2 3; do \
		if open "$$APP" 2>/dev/null; then exit 0; fi; \
		sleep 0.6; \
	done; \
	echo "could not launch $$APP"; exit 1

clean:
	rm -rf build DerivedData $(PROJECT)

# --- Local disk image ---------------------------------------------------------
# A drag-to-Applications dmg from a Release build signed with whatever identity
# this machine has, which may be ad-hoc. It needs no Developer ID certificate
# and no notary credentials, so anyone who can build the app can package it.
#
# What it is not: notarized. Gatekeeper will say Apple could not verify the
# app on first launch. The person installing clicks Open Anyway in System
# Settings > Privacy & Security once, or removes the quarantine flag:
#
#   xattr -dr com.apple.quarantine /Applications/Notchd.app
#
# `make dmg` is the signed and notarized path, and needs the maintainer's
# Developer ID certificate.

LOCAL_DIR := build/local
LOCAL_DMG  = $(LOCAL_DIR)/$(APP_NAME).dmg

.PHONY: dmg-local
dmg-local: gen
	rm -rf $(LOCAL_DIR)
	mkdir -p $(LOCAL_DIR)/stage
	@touch build/.metadata_never_index
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release $(DEV_SIGN) \
		CONFIGURATION_BUILD_DIR=$(CURDIR)/$(LOCAL_DIR)/products build
	cp -R $(LOCAL_DIR)/products/$(APP_NAME).app $(LOCAL_DIR)/stage/
	ln -s /Applications $(LOCAL_DIR)/stage/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(LOCAL_DIR)/stage \
		-ov -format UDZO $(LOCAL_DMG)
	rm -rf $(LOCAL_DIR)/stage $(LOCAL_DIR)/products
	@echo "Wrote $(LOCAL_DMG)"

# --- Local release ------------------------------------------------------------
# The whole path from source to something an installed copy will update to:
# build the dmg, sign it with the EdDSA key in the login keychain, write the
# appcast, and publish both as a GitHub release tagged with the version.
#
# The app's SUFeedURL points at releases/latest/download/appcast.xml, which
# GitHub resolves to the newest release, so uploading the appcast beside the
# dmg is all it takes for every installed copy to find it.
#
# Needs `gh` signed in, the Sparkle private key (`generate_keys`), and a
# MARKETING_VERSION in project.yml that has not been released yet. Release
# notes come from NOTES=<file>; without one GitHub writes them from commits.

VERSION  := $(shell sed -nE 's/^ *MARKETING_VERSION: "(.*)"/\1/p' project.yml)
TAG       = v$(VERSION)
REPO_URL := https://github.com/MuhammadHananAsghar/notchd
NOTES    ?=

.PHONY: appcast-local release-local
appcast-local: dmg-local
	@test -n "$(SPARKLE_BIN)" || (echo "Sparkle tools not found: run make build first" && exit 1)
	rm -f $(LOCAL_DIR)/appcast.xml
	$(SPARKLE_BIN)/generate_appcast $(LOCAL_DIR) \
		--download-url-prefix $(REPO_URL)/releases/download/$(TAG)/
	@grep -q 'sparkle:edSignature' $(LOCAL_DIR)/appcast.xml \
		|| (echo "appcast has no EdDSA signature: is the private key in the keychain?" && exit 1)
	@echo "Wrote $(LOCAL_DIR)/appcast.xml"

release-local: appcast-local
	gh release create $(TAG) $(LOCAL_DMG) $(LOCAL_DIR)/appcast.xml \
		--title "Notchd $(VERSION)" \
		$(if $(NOTES),--notes-file $(NOTES),--generate-notes)
	@echo "Published $(REPO_URL)/releases/tag/$(TAG)"

# --- Release -----------------------------------------------------------------
# The path to a notarized .dmg. Run `make release` for the whole thing, or the
# steps one at a time while something is going wrong.
#
# One-time setup, which you have to run yourself because it takes a password:
#
#   xcrun notarytool store-credentials Notchd \
#       --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com → Sign-In and Security
# → App-Specific Passwords. Not your Apple ID password.

RELEASE_DIR := build/release
APP_NAME    := Notchd
# The label of the stored notarytool credential in the login keychain. It is
# just a label and need not match the app's name, but no credential is stored
# under it yet - create one with the `store-credentials` line above before
# running `make notarize`, or change this to match a label you already have.
NOTARY_PROFILE := Notchd
DMG := $(RELEASE_DIR)/$(APP_NAME).dmg

.PHONY: archive dmg notarize release verify-release

# Release configuration, exported with the Developer ID identity. `xcodebuild
# archive` + `-exportArchive` rather than a plain build: it re-signs the bundle
# as a distributable, which a Debug build is not.
archive: gen
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	@# Spotlight indexes build output as installed applications, so every
	@# release leaves extra "Notchd" entries in app search next to the
	@# real one in /Applications. This stops the whole tree being indexed.
	@touch build/.metadata_never_index
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive archive
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>developer-id</string>' \
		'<key>teamID</key><string>QRG2QY4242</string>' \
		'<key>signingStyle</key><string>manual</string>' \
		'<key>signingCertificate</key><string>Developer ID Application</string>' \
		'</dict></plist>' > $(RELEASE_DIR)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive \
		-exportOptionsPlist $(RELEASE_DIR)/ExportOptions.plist \
		-exportPath $(RELEASE_DIR)

# A plain drag-to-Applications disk image. `hdiutil` writes it read-only and
# compressed, which is what notarization expects.
dmg: archive
	rm -f $(DMG)
	rm -rf $(RELEASE_DIR)/stage
	mkdir -p $(RELEASE_DIR)/stage
	cp -R $(RELEASE_DIR)/$(APP_NAME).app $(RELEASE_DIR)/stage/
	ln -s /Applications $(RELEASE_DIR)/stage/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(RELEASE_DIR)/stage \
		-ov -format UDZO $(DMG)
	codesign --force --sign "Developer ID Application" --timestamp $(DMG)
	@# The app is inside the dmg now. Leaving the loose copies around is how
	@# three spare "Notchd" entries end up in Spotlight; everything
	@# downstream (notarize, verify, appcast) works from the dmg alone.
	rm -rf $(RELEASE_DIR)/stage $(RELEASE_DIR)/$(APP_NAME).app

# Submits and waits. `--wait` blocks until Apple answers, which is usually a
# couple of minutes; on rejection, the log says which binary failed and why.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)

# Sparkle ships its tools inside the resolved package artifacts.
SPARKLE_BIN = $(shell dirname $$(find $$HOME/Library/Developer/Xcode/DerivedData/Notchd-*/SourcePackages/artifacts/sparkle -name generate_appcast 2>/dev/null | head -1))

# The feed customers' copies poll. Signs each update with the EdDSA private key
# in the login keychain - Sparkle installs nothing that key did not sign, so a
# compromised host cannot push code.
#
# Writes into docs/, which GitHub Pages serves. The dmg goes there too, so the
# URL the appcast advertises is the one the file actually sits at - a mismatch
# is the usual reason an update downloads and then fails to verify.
# NOT docs/ - that holds the design frames and specs, and GitHub Pages serves
# whatever it is pointed at. Publishing from there would put the whole design
# history on the public web alongside the download.
PAGES_DIR := site
# Where the dmg actually sits. The enclosure URL the appcast advertises has to
# match it exactly, or an update downloads and then fails to verify.
DOWNLOAD_PREFIX := https://example.invalid/

appcast: $(DMG)
	@test -n "$(SPARKLE_BIN)" || (echo "Sparkle tools not found: run make build first" && exit 1)
	mkdir -p $(PAGES_DIR)
	@# Rebuilt from what is actually in the folder, never merged into the old
	@# one. The dmg keeps a constant name, so only one build can exist at a
	@# time - but generate_appcast preserves entries it already knows, and left
	@# the previous version advertised at a URL now serving a different file,
	@# with a signature that could never verify.
	rm -f $(PAGES_DIR)/appcast.xml
	cp $(DMG) $(PAGES_DIR)/
	$(SPARKLE_BIN)/generate_appcast $(PAGES_DIR) --download-url-prefix $(DOWNLOAD_PREFIX)
	@echo "Publish by committing $(PAGES_DIR)/ and pushing."

release: notarize verify-release appcast
	@echo "Notarized: $(DMG)"

# What Gatekeeper on a customer's Mac will check. `spctl` accepting the app is
# the actual proof that the download will open without a right-click.
verify-release:
	xcrun stapler validate $(DMG)
	hdiutil attach $(DMG) -nobrowse -mountpoint $(RELEASE_DIR)/mnt
	codesign --verify --deep --strict --verbose=2 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	spctl --assess --type execute --verbose=4 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	hdiutil detach $(RELEASE_DIR)/mnt
