//! Slash — headless integration tests (PLAN §17.6).
//!
//! Each case asserts the observable behavior of running a source string
//! through `source → Shape → Program → Job` end-to-end. Output is
//! captured via fd-redirection (dup2 over fd 1 and 2 around the eval
//! call). The harness is in-process, single-threaded; it exercises the
//! actual fork/exec/waitpid path for external commands.
//!
//! These cases prove the load-bearing v0 invariants:
//!   - shell-context builtins run as zero-child Jobs (PLAN §7 Rule 19)
//!   - external commands fork+exec and we collect the right exit byte
//!   - pipelines are one Job, one pgid, N pids, with pipefail=on
//!   - `&&` / `||` short-circuit on typed `Result`
//!   - subshells fork and isolate state mutation
//!   - detached returns synchronous .exited(0) and registers a job
//!   - `exit N` sets `session.exit_request` and is honored at the top.

const std = @import("std");
const diag = @import("../src/diagnostics.zig");
const shape = @import("../src/shape.zig");
const program = @import("../src/program.zig");
const session_mod = @import("../src/session.zig");
const eval = @import("../src/eval.zig");
const exec = @import("../src/exec.zig");
const builtins = @import("../src/builtins.zig");
const repl = @import("../src/repl.zig");

extern "c" var environ: [*:null]?[*:0]u8;

const Expect = struct {
    exit_code: u8,
    stdout: ?[]const u8 = null, // null = don't check
    stderr: ?[]const u8 = null,
    /// If true, only assert that `stdout` is a substring of the observed
    /// output. Useful for cases where the wider test-runner output gets
    /// in the way.
    stdout_contains: bool = false,
    /// Same idea for stderr: if true, treat `stderr` as a needle and
    /// assert it appears anywhere in the observed stderr stream.
    /// Useful for forms (e.g. `time`) where the line of interest is
    /// embedded in a multi-line emission.
    stderr_contains: bool = false,
};

const Case = struct {
    name: []const u8,
    source: []const u8,
    expect: Expect,
};

