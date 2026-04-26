//! eval — the only module that knows shell semantics.
//!
//! Evaluation contracts:
//!
//!   - Every `evalProgram` returns exactly one `Job` and one
//!     `expression_result`.
//!   - For non-detached forms, `expression_result == job.result.?` after
//!     wait/service completion.
//!   - For detached forms, `expression_result` reflects launch
//!     success/failure, not eventual completion.
//!   - Sequence/`&&`/`||` consult only `expression_result`.
//!   - Job-control builtins consult `Job.state`/`Job.result`.
//!   - Only successfully launched detached jobs are inserted into
//!     `session.jobs`.
//!
//! Word expansion happens once per word during evaluation. A materialized
//! argv element is never re-scanned for variables, command substitution,
//! or globs. The Word→argv boundary is a one-way gate.

const std = @import("std");
const shape_mod = @import("shape.zig");
const program_mod = @import("program.zig");
const word_mod = @import("word.zig");
const diag = @import("diagnostics.zig");
const runtime = @import("runtime.zig");
const exec = @import("exec.zig");
const job = @import("job.zig");
const builtins = @import("builtins.zig");
const session_mod = @import("session.zig");
const vars_mod = @import("vars.zig");

pub const Allocator = std.mem.Allocator;
pub const Result = runtime.Result;
pub const Sink = diag.Sink;
pub const Session = session_mod.Session;
pub const Job = job.Job;
const Program = program_mod.Program;
const Command = program_mod.Command;
const Word = word_mod.Word;
const Redirect = program_mod.Redirect;

// =============================================================================
// EvalContext / EvalOutcome
// =============================================================================

pub const EvalContext = struct {
    /// `true` means the evaluation is happening inside a forked child
    /// (pipeline stage, subshell body, detached body). Disqualifies the
    /// zero-child Job optimization for Command nodes.
    in_child_context: bool = false,
    /// Per-run scratch arena.
    scratch: Allocator,
};

const EvalOutcome = struct {
    job: *Job,
    expression_result: Result,
};

/// Thrown by `break`/`continue` builtins; caught by loop evaluators.
const LoopControl = error{
    BreakLoop,
    ContinueLoop,
};

// =============================================================================
// Public entry points
// =============================================================================

pub fn runForeground(
    prog: *const Program,
    session: *Session,
    scratch: Allocator,
    sink: ?Sink,
) !Result {
    const outcome = try evalProgram(prog, session, .{ .scratch = scratch }, sink);
    job.service(&session.jobs, .poll, null) catch {};
    session.last_status = outcome.expression_result.toStatusByte();
    return outcome.expression_result;
}

pub fn run(
    prog: *const Program,
    session: *Session,
    scratch: Allocator,
    sink: ?Sink,
) !*Job {
    const outcome = try evalProgram(prog, session, .{ .scratch = scratch }, sink);
    return outcome.job;
}

// =============================================================================
// Dispatch
// =============================================================================

fn evalProgram(
    prog: *const Program,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    const outcome: EvalOutcome = switch (prog.*) {
        .command => |c| try evalCommand(&c, session, ctx, sink),
        .pipeline => |p| try evalPipeline(p, session, ctx, sink),
        .sequence => |s| try evalSequence(s, session, ctx, sink),
        .subshell => |s| try evalSubshell(s, session, ctx, sink),
        .block => |b| try evalBlock(b, session, ctx, sink),
        .detached => |d| try evalDetached(d, session, ctx, sink),
        .assigns => |a| try evalAssigns(a, session, ctx, sink),
        .conditional => |c| try evalConditional(c, session, ctx, sink),
        .@"while" => |w| try evalWhile(w, session, ctx, sink),
        .@"for" => |f| try evalFor(f, session, ctx, sink),
        .define => |d| try evalDefine(d, session, ctx, sink),
    };
    // `$?` reflects the most recent command result. Every program node
    // updates it on completion so subsequent statements in the same
    // sequence (or condition / body) observe the correct value.
    session.last_status = outcome.expression_result.toStatusByte();
    return outcome;
}

// =============================================================================
// Command
// =============================================================================

fn evalCommand(
    c: *const Command,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    // Expand exe and args first.
    const exe_text = try expandWordToScalar(c.exe, session, ctx.scratch, sink);
    if (exe_text.len == 0) {
        try diag.emit(sink, diag.make(
            .eval, .@"error", "EV0001",
            "command name expanded to empty",
            .{ .name = "<eval>", .text = "" }, c.span,
        ));
        return makeFailedOutcome(session, "<empty>", .{ .exited = 127 });
    }

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(ctx.scratch);
    try argv.append(ctx.scratch, exe_text);
    for (c.args) |arg| {
        try expandWordToArgv(arg, session, ctx.scratch, &argv);
    }

    // Build envp for the spawn: session exports + command-scoped env-prefix.
    const local_env = if (c.env.len > 0)
        try buildLocalEnv(c.env, session, ctx.scratch)
    else
        null;

    // Shell-context builtin path (zero-child Job).
    //
    // Env-prefixes still require a forked child so the override doesn't
    // leak into the parent shell. Redirects, however, can be applied to
    // the parent fd table around a tightly-scoped builtin call (PLAN §7
    // Rule 23) — that's how `read NAME < file` keeps the assignment.
    if (!ctx.in_child_context and c.env.len == 0) {
        // `source` / `.` are special: they re-enter the parse/lower/eval
        // pipeline on a file's contents in shell context. They can't be
        // ordinary builtins because a builtin can't import eval without
        // a module cycle; the dispatch happens here instead.
        if (std.mem.eql(u8, exe_text, "source") or std.mem.eql(u8, exe_text, ".")) {
            return try runSourceCommand(argv.items, session, ctx, sink);
        }
        // `exec` replaces the shell process with the named program — it
        // necessarily breaks the "builtins never call exec" rule (PLAN
        // §7 Rule 19), which is why it's special-cased here rather than
        // sitting in the regular builtin table.
        if (std.mem.eql(u8, exe_text, "exec")) {
            return try runExecCommand(c, argv.items, session, ctx, sink);
        }
        // `command` skips the builtin lookup so the user can force the
        // external command of the same name. Other than that, behaves
        // like any external invocation.
        if (std.mem.eql(u8, exe_text, "command")) {
            if (argv.items.len < 2) {
                return makeFailedOutcome(session, "command", .{ .exited = 0 });
            }
            return try runExternalForced(c, argv.items[1..], session, ctx, sink);
        }
        if (session.builtins.lookup(exe_text)) |b| {
            if (c.redirects.len == 0) {
                return try runShellContextBuiltin(c, b, argv.items, session);
            }
            return try runShellContextBuiltinWithRedirects(c, b, argv.items, session, ctx, sink);
        }
        if (session.defs.lookup(exe_text)) |def_body| {
            return try runUserDefinedCommand(c, def_body, argv.items, session, ctx, sink);
        }
    }

    return try runExternalSingle(c, argv.items, local_env, session, ctx, sink);
}

fn runShellContextBuiltin(
    c: *const Command,
    b: builtins.Builtin,
    argv: []const []const u8,
    session: *Session,
) !EvalOutcome {
    _ = c;
    const j = try session.jobs.create(true, false, argv[0]);
    j.state = .running;
    const io: builtins.BuiltinIo = .{ .stdin = 0, .stdout = 1, .stderr = 2 };
    const result = try b.run(argv, io, .{ .shell = session });
    session.jobs.completeZeroChild(j, result);
    return .{ .job = j, .expression_result = result };
}

/// Run a shell-context builtin with file/dup redirects applied to the
/// parent's fd table. Each affected fd is `dup`'d before mutation so we
/// can restore it after the builtin returns. PLAN §7 Rule 23 carves
/// this out as the one place the parent shell's fds may be mutated.
fn runShellContextBuiltinWithRedirects(
    c: *const Command,
    b: builtins.Builtin,
    argv: []const []const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const ops = try buildRedirectOps(ctx.scratch, c.redirects, session);

    const SavedFd = struct { saved_fd: i32, target_fd: i32 };
    var saved = std.ArrayListUnmanaged(SavedFd).empty;
    defer saved.deinit(ctx.scratch);

    const restore = struct {
        fn run(items: []const SavedFd) void {
            // Restore in reverse order so a redirect that touched the
            // same target as a later one ends up with the right state.
            var i: usize = items.len;
            while (i > 0) {
                i -= 1;
                _ = std.c.dup2(items[i].saved_fd, items[i].target_fd);
                _ = std.c.close(items[i].saved_fd);
            }
        }
    }.run;

    for (ops) |op| {
        var fd_buf: [2]exec.Fd = undefined;
        const target_fds = redirectTargetFds(op, &fd_buf);
        for (target_fds) |target_fd| {
            const dup_fd = std.c.dup(target_fd);
            // EBADF means the target wasn't open in the first place; we
            // skip the save (and rely on the application step to install
            // the redirect into a fresh slot). Other errors abort with
            // the prior saves restored.
            if (dup_fd >= 0) try saved.append(ctx.scratch, .{ .saved_fd = dup_fd, .target_fd = target_fd });
        }
        applyRedirInParent(op) catch {
            try diag.emit(sink, diag.make(
                .exec, .@"error", "EX0003",
                "redirect failed", .{ .name = "<eval>", .text = "" }, c.span,
            ));
            restore(saved.items);
            return makeFailedOutcome(session, argv[0], .{ .exited = 1 });
        };
    }

    const j = try session.jobs.create(true, false, argv[0]);
    j.state = .running;
    const io: builtins.BuiltinIo = .{ .stdin = 0, .stdout = 1, .stderr = 2 };
    const result = b.run(argv, io, .{ .shell = session }) catch |err| switch (err) {
        error.BreakLoop, error.ContinueLoop, error.ReturnFromCmd => {
            restore(saved.items);
            return err;
        },
        else => Result{ .exited = 1 },
    };
    restore(saved.items);
    session.jobs.completeZeroChild(j, result);
    return .{ .job = j, .expression_result = result };
}

