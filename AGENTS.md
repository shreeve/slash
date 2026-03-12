# Slash

A modern shell written in Zig. Grammar-driven lexer and SLR(1) parser that
emits s-expressions — no AST, no intermediate representation. The executor
walks s-expressions recursively and dispatches on the head tag.

## Architecture

```
grammar.zig  (build-time tool — reads slash.grammar, emits parser.zig)
parser.zig   (generated — token patterns, SLR tables, s-expression builder)
lexer.zig    (shell-specific lexer state: heredocs, indent, regex literals, math)
exec.zig     (walks s-expressions, fork/exec/pipe, builtins, job control)
main.zig     (CLI entry point, REPL loop, key bindings, continuation logic)
readline.zig (line editor: raw mode, cursor, tab completion, highlighting, overlay search)
prompt.zig   (prompt rendering: format escapes, git branch, duration)
history.zig  (flat-file command history, search, suggest)
regex.zig    (libc POSIX regex wrapper for executor =~/!~/globs)
```

Pipeline: `source text → lexer → tokens → parser → s-expressions → executor`

Dependency flow:
```
main → readline → (callbacks into exec)
main → exec → parser → (uses lexer)
main → prompt
main → history
exec → regex
exec → lexer → parser (BaseLexer)
```

## Key Files

- `slash.grammar` — lexer rules + parser rules (single source of truth)
- `src/grammar.zig` — generic grammar tool, generates parser.zig from any .grammar file
- `src/parser.zig` — **generated, do not edit** — regenerate with `./bin/grammar slash.grammar src/parser.zig`
- `src/lexer.zig` — shell-specific lexer extensions (heredoc, indent, regex disambiguation)
- `src/exec.zig` — walks s-expressions, executes commands (struct: `Shell`)
- `src/main.zig` — entry point, CLI flags, REPL loop
- `src/readline.zig` — line editing, key bindings, syntax highlighting, tab completion
- `src/prompt.zig` — prompt rendering with format escapes, git branch (reads `.git/HEAD`)
- `src/history.zig` — flat-file history (`~/.slash/history`)
- `src/regex.zig` — libc POSIX regex wrapper (ERE) for `=~`, `!~`, glob expansion

## Build

```
zig build              # build bin/slash
zig build grammar      # build bin/grammar
zig build run          # build and run slash
```

## Regenerate Parser

When `slash.grammar` changes:

```
zig build grammar
./bin/grammar slash.grammar src/parser.zig
zig build
```

## Zig Version

Zig 0.15.2. See `docs/ZIG-0.15.2.md` for API changes (Writergate, ArrayList
`.empty` pattern, etc).

## Conventions

- Do not edit `src/parser.zig` — it is generated from `slash.grammar`
- Lexer patterns are regex strings matched by a pure-Zig interpreter (no C regex library), dispatched via first-char table
- S-expressions are the interface between parser and executor — no AST
- `std.debug.print` for all user-facing output (Zig 0.15 Writer API is buffer-based)
- Commit messages: imperative, 1-2 sentences focused on "why"
- Uppercase variables are auto-exported; no `export` keyword
- `cmd` is the single mechanism for user-defined commands (no aliases, no functions)
- `cmd` bodies have automatic local scope — assignments do not leak
- Block syntax: braces `{}` for one-liners, `INDENT`/`OUTDENT` for scripts — grammar is identical for both
- String lists: `args = [find .]`, `args += [...]`, `run $args`
- `ok` runs a command silently (suppresses stdout+stderr), returns exit code
- `run` executes a list-valued variable as a command with redirections and pipes
- `$0` is the full absolute path of the executing script
- `~` and `~/path` expand to `$HOME` in all arguments

## Design Decisions

- **No AST** — parser outputs s-expressions directly (`mode = 'sexp'`); executor pattern-matches on head tags
- **No separate tag/keyword files** — tag enum and keyword matchers are generated inline in parser.zig
- **Grammar is documentation** — the grammar file is the authoritative specification of the language
- **Flat-file history** — `~/.slash/history` (TSV), loaded into memory on startup (records cwd alongside each command)
- **`??` for defaults** — `$1 ?? 8080` instead of `${1:-8080}`
- **`cmd ???`** — command-not-found hook, three characters
- **Heredocs use `'''`/`"""`/`` ``` ``** — no `<<EOF` arbitrary tokens
- **`= expr`** — bare `=` followed by expression evaluates and prints
- **`unless ok`** — idempotent check pattern for infrastructure scripts

## Reference

- `README.md` — full project documentation for developers
- `INTERNALS.md` — grammar reference, s-expression format, job control details
