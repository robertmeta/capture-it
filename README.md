# capture-it

![capture-it — app audio, mic, words](docs/assets/capture-it.svg)

**One app. Your mic. A WAV and a live transcript, from your terminal.**

Record a meeting without adding another desktop app to your day. Capture one
macOS application's playback and a microphone while Apple's on-device speech
recognition writes finalized text to both your screen and a file.

Built for people working in Claude Code, Codex, agy, Gemini CLI, OpenCode,
Aider and the rest of the terminal. The output is ordinary audio, text and JSON;
your assistant can use the files without a special integration.

## Quick setup and usage

Requires **macOS 26+**, a compatible Mac for Apple's SpeechTranscriber, and
Xcode or Command Line Tools with the macOS 26+ SDK and Swift 6. The core CLI
has no external package dependencies. `doctor` checks local speech readiness.

Clone and install:

```sh
git clone https://github.com/robertmeta/capture-it.git
cd capture-it
make install
export PATH="$HOME/bin:$PATH"
capture-it doctor
```

If speech assets are missing, install the desired language explicitly:

```sh
capture-it setup-speech --locale en-US
```

Open Teams, join your call, then run:

```sh
capture-it teams
```

That creates `./teams-yyyyMMdd-HHmmss/` in your current directory. The WAV grows
while you record; finalized words appear on screen and in `transcript.txt`.
**Press Ctrl-C to stop and save.** The WAV finishes first, then pending
transcription. Press Ctrl-C again to skip the remaining transcription wait.

English (`en-US`) is the default. `make install` builds and signs the CLI, then
installs it to `~/bin/capture-it`. Add `export PATH="$HOME/bin:$PATH"` to
`~/.zshrc` if needed for future terminals. Choose another install directory with:

```sh
make install BINDIR="$HOME/.local/bin"
```

You can also use `make build` and run `.build/release/capture-it teams` directly
from the repository.

On first capture, allow macOS **Microphone** and **Screen & System Audio
Recording** access. Check System Settings → Privacy & Security if access was
denied. Keep the signed executable in a stable location; rebuilding or moving
an ad-hoc-signed binary can require authorization again. Playback remains audible.
ScreenCaptureKit requires a display; no video output is saved.

Built-in capture and transcription run locally. `setup-speech` contacts Apple
to download assets. Optional user-selected hooks may contact their own providers.

## Stop and save

- **Ctrl-C once:** stop capture, drain audio and finalize the WAV. Finish pending
  transcription, flush text and run any explicitly selected hooks.
- **Ctrl-C again:** skip remaining speech processing, cancel a running hook and
  skip later hooks. Audio still finishes saving first; written text is retained.

The CLI announces when the WAV is saved. Speech finalization has no fixed cutoff;
you can interrupt again to stop waiting. After an automatic stop, Ctrl-C also
cancels remaining processing. SIGTERM follows the same shutdown path.

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
app instances show their PIDs. Capture stays bound to the selected PID. Ambiguous
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
capture-it transcribe ./teams-20261117-143000
```

`capture-it record teams` and `capture-it record --app teams` also work.
Default folder names use your sanitized search term and local timestamp;
`'*teams*'` becomes `teams-…`. A numeric suffix avoids collisions. Existing
sessions are never overwritten. Capture folders and files use private permissions.

## Meeting title

With Accessibility access, a separate worker reads the selected app's window
titles. One useful title is saved as an **unverified candidate** and passed to
hooks. Generic or ambiguous titles stay unknown. Supply a confirmed title when
needed:

```sh
capture-it setup-accessibility
capture-it teams --title 'Weekly Planning'
```

Audio works without Accessibility. The output folder still uses the app search
and timestamp. See [meeting metadata](docs/meeting-metadata.md) for provenance
and permission details. Speaker names are a separate problem; no Teams/Slack
speaker-name adapter is included. See the [speaker attribution research](docs/speaker-attribution.md).

## Files you can work with

| File | Contents |
| --- | --- |
| `recording.wav` | One 48 kHz PCM16 WAV: app left, app right, microphone |
| `session.json` | Selected app/mic, title evidence, channel layout, counts, status and issues |
| `transcript.txt` | Finalized timestamped lines, appended and synced while recording |
| `transcript.jsonl` | The same segments with source, start time, duration and text |
| `transcript.json` | Completion status and segment count |

Transcript files are created when local speech is ready. Stdout contains only
finalized transcript lines; status goes to stderr. Redirection or a slow pipe
does not block the transcript-file or WAV workers.

Point your terminal assistant at the saved text, for example:

```text
Read ./teams-20261117-143000/transcript.txt. Summarize the decisions,
open questions and action items, keeping names only where stated.
```

The WAV stores three discrete channels using WAVE_FORMAT_EXTENSIBLE. App L/R
stay separate; mic channels are averaged into the third channel. All share one
host-clock timeline, with silence for missing intervals. Speech receives an
explicit mono mix: `0.25*L + 0.25*R + 0.5*mic`. Some stereo players ignore the
third channel; use an editor that supports discrete multichannel audio.

## Post-recording hooks

Choose executable scripts explicitly. They receive JSON containing the saved
WAV and optional transcript paths, then write into their own private output
folder under `SESSION/hooks/UUID/`. Hooks run in flag order after files finalize;
their stdout stays in separate logs.

```sh
# Working local example: inspect the artifact handoff.
capture-it teams --hook ./examples/hooks/inspect-session.py

