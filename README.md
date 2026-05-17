<p align="center">
  <img src="docs/assets/slash-1280w.png" alt="Slash" width="500">
</p>

<div align="center">
  <strong>Slash runs programs. It is not a programming language.</strong><br>
  <em>Fish-class editing, POSIX-shaped syntax, real Unix job control.</em>
</div>

<p align="center">
  <a href="https://github.com/shreeve/slash/actions/workflows/ci.yml">
    <img src="https://github.com/shreeve/slash/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

---

Slash is a Unix shell written in Zig for people who want modern
interactive ergonomics without a new programming language to learn. It
runs programs, builds pipelines, and manages jobs with real Unix
semantics — stable `argv`, no implicit word-splitting, correct process
groups and terminal ownership. The editor is modern. The shell stays a
shell.

## Taste

```sh
# values and lists
name=world
files=[README.md PLAN.md CHECKLIST.md]

# pipelines with pipefail on by default
grep -l zig $files | sort -u > hits.txt || echo no matches

# control flow
if test -d /tmp
  echo found
else
  echo missing

# user-defined commands
cmd greet
  echo "hello, $1"

# jobs
sleep 60 &
jobs
fg %1
```

Indent and brace blocks have the same semantics. The sample above is
indent-style; `{ … }` form is handy for one-liners, e.g.
`if test -d /tmp { echo found }`.

## What makes Slash different

- **Words are words, not strings to re-parse.** Expansion happens once,
  per word. `argv` is never flattened into a shell string and
  re-tokenized. No implicit word-splitting, no hidden coercion.
- **Pipelines are correct by default.** `pipefail` is always on, so
  `a | b | c` fails when any stage fails. Redirections, expansions, and
  pipeline wiring are resolved once, at lowering time.
- **Jobs are runtime objects, not prompt decorations.** Process groups,
  terminal ownership, signals, and explicit state transitions:
  `pending → running → {stopped ↔ running}* → done`.
- **One grammar drives everything the user sees.** Parsing, syntax
  highlighting, Tab completion, and formatting share one syntax model.
  What the parser accepts is what the highlighter colors and the
  completer understands.

## Interactive use

Slash ships fish-class interactive UX: syntax highlighting, history
autosuggestions, Ctrl-R search, prefix-aware Up/Down, and Tab
completion (paths, `$PATH` commands, builtin specs for `cd` / `kill`
/ `fg` / `bg`). Key bindings are configurable via the `key` builtin,
`$PROMPT` accepts zsh-style prompt strings, and job-state changes
can be surfaced inline.

Four built-in syntax highlighting themes ship: `github-dark`,
`github-light`, `vscode-dark`, `vscode-light` — colors lifted directly
from GitHub's Primer design system and VS Code's `Dark+` / `Light+`
defaults. Set `$SLASH_THEME=github-light` (or any of the four) in
`~/.slashrc`. With `$SLASH_THEME` unset, Slash auto-detects the
terminal background via `$COLORFGBG` and picks the GitHub variant.

For rich completions across ~1100 modern CLIs (`git checkout` branches,
`docker run --flags`, `kubectl get` resources, `cargo`, `gh`,
`terraform`, ...), `brew install carapace` (or `apt install carapace-bin`).
Slash detects it on `$PATH` and delegates the long tail of completion
specs transparently, without ever becoming a runtime for completion
scripts.

See [`.slashrc.example`](./.slashrc.example) for prompts, `str`
abbreviations, and key-binding recipes.

## Status

Slash is tested as a Unix shell, not just as a parser.

- **v1.2.0.** Linux + macOS CI is green.
- **166 / 166 tests** passing: 102 unit + headless, 64 PTY-driven.
- **77 / 77 items** checked in [`CHECKLIST.md`](./CHECKLIST.md), the
  operational-correctness audit drawn from POSIX, APUE, and Harvard CS61.
- **Interactive validation** in [`VALIDATION.md`](./VALIDATION.md)
  covers vim, less, ssh, nested shells, and Python/node REPLs.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
git clone https://github.com/shreeve/slash
cd slash

zig build                            # produces ./bin/slash
zig build run -- --version
zig build run -- -c 'echo hello'
zig build test
```

Apart from libc, the binary has no runtime package dependencies. Copy
`bin/slash` anywhere on your `$PATH`.

## Design

> Does this improve `Command` clarity, `Pipeline` correctness,
> `Program` composability, or `Job` control? If not, do not build it.

Slash has one execution path: source is parsed into `Shape`, lowered
into an immutable `Program`, then launched as a `Job`. That boundary
keeps parsing, expansion, redirection, pipeline wiring, and job control
separate instead of letting shell strings leak across phases.

The grammar engine is [nexus](https://github.com/shreeve/nexus).
`slash.grammar` and `src/slash.zig` are the Slash-specific inputs;
`src/parser.zig` is generated from them. The line editor is
[zigline](https://github.com/shreeve/zigline).

The full design lives in [`PLAN.md`](./PLAN.md): types, semantic rules,
signal model, job model, and testing strategy.

## Documentation

- [Documentation site](https://shreeve.github.io/slash/)
- [`man slash`](./docs/slash.1)
- [Example config](./.slashrc.example)

## License

MIT.
