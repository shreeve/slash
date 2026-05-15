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
//!     subshell): use `runForeground(session, job)` — does everything
//!     in one call, including the blocking wait.
//!
//!   - `builtins.fgFn`: needs to interleave its own SIGCONT between
//!     giving the tty to the job and the wait, in APUE order. The
//!     required call sequence is:
//!
//!         giveToJob(session, job)            -- tty handoff + termios install
//!         (mark j.foreground/detached)
//!         (SIGCONT to j.pgid if was stopped)
//!         job.service(.foreground, j)
//!         reclaimForShell(session, job)
//!
//!     `SIGCONT` MUST come after `giveToJob` so the resumed program
//!     sees the tty already handed over and its own termios already
//!     restored — otherwise it might write to the tty before we own
//!     the foreground group, taking SIGTTOU.

const std = @import("std");
const session_mod = @import("session.zig");
const job_mod = @import("job.zig");
const exec = @import("exec.zig");
const zigline = @import("zigline");

const Session = session_mod.Session;
const Job = job_mod.Job;

/// Hand the controlling terminal to the job's process group AND set
/// the appropriate terminal modes:
///
///   - If the job has a saved termios from a prior stop (it was `fg`'d
///     after `Ctrl-Z`), restore that — vim wants its raw mode, less
///     wants its cbreak mode, etc.
///
///   - Otherwise, install a "user-mode" termios derived from the shell's
///     baseline by forcing the standard cooked-mode echo flags on:
///     `ECHO|ECHOE|ECHOK|ECHOCTL|ICANON|ISIG|IEXTEN` on lflag,
///     `OPOST|ONLCR` on oflag. This is the bash/zsh "shell mode →
///     user mode" distinction. The load-bearing flag is `ECHOCTL`,
///     which makes the kernel echo `^C` when Ctrl-C arrives at a
///     foreground job — without it, pressing Ctrl-C kills the job
///     but provides no visual feedback (VALIDATION.md F2).
///
/// No-op when there's no controlling tty (non-interactive shape) or
/// when the job has no real process group (zero-child shell-context
/// jobs shouldn't reach this path, but defensive).
pub fn giveToJob(session: *Session, j: *Job) void {
    const tty_fd = session.controlling_tty_fd orelse return;
    if (j.pgid > 0) _ = exec.tcSetPgrp(tty_fd, j.pgid);
    if (j.termios) |t| {
        std.posix.tcsetattr(tty_fd, .DRAIN, t) catch {};
    } else if (session.shell_termios) |base| {
        var user_t = base;
        user_t.lflag.ECHO = true;
        user_t.lflag.ECHOE = true;
        user_t.lflag.ECHOK = true;
        user_t.lflag.ECHOCTL = true;
        user_t.lflag.ICANON = true;
        user_t.lflag.ISIG = true;
        user_t.lflag.IEXTEN = true;
        user_t.oflag.OPOST = true;
        user_t.oflag.ONLCR = true;
        std.posix.tcsetattr(tty_fd, .DRAIN, user_t) catch {};
    }
}

/// Reclaim the controlling terminal for the shell after a foreground
/// wait completes or stops. On `.stopped`, snapshot the job's current
/// termios into `j.termios` first so a later `fg` can restore it.
/// Then `tcsetpgrp(tty, shell_pgid)` and restore the shell's saved
/// modes via `tcsetattr(DRAIN, shell_termios)`.
///
/// On `.done` with a signaled result, ask zigline to ensure its next
/// render starts on a fresh row. Without this, any kernel-echoed
/// control character (`^C`, `^\`, `^Z`) gets wiped by the editor's
/// `\x1b[2K\r` clear-line on the next prompt redraw. Bash and zsh
/// ensure a fresh row after a signaled foreground job for the same
/// reason; `zigline.pokeActiveFreshRow` (v0.3.1+) is the proper
/// hook for it — Editor-scoped lifetime, so it works between
/// `readLine` calls (which is exactly when we're calling it).
///
/// `TCSADRAIN` waits for any in-flight output before the termios
/// change so we don't truncate the program's last line.
pub fn reclaimForShell(session: *Session, j: *Job) void {
    const tty_fd = session.controlling_tty_fd orelse return;
    switch (j.state) {
        .stopped => {
            if (std.posix.tcgetattr(tty_fd)) |t| {
                j.termios = t;
            } else |_| {}
        },
        .done => |r| switch (r) {
            .signaled => zigline.pokeActiveFreshRow(),
            else => {},
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
pub fn runForeground(session: *Session, j: *Job) !void {
    giveToJob(session, j);
    defer reclaimForShell(session, j);
    try job_mod.service(&session.jobs, .foreground, j);
}
