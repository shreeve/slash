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

## Run: 2026-05-15 19:55 UTC

- commit: `82ac1b0` (notice: drop leading \r\n on stop notice)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash` (ReleaseFast)
- operator: shreeve
- mode: targeted re-validation of the F3-placement closure + the new
  job-state announcement mechanism (`src/notice.zig`). Exercised the
  status-notice and live-state-announcement paths interactively at
  the prompt.

| # | test | result | note |
|---|---|---|---|
| 1 | status notice on `false` | PASS | `slash: exit 1` on its own dim line above the next prompt |
| 2 | status notice with signal name | PASS | `sleep 30` + Ctrl-C → `slash: exit 130 (SIGINT)` |
| 3 | status notice clears | PASS | `false` then `true` → notice fires once, next prompt is silent |
| 4 | status notice plain on non-signal exit | PASS | `sh -c "exit 42"` → `slash: exit 42`, no spurious signal name |
| 5 | Ctrl-Z auto-notice | PASS | `sleep 30` Ctrl-Z → `[1] Stopped sleep 30` immediately, no need to run `jobs` |
| 6 | `fg` continued notice | PASS | resumed sleep prints `[1] Continued sleep 30` |
| 7 | `bg` continued notice with `&` | PASS | `[1] Continued sleep 30 &` — `&` suffix matches the launch convention |
| 8 | `fg`/`bg` on already-running silent | PASS | `sleep 30 &` then `bg %1` → no Continued line; idempotent |
| 9 | sequence-after-Ctrl-Z suspends | PASS | `sleep 30; echo HI` after Ctrl-Z does NOT run `echo HI`; matches bash/zsh |
| 10 | pipeline Ctrl-Z aggregate | PASS | `sleep 30 \| cat` Ctrl-Z → exactly one `[1] Stopped` notice for the pipeline as a whole |
| 11 | no redundant `slash: exit` on stop | PASS | Ctrl-Z'd job leaves session at `[N] Stopped` only — no spurious `slash: exit` for the placeholder result |
| 12 | prompt is clean (no `[N]` badge) | PASS | the failing-command exit-status badge moved out of the prompt entirely |

**Tally:** 12 PASS, 0 FAIL, 0 SKIP.

### Findings

None new. F3 closure (commits `46a13b7` + `82ac1b0`) is confirmed
visually. The corresponding PTY tests (`tests/pty_tests.zig` —
`nonzero last-status surfaces as 'slash: exit N' notice`,
`status notice names signal when foreground is Ctrl-C'd`,
`Ctrl-Z auto-notices Stopped and fg auto-notices Continued`,
`Ctrl-Z in a sequence suspends the rest of the sequence`,
`Ctrl-Z in a pipeline emits one Stopped notice for the pipeline`,
`bg announces '[N] Continued <command> &'`,
`bg on already-running job is silent`,
`Ctrl-Z does not emit a redundant 'slash: exit' notice`) are all
green at this commit.

### Verdict

F3-placement is closed. The first wave of interactive UX (`str`
abbreviations, persistent metadata-rich history, smart prefix-aware
Up/Down, pre-prompt status notices, live job-state announcements)
all behave correctly under real keystrokes. Slash is ready to move
to the next ROADMAP item — autosuggestions are the natural pickup
since the `HistoryIndex` substrate is already in.

---

## Targeted PTY Validation: 2026-05-15 21:50 UTC

- commit: working tree (intelligent completions + history autosuggestions)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression suite (`zig build test`)

| # | test | result | note |
|---|---|---|---|
| 1 | `cd` completion | PASS | `cd sr<Tab>` completes to the `src/` directory and `pwd` confirms the directory change |
| 2 | `git` completion | PASS | `git <Tab>` lists starter subcommands such as `checkout` without invoking git completion scripts |
| 3 | `kill` signal completion | PASS | `kill -K<Tab>` completes to `-KILL` |
| 4 | `str -e` completion | PASS | `str -e z<Tab>` targets the defined `str` name and erases it |
| 5 | job completion | PASS | `fg %<Tab>` targets the current job spec rather than the literal `%` |
| 6 | history autosuggestion render + accept | PASS | seeded history renders the ghost suffix; Right Arrow accepts and Enter runs the full command |

**Tally:** 6 PASS, 0 FAIL, 0 SKIP.

### Findings

The first PTY pass caught a real `str -e` completion-context bug:
the provider checked the current word instead of the previous word, so
`str -e z<Tab>` missed the `str`-name provider. Fixed in
`src/completion.zig` by checking the word before the replacement range.

### Verdict

The new editor-time completion and autosuggestion surfaces are pinned
by PTY tests and by the unit/headless suite. They stay within PLAN §12:
no shell code is evaluated at editor events, suggestions are not part
of the command until accepted, and completion providers are bounded.

---

## Targeted PTY Validation: 2026-05-15 23:35 UTC

