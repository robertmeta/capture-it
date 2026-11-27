# capture-it

![capture-it — app audio, mic, words](docs/assets/capture-it.svg)

**Record selected apps and your microphone from the terminal, with an M4A and live transcript for each meeting.**

Record a meeting without adding another desktop app to your day. Capture playback from one or more
macOS applications and a microphone while Apple's on-device speech
recognition writes finalized text to both your screen and a file.

Built for people working in Claude Code, Codex, agy, Gemini CLI, OpenCode,
Aider and the rest of the terminal. The output is ordinary audio, text and JSON;
your assistant can use the files without a special integration.

## Quick setup and usage

Requires **macOS 26+**, a compatible Mac for Apple's SpeechTranscriber, and
an Apple toolchain with **Swift 6.2+** and the **macOS 26+ SDK**. Install
Xcode 26 or newer, or the corresponding Command Line Tools. The core CLI has
no external package dependencies. `doctor` checks local speech readiness.

Clone and install:

```sh
git clone https://github.com/robertmeta/capture-it.git
cd capture-it
make install
export PATH="$HOME/bin:$PATH"
capture-it doctor
```

Use `capture-it --help` for command help. AI agents can request the dense
operational guide with `capture-it --ai-help`, covering commands, defaults,
file schemas, hooks, speaker review, privacy and recovery.

If speech assets are missing, install the desired language explicitly:

```sh
capture-it setup-speech --locale en-US
```

Open Teams, join your call, then run:

```sh
capture-it teams
```

Each recording gets a numbered folder under `~/Documents/capture-it/recordings/`.
The recovery WAV grows while finalized phrases appear on screen and in `transcript.txt`.

To keep Teams and Slack ready throughout the day, run:

```sh
capture-it teams slack
```

Press **`n` for a new meeting**. Capture continues into the next recording while
FluidAudio and other configured hooks process the previous meeting in the
background. Press **`q` to save and quit**. Both keys work without Enter.
For example, the first M4A on November 25 is
`teams-slack-2026-11-25-01/teams-slack-2026-11-25-01.m4a`. The next meeting
that day uses `-02`, including when you restart the CLI. Numbering starts at
`01` for each local date and ordered set of app search terms.

English (`en-US`) is the default. `make install` builds and signs the CLI, then
installs it to `~/bin/capture-it` with `capture-it-ai` beside it. Add `export PATH="$HOME/bin:$PATH"` to
`~/.zshrc` if needed for future terminals. Choose another install directory with:

```sh
make install BINDIR="$HOME/.local/bin"
```

You can also use `make build` and run `.build/release/capture-it teams` directly
from the repository.

If `make build` reports an invalid Swift package manifest, check which toolchain
and SDK are active.

```sh
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-version
```

