# 0001. Use one native executable with independent bounded workers

- Status: Superseded by 0002 for capture and 0003 for audio storage/transcription; bounded worker separation retained
- Date: 2026-11-17
- Decided by: Project implementation direction

## Context

The CLI must capture one app and a microphone, save WAV files, and tee live
on-device transcription to a file and the screen concurrently. Recording must
remain dependable when recognition or an output consumer is slow.

## Decision

Use Swift and platform frameworks in one executable: Core Audio process taps,
AVAudioEngine microphone input and SpeechAnalyzer. Keep sample buffers in one
native process. Separate per-source WAV and speech workers, transcript file I/O
and nonblocking stdout with bounded queues and explicit failure states. Persist
audio independently of speech. Store PCM16 WAV chunks, text transcript lines,
JSONL segments and JSON session/summary metadata.

## Alternatives considered

Go or Rust with a Swift helper adds another toolchain and process protocol.
A single serial processing loop lets model or terminal delays interrupt audio.
Unbounded asynchronous work hides overload as growing memory use.
ScreenCaptureKit adds display/screen-capture concerns to an audio-only task.
External speech engines add a dependency and model lifecycle before their
quality advantage has been measured.

## Consequences

The application is macOS-specific and targets macOS 26+ for current speech APIs.
Language assets are installed only by explicit command. Overload is visible;
speech/output can become incomplete while audio remains complete. Physical
device behavior, permissions and model performance still require real-machine
journeys beyond unit tests.
