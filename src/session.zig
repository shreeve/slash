//! Session — long-lived shell state.

const std = @import("std");
const job = @import("job.zig");
const builtins = @import("builtins.zig");
const runtime = @import("runtime.zig");
const vars = @import("vars.zig");

pub const Allocator = std.mem.Allocator;

pub const Session = struct {
    alloc: Allocator,
    jobs: job.JobTable,
    builtins: builtins.BuiltinSet,
    vars: vars.VarStore,
    /// Inherited environment as a raw `execve`-ready pointer. Threaded
    /// from `std.c.environ` in `main`; not owned by Session.
    envp: [*:null]const ?[*:0]const u8,
    interactive: bool,
    default_pipefail: bool,
    /// Set by builtin `exit`. The `runForeground` caller (typically `main`)
    /// observes this after evaluation completes and may terminate the shell
    /// with the requested result.
    exit_request: ?runtime.Result,
    /// Last command's exit status (for `$?`).
    last_status: u8,

    pub fn init(
        alloc: Allocator,
        envp: [*:null]const ?[*:0]const u8,
        interactive: bool,
    ) !Session {
        return .{
            .alloc = alloc,
            .jobs = job.JobTable.init(alloc),
            .builtins = try builtins.init(alloc),
            .vars = vars.VarStore.init(alloc),
            .envp = envp,
            .interactive = interactive,
            .default_pipefail = true,
            .exit_request = null,
            .last_status = 0,
        };
    }

    pub fn deinit(self: *Session) void {
        self.jobs.deinit();
        self.builtins.deinit(self.alloc);
        self.vars.deinit();
    }

    /// Read a variable as a single string (joining lists with space).
    /// Returns null if undefined.
    pub fn varString(self: *const Session, name: []const u8, alloc: Allocator) !?[]u8 {
        if (self.vars.get(name)) |v| {
            return switch (v.value) {
                .scalar => |s| try alloc.dupe(u8, s),
                .list => |xs| try std.mem.join(alloc, " ", xs),
            };
        }
        return null;
    }
};
