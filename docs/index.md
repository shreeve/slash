---
title: Slash
description: A Unix shell with structured commands, composable pipelines, and first-class jobs.
---

# Slash

> A Unix shell with structured commands, composable pipelines, and
> first-class jobs — one grammar, end to end.

[![CI](https://github.com/shreeve/slash/actions/workflows/ci.yml/badge.svg)](https://github.com/shreeve/slash/actions/workflows/ci.yml)

<img src="assets/slash-512w.png" alt="Slash" width="180" align="right">

Slash is a Unix shell built around a three-stage execution model:
**Shape** (parsed structure) → **Program** (lowered executable
semantics, immutable) → **Job** (runtime instance with process
group, pids, state, result). The same grammar drives parsing,
syntax highlighting, completion, and editor behavior. There is no
second tokenizer, no regex highlighting hack, no separate
configuration language.

Slash chooses **correctness over POSIX compatibility** in the
places shells have historically lied:

- `pipefail` is on by default, no surface syntax to disable
- Variables are scalars or lists; no implicit word-splitting
- `argv` is never flattened to a shell string; expansion happens
  exactly once per word
- `Job` state transitions monotonically:
  `pending → running → {stopped ↔ running}* → done`

## What ships today

- **Real Unix shell.** Process groups, terminal ownership,
  signal discipline, pipe hygiene, reaping — all
  [CHECKLIST](https://github.com/shreeve/slash/blob/main/CHECKLIST.md)-verified.
- **Fish-class interactive UX.** Syntax highlighting as you type,
  history autosuggestions (dim ghost text), intelligent Tab
  completion, smart prefix-aware Up/Down navigation,
  reverse-i-search via Ctrl-R, rich prompts (any zsh `PROMPT`
  works), mid-prompt `[N] Done` notifications (opt-in via
  `$SLASH_NOTIFY=immediate`).
- **`key` builtin** for user-configurable keybindings, with
  layout-aware Option-key handling on macOS — `key Option-L "ls
  -la\n"` works on any Mac out of the box, no terminal config
  flips required.
- **`time` keyword** for honest wall + user + sys timing of any
  pipeline, block, or control-flow construct.
- **Structured introspection.** `slash --dump-sexp`,
  `--dump-shape`, `--dump-program` give you the parse,
  typed-shape, and lowered-program forms of any source. Every
  diagnostic carries a stable code (SHxxxx/LWxxxx/EVxxxx/EXxxxx/JBxxxx).

## Install

Slash requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
git clone https://github.com/shreeve/slash
cd slash
zig build -Doptimize=ReleaseFast
./bin/slash --version
```

The `bin/slash` binary is self-contained — no runtime dependencies
beyond libc and a TTY. Copy it anywhere on your `$PATH`.

## Quick start

```sh
# Run interactively (in slash)
./bin/slash

# One-liner
./bin/slash -c 'echo hello, world'

# Run a script
./bin/slash my-script.sh arg1 arg2
```

Drop the [`.slashrc.example`](https://github.com/shreeve/slash/blob/main/.slashrc.example)
template at `~/.slashrc` and uncomment the recipes you want:

```sh
# Prompt
export PROMPT='%F{#ecede8}%K{#43669d}%D{%H:%M:%S} %F{#43669d}%K{#81a1c7}%F{#ecede8} %n@%m %F{#81a1c7}%K{}%F{#ecede8}%k %~> %f'

# Editor-time abbreviations
str ll { ls -la }
str gst { git status }

# Key bindings
key Option-L "ls -la\n"
key Option-G "git status\n"
```

## Documentation

The full design lives in markdown in the repo:

- [README](https://github.com/shreeve/slash/blob/main/README.md) —
  high-level overview and current capabilities
- [PLAN](https://github.com/shreeve/slash/blob/main/PLAN.md) —
  the design constitution. The §14 test ("does this improve
  `Command` clarity, `Pipeline` correctness, `Program`
  composability, or `Job` control?") is the rule every feature
  has to pass.
- [CHECKLIST](https://github.com/shreeve/slash/blob/main/CHECKLIST.md)
  — line-by-line operational-correctness audit (POSIX + APUE +
  Harvard CS61). 77/77 boxes checked.
- [VALIDATION](https://github.com/shreeve/slash/blob/main/VALIDATION.md)
  — empirical log of interactive correctness runs against real
  software (vim, less, top, ssh, nested shells, Python/node
  REPLs).

A `man slash` page lives at
[`docs/slash.1`](https://github.com/shreeve/slash/blob/main/docs/slash.1)
in the repo. Install it manually with:

```sh
sudo install -m 644 docs/slash.1 /usr/local/share/man/man1/
```

## Tests

166 tests covering parse, lower, runtime, builtins, signal/job
discipline, and interactive editor behavior:

```sh
zig build test
```

CI runs on Linux + macOS for every push; status badge at the
top of this page reflects the latest `main`.

## Credits

The interactive line editor is
[zigline](https://github.com/shreeve/zigline) — a separate
project that grew alongside slash to provide the primitives a
modern shell needs: hint hooks, transient input mode, mid-prompt
`printAbove`, and the keymap layer slash extends.