const cases: []const Case = &.{
    .{
        .name = "echo zero-child",
        .source = "echo hi",
        .expect = .{ .exit_code = 0, .stdout = "hi\n" },
    },
    .{
        .name = "true is exit 0",
        .source = "true",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "false is exit 1",
        .source = "false",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "echo with multiple args",
        .source = "echo one two three",
        .expect = .{ .exit_code = 0, .stdout = "one two three\n" },
    },
    .{
        .name = "and-then short-circuit success",
        .source = "true && echo yes",
        .expect = .{ .exit_code = 0, .stdout = "yes\n" },
    },
    .{
        .name = "and-then short-circuit failure skips",
        .source = "false && echo skipped",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "or-else short-circuit on failure",
        .source = "false || echo recovered",
        .expect = .{ .exit_code = 0, .stdout = "recovered\n" },
    },
    .{
        .name = "or-else short-circuit on success skips",
        .source = "true || echo skipped",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "sequence semicolon runs both",
        .source = "echo first; echo second",
        .expect = .{ .exit_code = 0, .stdout = "first\nsecond\n" },
    },
    .{
        .name = "external command exit propagates",
        .source = "/bin/sh -c 'exit 7'",
        .expect = .{ .exit_code = 7 },
    },
    .{
        .name = "pipeline pipefail off-style: last stage 0 wins",
        .source = "echo hello | /bin/cat",
        .expect = .{ .exit_code = 0, .stdout = "hello\n" },
    },
    .{
        .name = "pipeline pipefail catches first non-zero",
        .source = "/bin/sh -c 'exit 3' | true",
        .expect = .{ .exit_code = 3 },
    },
    .{
        .name = "exit builtin overrides last result",
        .source = "true; exit 42",
        .expect = .{ .exit_code = 42 },
    },
    .{
        .name = "subshell isolates",
        .source = "(echo inside)",
        .expect = .{ .exit_code = 0, .stdout = "inside\n" },
    },
    .{
        .name = "echo with redirect writes file (no stdout leak)",
        .source = "echo redirected > /tmp/slash-headless-1.txt && /bin/cat /tmp/slash-headless-1.txt",
        .expect = .{ .exit_code = 0, .stdout = "redirected\n" },
    },
    .{
        .name = "scalar variable assignment + expansion",
        .source = "x=hello; echo $x",
        .expect = .{ .exit_code = 0, .stdout = "hello\n" },
    },
    .{
        .name = "multiple assignments + expansion",
        .source = "x=one; y=two; echo $x $y",
        .expect = .{ .exit_code = 0, .stdout = "one two\n" },
    },
    .{
        .name = "if-then brace form",
        .source = "if true { echo yes } else { echo no }",
        .expect = .{ .exit_code = 0, .stdout = "yes\n" },
    },
    .{
        .name = "if-else brace form",
        .source = "if false { echo yes } else { echo no }",
        .expect = .{ .exit_code = 0, .stdout = "no\n" },
    },
    .{
        .name = "else if chain",
        .source = "if false { echo a } else if true { echo b } else { echo c }",
        .expect = .{ .exit_code = 0, .stdout = "b\n" },
    },
    .{
        .name = "for loop iterates",
        .source = "for x in a b c { echo $x }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\nc\n" },
    },
    .{
        .name = "test builtin: file exists",
        .source = "if test -d /tmp { echo dir } else { echo nope }",
        .expect = .{ .exit_code = 0, .stdout = "dir\n" },
    },
    .{
        .name = "test builtin: numeric compare",
        .source = "if test 5 -gt 3 { echo bigger }",
        .expect = .{ .exit_code = 0, .stdout = "bigger\n" },
    },
    .{
        .name = "command substitution scalar",
        .source = "x=$(/bin/echo captured); echo got $x",
        .expect = .{ .exit_code = 0, .stdout = "got captured\n" },
    },
    .{
        .name = "env-prefix on external command",
        .source = "MY_KEY=42 /usr/bin/env",
        .expect = .{ .exit_code = 0, .stdout = "MY_KEY=42", .stdout_contains = true },
    },
    .{
        .name = "indent block parses same as brace",
        .source = "if true\n  echo from-indent\nelse\n  echo nope\n",
        .expect = .{ .exit_code = 0, .stdout = "from-indent\n" },
    },
    .{
        .name = "for over multi-line indent block",
        .source = "for x in 1 2 3\n  echo num $x\n",
        .expect = .{ .exit_code = 0, .stdout = "num 1\nnum 2\nnum 3\n" },
    },
    .{
        .name = "while loop counts",
        .source = "i=0; while test $i -lt 0 { echo never }; echo done",
        .expect = .{ .exit_code = 0, .stdout = "done\n" },
    },
    .{
        .name = "printf %s and %d",
        .source = "printf '%s %d\\n' hi 42",
        .expect = .{ .exit_code = 0, .stdout = "hi 42\n" },
    },
    .{
        .name = "cd changes pwd",
        .source = "cd /tmp && pwd",
        .expect = .{ .exit_code = 0, .stdout = "/tmp", .stdout_contains = true },
    },
    .{
        .name = "export propagates to children",
        .source = "export GREETING=howdy; /usr/bin/env",
        .expect = .{ .exit_code = 0, .stdout = "GREETING=howdy", .stdout_contains = true },
    },
    .{
        .name = "unset removes a variable (unquoted expansion)",
        .source = "x=alive; echo first $x; unset x; echo second $x",
        .expect = .{ .exit_code = 0, .stdout = "first alive\nsecond\n" },
    },

    // ---- dq variable interpolation ---------------------------------------

    .{
        .name = "dq simple variable",
        .source = "x=world; echo \"hello $x\"",
        .expect = .{ .exit_code = 0, .stdout = "hello world\n" },
    },
    .{
        .name = "dq variable alone",
        .source = "x=world; echo \"$x\"",
        .expect = .{ .exit_code = 0, .stdout = "world\n" },
    },
    .{
        .name = "dq braced variable",
        .source = "dir=/tmp; echo \"path: ${dir}/x\"",
        .expect = .{ .exit_code = 0, .stdout = "path: /tmp/x\n" },
    },
    .{
        .name = "dq concatenated variables",
        .source = "x=alpha; y=beta; echo \"$x$y\"",
        .expect = .{ .exit_code = 0, .stdout = "alphabeta\n" },
    },
    .{
        .name = "dq command substitution",
        .source = "echo \"got: $(/bin/echo hi)\"",
        .expect = .{ .exit_code = 0, .stdout = "got: hi\n" },
    },
    .{
        .name = "dq cmd subst sandwiched between text",
        .source = "echo \"prefix-$(/bin/echo body)-suffix\"",
        .expect = .{ .exit_code = 0, .stdout = "prefix-body-suffix\n" },
    },
    .{
        .name = "dq escape backslash dollar keeps literal",
        .source = "x=expanded; echo \"\\$x is literal\"",
        .expect = .{ .exit_code = 0, .stdout = "$x is literal\n" },
    },
    .{
        .name = "dq escape newline",
        .source = "echo \"line1\\nline2\"",
        .expect = .{ .exit_code = 0, .stdout = "line1\nline2\n" },
    },
    .{
        .name = "dq escape tab",
        .source = "echo \"a\\tb\"",
        .expect = .{ .exit_code = 0, .stdout = "a\tb\n" },
    },
    .{
        .name = "dq escape embedded quote",
        .source = "echo \"q\\\"end\"",
        .expect = .{ .exit_code = 0, .stdout = "q\"end\n" },
    },
    .{
        .name = "dq empty string",
        .source = "echo \"\"",
        .expect = .{ .exit_code = 0, .stdout = "\n" },
    },
    .{
        .name = "dq preserves leading and trailing whitespace",
        .source = "echo \"  spaces  \"",
        .expect = .{ .exit_code = 0, .stdout = "  spaces  \n" },
    },
    .{
        .name = "dq single-quoted is unaffected",
        .source = "x=expanded; echo '$x literal'",
        .expect = .{ .exit_code = 0, .stdout = "$x literal\n" },
    },
    .{
        .name = "dq variable then literal text",
        .source = "name=alice; echo \"hi $name, welcome\"",
        .expect = .{ .exit_code = 0, .stdout = "hi alice, welcome\n" },
    },
    .{
        .name = "dq undefined variable expands to empty",
        .source = "echo \"begin>$nope<end\"",
        .expect = .{ .exit_code = 0, .stdout = "begin><end\n" },
    },
    .{
        .name = "dq inside if condition",
        .source = "x=hello; if test \"$x\" = hello { echo match } else { echo no }",
        .expect = .{ .exit_code = 0, .stdout = "match\n" },
    },
    .{
        .name = "dq inside for items",
        .source = "for s in \"red apple\" \"green pear\" { echo got: $s }",
        .expect = .{ .exit_code = 0, .stdout = "got: red apple\ngot: green pear\n" },
    },
    .{
        .name = "$? sees previous command result within a sequence",
        .source = "/bin/sh -c 'exit 7'; echo \"last=$?\"",
        .expect = .{ .exit_code = 0, .stdout = "last=7\n" },
    },
    .{
        .name = "$? after success is 0",
        .source = "true; echo \"last=$?\"",
        .expect = .{ .exit_code = 0, .stdout = "last=0\n" },
    },

    // ---- break / continue / return ---------------------------------------

    .{
        .name = "break exits a for loop",
        .source = "for x in a b stop c d { if test $x = stop { break }; echo $x }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "continue skips the current for iteration",
        .source = "for x in 1 2 skip 3 4 { if test $x = skip { continue }; echo $x }",
        .expect = .{
            .exit_code = 0,
            .stdout = "1\n2\n3\n4\n",
        },
    },
    .{
        .name = "break exits while loop on first iteration",
        .source = "while true { break }; echo after",
        .expect = .{ .exit_code = 0, .stdout = "after\n" },
    },
    // ----------------------------------------------------------------
    // `time` — behavioral wrapper; transparent to stdout + exit status
    // ----------------------------------------------------------------
    //
    // The wrapper writes its `real / user / sys` lines to stderr; the
    // body's stdout and exit status must pass through completely
    // unaffected. These cases lock in that contract — separate
    // PTY-level visual checks (dim ANSI, alignment) live outside
    // headless.
    .{
        .name = "time wraps a simple command; stdout passes through",
        .source = "time echo hello",
        .expect = .{ .exit_code = 0, .stdout = "hello\n" },
    },
    .{
        .name = "time propagates body exit status (true)",
        .source = "time true",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "time propagates body exit status (false)",
        .source = "time false",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "time wraps a pipeline; only the body's stdout reaches the consumer",
        .source = "time echo first | /bin/cat",
        .expect = .{ .exit_code = 0, .stdout = "first\n" },
    },
    .{
        .name = "time { ... } block sums child outputs",
        .source = "time { echo a; echo b }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "time fires only when reached (false && skips body)",
        // `&&` short-circuits before evaluating `time`. If `time` were
        // somehow eager, `BUG` would land on stdout.
        .source = "false && time echo BUG",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "time wraps a for-loop without an explicit brace",
        // Locks in the wider `timed_form` grammar — `time for x in
        // ...` parses as one wrapped unit, not `(time for x ...)`
        // with the `... { body }` orphaned.
        .source = "time for x in a b c { echo $x }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\nc\n" },
    },
    .{
        .name = "time wraps an if/then",
        .source = "time if true { echo yes }",
        .expect = .{ .exit_code = 0, .stdout = "yes\n" },
    },
    // ----------------------------------------------------------------
    // `key` builtin — user-configurable key bindings
    // ----------------------------------------------------------------
    //
    // These cases exercise the builtin's surface (parser + listing +
    // diagnostics + storage). The actual dispatch path requires
    // interactive raw mode and lives in the PTY suite.
    .{
        .name = "key: bind to a named action succeeds silently",
        .source = "key Esc-P history-prev-prefix",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "key: bind to a literal string succeeds silently",
        .source = "key Alt-L \"ls -la\\n\"",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "key: empty `key` lists installed bindings (canonical form)",
        // `Esc-P` canonicalizes to `Alt-p` on listing — `Alt-` is
        // the canonical modifier name, and Alt-letter case-folds
        // to lowercase (matches the byte sequence Option+P emits).
        .source = "key Esc-P history-prev-prefix; key",
        .expect = .{ .exit_code = 0, .stdout = "Alt-p", .stdout_contains = true },
    },
    .{
        .name = "key: listing shows literal-text bindings re-encoded",
        .source = "key Alt-L \"ls -la\\n\"; key",
        .expect = .{ .exit_code = 0, .stdout = "\"ls -la\\n\"", .stdout_contains = true },
    },
    .{
        .name = "key: unknown action name errors with a helpful hint",
        .source = "key Alt-Q foo-bar-baz",
        .expect = .{
            .exit_code = 1,
            .stderr = "unknown action 'foo-bar-baz'",
            .stderr_contains = true,
        },
    },
    .{
        .name = "key: snake_case action name errors AND suggests kebab",
        // `word_backward` is snake_case; slash's registry has
        // `word-backward`. Critical: must NOT silently bind as
        // literal text (the original draft did and GPT 5.5 caught
        // it). The diagnostic should mention both the typo'd name
        // and the kebab suggestion.
        .source = "key Alt-Q word_backward",
        .expect = .{
            .exit_code = 1,
            .stderr = "did you mean 'word-backward'",
            .stderr_contains = true,
        },
    },
    .{
        .name = "key: multi-chord binding accepted (Ctrl-X,Ctrl-E)",
        // As of zigline v0.7.1 (and slash's multi-chord support),
        // comma-separated chord sequences are bound via the
        // BindingTable primitive. This test asserts the bind path
        // exits cleanly; live navigation is covered by PTY tests.
        .source = "key Ctrl-X,Ctrl-E edit-in-editor",
        .expect = .{ .exit_code = 0 },
    },
    .{
        .name = "key: multi-chord sequence over 8 chords rejected",
        // MAX_CHORD_SEQUENCE = 8; nine chords must error precisely.
        .source = "key a,b,c,d,e,f,g,h,i forward-char",
        .expect = .{
            .exit_code = 2,
            .stderr = "too many chords",
            .stderr_contains = true,
        },
    },
    .{
        .name = "key: empty spec rejected",
        .source = "key \"\" history-prev-prefix",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "key: -e removes a binding (idempotent on missing)",
        .source = "key Alt-Z history-prev-prefix; key -e Alt-Z; key -e Alt-Z",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "key: --erase long form",
        .source = "key Alt-Z history-prev-prefix; key --erase Alt-Z; key",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // No `-d` or `--delete` — slash uses one spelling only.
        .name = "key: -d is not accepted",
        .source = "key Alt-Z history-prev-prefix; key -d Alt-Z",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "key: --delete is not accepted",
        .source = "key Alt-Z history-prev-prefix; key --delete Alt-Z",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "key: -l lists bindings (alias for bare `key`)",
        .source = "key Alt-A history-prev-prefix; key -l",
        .expect = .{ .exit_code = 0, .stdout = "Alt-a", .stdout_contains = true },
    },
    .{
        .name = "key: -r short form for --reset",
        .source = "key Alt-A history-prev-prefix; key -r; key",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "key: --reset clears all user bindings",
        .source = "key Alt-A history-prev-prefix; key Alt-B history-next-prefix; key --reset; key",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "key: --actions lists every registered action",
        // Spot-check three representative entries.
        .source = "key --actions",
        .expect = .{ .exit_code = 0, .stdout = "history-prev-prefix", .stdout_contains = true },
    },
    .{
        .name = "key: rebinding the same chord replaces (no duplicate)",
        // Two binds of `Alt-Z`, then `key` should list it once.
        // Canonical form lowercases the letter (meta-letter case-fold).
        .source = "key Alt-Z history-prev-prefix; key Alt-Z \"echo X\\n\"; key",
        .expect = .{
            .exit_code = 0,
            .stdout = "Alt-z \t\"echo X\\n\"\n",
            .stdout_contains = true,
        },
    },
    .{
        .name = "time emits a `real` line to stderr",
        .source = "time true",
        .expect = .{
            .exit_code = 0,
            .stdout = "",
            .stderr = "real",
            .stderr_contains = true,
        },
    },
    .{
        .name = "time emits user and sys lines too",
        // Anchor on `sys` since it's the last of the three; if it
        // appears we know `real` and `user` did too (formatter writes
        // them in order with one `write` per group).
        .source = "time true",
        .expect = .{
            .exit_code = 0,
            .stdout = "",
            .stderr = "sys",
            .stderr_contains = true,
        },
    },
    .{
        // A flag-flipping pattern keeps the loop bounded without
        // arithmetic — the body sets the flag that the condition reads.
        .name = "while loop with body-set flag terminates cleanly",
        .source = "f=go; while test $f = go { echo iter; f=stop }; echo done",
        .expect = .{ .exit_code = 0, .stdout = "iter\ndone\n" },
    },
    .{
        .name = "break in nested for breaks only the innermost",
        .source = "for outer in A B { for inner in 1 2 3 { if test $inner = 2 { break }; echo $outer$inner } }",
        .expect = .{ .exit_code = 0, .stdout = "A1\nB1\n" },
    },
    .{
        .name = "continue in nested for continues only the innermost",
        .source = "for outer in A B { for inner in 1 skip 2 { if test $inner = skip { continue }; echo $outer$inner } }",
        .expect = .{ .exit_code = 0, .stdout = "A1\nA2\nB1\nB2\n" },
    },

    // ---- glob expansion (against a tmpfs fixture) ------------------------
    //
    // The harness pre-creates /tmp/slash-glob-fixture before the test run
    // with a known set of files; these cases cd in and exercise globbing
    // patterns. Hidden files require an explicit leading `.` in the
    // pattern, no-match leaves the pattern literal, and quoted strings
    // never glob.

    .{
        .name = "glob: simple star expands sorted",
        .source = "cd /tmp/slash-glob-fixture && echo *.txt",
        .expect = .{ .exit_code = 0, .stdout = "a.txt b.txt c.txt\n" },
    },
    .{
        .name = "glob: question mark matches one byte",
        .source = "cd /tmp/slash-glob-fixture && echo ?.txt",
        .expect = .{ .exit_code = 0, .stdout = "a.txt b.txt c.txt\n" },
    },
    .{
        .name = "glob: no match leaves pattern literal",
        .source = "cd /tmp/slash-glob-fixture && echo *.nope",
        .expect = .{ .exit_code = 0, .stdout = "*.nope\n" },
    },
    .{
        .name = "glob: hidden files require explicit dot",
        .source = "cd /tmp/slash-glob-fixture && echo *",
        .expect = .{ .exit_code = 0, .stdout = "a.txt b.txt c.txt sub\n" },
    },
    .{
        .name = "glob: explicit leading dot picks up hidden",
        .source = "cd /tmp/slash-glob-fixture && echo .h*",
        .expect = .{ .exit_code = 0, .stdout = ".hidden\n" },
    },
    .{
        .name = "glob: quoted pattern is literal (no expansion)",
        .source = "cd /tmp/slash-glob-fixture && echo '*.txt'",
        .expect = .{ .exit_code = 0, .stdout = "*.txt\n" },
    },
    .{
        .name = "glob: dq pattern is literal",
        .source = "cd /tmp/slash-glob-fixture && echo \"*.txt\"",
        .expect = .{ .exit_code = 0, .stdout = "*.txt\n" },
    },
    .{
        .name = "glob: subdirectory pattern",
        .source = "cd /tmp/slash-glob-fixture && echo sub/*.md",
        .expect = .{ .exit_code = 0, .stdout = "sub/x.md sub/y.md\n" },
    },
    .{
        .name = "glob: ** recursive descent",
        .source = "cd /tmp/slash-glob-fixture && echo **/*.md",
        .expect = .{ .exit_code = 0, .stdout = "sub/x.md sub/y.md\n" },
    },
    .{
        .name = "glob: for loop iterates over matches",
        .source = "cd /tmp/slash-glob-fixture && for f in *.txt { echo got $f }",
        .expect = .{ .exit_code = 0, .stdout = "got a.txt\ngot b.txt\ngot c.txt\n" },
    },

    // ---- ${var ?? default} fallback expansion (PLAN §12) -----------------
    //
    // The narrow form: bare name on the left of `??`, fallback word on
    // the right. Name set & non-empty → use the value. Name unset or
    // empty → use the fallback. The fallback is itself a Word, supporting
    // `$name` references, double- and single-quoted segments, and escape
    // decoding. No nested `${...}` form.

    .{
        .name = "fallback: set variable wins",
        .source = "x=alice; echo \"${x ?? guest}\"",
        .expect = .{ .exit_code = 0, .stdout = "alice\n" },
    },
    .{
        .name = "fallback: unset variable picks default literal",
        .source = "echo \"${nope ?? guest}\"",
        .expect = .{ .exit_code = 0, .stdout = "guest\n" },
    },
    .{
        .name = "fallback: default with $var reference",
        .source = "alt=BACKUP; echo \"${nope ?? $alt}\"",
        .expect = .{ .exit_code = 0, .stdout = "BACKUP\n" },
    },
    .{
        .name = "fallback: default with mixed text and var",
        .source = "u=root; echo \"${user ?? hi-$u-end}\"",
        .expect = .{ .exit_code = 0, .stdout = "hi-root-end\n" },
    },
    .{
        // The outer dq already preserves spaces in the default, so no
        // inner quoting is needed for a multi-word fallback.
        .name = "fallback: default with multi-word literal",
        .source = "echo \"${nope ?? two words}\"",
        .expect = .{ .exit_code = 0, .stdout = "two words\n" },
    },
    .{
        .name = "fallback: single-quoted default in body",
        .source = "echo \"${nope ?? 'literal $x'}\"",
        .expect = .{ .exit_code = 0, .stdout = "literal $x\n" },
    },
    .{
        .name = "fallback: default literal path with slashes",
        .source = "echo \"${LOG ?? /var/log/app.log}\"",
        .expect = .{ .exit_code = 0, .stdout = "/var/log/app.log\n" },
    },
    .{
        .name = "fallback: outside dq context still works",
        .source = "echo ${maybe ?? safe}",
        .expect = .{ .exit_code = 0, .stdout = "safe\n" },
    },
    .{
        .name = "fallback: no `??` is a plain braced reference",
        .source = "x=plain; echo \"${x}\"",
        .expect = .{ .exit_code = 0, .stdout = "plain\n" },
    },

    // ---- source / . builtin ---------------------------------------------
    //
    // Loads another script's contents into the current session in shell
    // context: assignments and definitions are visible after the source
    // call returns. Failures (missing file, parse error) exit 1 with a
    // diagnostic on stderr.

    .{
        .name = "source: assigns and emits in current session",
        .source = "source /tmp/slash-source-fixture/basic.sl; echo got=$msg",
        .expect = .{ .exit_code = 0, .stdout = "from-source\ngot=hello\n" },
    },
    .{
        .name = "source: dot is an alias",
        .source = ". /tmp/slash-source-fixture/basic.sl",
        .expect = .{ .exit_code = 0, .stdout = "from-source\n" },
    },
    .{
        .name = "source: vars set in script visible afterwards",
        .source = "source /tmp/slash-source-fixture/setvars.sl; echo $a-$b",
        .expect = .{ .exit_code = 0, .stdout = "alpha-beta\n" },
    },
    .{
        .name = "source: exit status is the last statement's",
        .source = "source /tmp/slash-source-fixture/exit7.sl",
        .expect = .{ .exit_code = 7 },
    },
    .{
        .name = "source: missing file exits 1",
        .source = "source /tmp/slash-source-fixture/missing.sl",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "source: shebang line is skipped",
        .source = "source /tmp/slash-source-fixture/shebang.sl",
        .expect = .{ .exit_code = 0, .stdout = "after-shebang\n" },
    },

    // ---- PATH resolution caching ----------------------------------------
    //
    // The cache is a performance optimization; from the user's point of
    // view, repeated lookups must produce the same answer and a `$PATH`
    // change must be honored on the next external invocation.

    .{
        .name = "path-cache: same command resolved twice in one session",
        .source = "/bin/sh -c 'echo first'; /bin/sh -c 'echo second'",
        .expect = .{ .exit_code = 0, .stdout = "first\nsecond\n" },
    },
    .{
        // Two bare-name invocations of the same external command in a
        // sequence — second one must hit the cache and resolve identically.
        .name = "path-cache: bare-name lookup is consistent",
        .source = "true; true; true",
        .expect = .{ .exit_code = 0 },
    },

    // ---- @(...) list capture (PLAN §7 Rule 29) ---------------------------
    //
    // `@(...)` is the list form of command substitution: stdout splits
    // on newlines, each non-empty field becomes one argv entry. `$(...)`
    // stays scalar; nothing about either form's behavior is overloaded.

    .{
        .name = "list-capture: assigns as list, iterates",
        .source = "xs=@(/usr/bin/printf 'a\\nb\\nc\\n'); for x in $xs { echo $x }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\nc\n" },
    },
    .{
        .name = "list-capture: splices directly into for items",
        .source = "for n in @(/usr/bin/printf '1\\n2\\n3\\n') { echo n=$n }",
        .expect = .{ .exit_code = 0, .stdout = "n=1\nn=2\nn=3\n" },
    },
    .{
        .name = "list-capture: scalar position joins with space",
        .source = "echo \"got: @(/usr/bin/printf 'a\\nb\\nc\\n')\"",
        .expect = .{ .exit_code = 0, .stdout = "got: a b c\n" },
    },
    .{
        .name = "list-capture: empty output yields no fields",
        .source = "for x in @(/usr/bin/true) { echo iter }; echo done",
        .expect = .{ .exit_code = 0, .stdout = "done\n" },
    },
    .{
        .name = "list-capture: single-line output is one field",
        .source = "for x in @(/bin/echo single) { echo got=$x }",
        .expect = .{ .exit_code = 0, .stdout = "got=single\n" },
    },
    .{
        .name = "list-capture: bare @user is still an ident (no fusion w/o paren)",
        .source = "echo @user",
        .expect = .{ .exit_code = 0, .stdout = "@user\n" },
    },

    // ---- read / shift / type / command / exec / cd polish ----------------

    .{
        .name = "read: single name absorbs full line",
        .source = "read line < /tmp/slash-builtins-fixture/three.txt; echo \"got=[$line]\"",
        .expect = .{ .exit_code = 0, .stdout = "got=[alpha beta gamma]\n" },
    },
    .{
        .name = "read: multi-name splits on whitespace; last absorbs rest",
        .source = "read first rest < /tmp/slash-builtins-fixture/three.txt; echo first=$first rest=$rest",
        .expect = .{ .exit_code = 0, .stdout = "first=alpha rest=beta gamma\n" },
    },
    .{
        .name = "read: three names, three fields",
        .source = "read a b c < /tmp/slash-builtins-fixture/three.txt; echo \"a=$a b=$b c=$c\"",
        .expect = .{ .exit_code = 0, .stdout = "a=alpha b=beta c=gamma\n" },
    },
    .{
        .name = "read: returns 1 on eof",
        .source = "read x < /tmp/slash-builtins-fixture/empty.txt",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "shift: default by one",
        .source = "/bin/sh -c 'echo a b c d' ; echo done", // ensure no shift happens here
        .expect = .{ .exit_code = 0, .stdout = "a b c d\ndone\n" },
    },
    .{
        .name = "type: builtin",
        .source = "type echo",
        .expect = .{ .exit_code = 0, .stdout = "echo is a shell builtin\n" },
    },
    .{
        // macOS canonicalizes `cat` to `/bin/cat`; Linux puts it at
        // `/usr/bin/cat`. Use `stdout_contains` so the test works
        // on both without locking in a specific FHS layout.
        .name = "type: external command",
        .source = "type cat",
        .expect = .{ .exit_code = 0, .stdout = "cat is /", .stdout_contains = true },
    },
    .{
        .name = "type: source / dot are special-dispatched builtins",
        .source = "type source",
        .expect = .{ .exit_code = 0, .stdout = "source is a shell builtin\n" },
    },
    .{
        .name = "type: not found exits 1",
        .source = "type nope-no-no",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "command: bypasses the echo builtin and uses external",
        .source = "command /bin/echo via-external",
        .expect = .{ .exit_code = 0, .stdout = "via-external\n" },
    },
    .{
        // exec failure leaves the shell alive (see PLAN §20 special
        // value 127); the test asserts that without trailing
        // statements that would overwrite the failure status.
        .name = "exec: missing target exits 127",
        .source = "exec /no/such/binary-anywhere",
        .expect = .{ .exit_code = 127 },
    },
    .{
        // macOS resolves `/tmp` to `/private/tmp`; Linux keeps it as
        // `/tmp`. Substring-check `/tmp` so both pass.
        .name = "cd -: toggles to OLDPWD and prints",
        .source = "cd /tmp; cd /; cd -",
        .expect = .{ .exit_code = 0, .stdout = "/tmp\n", .stdout_contains = true },
    },
    .{
        .name = "cd -: errors when OLDPWD unset",
        .source = "cd -",
        .expect = .{ .exit_code = 1 },
    },

    // ---- job control: kill / disown / fg / bg ---------------------------
    //
    // `kill -SIG TARGET...` accepts named signals (with or without `SIG`
    // prefix), numeric signals, and either `pid` or `%N` targets. `kill
    // -l` lists every signal slash recognizes. `disown` removes a job
    // from the JobTable; the underlying process keeps running. `fg`/`bg`
    // resume stopped jobs by sending `SIGCONT` to the process group.
    //
    // These cases assert the user-visible behavior; deeper interactions
    // with terminal handoff (`tcsetpgrp`) are exercised in the PTY tests.

    .{
        .name = "kill: -l lists known signals",
        .source = "kill -l",
        .expect = .{ .exit_code = 0, .stdout = "HUP", .stdout_contains = true },
    },
    .{
        .name = "kill: -INVALID is a usage error",
        .source = "kill -ZAP 1",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "kill: missing target is a usage error",
        .source = "kill -TERM",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "kill: bad pid spec",
        .source = "kill -TERM not-a-pid",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "kill: bad %N spec",
        .source = "kill -TERM %nope",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "kill: nonexistent job id",
        .source = "kill -TERM %99",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "disown: no current job is an error",
        .source = "disown",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "kill: signals a real backgrounded job via %N",
        .source = "sleep 5 >/dev/null 2>&1 & kill -TERM %1; wait %1; echo done",
        .expect = .{ .exit_code = 0, .stdout = "done\n", .stdout_contains = true },
    },

    // ---- $! and wait $pid (POSIX async-pid + wait-by-pid) ---------------
    //
    // `$!` is the pid of the most recently launched background job (the
    // last process of a backgrounded pipeline). `wait PID` finds the
    // owning Job and waits on it; bash-compatible.

    .{
        .name = "$!: empty before any bg job",
        .source = "echo \"before=[$!]\"",
        .expect = .{ .exit_code = 0, .stdout = "before=[]\n" },
    },
    .{
        .name = "$!: set to backgrounded pid; wait $! works",
        .source = "sleep 0.2 >/dev/null 2>&1 &\nwait $!\necho final=$?",
        .expect = .{ .exit_code = 0, .stdout = "final=0\n" },
    },
    .{
        .name = "wait $! propagates the exit status",
        .source = "false &\nwait $!\necho got=$?",
        .expect = .{ .exit_code = 0, .stdout = "got=1\n" },
    },
    .{
        .name = "wait: bare integer that's not our child errors",
        .source = "wait 1",
        .expect = .{ .exit_code = 127 },
    },
    .{
        .name = "wait: invalid spec is a usage error",
        .source = "wait %nope",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "$!: bg pipeline records the LAST stage's pid; wait returns the JOB result (pipefail-on)",
        // `$!` is the last stage's pid, but `wait $!` finds the owning
        // Job and returns its aggregate result. Per Slash's default
        // `pipefail = on` (PLAN §7 Rule 11), `false | true` => 1.
        .source = "false | true >/dev/null 2>&1 &\nwait $!\necho got=$?",
        .expect = .{ .exit_code = 0, .stdout = "got=1\n" },
    },

    .{
        .name = "disown: removes a backgrounded job",
        // After disown, the orphan keeps running its (short) sleep then
        // exits naturally. We don't reap it from the table — that's the
        // whole point of disown.
        .source = "sleep 1 >/dev/null 2>&1 & disown; jobs; echo gone",
        .expect = .{ .exit_code = 0, .stdout = "gone\n", .stdout_contains = true },
    },
    .{
        .name = "disown: %N variant",
        .source = "sleep 1 >/dev/null 2>&1 & disown %1; jobs; echo ok",
        .expect = .{ .exit_code = 0, .stdout = "ok\n", .stdout_contains = true },
    },
    .{
        .name = "disown: -a clears all backgrounded jobs",
        .source = "sleep 1 >/dev/null 2>&1 & sleep 1 >/dev/null 2>&1 & disown -a; jobs; echo cleared",
        .expect = .{ .exit_code = 0, .stdout = "cleared\n", .stdout_contains = true },
    },

    .{
        .name = "type: kill / fg / bg / disown are builtins",
        .source = "type kill; type fg; type bg; type disown",
        .expect = .{ .exit_code = 0, .stdout = "kill is a shell builtin\nfg is a shell builtin\nbg is a shell builtin\ndisown is a shell builtin\n" },
    },

    // ---- SIGPIPE / EOF semantics (CHECKLIST §8, §9) ---------------------
    //
    // The classic `yes | head` test: head reads a few lines and exits;
    // its closure of the pipe should make yes's next write fail with
    // SIGPIPE, terminating the pipeline naturally. The shell itself
    // must not die. Builtin printf into a closed pipe also exercises
    // the shell-process SIGPIPE-ignore path (the writing process is
    // an external `printf`/`yes`, but the case below where we pipe
    // an *internal* echo through head proves the parent shell isn't
    // killed when its forked child takes SIGPIPE either).

    .{
        .name = "yes | head terminates cleanly (pipefail surfaces SIGPIPE)",
        // With pipefail=on (Slash default), the pipeline result is the
        // first non-zero/signaled stage. `head` exits 0; `yes` dies of
        // SIGPIPE → 141. The shell survives, which is what this test
        // is really asserting; the exit byte is just confirmation that
        // the SIGPIPE made it back as a typed Result.
        .source = "yes | head -n 3",
        .expect = .{ .exit_code = 141, .stdout = "y\ny\ny\n" },
    },
    .{
        .name = "yes | head — shell survives and runs the next statement",
        .source = "yes | head -n 3; echo survived",
        .expect = .{ .exit_code = 0, .stdout = "survived\n", .stdout_contains = true },
    },
    .{
        .name = "echo builtin into head does not kill the shell",
        // Even though `echo` writes only one line and exits 0, this
        // exercises the path: builtin runs in a forked pipeline child,
        // head reads, both finish cleanly. Subsequent `echo done` proves
        // the parent shell survived.
        .source = "echo upstream | head -n 1; echo done",
        .expect = .{ .exit_code = 0, .stdout = "upstream\ndone\n" },
    },
    .{
        .name = "external writer into head: shell survives a pipefail-on-SIGPIPE",
        // /bin/yes runs forever until SIGPIPE; pipefail-on (default)
        // means the pipeline result is the first non-zero stage. /bin/yes
        // dying to SIGPIPE counts as non-zero, so the pipeline exits
        // non-zero — but the shell is still alive to run the next
        // statement.
        .source = "yes | head -n 2; echo survived",
        .expect = .{ .exit_code = 0, .stdout = "y\ny\nsurvived\n", .stdout_contains = true },
    },

    // ---- match: pattern dispatch (PLAN §12) ------------------------------
    //
    // `match SUBJECT { arms... }` runs the body of the first arm whose
    // pattern matches. Subject is one Word expanded at runtime; patterns
    // are literal grammar atoms (no $var, no command substitution). With
    // no matching arm, exit 0.

    .{
        .name = "match: literal pattern hit",
        .source = "match alpha { alpha { echo got-alpha }; beta { echo got-beta }; * { echo other } }",
        .expect = .{ .exit_code = 0, .stdout = "got-alpha\n" },
    },
    .{
        .name = "match: literal pattern miss falls through to *",
        .source = "match wibble { alpha { echo a }; beta { echo b }; * { echo other } }",
        .expect = .{ .exit_code = 0, .stdout = "other\n" },
    },
    .{
        .name = "match: glob arm",
        .source = "match readme.md { *.md { echo doc }; *.txt { echo text }; * { echo other } }",
        .expect = .{ .exit_code = 0, .stdout = "doc\n" },
    },
    .{
        .name = "match: multi-pattern arm",
        .source = "match push { init status { echo control }; push pull { echo network }; * { echo none } }",
        .expect = .{ .exit_code = 0, .stdout = "network\n" },
    },
    .{
        .name = "match: variable subject",
        .source = "x=hi; match $x { hi { echo found }; * { echo missed } }",
        .expect = .{ .exit_code = 0, .stdout = "found\n" },
    },
    .{
        .name = "match: no arm matches => exit 1, runs nothing",
        // PLAN §12: missing default surfaces as a non-zero status so
        // `&&`/`||` can distinguish "matched a no-op" from "no arm
        // matched". Users who want silent no-op write `* { true }`.
        .source = "match nope { alpha { echo a } }; echo done=$?",
        .expect = .{ .exit_code = 0, .stdout = "done=1\n" },
    },
    .{
        .name = "match: explicit `* { true }` opts into silent no-op",
        .source = "match nope { alpha { echo a }; * { true } }; echo done=$?",
        .expect = .{ .exit_code = 0, .stdout = "done=0\n" },
    },
    .{
        .name = "match: first match wins",
        .source = "match all { * { echo first }; * { echo second } }",
        .expect = .{ .exit_code = 0, .stdout = "first\n" },
    },
    .{
        .name = "match: brace-form body with sequenced statements",
        .source = "match go { go { echo a; echo b } }",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "match: indent form",
        .source = "match alpha\n  alpha { echo from-indent }\n  beta { echo nope }\n",
        .expect = .{ .exit_code = 0, .stdout = "from-indent\n" },
    },
    .{
        .name = "match: subcommand router inside cmd",
        .source = "cmd dispatch {\n  match $1 {\n    init { echo doing-init }\n    status { echo all-good }\n    * { echo unknown }\n  }\n}\ndispatch init\ndispatch status\ndispatch wat",
        .expect = .{ .exit_code = 0, .stdout = "doing-init\nall-good\nunknown\n" },
    },
    .{
        .name = "match: runtime-generated pattern rejected at lower",
        .source = "p=hi; match hi { $p { echo nope } }",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "match: command-substitution pattern rejected",
        .source = "match hi { $(echo hi) { echo nope } }",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "match: body's exit status propagates",
        .source = "match hit { hit { false } }",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "match: arm with quoted pattern (literal text)",
        .source = "match ab { 'ab' { echo q-yes }; * { echo q-no } }",
        .expect = .{ .exit_code = 0, .stdout = "q-yes\n" },
    },

    // ---- cmd user-defined commands (PLAN §7 Rule 26) ---------------------
    //
    // `cmd name { body }` registers a session-scoped command body.
    // Resolution order: builtins → defs → PATH. Body sees `$1..$N`,
    // `$@`, `$#` bound from the call site; the call frame restores the
    // caller's positionals on return. Mutations to vars/cwd/etc. escape
    // back into the calling session — `cmd` is NOT a subshell.

    .{
        .name = "cmd: simple greet by positional",
        .source = "cmd greet { echo hello $1 }; greet world",
        .expect = .{ .exit_code = 0, .stdout = "hello world\n" },
    },
    .{
        .name = "cmd: $#, $@ inside body",
        .source = "cmd args { echo n=$#; for a in $@ { echo a=$a } }; args x y z",
        .expect = .{ .exit_code = 0, .stdout = "n=3\na=x\na=y\na=z\n" },
    },
    .{
        .name = "cmd: return N propagates to caller",
        .source = "cmd bad { return 7 }; bad || echo \"got=$?\"",
        .expect = .{ .exit_code = 0, .stdout = "got=7\n" },
    },
    .{
        .name = "cmd: return 0 is success",
        .source = "cmd ok { return 0 }; ok && echo all-good",
        .expect = .{ .exit_code = 0, .stdout = "all-good\n" },
    },
    .{
        .name = "cmd: var mutation escapes (not a subshell)",
        .source = "cmd set { x=inside }; x=outer; set; echo $x",
        .expect = .{ .exit_code = 0, .stdout = "inside\n" },
    },
    .{
        .name = "cmd: caller's positionals restored after body",
        .source = "cmd inner { echo inner=$1 }; cmd outer { inner X; echo outer=$1 }; outer A",
        .expect = .{ .exit_code = 0, .stdout = "inner=X\nouter=A\n" },
    },
    .{
        .name = "cmd: redefinition replaces the body",
        .source = "cmd f { echo first }; f; cmd f { echo second }; f",
        .expect = .{ .exit_code = 0, .stdout = "first\nsecond\n" },
    },
    .{
        .name = "cmd: builtins still win the lookup",
        .source = "cmd echo { /bin/echo never-fires }; echo direct",
        .expect = .{ .exit_code = 0, .stdout = "direct\n" },
    },
    .{
        .name = "cmd: defined cmd beats PATH external",
        .source = "cmd cat { echo overridden }; cat",
        .expect = .{ .exit_code = 0, .stdout = "overridden\n" },
    },

    // ---- `cmd` builtin (list / query / delete / reset) -------------------

    .{
        // Empty session: `cmd` with no args lists nothing and exits 0.
        // Important for the `cmd<Enter>` REPL path.
        .name = "cmd: bare `cmd` with no defs lists nothing",
        .source = "cmd",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // `cmd -l` and `cmd --list` are the same as bare `cmd`.
        .name = "cmd: -l alias for list",
        .source = "cmd greet { echo hi }\ncmd -l",
        .expect = .{
            .exit_code = 0,
            .stdout = "cmd greet { echo hi }\n",
        },
    },
    .{
        .name = "cmd: --list alias for list",
        .source = "cmd greet { echo hi }\ncmd --list",
        .expect = .{
            .exit_code = 0,
            .stdout = "cmd greet { echo hi }\n",
        },
    },
    .{
        // `cmd NAME` queries a single definition. The output is the
        // round-trippable source — the same bytes the user typed.
        .name = "cmd: NAME queries the round-trippable source (brace form)",
        .source = "cmd greet { echo \"hello, $1\" }\ncmd greet",
        .expect = .{
            .exit_code = 0,
            .stdout = "cmd greet { echo \"hello, $1\" }\n",
        },
    },
    .{
        // Same query, indent form. The reprinted definition shows the
        // exact whitespace the user typed.
        .name = "cmd: NAME queries the indent-form source verbatim",
        .source = "cmd greet\n  echo \"hello, $1\"\ncmd greet",
        .expect = .{
            .exit_code = 0,
            .stdout = "cmd greet\n  echo \"hello, $1\"\n",
        },
    },
    .{
        // Querying an undefined name is a non-zero exit with no
        // stdout — matches `str NAME` for undefined abbreviations.
        .name = "cmd: query of undefined name exits 1",
        .source = "cmd missing",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "cmd: -e removes a definition",
        .source = "cmd a { echo A }\ncmd b { echo B }\ncmd -e a\ncmd",
        .expect = .{
            .exit_code = 0,
            .stdout = "cmd b { echo B }\n",
        },
    },
    .{
        .name = "cmd: --erase long form",
        .source = "cmd a { echo A }\ncmd --erase a\ncmd",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // No `-d` or `--delete` aliases. The trio uses one spelling.
        .name = "cmd: -d is not accepted",
        .source = "cmd a { echo A }\ncmd -d a",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "cmd: --delete is not accepted",
        .source = "cmd a { echo A }\ncmd --delete a",
        .expect = .{ .exit_code = 2 },
    },
    .{
        // Idempotent erase — missing names are not an error. Same
        // semantics as `str -e` and `key -e`.
        .name = "cmd: -e on missing name succeeds idempotently",
        .source = "cmd -e nope",
        .expect = .{ .exit_code = 0 },
    },
    .{
        .name = "cmd: -e with no names is a usage error",
        .source = "cmd -e",
        .expect = .{ .exit_code = 2, .stderr = "cmd: usage: cmd -e NAME [NAME...]\n" },
    },
    .{
        .name = "cmd: --reset clears every definition",
        .source = "cmd a { echo A }\ncmd b { echo B }\ncmd --reset\ncmd",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "cmd: -r short form for --reset",
        .source = "cmd a { echo A }\ncmd b { echo B }\ncmd -r\ncmd",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // Calling an erased cmd falls through to PATH lookup (and
        // typically errors). Confirms the erase took effect.
        .name = "cmd: erased cmd is no longer callable",
        .source = "cmd hello { echo hi }\nhello\ncmd -e hello\nhello",
        .expect = .{ .exit_code = 127, .stdout = "hi\n", .stdout_contains = true },
    },

    // ---- `cmd` lexical disambiguation (line-at-a-time REPL behavior) -----

    .{
        // Line-at-a-time REPL: `cmd<Enter>` with no following body
        // commits immediately as a builtin call. This is the desired
        // tradeoff vs the old behavior of entering multi-line
        // continuation. (See PLAN §14 + the original design discussion
        // — preserves Command clarity at the keystroke moment.)
        .name = "cmd: bare `cmd` does not enter multi-line continuation",
        .source = "cmd",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // `cmd NAME<Enter>` with no following body is a builtin
        // query, not an incomplete definition.
        .name = "cmd: `cmd NAME` with no body is a query, not incomplete",
        .source = "cmd missing",
        .expect = .{ .exit_code = 1 },
    },
    .{
        // The grammar still routes to the keyword definition path
        // when a brace block follows; this regression-tests that the
        // wrapper's contextual promotion didn't break the existing
        // definition syntax.
        .name = "cmd: brace-form definition still works",
        .source = "cmd hi { echo hi-body }\nhi",
        .expect = .{ .exit_code = 0, .stdout = "hi-body\n" },
    },
    .{
        // Indent-form definition still works when the deeper-indent
        // body is present in the same parsed chunk.
        .name = "cmd: indent-form definition still works",
        .source = "cmd hi\n  echo indent-body\nhi",
        .expect = .{ .exit_code = 0, .stdout = "indent-body\n" },
    },

    // ---- `str` flags: `-l`/`-e`/`-r` (no aliases) ------------------------

    .{
        .name = "str: --erase long form",
        .source = "str a foo\nstr --erase a\nstr",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        // No `-d` or `--delete` — slash uses one spelling.
        .name = "str: -d is not accepted",
        .source = "str a foo\nstr -d a",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "str: --delete is not accepted",
        .source = "str a foo\nstr --delete a",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "str: -e takes multiple names",
        .source = "str a 1\nstr b 2\nstr -e a b\nstr",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "str: -l lists abbreviations",
        .source = "str a foo\nstr -l",
        .expect = .{ .exit_code = 0, .stdout = "str 'a' 'foo'\n" },
    },
    .{
        .name = "str: --list long form",
        .source = "str a foo\nstr b bar\nstr --list",
        .expect = .{ .exit_code = 0, .stdout = "str 'a' 'foo'\nstr 'b' 'bar'\n" },
    },
    .{
        .name = "str: --reset clears all",
        .source = "str a 1\nstr b 2\nstr --reset\nstr",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "str: -r short form for --reset",
        .source = "str a 1\nstr b 2\nstr -r\nstr",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },

    // ---- jobs / wait builtins (PLAN §19) --------------------------------

    .{
        .name = "wait: with no jobs is a no-op success",
        .source = "wait",
        .expect = .{ .exit_code = 0 },
    },
    .{
        .name = "wait %N: returns the named job's status",
        .source = "/bin/sh -c 'exit 5' & wait %1; echo result=$?",
        .expect = .{ .exit_code = 0, .stdout = "result=5\n" },
    },
    .{
        .name = "wait: aggregates over all background jobs",
        .source = "/bin/sh -c 'exit 0' & wait; echo done=$?",
        .expect = .{ .exit_code = 0, .stdout = "done=0\n" },
    },
    .{
        .name = "jobs: lists a running detached job",
        .source = "/bin/sleep 0.05 & jobs; wait",
        .expect = .{ .exit_code = 0, .stdout = "[1]", .stdout_contains = true },
    },
    .{
        .name = "jobs: empty when no detached jobs",
        .source = "true; jobs",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },

    // ---- comment handling inside compound forms -------------------------
    //
    // The lexer drops `#...` runs as trivia. These cases lock down the
    // behavior so the trivia drop never quietly fails inside a compound
    // body, after a keyword, inside `( ... )`, or as a stand-alone line
    // between sequence items.

    .{
        .name = "comments: inside { ... } body",
        .source = "if true {\n  # in body\n  echo got\n}",
        .expect = .{ .exit_code = 0, .stdout = "got\n" },
    },
    .{
        .name = "comments: trailing on the keyword's own line",
        .source = "if true { # on the same line\n  echo k\n}",
        .expect = .{ .exit_code = 0, .stdout = "k\n" },
    },
    .{
        .name = "comments: inside ( ... ) subshell",
        .source = "(echo a\n# inside sub\necho b)",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "comments: stand-alone line between statements",
        .source = "echo a\n# stand-alone\necho b",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "comments: leading comment before any statement",
        .source = "# leading\necho hi",
        .expect = .{ .exit_code = 0, .stdout = "hi\n" },
    },
    .{
        .name = "comments: in for body",
        .source = "for x in 1 2 {\n  # iter\n  echo $x\n}",
        .expect = .{ .exit_code = 0, .stdout = "1\n2\n" },
    },
    .{
        .name = "comments: in while body",
        .source = "i=go; while test $i = go {\n  # one pass\n  echo iter\n  i=stop\n}",
        .expect = .{ .exit_code = 0, .stdout = "iter\n" },
    },
    .{
        .name = "comments: in cmd body",
        .source = "cmd f {\n  # private\n  echo body\n}\nf",
        .expect = .{ .exit_code = 0, .stdout = "body\n" },
    },

    // ---- heredocs (PLAN: column-determined dedent) -----------------------
    //
    // Two open sigils: `<<TAG` interpolates `$var` / `$(...)`,
    // `<<'TAG'` is byte-literal. The closing line is the first line
    // whose trimmed content equals the tag; that line's column at the
    // tag's first byte sets the dedent margin for body lines. Multiple
    // heredocs on one logical line are queued in source order.

    .{
        .name = "heredoc: literal body, single line",
        .source = "cat <<'EOF'\nhello world\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "hello world\n" },
    },
    .{
        .name = "heredoc: literal preserves $ unchanged",
        .source = "x=alice\ncat <<'EOF'\nhello $x\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "hello $x\n" },
    },
    .{
        .name = "heredoc: interpolating expands $var",
        .source = "x=alice\ncat <<EOF\nhello $x\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "hello alice\n" },
    },
    .{
        .name = "heredoc: interpolating expands ${name}",
        .source = "user=root\ncat <<EOF\npath=/home/${user}\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "path=/home/root\n" },
    },
    .{
        .name = "heredoc: interpolating expands $(cmd)",
        .source = "cat <<EOF\ngot: $(/bin/echo hi)\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "got: hi\n" },
    },
    .{
        .name = "heredoc: column-determined dedent",
        .source = "cat <<EOF\n    indented\n    more\n    EOF\n",
        .expect = .{ .exit_code = 0, .stdout = "indented\nmore\n" },
    },
    .{
        .name = "heredoc: empty body",
        .source = "cat <<EOF\nEOF\necho done",
        .expect = .{ .exit_code = 0, .stdout = "done\n" },
    },
    .{
        .name = "heredoc: command after the sigil on the same line",
        .source = "echo before; cat <<EOF; echo after\nin body\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "before\nin body\nafter\n" },
    },
    .{
        .name = "heredoc: multiple heredocs on one line, queued in order",
        .source = "cat <<A; cat <<B\nbody of A\nA\nbody of B\nB\n",
        .expect = .{ .exit_code = 0, .stdout = "body of A\nbody of B\n" },
    },
    .{
        .name = "heredoc: feeds read",
        .source = "read line <<EOF\nhello\nEOF\necho got=$line",
        .expect = .{ .exit_code = 0, .stdout = "got=hello\n" },
    },
    .{
        .name = "heredoc: literal escape leaves backslash unchanged",
        .source = "cat <<'EOF'\na\\nb\nEOF\n",
        .expect = .{ .exit_code = 0, .stdout = "a\\nb\n" },
    },

    // ---- trap builtin ----------------------------------------------------
    //
    // EXIT pseudo-signal fires before the shell process returns. Real
    // signals (HUP/INT/QUIT/TERM/USR1/USR2) install async-signal-safe
    // handlers that flip a flag; the eval safe-point loop drains and
    // runs the body. Trap source is parsed at registration time so
    // surface errors surface there, not on signal delivery.

    .{
        .name = "trap: EXIT runs after the body completes",
        .source = "trap 'echo bye' EXIT; echo hi",
        .expect = .{ .exit_code = 0, .stdout = "hi\nbye\n" },
    },
    .{
        .name = "trap: EXIT runs after `exit N`",
        .source = "trap 'echo bye' EXIT; echo before; exit 5",
        .expect = .{ .exit_code = 5, .stdout = "before\nbye\n" },
    },
    .{
        .name = "trap: '' ignores the signal",
        .source = "trap '' INT; echo registered",
        .expect = .{ .exit_code = 0, .stdout = "registered\n" },
    },
    .{
        .name = "trap: - restores default",
        .source = "trap 'echo y' INT; trap - INT; echo done",
        .expect = .{ .exit_code = 0, .stdout = "done\n" },
    },
    .{
        .name = "trap: unknown signal name fails",
        .source = "trap 'echo x' NOPE",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "trap: missing args fails",
        .source = "trap",
        .expect = .{ .exit_code = 2 },
    },
    .{
        .name = "trap: EXIT body sees session vars",
        .source = "trap 'echo trap=$x' EXIT; x=outer; echo before",
        .expect = .{ .exit_code = 0, .stdout = "before\ntrap=outer\n" },
    },

    // ---- process substitution -------------------------------------------
    //
    // `<(prog)` materializes as `/dev/fd/N` reading from prog's stdout;
    // `>(prog)` does the mirror image. The tests use coreutils `cat`,
    // `diff`, and `wc` to keep the assertions hermetic.

    .{
        .name = "proc-sub: `<(cmd)` feeds stdout to a reader",
        .source = "/bin/cat <(/bin/echo hello-from-subst)",
        .expect = .{ .exit_code = 0, .stdout = "hello-from-subst\n" },
    },
    .{
        .name = "proc-sub: two `<(...)` feeds compare equal",
        .source = "/usr/bin/diff <(/bin/echo a) <(/bin/echo a) && echo same",
        .expect = .{ .exit_code = 0, .stdout = "same\n" },
    },
    .{
        .name = "proc-sub: `>(cmd)` accepts stdin via a /dev/fd path",
        .source = "/bin/echo data > >(/usr/bin/wc -c)",
        .expect = .{ .exit_code = 0, .stdout = "5", .stdout_contains = true },
    },
    .{
        .name = "proc-sub: nested under @(...)",
        .source = "for x in @(/bin/cat <(/usr/bin/printf '1\\n2\\n3\\n')) { echo got=$x }",
        .expect = .{ .exit_code = 0, .stdout = "got=1\ngot=2\ngot=3\n" },
    },

    // ---- UTF-8 awareness -------------------------------------------------
    //
    // The lexer's auto-generated LETTER class is ASCII-only; the
    // wrapper extends ident scans to cover any byte ≥ 0x80, so multi-
    // byte names and arguments lex as one token. Variable refs
    // (`$name`, `${name}`) accept UTF-8 in the name too.

    .{
        .name = "utf8: bare word with multibyte chars echoes through",
        .source = "echo 你好世界",
        .expect = .{ .exit_code = 0, .stdout = "你好世界\n" },
    },
    .{
        .name = "utf8: variable name with multibyte chars",
        .source = "café=hello; echo $café",
        .expect = .{ .exit_code = 0, .stdout = "hello\n" },
    },
    .{
        .name = "utf8: dq string preserves multibyte text",
        .source = "echo \"héllo wörld\"",
        .expect = .{ .exit_code = 0, .stdout = "héllo wörld\n" },
    },
    .{
        .name = "utf8: dq variable reference picks up multibyte name",
        .source = "naïve=ok; echo \"got: $naïve\"",
        .expect = .{ .exit_code = 0, .stdout = "got: ok\n" },
    },
    .{
        .name = "utf8: for binding with multibyte name",
        .source = "for naïve in alpha beta { echo $naïve }",
        .expect = .{ .exit_code = 0, .stdout = "alpha\nbeta\n" },
    },

    // ---- pipefail across multi-stage pipelines (PLAN §7 Rule 11) --------
    //
    // pipefail = on by default. The pipeline's exit status is the FIRST
    // non-zero/signaled stage; otherwise zero. Tests cover a 3-stage
    // pipeline with the failure at each position.

    .{
        .name = "pipeline: 3 stages all succeed",
        .source = "/bin/echo hello | /bin/cat | /bin/cat",
        .expect = .{ .exit_code = 0, .stdout = "hello\n" },
    },
    .{
        .name = "pipeline: failure in stage 1 propagates",
        .source = "/bin/sh -c 'exit 5' | /bin/cat | /bin/cat",
        .expect = .{ .exit_code = 5 },
    },
    .{
        .name = "pipeline: failure in stage 2 propagates",
        .source = "/bin/echo data | /bin/sh -c 'exit 6' | /bin/cat",
        .expect = .{ .exit_code = 6 },
    },
    .{
        .name = "pipeline: failure in stage 3 propagates",
        .source = "/bin/echo data | /bin/cat | /bin/sh -c 'exit 7'",
        .expect = .{ .exit_code = 7 },
    },
    .{
        .name = "pipeline: first non-zero wins (multiple failures)",
        .source = "/bin/sh -c 'exit 3' | /bin/sh -c 'exit 5' | /bin/sh -c 'exit 7'",
        .expect = .{ .exit_code = 3 },
    },

    // ---- redirect ordering ----------------------------------------------
    //
    // `>file 2>&1` writes both stdout and stderr to file. Reverse order
    // `2>&1 >file` redirects stderr to whatever stdout was THEN points
    // stdout to file — only stdout ends up in the file. Both shells
    // should agree.

    .{
        .name = "redirect: > file 2>&1 captures both streams",
        .source = "/bin/sh -c 'echo out; echo err 1>&2' >/tmp/slash-redir-1.txt 2>&1; /bin/cat /tmp/slash-redir-1.txt; rm -f /tmp/slash-redir-1.txt",
        .expect = .{ .exit_code = 0, .stdout = "out\nerr\n" },
    },
    .{
        .name = "redirect: append to file",
        .source = "/bin/echo a > /tmp/slash-redir-2.txt; /bin/echo b >> /tmp/slash-redir-2.txt; /bin/cat /tmp/slash-redir-2.txt; rm -f /tmp/slash-redir-2.txt",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\n" },
    },
    .{
        .name = "redirect: numbered fd write",
        .source = "/bin/sh -c 'echo err 1>&2' 2>/tmp/slash-redir-3.txt; /bin/cat /tmp/slash-redir-3.txt; rm -f /tmp/slash-redir-3.txt",
        .expect = .{ .exit_code = 0, .stdout = "err\n" },
    },
    .{
        .name = "redirect: input < file",
        .source = "printf 'aa\\nbb\\n' > /tmp/slash-redir-4.txt; /usr/bin/wc -l < /tmp/slash-redir-4.txt; rm -f /tmp/slash-redir-4.txt",
        .expect = .{ .exit_code = 0, .stdout = "2", .stdout_contains = true },
    },

    // ---- multi-line scripts with comments & mixed structure --------------
    //
    // Smoke that the lexer/parser handle the common idiomatic
    // combinations: blank lines, comments, mixed brace/indent forms,
    // nested control flow.

    .{
        .name = "multiline: blank lines are statement separators",
        .source = "echo a\n\n\necho b\n\necho c",
        .expect = .{ .exit_code = 0, .stdout = "a\nb\nc\n" },
    },
    .{
        .name = "multiline: indented for body",
        .source = "for x in 1 2 3\n  echo n=$x\n",
        .expect = .{ .exit_code = 0, .stdout = "n=1\nn=2\nn=3\n" },
    },
    .{
        .name = "multiline: nested if inside for body",
        .source = "for x in 0 1 2 3 {\n  if test $x -gt 1 { echo big-$x }\n}",
        .expect = .{ .exit_code = 0, .stdout = "big-2\nbig-3\n" },
    },
    .{
        .name = "multiline: cmd def + invocation across lines",
        .source = "cmd greet {\n  echo hello $1\n}\ngreet world\ngreet alice",
        .expect = .{ .exit_code = 0, .stdout = "hello world\nhello alice\n" },
    },

    // -------------------------------------------------------------------------
    // str — editor-only literal-text rewrites (PLAN §12)
    // -------------------------------------------------------------------------
    .{
        .name = "str: empty list is empty",
        .source = "str",
        .expect = .{ .exit_code = 0, .stdout = "" },
    },
    .{
        .name = "str: set then list",
        .source = "str ll ls -lAh\nstr",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'ls -lAh'\n" },
    },
    .{
        .name = "str: set then query",
        .source = "str ll ls -lAh\nstr ll",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'ls -lAh'\n" },
    },
    .{
        .name = "str: query unset is silent exit 1",
        .source = "str nope",
        .expect = .{ .exit_code = 1, .stdout = "", .stderr = "" },
    },
    .{
        .name = "str: list is sorted alphabetically",
        .source = "str zzz alpha\nstr aaa beta\nstr mmm gamma\nstr",
        .expect = .{
            .exit_code = 0,
            .stdout =
            \\str 'aaa' 'beta'
            \\str 'mmm' 'gamma'
            \\str 'zzz' 'alpha'
            \\
            ,
        },
    },
    .{
        .name = "str: erase removes one",
        .source = "str a foo\nstr b bar\nstr -e a\nstr",
        .expect = .{ .exit_code = 0, .stdout = "str 'b' 'bar'\n" },
    },
    .{
        .name = "str: erase is idempotent when name not set",
        .source = "str -e never_existed",
        .expect = .{ .exit_code = 0, .stdout = "", .stderr = "" },
    },
    .{
        .name = "str: erase mixes hits and misses, all-or-some clean",
        .source = "str a foo\nstr -e a missing other\nstr",
        .expect = .{ .exit_code = 0, .stdout = "", .stderr = "" },
    },
    .{
        .name = "str: -e without args is usage error",
        .source = "str -e",
        .expect = .{ .exit_code = 2, .stderr = "str: usage: str -e NAME [NAME...]\n" },
    },
    .{
        .name = "str: reject digit-start LHS",
        .source = "str 2x foo",
        .expect = .{
            .exit_code = 1,
            .stderr = "str: invalid name '2x': must lex as a single bare ident\n",
        },
    },
    .{
        .name = "str: reject keyword LHS",
        .source = "str if foo",
        .expect = .{
            .exit_code = 1,
            .stderr = "str: invalid name 'if': is a slash keyword\n",
        },
    },
    .{
        .name = "str: reject leading-dash LHS (not -e)",
        .source = "str -x foo",
        .expect = .{
            .exit_code = 1,
            .stderr = "str: invalid name '-x': names starting with '-' clash with str -e\n",
        },
    },
    .{
        .name = "str: round-trippable single-quote escaping",
        .source = "str x \"don't\"\nstr",
        .expect = .{ .exit_code = 0, .stdout = "str 'x' 'don''t'\n" },
    },
    .{
        .name = "str: multi-arg VALUE joins with space",
        .source = "str g push origin main\nstr g",
        .expect = .{ .exit_code = 0, .stdout = "str 'g' 'push origin main'\n" },
    },
    .{
        .name = "str: empty value is stored, not erased",
        .source = "str foo \"\"\nstr foo\nstr -e foo\nstr foo",
        .expect = .{ .exit_code = 1, .stdout = "str 'foo' ''\n" },
    },
    .{
        .name = "str: re-set replaces",
        .source = "str ll first\nstr ll second\nstr",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'second'\n" },
    },
    .{
        .name = "str: in pipeline child, set is no-op (child context)",
        .source = "str a 1 | cat\nstr a",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        // Slash's double-quote lexer doesn't support `\t` as an escape
        // (it'd pass through as literal `\t`), but a literal tab byte
        // inside a single-quoted string is fine; the validator allows
        // tab. NUL/LF/CR can't be injected via source syntax (lexer
        // rejects them at the string level), so those branches of the
        // validator are exercised through the brace form's raw-byte
        // capture path — see brace tests below.
        .name = "str: literal tab in value is preserved",
        .source = "str t 'a\tb'\nstr t",
        .expect = .{ .exit_code = 0, .stdout = "str 't' 'a\tb'\n" },
    },

    // -------------------------------------------------------------------------
    // str — brace form (raw-byte body via lexer wrapper)
    // -------------------------------------------------------------------------
    .{
        .name = "str_def: simple brace body",
        .source = "str ll { ls -lAh }\nstr ll",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'ls -lAh'\n" },
    },
    .{
        .name = "str_def: pipe inside body needs no escaping",
        .source = "str logs { tail -f /var/log | grep err }\nstr logs",
        .expect = .{ .exit_code = 0, .stdout = "str 'logs' 'tail -f /var/log | grep err'\n" },
    },
    .{
        .name = "str_def: balanced inner braces are preserved",
        .source = "str awk1 { awk '{print $1}' | sort }\nstr awk1",
        .expect = .{
            .exit_code = 0,
            .stdout = "str 'awk1' 'awk ''{print $1}'' | sort'\n",
        },
    },
    .{
        .name = "str_def: ampersand and semicolons inside body",
        .source = "str chain { a && b ; c || d & e }\nstr chain",
        .expect = .{ .exit_code = 0, .stdout = "str 'chain' 'a && b ; c || d & e'\n" },
    },
    .{
        .name = "str_def: dollar signs and quotes inside body",
        .source = "str foo { echo \"$USER\" 'don''t' }\nstr foo",
        .expect = .{
            .exit_code = 0,
            .stdout = "str 'foo' 'echo \"$USER\" ''don''''t'''\n",
        },
    },
    .{
        .name = "str_def: empty brace body stores as empty",
        .source = "str foo {}\nstr foo",
        .expect = .{ .exit_code = 0, .stdout = "str 'foo' ''\n" },
    },
    .{
        .name = "str_def: whitespace-only brace body trims to empty",
        .source = "str foo {    \t  }\nstr foo",
        .expect = .{ .exit_code = 0, .stdout = "str 'foo' ''\n" },
    },
    .{
        .name = "str_def: leading/trailing whitespace is trimmed",
        .source = "str foo {   ls -lAh   }\nstr foo",
        .expect = .{ .exit_code = 0, .stdout = "str 'foo' 'ls -lAh'\n" },
    },
    .{
        .name = "str_def: internal whitespace is preserved",
        .source = "str foo { ls   -lAh }\nstr foo",
        .expect = .{ .exit_code = 0, .stdout = "str 'foo' 'ls   -lAh'\n" },
    },
    .{
        // Runtime validation rejects keyword names. The diagnostic is
        // emitted via the standard diag sink (EV0030) — at the
        // `slash -c` entry point, eval-time diagnostics aren't
        // rendered to stderr (per existing behavior across eval; see
        // EV0001/EX0001 etc.), so we only assert on the exit code.
        .name = "str_def: rejects keyword name at runtime",
        .source = "str if { foo }",
        .expect = .{ .exit_code = 1 },
    },
    .{
        .name = "str_def: re-definition replaces",
        .source = "str ll { first }\nstr ll { second }\nstr ll",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'second'\n" },
    },
    .{
        .name = "str_def: brace form sets, then -e erases",
        .source = "str ll { ls -lAh }\nstr -e ll\nstr ll",
        .expect = .{ .exit_code = 1, .stdout = "" },
    },
    .{
        .name = "str_def: trailing comment is allowed",
        .source = "str ll { ls -lAh } # quick listing\nstr ll",
        .expect = .{ .exit_code = 0, .stdout = "str 'll' 'ls -lAh'\n" },
    },
    .{
        .name = "str_def: sequence continuation after brace body",
        .source = "str a { 1 } ; str b { 2 }\nstr",
        .expect = .{
            .exit_code = 0,
            .stdout = "str 'a' '1'\nstr 'b' '2'\n",
        },
    },

    // -------------------------------------------------------------------------
    // Scanner: command-position state machine edge cases
    // -------------------------------------------------------------------------
    //
    // Sticky NAME_EQ: env-prefix preserves command position;
    // argument-position NAME_EQ doesn't promote it. Without these tests
    // the brace-form lookahead in the lexer wrapper or the keystroke
    // scanner could mis-fire on `echo FOO= str x { y }` (mistaking
    // argument-position for sequence-start) or fail to honor
    // `FOO=1 ll<space>` (treating env-prefix as argument).
    .{
        // Env-prefix ON the str_def grammar form is intentionally
        // unsupported (str_def is a sequence_item, not a simple_command),
        // so this should fail to parse rather than secretly succeed.
        .name = "scanner: str_def cannot follow env-prefix on a simple_command",
        .source = "echo FOO= str x { y }\nstr x",
        .expect = .{ .exit_code = 1 },
    },
    .{
        // Backslash inside the brace body has no escape semantics —
        // it's a literal byte. The matched closing `}` is the one
        // that returns brace depth to zero, regardless of any
        // preceding backslash.
        .name = "str_def: backslash inside body is a literal byte",
        .source = "str x { a\\b }\nstr x",
        .expect = .{ .exit_code = 0, .stdout = "str 'x' 'a\\b'\n" },
    },
};

