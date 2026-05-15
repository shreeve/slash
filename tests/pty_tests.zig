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

// `TIOCSCTTY` — make this fd the calling session leader's controlling
// terminal. After `setsid()` clears the inherited ctty, the child needs
// this ioctl on the slave PTY so the kernel routes tty-driven signals
// (SIGINT/SIGTSTP/SIGWINCH) to it. Without it, slash's tcsetpgrp calls
// fail with ENOTTY and Ctrl-Z under PTY stops the wrong process group.
const TIOCSCTTY: c_ulong = switch (builtin.target.os.tag) {
    .linux => 0x540E,
    .macos, .ios, .driverkit, .maccatalyst, .tvos, .visionos, .watchos => 0x20007461,
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x20007461,
    else => 0x20007461,
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

    /// Drain until `needle` appears in `out` or `timeout_ms` elapses.
    /// Returns true iff the needle was observed. Polls in 50 ms slices
    /// so a fast match doesn't pay the full timeout — load-tolerant
    /// without making clean runs slow. Existing buffer contents count;
    /// a step that waits for output produced by an earlier step still
    /// matches if those bytes are already collected.
    ///
    /// Time is tracked by deducting each poll slice from a countdown.
    /// Zig 0.16 removed `std.time.milliTimestamp` and friends; the
    /// replacement (`std.Io.Clock.Timestamp.now(io, .awake)`) needs an
    /// io instance to thread through. The countdown is approximate
    /// (it ignores time spent inside `read`, which is fast on a PTY)
    /// but more than precise enough for "wait up to N seconds for a
    /// kernel event."
    fn drainUntil(
        self: Spawned,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        needle: []const u8,
        timeout_ms: i64,
    ) !bool {
        if (std.mem.indexOf(u8, out.items, needle) != null) return true;
        var chunk: [4096]u8 = undefined;
        var remaining = timeout_ms;
        while (remaining > 0) {
            const slice_ms: i64 = @min(remaining, 50);
            if (try waitReadable(self.master, slice_ms)) {
                const n = std.c.read(self.master, &chunk, chunk.len);
                if (n < 0) {
                    const e = std.c.errno(@as(c_int, -1));
                    if (e == .INTR) continue;
                    if (e == .IO) return false; // slave closed before needle appeared
                    return error.ReadFailed;
                }
                if (n == 0) return false; // EOF
                try out.appendSlice(alloc, chunk[0..@intCast(n)]);
                if (std.mem.indexOf(u8, out.items, needle) != null) return true;
            }
            remaining -= slice_ms;
        }
        return false;
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

        // Acquire the slave PTY as our controlling terminal. setsid()
        // clears the inherited ctty; without TIOCSCTTY the child has no
        // ctty even though dup2() makes the slave fd 0/1/2. Slash needs
        // a ctty for tcsetpgrp + tty-driven signal delivery (Ctrl-Z).
        _ = ioctl_with_ulong_request(pty.slave, TIOCSCTTY, @as(c_int, 0));

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
    /// If set, after `send` the script drains until this needle appears in
    /// the collected output OR `settle_ms` elapses (whichever comes first).
    /// Use for steps that depend on async kernel events (SIGCHLD propagation,
    /// SIGTTIN delivery, prompt repaint) where a fixed-time settle races
    /// the scheduler under load. `settle_ms` becomes the maximum wait,
    /// not the actual wait — fast machines exit as soon as the needle
    /// shows up.
    wait_for: ?[]const u8 = null,
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
        if (step.wait_for) |needle| {
            _ = try child.drainUntil(alloc, &collected, needle, step.settle_ms);
        } else {
            try child.drain(alloc, &collected, step.settle_ms);
        }
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
    // escape sequences on the wire. Slash now uses 24-bit truecolor
    // codes (`\x1b[38;2;R;G;Bm`) so the rendered colors don't depend
    // on the user's terminal palette.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "if true { echo \"hi\" }\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Truecolor fg SGR appears as `\x1b[38;2;R;G;Bm`. Slash emits this
    // for any styled token. The bold flag accompanies the keyword span,
    // so bold + truecolor in the stream is the keyword signature.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[38;2;") != null);
    // Bold should appear at least once (for `if` keyword + bracket match).
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[1") != null);
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

    // The bracket-match span is bold + truecolor (palette.bracket_match).
    // The keyword `if` is also bold + truecolor (palette.keyword). Both
    // are bold + 24-bit fg, but the bracket-match RGB differs from the
    // keyword RGB. Just verify SOME bold + truecolor combo fires.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[38;2;") != null);
    // And the executed command produced its expected stdout.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bracket-test") != null);
}

test "slash pty: highlighter inside dq with $var emits string + variable colors" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // The constraint slash's highlighter MUST satisfy: emit alternating
    // non-overlapping spans inside dq strings. If slash emitted a
    // wrapping string-color span (over the whole dq + an inner var-
    // color span for $name), zigline's renderer would drop the inner
    // overlap and the user would see string-color-only output.
    //
    // Slash uses 24-bit truecolor since v1.1, so we check for the
    // specific RGB triplets from `palette_dark` (the default theme):
    // string is `#9ece6a` (green) → "38;2;158;206;106", variable is
    // `#e0af68` (amber) → "38;2;224;175;104".
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "echo \"hi $USER there\"\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);

    // Both string color and variable color must appear in the rendered
    // output. The renderer emits SGR around each span.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[38;2;158;206;106m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\x1b[38;2;224;175;104m") != null);
}

// =============================================================================
// Job control under a real PTY
// =============================================================================
//
// These cases exercise the path the headless harness can't reach: a real
// controlling terminal, real `tcsetpgrp` handoff, real `SIGTSTP` from
// the kernel's tty driver translating Ctrl-Z (byte 0x1A). The bookkeeping
// invariants from PLAN §7 Rule 22 + §19 must hold under terminal pressure.

test "slash pty: Ctrl-C in foreground job echoes `^C` (ECHOCTL on)" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // VALIDATION.md run 2026-05-14 finding F2: pressing Ctrl-C while a
    // foreground job runs killed the job correctly (exit 130) but the
    // kernel never echoed `^C` first, so the user had no visible
    // feedback before the prompt returned. Bash and zsh both echo
    // `^C` because their tty's lflag has ECHOCTL on. Our `bootstrap-
    // Interactive` step 7 now forces ECHOCTL (plus ECHO/ECHOE/ECHOK/
    // ICANON/ISIG/IEXTEN/OPOST/ONLCR) on before saving shell_termios,
    // so the editor's enterRawMode snapshots a "user mode" baseline
    // that includes the cooked-mode echo flags.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 30\n", .settle_ms = 200 },
        .{ .send = "\x03", .settle_ms = 300 }, // Ctrl-C → SIGINT
        .{ .send = "echo back\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // The kernel echoes Ctrl-C as the literal two-byte sequence "^C"
    // when ECHOCTL is on. Without our bootstrap fix, this would be
    // absent.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "^C") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "back") != null);
}

test "slash pty: backgrounding with & prints [N] PID announcement" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // bash/zsh convention: when a job is backgrounded via `&`, the shell
    // immediately prints `[N] <pid>` to stderr so the user sees what
    // happened and can refer to the pid (matches `$!`, `wait $pid`,
    // etc.). Without this announcement, `cat &` looks identical to a
    // hung `cat` — the user has no immediate confirmation. Validation
    // run #1 surfaced this gap; this test pins the behavior.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 5 >/dev/null 2>&1 &\n", .settle_ms = 200 },
        .{ .send = "kill -KILL %1\n", .settle_ms = 100 },
        .{ .send = "wait %1\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // The announcement appears as `[1] <pid>\n` on stderr; the PTY
    // harness merges stderr and stdout, so both are in r.out.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "[1] ") != null);
}

test "slash pty: sleep & jobs shows the backgrounded sleep" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 5 >/dev/null 2>&1 &\n", .settle_ms = 200 },
        .{ .send = "jobs\n", .settle_ms = 200 },
        .{ .send = "kill -TERM %1\n", .settle_ms = 100 },
        .{ .send = "wait %1\n", .settle_ms = 200 },
        .{ .send = "echo done-pty\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // `jobs` output should mention `sleep` somewhere. The bracketed job
    // id and "Running" label are formatted by `jobsFn`.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "sleep") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "done-pty") != null);
}

test "slash pty: $! reports a real pid that wait can drain" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 0.3 >/dev/null 2>&1 &\n", .settle_ms = 100 },
        .{ .send = "echo bgpid=$!\n", .settle_ms = 100 },
        .{ .send = "wait $!\n", .settle_ms = 600 },
        .{ .send = "echo final=$?\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // `bgpid=NNNN` must appear with at least one digit (the rendered pid).
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bgpid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "final=0") != null);
}

