//! notice — pre-prompt and live-event status notices.
//!
//! Slash communicates command-status and job-state changes through
//! short stderr lines that read as shell metadata, not program output.
//! Two flavors:
//!
//!   - **Status notice** (`slash: exit 130 (SIGINT)`): emitted once
//!     just before the next prompt when the previous command exited
//!     non-zero. Replaces the `[N]` badge that used to sit between
//!     cwd and the prompt's `$` (VALIDATION.md F3 placement).
//!     The `slash:` prefix disambiguates the line from program
//!     output — without it, `exit 130` could be read as something
//!     the program printed.
//!
//!   - **Job-state notice** (`[1] Stopped sleep 30`): emitted at the
//!     point of a job-state change — Ctrl-Z stopping a foreground
//!     job, `fg`/`bg` resuming a stopped job, idle-time completion
//!     post-prompt. Format matches the `jobs` builtin's listing for
//!     visual consistency. No `slash:` prefix because job-state
//!     announcements always follow either a kernel-echoed `^Z` (for
//!     Ctrl-Z) or a user-typed `fg`/`bg` line (which itself
//!     establishes context).
//!
//! Both kinds dim themselves when stderr is a TTY (ANSI 2 bracket),
//! so they recede visually relative to program output. Skipped when
//! the session is non-interactive (`-c`, scripts, headless tests)
//! where the stderr noise would be unwanted. Failures to write are
//! ignored — a notice is a hint, not a hard requirement.

const std = @import("std");
const session_mod = @import("session.zig");
const job_mod = @import("job.zig");
const runtime = @import("runtime.zig");

pub const Result = runtime.Result;
pub const Signal = runtime.Signal;
pub const Session = session_mod.Session;
pub const Job = job_mod.Job;

const STDERR: c_int = 2;

pub const JobNoticeKind = enum {
    /// Foreground job was stopped (Ctrl-Z / SIGTSTP).
    stopped,
    /// Stopped job was resumed in the foreground (`fg`).
    continued_fg,
    /// Stopped job was resumed in the background (`bg`).
    continued_bg,
    /// Background job finished while the shell was idle. Reserved
    /// for the upcoming idle-time-notification path; not currently
    /// fired by any caller.
    done,
};

/// Caller-supplied sink for `drainDoneJobs`. Receives the formatted
/// `[N] Done <cmd>` text WITHOUT a trailing newline; the writer is
/// responsible for whatever decoration (dim ANSI, CRLF, etc.) matches
/// the output channel it's targeting.
pub const DoneWriter = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, text: []const u8) void,
};

/// Poll for any uncollected SIGCHLD events, then iterate backgrounded
/// jobs that have just transitioned to `.done`. For each, mark
/// `notified_done = true` and hand the formatted text to `writer`.
///
/// Two writers share this iteration:
///
///   - `pendingDoneJobs` (between-prompts, default mode) wraps a
///     stderr `writeLineDim` writer; matches bash/zsh `set +b`
///     timing.
///   - `repl.onWakeHook` (mid-prompt, `$SLASH_NOTIFY=immediate`
///     opt-in) wraps a `zigline.Editor.printAbove` writer; matches
///     bash/zsh `set -b` timing.
///
/// The `notified_done` bit is set BEFORE the writer is called so a
/// writer failure / partial print can't re-announce the same job on
/// the next iteration.
pub fn drainDoneJobs(session: *Session, writer: DoneWriter) void {
    if (!session.interactive) return;

    // Drain any uncollected SIGCHLD events so .done transitions are
    // visible. Cheap when nothing is pending — `waitpid(WNOHANG)` is
    // a single syscall that returns immediately when the kernel has
    // nothing to report.
    job_mod.service(&session.jobs, .poll, null) catch {};

    for (session.jobs.list()) |j| {
        if (j.processes.len == 0) continue;
        if (!j.detached) continue;
        if (j.notified_done) continue;
        switch (j.state) {
            .done => {},
            else => continue,
        }
        var buf: [256]u8 = undefined;
        const text = formatDone(j, &buf) orelse {
            j.notified_done = true;
            continue;
        };
        j.notified_done = true;
        writer.writeFn(writer.ctx, text);
    }
}