/// Fds touched by a single redirect — `both_*` modes affect fds 1 AND
/// 2; everything else is one fd. The caller passes a 2-slot scratch
/// array; the returned slice points into it.
fn redirectTargetFds(op: exec.RedirectOp, buf: *[2]exec.Fd) []const exec.Fd {
    switch (op) {
        .dup => |d| {
            buf[0] = d.dst;
            return buf[0..1];
        },
        .close => |fd| {
            buf[0] = fd;
            return buf[0..1];
        },
        .file => |f| switch (f.mode) {
            .both_write, .both_append => {
                buf[0] = 1;
                buf[1] = 2;
                return buf[0..2];
            },
            else => {
                buf[0] = f.dst;
                return buf[0..1];
            },
        },
    }
}

/// Parent-safe variant of `applyRedirInChild`. Returns errors instead of
/// `_exit`-ing — the caller restores fds on failure.
fn applyRedirInParent(op: exec.RedirectOp) !void {
    switch (op) {
        .dup => |d| {
            if (std.c.dup2(d.src, d.dst) < 0) return error.Dup2Failed;
        },
        .close => |fd| {
            _ = std.c.close(fd);
        },
        .file => |f| {
            const flags: std.c.O = switch (f.mode) {
                .read => .{ .ACCMODE = .RDONLY },
                .write, .both_write => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                .append, .both_append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            };
            const opened = std.c.open(f.path, flags, @as(std.c.mode_t, 0o644));
            if (opened < 0) return error.OpenFailed;
            switch (f.mode) {
                .both_write, .both_append => {
                    if (std.c.dup2(opened, 1) < 0) {
                        _ = std.c.close(opened);
                        return error.Dup2Failed;
                    }
                    if (std.c.dup2(opened, 2) < 0) {
                        _ = std.c.close(opened);
                        return error.Dup2Failed;
                    }
                },
                else => {
                    if (std.c.dup2(opened, f.dst) < 0) {
                        _ = std.c.close(opened);
                        return error.Dup2Failed;
                    }
                },
            }
            _ = std.c.close(opened);
        },
    }
}

/// Invoke a user-defined `cmd` body with positional parameters bound to
/// the call's argv. Saves the caller's positional state, installs new
/// `$1..$N` / `$#` / `$@`, evaluates the body, then restores. A `return
/// N` builtin in the body raises `error.ReturnFromCmd`; the call frame
/// here catches it and translates to a normal exit status.
///
/// State not saved: anything else the body mutates (regular vars, defs,
/// cwd, exports). PLAN §7 Rule 26 makes user commands session-scoped,
/// so these mutations are visible to subsequent statements — that's the
/// difference between a `cmd` and a subshell.
fn runUserDefinedCommand(
    c: *const Command,
    body: *const program_mod.Program,
    argv: []const []const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    _ = c;

    // Snapshot positional params so the call frame can restore them. We
    // only need to capture what's in scope: `$0..$#` and `$@`.
    const snapshot = try snapshotPositionals(session, ctx.scratch);
    defer restorePositionals(session, snapshot, ctx.scratch);

    // Install the call's argv as $0/$1/$.../@/#.
    try installPositionals(session, argv);

    const outcome = evalProgram(body, session, ctx, sink) catch |err| switch (err) {
        error.ReturnFromCmd => {
            const j = try session.jobs.create(true, false, argv[0]);
            const result = Result{ .exited = session.last_status };
            session.jobs.completeZeroChild(j, result);
            return .{ .job = j, .expression_result = result };
        },
        else => return err,
    };
    return outcome;
}

const Positional = struct {
    name: []const u8,
    value: ?vars_mod.Value,
};

fn snapshotPositionals(session: *Session, scratch: Allocator) ![]Positional {
    var saved = std.ArrayListUnmanaged(Positional).empty;
    defer saved.deinit(scratch);

    const names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "@" };
    for (names) |name| {
        const dup = try scratch.dupe(u8, name);
        if (session.vars.get(name)) |v| {
            const cloned: vars_mod.Value = switch (v.value) {
                .scalar => |s| .{ .scalar = try scratch.dupe(u8, s) },
                .list => |xs| blk: {
                    var arr = try scratch.alloc([]const u8, xs.len);
                    for (xs, 0..) |e, i| arr[i] = try scratch.dupe(u8, e);
                    break :blk .{ .list = arr };
                },
            };
            try saved.append(scratch, .{ .name = dup, .value = cloned });
        } else {
            try saved.append(scratch, .{ .name = dup, .value = null });
        }
    }
    return saved.toOwnedSlice(scratch);
}

fn restorePositionals(session: *Session, snapshot: []Positional, scratch: Allocator) void {
    _ = scratch; // entries live in scratch; arena cleanup releases them
    for (snapshot) |entry| {
        if (entry.value) |v| switch (v) {
            .scalar => |s| session.vars.setScalar(entry.name, s, false) catch {},
            .list => |xs| session.vars.setList(entry.name, xs, false) catch {},
        } else {
            session.vars.unset(entry.name);
        }
    }
}

fn installPositionals(session: *Session, argv: []const []const u8) !void {
    // `$0` is the command's own name; `$1..$N` are the rest.
    try session.vars.setScalar("0", argv[0], false);
    var i: usize = 1;
    while (i <= 9) : (i += 1) {
        var keybuf: [4]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{i}) catch continue;
        if (i < argv.len) {
            try session.vars.setScalar(key, argv[i], false);
        } else {
            session.vars.unset(key);
        }
    }
    var countbuf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&countbuf, "{d}", .{argv.len -| 1}) catch unreachable;
    try session.vars.setScalar("#", count, false);
    if (argv.len > 1) {
        try session.vars.setList("@", argv[1..], false);
    } else {
        session.vars.unset("@");
    }
}

/// `exec CMD ARGS...` replaces the running shell process with `CMD`.
/// On success, this function does not return: `execve` overwrites the
/// process image. On failure (resolution miss, permission denied), it
/// emits a diagnostic and returns a failed outcome — the shell stays
/// alive, which is the safer of the two POSIX behaviors.
///
/// `exec` with no arguments at all is a no-op success (the redirects-
/// only form would need to mutate parent fds permanently; that is a
/// future change deferred behind a clean redirect-application API).
fn runExecCommand(
    c: *const Command,
    argv: []const []const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    if (argv.len < 2) {
        return makeFailedOutcome(session, "exec", .{ .exited = 0 });
    }

    const exe_text = argv[1];
    const rest = argv[2..];
    var spawn_argv = std.ArrayListUnmanaged([]const u8).empty;
    defer spawn_argv.deinit(ctx.scratch);
    try spawn_argv.append(ctx.scratch, exe_text);
    for (rest) |a| try spawn_argv.append(ctx.scratch, a);

    const path_z = try resolvePath(session, ctx.scratch, exe_text);
    const argv_z = try buildArgvZ(ctx.scratch, spawn_argv.items);
    const envp = blk: {
        const built = try buildLocalEnv(&.{}, session, ctx.scratch);
        break :blk built orelse session.envp;
    };

    _ = std.c.execve(path_z, argv_z, envp);
    const errno = std.c.errno(@as(c_int, -1));
    const reason: []const u8 = switch (errno) {
        .ACCES => "permission denied",
        .NOENT => "no such file or directory",
        else => "exec failed",
    };
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "exec: {s}: {s}\n", .{ exe_text, reason }) catch "exec: failed\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    try diag.emit(sink, diag.make(
        .exec, .@"error", "EX0001",
        reason,
        .{ .name = "<eval>", .text = "" }, c.span,
    ));
    const code: u8 = switch (errno) {
        .ACCES => 126,
        .NOENT => 127,
        else => 127,
    };
    return makeFailedOutcome(session, exe_text, .{ .exited = code });
}

/// `command NAME ARGS...` — run NAME as an external command, bypassing
/// the builtin lookup. Resolves NAME via the regular PATH search.
fn runExternalForced(
    c: *const Command,
    argv: []const []const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    return try runExternalSingle(c, argv, null, session, ctx, sink);
}

