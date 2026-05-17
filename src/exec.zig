//! Slash — POSIX plumbing.
//!
//! This module is the only place that calls `fork`, `execve`, `waitpid`,
//! `pipe`, `dup2`, `setpgid`, and `_exit`. It knows nothing about builtins,
//! pipelines, sequences, or shell policy. It accepts a fully-prepared
//! `SpawnRequest` and either forks-and-execs or forks-and-runs-callback.
//!
//! Caller responsibilities (PLAN §11 must-get-right + GPT-5.4 review):
//!   - Build argv / envp / redirect plan in the parent before fork.
//!   - For external commands, resolve PATH in the parent so the child does
//!     not need to allocate.
//!   - For builtins-in-child (pipeline stages, subshell builtin bodies),
//!     pre-marshal a stable POD ctx blob; child callback reads it
//!     read-only, returns u8, parent never sees builtin types.
//!
//! Zig 0.16 note: `std.posix.fork`/`waitpid`/`pipe`/`close`/`dup2`/`_exit`
//! were all removed; we go straight to `std.c.*` and decode `errno` via
//! `std.c.errno(rc)`. `std.posix.sigaction` survives.

const std = @import("std");
const runtime = @import("runtime.zig");

pub const Fd = std.c.fd_t;
pub const Pid = std.c.pid_t;

// libc bindings — Zig 0.16's `std.c` doesn't expose `tcsetpgrp` or
// `tcgetpgrp`. They're standard POSIX (XSI); declare directly so the
// job-control handoff in `tcSetPgrp` and the interactive bootstrap in
// `tcGetPgrp` can call them.
extern "c" fn tcsetpgrp(fd: Fd, pgid: Pid) c_int;
extern "c" fn tcgetpgrp(fd: Fd) Pid;

pub const Error = error{
    ForkFailed,
    PipeFailed,
    Dup2Failed,
    OpenFailed,
    SetPgidFailed,
    WaitFailed,
    Unexpected,
};

// =============================================================================
// Redirect plan — resolved, child-applicable
// =============================================================================

pub const OpenMode = enum { read, write, append, both_write, both_append };

/// One redirect operation, resolved against an already-NUL-terminated path
/// or already-open fd. The eval layer is responsible for opening / wiring;
/// the child just applies in order.
pub const RedirectOp = union(enum) {
    /// `dup2(src, dst)` then leave src open (caller decides closes via
    /// `extra_close`). Used for pipe wiring.
    dup: struct { src: Fd, dst: Fd },

    /// `open(path, ...)` then `dup2(opened, dst)` then close the opened fd.
    /// `both_write` / `both_append` dup the opened fd to BOTH 1 and 2 (in
    /// that order); `dst` is ignored for those modes.
    file: struct { path: [*:0]const u8, mode: OpenMode, dst: Fd },

    /// Close `fd` in the child. Useful for unused pipe ends.
    close: Fd,
};

// =============================================================================
// Spawn request
// =============================================================================

pub const ChildAction = union(enum) {
    /// External command path: child applies redirects + signals, then execve.
    exec: struct {
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    },

    /// Builtin-in-child: child applies redirects + signals, then runs the
    /// callback and `_exit`s with its return value. The callback contract
    /// (GPT-5.4 review item 5):
    ///   - runs after fork, in the child
    ///   - context is read-only, fully prepared in parent
    ///   - must not return Zig errors across the boundary
    ///   - must not allocate via the shell's allocator
    builtin_child: struct {
        run: *const fn (ctx: *const anyopaque) callconv(.c) u8,
        ctx: *const anyopaque,
    },
};

pub const SpawnRequest = struct {
    redirects: []const RedirectOp = &.{},
    /// Fds to `close()` in the child immediately before applying redirects.
    /// Typically the unused ends of pipes belonging to other stages.
    extra_close: []const Fd = &.{},
    /// Child pgid. `0` means "child becomes its own process group leader"
    /// (the typical pipeline-leader case). For non-leader stages, set this
    /// to the leader's pid; the child calls `setpgid(0, pgid)` and the
    /// parent calls `setpgid(pid, pgid)` to close the fork race.
    pgid: Pid = 0,
    action: ChildAction,
};