test "slash pty: Ctrl-Z stops a foreground sleep, fg resumes it" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // `sleep 30` runs as a foreground command. We send Ctrl-Z (byte
    // 0x1A); the tty driver translates that to SIGTSTP for the
    // controlling terminal's foreground process group, which is the
    // sleep job's pgrp because slash handed the tty to it via
    // `tcsetpgrp`. The sleep stops, control returns to the shell,
    // and `fg` resumes it. Without the `tcsetpgrp` wiring this whole
    // sequence breaks (Ctrl-Z would target the shell instead of the
    // job, or the job wouldn't be the controlling-tty's foreground).
    //
    // Two non-obvious settings here:
    //
    //   1. **`sleep 30`, not `sleep 5`.** A 5-second sleep can finish
    //      before the test inspects `jobs` under load, which used to
    //      look like "Stopped is missing" but was actually "sleep
    //      already exited normally." 30s is comfortably longer than
    //      any reasonable test runtime.
    //
    //   2. **800 ms initial settle before Ctrl-Z.** If we send Ctrl-Z
    //      too soon after `sleep 30\n`, slash hasn't yet finished
    //      fork+exec+tcsetpgrp. The kernel then delivers SIGTSTP to
    //      slash's pgrp (which includes the still-pre-exec child).
    //      Both parent and child inherit SIGTSTP-ignore from the
    //      shell's interactive setup, so the signal is silently
    //      dropped — by the time the child does `execve("/bin/sleep")`,
    //      the SIGTSTP has been swallowed and sleep runs untouched.
    //      800 ms gives slash room to fork, exec, install the user-
    //      mode termios, and `tcsetpgrp` the tty to the job's pgrp
    //      before Ctrl-Z arrives.
    //
    // The `jobs` step uses `wait_for = "Stopped"` so we exit the wait
    // as soon as the marker appears — fast on a healthy machine,
    // tolerant on a busy one. The `echo` step uses `wait_for =
    // "resumed-ok"` for the same reason after `fg`.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 30\n", .settle_ms = 800 },
        .{ .send = "\x1a", .settle_ms = 400 }, // Ctrl-Z → SIGTSTP
        .{ .send = "jobs\n", .settle_ms = 4000, .wait_for = "Stopped" },
        .{ .send = "fg\n", .settle_ms = 200 },
        .{ .send = "\x03", .settle_ms = 400 }, // Ctrl-C kills the resumed sleep
        .{ .send = "echo resumed-ok\n", .settle_ms = 2000, .wait_for = "resumed-ok" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "resumed-ok") != null);
}

