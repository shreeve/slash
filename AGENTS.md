# Slash

A modern shell written in Zig. Grammar-driven lexer and LALR parser.

## Architecture

```
slash.grammar → grammar.zig → parser.zig (lexer + parser)
                               (tags + keywords generated inline in parser.zig)
exec.zig                       (s-expression executor: fork/exec/pipe)
main.zig                       (CLI, REPL)
regex.zig                      (regex wrapper, powered by Oniguruma)
```

## Key Files

- `slash.grammar` — lexer rules + parser rules (single source of truth)
- `src/grammar.zig` — generic grammar tool, generates parser.zig from any .grammar file
- `src/parser.zig` — **generated, do not edit** — regenerate with `./bin/grammar slash.grammar src/parser.zig`
- `src/exec.zig` — walks s-expressions, executes commands (struct: `Shell`)
- Tag enum and keyword matchers are generated inline in parser.zig (no separate file needed)
- `src/regex.zig` — regex wrapper (Oniguruma C API)
- `regex/` — Oniguruma 6.9.9 C source (compiled by build.zig)
- `SLASH.md` — language specification

## Build

```
zig build              # build bin/slash
zig build grammar      # build bin/grammar
zig build run          # build and run slash
```

## Regenerate Parser

```
zig build grammar
./bin/grammar slash.grammar src/parser.zig
zig build
```

## Zig Version

Zig 0.15.2. See `docs/ZIG-0.15.2.md` for API changes (Writergate, ArrayList .empty pattern, etc).

## Conventions

- Do not edit `src/parser.zig` — it is generated
- Lexer patterns are Oniguruma regex, compiled at init, matched via first-char dispatch table
- S-expressions are the interface between parser and executor — no AST
- `std.debug.print` for all user-facing output (Zig 0.15 Writer API is buffer-based)
- Commit messages: imperative, 1-2 sentences focused on "why"