// =============================================================================
// Spawn
// =============================================================================

pub fn spawn(req: SpawnRequest) Error!Pid {
    const rc = std.c.fork();
    if (rc < 0) return Error.ForkFailed;
    if (rc != 0) {
        // Parent: close the fork race on pgid before returning.
        const pid: Pid = @intCast(rc);
        // Best-effort; ignore EACCES/ESRCH if child already won the race.
        _ = std.c.setpgid(pid, req.pgid);
        return pid;
    }

    // Child path. From here on, errors must `_exit`; we never throw or
    // return a Zig error to a non-existent parent stack.
    runChild(req);
}

fn runChild(req: SpawnRequest) noreturn {
    // 1) Set our own pgid first so the parent's setpgid is idempotent.
    //    `setpgid(0, 0)` makes us our own leader; `setpgid(0, leader)`
    //    joins an existing group.
    _ = std.c.setpgid(0, req.pgid);

    // 2) Reset signal dispositions (PLAN §18.2 / §19 child-before-exec
    //    column). The shell may have ignored or caught these; child must
    //    inherit defaults regardless of execution mode.
    resetSignalDefaults();

    // 3) Close caller-specified extra fds (typically unused pipe ends).
    for (req.extra_close) |fd| _ = std.c.close(fd);

    // 4) Apply redirects in source order.
    for (req.redirects) |op| applyRedirectOp(op) catch _exit(126);

    // 5) Dispatch.
    switch (req.action) {
        .exec => |e| {
            _ = std.c.execve(e.path, e.argv, e.envp);
            // If execve returns, it failed. errno tells us why.
            const errno = std.c.errno(@as(c_int, -1));
            const code: u8 = switch (errno) {
                .ACCES => 126,
                .NOENT => 127,
                else => 127,
            };
            _exit(code);
        },
        .builtin_child => |b| {
            const code = b.run(b.ctx);
            _exit(code);
        },
    }
}

fn applyRedirectOp(op: RedirectOp) Error!void {
    switch (op) {
        .dup => |d| {
            if (std.c.dup2(d.src, d.dst) < 0) return Error.Dup2Failed;
        },
        .close => |fd| {
            _ = std.c.close(fd);
        },
        .file => |f| {
            const flags: std.c.O = switch (f.mode) {
                .read => .{ .ACCMODE = .RDONLY },
                .write => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                .both_write => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                .both_append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            };
            // Mode 0644 for newly created files.
            const opened = std.c.open(f.path, flags, @as(std.c.mode_t, 0o644));
            if (opened < 0) return Error.OpenFailed;
            switch (f.mode) {
                .both_write, .both_append => {
                    if (std.c.dup2(opened, 1) < 0) return Error.Dup2Failed;
                    if (std.c.dup2(opened, 2) < 0) return Error.Dup2Failed;
                },
                else => {
                    if (std.c.dup2(opened, f.dst) < 0) return Error.Dup2Failed;
                },
            }
            _ = std.c.close(opened);
        },
    }
}

// =============================================================================
// Pipes, fds, signals
// =============================================================================

/// Create a pipe with FD_CLOEXEC set on both ends. The shell explicitly
/// dups the ends it wants into stdin/stdout/stderr in each child; CLOEXEC
/// keeps stale ends out of execve'd children.
pub fn makePipe() Error![2]Fd {
    var fds: [2]Fd = undefined;
    if (std.c.pipe(&fds) != 0) return Error.PipeFailed;
    setCloexec(fds[0]);
    setCloexec(fds[1]);
    return fds;
}

fn setCloexec(fd: Fd) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFD);
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFD, flags | std.c.FD_CLOEXEC);
}

/// Drop FD_CLOEXEC on a fd so it survives `execve`. Process
/// substitution needs this for the pipe end the user-named child
/// will inherit; pipeline plumbing keeps CLOEXEC because those ends
/// are only for the immediate child.
pub fn clearCloexec(fd: Fd) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFD);
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFD, flags & ~@as(c_int, std.c.FD_CLOEXEC));
}

pub fn closeFd(fd: Fd) void {
    _ = std.c.close(fd);
}

