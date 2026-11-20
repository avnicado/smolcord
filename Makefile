# smolcord
#
# Phase 0 (the data-budget gate) runs anywhere Python 3.7+ runs, including
# Linux. Everything from Phase 1 on needs a Mac with Xcode.

PY ?= python3
XCODEGEN ?= xcodegen
SCHEME ?= smolcord
DESTINATION ?= 'platform=iOS Simulator,name=iPhone SE (3rd generation)'

.PHONY: help
help:
	@echo "smolcord"
	@echo
	@echo "  no Mac needed:"
	@echo "    make smoke        connect to the gateway, read HELLO, no token"
	@echo "    make probe        settle the op 37 question (needs DISCORD_TOKEN)"
	@echo "    make probe-patient  same, but waits 20 min for quiet guilds"
	@echo "    make probe-cached lever 3: does guild_versions shrink READY?"
	@echo "    make scan         break down the saved READY fixture, offline"
	@echo "    make test-py      offline transport and verdict tests"
	@echo "    make swift-test   run the 40 portable Swift tests (needs swift)"
	@echo
	@echo "  Mac only:"
	@echo "    make project      regenerate smolcord.xcodeproj from project.yml"
	@echo "    make build        build for the simulator"
	@echo "    make test         run the Swift test bundle"
	@echo "    make device       build and install on a connected device"

# ---------------------------------------------------------------- Phase 0

.PHONY: smoke
smoke:
	$(PY) -I tools/gwprobe.py --smoke

.PHONY: probe
probe:
	@test -n "$$DISCORD_TOKEN" || (echo "set DISCORD_TOKEN first"; exit 1)
	$(PY) -I tools/gwprobe.py

# For an account whose servers are quiet. The probe needs to see real guild
# traffic in the control arm, or it reports INCONCLUSIVE rather than a pass.
# Lever 3. After the first probe run this became the highest-value
# measurement: a fresh IDENTIFY costs about 131KB, and `guilds` is 84% of it.
.PHONY: probe-cached
probe-cached:
	@test -n "$$DISCORD_TOKEN" || (echo "set DISCORD_TOKEN first"; exit 1)
	$(PY) -I tools/gwprobe.py --cached-identify

# Offline. Needs only the fixture the probe already saved.
.PHONY: scan
scan:
	$(PY) -I tools/readyscan.py

.PHONY: probe-patient
probe-patient:
	@test -n "$$DISCORD_TOKEN" || (echo "set DISCORD_TOKEN first"; exit 1)
	$(PY) -I tools/gwprobe.py --cap-minutes 20

# The portable Swift subset, via Package.swift. Needs a Swift toolchain but no
# Mac: it covers wire-format parsing, byte accounting, the on-disk format and
# text layout. It cannot touch UIKit, Network or Security, so a green run here
# does NOT mean the app builds.
.PHONY: swift-test
swift-test:
	swift test

.PHONY: swift-build
swift-build:
	swift build

.PHONY: test-py
test-py:
	$(PY) -I Tests/test_gwlib.py
	@echo
	$(PY) -I Tests/test_verdict.py

# ---------------------------------------------------------------- Mac only

.PHONY: project
project:
	$(XCODEGEN) generate

.PHONY: build
build: project
	xcodebuild -scheme $(SCHEME) -destination $(DESTINATION) build

.PHONY: test
test: project
	xcodebuild -scheme $(SCHEME) -destination $(DESTINATION) test

.PHONY: device
device: project
	xcodebuild -scheme $(SCHEME) -destination 'generic/platform=iOS' \
		-configuration Debug build

.PHONY: clean
clean:
	rm -rf build DerivedData smolcord.xcodeproj
	rm -f tools/fixtures/*.json