- commit: working tree (`str` Enter trigger)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression suite (`zig build test-pty`)

| # | test | result | note |
|---|---|---|---|
| 1 | `str` Enter expansion | PASS | `ll<Enter>` expands and accepts the stored RHS in one editor event |
| 2 | argument-position Enter | PASS | `echo ARG_RESULT=ll<Enter>` keeps `ll` literal; `str` expansion remains command-position only |

**Tally:** 2 PASS, 0 FAIL, 0 SKIP.

### Verdict

The `str` Enter trigger now matches the shipped Space trigger's
command-position rule while using zigline's `replace_buffer_and_accept`
path so the submitted line is the expansion, not the abbreviation.

---

## Targeted PTY Validation: 2026-05-15 23:55 UTC

- commit: working tree (rich prompt presets)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression suite (`zig build test-pty`)

| # | test | result | note |
|---|---|---|---|
| 1 | `SLASH_PROMPT=minimal` | PASS | prompt is just ` $ `; cwd does not appear |
| 2 | `SLASH_PROMPT=rich` + `VIRTUAL_ENV` | PASS | prompt prefix includes `(myvenv)` from the venv basename |
| 3 | `SLASH_PROMPT=rich` with bg job | PASS | prompt suffix includes `[1j]` while `sleep &` is alive |
| 4 | `$PROMPT` template precedence | PASS | a user-set `$PROMPT` overrides any `$SLASH_PROMPT` preset |

**Tally:** 4 PASS, 0 FAIL, 0 SKIP.

### Verdict

Prompt presets compose from bounded providers (env vars, `.git/HEAD`,
in-memory `JobTable`) and never call into the slash kernel. The
`default` preset is the legacy `cwd $ ` baseline so existing users
see no change; `rich` is the explicit opt-in upgrade. The existing
`$PROMPT` template path keeps full control for users who want it.

---

## Targeted Headless Validation: 2026-05-15 23:58 UTC

- commit: working tree (syntax highlighting polish)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- mode: in-process highlighter assertions (`zig build test-headless`)

| # | test | result | note |
|---|---|---|---|
| 1 | `$(date)` distinct color | PASS | command substitution uses `cmd_subst` (lavender), not `variable` (amber) |
| 2 | `$name` + `$(date)` coexist | PASS | each token gets its own class; no confusion in mixed expansions |
| 3 | `>` vs `\|` color split | PASS | redirects route to `redirect`; pipe stays in `operator` |
| 4 | `<<EOF` heredoc open | PASS | heredoc open sigil colored as a redirect |
| 5 | `*.zig` glob char | PASS | `*` byte gets `glob` color; `.zig` stays argument |
| 6 | `FOO=bar` assignment | PASS | LHS ident colored as `variable`; spurious `==` does not promote |

**Tally:** 6 PASS, 0 FAIL, 0 SKIP.

### Verdict

The highlighter now distinguishes the categories the roadmap called
out (variables, command substitutions, redirects, glob parts, heredoc
bodies) without introducing a second tokenizer — every span is still
driven by `parser.BaseLexer` plus a small post-tokenization scan
inside bare-word idents. Spans stay sorted and non-overlapping, so
zigline's renderer keeps every emitted color.

---

## Targeted PTY Validation: 2026-05-15 23:75 UTC

- commit: working tree (Ctrl-R reverse-i-search)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression (`zig build test-pty`) plus headless
  unit tests for the hook state machine

| # | test | result | note |
|---|---|---|---|
| 1 | hook `.opened` with no history | PASS | status surfaces `(no history): `, no preview |
| 2 | `.query_changed` finds match | PASS | preview = ranked top match; status = `(reverse-i-search) \`q': ` |
| 3 | `.next` advances cycle | PASS | repeated Ctrl-R picks the next-older match |
| 4 | `.next` past end clamps + fails | PASS | last preview pinned; status flips to `(failing-i-search) \`q': ` |
| 5 | empty query renders no preview | PASS | nothing matches the empty-string substring without surfacing the entire history |
| 6 | `.aborted` releases candidate slice | PASS | hook frees its results so a subsequent open starts cleanly |
| 7 | PTY accept replaces buffer + runs | PASS | Ctrl-R + query + Enter + Enter executes the matched command |
| 8 | PTY Esc abort restores buffer | PASS | original benign buffer runs; the seeded match is never executed |

**Tally:** 8 PASS, 0 FAIL, 0 SKIP.

### Verdict

Slash now surfaces every accepted command (across sessions, with cwd
and frecency context) through Ctrl-R. The hook is a thin adapter
over `HistoryIndex.search(.substring)`; zigline owns the keystroke
loop, the rendering, and the main-buffer preservation. Accept does
not auto-submit, matching the bash/zsh contract that Ctrl-R is for
*finding* a command, not running one.

---

## Targeted PTY Validation: 2026-05-15 23:80 UTC

