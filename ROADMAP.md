# Slash — Roadmap to Complete

This file lists every concrete unit of work that stands between Slash today
and Slash 1.0. As items ship, **delete them from this file**. When the
file is empty, Slash 1.0 ships.

Items are flat bullets — no numbering, ship in whichever order makes
sense. As items ship, **delete the bullet** in the same commit; the
ROADMAP shrinks until empty.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

## REPL — world-class polish

The cooked-mode REPL with multi-line continuation and `~/.slashrc`
sourcing is in. The remaining items upgrade the experience to what a
modern shell user expects.

- **Live syntax highlighting.** Re-parse on each keystroke. Walk the
  Shape, emit ANSI escape sequences per node type: builtins / keywords
  in bold cyan, strings in green (with `$var` inside double-quoted in
  yellow), variables in yellow, pipes / redirects in dim white, syntax
  errors in red underline with caret, comments in dim gray. The DuckDB
  CLI insight: highlight from the parse tree, not regex. Our parser is
  fast enough — even multi-KB lines re-parse in microseconds.

- **Bracket matching.** When the cursor sits on `}`, dim the matching
  `{` for 200ms (or until cursor moves). Use the Shape spans — no
  character-counting needed.


## Done means done

When this file is empty, Slash 1.0 ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