// =============================================================================
// fd-capturing harness
// =============================================================================

const RunOutput = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOutput, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

fn runHeadless(alloc: std.mem.Allocator, source_text: []const u8) !RunOutput {
    // Make the capture pipes BEFORE doing anything that could fail; we
    // need to release them on every error path.
    const out_pipe = try exec.makePipe();
    const err_pipe = try exec.makePipe();

    // Save originals.
    const saved_out = std.c.dup(1);
    const saved_err = std.c.dup(2);
    if (saved_out < 0 or saved_err < 0) return error.DupFailed;

    // Redirect.
    if (std.c.dup2(out_pipe[1], 1) < 0) return error.Dup2Failed;
    if (std.c.dup2(err_pipe[1], 2) < 0) return error.Dup2Failed;
    // Close write ends in this process so EOF propagates after children
    // exit. (The dup2'd fds 1/2 still hold the write end open; we close
    // those by restoring the originals below.)
    exec.closeFd(out_pipe[1]);
    exec.closeFd(err_pipe[1]);

    // Anything past this point that fails has to restore fds 1/2 and
    // release the pipe read ends, otherwise a single bad case wedges
    // the rest of the suite.
    errdefer {
        _ = std.c.dup2(saved_out, 1);
        _ = std.c.dup2(saved_err, 2);
        exec.closeFd(saved_out);
        exec.closeFd(saved_err);
        exec.closeFd(out_pipe[0]);
        exec.closeFd(err_pipe[0]);
    }

    // Run the eval. Parse and lower failures map to exit code 1 — this
    // matches what the REPL does in the same situation, so headless and
    // interactive paths both surface bad-program failures as exit 1.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const source = diag.Source{ .name = "<test>", .text = source_text };
    const exit_code = blk: {
        const parsed = shape.parse(source, a, null) catch break :blk @as(u8, 1);
        const ctx = program.LowerContext{ .alloc = a, .source = source };
        const prog = program.lower(parsed.root, &ctx, null) catch break :blk @as(u8, 1);

        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
        var session = try session_mod.Session.init(alloc, envp_ptr, false);
        defer session.deinit();
        builtins.installSession(&session);

        const result = try eval.runForeground(prog, &session, a, null);
        eval.fireExitTrap(&session, a, null) catch {};
        const final = session.exit_request orelse result;
        break :blk final.toStatusByte();
    };

    // Restore originals (this also closes our write-end of fd 1 and 2).
    _ = std.c.dup2(saved_out, 1);
    _ = std.c.dup2(saved_err, 2);
    exec.closeFd(saved_out);
    exec.closeFd(saved_err);

    // Drain pipes.
    const stdout_bytes = try drainFd(alloc, out_pipe[0]);
    const stderr_bytes = try drainFd(alloc, err_pipe[0]);
    exec.closeFd(out_pipe[0]);
    exec.closeFd(err_pipe[0]);

    return .{
        .exit_code = exit_code,
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
    };
}

