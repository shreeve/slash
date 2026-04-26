# Slash — Roadmap to Complete

This file lists every concrete unit of work that stands between Slash today
and Slash 1.0. As items ship, **delete them from this file**. When the
file is empty, Slash 1.0 ships.

Items are grouped by tier, but tiers are advisory — within a tier, ship in
whichever order makes sense.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

## Tier 3 — robustness

### 1. Memory ownership audit and tightening

Concrete model needs locking down:

| Arena | Lifetime | Owns |
|---|---|---|
| Session arena | shell process | `JobTable`, `BuiltinSet`, `VarStore` values, `cmd` definitions |
| Eval scratch arena | one statement | Word expansions, NUL-terminated argv buffers, redirect plans, expanded glob lists |
| Promoted definitions | session | `cmd`-body Programs, retained command-text strings |

Detached jobs that retain Programs need their Program promoted to
session arena (PLAN §6.8).

Stress test: 10,000 commands in a row, no leaks, no fragmentation. Easy
to build now, hard to retrofit later.

### 2. Signal handling at the REPL boundary

PLAN §18-§19 documents the model. The implementation:

- Parent shell ignores `SIGINT` while reading input.
- Children reset to default before `exec` (already done).
- `Ctrl-C` cancels the line being edited, emits a fresh prompt (REPL).
- `Ctrl-Z` doesn't crash anything; for now, ignored (full job-control later).
- `SIGCHLD` reaping at safe points (already done in `service`).
- Foreground-job's process group receives terminal-generated signals;
  shell does not forward `SIGINT` itself.


### 3. Diagnostic infrastructure actually used

We built `diag.Sink` / `ListSink` / codes per PLAN §16. Almost nothing
emits structured diagnostics. Every `slash: parse error` print today
should be a `Diagnostic` with code `SH0001`, span, and helpful note.

The REPL's red squiggles (live error preview) are downstream of this.

Specific call sites needing structured diagnostics:
- `shape.parse` — promote raw `ParserError` to `SH0001..SH0099` codes
  with span and one-line message
- `program.lower` — currently silent on validation; add `LW00xx` codes
- `eval` — currently uses `EV00xx` ad-hoc; standardize the table
- `exec.spawn` — `EX00xx` for fork/exec/redirect failures with the
  failing path

### 4. CLOEXEC discipline audit

Pipes get FD_CLOEXEC. What about other fds opened by the shell? Verify
no fd leaks into spawned children when:
- The shell opens a config file with `source`
- The shell opens a heredoc body via `pipe()`
- The shell stat's a path during PATH resolution
- The shell's own stdin/stdout/stderr aren't accidentally inherited
  cross-purpose

---

## Tier 4 — quality of execution

### 5. Comprehensive test suite

Need:

- Word-expansion table tests — every quoting × variable type × position
  combination
- Glob match tests — with a tmpfs fixture (or a `tmpdir/` setup helper)
- Redirect ordering tests — `>file 2>&1` vs `2>&1 >file`
- Pipeline pipefail tests — across 2/3/4 stages, with failures at each
  position
- Signal/PTY tests — `Ctrl-C`, `Ctrl-Z`, `fg`, foreground takeover
- Multi-line script fixtures — comments, blank lines, mixed brace/indent,
  nested control flow
- Memory-leak tests — `DebugAllocator` + thousands of iterations
- Differential tests against `bash`/`dash` for explicitly-aligned semantics
  (PLAN §17.8) — and **only** for those; intentional deltas don't get a
  diff case

### 6. UTF-8 awareness

Today the lexer is ASCII. A user typing `let café = 5` or piping Chinese
filenames hits errors. We need at minimum:

