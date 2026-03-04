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
- [x] 233 tests — parse + execution coverage

## Next Up

- [ ] Readline / line editing — raw terminal mode, arrow keys, history navigation
- [ ] Rich prompt — directory, git branch, exit code, duration

## Grammar Engine

- [ ] Regex `=~` / `!~` — context-sensitive `/` disambiguation in grammar.zig
- [ ] `cmd` with params `foo(x)` — whitespace-sensitive `pre` field check
- [ ] Heredoc stacking — multiple heredocs per line

## Executor

- [ ] `shift` — needs positional argument tracking ($1, $2, etc.)
- [ ] Positional args `$1`-`$9`, `$*`, `$#` — arg passing to user commands and scripts
- [ ] String interpolation in `"""` heredocs — `$var` expansion inside body text
- [ ] `exec` (replace process) — should execvpe without fork
- [ ] Glob expansion — pre-parse filesystem matching (*.zig, file[0-9], {a,b}.txt)

## Job Control (Phase C)

- [ ] Process groups / `setpgid` — every pipeline gets its own process group
- [ ] Terminal ownership / `tcsetpgrp` — transfer terminal to foreground job
- [ ] Job table — track background/stopped jobs
- [ ] `fg` / `bg` / `jobs` builtins

## Interactive (Phase D)

- [ ] Syntax highlighting — live as you type, using the parser
- [ ] `key` bindings — actual implementation with human-readable combos
- [ ] Multi-line editing — `\` continuation at the prompt

## Persistence (Phase E)

- [ ] SQLite history — every command stored with timestamp, cwd, exit code
- [ ] `Ctrl+R` history search
- [ ] Directory frecency / `j` fuzzy jump
- [ ] `dirs` interactive picker

## Completion (Phase F)

- [ ] Tab completion engine — context-aware (command, file, variable, flag)
- [ ] Completion definitions for common commands (git, zig, etc.)