pub fn setPgid(pid: Pid, pgid: Pid) Error!void {
    if (std.c.setpgid(pid, pgid) != 0) return Error.SetPgidFailed;
}

/// Hand the controlling terminal's foreground process group to `pgid`.
/// Best-effort: returns `false` on EBADF / ENOTTY (no controlling tty)
/// or any other failure. The shell is responsible for ignoring SIGTTOU
/// before calling this — otherwise it'd stop itself trying to set the
/// foreground group from a background context (PLAN §18 disposition
/// table).
pub fn tcSetPgrp(fd: Fd, pgid: Pid) bool {
    while (true) {
        const rc = tcsetpgrp(fd, pgid);
        if (rc == 0) return true;
        const e = std.c.errno(@as(c_int, -1));
        if (e == .INTR) continue;
        return false;
    }
}

/// Read the controlling terminal's current foreground process group, or
/// `null` if the fd has no controlling terminal (ENOTTY / EBADF).
pub fn tcGetPgrp(fd: Fd) ?Pid {
    const rc = tcgetpgrp(fd);
    if (rc < 0) return null;
    return rc;
}

/// Reset the disposition of signals the interactive shell typically catches
/// or ignores back to defaults, so children behave predictably.
fn resetSignalDefaults() void {
    const defaults = [_]std.c.SIG{
        .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD, .HUP,
    };
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (defaults) |sig| std.posix.sigaction(sig, &sa, null);
}

// =============================================================================
// Wait
// =============================================================================

pub const WaitEvent = struct {
    pid: Pid,
    state: runtime.ChildState,
};

pub const WaitOptions = struct {
    /// `null` = wait for any child; otherwise wait specifically for this pid.
    pid: ?Pid = null,
    blocking: bool,
    /// Report `.stopped` events too so the foreground wait loop can break
    /// out cleanly even when no fg/bg-driven resume is wired up.
    untraced: bool = true,
};

/// Returns `null` only when `blocking == false` and no child has changed
/// state. A blocking wait either returns an event or fails.
pub fn waitOne(opts: WaitOptions) Error!?WaitEvent {
    var status: c_int = 0;
    var flags: c_int = 0;
    if (!opts.blocking) flags |= std.c.W.NOHANG;
    if (opts.untraced) flags |= std.c.W.UNTRACED;
    const target_pid: Pid = opts.pid orelse -1;

    while (true) {
        const rc = std.c.waitpid(target_pid, &status, flags);
        if (rc == 0) return null; // WNOHANG, nothing ready
        if (rc < 0) {
            const errno = std.c.errno(rc);
            if (errno == .INTR) continue;
            if (errno == .CHILD) return null;
            return Error.WaitFailed;
        }
        return WaitEvent{
            .pid = rc,
            .state = runtime.decodeWaitStatus(status),
        };
    }
}

// =============================================================================
// Child exit (no return)
// =============================================================================

pub fn _exit(code: u8) noreturn {
    std.c._exit(@intCast(code));
}

// =============================================================================
// One-shot helper subprocess (POSIX plumbing only — no shell semantics)
// =============================================================================

pub const CaptureError = error{
    SpawnFailed,
    PipeFailed,
    TimedOut,
    OutputCap,
    ChildFailed,
    OutOfMemory,
};

