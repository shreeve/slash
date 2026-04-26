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

test "Result types compile and link" {
    // smoke
    _ = makePipe;
    _ = spawn;
    _ = waitOne;
}