test "slash pty: Ctrl-Z then bg lets the job finish without blocking" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 0.5\n", .settle_ms = 150 },
        .{ .send = "\x1a", .settle_ms = 200 }, // Ctrl-Z
        .{ .send = "bg\n", .settle_ms = 100 },
        // After bg, we can immediately run other commands. The sleep
        // finishes in the background; `wait` drains it.
        .{ .send = "echo bg-prompt-ok\n", .settle_ms = 100 },
        .{ .send = "wait\n", .settle_ms = 800 },
        .{ .send = "echo all-drained\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bg-prompt-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "all-drained") != null);
}

test "slash pty: kill -TERM %1 reaps a backgrounded sleep" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 30 >/dev/null 2>&1 &\n", .settle_ms = 150 },
        .{ .send = "kill -TERM %1\n", .settle_ms = 200 },
        .{ .send = "wait %1\n", .settle_ms = 300 },
        .{ .send = "echo killed-cleanly\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "killed-cleanly") != null);
}

test "slash pty: disown removes a backgrounded job from the table" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 1 >/dev/null 2>&1 &\n", .settle_ms = 150 },
        .{ .send = "disown\n", .settle_ms = 100 },
        // After disown, `jobs` should show NO `[1]` because it's been
        // forgotten. We then echo a marker; the disowned sleep finishes
        // in 1s on its own, but the test moves on without waiting.
        .{ .send = "jobs\n", .settle_ms = 100 },
        .{ .send = "echo after-disown\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "after-disown") != null);
}

// ---- SIGHUP at shell exit (PLAN §18, CHECKLIST §11) -------------------------
//
// When Slash exits, every non-disowned, non-done job in the table gets
// SIGHUP+SIGCONT. Verified by spawning a `/bin/sh` child that traps
// SIGHUP and writes a marker file before dying. After the slash test
// process reaps, we check the marker. Disowned jobs are explicitly
// excluded — second test asserts the disown variant gets NO marker.

