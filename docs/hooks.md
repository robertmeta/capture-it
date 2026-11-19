# Post-session hooks

The first-party [FluidAudio offline hook](fluid-audio-hook.md) adds anonymous
speaker turns and conservative labels after recording. Its code/model setup is
optional and explicit; it uses the same executable contract described below.

Hooks let a terminal program process the saved WAV, or the WAV and transcript.
Your hooks are explicit executable files. After `make setup`, the first-party
`capture-it-fluid` installed beside the CLI is selected automatically; use
`--no-fluid` to skip it. Arbitrary plugins and agents are never discovered.

```sh
capture-it teams --hook ./examples/hooks/inspect-session.py
capture-it teams --hook ./my-diarizer --hook ./my-notes --hook-timeout 900

# Run again on existing audio without recording or re-transcribing.
capture-it hooks ./teams-20261117-143000 --hook ./my-notes

# Use the new text after retrying transcription.
capture-it transcribe ./teams-20261117-143000 --out ./retry-text --hook ./my-notes
capture-it hooks ./teams-20261117-143000 --transcript ./retry-text --hook ./my-notes
```

Each `--hook` names an executable file, such as a script with a shebang.
Relative paths resolve in the directory where you start capture-it. Arguments
and shell fragments are not accepted in that value; put them inside your script.
`--hook-timeout` defaults to 900 seconds per executable with the installed
FluidAudio helper selected, otherwise 300. The examples need Python 3, which
the core CLI does not. FluidAudio runs first unless explicitly included at a
chosen position in your hook list; it is then selected only once. `--no-fluid`
disables automatic selection while retaining explicit hooks.

## Handoff

Capture closes the WAV and finishes its transcription attempt before hooks run.
Hooks run sequentially in the selected order, in their own processes. Neither the agent
nor its output participates in the recording worker queues.

Your executable receives one argument: an absolute path to `input.json`:

```json
{
  "version": 1,
  "event": "session-finished",
  "sessionDirectory": "/absolute/path/to/session",
  "sessionManifest": "/absolute/path/to/session/session.json",
  "wav": "/absolute/path/to/session/recording.wav",
  "transcript": "/absolute/path/to/session/transcript.txt",
  "segments": "/absolute/path/to/session/transcript.jsonl",
  "transcriptSummary": "/absolute/path/to/session/transcript.json",
  "transcriptComplete": true,
  "recordingStatus": "complete",
  "transcriptionStatus": "complete",
  "meeting": {
    "title": "Weekly Planning",
    "source": "accessibility-window-title",
    "verified": false,
    "status": "candidate",
    "windowTitle": "Weekly Planning | Microsoft Teams"
  }
}
```

Transcript fields are omitted when their files are absent. Audio-only capture
still invokes hooks with the WAV. Partial transcripts can be passed too; inspect
completion fields before deciding what to do. `transcriptionStatus` describes
the original session; when you select a retried transcript, `transcriptComplete`
comes from that transcript's own summary. A failed capture may supply a closed
partial WAV, marked `recordingStatus: failed`. Unclosed or mismatched audio is
rejected.

The optional `meeting` object carries [title evidence](meeting-metadata.md).
An Accessibility title is a window-title candidate, not a verified meeting
subject. `--title` supplies an explicit title. Older sessions may have no meeting
object; no title or participant identity should be invented in that case.

The same handoff includes environment variables:

| Variable | Value |
| --- | --- |
| `CAPTURE_IT_EVENT` | Absolute `input.json` path, also passed as argument 1 |
| `CAPTURE_IT_SESSION` | Session directory |
| `CAPTURE_IT_WAV` | WAV path |
| `CAPTURE_IT_TRANSCRIPT` | Text path, or an empty string |
| `CAPTURE_IT_HOOK_OUTPUT` | Private output directory for this executable |

Stdin is `/dev/null`; hooks should use non-interactive modes. The working
directory and other environment variables are inherited from your terminal.
Use the supplied absolute paths rather than depending on the current directory.

## Outputs and failures

Each invocation gets a new directory, so re-running hooks preserves earlier runs:

```text
SESSION/hooks/UUID/
  input.json
  result.json
  001/
    stdout.log
    stderr.log
    ...your derived files...
  002/
    ...
```

`result.json` records each executable, status, exit code or termination signal,
duration and output directory. Statuses are `complete`, `failed`, `timed-out`,
`interrupted` and `skipped`. A failed or timed-out hook does not prevent the next
hook from running. Interrupting cancels the current process group and skips the
remaining hooks. Background descendants are stopped when the hook exits too;
hooks must finish their work before returning and must not detach services.
Later hooks can read `result.json` beside their input JSON to find earlier
hooks' statuses and output directories. The input artifact paths stay unchanged.

First Ctrl-C during recording saves audio and finishes text, then runs the hooks.
Another Ctrl-C skips or cancels hooks. During automatic shutdown, or the standalone
`hooks` command, Ctrl-C cancels remaining work immediately. Audio closure still
takes priority. Hook output stays in its logs; transcript stdout remains clean.
Hook failure or cancellation yields exit 2 when audio succeeded; recording failure
keeps exit 1. The original capture and transcript remain available for a retry.

Hooks run as your normal user and can access your files. Use hooks you trust and
write derived work into `CAPTURE_IT_HOOK_OUTPUT`. This is a process boundary,
not a sandbox or a guarantee against a hook intentionally changing its inputs.

## Terminal AI example

The [agent notes example](../examples/hooks/agent-notes.py) supports the locally
verified print/exec modes of agy, Claude Code and Codex. It passes transcript
text and a WAV reference, then writes `notes.md` in the hook's output directory.
It does not attach or upload WAV bytes. A terminal coding agent is not assumed
to implement an audio decoder, speech recognizer or speaker diarizer.

```sh
CAPTURE_IT_AGENT=codex \
CAPTURE_IT_AGENT_BIN=/absolute/path/to/codex \
capture-it teams --hook ./examples/hooks/agent-notes.py --hook-timeout 900
```

For the other agents, choose `CAPTURE_IT_AGENT=claude` or `CAPTURE_IT_AGENT=agy`
and the corresponding executable. Use the actual installed CLI binary; wrappers
can add update or permission behavior. The example adds no permission-bypass
flags. Your agent's authentication and provider configuration still apply.

Running this example sends transcript text to that agent's configured model
provider, which may be remote or paid. Choose it explicitly for the data and
account you intend to use. No agent example or model-backed request is run by
capture-it's tests; tests use local deterministic executables. The small notes
example accepts up to 100 KB of text; longer sessions need a chunking hook.

For a WAV-only pipeline, write a hook that invokes your chosen audio analysis
tool using `CAPTURE_IT_WAV`. For combined processing, use both that file and the
transcript. See [speaker attribution](speaker-attribution.md) for the distinction
between anonymous speakers and people's names.