const StderrSink = struct {
    fn write(ctx: *anyopaque, text: []const u8) void {
        _ = ctx;
        writeLineDim(text);
    }
};

/// Announce backgrounded jobs that finished since the previous prompt.
/// Polls for any pending SIGCHLD events first so a sleep that finished
/// while the user was sitting at the prompt becomes visible at the
/// next Enter (bash/zsh `set +b` default timing). Routes through
/// `drainDoneJobs` so the same iteration logic backs both the
/// between-prompts path and the mid-prompt `set -b` path in
/// `repl.onWakeHook`.
pub fn pendingDoneJobs(session: *Session) void {
    // `StderrSink.write` ignores its ctx, but `*anyopaque` shouldn't
    // ever be passed an `undefined` pointer value — feed it the
    // session so it's always a valid address.
    drainDoneJobs(session, .{
        .ctx = @ptrCast(session),
        .writeFn = StderrSink.write,
    });
}

/// Drain a pending exit-status notice. No-op when the flag is clear,
/// the last status was zero, or the session isn't interactive. Always
/// clears the flag so a subsequent prompt is silent.
///
/// Called from the runRaw loop just before `slashPrompt`. The previous
/// `[N]` badge inside the prompt itself is gone — placement and
/// stickiness both lived there, and both are addressed by emitting a
/// dedicated line above the prompt instead.
pub fn pendingExitStatus(session: *Session) void {
    if (!session.status_pending) return;
    defer session.status_pending = false;
    // `last_status_explained` is set when the failure already produced
    // a specific user-facing stderr message (e.g. `slash: command not
    // found: NAME`). Suppress the generic notice in that case to avoid
    // duplicate noise. Always clear the flag, regardless of whether
    // we suppressed.
    const explained = session.last_status_explained;
    session.last_status_explained = false;
    if (explained) return;
    if (!session.interactive) return;
    if (session.last_status == 0) return;

    const result = session.last_result;
    var buf: [128]u8 = undefined;
    const text = formatExit(result, session.last_status, &buf) orelse return;
    writeLineDim(text);
}

/// Emit a job-state-change notice at the point of action.
///
/// All four kinds land at column 0 by the time we write: kernel
/// echoes of `^Z` / `^C` already advance to the next line, and `fg`
/// / `bg` / idle-done all fire after an Enter. So no special leading
/// break is needed — the line just lands cleanly under whatever was
/// last on screen.
pub fn jobStateChange(session: *Session, j: *const Job, kind: JobNoticeKind) void {
    if (!session.interactive) return;

    var buf: [256]u8 = undefined;
    const cmd = j.command_text orelse "<job>";
    const text: []const u8 = switch (kind) {
        .stopped => std.fmt.bufPrint(&buf, "[{d}] Stopped {s}", .{ j.id, cmd }) catch return,
        .continued_fg => std.fmt.bufPrint(&buf, "[{d}] Continued {s}", .{ j.id, cmd }) catch return,
        .continued_bg => std.fmt.bufPrint(&buf, "[{d}] Continued {s} &", .{ j.id, cmd }) catch return,
        .done => formatDone(j, &buf) orelse return,
    };

    writeLineDim(text);
}

// =============================================================================
// Internals
// =============================================================================

fn writeLineDim(body: []const u8) void {
    const tty = std.c.isatty(STDERR) != 0;
    if (tty) {
        const dim = "\x1b[2m";
        _ = std.c.write(STDERR, dim, dim.len);
    }
    _ = std.c.write(STDERR, body.ptr, body.len);
    if (tty) {
        const reset = "\x1b[0m\n";
        _ = std.c.write(STDERR, reset, reset.len);
    } else {
        _ = std.c.write(STDERR, "\n", 1);
    }
}

