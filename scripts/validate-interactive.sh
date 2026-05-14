#!/usr/bin/env bash
# scripts/validate-interactive.sh
#
# Interactive correctness validation harness for Slash. Walks the
# operator through CHECKLIST §12 — running real interactive software
# under the just-built `bin/slash` and recording pass/fail per program.
#
# Usage:
#   ./scripts/validate-interactive.sh        # interactive run, appends to VALIDATION.md
#   ./scripts/validate-interactive.sh --plan  # print the test plan, run nothing
#
# The harness asks the operator to perform a small action (type some
# text, press Ctrl-Z, etc.) and confirm whether it behaved correctly.
# Each test reports: program, action, expected, observed (y/n + free
# text), and the OS / Slash commit fingerprint. Results append to
# VALIDATION.md so a history accumulates across releases.

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
slash="$repo_root/bin/slash"
report="$repo_root/VALIDATION.md"

if [[ ! -x "$slash" ]]; then
  echo "slash binary not found at $slash — run \`zig build\` first." >&2
  exit 1
fi

# --- test plan ---------------------------------------------------------------

# Each entry: NAME|DESCRIPTION|RUN|EXPECT
# RUN is the command to launch inside slash (the operator types it at
# the slash prompt). EXPECT is the human-readable success criterion.
plan=(
  "cat-fg|cat (foreground): line discipline + Ctrl-D EOF|cat|Type some text + Enter; cat echoes it. Press Ctrl-D; cat exits cleanly and the slash prompt returns."
  "cat-bg-sigttin|cat & (background reader): SIGTTIN on stdin read|cat &|cat is backgrounded; on its first stdin read it should stop with SIGTTIN. \`jobs\` shows it as Stopped."
  "ctrl-c-fg|Ctrl-C interrupts foreground only|sleep 30|Press Ctrl-C; sleep dies with 130; the shell prompt returns."
  "ctrl-z-fg|Ctrl-Z stops foreground; fg resumes|sleep 30|Press Ctrl-Z; \`jobs\` shows Stopped sleep; type \`fg\`; sleep resumes; Ctrl-C to kill."
  "less|less: termios + cleanup|less /etc/passwd|less paints the file; arrow keys scroll; q quits; the prompt is restored to cooked mode."
  "vim|vim: termios save/restore|vim /tmp/slash-validate-vim.txt|vim opens; type :q!; on exit slash's prompt is cooked-mode (no raw-mode artifacts)."
  "top|top: alternate-screen + termios|top|top paints; q quits; slash's screen is restored, cursor is visible, prompt is cooked-mode."
  "man|man: pager+termios chain|man slash 2>/dev/null || man ls|the pager opens; arrow keys scroll; q quits; prompt restored."
  "ssh|ssh localhost: nested tty allocation|ssh -o BatchMode=yes localhost echo from-ssh|works only if local sshd is set up; otherwise \"connection refused\" is acceptable. The point: shell survives ssh's pty allocation attempt."
  "nested-slash|slash inside slash: nested job control|$slash --norc|inside, run \`echo nested\` then \`exit\`. Outer slash returns to its prompt cleanly."
  "nested-bash|bash inside slash: cross-shell job control|bash --noprofile --norc|inside, run \`echo from-bash\` then \`exit\`. Outer slash returns cleanly."
  "python-repl|python REPL: line discipline + Ctrl-D|python3 -q 2>/dev/null || python -q|the >>> prompt appears; type \`print(1+1)\` Enter; sees 2. Ctrl-D exits; slash prompt returns cooked."
  "node-repl|node REPL: line discipline + Ctrl-D twice|node|the > prompt appears; type \`1+1\` Enter; sees 2. Ctrl-D twice exits; slash prompt returns cooked."
  "yes-head|yes | head: SIGPIPE termination|yes | head -n 3|prints y three times; the pipeline exits; the prompt comes back."
)

print_plan() {
  echo "Slash interactive validation plan (CHECKLIST §12)"
  echo "================================================="
  echo
  local i=0
  for entry in "${plan[@]}"; do
    IFS='|' read -r name desc run expect <<<"$entry"
    i=$((i + 1))
    printf '%2d. %-22s %s\n' "$i" "$name" "$desc"
    printf '    run:    %s\n' "$run"
    printf '    expect: %s\n' "$expect"
    echo
  done
}

if [[ "${1:-}" == "--plan" ]]; then
  print_plan
  exit 0
fi

# --- environment fingerprint -------------------------------------------------

os="$(uname -s) $(uname -r) $(uname -m)"
commit="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
when="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# --- interactive runner ------------------------------------------------------

cat <<'BANNER'

  ┌─────────────────────────────────────────────────────────────────┐
  │ slash interactive validation harness                            │
  │                                                                 │
  │ For each test:                                                  │
  │   1. The harness prints what to do.                             │
  │   2. It launches `bin/slash --norc`. Run the command shown.     │
  │   3. After the slash session ends, you say PASS / FAIL / SKIP   │
  │      and (optionally) write a note.                             │
  │                                                                 │
  │ Results append to VALIDATION.md. Ctrl-C aborts the run.         │
  └─────────────────────────────────────────────────────────────────┘

BANNER

# Append a fresh section header to VALIDATION.md.
{
  echo
  echo "## Run: $when"
  echo
  echo "- commit: \`$commit\`"
  echo "- os: $os"
  echo "- slash binary: \`$slash\`"
  echo
  echo "| # | test | result | note |"
  echo "|---|---|---|---|"
} >> "$report"

i=0
for entry in "${plan[@]}"; do
  IFS='|' read -r name desc run expect <<<"$entry"
  i=$((i + 1))

  echo
  echo "── test $i: $name ─────────────────────────────────────────────"
  echo "    $desc"
  echo
  echo "  run inside slash:"
  echo "    $run"
  echo
  echo "  expected:"
  echo "    $expect"
  echo
  read -r -p "  press Enter to launch slash (or 's' to skip)... " skip_choice

  if [[ "$skip_choice" == "s" ]]; then
    printf '| %d | %s | SKIP | skipped by operator |\n' "$i" "$name" >> "$report"
    continue
  fi

  # Launch slash in a clean way. The operator does whatever's needed,
  # then exits the inner slash session.
  "$slash" --norc

  echo
  read -r -p "  result [P/f/s] (PASS / fail / skip): " result_choice
  read -r -p "  note (optional): " note
  case "${result_choice:-P}" in
    P|p|"") result="PASS" ;;
    F|f)    result="FAIL" ;;
    S|s)    result="SKIP" ;;
    *)      result="?? ($result_choice)" ;;
  esac
  # Escape pipes in the note so the markdown table doesn't break.
  note_escaped="${note//|/\\|}"
  printf '| %d | %s | %s | %s |\n' "$i" "$name" "$result" "$note_escaped" >> "$report"
done

echo
echo "Done. Results appended to: $report"