Update the Apple toolchain if either version is below the minimum above. If a
compatible Xcode is already installed at `/Applications/Xcode.app`, select it
for a single build.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
```

On first capture, allow macOS **Microphone** and **Screen & System Audio
Recording** access. If ScreenCaptureKit returns `-3801` after you clicked Allow,
open **System Settings → Privacy & Security → Screen & System Audio Recording**.
Enable the terminal or capture-it entry in the section that grants both screen
and system audio access. Quit the terminal completely, reopen it, then run
`capture-it doctor` and retry capture from the same installed path. Doctor
checks the screen grant for its current launch without requesting permission.
Rebuilding or moving an ad-hoc-signed binary can require authorization again.
Playback remains audible. ScreenCaptureKit requires a display and saves audio only.

Built-in capture, transcription and FluidAudio run locally. The installed AI
enrichment step defaults to **Codex / `gpt-6.2-sol`**, sending transcript text to
Codex’s configured provider after saving. Use `--no-ai` to keep built-in processing
local. `setup-speech` contacts Apple to download assets.

### Set up automatic speaker labels

From the checkout, run:

```sh
make setup
capture-it doctor
capture-it teams
```

`make setup` installs the CLI and FluidAudio helper in `~/bin`, with its runtime
resources beside the helper, and downloads pinned models for offline use.
It requires Swift 6.2+. Use `BINDIR` to change the install location for both tools.
Run `make setup` when upgrading an older speaker helper to review M4A recordings.
Apple speech assets are separate: use `setup-speech` above if needed.

Once installed, FluidAudio runs automatically **after the audio and live transcript
finish saving**, including after the first Ctrl-C. It writes a separate
speaker-labeled transcript; live text still appears without speaker labels.
Ctrl-C again skips or cancels the remaining processing. To skip automatic labels:

```sh
capture-it teams --no-fluid
```

### AI enrichment

`make install` also installs the AI hook. Install and authenticate the Codex CLI
separately. After local speaker analysis, Codex proposes speaker names with
quoted, timestamped evidence and writes meeting notes. No audio is attached.

```sh
capture-it teams slack                         # default Codex / Sol enrichment
capture-it teams slack --no-ai                 # skip the AI step
capture-it enrich ./my-call --no-review        # enrich saved text/speakers
capture-it enrich ./my-call --run UUID/001     # select an existing analysis
```

Review plays each unmatched voice and shows available suggestions. Type
`:accept 1` to confirm, another name to change it, `:reject` to dismiss, Enter to
skip, or `:quit` to return later. Confirmation labels the speaker throughout the
recording and saves voice samples. AI guesses never enroll automatically.
`--no-review` saves the results for later. Failed AI processing preserves saved
audio, transcripts and completed voice analysis.

[Configuration, outputs and jq recipes](docs/ai-enrichment.md).

### Remember a speaker

After saving a call, capture-it checks for remembered voices. In a foreground
terminal it plays one example for each unmatched speaker and asks for a name.
Enter a name to save it, press Enter to skip that speaker, or type `:quit` to
finish. Ctrl-C also ends the review. The recording and confirmed names are
already saved. Use `--no-review` to keep automatic matching and skip the prompts.

To record raw audio now and review it later, use the session path printed when
the recording finishes:

```sh
capture-it teams --no-transcribe --no-fluid --no-ai --out ./my-call
capture-it hooks ./my-call                 # run FluidAudio and review
capture-it speakers ./my-call              # resume an existing review
capture-it speakers ./my-call --list        # show IDs, names and example times
capture-it speakers ./my-call --match       # match unnamed voices from other calls locally
capture-it speakers ./my-call --assign S1 --name "Joe Smith"
capture-it people
```

The assignment updates Joe’s turns in the call’s `speaker-transcript.txt` and
saves up to three isolated voice samples on this Mac. Future recordings with
FluidAudio enabled automatically use remembered names when the voices match.
Confirm Joe in another recording under the same name to add more examples.
After growing the library, use `speakers SESSION --match` to identify unnamed
voices in saved analyses without repeating transcription, FluidAudio detection
or AI enrichment. It preserves existing names and leaves uncertain voices unnamed.
Use `--run UUID/NNN` when the session has multiple analyses. Matching never enrolls
more samples automatically.
Names appear after saving. [Voice library and matching details](docs/fluid-audio-hook.md#remembered-voices).

### Capture home

The default home is `~/Documents/capture-it`. Each call gets a folder under
`recordings/` containing its audio, manifest, available transcripts, and hook
results. New voice libraries live under `voices/`. Existing recordings can
still be opened by path. An existing default voice library in Application
Support continues to be used with the default configuration.

Use `capture-it teams --home /path/to/home` for another home, or set
`CAPTURE_IT_HOME` for all commands. Pass the same home to later `hooks`,
`speakers`, and `people` commands to use its voice library. `--out` selects
an exact session directory and `CAPTURE_IT_VOICES` selects an exact voice
library. macOS may sync Documents if you have enabled iCloud Drive for it.

## Meeting controls

- **n** starts the next meeting. The bottom row shows both controls. Previous
  meetings finish processing in order. When capture ends, the terminal reviews
  meetings in order and checks remembered voices before playing unknown ones.
  Type `:quit` to leave the rest for later. Resume any meeting with
  `capture-it speakers SESSION_DIRECTORY`.
- **q:** in a foreground interactive terminal, start a graceful stop without
  Enter. Further `q` presses never skip transcription or cancel hooks.
- **Ctrl-C once:** stop capture, drain audio and finalize the audio. Finish pending
  transcription, flush text, run installed FluidAudio, then your selected hooks.
- **Ctrl-C again:** skip remaining speech processing, cancel a running hook and
  skip later hooks. Audio still finishes saving first; written text is retained.

The CLI announces when audio is saved. Speech finalization has no fixed cutoff;
you can interrupt again to stop waiting. After an automatic stop, Ctrl-C also
cancels remaining processing. SIGTERM follows the same shutdown path.
Escape has no stop action. Keyboard input is enabled after app selection and
capture startup, stays active through finalization, and restores your terminal
settings on exit. Piped stdin is left unread; use signals in scripts.

## Choose the app and microphone

App names and bundle IDs match case-insensitively. One match selects automatically;
several show a numbered picker. Enter a number or `q` to cancel. Quote wildcards
so the shell leaves them intact:

```sh
capture-it teams
capture-it '*zoom*'
capture-it 'Microsoft *'
capture-it com.microsoft.teams2

