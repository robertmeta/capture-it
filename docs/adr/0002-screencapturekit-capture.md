# 0002. Use ScreenCaptureKit for app and microphone capture

- Status: Accepted
- Date: 2026-11-17
- Decided by: Native implementation verification

## Context

The real capture spike exposed blocked Core Audio process-tap IO registration
and teardown. A separate AVAudioEngine microphone tap returned no samples in
the same environment. ScreenCaptureKit successfully produced both streams and
stopped cleanly. A two-app tone test verified its app allowlist when fixtures
were launched as independent applications through LaunchServices.

## Decision

Use one ScreenCaptureKit stream filtered to exactly one running application,
with separate app-audio and microphone outputs and callback queues. Select the
microphone by its validated AVCaptureDevice unique ID. Retain the independently
bounded WAV, speech, transcript file and stdout workers from decision 0001.
Core Audio remains responsible for process and input-device discovery.

Attach no video output and save no screen frames. Require an available display
and the native screen/audio and microphone permissions. Stop the stream with
a deadline; report failure instead of blocking CLI exit indefinitely.

## Alternatives considered

Keeping both native backends increases lifecycle paths without improving the
verified outcome. Continuing to depend on the stalled process-tap path fails
the dependable-capture requirement. Capturing all audio and filtering after
the fact would violate the selected-app requirement.

## Consequences

The native capture lifecycle is smaller and app/mic timing shares one stream.
This is unsuitable for a headless Mac without a display. The app filter includes
the selected application's audio helpers and browser tabs. Worker overload and
speech asset handling remain independent of the capture backend.