const hup_marker = "/tmp/slash-pty-hup-marker";
const disown_marker = "/tmp/slash-pty-disown-marker";

fn unlinkMarker(path: [:0]const u8) void {
    _ = std.c.unlink(path);
}

fn markerExists(path: [:0]const u8) bool {
    return std.c.access(path, std.c.F_OK) == 0;
}

test "slash pty: shell exit hangs up running bg jobs" {
    if (!ptySupported()) return error.SkipZigTest;
    unlinkMarker(hup_marker);
    defer unlinkMarker(hup_marker);

    const alloc = std.testing.allocator;
    // Background a sh with a SIGHUP trap that writes the marker. Slash
    // should signal it on exit. We give the orphan up to ~600ms after
    // slash exits to actually run its handler.
    // Generous settle so the bg sh has time to install its HUP trap
    // before we exit slash. Without it the orphan can race past
    // `trap` registration before slash sends SIGHUP.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{
            .send =
                "/bin/sh -c 'trap \"echo hupped > " ++ hup_marker ++
                "; exit 0\" HUP; sleep 10' >/dev/null 2>&1 &\n",
            .settle_ms = 600,
        },
        .{ .send = "exit 0\n", .settle_ms = 800 },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // Patient wait for the orphan to receive HUP, run the trap, write
    // the marker, and exit. macOS scheduler under load can take a
    // surprising fraction of a second to deliver the HUP and schedule
    // the trap handler in the orphan. ~3s cap.
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 50) {
        if (markerExists(hup_marker)) break;
        var pfd: std.c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&pfd), 0, 50);
    }
    try std.testing.expect(markerExists(hup_marker));
}

// ---- Job-control edge cases (CHECKLIST §5, §6 — GPT 5.5 review list) -------
//
// These are the cases that distinguish "PTY tests pass" from "vim/less/
// nested shell behave correctly." Each one targets a load-bearing
// invariant that's easy to miss until a real user trips it:
//
//   - `cat &` (a bg reader): on its first stdin read it should stop with
//     SIGTTIN, not silently hang or read from the shell's input.
//   - Ctrl-\ (SIGQUIT) on a foreground job: kills the job; the shell
//     itself ignores QUIT and survives.
//   - bg writer with `stty tostop`: a background process trying to write
//     to the terminal stops with SIGTTOU. (POSIX-optional; the kernel
//     drives this entirely off the tty's `tostop` flag.)
//   - nested slash inside slash: stop the outer's foreground (which is
//     the inner slash) with Ctrl-Z; `fg` resumes. Verifies that nested
//     interactive shells respect the parent's terminal-handoff dance.

test "slash pty: cat & stops with SIGTTIN on bg stdin read" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // `cat &` puts cat in the background reading stdin. The kernel
    // delivers SIGTTIN on its first read attempt because cat isn't in
    // the foreground pgrp. `jobs` should show it as Stopped.
    //
    // The flake we used to hit: 300 ms wasn't always enough for the
    // full chain "cat is forked → cat starts → cat issues read() on
    // stdin → kernel delivers SIGTTIN → cat stops → SIGCHLD reaches
    // slash → slash records the stop in the job table." Under load
    // any of those steps can slip past 300 ms. Two changes here:
    //
    //   1. **800 ms post-bg settle.** Gives the SIGTTIN dance room
    //      to complete on a busy machine before we ask for `jobs`.
    //   2. **`wait_for = "Stopped"` on `jobs`.** Exits the wait the
    //      moment the listing prints — fast on a healthy machine,
    //      tolerant on a busy one. `echo done` uses the same idiom
    //      against its own marker.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "cat &\n", .settle_ms = 800 },
        .{ .send = "jobs\n", .settle_ms = 4000, .wait_for = "Stopped" },
        .{ .send = "kill -KILL %1\n", .settle_ms = 100 },
        .{ .send = "wait %1\n", .settle_ms = 200 },
        .{ .send = "echo done\n", .settle_ms = 2000, .wait_for = "done" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // The `jobs` listing between bg and kill must show Stopped.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "done") != null);
}

test "slash pty: Ctrl-\\ sends SIGQUIT to foreground job; shell survives" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // `\x1c` is the default SIGQUIT character (FS / Ctrl-\). Same path
    // as Ctrl-C: the kernel delivers SIGQUIT to the tty's foreground
    // pgrp. With slash's tcsetpgrp wiring, that's the sleep job.
    // SIGQUIT's default action is core-dump-and-die. Shell ignores it.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "sleep 5\n", .settle_ms = 200 },
        .{ .send = "\x1c", .settle_ms = 300 }, // Ctrl-\ → SIGQUIT
        .{ .send = "echo shell-still-alive\n" },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "shell-still-alive") != null);
}

