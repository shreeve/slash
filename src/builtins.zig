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
const job_mod = @import("job.zig");
const exec_mod = @import("exec.zig");
const terminal_mod = @import("terminal.zig");
const shape_mod = @import("shape.zig");
const program_mod = @import("program.zig");
const diag = @import("diagnostics.zig");
const word_mod = @import("word.zig");
const parser = @import("parser.zig");
const slash = @import("slash.zig");
const history_mod = @import("history.zig");
const notice = @import("notice.zig");

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
    try set.table.put(alloc, "read", .{ .name = "read", .run = readFn });
    try set.table.put(alloc, "shift", .{ .name = "shift", .run = shiftFn });
    try set.table.put(alloc, "type", .{ .name = "type", .run = typeFn });
    try set.table.put(alloc, "jobs", .{ .name = "jobs", .run = jobsFn });
    try set.table.put(alloc, "wait", .{ .name = "wait", .run = waitFn });
    try set.table.put(alloc, "fg", .{ .name = "fg", .run = fgFn });
    try set.table.put(alloc, "bg", .{ .name = "bg", .run = bgFn });
    try set.table.put(alloc, "kill", .{ .name = "kill", .run = killFn });
    try set.table.put(alloc, "disown", .{ .name = "disown", .run = disownFn });
    try set.table.put(alloc, "trap", .{ .name = "trap", .run = trapFn });
    try set.table.put(alloc, "str", .{ .name = "str", .run = strFn });
    try set.table.put(alloc, "history", .{ .name = "history", .run = historyFn });
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
    const session_opt: ?*session_mod.Session = switch (ctx) {
        .shell => |s| s,
        .child => null,
    };

    var print_target = false; // `cd -` echoes the new pwd, like bash
    var target_arg: []const u8 = "";
    if (argv.len >= 2) {
        if (std.mem.eql(u8, argv[1], "-")) {
            print_target = true;
            const old = if (session_opt) |s|
                if (s.vars.get("OLDPWD")) |v| switch (v.value) {
                    .scalar => |p| p,
                    else => "",
                } else ""
            else "";
            if (old.len == 0) {
                _ = writeAllToFd(io.stderr, "cd: OLDPWD not set\n");
                return .{ .exited = 1 };
            }
            target_arg = old;
        } else {
            target_arg = argv[1];
        }
    } else {
        // No argument — go to $HOME.
        if (session_opt) |s| {
            if (s.vars.get("HOME")) |v| switch (v.value) {
                .scalar => |home| target_arg = home,
                else => {},
            };
        }
        if (target_arg.len == 0) {
            const home_env = std.c.getenv("HOME") orelse {
                _ = writeAllToFd(io.stderr, "cd: HOME not set\n");
                return .{ .exited = 1 };
            };
            target_arg = std.mem.span(home_env);
        }
    }

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
    if (session_opt) |s| {
        var cwd_buf: [4096]u8 = undefined;
        if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |got| {
            const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
            const new_pwd = cwd_buf[0..len];
            if (s.vars.get("PWD")) |old| switch (old.value) {
                .scalar => |p| s.vars.setScalar("OLDPWD", p, true) catch {},
                else => {},
            };
            s.vars.setScalar("PWD", new_pwd, true) catch {};
            if (print_target) {
                _ = writeAllToFd(io.stdout, new_pwd);
                _ = writeAllToFd(io.stdout, "\n");
            }
        }
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
    // `return N` inside a `cmd` body raises `ReturnFromCmd`; the call
    // frame catches and uses `session.last_status` as the exit code.
    // Stashing the requested status here keeps the builtin signature
    // pure (it can't return both Result and the typed control error).
    if (argv.len >= 2) {
        const code = std.fmt.parseInt(u8, argv[1], 10) catch {
            _ = writeAllToFd(io.stderr, "return: numeric argument required\n");
            return .{ .exited = 2 };
        };
        switch (ctx) {
            .shell => |s| s.last_status = code,
            .child => {},
        }
    }
    return error.ReturnFromCmd;
}

// =============================================================================
// read
// =============================================================================
//
// `read NAME ...` consumes one line from stdin. With one name, the entire
// trimmed line is bound to that variable. With multiple names, the line
// is split on whitespace into N fields; the last name absorbs the
// remainder so multi-word values work without surprises:
//
//   read first rest    line: "alpha beta gamma"
//   first=alpha  rest="beta gamma"
//
// Returns 1 at end-of-file (no bytes read) so the typical loop pattern
// `while read line { ... }` terminates cleanly.

fn readFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    if (argv.len < 2) {
        _ = writeAllToFd(io.stderr, "read: variable name required\n");
        return .{ .exited = 2 };
    }
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    // Read until newline or EOF, one byte at a time. Reading more would
    // require an unread buffer — we don't own stdin's underlying buffer.
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(session.alloc);

    var saw_any = false;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(io.stdin, &byte, 1);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return .{ .exited = 1 };
        }
        if (n == 0) break; // EOF
        saw_any = true;
        if (byte[0] == '\n') break;
        try line_buf.append(session.alloc, byte[0]);
    }

    if (!saw_any) return .{ .exited = 1 };

    const names = argv[1..];
    if (names.len == 1) {
        try session.vars.setScalar(names[0], line_buf.items, false);
        return .{ .exited = 0 };
    }

    // Multiple names: split on whitespace, last name absorbs the rest.
    var i: usize = 0;
    var name_idx: usize = 0;
    const text = line_buf.items;

    while (name_idx + 1 < names.len) : (name_idx += 1) {
        while (i < text.len and isReadWs(text[i])) : (i += 1) {}
        const start = i;
        while (i < text.len and !isReadWs(text[i])) : (i += 1) {}
        try session.vars.setScalar(names[name_idx], text[start..i], false);
    }

    while (i < text.len and isReadWs(text[i])) : (i += 1) {}
    var end = text.len;
    while (end > i and isReadWs(text[end - 1])) end -= 1;
    try session.vars.setScalar(names[names.len - 1], text[i..end], false);
    return .{ .exited = 0 };
}

fn isReadWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

