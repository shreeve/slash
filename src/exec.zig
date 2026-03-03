//! Slash Executor
//!
//! Walks s-expressions produced by the parser and executes them.
//!
//! Pipeline:
//!   source text → lexer → parser → s-expressions → Shell (this)

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");
const Sexp = parser.Sexp;
const Tag = parser.Tag;
const Parser = parser.Parser;

pub const Shell = struct {
    allocator: Allocator,
    vars: std.StringHashMap([]const u8),
    last_exit: u8 = 0,
    user_cmds: std.StringHashMap(Sexp),
    options: std.StringHashMap([]const u8),

    pub fn init(alloc: Allocator) Shell {
        return .{
            .allocator = alloc,
            .vars = std.StringHashMap([]const u8).init(alloc),
            .user_cmds = std.StringHashMap(Sexp).init(alloc),
            .options = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.vars.deinit();
        self.user_cmds.deinit();
        self.options.deinit();
    }

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    pub fn execLine(self: *Shell, source: []const u8) void {
        var p = Parser.init(self.allocator, source);
        defer p.deinit();
        const sexp = p.parseOneline() catch {
            if (self.retryMathSpaced(source)) return;
            std.debug.print("parse error\n", .{});
            self.last_exit = 2;
            return;
        };
        self.eval(sexp, source);
    }

    fn retryMathSpaced(self: *Shell, source: []const u8) bool {
        const trimmed = std.mem.trimLeft(u8, source, " \t");
        if (trimmed.len == 0 or trimmed[0] != '=') return false;
        const expr_part = std.mem.trimLeft(u8, trimmed[1..], " \t");
        const spaced = spaceMathOps(self.allocator, expr_part) orelse return false;
        defer self.allocator.free(spaced);
        const wrapped = std.fmt.allocPrint(self.allocator, "= {s}", .{spaced}) catch return false;
        defer self.allocator.free(wrapped);
        var p2 = Parser.init(self.allocator, wrapped);
        defer p2.deinit();
        const sexp = p2.parseOneline() catch return false;
        self.eval(sexp, wrapped);
        return true;
    }

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
            .nil, .tag, .src, .str => {},
            .list => |items| {
                if (items.len == 0) return;
                switch (items[0]) {
                    .tag => |tag| self.dispatch(tag, items[1..], source),
                    else => {},
                }
            },
        }
    }

    fn dispatch(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8) void {
        switch (tag) {
            .program, .block => self.evalSequence(args, source),
            .cmd => self.evalCmd(args, source),
            .pipe, .pipe_err => self.evalPipe(args, source),
            .@"and" => self.evalAnd(args, source),
            .@"or" => self.evalOr(args, source),
            .xor => self.evalXor(args, source),
            .seq => self.evalSequence(args, source),
            .bg => self.evalBg(args, source),
            .not => self.evalNot(args, source),
            .subshell => self.evalSubshell(args, source),
            .display => self.evalDisplay(args, source),
            .assign => self.evalAssign(args, source),
            .unset => self.evalUnset(args, source),
            .unless => self.evalUnless(args, source),
            .until => self.evalUntil(args, source),
            .exit => self.evalExit(args, source),
            .source => self.evalSourceCmd(args, source),
            .exec => self.evalExec(args, source),
            .cmd_def => self.evalCmdDef(args, source),
            .cmd_del => self.evalCmdDel(args, source),
            .cmd_show => self.evalCmdShow(args, source),
            .cmd_list => self.evalCmdList(),
            .cmd_missing => self.evalCmdDef(args, source),
            .cmd_missing_del => { self.last_exit = 0; },
            .cmd_missing_show => { self.last_exit = 0; },
            .set_reset => self.evalSetReset(args, source),
            .set_show => self.evalSetShow(args, source),
            .set_list => self.evalSetList(),
            .key => { self.last_exit = 0; },
            .key_del => { self.last_exit = 0; },
            .eq, .ne, .lt, .gt, .le, .ge, .match, .nomatch => self.evalComparison(tag, args, source),
            .shift => { self.last_exit = 0; },
            else => self.dispatchKeyword(tag, args, source),
        }
    }

    fn dispatchKeyword(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8) void {
        const tag_name = @tagName(tag);
        if (std.mem.eql(u8, tag_name, "if")) return self.evalIf(args, source);
        if (std.mem.eql(u8, tag_name, "for")) return self.evalFor(args, source);
        if (std.mem.eql(u8, tag_name, "while")) return self.evalWhile(args, source);
        if (std.mem.eql(u8, tag_name, "try")) return self.evalTry(args, source);
        if (std.mem.eql(u8, tag_name, "else")) { if (args.len >= 1) self.eval(args[0], source); return; }
        if (std.mem.eql(u8, tag_name, "test")) return self.evalTest(args, source);
        if (std.mem.eql(u8, tag_name, "set")) return self.evalSet(args, source);
        if (std.mem.eql(u8, tag_name, "break") or std.mem.eql(u8, tag_name, "continue")) { self.last_exit = 0; return; }
        std.debug.print("slash: unhandled tag: {s}\n", .{tag_name});
        self.last_exit = 1;
    }

    // =========================================================================
    // COMMAND EXECUTION WITH REDIRECTIONS
    // =========================================================================

    const Redirect = struct {
        tag: Tag,
        target: []const u8,
    };

    const ProcSubFd = struct {
        pipe_fd: posix.fd_t,
        child_pid: posix.pid_t,
    };

    fn evalCmd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;

        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        var redir_list: std.ArrayList(Redirect) = .empty;
        defer redir_list.deinit(self.allocator);
        var procsub_fds: std.ArrayList(ProcSubFd) = .empty;
        defer procsub_fds.deinit(self.allocator);

        for (args) |arg| {
            switch (arg) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    const expanded = self.expandToken(text);
                    if (argv_list.items.len > 0 and s.pos > 0) {
                        const prev = argv_list.items[argv_list.items.len - 1];
                        const prev_start = @intFromPtr(prev.ptr) - @intFromPtr(source.ptr);
                        const prev_end = prev_start + prev.len;
                        if (s.pos == prev_end and expanded.ptr == text.ptr) {
                            argv_list.items[argv_list.items.len - 1] = source[prev_start .. s.pos + s.len];
                            continue;
                        }
                    }
                    argv_list.append(self.allocator, expanded) catch {};
                },
                .list => |items| {
                    if (items.len == 0) continue;
                    switch (items[0]) {
                        .tag => |t| {
                            if (isRedirTag(t)) {
                                self.collectRedirect(t, items[1..], source, &redir_list);
                                continue;
                            }
                            if (t == .capture) {
                                const val = self.evalCapture(items[1..], source);
                                if (val) |v| argv_list.append(self.allocator, v) catch {};
                                continue;
                            }
                            if (t == .procsub_in or t == .procsub_out) {
                                if (self.spawnProcSub(t, items[1..], source, &procsub_fds)) |path| {
                                    argv_list.append(self.allocator, path) catch {};
                                }
                                continue;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        const argv = argv_list.items;
        if (argv.len == 0) return;

        const redirs = redir_list.items;
        const has_redirs = redirs.len > 0;
        const is_builtin = isBuiltin(argv[0]);
        const is_user_cmd = self.user_cmds.get(argv[0]) != null;

        if (is_builtin or is_user_cmd) {
            var saved: [3]posix.fd_t = .{ -1, -1, -1 };
            if (has_redirs) {
                saved[0] = posix.dup(posix.STDIN_FILENO) catch -1;
                saved[1] = posix.dup(posix.STDOUT_FILENO) catch -1;
                saved[2] = posix.dup(posix.STDERR_FILENO) catch -1;
                applyRedirects(self.allocator, redirs);
            }
            if (is_builtin) {
                _ = self.tryBuiltin(argv, source);
            } else if (self.user_cmds.get(argv[0])) |body| {
                self.eval(body, source);
            }
            if (has_redirs) {
                if (saved[0] != -1) { posix.dup2(saved[0], posix.STDIN_FILENO) catch {}; posix.close(saved[0]); }
                if (saved[1] != -1) { posix.dup2(saved[1], posix.STDOUT_FILENO) catch {}; posix.close(saved[1]); }
                if (saved[2] != -1) { posix.dup2(saved[2], posix.STDERR_FILENO) catch {}; posix.close(saved[2]); }
            }
            self.cleanupProcSubs(procsub_fds.items);
            return;
        }

        self.forkExecWithRedirects(argv, redirs);
        self.cleanupProcSubs(procsub_fds.items);
    }

    fn spawnProcSub(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, fds: *std.ArrayList(ProcSubFd)) ?[]const u8 {
        if (args.len < 1) return null;
        const pipe_fds = posix.pipe() catch return null;
        const pid = posix.fork() catch return null;

        if (tag == .procsub_in) {
            if (pid == 0) {
                posix.close(pipe_fds[0]);
                posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
                posix.close(pipe_fds[1]);
                self.eval(args[0], source);
                posix.exit(self.last_exit);
            }
            posix.close(pipe_fds[1]);
            fds.append(self.allocator, .{ .pipe_fd = pipe_fds[0], .child_pid = pid }) catch {};
            return std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{pipe_fds[0]}) catch null;
        } else {
            if (pid == 0) {
                posix.close(pipe_fds[1]);
                posix.dup2(pipe_fds[0], posix.STDIN_FILENO) catch posix.exit(1);
                posix.close(pipe_fds[0]);
                self.eval(args[0], source);
                posix.exit(self.last_exit);
            }
            posix.close(pipe_fds[0]);
            fds.append(self.allocator, .{ .pipe_fd = pipe_fds[1], .child_pid = pid }) catch {};
            return std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{pipe_fds[1]}) catch null;
        }
    }

    fn cleanupProcSubs(_: *Shell, fds: []const ProcSubFd) void {
        for (fds) |ps| {
            posix.close(ps.pipe_fd);
            _ = posix.waitpid(ps.child_pid, 0);
        }
    }

    fn collectRedirect(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, list: *std.ArrayList(Redirect)) void {
        if (tag == .redir_dup) {
            list.append(self.allocator, .{ .tag = tag, .target = "" }) catch {};
            return;
        }
        if (args.len < 1) return;
        const target = if (tag == .herestring)
            self.sexpToExpandedStr(args[0], source)
        else
            self.sexpToStr(args[0], source) orelse return;
        list.append(self.allocator, .{ .tag = tag, .target = target }) catch {};
    }

    fn applyRedirects(alloc: Allocator, redirs: []const Redirect) void {
        for (redirs) |r| {
            switch (r.tag) {
                .redir_out => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDOUT_FILENO),
                .redir_append => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644, posix.STDOUT_FILENO),
                .redir_in => openAndDup(alloc, r.target, .{ .ACCMODE = .RDONLY }, 0, posix.STDIN_FILENO),
                .redir_err => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDERR_FILENO),
                .redir_err_app => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644, posix.STDERR_FILENO),
                .redir_both => {
                    openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDOUT_FILENO);
                    posix.dup2(posix.STDOUT_FILENO, posix.STDERR_FILENO) catch {};
                },
                .redir_dup => { posix.dup2(posix.STDOUT_FILENO, posix.STDERR_FILENO) catch {}; },
                .herestring => {
                    const hs_pipe = posix.pipe() catch continue;
                    _ = posix.write(hs_pipe[1], r.target) catch 0;
                    _ = posix.write(hs_pipe[1], "\n") catch 0;
                    posix.close(hs_pipe[1]);
                    posix.dup2(hs_pipe[0], posix.STDIN_FILENO) catch {};
                    posix.close(hs_pipe[0]);
                },
                else => {},
            }
        }
    }

    fn openAndDup(alloc: Allocator, target: []const u8, flags: posix.O, mode: posix.mode_t, dup_to: i32) void {
        const pathZ = alloc.dupeZ(u8, target) catch return;
        const fd = posix.openatZ(posix.AT.FDCWD, pathZ, flags, mode) catch return;
        posix.dup2(fd, dup_to) catch {};
        if (fd != dup_to) posix.close(fd);
    }

    fn forkExecWithRedirects(self: *Shell, argv: []const []const u8, redirs: []const Redirect) void {
        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid == 0) {
            applyRedirects(self.allocator, redirs);
            const argv_z = toExecArgs(self.allocator, argv) catch posix.exit(127);
            const envp = getEnvP();
            posix.execvpeZ(argv_z[0].?, argv_z, envp) catch {};
            std.debug.print("slash: {s}: command not found\n", .{argv[0]});
            posix.exit(127);
        }

        const result = posix.waitpid(pid, 0);
        self.last_exit = statusToExit(result.status);
    }

    // =========================================================================
    // VARIABLE EXPANSION
    // =========================================================================

    fn expandToken(self: *Shell, text: []const u8) []const u8 {
        if (text.len == 0) return text;

        if (text[0] == '$') {
            if (text.len >= 2 and text[1] == '{') {
                const inner = if (text.len > 3) text[2 .. text.len - 1] else return "";
                return self.lookupVar(inner);
            }
            const name = text[1..];
            return self.lookupVar(name);
        }

        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            return text[1 .. text.len - 1];
        }

        if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
            return text[1 .. text.len - 1];
        }

        return text;
    }

    fn lookupVar(self: *Shell, name: []const u8) []const u8 {
        if (name.len == 0) return "";
        if (std.mem.eql(u8, name, "?")) return self.exitCodeStr();
        if (std.mem.eql(u8, name, "$")) return self.pidStr();
        if (name[0] >= '0' and name[0] <= '9') return "";
        if (std.mem.eql(u8, name, "#")) return "0";
        if (std.mem.eql(u8, name, "*")) return "";
        if (std.mem.eql(u8, name, "!")) return "";
        if (self.vars.get(name)) |val| return val;
        return posix.getenv(name) orelse "";
    }

    fn exitCodeStr(self: *Shell) []const u8 {
        const vals = "0\x001\x002\x003\x004\x005\x006\x007\x008\x009";
        if (self.last_exit < 10) return vals[self.last_exit * 2 ..][0..1];
        return "0";
    }

    fn pidStr(_: *Shell) []const u8 {
        return "0";
    }

    // =========================================================================
    // SUBSHELL CAPTURE
    // =========================================================================

    fn evalCapture(self: *Shell, args: []const Sexp, source: []const u8) ?[]const u8 {
        if (args.len < 1) return null;

        const pipe_fds = posix.pipe() catch return null;
        const pid = posix.fork() catch return null;

        if (pid == 0) {
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[1]);
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        posix.close(pipe_fds[1]);
        const file = std.fs.File{ .handle = pipe_fds[0] };
        const output = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            posix.close(pipe_fds[0]);
            _ = posix.waitpid(pid, 0);
            return null;
        };
        posix.close(pipe_fds[0]);
        const result = posix.waitpid(pid, 0);
        self.last_exit = statusToExit(result.status);

        return std.mem.trimRight(u8, output, "\n");
    }

    // =========================================================================
    // DISPLAY (= expr)
    // =========================================================================

    fn evalDisplay(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const val = self.evalMath(args[0], source);
        const str = formatFloat(self.allocator, val);
        const stdout = std.fs.File.stdout();
        stdout.writeAll(str) catch {};
        stdout.writeAll("\n") catch {};
        self.last_exit = 0;
    }

    // =========================================================================
    // MATH EVALUATION (f64)
    // =========================================================================

    fn evalMathToStr(self: *Shell, sexp: Sexp, source: []const u8) []const u8 {
        return formatFloat(self.allocator, self.evalMath(sexp, source));
    }

    fn evalMath(self: *Shell, sexp: Sexp, source: []const u8) f64 {
        switch (sexp) {
            .src => |s| {
                const text = source[s.pos..][0..s.len];
                const expanded = self.expandToken(text);
                return std.fmt.parseFloat(f64, expanded) catch 0;
            },
            .str => |s| return std.fmt.parseFloat(f64, s) catch 0,
            .nil => return 0,
            .tag => return 0,
            .list => |items| {
                if (items.len == 0) return 0;
                switch (items[0]) {
                    .tag => |tag| {
                        const a = items[1..];
                        if (a.len == 0) return 0;
                        return switch (tag) {
                            .add => self.evalMath(a[0], source) + if (a.len > 1) self.evalMath(a[1], source) else 0,
                            .sub => self.evalMath(a[0], source) - if (a.len > 1) self.evalMath(a[1], source) else 0,
                            .mul => self.evalMath(a[0], source) * if (a.len > 1) self.evalMath(a[1], source) else 1,
                            .div => blk: {
                                const b = if (a.len > 1) self.evalMath(a[1], source) else 1;
                                break :blk if (b != 0) self.evalMath(a[0], source) / b else 0;
                            },
                            .mod => blk: {
                                const b = if (a.len > 1) self.evalMath(a[1], source) else 1;
                                break :blk if (b != 0) @mod(self.evalMath(a[0], source), b) else 0;
                            },
                            .pow => std.math.pow(f64, self.evalMath(a[0], source), if (a.len > 1) self.evalMath(a[1], source) else 0),
                            .neg => -self.evalMath(a[0], source),
                            .default => blk: {
                                const val = self.evalMath(a[0], source);
                                if (val != 0) break :blk val;
                                break :blk if (a.len > 1) self.evalMath(a[1], source) else 0;
                            },
                            .capture => blk: {
                                const out = self.evalCapture(a, source) orelse break :blk @as(f64, 0);
                                break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, out, " \t\n")) catch 0;
                            },
                            else => 0,
                        };
                    },
                    else => return 0,
                }
            },
        }
    }

    // =========================================================================
    // COMPARISON EVALUATION
    // =========================================================================

    fn evalComparison(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) { self.last_exit = 1; return; }
        const lhs = self.sexpToExpandedStr(args[0], source);
        const rhs = self.sexpToExpandedStr(args[1], source);

        const result = switch (tag) {
            .eq => std.mem.eql(u8, lhs, rhs) or numCmp(lhs, rhs) == .eq,
            .ne => !std.mem.eql(u8, lhs, rhs) and numCmp(lhs, rhs) != .eq,
            .lt => numCmp(lhs, rhs) == .lt,
            .gt => numCmp(lhs, rhs) == .gt,
            .le => numCmp(lhs, rhs) != .gt,
            .ge => numCmp(lhs, rhs) != .lt,
            else => false,
        };
        self.last_exit = if (result) 0 else 1;
    }

    fn numCmp(a: []const u8, b: []const u8) std.math.Order {
        const na = std.fmt.parseFloat(f64, a) catch return strOrd(a, b);
        const nb = std.fmt.parseFloat(f64, b) catch return strOrd(a, b);
        return std.math.order(na, nb);
    }

    fn strOrd(a: []const u8, b: []const u8) std.math.Order {
        return std.mem.order(u8, a, b);
    }

    fn sexpToExpandedStr(self: *Shell, sexp: Sexp, source: []const u8) []const u8 {
        switch (sexp) {
            .src => |s| return self.expandToken(source[s.pos..][0..s.len]),
            .str => |s| return s,
            .list => |items| {
                if (items.len > 0) {
                    switch (items[0]) {
                        .tag => |t| {
                            if (t == .capture) return self.evalCapture(items[1..], source) orelse "";
                            if (isArithTag(t)) return self.evalMathToStr(sexp, source);
                        },
                        else => {},
                    }
                }
                return "";
            },
            else => return "",
        }
    }

    // =========================================================================
    // CONTROL FLOW
    // =========================================================================

    fn evalAnd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        if (self.last_exit == 0 and args.len >= 2) self.eval(args[1], source);
    }

    fn evalOr(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        if (self.last_exit != 0 and args.len >= 2) self.eval(args[1], source);
    }

    fn evalXor(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        self.eval(args[0], source);
        const a = self.last_exit;
        self.eval(args[1], source);
        const b = self.last_exit;
        self.last_exit = if ((a == 0) != (b == 0)) 0 else 1;
    }

    fn evalNot(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
        self.last_exit = if (self.last_exit == 0) 1 else 0;
    }

    fn evalSequence(self: *Shell, args: []const Sexp, source: []const u8) void {
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

    fn evalPipe(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) {
            if (args.len == 1) self.eval(args[0], source);
            return;
        }
        const pipe_fds = posix.pipe() catch { self.last_exit = 1; return; };

        const pid1 = posix.fork() catch { self.last_exit = 1; return; };
        if (pid1 == 0) {
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[1]);
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        const pid2 = posix.fork() catch { self.last_exit = 1; return; };
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

    // =========================================================================
    // ASSIGNMENT
    // =========================================================================

    fn evalAssign(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        const value = self.sexpToExpandedStr(args[1], source);
        self.vars.put(name, value) catch {};
        self.last_exit = 0;
    }

    fn evalUnset(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        _ = self.vars.remove(name);
        self.last_exit = 0;
    }

    // =========================================================================
    // CONDITIONALS AND LOOPS
    // =========================================================================

    fn evalIf(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        self.eval(args[0], source);
        if (self.last_exit == 0) {
            self.eval(args[1], source);
        } else if (args.len >= 3) {
            self.eval(args[2], source);
        }
    }

    fn evalUnless(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        self.eval(args[0], source);
        if (self.last_exit != 0) {
            self.eval(args[1], source);
        }
    }

    fn evalFor(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 3) return;
        const var_name = self.sexpToStr(args[0], source) orelse return;
        const word_list = args[1];
        const body = args[2];

        switch (word_list) {
            .list => |items| {
                for (items) |item| {
                    const val = self.sexpToExpandedStr(item, source);
                    self.vars.put(var_name, val) catch continue;
                    self.eval(body, source);
                }
            },
            else => {
                const val = self.sexpToExpandedStr(word_list, source);
                self.vars.put(var_name, val) catch return;
                self.eval(body, source);
            },
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

    fn evalUntil(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        while (true) {
            self.eval(args[0], source);
            if (self.last_exit == 0) break;
            self.eval(args[1], source);
        }
    }

    fn evalTry(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const value = self.sexpToExpandedStr(args[0], source);

        for (args[1..]) |arm_sexp| {
            switch (arm_sexp) {
                .list => |items| {
                    if (items.len < 2) continue;
                    switch (items[0]) {
                        .tag => |t| {
                            if (t == .arm_else) {
                                self.eval(items[1], source);
                                return;
                            }
                            if (t == .arm and items.len >= 3) {
                                const pattern = self.sexpToExpandedStr(items[1], source);
                                if (std.mem.eql(u8, value, pattern)) {
                                    self.eval(items[2], source);
                                    return;
                                }
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        self.last_exit = 1;
    }

    // =========================================================================
    // TEST BUILTIN
    // =========================================================================

    fn evalTest(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) { self.last_exit = 1; return; }
        const flag = self.sexpToStr(args[0], source) orelse { self.last_exit = 1; return; };
        const path = self.sexpToExpandedStr(args[1], source);

        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch {
            self.last_exit = 1;
            return;
        };

        if (std.mem.eql(u8, flag, "-e")) {
            self.last_exit = 0;
        } else if (std.mem.eql(u8, flag, "-f")) {
            self.last_exit = if (stat.kind == .file) 0 else 1;
        } else if (std.mem.eql(u8, flag, "-d")) {
            self.last_exit = if (stat.kind == .directory) 0 else 1;
        } else if (std.mem.eql(u8, flag, "-s")) {
            self.last_exit = if (stat.size > 0) 0 else 1;
        } else if (std.mem.eql(u8, flag, "-L")) {
            self.last_exit = if (stat.kind == .sym_link) 0 else 1;
        } else {
            self.last_exit = 0;
        }
    }

    // =========================================================================
    // EXEC (replace process)
    // =========================================================================

    fn evalExec(self: *Shell, args: []const Sexp, source: []const u8) void {
        self.eval(args[0], source);
    }

    // =========================================================================
    // BUILTINS
    // =========================================================================

    fn tryBuiltin(self: *Shell, argv: []const []const u8, source: []const u8) bool {
        _ = source;
        const name = argv[0];

        if (std.mem.eql(u8, name, "cd")) { self.builtinCd(argv); return true; }
        if (std.mem.eql(u8, name, "echo")) { self.builtinEcho(argv); return true; }
        if (std.mem.eql(u8, name, "true")) { self.last_exit = 0; return true; }
        if (std.mem.eql(u8, name, "false")) { self.last_exit = 1; return true; }
        if (std.mem.eql(u8, name, "type")) { self.builtinType(argv); return true; }
        if (std.mem.eql(u8, name, "pwd")) { self.builtinPwd(); return true; }

        return false;
    }

    fn builtinCd(self: *Shell, argv: []const []const u8) void {
        const target = if (argv.len > 1) argv[1] else posix.getenv("HOME") orelse "/";
        posix.chdir(target) catch |err| {
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

    fn builtinPwd(self: *Shell) void {
        var buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch { self.last_exit = 1; return; };
        std.debug.print("{s}\n", .{cwd});
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
        const builtins = [_][]const u8{ "cd", "echo", "true", "false", "type", "pwd", "exit", "source", "set", "cmd", "key", "test", "shift", "break", "continue" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    // =========================================================================
    // CMD / SET MANAGEMENT
    // =========================================================================

    fn evalCmdDef(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        self.user_cmds.put(name, args[args.len - 1]) catch {};
        self.last_exit = 0;
    }

    fn evalCmdDel(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        _ = self.user_cmds.remove(name);
        self.last_exit = 0;
    }

    fn evalCmdShow(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.user_cmds.get(name)) |_| {
            std.debug.print("cmd {s} (defined)\n", .{name});
        } else {
            std.debug.print("slash: cmd {s}: not defined\n", .{name});
        }
        self.last_exit = 0;
    }

    fn evalCmdList(self: *Shell) void {
        var it = self.user_cmds.iterator();
        while (it.next()) |entry| std.debug.print("cmd {s}\n", .{entry.key_ptr.*});
        self.last_exit = 0;
    }

    fn evalSourceCmd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const path = self.sexpToExpandedStr(args[0], source);
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("slash: source: {s}: {s}\n", .{ path, @errorName(err) });
            self.last_exit = 1;
            return;
        };
        defer self.allocator.free(content);
        self.execSource(content);
    }

    fn evalExit(_: *Shell, args: []const Sexp, source: []const u8) void {
        var code: u8 = 0;
        if (args.len >= 1) {
            switch (args[0]) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    code = std.fmt.parseInt(u8, text, 10) catch 0;
                },
                else => {},
            }
        }
        posix.exit(code);
    }

    fn evalSet(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        const value = self.sexpToExpandedStr(args[1], source);
        self.options.put(name, value) catch {};
        self.last_exit = 0;
    }

    fn evalSetReset(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        _ = self.options.remove(name);
        self.last_exit = 0;
    }

    fn evalSetShow(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.options.get(name)) |val| {
            std.debug.print("{s} = {s}\n", .{ name, val });
        } else {
            std.debug.print("{s}: not set\n", .{name});
        }
        self.last_exit = 0;
    }

    fn evalSetList(self: *Shell) void {
        var it = self.options.iterator();
        while (it.next()) |entry| std.debug.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        self.last_exit = 0;
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    fn sexpToStr(_: *Shell, sexp: Sexp, source: []const u8) ?[]const u8 {
        return switch (sexp) {
            .src => |s| source[s.pos..][0..s.len],
            .str => |s| s,
            else => null,
        };
    }

    fn isRedirTag(tag: Tag) bool {
        return switch (tag) {
            .redir_out, .redir_append, .redir_in, .redir_err, .redir_err_app, .redir_both, .redir_dup, .redir_fd_out, .redir_fd_in, .redir_fd_dup, .herestring => true,
            else => false,
        };
    }

    fn isArithTag(tag: Tag) bool {
        return switch (tag) {
            .add, .sub, .mul, .div, .mod, .pow, .neg, .default => true,
            else => false,
        };
    }
};

// =============================================================================
// EXEC HELPERS
// =============================================================================

fn toExecArgs(alloc: Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const buf = try alloc.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| buf[i] = try alloc.dupeZ(u8, arg);
    buf[argv.len] = null;
    return @ptrCast(buf.ptr);
}

fn getEnvP() [*:null]const ?[*:0]const u8 {
    return std.c.environ;
}

fn spaceMathOps(alloc: Allocator, input: []const u8) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '*' and i + 1 < input.len and input[i + 1] == '*') {
            out.appendSlice(alloc, " ** ") catch return null;
            i += 2;
        } else if (c == '^') {
            out.appendSlice(alloc, " ** ") catch return null;
            i += 1;
        } else if (c == '+' or c == '/' or c == '%') {
            out.append(alloc, ' ') catch return null;
            out.append(alloc, c) catch return null;
            out.append(alloc, ' ') catch return null;
            i += 1;
        } else if (c == '*') {
            out.append(alloc, ' ') catch return null;
            out.append(alloc, c) catch return null;
            out.append(alloc, ' ') catch return null;
            i += 1;
        } else if (c == '-' and i > 0 and input[i - 1] >= '0' and input[i - 1] <= '9') {
            out.append(alloc, ' ') catch return null;
            out.append(alloc, c) catch return null;
            out.append(alloc, ' ') catch return null;
            i += 1;
        } else {
            out.append(alloc, c) catch return null;
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn statusToExit(status: u32) u8 {
    if (posix.W.IFSIGNALED(status)) return 128 +| @as(u8, @truncate(posix.W.TERMSIG(status)));
    if (posix.W.IFEXITED(status)) return @truncate(posix.W.EXITSTATUS(status));
    return 1;
}

fn formatFloat(alloc: Allocator, val: f64) []const u8 {
    if (val == @trunc(val) and @abs(val) < 1e15) {
        return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(val))}) catch "0";
    }
    const raw = std.fmt.allocPrint(alloc, "{d:.10}", .{val}) catch return "0";
    var end: usize = raw.len;
    while (end > 0 and raw[end - 1] == '0') end -= 1;
    if (end > 0 and raw[end - 1] == '.') end -= 1;
    if (end == 0) return "0";
    return raw[0..end];
}
