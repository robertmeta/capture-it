# 0012. Enroll confirmed voices for post-session recognition

- Status: Accepted
- Date: 2026-11-25
- Decided by: capture-it maintainers

## Context

The diarizer assigns fresh speaker IDs every run. A listener who recognizes
a voice wants to name all its turns and reuse that name across recordings.

## Decision

A manual assignment confirms one speaker within one analysis. Sample several
isolated intervals, store their audio and model-specific embeddings together
on the Mac, and group confirmed examples by the full name the listener enters.
Use the existing local FluidAudio models and compare future cluster embeddings
against those examples. Keep the speaker IDs and record whether each name was
assigned by the listener or matched by voice.

## Alternatives considered

Reusing IDs across sessions would conflate unrelated people. Enrolling every
automatic prediction would let a mistaken name influence subsequent calls.

## Consequences

Corrections can relabel the original enrollment. Uncertain speakers can stay
anonymous. Capture and live transcription keep their existing timing.
