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

## Tier 1 — script writing breaks without these

These are not optional. Without them, common scripts fail in the first
ten lines and Slash feels half-built.


## Tier 2 — common patterns break

### 1. Heredocs

See the dedicated **Heredoc spec** section below. Both literal
(`<<'TAG'`) and interpolating (`<<TAG`) forms ship in one piece — the
expansion machinery for the interpolating form is the same one already
in place for `"$x"` inside double-quoted strings.


## Tier 3 — robustness

### 2. Memory ownership audit and tightening

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

### 3. Signal handling at the REPL boundary

PLAN §18-§19 documents the model. The implementation:

- Parent shell ignores `SIGINT` while reading input.
- Children reset to default before `exec` (already done).
- `Ctrl-C` cancels the line being edited, emits a fresh prompt (REPL).
- `Ctrl-Z` doesn't crash anything; for now, ignored (full job-control later).
- `SIGCHLD` reaping at safe points (already done in `service`).
- Foreground-job's process group receives terminal-generated signals;
  shell does not forward `SIGINT` itself.


### 4. Diagnostic infrastructure actually used

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

### 5. CLOEXEC discipline audit

Pipes get FD_CLOEXEC. What about other fds opened by the shell? Verify
no fd leaks into spawned children when:
- The shell opens a config file with `source`
- The shell opens a heredoc body via `pipe()`
- The shell stat's a path during PATH resolution
- The shell's own stdin/stdout/stderr aren't accidentally inherited
  cross-purpose

---

## Tier 4 — quality of execution

### 6. Comprehensive test suite

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

### 7. UTF-8 awareness

Today the lexer is ASCII. A user typing `let café = 5` or piping Chinese
filenames hits errors. We need at minimum:

