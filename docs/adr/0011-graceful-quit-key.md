# 0011. q starts graceful recording shutdown without escalation

- Status: Accepted
- Date: 2026-11-19
- Decided by: User requested q only, repeated q must never hard exit; Ctrl-C retained

## Context

Terminal users want an ordinary key to stop recording and finish transcription
and hooks. Escape was explicitly excluded. The signal state machine from
[ADR 0006](0006-two-stage-interrupt-shutdown.md) must keep its audio-first cancel
behavior when Ctrl-C is repeated.

## Decision

After capture starts in a foreground interactive terminal, observe lowercase q
without Enter. Call the existing idempotent beginDraining transition; repeated
keys never escalate or undo interruption. Keep observing through speech and hooks
so later q presses do not cancel their work. Ctrl-C retains signal escalation;
once already draining, it can cancel speech/hooks while saved audio is retained.

Use a separate nonblocking controlling-terminal descriptor and a bounded 50 ms
control worker. Disable canonical input and echo, preserving signal generation.
Leave piped stdin unread and let app selection finish before enabling keys.
Restore original terminal settings synchronously on handled recording exits,
before the executable calls exit. Do not assign Escape a shutdown action.

## Consequences

Keyboard input does not share audio, transcript or stdout queues. No raw-mode
package or dependency is required. Signal-only scripting behavior remains intact.
A PTY journey verifies q, repeated q while a hook waits, ignored Escape, real
terminal-generated Ctrl-C escalation, pipeline input preservation and terminal
restoration, with real capture and persisted artifacts.