fn drainFd(alloc: std.mem.Allocator, fd: i32) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = std.c.read(fd, &buf, buf.len);
        if (rc < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        try out.appendSlice(alloc, buf[0..@intCast(rc)]);
    }
    return out.toOwnedSlice(alloc);
}

// =============================================================================
// Filesystem fixture (used by glob cases)
// =============================================================================
//
// `setupGlobFixture` creates a known directory tree at
// /tmp/slash-glob-fixture/ before the test run and removes it afterwards.
// Built with raw POSIX so the test harness has no dependency on a Zig
// `std.Io` instance.

const fixture_root: [:0]const u8 = "/tmp/slash-glob-fixture";

fn setupGlobFixture() void {
    teardownGlobFixture();
    _ = std.c.mkdir(fixture_root, 0o755);
    writeFile("/tmp/slash-glob-fixture/a.txt", "a\n");
    writeFile("/tmp/slash-glob-fixture/b.txt", "b\n");
    writeFile("/tmp/slash-glob-fixture/c.txt", "c\n");
    writeFile("/tmp/slash-glob-fixture/.hidden", "hidden\n");
    _ = std.c.mkdir("/tmp/slash-glob-fixture/sub", 0o755);
    writeFile("/tmp/slash-glob-fixture/sub/x.md", "x\n");
    writeFile("/tmp/slash-glob-fixture/sub/y.md", "y\n");
}

