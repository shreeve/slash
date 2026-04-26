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

## REPL — world-class polish

The cooked-mode REPL with multi-line continuation and `~/.slashrc`
sourcing is in. The remaining items upgrade the experience to what a
modern shell user expects.

### 1. Raw-mode line editor

`tcgetattr` / `tcsetattr` for raw mode, ANSI escape sequences, cursor
movement, Backspace / Ctrl-W / Ctrl-U / Home / End. The terminal-
abstraction layer the rest of the REPL items depend on.

### 2. Live syntax highlighting

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

### 3. Tab completion via Shape introspection

| Cursor position | Completions |
|---|---|
| Start of statement / first word of command | builtins ∪ PATH ∪ user-defined `cmd`s |
| `$` token | session variables |
| After `cd` | directories only |
| After `export` | existing var names |
| After redirect operator (`>`, `<`, `2>`) | files |
| Default argument position | files in current dir, dirs first |

The parser tells us *which* of these we're in. No regex hacks.

### 4. History

Persistent flat file at `~/.slash/history`. Each entry has rich
metadata:

- Timestamp (Unix seconds)
- cwd at execution
- Exit code
- Duration

`Up`/`Down` step through. `Ctrl-R` opens a fzf-style overlay with live
filtering. **Frecency** sort by default (frequency × recency, weighted
toward recency).

### 5. Bracket matching

When the cursor sits on `}`, dim the matching `{` for 200ms (or until
cursor moves). Use the Shape spans — no character-counting needed.

### 6. Prompt

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




## Done means done

When this file is empty, Slash 1.0 ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
