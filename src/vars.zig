//! Variable store — scalar and list-typed shell variables.
//!
//! Variables live in a flat namespace per session. Scalars are single
//! strings; lists are slices of strings. `$name` expansion produces one
//! argv field for scalars and N fields for lists. Quoted expansion
//! preserves field boundaries — there is no implicit word splitting.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
};

pub const Var = struct {
    value: Value,
    /// `true` iff `export NAME` was called (or env-inherited from process
    /// startup). Exported variables propagate to spawned children's env.
    exported: bool,
};

pub const VarStore = struct {
    alloc: Allocator,
    table: std.StringHashMapUnmanaged(Var) = .empty,

    pub fn init(alloc: Allocator) VarStore {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *VarStore) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            switch (e.value_ptr.value) {
                .scalar => |s| self.alloc.free(s),
                .list => |xs| {
                    for (xs) |s| self.alloc.free(s);
                    self.alloc.free(xs);
                },
            }
        }
        self.table.deinit(self.alloc);
    }

    pub fn setScalar(self: *VarStore, name: []const u8, value: []const u8, exported: bool) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        const val = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(val);

        const gop = try self.table.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            switch (gop.value_ptr.value) {
                .scalar => |s| self.alloc.free(s),
                .list => |xs| {
                    for (xs) |s| self.alloc.free(s);
                    self.alloc.free(xs);
                },
            }
            gop.value_ptr.* = .{ .value = .{ .scalar = val }, .exported = exported or gop.value_ptr.exported };
        } else {
            gop.value_ptr.* = .{ .value = .{ .scalar = val }, .exported = exported };
        }
    }

    pub fn setList(self: *VarStore, name: []const u8, items: []const []const u8, exported: bool) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);

        var dup = try self.alloc.alloc([]const u8, items.len);
        errdefer self.alloc.free(dup);
        var i: usize = 0;
        errdefer for (dup[0..i]) |s| self.alloc.free(s);
        while (i < items.len) : (i += 1) dup[i] = try self.alloc.dupe(u8, items[i]);

        const gop = try self.table.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            switch (gop.value_ptr.value) {
                .scalar => |s| self.alloc.free(s),
                .list => |xs| {
                    for (xs) |s| self.alloc.free(s);
                    self.alloc.free(xs);
                },
            }
            gop.value_ptr.* = .{ .value = .{ .list = dup }, .exported = exported or gop.value_ptr.exported };
        } else {
            gop.value_ptr.* = .{ .value = .{ .list = dup }, .exported = exported };
        }
    }

    pub fn get(self: *const VarStore, name: []const u8) ?Var {
        return self.table.get(name);
    }

    pub fn unset(self: *VarStore, name: []const u8) void {
        if (self.table.fetchRemove(name)) |entry| {
            self.alloc.free(entry.key);
            switch (entry.value.value) {
                .scalar => |s| self.alloc.free(s),
                .list => |xs| {
                    for (xs) |s| self.alloc.free(s);
                    self.alloc.free(xs);
                },
            }
        }
    }

    /// Mark a name as exported; do nothing if the name doesn't exist.
    pub fn markExported(self: *VarStore, name: []const u8) void {
        if (self.table.getPtr(name)) |v| v.exported = true;
    }
};

test "VarStore basic" {
    var store = VarStore.init(std.testing.allocator);
    defer store.deinit();
    try store.setScalar("x", "hello", false);
    try std.testing.expectEqualStrings("hello", store.get("x").?.value.scalar);
    try store.setScalar("x", "world", false);
    try std.testing.expectEqualStrings("world", store.get("x").?.value.scalar);
    try store.setList("xs", &.{ "a", "b", "c" }, false);
    const xs = store.get("xs").?.value.list;
    try std.testing.expectEqual(@as(usize, 3), xs.len);
    try std.testing.expectEqualStrings("b", xs[1]);
}