// =============================================================================
// shift
// =============================================================================
//
// `shift [N]` shifts positional parameters down by N (default 1). After
// `shift`, the old `$2` becomes `$1`, the old `$3` becomes `$2`, etc.;
// `$#` decrements; `$@` reflects the new tail. Shifting past the end is
// an error (status 1). Used in argv-loop patterns.

fn shiftFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    var n: usize = 1;
    if (argv.len >= 2) {
        n = std.fmt.parseInt(usize, argv[1], 10) catch {
            _ = writeAllToFd(io.stderr, "shift: numeric argument required\n");
            return .{ .exited = 2 };
        };
    }

    const cur = readPositionalCount(session);
    if (n > cur) {
        _ = writeAllToFd(io.stderr, "shift: count exceeds $#\n");
        return .{ .exited = 1 };
    }

    // Read all current positionals into a heap-allocated list before
    // mutating, so we don't trip over our own renumbering.
    var current = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (current.items) |s| session.alloc.free(s);
        current.deinit(session.alloc);
    }
    var idx: usize = 1;
    while (idx <= cur) : (idx += 1) {
        var keybuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{idx}) catch continue;
        if (session.vars.get(key)) |v| switch (v.value) {
            .scalar => |s| try current.append(session.alloc, try session.alloc.dupe(u8, s)),
            else => try current.append(session.alloc, try session.alloc.dupe(u8, "")),
        };
    }

    // Unset the old slots first to avoid stale indices when count shrinks.
    idx = 1;
    while (idx <= cur) : (idx += 1) {
        var keybuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{idx}) catch continue;
        session.vars.unset(key);
    }

    const remaining = current.items[n..];
    for (remaining, 0..) |val, i| {
        var keybuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{i + 1}) catch continue;
        try session.vars.setScalar(key, val, false);
    }

    var countbuf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&countbuf, "{d}", .{remaining.len}) catch unreachable;
    try session.vars.setScalar("#", count, false);
    if (remaining.len > 0) {
        try session.vars.setList("@", remaining, false);
    } else {
        session.vars.unset("@");
    }
    return .{ .exited = 0 };
}

fn readPositionalCount(session: *session_mod.Session) usize {
    if (session.vars.get("#")) |v| switch (v.value) {
        .scalar => |s| return std.fmt.parseInt(usize, s, 10) catch 0,
        else => return 0,
    };
    return 0;
}

// =============================================================================
// type
// =============================================================================
//
// Describes how `NAME` would resolve. Order matches eval dispatch:
// special-cased keywords (`source`, `.`, `exec`, `command`) → builtins
// → `cmd` definitions (when they exist) → `$PATH` lookup.

fn typeFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    if (argv.len < 2) {
        _ = writeAllToFd(io.stderr, "type: name required\n");
        return .{ .exited = 2 };
    }
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };
    var any_unknown = false;
    for (argv[1..]) |name| {
        if (isSpecialDispatchName(name)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} is a shell builtin\n", .{name}) catch continue;
            _ = writeAllToFd(io.stdout, msg);
            continue;
        }
        if (session.builtins.lookup(name) != null) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} is a shell builtin\n", .{name}) catch continue;
            _ = writeAllToFd(io.stdout, msg);
            continue;
        }
        if (try findInPath(session, name)) |path| {
            defer session.alloc.free(path);
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} is {s}\n", .{ name, path }) catch continue;
            _ = writeAllToFd(io.stdout, msg);
            continue;
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "type: {s}: not found\n", .{name}) catch continue;
        _ = writeAllToFd(io.stderr, msg);
        any_unknown = true;
    }
    return .{ .exited = if (any_unknown) 1 else 0 };
}

fn isSpecialDispatchName(name: []const u8) bool {
    return std.mem.eql(u8, name, "source") or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "exec") or
        std.mem.eql(u8, name, "command");
}

/// Walk `$PATH` once; returns the first executable match as a session-
/// allocated string. Bypasses the eval-side cache because `type` is rare
/// and the cache stores resolved paths only on actual exec dispatch.
fn findInPath(session: *session_mod.Session, name: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (accessExecutable(name))
            return try session.alloc.dupe(u8, name);
        return null;
    }
    const path_env = std.c.getenv("PATH") orelse return null;
    const path_str = std.mem.span(path_env);
    var it = std.mem.splitScalar(u8, path_str, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(session.alloc, "{s}/{s}", .{ dir, name });
        if (accessExecutable(candidate)) return candidate;
        session.alloc.free(candidate);
    }
    return null;
}

fn accessExecutable(path: []const u8) bool {
    var pathbuf: [4096]u8 = undefined;
    if (path.len >= pathbuf.len) return false;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&pathbuf);
    return std.c.access(path_z, std.c.X_OK) == 0;
}

// =============================================================================
// jobs / wait
// =============================================================================
//
// `jobs` lists the session's background/detached jobs with their current
// state and command text. Foreground zero-child jobs are runtime
// bookkeeping and stay invisible.
//
// `wait` (no args) blocks until every currently-known background job is
// done; the result is the last completing job's exit status. `wait %N`
// blocks on the given job id specifically.

fn jobsFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = argv;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    // Drain any pending child events before listing so the displayed
    // state is as fresh as possible (PLAN §19 safe-point reaping).
    job_mod.service(&session.jobs, .poll, null) catch {};

    var line_buf: [512]u8 = undefined;
    for (session.jobs.list()) |j| {
        // List backgrounded jobs and stopped foreground jobs. Skip
        // zero-child shell-context bookkeeping (`processes.len == 0`)
        // and reaped jobs.
        if (j.processes.len == 0) continue;
        switch (j.state) {
            .done => continue,
            .stopped => {}, // include stopped jobs even if not detached
            .running, .pending => if (!j.detached) continue,
        }
        const status_label = formatJobState(j.state);
        const text = j.command_text orelse "<job>";
        const line = std.fmt.bufPrint(
            &line_buf,
            "[{d}] {s} {s}\n",
            .{ j.id, status_label.bytes(&line_buf), text },
        ) catch continue;
        _ = writeAllToFd(io.stdout, line);
    }
    return .{ .exited = 0 };
}

