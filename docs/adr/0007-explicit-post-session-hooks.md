# 0007. Explicit executable hooks after saved-session finalization

- Status: Accepted
- Date: 2026-11-18
- Decided by: User request for terminal-agent processing of WAV and transcripts

## Context

Users want terminal agents or audio tools to do additional work on recordings.
Agent command lines, model providers and audio capabilities differ. Capture
must remain dependable when analysis fails, takes too long or needs a retry.

## Decision

Accept repeated --hook EXECUTABLE options for record and transcribe, plus a
standalone hooks command for existing sessions. No hook runs implicitly. Launch
executable files directly with a versioned event-file argument and absolute
artifact paths. Use optional transcript fields for audio-only or partial sessions.
Select a retried transcript through --transcript DIRECTORY on the standalone path.

Run hooks sequentially after WAV closure and transcript finalization attempt.
Give each a private output directory, stdout/stderr files, process group and
per-executable timeout. Persist result status independently of capture files.
Failure/timeout permits the next hook; interruption stops the group and skips
remaining hooks. Preserve audio-first Ctrl-C semantics. No daemon or shell
command-string evaluation is involved.

## Consequences

Agent behavior stays in explicit scripts instead of provider-specific core
integrations. The core needs no dependencies or model calls. Hooks have the
user's ordinary permissions; they are not sandboxed. Model/data authorization
belongs to the explicitly selected hook and provider. A hook should write derived
artifacts rather than edit the source files.

Speaker diarization and identity attribution are separate enrichment tasks.
The handoff supplies audio and text but does not promise participant names or
native audio support in a coding agent. App-specific speaker adapters require
separate verified capabilities and authorization.
