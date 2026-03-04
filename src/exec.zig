//! Slash Executor
//!
//! Walks s-expressions produced by the parser and executes them.
//!
//! Pipeline:
//!   source text → lexer → parser → s-expressions → Shell (this)

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

const parser = @import("parser.zig");
const Regex = @import("regex.zig").Regex;
const Sexp = parser.Sexp;
const Tag = parser.Tag;
const Parser = parser.Parser;

const Flow = enum { normal, break_loop, continue_loop };

const UserCmd = struct {
    params: [][]const u8,
    body: Sexp,
    source: []const u8,
};

// =========================================================================
// JOB CONTROL
// =========================================================================

pub const JobState = enum { running, stopped, done };

pub const Job = struct {
    id: u16,
    pgid: posix.pid_t,
    state: JobState,
    exit_code: u8,
    command: []const u8,
    pids: [8]posix.pid_t = .{0} ** 8,
    pid_count: u8 = 0,
};

const MAX_JOBS = 64;

pub const Shell = struct {
    allocator: Allocator,
    vars: std.StringHashMap([]const u8),
    last_exit: u8 = 0,
    flow: Flow = .normal,
    user_cmds: std.StringHashMap(UserCmd),
    options: std.StringHashMap([]const u8),

    // Positional arguments ($1-$9, $*, $#)
    args: []const []const u8 = &.{},

    // Directory history (MRU, deduplicated)
    dir_history: [32][]const u8 = .{""} ** 32,
    dir_count: u8 = 0,

    // Key bindings (key combo → command string)
    key_bindings: std.StringHashMap([]const u8),

    // History database (set by REPL)
    history_db: ?@import("history.zig").Db = null,

    // Job control state
    tty_fd: posix.fd_t = posix.STDIN_FILENO,
    shell_pgid: posix.pid_t = 0,
    interactive: bool = false,
    jobs: [MAX_JOBS]?Job = .{null} ** MAX_JOBS,
    next_job_id: u16 = 1,

    pub fn init(alloc: Allocator) Shell {
        return .{
            .allocator = alloc,
            .vars = std.StringHashMap([]const u8).init(alloc),
            .user_cmds = std.StringHashMap(UserCmd).init(alloc),
            .options = std.StringHashMap([]const u8).init(alloc),
            .key_bindings = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn initInteractive(self: *Shell) void {
        self.tty_fd = posix.STDIN_FILENO;
        self.shell_pgid = libc.getpid();
        self.interactive = true;
        _ = libc.setpgid(0, self.shell_pgid);
        _ = libc.tcsetpgrp(self.tty_fd, self.shell_pgid);
    }

    pub fn setArgs(self: *Shell, script_args: []const []const u8) void {
        self.args = script_args;
    }

    pub fn deinit(self: *Shell) void {
        self.vars.deinit();
        self.user_cmds.deinit();
        self.options.deinit();
        self.key_bindings.deinit();
    }

    // =========================================================================
    // JOB TABLE MANAGEMENT
    // =========================================================================

    fn addJob(self: *Shell, pgid: posix.pid_t, state: JobState, command: []const u8, pids: []const posix.pid_t) u16 {
        const id = self.next_job_id;
        self.next_job_id += 1;
        for (&self.jobs) |*slot| {
            if (slot.* == null) {
                var job = Job{ .id = id, .pgid = pgid, .state = state, .exit_code = 0, .command = command };
                for (pids, 0..) |pid, i| {
                    if (i >= 8) break;
                    job.pids[i] = pid;
                }
                job.pid_count = @intCast(@min(pids.len, 8));
                slot.* = job;
                return id;
            }
        }
        return 0;
    }

    fn findJobByPgid(self: *Shell, pgid: posix.pid_t) ?*Job {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.pgid == pgid) return job;
            }
        }
        return null;
    }

    fn findJobById(self: *Shell, id: u16) ?*Job {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.id == id) return job;
            }
        }
        return null;
    }

    fn lastJob(self: *Shell) ?*Job {
        var best: ?*Job = null;
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (best == null or job.id > best.?.id) best = job;
            }
        }
        return best;
    }

    fn removeJob(self: *Shell, id: u16) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |job| {
                if (job.id == id) { slot.* = null; return; }
            }
        }
    }

    fn reclaimTerminal(self: *Shell) void {
        if (self.interactive) _ = libc.tcsetpgrp(self.tty_fd, self.shell_pgid);
    }

    pub fn reapAndReport(self: *Shell) void {
        // Reap any finished background children (use raw C waitpid to handle ECHILD gracefully)
        while (true) {
            var status: i32 = 0;
            const pid = libc.waitpid(-1, &status, 1);
            if (pid <= 0) break;
            const result_status: u32 = @bitCast(status);
            for (&self.jobs) |*slot| {
                if (slot.*) |*job| {
                    if (job.state == .running) {
                        for (job.pids[0..job.pid_count]) |jpid| {
                            if (jpid == pid) {
                                job.state = .done;
                                job.exit_code = statusToExit(result_status);
                                break;
                            }
                        }
                    }
                }
            }
        }
        // Report and remove done jobs
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.state == .done) {
                    std.debug.print("[{d}]  Done\t\t{s}\n", .{ job.id, job.command });
                    slot.* = null;
                }
            }
        }
    }

    fn waitForForegroundJob(self: *Shell, pgid: posix.pid_t, pid_count: u8) void {
        var remaining = pid_count;
        while (remaining > 0) {
            const result = posix.waitpid(-pgid, posix.W.UNTRACED);
            if (result.pid <= 0) break;

            if (posix.W.IFSTOPPED(result.status)) {
                if (self.findJobByPgid(pgid)) |job| {
                    job.state = .stopped;
                    std.debug.print("\n[{d}]  Stopped\t\t{s}\n", .{ job.id, job.command });
                }
                self.reclaimTerminal();
                return;
            }

            remaining -= 1;
            if (remaining == 0) {
                self.last_exit = statusToExit(result.status);
            }
        }
        self.reclaimTerminal();
    }

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    pub fn sourceFile(self: *Shell, path: []const u8) void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);
        self.execSource(content);
    }

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
            .key => self.evalKey(args, source),
            .key_del => self.evalKeyDel(args, source),
            .eq, .ne, .lt, .gt, .le, .ge, .match, .nomatch => self.evalComparison(tag, args, source),
            .shift => self.evalShift(),
            .@"break" => { self.flow = .break_loop; self.last_exit = 0; },
            .@"continue" => { self.flow = .continue_loop; self.last_exit = 0; },
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
                    if (argv_list.items.len > 0 and s.pos > 0 and expanded.ptr == text.ptr) {
                        const prev = argv_list.items[argv_list.items.len - 1];
                        const src_start = @intFromPtr(source.ptr);
                        const prev_addr = @intFromPtr(prev.ptr);
                        if (prev_addr >= src_start and prev_addr < src_start + source.len) {
                            const prev_start = prev_addr - src_start;
                            const prev_end = prev_start + prev.len;
                            if (s.pos == prev_end) {
                                argv_list.items[argv_list.items.len - 1] = source[prev_start .. s.pos + s.len];
                                continue;
                            }
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
                            if (isHeredocTag(t)) {
                                self.collectHeredocRedirect(t, items[1..], source, &redir_list);
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

        // Expand globs and regex literals in arguments
        var expanded_argv: std.ArrayList([]const u8) = .empty;
        defer expanded_argv.deinit(self.allocator);
        for (argv_list.items) |arg| {
            if (isRegexGlob(arg)) {
                expandRegexGlob(self.allocator, arg, &expanded_argv);
            } else if (hasGlobChars(arg)) {
                expandGlob(self.allocator, arg, &expanded_argv);
            } else {
                expanded_argv.append(self.allocator, arg) catch {};
            }
        }
        const argv = expanded_argv.items;
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
            } else if (self.user_cmds.get(argv[0])) |cmd| {
                self.invokeUserCmd(cmd, argv);
            }
            if (has_redirs) {
                if (saved[0] != -1) { posix.dup2(saved[0], posix.STDIN_FILENO) catch {}; posix.close(saved[0]); }
                if (saved[1] != -1) { posix.dup2(saved[1], posix.STDOUT_FILENO) catch {}; posix.close(saved[1]); }
                if (saved[2] != -1) { posix.dup2(saved[2], posix.STDERR_FILENO) catch {}; posix.close(saved[2]); }
            }
            self.cleanupProcSubs(procsub_fds.items);
            return;
        }

        // Auto-cd: if command is a directory path, cd to it
        if (argv.len == 1 and !has_redirs) {
            const name = argv[0];
            if (name.len > 0 and (name[0] == '/' or name[0] == '.' or name[0] == '~')) {
                const pathZ = self.allocator.dupeZ(u8, name) catch {
                    self.forkExecWithRedirects(argv, redirs);
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                };
                defer self.allocator.free(pathZ);
                const stat = std.fs.cwd().statFile(name) catch {
                    self.forkExecWithRedirects(argv, redirs);
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                };
                if (stat.kind == .directory) {
                    posix.chdir(pathZ) catch |err| {
                        std.debug.print("cd: {s}: {s}\n", .{ name, @errorName(err) });
                        self.last_exit = 1;
                    };
                    self.recordDir();
                    self.last_exit = 0;
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                }
            }
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
        const cmd_text = self.allocator.dupe(u8, argv[0]) catch argv[0];
        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };

        if (pid == 0) {
            if (self.interactive) {
                _ = libc.setpgid(0, 0);
                _ = libc.tcsetpgrp(self.tty_fd, libc.getpid());
            }
            resetChildSignals();
            applyRedirects(self.allocator, redirs);
            const argv_z = toExecArgs(self.allocator, argv) catch posix.exit(127);
            const envp = getEnvP();
            posix.execvpeZ(argv_z[0].?, argv_z, envp) catch {};
            std.debug.print("slash: {s}: command not found\n", .{argv[0]});
            posix.exit(127);
        }

        if (self.interactive) {
            _ = libc.setpgid(pid, pid);
            const pids = [_]posix.pid_t{pid};
            const job_id = self.addJob(pid, .running, cmd_text, &pids);
            _ = libc.tcsetpgrp(self.tty_fd, pid);
            self.waitForForegroundJob(pid, 1);
            if (self.findJobById(job_id)) |job| {
                if (job.state != .stopped) self.removeJob(job_id);
            }
        } else {
            const result = posix.waitpid(pid, 0);
            self.last_exit = statusToExit(result.status);
        }
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
        if (name.len == 1 and name[0] >= '1' and name[0] <= '9') {
            const idx = name[0] - '1';
            return if (idx < self.args.len) self.args[idx] else "";
        }
        if (std.mem.eql(u8, name, "#")) return self.argCountStr();
        if (std.mem.eql(u8, name, "*")) return self.argJoinStr();
        if (std.mem.eql(u8, name, "0")) return self.vars.get("0") orelse "slash";
        if (std.mem.eql(u8, name, "!")) return "";
        if (self.vars.get(name)) |val| return val;
        return posix.getenv(name) orelse "";
    }

    fn argCountStr(self: *Shell) []const u8 {
        const vals = "0\x001\x002\x003\x004\x005\x006\x007\x008\x009";
        if (self.args.len < 10) return vals[self.args.len * 2 ..][0..1];
        return std.fmt.allocPrint(self.allocator, "{d}", .{self.args.len}) catch "0";
    }

    fn argJoinStr(self: *Shell) []const u8 {
        if (self.args.len == 0) return "";
        var total: usize = 0;
        for (self.args) |a| total += a.len + 1;
        const buf = self.allocator.alloc(u8, total - 1) catch return "";
        var pos: usize = 0;
        for (self.args, 0..) |a, i| {
            if (i > 0) { buf[pos] = ' '; pos += 1; }
            @memcpy(buf[pos..][0..a.len], a);
            pos += a.len;
        }
        return buf[0..pos];
    }

    fn evalShift(self: *Shell) void {
        if (self.args.len > 0) {
            self.args = self.args[1..];
        }
        self.last_exit = 0;
    }

    fn exitCodeStr(self: *Shell) []const u8 {
        const vals = "0\x001\x002\x003\x004\x005\x006\x007\x008\x009";
        if (self.last_exit < 10) return vals[self.last_exit * 2 ..][0..1];
        return "0";
    }

    fn pidStr(self: *Shell) []const u8 {
        const pid = libc.getpid();
        return std.fmt.allocPrint(self.allocator, "{d}", .{pid}) catch "0";
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

        if (tag == .match or tag == .nomatch) {
            const rhs_raw = self.sexpToStr(args[1], source) orelse "";
            const pattern = parseRegexLiteral(rhs_raw);
            const re = Regex.compile(pattern) catch {
                std.debug.print("slash: invalid regex: {s}\n", .{pattern});
                self.last_exit = 2;
                return;
            };
            defer re.free();
            const found = re.search(lhs);
            self.last_exit = if ((tag == .match) == found) 0 else 1;
            return;
        }

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

    fn parseRegexLiteral(raw: []const u8) []const u8 {
        if (raw.len < 2) return raw;
        var start: usize = 0;
        // Skip ~ prefix if present
        if (raw[0] == '~') start = 1;
        // The first char after optional ~ is the delimiter
        const delim = raw[start];
        start += 1;
        // Find closing delimiter from the end (before flags)
        var end = raw.len;
        while (end > start and std.ascii.isAlphabetic(raw[end - 1])) end -= 1;
        if (end > start and raw[end - 1] == delim) end -= 1;
        return raw[start..end];
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
        for (args) |child| {
            self.eval(child, source);
            if (self.flow != .normal) return;
        }
    }

    fn evalBg(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;
        const cmd_text = self.allocator.dupe(u8, source[0..@min(source.len, 80)]) catch "";
        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };
        if (pid == 0) {
            if (self.interactive) _ = libc.setpgid(0, 0);
            resetChildSignals();
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }
        if (self.interactive) _ = libc.setpgid(pid, pid);
        const pids = [_]posix.pid_t{pid};
        const job_id = self.addJob(pid, .running, cmd_text, &pids);
        std.debug.print("[{d}] {d}\n", .{ job_id, pid });
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
            if (self.interactive) _ = libc.setpgid(0, 0);
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[1]);
            resetChildSignals();
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }

        if (self.interactive) _ = libc.setpgid(pid1, pid1);

        const pid2 = posix.fork() catch { self.last_exit = 1; return; };
        if (pid2 == 0) {
            if (self.interactive) _ = libc.setpgid(0, pid1);
            posix.close(pipe_fds[1]);
            posix.dup2(pipe_fds[0], posix.STDIN_FILENO) catch posix.exit(1);
            posix.close(pipe_fds[0]);
            resetChildSignals();
            self.eval(args[1], source);
            posix.exit(self.last_exit);
        }

        if (self.interactive) _ = libc.setpgid(pid2, pid1);

        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);

        if (self.interactive) {
            const pids = [_]posix.pid_t{ pid1, pid2 };
            const cmd_text = self.allocator.dupe(u8, source[0..@min(source.len, 80)]) catch "";
            const job_id = self.addJob(pid1, .running, cmd_text, &pids);
            _ = libc.tcsetpgrp(self.tty_fd, pid1);
            self.waitForForegroundJob(pid1, 2);
            if (self.findJobById(job_id)) |job| {
                if (job.state != .stopped) self.removeJob(job_id);
            }
        } else {
            _ = posix.waitpid(pid1, 0);
            const result = posix.waitpid(pid2, 0);
            self.last_exit = statusToExit(result.status);
        }
    }

    // =========================================================================
    // ASSIGNMENT
    // =========================================================================

    fn evalAssign(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const value_raw = self.sexpToExpandedStr(args[1], source);
        const name = self.allocator.dupe(u8, name_raw) catch return;
        const value = self.allocator.dupe(u8, value_raw) catch return;
        self.vars.put(name, value) catch return;
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
                const start: usize = if (items.len > 0 and items[0] == .tag) 1 else 0;
                for (items[start..]) |item| {
                    const val = self.sexpToExpandedStr(item, source);
                    self.vars.put(var_name, val) catch continue;
                    self.eval(body, source);
                    if (self.flow == .break_loop) { self.flow = .normal; break; }
                    if (self.flow == .continue_loop) { self.flow = .normal; }
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
            if (self.flow == .break_loop) { self.flow = .normal; break; }
            if (self.flow == .continue_loop) { self.flow = .normal; }
        }
    }

    fn evalUntil(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        while (true) {
            self.eval(args[0], source);
            if (self.last_exit == 0) break;
            self.eval(args[1], source);
            if (self.flow == .break_loop) { self.flow = .normal; break; }
            if (self.flow == .continue_loop) { self.flow = .normal; }
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
        if (args.len < 1) return;

        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        var redir_list: std.ArrayList(Redirect) = .empty;
        defer redir_list.deinit(self.allocator);

        const inner = switch (args[0]) {
            .list => |items| items,
            else => return,
        };
        if (inner.len < 2) return;
        for (inner[1..]) |arg| {
            switch (arg) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    argv_list.append(self.allocator, self.expandToken(text)) catch {};
                },
                .list => |items| {
                    if (items.len >= 2 and items[0] == .tag) {
                        const tag = items[0].tag;
                        self.collectRedirect(tag, items[1..], source, &redir_list);
                    }
                },
                else => {},
            }
        }

        const argv = argv_list.items;
        if (argv.len == 0) return;

        applyRedirects(self.allocator, redir_list.items);
        resetChildSignals();
        const argv_z = toExecArgs(self.allocator, argv) catch {
            std.debug.print("slash: exec: allocation failed\n", .{});
            self.last_exit = 1;
            return;
        };
        const envp = getEnvP();
        posix.execvpeZ(argv_z[0].?, argv_z, envp) catch {};
        std.debug.print("slash: exec: {s}: command not found\n", .{argv[0]});
        posix.exit(127);
    }

    // =========================================================================
    // BUILTINS
    // =========================================================================

    fn tryBuiltin(self: *Shell, argv: []const []const u8, source: []const u8) bool {
        _ = source;
        const name = argv[0];

        if (std.mem.eql(u8, name, "cd")) { self.builtinCd(argv); return true; }
        if (name.len >= 2 and name[0] == '.' and std.mem.allEqual(u8, name, '.')) {
            var buf: [128]u8 = undefined;
            const levels = name.len - 1;
            var pos: usize = 0;
            for (0..levels) |j| {
                if (j > 0 and pos < buf.len) { buf[pos] = '/'; pos += 1; }
                if (pos + 2 <= buf.len) { buf[pos] = '.'; buf[pos + 1] = '.'; pos += 2; }
            }
            if (pos > 0) posix.chdir(buf[0..pos]) catch {};
            self.recordDir();
            self.last_exit = 0;
            return true;
        }
        if (std.mem.eql(u8, name, "echo")) { self.builtinEcho(argv); return true; }
        if (std.mem.eql(u8, name, "true")) { self.last_exit = 0; return true; }
        if (std.mem.eql(u8, name, "false")) { self.last_exit = 1; return true; }
        if (std.mem.eql(u8, name, "type")) { self.builtinType(argv); return true; }
        if (std.mem.eql(u8, name, "pwd")) { self.builtinPwd(); return true; }
        if (std.mem.eql(u8, name, "jobs")) { self.builtinJobs(); return true; }
        if (std.mem.eql(u8, name, "dirs")) { self.builtinDirs(); return true; }
        if (std.mem.eql(u8, name, "history")) { self.builtinHistory(argv); return true; }
        if (std.mem.eql(u8, name, "j")) { self.builtinJ(argv); return true; }
        if (std.mem.eql(u8, name, "fg")) { self.builtinFg(argv); return true; }
        if (std.mem.eql(u8, name, "bg")) { self.builtinBg(argv); return true; }

        return false;
    }

    fn builtinCd(self: *Shell, argv: []const []const u8) void {
        const target = if (argv.len > 1) argv[1] else posix.getenv("HOME") orelse "/";
        posix.chdir(target) catch |err| {
            std.debug.print("cd: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_exit = 1;
            return;
        };
        self.recordDir();
        self.last_exit = 0;
    }

    pub fn recordDir(self: *Shell) void {
        var buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch return;
        // Deduplicate: remove existing entry if present
        var i: u8 = 0;
        while (i < self.dir_count) {
            if (std.mem.eql(u8, self.dir_history[i], cwd)) {
                var j = i;
                while (j + 1 < self.dir_count) : (j += 1) self.dir_history[j] = self.dir_history[j + 1];
                self.dir_count -= 1;
            } else i += 1;
        }
        // Shift down and insert at front
        if (self.dir_count >= 32) self.dir_count = 31;
        var k: u8 = self.dir_count;
        while (k > 0) : (k -= 1) self.dir_history[k] = self.dir_history[k - 1];
        self.dir_history[0] = self.allocator.dupe(u8, cwd) catch return;
        self.dir_count += 1;
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
        const stdout = std.fs.File.stdout();
        stdout.writeAll(cwd) catch {};
        stdout.writeAll("\n") catch {};
        self.last_exit = 0;
    }

    fn builtinJobs(self: *Shell) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |job| {
                const state_str = switch (job.state) {
                    .running => "Running",
                    .stopped => "Stopped",
                    .done => "Done",
                };
                std.debug.print("[{d}]  {s}\t\t{s}\n", .{ job.id, state_str, job.command });
            }
        }
        self.last_exit = 0;
    }

    fn builtinFg(self: *Shell, argv: []const []const u8) void {
        const job = if (argv.len > 1) blk: {
            const id = std.fmt.parseInt(u16, argv[1], 10) catch {
                std.debug.print("fg: {s}: no such job\n", .{argv[1]});
                self.last_exit = 1;
                return;
            };
            break :blk self.findJobById(id);
        } else self.lastJob();

        if (job == null) {
            std.debug.print("fg: no current job\n", .{});
            self.last_exit = 1;
            return;
        }
        const j = job.?;
        std.debug.print("{s}\n", .{j.command});

        if (self.interactive) _ = libc.tcsetpgrp(self.tty_fd, j.pgid);
        if (j.state == .stopped) {
            j.state = .running;
            std.posix.kill(-j.pgid, std.posix.SIG.CONT) catch {};
        }
        self.waitForForegroundJob(j.pgid, j.pid_count);
        if (j.state != .stopped) self.removeJob(j.id);
    }

    fn builtinBg(self: *Shell, argv: []const []const u8) void {
        const job = if (argv.len > 1) blk: {
            const id = std.fmt.parseInt(u16, argv[1], 10) catch {
                std.debug.print("bg: {s}: no such job\n", .{argv[1]});
                self.last_exit = 1;
                return;
            };
            break :blk self.findJobById(id);
        } else blk: {
            for (&self.jobs) |*slot| {
                if (slot.*) |*j| {
                    if (j.state == .stopped) break :blk j;
                }
            }
            break :blk null;
        };

        if (job == null) {
            std.debug.print("bg: no current job\n", .{});
            self.last_exit = 1;
            return;
        }
        const j = job.?;
        j.state = .running;
        std.debug.print("[{d}]  {s} &\n", .{ j.id, j.command });
        std.posix.kill(-j.pgid, std.posix.SIG.CONT) catch {};
        self.last_exit = 0;
    }

    fn builtinDirs(self: *Shell) void {
        if (self.dir_count == 0) {
            std.debug.print("(no directory history)\n", .{});
            self.last_exit = 0;
            return;
        }
        const show = @min(self.dir_count, 9);
        for (0..show) |i| {
            std.debug.print("{d} {s}\n", .{ i + 1, self.dir_history[i] });
        }
        // Read a single digit
        std.debug.print("? ", .{});
        var input: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &input) catch {
            self.last_exit = 0;
            return;
        };
        if (n == 0) { self.last_exit = 0; return; }
        std.debug.print("\n", .{});
        const digit = input[0];
        if (digit >= '1' and digit <= '9') {
            const idx: usize = digit - '1';
            if (idx < self.dir_count) {
                posix.chdir(self.dir_history[idx]) catch |err| {
                    std.debug.print("dirs: {s}: {s}\n", .{ self.dir_history[idx], @errorName(err) });
                    self.last_exit = 1;
                    return;
                };
                self.recordDir();
            }
        }
        self.last_exit = 0;
    }

    fn builtinHistory(self: *Shell, argv: []const []const u8) void {
        const hdb = self.history_db orelse {
            std.debug.print("history: database not available\n", .{});
            self.last_exit = 1;
            return;
        };
        const query = if (argv.len > 1) argv[1] else "";
        const limit: usize = if (argv.len > 2) std.fmt.parseInt(usize, argv[2], 10) catch 20 else 20;
        const results = hdb.search(self.allocator, query, limit);
        for (results) |cmd| std.debug.print("{s}\n", .{cmd});
        self.last_exit = 0;
    }

    fn builtinJ(self: *Shell, argv: []const []const u8) void {
        const HistoryDb = @import("history.zig");
        const hdb = self.history_db orelse {
            std.debug.print("j: database not available\n", .{});
            self.last_exit = 1;
            return;
        };
        const query = if (argv.len > 1) argv[1] else "";
        const results = hdb.frecency(self.allocator, query, 9);
        if (results.len == 0) {
            std.debug.print("j: no matches\n", .{});
            self.last_exit = 1;
            return;
        }
        if (argv.len > 1) {
            posix.chdir(results[0].path) catch |err| {
                std.debug.print("j: {s}: {s}\n", .{ results[0].path, @errorName(err) });
                self.last_exit = 1;
                return;
            };
            self.recordDir();
            self.last_exit = 0;
            return;
        }
        for (results, 0..) |r, i| {
            std.debug.print("{d} {s}\n", .{ i + 1, r.path });
        }
        std.debug.print("? ", .{});
        var input: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &input) catch { self.last_exit = 0; return; };
        if (n == 0) { self.last_exit = 0; return; }
        std.debug.print("\n", .{});
        if (input[0] >= '1' and input[0] <= '9') {
            const idx: usize = input[0] - '1';
            if (idx < results.len) {
                posix.chdir(results[idx].path) catch |err| {
                    std.debug.print("j: {s}: {s}\n", .{ results[idx].path, @errorName(err) });
                    self.last_exit = 1;
                    return;
                };
                self.recordDir();
            }
        }
        _ = HistoryDb;
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
        if (name.len >= 2 and name[0] == '.' and std.mem.allEqual(u8, name, '.')) return true;
        const builtins = [_][]const u8{ "cd", "echo", "true", "false", "type", "pwd", "jobs", "fg", "bg", "dirs", "history", "j", "exit", "source", "set", "cmd", "key", "test", "shift", "break", "continue" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn invokeUserCmd(self: *Shell, cmd: UserCmd, argv: []const []const u8) void {
        const params = cmd.params;
        const call_args = argv[1..];
        const saved_args = self.args;

        // Set positional args ($1, $2, ... $#, $*)
        self.args = call_args;

        // Bind named params
        const saved = self.allocator.alloc(?[]const u8, params.len) catch return;
        defer self.allocator.free(saved);
        for (params, 0..) |pname, i| {
            saved[i] = self.vars.get(pname);
            const val = if (i < call_args.len) call_args[i] else "";
            self.vars.put(pname, val) catch {};
        }

        self.eval(cmd.body, cmd.source);

        // Restore named params
        for (params, 0..) |pname, i| {
            if (saved[i]) |old| {
                self.vars.put(pname, old) catch {};
            } else {
                _ = self.vars.remove(pname);
            }
        }
        self.args = saved_args;
    }

    // =========================================================================
    // CMD / SET MANAGEMENT
    // =========================================================================

    fn evalCmdDef(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const name = self.allocator.dupe(u8, name_raw) catch return;
        const source_copy = self.allocator.dupe(u8, source) catch return;

        var params: [][]const u8 = &.{};
        if (args.len >= 3) {
            if (args[1] == .list) {
                const plist = args[1].list;
                var param_names = self.allocator.alloc([]const u8, plist.len) catch return;
                for (plist, 0..) |p, i| {
                    param_names[i] = self.allocator.dupe(u8, self.sexpToStr(p, source) orelse "") catch "";
                }
                params = param_names;
            }
        }

        self.user_cmds.put(name, .{
            .params = params,
            .body = args[args.len - 1],
            .source = source_copy,
        }) catch {};
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

    fn evalKey(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const combo = self.allocator.dupe(u8, self.sexpToStr(args[0], source) orelse return) catch return;
        const command = self.allocator.dupe(u8, self.sexpToStr(args[1], source) orelse return) catch return;
        self.key_bindings.put(combo, command) catch {};
        self.last_exit = 0;
    }

    fn evalKeyDel(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const combo = self.sexpToStr(args[0], source) orelse return;
        _ = self.key_bindings.remove(combo);
        self.last_exit = 0;
    }

    pub fn lookupKeyBinding(self: *Shell, combo: []const u8) ?[]const u8 {
        return self.key_bindings.get(combo);
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
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const value_raw = self.sexpToExpandedStr(args[1], source);
        const name = self.allocator.dupe(u8, name_raw) catch return;
        const value = self.allocator.dupe(u8, value_raw) catch return;
        self.options.put(name, value) catch return;
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

    fn isHeredocTag(tag: Tag) bool {
        return switch (tag) {
            .heredoc_literal, .heredoc_interp, .heredoc_lang => true,
            else => false,
        };
    }

    fn collectHeredocRedirect(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, list: *std.ArrayList(Redirect)) void {
        var content: std.ArrayListUnmanaged(u8) = .{};
        const interpolate = (tag == .heredoc_interp or tag == .heredoc_lang);
        const start: usize = if (tag == .heredoc_lang and args.len > 0) 1 else 0;
        var first = true;
        for (args[start..]) |body| {
            if (!first) content.append(self.allocator, '\n') catch {};
            first = false;
            const text = self.sexpToStr(body, source) orelse continue;
            if (interpolate) {
                self.expandInto(&content, text);
            } else {
                content.appendSlice(self.allocator, text) catch {};
            }
        }
        const result = content.toOwnedSlice(self.allocator) catch "";
        list.append(self.allocator, .{ .tag = .herestring, .target = result }) catch {};
    }

    fn expandInto(self: *Shell, buf: *std.ArrayListUnmanaged(u8), text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '$' and i + 1 < text.len) {
                if (text[i + 1] == '{') {
                    if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |close| {
                        const name = text[i + 2 .. close];
                        const val = self.lookupVar(name);
                        buf.appendSlice(self.allocator, val) catch {};
                        i = close + 1;
                        continue;
                    }
                } else {
                    const name_start = i + 1;
                    var name_end = name_start;
                    while (name_end < text.len and (std.ascii.isAlphanumeric(text[name_end]) or text[name_end] == '_' or
                        (name_end == name_start and (text[name_end] == '?' or text[name_end] == '$' or
                        text[name_end] == '#' or text[name_end] == '*' or text[name_end] == '!')))) : (name_end += 1) {}
                    if (name_end > name_start) {
                        const val = self.lookupVar(text[name_start..name_end]);
                        buf.appendSlice(self.allocator, val) catch {};
                        i = name_end;
                        continue;
                    }
                }
            }
            if (text[i] == '\\' and i + 1 < text.len) {
                const next = text[i + 1];
                switch (next) {
                    'n' => buf.append(self.allocator, '\n') catch {},
                    't' => buf.append(self.allocator, '\t') catch {},
                    '\\' => buf.append(self.allocator, '\\') catch {},
                    '$' => buf.append(self.allocator, '$') catch {},
                    else => {
                        buf.append(self.allocator, '\\') catch {};
                        buf.append(self.allocator, next) catch {};
                    },
                }
                i += 2;
                continue;
            }
            buf.append(self.allocator, text[i]) catch {};
            i += 1;
        }
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

fn resetChildSignals() void {
    const dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &dfl, null);
    posix.sigaction(posix.SIG.QUIT, &dfl, null);
    posix.sigaction(posix.SIG.TSTP, &dfl, null);
    posix.sigaction(posix.SIG.TTOU, &dfl, null);
    posix.sigaction(posix.SIG.TTIN, &dfl, null);
    posix.sigaction(posix.SIG.PIPE, &dfl, null);
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

// =============================================================================
// GLOB AND REGEX EXPANSION
// =============================================================================

fn isRegexGlob(arg: []const u8) bool {
    return arg.len >= 3 and arg[0] == '~' and !std.ascii.isAlphanumeric(arg[1]) and arg[1] != '/';
}

fn hasGlobChars(arg: []const u8) bool {
    for (arg) |ch| {
        if (ch == '*' or ch == '?' or ch == '[' or ch == '{') return true;
    }
    return false;
}

fn expandRegexGlob(alloc: Allocator, arg: []const u8, out: *std.ArrayList([]const u8)) void {
    const parsed = parseRegexGlob(arg) orelse {
        out.append(alloc, arg) catch {};
        return;
    };
    const re = if (parsed.ignore_case) Regex.compileIgnoreCase(parsed.pattern) catch {
        out.append(alloc, arg) catch {};
        return;
    } else Regex.compile(parsed.pattern) catch {
        out.append(alloc, arg) catch {};
        return;
    };
    defer re.free();

    const dir_path = if (parsed.dir.len > 0) parsed.dir else ".";
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        out.append(alloc, arg) catch {};
        return;
    };
    defer dir.close();

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(alloc);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name[0] == '.' and (parsed.pattern.len == 0 or parsed.pattern[0] != '.')) continue;
        if (re.search(entry.name)) {
            const name = if (parsed.dir.len > 0)
                std.fmt.allocPrint(alloc, "{s}/{s}", .{ parsed.dir, entry.name }) catch continue
            else
                alloc.dupe(u8, entry.name) catch continue;
            matches.append(alloc, name) catch {};
        }
    }

    if (matches.items.len == 0) {
        out.append(alloc, arg) catch {};
        return;
    }
    std.mem.sort([]const u8, matches.items, {}, lessThanStr);
    for (matches.items) |m| out.append(alloc, m) catch {};
}