const StateLabel = struct {
    inline_buf: [32]u8 = undefined,
    len: u8 = 0,

    fn bytes(self: *const StateLabel, _: []u8) []const u8 {
        return self.inline_buf[0..self.len];
    }
};

fn formatJobState(state: job_mod.JobState) StateLabel {
    var label = StateLabel{};
    const text = switch (state) {
        .pending => "Pending",
        .running => "Running",
        .stopped => "Stopped",
        .done => |r| switch (r) {
            .exited => |n| return scalarLabel("Done", n),
            .signaled => return constLabel("Signaled"),
        },
    };
    @memcpy(label.inline_buf[0..text.len], text);
    label.len = @intCast(text.len);
    return label;
}

fn constLabel(text: []const u8) StateLabel {
    var label = StateLabel{};
    @memcpy(label.inline_buf[0..text.len], text);
    label.len = @intCast(text.len);
    return label;
}

fn scalarLabel(prefix: []const u8, n: u8) StateLabel {
    var label = StateLabel{};
    const written = std.fmt.bufPrint(&label.inline_buf, "{s}({d})", .{ prefix, n }) catch {
        @memcpy(label.inline_buf[0..prefix.len], prefix);
        label.len = @intCast(prefix.len);
        return label;
    };
    label.len = @intCast(written.len);
    return label;
}

fn waitFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    if (argv.len >= 2) {
        const target = argv[1];
        const j = blk: {
            // `%N` form: numeric job id.
            if (target.len >= 1 and target[0] == '%') {
                const id = std.fmt.parseInt(u32, target[1..], 10) catch {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "wait: invalid job spec `{s}`\n", .{target}) catch "wait: invalid job spec\n";
                    _ = std.c.write(2, msg.ptr, msg.len);
                    return .{ .exited = 2 };
                };
                break :blk session.jobs.lookup(id) orelse {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "wait: no such job {d}\n", .{id}) catch "wait: no such job\n";
                    _ = std.c.write(2, buf[0..msg.len].ptr, msg.len);
                    return .{ .exited = 127 };
                };
            }
            // Bare integer: pid (POSIX `wait pid...`). Find the owning
            // job and wait on it. `$!` flows through this branch.
            const pid = std.fmt.parseInt(std.c.pid_t, target, 10) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "wait: invalid pid `{s}`\n", .{target}) catch "wait: invalid pid\n";
                _ = std.c.write(2, msg.ptr, msg.len);
                return .{ .exited = 2 };
            };
            break :blk findJobByPid(session, pid) orelse {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "wait: pid {d} is not a child of this shell\n", .{pid}) catch "wait: not a child\n";
                _ = std.c.write(2, msg.ptr, msg.len);
                return .{ .exited = 127 };
            };
        };
        try job_mod.service(&session.jobs, .foreground, j);
        return j.result orelse Result{ .exited = 0 };
    }

    // No args: wait for every currently-known background job. Aggregate
    // result is the last-completed job's status — matches POSIX `wait`
    // with no operands.
    var last_result: Result = .{ .exited = 0 };
    while (true) {
        const target = pickPendingBgJob(session) orelse break;
        try job_mod.service(&session.jobs, .foreground, target);
        if (target.result) |r| last_result = r;
    }
    return last_result;
}

fn findJobByPid(session: *session_mod.Session, pid: std.c.pid_t) ?*job_mod.Job {
    for (session.jobs.list()) |j| {
        for (j.processes) |p| if (p.pid == pid) return j;
    }
    return null;
}

fn pickPendingBgJob(session: *session_mod.Session) ?*job_mod.Job {
    for (session.jobs.list()) |j| {
        if (!j.detached) continue;
        switch (j.state) {
            .done => continue,
            else => return j,
        }
    }
    return null;
}

/// `%N` or bare integer N. Returns the parsed numeric job id, or null
/// if the argument doesn't fit either form.
fn parseJobSpec(arg: []const u8) ?u32 {
    var bytes = arg;
    if (bytes.len >= 1 and bytes[0] == '%') bytes = bytes[1..];
    return std.fmt.parseInt(u32, bytes, 10) catch null;
}

// =============================================================================
// trap
// =============================================================================
//
// Surface forms:
//   trap CMD  SIG ...      register CMD as the handler for each SIG
//   trap ''   SIG ...      ignore the signal
//   trap '-'  SIG ...      restore default disposition
//
// CMD is parsed and lowered at registration time, not at fire time, so
// surface errors surface immediately. Real signals install a minimal
// async-signal-safe handler that flips a flag in the session's trap
// table; the eval safe-point loop drains the flag and runs the trap
// program in shell context. The pseudo-signal `EXIT` runs at shell
// exit (no signal handler involved) and is the most common form.

