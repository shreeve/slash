# Slash — Roadmap

This file lists every concrete unit of work that stands between Slash
today and the next release. As items ship, **delete them from this
file** in the same commit. The ROADMAP shrinks until empty; that's how
the next release ships.

Items are flat bullets — no numbering, ship in whichever order makes
sense.

> **The test that decides whether anything joins this list:**
> Does this improve `Command` clarity, `Pipeline` correctness, `Program`
> composability, or `Job` control? If not, do not build it. (PLAN §14)

---

## Interactive UX

All items below live in `repl.zig` plus `zigline`. None of them touch
the execution kernel. Each one must stay constrained as defined in
PLAN §12 "In scope as interactive UX" — no language semantics, no user
shell code at editor events.

- **Autosuggestions.** History-backed (and optionally completion-spec
  backed) "ghost text" predicted continuation. Render via zigline's
  highlight hook; accept on a single explicit key (right arrow,
  Ctrl-F). Never executed unless accepted as ordinary input.
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
- **Intelligent tab completions.** Per-command completion specs as
  declarative data (subcommand sets, flag definitions, file-path
  filters, dynamic-source hooks where the source is a slash command
  whose stdout becomes the candidate list). Starter specs: `git`,
  `cd`, `ssh`, `kill`, `fg`/`bg`, `cmd`. Specs live in a registry
  loaded from config; no completion script ever runs arbitrary slash
  expressions at completion time beyond the explicit dynamic-source
  hook.
- **Rich prompt.** Extend the prompt provider set (cwd, last-status,
  jobs count, git context, virtualenv, host/user, time). Prompt
  content is data — fixed providers, no user-defined "prompt is a
  function." Ship a small set of defaults (default, plain, minimal)
  and a config knob to compose the providers.
- **Syntax highlighting polish.** Already shipped as a feature. Expand
  the token classes (variables, command substitutions, redirects,
  glob parts, heredoc bodies). Always driven by the BaseLexer / one
  grammar — never a second tokenizer.

## Done means done

When this file is empty, the next Slash release ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively (fish-class UX)
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
