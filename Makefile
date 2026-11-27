.PHONY: help build install setup test lint verify test-journeys test-native test-speech test-selection test-microphone test-shutdown test-keys test-meetings test-m4a test-hooks test-title build-fluid setup-fluid test-fluid test-fluid-installed test-ai audit-public

BINDIR ?= $(HOME)/bin
# Fixture checks never invoke a configured model provider.
export CAPTURE_IT_AI = off

help:
	@echo 'build          Build and ad-hoc sign the release CLI'
	@echo 'install        Build and install to ~/bin (override BINDIR=...)'
	@echo 'setup          Install CLI and FluidAudio hook/models; enables automatic labels'
	@echo 'test           Run queue, WAV and transcript concurrency tests'
	@echo 'lint           Compile with warnings treated as errors'
	@echo 'test-journeys  Exercise CLI discovery and error handling'
	@echo 'test-native    Record a controlled tone app + real mic (macOS prompts)'
	@echo 'test-speech    Verify real local speech, tee and live WAV (installed assets)'
	@echo 'test-selection Verify real app wildcard/interactive selection and WAV'
	@echo 'test-microphone Check real active app mic inference and explicit override'
	@echo 'test-shutdown   Check double Ctrl-C preserves WAV and partial transcript'
	@echo 'test-keys       Real terminal q, repeated q, Ctrl-C, Escape and restoration'
	@echo 'test-m4a        Import M4A/WAV, replay and label audio with local speech and FluidAudio'
	@echo 'test-meetings   Rotate real multi-app audio while hooks run and apps relaunch'
	@echo 'test-ai         AI suggestions, review and enrollment with real local voices'
	@echo 'test-hooks      Real capture + local hooks, failure, timeout and cancellation'
	@echo 'test-title      Real selected-app Accessibility title, override and hook metadata'
	@echo 'setup-fluid     Download/build/install FluidAudio hook and offline models'
	@echo 'test-fluid      Real offline diarization through hooks (requires setup-fluid)'
	@echo 'test-fluid-installed Verify automatic installed hook, offline inference and cancellation'
	@echo 'audit-public    Offline tracked-file/history/ignore audit (requires Gitleaks)'
	@echo 'verify         Build, tests, lint and CLI journeys'

build:
	swift build -c release
	codesign --force --sign - --identifier com.robertmeta.capture-it .build/release/capture-it

install: build
	mkdir -p "$(BINDIR)"
	install -m 755 .build/release/capture-it "$(BINDIR)/capture-it"
	install -m 755 hooks/ai-enrich.py "$(BINDIR)/capture-it-ai"
	@printf 'Installed %s\n' "$(BINDIR)/capture-it"

setup: install setup-fluid

test:
	swift test

lint:
	swift build -Xswiftc -warnings-as-errors

test-journeys: build
	python3 scripts/journey.py .build/release/capture-it
	python3 scripts/ai_journey.py .build/release/capture-it

test-native: build
	python3 scripts/native_journey.py .build/release/capture-it

test-speech: build
	python3 scripts/speech_journey.py .build/release/capture-it

test-shutdown: build
	python3 scripts/shutdown_journey.py .build/release/capture-it

test-m4a: build
	python3 scripts/m4a_journey.py .build/release/capture-it

test-meetings: build
	python3 scripts/meeting_journey.py .build/release/capture-it

test-keys: build
	python3 scripts/quit_key_journey.py .build/release/capture-it

test-selection: build
	python3 scripts/selection_journey.py .build/release/capture-it

test-microphone: build
	python3 scripts/microphone_journey.py .build/release/capture-it

test-hooks: build
	python3 scripts/hooks_journey.py .build/release/capture-it

test-title: build
	python3 scripts/title_journey.py .build/release/capture-it

verify: test lint test-journeys

# Optional hook setup: these targets explicitly fetch third-party code/models.
build-fluid:
	swift build --package-path hooks/fluid-audio -c release
	codesign --force --sign - --identifier com.robertmeta.capture-it.fluid hooks/fluid-audio/.build/release/capture-it-fluid

setup-fluid: build-fluid
	python3 scripts/setup_fluid.py
	./hooks/fluidaudio --check
	mkdir -p "$(BINDIR)/.capture-it-fluid"
	install -m 755 hooks/fluid-audio/.build/release/capture-it-fluid "$(BINDIR)/.capture-it-fluid/capture-it-fluid"
	install -m 644 LICENSE "$(BINDIR)/.capture-it-fluid/LICENSE.capture-it"
	install -m 644 hooks/fluid-audio/.build/checkouts/FluidAudio/LICENSE "$(BINDIR)/.capture-it-fluid/LICENSE.FluidAudio"
	ditto hooks/fluid-audio/.build/checkouts/FluidAudio/ThirdPartyLicenses "$(BINDIR)/.capture-it-fluid/ThirdPartyLicenses"
	@set -eu; for bundle in hooks/fluid-audio/.build/release/*.bundle; do \
		[ -d "$$bundle" ] || continue; \
		ditto "$$bundle" "$(BINDIR)/.capture-it-fluid/$$(basename "$$bundle")"; \
	done
	install -m 755 hooks/fluidaudio "$(BINDIR)/capture-it-fluid"
	"$(BINDIR)/capture-it-fluid" --check
	@echo 'FluidAudio installed. Record with capture-it teams; labels run after saving. Use --no-fluid to skip.'

test-ai: build
	python3 scripts/ai_journey.py .build/release/capture-it --fluid

test-fluid: build
	python3 scripts/fluid_journey.py .build/release/capture-it

test-fluid-installed:
	python3 scripts/fluid_journey.py "$(BINDIR)/capture-it" --installed

audit-public:
	python3 scripts/audit_public.py