fn trapFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    if (argv.len < 3) {
        _ = writeAllToFd(io.stderr, "trap: usage: trap CMD SIGNAL [SIGNAL...]\n");
        return .{ .exited = 2 };
    }
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    const cmd = argv[1];
    const sig_args = argv[2..];

    // Pre-parse + pre-lower if a real handler is being installed. Errors
    // surface here so the user finds out at trap time.
    var prepared_arena: ?std.heap.ArenaAllocator = null;
    var prepared_program: ?*const program_mod.Program = null;
    const action: enum { run, ignore, default } = blk: {
        if (cmd.len == 0) break :blk .ignore;
        if (std.mem.eql(u8, cmd, "-")) break :blk .default;

        var arena = std.heap.ArenaAllocator.init(session.alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        const source = diag.Source{ .name = "<trap>", .text = cmd };
        const parsed = shape_mod.parse(source, a, null) catch {
            arena.deinit();
            _ = writeAllToFd(io.stderr, "trap: parse error in trap source\n");
            return .{ .exited = 1 };
        };
        const low_ctx = program_mod.LowerContext{ .alloc = a, .source = source };
        const prog = program_mod.lower(parsed.root, &low_ctx, null) catch {
            arena.deinit();
            _ = writeAllToFd(io.stderr, "trap: lower error in trap source\n");
            return .{ .exited = 1 };
        };
        prepared_arena = arena;
        prepared_program = prog;
        break :blk .run;
    };

    // Apply to every named signal. If any signal name is bad, abort
    // before installing — partial install is worse than no install.
    var sigs = std.ArrayListUnmanaged(session_mod.TrapSignal).empty;
    defer sigs.deinit(session.alloc);
    for (sig_args) |name| {
        const sig = session_mod.TrapTable.parseSignal(name) orelse {
            if (prepared_arena) |*arena| arena.deinit();
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "trap: unknown signal `{s}`\n", .{name}) catch "trap: unknown signal\n";
            _ = writeAllToFd(io.stderr, msg);
            return .{ .exited = 1 };
        };
        try sigs.append(session.alloc, sig);
    }

    for (sigs.items, 0..) |sig, i| {
        switch (action) {
            .ignore => {
                session.traps.setIgnore(sig);
                installSignalDispatch(sig, .ignore);
            },
            .default => {
                session.traps.setDefault(sig);
                installSignalDispatch(sig, .default);
            },
            .run => {
                if (i == 0) {
                    session.traps.setRun(sig, prepared_arena.?, prepared_program.?);
                    prepared_arena = null;
                } else {
                    // Subsequent signals share the same source — re-parse
                    // and re-lower into a fresh arena per slot so the
                    // table owns each entry independently.
                    var arena = std.heap.ArenaAllocator.init(session.alloc);
                    const a = arena.allocator();
                    const source = diag.Source{ .name = "<trap>", .text = cmd };
                    const parsed = shape_mod.parse(source, a, null) catch {
                        arena.deinit();
                        continue;
                    };
                    const low_ctx = program_mod.LowerContext{ .alloc = a, .source = source };
                    const prog = program_mod.lower(parsed.root, &low_ctx, null) catch {
                        arena.deinit();
                        continue;
                    };
                    session.traps.setRun(sig, arena, prog);
                }
                installSignalDispatch(sig, .run);
            },
        }
    }
    return .{ .exited = 0 };
}

const SignalDispatch = enum { run, ignore, default };

/// Install (or remove) the per-signal disposition. Real signals get a
/// minimal handler that toggles the session's pending flag via a
/// `current_session` pointer. EXIT is a pseudo-signal — no kernel
/// handler is installed; the trap fires on shell exit instead.
fn installSignalDispatch(sig: session_mod.TrapSignal, mode: SignalDispatch) void {
    if (sig == .EXIT) return;
    const sig_id = sigToCSig(sig);
    var sa: std.posix.Sigaction = .{
        .handler = switch (mode) {
            .ignore => .{ .handler = std.c.SIG.IGN },
            .default => .{ .handler = std.c.SIG.DFL },
            .run => .{ .handler = trapSignalHandler },
        },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    std.posix.sigaction(sig_id, &sa, null);
}

fn sigToCSig(sig: session_mod.TrapSignal) std.c.SIG {
    return switch (sig) {
        .EXIT => unreachable,
        .HUP => .HUP,
        .INT => .INT,
        .QUIT => .QUIT,
        .TERM => .TERM,
        .USR1 => .USR1,
        .USR2 => .USR2,
    };
}

/// Module-level pointer to the session whose trap table the handler
/// should mark. Slash is single-session per process; `installSession`
/// is called once near startup. The handler itself does nothing more
/// than flip a boolean — async-signal-safe per PLAN §19.
var current_session: ?*session_mod.Session = null;

pub fn installSession(s: *session_mod.Session) void {
    current_session = s;
}

/// Read accessor for the SIGCHLD handler living in `repl.zig` —
/// keeping the global module-private but exposing a getter avoids
/// scattering raw `*Session` pointers across the codebase.
pub fn currentSession() ?*session_mod.Session {
    return current_session;
}

fn trapSignalHandler(sig_id: std.c.SIG) callconv(.c) void {
    const s = current_session orelse return;
    const sig: session_mod.TrapSignal = switch (sig_id) {
        .HUP => .HUP,
        .INT => .INT,
        .QUIT => .QUIT,
        .TERM => .TERM,
        .USR1 => .USR1,
        .USR2 => .USR2,
        else => return,
    };
    s.traps.markPending(sig);
}

// =============================================================================
// fg / bg / kill / disown
// =============================================================================
//
// Job-control surface (PLAN §7 Rule 22, §19, §20.3 "Job control operates on
// groups, not individual pids"). All four operate against the session's
// JobTable; `kill` also accepts raw pids for ad-hoc signaling.
//
// `fg` and `bg` send `SIGCONT` to the target job's process group via
// `kill(-pgid, SIGCONT)` and update Job state. `fg` hands the controlling
// terminal to the resumed pgrp via `tcsetpgrp`, blocks via `job.service
// (.foreground, target)` until the job is done or stopped again, and
// then takes the terminal back so the shell's prompt stays usable.
// `bg` only sends `SIGCONT` — backgrounded jobs never own the tty.
//
// `kill -SIG TARGET...` parses the signal as a name (`-INT`, `-HUP`,
// `-CONT`, ...) or a number (`-9`, `-15`); default is `TERM`. Targets are
// `pid` (positive integer; the kernel routes negative pids to process
// groups but slash makes that explicit via `%N` instead) or `%N` (job id).
//
// `disown` removes a job from `Session.jobs` without signaling it. The
// underlying process group keeps running; the shell simply forgets it.
// `disown -a` removes every detached job; `disown` (no args) targets the
// current background job (most recent detached job that isn't done).

/// Most-recent eligible job for `fg`/`bg`/`disown` with no args. Picks
/// the highest-id job that is detached or stopped.
fn pickCurrentJob(session: *session_mod.Session) ?*job_mod.Job {
    const list = session.jobs.list();
    var i: usize = list.len;
    while (i > 0) {
        i -= 1;
        const j = list[i];
        switch (j.state) {
            .done => continue,
            .stopped => return j,
            .running, .pending => if (j.detached) return j,
        }
    }
    return null;
}

/// Resolve a `%N`/`N` job spec or fall back to the current job. Emits
/// the matching error to stderr and returns null on failure.
fn resolveJobArg(
    session: *session_mod.Session,
    builtin_name: []const u8,
    arg: ?[]const u8,
) ?*job_mod.Job {
    if (arg) |a| {
        const id = parseJobSpec(a) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: invalid job id `{s}`\n", .{ builtin_name, a }) catch "";
            _ = std.c.write(2, msg.ptr, msg.len);
            return null;
        };
        return session.jobs.lookup(id) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: no such job {d}\n", .{ builtin_name, id }) catch "";
            _ = std.c.write(2, msg.ptr, msg.len);
            return null;
        };
    }
    return pickCurrentJob(session) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: no current job\n", .{builtin_name}) catch "";
        _ = std.c.write(2, msg.ptr, msg.len);
        return null;
    };
}

