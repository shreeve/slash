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
    // Skip when redirects are present or env-prefixes are present — those
    // cases need a child to apply redirects/env without leaking into the
    // parent shell.
    if (!ctx.in_child_context and c.redirects.len == 0 and c.env.len == 0) {
        if (session.builtins.lookup(exe_text)) |b| {
            return try runShellContextBuiltin(c, b, argv.items, session);
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

fn runExternalSingle(
    c: *const Command,
    argv: []const []const u8,
    local_env: ?[*:null]const ?[*:0]const u8,
    session: *Session,
    ctx: EvalContext,
    sink: ?Sink,
) !EvalOutcome {
    const action = try buildAction(argv[0], argv, local_env, session, ctx.scratch);
    const redirs = try buildRedirectOps(ctx.scratch, c.redirects, session);
    const pid = exec.spawn(.{
        .redirects = redirs,
        .extra_close = &.{},
        .pgid = 0,
        .action = action,
    }) catch |err| {
        try diag.emit(sink, diag.make(
            .exec, .@"error", "EX0001",
            @errorName(err), .{ .name = "<eval>", .text = "" }, c.span,
        ));
        return makeFailedOutcome(session, argv[0], .{ .exited = 127 });
    };

    const j = try session.jobs.create(true, false, argv[0]);
    var pids = [_]exec.Pid{pid};
    try session.jobs.setProcesses(j, pid, &pids);
    try job.service(&session.jobs, .foreground, j);
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

    const j = try session.jobs.create(true, false, "<pipeline>");
    try session.jobs.setProcesses(j, leader_pgid, pids);
    try job.service(&session.jobs, .foreground, j);
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

        const out = try evalProgram(item.program, session, ctx, sink);
        last_result = out.expression_result;
        last_job = out.job;

        job.service(&session.jobs, .poll, null) catch {};
        if (session.exit_request != null) break;

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
        try diag.emit(sink, diag.make(
            .exec, .@"error", "EX0001",
            @errorName(err), .{ .name = "<eval>", .text = "" }, c.span,
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
) ![]const u8 {
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
    _ = sink;
    switch (part) {
        .text => |t| try buf.appendSlice(scratch, t),
        .variable => |name| {
            if (try lookupSpecialOrVar(name, session, scratch)) |val| {
                try buf.appendSlice(scratch, val);
                scratch.free(val);
            }
        },
        .var_braced => |body| {
            // Strip leading/trailing whitespace; treat body as a name only.
            const trimmed = std.mem.trim(u8, body, " \t");
            if (try lookupSpecialOrVar(trimmed, session, scratch)) |val| {
                try buf.appendSlice(scratch, val);
                scratch.free(val);
            }
        },
        .cmd_subst => |inner| {
            const captured = try captureProgramStdout(inner, session, scratch);
            try buf.appendSlice(scratch, captured);
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

    const path_z = try resolvePath(scratch, exe_text);
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

fn resolvePath(scratch: Allocator, exe: []const u8) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, exe, '/') != null) {
        const z = try scratch.dupeZ(u8, exe);
        return z.ptr;
    }

    const path_env = std.c.getenv("PATH") orelse {
        const z = try scratch.dupeZ(u8, exe);
        return z.ptr;
    };
    const path_str = std.mem.span(path_env);

    var it = std.mem.splitScalar(u8, path_str, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrintSentinel(scratch, "{s}/{s}", .{ dir, exe }, 0);
        const rc = std.c.access(candidate.ptr, std.c.X_OK);
        if (rc == 0) return candidate.ptr;
    }

    const z = try scratch.dupeZ(u8, exe);
    return z.ptr;
}

fn buildRedirectOps(
    scratch: Allocator,
    reds: []const Redirect,
    session: *Session,
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
        }
    }
    return out.toOwnedSlice(scratch);
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