/// Implementation of the `source` / `.` builtin. Reads the named file,
/// parses, lowers, and evaluates it in shell context — no fork. The
/// final result is the result of the last top-level statement that ran;
/// I/O failures and parse/lower failures surface as exit 1 with a
/// diagnostic. The sourced script sees the calling session's variables
/// and may mutate them.
fn runSourceCommand(
    argv: []const []const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    if (argv.len < 2) {
        const msg = "source: filename required\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        return makeFailedOutcome(session, argv[0], .{ .exited = 2 });
    }
    const path = argv[1];

    const src = readFileToBuffer(path, ctx.scratch) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "source: {s}: {s}\n",
            .{ path, @errorName(err) },
        ) catch "source: cannot read file\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        return makeFailedOutcome(session, argv[0], .{ .exited = 1 });
    };

    const source = diag.Source{ .name = path, .text = src };
    const parsed = shape_mod.parse(source, ctx.scratch, sink) catch {
        return makeFailedOutcome(session, argv[0], .{ .exited = 1 });
    };
    const low_ctx = program_mod.LowerContext{ .alloc = ctx.scratch, .source = source };
    const inner_prog = program_mod.lower(parsed.root, &low_ctx, sink) catch {
        return makeFailedOutcome(session, argv[0], .{ .exited = 1 });
    };

    return try evalProgram(inner_prog, session, ctx, sink);
}

const max_source_size: usize = 64 * 1024 * 1024;

fn readFileToBuffer(path: []const u8, scratch: Allocator) ![]const u8 {
    const path_z = try scratch.dupeZ(u8, path);
    defer scratch.free(path_z);

    const fd = std.c.open(
        path_z.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        @as(std.c.mode_t, 0),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(scratch);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        try buf.appendSlice(scratch, chunk[0..@intCast(n)]);
        if (buf.items.len > max_source_size) return error.FileTooLarge;
    }

    var bytes = try buf.toOwnedSlice(scratch);
    // Skip a leading shebang line if present.
    if (bytes.len >= 2 and bytes[0] == '#' and bytes[1] == '!') {
        const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        const start = if (nl < bytes.len) nl + 1 else bytes.len;
        const remaining = try scratch.dupe(u8, bytes[start..]);
        scratch.free(bytes);
        bytes = remaining;
    }
    return bytes;
}

fn runExternalSingle(
    c: *const Command,
    argv: []const []const u8,
    local_env: ?[*:null]const ?[*:0]const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const action = try buildAction(argv[0], argv, local_env, session, ctx.scratch);
    var heredoc_fds = std.ArrayListUnmanaged(exec.Fd).empty;
    defer heredoc_fds.deinit(ctx.scratch);
    const redirs = try buildRedirectOpsAndCollectHeredocs(ctx.scratch, c.redirects, session, &heredoc_fds);
    const pid = exec.spawn(.{
        .redirects = redirs,
        .extra_close = &.{},
        .pgid = 0,
        .action = action,
    }) catch |err| {
        for (heredoc_fds.items) |fd| exec.closeFd(fd);
        const msg = std.fmt.allocPrint(
            ctx.scratch,
            "spawn `{s}` failed: {s}",
            .{ argv[0], @errorName(err) },
        ) catch "spawn failed";
        try diag.emit(sink, diag.make(
            .exec, .@"error", "EX0001",
            msg, .{ .name = "<eval>", .text = "" }, c.span,
        ));
        return makeFailedOutcome(session, argv[0], .{ .exited = 127 });
    };
    // Close the parent's copies of any heredoc pipe read ends now that
    // the child has them; the alternative is a slow fd leak per heredoc
    // every command run.
    for (heredoc_fds.items) |fd| exec.closeFd(fd);

    const j = try session.jobs.create(true, false, argv[0]);
    var pids = [_]exec.Pid{pid};
    try session.jobs.setProcesses(j, pid, &pids);
    try job.service(&session.jobs, .foreground, j);
    session.drainProcSubs();
    const result: Result = j.result orelse Result{ .exited = 1 };
    return .{ .job = j, .expression_result = result };
}

// =============================================================================
// Pipeline
// =============================================================================

fn evalPipeline(
    p: program_mod.Pipeline,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const n = p.stages.len;
    std.debug.assert(n >= 2);

    var pipes = try ctx.scratch.alloc([2]exec.Fd, n - 1);
    var made: usize = 0;
    while (made < n - 1) : (made += 1) pipes[made] = try exec.makePipe();

    var pids = try ctx.scratch.alloc(exec.Pid, n);
    var leader_pgid: exec.Pid = 0;

    var heredoc_fds = std.ArrayListUnmanaged(exec.Fd).empty;
    defer heredoc_fds.deinit(ctx.scratch);

    for (p.stages, 0..) |stage_prog, i| {
        const stage_cmd = switch (stage_prog.*) {
            .command => |*cc| cc,
            else => {
                try diag.emit(sink, diag.make(
                    .eval, .@"error", "EV0010",
                    "pipeline stage must be a command",
                    .{ .name = "<eval>", .text = "" }, stage_prog.span(),
                ));
                return error.UnsupportedPipelineStage;
            },
        };

        const exe_text = try expandWordToScalar(stage_cmd.exe, session, ctx.scratch, sink);
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(ctx.scratch);
        try argv.append(ctx.scratch, exe_text);
        for (stage_cmd.args) |a| try expandWordToArgv(a, session, ctx.scratch, &argv);

        var redirs = std.ArrayListUnmanaged(exec.RedirectOp).empty;
        defer redirs.deinit(ctx.scratch);
        if (i > 0) try redirs.append(ctx.scratch, .{ .dup = .{ .src = pipes[i - 1][0], .dst = 0 } });
        if (i < n - 1) try redirs.append(ctx.scratch, .{ .dup = .{ .src = pipes[i][1], .dst = 1 } });
        const file_redirs = try buildRedirectOpsAndCollectHeredocs(ctx.scratch, stage_cmd.redirects, session, &heredoc_fds);
        try redirs.appendSlice(ctx.scratch, file_redirs);

        var extra_close = std.ArrayListUnmanaged(exec.Fd).empty;
        defer extra_close.deinit(ctx.scratch);
        for (pipes, 0..) |pipe, k| {
            if (i > 0 and k == i - 1) {
                try extra_close.append(ctx.scratch, pipe[1]);
            } else if (i < n - 1 and k == i) {
                try extra_close.append(ctx.scratch, pipe[0]);
            } else {
                try extra_close.append(ctx.scratch, pipe[0]);
                try extra_close.append(ctx.scratch, pipe[1]);
            }
        }

        const local_env = try buildLocalEnv(stage_cmd.env, session, ctx.scratch);
        const action = try buildAction(exe_text, argv.items, local_env, session, ctx.scratch);
        const pid = try exec.spawn(.{
            .redirects = try ctx.scratch.dupe(exec.RedirectOp, redirs.items),
            .extra_close = try ctx.scratch.dupe(exec.Fd, extra_close.items),
            .pgid = leader_pgid,
            .action = action,
        });
        pids[i] = pid;
        if (i == 0) leader_pgid = pid;
    }

    for (pipes) |pipe| {
        exec.closeFd(pipe[0]);
        exec.closeFd(pipe[1]);
    }
    for (heredoc_fds.items) |fd| exec.closeFd(fd);

    const j = try session.jobs.create(true, false, "<pipeline>");
    try session.jobs.setProcesses(j, leader_pgid, pids);
    try job.service(&session.jobs, .foreground, j);
    session.drainProcSubs();
    const result: Result = j.result orelse Result{ .exited = 1 };
    return .{ .job = j, .expression_result = result };
}

// =============================================================================
// Sequence
// =============================================================================

fn evalSequence(
    s: program_mod.Sequence,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    var last_result: Result = .{ .exited = 0 };
    var last_job: ?*Job = null;
    var skip_next = false;
    var i: usize = 0;
    while (i < s.items.len) : (i += 1) {
        const item = s.items[i];

        if (skip_next) {
            skip_next = decideSkip(last_result, item.next_op);
            continue;
        }

        // Safe point: between sequence items, fire any pending signal
        // traps before launching the next program. This is the spot
        // PLAN §19 calls out as "after each top-level item completes,
        // before starting the next".
        try fireSignalTraps(session, ctx, sink);

        const out = try evalProgram(item.program, session, ctx, sink);
        last_result = out.expression_result;
        last_job = out.job;

        job.service(&session.jobs, .poll, null) catch {};
        if (session.exit_request != null) break;

        try fireSignalTraps(session, ctx, sink);

        if (item.next_op) |op| {
            skip_next = !shouldRun(last_result, op);
        }
    }
    return .{ .job = last_job orelse blk: {
        const j = try session.jobs.create(true, false, "<empty>");
        session.jobs.completeZeroChild(j, .{ .exited = 0 });
        break :blk j;
    }, .expression_result = last_result };
}

/// Drain pending signal flags and run the registered trap programs.
/// Each trap fires at most once per sequence boundary; if its body
/// raises an error, we let it bubble. The trap body inherits the
/// surrounding context — same scratch allocator, same in-child flag —
/// so a trap inside a forked child still does the right thing.
const real_trap_signals = [_]session_mod.TrapSignal{
    .HUP, .INT, .QUIT, .TERM, .USR1, .USR2,
};

fn fireSignalTraps(session: *Session, ctx: EvalContext, sink: ?Sink) !void {
    for (real_trap_signals) |sig| {
        if (!session.traps.takePending(sig)) continue;
        const dispo = session.traps.lookup(sig);
        switch (dispo) {
            .run => |entry| {
                const out = evalProgram(entry.program, session, ctx, sink) catch |err| switch (err) {
                    error.BreakLoop, error.ContinueLoop, error.ReturnFromCmd => continue,
                    else => return err,
                };
                _ = out;
            },
            else => {},
        }
    }
}

