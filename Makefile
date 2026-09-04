EXEC     := Murmur
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MurmurBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MurmurBuild
APPNAME  := Murmur.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## The single source of truth for the version is CFBundleShortVersionString in
## Resources/Info.plist. `./release.sh` bumps it; the release workflow reads it back and
## releases whatever has no tag yet. Nothing else stores a version number, because two
## places storing it is how a DMG ends up named after a version it does not contain.
VERSION  := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

## CFBundleVersion is the build number, not the marketing version. CI passes the workflow
## run number; a local build gets 1, which is what the checked-in plist already says.
BUILD_NUMBER ?= 1

## Deliberately NOT versioned in the filename. The website links to
## /releases/latest/download/Murmur-arm64.dmg, which only resolves if the asset name is
## the same in every release. The version lives in the volume name and in the app.
DMG      := $(STAGE)/Murmur-arm64.dmg
DMGROOT  := $(STAGE)/dmgroot

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build test vectors app dmg run install clean icon print-dmg print-app

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## The two cross-platform contracts — the dictionary and the structure pass — using the
## same vectors the Windows side runs. `VectorTests` matches both suites. Goes through the
## shared scratch path for the same reason everything else does: a bare `swift test`
## writes .build into the iCloud-synced tree and reintroduces the mid-compile mutation
## race this Makefile exists to avoid.
test: vectors
	@swift test --filter VectorTests --scratch-path "$(SCRATCH)"

## The test bundles read their own copy of the vectors, so an edit to shared/ that isn't
## copied across passes locally and fails in CI. This copies them.
vectors:
	@cp shared/dictionary-test-vectors.json Tests/MurmurDictionaryTests/
	@cp shared/formatting-test-vectors.json Tests/MurmurFormattingTests/

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@# The marketing version is already correct in the checked-in plist; only the build
	@# number is stamped, so a CI build is traceable to the run that produced it.
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## The distributable. A plain UDZO image containing the .app and a symlink to
## /Applications, which is the drag-to-install window everyone already knows.
##
## Built from $(STAGE), never from this directory — the same iCloud reason as the bundle:
## hdiutil reads every byte of the source folder, and a file-provider dematerializing one
## mid-read produces a corrupt image rather than an error.
dmg: app
	@rm -rf "$(DMGROOT)" "$(DMG)"
	@mkdir -p "$(DMGROOT)"
	@cp -R "$(BUNDLE)" "$(DMGROOT)/$(APPNAME)"
	@ln -s /Applications "$(DMGROOT)/Applications"
	@hdiutil create \
		-volname "Murmur $(VERSION)" \
		-srcfolder "$(DMGROOT)" \
		-ov -format UDZO -quiet \
		"$(DMG)"
	@rm -rf "$(DMGROOT)"
	@echo "built $(DMG)  [version: $(VERSION), build: $(BUILD_NUMBER)]"

## So CI never hardcodes the staging path. `make -s print-dmg` and `make -s print-app`
## are the only places the workflow learns where anything landed.
print-dmg:
	@echo "$(DMG)"

print-app:
	@echo "$(BUNDLE)"

## `pkill -x $(EXEC)` matches any binary named Murmur, including one belonging to a
## different app. That was impossible under the old MurmurYouTube name.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
