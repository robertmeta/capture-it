# 0009. FluidAudio offline diarization as a separate optional hook

- Status: Accepted
- Date: 2026-11-18
- Decided by: User selected post-recording labeling and FluidAudio as the first hook

## Context

Post-recording speaker labeling should exercise the generic hook boundary,
preserve dependable capture and avoid changing the live speech engine. Phrase
timestamps do not support reliable splitting of words between speakers.

## Decision

Provide hooks/fluidaudio backed by a separate pinned Swift package using the
offline Community-1/VBx pipeline. Keep FluidAudio out of the core dependency
graph. Share only the model-free artifact, audio-preparation and attribution
code with core verification. Enable only the upstream Diarizer package trait.

Setup explicitly downloads selected pinned model assets with integrity checks
and license/provenance retention. Runtime verifies local assets and initializes
the pipeline from local MLModels, bypassing automatic download/fallback APIs.
Use the existing audio downmix and file-based analysis. Keep original artifacts
unchanged; write anonymous turns, RTTM and conservative phrase labels to the
private hook output directory. Mixed or poorly covered phrases stay uncertain.

## Consequences

The generic runner supplies ordering, timeout, cancellation and isolated logs.
No new provider framework, live processing or participant-name guesses are
needed. Model setup is optional and separate from normal build/verification.
The actual model journey must pass before claiming working diarization; unit
tests alone establish only mix/attribution behavior, not model accuracy.
