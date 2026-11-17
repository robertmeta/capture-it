# 0005. Default capture output and prefer a uniquely known app microphone

- Status: Accepted
- Date: 2026-11-17
- Decided by: User request for capture-it teams and app microphone defaults

## Context

Starting a capture should require only a search term. Output belongs in a
query-dated directory under the current directory. A meeting app may use a
different microphone from the system default, but its configured inactive or
brokered input is not always publicly observable.

## Decision

Route a non-command first argument to recording, accepting capture-it teams,
record teams, and record --app teams. Keep reserved commands and explicit
--out/--mic forms. Without --out, sanitize the search term and append the local
yyyyMMdd-HHmmss timestamp; use the selected app name for wildcard-only terms
and add a numeric suffix when a destination already exists. Never overwrite.

An explicit microphone override wins. Otherwise read Core Audio process input
activity and input-scoped device IDs for the selected PID, descendants and
unambiguously related helper bundles. Choose only a single known device that
the capture framework can open. Missing, failed, ambiguous or unsupported
inspection uses the system default, without a mic picker. Report and persist
the chosen UID, source and reason. The device remains fixed for the session.

## Alternatives considered

Requiring app IDs, output paths and microphone flags adds avoidable startup
steps. Always choosing the system mic ignores a known app-specific input.
Guessing from unrelated active processes risks recording the wrong device.
Reading private Teams settings or automating its UI adds fragile integration.

## Consequences

An idle or brokered app can legitimately use the documented fallback. This does
not follow later microphone changes or inherit the app's mute/processing state.
Local folders contain private session files, and existing explicit commands
continue to work. A unique app input policy can be tested deterministically;
actual exposure depends on the app's audio implementation.
