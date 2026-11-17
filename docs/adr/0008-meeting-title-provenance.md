# 0008. Best-effort selected-app Accessibility title with explicit provenance

- Status: Accepted
- Date: 2026-11-18
- Decided by: User request for meeting titles and willingness to grant Accessibility

## Context

Meeting titles improve agent-generated notes. A window title is useful local
evidence, but may describe a chat or unrelated browser tab. Reading metadata
must not interrupt dependable audio recording or silently claim a verified subject.

## Decision

Read only the selected PID's window titles on an independent serial worker.
Bound AX messages to 150 ms each, inspect at most eight windows and sample every
two seconds. Do not traverse contents or perform actions. Use existing trust
without a prompt; setup-accessibility explicitly requests access and doctor
reports trust. Recording continues when metadata is unavailable.

Store one distinct non-generic title as an unverified candidate, including its
raw sanitized window title and source. Generic, absent and ambiguous evidence
cannot create a title. An explicit --title overrides AX and is marked as user
provided. Persist the meeting object in the manifest and post-session hook event.
Keep search-based folder naming unchanged.

## Consequences

No accounts, calendar access, provider dependencies or network calls are needed.
App/version behavior and UI choices limit automatic title quality; a dedicated
app adapter would be required for stronger meeting-specific evidence. This
feature does not implement speaker-name observation or diarization.