/// Capture stdout from a short-lived helper subprocess. Used by callers
/// that need to consult an external tool synchronously and parse a small
/// reply (e.g. `carapace` for completion delegation, version probes).
/// NOT for jobs — jobs go through `spawn(req: SpawnRequest)` above.
///
/// Discipline:
///   - The child runs in its own process group so a SIGKILL on timeout
///     or output-cap overrun reaches grandchildren too (carapace may
///     shell out to git/docker/etc. to compute candidates).
///   - stdin is redirected from /dev/null; stderr is discarded.
///   - stdout is read until EOF, exit, `max_bytes`, or `timeout_ms`.
///
/// Returns the captured bytes on success (caller frees). A non-zero
/// child exit collapses to `ChildFailed` — callers that want the
/// partial output of failing helpers must adapt the contract.
pub fn spawnAndCapture(
    allocator: std.mem.Allocator,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    max_bytes: usize,
    timeout_ms: u32,
) CaptureError![]u8 {
    var pipe_fds: [2]Fd = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return CaptureError.PipeFailed;
    const r_fd = pipe_fds[0];
    const w_fd = pipe_fds[1];

    const rc = std.c.fork();
    if (rc < 0) {
        _ = std.c.close(r_fd);
        _ = std.c.close(w_fd);
        return CaptureError.SpawnFailed;
    }

    if (rc == 0) {
        // Child path. Errors here must _exit; do not throw or return.
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(r_fd);

        const devnull_path: [*:0]const u8 = "/dev/null";
        const devnull = std.c.open(devnull_path, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = std.c.dup2(w_fd, 1);
        _ = std.c.close(w_fd);

        resetSignalDefaults();

        _ = std.c.execve(argv[0].?, argv, envp);
        _exit(127);
    }

    // Parent path.
    const child_pid: Pid = @intCast(rc);
    // Close the fork race on the child's pgrp (idempotent if child won).
    _ = std.c.setpgid(child_pid, child_pid);
    _ = std.c.close(w_fd);

    var out = std.ArrayList(u8).empty;
    var failure: ?CaptureError = null;

    const start_ms = monotonicMs();
    const deadline_ms = start_ms + @as(i64, @intCast(timeout_ms));

    poll_loop: while (true) {
        const now_ms = monotonicMs();
        const remaining = deadline_ms - now_ms;
        if (remaining <= 0) {
            failure = CaptureError.TimedOut;
            break :poll_loop;
        }

        var pfd: std.c.pollfd = .{ .fd = r_fd, .events = std.c.POLL.IN, .revents = 0 };
        const pr = std.c.poll(@ptrCast(&pfd), 1, @intCast(remaining));
        if (pr < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            failure = CaptureError.SpawnFailed;
            break :poll_loop;
        }
        if (pr == 0) {
            failure = CaptureError.TimedOut;
            break :poll_loop;
        }

        if ((pfd.revents & std.c.POLL.IN) != 0) {
            const room = if (max_bytes > out.items.len) max_bytes - out.items.len else 0;
            if (room == 0) {
                failure = CaptureError.OutputCap;
                break :poll_loop;
            }
            const want = @min(room, @as(usize, 4096));
            const old = out.items.len;
            out.resize(allocator, old + want) catch {
                failure = CaptureError.OutOfMemory;
                break :poll_loop;
            };
            const n_rc = std.c.read(r_fd, out.items.ptr + old, want);
            if (n_rc < 0) {
                const e = std.c.errno(@as(c_int, -1));
                out.shrinkRetainingCapacity(old);
                if (e == .INTR) continue;
                failure = CaptureError.SpawnFailed;
                break :poll_loop;
            }
            const n: usize = @intCast(n_rc);
            out.shrinkRetainingCapacity(old + n);
            if (n == 0) break :poll_loop; // EOF
        } else {
            // POLLHUP / POLLERR with no readable bytes — child closed.
            break :poll_loop;
        }
    }

    _ = std.c.close(r_fd);

    if (failure) |_| {
        // Kill the whole pgrp so grandchildren are reaped too.
        _ = std.c.kill(-child_pid, std.c.SIG.KILL);
    }

    // Reap the child unconditionally so it doesn't zombify.
    var status: c_int = 0;
    while (true) {
        const wr = std.c.waitpid(child_pid, &status, 0);
        if (wr >= 0) break;
        const e = std.c.errno(@as(c_int, -1));
        if (e == .INTR) continue;
        break;
    }

    if (failure) |err| {
        out.deinit(allocator);
        return err;
    }

    const ux: u32 = @bitCast(status);
    if (!std.c.W.IFEXITED(ux) or std.c.W.EXITSTATUS(ux) != 0) {
        out.deinit(allocator);
        return CaptureError.ChildFailed;
    }

    return out.toOwnedSlice(allocator) catch CaptureError.OutOfMemory;
}

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "Result types compile and link" {
    // smoke
    _ = makePipe;
    _ = spawn;
    _ = waitOne;
}
