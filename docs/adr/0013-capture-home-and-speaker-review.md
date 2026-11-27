# 0013. Review unmatched voices after saving in a capture home

- Status: Accepted
- Date: 2026-11-25
- Decided by: capture-it maintainers

## Context

Recordings and speaker enrollment need a predictable location. A listener
should be able to stop work once audio is saved and return to naming later.

## Decision

Use Documents/capture-it as the default home for recordings and new voice
libraries. An explicit home takes precedence over CAPTURE_IT_HOME. Preserve
explicit session and library paths and existing default enrollments.

After a recording or a hooks retry, the CLI offers the completed FluidAudio
analysis to a separate foreground review after hook processing. The helper
plays an isolated example and asks for a name only for unmatched speakers.
Each confirmed assignment persists immediately and review can resume by run ID.

## Alternatives considered

Prompting from the analysis hook would tie human input to a timed process
with redirected stdin and private logs. A foreground dialogue can take as
long as the listener needs and can be cancelled independently.

## Consequences

Unattended recordings still complete without human input. The capture path,
WAV and transcript formats, and model cache work independently of the review.
