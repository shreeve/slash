//! terminal — controlling-tty handoff and termios save/restore.
//!
//! Centralizes the dance every foreground-wait site has to perform:
//!
//!   pre-wait:  tcsetpgrp(tty, job.pgid); tcsetattr(tty, DRAIN, job.termios)
//!   wait:      job.service(.foreground, target)  -- caller owns this
//!   post-wait: on stop -> snapshot j.termios from tty
//!              tcsetpgrp(tty, shell_pgid); tcsetattr(tty, DRAIN, shell_termios)
//!
//! Before this module the dance was duplicated in `eval.serviceForeground`
//! and `builtins.fgFn`, kept in lockstep manually. That's exactly the
//! kind of code that drifts and produces impossible terminal bugs six
//! months later. PLAN §11 + CHECKLIST §5 demand one implementation.
//!
//! Two flavors of caller:
//!
//!   - `eval.serviceForeground` and friends (single command / pipeline /
//!     subshell): use `waitForeground(session, job)` — does everything
//!     in one call, including the blocking wait.
//!
//!   - `builtins.fgFn`: needs to interleave its own SIGCONT between
//!     giving the tty to the job and the wait, in APUE order. Use
//!     the lower-level pair `giveTo(session, job)` + `reclaim(session,
//!     job)` and call `job.service` directly between them.

const std = @import("std");
const session_mod = @import("session.zig");
const job_mod = @import("job.zig");
const exec = @import("exec.zig");

const Session = session_mod.Session;
const Job = job_mod.Job;

/// Hand the controlling terminal to the job's process group AND restore
/// the job's saved terminal modes (vim raw, less cbreak, etc.).
///
/// No-op when there's no controlling tty (non-interactive shape) or when
/// the job has no real process group (zero-child shell-context jobs
/// shouldn't be reaching this path anyway, but defensive).
pub fn giveTo(session: *Session, j: *Job) void {
    const tty_fd = session.controlling_tty_fd orelse return;
    if (j.pgid > 0) _ = exec.tcSetPgrp(tty_fd, j.pgid);
    if (j.termios) |t| {
        std.posix.tcsetattr(tty_fd, .DRAIN, t) catch {};
    }
}

/// Reclaim the controlling terminal for the shell after a foreground
/// wait completes or stops. On `.stopped`, snapshot the job's current
/// termios into `j.termios` first so a later `fg` can restore it.
/// Then `tcsetpgrp(tty, shell_pgid)` and restore the shell's saved
/// modes via `tcsetattr(DRAIN, shell_termios)`.
///
/// `TCSADRAIN` waits for any in-flight output before the change so we
/// don't truncate the program's last line.
pub fn reclaim(session: *Session, j: *Job) void {
    const tty_fd = session.controlling_tty_fd orelse return;
    switch (j.state) {
        .stopped => {
            if (std.posix.tcgetattr(tty_fd)) |t| {
                j.termios = t;
            } else |_| {}
        },
        else => {},
    }
    if (session.shell_pgid > 0) _ = exec.tcSetPgrp(tty_fd, session.shell_pgid);
    if (session.shell_termios) |t| {
        std.posix.tcsetattr(tty_fd, .DRAIN, t) catch {};
    }
}

/// Convenience: hand the tty to `j`, block on its foreground wait,
/// reclaim the tty for the shell. The common case for spawn sites
/// that don't need to interleave anything between handoff and wait.
pub fn waitForeground(session: *Session, j: *Job) !void {
    giveTo(session, j);
    defer reclaim(session, j);
    try job_mod.service(&session.jobs, .foreground, j);
}