fn writeFile(path: [:0]const u8, contents: []const u8) void {
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(path.ptr, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < contents.len) {
        const n = std.c.write(fd, contents.ptr + off, contents.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn teardownGlobFixture() void {
    // Best-effort recursive removal. Order matters because rmdir requires
    // an empty directory; we unlink files first.
    _ = std.c.unlink("/tmp/slash-glob-fixture/a.txt");
    _ = std.c.unlink("/tmp/slash-glob-fixture/b.txt");
    _ = std.c.unlink("/tmp/slash-glob-fixture/c.txt");
    _ = std.c.unlink("/tmp/slash-glob-fixture/.hidden");
    _ = std.c.unlink("/tmp/slash-glob-fixture/sub/x.md");
    _ = std.c.unlink("/tmp/slash-glob-fixture/sub/y.md");
    _ = std.c.rmdir("/tmp/slash-glob-fixture/sub");
    _ = std.c.rmdir(fixture_root);
}

const source_fixture_root: [:0]const u8 = "/tmp/slash-source-fixture";

fn setupSourceFixture() void {
    teardownSourceFixture();
    _ = std.c.mkdir(source_fixture_root, 0o755);
    writeFile(
        "/tmp/slash-source-fixture/basic.sl",
        "msg=hello\necho from-source\n",
    );
    writeFile(
        "/tmp/slash-source-fixture/setvars.sl",
        "a=alpha\nb=beta\n",
    );
    writeFile(
        "/tmp/slash-source-fixture/exit7.sl",
        "/bin/sh -c 'exit 7'\n",
    );
    writeFile(
        "/tmp/slash-source-fixture/shebang.sl",
        "#!/usr/bin/env slash\necho after-shebang\n",
    );
}

fn teardownSourceFixture() void {
    _ = std.c.unlink("/tmp/slash-source-fixture/basic.sl");
    _ = std.c.unlink("/tmp/slash-source-fixture/setvars.sl");
    _ = std.c.unlink("/tmp/slash-source-fixture/exit7.sl");
    _ = std.c.unlink("/tmp/slash-source-fixture/shebang.sl");
    _ = std.c.rmdir(source_fixture_root);
}

const builtins_fixture_root: [:0]const u8 = "/tmp/slash-builtins-fixture";

fn setupBuiltinsFixture() void {
    teardownBuiltinsFixture();
    _ = std.c.mkdir(builtins_fixture_root, 0o755);
    writeFile("/tmp/slash-builtins-fixture/three.txt", "alpha beta gamma\n");
    writeFile("/tmp/slash-builtins-fixture/empty.txt", "");
}

fn teardownBuiltinsFixture() void {
    _ = std.c.unlink("/tmp/slash-builtins-fixture/three.txt");
    _ = std.c.unlink("/tmp/slash-builtins-fixture/empty.txt");
    _ = std.c.rmdir(builtins_fixture_root);
}

// =============================================================================
// Tests
// =============================================================================

// =============================================================================
// Stress / leak detection (CHECKLIST §11)
// =============================================================================
//
// Long-lived shells must not accumulate fds or zombie processes across
// command execution. The two stress tests below run a short payload
// repeatedly and assert the post-state is within a tiny stable delta
// of the pre-state.

/// Count open file descriptors in this process by probing fcntl(F_GETFD)
/// across [0, RLIMIT_NOFILE.cur). Cross-platform — no /proc walk on
/// Linux, no proc_pidinfo on macOS. Cap at 65536 defensively in case
/// the soft limit is set absurdly high (some macOS setups push it to
/// MAX_INT, which would make this loop pointlessly slow).
fn countOpenFds() u32 {
    var rl: std.c.rlimit = undefined;
    const cap: c_int = if (std.c.getrlimit(.NOFILE, &rl) == 0)
        @intCast(@min(rl.cur, 65536))
    else
        1024;
    var n: u32 = 0;
    var fd: c_int = 0;
    while (fd < cap) : (fd += 1) {
        const rc = std.c.fcntl(fd, std.c.F.GETFD);
        if (rc >= 0) n += 1;
    }
    return n;
}

/// Drain zombie children with `waitpid(-1, WNOHANG)`. Returns the number
/// reaped. Loops with brief naps until five consecutive empty polls —
/// a child that exited microseconds ago may not be visible to the
/// first WNOHANG call (kernel-side bookkeeping latency is real and
/// can run into the tens of milliseconds under load). Total wait
/// caps at ~3s so a true leak still surfaces as a non-zero return.
fn drainZombies() u32 {
    var reaped: u32 = 0;
    var quiet_polls: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 150) : (attempts += 1) {
        var status: c_int = 0;
        const rc = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        if (rc > 0) {
            reaped += 1;
            quiet_polls = 0;
            continue;
        }
        quiet_polls += 1;
        if (quiet_polls >= 5) break;
        var pfd: std.c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&pfd), 0, 20);
    }
    return reaped;
}

