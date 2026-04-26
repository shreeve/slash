//! Slash — Job table, monotonic state graph, wait service.
//!
//! Every evaluation produces exactly one `Job` (PLAN §7 Rule 19 + Rule 32).
//! A zero-child Job — what shell-context builtins use — has
//! `processes.len == 0` and transitions directly `pending → running → done`
//! without any `service` call.
//!
//! `service(session, mode, target)` is the public abstraction over
//! `waitpid` per PLAN §19. The implementation is a blocking
//! `waitpid(-1)` loop in `.foreground` mode and a `WNOHANG` drain in
//! `.poll` mode. Linux `signalfd` / macOS `kqueue` can replace the body
//! without changing callers.

const std = @import("std");
const exec = @import("exec.zig");
const runtime = @import("runtime.zig");
const program = @import("program.zig");

pub const Allocator = std.mem.Allocator;
pub const Pid = exec.Pid;
pub const Result = runtime.Result;
pub const Signal = runtime.Signal;

// =============================================================================
// Process / Job state
// =============================================================================

pub const ProcessState = union(enum) {
    running,
    stopped: Signal,
    done: Result,
};

pub const Process = struct {
    pid: Pid,
    state: ProcessState,
};

pub const JobState = union(enum) {
    pending,
    running,
    stopped: Signal,
    done: Result,
};

pub const Job = struct {
    id: u32,
    pgid: Pid,
    processes: []Process,
    state: JobState,
    result: ?Result,
    foreground: bool,
    detached: bool,
    /// Display string, owned by the JobTable's allocator if non-null.
    command_text: ?[]const u8,
};

// =============================================================================
// JobTable
// =============================================================================

pub const JobTable = struct {
    alloc: Allocator,
    jobs: std.ArrayListUnmanaged(*Job) = .empty,
    next_id: u32 = 1,

    pub fn init(alloc: Allocator) JobTable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *JobTable) void {
        for (self.jobs.items) |j| {
            self.alloc.free(j.processes);
            if (j.command_text) |t| self.alloc.free(t);
            self.alloc.destroy(j);
        }
        self.jobs.deinit(self.alloc);
    }

    /// Allocate a Job in `pending` state and register it for cleanup at
    /// `JobTable.deinit`. All jobs are session-owned for lifetime safety;
    /// user-visible filtering (e.g. a `jobs` listing showing only
    /// background jobs) happens at the consumer, not at registration.
    pub fn create(
        self: *JobTable,
        foreground: bool,
        detached: bool,
        command_text: ?[]const u8,
    ) !*Job {
        const j = try self.alloc.create(Job);
        j.* = .{
            .id = self.next_id,
            .pgid = 0,
            .processes = &.{},
            .state = .pending,
            .result = null,
            .foreground = foreground,
            .detached = detached,
            .command_text = if (command_text) |t| try self.alloc.dupe(u8, t) else null,
        };
        self.next_id += 1;
        try self.jobs.append(self.alloc, j);
        return j;
    }

    /// Install per-process records for a Job that actually forked children.
    /// Transitions state `pending → running`. `pgid` is the leader pid.
    pub fn setProcesses(self: *JobTable, j: *Job, pgid: Pid, pids: []const Pid) !void {
        const procs = try self.alloc.alloc(Process, pids.len);
        for (pids, 0..) |pid, i| procs[i] = .{ .pid = pid, .state = .running };
        j.processes = procs;
        j.pgid = pgid;
        j.state = .running;
    }

    /// Mark a zero-child Job as completed in one step. Used by
    /// shell-context builtins (PLAN §7 Rule 19): no fork, no waitpid,
    /// `processes.len == 0`, and `state` walks `pending → running → done`
    /// monotonically per PLAN §7 Rule 32.
    pub fn completeZeroChild(self: *JobTable, j: *Job, result: Result) void {
        _ = self;
        std.debug.assert(j.processes.len == 0);
        j.state = .running;
        j.result = result;
        j.state = .{ .done = result };
    }

    /// No-op in v0 — `create` already inserts. Kept as the API hook for
    /// when the `jobs` builtin lands and needs explicit registration
    /// timing for detached jobs (e.g. to print the bg job number only
    /// after the leader pid is known).
    pub fn insert(self: *JobTable, j: *Job) !void {
        _ = self;
        _ = j;
    }

    pub fn lookup(self: *const JobTable, id: u32) ?*Job {
        for (self.jobs.items) |j| if (j.id == id) return j;
        return null;
    }

    pub fn list(self: *const JobTable) []const *Job {
        return self.jobs.items;
    }

    fn findProcessOwner(self: *JobTable, pid: Pid) ?struct { job: *Job, idx: usize } {
        for (self.jobs.items) |j| {
            for (j.processes, 0..) |p, i| if (p.pid == pid) return .{ .job = j, .idx = i };
        }
        return null;
    }

    fn applyEvent(self: *JobTable, j: *Job, idx: usize, state: runtime.ChildState) void {
        j.processes[idx].state = switch (state) {
            .exited => |c| .{ .done = .{ .exited = c } },
            .signaled => |s| .{ .done = .{ .signaled = s } },
            .stopped => |s| .{ .stopped = s },
            .continued => .running,
        };
        recomputeJobState(j);
        _ = self;
    }
};