/// `kill(-pgid, sig)` — POSIX form for "signal every process in this
/// process group." Returns true if the syscall reported success.
fn signalGroup(pgid: std.c.pid_t, sig: std.c.SIG) bool {
    if (pgid <= 0) return false;
    return std.c.kill(-pgid, sig) == 0;
}

fn signalProcess(pid: std.c.pid_t, sig: std.c.SIG) bool {
    return std.c.kill(pid, sig) == 0;
}

fn fgFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };
    const arg: ?[]const u8 = if (argv.len >= 2) argv[1] else null;
    const j = resolveJobArg(session, "fg", arg) orelse return .{ .exited = 1 };
    if (j.state == .done) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fg: job {d} already done\n", .{j.id}) catch "fg: job done\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        return .{ .exited = 1 };
    }

    // Announce only when there's an actual transition. `fg` on a
    // stopped job is a Continued — the program was paused and is
    // about to run again. `fg` on an already-running detached job
    // (`sleep 30 &`, then `fg %1`) doesn't continue anything; it
    // just brings the job to the foreground. Bash echoes the
    // command line in that case; we elide the notice and rely on
    // the next prompt boundary to surface any subsequent failure.
    if (j.state == .stopped) {
        notice.jobStateChange(session, j, .continued_fg);
    }

    // APUE order: give the tty to the job (handoff + termios install),
    // mark the job foreground, send SIGCONT if it was stopped, block
    // on the wait, reclaim the tty.
    //
    // The terminal dance lives in `terminal.zig` so both this builtin
    // and eval's foreground-wait sites use one implementation. We
    // can't use `terminal.runForeground` directly here because we
    // need to interleave SIGCONT between handoff and wait — see the
    // documented call order in terminal.zig.
    terminal_mod.giveToJob(session, j);

    if (j.state == .stopped) {
        for (j.processes) |*p| switch (p.state) {
            .stopped => p.state = .running,
            else => {},
        };
        j.state = .running;
        _ = signalGroup(j.pgid, .CONT);
    }
    j.detached = false;
    j.foreground = true;

    try job_mod.service(&session.jobs, .foreground, j);

    terminal_mod.reclaimForShell(session, j);
    return j.result orelse Result{ .exited = 0 };
}

fn bgFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };
    const arg: ?[]const u8 = if (argv.len >= 2) argv[1] else null;
    const j = resolveJobArg(session, "bg", arg) orelse return .{ .exited = 1 };
    if (j.state == .done) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "bg: job {d} already done\n", .{j.id}) catch "bg: job done\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        return .{ .exited = 1 };
    }

    // `bg` on a stopped job is the only meaningful transition —
    // resume in the background. On an already-running detached job
    // it's idempotent and silent: nothing was actually continued.
    const was_stopped = j.state == .stopped;
    if (was_stopped) {
        for (j.processes) |*p| switch (p.state) {
            .stopped => p.state = .running,
            else => {},
        };
        j.state = .running;
        _ = signalGroup(j.pgid, .CONT);
    }
    j.detached = true;
    j.foreground = false;
    // Mirror POSIX: backgrounding a job (whether by `&` or `bg`) makes
    // it the new `$!` target. Use the last process in the group so
    // `wait $!` returns the meaningful exit status.
    if (j.processes.len > 0) {
        session.last_bg_pid = j.processes[j.processes.len - 1].pid;
    }

    if (was_stopped) {
        notice.jobStateChange(session, j, .continued_bg);
    }
    return .{ .exited = 0 };
}

/// Map a textual signal name (`HUP`, `SIGHUP`, `INT`, ...) or a numeric
/// string (`9`, `15`) to a `std.c.SIG`. Returns null on unknown names or
/// numbers without a matching enum value.
fn parseSignalName(arg: []const u8) ?std.c.SIG {
    var name = arg;
    if (name.len >= 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG"))
        name = name[3..];

    if (std.ascii.isDigit(name[0])) {
        const n = std.fmt.parseInt(c_int, name, 10) catch return null;
        return signalFromNumber(n);
    }

    var upper_buf: [16]u8 = undefined;
    if (name.len >= upper_buf.len) return null;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];

    const Map = struct { n: []const u8, s: std.c.SIG };
    const table = [_]Map{
        .{ .n = "HUP", .s = .HUP },
        .{ .n = "INT", .s = .INT },
        .{ .n = "QUIT", .s = .QUIT },
        .{ .n = "ILL", .s = .ILL },
        .{ .n = "TRAP", .s = .TRAP },
        .{ .n = "ABRT", .s = .ABRT },
        .{ .n = "BUS", .s = .BUS },
        .{ .n = "FPE", .s = .FPE },
        .{ .n = "KILL", .s = .KILL },
        .{ .n = "USR1", .s = .USR1 },
        .{ .n = "SEGV", .s = .SEGV },
        .{ .n = "USR2", .s = .USR2 },
        .{ .n = "PIPE", .s = .PIPE },
        .{ .n = "ALRM", .s = .ALRM },
        .{ .n = "TERM", .s = .TERM },
        .{ .n = "CONT", .s = .CONT },
        .{ .n = "STOP", .s = .STOP },
        .{ .n = "TSTP", .s = .TSTP },
        .{ .n = "TTIN", .s = .TTIN },
        .{ .n = "TTOU", .s = .TTOU },
        .{ .n = "CHLD", .s = .CHLD },
    };
    for (table) |m| {
        if (std.mem.eql(u8, upper, m.n)) return m.s;
    }
    return null;
}

