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

- [ ] Every pipeline stage shares one pgid
- [ ] Parent closes setpgid race
- [ ] Child closes setpgid race
- [ ] Job table records pgid before wait/control operations
- [ ] Detached jobs receive independent process groups

---

# 5. Terminal Ownership (Critical)

## Terminal ownership model

The shell is fundamentally a terminal traffic controller.

At any given moment:
- exactly one foreground process group owns the terminal
- the shell itself should NOT receive Ctrl-C intended for the job

Checklist:

- [ ] shell places itself in its own pgid
- [ ] shell owns controlling terminal at startup
- [ ] foreground jobs receive terminal via tcsetpgrp()
- [ ] shell regains terminal after wait
- [ ] stopped jobs relinquish terminal
- [ ] resumed jobs reacquire terminal
- [ ] background jobs never read from terminal
- [ ] SIGTTIN/SIGTTOU handled correctly
- [ ] terminal handoff survives races
- [ ] interactive programs retain terminal ownership correctly

Validation programs:

- [ ] vim
- [ ] less
- [ ] top
- [ ] man
- [ ] ssh
- [ ] nested slash
- [ ] nested bash

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

- [ ] parent ignores interactive job-control signals
- [ ] child restores signal defaults
- [ ] signal disposition reset occurs before execve
- [ ] builtins-in-child behave like external commands

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

- [ ] Ctrl-C hits the entire foreground pipeline
- [ ] Ctrl-Z stops the entire foreground pipeline
- [ ] shell itself survives
- [ ] resumed jobs continue as one group

---

# 7. Pipe Invariants

## Pipe invariants

A pipeline is not correct until ALL unused pipe ends are closed.

Checklist:

- [ ] every child closes unused read ends
- [ ] every child closes unused write ends
- [ ] parent closes its copies too
- [ ] CLOEXEC prevents descriptor leakage across execve
- [ ] pipeline stages inherit only intended fds
- [ ] no stale pipe descriptors survive exec

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

- [ ] EOF propagates correctly through pipelines
- [ ] parent pipe fds are closed after spawn
- [ ] dead pipelines terminate naturally
- [ ] no dangling writers remain

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

- [ ] SIGPIPE is not treated as an internal shell failure
- [ ] pipeline writers terminate naturally
- [ ] shell survives SIGPIPE generated by child jobs

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

- [ ] foreground jobs are waited fully
- [ ] background jobs are eventually reaped
- [ ] detached jobs are intentionally managed
- [ ] no unreachable children exist
- [ ] waitpid EINTR handling is correct
- [ ] unrelated child events do not corrupt active waits

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

- [ ] repeated command execution is stable
- [ ] repeated pipeline execution is stable
- [ ] repeated subshell execution is stable
- [ ] no descriptor growth over time
- [ ] no process leakage over time

---

# 12. Interactive Compatibility Matrix

## Interactive compatibility tests

Slash should be validated against real interactive software.

Required validation set:

- [ ] vim
- [ ] less
- [ ] top
- [ ] ssh
- [ ] nested slash
- [ ] nested bash
- [ ] cat
- [ ] man
- [ ] python REPL
- [ ] node REPL

Behavioral tests:

- [ ] Ctrl-C interrupts foreground job only
- [ ] Ctrl-Z suspends foreground job only
- [ ] fg restores terminal ownership
- [ ] bg resumes without terminal ownership
- [ ] background jobs cannot steal stdin
- [ ] pipelines terminate cleanly
- [ ] heredocs behave interactively
- [ ] process substitution behaves correctly

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

- [ ] parent bookkeeping survives immediate child exit
- [ ] terminal ownership survives rapid stop/continue cycles
- [ ] signal delivery order does not corrupt state
- [ ] wait loops tolerate EINTR
- [ ] pgid assignment is deterministic

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

# 15. Future Runtime Goals

## Future runtime goals

Potential future enhancements:

- signalfd backend on Linux
- kqueue EVFILT_PROC backend on macOS
- pidfd integration on Linux
- structured tty layer
- async job notifications
- pty integration layer
- shell-safe cancellation primitives
- runtime tracing/debug mode
- deterministic shell integration tests

---

# 16. Canonical Validation Commands

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

# 17. Operational Philosophy

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

# 18. Key Lessons Extracted from CS61

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

