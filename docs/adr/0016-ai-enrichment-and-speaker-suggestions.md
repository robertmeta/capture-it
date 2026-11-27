# 0016. Enrich saved meetings through AI CLIs and confirm name suggestions

- Status: Accepted
- Date: 2026-11-26
- Decided by: capture-it maintainer, selecting Codex / Sol as the default

## Context

Voice matching recognizes confirmed people, but introductions and addressed
responses can help name unfamiliar voices. Terminal AI clients can analyze
those clues after local transcription and diarization. A wrong inferred name
must not become a reference voice for subsequent recordings.

## Decision

Install a first-party AI executable hook with the CLI. Default to Codex with
gpt-6.2-sol, with explicit adapter/model overrides and --no-ai. Reuse sequential
hooks, durable private artifacts, process-group cancellation and foreground
speaker review. Enrichment may use the configured AI provider; transcript text
is supplied without audio attachments.

Validate structured suggestions against exact cited phrases. Bind proposals to
one analysis run and the source transcript hash. Save evidence and provenance
beside derived notes. Human acceptance uses normal assignment and enrollment.
Persist rejected suggestions without changing voice identities. Preserve original
media/text and uncertain anonymous speaker IDs. Add an enrich command that reuses
saved analyses without repeating transcription or voice analysis.

## Alternatives considered

Automatic name enrollment would spread an inference error across recordings.
An additional plugin framework would duplicate existing hook lifecycle controls.
One unbounded prompt would omit or exceed limits for long recordings.

## Consequences

The installed workflow can use a remote or paid configured provider by default.
Local-only use opts out of AI. Failures retain original capture and allow manual
review or retry. Chunked notes are presented in parts; they are not a second-pass
whole-meeting synthesis. Application rosters and live speaker observation remain
separate future integrations.
