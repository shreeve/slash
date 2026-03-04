# Slash — TODO

Features not yet implemented, organized by category and priority.

## Recently Completed

- [x] `break` / `continue` in loops — flow state unwinding
- [x] Auto-cd — if sole arg is a directory path, cd to it
- [x] `..` / `...` / `....` etc. — dynamic dot-counter, unlimited levels
- [x] Signal handling — shell ignores SIGINT/QUIT/TSTP, children reset to defaults
- [x] Heredocs — all 3 types (`'''`, `"""`, `` ```lang ``), margin stripping, pipe continuation
- [x] Herestrings (`<<<`) — pipe content to stdin
- [x] Process substitution (`<(cmd)`, `>(cmd)`) — /dev/fd/N passing
- [x] Subshell capture (`$(cmd)`) — fork, pipe, read stdout
- [x] Redirections — all forms (>, >>, <, 2>, 2>>, &>, 2>&1)
- [x] Variable expansion — $name, $?, $$, ${name}
- [x] Math evaluation — f64, all operators, smart formatting
- [x] `= expr` display command — evaluate and print math
- [x] No-space math — `=22/7`, `=2^10` via operator spacing retry
- [x] Comparison evaluation — eq/ne/lt/gt/le/ge with smart numeric/string logic
- [x] `cmd ???` hook — define, show, delete
- [x] Readline — raw terminal mode, arrow keys, history (512 entries), Ctrl+A/E/K/U/C/D
- [x] 233 tests — parse + execution coverage
- [x] Rich prompt — PROMPT variable, format escapes (%t %u %h %d %g %e %D %$ %fg %bg %> %r), hex colors, git branch via .git/HEAD, command timing, ~/.slashrc
- [x] `cmd` with params — `cmd greet(name) echo hello $name`, LPAREN_TIGHT token, UserCmd struct with owned source
- [x] Indent blocks — INDENT/OUTDENT tokens from lexer, `block = INDENT line* OUTDENT`, works for cmd/if/for/while, nested
- [x] `exec` (replace process) — execvpeZ without fork, replaces current process
- [x] Job control — process groups (setpgid), terminal ownership (tcsetpgrp), job table, WUNTRACED for Ctrl+Z, fg/bg/jobs builtins, background reaping
- [x] Regex literals — `~|pattern|flags` standalone, `/pattern/` after `=~`/`!~`, any delimiter, Oniguruma execution
- [x] Extract slash-specific lexer logic from grammar.zig into lexer.zig — heredoc, indent, regex are shell-specific, not generic grammar engine
- [x] Positional args `$1`-`$9`, `$*`, `$#` — arg passing to user commands and scripts
- [x] `shift` — shifts positional args left, drops $1
- [x] String interpolation in `"""` and `` ```lang `` heredocs — `$var`, `${var}`, `\$` escape

## Executor

- [x] Glob expansion — *, ?, [a-z], {a,b}, ** recursive, plus regex globs (~|pattern|), sorted output
- [ ] Regexp expansion - similar but using our new regex types

## Interactive (Phase D)

- [ ] Syntax highlighting — live as you type, using the parser
- [ ] `key` bindings — actual implementation with human-readable combos
- [ ] Multi-line editing — blank-line continuation for indent blocks, `\` continuation at the prompt

## Persistence (Phase E)

- [ ] SQLite history — every command stored with timestamp, cwd, exit code
- [ ] `Ctrl+R` history search
- [ ] Directory frecency / `j` fuzzy jump
- [ ] `dirs` interactive picker

## Completion (Phase F)

- [ ] Tab completion engine — context-aware (command, file, variable, flag)
- [ ] Completion definitions for common commands (git, zig, etc.)
