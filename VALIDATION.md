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
- **F2: no `^C` echo on Ctrl-C foreground.** Pressing Ctrl-C in slash kills the foreground job and returns the prompt with `[130]` (correct), but the kernel never echoed `^C` first (zsh and bash both do). Diagnosis: ECHOCTL wasn't on when the foreground job ran AND zigline's render-on-readLine cleared the prompt row, wiping any kernel echo. **FIXED post-validation (commit `d53ce67`).** `terminal.giveToJob` now derives a "user-mode" termios from shell_termios (forces `ECHO|ECHOE|ECHOK|ECHOCTL|ICANON|ISIG|IEXTEN|OPOST|ONLCR` on) and installs it just before the foreground job runs — without touching shell_termios itself, so zigline's saved-termios bookkeeping is undisturbed. `terminal.reclaimForShell` writes `\r\n` to the tty when the job ended via signal, so the editor's render-clear wipes a fresh row above the kernel-echo row. PTY regression test added.
- **F3: prompt status-indicator placement + stickiness.**
  - **Stickiness sub-issue:** `[N]` previously stuck to every subsequent prompt until something succeeded — `Ctrl-C` once and `[130]` followed you forever. **FIXED post-validation (commit `d53ce67`).** `Session.status_pending` flag, set in `eval.runForeground` after each command's status is recorded, cleared by the prompt renderer once it surfaces the indicator. The badge appears exactly once after a failed command and disappears on subsequent prompts.
  - **Placement sub-issue:** the `[N]` badge used to sit between cwd and `$`, scooting the prompt rightward whenever a command failed. **FIXED post-validation.** Replaced with a dedicated pre-prompt notice line — `slash: exit N (SIGNAME)` for signaled exits, `slash: exit N` otherwise — written to stderr by `notice.pendingExitStatus` immediately before the next prompt renders. The prompt itself stays uncluttered. The same `notice` module also surfaces job-state changes — `[N] Stopped command` on Ctrl-Z (auto, no need to run `jobs`), `[N] Continued command` on `fg`, `[N] Continued command & ` on `bg`. All notice lines are dimmed when stderr is a TTY so they read as shell metadata, not program output. Pinned by PTY tests in `tests/pty_tests.zig` (`nonzero last-status surfaces as 'slash: exit N' notice`, `status notice names signal when foreground is Ctrl-C'd`, `status notice does not stick to subsequent prompts`, `Ctrl-Z auto-notices Stopped and fg auto-notices Continued`, `bg announces '[N] Continued <command> &'`).
- **F4: comment-only line triggers continuation prompt.** Typing `# blah` and Enter put slash into `... ` continuation mode forever (the parser saw no sequence_item, reported an end-of-buffer error, `isIncompleteParse` interpreted that as "needs more input"). Surfaced during the F2 follow-up testing. **FIXED post-validation (commit `d53ce67`).** `evaluatePending` now uses a `containsNoStatement(text)` helper that walks the buffer skipping spaces/tabs/newlines/CR/`#`-to-end-of-line comments. Empty Enter and comment-only Enter both short-circuit to a fresh prompt.

### Verdict

The foundation is solid under real interactive software. vim / less / top / man / nested shells / ssh / Python REPL / node REPL all behave correctly. The only post-validation gaps are cosmetic (F2, F3) and tracked.

Per the post-validation plan: this is the "core solid" milestone. Slash is ready for the interactive UX phase.

---
