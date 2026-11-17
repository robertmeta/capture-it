# 0006. Two-stage interrupt shutdown preserves audio before skipping speech

- Status: Accepted
- Date: 2026-11-17
- Decided by: User request for graceful Ctrl-C and a second interrupt to exit

## Context

Recognition can lag behind live capture. A fixed fifteen-second finalization
deadline can lose pending words. Users need both a complete normal shutdown and
a way to stop waiting, including when stdout is stalled.

## Decision

Use an explicit running → draining → interrupted state shared by signal
handling and shutdown joins. First Ctrl-C or SIGTERM requests draining. Count
coalesced dispatch signals. Automatic/error stops enter draining too; another
interrupt requests interrupted shutdown.

Stop native capture, drain the assembler and finalize the WAV before speech
waiting. Persist audio completion first. Let speech finish without a fixed
deadline in the normal path. The interrupted path cancels recognition and skips
its completion wait. Transcript-file and stdout joins observe the same state;
they allow brief bounded cleanup, retain already written text and report an
incomplete transcript summary. Session transcription becomes interrupted and
successful audio with interrupted text returns status 2.

## Consequences

A second interrupt cannot bypass WAV finalization. It is an audio-preserving
exit, rather than an immediate process kill. Existing bounded native/audio
shutdown failures remain explicit; this cannot promise recovery from disk
failure or SIGKILL. Normal speech shutdown can wait indefinitely if Apple's
analyzer stalls, with a visible instruction to interrupt again.

Unit checks cover state escalation and interruptible output. A public CLI
journey uses real speech and a full stdout pipe to hold shutdown open, then
checks prompt exit, saved partial text and a readable finalized WAV.
