# 0003. Store one aligned multichannel WAV and derive one speech stream

- Status: Accepted
- Date: 2026-11-17
- Decided by: User direction for one WAV with app L/R and microphone

## Context

The session should have one audio file and one transcript stream. WAV supports
more than two channels, allowing app stereo and microphone audio to remain
separate while sharing a timestamp timeline. Synchronization helps preserve
conversation timing but cannot guarantee correct recognition of overlapping
voices or noisy audio.

## Decision

Save recording.wav as 48 kHz PCM16 WAVE_FORMAT_EXTENSIBLE with discrete channels
ordered app-left, app-right, microphone. Use native capture timestamps to align
inputs on a dedicated bounded worker, normalize sample rates and microphone
channels, and insert silence for missing source intervals. Transcript/file
timestamps start at the first assembled sample, at zero.

Use one speech recognizer with the explicit downmix 0.25*L + 0.25*R + 0.5*mic.
Live capture and saved-file replay use the same downmix. Keep the WAV writer,
recognition, transcript file and stdout workers independent. Reject input that
arrives after the bounded alignment deadline instead of silently losing it.

Create exactly one WAV; stop and retain it before reaching the RIFF size limit
rather than creating additional files. The manifest records the channel layout
and received input counts. Preserve earlier sessions unchanged and explicitly
reject the older separate-file replay format. Bump the pre-1.0 minor version
for the changed output contract.

## Alternatives considered

Separate WAV files conflict with the requested session layout. Mixing audio
permanently to mono loses the raw app/microphone separation. Labeling the
microphone as a center speaker gives it incorrect playback semantics. Multiple
recognizers could improve overlap handling, but add result-merging behavior;
the initial implementation uses the single mixed speech path.

## Consequences

Audio editors can access each discrete channel, although stereo players vary
in how they handle the third channel. The WAV size limit permits approximately
four hours at this format. A bounded 0.5-second assembly delay adds latency to
live recognition. Overlap and acoustic echo remain accuracy limitations, and
actual speech performance still requires representative real-model testing.