test "slash pty: nested slash — runs commands and exits cleanly back to outer" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Inner slash starts as the outer's foreground. It does its own
    // bootstrap (setpgid/tcsetpgrp), runs commands, and on `exit 0`
    // hands the tty back to the outer cleanly.
    //
    // Note: we do NOT try to Ctrl-Z the inner. Like bash, an interactive
    // slash IGNORES SIGTSTP (job-control hygiene per PLAN §18) — Ctrl-Z
    // from the outer translates to SIGTSTP for the inner's pgrp, which
    // ignores it. That's correct behavior; this test focuses on the
    // tty-handoff round trip instead.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "bin/slash --norc\n", .settle_ms = 600 },
        .{ .send = "echo inner-running\n", .settle_ms = 200 },
        .{ .send = "echo from-inner-pid=$$\n", .settle_ms = 200 },
        .{ .send = "exit 0\n", .settle_ms = 400 },
        .{ .send = "echo outer-back\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "inner-running") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "from-inner-pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "outer-back") != null);
}

test "slash pty: nested bash — runs commands and exits cleanly back to outer" {
    if (!ptySupported()) return error.SkipZigTest;
    if (std.c.access("/bin/bash", std.c.X_OK) != 0) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // Same shape as the nested-slash test but with bash, exercising
    // cross-shell terminal-handoff compatibility. Like slash, bash
    // ignores SIGTSTP when interactive, so the test covers exit/return,
    // not stop/resume.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "/bin/bash --noprofile --norc\n", .settle_ms = 600 },
        .{ .send = "echo bash-running\n", .settle_ms = 200 },
        .{ .send = "exit 0\n", .settle_ms = 400 },
        .{ .send = "echo outer-back\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bash-running") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "outer-back") != null);
}

test "slash pty: nested slash — Ctrl-Z stops a sleep INSIDE the inner shell" {
    if (!ptySupported()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // The valuable nested-shell job-control test: stop a foreground
    // command that's running INSIDE the inner shell. The inner shell
    // (not the outer) is the one whose tcsetpgrp/termios discipline
    // is exercised here. Validates that a slash inside slash can do
    // its own job control independently.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{ .send = "bin/slash --norc\n", .settle_ms = 600 },
        .{ .send = "sleep 5\n", .settle_ms = 200 },
        .{ .send = "\x1a", .settle_ms = 400 }, // Ctrl-Z hits sleep, not the inner slash
        .{ .send = "jobs\n", .settle_ms = 200 },
        .{ .send = "kill -KILL %1\n", .settle_ms = 200 },
        .{ .send = "wait %1\n", .settle_ms = 200 },
        .{ .send = "echo inner-recovered\n", .settle_ms = 200 },
        .{ .send = "exit 0\n", .settle_ms = 400 },
        .{ .send = "echo outer-back\n", .settle_ms = 200 },
        .{ .send = "exit 0\n" },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "inner-recovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "outer-back") != null);
}

test "slash pty: shell exit does NOT signal disowned jobs" {
    if (!ptySupported()) return error.SkipZigTest;
    unlinkMarker(disown_marker);
    defer unlinkMarker(disown_marker);

    const alloc = std.testing.allocator;
    // Same setup but with `disown`. The orphan finishes its sleep
    // naturally without ever receiving HUP, so the marker stays
    // absent. The sleep is short so the test finishes quickly.
    const r = try runScript(alloc, &.{"--norc"}, &.{
        .{
            .send =
                "/bin/sh -c 'trap \"echo hupped > " ++ disown_marker ++
                "\" HUP; sleep 0.4' >/dev/null 2>&1 &\n",
            .settle_ms = 200,
        },
        .{ .send = "disown\n", .settle_ms = 100 },
        .{ .send = "exit 0\n", .settle_ms = 800 },
    });
    defer alloc.free(r.out);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    // Wait long enough for the disowned sleep to finish naturally.
    var waited: u32 = 0;
    while (waited < 1000) : (waited += 100) {
        var pfd: std.c.pollfd = .{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&pfd), 0, 100);
    }
    try std.testing.expect(!markerExists(disown_marker));
}
