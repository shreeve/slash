# Slash — Roadmap

This file lists every concrete unit of work that stands between Slash
today and the next release. As items ship, **delete them from this
file** in the same commit. The ROADMAP shrinks until empty; that's how
the next release ships.

Items are grouped by readiness: **ready now** vs **blocked on missing
zigline primitives**. Two of the blockers are tracked as zigline
0.4.0 (`replace_buffer_and_accept`, transient input mode);
autosuggestions need ghost-text rendering, which lives in
`zigline/FUTURE.md` without a specific release number. Within each
group, ship in whichever order makes sense.

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

## Interactive UX — ready now

These three are unblocked.

- **Intelligent tab completions.** Per-command completion specs as
  declarative data (subcommand sets, flag definitions, file-path
  filters, explicit bounded provider IDs). Starter specs: `git`,
  `cd`, `ssh`, `kill`, `fg`/`bg`, `cmd`, `str`. Specs live in a
  slash-side registry; later config may select or extend declared
  specs without allowing arbitrary code execution at completion
  time. Dynamic candidates come from explicit bounded providers,
  **not** sourced completion scripts and **not** arbitrary slash
  evaluation. A provider may run a fixed argv vector with a short
  timeout, read newline-delimited stdout, treat failure as no
  candidates, and must never mutate shell state. zigline 0.2.x
  already provides the completion hook + multi-column menu
  (slash's `completionHook` in `repl.zig` uses them); this work is
  the slash-side spec registry and starter specs, no zigline
  blocker. See `HANDOFF.md` "Ready now" for the full implementation
  shape and definition of done.
- **Rich prompt.** Extend the prompt provider set (cwd, last-status,
  jobs count, git context, virtualenv, host/user, time). Prompt
  content is data — fixed providers, no user-defined "prompt is a
  function." Ship a small set of defaults (default, plain, minimal)
  and a config knob to compose the providers. Pure slash work; no
  zigline dependency.
- **Syntax highlighting polish.** Already shipped as a feature. Expand
  the token classes (variables, command substitutions, redirects,
  glob parts, heredoc bodies). Always driven by the BaseLexer / one
  grammar — never a second tokenizer. Uses zigline's existing
  highlight hook.

## Interactive UX — blocked on zigline

Three items wait on zigline render/input-mode primitives that aren't
in 0.3.1. Each names the specific zigline addition it needs.

- **Autosuggestions.** History-backed "ghost text" predicted
  continuation rendered to the right of the cursor; accept on right
  arrow / Ctrl-F. Never executed unless accepted as ordinary input.
  Candidate source: `Session.history` / `HistoryIndex` ranked prefix
  search.
  - **Blocker:** zigline does not currently render virtual ghost
    text past the end of the editable buffer. The existing highlight
    hook only styles existing buffer text. Ghost-text rendering
    is in [`zigline/FUTURE.md`](../zigline/FUTURE.md) as
    "Hints (ghost text). Right-of-cursor suggestion rendering."
    Wire up in slash once that lands in zigline (any 0.x release).
  - **Do not fake it** by inserting text into the editable buffer;
    that violates the UX semantic (the suggestion isn't the user's
    command until they accept it).
- **`str` — Enter trigger.** Space-trigger expansion shipped (`StrTable`
  in `session.zig`, `str` builtin in `builtins.zig`, `strCandidate`
  scanner + custom-action hook in `repl.zig`, `str NAME { body }`
  brace-form via lexer wrapper). Enter-trigger expansion needs a
  zigline result variant that combines `replace_buffer` with
  `accept_line` in one step (renders the expanded buffer, then
  submits as the executed line). Without it, Enter on an unexpanded
  `str` candidate would either submit the LHS literally or require a
  second Enter — both wrong. Tracked as zigline 0.4.0
  `replace_buffer_and_accept`; wire up here when shipped.
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
