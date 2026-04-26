//! builtins — registry and implementations.
//!
//! A builtin runs in one of two execution contexts:
//!
//!   - `shell` — the calling Job has zero children. Mutations to
//!     `Session` are visible to the rest of the shell.
//!
//!   - `child` — the builtin runs as a forked stage of a pipeline,
//!     subshell body, or detached child. Session mutation is meaningless
//!     in this context; the only outputs are stdout/stderr fds and the
//!     returned exit byte.
//!
//! The `BuiltinContext` union forces every builtin to be honest about
//! which context it has. A child-context builtin cannot accidentally
//! write to parent session state because the session simply isn't there.

const std = @import("std");
const runtime = @import("runtime.zig");
const session_mod = @import("session.zig");
const vars_mod = @import("vars.zig");

pub const Allocator = std.mem.Allocator;
pub const Result = runtime.Result;

pub const BuiltinIo = struct {
    stdin: i32,
    stdout: i32,
    stderr: i32,
};

pub const BuiltinContext = union(enum) {
    shell: *session_mod.Session,
    child,
};

pub const BuiltinFn = *const fn (
    argv: []const []const u8,
    io: BuiltinIo,
    ctx: BuiltinContext,
) anyerror!Result;

/// Errors thrown by control-flow builtins (`break`, `continue`,
/// `return`). Loop and call-frame evaluators catch these to redirect
/// control without unwinding through every intermediate program node.
pub const ControlError = error{
    BreakLoop,
    ContinueLoop,
    ReturnFromCmd,
};

pub const Builtin = struct {
    name: []const u8,
    run: BuiltinFn,
};

pub const BuiltinSet = struct {
    table: std.StringHashMapUnmanaged(Builtin),

    pub fn lookup(self: *const BuiltinSet, name: []const u8) ?Builtin {
        return self.table.get(name);
    }

    pub fn deinit(self: *BuiltinSet, alloc: Allocator) void {
        self.table.deinit(alloc);
    }
};

pub fn init(alloc: Allocator) !BuiltinSet {
    var set: BuiltinSet = .{ .table = .empty };
    try set.table.put(alloc, "echo", .{ .name = "echo", .run = echoFn });
    try set.table.put(alloc, "true", .{ .name = "true", .run = trueFn });
    try set.table.put(alloc, "false", .{ .name = "false", .run = falseFn });
    try set.table.put(alloc, "pwd", .{ .name = "pwd", .run = pwdFn });
    try set.table.put(alloc, "exit", .{ .name = "exit", .run = exitFn });
    try set.table.put(alloc, "cd", .{ .name = "cd", .run = cdFn });
    try set.table.put(alloc, "export", .{ .name = "export", .run = exportFn });
    try set.table.put(alloc, "unset", .{ .name = "unset", .run = unsetFn });
    try set.table.put(alloc, "test", .{ .name = "test", .run = testFn });
    try set.table.put(alloc, "[", .{ .name = "[", .run = testFn });
    try set.table.put(alloc, "printf", .{ .name = "printf", .run = printfFn });
    try set.table.put(alloc, "break", .{ .name = "break", .run = breakFn });
    try set.table.put(alloc, "continue", .{ .name = "continue", .run = continueFn });
    try set.table.put(alloc, "return", .{ .name = "return", .run = returnFn });
    return set;
}

// =============================================================================
// I/O helpers
// =============================================================================

fn writeAllToFd(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return false;
        }
        if (rc == 0) return false;
        off += @intCast(rc);
    }
    return true;
}

// =============================================================================
// echo / true / false / pwd / exit
// =============================================================================

fn echoFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = ctx;
    var first = true;
    for (argv[1..]) |arg| {
        if (!first) {
            if (!writeAllToFd(io.stdout, " ")) return .{ .exited = 1 };
        }
        if (!writeAllToFd(io.stdout, arg)) return .{ .exited = 1 };
        first = false;
    }
    if (!writeAllToFd(io.stdout, "\n")) return .{ .exited = 1 };
    return .{ .exited = 0 };
}

fn trueFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    _ = io;
    _ = ctx;
    return .{ .exited = 0 };
}

fn falseFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    _ = io;
    _ = ctx;
    return .{ .exited = 1 };
}

fn pwdFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    _ = ctx;
    var buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&buf, buf.len) orelse {
        const msg = "pwd: cannot determine current directory\n";
        _ = writeAllToFd(io.stderr, msg);
        return .{ .exited = 1 };
    };
    const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
    if (!writeAllToFd(io.stdout, buf[0..len])) return .{ .exited = 1 };
    if (!writeAllToFd(io.stdout, "\n")) return .{ .exited = 1 };
    return .{ .exited = 0 };
}