const ParsedRegex = struct { dir: []const u8, pattern: []const u8, ignore_case: bool };

fn parseRegexGlob(arg: []const u8) ?ParsedRegex {
    if (arg.len < 3 or arg[0] != '~') return null;
    const delim = arg[1];
    var end: usize = 2;
    while (end < arg.len) {
        if (arg[end] == '\\' and end + 1 < arg.len) { end += 2; continue; }
        if (arg[end] == delim) break;
        end += 1;
    }
    if (end >= arg.len) return null;
    const pattern = arg[2..end];
    var ignore_case = false;
    var fi = end + 1;
    while (fi < arg.len and std.ascii.isAlphabetic(arg[fi])) : (fi += 1) {
        if (arg[fi] == 'i') ignore_case = true;
    }
    return .{ .dir = "", .pattern = pattern, .ignore_case = ignore_case };
}

fn expandGlob(alloc: Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) void {
    const re_pattern = globToRegex(alloc, pattern) orelse {
        out.append(alloc, pattern) catch {};
        return;
    };
    const re = Regex.compile(re_pattern) catch {
        out.append(alloc, pattern) catch {};
        return;
    };
    defer re.free();

    // Split pattern into directory and filename parts
    var dir_end: usize = 0;
    for (pattern, 0..) |ch, i| {
        if (ch == '/') dir_end = i + 1;
    }
    const dir_part = if (dir_end > 0) pattern[0 .. dir_end - 1] else "";
    const dir_path = if (dir_part.len > 0) dir_part else ".";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        out.append(alloc, pattern) catch {};
        return;
    };
    defer dir.close();

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(alloc);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name[0] == '.' and (pattern.len == 0 or pattern[dir_end] != '.')) continue;
        const full = if (dir_part.len > 0)
            std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_part, entry.name }) catch continue
        else
            alloc.dupe(u8, entry.name) catch continue;
        if (re.search(full)) {
            matches.append(alloc, full) catch {};
        }
    }

    if (matches.items.len == 0) {
        out.append(alloc, pattern) catch {};
        return;
    }
    std.mem.sort([]const u8, matches.items, {}, lessThanStr);
    for (matches.items) |m| out.append(alloc, m) catch {};
}

