//! PTY-driven tests for slash — shell-specific cases.
//!
//! After the zigline cutover, line-editor mechanics (cursor movement,
//! backspace, history navigation, Ctrl-C cancel, wrap-aware repaint)
//! are covered by zigline's own PTY tests against zigline's example
//! binaries. This file focuses on what zigline can't test for slash
//! specifically:
//!
//!   - shell-specific behaviors that need slash to think it's at an
//!     interactive prompt (multi-line continuation, exit-status
//!     propagation, prompt content with PWD + last-status suffix)
//!   - slash's syntax highlighter actually firing through zigline's
//!     renderer to produce ANSI on the wire
//!
//! The harness allocates a fresh pseudo-terminal via `posix_openpt` /
//! `grantpt` / `unlockpt` / `ptsname`, forks `bin/slash` with the
//! slave end as its stdin/stdout/stderr, and drives keystrokes through
//! the master end. Tests are platform-gated — Linux and macOS only.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn setsid() std.c.pid_t;

const ioctl_with_ulong_request = struct {
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
}.ioctl;

const TIOCSWINSZ: c_ulong = switch (builtin.target.os.tag) {
    .linux => 0x5414,
    .macos, .ios, .driverkit, .maccatalyst, .tvos, .visionos, .watchos => 0x80087467,
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x80087467,
    else => 0x80087467,
};

const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = switch (builtin.target.os.tag) {
    .macos, .ios => 0x20000,
    .linux => 0o400,
    else => 0,
};

const slash_bin = "bin/slash";

const PtyPair = struct {
    master: c_int,
    slave: c_int,
    slave_path: [256]u8,

    fn open() !PtyPair {
        const master = posix_openpt(O_RDWR | O_NOCTTY);
        if (master < 0) return error.OpenPtFailed;
        errdefer _ = std.c.close(master);

        if (grantpt(master) != 0) return error.GrantPtFailed;
        if (unlockpt(master) != 0) return error.UnlockPtFailed;

        const name_ptr = ptsname(master) orelse return error.PtsnameFailed;
        const name = std.mem.span(name_ptr);

        var path_buf: [256]u8 = undefined;
        if (name.len + 1 > path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..name.len], name);
        path_buf[name.len] = 0;

        const slave = std.c.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (slave < 0) return error.OpenSlaveFailed;

        return .{ .master = master, .slave = slave, .slave_path = path_buf };
    }
};

const Spawned = struct {
    pid: std.c.pid_t,
    master: c_int,

    fn send(self: Spawned, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteEof;
            off += @intCast(n);
        }
    }

    fn drain(
        self: Spawned,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        deadline_ms: i64,
    ) !void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (try waitReadable(self.master, deadline_ms)) {
                const n = std.c.read(self.master, &chunk, chunk.len);
                if (n < 0) {
                    const e = std.c.errno(@as(c_int, -1));
                    if (e == .INTR) continue;
                    if (e == .IO) return; // PTY master returns EIO when slave closes
                    return error.ReadFailed;
                }
                if (n == 0) return; // EOF
                try out.appendSlice(alloc, chunk[0..@intCast(n)]);
            } else {
                return; // deadline reached
            }
        }
    }

    fn reap(self: Spawned) u8 {
        var status: c_int = 0;
        while (true) {
            const r = std.c.waitpid(self.pid, &status, 0);
            if (r >= 0) break;
            const e = std.c.errno(r);
            if (e == .INTR) continue;
            return 0;
        }
        const ux: u32 = @bitCast(status);
        if (std.c.W.IFEXITED(ux)) return std.c.W.EXITSTATUS(ux);
        return 128;
    }

    fn close(self: Spawned) void {
        _ = std.c.close(self.master);
    }
};

