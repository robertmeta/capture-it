# FluidAudio: offline speaker-labeling hook

The optional adapter builds separately from the dependency-free core CLI.
Model-free checks and a real offline multi-voice journey cover its integration;
speaker accuracy still depends on the recording.

This optional hook uses FluidAudio's offline Community-1/VBx pipeline on the
saved audio. It adds anonymous speaker intervals and a derived transcript copy;
the original recording and transcript are retained. Core capture-it still has
no external package dependencies. The hook builds as a separate Swift package.

## Explicit setup

Requires Swift 6.2+ and macOS 26+. Initial setup downloads the pinned
[FluidAudio source](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.3)
from GitHub and selected model assets from
[FluidInference on Hugging Face](https://huggingface.co/FluidInference/speaker-diarization-coreml).
It does not send audio or transcripts.

```sh
make setup                      # install core CLI, helper and models
# Or add FluidAudio to an existing CLI installation:
make setup-fluid
~/bin/capture-it-fluid --check
```

Code is pinned to FluidAudio 0.18.3 with only its Diarizer trait enabled; TTS and
the native text-normalization engine are excluded. The model spec pins an
immutable Hugging Face revision. Setup downloads four compiled Core ML bundles,
PLDA parameters and license/provenance files, verifies source object hashes,
then records SHA-256 checksums. Assets live under
`~/Library/Application Support/capture-it/fluid-models` by default.

Set `CAPTURE_IT_FLUID_MODELS` during setup and hook execution to choose another
location. An existing matching setup is checked rather than downloaded again.
Incomplete, mismatched or corrupted setups fail explicitly; choose a fresh
directory to reinstall. No cached asset directory is silently deleted/replaced.

Both tools install to `~/bin` by default; `BINDIR` overrides the destination.
The helper launcher and `.capture-it-fluid/` runtime directory stay together.
The runtime contains the signed executable and required Swift resource bundles,
plus code license notices, so it works outside the checkout. Keep `CAPTURE_IT_FLUID_MODELS` set at runtime
if you chose a custom model location.

The hook verifies the local asset manifest and loads Core ML models directly.
It does not call FluidAudio's download/fallback APIs. Missing assets fail with
setup instructions while the original audio remains available. `make verify`
does not fetch FluidAudio or models.

## Capture or retry

```sh
capture-it teams
capture-it teams --no-fluid       # skip automatic labels for this recording

# Process an existing session.
capture-it hooks ~/Documents/capture-it/recordings/teams-2026-11-25-01

# Use a retried transcript.
capture-it hooks ~/Documents/capture-it/recordings/teams-2026-11-25-01 --transcript ./retry-text \
  --hook-timeout 900

# Checkout CLI without an installed sibling helper:
.build/release/capture-it teams --hook ./hooks/fluidaudio --hook-timeout 900
```

After setup, the CLI discovers `capture-it-fluid` beside its own executable.
It adds this first-party helper before your explicit hooks. An explicitly
listed copy keeps your chosen order and is not added twice. `--no-fluid`
disables automatic selection, including on `transcribe` and `hooks`; explicit
hooks still run. With FluidAudio installed, the default timeout per hook is
900 seconds; otherwise it is 300. Set `--hook-timeout` to override it.

First Ctrl-C, or `q` in an interactive recording, stops capture, saves the M4A,
finishes speech and then runs hooks. Repeated `q` never interrupts analysis.
An automatic stop follows the same path. Second Ctrl-C skips pending analysis
or terminates a running hook; finalized audio and written text remain available.
Live text is not held back for FluidAudio. The labeled transcript is a separate
post-recording artifact, rather than a rewrite of text already printed.

A later notes hook can read the preceding
result and output directory from `result.json` beside its input JSON. Model
loading and analysis happen after recording, outside the capture workers.

The hook expects capture-it's M4A or WAV audio and prepares an explicit
16 kHz mono mix: `0.25*app-left + 0.25*app-right + 0.5*microphone`. Conversion
uses bounded buffers; FluidAudio processes the derived file through its
disk-backed API. The temporary analysis WAV is removed on normal return or
handled failure. A forced process kill can leave it in the private hook output
directory; it is never a second original recording.

## Artifacts

Each run writes into its normal `SESSION/hooks/UUID/NNN/` directory:

| File | Meaning |
| --- | --- |
| `diarization.json` | Completed analysis: engine, pinned model revision, duration, processing time, speaker IDs, turns, meeting evidence and transcript completion |
| `speaker-identities.json` | Map from recording-local speaker ID to a name and its source (`assigned` or `voice-match`). Unrecognized speakers have no entry. |
| `diarization.rttm` | Standard speaker intervals, in seconds from recording start |
| `speaker-transcript.jsonl` | Original phrases plus overlapping speaker IDs, coverage and attribution status; created when source JSONL exists |
| `speaker-transcript.txt` | Readable speaker-labeled copy, preserving original words and phrase times |
| `stdout.log`, `stderr.log` | Existing hook-runner logs |

Speaker intervals are trimmed to the source duration so padded model windows
cannot export timestamps beyond the audio. A meeting with no detected speech
produces an empty speaker and turn list.
The completion JSON is written last. A failure can leave partial derived files;
the generic hook result records failure. Retrying creates a new run directory.
Audio-only sessions produce the diarization artifacts without inventing text.

## What a label means

Each speaker ID belongs to a single analysis run. The separate identity map supplies display names for known voices.

Attribution uses phrase time overlap rather than forced word alignment:

- One intersecting speaker covering at least half the phrase interval receives
  a `single-speaker-overlap` label.
- More than one intersecting speaker produces `mixed`, listing the candidates.
- No useful match, or insufficient coverage, produces `unknown`.

The hook preserves each source phrase together; it never guesses where to split
its words. Simultaneous voices do not inflate interval coverage. Existing ASR
timing errors and diarization errors can still affect labels. For word-accurate
speaker turns, a later alignment stage would be needed.

## Remembered voices

After recording or running `capture-it hooks SESSION`, a foreground terminal
reviews completed meetings in order. Before playback it checks an eligible
unknown voice against the current library, including names just confirmed in
an earlier meeting. It skips assigned and voice-matched IDs, plays a clip
of each remaining voice with an isolated sample, and asks for a name. Enter
skips a speaker, while `:quit`, Ctrl-D at an empty prompt, or Ctrl-C ends review.
Confirmed assignments persist. Scripts with piped input never prompt.
`--no-review` on record or hooks skips this dialogue.

Use `capture-it speakers SESSION` to resume. Use `--list` for IDs, names and
example times, including speakers with too little isolated speech for playback.
Use `--listen ID` to hear the longest isolated example. Use `--assign ID --name
"Joe Smith"` to label every turn assigned to that ID, update the readable
speaker transcript, and enroll Joe for future calls. If the session has several
completed analyses, the CLI lists the exact `--run UUID/NNN` choices. Previously
saved version-1 reports can be reviewed after upgrading the CLI and helper.

Each confirmation saves up to three separate clips of 2–8 seconds where just
that speaker was detected. With too little isolated speech, the name applies
only to that recording. Use the same full name across recordings to add examples
from other microphones or environments. Repeating an assignment reuses its clips.
Assigning a different name corrects that enrollment and its recording. Use a
distinguishing name for people who share a full name.

`capture-it people` lists remembered names and sample counts. Private
`.voice` folders under `~/Documents/capture-it/voices` by default
contain playable mono WAVs and their names and model-specific embeddings.
An existing default library at `~/Library/Application Support/capture-it/voices`
remains active until a custom home or library is selected. `--home` or
`CAPTURE_IT_HOME` selects a home containing `recordings/` and `voices/`.
`CAPTURE_IT_VOICES` selects an exact library for both enrollment
and recognition. The assignment prints its folder path. Removing one of these
folders forgets its examples for future processing.

After each capture, FluidAudio compares each eligible speaker’s embedding with
confirmed examples from the same model revision. It accepts a name at cosine
similarity 0.70 or higher with at least a 0.10 lead over the next person.
Weak or ambiguous matches retain the recording-local ID. Only a manual
assignment adds training examples. Noise, overlap, similar voices and changes
in microphone can affect accuracy. The original recording and live transcript
are preserved. Structured transcript consumers can join the `speakers` array
to `speaker-identities.json` in the same directory.

## Verification

```sh
make verify       # core checks + model-free mix/attribution regressions
make test-fluid   # requires explicit setup; real local model through public hooks
make test-fluid-installed # installed auto-selection, network denied, failure/cancel paths
```

The real-model journey uses locally synthesized alternating voices in app and
mic channels, checks repeated-speaker consistency, interval bounds, mixed
phrases, meeting evidence, clean stdout and unchanged original-file hashes.
It tests integration and controlled fixtures, not general meeting accuracy.
Its fixture generation needs installed macOS Daniel/Samantha voices and FFmpeg;
it does not install them or download datasets.

FluidAudio code uses Apache-2.0. The selected Community-1 model artifacts have
their own CC-BY-4.0 attribution and provenance; setup retains the upstream
LICENSE, NOTICE and PROVENANCE files. Capture-it's MIT license does not replace
those model terms.

M4A recordings use the same offline pipeline. Standalone mono and stereo
imports retain their source sample rate and are resampled to 16 kHz for
analysis. The helper reads the session manifest to find its saved audio.

Model output tensors are copied into owned CPU buffers between inference calls.
This keeps long imports from retaining Core ML surfaces through feature accessors.
Prediction counters are available in the helper’s debug logs.

## Rematch saved speakers

After adding people to the library, run `capture-it speakers SESSION --match`
(or add `--run UUID/NNN`) to identify the remaining unnamed voices locally.
The helper reuses saved turns, extracts up to three isolated 2–8 second clips,
and compares their embeddings to remembered people. It does not rerun ASR,
full diarization or AI. Existing identities and their extension metadata remain
intact, and automatic matches do not add reference samples.

Profiles record `sourceSession` when enrolled. Rematching excludes profiles from
the target session so its new names are supported by other recordings. Legacy
profiles without origin metadata remain eligible. Per-clip similarity must reach
0.70 with a 0.10 margin over another person. A strict majority of the clips must
agree and no positively matched clip may name someone else. Ambiguous aliases,
weak evidence, conflicting clips and short voices remain unnamed.

Each invocation writes a private `ANALYSIS/voice-matches/UUID.json` report with
completion state, source/model/library metadata, excluded session, per-speaker
status, clip intervals, query embeddings and similarity assessments. Names save
immediately as `source: voice-match` and regenerate the full derived text. Repeat
matching skips existing names. `make test-rematch` verifies this journey with real
local synthetic voices and a deterministic AI boundary; it makes no provider call.