# Chain your own tools, with a 15-minute timeout for each.
capture-it teams --hook ./my-diarizer --hook ./my-notes --hook-timeout 900

# Retry processing on an existing session.
capture-it hooks ./teams-20261117-143000 --hook ./my-notes
```

See the [hook contract and agy/Claude/Codex examples](docs/hooks.md).
Agent hooks use the executable, account and model provider you select; that
provider may be remote or paid. Coding agents are not assumed to decode WAV files.

### FluidAudio hook — experimental

The optional [FluidAudio adapter](docs/fluid-audio-hook.md) is implemented with
model-free mix/attribution checks. **Its external package build and actual model
inference have not yet been verified.** It is separate from the tested capture
path and the normal build.

Its explicit setup downloads pinned code and model assets. For contributors
validating this integration:

```sh
make setup-fluid
make test-fluid

# After successful setup and validation:
capture-it teams --hook ./hooks/fluidaudio --hook-timeout 900
```

The intended outputs are anonymous speaker turns and a derived labeled transcript.
Mixed phrases remain mixed; this does not infer people's names or provide word
alignment. See the [setup and artifact details](docs/fluid-audio-hook.md).

## Dependability and limits

Capture callbacks, timeline assembly, WAV writing, speech, transcript files and
stdout use independent workers and bounded queues.

- Missing assets or failed speech leave audio available for a later retry.
- A stalled stdout reader is disconnected after two seconds or a full queue;
  the transcript file and recording continue.
- Lost audio buffers, write failures, late timestamps, app exit, disconnected
  mic or format changes stop capture with an explicit issue. Devices never
  switch silently, and the app filter never expands to all system audio.
- One WAV is limited to roughly **4 GiB / 4 hours 8 minutes** at this format.
  Recording stops before exceeding it; there is no rollover.
- WAV headers are checkpointed about once a second. Ctrl-C follows the save
  path; SIGKILL, power loss and hardware faults cannot guarantee finalization.

Aligned timing cannot guarantee accurate transcription of overlapping voices,
noise or echo. Live transcription has recognition delay and no speaker labels.
Older v0.1 separate-track sessions cannot be replayed by the current transcriber.

Exit codes: `0` complete; `1` usage or recording failure; `2` saved audio with
unavailable/incomplete/interrupted speech, transcript-output issues or failed
hooks. Inspect `recording`, `transcription` and `issues` in `session.json`.

## Development and contributions

```sh
make verify          # unit tests, warnings-as-errors and public CLI checks
make test-native     # real app isolation, mic, WAV and failure paths
make test-speech     # real local speech, tee and graceful shutdown
make test-shutdown   # second Ctrl-C during drain
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
