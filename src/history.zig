//! History — flat-file command history
//!
//! Stores command history in ~/.slash/history as tab-separated lines:
//!   timestamp\texit_code\tduration_ms\tescaped_cwd\tescaped_command
//!
//! Loaded into memory on open; new entries appended to both the file
//! and the in-memory list. Pruned to 50,000 entries on open.

const std = @import("std");
const posix = std.posix;
const c = @cImport(@cInclude("sys/file.h"));

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
    lock_file: ?std.fs.File,
    path: []const u8,
    lock_path: []const u8,

    pub fn open() !*Db {
        return openWith(std.heap.page_allocator);
    }

    pub fn openWith(alloc: std.mem.Allocator) !*Db {
        const home = posix.getenv("HOME") orelse return error.NoHome;

        var dir_buf: [4096]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.slash", .{home}) catch return error.PathTooLong;
        std.fs.cwd().makePath(dir_path) catch {};

        var path_buf: [4096]u8 = undefined;
        const path_tmp = std.fmt.bufPrint(&path_buf, "{s}/.slash/history", .{home}) catch return error.PathTooLong;
        const path = alloc.dupe(u8, path_tmp) catch return error.OutOfMemory;
        errdefer alloc.free(path);
        var lock_path_buf: [4096]u8 = undefined;
        const lock_path_tmp = std.fmt.bufPrint(&lock_path_buf, "{s}/.slash/history.lock", .{home}) catch return error.PathTooLong;
        const lock_path = alloc.dupe(u8, lock_path_tmp) catch return error.OutOfMemory;
        errdefer alloc.free(lock_path);

        const self = alloc.create(Db) catch return error.OutOfMemory;
        self.* = .{
            .alloc = alloc,
            .entries = .{},
            .file = null,
            .lock_file = null,
            .path = path,
            .lock_path = lock_path,
        };

        self.load();
        self.prune();

        self.lock_file = openLockFile(lock_path);
        self.file = openHistoryAppendFile(path);
        if (self.file) |f| {
            posix.fchmod(f.handle, 0o600) catch {};
        }

        return self;
    }

    pub fn close(self: *Db) void {
        if (self.file) |f| f.close();
        if (self.lock_file) |f| f.close();
        for (self.entries.items) |e| {
            self.alloc.free(e.cwd);
            self.alloc.free(e.command);
        }
        self.entries.deinit(self.alloc);
        self.alloc.free(self.path);
        self.alloc.free(self.lock_path);
        self.alloc.destroy(self);
    }

    pub fn record(self: *Db, command: []const u8, cwd: []const u8, exit_code: u8, duration_ms: u64) void {
        if (self.entries.items.len > 0 and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1].command, command))
            return;
        const now = std.time.timestamp();
        const escaped_cwd = escapeFieldAlloc(self.alloc, cwd) catch return;
        defer self.alloc.free(escaped_cwd);
        const escaped_command = escapeFieldAlloc(self.alloc, command) catch return;
        defer self.alloc.free(escaped_command);
        var persisted = true;
        if (self.file) |f| {
            if (!self.lockHistory()) {
                persisted = false;
            } else {
                defer self.unlockHistory();
                const line = std.fmt.allocPrint(self.alloc, "{d}\t{d}\t{d}\t{s}\t{s}\n", .{
                    now, exit_code, duration_ms, escaped_cwd, escaped_command,
                }) catch return;
                defer self.alloc.free(line);
                const written: usize = blk: {
                    break :blk posix.write(f.handle, line) catch {
                        persisted = false;
                        break :blk 0;
                    };
                };
                if (written != line.len) persisted = false;
                if (persisted) {
                    posix.fsync(f.handle) catch {
                        persisted = false;
                    };
                }
            }
            if (!persisted) {
                if (self.lock_file == null)
                    std.debug.print("slash: history: lock unavailable, disabling persistent history for this session\n", .{})
                else
                    std.debug.print("slash: history: append failed, disabling persistent history for this session\n", .{});
                f.close();
                self.file = null;
            }
        }
        const cwd_copy = self.alloc.dupe(u8, cwd) catch return;
        errdefer self.alloc.free(cwd_copy);
        const command_copy = self.alloc.dupe(u8, command) catch return;
        errdefer self.alloc.free(command_copy);
        const entry = Entry{
            .timestamp = now,
            .exit_code = exit_code,
            .duration_ms = duration_ms,
            .cwd = cwd_copy,
            .command = command_copy,
        };
        self.entries.append(self.alloc, entry) catch {};
        if (self.entries.items.len > MAX_ENTRIES + 1024) self.prune();
    }

    fn lockHistory(self: *Db) bool {
        const lock_file = self.lock_file orelse return false;
        return c.flock(lock_file.handle, c.LOCK_EX) == 0;
    }

    fn unlockHistory(self: *Db) void {
        if (self.lock_file) |lock_file| {
            _ = c.flock(lock_file.handle, c.LOCK_UN);
        }
    }

    fn openHistoryAppendFile(path: []const u8) ?std.fs.File {
        const path_z = std.posix.toPosixPath(path) catch return null;
        const fd = posix.openatZ(posix.AT.FDCWD, &path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o600) catch return null;
        return std.fs.File{ .handle = fd };
    }

    fn openLockFile(path: []const u8) ?std.fs.File {
        const path_z = std.posix.toPosixPath(path) catch return null;
        const fd = posix.openatZ(posix.AT.FDCWD, &path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
        }, 0o600) catch return null;
        return std.fs.File{ .handle = fd };
    }

    fn reopenHistoryFile(self: *Db) void {
        if (self.file) |f| f.close();
        self.file = openHistoryAppendFile(self.path);
        if (self.file) |f| {
            posix.fchmod(f.handle, 0o600) catch {};
        } else {
            std.debug.print("slash: history: failed to reopen history file after rewrite\n", .{});
        }
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

        const cwd = unescapeFieldAlloc(self.alloc, cwd_field) catch return error.OutOfMemory;
        errdefer self.alloc.free(cwd);
        const cmd = unescapeFieldAlloc(self.alloc, command) catch return error.OutOfMemory;
        errdefer self.alloc.free(cmd);

        self.entries.append(self.alloc, .{
            .timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return error.BadLine,
            .exit_code = std.fmt.parseInt(u8, exit_str, 10) catch 0,
            .duration_ms = std.fmt.parseInt(u64, dur_str, 10) catch 0,
            .cwd = cwd,
            .command = cmd,
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
        if (!self.lockHistory()) {
            std.debug.print("slash: history: lock acquisition failed for rewrite\n", .{});
            return;
        }
        defer self.unlockHistory();

        const tmp = std.fmt.allocPrint(self.alloc, "{s}.tmp", .{self.path}) catch return;
        defer self.alloc.free(tmp);
        const out = std.fs.cwd().createFile(tmp, .{ .mode = 0o600 }) catch return;
        posix.fchmod(out.handle, 0o600) catch {};
        var closed = false;
        defer if (!closed) out.close();
        var write_ok = true;
        for (self.entries.items) |e| {
            const escaped_cwd = escapeFieldAlloc(self.alloc, e.cwd) catch { write_ok = false; continue; };
            defer self.alloc.free(escaped_cwd);
            const escaped_command = escapeFieldAlloc(self.alloc, e.command) catch { write_ok = false; continue; };
            defer self.alloc.free(escaped_command);
            var prefix_buf: [96]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "{d}\t{d}\t{d}\t", .{
                e.timestamp, e.exit_code, e.duration_ms,
            }) catch { write_ok = false; continue; };
            out.writeAll(prefix) catch { write_ok = false; };
            out.writeAll(escaped_cwd) catch { write_ok = false; };
            out.writeAll("\t") catch { write_ok = false; };
            out.writeAll(escaped_command) catch { write_ok = false; };
            out.writeAll("\n") catch { write_ok = false; };
        }
        if (write_ok) {
            posix.fsync(out.handle) catch {
                write_ok = false;
            };
        }
        out.close();
        closed = true;
        if (write_ok) {
            std.fs.cwd().rename(tmp, self.path) catch {
                std.debug.print("slash: history: failed to replace history file\n", .{});
                return;
            };
            syncParentDir(self.path);
            self.reopenHistoryFile();
        } else {
            std.fs.cwd().deleteFile(tmp) catch {
                std.debug.print("slash: history: failed to clean temporary history file\n", .{});
            };
        }
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
            results.append(alloc, dupe) catch {
                alloc.free(dupe);
                continue;
            };
            seen.put(dupe, {}) catch {};
            if (results.items.len >= limit) break;
        }
        return results.toOwnedSlice(alloc) catch &.{};
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

};