/// Run the EXIT pseudo-signal trap if one is registered. Called by the
/// top-level entry point right before returning to the OS so cleanup
/// scripts get a last-call moment.
pub fn fireExitTrap(session: *Session, scratch: Allocator, sink: ?Sink) !void {
    const dispo = session.traps.lookup(.EXIT);
    switch (dispo) {
        .run => |entry| {
            const ctx: EvalContext = .{ .scratch = scratch };
            const out = evalProgram(entry.program, session, ctx, sink) catch |err| switch (err) {
                error.BreakLoop, error.ContinueLoop, error.ReturnFromCmd => return,
                else => return err,
            };
            _ = out;
        },
        else => {},
    }
}

fn shouldRun(prev: Result, op: program_mod.SequenceOp) bool {
    return switch (op) {
        .always => true,
        .and_then => prev.ok(),
        .or_else => !prev.ok(),
    };
}

fn decideSkip(last: Result, next_op: ?program_mod.SequenceOp) bool {
    if (next_op) |op| return !shouldRun(last, op);
    return false;
}

// =============================================================================
// Subshell / Block
// =============================================================================

fn evalSubshell(
    s: anytype,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const redirs = try buildRedirectOps(ctx.scratch, s.redirects, session);

    const rc = std.c.fork();
    if (rc < 0) {
        try diag.emit(sink, diag.make(
            .exec, .@"error", "EX0002",
            "fork failed", .{ .name = "<eval>", .text = "" }, s.span,
        ));
        return makeFailedOutcome(session, "<subshell>", .{ .exited = 127 });
    }

    if (rc == 0) {
        _ = std.c.setpgid(0, 0);
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const defaults = [_]std.c.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD, .HUP };
        for (defaults) |sig| std.posix.sigaction(sig, &sa, null);

        for (redirs) |op| applyRedirInChild(op);

        const body_outcome = evalProgram(s.body, session, .{
            .in_child_context = true,
            .scratch = ctx.scratch,
        }, sink) catch {
            exec._exit(127);
        };
        exec._exit(body_outcome.expression_result.toStatusByte());
    }

    const pid: exec.Pid = @intCast(rc);
    _ = std.c.setpgid(pid, pid);
    const j = try session.jobs.create(true, false, "<subshell>");
    var pids = [_]exec.Pid{pid};
    try session.jobs.setProcesses(j, pid, &pids);
    try job.service(&session.jobs, .foreground, j);
    const result: Result = j.result orelse Result{ .exited = 1 };
    return .{ .job = j, .expression_result = result };
}

/// `{ ... }` runs the body in the CURRENT shell context — variables,
/// directory, and other state mutations escape. Lowering normalizes
/// redirected blocks into subshells, so blocks reaching here have no
/// redirects.
fn evalBlock(
    b: anytype,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    return evalProgram(b.body, session, ctx, sink);
}

fn applyRedirInChild(op: exec.RedirectOp) void {
    switch (op) {
        .dup => |d| _ = std.c.dup2(d.src, d.dst),
        .close => |fd| _ = std.c.close(fd),
        .file => |f| {
            const flags: std.c.O = switch (f.mode) {
                .read => .{ .ACCMODE = .RDONLY },
                .write, .both_write => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                .append, .both_append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            };
            const opened = std.c.open(f.path, flags, @as(std.c.mode_t, 0o644));
            if (opened < 0) exec._exit(126);
            switch (f.mode) {
                .both_write, .both_append => {
                    _ = std.c.dup2(opened, 1);
                    _ = std.c.dup2(opened, 2);
                },
                else => _ = std.c.dup2(opened, f.dst),
            }
            _ = std.c.close(opened);
        },
    }
}

// =============================================================================
// Detached
// =============================================================================

fn evalDetached(
    d: anytype,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    switch (d.body.*) {
        .command, .pipeline => {},
        else => {
            try diag.emit(sink, diag.make(
                .eval, .@"error", "EV0011",
                "detached body must be a command or pipeline",
                .{ .name = "<eval>", .text = "" }, d.span,
            ));
            return makeFailedOutcome(session, "<detached>", .{ .exited = 127 });
        },
    }

    const child_ctx: EvalContext = .{ .in_child_context = false, .scratch = ctx.scratch };
    switch (d.body.*) {
        .command => |c| {
            const out = try spawnCommandNoWait(&c, session, child_ctx, sink);
            out.job.foreground = false;
            out.job.detached = true;
            return .{ .job = out.job, .expression_result = .{ .exited = 0 } };
        },
        .pipeline => |p| {
            const out = try spawnPipelineNoWait(p, session, child_ctx, sink);
            out.job.foreground = false;
            out.job.detached = true;
            return .{ .job = out.job, .expression_result = .{ .exited = 0 } };
        },
        else => unreachable,
    }
}

fn spawnCommandNoWait(
    c: *const Command,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const exe_text = try expandWordToScalar(c.exe, session, ctx.scratch, sink);
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(ctx.scratch);
    try argv.append(ctx.scratch, exe_text);
    for (c.args) |a| try expandWordToArgv(a, session, ctx.scratch, &argv);

    const local_env = try buildLocalEnv(c.env, session, ctx.scratch);
    const action = try buildAction(exe_text, argv.items, local_env, session, ctx.scratch);
    const redirs = try buildRedirectOps(ctx.scratch, c.redirects, session);

    const pid = exec.spawn(.{
        .redirects = redirs,
        .extra_close = &.{},
        .pgid = 0,
        .action = action,
    }) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.scratch,
            "spawn `{s}` failed: {s}",
            .{ exe_text, @errorName(err) },
        ) catch "spawn failed";
        try diag.emit(sink, diag.make(
            .exec, .@"error", "EX0001",
            msg, .{ .name = "<eval>", .text = "" }, c.span,
        ));
        return error.SpawnFailed;
    };

    const j = try session.jobs.create(false, true, exe_text);
    var pids = [_]exec.Pid{pid};
    try session.jobs.setProcesses(j, pid, &pids);
    return .{ .job = j, .expression_result = .{ .exited = 0 } };
}

fn spawnPipelineNoWait(
    p: program_mod.Pipeline,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    _ = sink;
    const n = p.stages.len;
    var pipes = try ctx.scratch.alloc([2]exec.Fd, n - 1);
    var made: usize = 0;
    while (made < n - 1) : (made += 1) pipes[made] = try exec.makePipe();
    var pids = try ctx.scratch.alloc(exec.Pid, n);
    var leader_pgid: exec.Pid = 0;

    for (p.stages, 0..) |stage_prog, i| {
        const stage_cmd = switch (stage_prog.*) {
            .command => |*cc| cc,
            else => return error.UnsupportedPipelineStage,
        };

        const exe_text = try expandWordToScalar(stage_cmd.exe, session, ctx.scratch, null);
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(ctx.scratch);
        try argv.append(ctx.scratch, exe_text);
        for (stage_cmd.args) |a| try expandWordToArgv(a, session, ctx.scratch, &argv);

        var redirs = std.ArrayListUnmanaged(exec.RedirectOp).empty;
        defer redirs.deinit(ctx.scratch);
        if (i > 0) try redirs.append(ctx.scratch, .{ .dup = .{ .src = pipes[i - 1][0], .dst = 0 } });
        if (i < n - 1) try redirs.append(ctx.scratch, .{ .dup = .{ .src = pipes[i][1], .dst = 1 } });
        const file_redirs = try buildRedirectOps(ctx.scratch, stage_cmd.redirects, session);
        try redirs.appendSlice(ctx.scratch, file_redirs);

        var extra_close = std.ArrayListUnmanaged(exec.Fd).empty;
        defer extra_close.deinit(ctx.scratch);
        for (pipes, 0..) |pipe, k| {
            if (i > 0 and k == i - 1) {
                try extra_close.append(ctx.scratch, pipe[1]);
            } else if (i < n - 1 and k == i) {
                try extra_close.append(ctx.scratch, pipe[0]);
            } else {
                try extra_close.append(ctx.scratch, pipe[0]);
                try extra_close.append(ctx.scratch, pipe[1]);
            }
        }

        const local_env = try buildLocalEnv(stage_cmd.env, session, ctx.scratch);
        const action = try buildAction(exe_text, argv.items, local_env, session, ctx.scratch);
        const pid = try exec.spawn(.{
            .redirects = try ctx.scratch.dupe(exec.RedirectOp, redirs.items),
            .extra_close = try ctx.scratch.dupe(exec.Fd, extra_close.items),
            .pgid = leader_pgid,
            .action = action,
        });
        pids[i] = pid;
        if (i == 0) leader_pgid = pid;
    }

    for (pipes) |pipe| {
        exec.closeFd(pipe[0]);
        exec.closeFd(pipe[1]);
    }

    const j = try session.jobs.create(false, true, "<pipeline>");
    try session.jobs.setProcesses(j, leader_pgid, pids);
    return .{ .job = j, .expression_result = .{ .exited = 0 } };
}

// =============================================================================
// Assignments
// =============================================================================

fn evalDefine(
    d: program_mod.Define,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    _ = ctx;
    _ = sink;
    // Promote the body into a session-lifetime arena. The caller's parse
    // arena may be torn down (REPL turn boundary, sourced-file return,
    // etc.); cloning into a fresh arena keeps the definition addressable
    // for the life of the session.
    var arena = std.heap.ArenaAllocator.init(session.alloc);
    errdefer arena.deinit();
    const cloned = try program_mod.clone(d.body, arena.allocator());
    try session.defs.install(d.name, arena, cloned);

    const j = try session.jobs.create(true, false, d.name);
    session.jobs.completeZeroChild(j, .{ .exited = 0 });
    return .{ .job = j, .expression_result = .{ .exited = 0 } };
}