capture-it apps
capture-it devices
```

An exact bundle ID takes priority. Embedded helpers stay with their app; multiple
app instances show their PIDs. If an app quits, the microphone keeps recording.
Capture resumes its audio when one instance with the same bundle ID returns.
If a search has no running match, capture-it also looks in the Applications
folders and can wait for an installed app to launch. Ambiguous
searches fail with available choices in non-interactive scripts. Selecting a
browser captures its audio across tabs.

Mic selection uses an explicit `--mic DEVICE_UID` first, then the app's active
input when macOS exposes exactly one capturable device, then the system default.
Join the call before recording. Idle or brokered apps may not expose their input.
The CLI prints and saves the chosen mic and reason; the device stays fixed.

**The mic is captured independently:** the meeting app's mute button and audio
processing do not apply. Headphones help avoid picking up playback a second time.

## Useful commands

```sh
# Choose a new output folder.
capture-it teams --out ./recordings/planning

# Use a microphone UID listed by `capture-it devices`.
capture-it teams --mic DEVICE_UID

# Stop after 60 seconds, or capture audio without speech recognition.
capture-it teams --duration 60
capture-it teams --no-transcribe

# Use another supported, installed locale.
capture-it teams --locale en-GB

# Retry transcription without changing the original session.
capture-it transcribe ~/Documents/capture-it/recordings/teams-2026-11-25-01
```

`capture-it record teams` and `capture-it record --app teams` also work.
Default folder and audio names use the sanitized search terms, local date and
next occurrence. `--out ./planning` selects that exact first folder and uses
`planning/recording.m4a`. Pressing `n` then creates a numbered sibling folder.
Capture folders and files use private permissions.

## Meeting title

For a single selected app with Accessibility access, a separate worker reads its window
titles. One useful title is saved as an **unverified candidate** and passed to
hooks. Generic or ambiguous titles stay unknown. Supply a confirmed title when
needed:

```sh
capture-it setup-accessibility
capture-it teams --title 'Weekly Planning'
```

Audio works without Accessibility. The output folder still uses the app search terms, date
and occurrence. See [meeting metadata](docs/meeting-metadata.md) for provenance
and permission details. Speaker names are a separate problem; no Teams/Slack
speaker-name adapter is included. See the [speaker attribution research](docs/speaker-attribution.md).

## Files you can work with

| File | Contents |
| --- | --- |
| `<meeting>.m4a` | Lossless ALAC audio at 48 kHz with selected apps L/R and microphone in three channels |
| `session.json` | Selected app bundle IDs, mic, title evidence, channel layout, counts, stop reason and issues |
| `transcript.txt` | Finalized timestamped lines, appended and synced while recording |
| `transcript.jsonl` | The same segments with source, start time, duration and text |
| `transcript.json` | Completion status and segment count |

Transcript files are created when local speech is ready. Stdout contains only
finalized transcript lines; status goes to stderr. Redirection or a slow pipe
does not block the transcript-file or WAV workers.

Point your terminal assistant at the saved text, for example:

```text
Read ~/Documents/capture-it/recordings/teams-2026-11-25-01/transcript.txt. Summarize the decisions,
open questions and action items, keeping names only where stated.
```

New recordings save as **M4A with Apple Lossless (ALAC)**. The app left, app
right and microphone channels retain their original PCM16 samples and frame
count. Live speech uses `0.25*L + 0.25*R + 0.5*mic`. Choose WAV explicitly with:

```sh
capture-it teams slack --format wav
```

While capture runs, a checkpointed recovery WAV keeps the audio readable. After
each meeting ends, a separate worker writes and validates the M4A, updates
`session.json`, then removes that recovery WAV. A conversion failure retains
the WAV and records the issue. Allow temporary space for both files during
finalization. ALAC size depends on the audio, so the previous PCM disk budget
still applies while recording.

### Use existing audio

Pass a standalone M4A directly to transcription:

```sh
capture-it transcribe ./meeting.m4a --out ./imported-meeting
capture-it speakers ./imported-meeting
```

This creates a saved session with audio, metadata, transcripts and configured
hook results. Existing M4A files are copied byte for byte. WAV, MP3, AIFF and CAF
inputs are decoded into lossless M4A. Inputs may have one, two or three channels.
Mono stays mono and stereo is averaged for speech analysis. Three-channel input
uses capture-it's app L/R/mic mix. Original input files stay at their source paths.

Existing WAV session folders still work with `transcribe`, `hooks` and `speakers`.

### Query recordings with jq

Use JSONL for transcripts. Each line is one phrase with its own timestamps, so
`jq` can filter a meeting as it grows. Use `session.json` for meeting metadata
and the audio path. After FluidAudio runs, `speaker-transcript.jsonl` holds
speaker IDs per phrase and `speaker-identities.json` maps known IDs to names.

List saved meetings with their start time, status, apps and audio filename:

```sh
recordings="$HOME/Documents/capture-it/recordings"
jq -r '[.startedAt, .recording, ((.apps // [.app]) | join(", ")), .chunks[0].file] | @tsv' "$recordings"/*/session.json
```

Read one meeting's phrases as tab-separated start seconds, duration and text:

```sh
session="$recordings/teams-slack-2026-11-25-01"
jq -r '[.start, .duration, .text] | @tsv' "$session/transcript.jsonl"
```

Find Joe Smith’s lines. First list the available labeled transcripts. Pick the
directory for the analysis run you want if you have reprocessed the meeting:

```sh
find "$session/hooks" -name speaker-transcript.jsonl
analysis="$session/hooks/YOUR-RUN-ID/001"
jq -r --arg person "Joe Smith" --slurpfile ids "$analysis/speaker-identities.json" '
  select(.attribution == "single-speaker-overlap")
  | select(any(.speakers[]; $ids[0][.].name == $person))
  | [.phrase.start, .phrase.text] | @tsv
' "$analysis/speaker-transcript.jsonl"
```

This last query omits mixed and unknown phrases. Speaker IDs are local to each
analysis run, so use its accompanying identity file.

## Post-recording hooks

Choose executable scripts explicitly. They receive JSON containing the saved
audio and optional transcript paths, then write into their own private output
folder under `SESSION/hooks/UUID/`. Hooks run in flag order after files finalize;
their stdout stays in separate logs.

```sh
# Working local example: inspect the artifact handoff.
capture-it teams --hook ./examples/hooks/inspect-session.py

# Chain your own tools, with a 15-minute timeout for each.
capture-it teams --hook ./my-diarizer --hook ./my-notes --hook-timeout 900

# Retry processing on an existing session.
capture-it hooks ~/Documents/capture-it/recordings/teams-2026-11-25-01 --hook ./my-notes
```

See the [hook contract and agy/Claude/Codex examples](docs/hooks.md).
Agent hooks use the executable, account and model provider you select; that
provider may be remote or paid. Coding agents are not assumed to decode audio files.

### FluidAudio speaker labeling

The optional [FluidAudio adapter](docs/fluid-audio-hook.md) runs offline after
recording. `make install` installs the core CLI; `make setup` also installs
FluidAudio and its models. You can add just the helper to an existing installation:

```sh
make setup-fluid
make test-fluid

# Installed CLI: automatic speaker labels after saving.
capture-it teams
capture-it hooks ~/Documents/capture-it/recordings/teams-2026-11-25-01

# Checkout CLI without a sibling helper:
.build/release/capture-it teams --hook ./hooks/fluidaudio --hook-timeout 900
```

Outputs are anonymous speaker turns and a derived labeled transcript under
`SESSION/hooks/UUID/001/`. The default per-hook timeout is 900 seconds when the
installed helper is selected, or 300 seconds otherwise; override with
`--hook-timeout`. FluidAudio runs before your other hooks, unless you explicitly
include it in your chosen hook order. `--no-fluid` disables automatic selection;
an explicit `--hook` still runs.

Mixed phrases retain their candidate speakers. Remembered names come from explicit
voice enrollments and local matching. See the [setup and artifact details](docs/fluid-audio-hook.md).

## Dependability and limits

Capture callbacks, timeline assembly, WAV writing, speech, transcript files and
stdout use independent workers and bounded queues.

- Missing assets or failed speech leave audio available for a later retry.
- A stalled stdout reader is disconnected after two seconds or a full queue;
  the transcript file and recording continue.
- Lost audio buffers, write failures, late timestamps, disconnected
  mic or format changes stop capture with an explicit issue. Devices never
  switch silently, and the app filter never expands to all system audio.
- At four hours of audio, capture moves to the next numbered meeting automatically,
  before the RIFF size limit. Budget about **1.04 GB per hour** (8.3 GB for
  eight hours) as the uncompressed baseline, plus space for analysis. Final M4A size varies
  with the audio. The microphone records
  between calls as long as capture is running.
- WAV headers are checkpointed about once a second. Ctrl-C follows the save
  path; SIGKILL, power loss and hardware faults cannot guarantee finalization.

Aligned timing cannot guarantee accurate transcription of overlapping voices,
noise or echo. Live transcription has recognition delay and no speaker labels.
Older v0.1 separate-track sessions cannot be replayed by the current transcriber.

Exit codes: `0` complete; `1` usage or recording failure; `2` saved audio with
unavailable/incomplete/interrupted speech, transcript-output issues or failed
hooks. Inspect `stopReason`, `recording`, `transcription` and `issues` in `session.json`.

## Development and contributions

```sh
make verify          # unit tests, warnings-as-errors and public CLI checks
make test-native     # real app isolation, mic, WAV and failure paths
make test-speech     # real local speech, tee and graceful shutdown
make test-shutdown   # second Ctrl-C during drain
make test-keys       # real terminal q/repeated q, Ctrl-C and terminal restoration
make test-m4a        # standalone M4A/WAV input, local ASR and speaker analysis
make test-meetings   # rotation, background hooks and selected-app relaunch
make test-selection  # app search and interactive picker
make test-microphone # active-input probe and safe fallback
make test-hooks      # hook handoff, failures, timeout and process cleanup
make test-title      # selected-app Accessibility titles and metadata handoff
make audit-public    # offline publication audit; requires installed Gitleaks
```

Native journeys need recording permissions; title tests also need Accessibility.
Speech tests use installed assets, FFmpeg and a local speech fixture. Run native
journeys one at a time because they share microphone/playback devices. Tests do
not install tools or models automatically. Optional FluidAudio setup is separate.

For changes, include a small reproduction and relevant verification. The
[architecture](docs/architecture.md) and linked decisions describe the worker
and file contracts. Keep private recordings and derived session artifacts out
of contributions; default sessions and hook-run folders are ignored here.

## License

[MIT](LICENSE) © 2026 Robert Melton. Optional third-party code and models retain
their own licenses; see [FluidAudio details](docs/fluid-audio-hook.md).
