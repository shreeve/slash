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

const Flow = enum { normal, break_loop, continue_loop, exit_cmd };

const UserCmd = struct {
    params: [][]const u8,
    body: Sexp,
    source: []const u8,

    fn deinit(self: UserCmd, alloc: Allocator) void {
        freeSexp(alloc, self.body);
        alloc.free(self.source);
        for (self.params) |p| alloc.free(p);
        if (self.params.len > 0) alloc.free(self.params);
    }

    fn freeSexp(alloc: Allocator, sexp: Sexp) void {
        switch (sexp) {
            .list => |items| {
                for (items) |item| freeSexp(alloc, item);
                alloc.free(items);
            },
            .str => |s| alloc.free(s),
            .nil, .tag, .src => {},
        }
    }

    fn dupeSexp(alloc: Allocator, sexp: Sexp) Sexp {
        return switch (sexp) {
            .nil => .nil,
            .tag => |t| .{ .tag = t },
            .src => |s| .{ .src = s },
            .str => |s| .{ .str = alloc.dupe(u8, s) catch "" },
            .list => |items| blk: {
                const copy = alloc.alloc(Sexp, items.len) catch break :blk .nil;
                for (items, 0..) |item, i| copy[i] = dupeSexp(alloc, item);
                break :blk .{ .list = copy };
            },
        };
    }
};

pub const VarValue = union(enum) {
    scalar: []const u8,
    argv: [][]const u8,
};

const Scope = struct {
    vars: std.StringHashMap(VarValue),
};

// =========================================================================
// JOB CONTROL
// =========================================================================

pub const JobState = enum { running, stopped, done };
const MAX_JOB_PIDS = 16;

pub const Job = struct {
    id: u16,
    pgid: posix.pid_t,
    state: JobState,
    exit_code: u8,
    reported_done: bool = false,
    command: []const u8,
    pids: [MAX_JOB_PIDS]posix.pid_t = .{0} ** MAX_JOB_PIDS,
    pid_count: u8 = 0,
    running_count: u8 = 0,
};

const MAX_JOBS = 64;

