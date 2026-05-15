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

## Run: 2026-05-14 19:00 UTC

- commit: `3a01a28` (Slash 1.5 + bg-launch announcement)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- operator: shreeve
- mode: co-driven through the chat (operator + AI walkthrough), not
  the standalone harness — same test plan, same per-test PASS/fail
  judgment, results recorded here

| # | test | result | note |
|---|---|---|---|
| 1 | cat-fg | PASS | clean cooked-mode echo, Ctrl-D EOF, prompt return |
| 2 | cat-bg-sigttin | PASS | initial run surfaced **F1** (no `[N] PID` announcement on `&`); fixed mid-validation; re-run clean |
| 3 | ctrl-c-fg | PASS | exit 130 confirmed by `[130]` indicator + `echo $?`; **F2** noted (no `^C` echo) |
| 4 | ctrl-z-fg | PASS | `[1] Stopped sleep` shown, `fg` resumed, Ctrl-C killed cleanly; **F3** noted (status indicator placement scoots prompt) |
| 5 | less | PASS | screen restored cleanly, cooked-mode echo perfect after exit |
| 6 | vim | PASS | alternate screen + raw mode + cursor handling all clean on `:q!` |
| 7 | top | PASS | alternate-screen restore clean, cursor + echo perfect |
| 8 | man | PASS | pager+termios chain clean; typo `eit` → `[127]` is another instance of **F3** |
| 9 | ssh | PASS | exceeded test bar — operator has real ssh setup (`trust` host); nested-PTY allocation completed end-to-end, output `from -ssh` returned, slash survived cleanly |
| 10 | nested-slash | PASS | inner shell did its own bootstrap; exit handed tty back cleanly |
| 11 | nested-bash | PASS | cross-shell tty handoff clean; macOS bash 3.2's "use zsh" warning is bash noise, not a slash issue |
| 12 | python-repl | PASS | raw mode + Ctrl-D EOF + cooked-mode return all worked |
| 13 | node-repl | PASS | one Ctrl-D was enough (recent node changed from requiring two); second Ctrl-D in slash exited slash itself, which is correct EOF handling |
| 14 | yes-head | PASS | pipeline returned 141 (128 + SIGPIPE), as documented Slash pipefail-on behavior; shell survived |

**Tally:** 14 PASS, 0 FAIL, 0 SKIP.

### Findings surfaced by this run

- **F1: bg launch announcement.** `cat &` (and other `&` forms) printed nothing; the user had no immediate confirmation that backgrounding succeeded. Bash/zsh/fish convention is `[N] <pid>` on stderr at launch. **FIXED in commit `3a01a28`** — added `eval.announceBackgroundLaunch`, gated on `session.interactive`, plus a PTY regression test.
- **F2: no `^C` echo on Ctrl-C foreground.** Pressing Ctrl-C in slash kills the foreground job and returns the prompt with `[130]` (correct), but the kernel never echoed `^C` first (zsh and bash both do). Diagnosis: shell_termios baseline was inheriting whatever flags the parent gave us; ECHOCTL wasn't reliably on. **FIXED post-validation.** `bootstrapInteractive` step 7 now explicitly forces the standard "user mode" cooked flags on before saving (`ECHO|ECHOE|ECHOK|ECHOCTL|ICANON|ISIG|IEXTEN` on lflag, `OPOST|ONLCR` on oflag), then `tcsetattr`s the result back so the editor's first `enterRawMode` snapshots that baseline. PTY regression test added.
- **F3: prompt status-indicator placement.** `[1]` (jobs count) and `[N]` (last-status) sit *between* cwd and `$`, scooting the `$` to the right. Visually noisy and the prompt anchor keeps shifting. Three plausible redesigns: render before the cwd (`[130] ~/path $`); on a separate line above the prompt; or right-aligned on the previous line (zsh RPROMPT-style). Real default-prompt design feedback. **Deferred.**

### Verdict

The foundation is solid under real interactive software. vim / less / top / man / nested shells / ssh / Python REPL / node REPL all behave correctly. The only post-validation gaps are cosmetic (F2, F3) and tracked.

Per the post-validation plan: this is the "core solid" milestone. Slash is ready for the interactive UX phase.

---
