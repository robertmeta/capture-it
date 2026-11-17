# FluidAudio: offline speaker-labeling hook

**Experimental:** adapter and model-free checks are present; the external
package build and actual model inference have not yet been verified.

This optional hook uses FluidAudio's offline Community-1/VBx pipeline on the
saved WAV. It adds anonymous speaker intervals and a derived transcript copy;
the original recording and transcript are retained. Core capture-it still has
no external package dependencies. The hook builds as a separate Swift package.

## Explicit setup

Requires Swift 6.2+ and macOS 26+. Initial setup downloads the pinned
[FluidAudio source](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.3)
from GitHub and selected model assets from
[FluidInference on Hugging Face](https://huggingface.co/FluidInference/speaker-diarization-coreml).
It does not send audio or transcripts.

```sh
make setup-fluid
./hooks/fluidaudio --check
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

The hook verifies the local asset manifest and loads Core ML models directly.
It does not call FluidAudio's download/fallback APIs. Missing assets fail with
setup instructions while the original audio remains available. `make verify`
does not fetch FluidAudio or models.

## Capture or retry

```sh
capture-it teams --hook ./hooks/fluidaudio --hook-timeout 900

# Process an existing session.
capture-it hooks ./teams-20261117-143000 --hook ./hooks/fluidaudio --hook-timeout 900

# Use a retried transcript.
capture-it hooks ./teams-20261117-143000 --transcript ./retry-text \
  --hook ./hooks/fluidaudio --hook-timeout 900
```

Hooks run in the order supplied. A later notes hook can read the preceding
result and output directory from `result.json` beside its input JSON. Model
loading and analysis happen after recording, outside the capture workers.

The hook expects capture-it's three-channel 48 kHz WAV and prepares an explicit
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
| `diarization.rttm` | Standard speaker intervals, in seconds from recording start |
| `speaker-transcript.jsonl` | Original phrases plus overlapping speaker IDs, coverage and attribution status; created when source JSONL exists |
| `speaker-transcript.txt` | Readable speaker-labeled copy, preserving original words and phrase times |
| `stdout.log`, `stderr.log` | Existing hook-runner logs |

The completion JSON is written last. A failure can leave partial derived files;
the generic hook result records failure. Retrying creates a new run directory.
Audio-only sessions produce the diarization artifacts without inventing text.

## What a label means

These are anonymous speaker IDs within this recording, not people's names or
stable identities across meetings. No Teams/Slack roster is consulted.

Attribution uses phrase time overlap rather than forced word alignment:

- One intersecting speaker covering at least half the phrase interval receives
  a `single-speaker-overlap` label.
- More than one intersecting speaker produces `mixed`, listing the candidates.
- No useful match, or insufficient coverage, produces `unknown`.

The hook preserves each source phrase together; it never guesses where to split
its words. Simultaneous voices do not inflate interval coverage. Existing ASR
timing errors and diarization errors can still affect labels. For word-accurate
speaker turns, a later alignment stage would be needed.

## Verification

```sh
make verify       # core checks + model-free mix/attribution regressions
make test-fluid   # requires explicit setup; real local model through public hooks
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
