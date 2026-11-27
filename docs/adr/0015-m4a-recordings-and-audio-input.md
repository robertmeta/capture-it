# 0015. Save M4A and accept audio files as input

- Status: Accepted
- Date: 2026-11-26

## Decision

Use lossless ALAC in M4A for saved recordings. Preserve the three discrete
48 kHz PCM16 channels and their sample count. Keep checkpointed WAV capture
for live recovery, then encode with bounded native buffers. Publish a validated
M4A through the session manifest before removing its recovery WAV. Failure
keeps that WAV usable. Explicit WAV output remains available.

Accept standalone M4A, WAV, MP3, AIFF and CAF through transcribe. Copy M4A
without re-encoding. Save other imports as ALAC M4A using their channel count
and rate. Keep mono and stereo imports usable through saved-session replay,
hooks, speaker playback and enrollment. Three-channel audio uses the existing
capture mix. Preserve original input files.

The version-1 hook contract adds audio and CAPTURE_IT_AUDIO. Legacy wav fields
carry the same saved path so consumers must use a decoder that accepts M4A.
Session metadata continues to identify the actual filename and audio format.