fn globToRegex(alloc: Allocator, pattern: []const u8) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.append(alloc, '^') catch return null;

    var i: usize = 0;
    var in_brace = false;
    while (i < pattern.len) {
        const ch = pattern[i];
        switch (ch) {
            '*' => {
                if (i + 1 < pattern.len and pattern[i + 1] == '*') {
                    buf.appendSlice(alloc, ".*") catch return null;
                    i += 2;
                    if (i < pattern.len and pattern[i] == '/') i += 1;
                } else {
                    buf.appendSlice(alloc, "[^/]*") catch return null;
                    i += 1;
                }
            },
            '?' => { buf.appendSlice(alloc, "[^/]") catch return null; i += 1; },
            '[' => { buf.append(alloc, '[') catch return null; i += 1; },
            ']' => { buf.append(alloc, ']') catch return null; i += 1; },
            '{' => { buf.append(alloc, '(') catch return null; in_brace = true; i += 1; },
            '}' => { buf.append(alloc, ')') catch return null; in_brace = false; i += 1; },
            ',' => {
                if (in_brace) buf.append(alloc, '|') catch return null
                else buf.append(alloc, ',') catch return null;
                i += 1;
            },
            '.', '(', ')', '+', '|', '^', '$' => {
                buf.append(alloc, '\\') catch return null;
                buf.append(alloc, ch) catch return null;
                i += 1;
            },
            else => { buf.append(alloc, ch) catch return null; i += 1; },
        }
    }

    buf.append(alloc, '$') catch return null;
    return (buf.toOwnedSlice(alloc) catch return null);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