fn evalAssigns(
    a: program_mod.Assigns,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    _ = sink;
    for (a.binds) |b| try applyAssign(b, session, ctx.scratch);

    const j = try session.jobs.create(true, false, "<assign>");
    session.jobs.completeZeroChild(j, .{ .exited = 0 });
    return .{ .job = j, .expression_result = .{ .exited = 0 } };
}

fn applyAssign(
    b: program_mod.EnvBind,
    session: *Session,
    scratch: Allocator,
) !void {
    switch (b.value) {
        .scalar => |w| {
            // A bare `@(cmd)` on the RHS of an assignment captures as a
            // list, not a space-joined scalar. The whole point of `@(...)`
            // is to produce N fields, so honoring that here keeps the
            // result usable with `for x in $xs` and friends.
            if (w.parts.len == 1) {
                switch (w.parts[0]) {
                    .list_capture => |inner| {
                        const captured = try captureProgramStdout(inner, session, scratch);
                        const fields = try splitNewlineFields(scratch, captured);
                        defer scratch.free(fields);
                        try session.vars.setList(b.name, fields, false);
                        return;
                    },
                    else => {},
                }
            }
            const val = try expandWordToScalar(w, session, scratch, null);
            try session.vars.setScalar(b.name, val, false);
        },
        .list => |ws| {
            var items = std.ArrayListUnmanaged([]const u8).empty;
            defer items.deinit(scratch);
            for (ws) |w| try expandWordToArgv(w, session, scratch, &items);
            try session.vars.setList(b.name, items.items, false);
        },
    }
}

// =============================================================================
// Conditional / While / For
// =============================================================================

fn evalConditional(
    c: program_mod.Conditional,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    const cond_outcome = try evalProgram(c.cond, session, ctx, sink);
    if (cond_outcome.expression_result.ok()) {
        return try evalProgram(c.then_body, session, ctx, sink);
    }
    if (c.else_body) |eb| {
        return try evalProgram(eb, session, ctx, sink);
    }
    const j = try session.jobs.create(true, false, "<if>");
    session.jobs.completeZeroChild(j, .{ .exited = 0 });
    return .{ .job = j, .expression_result = .{ .exited = 0 } };
}

fn evalWhile(
    w: program_mod.While,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    var last_result: Result = .{ .exited = 0 };
    var last_job: ?*Job = null;

    while (true) {
        const cond_outcome = try evalProgram(w.cond, session, ctx, sink);
        if (!cond_outcome.expression_result.ok()) break;
        if (session.exit_request != null) break;

        const body_outcome = evalProgram(w.body, session, ctx, sink) catch |err| switch (err) {
            error.BreakLoop => break,
            error.ContinueLoop => continue,
            else => return err,
        };
        last_result = body_outcome.expression_result;
        last_job = body_outcome.job;
        if (session.exit_request != null) break;
    }

    return .{
        .job = last_job orelse blk: {
            const j = try session.jobs.create(true, false, "<while>");
            session.jobs.completeZeroChild(j, last_result);
            break :blk j;
        },
        .expression_result = last_result,
    };
}

fn evalFor(
    f: program_mod.For,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) anyerror!EvalOutcome {
    var items = std.ArrayListUnmanaged([]const u8).empty;
    defer items.deinit(ctx.scratch);
    for (f.items) |w| try expandWordToArgv(w, session, ctx.scratch, &items);

    var last_result: Result = .{ .exited = 0 };
    var last_job: ?*Job = null;

    for (items.items) |item| {
        try session.vars.setScalar(f.binding, item, false);
        const body_outcome = evalProgram(f.body, session, ctx, sink) catch |err| switch (err) {
            error.BreakLoop => break,
            error.ContinueLoop => continue,
            else => return err,
        };
        last_result = body_outcome.expression_result;
        last_job = body_outcome.job;
        if (session.exit_request != null) break;
    }

    return .{
        .job = last_job orelse blk: {
            const j = try session.jobs.create(true, false, "<for>");
            session.jobs.completeZeroChild(j, last_result);
            break :blk j;
        },
        .expression_result = last_result,
    };
}

// =============================================================================
// Word expansion
// =============================================================================

/// Expand a Word to a single scalar string. Used for command exes and
/// assign-value scalars. List-typed variables in the middle of a word are
/// joined with spaces (single-position case).
fn expandWordToScalar(
    word: Word,
    session: *Session,
    scratch: Allocator,
    sink: ?Sink,
) anyerror![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(scratch);
    for (word.parts) |part| try appendPartScalar(part, session, scratch, &buf, sink);
    return buf.toOwnedSlice(scratch);
}

fn appendPartScalar(
    part: Word.Part,
    session: *Session,
    scratch: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    sink: ?Sink,
) !void {
    switch (part) {
        .text => |t| try buf.appendSlice(scratch, t),
        .variable => |name| {
            if (try lookupSpecialOrVar(name, session, scratch)) |val| {
                try buf.appendSlice(scratch, val);
                scratch.free(val);
            }
        },
        .var_braced => |vb| {
            if (try lookupSpecialOrVar(vb.name, session, scratch)) |val| {
                if (val.len > 0) {
                    try buf.appendSlice(scratch, val);
                    scratch.free(val);
                    return;
                }
                scratch.free(val);
            }
            // Variable is unset OR resolved to the empty string. Fall back
            // to the default expression if the user wrote `??`.
            if (vb.default) |dw| {
                const def = try expandWordToScalar(dw.*, session, scratch, sink);
                try buf.appendSlice(scratch, def);
                scratch.free(def);
            }
        },
        .cmd_subst => |inner| {
            const captured = try captureProgramStdout(inner, session, scratch);
            try buf.appendSlice(scratch, captured);
        },
        .list_capture => |inner| {
            // In a scalar position, splice the list with single spaces.
            // The argv path handles the splicing case directly.
            const captured = try captureProgramStdout(inner, session, scratch);
            const fields = splitNewlineFields(scratch, captured) catch &[_][]const u8{};
            defer scratch.free(fields);
            var first = true;
            for (fields) |f| {
                if (!first) try buf.append(scratch, ' ');
                try buf.appendSlice(scratch, f);
                first = false;
            }
        },
        .proc_subst => |ps| {
            // Materialize the substitution: spawn the side child and
            // write the resulting `/dev/fd/N` path into the buffer.
            const path = try spawnProcSubst(ps.dir, ps.body, session, scratch);
            try buf.appendSlice(scratch, path);
        },
        .glob => |pat| try buf.appendSlice(scratch, pat),
    }
}

/// Expand a Word into argv elements. A list-typed variable splices as
/// multiple elements; a scalar contributes one element. Multi-part Words
/// where each part is a non-list contribute one concatenated element.
fn expandWordToArgv(
    word: Word,
    session: *Session,
    scratch: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    // If the word is a single-part variable that resolves to a list,
    // splice it. Otherwise concatenate parts into one argv element.
    if (word.parts.len == 1) {
        switch (word.parts[0]) {
            .variable => |name| {
                if (session.vars.get(name)) |v| switch (v.value) {
                    .list => |xs| {
                        for (xs) |s| try out.append(scratch, try scratch.dupe(u8, s));
                        return;
                    },
                    .scalar => |s| {
                        try out.append(scratch, try scratch.dupe(u8, s));
                        return;
                    },
                };
                if (try lookupSpecial(name, session, scratch)) |val| {
                    try out.append(scratch, val);
                    return;
                }
                // Undefined variable expands to empty string. Don't add.
                return;
            },
            .list_capture => |inner| {
                // `@(cmd)` as a single-part word splices its captured
                // stdout as N argv entries (one per non-empty newline-
                // separated field). PLAN §7 Rule 29 keeps the scalar
                // `$(...)` form distinct from this list capture.
                const captured = try captureProgramStdout(inner, session, scratch);
                const fields = try splitNewlineFields(scratch, captured);
                defer scratch.free(fields);
                for (fields) |f| try out.append(scratch, try scratch.dupe(u8, f));
                return;
            },
            else => {},
        }
    }

    // Per PLAN §7 Rule 9: words with at least one unquoted glob part
    // expand against the filesystem; matches splice as N argv entries
    // and a no-match leaves the literal pattern as one entry.
    if (wordHasGlob(word)) {
        const pattern = try expandWordToScalar(word, session, scratch, null);
        const matches = try expandGlob(pattern, scratch);
        if (matches.len == 0) {
            try out.append(scratch, pattern);
        } else {
            for (matches) |m| try out.append(scratch, m);
        }
        return;
    }

    const concat = try expandWordToScalar(word, session, scratch, null);
    try out.append(scratch, concat);
}

fn wordHasGlob(word: Word) bool {
    for (word.parts) |p| switch (p) {
        .glob => return true,
        else => {},
    };
    return false;
}

fn lookupSpecial(name: []const u8, session: *Session, scratch: Allocator) !?[]const u8 {
    if (name.len == 0) return null;
    // Magic params.
    if (std.mem.eql(u8, name, "?")) {
        return try std.fmt.allocPrint(scratch, "{d}", .{session.last_status});
    }
    if (std.mem.eql(u8, name, "$")) {
        return try std.fmt.allocPrint(scratch, "{d}", .{std.c.getpid()});
    }
    return null;
}

