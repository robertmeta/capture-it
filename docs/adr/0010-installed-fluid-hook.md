# 0010. Setup installs and enables the first-party FluidAudio hook

- Status: Accepted
- Date: 2026-11-19
- Decided by: User selected automatic labeling after setup; post-recording accepted

## Context

The optional adapter works through the generic hook contract, but a checkout-only
build is inconvenient for installed CLI users. The user wants setup to install
the tools and run speaker labeling automatically after recording. Labeling before
live text is printed is a future preference; post-recording processing is accepted.

## Decision

`make install` retains the core-only install. `make setup` also builds the pinned
FluidAudio package, verifies/installs offline model assets, and installs a helper
beside the core CLI in BINDIR (default ~/bin). Keep its executable and required
Swift resource bundles together under `.capture-it-fluid/` beside the launcher.
The launcher works independently of the source checkout.

Presence of the first-party sibling `capture-it-fluid` enables automatic
selection. Resolve the CLI's executable location, rather than searching PATH or
the current directory for plugins. Run it first unless explicitly selected in
the user's ordered hooks. `--no-fluid` disables automatic selection; explicit
hooks retain their behavior. The default per-hook timeout is 900 seconds with
the installed helper selected, otherwise 300; an explicit timeout takes priority.
Doctor reports the installed helper path, without launching it or downloading.

The existing shutdown state machine remains authoritative: stop capture, close
WAV, finish speech/tee, then run hooks. A second interrupt skips or cancels hooks
without discarding saved artifacts. Live text remains immediate; speaker labels
are written as derived artifacts. Inference uses only verified local models.

## Consequences

This specializes ADR 0007's explicit-selection rule for the first-party helper
after explicit setup. Arbitrary hooks and agents still require --hook. FluidAudio
remains separate from the dependency-free core. Keep model/code license notices
and the package lockfile. Setup does network I/O; capture and ordinary inference
do not install models. Disabling labeling does not require uninstalling anything.
