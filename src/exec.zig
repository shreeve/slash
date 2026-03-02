//! Slash Executor
//!
//! Walks s-expressions produced by the parser and executes them.
//!
//! Pipeline:
//!   source text → lexer → parser → s-expressions → Shell (this)
//!
//! Handles:
//!   - Command execution (fork/execvpe)
//!   - Pipelines (pipe + fork)
//!   - Redirections (dup2)
//!   - Variable expansion
//!   - Conditionals, loops, try/match
//!   - User commands (cmd)
//!   - Builtins (cd, exit, source, set, etc.)

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");
const Sexp = parser.Sexp;
const Tag = parser.Tag;
const Parser = parser.Parser;

pub const Shell = struct {
    allocator: Allocator,

    /// Shell variables ($name → value)
    vars: std.StringHashMap([]const u8),

    /// Exit code of the last command ($?)
    last_exit: u8 = 0,

    /// User-defined commands (cmd name body)
    user_cmds: std.StringHashMap(Sexp),

    pub fn init(alloc: Allocator) Shell {
        return .{
            .allocator = alloc,
            .vars = std.StringHashMap([]const u8).init(alloc),
            .user_cmds = std.StringHashMap(Sexp).init(alloc),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.vars.deinit();
        self.user_cmds.deinit();
    }

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    /// Execute a single line of input (interactive / -c mode).
    pub fn execLine(self: *Shell, source: []const u8) void {
        var p = Parser.init(self.allocator, source);
        defer p.deinit();
        const sexp = p.parseOneline() catch |err| {
            std.debug.print("parse error: {s}\n", .{@errorName(err)});
            self.last_exit = 2;
            return;
        };
        self.eval(sexp, source);
    }

    /// Execute a full script (program mode).
    pub fn execSource(self: *Shell, source: []const u8) void {
        var p = Parser.init(self.allocator, source);
        defer p.deinit();
        const sexp = p.parseProgram() catch |err| {
            std.debug.print("parse error: {s}\n", .{@errorName(err)});
            self.last_exit = 2;
            return;
        };
        self.eval(sexp, source);
    }

    // =========================================================================
    // S-EXPRESSION EVALUATOR
    // =========================================================================

    fn eval(self: *Shell, sexp: Sexp, source: []const u8) void {
        switch (sexp) {
            .nil => {},
            .tag => {},
            .src => {},
            .str => {},
            .list => |items| {
                if (items.len == 0) return;
                const head = items[0];
                switch (head) {
                    .tag => |tag| self.dispatch(tag, items[1..], source),
                    else => {},
                }
            },
        }
    }

    fn dispatch(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8) void {
        switch (tag) {
            .program => self.evalProgram(args, source),
            .cmd => self.evalCmd(args, source),
            .pipe => self.evalPipe(args, source),
            .pipe_err => self.evalPipe(args, source),
            .@"and" => self.evalAnd(args, source),
            .@"or" => self.evalOr(args, source),
            .seq => self.evalSeq(args, source),
            .bg => self.evalBg(args, source),
            .not => self.evalNot(args, source),
            .subshell => self.evalSubshell(args, source),
            .assign => self.evalAssign(args, source),
            // .unset removed — use builtin command instead
            .@"if" => self.evalIf(args, source),
            .@"for" => self.evalFor(args, source),
            .@"while" => self.evalWhile(args, source),
            .block => self.evalBlock(args, source),
            .exit => self.evalExit(args, source),
            .source => self.evalSource(args, source),
            .cmd_def => self.evalCmdDef(args, source),
            .cmd_list => self.evalCmdList(),
            else => {
                std.debug.print("slash: unhandled tag: {s}\n", .{@tagName(tag)});
                self.last_exit = 1;
            },
        }
    }

    // =========================================================================
    // NODE EVALUATORS
    // =========================================================================

    fn evalProgram(self: *Shell, args: []const Sexp, source: []const u8) void {
        for (args) |child| {
            self.eval(child, source);
        }
    }

    fn evalBlock(self: *Shell, args: []const Sexp, source: []const u8) void {
        for (args) |child| {
            self.eval(child, source);
        }
    }

    fn evalCmd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;

        // Build argv by joining adjacent tokens (pre==0 means no whitespace gap)
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);

        for (args) |arg| {
            switch (arg) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    if (argv_list.items.len > 0) {
                        const prev = argv_list.items[argv_list.items.len - 1];
                        const prev_start = @intFromPtr(prev.ptr) - @intFromPtr(source.ptr);
                        const prev_end = prev_start + prev.len;
                        if (s.pos == prev_end) {
                            // Contiguous in source — extend previous slice
                            argv_list.items[argv_list.items.len - 1] = source[prev_start .. s.pos + s.len];
                            continue;
                        }
                    }
                    argv_list.append(self.allocator, text) catch {};
                },
                .list => |items| {
                    if (items.len > 0) {
                        switch (items[0]) {
                            .tag => |t| {
                                if (isRedirTag(t)) continue;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        const argv = argv_list.items;
        if (argv.len == 0) return;

        if (self.tryBuiltin(argv, source)) return;

        self.forkExec(argv);
    }

    fn evalPipe(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) {
            if (args.len == 1) self.eval(args[0], source);
            return;
        }

        const pipe_fds = posix.pipe() catch {
            std.debug.print("slash: pipe failed\n", .{});
            self.last_exit = 1;
            return;
        };

        const pid1 = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid1 == 0) {
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[1]);
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        const pid2 = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid2 == 0) {
            posix.close(pipe_fds[1]);
            posix.dup2(pipe_fds[0], posix.STDIN_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[0]);
            self.eval(args[1], source);
            posix.exit(self.last_exit);
        }

        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
        _ = posix.waitpid(pid1, 0);
        const result = posix.waitpid(pid2, 0);
        self.last_exit = statusToExit(result.status);
    }

    fn evalAnd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        if (self.last_exit == 0 and args.len >= 2) self.eval(args[1], source);
    }

    fn evalOr(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        if (self.last_exit != 0 and args.len >= 2) self.eval(args[1], source);
    }

    fn evalSeq(self: *Shell, args: []const Sexp, source: []const u8) void {
        for (args) |child| self.eval(child, source);
    }

    fn evalBg(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;

        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid == 0) {
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        std.debug.print("[bg] {d}\n", .{pid});
        self.last_exit = 0;
        if (args.len >= 2) self.eval(args[1], source);
    }

    fn evalNot(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        self.last_exit = if (self.last_exit == 0) 1 else 0;
    }

    fn evalSubshell(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;

        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid == 0) {
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        const result = posix.waitpid(pid, 0);
        self.last_exit = statusToExit(result.status);
    }

    fn evalAssign(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        const value = self.sexpToStr(args[1], source) orelse return;
        self.vars.put(name, value) catch {};
        self.last_exit = 0;
    }

    fn evalUnset(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        _ = self.vars.remove(name);
        self.last_exit = 0;
    }

    fn evalIf(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        self.eval(args[0], source);
        if (self.last_exit == 0) {
            self.eval(args[1], source);
        } else if (args.len >= 3) {
            self.eval(args[2], source);
        }
    }

    fn evalFor(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 3) return;

        const var_name = self.sexpToStr(args[0], source) orelse return;
        const body = args[args.len - 1];

        for (args[1 .. args.len - 1]) |word| {
            const val = self.sexpToStr(word, source) orelse continue;
            self.vars.put(var_name, val) catch continue;
            self.eval(body, source);
        }
    }

    fn evalWhile(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        while (true) {
            self.eval(args[0], source);
            if (self.last_exit != 0) break;
            self.eval(args[1], source);
        }
    }

    fn evalExit(self: *Shell, args: []const Sexp, source: []const u8) void {
        var code: u8 = 0;
        if (args.len >= 1) {
            const s = self.sexpToStr(args[0], source) orelse "0";
            code = std.fmt.parseInt(u8, s, 10) catch 0;
        }
        posix.exit(code);
    }

    fn evalSource(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const path = self.sexpToStr(args[0], source) orelse return;
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("slash: source: {s}: {s}\n", .{ path, @errorName(err) });
            self.last_exit = 1;
            return;
        };
        defer self.allocator.free(content);
        self.execSource(content);
    }

    fn evalCmdDef(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        _ = self.user_cmds.put(name, args[args.len - 1]) catch {};
        self.last_exit = 0;
    }

    fn evalCmdList(self: *Shell) void {
        var it = self.user_cmds.iterator();
        while (it.next()) |entry| {
            std.debug.print("cmd {s}\n", .{entry.key_ptr.*});
        }
        self.last_exit = 0;
    }

    // =========================================================================
    // BUILTINS
    // =========================================================================

    fn tryBuiltin(self: *Shell, argv: []const []const u8, source: []const u8) bool {
        _ = source;
        const name = argv[0];

        if (std.mem.eql(u8, name, "cd")) {
            self.builtinCd(argv);
            return true;
        } else if (std.mem.eql(u8, name, "echo")) {
            self.builtinEcho(argv);
            return true;
        } else if (std.mem.eql(u8, name, "true")) {
            self.last_exit = 0;
            return true;
        } else if (std.mem.eql(u8, name, "false")) {
            self.last_exit = 1;
            return true;
        } else if (std.mem.eql(u8, name, "type")) {
            self.builtinType(argv);
            return true;
        }

        return false;
    }

    fn builtinCd(self: *Shell, argv: []const []const u8) void {
        const target = if (argv.len > 1)
            argv[1]
        else
            std.posix.getenv("HOME") orelse "/";

        std.posix.chdir(target) catch |err| {
            std.debug.print("cd: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_exit = 1;
            return;
        };
        self.last_exit = 0;
    }

    fn builtinEcho(self: *Shell, argv: []const []const u8) void {
        const stdout = std.fs.File.stdout();
        for (argv[1..], 0..) |arg, i| {
            if (i > 0) stdout.writeAll(" ") catch {};
            stdout.writeAll(arg) catch {};
        }
        stdout.writeAll("\n") catch {};
        self.last_exit = 0;
    }

    fn builtinType(self: *Shell, argv: []const []const u8) void {
        for (argv[1..]) |name| {
            if (self.user_cmds.contains(name)) {
                std.debug.print("{s} is a user command\n", .{name});
            } else if (isBuiltin(name)) {
                std.debug.print("{s} is a shell builtin\n", .{name});
            } else {
                std.debug.print("{s}: not found\n", .{name});
            }
        }
        self.last_exit = 0;
    }

    fn isBuiltin(name: []const u8) bool {
        const builtins = [_][]const u8{ "cd", "echo", "true", "false", "type", "exit", "source", "set", "cmd", "key" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    // =========================================================================
    // EXTERNAL COMMAND EXECUTION
    // =========================================================================

    fn forkExec(self: *Shell, argv: []const []const u8) void {
        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid == 0) {
            const argv_z = toExecArgs(self.allocator, argv) catch posix.exit(127);
            const envp = getEnvP();
            posix.execvpeZ(argv_z[0].?, argv_z, envp) catch {};
            const name = argv[0];
            std.debug.print("slash: {s}: command not found\n", .{name});
            posix.exit(127);
        }

        const result = posix.waitpid(pid, 0);
        self.last_exit = statusToExit(result.status);
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    fn sexpToStr(self: *Shell, sexp: Sexp, source: []const u8) ?[]const u8 {
        _ = self;
        return switch (sexp) {
            .src => |s| source[s.pos..][0..s.len],
            .str => |s| s,
            .nil => null,
            .tag => null,
            .list => null,
        };
    }

    fn isRedirTag(tag: Tag) bool {
        return switch (tag) {
            .redir_out, .redir_append, .redir_in, .redir_err, .redir_err_app, .redir_both, .redir_dup, .herestring => true,
            else => false,
        };
    }
};

// =============================================================================
// EXEC ARGUMENT CONVERSION
// =============================================================================

fn toExecArgs(alloc: Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const buf = try alloc.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| {
        buf[i] = try alloc.dupeZ(u8, arg);
    }
    buf[argv.len] = null;
    return @ptrCast(buf.ptr);
}

fn getEnvP() [*:null]const ?[*:0]const u8 {
    return std.c.environ;
}

fn statusToExit(status: u32) u8 {
    if (posix.W.IFSIGNALED(status)) return 128 +| @as(u8, @truncate(posix.W.TERMSIG(status)));
    if (posix.W.IFEXITED(status)) return @truncate(posix.W.EXITSTATUS(status));
    return 1;
}