- Bare-word class accepts non-ASCII letter bytes (continuation bytes are
  fine; just don't reject them as `err`)
- Source positions count code units correctly for diagnostics
- No truncation of multi-byte characters in error messages or word slices

Stretch: render multi-byte characters in REPL highlighting without
collapsing the cursor.



### 8. Process substitution `<(...)` / `>(...)`

PLAN §6.2 documents. Implementation:
- Lexer adds `proc_sub_in` (`<(`) and `proc_sub_out` (`>(`) tokens
- Word part variants: `process_subst_in`, `process_subst_out`
- Eval forks a child for each, opens `/dev/fd/N` (Linux) or named-pipe
  (BSD/macOS) bindings, threads the path into the parent's argv
- Job-owned cleanup on every termination path (PLAN §7 Rule 25)

### 9. Configuration loading

`~/.slashrc` is sourced at interactive shell startup. That's the entire
mechanism. No `~/.slash/config` file format, no `set` runtime config
builtin. Users configure by writing Slash code in `.slashrc`.

- `--norc` flag to skip
- `.slashrc` is run before the first prompt; non-interactive shells (`-c`,
  scripts) do not source it





### 10. `trap` builtin

`trap 'CMD' SIGNAL...` registers a Slash source string to run when the
named signal is received. `trap '' SIGNAL` ignores the signal. `trap -`
restores default. The `EXIT` pseudo-signal runs on shell exit.

Real scripts need this for cleanup paths. Implementation requires:
- Per-session signal handler table (signal → Slash source)
- The minimal `SIGCHLD`-style flag handler pattern (PLAN §19) extended
  to user signals
- Trap source is parsed to a `Program` at registration, not at fire time
- Trap fires at the next safe point (between sequence items, or before
  the next prompt)

---

## Heredoc spec

Slash heredocs use **column-determined dedent** and allow **line
continuation after the sigil**. Two open sigils:

- `<<TAG` — interpolating (`$var`, `${var}`, `$(...)` expansion)
- `<<'TAG'` — literal (no expansion, body is exact bytes)

No `<<-TAG` form. Column-based dedent obsoletes it.

The closing line is the first line whose **trimmed** content equals
`TAG`. The **column where `TAG` starts on the closing line** is the
dedent margin. Every body line has up to that many columns of leading
whitespace stripped (capped at the line's actual indentation, so
under-indented body lines aren't damaged).

```sh
cat <<EOF
    hello world
    indented further
        more
    EOF
```

Closing `EOF` at column 4. Body becomes:

```
hello world
indented further
    more
```

### Line continuation after the sigil

After `<<TAG` (or `<<'TAG'`), the rest of the line continues exactly as
it would for any other redirect. `;`, `&&`, `||`, `|`, `&`, and bare
statement-end all work. The body comes from subsequent lines.

```sh
echo before; cat <<EOF; echo after
    hello world
    EOF
```

Output:

```
before
hello world
after
```

Multiple heredocs on one line are queued in order:

```sh
cat <<A; cat <<B
    body of A
    A
    body of B
    B
```

### Implementation outline

**Lexer rules** (`slash.grammar`):

```
"<<" "'" [A-Za-z_] [A-Za-z0-9_]* "'"   → heredoc_open_lit
"<<" [A-Za-z_] [A-Za-z0-9_]*           → heredoc_open
heredoc_body
```

`heredoc_body` is emitted by the wrapper; no lexer pattern.

**Lexer wrapper** (`slash.zig`):

```zig
const PendingHeredoc = struct {
    tag: []const u8,
    interpolating: bool,
    dedent_col: u32 = 0,
};

pending_heredocs: std.ArrayListUnmanaged(PendingHeredoc) = .empty,
```

Flow:
1. On `heredoc_open` / `heredoc_open_lit`, parse the tag, push to
   `pending_heredocs`. Return the open token unchanged.
2. On a newline token, if `pending_heredocs.len > 0`:
   - Save the deferred newline.
   - For each pending heredoc in order:
     - Scan `base.source` line by line from `base.pos`.
     - First line whose trimmed content equals `TAG` ends the body and
       records `dedent_col`.
     - Otherwise: append (raw, untouched) to a body accumulator.
   - Cook each body: strip up to `dedent_col` columns of leading
     whitespace from each line. Join with `\n`.
   - Emit a `heredoc_body` token whose source span covers the cooked
     body. Queue subsequent heredoc bodies for sequential return.
   - After all bodies are emitted, emit the deferred newline.

The wrapper's `next()` must drain queued heredoc bodies before resuming
normal lexing.

**Grammar**:

```
redirect = ...
         | HEREDOC_OPEN     HEREDOC_BODY    → (redir_heredoc 1 2)
         | HEREDOC_OPEN_LIT HEREDOC_BODY    → (redir_heredoc_lit 1 2)
```

**Shape**:

```zig
pub const RedirectOp = enum {
    read, read_fd, write, write_fd, append,
    both, both_append, dup_out, dup_in,
    heredoc, heredoc_literal,
};

pub const HeredocBody = struct {
    body: []const u8,       // cooked, dedented bytes
    interpolating: bool,
    span: Span,
};
```

`RedirectShape.target` becomes a `union { word: WordShape, heredoc: HeredocBody }`.

**Eval**: for each heredoc redirect on a command:
1. Create a pipe.
2. Fork a tiny writer process (or write from the parent if the body
   fits in the kernel pipe buffer).
3. Dup the read end onto the target fd in the child.
4. Close both ends in the parent.

Tiny writer is the safe default — no buffer-size assumptions, no parent
blocking.

For interpolating heredocs, the body needs `$var` / `$(...)` expansion
at eval time, sharing machinery with `"$x"` inside double-quoted
strings.

### Edge cases to nail

- **No closing tag found before EOF** — parse error, primary span on the
  open sigil. Code `SH0021: heredoc opened at <line:col> with tag '<tag>'
  was never closed`.
- **Mixed tabs and spaces in body indent** — same hard error as code
  indentation. Not a place to be permissive.
- **Body line indented less than the closing tag** — strip what's there,
  leave the rest.
- **Empty body** — closing tag immediately after open line: body is the
  empty string.
- **Multiple opens, same tag** — each is collected against its own next
  occurrence.
- **Closing tag inside a quoted string in the body** — doesn't close.
  Only trimmed-line-equals-tag counts.

---

## REPL — world class

The killer feature: we have a real parser. Every keystroke can re-parse
the line and we know the Shape immediately. That means we're not
pattern-matching tokens for highlighting, completion, or error preview —
we're rendering the parse tree. It can never lie.

This work depends on partial-Shape support for incomplete input (REPL
continuation prompt) and benefits from Tier 3 #4 (real
diagnostics).

### 11. Live syntax highlighting

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

### 12. Multi-line continuation

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

### 13. Tab completion via Shape introspection

| Cursor position | Completions |
|---|---|
| Start of statement / first word of command | builtins ∪ PATH ∪ user-defined `cmd`s |
| `$` token | session variables |
| After `cd` | directories only |
| After `export` | existing var names |
| After redirect operator (`>`, `<`, `2>`) | files |
| Default argument position | files in current dir, dirs first |

The parser tells us *which* of these we're in. No regex hacks.

### 14. History

Persistent flat file at `~/.slash/history`. Each entry has rich
metadata:
- Timestamp (Unix seconds)
- cwd at execution
- Exit code
- Duration

`Up`/`Down` step through. `Ctrl-R` opens a fzf-style overlay with live
filtering. **Frecency** sort by default (frequency × recency, weighted
toward recency).

### 15. Bracket matching

When the cursor sits on `}`, dim the matching `{` for 200ms (or until
cursor moves). Use the Shape spans — no character-counting needed.

### 16. Prompt

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

### 17. Implementation foundation

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
