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
- **Abbreviations.** Editor-only token-or-phrase rewrites, fired on
  space/enter, visible before line accept. **Strictly literal text →
  literal text.** No variables, no command substitution, no
  placeholders, no conditionals, no template language. Storage: a
  session table populated by an `abbr` builtin (`abbr ll 'ls -lAh'`,
  `abbr -e ll`). The `abbr` builtin is in scope as a UX configuration
  point, not a language feature.
- **Smart history.** Replace the current flat `~/.slash/history` with a
  frecency-indexed store. Per-cwd recall, dedup, fuzzy reverse-search
  (Ctrl-R). Pure data and indexing; no behavioral hooks.
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

## Job-control surface — completing `fg`

`fg` resumes stopped/background jobs and waits for them via the
existing `service(.foreground, target)` machinery, but slash does not
yet hand the controlling tty back to the resumed process group via
`tcsetpgrp`. A resumed job that reads the controlling tty therefore
takes `SIGTTIN`. The bookkeeping is correct in either case; the gap
is purely the terminal handoff.

- Wire `tcsetpgrp` in `exec.zig` (or a small helper module). Track the
  controlling tty fd on `Session`. On `fg`, hand the tty to the
  job's pgid before waiting; on stop or completion, take it back.

## Done means done

When this file is empty, the next Slash release ships:
- A real Unix shell, not a toy
- Usable as the daily driver for new shell work
- Pleasant to live in interactively (fish-class UX)
- Mechanically correct in the places shells historically lie
- Inspectable end-to-end, from source byte to job exit

We don't need to support old bash scripts. We need to be the better
choice for new ones. That's the bar.