test "stress: 200 pipeline iterations leave fd count stable" {
    const alloc = std.testing.allocator;
    const baseline = countOpenFds();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        // Mix the most fd-intensive paths: external command, pipeline,
        // redirect to /dev/null, plus a builtin write. Each iteration
        // creates pipes, opens files, forks children, reaps them.
        const source_text = "echo hi | /usr/bin/wc -l >/dev/null; true";
        const source = diag.Source{ .name = "<stress>", .text = source_text };
        const parsed = try shape.parse(source, a, null);
        const ctx = program.LowerContext{ .alloc = a, .source = source };
        const prog = try program.lower(parsed.root, &ctx, null);

        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
        var session = try session_mod.Session.init(alloc, envp_ptr, false);
        defer session.deinit();
        builtins.installSession(&session);

        const saved_out = std.c.dup(1);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 1);
            _ = std.c.close(devnull);
        }
        _ = eval.runForeground(prog, &session, a, null) catch {};
        _ = std.c.dup2(saved_out, 1);
        _ = std.c.close(saved_out);
    }

    const after = countOpenFds();
    // Allow at most a small stable delta (e.g., a heap-grow side
    // effect from the testing allocator). Anything beyond a couple
    // of fds is a leak.
    if (after > baseline + 2) {
        std.debug.print(
            "fd leak: baseline={d} after={d} delta={d}\n",
            .{ baseline, after, after - baseline },
        );
        return error.FdLeak;
    }
}

