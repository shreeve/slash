//! History — flat-file command history and directory frecency
//!
//! Stores command history in ~/.slash/history as tab-separated lines:
//!   timestamp\texit_code\tduration_ms\tcwd\tcommand
//!
//! Loaded into memory on open; new entries appended to both the file
//! and the in-memory list. Pruned to 50,000 entries on open.

const std = @import("std");
const posix = std.posix;

const MAX_ENTRIES = 50_000;

const Entry = struct {
    timestamp: i64,
    exit_code: u8,
    duration_ms: u64,
    cwd: []const u8,
    command: []const u8,
};

pub const Db = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry),
    file: ?std.fs.File,
    path: []const u8,

    pub fn open() !*Db {
        const home = posix.getenv("HOME") orelse return error.NoHome;
        const alloc = std.heap.page_allocator;

        var dir_buf: [4096]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.slash", .{home}) catch return error.PathTooLong;
        std.fs.cwd().makePath(dir_path) catch {};

        var path_buf: [4096]u8 = undefined;
        const path_tmp = std.fmt.bufPrint(&path_buf, "{s}/.slash/history", .{home}) catch return error.PathTooLong;
        const path = alloc.dupe(u8, path_tmp) catch return error.OutOfMemory;

        const self = alloc.create(Db) catch return error.OutOfMemory;
        self.* = .{
            .alloc = alloc,
            .entries = .{},
            .file = null,
            .path = path,
        };

        self.load();
        self.prune();

        self.file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch
            std.fs.cwd().createFile(path, .{}) catch null;
        if (self.file) |f| f.seekFromEnd(0) catch {};

        return self;
    }

    pub fn close(self: *Db) void {
        if (self.file) |f| f.close();
        for (self.entries.items) |e| {
            self.alloc.free(e.cwd);
            self.alloc.free(e.command);
        }
        self.entries.deinit(self.alloc);
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }

    pub fn record(self: *Db, command: []const u8, cwd: []const u8, exit_code: u8, duration_ms: u64) void {
        const now = std.time.timestamp();
        if (self.file) |f| {
            var buf: [8192]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d}\t{d}\t{d}\t{s}\t{s}\n", .{
                now, exit_code, duration_ms, cwd, command,
            }) catch return;
            f.writeAll(line) catch {};
        }
        const entry = Entry{
            .timestamp = now,
            .exit_code = exit_code,
            .duration_ms = duration_ms,
            .cwd = self.alloc.dupe(u8, cwd) catch return,
            .command = self.alloc.dupe(u8, command) catch return,
        };
        self.entries.append(self.alloc, entry) catch {};
    }

    pub fn search(self: *const Db, alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 {
        var results: std.ArrayList([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const cmd = self.entries.items[i].command;
            if (query.len > 0 and !containsSubstring(cmd, query)) continue;
            if (seen.contains(cmd)) continue;
            const dupe = alloc.dupe(u8, cmd) catch continue;
            results.append(alloc, dupe) catch {};
            seen.put(dupe, {}) catch {};
            if (results.items.len >= limit) break;
        }
        return results.items;
    }

    pub fn suggest(self: *const Db, _: std.mem.Allocator, prefix: []const u8) ?[]const u8 {
        if (prefix.len < 2) return null;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const cmd = self.entries.items[i].command;
            if (cmd.len > prefix.len and std.mem.startsWith(u8, cmd, prefix))
                return cmd;
        }
        return null;
    }

    pub fn frecency(self: *const Db, alloc: std.mem.Allocator, query: []const u8, limit: usize) []DirScore {
        const now = std.time.timestamp();
        var map = std.StringHashMap(DirAccum).init(alloc);
        defer map.deinit();
        for (self.entries.items) |e| {
            if (e.cwd.len == 0) continue;
            if (query.len > 0 and !containsSubstring(e.cwd, query)) continue;
            if (map.getPtr(e.cwd)) |acc| {
                acc.count += 1;
                if (e.timestamp > acc.max_ts) acc.max_ts = e.timestamp;
            } else {
                map.put(e.cwd, .{ .count = 1, .max_ts = e.timestamp }) catch continue;
            }
        }

        var scored: std.ArrayList(DirScore) = .empty;
        var it = map.iterator();
        while (it.next()) |kv| {
            const age_hours: f64 = @as(f64, @floatFromInt(@max(0, now - kv.value_ptr.max_ts))) / 3600.0;
            const score = @as(f64, @floatFromInt(kv.value_ptr.count)) / (1.0 + age_hours);
            const path = alloc.dupe(u8, kv.key_ptr.*) catch continue;
            scored.append(alloc, .{ .path = path, .score = score }) catch {};
        }
        std.mem.sortUnstable(DirScore, scored.items, {}, struct {
            fn cmp(_: void, a: DirScore, b: DirScore) bool {
                return a.score > b.score;
            }
        }.cmp);

        const n = @min(scored.items.len, limit);
        if (n < scored.items.len) {
            for (scored.items[n..]) |entry| alloc.free(entry.path);
        }
        scored.shrinkRetainingCapacity(n);
        return scored.items;
    }

    fn load(self: *Db) void {
        const file = std.fs.cwd().openFile(self.path, .{}) catch return;
        defer file.close();
        const data = file.readToEndAlloc(self.alloc, 128 * 1024 * 1024) catch return;
        defer self.alloc.free(data);
        var pos: usize = 0;
        while (pos < data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
            const line = data[pos..line_end];
            pos = line_end + 1;
            if (line.len == 0) continue;
            self.parseLine(line) catch continue;
        }
    }

    fn parseLine(self: *Db, line: []const u8) !void {
        var rest = line;
        const ts_str = nextField(&rest) orelse return error.BadLine;
        const exit_str = nextField(&rest) orelse return error.BadLine;
        const dur_str = nextField(&rest) orelse return error.BadLine;
        const cwd_field = nextField(&rest) orelse return error.BadLine;
        const command = rest;
        if (command.len == 0) return error.BadLine;

        self.entries.append(self.alloc, .{
            .timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return error.BadLine,
            .exit_code = std.fmt.parseInt(u8, exit_str, 10) catch 0,
            .duration_ms = std.fmt.parseInt(u64, dur_str, 10) catch 0,
            .cwd = self.alloc.dupe(u8, cwd_field) catch return error.OutOfMemory,
            .command = self.alloc.dupe(u8, command) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }

    fn nextField(rest: *[]const u8) ?[]const u8 {
        const data = rest.*;
        const sep = std.mem.indexOfScalar(u8, data, '\t') orelse return null;
        rest.* = data[sep + 1 ..];
        return data[0..sep];
    }

    fn prune(self: *Db) void {
        if (self.entries.items.len <= MAX_ENTRIES) return;
        const drop = self.entries.items.len - MAX_ENTRIES;
        for (self.entries.items[0..drop]) |e| {
            self.alloc.free(e.cwd);
            self.alloc.free(e.command);
        }
        std.mem.copyForwards(Entry, self.entries.items[0..MAX_ENTRIES], self.entries.items[drop..]);
        self.entries.shrinkRetainingCapacity(MAX_ENTRIES);
        self.rewrite();
    }

    fn rewrite(self: *Db) void {
        const tmp = std.fmt.allocPrint(self.alloc, "{s}.tmp", .{self.path}) catch return;
        defer self.alloc.free(tmp);
        const out = std.fs.cwd().createFile(tmp, .{}) catch return;
        var closed = false;
        defer if (!closed) out.close();
        var buf: [8192]u8 = undefined;
        for (self.entries.items) |e| {
            const line = std.fmt.bufPrint(&buf, "{d}\t{d}\t{d}\t{s}\t{s}\n", .{
                e.timestamp, e.exit_code, e.duration_ms, e.cwd, e.command,
            }) catch continue;
            out.writeAll(line) catch {};
        }
        out.close();
        closed = true;
        std.fs.cwd().rename(tmp, self.path) catch {};
    }
};

const DirAccum = struct { count: u64, max_ts: i64 };

pub const DirScore = struct {
    path: []const u8,
    score: f64,
};

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
