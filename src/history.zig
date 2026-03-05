//! History — SQLite-backed command history and directory frecency
//!
//! Stores command history in ~/.slash/history.db with:
//!   command, cwd, timestamp, exit_code, duration_ms
//!
//! Note: SQLITE_STATIC is used for bind_text because all bound strings
//! remain valid through sqlite3_step. SQLITE_TRANSIENT would be safer but
//! Zig's type system prevents casting the C macro ((destructor_type)-1).

const std = @import("std");
const posix = std.posix;
const c = @cImport(@cInclude("sqlite3.h"));

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open() !Db {
        const home = posix.getenv("HOME") orelse return error.NoHome;
        var path_buf: [4096]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/.slash", .{home}) catch return error.PathTooLong;
        std.fs.cwd().makePath(dir_path) catch {};

        var db_path_buf: [4096]u8 = undefined;
        const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/.slash/history.db\x00", .{home}) catch return error.PathTooLong;

        var db_handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(@ptrCast(db_path.ptr), &db_handle) != c.SQLITE_OK) return error.OpenFailed;

        const self = Db{ .handle = db_handle.? };
        self.exec("PRAGMA journal_mode=WAL");
        self.exec(
            \\CREATE TABLE IF NOT EXISTS history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  command TEXT NOT NULL,
            \\  cwd TEXT,
            \\  timestamp INTEGER DEFAULT (strftime('%s','now')),
            \\  exit_code INTEGER DEFAULT 0,
            \\  duration_ms INTEGER DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_history_ts ON history(timestamp DESC);
            \\CREATE INDEX IF NOT EXISTS idx_history_cwd ON history(cwd);
        );
        self.prune();
        return self;
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn record(self: Db, command: []const u8, cwd: []const u8, exit_code: u8, duration_ms: u64) void {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO history (command, cwd, exit_code, duration_ms) VALUES (?, ?, ?, ?)";
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, @ptrCast(command.ptr), @intCast(command.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, @ptrCast(cwd.ptr), @intCast(cwd.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 3, exit_code);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(duration_ms));
        _ = c.sqlite3_step(stmt);
    }

    pub fn search(self: Db, alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 {
        var results: std.ArrayList([]const u8) = .empty;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = if (query.len > 0)
            "SELECT DISTINCT command FROM history WHERE command LIKE ? ORDER BY timestamp DESC LIMIT ?"
        else
            "SELECT DISTINCT command FROM history ORDER BY timestamp DESC LIMIT ?";

        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return results.items;
        defer _ = c.sqlite3_finalize(stmt);

        if (query.len > 0) {
            const pattern = std.fmt.allocPrint(alloc, "%{s}%", .{query}) catch return results.items;
            _ = c.sqlite3_bind_text(stmt, 1, @ptrCast(pattern.ptr), @intCast(pattern.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int(stmt, 2, @intCast(limit));
        } else {
            _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (text_ptr) |p| {
                const s: [*]const u8 = @ptrCast(p);
                const dupe = alloc.dupe(u8, s[0..text_len]) catch continue;
                results.append(alloc, dupe) catch {};
            }
        }
        return results.items;
    }

    pub fn recentDirs(self: Db, alloc: std.mem.Allocator, limit: usize) [][]const u8 {
        var results: std.ArrayList([]const u8) = .empty;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT cwd FROM history WHERE cwd != '' GROUP BY cwd ORDER BY MAX(timestamp) DESC LIMIT ?";
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return results.items;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (text_ptr) |p| {
                const s: [*]const u8 = @ptrCast(p);
                results.append(alloc, alloc.dupe(u8, s[0..text_len]) catch continue) catch {};
            }
        }
        return results.items;
    }

    pub fn suggest(self: Db, alloc: std.mem.Allocator, prefix: []const u8) ?[]const u8 {
        if (prefix.len < 2) return null;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT command FROM history WHERE command LIKE ? AND command != ? ORDER BY timestamp DESC LIMIT 1";
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        const pattern = std.fmt.allocPrint(alloc, "{s}%", .{prefix}) catch return null;
        _ = c.sqlite3_bind_text(stmt, 1, @ptrCast(pattern.ptr), @intCast(pattern.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, @ptrCast(prefix.ptr), @intCast(prefix.len), c.SQLITE_STATIC);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (text_ptr) |p| {
                const s: [*]const u8 = @ptrCast(p);
                return alloc.dupe(u8, s[0..text_len]) catch null;
            }
        }
        return null;
    }

    pub fn frecency(self: Db, alloc: std.mem.Allocator, query: []const u8, limit: usize) []DirScore {
        var results: std.ArrayList(DirScore) = .empty;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = if (query.len > 0)
            \\SELECT cwd,
            \\  COUNT(*) * 1.0 / (1 + (strftime('%s','now') - MAX(timestamp)) / 3600.0) as score
            \\FROM history WHERE cwd LIKE ? AND cwd != ''
            \\GROUP BY cwd ORDER BY score DESC LIMIT ?
        else
            \\SELECT cwd,
            \\  COUNT(*) * 1.0 / (1 + (strftime('%s','now') - MAX(timestamp)) / 3600.0) as score
            \\FROM history WHERE cwd != ''
            \\GROUP BY cwd ORDER BY score DESC LIMIT ?
        ;

        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return results.items;
        defer _ = c.sqlite3_finalize(stmt);

        if (query.len > 0) {
            const pattern = std.fmt.allocPrint(alloc, "%{s}%", .{query}) catch return results.items;
            _ = c.sqlite3_bind_text(stmt, 1, @ptrCast(pattern.ptr), @intCast(pattern.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int(stmt, 2, @intCast(limit));
        } else {
            _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const score = c.sqlite3_column_double(stmt, 1);
            if (text_ptr) |p| {
                const s: [*]const u8 = @ptrCast(p);
                const path = alloc.dupe(u8, s[0..text_len]) catch continue;
                results.append(alloc, .{ .path = path, .score = score }) catch {};
            }
        }
        return results.items;
    }

    fn prune(self: Db) void {
        // Cap history at 50,000 entries
        self.exec("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY timestamp DESC LIMIT 50000)");
        // Remove entries with directories that no longer exist (check top 500 distinct dirs)
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT cwd FROM history WHERE cwd != '' GROUP BY cwd ORDER BY MAX(id) DESC LIMIT 500";
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        var dead_buf: [32][512]u8 = undefined;
        var dead_count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and dead_count < 32) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (text_ptr) |p| {
                const s: [*]const u8 = @ptrCast(p);
                const path = s[0..text_len];
                std.fs.cwd().access(path, .{}) catch {
                    if (text_len < 512) {
                        @memcpy(dead_buf[dead_count][0..text_len], path);
                        dead_buf[dead_count][text_len] = 0;
                        dead_count += 1;
                    }
                    continue;
                };
            }
        }
        for (dead_buf[0..dead_count]) |*buf| {
            var del_stmt: ?*c.sqlite3_stmt = null;
            const del_sql = "DELETE FROM history WHERE cwd = ?";
            if (c.sqlite3_prepare_v2(self.handle, del_sql, -1, &del_stmt, null) != c.SQLITE_OK) continue;
            const end = std.mem.indexOfScalar(u8, buf, 0) orelse continue;
            _ = c.sqlite3_bind_text(del_stmt, 1, @ptrCast(buf), @intCast(end), c.SQLITE_STATIC);
            _ = c.sqlite3_step(del_stmt);
            _ = c.sqlite3_finalize(del_stmt);
        }
    }

    fn exec(self: Db, sql: [*:0]const u8) void {
        _ = c.sqlite3_exec(self.handle, sql, null, null, null);
    }
};

pub const DirScore = struct {
    path: []const u8,
    score: f64,
};