fn signalFromNumber(n: c_int) ?std.c.SIG {
    inline for (@typeInfo(std.c.SIG).@"enum".fields) |f| {
        if (f.value == n) return @as(std.c.SIG, @enumFromInt(f.value));
    }
    return null;
}

fn killFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    const session_opt: ?*session_mod.Session = switch (ctx) {
        .shell => |s| s,
        .child => null,
    };

    var sig: std.c.SIG = .TERM;
    var i: usize = 1;

    if (i < argv.len and argv[i].len >= 2 and argv[i][0] == '-') {
        const flag = argv[i][1..];
        if (std.mem.eql(u8, flag, "l")) {
            const list_str =
                "HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 " ++
                "PIPE ALRM TERM CONT STOP TSTP TTIN TTOU CHLD\n";
            _ = writeAllToFd(io.stdout, list_str);
            return .{ .exited = 0 };
        }
        sig = parseSignalName(flag) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "kill: {s}: invalid signal\n", .{flag}) catch "kill: invalid signal\n";
            _ = writeAllToFd(io.stderr, msg);
            return .{ .exited = 2 };
        };
        i += 1;
    }

    if (i >= argv.len) {
        _ = writeAllToFd(io.stderr, "kill: usage: kill [-SIG] PID|%JOB ...\n");
        return .{ .exited = 2 };
    }

    var any_failed = false;
    while (i < argv.len) : (i += 1) {
        const target = argv[i];
        if (target.len >= 1 and target[0] == '%') {
            const session = session_opt orelse {
                _ = writeAllToFd(io.stderr, "kill: %job not valid in non-shell context\n");
                any_failed = true;
                continue;
            };
            const id = parseJobSpec(target) orelse {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "kill: invalid job id `{s}`\n", .{target}) catch "";
                _ = writeAllToFd(io.stderr, msg);
                any_failed = true;
                continue;
            };
            const j = session.jobs.lookup(id) orelse {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "kill: no such job {d}\n", .{id}) catch "";
                _ = writeAllToFd(io.stderr, msg);
                any_failed = true;
                continue;
            };
            if (!signalGroup(j.pgid, sig)) any_failed = true;
        } else {
            const pid = std.fmt.parseInt(std.c.pid_t, target, 10) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "kill: invalid pid `{s}`\n", .{target}) catch "";
                _ = writeAllToFd(io.stderr, msg);
                any_failed = true;
                continue;
            };
            if (!signalProcess(pid, sig)) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "kill: ({d}) failed\n", .{pid}) catch "";
                _ = writeAllToFd(io.stderr, msg);
                any_failed = true;
            }
        }
    }
    return .{ .exited = if (any_failed) 1 else 0 };
}

fn disownFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    _ = io;
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    // `disown -a` clears every disownable job (detached or stopped) —
    // crucially **not** zero-child shell-context jobs (including the
    // disown call itself, which is still held by the eval frame). No
    // arg removes the current job; `%N` / `N` removes a specific job
    // and rejects targets that aren't disownable.
    var remove_all = false;
    var arg: ?[]const u8 = null;
    if (argv.len >= 2) {
        if (std.mem.eql(u8, argv[1], "-a")) {
            remove_all = true;
        } else {
            arg = argv[1];
        }
    }

    if (remove_all) {
        var i: usize = session.jobs.jobs.items.len;
        while (i > 0) {
            i -= 1;
            const j = session.jobs.jobs.items[i];
            if (!isDisownable(j)) continue;
            removeJobAt(session, i);
        }
        return .{ .exited = 0 };
    }

    const j = resolveJobArg(session, "disown", arg) orelse return .{ .exited = 1 };
    if (!isDisownable(j)) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "disown: job {d} not disownable\n", .{j.id}) catch "";
        _ = std.c.write(2, msg.ptr, msg.len);
        return .{ .exited = 1 };
    }
    const idx = jobIndex(session, j) orelse return .{ .exited = 1 };
    removeJobAt(session, idx);
    return .{ .exited = 0 };
}

/// A job is disownable only if it's a real backgrounded process group
/// (detached or stopped). Zero-child shell-context jobs are runtime
/// bookkeeping — disowning one would yank the rug out from under the
/// builtin currently using it.
fn isDisownable(j: *job_mod.Job) bool {
    if (j.processes.len == 0) return false;
    return switch (j.state) {
        .stopped => true,
        .running, .pending => j.detached,
        .done => false,
    };
}

fn jobIndex(session: *session_mod.Session, target: *job_mod.Job) ?usize {
    for (session.jobs.jobs.items, 0..) |j, i| {
        if (j == target) return i;
    }
    return null;
}

/// Free a job's owned memory and remove it from the table. Does NOT
/// signal the underlying process group — `disown` leaves the children
/// running; the shell just forgets them.
fn removeJobAt(session: *session_mod.Session, idx: usize) void {
    const t = &session.jobs;
    const j = t.jobs.items[idx];
    t.alloc.free(j.processes);
    if (j.command_text) |txt| t.alloc.free(txt);
    t.alloc.destroy(j);
    _ = t.jobs.orderedRemove(idx);
}

// =============================================================================
// str — editor-only literal-text rewrites (PLAN §12)
// =============================================================================
//
// Surface forms (cooked / bare-args, handled here in the builtin):
//
//   str                    list every str (sorted), exit 0
//   str NAME               query: "str 'NAME' 'VALUE'\n", exit 0; 1 silent if unset
//   str NAME ARGS...       set NAME to ARGS joined with " " (cooked argv)
//   str -e NAME...         erase named, idempotent, silent on missing, exit 0
//   str -e (no names)      usage error, exit 2
//   str BAD-NAME ...       validation error, exit 1, stderr message
//
// The shell never expands `str` entries — registration just stores
// bytes. Expansion is driven by the REPL's keystroke handler (see
// `repl.expandStrSpace`). Per PLAN §12 the rules are strict:
//
//   - LHS must lex as a single bare `.ident` token, must not be a
//     slash keyword, must not start with `-` (would clash with -e).
//   - RHS bytes must be valid UTF-8 with no NUL/CR/LF/DEL/C0 except
//     tab — exactly the editor-text contract zigline enforces on
//     every buffer mutation.
//   - Empty RHS is allowed and is a real, distinct stored value:
//     when the candidate fires, the typed name is deleted from the
//     buffer (vs. an unset name, which inserts a literal space).
//
// The brace form (`str NAME { body }`) goes through the grammar +
// lexer wrapper (raw byte capture, no shell expansion) and lands at
// `session.strs.set(name, body)` directly — see `eval.evalStrDef`.
// This builtin only handles the cooked / bare-args / management forms.

