# Slash Shell Runtime Audit
## Unix Runtime Invariants, Job Control, and Interactive Correctness

This document captures the operational invariants required for Slash to
behave as a correct interactive Unix shell.

Primary references:

- Harvard CS61 Shell Notes:
  https://cs61.seas.harvard.edu/wiki/2017/Shell3/

- POSIX Shell & Utilities
- Stevens & Rago — APUE
- Existing Slash PLAN.md runtime model

This document is intentionally redundant and operational.
It exists to audit correctness against real Unix shell behavior.

---

# 1. Shell Runtime Model

## Runtime decomposition

Slash separates shell responsibilities into layers:

| Layer | Responsibility |
|---|---|
| Parser | Syntax + grammar |
| Evaluator | Shell semantics |
| Exec | fork/exec/pipe/dup/setpgid/waitpid |
| Job system | Process groups + lifecycle |
| TTY layer | Foreground terminal ownership |
| Interactive layer | REPL, line editing, completion |

The parser is NOT the shell runtime.

The runtime is primarily:
- processes
- pipes
- signals
- process groups
- terminal ownership

---

# 2. Parent vs Child Responsibility Matrix

## Parent vs child responsibilities

| Operation | Parent | Child |
|---|---:|---:|
| Parse command | ✅ | ❌ |
| Expand words | ✅ | ❌ |
| Resolve PATH | ✅ | ❌ |
| Allocate memory | ✅ | ❌ |
| Create pipes | ✅ | ❌ |
| Fork | ✅ | ❌ |
| setpgid | ✅ | ✅ |
| tcsetpgrp | ✅ | ❌ |
| Close unused pipe ends | ✅ | ✅ |
| Apply dup2 redirects | ❌ | ✅ |
| Reset signals to defaults | ❌ | ✅ |
| execve | ❌ | ✅ |
| waitpid | ✅ | ❌ |
| Job bookkeeping | ✅ | ❌ |

---

# 3. Post-Fork Invariants

## Post-fork invariants

After fork(), the child must do almost nothing before execve().

Child-side operations must avoid:
- heap allocation
- locks
- buffered stdio
- hash maps
- arena mutation
- Zig error unwinding
- non-async-signal-safe operations

The child path should consist almost entirely of:
- setpgid
- dup2
- close
- sigaction
- execve
- _exit

Existing Slash alignment:
- `src/exec.zig` intentionally centralizes the post-fork boundary.
- Child execution paths avoid returning Zig errors.
- `_exit()` is used rather than returning to parent control flow.

---

# 4. Process Group Invariants

## Foreground process groups

A foreground pipeline is ONE process group.

Example:

```sh
cat file | grep foo | less
```

The user perceives this as one command even though it is multiple processes.

Therefore:
- all stages share one pgid
- terminal signals target the pgid
- job state aggregates across all children

## setpgid race prevention

Both parent AND child call setpgid().

Child:

```c
setpgid(0, pgid)
```

Parent:

```c
setpgid(pid, pgid)
```

This closes the fork race where either side may run first.

Checklist:

- [x] Every pipeline stage shares one pgid (eval.spawnPipelineNoWait sets `leader_pgid = pids[0]`; subsequent stages spawn with `pgid=leader_pgid`)
- [x] Parent closes setpgid race (`exec.spawn` calls `setpgid(pid, req.pgid)` after fork in parent)
- [x] Child closes setpgid race (`exec.runChild` calls `setpgid(0, req.pgid)` first thing in child)
- [x] Job table records pgid before wait/control operations (`JobTable.setProcesses(j, pgid, pids)` is required before any service call)
- [x] Detached jobs receive independent process groups (default `pgid=0` in spawn means child becomes own group leader)

---

# 5. Terminal Ownership (Critical)

## Terminal ownership model

The shell is fundamentally a terminal traffic controller.

At any given moment:
- exactly one foreground process group owns the terminal
- the shell itself should NOT receive Ctrl-C intended for the job

Checklist:

