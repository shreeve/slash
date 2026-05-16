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

/// Announce backgrounded jobs that finished since the previous prompt.
/// Polls for any pending SIGCHLD events first so a sleep that finished
/// while the user was sitting at the prompt becomes visible at the
/// next Enter (bash/zsh default-mode timing). Mid-prompt announcement
/// in the style of bash `set -b` would require a zigline `printAbove`
/// primitive that hasn't shipped yet.
///
/// Only backgrounded jobs surface notices — foreground completions
/// already go through the exit-status notice and re-announcing them
/// would be redundant. Each job is announced exactly once via the
/// per-job `notified_done` bit.
pub fn pendingDoneJobs(session: *Session) void {
    if (!session.interactive) return;

    // Drain any uncollected SIGCHLD events so .done transitions are
    // visible. Cheap when nothing is pending — waitpid(WNOHANG) is a
    // single syscall that returns immediately when the kernel has
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
        // Set the bit BEFORE firing the notice so even a future
        // `jobStateChange` that grows side effects (or fails partway)
        // cannot re-announce the same completion on a later prompt.
        // Worst case: the user sees no notice for this job once and
        // still finds it via `jobs`. Re-announcement noise would be
        // strictly worse.
        j.notified_done = true;
        jobStateChange(session, j, .done);
    }
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