fn formatExit(result: ?Result, status: u8, buf: []u8) ?[]const u8 {
    // Prefer the typed Result when available — a process can `exit 130`
    // literally, which is byte-equivalent to a SIGINT-killed status but
    // semantically different. With the typed Result we get the truth.
    if (result) |r| switch (r) {
        .signaled => |sig| {
            const name = signalName(sig);
            return std.fmt.bufPrint(buf, "slash: exit {d} ({s})", .{ status, name }) catch null;
        },
        .exited => return std.fmt.bufPrint(buf, "slash: exit {d}", .{status}) catch null,
    };

    // Fallback: status byte alone. For 128..159 the convention is that
    // the process was killed by signal `status - 128`; we add the name
    // when the lookup succeeds. For other ranges, just the number.
    if (status >= 128 and status < 160) {
        const sig_n: u8 = status - 128;
        if (signalNameForNumber(sig_n)) |name| {
            return std.fmt.bufPrint(buf, "slash: exit {d} ({s})", .{ status, name }) catch null;
        }
    }
    return std.fmt.bufPrint(buf, "slash: exit {d}", .{status}) catch null;
}

fn formatDone(j: *const Job, buf: []u8) ?[]const u8 {
    const cmd = j.command_text orelse "<job>";
    const r = j.result orelse return null;
    return switch (r) {
        .exited => |n| if (n == 0)
            std.fmt.bufPrint(buf, "[{d}] Done {s}", .{ j.id, cmd }) catch null
        else
            std.fmt.bufPrint(buf, "[{d}] Exit {d} {s}", .{ j.id, n, cmd }) catch null,
        .signaled => |sig| blk: {
            const name = signalName(sig);
            break :blk std.fmt.bufPrint(buf, "[{d}] Killed ({s}) {s}", .{ j.id, name, cmd }) catch null;
        },
    };
}

fn signalName(sig: Signal) []const u8 {
    return switch (sig) {
        .HUP => "SIGHUP",
        .INT => "SIGINT",
        .QUIT => "SIGQUIT",
        .ILL => "SIGILL",
        .TRAP => "SIGTRAP",
        .ABRT => "SIGABRT",
        .FPE => "SIGFPE",
        .KILL => "SIGKILL",
        .BUS => "SIGBUS",
        .SEGV => "SIGSEGV",
        .PIPE => "SIGPIPE",
        .ALRM => "SIGALRM",
        .TERM => "SIGTERM",
        .USR1 => "SIGUSR1",
        .USR2 => "SIGUSR2",
        .CHLD => "SIGCHLD",
        .CONT => "SIGCONT",
        .STOP => "SIGSTOP",
        .TSTP => "SIGTSTP",
        .TTIN => "SIGTTIN",
        .TTOU => "SIGTTOU",
        else => "SIG?",
    };
}