/// `exit N` in shell context records the request on Session and returns
/// success synchronously. The shell's top-level loop reads the request
/// after evaluation completes. In child context, `exit N` ends the child
/// with status N.
fn exitFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    var code: u8 = 0;
    if (argv.len >= 2) {
        code = std.fmt.parseInt(u8, argv[1], 10) catch {
            const msg = "exit: numeric argument required\n";
            _ = writeAllToFd(io.stderr, msg);
            return .{ .exited = 2 };
        };
    }
    const result: Result = .{ .exited = code };
    switch (ctx) {
        .shell => |s| s.exit_request = result,
        .child => {},
    }
    return result;
}

// =============================================================================
// cd
// =============================================================================

fn cdFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    const target_arg: []const u8 = if (argv.len >= 2) argv[1] else blk: {
        // No argument — go to $HOME.
        switch (ctx) {
            .shell => |s| {
                if (s.vars.get("HOME")) |v| switch (v.value) {
                    .scalar => |home| break :blk home,
                    else => {},
                };
            },
            .child => {},
        }
        const home_env = std.c.getenv("HOME") orelse {
            _ = writeAllToFd(io.stderr, "cd: HOME not set\n");
            return .{ .exited = 1 };
        };
        break :blk std.mem.span(home_env);
    };

    // Convert to NUL-terminated path. Use a stack buffer.
    var pathbuf: [4096]u8 = undefined;
    if (target_arg.len >= pathbuf.len) {
        _ = writeAllToFd(io.stderr, "cd: path too long\n");
        return .{ .exited = 1 };
    }
    @memcpy(pathbuf[0..target_arg.len], target_arg);
    pathbuf[target_arg.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&pathbuf);

    if (std.c.chdir(path_z) != 0) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "cd: {s}: No such file or directory\n", .{target_arg}) catch return .{ .exited = 1 };
        _ = writeAllToFd(io.stderr, msg);
        return .{ .exited = 1 };
    }

    // Update PWD/OLDPWD in shell context.
    switch (ctx) {
        .shell => |s| {
            // Read back canonical cwd.
            var cwd_buf: [4096]u8 = undefined;
            if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |got| {
                const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
                const new_pwd = cwd_buf[0..len];
                if (s.vars.get("PWD")) |old| switch (old.value) {
                    .scalar => |p| s.vars.setScalar("OLDPWD", p, true) catch {},
                    else => {},
                };
                s.vars.setScalar("PWD", new_pwd, true) catch {};
            }
        },
        .child => {},
    }
    return .{ .exited = 0 };
}

// =============================================================================
// export / unset
// =============================================================================

fn exportFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    if (argv.len < 2) return .{ .exited = 0 };
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };
    for (argv[1..]) |arg| {
        // `export NAME=VALUE` or `export NAME`.
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            const value = arg[eq + 1 ..];
            session.vars.setScalar(name, value, true) catch return .{ .exited = 1 };
        } else {
            session.vars.markExported(arg);
        }
    }
    return .{ .exited = 0 };
}

fn unsetFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };
    for (argv[1..]) |name| session.vars.unset(name);
    return .{ .exited = 0 };
}

// =============================================================================
// test / [
// =============================================================================
//
// File checks: -e -f -d -r -w -x -s
// String compares: =, !=
// Integer compares: -eq -ne -lt -le -gt -ge

fn testFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = ctx;
    // `[ ... ]` form requires last argv to be `]`.
    var args = argv[1..];
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "[")) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            _ = writeAllToFd(io.stderr, "[: missing ']'\n");
            return .{ .exited = 2 };
        }
        args = args[0 .. args.len - 1];
    }

    if (args.len == 0) return .{ .exited = 1 }; // empty test = false
    if (args.len == 1) {
        // Truthy if non-empty string.
        return .{ .exited = if (args[0].len > 0) 0 else 1 };
    }

    if (args.len == 2 and isUnaryOp(args[0])) {
        return runUnaryTest(args[0], args[1]);
    }

    if (args.len == 3) {
        return runBinaryTest(args[0], args[1], args[2]);
    }

    _ = writeAllToFd(io.stderr, "test: unsupported expression\n");
    return .{ .exited = 2 };
}

fn isUnaryOp(s: []const u8) bool {
    return s.len == 2 and s[0] == '-' and switch (s[1]) {
        'e', 'f', 'd', 'r', 'w', 'x', 's', 'n', 'z' => true,
        else => false,
    };
}

