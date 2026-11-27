# 0014. Keep capture running across meetings

- Status: Accepted
- Date: 2026-11-25

Teams and Slack calls can occur in succession, and either app can quit during
the day. Keep one ScreenCaptureKit stream for the selected applications and
one microphone. Refresh its include filter as selected apps leave or return.
An empty selection carries only the microphone. Keep the explicitly selected
PID while available and accept a unique replacement with the same bundle ID.

A meeting owns one WAV, transcript and manifest. The assembler switches output
between complete aligned audio packets when the user presses `n` or the WAV
reaches four hours. Timestamps restart in the new file. Each previous meeting
drains independently. Its offline hooks wait for preceding hooks and can run
while capture continues. Speaker playback uses a separate foreground review
after capture, in meeting order. Review checks the current library before
playing an unknown speaker and cancellation ends the queue. A failed hook leaves its meeting available for retry.

Reserve a directory atomically for each ordered set of sanitized app queries,
local date and occurrence. Its WAV shares the basename. Exact first-session
paths retain `recording.wav`. Readers take the WAV filename from the manifest.
JSONL keeps finalized phrases individually readable while JSON holds whole
session metadata and per-analysis speaker identity mappings.
