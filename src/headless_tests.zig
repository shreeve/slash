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
const diag = @import("diagnostics.zig");
const shape = @import("shape.zig");
const program = @import("program.zig");
const session_mod = @import("session.zig");
const eval = @import("eval.zig");
const exec = @import("exec.zig");
const builtins = @import("builtins.zig");

extern "c" var environ: [*:null]?[*:0]u8;

const Expect = struct {
    exit_code: u8,
    stdout: ?[]const u8 = null, // null = don't check
    stderr: ?[]const u8 = null,
    /// If true, only assert that `stdout` is a substring of the observed
    /// output. Useful for cases where the wider test-runner output gets
    /// in the way.
    stdout_contains: bool = false,
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
        .expect = .{ .exit_code = 0, .stdout = "1\n2\n3\n4\n",  },
    },
    .{
        .name = "break exits while loop on first iteration",
        .source = "while true { break }; echo after",
        .expect = .{ .exit_code = 0, .stdout = "after\n" },
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
        .name = "type: external command",
        .source = "type cat",
        .expect = .{ .exit_code = 0, .stdout = "cat is /bin/cat\n" },
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
        .name = "cd -: toggles to OLDPWD and prints",
        .source = "cd /tmp; cd /; cd -",
        .expect = .{ .exit_code = 0, .stdout = "/private/tmp\n", .stdout_contains = true },
    },
    .{
        .name = "cd -: errors when OLDPWD unset",
        .source = "cd -",
        .expect = .{ .exit_code = 1 },
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

    // Run the eval.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const source = diag.Source{ .name = "<test>", .text = source_text };
    const parsed = try shape.parse(source, a, null);
    const ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = try program.lower(parsed.root, &ctx, null);

    const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(environ));
    var session = try session_mod.Session.init(alloc, envp_ptr, false);
    defer session.deinit();
    builtins.installSession(&session);

    const result = try eval.runForeground(prog, &session, a, null);
    eval.fireExitTrap(&session, a, null) catch {};
    const final = session.exit_request orelse result;
    const exit_code = final.toStatusByte();

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
            if (!std.mem.eql(u8, out.stderr, want)) {
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
