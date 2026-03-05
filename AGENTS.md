# Slash

A modern shell written in Zig. Grammar-driven lexer and LALR(1) parser that
emits s-expressions — no AST, no intermediate representation. The executor
walks s-expressions recursively and dispatches on the head tag.

## Architecture

```
slash.grammar → grammar.zig → parser.zig (lexer + parser, tags + keywords inline)
exec.zig       (s-expression executor: fork/exec/pipe)
main.zig       (CLI, REPL)
lexer.zig      (shell-specific lexer: heredoc, indent, regex)
readline.zig   (line editing, highlighting, completion)
prompt.zig     (prompt rendering, format escapes, git status)
history.zig    (SQLite history + frecency)
regex.zig      (Oniguruma C API wrapper)
```

Pipeline: `source text → lexer → tokens → parser → s-expressions → executor`

## Key Files

- `slash.grammar` — lexer rules + parser rules (single source of truth)
- `src/grammar.zig` — generic grammar tool, generates parser.zig from any .grammar file
- `src/parser.zig` — **generated, do not edit** — regenerate with `./bin/grammar slash.grammar src/parser.zig`
- `src/lexer.zig` — shell-specific lexer extensions (heredoc, indent, regex disambiguation)
- `src/exec.zig` — walks s-expressions, executes commands (struct: `Shell`)
- `src/main.zig` — entry point, CLI flags, REPL loop
- `src/readline.zig` — line editing, key bindings, syntax highlighting, tab completion
- `src/prompt.zig` — prompt rendering with format escapes, git status (reads `.git/HEAD`)
- `src/history.zig` — SQLite interface for history and directory frecency
- `src/regex.zig` — Oniguruma regex wrapper (Zig FFI)
- `regex/` — Oniguruma 6.9.9 C source (compiled by build.zig)

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
- Lexer patterns are Oniguruma regex, compiled at init, matched via first-char dispatch table
- S-expressions are the interface between parser and executor — no AST
- `std.debug.print` for all user-facing output (Zig 0.15 Writer API is buffer-based)
- Commit messages: imperative, 1-2 sentences focused on "why"
- Uppercase variables are auto-exported; no `export` keyword
- `cmd` is the single mechanism for user-defined commands (no aliases, no functions)
- Block syntax: braces `{}` for one-liners, `INDENT`/`OUTDENT` for scripts — grammar is identical for both

## Design Decisions

- **No AST** — parser outputs s-expressions directly (`mode = 'sexp'`); executor pattern-matches on head tags
- **No separate tag/keyword files** — tag enum and keyword matchers are generated inline in parser.zig
- **Grammar is documentation** — the grammar file is the authoritative specification of the language
- **SQLite for all state** — `~/.slash/history.db`, frecency derived from history `cwd` column, no flat files
- **`??` for defaults** — `$1 ?? 8080` instead of `${1:-8080}`
- **`cmd ???`** — command-not-found hook, three characters
- **Heredocs use `'''`/`"""`/`` ``` ``** — no `<<EOF` arbitrary tokens
- **`= expr`** — bare `=` followed by expression evaluates and prints

## Reference

- `README.md` — full project documentation for developers
- `INTERNALS.md` — grammar reference, s-expression format, job control details