/// Recompute aggregate Job state from per-process state. Pipefail policy
/// per PLAN §20.3 / §7 Rule 11: with `pipefail = on` (the default), the
/// pipeline result is the FIRST non-zero or signaled stage; otherwise the
/// last stage's result. Once `done`, monotonic per Rule 32.
fn recomputeJobState(j: *Job) void {
    if (j.state == .done) return;

    var all_done = true;
    var any_stopped = false;
    var stopped_sig: Signal = .TSTP;
    var first_nonzero: ?Result = null;
    var last_result: Result = .{ .exited = 0 };
    for (j.processes) |p| {
        switch (p.state) {
            .running => all_done = false,
            .stopped => |s| {
                any_stopped = true;
                stopped_sig = s;
                all_done = false;
            },
            .done => |r| {
                last_result = r;
                if (first_nonzero == null and !r.ok()) first_nonzero = r;
            },
        }
    }
    if (!all_done) {
        if (any_stopped) {
            j.state = .{ .stopped = stopped_sig };
        } else {
            j.state = .running;
        }
        return;
    }
    const result = first_nonzero orelse last_result;
    j.result = result;
    j.state = .{ .done = result };
}

// =============================================================================
// Service (wait abstraction) — see PLAN §19
// =============================================================================

pub const WaitMode = enum { poll, foreground };

/// Drain pending child events into the table; in `.foreground` mode block
/// until `target` reaches a terminal-or-stopped state.
pub fn service(table: *JobTable, mode: WaitMode, target: ?*Job) !void {
    switch (mode) {
        .poll => {
            while (true) {
                const ev = try exec.waitOne(.{ .blocking = false }) orelse return;
                if (table.findProcessOwner(ev.pid)) |info| {
                    table.applyEvent(info.job, info.idx, ev.state);
                }
            }
        },
        .foreground => {
            const t = target.?;
            while (true) {
                switch (t.state) {
                    .done => return,
                    .stopped => return,
                    else => {},
                }
                const ev = (try exec.waitOne(.{ .blocking = true })) orelse return;
                if (table.findProcessOwner(ev.pid)) |info| {
                    table.applyEvent(info.job, info.idx, ev.state);
                }
                // If event was for an unrelated job, loop continues; the
                // unrelated job's state is updated as a side effect.
            }
        },
    }
}

test "JobTable zero-child completion is monotonic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = JobTable.init(arena.allocator());
    defer table.deinit();
    const j = try table.create(true, false, "echo");
    try std.testing.expect(j.state == .pending);
    table.completeZeroChild(j, .{ .exited = 0 });
    try std.testing.expect(j.state == .done);
    try std.testing.expectEqual(@as(u8, 0), j.state.done.exited);
}