- [x] shell places itself in its own pgid (`bootstrapInteractive` step 4: `setpgid(0, 0)` after the foreground-acquisition loop)
- [x] shell owns controlling terminal at startup (`bootstrapInteractive` step 5: `tcsetpgrp(tty, getpgrp())`)
- [x] foreground jobs receive terminal via tcsetpgrp() (`terminal.giveToJob` does `tcsetpgrp(tty, j.pgid)`)
- [x] shell regains terminal after wait (`terminal.reclaimForShell` restores `tcsetpgrp(tty, shell_pgid)` and `shell_termios`)
- [x] stopped jobs relinquish terminal (`reclaimForShell` snapshots `j.termios` on `.stopped` and restores shell ownership)
- [x] resumed jobs reacquire terminal (`fgFn`: `giveToJob` → SIGCONT, with prior `j.termios` re-installed first)
- [x] background jobs never read from terminal (kernel SIGTTIN-stops bg readers; verified by `cat &` PTY test)
- [x] SIGTTIN/SIGTTOU handled correctly (interactive shell ignores both; bootstrap forces SIGTTIN to default before the fg-acquisition loop and re-ignores after)
- [ ] terminal handoff survives races (no dedicated stress test; deferred — would need a rapid-stop/continue stress harness)
- [x] interactive programs retain terminal ownership correctly (validated against vim/less/top/man/python/node — see VALIDATION.md run 2026-05-14)

Validation programs:

- [x] vim (run 2026-05-14: PASS)
- [x] less (run 2026-05-14: PASS)
- [x] top (run 2026-05-14: PASS)
- [x] man (run 2026-05-14: PASS)
- [x] ssh (run 2026-05-14: PASS, real nested-PTY end-to-end)
- [x] nested slash (run 2026-05-14: PASS)
- [x] nested bash (run 2026-05-14: PASS)

---

# 6. Signal Discipline

## Interactive shell signal policy

Parent shell behavior:
- ignore SIGINT
- ignore SIGQUIT
- ignore SIGTSTP

Foreground children:
- restore defaults before execve

Checklist:

- [x] parent ignores interactive job-control signals (`installInteractiveSignalHandlers`: ignore QUIT/TSTP/TTIN/TTOU + SIGINT noop; `installShellSignalDefaults`: ignore SIGPIPE for every entry point)
- [x] child restores signal defaults (`exec.runChild` resets INT/QUIT/TSTP/TTIN/TTOU/PIPE/CHLD/HUP to SIG_DFL before execve; same reset in eval.zig direct-fork sites: subshell body, captureProgramStdout, proc-subst child; same reset in repl's Ctrl-X edit-in-editor fork — fixed in 5bbab06)
- [x] signal disposition reset occurs before execve (per the resetSignalDefaults pass in runChild; ignored dispositions don't survive execve only because we explicitly DFL them — POSIX preserves SIG_IGN across execve otherwise)
- [x] builtins-in-child behave like external commands (audited in commit 5bbab06 item A; all forked-builtin-child paths route through `exec.spawn`, which resets dispositions)

## Signals target process groups

Ctrl-C and Ctrl-Z are delivered to foreground PROCESS GROUPS,
not individual processes.

Correct:

```c
kill(-pgid, SIGINT)
```

Incorrect:

```c
kill(pid, SIGINT)
```

Checklist:

- [x] Ctrl-C hits the entire foreground pipeline (kernel routes via tty foreground pgrp = pipeline pgid; validated by PTY test "Ctrl-\ sends SIGQUIT" + manual run 2026-05-14 test 3)
- [x] Ctrl-Z stops the entire foreground pipeline (PTY test "Ctrl-Z stops a foreground sleep, fg resumes" + "Ctrl-Z in a pipeline emits one Stopped notice for the pipeline" — confirms the aggregate pipeline Job state goes `.stopped` rather than mixed; manual run 2026-05-14 test 4 + 2026-05-15 test 10)
- [x] shell itself survives (interactive shell ignores INT/QUIT/TSTP; verified by tests + manual)
- [x] resumed jobs continue as one group (`fgFn` SIGCONTs the entire pgrp via `kill(-pgid, .CONT)`)

---

# 7. Pipe Invariants

## Pipe invariants

A pipeline is not correct until ALL unused pipe ends are closed.

Checklist:

- [x] every child closes unused read ends (`extra_close` list threaded through `exec.SpawnRequest`; closed in `runChild` before redirects)
- [x] every child closes unused write ends (same `extra_close` mechanism; spawnPipelineNoWait builds the per-stage close list)
- [x] parent closes its copies too (parent closes both pipe ends in evalPipeline's after-spawn loop)
- [x] CLOEXEC prevents descriptor leakage across execve (`exec.makePipe` calls `setCloexec` on both ends; bootstrap's controlling-tty fd dup also CLOEXEC'd)
- [x] pipeline stages inherit only intended fds (verified by the explicit dup wiring in spawnPipelineNoWait + `extra_close`)
- [x] no stale pipe descriptors survive exec (CLOEXEC enforces; stress test "200 pipeline iterations" confirms fd count stable within +2 of baseline)

Existing Slash alignment:

- explicit `extra_close` handling
- explicit dup wiring
- CLOEXEC discipline
- centralized pipe creation

---

# 8. EOF Semantics

## EOF semantics

EOF only occurs when ALL write ends are closed.

If ANY process still holds a write fd:
- readers block forever
- pipelines hang

Canonical validation:

```sh
yes | head
```

Expected:
- head exits
- pipe closes
- yes receives SIGPIPE
- pipeline terminates naturally

Checklist:

- [x] EOF propagates correctly through pipelines (headless test "yes | head -n 3" returns 141 (SIGPIPE); manual run 2026-05-14 test 14 PASS)
- [x] parent pipe fds are closed after spawn (evalPipeline's after-spawn loop closes both ends of every pipe)
- [x] dead pipelines terminate naturally (head exits → pipe closes → yes dies of SIGPIPE on next write; verified end-to-end)
- [x] no dangling writers remain (extra_close machinery + parent-close ensures only the intended write end is held)

---

# 9. SIGPIPE Semantics

## SIGPIPE is normal

SIGPIPE is expected behavior in Unix pipelines.

It is not an exceptional condition.

Example:

```sh
yes | head
```

The writer should terminate naturally once the reader exits.

Checklist:

- [x] SIGPIPE is not treated as an internal shell failure (`installShellSignalDefaults` ignores SIGPIPE in the shell process for every entry point)
- [x] pipeline writers terminate naturally (yes / head test confirms; 141 exit propagates correctly per pipefail-on)
- [x] shell survives SIGPIPE generated by child jobs (headless test "shell survives" + "echo upstream | head -n 1; echo done" exercises the builtin-in-pipeline-child path)

---

# 10. Waiting / Reaping Invariants

## Child lifecycle invariants

Every child launched by Slash must eventually:
- be waited
- be represented in JobTable
- or be intentionally detached

## Zombie prevention

Slash is a long-lived process.

Zombie accumulation is a correctness failure.

Checklist:

- [x] foreground jobs are waited fully (`terminal.runForeground` blocks via `job.service(.foreground, target)` until done or stopped)
- [x] background jobs are eventually reaped (safe-point `service(.poll)` calls + SIGCHLD handler sets `child_event_pending` flag drained by `eval.drainChildEvents`)
- [x] detached jobs are intentionally managed (`evalDetached` registers in JobTable; `disown` is the explicit opt-out; stress test "100 detached jobs are reaped without explicit wait" confirms)
- [x] no unreachable children exist (every fork goes through JobTable; verified by stress test counting reapings via tracked pids)
- [x] waitpid EINTR handling is correct (`exec.waitOne` loops on EINTR)
- [x] unrelated child events do not corrupt active waits (foreground service loops on the target job's state, not on event pid; unrelated events are applied to their own jobs and the loop continues)

Existing Slash alignment:

- centralized wait service abstraction
- monotonic job state recomputation
- foreground wait loops
- polling service path

---

# 11. Long-Lived Shell Invariants

## Long-lived process discipline

Unlike short-lived programs, shells persist indefinitely.

Therefore Slash must avoid:
- fd leaks
- zombie leaks
- stale terminal ownership
- leaked pipe ends
- leaked process groups
- unreaped detached children
- allocator growth from command execution

Checklist:

- [x] repeated command execution is stable (memory test: 500 iterations of mixed eval, no allocator leaks via `std.testing.allocator`)
- [x] repeated pipeline execution is stable (stress test: 200 iterations of `echo hi | wc -l >/dev/null`, fd count within +2 baseline)
- [x] repeated subshell execution is stable (covered indirectly by 500-iter memory test; subshell forks are part of the mix)
- [x] no descriptor growth over time (stress test: cross-platform fd probe via `fcntl(F_GETFD)` over `[0, RLIMIT_NOFILE.cur)`)
- [x] no process leakage over time (stress test: 100 detached `true &` iterations, race-free join via tracked pids + `drainZombies`)

---

# 12. Interactive Compatibility Matrix

## Interactive compatibility tests

Slash should be validated against real interactive software.

Required validation set:

- [x] vim (run 2026-05-14: PASS)
- [x] less (run 2026-05-14: PASS)
- [x] top (run 2026-05-14: PASS)
- [x] ssh (run 2026-05-14: PASS)
- [x] nested slash (run 2026-05-14: PASS)
- [x] nested bash (run 2026-05-14: PASS)
- [x] cat (run 2026-05-14: PASS — fg, bg+SIGTTIN both)
- [x] man (run 2026-05-14: PASS)
- [x] python REPL (run 2026-05-14: PASS)
- [x] node REPL (run 2026-05-14: PASS)

Behavioral tests:

- [x] Ctrl-C interrupts foreground job only (manual run test 3 + PTY test "Ctrl-\ SIGQUIT to fg")
- [x] Ctrl-Z suspends foreground job only (manual run 2026-05-14 test 4; targeted run 2026-05-15 tests 5, 9–11; PTY tests "Ctrl-Z stops a foreground sleep, fg resumes it", "Ctrl-Z auto-notices Stopped and fg auto-notices Continued", "Ctrl-Z in a sequence suspends the rest of the sequence" — `outcomeStopped` propagates the stop up through evalSequence/evalWhile/evalFor so the abandoned tail does not run, "Ctrl-Z in a pipeline emits one Stopped notice for the pipeline", "Ctrl-Z does not emit a redundant 'slash: exit' notice")
- [x] fg restores terminal ownership (manual run test 4: `fg` resumed sleep cleanly; `terminal.giveToJob` does the handoff)
- [x] bg resumes without terminal ownership (PTY test "Ctrl-Z then bg lets the job finish without blocking" — bg builtin doesn't touch tty ownership)
- [x] background jobs cannot steal stdin (kernel SIGTTIN-stops them; PTY test "cat & stops with SIGTTIN" + manual run test 2)
- [x] pipelines terminate cleanly (manual run test 14 yes-head + headless yes-pipe regression test)
- [x] heredocs behave interactively (existing heredoc support; PLAN §3.1 + headless tests for `<<TAG` / `<<'TAG'` with column-determined dedent)
- [x] process substitution behaves correctly (existing `<(...)` and `>(...)` support; headless tests + cleanup-on-termination per PLAN §7 Rule 25)

---

# 13. Race Condition Audit

## Race condition audit

Shells are inherently concurrent systems.

Audit all:
- fork/exec windows
- setpgid races
- waitpid timing races
- terminal handoff races
- signal delivery races
- child-exit-before-parent-bookkeeping races
- pipeline shutdown races

Checklist:

- [x] parent bookkeeping survives immediate child exit (caught a real UAF in `disown -a` during this work — Job referenced after free; fixed via `isDisownable` filter)
- [ ] terminal ownership survives rapid stop/continue cycles (no dedicated stress test; deferred — would need a synthetic Ctrl-Z/fg loop)
- [x] signal delivery order does not corrupt state (SIGCHLD handler is flag-only-async-signal-safe; reaping happens in shell context at safe points)
- [x] wait loops tolerate EINTR (`exec.waitOne` and `serviceForeground` both loop on EINTR)
- [x] pgid assignment is deterministic (parent + child both call setpgid; fork-race-closed; verified by every job-control test)

---

# 14. Existing Slash Runtime Alignment

## Existing runtime alignment

Current runtime alignment already includes:

- centralized exec subsystem
- explicit process groups
- monotonic job state
- CLOEXEC discipline
- child signal reset
- wait abstraction layer
- pipeline fd ownership tracking
- foreground wait service
- parent/child role separation

Relevant files:

- `src/exec.zig`
- `src/job.zig`
- `src/eval.zig`
- `src/session.zig`
- `PLAN.md`

---

# 15. Canonical Validation Commands

## Required validation commands

These commands should work identically to established Unix shells.

Basic:

```sh
echo hello
pwd
ls | cat
```

Signals:

```sh
sleep 10
# Ctrl-C

sleep 10
# Ctrl-Z
```

Pipelines:

```sh
yes | head
cat | cat | cat
seq 1000000 | less
```

Background jobs:

```sh
sleep 30 &
fg
bg
jobs
```

Nested shells:

```sh
bash
slash
```

Interactive:

```sh
vim
less
python
node
```

---

# 16. Operational Philosophy

## Shell philosophy

A shell is not merely:
- a parser
- a scripting language
- a command launcher

A shell is:
- a long-lived process supervisor
- a process-group coordinator
- a signal router
- a terminal ownership manager
- an interactive runtime environment

The parser is only one subsystem.

Correct shell behavior is primarily determined by:
- process discipline
- signal discipline
- terminal discipline
- descriptor discipline
- race-condition handling

---

# 17. Key Lessons Extracted from CS61

## High-value lessons extracted

The Harvard CS61 shell material emphasizes:

- process groups are fundamental
- terminal ownership is central
- EOF semantics are subtle
- SIGPIPE is normal
- shells are concurrent systems
- races are unavoidable and must be designed around
- pipe fd hygiene is critical
- child execution paths must stay minimal
- interactive correctness matters more than parsing cleverness

These lessons form the operational foundation for Slash.

