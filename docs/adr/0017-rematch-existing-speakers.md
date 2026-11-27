# 0017. Rematch unnamed speakers using saved turns and frozen references

- Status: Accepted
- Date: 2026-11-27
- Decided by: capture-it maintainer requesting cross-recording identification

## Context

Newly enrolled people can identify anonymous voices in earlier recordings.
Repeating full diarization changes local cluster IDs and discards the opportunity
to retain existing assignments and transcript attribution.

## Decision

Add `speakers --match` to reuse existing isolated turns. Compare up to three
2–8 second clips with compatible local reference embeddings. Keep the existing
0.70 similarity and 0.10 next-person separation. Require a strict majority of
samples to agree, with no conflicting positive name. Leave uncertainty anonymous.

Preserve existing identities and extension metadata. Save matches as voice-match,
regenerate derived text, and persist local model/reference/interval/score evidence.
Never enroll automatically. Record sourceSession for new enrollments and exclude
known target-session references during rematching. Legacy profiles without origin
remain usable. Bulk passes may freeze a provenance-tagged library snapshot.

## Alternatives considered

Full diarization repeats expensive work and generates a new analysis scope.
Matching a clip against its own enrollment overstates cross-recording support.
Lowering thresholds to accommodate name aliases would spread uncertain labels.

## Consequences

The rematch path needs no AI provider request, transcription or new model assets.
Conflicting aliases and voices without isolated speech can remain anonymous.
Existing named speakers keep their assignments. Reports retain query embeddings
locally for audit and comparison; they are private voice data.