- commit: working tree (between-prompts `[N] Done` notices)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression (`zig build test-pty`)

| # | test | result | note |
|---|---|---|---|
| 1 | bg job `[N] Done` notice | PASS | `sleep 0.2 &` plus a follow-up command produces exactly one `[1] Done sleep` line between the two prompts |
| 2 | foreground completion silence | PASS | a plain `echo` does NOT trigger any spurious `] Done echo` line |

**Tally:** 2 PASS, 0 FAIL, 0 SKIP.

### Verdict

Matches bash/zsh `set +b` default-mode timing — backgrounded jobs
announce at the next prompt boundary, not mid-prompt. Mid-prompt
`set -b` semantics would require a zigline `printAbove` primitive
that hasn't shipped yet.

---

## Targeted PTY Validation: 2026-05-15 23:90 UTC

- commit: working tree (CHECKLIST §5/§13 stress test)
- os: Darwin 25.4.0 arm64 (macOS, M-series)
- slash binary: `bin/slash`
- mode: automated PTY regression (`zig build test-pty`)

| # | test | result | note |
|---|---|---|---|
| 1 | 10 rapid Ctrl-Z/fg cycles | PASS | ≥ 6 `Stopped sleep` and ≥ 6 `Continued sleep` notices in the transcript; post-storm `echo STRESS_OK` confirms the shell is still healthy |

**Tally:** 1 PASS, 0 FAIL, 0 SKIP.

### Verdict

CHECKLIST §5 ("terminal handoff survives races") and §13 ("terminal
ownership survives rapid stop/continue cycles") are both closed —
the same PTY stress test exercises `terminal.giveToJob` +
`tcsetpgrp` on resume, parent bookkeeping (`Job.state` transitions
monotonically), the SIGCHLD safe-point reaping path under burst
load, and the post-storm prompt recovery.

---

## CI: Linux PTY validation live: 2026-05-15 24:10 UTC

- workflow: `.github/workflows/ci.yml`
- matrix: `ubuntu-latest`, `macos-latest`
- zigline: pinned by URL + hash in `build.zig.zon` (v0.5.0); the
  package manager fetches and caches on first build
- Zig: 0.16.0 (downloaded from `ziglang.org` per platform)

The CI build process exposed real Linux-portability bugs that
macOS-only development had hidden:

- **F5: `std.c.fstatat` macOS-only.** Zig 0.16's `std.c.Stat` is
  `void` on Linux — the stdlib steers callers toward `statx(2)`
  and drops the per-glibc `struct stat` shape. **FIXED**: added
  `src/portable_stat.zig` with a narrow `Info { kind, size }`
  surface that routes through `statx` on Linux and `fstatat` on
  macOS. Four call sites in `builtins.zig`, `completion.zig`,
  and `eval.zig` migrated.
- **F6: macOS-baked headless test expectations.** `type cat`
  expected `/bin/cat`; `cd -` expected `/private/tmp`. Both fail
  on Linux's `/usr/bin/cat` + `/tmp`. **FIXED**: switched to
  `stdout_contains` substrings that work on both.
- **F7: bg-job-notice timing race in the new PTY test.**
  `sleep 0.2 & + settle 200` could race the SIGCHLD on a slow
  CI runner. **FIXED**: restructured to use `wait %1` for
  deterministic sync; matched on `Done sleep` without the
  job-number prefix (which depends on test ordering).

| # | check | linux | macos |
|---|---|---|---|
| 1 | `zig build` | PASS | PASS |
| 2 | `zig build test-headless` (80 tests) | PASS | PASS |
| 3 | `zig build test-pty` (65 tests, includes the 10-cycle stress test) | PASS | PASS |
| 4 | `./bin/slash --version` smoke | PASS | PASS |

Linux PTY validation is now continuous — any regression that
breaks the `linux` branch of the harness's `TIOCSCTTY` /
`TIOCSWINSZ` / `O_NOCTTY` switches, or any timing race that
doesn't reproduce on macOS, surfaces as a red check on the PR
before merge.

---

## GitHub Actions CI: 2026-05-15 24:00 UTC

- workflow: `.github/workflows/ci.yml`
- matrix: `ubuntu-latest`, `macos-latest`
- zigline: pinned by URL + hash in `build.zig.zon` (v0.5.0)
- Zig: 0.16.0 via `mlugg/setup-zig@v1`

Every push and PR to `main` runs:
- `zig build`
- `zig build test-headless` (80 tests)
- `zig build test-pty` (65 tests, including the 10-cycle Ctrl-Z/fg
  stress test)
- `./bin/slash --version` smoke check

Linux validation lives in CI — any regression that breaks the
`linux` branch of the PTY harness's `TIOCSCTTY` / `TIOCSWINSZ` /
`O_NOCTTY` switches, or any timing race that doesn't reproduce on
macOS, surfaces as a red check on the PR before merge.

---