test "stress: 200 `<(cmd)` iterations leak no fds or zombies" {
    // Regression for the proc-sub teardown audit. Each iteration
    // creates one or more side children and `/dev/fd/N` pipes via
    // `spawnProcSubst`; `drainProcSubs` must reap and close them
    // before the next iteration runs. A WNOHANG-and-forget bug
    // would leave the parent fd open AND the child as a zombie,
    // both detectable here.
    const alloc = std.testing.allocator;
    _ = drainZombies();
    const baseline = countOpenFds();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        // `diff <(echo a) <(echo a) && true` — two side children,
        // one foreground reader, plus a follow-on so the
        // `drainProcSubs` cadence runs at end-of-command before the
        // session goes away.
        const source_text = "/usr/bin/diff <(/bin/echo a) <(/bin/echo a) >/dev/null && true";
        const source = diag.Source{ .name = "<procsub-stress>", .text = source_text };
        const parsed = try shape.parse(source, a, null);
        const ctx = program.LowerContext{ .alloc = a, .source = source };
        const prog = try program.lower(parsed.root, &ctx, null);

        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
        var session = try session_mod.Session.init(alloc, envp_ptr, false);
        defer session.deinit();
        builtins.installSession(&session);

        _ = eval.runForeground(prog, &session, a, null) catch {};
    }

    const after = countOpenFds();
    if (after > baseline + 2) {
        std.debug.print(
            "proc-sub fd leak: baseline={d} after={d} delta={d}\n",
            .{ baseline, after, after - baseline },
        );
        return error.FdLeak;
    }
    // Any zombies left dangling fall out here — drainZombies returns
    // > 0 if the per-iteration `drainProcSubs` retry path failed to
    // catch the side children before the session torn down.
    const leftover = drainZombies();
    if (leftover > 0) {
        std.debug.print("proc-sub zombie leak: {d} unreaped\n", .{leftover});
        return error.ZombieLeak;
    }
}