pub const Shell = struct {
    allocator: Allocator,
    vars: std.StringHashMap(VarValue),
    local_scopes: std.ArrayListUnmanaged(Scope) = .{},
    last_exit: u8 = 0,
    flow: Flow = .normal,
    user_cmds: std.StringHashMap(UserCmd),
    options: std.StringHashMap([]const u8),

    // Positional arguments ($1-$9, $*, $#)
    args: []const []const u8 = &.{},

    // Scratch buffer for argv-to-string conversion (freed on next use)
    argv_str_scratch: ?[]const u8 = null,

    // Per-command expansion tracking (freed after each evalCmd)
    cmd_expansions: std.ArrayListUnmanaged([]const u8) = .{},

    // Last j listing (for bare digit jump)
    j_list: [9][]const u8 = .{""} ** 9,
    j_count: u8 = 0,

    // Session MRU directories (most recent first, deduped)
    dir_mru: [9][]const u8 = .{""} ** 9,
    dir_mru_count: u8 = 0,

    // Key bindings (key combo → command string)
    key_bindings: std.StringHashMap([]const u8),

    // History database (set by REPL)
    history_db: ?*@import("history.zig").Db = null,

    // Job control state
    tty_fd: posix.fd_t = posix.STDIN_FILENO,
    shell_pgid: posix.pid_t = 0,
    interactive: bool = false,
    jobs: [MAX_JOBS]?Job = .{null} ** MAX_JOBS,
    next_job_id: u16 = 1,
    last_bg_pid: posix.pid_t = 0,

    pub fn init(alloc: Allocator) Shell {
        var sh: Shell = .{
            .allocator = alloc,
            .vars = std.StringHashMap(VarValue).init(alloc),
            .user_cmds = std.StringHashMap(UserCmd).init(alloc),
            .options = std.StringHashMap([]const u8).init(alloc),
            .key_bindings = std.StringHashMap([]const u8).init(alloc),
        };
        sh.initCwdState();
        return sh;
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
        while (self.local_scopes.items.len > 0) self.popLocalScope();
        self.local_scopes.deinit(self.allocator);
        self.deinitVarMap(&self.vars);
        {
            var it = self.user_cmds.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
        }
        self.user_cmds.deinit();
        {
            var it = self.options.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.options.deinit();
        {
            var it = self.key_bindings.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.key_bindings.deinit();
        if (self.argv_str_scratch) |s| self.allocator.free(s);
        for (self.cmd_expansions.items) |s| self.allocator.free(s);
        self.cmd_expansions.deinit(self.allocator);
        self.clearJList();
        self.clearSessionDirs();
    }

    fn deinitVarValue(self: *Shell, value: VarValue) void {
        switch (value) {
            .scalar => |text| self.allocator.free(text),
            .argv => |items| {
                for (items) |item| self.allocator.free(item);
                self.allocator.free(items);
            },
        }
    }

    fn deinitVarMap(self: *Shell, map: *std.StringHashMap(VarValue)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.deinitVarValue(entry.value_ptr.*);
        }
        map.deinit();
    }

    fn putOwnedVar(self: *Shell, map: *std.StringHashMap(VarValue), name_raw: []const u8, value: VarValue) bool {
        if (map.getPtr(name_raw)) |slot| {
            self.deinitVarValue(slot.*);
            slot.* = value;
            return true;
        }
        const name = self.allocator.dupe(u8, name_raw) catch {
            self.deinitVarValue(value);
            return false;
        };
        map.put(name, value) catch {
            self.allocator.free(name);
            self.deinitVarValue(value);
            return false;
        };
        return true;
    }

    fn putScalarDupe(self: *Shell, map: *std.StringHashMap(VarValue), name_raw: []const u8, value_raw: []const u8) bool {
        const value = self.allocator.dupe(u8, value_raw) catch return false;
        return self.putOwnedVar(map, name_raw, .{ .scalar = value });
    }

    fn currentVarMap(self: *Shell) *std.StringHashMap(VarValue) {
        if (self.local_scopes.items.len > 0) {
            return &self.local_scopes.items[self.local_scopes.items.len - 1].vars;
        }
        return &self.vars;
    }

    pub fn lookupScopedValue(self: *const Shell, name: []const u8) ?VarValue {
        var i = self.local_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.local_scopes.items[i].vars.get(name)) |val| return val;
        }
        return self.vars.get(name);
    }

    fn lookupGlobalScalar(self: *const Shell, name: []const u8) ?[]const u8 {
        if (self.vars.get(name)) |val| {
            return switch (val) {
                .scalar => |text| text,
                .argv => null,
            };
        }
        return null;
    }

    fn hasExportOverride(self: *const Shell, name: []const u8) bool {
        if (!shouldExportVar(name)) return false;
        var i = self.local_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.local_scopes.items[i].vars.contains(name)) return true;
        }
        return self.vars.contains(name);
    }

    fn pushLocalScope(self: *Shell) bool {
        const scope = Scope{ .vars = std.StringHashMap(VarValue).init(self.allocator) };
        self.local_scopes.append(self.allocator, scope) catch return false;
        return true;
    }

    fn popLocalScope(self: *Shell) void {
        if (self.local_scopes.items.len == 0) return;
        var scope = self.local_scopes.pop().?;
        self.deinitVarMap(&scope.vars);
    }

    fn clearJList(self: *Shell) void {
        const count: usize = @intCast(self.j_count);
        for (self.j_list[0..count]) |path| {
            if (path.len > 0) self.allocator.free(path);
        }
        self.j_count = 0;
        for (&self.j_list) |*slot| slot.* = "";
    }

    fn clearSessionDirs(self: *Shell) void {
        const count: usize = @intCast(self.dir_mru_count);
        for (self.dir_mru[0..count]) |path| {
            if (path.len > 0) self.allocator.free(path);
        }
        self.dir_mru_count = 0;
        for (&self.dir_mru) |*slot| slot.* = "";
    }

    fn setVarDupe(self: *Shell, name_raw: []const u8, value_raw: []const u8) void {
        _ = self.putScalarDupe(&self.vars, name_raw, value_raw);
    }

    fn initCwdState(self: *Shell) void {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch return;
        self.setVarDupe("PWD", cwd);
        self.noteSessionDir(cwd);
    }

    fn recordDirChange(self: *Shell, old_cwd: []const u8, new_cwd: []const u8) void {
        if (old_cwd.len > 0) self.setVarDupe("OLDPWD", old_cwd);
        if (new_cwd.len > 0) self.setVarDupe("PWD", new_cwd);
        self.noteSessionDir(new_cwd);
    }

    fn chdirTracked(self: *Shell, label: []const u8, target: []const u8) bool {
        var old_buf: [4096]u8 = undefined;
        const old_cwd = posix.getcwd(&old_buf) catch "";
        posix.chdir(target) catch |err| {
            std.debug.print("{s}: {s}: {s}\n", .{ label, target, @errorName(err) });
            self.last_exit = 1;
            return false;
        };
        var new_buf: [4096]u8 = undefined;
        const new_cwd = posix.getcwd(&new_buf) catch "";
        self.recordDirChange(old_cwd, new_cwd);
        return true;
    }

    fn noteSessionDir(self: *Shell, cwd: []const u8) void {
        if (cwd.len == 0) return;

        const count: usize = @intCast(self.dir_mru_count);
        for (0..count) |i| {
            if (std.mem.eql(u8, self.dir_mru[i], cwd)) {
                const existing = self.dir_mru[i];
                var j = i;
                while (j > 0) : (j -= 1) {
                    self.dir_mru[j] = self.dir_mru[j - 1];
                }
                self.dir_mru[0] = existing;
                return;
            }
        }

        const duped = self.allocator.dupe(u8, cwd) catch return;
        if (self.dir_mru_count == self.dir_mru.len) {
            const last = self.dir_mru.len - 1;
            if (self.dir_mru[last].len > 0) self.allocator.free(self.dir_mru[last]);
        } else {
            self.dir_mru_count += 1;
        }
        const new_count: usize = @intCast(self.dir_mru_count);
        var i = new_count - 1;
        while (i > 0) : (i -= 1) {
            self.dir_mru[i] = self.dir_mru[i - 1];
        }
        self.dir_mru[0] = duped;
    }

    // =========================================================================
    // JOB TABLE MANAGEMENT
    // =========================================================================

    fn addJob(self: *Shell, pgid: posix.pid_t, state: JobState, command: []const u8, pids: []const posix.pid_t) u16 {
        const id = self.next_job_id;
        self.next_job_id +%= 1;
        if (self.next_job_id == 0) self.next_job_id = 1;
        const command_owned = self.allocator.dupe(u8, command) catch return 0;
        for (&self.jobs) |*slot| {
            if (slot.* == null) {
                var job = Job{ .id = id, .pgid = pgid, .state = state, .exit_code = 0, .command = command_owned };
                for (pids, 0..) |pid, i| {
                    if (i >= MAX_JOB_PIDS) break;
                    job.pids[i] = pid;
                }
                job.pid_count = @intCast(@min(pids.len, MAX_JOB_PIDS));
                job.running_count = job.pid_count;
                slot.* = job;
                return id;
            }
        }
        self.allocator.free(command_owned);
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
                if (job.state == .done) continue;
                if (best == null or job.id > best.?.id) best = job;
            }
        }
        return best;
    }

    fn removeJob(self: *Shell, id: u16) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |job| {
                if (job.id == id) {
                    self.allocator.free(job.command);
                    slot.* = null;
                    return;
                }
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
            const pid = libc.waitpid(-1, &status, libc.WNOHANG);
            if (pid <= 0) break;
            const result_status: u32 = @bitCast(status);
            self.markReapedPid(pid, result_status);
        }
        // Report done jobs once; keep them so `wait` can still consume status.
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.state == .done and !job.reported_done) {
                    std.debug.print("[{d}]  Done\t\t{s}\n", .{ job.id, job.command });
                    job.reported_done = true;
                }
            }
        }
    }

    fn markReapedPid(self: *Shell, pid: posix.pid_t, status: u32) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                for (job.pids[0..job.pid_count], 0..) |jpid, i| {
                    if (jpid == pid) {
                        job.pids[i] = 0;
                        if (job.running_count > 0) job.running_count -= 1;
                        job.exit_code = statusToExit(status);
                        if (job.running_count == 0) {
                            job.state = .done;
                            job.reported_done = false;
                        }
                        return;
                    }
                }
            }
        }
    }

    fn waitForForegroundJob(self: *Shell, pgid: posix.pid_t, pid_count: u8) void {
        if (self.findJobByPgid(pgid)) |job| {
            if (job.state == .done) {
                self.last_exit = job.exit_code;
                self.reclaimTerminal();
                return;
            }
        }
        var remaining = pid_count;
        const rightmost_pid = if (self.findJobByPgid(pgid)) |job|
            job.pids[job.pid_count - 1]
        else
            0;
        var last_status: ?u32 = null;
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
            if (result.pid == rightmost_pid) self.last_exit = statusToExit(result.status);
            last_status = result.status;
        }
        if (rightmost_pid == 0 and last_status != null) self.last_exit = statusToExit(last_status.?);
        self.reclaimTerminal();
    }

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    pub fn setScriptPath(self: *Shell, path: []const u8) void {
        if (path.len > 0 and path[0] == '/') {
            self.setVarDupe("0", path);
            return;
        }
        var cwd_buf: [4096]u8 = undefined;
        var abs_buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch {
            self.setVarDupe("0", path);
            return;
        };
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd, path }) catch {
            self.setVarDupe("0", path);
            return;
        };
        self.setVarDupe("0", abs);
    }

    pub fn sourceFile(self: *Shell, path: []const u8) void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);
        self.execSource(content);
    }

    pub var exit_requested: bool = false;

    pub fn execLine(self: *Shell, source: []const u8) void {
        var p = Parser.init(self.allocator, source);
        defer p.deinit();
        const sexp = p.parseOneline() catch {
            std.debug.print("invalid syntax\n", .{});
            self.last_exit = 2;
            return;
        };
        self.eval(sexp, source);
        if (self.flow == .exit_cmd) {
            self.flow = .normal;
            exit_requested = true;
        }
    }

    pub fn execSource(self: *Shell, source: []const u8) void {
        const parse_source = ensureTrailingNewlineAlloc(self.allocator, source) catch source;
        defer if (parse_source.ptr != source.ptr) self.allocator.free(parse_source);
        var p = Parser.init(self.allocator, parse_source);
        defer p.deinit();
        const sexp = p.parseProgram() catch {
            std.debug.print("invalid syntax\n", .{});
            self.last_exit = 2;
            return;
        };
        self.eval(sexp, parse_source);
        if (self.flow == .exit_cmd) {
            self.flow = .normal;
            exit_requested = true;
        }
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
        // Tags that collide with Zig keywords can't appear as switch prongs.
        if (tag == .@"if") return self.evalIf(args, source);
        if (tag == .@"for") return self.evalFor(args, source);
        if (tag == .@"while") return self.evalWhile(args, source);
        if (tag == .@"try") return self.evalTry(args, source);
        if (tag == .@"else") return self.evalElse(args, source);
        if (tag == .@"test") return self.evalTest(args, source);
        if (tag == .@"set") return self.evalSet(args, source);
        switch (tag) {
            .program => if (self.interactive) self.evalSequence(args, source) else self.evalProgram(args, source),
            .block => self.evalSequence(args, source),
            .cmd => self.evalCmd(args, source),
            .pipe => self.evalPipe(args, source, false),
            .pipe_err => self.evalPipe(args, source, true),
            .@"and" => self.evalAnd(args, source),
            .@"or" => self.evalOr(args, source),
            .xor => self.evalXor(args, source),
            .seq => self.evalSequence(args, source),
            .bg => self.evalBg(args, source),
            .not => self.evalNot(args, source),
            .subshell => self.evalSubshell(args, source),
            .display => self.evalDisplay(args, source),
            .assign => self.evalAssign(args, source),
            .assign_argv => self.evalAssignArgv(args, source),
            .append_argv => self.evalAppendArgv(args, source),
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
            .cmd_missing => self.evalCmdMissingDef(args, source),
            .cmd_missing_del => self.evalCmdMissingDel(),
            .cmd_missing_show => self.evalCmdMissingShow(),
            .set_reset => self.evalSetReset(args, source),
            .set_show => self.evalSetShow(args, source),
            .set_list => self.evalSetList(),
            .key => self.evalKey(args, source),
            .key_del => self.evalKeyDel(args, source),
            .key_list => self.evalKeyList(),
            .eq, .ne, .lt, .gt, .le, .ge, .match, .nomatch => self.evalComparison(tag, args, source),
            .shift_value => _ = self.evalShiftValue(args, source),
            .@"break" => { self.flow = .break_loop; self.last_exit = 0; },
            .@"continue" => { self.flow = .continue_loop; self.last_exit = 0; },
            else => {
                std.debug.print("slash: unhandled tag: {s}\n", .{@tagName(tag)});
                self.last_exit = 1;
            },
        }
    }

    fn evalElse(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len >= 1) self.eval(args[0], source);
    }

    // =========================================================================
    // COMMAND EXECUTION WITH REDIRECTIONS
    // =========================================================================

    const Redirect = struct {
        tag: Tag,
        target: []const u8 = "",
        src_fd: posix.fd_t = -1,
        dest_fd: posix.fd_t = -1,
    };

    const ProcSubFd = struct {
        pipe_fd: posix.fd_t,
        child_pid: posix.pid_t,
    };

    fn evalCmd(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;
        var build_ok = true;

        const saved_expansion_count = self.cmd_expansions.items.len;
        defer {
            while (self.cmd_expansions.items.len > saved_expansion_count) {
                const s = self.cmd_expansions.pop().?;
                self.allocator.free(s);
            }
        }

        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        var literal_items: std.ArrayList(usize) = .empty;
        defer literal_items.deinit(self.allocator);
        var redir_list: std.ArrayList(Redirect) = .empty;
        defer redir_list.deinit(self.allocator);
        var procsub_fds: std.ArrayList(ProcSubFd) = .empty;
        defer procsub_fds.deinit(self.allocator);

        for (args) |arg| {
            switch (arg) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    if (self.appendBareArgvVar(&argv_list, &literal_items, text)) continue;
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
                    argv_list.append(self.allocator, expanded) catch {
                        build_ok = false;
                    };
                },
                .list => |items| {
                    if (items.len == 0) continue;
                    switch (items[0]) {
                        .tag => |t| {
                            if (isRedirTag(t)) {
                                if (!self.collectRedirect(t, items[1..], source, &redir_list)) build_ok = false;
                                continue;
                            }
                            if (t == .capture) {
                                const val = self.evalCapture(items[1..], source);
                                if (val) |v| argv_list.append(self.allocator, v) catch {
                                    build_ok = false;
                                };
                                continue;
                            }
                            if (isHeredocTag(t)) {
                                if (!self.collectHeredocRedirect(t, items[1..], source, &redir_list)) build_ok = false;
                                continue;
                            }
                            if (t == .procsub_in or t == .procsub_out) {
                                if (self.spawnProcSub(t, items[1..], source, &procsub_fds)) |path| {
                                    argv_list.append(self.allocator, path) catch {
                                        build_ok = false;
                                    };
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

        var expanded_argv: std.ArrayList([]const u8) = .empty;
        defer expanded_argv.deinit(self.allocator);
        var owned_expansions: std.ArrayList([]const u8) = .empty;
        defer {
            for (owned_expansions.items) |s| self.allocator.free(s);
            owned_expansions.deinit(self.allocator);
        }
        for (argv_list.items, 0..) |arg, idx| {
            const is_literal = for (literal_items.items) |li| {
                if (li == idx) break true;
            } else false;
            if (is_literal) {
                expanded_argv.append(self.allocator, arg) catch {
                    build_ok = false;
                };
            } else if (isRegexGlob(arg)) {
                const before = expanded_argv.items.len;
                expandRegexGlob(self.allocator, arg, &expanded_argv);
                for (expanded_argv.items[before..]) |s| {
                    owned_expansions.append(self.allocator, s) catch {
                        build_ok = false;
                    };
                }
            } else if (hasGlobChars(arg)) {
                const before = expanded_argv.items.len;
                expandGlob(self.allocator, arg, &expanded_argv);
                for (expanded_argv.items[before..]) |s| {
                    owned_expansions.append(self.allocator, s) catch {
                        build_ok = false;
                    };
                }
            } else {
                expanded_argv.append(self.allocator, arg) catch {
                    build_ok = false;
                };
            }
        }
        if (!build_ok) {
            std.debug.print("slash: command setup failed (allocation error)\n", .{});
            self.last_exit = 1;
            return;
        }
        var argv = expanded_argv.items;
        if (argv.len == 0) return;

        var ok_mode = false;
        if (argv.len >= 1 and std.mem.eql(u8, argv[0], "ok")) {
            argv = if (argv.len > 1) argv[1..] else argv[0..0];
            if (argv.len == 0) return;
            ok_mode = true;
        }
        if (argv.len >= 1 and std.mem.eql(u8, argv[0], "run")) {
            argv = if (argv.len > 1) argv[1..] else argv[0..0];
            if (argv.len == 0) return;
        }

        if (ok_mode) {
            redir_list.append(self.allocator, .{ .tag = .redir_out, .target = "/dev/null" }) catch {
                std.debug.print("slash: command setup failed (allocation error)\n", .{});
                self.last_exit = 1;
                return;
            };
            redir_list.append(self.allocator, .{ .tag = .redir_err, .target = "/dev/null" }) catch {
                std.debug.print("slash: command setup failed (allocation error)\n", .{});
                self.last_exit = 1;
                return;
            };
        }
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
                if (!applyRedirects(self.allocator, redirs)) {
                    self.last_exit = 1;
                    if (saved[0] != -1) { posix.dup2(saved[0], posix.STDIN_FILENO) catch {}; posix.close(saved[0]); }
                    if (saved[1] != -1) { posix.dup2(saved[1], posix.STDOUT_FILENO) catch {}; posix.close(saved[1]); }
                    if (saved[2] != -1) { posix.dup2(saved[2], posix.STDERR_FILENO) catch {}; posix.close(saved[2]); }
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                }
            }
            if (is_builtin) {
                _ = self.tryBuiltin(argv);
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
                const stat = std.fs.cwd().statFile(name) catch {
                    self.forkExecWithRedirects(argv, redirs);
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                };
                if (stat.kind == .directory) {
                    if (!self.chdirTracked("cd", name)) {
                        self.cleanupProcSubs(procsub_fds.items);
                        return;
                    }
                    self.last_exit = 0;
                    self.cleanupProcSubs(procsub_fds.items);
                    return;
                }
            }
        }

        self.forkExecWithRedirects(argv, redirs);
        self.cleanupProcSubs(procsub_fds.items);

        if (self.last_exit == 127) {
            if (self.user_cmds.get("???")) |hook| {
                self.invokeUserCmd(hook, argv);
            }
        }
    }

    fn spawnProcSub(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, fds: *std.ArrayList(ProcSubFd)) ?[]const u8 {
        if (args.len < 1) return null;
        const pipe_fds = posix.pipe() catch return null;
        const pid = posix.fork() catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return null;
        };

        if (tag == .procsub_in) {
            if (pid == 0) {
                resetChildSignals();
                posix.close(pipe_fds[0]);
                posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
                posix.close(pipe_fds[1]);
                self.eval(args[0], source);
                posix.exit(self.last_exit);
            }
            posix.close(pipe_fds[1]);
            fds.append(self.allocator, .{ .pipe_fd = pipe_fds[0], .child_pid = pid }) catch {
                posix.close(pipe_fds[0]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            const path = std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{pipe_fds[0]}) catch {
                _ = fds.pop();
                posix.close(pipe_fds[0]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            self.cmd_expansions.append(self.allocator, path) catch {
                self.allocator.free(path);
                _ = fds.pop();
                posix.close(pipe_fds[0]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            return path;
        } else {
            if (pid == 0) {
                resetChildSignals();
                posix.close(pipe_fds[1]);
                posix.dup2(pipe_fds[0], posix.STDIN_FILENO) catch posix.exit(1);
                posix.close(pipe_fds[0]);
                self.eval(args[0], source);
                posix.exit(self.last_exit);
            }
            posix.close(pipe_fds[0]);
            fds.append(self.allocator, .{ .pipe_fd = pipe_fds[1], .child_pid = pid }) catch {
                posix.close(pipe_fds[1]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            const path = std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{pipe_fds[1]}) catch {
                _ = fds.pop();
                posix.close(pipe_fds[1]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            self.cmd_expansions.append(self.allocator, path) catch {
                self.allocator.free(path);
                _ = fds.pop();
                posix.close(pipe_fds[1]);
                posix.kill(pid, posix.SIG.TERM) catch {};
                _ = posix.waitpid(pid, 0);
                return null;
            };
            return path;
        }
    }

    fn cleanupProcSubs(_: *Shell, fds: []const ProcSubFd) void {
        for (fds) |ps| {
            posix.close(ps.pipe_fd);
            _ = posix.waitpid(ps.child_pid, 0);
        }
    }

    fn collectRedirect(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, list: *std.ArrayList(Redirect)) bool {
        if (tag == .redir_dup) {
            list.append(self.allocator, .{ .tag = tag, .src_fd = posix.STDERR_FILENO, .dest_fd = posix.STDOUT_FILENO }) catch return false;
            return true;
        }
        if (tag == .redir_fd_dup) {
            if (args.len < 1) return true;
            const token = self.sexpToStr(args[0], source) orelse return true;
            const parsed = parseFdDupToken(token) orelse return true;
            list.append(self.allocator, .{
                .tag = tag,
                .src_fd = parsed.src_fd,
                .dest_fd = parsed.dest_fd,
            }) catch return false;
            return true;
        }
        if (tag == .redir_fd_out or tag == .redir_fd_in) {
            if (args.len < 2) return true;
            const fd_token = self.sexpToStr(args[0], source) orelse return true;
            const fd = parseFdToken(fd_token) orelse return true;
            const target = self.sexpToStr(args[1], source) orelse return true;
            list.append(self.allocator, .{
                .tag = tag,
                .target = target,
                .src_fd = fd,
            }) catch return false;
            return true;
        }
        if (args.len < 1) return true;
        const target = if (tag == .herestring)
            self.sexpToExpandedStr(args[0], source)
        else
            self.sexpToStr(args[0], source) orelse return true;
        list.append(self.allocator, .{ .tag = tag, .target = target }) catch return false;
        return true;
    }

    fn applyRedirects(alloc: Allocator, redirs: []const Redirect) bool {
        for (redirs) |r| {
            const ok = switch (r.tag) {
                .redir_out => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDOUT_FILENO),
                .redir_append => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644, posix.STDOUT_FILENO),
                .redir_in => openAndDup(alloc, r.target, .{ .ACCMODE = .RDONLY }, 0, posix.STDIN_FILENO),
                .redir_err => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDERR_FILENO),
                .redir_err_app => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644, posix.STDERR_FILENO),
                .redir_both => blk: {
                    if (!openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, posix.STDOUT_FILENO))
                        break :blk false;
                    posix.dup2(posix.STDOUT_FILENO, posix.STDERR_FILENO) catch break :blk false;
                    break :blk true;
                },
                .redir_dup, .redir_fd_dup => blk: {
                    posix.dup2(r.dest_fd, r.src_fd) catch break :blk false;
                    break :blk true;
                },
                .redir_fd_out => openAndDup(alloc, r.target, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, r.src_fd),
                .redir_fd_in => openAndDup(alloc, r.target, .{ .ACCMODE = .RDONLY }, 0, r.src_fd),
                .herestring => blk: {
                    const fd = openHereStringFd(alloc, r.target) orelse break :blk false;
                    posix.dup2(fd, posix.STDIN_FILENO) catch {
                        posix.close(fd);
                        break :blk false;
                    };
                    if (fd != posix.STDIN_FILENO) posix.close(fd);
                    break :blk true;
                },
                else => true,
            };
            if (!ok) return false;
        }
        return true;
    }

    fn openAndDup(alloc: Allocator, target: []const u8, flags: posix.O, mode: posix.mode_t, dup_to: i32) bool {
        const pathZ = alloc.dupeZ(u8, target) catch {
            std.debug.print("slash: {s}: allocation failed\n", .{target});
            return false;
        };
        defer alloc.free(pathZ);
        const fd = posix.openatZ(posix.AT.FDCWD, pathZ, flags, mode) catch {
            std.debug.print("slash: {s}: cannot open\n", .{target});
            return false;
        };
        posix.dup2(fd, dup_to) catch {
            std.debug.print("slash: {s}: dup2 failed\n", .{target});
            posix.close(fd);
            return false;
        };
        if (fd != dup_to) posix.close(fd);
        return true;
    }

    fn execErrorInfo(err: posix.ExecveError) struct { code: u8, msg: []const u8 } {
        var code: u8 = 126;
        var msg: []const u8 = @errorName(err);
        switch (err) {
            error.FileNotFound => {
                code = 127;
                msg = "command not found";
            },
            error.AccessDenied, error.PermissionDenied => msg = "permission denied",
            error.InvalidExe => msg = "exec format error",
            error.IsDir => msg = "is a directory",
            error.NotDir => msg = "not a directory",
            error.FileBusy => msg = "text file busy",
            else => {},
        }
        return .{ .code = code, .msg = msg };
    }

    fn reportExecError(context: []const u8, cmd: []const u8, err: posix.ExecveError) noreturn {
        const info = execErrorInfo(err);
        std.debug.print("slash: {s}{s}: {s}\n", .{ context, cmd, info.msg });
        posix.exit(info.code);
    }

    fn reportExecErrorNoExit(context: []const u8, cmd: []const u8, err: posix.ExecveError) u8 {
        const info = execErrorInfo(err);
        std.debug.print("slash: {s}{s}: {s}\n", .{ context, cmd, info.msg });
        return info.code;
    }

    fn writeAllFd(fd: posix.fd_t, data: []const u8) bool {
        var written: usize = 0;
        while (written < data.len) {
            const n = posix.write(fd, data[written..]) catch return false;
            if (n == 0) return false;
            written += n;
        }
        return true;
    }

    fn openHereStringFd(alloc: Allocator, payload: []const u8) ?posix.fd_t {
        var path_buf: [128]u8 = undefined;
        const pid = libc.getpid();
        var attempt: u32 = 0;
        while (attempt < 64) : (attempt += 1) {
            const path = std.fmt.bufPrint(&path_buf, "/tmp/slash-hs-{d}-{d}", .{ pid, attempt }) catch return null;
            const path_z = alloc.dupeZ(u8, path) catch return null;
            defer alloc.free(path_z);
            const fd = posix.openatZ(posix.AT.FDCWD, path_z, .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .EXCL = true,
            }, 0o600) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return null,
            };
            posix.unlinkZ(path_z) catch {};
            if (!writeAllFd(fd, payload)) {
                posix.close(fd);
                return null;
            }
            if (!writeAllFd(fd, "\n")) {
                posix.close(fd);
                return null;
            }
            var file = std.fs.File{ .handle = fd };
            file.seekTo(0) catch {
                posix.close(fd);
                return null;
            };
            return fd;
        }
        return null;
    }

    fn forkExecWithRedirects(self: *Shell, argv: []const []const u8, redirs: []const Redirect) void {
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
            if (!applyRedirects(self.allocator, redirs)) posix.exit(1);
            const argv_z = toExecArgs(self.allocator, argv) catch posix.exit(127);
            const envp = buildEnvP(self.allocator, self);
            const err = posix.execvpeZ(argv_z[0].?, argv_z, envp);
            reportExecError("", argv[0], err);
        }

        if (self.interactive) {
            _ = libc.setpgid(pid, pid);
            const cmd_text = argv[0];
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

        if (text[0] == '~') {
            if (text.len == 1) return posix.getenv("HOME") orelse "~";
            if (text[1] == '/') {
                const home = posix.getenv("HOME") orelse return text;
                const result = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, text[1..] }) catch return text;
                self.cmd_expansions.append(self.allocator, result) catch {};
                return result;
            }
        }

        if (text[0] == '$') {
            if (text.len >= 2 and text[1] == '{') {
                const inner = if (text.len > 3) text[2 .. text.len - 1] else return "";
                return self.resolveBracedVar(inner);
            }
            const name = text[1..];
            return self.lookupVar(name);
        }

        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            const inner = text[1 .. text.len - 1];
            if (std.mem.indexOfScalar(u8, inner, '$') != null or std.mem.indexOfScalar(u8, inner, '\\') != null) {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                self.expandInto(&buf, inner);
                const result = buf.toOwnedSlice(self.allocator) catch return inner;
                self.cmd_expansions.append(self.allocator, result) catch {};
                return result;
            }
            return inner;
        }

        if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
            return text[1 .. text.len - 1];
        }

        return text;
    }

    fn bareVarName(text: []const u8) ?[]const u8 {
        if (text.len >= 2 and text[0] == '$') {
            if (text[1] == '{') {
                if (text.len < 4 or text[text.len - 1] != '}') return null;
                const inner = std.mem.trim(u8, text[2 .. text.len - 1], " \t");
                if (inner.len == 0 or std.mem.indexOf(u8, inner, "??") != null) return null;
                return inner;
            }
            return text[1..];
        }
        return null;
    }

    fn appendBareArgvVar(self: *Shell, list: *std.ArrayList([]const u8), literal_indices: ?*std.ArrayList(usize), text: []const u8) bool {
        const name = bareVarName(text) orelse return false;
        const value = self.lookupScopedValue(name) orelse return false;
        switch (value) {
            .argv => |items| {
                for (items) |item| {
                    if (literal_indices) |li| li.append(self.allocator, list.items.len) catch {};
                    list.append(self.allocator, item) catch {};
                }
                return true;
            },
            .scalar => return false,
        }
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
        if (std.mem.eql(u8, name, "0")) return self.lookupGlobalScalar("0") orelse "slash";
        if (std.mem.eql(u8, name, "!")) return self.lastBgPidStr();
        if (self.lookupScopedValue(name)) |val| return self.varValueToStr(val);
        return posix.getenv(name) orelse "";
    }

    fn resolveBracedVar(self: *Shell, inner_raw: []const u8) []const u8 {
        const inner = std.mem.trim(u8, inner_raw, " \t");
        if (std.mem.indexOf(u8, inner, "??")) |idx| {
            const name = std.mem.trim(u8, inner[0..idx], " \t");
            const fallback = std.mem.trim(u8, inner[idx + 2 ..], " \t");
            const value = self.lookupVar(name);
            if (value.len > 0) return value;
            return self.expandDefaultValue(fallback);
        }
        return self.lookupVar(inner);
    }

    fn expandDefaultValue(self: *Shell, raw: []const u8) []const u8 {
        if (raw.len == 0) return "";
        if (raw[0] == '$') return self.expandToken(raw);
        if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or
            (raw[0] == '\'' and raw[raw.len - 1] == '\'')))
        {
            return self.expandToken(raw);
        }
        return raw;
    }

    var argc_str_buf: [10]u8 = undefined;

    fn argCountStr(self: *Shell) []const u8 {
        return std.fmt.bufPrint(&argc_str_buf, "{d}", .{self.args.len}) catch "0";
    }

    var arg_join_buf: [4096]u8 = undefined;

    fn argJoinStr(self: *Shell) []const u8 {
        if (self.args.len == 0) return "";
        var pos: usize = 0;
        for (self.args, 0..) |a, i| {
            if (i > 0) {
                if (pos >= arg_join_buf.len) break;
                arg_join_buf[pos] = ' ';
                pos += 1;
            }
            const n = @min(a.len, arg_join_buf.len - pos);
            @memcpy(arg_join_buf[pos..][0..n], a[0..n]);
            pos += n;
        }
        return arg_join_buf[0..pos];
    }

    fn varValueToStr(self: *Shell, value: VarValue) []const u8 {
        return switch (value) {
            .scalar => |text| text,
            .argv => |items| self.joinArgvAlloc(items),
        };
    }

    fn joinArgvAlloc(self: *Shell, items: []const []const u8) []const u8 {
        if (self.argv_str_scratch) |old| {
            self.allocator.free(old);
            self.argv_str_scratch = null;
        }
        if (items.len == 0) return "";
        var total: usize = 0;
        for (items, 0..) |item, i| {
            if (i > 0) total += 1;
            total += item.len;
        }
        const buf = self.allocator.alloc(u8, total) catch return "";
        var pos: usize = 0;
        for (items, 0..) |item, i| {
            if (i > 0) { buf[pos] = ' '; pos += 1; }
            @memcpy(buf[pos..][0..item.len], item);
            pos += item.len;
        }
        self.argv_str_scratch = buf;
        return buf;
    }

    fn evalShiftValue(self: *Shell, args: []const Sexp, source: []const u8) []const u8 {
        if (args.len >= 1) {
            const raw = self.sexpToStr(args[0], source) orelse "";
            if (!std.mem.eql(u8, raw, "shift")) {
                self.last_exit = 0;
                return self.expandToken(raw);
            }
        }
        if (self.args.len == 0) {
            self.last_exit = 1;
            return "";
        }
        const val = self.args[0];
        self.args = self.args[1..];
        self.last_exit = 0;
        return val;
    }

    var exit_str_buf: [4]u8 = undefined;

    fn exitCodeStr(self: *Shell) []const u8 {
        return std.fmt.bufPrint(&exit_str_buf, "{d}", .{self.last_exit}) catch "0";
    }

    var pid_str_buf: [10]u8 = undefined;

    fn pidStr(_: *Shell) []const u8 {
        const pid = libc.getpid();
        return std.fmt.bufPrint(&pid_str_buf, "{d}", .{pid}) catch "0";
    }

    var last_bg_pid_buf: [10]u8 = undefined;

    fn lastBgPidStr(self: *Shell) []const u8 {
        if (self.last_bg_pid == 0) return "";
        return std.fmt.bufPrint(&last_bg_pid_buf, "{d}", .{self.last_bg_pid}) catch "";
    }

    // =========================================================================
    // SUBSHELL CAPTURE
    // =========================================================================

    fn evalCapture(self: *Shell, args: []const Sexp, source: []const u8) ?[]const u8 {
        if (args.len < 1) return null;

        const pipe_fds = posix.pipe() catch return null;
        const pid = posix.fork() catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return null;
        };

        if (pid == 0) {
            resetChildSignals();
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

        const trimmed = std.mem.trimRight(u8, output, "\n");
        self.cmd_expansions.append(self.allocator, output) catch {};
        return trimmed;
    }

    // =========================================================================
    // DISPLAY (= expr)
    // =========================================================================

    pub fn tryEvalMath(self: *Shell, source: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimLeft(u8, source, " \t");
        if (trimmed.len < 2 or trimmed[0] != '=') return null;
        var p = Parser.init(self.allocator, source);
        defer p.deinit();
        const sexp = p.parseOneline() catch return null;
        return switch (sexp) {
            .list => |items| if (items.len >= 2 and items[0] == .tag and items[0].tag == .display)
                formatFloat(self.evalMath(items[1], source))
            else
                null,
            else => null,
        };
    }

    fn evalDisplay(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const val = self.evalMath(args[0], source);
        const str = formatFloat(val);
        const stdout = std.fs.File.stdout();
        stdout.writeAll(str) catch {};
        stdout.writeAll("\n") catch {};
        self.last_exit = 0;
    }

    // =========================================================================
    // MATH EVALUATION (f64)
    // =========================================================================

    fn evalMathToStr(self: *Shell, sexp: Sexp, source: []const u8) []const u8 {
        return formatFloat(self.evalMath(sexp, source));
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
                            .shift_value => blk: {
                                const out = self.evalShiftValue(a, source);
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
            const spec = parseRegexSpec(rhs_raw) orelse {
                std.debug.print("slash: invalid regex: {s}\n", .{rhs_raw});
                self.last_exit = 2;
                return;
            };
            var re = (if (spec.ignore_case)
                Regex.compileIgnoreCase(spec.pattern)
            else
                Regex.compile(spec.pattern)) catch {
                std.debug.print("slash: invalid regex: {s}\n", .{spec.pattern});
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

    fn parseRegexSpec(raw: []const u8) ?struct { pattern: []const u8, ignore_case: bool } {
        if (raw.len < 2) return null;
        var start: usize = 0;
        if (raw[0] == '~') start = 1;
        if (start >= raw.len) return null;
        const delim = raw[start];
        start += 1;
        var end = start;
        while (end < raw.len) {
            if (raw[end] == '\\' and end + 1 < raw.len) {
                end += 2;
                continue;
            }
            if (raw[end] == delim) break;
            end += 1;
        }
        if (end >= raw.len) return null;
        var ignore_case = false;
        var fi = end + 1;
        while (fi < raw.len and std.ascii.isAlphabetic(raw[fi])) : (fi += 1) {
            if (raw[fi] == 'i') {
                ignore_case = true;
            } else {
                return null;
            }
        }
        if (fi != raw.len) return null;
        return .{ .pattern = raw[start..end], .ignore_case = ignore_case };
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
                            if (t == .shift_value) return self.evalShiftValue(items[1..], source);
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

    fn evalProgram(self: *Shell, args: []const Sexp, source: []const u8) void {
        for (args) |child| {
            self.eval(child, source);
            if (self.flow != .normal) return;
            if (self.last_exit != 0 and shouldAbortScriptOnFailure(child)) return;
        }
    }

    fn shouldAbortScriptOnFailure(sexp: Sexp) bool {
        switch (sexp) {
            .list => |items| {
                if (items.len > 0 and items[0] == .tag) {
                    const tag = items[0].tag;
                    if (tag == .@"if" or tag == .unless or tag == .@"while" or tag == .until or tag == .@"for" or tag == .@"try")
                        return false;
                }
                return true;
            },
            else => return true,
        }
    }

    fn evalBg(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len == 0) return;
        const pid = posix.fork() catch {
            std.debug.print("slash: fork failed\n", .{});
            self.last_exit = 1;
            return;
        };
        if (pid == 0) {
            if (self.interactive) _ = libc.setpgid(0, 0);
            resetChildSignals();
            // Background wrapper children must not inherit foreground job behavior.
            // Nested eval paths (especially pipelines) should execute detached from
            // terminal ownership logic even though they reuse the same Shell code.
            self.interactive = false;
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }
        self.last_bg_pid = pid;
        if (self.interactive) {
            _ = libc.setpgid(pid, pid);
            const cmd_text = self.commandTextForJob(args[0], source);
            const pids = [_]posix.pid_t{pid};
            const job_id = self.addJob(pid, .running, cmd_text, &pids);
            std.debug.print("[{d}] {d}\n", .{ job_id, pid });
        }
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
            resetChildSignals();
            self.eval(args[0], source);
            posix.exit(self.last_exit);
        }
        const result = posix.waitpid(pid, 0);
        self.last_exit = statusToExit(result.status);
    }

    const PipeSegment = struct { sexp: Sexp, pipe_stderr: bool };
    const MAX_PIPE_SEGMENTS = MAX_JOB_PIDS;

    fn flattenPipeline(args: []const Sexp, pipe_stderr: bool, buf: *[MAX_PIPE_SEGMENTS]PipeSegment) ?u8 {
        if (args.len < 2) return 0;
        var count: u8 = 0;

        buf[0] = .{ .sexp = args[0], .pipe_stderr = pipe_stderr };
        count = 1;

        var right = args[1];
        while (true) {
            if (count >= MAX_PIPE_SEGMENTS) return null;
            switch (right) {
                .list => |items| {
                    if (items.len >= 3 and items[0] == .tag) {
                        const tag = items[0].tag;
                        if (tag == .pipe or tag == .pipe_err) {
                            buf[count] = .{ .sexp = items[1], .pipe_stderr = (tag == .pipe_err) };
                            count += 1;
                            right = items[2];
                            continue;
                        }
                    }
                },
                else => {},
            }
            buf[count] = .{ .sexp = right, .pipe_stderr = false };
            count += 1;
            break;
        }
        return count;
    }

    fn evalPipe(self: *Shell, args: []const Sexp, source: []const u8, pipe_stderr: bool) void {
        if (args.len < 2) {
            if (args.len == 1) self.eval(args[0], source);
            return;
        }

        var seg_buf: [MAX_PIPE_SEGMENTS]PipeSegment = undefined;
        const n = flattenPipeline(args, pipe_stderr, &seg_buf) orelse {
            std.debug.print("slash: pipeline exceeds {d} stages\n", .{MAX_PIPE_SEGMENTS});
            self.last_exit = 1;
            return;
        };
        if (n < 2) {
            if (n == 1) self.eval(seg_buf[0].sexp, source);
            return;
        }
        const segments = seg_buf[0..n];

        var pipe_fds: [MAX_PIPE_SEGMENTS - 1][2]posix.fd_t = undefined;
        for (0..n - 1) |i| {
            pipe_fds[i] = posix.pipe() catch {
                for (0..i) |j| { posix.close(pipe_fds[j][0]); posix.close(pipe_fds[j][1]); }
                self.last_exit = 1;
                return;
            };
        }

        var child_pids: [MAX_PIPE_SEGMENTS]posix.pid_t = .{0} ** MAX_PIPE_SEGMENTS;
        var pgid: posix.pid_t = 0;
        var spawned: usize = 0;
        var fork_failed = false;

        for (segments, 0..) |seg, i| {
            const pid = posix.fork() catch {
                self.last_exit = 1;
                fork_failed = true;
                break;
            };

            if (pid == 0) {
                if (self.interactive) _ = libc.setpgid(0, if (pgid != 0) pgid else 0);
                resetChildSignals();

                if (i > 0) {
                    posix.dup2(pipe_fds[i - 1][0], posix.STDIN_FILENO) catch posix.exit(1);
                }
                if (i < n - 1) {
                    posix.dup2(pipe_fds[i][1], posix.STDOUT_FILENO) catch posix.exit(1);
                    if (seg.pipe_stderr)
                        posix.dup2(pipe_fds[i][1], posix.STDERR_FILENO) catch posix.exit(1);
                }

                for (0..n - 1) |j| {
                    posix.close(pipe_fds[j][0]);
                    posix.close(pipe_fds[j][1]);
                }

                self.eval(seg.sexp, source);
                posix.exit(self.last_exit);
            }

            if (i == 0) pgid = pid;
            if (self.interactive) _ = libc.setpgid(pid, pgid);
            child_pids[i] = pid;
            spawned += 1;
        }

        for (0..n - 1) |i| {
            posix.close(pipe_fds[i][0]);
            posix.close(pipe_fds[i][1]);
        }

        if (fork_failed) {
            for (child_pids[0..spawned]) |pid| {
                if (pid > 0) posix.kill(pid, posix.SIG.TERM) catch {};
            }
            for (child_pids[0..spawned]) |pid| {
                if (pid > 0) _ = posix.waitpid(pid, 0);
            }
            self.last_exit = 1;
            return;
        }

        if (self.interactive) {
            const cmd_text = self.sourceSpanForArgs(args[0..2], source);
            const job_id = self.addJob(pgid, .running, cmd_text, child_pids[0..spawned]);
            _ = libc.tcsetpgrp(self.tty_fd, pgid);
            self.waitForForegroundJob(pgid, @intCast(spawned));
            if (self.findJobById(job_id)) |job| {
                if (job.state != .stopped) self.removeJob(job_id);
            }
        } else {
            var last_exit: u8 = 0;
            for (0..spawned) |i| {
                const result = posix.waitpid(child_pids[i], 0);
                if (i == spawned - 1) last_exit = statusToExit(result.status);
            }
            self.last_exit = last_exit;
        }
    }

    // =========================================================================
    // ASSIGNMENT
    // =========================================================================

    fn buildArgvValue(self: *Shell, sexp: Sexp, source: []const u8) ?VarValue {
        const items = switch (sexp) {
            .list => |list_items| list_items,
            else => return null,
        };
        if (items.len == 0 or items[0] != .tag or items[0].tag != .list) return null;

        var result: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (result.items) |item| self.allocator.free(item);
            result.deinit(self.allocator);
        }

        for (items[1..]) |item| {
            switch (item) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    if (text.len >= 2 and text[0] == '$' and std.mem.eql(u8, text[1..], "*")) {
                        for (self.args) |a| {
                            result.append(self.allocator, self.allocator.dupe(u8, a) catch return null) catch return null;
                        }
                        continue;
                    }
                    if (text.len >= 2 and text[0] == '$') {
                        const name = bareVarName(text) orelse {
                            self.dupeExpandedToken(&result, text) orelse return null;
                            continue;
                        };
                        if (self.lookupScopedValue(name)) |val| {
                            switch (val) {
                                .argv => |av| {
                                    for (av) |a| result.append(self.allocator, self.allocator.dupe(u8, a) catch return null) catch return null;
                                    continue;
                                },
                                .scalar => {},
                            }
                        }
                    }
                    self.dupeExpandedToken(&result, text) orelse return null;
                },
                else => {
                    const text = self.sexpToExpandedStr(item, source);
                    result.append(self.allocator, self.allocator.dupe(u8, text) catch return null) catch return null;
                },
            }
        }
        const owned = result.toOwnedSlice(self.allocator) catch return null;
        return .{ .argv = owned };
    }

    fn dupeExpandedToken(self: *Shell, list: *std.ArrayListUnmanaged([]const u8), text: []const u8) ?void {
        const expanded = self.expandToken(text);
        const owned = self.allocator.dupe(u8, expanded) catch return null;
        list.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return null;
        };
    }

    fn evalAssign(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const value = self.allocator.dupe(u8, self.sexpToExpandedStr(args[1], source)) catch return;
        _ = self.putOwnedVar(self.currentVarMap(), name_raw, .{ .scalar = value });
        self.last_exit = 0;
    }

    fn evalAssignArgv(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const value = self.buildArgvValue(args[1], source) orelse return;
        _ = self.putOwnedVar(self.currentVarMap(), name_raw, value);
        self.last_exit = 0;
    }

    fn evalAppendArgv(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const extra = self.buildArgvValue(args[1], source) orelse return;
        const append_items = switch (extra) {
            .argv => |items| items,
            .scalar => unreachable,
        };
        var map = self.currentVarMap();
        if (map.getPtr(name_raw)) |slot| {
            switch (slot.*) {
                .argv => |existing| {
                    const merged = self.allocator.alloc([]const u8, existing.len + append_items.len) catch {
                        self.deinitVarValue(extra);
                        return;
                    };
                    @memcpy(merged[0..existing.len], existing);
                    @memcpy(merged[existing.len..][0..append_items.len], append_items);
                    self.allocator.free(existing);
                    self.allocator.free(append_items);
                    slot.* = .{ .argv = merged };
                },
                .scalar => {
                    self.deinitVarValue(extra);
                    self.last_exit = 1;
                    return;
                },
            }
        } else {
            _ = self.putOwnedVar(map, name_raw, extra);
        }
        self.last_exit = 0;
    }

    fn evalUnset(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.currentVarMap().fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.deinitVarValue(kv.value);
        }
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
                    const val = self.allocator.dupe(u8, self.sexpToExpandedStr(item, source)) catch continue;
                    _ = self.putOwnedVar(self.currentVarMap(), var_name, .{ .scalar = val });
                    self.eval(body, source);
                    if (self.flow != .normal) {
                        if (self.flow == .break_loop) self.flow = .normal;
                        if (self.flow == .continue_loop) { self.flow = .normal; continue; }
                        break;
                    }
                }
            },
            else => {
                const val = self.allocator.dupe(u8, self.sexpToExpandedStr(word_list, source)) catch return;
                _ = self.putOwnedVar(self.currentVarMap(), var_name, .{ .scalar = val });
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
            if (self.flow != .normal) {
                if (self.flow == .break_loop) self.flow = .normal;
                if (self.flow == .continue_loop) { self.flow = .normal; continue; }
                break;
            }
        }
    }

    fn evalUntil(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        while (true) {
            self.eval(args[0], source);
            if (self.last_exit == 0) break;
            self.eval(args[1], source);
            if (self.flow != .normal) {
                if (self.flow == .break_loop) self.flow = .normal;
                if (self.flow == .continue_loop) { self.flow = .normal; continue; }
                break;
            }
        }
    }

    fn evalTry(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const value = self.sexpToExpandedStr(args[0], source);

        if (args[1] == .list) {
            for (args[1].list) |arm_sexp| {
                if (self.tryExecArm(arm_sexp, value, source)) return;
            }
        } else {
            for (args[1..]) |arm_sexp| {
                if (self.tryExecArm(arm_sexp, value, source)) return;
            }
        }
        self.last_exit = 1;
    }

    fn tryExecArm(self: *Shell, arm_sexp: Sexp, value: []const u8, source: []const u8) bool {
        switch (arm_sexp) {
            .list => |items| {
                if (items.len < 2) return false;
                switch (items[0]) {
                    .tag => |t| {
                        if (t == .arm_else) {
                            self.eval(items[1], source);
                            return true;
                        }
                        if (t == .arm and items.len >= 3 and self.tryPatternMatches(items[1], value, source)) {
                            self.eval(items[2], source);
                            return true;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        return false;
    }

    fn tryPatternMatches(self: *Shell, pattern_sexp: Sexp, value: []const u8, source: []const u8) bool {
        const raw = self.sexpToStr(pattern_sexp, source) orelse return false;
        if (parseRegexSpec(raw)) |spec| {
            var re = (if (spec.ignore_case)
                Regex.compileIgnoreCase(spec.pattern)
            else
                Regex.compile(spec.pattern)) catch return false;
            defer re.free();
            return re.search(value);
        }
        const pattern = self.sexpToExpandedStr(pattern_sexp, source);
        return std.mem.eql(u8, value, pattern);
    }

    // =========================================================================
    // TEST BUILTIN
    // =========================================================================

    fn evalTest(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) { self.last_exit = 1; return; }
        const flag = self.sexpToStr(args[0], source) orelse { self.last_exit = 1; return; };
        const path = self.sexpToExpandedStr(args[1], source);

        if (std.mem.eql(u8, flag, "-e")) {
            posix.access(path, posix.F_OK) catch { self.last_exit = 1; return; };
            self.last_exit = 0;
            return;
        }
        if (std.mem.eql(u8, flag, "-r")) {
            posix.access(path, posix.R_OK) catch { self.last_exit = 1; return; };
            self.last_exit = 0;
            return;
        }
        if (std.mem.eql(u8, flag, "-w")) {
            posix.access(path, posix.W_OK) catch { self.last_exit = 1; return; };
            self.last_exit = 0;
            return;
        }
        if (std.mem.eql(u8, flag, "-x")) {
            posix.access(path, posix.X_OK) catch { self.last_exit = 1; return; };
            self.last_exit = 0;
            return;
        }
        if (std.mem.eql(u8, flag, "-L")) {
            const stat = posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch {
                self.last_exit = 1;
                return;
            };
            self.last_exit = if ((stat.mode & posix.S.IFMT) == posix.S.IFLNK) 0 else 1;
            return;
        }

        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch {
            self.last_exit = 1;
            return;
        };

        if (std.mem.eql(u8, flag, "-f")) {
            self.last_exit = if (stat.kind == .file) 0 else 1;
        } else if (std.mem.eql(u8, flag, "-d")) {
            self.last_exit = if (stat.kind == .directory) 0 else 1;
        } else if (std.mem.eql(u8, flag, "-s")) {
            self.last_exit = if (stat.size > 0) 0 else 1;
        } else {
            self.last_exit = 1;
        }
    }

    // =========================================================================
    // EXEC (replace process)
    // =========================================================================

    fn evalExec(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        var build_ok = true;

        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        var redir_list: std.ArrayList(Redirect) = .empty;
        defer redir_list.deinit(self.allocator);
        var procsub_fds: std.ArrayList(ProcSubFd) = .empty;
        defer procsub_fds.deinit(self.allocator);

        const inner = switch (args[0]) {
            .list => |items| items,
            else => return,
        };
        if (inner.len < 2) return;
        for (inner[1..]) |arg| {
            switch (arg) {
                .src => |s| {
                    const text = source[s.pos..][0..s.len];
                    if (self.appendBareArgvVar(&argv_list, null, text)) continue;
                    argv_list.append(self.allocator, self.expandToken(text)) catch {
                        build_ok = false;
                    };
                },
                .list => |items| {
                    if (items.len == 0) continue;
                    switch (items[0]) {
                        .tag => |tag| {
                            if (isRedirTag(tag)) {
                                if (!self.collectRedirect(tag, items[1..], source, &redir_list)) build_ok = false;
                                continue;
                            }
                            if (tag == .capture) {
                                const val = self.evalCapture(items[1..], source);
                                if (val) |v| argv_list.append(self.allocator, v) catch {
                                    build_ok = false;
                                };
                                continue;
                            }
                            if (isHeredocTag(tag)) {
                                if (!self.collectHeredocRedirect(tag, items[1..], source, &redir_list)) build_ok = false;
                                continue;
                            }
                            if (tag == .procsub_in or tag == .procsub_out) {
                                if (self.spawnProcSub(tag, items[1..], source, &procsub_fds)) |path| {
                                    argv_list.append(self.allocator, path) catch {
                                        build_ok = false;
                                    };
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
        if (!build_ok) {
            std.debug.print("slash: exec: setup failed (allocation error)\n", .{});
            self.last_exit = 1;
            return;
        }

        const argv = argv_list.items;
        if (argv.len == 0) return;

        var saved: [3]posix.fd_t = .{ -1, -1, -1 };
        const has_redirs = redir_list.items.len > 0;
        if (has_redirs) {
            saved[0] = posix.dup(posix.STDIN_FILENO) catch -1;
            saved[1] = posix.dup(posix.STDOUT_FILENO) catch -1;
            saved[2] = posix.dup(posix.STDERR_FILENO) catch -1;
        }
        defer {
            if (saved[0] != -1) { posix.dup2(saved[0], posix.STDIN_FILENO) catch {}; posix.close(saved[0]); }
            if (saved[1] != -1) { posix.dup2(saved[1], posix.STDOUT_FILENO) catch {}; posix.close(saved[1]); }
            if (saved[2] != -1) { posix.dup2(saved[2], posix.STDERR_FILENO) catch {}; posix.close(saved[2]); }
            self.cleanupProcSubs(procsub_fds.items);
        }

        if (!applyRedirects(self.allocator, redir_list.items)) {
            self.last_exit = 1;
            return;
        }
        resetChildSignals();
        const argv_z = toExecArgs(self.allocator, argv) catch {
            std.debug.print("slash: exec: allocation failed\n", .{});
            self.last_exit = 1;
            return;
        };
        const envp = buildEnvP(self.allocator, self);
        const err = posix.execvpeZ(argv_z[0].?, argv_z, envp);
        self.last_exit = reportExecErrorNoExit("exec: ", argv[0], err);
    }

    // =========================================================================
    // BUILTINS
    // =========================================================================

    fn tryBuiltin(self: *Shell, argv: []const []const u8) bool {
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
            if (pos > 0) {
                if (!self.chdirTracked("cd", buf[0..pos])) return true;
            }
            self.last_exit = 0;
            return true;
        }
        if (std.mem.eql(u8, name, "echo")) { self.builtinEcho(argv); return true; }
        if (std.mem.eql(u8, name, "true")) { self.last_exit = 0; return true; }
        if (std.mem.eql(u8, name, "false")) { self.last_exit = 1; return true; }
        if (std.mem.eql(u8, name, "type")) { self.builtinType(argv); return true; }
        if (std.mem.eql(u8, name, "pwd")) { self.builtinPwd(); return true; }
        if (std.mem.eql(u8, name, "shift")) { self.builtinShift(argv); return true; }
        if (std.mem.eql(u8, name, "jobs")) { self.builtinJobs(); return true; }
        if (std.mem.eql(u8, name, "wait")) { self.builtinWait(argv); return true; }
        if (std.mem.eql(u8, name, "history")) { self.builtinHistory(argv); return true; }
        if (std.mem.eql(u8, name, "j")) { self.builtinJ(argv); return true; }
        if (std.mem.eql(u8, name, "fg")) { self.builtinFg(argv); return true; }
        if (std.mem.eql(u8, name, "bg")) { self.builtinBg(argv); return true; }

        return false;
    }

    fn builtinCd(self: *Shell, argv: []const []const u8) void {
        const raw = if (argv.len > 1) argv[1] else posix.getenv("HOME") orelse "/";
        const target = if (raw.len == 1 and raw[0] == '-') blk: {
            break :blk self.lookupGlobalScalar("OLDPWD") orelse {
                std.debug.print("cd: OLDPWD not set\n", .{});
                self.last_exit = 1;
                return;
            };
        } else raw;
        if (!self.chdirTracked("cd", target)) return;
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

    fn builtinShift(self: *Shell, argv: []const []const u8) void {
        var count: usize = 1;
        if (argv.len > 2) {
            std.debug.print("slash: shift: too many arguments\n", .{});
            self.last_exit = 1;
            return;
        }
        if (argv.len == 2) {
            count = std.fmt.parseInt(usize, argv[1], 10) catch {
                std.debug.print("slash: shift: invalid count: {s}\n", .{argv[1]});
                self.last_exit = 1;
                return;
            };
        }
        if (count >= self.args.len) {
            self.args = self.args[self.args.len..];
        } else {
            self.args = self.args[count..];
        }
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
        var ordered: [MAX_JOBS]Job = undefined;
        const count = self.collectJobsOrdered(&ordered);
        for (ordered[0..count]) |job| {
            const state_str = switch (job.state) {
                .running => "Running",
                .stopped => "Stopped",
                .done => "Done",
            };
            printOut("[{d}]  {s}\t\t{s}\n", .{ job.id, state_str, job.command });
        }
        self.last_exit = 0;
    }

    fn collectJobsOrdered(self: *Shell, out: *[MAX_JOBS]Job) usize {
        var count: usize = 0;
        for (&self.jobs) |*slot| {
            if (slot.*) |job| {
                out[count] = job;
                count += 1;
            }
        }
        var i: usize = 1;
        while (i < count) : (i += 1) {
            var j = i;
            while (j > 0 and out[j - 1].id > out[j].id) : (j -= 1) {
                const tmp = out[j - 1];
                out[j - 1] = out[j];
                out[j] = tmp;
            }
        }
        return count;
    }

    fn builtinWait(self: *Shell, argv: []const []const u8) void {
        // wait [job|pid]...
        //
        // Minimal semantics:
        // - wait          : wait for all running jobs (interactive) or all children (script mode)
        // - wait N        : if N matches a job id, wait for that job; otherwise treat as PID
        // - wait $!       : works (PID of last background wrapper)
        //
        // Note: we intentionally avoid waiting on stopped jobs (it would hang and isn't
        // interruptible because the shell ignores SIGINT).
        if (argv.len == 1) {
            if (self.interactive) {
                // Wait for all running jobs (stopped jobs are ignored).
                var waited_any = false;
                while (true) {
                    var next_id: ?u16 = null;
                    var consume_done = false;
                    for (&self.jobs) |*slot| {
                        if (slot.*) |*job| {
                            if (job.state == .done) {
                                next_id = job.id;
                                consume_done = true;
                                break;
                            }
                            if (job.state == .running) {
                                next_id = job.id;
                                break;
                            }
                        }
                    }
                    if (next_id == null) break;
                    waited_any = true;
                    if (self.findJobById(next_id.?)) |job| {
                        if (consume_done) {
                            self.last_exit = job.exit_code;
                            self.removeJob(job.id);
                            continue;
                        }
                        self.waitForForegroundJob(job.pgid, job.pid_count);
                        if (job.state != .stopped) self.removeJob(job.id);
                    }
                }
                if (!waited_any) self.last_exit = 0;
                return;
            }

            // Script mode: wait for all remaining children.
            var waited_any = false;
            while (true) {
                var status: i32 = 0;
                const pid = libc.waitpid(-1, &status, libc.WUNTRACED);
                if (pid <= 0) break;
                waited_any = true;
                const ustatus: u32 = @bitCast(status);
                if (posix.W.IFSTOPPED(ustatus)) {
                    self.last_exit = 1;
                    return;
                }
                self.last_exit = statusToExit(ustatus);
            }
            if (!waited_any) self.last_exit = 0;
            return;
        }

        for (argv[1..]) |tok| {
            if (tok.len == 0) continue;

            // Prefer job-id semantics when an existing job matches.
            var handled = false;
            if (std.fmt.parseInt(u16, tok, 10)) |jid| {
                if (self.findJobById(jid)) |job| {
                    if (job.state == .stopped) {
                        std.debug.print("wait: {s}: job is stopped (use fg/bg)\n", .{tok});
                        self.last_exit = 1;
                        return;
                    }
                    if (job.state == .done) {
                        self.last_exit = job.exit_code;
                        self.removeJob(job.id);
                        handled = true;
                        continue;
                    }
                    self.waitForForegroundJob(job.pgid, job.pid_count);
                    if (job.state != .stopped) self.removeJob(job.id);
                    handled = true;
                }
            } else |_| {}
            if (handled) continue;

            // Otherwise treat as PID.
            const pid = std.fmt.parseInt(posix.pid_t, tok, 10) catch {
                std.debug.print("wait: {s}: invalid pid\n", .{tok});
                self.last_exit = 1;
                return;
            };
            if (pid <= 0) {
                std.debug.print("wait: {s}: invalid pid\n", .{tok});
                self.last_exit = 1;
                return;
            }

            var status: i32 = 0;
            const waited_pid = libc.waitpid(pid, &status, libc.WUNTRACED);
            if (waited_pid <= 0) {
                std.debug.print("wait: {s}: no such child\n", .{tok});
                self.last_exit = 1;
                return;
            }
            const ustatus: u32 = @bitCast(status);
            if (posix.W.IFSTOPPED(ustatus)) {
                self.last_exit = 1;
                return;
            }
            self.last_exit = statusToExit(ustatus);

            // If this PID is also tracked as a job pgid, clean it up.
            if (self.interactive) {
                if (self.findJobByPgid(pid)) |job| {
                    if (job.state != .stopped) self.removeJob(job.id);
                }
            }
        }
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

    fn builtinHistory(self: *Shell, argv: []const []const u8) void {
        const hdb = self.history_db orelse {
            std.debug.print("history: database not available\n", .{});
            self.last_exit = 1;
            return;
        };
        const query = if (argv.len > 1) argv[1] else "";
        const limit: usize = if (argv.len > 2) std.fmt.parseInt(usize, argv[2], 10) catch 20 else 20;
        const results = hdb.search(self.allocator, query, limit);
        defer {
            for (results) |cmd| self.allocator.free(cmd);
            if (results.len > 0) self.allocator.free(results);
        }
        for (results) |cmd| printOut("{s}\n", .{cmd});
        self.last_exit = 0;
    }

    fn builtinJ(self: *Shell, argv: []const []const u8) void {
        const query = if (argv.len > 1) argv[1] else "";
        var filtered: [9][]const u8 = .{""} ** 9;
        var count: usize = 0;
        const mru_count: usize = @intCast(self.dir_mru_count);
        for (self.dir_mru[0..mru_count]) |path| {
            if (query.len > 0 and std.mem.indexOf(u8, path, query) == null) continue;
            filtered[count] = path;
            count += 1;
            if (count >= filtered.len) break;
        }

        if (count == 0) {
            if (query.len > 0)
                std.debug.print("j: no matches for '{s}'\n", .{query})
            else
                std.debug.print("j: no directory history\n", .{});
            self.last_exit = 1;
            return;
        }

        // j [query] — list and store for digit jump
        self.clearJList();
        for (filtered[0..count], 0..) |path, i| {
            printOut("{d} {s}\n", .{ i + 1, path });
            self.j_list[i] = self.allocator.dupe(u8, path) catch {
                std.debug.print("j: out of memory\n", .{});
                self.clearJList();
                self.last_exit = 1;
                return;
            };
            self.j_count = @intCast(i + 1);
        }
        self.last_exit = 0;
    }

    pub fn builtinJumpTo(self: *Shell, idx: usize) void {
        if (idx >= self.j_count) {
            std.debug.print("j: no entry {d}\n", .{idx + 1});
            self.last_exit = 1;
            return;
        }
        if (!self.chdirTracked("j", self.j_list[idx])) return;
        self.last_exit = 0;
    }

    fn builtinType(self: *Shell, argv: []const []const u8) void {
        for (argv[1..]) |name| {
            if (self.user_cmds.contains(name)) {
                printOut("{s} is a user command\n", .{name});
            } else if (isBuiltin(name)) {
                printOut("{s} is a shell builtin\n", .{name});
            } else {
                printOut("{s}: not found\n", .{name});
            }
        }
        self.last_exit = 0;
    }

    // Authoritative list of all builtin command names. Two dispatch layers:
    //   tryBuiltin()       — runtime builtins, arrive as (cmd "name" ...)
    //   dispatch/Keyword() — parser keywords with own s-expression tags
    // Control-flow keywords (if/for/while/unless/until/try/else) and
    // operator keywords (and/or/not/xor/in) are syntax, not commands,
    // and are intentionally excluded.
    pub const keyword_names = [_][]const u8{
        "if",   "unless", "else",     "for",    "in",       "while",
        "until", "try",   "and",      "or",     "not",      "xor",
        "cmd",  "key",    "set",      "test",   "source",   "exit",
        "exec", "break",  "continue", "shift",
    };

    pub const builtin_names = [_][]const u8{
        "cd",      "echo",    "true",    "false",   "type",    "pwd",
        "jobs",    "fg",      "bg",      "wait",    "history", "j",
        "exec",    "exit",    "source",
        "set",     "cmd",     "key",
        "test",    "shift",   "break",   "continue",
    };

    fn isBuiltin(name: []const u8) bool {
        if (name.len >= 2 and name[0] == '.' and std.mem.allEqual(u8, name, '.')) return true;
        inline for (builtin_names) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn invokeUserCmd(self: *Shell, cmd: UserCmd, argv: []const []const u8) void {
        const params = cmd.params;
        const call_args = argv[1..];
        const saved_args = self.args;
        self.args = call_args;
        defer self.args = saved_args;

        if (!self.pushLocalScope()) return;
        defer self.popLocalScope();

        const scope = self.currentVarMap();
        for (params, 0..) |pname, i| {
            const raw = if (i < call_args.len) call_args[i] else "";
            const val = self.allocator.dupe(u8, raw) catch continue;
            _ = self.putOwnedVar(scope, pname, .{ .scalar = val });
        }

        self.eval(cmd.body, cmd.source);
        if (self.flow == .exit_cmd) self.flow = .normal;
    }

    // =========================================================================
    // CMD / SET MANAGEMENT
    // =========================================================================

    fn evalCmdDef(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
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

        const new_cmd = UserCmd{
            .params = params,
            .body = UserCmd.dupeSexp(self.allocator, args[args.len - 1]),
            .source = source_copy,
        };

        if (self.user_cmds.getPtr(name_raw)) |slot| {
            slot.deinit(self.allocator);
            slot.* = new_cmd;
        } else {
            const name = self.allocator.dupe(u8, name_raw) catch return;
            self.user_cmds.put(name, new_cmd) catch {};
        }
        self.last_exit = 0;
    }

    fn evalCmdDel(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.user_cmds.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }
        self.last_exit = 0;
    }

    fn evalCmdMissingDef(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const source_copy = self.allocator.dupe(u8, source) catch return;

        var params: [][]const u8 = &.{};
        const body_idx: usize = if (args.len >= 3 and args[1] == .list) blk: {
            const plist = args[1].list;
            var param_names = self.allocator.alloc([]const u8, plist.len) catch return;
            for (plist, 0..) |p, i| {
                param_names[i] = self.allocator.dupe(u8, self.sexpToStr(p, source) orelse "") catch "";
            }
            params = param_names;
            break :blk args.len - 1;
        } else args.len - 1;

        const new_cmd = UserCmd{
            .params = params,
            .body = UserCmd.dupeSexp(self.allocator, args[body_idx]),
            .source = source_copy,
        };

        if (self.user_cmds.getPtr("???")) |slot| {
            slot.deinit(self.allocator);
            slot.* = new_cmd;
        } else {
            const name = self.allocator.dupe(u8, "???") catch return;
            self.user_cmds.put(name, new_cmd) catch {};
        }
        self.last_exit = 0;
    }

    fn evalCmdMissingDel(self: *Shell) void {
        if (self.user_cmds.fetchRemove("???")) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }
        self.last_exit = 0;
    }

    fn evalCmdShow(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        self.showCmd(name);
    }

    fn evalCmdMissingShow(self: *Shell) void {
        self.showCmd("???");
    }

    fn showCmd(self: *Shell, name: []const u8) void {
        if (self.user_cmds.get(name)) |cmd| {
            printCmdDefinition(name, cmd);
        } else {
            std.debug.print("slash: cmd {s}: not defined\n", .{name});
        }
        self.last_exit = 0;
    }

    fn evalCmdList(self: *Shell) void {
        var it = self.user_cmds.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const cmd = entry.value_ptr.*;
            printCmdDefinition(name, cmd);
        }
        self.last_exit = 0;
    }

    fn printCmdDefinition(name: []const u8, cmd: UserCmd) void {
        const stdout = std.fs.File.stdout();
        printOut("cmd {s}", .{name});
        if (cmd.params.len > 0) {
            stdout.writeAll("(") catch {};
            for (cmd.params, 0..) |p, i| {
                if (i > 0) stdout.writeAll(", ") catch {};
                stdout.writeAll(p) catch {};
            }
            stdout.writeAll(")") catch {};
        }
        const span = sexpSourceSpan(cmd.body, cmd.source);
        if (span.len > 0) {
            if (std.mem.indexOfScalar(u8, span, '\n') != null) {
                printOut("\n    {s}\n", .{span});
            } else {
                printOut(" {s}\n", .{span});
            }
        } else {
            stdout.writeAll("\n") catch {};
        }
    }

    fn sexpSourceSpan(sexp: Sexp, source: []const u8) []const u8 {
        var lo: u32 = @intCast(source.len);
        var hi: u32 = 0;
        sexpSpanWalk(sexp, &lo, &hi);
        if (lo >= hi) return "";
        return std.mem.trim(u8, source[lo..hi], " \t\n");
    }

    fn sourceSpanForArgs(self: *Shell, args: []const Sexp, source: []const u8) []const u8 {
        var lo: u32 = @intCast(source.len);
        var hi: u32 = 0;
        for (args) |arg| sexpSpanWalk(arg, &lo, &hi);
        if (lo < hi) return std.mem.trim(u8, source[lo..hi], " \t\n");
        return self.commandTextFallback(source);
    }

    fn commandTextForJob(self: *Shell, sexp: Sexp, source: []const u8) []const u8 {
        const span = sexpSourceSpan(sexp, source);
        if (span.len > 0) return span;
        return self.commandTextFallback(source);
    }

    fn commandTextFallback(_: *Shell, source: []const u8) []const u8 {
        const prefix = source[0..@min(source.len, 80)];
        const trimmed = std.mem.trim(u8, prefix, " \t\r\n");
        return if (trimmed.len > 0) trimmed else "<job>";
    }

    fn sexpSpanWalk(sexp: Sexp, lo: *u32, hi: *u32) void {
        switch (sexp) {
            .src => |s| {
                if (s.pos < lo.*) lo.* = s.pos;
                const end = s.pos + s.len;
                if (end > hi.*) hi.* = end;
            },
            .list => |items| {
                for (items) |child| sexpSpanWalk(child, lo, hi);
            },
            else => {},
        }
    }

    fn evalKey(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        var owned_combo: ?[]const u8 = null;
        defer if (owned_combo) |s| self.allocator.free(s);
        const combo_raw = self.keyComboText(args[0], source, &owned_combo) orelse return;
        const command_text = switch (args[1]) {
            .list => self.commandTextForJob(args[1], source),
            else => self.sexpToExpandedStr(args[1], source),
        };
        const command = self.allocator.dupe(u8, command_text) catch return;
        if (self.key_bindings.getPtr(combo_raw)) |slot| {
            self.allocator.free(slot.*);
            slot.* = command;
        } else {
            const combo = self.allocator.dupe(u8, combo_raw) catch return;
            self.key_bindings.put(combo, command) catch {};
        }
        self.last_exit = 0;
    }

    fn evalKeyDel(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        var owned_combo: ?[]const u8 = null;
        defer if (owned_combo) |s| self.allocator.free(s);
        const combo = self.keyComboText(args[0], source, &owned_combo) orelse return;
        if (self.key_bindings.fetchRemove(combo)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        self.last_exit = 0;
    }

    fn evalKeyList(self: *Shell) void {
        var it = self.key_bindings.iterator();
        while (it.next()) |entry| printOut("key {s} {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        self.last_exit = 0;
    }

    pub fn lookupKeyBinding(self: *Shell, combo: []const u8) ?[]const u8 {
        return self.key_bindings.get(combo);
    }

    fn keyComboText(self: *Shell, combo_sexp: Sexp, source: []const u8, owned_out: *?[]const u8) ?[]const u8 {
        switch (combo_sexp) {
            .src, .str => return self.sexpToStr(combo_sexp, source),
            .list => |items| {
                if (items.len >= 2 and items[0] == .tag and items[0].tag == .key_combo_eq) {
                    const base = self.sexpToStr(items[1], source) orelse return null;
                    const full = std.fmt.allocPrint(self.allocator, "{s}=", .{base}) catch return null;
                    owned_out.* = full;
                    return full;
                }
                return null;
            },
            else => return null,
        }
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
        const saved_0 = self.lookupGlobalScalar("0");
        const saved_0_copy = if (saved_0) |s| self.allocator.dupe(u8, s) catch null else null;
        self.setScriptPath(path);
        self.execSource(content);
        if (saved_0_copy) |old| {
            self.setVarDupe("0", old);
            self.allocator.free(old);
        }
    }

    fn evalExit(self: *Shell, args: []const Sexp, source: []const u8) void {
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
        self.last_exit = code;
        self.flow = .exit_cmd;
    }

    fn evalSet(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 2) return;
        const name_raw = self.sexpToStr(args[0], source) orelse return;
        const value = self.allocator.dupe(u8, self.sexpToExpandedStr(args[1], source)) catch return;
        if (self.options.getPtr(name_raw)) |slot| {
            self.allocator.free(slot.*);
            slot.* = value;
        } else {
            const name = self.allocator.dupe(u8, name_raw) catch return;
            self.options.put(name, value) catch return;
        }
        self.last_exit = 0;
    }

    fn evalSetReset(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.options.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        self.last_exit = 0;
    }

    fn evalSetShow(self: *Shell, args: []const Sexp, source: []const u8) void {
        if (args.len < 1) return;
        const name = self.sexpToStr(args[0], source) orelse return;
        if (self.options.get(name)) |val| {
            printOut("{s}={s}\n", .{ name, val });
        } else {
            printOut("{s}: not set\n", .{name});
        }
        self.last_exit = 0;
    }

    fn evalSetList(self: *Shell) void {
        var it = self.options.iterator();
        while (it.next()) |entry| printOut("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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

    fn collectHeredocRedirect(self: *Shell, tag: Tag, args: []const Sexp, source: []const u8, list: *std.ArrayList(Redirect)) bool {
        var content: std.ArrayListUnmanaged(u8) = .{};
        defer content.deinit(self.allocator);
        const interpolate = (tag == .heredoc_interp or tag == .heredoc_lang);
        const start: usize = if (tag == .heredoc_lang and args.len > 0) 1 else 0;
        var first = true;
        for (args[start..]) |body| {
            if (!first) content.append(self.allocator, '\n') catch return false;
            first = false;
            const text = self.sexpToStr(body, source) orelse continue;
            if (interpolate) {
                self.expandInto(&content, text);
            } else {
                content.appendSlice(self.allocator, text) catch return false;
            }
        }
        const result = content.toOwnedSlice(self.allocator) catch return false;
        self.cmd_expansions.append(self.allocator, result) catch {
            self.allocator.free(result);
            return false;
        };
        list.append(self.allocator, .{ .tag = .herestring, .target = result }) catch {
            _ = self.cmd_expansions.pop();
            self.allocator.free(result);
            return false;
        };
        return true;
    }

    fn expandInto(self: *Shell, buf: *std.ArrayListUnmanaged(u8), text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '$' and i + 1 < text.len) {
                if (text[i + 1] == '{') {
                    if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |close| {
                        const inner = text[i + 2 .. close];
                        const val = self.resolveBracedVar(inner);
                        buf.appendSlice(self.allocator, val) catch {};
                        i = close + 1;
                        continue;
                    }
                } else {
                    const name_start = i + 1;
                    var name_end = name_start;
                    if (name_end < text.len and (text[name_end] == '?' or text[name_end] == '$' or
                        text[name_end] == '#' or text[name_end] == '*' or text[name_end] == '!' or
                        (text[name_end] >= '0' and text[name_end] <= '9')))
                    {
                        name_end += 1;
                    } else {
                        while (name_end < text.len and (std.ascii.isAlphanumeric(text[name_end]) or text[name_end] == '_')) : (name_end += 1) {}
                    }
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
                    '"' => buf.append(self.allocator, '"') catch {},
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
// STDOUT HELPER
// =============================================================================

fn printOut(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        stdout.writeAll(fmt) catch {};
        return;
    };
    stdout.writeAll(text) catch {};
}

// =============================================================================
// EXEC HELPERS
// =============================================================================

fn toExecArgs(alloc: Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const buf = try alloc.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| buf[i] = try alloc.dupeZ(u8, arg);
    buf[argv.len] = null;
    return @ptrCast(buf.ptr);
}

// Called in the child process after fork(), so allocations are intentionally
// not freed — exec() replaces the process image, or _exit() terminates it.
fn buildEnvP(alloc: Allocator, shell: *const Shell) [*:null]const ?[*:0]const u8 {
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    var seen_exports = std.StringHashMap(void).init(alloc);
    defer seen_exports.deinit();
    const env = std.c.environ;
    var i: usize = 0;
    while (env[i]) |entry| : (i += 1) {
        const slice: [*]const u8 = @ptrCast(entry);
        var len: usize = 0;
        while (slice[len] != 0) len += 1;
        const text = slice[0..len];
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse text.len;
        const name = text[0..eq];
        if (shell.hasExportOverride(name)) continue;
        envp.append(alloc, alloc.dupeZ(u8, text) catch continue) catch continue;
    }

    var scope_index = shell.local_scopes.items.len;
    while (scope_index > 0) {
        scope_index -= 1;
        var it = shell.local_scopes.items[scope_index].vars.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!shouldExportVar(name) or seen_exports.contains(name)) continue;
            seen_exports.put(name, {}) catch continue;
            const name_len = name.len;
            const val = entry.value_ptr.*;
            const total = name_len + 1 + varValueLen(val);
            const pair = alloc.allocSentinel(u8, total, 0) catch continue;
            @memcpy(pair[0..name_len], name);
            pair[name_len] = '=';
            writeVarValue(pair[name_len + 1 ..][0 .. total - name_len - 1], val);
            envp.append(alloc, pair) catch continue;
        }
    }

    var it = shell.vars.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!shouldExportVar(name) or seen_exports.contains(name)) continue;
        seen_exports.put(name, {}) catch continue;
        const name_len = name.len;
        const val = entry.value_ptr.*;
        const total = name_len + 1 + varValueLen(val);
        const pair = alloc.allocSentinel(u8, total, 0) catch continue;
        @memcpy(pair[0..name_len], name);
        pair[name_len] = '=';
        writeVarValue(pair[name_len + 1 ..][0 .. total - name_len - 1], val);
        envp.append(alloc, pair) catch continue;
    }

    envp.append(alloc, null) catch {};
    return @ptrCast(envp.items.ptr);
}

fn shouldExportVar(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn varValueLen(value: VarValue) usize {
    return switch (value) {
        .scalar => |text| text.len,
        .argv => |items| blk: {
            var total: usize = 0;
            for (items, 0..) |item, i| {
                if (i > 0) total += 1;
                total += item.len;
            }
            break :blk total;
        },
    };
}

fn writeVarValue(buf: []u8, value: VarValue) void {
    switch (value) {
        .scalar => |text| @memcpy(buf[0..text.len], text),
        .argv => |items| {
            var pos: usize = 0;
            for (items, 0..) |item, i| {
                if (i > 0) {
                    buf[pos] = ' ';
                    pos += 1;
                }
                @memcpy(buf[pos..][0..item.len], item);
                pos += item.len;
            }
        },
    }
}

fn parseFdToken(token: []const u8) ?posix.fd_t {
    if (token.len < 2) return null;
    return std.fmt.parseInt(posix.fd_t, token[0 .. token.len - 1], 10) catch null;
}

fn parseFdDupToken(token: []const u8) ?struct { src_fd: posix.fd_t, dest_fd: posix.fd_t } {
    const sep = std.mem.indexOf(u8, token, ">&") orelse return null;
    const src_fd = std.fmt.parseInt(posix.fd_t, token[0..sep], 10) catch return null;
    const dest_fd = std.fmt.parseInt(posix.fd_t, token[sep + 2 ..], 10) catch return null;
    return .{ .src_fd = src_fd, .dest_fd = dest_fd };
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

var float_buf: [64]u8 = undefined;

fn formatFloat(val: f64) []const u8 {
    if (val == @trunc(val) and @abs(val) < 1e15) {
        return std.fmt.bufPrint(&float_buf, "{d}", .{@as(i64, @intFromFloat(val))}) catch "0";
    }
    const raw = std.fmt.bufPrint(&float_buf, "{d:.10}", .{val}) catch return "0";
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
    var re = if (parsed.ignore_case) Regex.compileIgnoreCase(parsed.pattern) catch {
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

    if (matches.items.len == 0) return;
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
    defer alloc.free(re_pattern);
    var re = Regex.compile(re_pattern) catch {
        out.append(alloc, pattern) catch {};
        return;
    };
    defer re.free();

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
        } else {
            alloc.free(full);
        }
    }

    if (matches.items.len == 0) return;
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

fn ensureTrailingNewlineAlloc(alloc: Allocator, source: []const u8) ![]const u8 {
    if (source.len == 0 or source[source.len - 1] == '\n') return source;
    const buf = try alloc.alloc(u8, source.len + 1);
    @memcpy(buf[0..source.len], source);
    buf[source.len] = '\n';
    return buf;
}

test "job ordering and stop resume bookkeeping" {
    var sh = Shell.init(std.testing.allocator);
    defer sh.deinit();

    const p1 = [_]posix.pid_t{1111};
    const p2 = [_]posix.pid_t{2222};
    const p3 = [_]posix.pid_t{3333};

    const id1 = sh.addJob(1111, .running, "job-one", &p1);
    const id2 = sh.addJob(2222, .running, "job-two", &p2);
    sh.removeJob(id1);
    const id3 = sh.addJob(3333, .running, "job-three", &p3);

    // Reusing a free slot can scramble table order; listing must still be ID-ordered.
    var ordered: [MAX_JOBS]Job = undefined;
    var count = sh.collectJobsOrdered(&ordered);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(id2, ordered[0].id);
    try std.testing.expectEqual(id3, ordered[1].id);

    // Stop then resume the older job and ensure bookkeeping reflects transitions.
    if (sh.findJobById(id2)) |j| j.state = .stopped;
    count = sh.collectJobsOrdered(&ordered);
    try std.testing.expect(ordered[0].state == .stopped);

    if (sh.findJobById(id2)) |j| j.state = .running;
    count = sh.collectJobsOrdered(&ordered);
    try std.testing.expect(ordered[0].state == .running);

    sh.removeJob(id2);
    sh.removeJob(id3);
}

test "reaped stopped job transitions to done" {
    var sh = Shell.init(std.testing.allocator);
    defer sh.deinit();

    const pids = [_]posix.pid_t{4444};
    const job_id = sh.addJob(4444, .running, "job-stopped", &pids);
    const job = sh.findJobById(job_id).?;
    job.state = .stopped;

    sh.markReapedPid(4444, 0);

    try std.testing.expectEqual(@as(u8, 0), job.running_count);
    try std.testing.expect(job.state == .done);
    sh.removeJob(job_id);
}

test "parseRegexSpec rejects unsupported flags" {
    try std.testing.expect(Shell.parseRegexSpec("/abc/i") != null);
    try std.testing.expect(Shell.parseRegexSpec("/abc/m") == null);
    try std.testing.expect(Shell.parseRegexSpec("~|abc|x") == null);
}

test "wait consumes done job status after reap reporting" {
    var sh = Shell.init(std.testing.allocator);
    defer sh.deinit();
    sh.interactive = true;

    const pids = [_]posix.pid_t{7777};
    const job_id = sh.addJob(7777, .done, "done-job", &pids);
    const job = sh.findJobById(job_id).?;
    job.exit_code = 7;

    sh.reapAndReport();
    try std.testing.expect(sh.findJobById(job_id) != null);
    try std.testing.expect(job.reported_done);

    var id_buf: [16]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{job_id});
    const argv = [_][]const u8{ "wait", id_text };
    sh.builtinWait(&argv);
    try std.testing.expectEqual(@as(u8, 7), sh.last_exit);
    try std.testing.expect(sh.findJobById(job_id) == null);
}