fn strFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    const args = argv[1..];

    if (args.len == 0) return listStrs(session, io);

    if (std.mem.eql(u8, args[0], "-e")) {
        if (args.len < 2) {
            _ = writeAllToFd(io.stderr, "str: -e: usage: str -e NAME [NAME...]\n");
            return .{ .exited = 2 };
        }
        return eraseStrs(session, args[1..]);
    }

    if (args.len == 1) return queryStr(session, io, args[0]);
    return setStr(session, io, args[0], args[1..]);
}

fn listStrs(session: *session_mod.Session, io: BuiltinIo) anyerror!Result {
    const names = try session.strs.sortedNames(session.alloc);
    defer session.alloc.free(names);
    for (names) |name| {
        const value = session.strs.lookup(name) orelse continue;
        try writeStrLine(session.alloc, io.stdout, name, value);
    }
    return .{ .exited = 0 };
}

fn queryStr(session: *session_mod.Session, io: BuiltinIo, name: []const u8) anyerror!Result {
    const value = session.strs.lookup(name) orelse return .{ .exited = 1 };
    try writeStrLine(session.alloc, io.stdout, name, value);
    return .{ .exited = 0 };
}

fn setStr(
    session: *session_mod.Session,
    io: BuiltinIo,
    name: []const u8,
    value_parts: []const []const u8,
) anyerror!Result {
    if (validateStrName(name)) |reason| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "str: invalid name '{s}': {s}\n", .{ name, reason }) catch "str: invalid name\n";
        _ = writeAllToFd(io.stderr, msg);
        return .{ .exited = 1 };
    }

    const value = try std.mem.join(session.alloc, " ", value_parts);
    defer session.alloc.free(value);

    if (validateStrValue(value)) |reason| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "str: invalid value: {s}\n", .{reason}) catch "str: invalid value\n";
        _ = writeAllToFd(io.stderr, msg);
        return .{ .exited = 1 };
    }

    try session.strs.set(name, value);
    return .{ .exited = 0 };
}

/// Idempotent erase. Missing names are not an error — a `str -e foo`
/// followed by another `str -e foo` both succeed silently (`mkdir
/// -p` / `rm -f` semantics). Scripts that want "ensure foo is gone"
/// don't need `|| true`.
fn eraseStrs(
    session: *session_mod.Session,
    names: []const []const u8,
) anyerror!Result {
    for (names) |name| {
        _ = session.strs.unset(name);
    }
    return .{ .exited = 0 };
}

/// Emit one `str 'NAME' 'VALUE'` line. Both LHS and RHS are quoted so
/// the listing is round-trippable Slash source: a name like `*` or `~`
/// re-registers as the same literal name when fed back to the shell,
/// no glob expansion or tilde substitution in the way.
fn writeStrLine(alloc: Allocator, fd: i32, name: []const u8, value: []const u8) !void {
    const quoted_name = try word_mod.quoteSingleForSlash(alloc, name);
    defer alloc.free(quoted_name);
    const quoted_value = try word_mod.quoteSingleForSlash(alloc, value);
    defer alloc.free(quoted_value);
    var line = try std.ArrayListUnmanaged(u8).initCapacity(alloc, quoted_name.len + quoted_value.len + 8);
    defer line.deinit(alloc);
    try line.appendSlice(alloc, "str ");
    try line.appendSlice(alloc, quoted_name);
    try line.append(alloc, ' ');
    try line.appendSlice(alloc, quoted_value);
    try line.append(alloc, '\n');
    _ = writeAllToFd(fd, line.items);
}

/// Returns `null` if `name` is a valid `str` LHS, or a short English
/// reason if it isn't. The legal set is exactly "what
/// `parser.BaseLexer` would lex as one whole `.ident` token, isn't a
/// slash keyword, and doesn't start with `-`". Reusing the lexer
/// keeps validation and trigger-eligibility identical: an LHS the
/// registrar accepts is precisely an LHS the keystroke scanner can
/// match.
pub fn validateStrName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "empty name";
    if (!std.unicode.utf8ValidateSlice(name)) return "not valid UTF-8";
    if (name[0] == '-') return "names starting with '-' clash with str -e";

    var lex = parser.BaseLexer.init(name);
    const first = lex.next();
    if (first.cat != .ident) return "must lex as a single bare ident";
    if (first.pos != 0) return "must lex as a single bare ident";
    if (@as(usize, first.len) != name.len) return "must lex as a single bare ident";

    const after = lex.next();
    if (after.cat != .eof) return "must lex as a single bare ident";

    if (slash.keywordAs(name) != null) return "is a slash keyword";

    return null;
}

/// Returns `null` if `value` is editor-safe RHS bytes, else a short
/// reason. Mirrors zigline's `replace_buffer` / `insert_text`
/// constraints: valid UTF-8, no NUL, no CR/LF (single-line invariant),
/// no DEL, no C0 controls EXCEPT horizontal tab — `awk '{print $1\t$2}'`
/// and similar idioms occasionally need a literal tab.
pub fn validateStrValue(value: []const u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return "not valid UTF-8";
    for (value) |c| {
        if (c == 0) return "contains NUL byte";
        if (c == '\n' or c == '\r') return "contains newline";
        if (c == 0x09) continue; // tab is allowed
        if (c < 0x20) return "contains control byte";
        if (c == 0x7f) return "contains DEL byte";
    }
    return null;
}

