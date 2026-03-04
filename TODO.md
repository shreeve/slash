# Slash — TODO

Features not yet implemented, organized by category and priority.

## Next Up

- [ ] `break` / `continue` in loops — need error/signal mechanism to unwind loop body
- [ ] Auto-cd — fallback when command not found and path is a directory
- [ ] `..` / `...` builtins — shorthand for `cd ..` / `cd ../..`
- [ ] Signal handling (SIGINT, SIGTSTP, SIGPIPE, SIGCHLD) — Ctrl+C won't kill the shell
- [ ] Readline / line editing — arrow keys, home/end, delete, history navigation

## Grammar Engine

- [ ] Regex `=~` / `!~` — context-sensitive `/` disambiguation in grammar.zig
- [ ] `cmd` with params `foo(x)` — whitespace-sensitive `pre` field check
- [ ] Heredoc stacking — multiple heredocs per line

## Executor

- [ ] `shift` — needs positional argument tracking ($1, $2, etc.)
- [ ] Positional args `$1`-`$9`, `$*`, `$#` — arg passing to user commands and scripts
- [ ] String interpolation in `"""` heredocs — `$var` expansion inside body text
- [ ] `exec` (replace process) — currently evals inner cmd, should execvpe without fork
- [ ] Glob expansion — pre-parse filesystem matching (*.zig, file[0-9], {a,b}.txt)

## Job Control (Phase C)

- [ ] Process groups / `setpgid` — every pipeline gets its own process group
- [ ] Terminal ownership / `tcsetpgrp` — transfer terminal to foreground job
- [ ] Job table — track background/stopped jobs
- [ ] `fg` / `bg` / `jobs` builtins

## Interactive (Phase D)

- [ ] Rich prompt — directory, git branch, exit code, duration
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