fn runUnaryTest(op: []const u8, arg: []const u8) !Result {
    if (std.mem.eql(u8, op, "-z")) return .{ .exited = if (arg.len == 0) 0 else 1 };
    if (std.mem.eql(u8, op, "-n")) return .{ .exited = if (arg.len > 0) 0 else 1 };

    var pathbuf: [4096]u8 = undefined;
    if (arg.len >= pathbuf.len) return .{ .exited = 1 };
    @memcpy(pathbuf[0..arg.len], arg);
    pathbuf[arg.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&pathbuf);

    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) != 0) return .{ .exited = 1 };
    const mode = st.mode;
    const is_dir = (mode & std.c.S.IFMT) == std.c.S.IFDIR;
    const is_reg = (mode & std.c.S.IFMT) == std.c.S.IFREG;
    if (std.mem.eql(u8, op, "-e")) return .{ .exited = 0 };
    if (std.mem.eql(u8, op, "-f")) return .{ .exited = if (is_reg) 0 else 1 };
    if (std.mem.eql(u8, op, "-d")) return .{ .exited = if (is_dir) 0 else 1 };
    if (std.mem.eql(u8, op, "-s")) return .{ .exited = if (st.size > 0) 0 else 1 };
    if (std.mem.eql(u8, op, "-r")) return .{ .exited = if (std.c.access(path_z, std.c.R_OK) == 0) 0 else 1 };
    if (std.mem.eql(u8, op, "-w")) return .{ .exited = if (std.c.access(path_z, std.c.W_OK) == 0) 0 else 1 };
    if (std.mem.eql(u8, op, "-x")) return .{ .exited = if (std.c.access(path_z, std.c.X_OK) == 0) 0 else 1 };
    return .{ .exited = 2 };
}

fn runBinaryTest(lhs: []const u8, op: []const u8, rhs: []const u8) !Result {
    if (std.mem.eql(u8, op, "=")) return .{ .exited = if (std.mem.eql(u8, lhs, rhs)) 0 else 1 };
    if (std.mem.eql(u8, op, "!=")) return .{ .exited = if (!std.mem.eql(u8, lhs, rhs)) 0 else 1 };

    const li = std.fmt.parseInt(i64, lhs, 10) catch return .{ .exited = 2 };
    const ri = std.fmt.parseInt(i64, rhs, 10) catch return .{ .exited = 2 };
    const cmp: bool = if (std.mem.eql(u8, op, "-eq"))
        li == ri
    else if (std.mem.eql(u8, op, "-ne"))
        li != ri
    else if (std.mem.eql(u8, op, "-lt"))
        li < ri
    else if (std.mem.eql(u8, op, "-le"))
        li <= ri
    else if (std.mem.eql(u8, op, "-gt"))
        li > ri
    else if (std.mem.eql(u8, op, "-ge"))
        li >= ri
    else
        return .{ .exited = 2 };
    return .{ .exited = if (cmp) 0 else 1 };
}

// =============================================================================
// printf
// =============================================================================
//
// Minimal: `%s` and `%d` and `%%` and `\n`/`\t`/`\\` escape sequences. No
// width/precision specifiers.

fn printfFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = ctx;
    if (argv.len < 2) return .{ .exited = 1 };
    const fmt = argv[1];
    const rest = argv[2..];

    var buf: [4096]u8 = undefined;
    var bw = std.Io.Writer.fixed(&buf);
    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '\\' and i + 1 < fmt.len) {
            const n = fmt[i + 1];
            const decoded: u8 = switch (n) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                else => {
                    bw.writeByte(c) catch return .{ .exited = 1 };
                    bw.writeByte(n) catch return .{ .exited = 1 };
                    i += 1;
                    continue;
                },
            };
            bw.writeByte(decoded) catch return .{ .exited = 1 };
            i += 1;
            continue;
        }
        if (c == '%' and i + 1 < fmt.len) {
            const n = fmt[i + 1];
            switch (n) {
                '%' => bw.writeByte('%') catch return .{ .exited = 1 },
                's' => {
                    const arg = if (arg_idx < rest.len) rest[arg_idx] else "";
                    arg_idx += 1;
                    bw.writeAll(arg) catch return .{ .exited = 1 };
                },
                'd' => {
                    const arg = if (arg_idx < rest.len) rest[arg_idx] else "0";
                    arg_idx += 1;
                    const v = std.fmt.parseInt(i64, arg, 10) catch 0;
                    bw.print("{d}", .{v}) catch return .{ .exited = 1 };
                },
                else => {
                    bw.writeByte(c) catch return .{ .exited = 1 };
                    bw.writeByte(n) catch return .{ .exited = 1 };
                },
            }
            i += 1;
            continue;
        }
        bw.writeByte(c) catch return .{ .exited = 1 };
    }
    if (!writeAllToFd(io.stdout, bw.buffered())) return .{ .exited = 1 };
    return .{ .exited = 0 };
}

// =============================================================================
// break / continue / return
// =============================================================================
//
// Control-flow builtins throw typed errors that loop and call-frame
// evaluators catch. In child context (pipeline stage, subshell, detached
// body) the error doesn't escape the child — the trampoline catches it
// and exits the child with the optional numeric argument as the status.

fn breakFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    _ = io;
    _ = ctx;
    return error.BreakLoop;
}

fn continueFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    _ = io;
    _ = ctx;
    return error.ContinueLoop;
}

fn returnFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    _ = ctx;
    // `return N` would surface N to the call frame; for now we throw
    // the typed error and let the catcher decide the status. When `cmd`
    // definitions land, the call-frame catcher will read argv[1] off the
    // session if needed.
    _ = argv;
    return error.ReturnFromCmd;
}