fn lookupSpecialOrVar(name: []const u8, session: *Session, scratch: Allocator) !?[]const u8 {
    if (try lookupSpecial(name, session, scratch)) |s| return s;
    if (session.vars.get(name)) |v| {
        return switch (v.value) {
            .scalar => |s| try scratch.dupe(u8, s),
            .list => |xs| try std.mem.join(scratch, " ", xs),
        };
    }
    return null;
}

// =============================================================================
// Helpers: env binds, action, redirects
// =============================================================================

/// Build the envp pointer for spawning a child. Always rebuilds from the
/// session's exported variables on top of the inherited process env, then
/// applies command-scoped env-prefix bindings on top. This is what makes
/// `export FOO=bar; cmd` see FOO=bar in the child's environment.
fn buildLocalEnv(
    env: []const program_mod.EnvBind,
    session: *Session,
    scratch: Allocator,
) !?[*:null]const ?[*:0]const u8 {
    var entries = std.ArrayListUnmanaged([]const u8).empty;
    defer entries.deinit(scratch);

    // Inherit non-overridden process env entries (anything not also in
    // session.vars as exported).
    var idx: usize = 0;
    while (true) {
        const e = session.envp[idx] orelse break;
        idx += 1;
        const slice = std.mem.span(e);
        const eq = std.mem.indexOfScalar(u8, slice, '=') orelse continue;
        const name = slice[0..eq];
        if (session.vars.get(name)) |v| {
            if (v.exported) continue; // session value will be added below
        }
        try entries.append(scratch, slice);
    }

    // Add session's exported variables.
    var var_it = session.vars.table.iterator();
    while (var_it.next()) |e| {
        if (!e.value_ptr.exported) continue;
        const value = switch (e.value_ptr.value) {
            .scalar => |s| try scratch.dupe(u8, s),
            .list => |xs| try std.mem.join(scratch, " ", xs),
        };
        try entries.append(scratch, try std.fmt.allocPrint(scratch, "{s}={s}", .{ e.key_ptr.*, value }));
    }

    // Apply env-prefix bindings (override exported and inherited).
    for (env) |b| {
        const value = switch (b.value) {
            .scalar => |w| try expandWordToScalar(w, session, scratch, null),
            .list => |ws| blk: {
                var parts = std.ArrayListUnmanaged([]const u8).empty;
                defer parts.deinit(scratch);
                for (ws) |w| try expandWordToArgv(w, session, scratch, &parts);
                break :blk try std.mem.join(scratch, " ", parts.items);
            },
        };
        const entry = try std.fmt.allocPrint(scratch, "{s}={s}", .{ b.name, value });
        const eq_pos = b.name.len + 1;
        var replaced = false;
        for (entries.items, 0..) |e, i| {
            if (e.len >= eq_pos and std.mem.eql(u8, e[0 .. eq_pos - 1], b.name) and e[eq_pos - 1] == '=') {
                entries.items[i] = entry;
                replaced = true;
                break;
            }
        }
        if (!replaced) try entries.append(scratch, entry);
    }

    const slots = try scratch.allocSentinel(?[*:0]const u8, entries.items.len, null);
    for (entries.items, 0..) |e, i| {
        const z = try scratch.dupeZ(u8, e);
        slots[i] = z.ptr;
    }
    return slots.ptr;
}

fn buildAction(
    exe_text: []const u8,
    argv_text: []const []const u8,
    local_env: ?[*:null]const ?[*:0]const u8,
    session: *Session,
    scratch: Allocator,
) !exec.ChildAction {
    if (session.builtins.lookup(exe_text)) |b| {
        const ctx = try scratch.create(BuiltinChildCtx);
        ctx.* = .{
            .run_fn = b.run,
            .argv = try scratch.dupe([]const u8, argv_text),
            .stdin = 0,
            .stdout = 1,
            .stderr = 2,
        };
        return .{ .builtin_child = .{ .run = builtinChildTrampoline, .ctx = ctx } };
    }

    const path_z = try resolvePath(session, scratch, exe_text);
    const argv_z = try buildArgvZ(scratch, argv_text);
    const envp = local_env orelse blk: {
        // Child inherits session-merged env even with no env-prefix.
        const built = try buildLocalEnv(&.{}, session, scratch);
        break :blk built orelse session.envp;
    };
    return .{ .exec = .{ .path = path_z, .argv = argv_z, .envp = envp } };
}

const BuiltinChildCtx = struct {
    run_fn: builtins.BuiltinFn,
    argv: []const []const u8,
    stdin: i32,
    stdout: i32,
    stderr: i32,
};

fn builtinChildTrampoline(raw: *const anyopaque) callconv(.c) u8 {
    const ctx: *const BuiltinChildCtx = @ptrCast(@alignCast(raw));
    const io: builtins.BuiltinIo = .{
        .stdin = ctx.stdin,
        .stdout = ctx.stdout,
        .stderr = ctx.stderr,
    };
    const result = ctx.run_fn(ctx.argv, io, .child) catch |err| switch (err) {
        // Control-flow signals don't cross a child boundary. `break` /
        // `continue` / `return` inside a forked stage just exit that
        // child; the parent's loop or call frame is unaffected.
        error.BreakLoop, error.ContinueLoop, error.ReturnFromCmd => Result{ .exited = 0 },
        else => Result{ .exited = 1 },
    };
    return result.toStatusByte();
}

fn buildArgvZ(scratch: Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const slots = try scratch.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| {
        const z = try scratch.dupeZ(u8, a);
        slots[i] = z.ptr;
    }
    return slots.ptr;
}

/// Resolve a bare command name to an absolute path by walking `$PATH`.
/// Names containing a `/` (`./script`, `/usr/bin/env`) skip the lookup
/// entirely. Successful lookups are cached on `session`; the cache is
/// dropped whenever `$PATH` changes (validated by string compare on
/// every call). The returned NUL-terminated string is allocated from
/// `scratch` so it always has the lifetime callers expect, even on a
/// cache hit.
fn resolvePath(session: *Session, scratch: Allocator, exe: []const u8) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, exe, '/') != null) {
        const z = try scratch.dupeZ(u8, exe);
        return z.ptr;
    }

    const path_str = session.refreshPathSignature() orelse {
        const z = try scratch.dupeZ(u8, exe);
        return z.ptr;
    };

    if (session.path_cache.get(exe)) |cached| {
        const z = try scratch.dupeZ(u8, cached);
        return z.ptr;
    }

    var it = std.mem.splitScalar(u8, path_str, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrintSentinel(
            scratch,
            "{s}/{s}",
            .{ dir, exe },
            0,
        );
        const rc = std.c.access(candidate.ptr, std.c.X_OK);
        if (rc == 0) {
            cachePathHit(session, exe, candidate);
            return candidate.ptr;
        }
    }

    const z = try scratch.dupeZ(u8, exe);
    return z.ptr;
}

fn cachePathHit(session: *Session, name: []const u8, candidate: [:0]const u8) void {
    const key = session.alloc.dupe(u8, name) catch return;
    const value = session.alloc.dupe(u8, candidate) catch {
        session.alloc.free(key);
        return;
    };
    session.path_cache.put(session.alloc, key, value) catch {
        session.alloc.free(key);
        session.alloc.free(value);
    };
}

fn buildRedirectOps(
    scratch: Allocator,
    reds: []const Redirect,
    session: *Session,
) ![]const exec.RedirectOp {
    return buildRedirectOpsAndCollectHeredocs(scratch, reds, session, null);
}

/// Variant of `buildRedirectOps` that also records every heredoc pipe
/// read end the caller is responsible for closing in the parent after
/// the spawn. Pass `null` for callers that don't fork (shell-context
/// builtin redirects close on their own).
fn buildRedirectOpsAndCollectHeredocs(
    scratch: Allocator,
    reds: []const Redirect,
    session: *Session,
    heredoc_fds: ?*std.ArrayListUnmanaged(exec.Fd),
) ![]const exec.RedirectOp {
    var out = std.ArrayListUnmanaged(exec.RedirectOp).empty;
    defer out.deinit(scratch);

    for (reds) |r| {
        switch (r.op) {
            .read => {
                const dst: exec.Fd = if (r.from_fd) |n| @intCast(n) else 0;
                const path = try wordToPathZ(scratch, r.target.?, session);
                try out.append(scratch, .{ .file = .{ .path = path, .mode = .read, .dst = dst } });
            },
            .write => {
                const dst: exec.Fd = if (r.from_fd) |n| @intCast(n) else 1;
                const path = try wordToPathZ(scratch, r.target.?, session);
                try out.append(scratch, .{ .file = .{ .path = path, .mode = .write, .dst = dst } });
            },
            .append => {
                const dst: exec.Fd = if (r.from_fd) |n| @intCast(n) else 1;
                const path = try wordToPathZ(scratch, r.target.?, session);
                try out.append(scratch, .{ .file = .{ .path = path, .mode = .append, .dst = dst } });
            },
            .both_write => {
                const path = try wordToPathZ(scratch, r.target.?, session);
                try out.append(scratch, .{ .file = .{ .path = path, .mode = .both_write, .dst = 1 } });
            },
            .both_append => {
                const path = try wordToPathZ(scratch, r.target.?, session);
                try out.append(scratch, .{ .file = .{ .path = path, .mode = .both_append, .dst = 1 } });
            },
            .dup => {
                const src: exec.Fd = if (r.to_fd) |n| @intCast(n) else 1;
                const dst: exec.Fd = if (r.from_fd) |n| @intCast(n) else 1;
                try out.append(scratch, .{ .dup = .{ .src = src, .dst = dst } });
            },
            .heredoc => {
                const dst: exec.Fd = if (r.from_fd) |n| @intCast(n) else 0;
                const payload = r.heredoc.?;
                const expanded = if (payload.interpolating)
                    try expandHeredocBody(payload.body, session, scratch)
                else
                    payload.body;
                const read_fd = try installHeredocPipe(expanded);
                try out.append(scratch, .{ .dup = .{ .src = read_fd, .dst = dst } });
                try out.append(scratch, .{ .close = read_fd });
                if (heredoc_fds) |fds| try fds.append(scratch, read_fd);
            },
        }
    }
    return out.toOwnedSlice(scratch);
}

