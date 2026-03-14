# Changelog

## 2026-03-14 (cont.)

### `src/exec.zig`
- Failed `exec` builtin now restores shell signal handlers in interactive mode instead of leaving SIGINT/SIGQUIT/SIGTSTP at SIG_DFL.
- Single-quoted string `''` escape is now processed at runtime (e.g., `'it''s'` → `it's`), matching the grammar.
- `while`/`until` loops now check flow state after condition evaluation, preventing extra body execution on exit/break in condition.
- `exec` builtin uses atomic `saveStdFds` for redirect save/restore instead of independent per-fd dups.
- `**` glob patterns now recursively walk subdirectories (depth-capped at 32).

### `src/lexer.zig`
- Heredoc trailing-token buffer increased from 64 to 255; limit now tracks array size instead of hardcoded constant.

### `src/prompt.zig`
- Global `esc_buf` for color escape sequences replaced with a caller-provided stack-local buffer.

### Documentation
- Fixed README inline math examples to include required `= ` prefix.
- Fixed README "no local scope" claim that contradicted `cmd` scoping description.
- Corrected regex flag documentation from `[gimsux]` to `i` (case-insensitive only).
- Removed nonexistent `glob` token type from INTERNALS token table.
- Updated INTERNALS ident pattern description to cover paths and glob forms.

## 2026-03-14

### `src/exec.zig`
- Builtin `exec` failure now reports and returns nonzero instead of exiting the shell process.
- `wait <pid>` now consumes cached job completion when async reap already collected the child.
- Pipeline stage children force non-interactive eval mode to avoid nested foreground job-control behavior.
- `=~` and `!~` now accept evaluated RHS expressions (for example, regex values held in variables).
- Malformed fd redirection forms now fail with explicit diagnostics instead of being silently dropped.
- Command-definition OOM paths now clean up allocations consistently and avoid non-owned string fallbacks.

### `src/lexer.zig`
- Regex token flag handling is aligned with runtime support.
- Heredoc close delimiters now terminate correctly when followed by inline separators/operators.
- Bare `/.../` regex forms are recognized in `try` arm pattern positions with narrow context gating.

### `src/readline.zig`
- Delete-key escape parsing now validates trailing-byte reads before use to avoid undefined behavior on partial sequences.

### `src/main.zig`
- REPL multiline continuation is now driven by syntax completeness rather than blank continuation lines.
- Multiline buffer allocation failures now abort the current entry explicitly with a clear error.

### `src/history.zig`
- History append/rewrite paths now fsync before treating writes as persisted.
- Rewrite rename/cleanup failures are now surfaced with diagnostics.
- Parent directory is fsynced after atomic replacement for stronger durability.

### `src/grammar.zig`
- Parser-generator literal unescape path now uses dynamic buffering instead of a fixed-size stack buffer.
- Action position references now parse full numeric tokens (`10`, `...12`, `~11`) across generator code paths.