fn signalNameForNumber(n: u8) ?[]const u8 {
    inline for (@typeInfo(Signal).@"enum".fields) |f| {
        if (f.value == @as(c_int, @intCast(n))) {
            return signalName(@as(Signal, @enumFromInt(f.value)));
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "notice: signalNameForNumber maps standard signals" {
    try std.testing.expectEqualStrings("SIGINT", signalNameForNumber(2).?);
    try std.testing.expectEqualStrings("SIGKILL", signalNameForNumber(9).?);
    try std.testing.expectEqualStrings("SIGTERM", signalNameForNumber(15).?);
}

test "notice: formatExit uses typed Result when available" {
    var buf: [128]u8 = undefined;
    const sig: Signal = .INT;
    const r = Result{ .signaled = sig };
    const text = formatExit(r, 130, &buf).?;
    try std.testing.expectEqualStrings("slash: exit 130 (SIGINT)", text);
}

test "notice: formatExit on plain non-zero exit" {
    var buf: [128]u8 = undefined;
    const text = formatExit(Result{ .exited = 1 }, 1, &buf).?;
    try std.testing.expectEqualStrings("slash: exit 1", text);
}

test "notice: formatExit falls back to status-byte heuristic" {
    var buf: [128]u8 = undefined;
    // No typed Result; status 137 → 128 + 9 → SIGKILL.
    const text = formatExit(null, 137, &buf).?;
    try std.testing.expectEqualStrings("slash: exit 137 (SIGKILL)", text);
}

test "notice: drainDoneJobs feeds the writer once per newly-done bg job" {
    // Build a minimal interactive Session, hand-construct a Job that
    // matches what `notice.drainDoneJobs` looks for (backgrounded,
    // `.done` with a zero exit, non-empty processes list,
    // `command_text` set, `notified_done = false`), then route it
    // through a recording `DoneWriter` instead of stderr.
    //
    // Verifies three contract points that the production `on_wake`
    // path in `repl.zig` (and the between-prompts wrapper) depends on:
    //
    //   1. The writer is called exactly once, with the expected
    //      `[N] Done <cmd>` text (no trailing newline — the writer
    //      decorates).
    //   2. `notified_done` flips to true.
    //   3. A second call to `drainDoneJobs` is a no-op (idempotent —
    //      this is how mid-prompt and between-prompts paths avoid
    //      double-announcing the same completion).
    const job_module = @import("job.zig");

    const alloc = std.testing.allocator;
    var s = try Session.init(alloc, @ptrCast(@alignCast(std.c.environ)), true);
    defer s.deinit();

    const j = try s.jobs.create(false, true, "sleep 1");
    // Hand-shape a single-process, done-with-status-0 job. The real
    // path arrives here via `JobTable.applyEvent` after a SIGCHLD
    // reap; we skip the kernel round-trip and assemble the same
    // end-state directly.
    const procs = try alloc.alloc(job_module.Process, 1);
    procs[0] = .{ .pid = 12345, .state = .{ .done = .{ .exited = 0 } } };
    j.processes = procs;
    j.state = .{ .done = .{ .exited = 0 } };
    j.result = .{ .exited = 0 };
    j.notified_done = false;

    const Recorder = struct {
        calls: usize = 0,
        last: [256]u8 = undefined,
        last_len: usize = 0,

        fn write(ctx: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            const n = @min(text.len, self.last.len);
            @memcpy(self.last[0..n], text[0..n]);
            self.last_len = n;
        }
    };
    var rec: Recorder = .{};
    drainDoneJobs(&s, .{ .ctx = @ptrCast(&rec), .writeFn = Recorder.write });
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expectEqualStrings("[1] Done sleep 1", rec.last[0..rec.last_len]);
    try std.testing.expect(j.notified_done);

    // Second call must be a no-op — the latch prevents double
    // announcement across overlapping wake / prompt-boundary
    // drain paths.
    drainDoneJobs(&s, .{ .ctx = @ptrCast(&rec), .writeFn = Recorder.write });
    try std.testing.expectEqual(@as(usize, 1), rec.calls);

    // Hand the job's process slice back to the allocator the way the
    // real teardown path does; `JobTable.deinit` will free it.
}

test "notice: drainDoneJobs skips foreground completions and pending jobs" {
    const job_module = @import("job.zig");

    const alloc = std.testing.allocator;
    var s = try Session.init(alloc, @ptrCast(@alignCast(std.c.environ)), true);
    defer s.deinit();

    // Foreground done — should be ignored (foreground completions go
    // through the exit-status notice, not the `[N] Done` channel).
    const fg = try s.jobs.create(true, false, "echo hi");
    const fg_procs = try alloc.alloc(job_module.Process, 1);
    fg_procs[0] = .{ .pid = 1, .state = .{ .done = .{ .exited = 0 } } };
    fg.processes = fg_procs;
    fg.state = .{ .done = .{ .exited = 0 } };

    // Backgrounded but still running — not done, must not announce.
    const bg_running = try s.jobs.create(false, true, "sleep 100");
    const bg_running_procs = try alloc.alloc(job_module.Process, 1);
    bg_running_procs[0] = .{ .pid = 2, .state = .running };
    bg_running.processes = bg_running_procs;
    bg_running.state = .running;

    const Recorder = struct {
        calls: usize = 0,
        fn write(ctx: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };
    var rec: Recorder = .{};
    drainDoneJobs(&s, .{ .ctx = @ptrCast(&rec), .writeFn = Recorder.write });
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
}