/// Expand a heredoc body once at eval time. Variable refs (`$name`,
/// `${name}`, `$?`/`$@`/etc.) and command substitutions (`$(...)`)
/// resolve against the live session; literal text passes through.
/// Quoted-delimiter heredocs (`<<'TAG'`) skip this pass entirely so
/// their bodies stay byte-perfect.
fn expandHeredocBody(body: []const u8, session: *Session, scratch: Allocator) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(scratch);
    try buf.ensureTotalCapacity(scratch, body.len);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            const n = body[i + 1];
            if (n == '$' or n == '\\' or n == '`') {
                try buf.append(scratch, n);
                i += 2;
                continue;
            }
            try buf.append(scratch, c);
            i += 1;
            continue;
        }
        if (c == '$' and i + 1 < body.len) {
            const n = body[i + 1];
            if (n == '{') {
                var j = i + 2;
                while (j < body.len and body[j] != '}') : (j += 1) {}
                if (j < body.len) {
                    const name = std.mem.trim(u8, body[i + 2 .. j], " \t");
                    if (try lookupSpecialOrVar(name, session, scratch)) |val| {
                        try buf.appendSlice(scratch, val);
                        scratch.free(val);
                    }
                    i = j + 1;
                    continue;
                }
            }
            if (n == '(') {
                var depth: u32 = 1;
                var j = i + 2;
                while (j < body.len) : (j += 1) {
                    const ch = body[j];
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (j < body.len and depth == 0) {
                    const inner_bytes = body[i + 2 .. j];
                    const inner_source = diag.Source{ .name = "<heredoc>", .text = inner_bytes };
                    const parsed = shape_mod.parse(inner_source, scratch, null) catch {
                        try buf.append(scratch, '$');
                        i += 1;
                        continue;
                    };
                    const low_ctx = program_mod.LowerContext{ .alloc = scratch, .source = inner_source };
                    const inner_prog = program_mod.lower(parsed.root, &low_ctx, null) catch {
                        try buf.append(scratch, '$');
                        i += 1;
                        continue;
                    };
                    const captured = try captureProgramStdout(inner_prog, session, scratch);
                    try buf.appendSlice(scratch, captured);
                    i = j + 1;
                    continue;
                }
            }
            if (isHeredocVarStart(n)) {
                var j = i + 2;
                while (j < body.len and isHeredocVarCont(body[j])) : (j += 1) {}
                const name = body[i + 1 .. j];
                if (try lookupSpecialOrVar(name, session, scratch)) |val| {
                    try buf.appendSlice(scratch, val);
                    scratch.free(val);
                }
                i = j;
                continue;
            }
            if (isHeredocSpecialVar(n)) {
                const name = body[i + 1 .. i + 2];
                if (try lookupSpecialOrVar(name, session, scratch)) |val| {
                    try buf.appendSlice(scratch, val);
                    scratch.free(val);
                }
                i += 2;
                continue;
            }
        }
        try buf.append(scratch, c);
        i += 1;
    }
    return buf.toOwnedSlice(scratch);
}

fn isHeredocVarStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isHeredocVarCont(c: u8) bool {
    return isHeredocVarStart(c) or (c >= '0' and c <= '9');
}

fn isHeredocSpecialVar(c: u8) bool {
    return switch (c) {
        '0'...'9', '?', '#', '@', '!', '*', '$' => true,
        else => false,
    };
}

/// Write the heredoc body into a fresh pipe and return the read end.
/// The current implementation writes from the parent under the
/// assumption that the body fits in the kernel pipe buffer (typically
/// 64 KiB on macOS / 64 KiB+ on Linux). A future change can fork a
/// tiny writer process for over-buffer-size bodies.
fn installHeredocPipe(body: []const u8) !exec.Fd {
    const fds = try exec.makePipe();
    var written: usize = 0;
    while (written < body.len) {
        const n = std.c.write(fds[1], body.ptr + written, body.len - written);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            exec.closeFd(fds[0]);
            exec.closeFd(fds[1]);
            return error.HeredocWriteFailed;
        }
        if (n == 0) break;
        written += @intCast(n);
    }
    exec.closeFd(fds[1]);
    return fds[0];
}

fn wordToPathZ(scratch: Allocator, w: Word, session: *Session) ![*:0]const u8 {
    const text = try expandWordToScalar(w, session, scratch, null);
    const z = try scratch.dupeZ(u8, text);
    return z.ptr;
}

fn makeFailedOutcome(
    session: *Session,
    label: []const u8,
    result: Result,
) !EvalOutcome {
    const j = try session.jobs.create(true, false, label);
    session.jobs.completeZeroChild(j, result);
    return .{ .job = j, .expression_result = result };
}

// =============================================================================
// Command substitution
// =============================================================================
//
// `$(...)` runs the inner program in a forked child whose stdout is
// captured via a pipe. Per PLAN §7 Rule 29, the captured string drops one
// trailing newline run and is treated as a scalar (no whitespace splitting).

fn captureProgramStdout(
    inner: *const Program,
    session: *Session,
    scratch: Allocator,
) ![]const u8 {
    const pipe = try exec.makePipe();

    const rc = std.c.fork();
    if (rc < 0) return error.ForkFailed;

    if (rc == 0) {
        // Child: dup pipe write end onto stdout, close other ends, run.
        _ = std.c.setpgid(0, 0);
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const defaults = [_]std.c.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD, .HUP };
        for (defaults) |sig| std.posix.sigaction(sig, &sa, null);

        _ = std.c.close(pipe[0]);
        _ = std.c.dup2(pipe[1], 1);
        _ = std.c.close(pipe[1]);

        const outcome = evalProgram(inner, session, .{
            .in_child_context = true,
            .scratch = scratch,
        }, null) catch {
            exec._exit(127);
        };
        exec._exit(outcome.expression_result.toStatusByte());
    }

    const pid: exec.Pid = @intCast(rc);
    _ = std.c.setpgid(pid, pid);
    exec.closeFd(pipe[1]);

    // Drain the pipe.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(scratch);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe[0], &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            break;
        }
        if (n == 0) break;
        try buf.appendSlice(scratch, chunk[0..@intCast(n)]);
    }
    exec.closeFd(pipe[0]);

    // Wait for the child.
    var status: c_int = 0;
    while (true) {
        const r = std.c.waitpid(pid, &status, 0);
        if (r >= 0) break;
        const e = std.c.errno(r);
        if (e == .INTR) continue;
        break;
    }

    // Trim one trailing newline run.
    var end: usize = buf.items.len;
    while (end > 0 and (buf.items[end - 1] == '\n' or buf.items[end - 1] == '\r')) end -= 1;
    return scratch.dupe(u8, buf.items[0..end]);
}

/// Split a captured-stdout buffer into newline-delimited fields. Used by
/// `@(...)` list capture: trailing `\r` is stripped per field, empty
/// trailing fields are discarded so a normal Unix tool's `text\n` output
/// produces one field rather than ["text", ""]. Empty interior lines are
/// preserved as empty fields.
fn splitNewlineFields(scratch: Allocator, text: []const u8) ![][]const u8 {
    var fields = std.ArrayListUnmanaged([]const u8).empty;
    defer fields.deinit(scratch);
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        var end = i;
        if (end > start and text[end - 1] == '\r') end -= 1;
        try fields.append(scratch, text[start..end]);
        if (i < text.len) i += 1;
    }
    // Drop a single trailing empty field — a tool that finishes its
    // output with `\n` shouldn't manifest an extra empty argv element.
    if (fields.items.len > 0 and fields.items[fields.items.len - 1].len == 0) {
        _ = fields.pop();
    }
    return fields.toOwnedSlice(scratch);
}

// =============================================================================
// Process substitution
// =============================================================================
//
// `<(prog)` materializes as `/dev/fd/N` where N is a pipe read fd
// connected to a forked child whose stdout writes to the corresponding
// write end. `>(prog)` is the mirror — child reads stdin from a pipe
// whose write fd we hand back as `/dev/fd/N`.
//
// The fd stays open for the parent's lifetime (so the main exec'd
// child inherits it via fork+exec); the child is reaped opportunistically
// at the next `service .poll`. PLAN §7 Rule 25 commits to job-owned
// cleanup; the current implementation relies on standard Unix EOF
// propagation (close → SIGPIPE → child exits) plus the reap loop.

