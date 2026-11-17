.PHONY: help build test lint verify test-journeys test-native test-speech test-selection test-microphone test-shutdown test-hooks test-title build-fluid setup-fluid test-fluid audit-public

help:
	@echo 'build          Build and ad-hoc sign the release CLI'
	@echo 'test           Run queue, WAV and transcript concurrency tests'
	@echo 'lint           Compile with warnings treated as errors'
	@echo 'test-journeys  Exercise CLI discovery and error handling'
	@echo 'test-native    Record a controlled tone app + real mic (macOS prompts)'
	@echo 'test-speech    Verify real local speech, tee and live WAV (installed assets)'
	@echo 'test-selection Verify real app wildcard/interactive selection and WAV'
	@echo 'test-microphone Check real active app mic inference and explicit override'
	@echo 'test-shutdown   Check double Ctrl-C preserves WAV and partial transcript'
	@echo 'test-hooks      Real capture + local hooks, failure, timeout and cancellation'
	@echo 'test-title      Real selected-app Accessibility title, override and hook metadata'
	@echo 'setup-fluid     Explicitly download/build optional FluidAudio hook and models'
	@echo 'test-fluid      Real offline diarization through hooks (requires setup-fluid)'
	@echo 'audit-public    Offline tracked-file/history/ignore audit (requires Gitleaks)'
	@echo 'verify         Build, tests, lint and CLI journeys'

build:
	swift build -c release
	codesign --force --sign - --identifier com.robertmeta.capture-it .build/release/capture-it

test:
	swift test

lint:
	swift build -Xswiftc -warnings-as-errors

test-journeys: build
	python3 scripts/journey.py .build/release/capture-it

test-native: build
	python3 scripts/native_journey.py .build/release/capture-it

test-speech: build
	python3 scripts/speech_journey.py .build/release/capture-it

test-shutdown: build
	python3 scripts/shutdown_journey.py .build/release/capture-it

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

setup-fluid: build-fluid
	python3 scripts/setup_fluid.py
	./hooks/fluidaudio --check

test-fluid: build
	python3 scripts/fluid_journey.py .build/release/capture-it

audit-public:
	python3 scripts/audit_public.py