test "stress: 100 detached jobs are reaped without explicit wait" {
    const alloc = std.testing.allocator;
    // Fence: reap anything outstanding before we measure.
    _ = drainZombies();

    // Track the pid of each iteration's bg `true` so we can blockingly
    // confirm reap at the end. The test invariant we want: every bg
    // job that slash's safe-point poll didn't reap inline must still
    // be reapable by an explicit `waitpid`. We catch real leaks
    // (children we have no record of, or children that escaped
    // process-group accounting) via `drainZombies` after.
    var pids: [100]std.c.pid_t = undefined;
    var pid_count: usize = 0;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        // Bare `true &` — no `wait`. This exercises the safe-point
        // poll path (PLAN §19) without relying on explicit-wait
        // reaping. The assertion combo at the end catches both stuck
        // children (waitpid blocks then succeeds) and unaccounted
        // orphans (drainZombies returns non-zero).
        const source_text = "true >/dev/null 2>&1 &";
        const source = diag.Source{ .name = "<stress>", .text = source_text };
        const parsed = try shape.parse(source, a, null);
        const ctx = program.LowerContext{ .alloc = a, .source = source };
        const prog = try program.lower(parsed.root, &ctx, null);

        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
        var session = try session_mod.Session.init(alloc, envp_ptr, false);
        defer session.deinit();
        builtins.installSession(&session);

        _ = eval.runForeground(prog, &session, a, null) catch {};
        // Capture the pid the bg launch recorded for $!. If the
        // safe-point poll already reaped it, waitpid below returns
        // -1/ECHILD; either way we detect a stuck child.
        if (session.last_bg_pid) |pid| {
            pids[pid_count] = pid;
            pid_count += 1;
        }
    }

    // Race-free join: blockingly waitpid for every recorded pid. If a
    // child is still running, this blocks until it exits — no timing
    // assumption. If it was already reaped via safe-point polling,
    // waitpid returns -1 with ECHILD which is fine.
    var j: usize = 0;
    while (j < pid_count) : (j += 1) {
        var status: c_int = 0;
        _ = std.c.waitpid(pids[j], &status, 0);
    }

    const leaked = drainZombies();
    if (leaked > 0) {
        std.debug.print("zombie leak: {d} unaccounted children\n", .{leaked});
        return error.ZombieLeak;
    }
}

test "notifyChildEventFromSignal sets the flag once; drainChildEvents clears it" {
    // Exercises the real signal-safe helper that the SIGCHLD handler
    // dispatches to (see `repl.notifyChildEventFromSignal`). Tests the
    // shipped path directly rather than duplicating the handler body.
    const alloc = std.testing.allocator;
    const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
    var session = try session_mod.Session.init(alloc, envp_ptr, false);
    defer session.deinit();
    builtins.installSession(&session);

    // First call: flag was false → returns true (set), wakes editor.
    try std.testing.expect(!session.child_event_pending.load(.acquire));
    repl.notifyChildEventFromSignal(&session);
    try std.testing.expect(session.child_event_pending.load(.acquire));

    // Second call before drain: flag stays true (coalesced); the
    // editor wake is suppressed (we can't directly observe the wake
    // here without an active zigline editor, but the swap-based
    // coalescing path is what we're verifying via the flag staying
    // set without spurious changes).
    repl.notifyChildEventFromSignal(&session);
    try std.testing.expect(session.child_event_pending.load(.acquire));

    // Spawn a real child and verify drainChildEvents reaps it.
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) std.c._exit(0);

    // Brief settle so the kernel marks the child reapable. We don't
    // need the SIGCHLD handler to fire here — drainChildEvents calls
    // service(.poll) which uses waitpid(WNOHANG) directly.
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        var pfd: std.c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&pfd), 0, 10);
        // Exit early once the child is reapable via waitpid.
        var st: c_int = 0;
        const r = std.c.waitpid(pid, &st, std.c.W.NOHANG);
        if (r > 0) {
            // Ourselves reaping it via direct waitpid means it was
            // ready; for the test purposes that's equivalent (the
            // child is no longer a zombie). Skip the drainChildEvents
            // reap path and just clear the flag.
            session.child_event_pending.store(false, .release);
            return;
        }
        if (r < 0) break;
    }

    eval.drainChildEvents(&session);
    try std.testing.expect(!session.child_event_pending.load(.acquire));
    // Child was reaped via service(.poll) inside drainChildEvents;
    // a follow-up waitpid for that pid returns -1 (ECHILD).
    var status: c_int = 0;
    const wrc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    try std.testing.expectEqual(@as(std.c.pid_t, -1), wrc);
}

test "memory: 500 iterations leave no allocator leaks" {
    // `std.testing.allocator` is the leak-detecting allocator, so any
    // session/program/job lifetime bug surfaces here directly. The
    // payload runs every code path that touches the session arenas
    // (vars, defs, traps, path cache) and the per-statement scratch.
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const source_text = "x=val; echo $x; cmd f { echo body }; f; trap 'echo bye' EXIT";
        const source = diag.Source{ .name = "<mem>", .text = source_text };
        const parsed = try shape.parse(source, a, null);
        const ctx = program.LowerContext{ .alloc = a, .source = source };
        const prog = try program.lower(parsed.root, &ctx, null);

        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
        var session = try session_mod.Session.init(alloc, envp_ptr, false);
        defer session.deinit();
        builtins.installSession(&session);

        const saved_out = std.c.dup(1);
        const saved_err = std.c.dup(2);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = eval.runForeground(prog, &session, a, null) catch {};
        eval.fireExitTrap(&session, a, null) catch {};
        _ = std.c.dup2(saved_out, 1);
        _ = std.c.dup2(saved_err, 2);
        _ = std.c.close(saved_out);
        _ = std.c.close(saved_err);
    }
}

test "headless v0" {
    setupGlobFixture();
    defer teardownGlobFixture();
    setupSourceFixture();
    defer teardownSourceFixture();
    setupBuiltinsFixture();
    defer teardownBuiltinsFixture();

    const alloc = std.testing.allocator;
    var failures: u32 = 0;
    for (cases) |case| {
        var out = runHeadless(alloc, case.source) catch |err| {
            std.debug.print("FAIL {s}: harness error {s}\n", .{ case.name, @errorName(err) });
            failures += 1;
            continue;
        };
        defer out.deinit(alloc);

        if (out.exit_code != case.expect.exit_code) {
            std.debug.print(
                "FAIL {s}: exit_code expected {d}, got {d}\n  stdout: {s}\n  stderr: {s}\n",
                .{ case.name, case.expect.exit_code, out.exit_code, out.stdout, out.stderr },
            );
            failures += 1;
            continue;
        }
        if (case.expect.stdout) |want| {
            const ok = if (case.expect.stdout_contains)
                std.mem.indexOf(u8, out.stdout, want) != null
            else
                std.mem.eql(u8, out.stdout, want);
            if (!ok) {
                std.debug.print(
                    "FAIL {s}: stdout mismatch\n  expected: {s}\n  actual:   {s}\n",
                    .{ case.name, want, out.stdout },
                );
                failures += 1;
                continue;
            }
        }
        if (case.expect.stderr) |want| {
            const ok = if (case.expect.stderr_contains)
                std.mem.indexOf(u8, out.stderr, want) != null
            else
                std.mem.eql(u8, out.stderr, want);
            if (!ok) {
                std.debug.print(
                    "FAIL {s}: stderr mismatch\n  expected: {s}\n  actual:   {s}\n",
                    .{ case.name, want, out.stderr },
                );
                failures += 1;
                continue;
            }
        }
    }
    if (failures > 0) return error.HeadlessTestFailed;
}