fn spawnProcSubst(
    dir: shape_mod.ProcSubstDir,
    inner: *const program_mod.Program,
    session: *Session,
    scratch: Allocator,
) ![]const u8 {
    const fds = try exec.makePipe();

    const rc = std.c.fork();
    if (rc < 0) {
        exec.closeFd(fds[0]);
        exec.closeFd(fds[1]);
        return error.ForkFailed;
    }

    if (rc == 0) {
        // Child path. Wire stdout (`<(...)`) or stdin (`>(...)`) to the
        // pipe end the parent will hand off as `/dev/fd/N`, reset
        // signal dispositions, then run the body and exit with its
        // status. Errors here `_exit` with a deterministic code.
        _ = std.c.setpgid(0, 0);
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const defaults = [_]std.c.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD, .HUP };
        for (defaults) |sig| std.posix.sigaction(sig, &sa, null);

        switch (dir) {
            .input => {
                // `<(prog)`: prog's stdout → write end; parent reads.
                _ = std.c.close(fds[0]);
                _ = std.c.dup2(fds[1], 1);
                _ = std.c.close(fds[1]);
            },
            .output => {
                // `>(prog)`: prog's stdin ← read end; parent writes.
                _ = std.c.close(fds[1]);
                _ = std.c.dup2(fds[0], 0);
                _ = std.c.close(fds[0]);
            },
        }

        const outcome = evalProgram(inner, session, .{
            .in_child_context = true,
            .scratch = scratch,
        }, null) catch {
            exec._exit(127);
        };
        exec._exit(outcome.expression_result.toStatusByte());
    }

    // Parent: close the end the child uses, keep the other end open
    // for `/dev/fd/N` referencing. The child's pid is recorded so the
    // session can reap it at a safe point.
    const pid: exec.Pid = @intCast(rc);
    _ = std.c.setpgid(pid, pid);
    const parent_fd: exec.Fd = switch (dir) {
        .input => blk: {
            exec.closeFd(fds[1]);
            break :blk fds[0];
        },
        .output => blk: {
            exec.closeFd(fds[0]);
            break :blk fds[1];
        },
    };
    // The exec'd child needs to inherit `parent_fd` across `execve`
    // so `/dev/fd/N` resolves; strip CLOEXEC the makePipe set.
    exec.clearCloexec(parent_fd);

    // Track for cleanup: the parent has to close its end after the
    // foreground command finishes so a `>(...)` reader sees EOF and
    // any leftover side children get reaped.
    try session.proc_subs.append(session.alloc, .{ .parent_fd = parent_fd, .pid = pid });

    // `/dev/fd/N` works on Linux and macOS. The exec'd child opens it
    // and gets a reference to the inherited fd.
    return std.fmt.allocPrint(scratch, "/dev/fd/{d}", .{parent_fd});
}

// =============================================================================
// Glob expansion
// =============================================================================
//
// Pattern grammar (PLAN §7 Rule 9):
//   `*`     — match any sequence of bytes that doesn't include `/`
//   `?`     — match exactly one non-`/` byte
//   `**/`   — recursive descent; matches zero or more path components
//   `/`     — literal path separator
//   anything else — literal byte match
//
// Hidden files (leading `.`) match only when the pattern's component
// explicitly begins with `.`. Results are returned in lexicographic order;
// no match leaves the literal pattern unchanged at the call site.

fn expandGlob(pattern: []const u8, scratch: Allocator) ![][]const u8 {
    if (pattern.len == 0) return &.{};

    var matches = std.ArrayListUnmanaged([]const u8).empty;
    defer matches.deinit(scratch);

    // Anchor: an absolute pattern starts globbing from "/"; a relative
    // pattern starts from cwd (encoded as ""). Tilde expansion is not
    // applied here — that's a separate concern handled by builtins.
    var start: usize = 0;
    var anchor: []const u8 = "";
    if (pattern[0] == '/') {
        anchor = "/";
        start = 1;
    }

    try globWalk(pattern[start..], anchor, scratch, &matches);

    std.mem.sort([]const u8, matches.items, {}, lessThanString);
    return matches.toOwnedSlice(scratch);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Walk one or more pattern components against `dir`. `pattern` is the
/// remaining slash-separated components; `dir` is the path matched so far
/// (empty string means cwd, "/" means root, otherwise absolute or
/// relative prefix). Matched results are appended to `out`.
fn globWalk(
    pattern: []const u8,
    dir: []const u8,
    scratch: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    if (pattern.len == 0) {
        // Matched all components — accept the current directory.
        if (dir.len > 0) try out.append(scratch, try scratch.dupe(u8, dir));
        return;
    }

    // Slice off the next component.
    const slash = std.mem.indexOfScalar(u8, pattern, '/') orelse pattern.len;
    const head = pattern[0..slash];
    const rest_after_slash: []const u8 = if (slash < pattern.len) pattern[slash + 1 ..] else "";
    const has_more = slash < pattern.len;

    // `**` — recursive descent.
    if (std.mem.eql(u8, head, "**")) {
        // Zero-descent: match `rest` directly against `dir`.
        try globWalk(rest_after_slash, dir, scratch, out);
        // One-or-more: descend into every subdirectory and recurse with
        // the same `**/rest` pattern.
        try recursiveDescend(pattern, dir, scratch, out);
        return;
    }

    if (componentHasMeta(head)) {
        try matchComponent(head, dir, has_more, rest_after_slash, scratch, out);
        return;
    }

    // Literal component: extend the path; recurse if more components.
    const child = try joinPath(scratch, dir, head);
    defer scratch.free(child);

    if (has_more) {
        // Verify the child is actually a directory before descending.
        if (!isDirectory(child)) return;
        try globWalk(rest_after_slash, child, scratch, out);
        return;
    }

    if (pathExists(child)) try out.append(scratch, try scratch.dupe(u8, child));
}

fn matchComponent(
    head: []const u8,
    dir: []const u8,
    has_more: bool,
    rest: []const u8,
    scratch: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    const open_path = if (dir.len == 0) "." else dir;
    const open_z = try scratch.dupeZ(u8, open_path);
    defer scratch.free(open_z);

    const dirp = std.c.opendir(open_z) orelse return;
    defer _ = std.c.closedir(dirp);

    while (true) {
        const ent = std.c.readdir(dirp) orelse break;
        const name = direntName(ent);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // Hidden files require an explicit leading `.` in the pattern.
        if (name[0] == '.' and (head.len == 0 or head[0] != '.')) continue;
        if (!fnmatchComponent(head, name)) continue;

        const child = try joinPath(scratch, dir, name);
        if (has_more) {
            defer scratch.free(child);
            if (!isDirectory(child)) continue;
            try globWalk(rest, child, scratch, out);
        } else {
            try out.append(scratch, child);
        }
    }
}

fn recursiveDescend(
    pattern_with_dblstar: []const u8,
    dir: []const u8,
    scratch: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    const open_path = if (dir.len == 0) "." else dir;
    const open_z = try scratch.dupeZ(u8, open_path);
    defer scratch.free(open_z);

    const dirp = std.c.opendir(open_z) orelse return;
    defer _ = std.c.closedir(dirp);

    while (true) {
        const ent = std.c.readdir(dirp) orelse break;
        const name = direntName(ent);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // `**` does not enter dotfile-named subtrees.
        if (name[0] == '.') continue;

        const child = try joinPath(scratch, dir, name);
        defer scratch.free(child);
        if (!isDirectory(child)) continue;
        try globWalk(pattern_with_dblstar, child, scratch, out);
    }
}

/// Read a directory entry's name as a slice. Different platforms expose
/// the field differently — some carry a `namlen`, others NUL-terminate.
fn direntName(ent: anytype) []const u8 {
    const T = @TypeOf(ent.*);
    if (@hasField(T, "namlen")) {
        const len: usize = ent.namlen;
        return ent.name[0..len];
    }
    const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
    return std.mem.span(name_ptr);
}

fn componentHasMeta(c: []const u8) bool {
    for (c) |b| switch (b) {
        '*', '?' => return true,
        else => {},
    };
    return false;
}

/// Match a single path component against a single pattern (no `/` in
/// either). Recursive backtrack on `*`; `?` matches exactly one byte.
fn fnmatchComponent(pattern: []const u8, name: []const u8) bool {
    return matchAt(pattern, 0, name, 0);
}

fn matchAt(p: []const u8, pi: usize, n: []const u8, ni: usize) bool {
    var i = pi;
    var j = ni;
    while (i < p.len) {
        const pc = p[i];
        if (pc == '*') {
            // Collapse runs of `*`.
            while (i < p.len and p[i] == '*') i += 1;
            if (i == p.len) return true;
            var k = j;
            while (k <= n.len) : (k += 1) {
                if (matchAt(p, i, n, k)) return true;
            }
            return false;
        }
        if (j >= n.len) return false;
        if (pc == '?') {
            i += 1;
            j += 1;
            continue;
        }
        if (pc != n[j]) return false;
        i += 1;
        j += 1;
    }
    return j == n.len;
}

fn joinPath(scratch: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return scratch.dupe(u8, name);
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(scratch, "/{s}", .{name});
    return std.fmt.allocPrint(scratch, "{s}/{s}", .{ dir, name });
}

fn pathExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    var st: std.c.Stat = undefined;
    return std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) == 0;
}

fn isDirectory(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) != 0) return false;
    return (st.mode & std.c.S.IFMT) == std.c.S.IFDIR;
}