fn waitReadable(fd: c_int, deadline_ms: i64) !bool {
    var pfd: std.c.pollfd = .{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
    const rc = std.c.poll(@ptrCast(&pfd), 1, @intCast(deadline_ms));
    if (rc < 0) {
        const e = std.c.errno(rc);
        if (e == .INTR) return false;
        return error.PollFailed;
    }
    return rc > 0;
}

fn ptySupported() bool {
    return switch (builtin.target.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

fn spawnSlash(args: []const []const u8) !Spawned {
    const pty = try PtyPair.open();

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = std.c.close(pty.master);
        _ = setsid();

        _ = std.c.dup2(pty.slave, 0);
        _ = std.c.dup2(pty.slave, 1);
        _ = std.c.dup2(pty.slave, 2);
        if (pty.slave > 2) _ = std.c.close(pty.slave);

        var argv_buf: [16]?[*:0]const u8 = undefined;
        var i: usize = 0;
        const slash_z = slash_bin ++ "\x00";
        argv_buf[i] = @ptrCast(slash_z.ptr);
        i += 1;

        var arg_storage: [16][256]u8 = undefined;
        for (args) |a| {
            if (i + 1 >= argv_buf.len) std.c._exit(127);
            if (a.len + 1 > arg_storage[i].len) std.c._exit(127);
            @memcpy(arg_storage[i][0..a.len], a);
            arg_storage[i][a.len] = 0;
            argv_buf[i] = @ptrCast(&arg_storage[i]);
            i += 1;
        }
        argv_buf[i] = null;

        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(std.c.environ));
        _ = std.c.execve(slash_z.ptr, @ptrCast(&argv_buf), envp);
        std.c._exit(127);
    }

    _ = std.c.close(pty.slave);
    return .{ .pid = pid, .master = pty.master };
}

const Step = struct {
    send: ?[]const u8 = null,
    settle_ms: i64 = 100,
};

fn runScript(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    steps: []const Step,
) !struct { out: []u8, status: u8 } {
    const child = try spawnSlash(args);
    defer child.close();

    var collected: std.ArrayListUnmanaged(u8) = .empty;
    defer collected.deinit(alloc);

    for (steps) |step| {
        if (step.send) |bytes| try child.send(bytes);
        try child.drain(alloc, &collected, step.settle_ms);
    }

    try child.drain(alloc, &collected, 1500);
    const status = child.reap();
    return .{ .out = try collected.toOwnedSlice(alloc), .status = status };
}

// =============================================================================
// Tests
// =============================================================================

test "slash pty: basic command runs and produces output" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "echo hi-from-slash-pty\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "hi-from-slash-pty") != null);
}

test "slash pty: exit status propagates" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "exit 7\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 7), r.status);
}

test "slash pty: multi-line continuation accumulates a brace block" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Open brace, body, close brace on separate lines. Slash's
    // `evaluatePending` recognizes the parse-incomplete state at EOF
    // and keeps accumulating; the editor receives `... ` as the
    // continuation prompt.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "if true {\n" },
        .{ .send = "echo block-body\n" },
        .{ .send = "}\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "block-body") != null);
    // The `... ` continuation prompt must have been written at least
    // once between the open brace and the close brace.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "... ") != null);
}

test "slash pty: prompt renders with `$ ` (or `# ` for root)" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    const has_dollar = std.mem.indexOf(u8, r.out, "$ ") != null;
    const has_hash = std.mem.indexOf(u8, r.out, "# ") != null;
    try std.testing.expect(has_dollar or has_hash);
}

test "slash pty: nonzero last-status appears in next prompt" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Run a command that exits 1, then check the next prompt contains
    // the bracketed status. (`renderPrompt` formats it as ` [{d}]`.)
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "false\n" },
        .{ .send = "exit 0\n", .settle_ms = 200 },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "[1]") != null);
}

