# 0004. Resolve app names and patterns to one selected process

- Status: Accepted
- Date: 2026-11-17
- Decided by: User request for app wildcard matching and a picker

## Context

Recording Teams should accept a short name rather than require a bundle ID.
Audio process lists contain helpers that should not appear as separate apps.
An ambiguous name must never cause capture to include all matching apps.

## Decision

Match --app against running main application names and bundle IDs using a
case-insensitive substring, or a quoted * / ? wildcard. Exact bundle IDs take
priority. Exclude prohibited/background and embedded helper applications from
the selection list while retaining separate running instances.

Auto-select one match. For several, show a numbered name/bundle/PID picker on
stderr and read a choice from interactive stdin. Retry invalid numbers and
allow q/EOF cancellation. Noninteractive ambiguity fails with a useful list.
Resolve before creating output or requesting capture permissions.

Bind the chosen bundle ID and PID to native capture, revalidate it before
starting, and record the selected PID in the session manifest. If that process
exits, report failure rather than selecting a replacement or broadening capture.

## Alternatives considered

Requiring bundle IDs adds discovery steps to every invocation. Picking the
first ambiguous result risks recording the wrong app. Treating audio helpers
as applications makes ordinary Teams selection unnecessarily ambiguous.
Adding a selection dependency is unnecessary for a numbered terminal prompt.

## Consequences

Shell scripts need an unambiguous identifier. App discovery includes foreground
and accessory applications; audio still must be available when capture starts.
The recording/transcription worker pipeline and file format are unaffected.
