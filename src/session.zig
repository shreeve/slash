//! Session — long-lived shell state.

const std = @import("std");
const job = @import("job.zig");
const builtins = @import("builtins.zig");
const runtime = @import("runtime.zig");
const vars = @import("vars.zig");
const program_mod = @import("program.zig");

pub const Allocator = std.mem.Allocator;

/// Tabulated signals supported by `trap`. The values are sequential
/// (0..N) because the trap table indexes by `@intFromEnum`; the mapping
/// to POSIX signal numbers lives in `builtins.sigToCSig`.
pub const TrapSignal = enum(u8) {
    EXIT, // pseudo-signal: runs at shell exit
    HUP,
    INT,
    QUIT,
    TERM,
    USR1,
    USR2,
};

pub const TrapDispo = union(enum) {
    default,
    ignore,
    run: TrapEntry,

    pub const TrapEntry = struct {
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    };
};

/// Per-session signal trap registry. Each slot holds either the default
/// disposition, an "ignore" marker, or a session-scoped Program parsed
/// from the registered source string. Real signals (everything except
/// EXIT) also have a `pending` flag set by the async-signal-safe handler;
/// the eval layer drains the flag at safe points and runs the trap.
pub const TrapTable = struct {
    alloc: Allocator,
    /// Indexed by the TrapSignal enum value (offset zero is EXIT).
    dispo: [num_slots]TrapDispo,
    /// Set by the signal handler; read at safe points.
    pending: [num_slots]bool,

    pub const num_slots: usize = @typeInfo(TrapSignal).@"enum".fields.len;

    pub fn init(alloc: Allocator) TrapTable {
        var t: TrapTable = .{
            .alloc = alloc,
            .dispo = undefined,
            .pending = [_]bool{false} ** num_slots,
        };
        for (&t.dispo) |*slot| slot.* = .default;
        return t;
    }

    pub fn deinit(self: *TrapTable) void {
        for (&self.dispo) |*slot| switch (slot.*) {
            .run => |*entry| entry.arena.deinit(),
            else => {},
        };
    }

    pub fn parseSignal(name: []const u8) ?TrapSignal {
        if (std.mem.eql(u8, name, "EXIT")) return .EXIT;
        if (std.mem.eql(u8, name, "HUP")) return .HUP;
        if (std.mem.eql(u8, name, "INT")) return .INT;
        if (std.mem.eql(u8, name, "QUIT")) return .QUIT;
        if (std.mem.eql(u8, name, "TERM")) return .TERM;
        if (std.mem.eql(u8, name, "USR1")) return .USR1;
        if (std.mem.eql(u8, name, "USR2")) return .USR2;
        return null;
    }

    pub fn setIgnore(self: *TrapTable, sig: TrapSignal) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .ignore;
    }

    pub fn setDefault(self: *TrapTable, sig: TrapSignal) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .default;
    }

    pub fn setRun(
        self: *TrapTable,
        sig: TrapSignal,
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    ) void {
        self.clearSlot(sig);
        self.dispo[@intFromEnum(sig)] = .{ .run = .{ .arena = arena, .program = program } };
    }

    pub fn lookup(self: *const TrapTable, sig: TrapSignal) TrapDispo {
        return self.dispo[@intFromEnum(sig)];
    }

    pub fn markPending(self: *TrapTable, sig: TrapSignal) void {
        self.pending[@intFromEnum(sig)] = true;
    }

    pub fn takePending(self: *TrapTable, sig: TrapSignal) bool {
        const idx = @intFromEnum(sig);
        const was = self.pending[idx];
        self.pending[idx] = false;
        return was;
    }

    fn clearSlot(self: *TrapTable, sig: TrapSignal) void {
        const idx = @intFromEnum(sig);
        switch (self.dispo[idx]) {
            .run => |*entry| entry.arena.deinit(),
            else => {},
        }
    }
};

/// Store for user-defined `cmd` bodies. Both keys (definition names) and
/// values (lowered Programs) live in the entry's own arena so the
/// definition outlives the originating parse.
pub const DefStore = struct {
    alloc: Allocator,
    table: std.StringHashMapUnmanaged(*Entry) = .empty,

    pub const Entry = struct {
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    };

    pub fn init(alloc: Allocator) DefStore {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DefStore) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            self.alloc.destroy(e.value_ptr.*);
        }
        self.table.deinit(self.alloc);
    }

    pub fn lookup(self: *const DefStore, name: []const u8) ?*const program_mod.Program {
        if (self.table.get(name)) |entry| return entry.program;
        return null;
    }

    /// Install a definition. The caller passes a freshly initialized
    /// arena and the lowered Program allocated from it. Ownership of
    /// the arena transfers to the store; on key replacement the old
    /// entry's arena is destroyed.
    pub fn install(
        self: *DefStore,
        name: []const u8,
        arena: std.heap.ArenaAllocator,
        program: *const program_mod.Program,
    ) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);

        const entry = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{ .arena = arena, .program = program };

        const gop = try self.table.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            gop.value_ptr.*.arena.deinit();
            self.alloc.destroy(gop.value_ptr.*);
        }
        gop.value_ptr.* = entry;
    }
};

pub const Session = struct {
    alloc: Allocator,
    jobs: job.JobTable,
    builtins: builtins.BuiltinSet,
    vars: vars.VarStore,
    defs: DefStore,
    traps: TrapTable,
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
            .defs = DefStore.init(alloc),
            .traps = TrapTable.init(alloc),
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
        self.defs.deinit();
        self.traps.deinit();
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