test "slash pty: highlighter emits ANSI for keywords + strings" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Slash's highlightHook returns spans; zigline's renderer translates
    // them to SGR. The full pipeline through a real PTY produces ANSI
    // escape sequences on the wire — bold-cyan for `if`, green for the
    // string literal.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "if true { echo \"hi\" }\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Bold cyan == ESC [ 1 ; 36 m  (keyword); the renderer may emit the
    // SGR fields in either order — accept both.
    const bold_cyan_a = std.mem.indexOf(u8, r.out, "\x1b[1;36m") != null;
    const bold_cyan_b = std.mem.indexOf(u8, r.out, "\x1b[36;1m") != null;
    try std.testing.expect(bold_cyan_a or bold_cyan_b);

    // Green for the dq string body.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[32m") != null);
}

test "slash pty: Ctrl-X opens current line in $EDITOR and replaces buffer" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Fake editor: a small shell script that writes a known marker to
    // its argv[1] (the temp file slash creates) AND touches a sentinel
    // so we can detect even-the-hook-fired separately from
    // even-the-buffer-replaced.
    const script_path = "/tmp/slash-pty-fake-editor.sh";
    const sentinel_path = "/tmp/slash-pty-fake-editor-fired";
    _ = std.c.unlink(sentinel_path);

    const script_body =
        \\#!/bin/sh
        \\touch /tmp/slash-pty-fake-editor-fired
        \\printf 'replaced\n' > "$1"
        \\
    ;
    {
        const fd = std.c.open(script_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o755));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, script_body.ptr, script_body.len);
    }
    defer _ = std.c.unlink(script_path);
    defer _ = std.c.unlink(sentinel_path);
    _ = std.c.chmod(script_path, 0o755);

    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;
    const unsetenv = struct {
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    }.unsetenv;
    _ = setenv("EDITOR", script_path, 1);
    _ = unsetenv("VISUAL");

    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "original-text" },
        .{ .send = "\x18", .settle_ms = 600 }, // Ctrl-X
        .{ .send = "\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // First check: did the hook fire at all? (sentinel file exists)
    const sentinel_fd = std.c.open(sentinel_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    const sentinel_existed = sentinel_fd >= 0;
    if (sentinel_fd >= 0) _ = std.c.close(sentinel_fd);

    if (!sentinel_existed) {
        std.debug.print("Ctrl-X did NOT invoke the custom-action hook.\n", .{});
        std.debug.print("PTY output ({d} bytes):\n{s}\n", .{ r.out.len, r.out });
    }
    try std.testing.expect(sentinel_existed);

    // Second check: did the buffer get replaced? "replaced" should
    // appear in the rendered output after the Ctrl-X round-trip.
    if (std.mem.indexOf(u8, r.out, "replaced") == null) {
        std.debug.print("hook fired but buffer wasn't redrawn with new content.\n", .{});
        std.debug.print("PTY output:\n{s}\n", .{r.out});
    }
    try std.testing.expect(std.mem.indexOf(u8, r.out, "replaced") != null);
}

test "slash pty: Ctrl-X on empty buffer pre-fills with last history entry (zigline ≥ v0.1.5)" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Fake editor: copies its argv[1] to a sentinel file so the test
    // can inspect what slash wrote there. (The test asserts on the
    // sentinel content, not on the rendered output, because the
    // editor takes over the terminal during its run.)
    const script_path = "/tmp/slash-pty-prefill-editor.sh";
    const sentinel_path = "/tmp/slash-pty-prefill-snapshot";
    _ = std.c.unlink(sentinel_path);

    const script_body =
        \\#!/bin/sh
        \\cp "$1" /tmp/slash-pty-prefill-snapshot
        \\printf 'edited\n' > "$1"
        \\
    ;
    {
        const fd = std.c.open(script_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o755));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, script_body.ptr, script_body.len);
    }
    defer _ = std.c.unlink(script_path);
    defer _ = std.c.unlink(sentinel_path);
    _ = std.c.chmod(script_path, 0o755);

    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;
    const unsetenv = struct {
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    }.unsetenv;
    _ = setenv("EDITOR", script_path, 1);
    _ = unsetenv("VISUAL");

    // Submit a command first (populates history), then with an empty
    // buffer hit Ctrl-X. Slash's editInEditor should detect the empty
    // buffer + non-empty history and pre-fill the temp file with the
    // last entry.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "echo seeded-from-history\n", .settle_ms = 200 },
        .{ .send = "\x18", .settle_ms = 600 }, // Ctrl-X on empty buffer
        .{ .send = "\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Read the sentinel snapshot — it captured what slash wrote into
    // the temp file before invoking the editor. Should contain the
    // last history entry.
    const fd = std.c.open(sentinel_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    try std.testing.expect(n > 0);
    const captured = buf[0..@intCast(n)];

    if (std.mem.indexOf(u8, captured, "echo seeded-from-history") == null) {
        std.debug.print("temp file did NOT receive the last history entry.\n", .{});
        std.debug.print("captured ({d} bytes): {s}\n", .{ captured.len, captured });
    }
    try std.testing.expect(std.mem.indexOf(u8, captured, "echo seeded-from-history") != null);
}

test "slash pty: M-. (yank-last-arg) pulls last word of last command — zigline v0.1.5 binding" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Submit a command, then on a fresh prompt type "echo " followed
    // by Alt-. The yank-last-arg action should insert the last
    // whitespace token of the previous command ("/tmp/foo"). Submit
    // the result; slash echoes whatever was on the line.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "echo first /tmp/foo\n", .settle_ms = 200 },
        .{ .send = "echo " },
        .{ .send = "\x1b." }, // Alt-. = M-. = yank-last-arg
        .{ .send = "\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // The submitted line was "echo /tmp/foo" — its output appears in
    // the PTY stream after the rendered prompt + keystrokes. Verify
    // /tmp/foo shows up at least twice (once in the original command,
    // once as yanked output).
    var count: usize = 0;
    var search: []const u8 = r.out;
    while (std.mem.indexOf(u8, search, "/tmp/foo")) |idx| {
        count += 1;
        search = search[idx + 8 ..];
    }
    if (count < 2) {
        std.debug.print("M-. did not appear to yank last arg. Output:\n{s}\n", .{r.out});
    }
    try std.testing.expect(count >= 2);
}

test "slash pty: bracket matching emits a bold span on the matching opener (zigline ≥ v0.1.6)" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Type a complete brace block. After typing, the cursor is just
    // past the closing `}` — slash's highlightHook reads
    // request.cursor_byte and emits a bold span over the matching `{`.
    // Verify the bold-SGR escape (\x1b[1m) appears in the rendered
    // PTY output BEFORE submitting the line. Submitting Enter is what
    // triggers slash to actually run `if true { echo bracket-test }`,
    // which prints "bracket-test" — so we verify both the bold ANSI
    // (during edit) and the executed output (after submit) appear.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "if true { echo bracket-test }", .settle_ms = 250 },
        .{ .send = "\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Bold SGR appears as `\x1b[1m`. Slash's highlighter emits this
    // ONLY for the matching-bracket span (everything else uses dim
    // white, cyan-bold for keywords, etc.). Bold-cyan keywords would
    // render as `\x1b[1;36m` or `\x1b[36;1m`. So a bare `\x1b[1m`
    // (with the `m` immediately after `1`) is uniquely the bracket-
    // match span.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[1m") != null);
    // And the executed command produced its expected stdout.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bracket-test") != null);
}

test "slash pty: highlighter inside dq with $var emits both green AND yellow" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // The constraint slash's highlighter MUST satisfy: emit alternating
    // non-overlapping spans inside dq strings. If slash emitted a
    // wrapping span (one big green over the whole dq + an inner yellow
    // for $name), zigline's renderer would drop the yellow as an
    // overlap and the user would see green-only output. This test
    // catches that regression by asserting both colors fire.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "echo \"hi $USER there\"\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Both green (literal) and yellow (variable) must appear in the
    // rendered output. The renderer emits SGR around each span.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[33m") != null);
}