// =============================================================================
// history — list / search the slash-side HistoryIndex
// =============================================================================
//
// Surface forms:
//
//   history                 list recent entries chronologically (last N)
//   history -n N            list the most-recent N
//   history -s QUERY        ranked search (substring match, ranking by
//                            frecency + cwd boost + recency + frequency)
//   history -p QUERY        ranked search (prefix-only)
//   history --json          emit one JSON object per event for tooling
//
// The flat-listing form prints `<seq>  <line>` so users can copy/paste.
// The search form prints `<line>` only — designed to feed `head`/`grep`.

const default_history_limit: usize = 50;

fn historyFn(argv: []const []const u8, io: BuiltinIo, ctx: BuiltinContext) anyerror!Result {
    const session = switch (ctx) {
        .shell => |s| s,
        .child => return .{ .exited = 0 },
    };

    const args = argv[1..];

    var search_query: ?[]const u8 = null;
    var search_mode: history_mod.SearchMode = .substring;
    var limit: usize = default_history_limit;
    var json_out = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--search")) {
            i += 1;
            if (i >= args.len) {
                _ = writeAllToFd(io.stderr, "history: -s requires a query argument\n");
                return .{ .exited = 2 };
            }
            search_query = args[i];
            search_mode = .substring;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--prefix")) {
            i += 1;
            if (i >= args.len) {
                _ = writeAllToFd(io.stderr, "history: -p requires a prefix argument\n");
                return .{ .exited = 2 };
            }
            search_query = args[i];
            search_mode = .prefix;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) {
                _ = writeAllToFd(io.stderr, "history: -n requires a count argument\n");
                return .{ .exited = 2 };
            }
            limit = std.fmt.parseInt(usize, args[i], 10) catch {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "history: -n: invalid count '{s}'\n", .{args[i]}) catch "history: -n: bad count\n";
                _ = writeAllToFd(io.stderr, msg);
                return .{ .exited = 2 };
            };
        } else if (std.mem.eql(u8, a, "--json")) {
            json_out = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            _ = writeAllToFd(io.stdout,
                "history                  list recent (default 50)\n" ++
                "history -n COUNT         list COUNT most-recent\n" ++
                "history -s QUERY         ranked substring search\n" ++
                "history -p PREFIX        ranked prefix search\n" ++
                "history --json           emit JSONL records\n");
            return .{ .exited = 0 };
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "history: unrecognized argument '{s}'\n", .{a}) catch "history: bad argument\n";
            _ = writeAllToFd(io.stderr, msg);
            return .{ .exited = 2 };
        }
    }

    const idx_ptr = if (session.history) |*h| h else {
        // No history index — interactive entry point didn't run, or
        // init failed. Empty list, exit 0 to keep scripts happy.
        return .{ .exited = 0 };
    };

    if (search_query) |q| {
        return searchHistoryAndPrint(idx_ptr, io, q, search_mode, limit);
    }
    return listHistoryAndPrint(idx_ptr, io, limit, json_out);
}

fn listHistoryAndPrint(
    idx: *const history_mod.HistoryIndex,
    io: BuiltinIo,
    limit: usize,
    json_out: bool,
) anyerror!Result {
    const events = idx.eventsSlice();
    const start: usize = if (events.len > limit) events.len - limit else 0;
    var line_buf = try std.ArrayListUnmanaged(u8).initCapacity(idx.alloc, 256);
    defer line_buf.deinit(idx.alloc);
    for (events[start..]) |ev| {
        line_buf.clearRetainingCapacity();
        if (json_out) {
            try writeHistoryJsonLine(idx.alloc, &line_buf, ev);
        } else {
            try writeHistoryListLine(idx.alloc, &line_buf, ev);
        }
        _ = writeAllToFd(io.stdout, line_buf.items);
    }
    return .{ .exited = 0 };
}

fn searchHistoryAndPrint(
    idx: *const history_mod.HistoryIndex,
    io: BuiltinIo,
    query: []const u8,
    mode: history_mod.SearchMode,
    limit: usize,
) anyerror!Result {
    var cwd_buf: [4096]u8 = undefined;
    extern_getcwd: {
        if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) {
            cwd_buf[0] = '?';
            cwd_buf[1] = 0;
            break :extern_getcwd;
        }
    }
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&cwd_buf)), 0);

    const results = try idx.search(idx.alloc, query, cwd, mode, limit);
    defer idx.alloc.free(results);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(idx.alloc);
    for (results) |r| {
        out.clearRetainingCapacity();
        try out.appendSlice(idx.alloc, r.line);
        try out.append(idx.alloc, '\n');
        _ = writeAllToFd(io.stdout, out.items);
    }
    return .{ .exited = 0 };
}

fn writeHistoryListLine(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    ev: history_mod.HistoryEvent,
) !void {
    var num_buf: [32]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&num_buf, "{d:>5}", .{ev.seq}) catch return;
    try out.appendSlice(alloc, seq_str);
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, ev.line);
    try out.append(alloc, '\n');
}

fn writeHistoryJsonLine(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    ev: history_mod.HistoryEvent,
) !void {
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(alloc, "{\"seq\":");
    try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{ev.seq}) catch "0");
    try out.appendSlice(alloc, ",\"ts\":");
    try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{ev.ts_s}) catch "0");
    try out.appendSlice(alloc, ",\"cwd\":");
    try writeJsonStringSimple(alloc, out, ev.cwd);
    try out.appendSlice(alloc, ",\"line\":");
    try writeJsonStringSimple(alloc, out, ev.line);
    if (ev.status) |s| {
        try out.appendSlice(alloc, ",\"status\":");
        try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{s}) catch "0");
    }
    if (ev.duration_s) |d| {
        try out.appendSlice(alloc, ",\"dur\":");
        try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{d}) catch "0");
    }
    try out.appendSlice(alloc, "}\n");
}

fn writeJsonStringSimple(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
) !void {
    try out.append(alloc, '"');
    for (bytes) |b| switch (b) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (b < 0x20) {
            var u_buf: [8]u8 = undefined;
            const formatted = std.fmt.bufPrint(&u_buf, "\\u{x:0>4}", .{b}) catch "";
            try out.appendSlice(alloc, formatted);
        } else try out.append(alloc, b),
    };
    try out.append(alloc, '"');
}
