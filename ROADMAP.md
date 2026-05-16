# Slash — Roadmap

This file lists every concrete unit of work that stands between Slash
today and the next release. As items ship, **delete them from this
file** in the same commit. The ROADMAP shrinks until empty; that's how
the next release ships.

All slash-side ready-now items have shipped. The single remaining blocker
is the zigline transient input mode primitive that the Ctrl-R reverse
search UI depends on.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

The editor integration points are in `repl.zig` and zigline hooks.
Keep new slash-side registries / providers / spec data in focused
modules — don't stuff declarative completion specs or prompt-provider
logic directly into the REPL loop. None of these items touch the
execution kernel. Each one must stay constrained as defined in
PLAN §12 "In scope as interactive UX" — no language semantics, no
user shell code at editor events.

## Interactive UX — blocked on zigline

One item waits on a zigline input-mode primitive.

- **Smart history — Ctrl-R interactive search.** The substrate is in
  place: slash-side `HistoryIndex` (`src/history.zig`) captures every
  accepted command with cwd / ts / status / duration, persists as
  JSONL under XDG, and exposes a frecency + cwd-boost + recency +
  prefix-vs-substring ranking API. The `history` builtin lists and
  searches against the same index. Smart prefix-aware Up/Down
  navigation against the same index already ships (commit
  `abab621` — empty buffer is chronological, non-empty buffer is
  ranked). What's pending is the **interactive Ctrl-R
  reverse-search UI**, which needs a zigline 0.4.0 search-mode
  primitive (no clean way to fake transient input mode without
  it).

## Done means done

When this file is empty, the next Slash release ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively (fish-class UX)
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
