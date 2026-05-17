# Slash — Changelog

Notable changes per release. The complete commit history lives in
`git log`; this file is the curated highlight reel.

Versioning follows the project's own bar in `PLAN.md` ("Done means
done"): a release ships when the criteria in that section all hold.
Minor versions add features that pass §14. Patch versions are
correctness fixes.

---

## 1.2.0 — 2026-05-16

The "*it just works*" release. The shell itself was already
shippable at 1.1.0; this cycle hardened the long tail (CI on
Linux, mid-prompt notifications, the first behavioral wrapper, a
process-substitution audit + leak fix) and shipped the
user-configurable keybinding system with the polish needed to be
genuinely natural on macOS.

### New features

- **`key` builtin** — user-configurable keybindings, zsh
  `bindkey`-style. Two forms:
  - `key KEYSPEC bare-ident` — bind to a named editor action
    from a kebab-case registry (40+ actions: `word-backward`,
    `accept-hint`, `history-prev-prefix`, ...).
  - `key KEYSPEC "literal text"` — type bytes into the buffer;
    trailing `\n` accepts the line.
  - KEYSPEC grammar: `Ctrl-X`, `Alt-Left`, `Ctrl-Alt-Right`,
    `Shift-F7` (hyphens join modifiers). `Alt-` /
    `Meta-` / `Esc-` / `Option-` / `Opt-` are five synonyms for
    the Meta modifier. Function keys `F1`..`F12`. Named keys
    (`Up`, `Down`, `Home`, `Tab`, `Enter`, `Backspace`, `Delete`,
    `Escape`, `Space`, `PageUp`, `PageDown`, `Insert`). Comma
    syntax (`Ctrl-X,Ctrl-E`) reserved for future multi-chord.
  - Listing: `key` (all bindings), `key --actions` (registry),
    `key -d KEYSPEC` (remove), `key --reset` (clear all).
  - **`key --probe`** — interactive diagnostic. Press any key in
    the probe and slash prints the canonical name + raw bytes +
    suggested `key K some-action` line, plus a precise compose-
    character warning when the bytes look like macOS Option-X
    with `Use Option as Meta key` disabled.
  - **UTF-8 keyspecs**: `key "¬" "ls -la\n"` binds directly to a
    Unicode codepoint your terminal happens to emit. Lets users
    write whatever character `key --probe` showed them.
  - **Layout-aware Option-key reverse-resolution**: on macOS US-
    QWERTY (the default), `key Option-L "ls -la\n"` fires on
    Option+L regardless of whether `Use Option as Meta key` is
    enabled in Terminal.app or iTerm2. The reverse table maps
    each compose codepoint (`¬` → `'l'`, `ø` → `'o'`, ...) back
    to its originating letter at dispatch time. Pluggable for
    future en_GB / de_DE / dvorak layouts via the
    `Session.keyboard_layout` field.
  - Default bindings seeded at interactive startup:
    `Alt-p`/`Alt-n` → `history-prev-prefix`/`history-next-prefix`
    (emacs-convention aliases for slash's smart Up/Down arrows).
  - Soft dead-key warning at bind time for `Option-{E,I,N,U}`
    (US-QWERTY): these emit combining diacritics, not standalone
    codepoints, so they can only fire via the Meta wire path.
  - `.slashrc.example` at the project root — full template with
    commented-out recipes for prompts, `str` abbreviations, key
    bindings, and traps.

- **`time` keyword** — first behavioral wrapper. Wraps a
  pipeline, block, or any control-flow construct (`if`, `while`,
  `for`, `match`); times the entire body's execution. Reports
  wall (`clock_gettime(MONOTONIC)`) and CPU (`getrusage(SELF) +
  getrusage(CHILDREN)` summed — bash's children-only timing
  undercounts shell-side work; slash chooses accuracy). Output
  goes to stderr, dim on TTY. Transparent to exit status,
  `$?`, `&&`/`||`, and pipefail — `time` returns whatever its
  body returned.

- **Mid-prompt `[N] Done` notices** — opt-in via
  `$SLASH_NOTIFY=immediate`. Backgrounded jobs that finish
  while the user is mid-buffer announce themselves above the
  in-progress prompt (via zigline v0.6.0's `Editor.printAbove`
  + `on_wake` hook) instead of waiting for the next Enter.
  Default behavior (`set +b`) is unchanged.

- **`time` keyword + behavioral wrapper template.** Future
  `Retry`, `Timeout`, `Within`, `WithEnv`, `Parallel` wrappers
  follow the same grammar / shape / lower / eval pattern this
  shipped.

### Correctness

- **Process substitution audit** — `<(prog)` / `>(prog)`
  cleanup is now zombie-safe + fd-leak-safe. The previous
  `WNOHANG`-then-forget reaper silently leaked side-children
  whose post-EOF work hadn't completed (common for `>(wc -c)`-
  style flushers). New `drainProcSubs` compacts in-place,
  classifies `waitpid` returns precisely (EINTR retains;
  ECHILD drops to avoid PID-recycle hazards), and the new
  `drainProcSubsAtExit` four-phase escalation
  (`WNOHANG → 100ms grace-poll → SIGTERM + grace → SIGKILL +
  blocking wait`) guarantees a bounded teardown without
  zombies leaking into init.

- **Hint-on-Enter clearing** — pressing Enter without
  accepting the autosuggestion hint no longer leaves the dim
  ghost text painted above the executed command. Shipped via
  `zigline v0.6.1`.

### Platform / CI

- **Linux validation live.** GitHub Actions matrix added for
  `ubuntu-latest` alongside `macos-latest`. Both run the full
  166-test suite on every push.
- **Portable file stat** — new `src/stat.zig` shim
  uses `statx(2)` on Linux and `fstatat(2)` on macOS,
  replacing the previous `std.c.Stat` calls that compiled to
  `void` on Linux in Zig 0.16.
- **CI hygiene** — `actions/checkout@v5` (Node 24);
  per-job 10-minute timeout to fail loud on harness wedges
  instead of burning CI budget; manual Zig 0.16.0 install
  bypasses `mlugg/setup-zig`'s stale release index.

### Dependencies

- **`zigline v0.6.1`** (was `v0.4.x` at 1.1.0). New primitives
  consumed:
  - `Editor.printAbove` + `Options.on_wake` (mid-prompt
    notifications, hint-on-Enter clearing)
  - `Options.transient_input` (Ctrl-R reverse-i-search hook)
  - `CustomActionResult.replace_buffer_and_accept`
    (the `key` literal-bind dispatch path)

### Tests

- 1.1.0 → 1.2.0: 91 → **166** tests passing.
  - 102 in the unit + headless suite (`zig build test-headless`)
  - 64 in the PTY suite (`zig build test-pty`)
- All green on Linux + macOS CI.

---

## 1.1.0 — 2026-05-15

Pattern dispatch, complete job control, fish-class interactive
UX. See `git log v1.0.0..v1.1.0` for the curated history; this
file's history starts at 1.2.0.

## 1.0.0 — 2026-04-27

Initial release. Phase 1 grammar + lang module + generated
parser, runtime, builtins, raw-mode line editor (pre-zigline).