fn syncParentDir(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse ".";
    if (std.fs.path.isAbsolute(parent)) {
        var dir = std.fs.openDirAbsolute(parent, .{}) catch return;
        defer dir.close();
        posix.fsync(dir.fd) catch {};
    } else {
        var dir = std.fs.cwd().openDir(parent, .{}) catch return;
        defer dir.close();
        posix.fsync(dir.fd) catch {};
    }
}

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn escapeFieldAlloc(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (value) |ch| {
        switch (ch) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, ch),
        }
    }
    return try buf.toOwnedSlice(alloc);
}

fn unescapeFieldAlloc(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\' and i + 1 < value.len) {
            i += 1;
            switch (value[i]) {
                'n' => try buf.append(alloc, '\n'),
                'r' => try buf.append(alloc, '\r'),
                't' => try buf.append(alloc, '\t'),
                '\\' => try buf.append(alloc, '\\'),
                else => {
                    try buf.append(alloc, '\\');
                    try buf.append(alloc, value[i]);
                },
            }
        } else {
            try buf.append(alloc, value[i]);
        }
    }
    return try buf.toOwnedSlice(alloc);
}

test "record keeps in-memory history when persistence write fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("history.tsv", .{ .truncate = true });
        f.close();
    }
    const read_only = try tmp.dir.openFile("history.tsv", .{ .mode = .read_only });

    var db = Db{
        .alloc = std.testing.allocator,
        .entries = .{},
        .file = read_only,
        .lock_file = null,
        .path = try std.testing.allocator.dupe(u8, "/tmp/.slash-history-test"),
        .lock_path = try std.testing.allocator.dupe(u8, "/tmp/.slash-history-test.lock"),
    };
    defer {
        if (db.file) |f| f.close();
        if (db.lock_file) |f| f.close();
        for (db.entries.items) |e| {
            std.testing.allocator.free(e.cwd);
            std.testing.allocator.free(e.command);
        }
        db.entries.deinit(std.testing.allocator);
        std.testing.allocator.free(db.path);
        std.testing.allocator.free(db.lock_path);
    }

    db.record("echo hi", "/tmp", 0, 1);
    try std.testing.expect(db.file == null);
    try std.testing.expectEqual(@as(usize, 1), db.entries.items.len);
    try std.testing.expectEqualStrings("echo hi", db.entries.items[0].command);
}