- Bare-word class accepts non-ASCII letter bytes (continuation bytes are
  fine; just don't reject them as `err`)
- Source positions count code units correctly for diagnostics
- No truncation of multi-byte characters in error messages or word slices

Stretch: render multi-byte characters in REPL highlighting without
collapsing the cursor.



### 7. Process substitution `<(...)` / `>(...)`

PLAN §6.2 documents. Implementation:
- Lexer adds `proc_sub_in` (`<(`) and `proc_sub_out` (`>(`) tokens
- Word part variants: `process_subst_in`, `process_subst_out`
- Eval forks a child for each, opens `/dev/fd/N` (Linux) or named-pipe
  (BSD/macOS) bindings, threads the path into the parent's argv
- Job-owned cleanup on every termination path (PLAN §7 Rule 25)

### 8. Configuration loading

`~/.slashrc` is sourced at interactive shell startup. That's the entire
mechanism. No `~/.slash/config` file format, no `set` runtime config
builtin. Users configure by writing Slash code in `.slashrc`.

- `--norc` flag to skip
- `.slashrc` is run before the first prompt; non-interactive shells (`-c`,
  scripts) do not source it






## REPL — world class

The killer feature: we have a real parser. Every keystroke can re-parse
the line and we know the Shape immediately. That means we're not
pattern-matching tokens for highlighting, completion, or error preview —
we're rendering the parse tree. It can never lie.

This work depends on partial-Shape support for incomplete input (REPL
continuation prompt) and benefits from Tier 3 #3 (real
diagnostics).

### 9. Live syntax highlighting

Re-parse on each keystroke. Walk the Shape, emit ANSI escape sequences
per node type:

- builtins / keywords: bold cyan
- strings: green (with `$var` inside double-quoted in yellow)
- variables: yellow
- pipes / redirects: dim white
- syntax errors: red underline with caret
- comments: dim gray

The DuckDB CLI insight: highlight from the parse tree, not regex. Our
parser is fast enough — even multi-KB lines re-parse in microseconds.

### 10. Multi-line continuation

If `shape.parse(line)` returns "incomplete" (open `{` / `(` / `[` /
heredoc), set the prompt to `... ` and accumulate. Otherwise execute.

User types:

```
if test -d /tmp {
  echo found
}
```

We know exactly when they're inside the block (open `{` on stack) and
when the statement is complete (matched `}` and shape is well-formed).

### 11. Tab completion via Shape introspection

| Cursor position | Completions |
|---|---|
| Start of statement / first word of command | builtins ∪ PATH ∪ user-defined `cmd`s |
| `$` token | session variables |
| After `cd` | directories only |
| After `export` | existing var names |
| After redirect operator (`>`, `<`, `2>`) | files |
| Default argument position | files in current dir, dirs first |

The parser tells us *which* of these we're in. No regex hacks.

### 12. History

Persistent flat file at `~/.slash/history`. Each entry has rich
metadata:
- Timestamp (Unix seconds)
- cwd at execution
- Exit code
- Duration

`Up`/`Down` step through. `Ctrl-R` opens a fzf-style overlay with live
filtering. **Frecency** sort by default (frequency × recency, weighted
toward recency).

### 13. Bracket matching

When the cursor sits on `}`, dim the matching `{` for 200ms (or until
cursor moves). Use the Shape spans — no character-counting needed.

### 14. Prompt

Default is minimal but useful:

```
~/Data/Code/slash main +3 ! 0.42s
$
```

Components (each independently disable-able):
- PWD (home-collapsed)
- Git branch + dirty flag (`+3` = 3 staged, `!` = unstaged changes)
- Last-command duration if >1s
- Last exit code if non-zero
- Then `$ ` (or `# ` for root)

Continuation prompt: `... `.

### 15. Implementation foundation

The REPL is one new module — `src/repl.zig`, ~600-800 lines.
Dependencies:

- `tcgetattr` / `tcsetattr` for raw mode (Zig 0.16's `std.posix`)
- ANSI escape sequences (small constant table)
- `shape.parse` already provides everything for highlighting and
  completion
- A thin terminal abstraction (cursor pos, line clear, color reset)

The hard part isn't writing the REPL. The hard part is making sure the
foundation (Tier 1–3 above) doesn't have holes. Building a beautiful
REPL on top of `"$x"` not expanding would be embarrassing.

---

## Done means done

When this file is empty, Slash 1.0 ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
