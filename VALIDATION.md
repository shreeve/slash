# Slash — Interactive Validation Log

This file is the running log of manual interactive correctness
validation against [`CHECKLIST.md`](./CHECKLIST.md) §12 — vim, less,
top, ssh, nested shells, Python/node REPLs, etc. Runs are appended
chronologically by `scripts/validate-interactive.sh`.

The point of this log: it's the only credible answer to "does Slash
actually work as someone's interactive shell?" Headless and PTY tests
can prove every kernel invariant and still miss the moment vim leaves
the terminal in raw mode. This log is the empirical record.

## How to use this file

```sh
# read the test plan without running anything
./scripts/validate-interactive.sh --plan

# do a real run (appends a new dated section)
./scripts/validate-interactive.sh
```

Run after every commit that touches:
- `src/exec.zig`
- `src/eval.zig` (foreground wait paths, signal/redirect handling)
- `src/builtins.zig` (`fg`/`bg`/`kill`/`disown`/`wait`)
- `src/repl.zig` (line editor, prompt, signal handlers, bootstrap)
- `src/session.zig` (controlling tty / shell pgid / termios state)

A regression in any of those almost always shows up first as an
interactive-program break (vim raw-mode leak, ssh-stops-the-shell, etc.)
and almost never as a headless-test failure.

## Scope

Each run records:
- date + git commit
- OS / arch fingerprint
- per-test result (PASS / FAIL / SKIP) + free-text note

The harness does not auto-detect failures — the operator decides. The
log is honest about that: a green run means a real human watched the
terminal and confirmed sanity, not that a CPU asserted on stdout.

---
