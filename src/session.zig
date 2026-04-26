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
    /// PATH lookup memoization. Keys and values are owned by `alloc`.
    /// `path_cache_signature` is a dup'd snapshot of `$PATH` at the time
    /// the cache was last validated; on mismatch the cache is dropped
    /// before any lookup.
    path_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
    path_cache_signature: ?[]const u8 = null,

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
        self.clearPathCache();
        self.path_cache.deinit(self.alloc);
        if (self.path_cache_signature) |sig| self.alloc.free(sig);
    }

    /// Free every cached entry but leave the table allocated.
    pub fn clearPathCache(self: *Session) void {
        var it = self.path_cache.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.path_cache.clearRetainingCapacity();
    }

    /// Drop the cache if `$PATH` has changed since the last validation.
    /// Returns the live `$PATH` slice (or `null` if PATH is unset). The
    /// returned slice is borrowed from the C runtime and is only valid
    /// until the next env mutation.
    pub fn refreshPathSignature(self: *Session) ?[]const u8 {
        const env = std.c.getenv("PATH") orelse {
            if (self.path_cache_signature != null) {
                self.alloc.free(self.path_cache_signature.?);
                self.path_cache_signature = null;
                self.clearPathCache();
            }
            return null;
        };
        const live = std.mem.span(env);
        if (self.path_cache_signature) |sig| {
            if (std.mem.eql(u8, sig, live)) return live;
            self.alloc.free(sig);
            self.path_cache_signature = null;
            self.clearPathCache();
        }
        const dup = self.alloc.dupe(u8, live) catch return live;
        self.path_cache_signature = dup;
        return live;
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
