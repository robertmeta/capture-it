# AI enrichment and speaker suggestions

The installed CLI saves audio and transcribes locally, runs FluidAudio to label
and match voices, then runs AI enrichment through **Codex / `gpt-6.2-sol`**.
The AI reads transcript text and returns suggested names, a proposed meeting
title, a summary, decisions, action items and open questions. It does not receive
audio attachments. Its configured provider may be remote or paid.

`make install` installs `capture-it-ai` beside the CLI. Python 3 and an installed,
authenticated Codex CLI must be available to run enrichment. `make setup` also
installs FluidAudio and its local models. Capture and saved audio do not depend
on the AI succeeding. A missing CLI, invalid response, timeout or cancellation
leaves the recording and prior processing intact, with details in private hook
logs. A processing failure returns exit 2. No transcript means no AI request.

```sh
capture-it teams slack                      # Codex / Sol after each saved meeting
capture-it teams slack --no-ai              # built-in processing stays local
capture-it teams --ai-model gpt-6.2-sol
CAPTURE_IT_AI=off capture-it teams slack    # persistent opt-out via your environment
```

Use `CAPTURE_IT_AGENT_BIN=/absolute/path/to/codex` to select an executable.
The resolver skips wrappers that inject permission-bypass flags; point overrides
at the actual CLI executable. `CAPTURE_IT_AI_MODEL` changes the default model. `--ai codex|claude|agy` selects
another supported CLI adapter; the latter two use their own configured model
unless you supply `--ai-model`. `CAPTURE_IT_AI` selects the default adapter or
`off`. Explicit command options take precedence. Core builds without the
installed AI helper do not discover it automatically; explicit AI requests
require `make install`.

## Saved recordings

Enrich an existing meeting without repeating transcription or FluidAudio:

```sh
capture-it enrich ~/Documents/capture-it/recordings/teams-slack-2026-11-25-01
capture-it enrich ./my-call --run UUID/001 --no-review
capture-it speakers ./my-call --run UUID/001
```

`enrich` reuses the unique completed speaker analysis. If there are several, it
lists the choices and requires `--run`. With no analysis, it produces notes from
the saved transcript and no speaker-name suggestions. To regenerate speech or
diarization first, use `transcribe` or `hooks`. `hooks --transcript DIRECTORY`
can analyze a replacement transcript before enrichment. Merely upgrading does
not process existing recordings.

## Review and memory

Press **n** while recording to start the next meeting and process the previous
one in the background. Press **q** to save and finish. After processing, a
foreground terminal reviews unmatched voices in each meeting. Each suggestion
shows the proposed name, confidence, reason and exact timestamped quotations.
Multiple candidates remain separate suggestions. A mentioned name is only a
clue; it does not establish that the person speaking has that name.

- Type `:accept 1` to confirm suggestion 1. `:accept` also works for a sole suggestion.
- Type a name to replace a proposal.
- Type `:reject` to dismiss the displayed proposals, then name or skip the voice.
- Press Enter to skip, or use `:quit` / Ctrl-C to finish and resume later.

Confirmation assigns the name to every turn with that speaker ID in the selected
analysis. The derived text transcript is regenerated. Up to three isolated
2–8 second voice clips and their local embeddings are saved for future matches.
Without two seconds of isolated speech, assignment still applies to this
recording and the CLI explains why enrollment was unavailable. Confirming the
same person in another recording adds more examples. AI suggestions never enroll
voices or replace confirmed identities automatically. Voice matches also do not
enroll more samples automatically.

The original transcript and audio remain intact. JSONL retains anonymous speaker
IDs and the original phrases; `speaker-identities.json` maps IDs to confirmed or
voice-matched names. Rejections persist for that exact suggestion and analysis.
`--no-review` keeps processing and skips prompts. A noninteractive invocation
always leaves review for later.

## Artifacts and hooks

AI enrichment uses the existing sequential executable-hook contract. It follows
FluidAudio and precedes ordinary explicit hooks, which can consume its results.
It writes to its own `SESSION/hooks/UUID/NNN/` output directory:

| File | Contents |
| --- | --- |
| `speaker-suggestions.jsonl` | Unconfirmed names, stable suggestion IDs, analysis run, confidence, reasons, evidence and agent/model provenance |
| `meeting-notes.json` | Structured note parts with proposed titles, summaries, decisions, action items and questions |
| `notes.md` | Proposed meeting title, summary, decisions, action items and open questions |
| `response-NNNN.json` | Each AI response, including a malformed response when validation fails |
| `enrichment.json` | Completion marker, selected analysis, configured agent/model, timestamp, source hash and counts |

Long transcripts are processed in chunks of up to 40,000 serialized characters
with nearby phrase overlap. Notes are retained by part rather than making a
second whole-meeting request. A single oversized phrase fails explicitly. Names
must occur in exact cited quotations, and evidence must include a phrase
unambiguously attributed to the proposed voice. These checks establish evidence
provenance; the human reviewer still decides whether the inference is correct.
Only completed hook results with matching analysis and transcript hashes are
offered during review. Old, partial and stale outputs are preserved but ignored.

Codex runs in noninteractive, ephemeral, read-only mode from a temporary directory
with a JSON output schema. The other adapters use their existing print modes.
Transcript text is quoted as untrusted data and never interpreted as commands.
The ordinary hook timeout and process-group cancellation cover the AI and its
children. These are trusted executables, not a filesystem sandbox for arbitrary
hooks. Your AI CLI's provider, authentication and configuration still apply.

Find completed output paths through `hooks/*/result.json` before using them in
automation. For example, with `AI_OUTPUT` set to one completed output directory:

```sh
jq -s 'group_by(.speaker) | map({speaker: .[0].speaker, names: map(.name) | unique})' \
  "$AI_OUTPUT/speaker-suggestions.jsonl"
jq -c 'select(.confidence == "high") | {speaker, name, evidence}' \
  "$AI_OUTPUT/speaker-suggestions.jsonl"
```

`make verify` tests the AI contract using a deterministic local CLI, without a
provider request. After building the FluidAudio helper, `make test-ai` exercises
real local diarization, M4A review, rejection, confirmation, persistence,
enrollment and future matching with synthetic voices. Provider inference and
authentication are separate from these fixture checks.
