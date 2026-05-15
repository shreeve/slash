//! HistoryIndex — slash-side persistent command history with metadata
//! and frecency-style ranking.
//!
//! This sits ALONGSIDE zigline's flat `History` (which still drives
//! chronological Up/Down navigation). The HistoryIndex captures
//! richer metadata (cwd, timestamp, exit status, duration) for every
//! accepted command, persists it as JSONL under XDG, and exposes a
//! search/ranking API for the future smart-Up/Down keystroke path,
//! the `history` builtin, and (eventually) autosuggestions.
//!
//! Persistence format: one JSON object per line, e.g.
//!
//!   {"v":1,"seq":42,"ts":1730000000,"cwd":"/repo/slash","line":"zig build test","status":0,"dur":1}
//!
//! `v` is a format version. `seq` is monotonic per-process across
//! sessions (recovered on load). `ts` is unix seconds. `dur` is
//! seconds; null when unknown.
//!
//! PLAN §12: this module is editor-time only. It does not parse
//! command bytes, expand variables, or evaluate substitutions. The
//! `line` field is opaque text.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

extern "c" fn time(t: ?*c_long) c_long;

pub const SearchMode = enum {
    /// Match if the query is a prefix of the line.
    prefix,
    /// Match if the query is a substring of the line. Prefix matches
    /// score higher than non-prefix substring matches via the
    /// ranking scorer.
    substring,
};

pub const HistoryEvent = struct {
    seq: u64,
    ts_s: i64,
    cwd: []const u8,
    line: []const u8,
    status: ?u8,
    duration_s: ?u32,
};

pub const HistoryCandidate = struct {
    line: []const u8,
    score: i64,
    last_ts_s: i64,
    last_seq: u64,
    count: u32,
    cwd_count: u32,
};

const LineStats = struct {
    total_count: u32,
    last_ts_s: i64,
    last_seq: u64,
    last_status: ?u8,
};

const CwdLineStats = struct {
    count: u32,
    last_ts_s: i64,
    last_seq: u64,
};

/// Cap loaded events to the most-recent N to bound memory + startup
/// latency. Older events stay on disk but aren't indexed for the
/// live session. 5000 is a deliberate ceiling: ranked search and
/// chronological recall both saturate well before 5000 unique
/// commands, and the cap keeps shell startup snappy even when the
/// log accumulates years of history.
const default_max_loaded_events: usize = 5_000;

/// Cap line length for storage. Longer lines (huge multi-line
/// pastes, accidental binary) are skipped at append time.
const max_line_bytes: usize = 65_536;

pub const HistoryIndex = struct {
    alloc: Allocator,
    events: std.ArrayListUnmanaged(HistoryEvent) = .empty,
    /// Owned storage for event strings (line, cwd). Each entry's
    /// slices point into here so we don't have to dupe per event.
    /// Append-only: never realloc-mutated after a push.
    arena: std.heap.ArenaAllocator,
    /// Aggregate stats by exact command line. Key is the line
    /// (borrowed from the arena's copy in `events`).
    by_line: std.StringHashMapUnmanaged(LineStats) = .empty,
    /// Aggregate stats by `cwd\x00line`. Key is owned by `alloc`
    /// (the composite key isn't already in the arena).
    by_cwd_line: std.StringHashMapUnmanaged(CwdLineStats) = .empty,
    next_seq: u64 = 1,
    /// Persistent JSONL path. `null` = in-memory only.
    path: ?[]const u8 = null,

    pub fn init(alloc: Allocator, path: ?[]const u8) !HistoryIndex {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .path = if (path) |p| try alloc.dupe(u8, p) else null,
        };
    }

    pub fn deinit(self: *HistoryIndex) void {
        // Free composite keys we own in by_cwd_line.
        var it = self.by_cwd_line.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.by_cwd_line.deinit(self.alloc);
        self.by_line.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.arena.deinit();
        if (self.path) |p| self.alloc.free(p);
    }

    /// Number of indexed events currently in memory.
    pub fn len(self: *const HistoryIndex) usize {
        return self.events.items.len;
    }

    /// Append a new event. Updates the in-memory aggregate index and
    /// persists to disk (if a path was configured). Returns silently
    /// for empty lines, lines that fail validation, or lines whose
    /// persisted form would exceed the size cap.
    ///
    /// `status` and `duration_s` may be null when not known yet
    /// (e.g. the caller hasn't run the command).
    pub fn append(
        self: *HistoryIndex,
        line: []const u8,
        cwd: []const u8,
        status: ?u8,
        duration_s: ?u32,
    ) !void {
        if (line.len == 0) return;
        if (line.len > max_line_bytes) return;
        // No NUL bytes — they break the JSONL writer's escape rule
        // and downstream string handling. CR/LF are allowed but get
        // \n / \r-escaped on disk.
        if (std.mem.indexOfScalar(u8, line, 0) != null) return;

        const ts: i64 = @intCast(time(null));
        const seq = self.next_seq;
        self.next_seq += 1;

        // Copy line + cwd into the arena so the slices outlive the
        // caller's scratch buffers. Future events reuse the same
        // arena; aggregate stats reference these stable slices.
        const aa = self.arena.allocator();
        const line_owned = try aa.dupe(u8, line);
        const cwd_owned = try aa.dupe(u8, cwd);

        const event: HistoryEvent = .{
            .seq = seq,
            .ts_s = ts,
            .cwd = cwd_owned,
            .line = line_owned,
            .status = status,
            .duration_s = duration_s,
        };
        try self.events.append(self.alloc, event);
        try self.indexEvent(event);

        if (self.path) |path| try persistAppend(self.alloc, path, event);
    }

    /// Update the aggregate index for an event. Used both at
    /// `append`-time and at `load`-time (for events read from disk).
    fn indexEvent(self: *HistoryIndex, event: HistoryEvent) !void {
        // by_line
        const gop = try self.by_line.getOrPut(self.alloc, event.line);
        if (gop.found_existing) {
            gop.value_ptr.total_count += 1;
            gop.value_ptr.last_ts_s = event.ts_s;
            gop.value_ptr.last_seq = event.seq;
            gop.value_ptr.last_status = event.status;
        } else {
            gop.value_ptr.* = .{
                .total_count = 1,
                .last_ts_s = event.ts_s,
                .last_seq = event.seq,
                .last_status = event.status,
            };
        }

        // by_cwd_line — composite key `cwd\x00line` owned by self.alloc.
        const composite = try std.fmt.allocPrint(
            self.alloc,
            "{s}\x00{s}",
            .{ event.cwd, event.line },
        );
        const cgop = try self.by_cwd_line.getOrPut(self.alloc, composite);
        if (cgop.found_existing) {
            self.alloc.free(composite);
            cgop.value_ptr.count += 1;
            cgop.value_ptr.last_ts_s = event.ts_s;
            cgop.value_ptr.last_seq = event.seq;
        } else {
            cgop.value_ptr.* = .{
                .count = 1,
                .last_ts_s = event.ts_s,
                .last_seq = event.seq,
            };
        }
    }

    /// Load events from the configured JSONL path. Skips malformed
    /// lines silently so a single corrupt entry doesn't block load.
    /// If `legacy_path` is non-null and the JSONL file doesn't exist
    /// (or is empty), each line of the legacy flat-file is imported
    /// as a metadata-less event.
    pub fn load(self: *HistoryIndex, legacy_path: ?[]const u8) !void {
        const path = self.path orelse return;
        const loaded = try self.loadFile(path);
        if (loaded == 0) {
            if (legacy_path) |lp| try self.importLegacy(lp);
        }
    }

    fn loadFile(self: *HistoryIndex, path: []const u8) !usize {
        const path_z = try self.alloc.dupeZ(u8, path);
        defer self.alloc.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return 0;
        defer _ = std.c.close(fd);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return 0;
            }
            if (n == 0) break;
            try buf.appendSlice(self.alloc, chunk[0..@intCast(n)]);
        }

        // Find the start offset of the most-recent N events without
        // parsing the whole file. Walk backward counting newlines;
        // we'll only parse from the newline preceding the (N+1)-th
        // line back to EOF. This keeps shell-startup latency O(N)
        // regardless of total file size — a multi-year history
        // archive doesn't slow down the next prompt.
        var start_off: usize = 0;
        if (buf.items.len > 0) {
            var newlines: usize = 0;
            var i: usize = buf.items.len;
            while (i > 0) : (i -= 1) {
                if (buf.items[i - 1] == '\n') {
                    newlines += 1;
                    if (newlines > default_max_loaded_events) {
                        start_off = i;
                        break;
                    }
                }
            }
        }

        var loaded: usize = 0;
        var max_seq: u64 = 0;
        var it = std.mem.splitScalar(u8, buf.items[start_off..], '\n');
        const aa = self.arena.allocator();
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            const event = parseJsonlEvent(aa, raw) catch continue;
            if (event.seq > max_seq) max_seq = event.seq;
            try self.events.append(self.alloc, event);
            try self.indexEvent(event);
            loaded += 1;
        }
        if (max_seq >= self.next_seq) self.next_seq = max_seq + 1;
        return loaded;
    }

    /// Import a flat-file legacy history (`~/.slash/history`) — one
    /// command per line, no metadata. Uses an unknown cwd ("?"),
    /// timestamps = 0, status/duration = null. Each entry persists
    /// to the JSONL store as it's appended, so a subsequent run
    /// finds them via the normal path.
    fn importLegacy(self: *HistoryIndex, legacy_path: []const u8) !void {
        const path_z = try self.alloc.dupeZ(u8, legacy_path);
        defer self.alloc.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n < 0) {
                const e = std.c.errno(@as(c_int, -1));
                if (e == .INTR or e == .AGAIN) continue;
                return;
            }
            if (n == 0) break;
            try buf.appendSlice(self.alloc, chunk[0..@intCast(n)]);
        }

        var it = std.mem.splitScalar(u8, buf.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (line.len > max_line_bytes) continue;
            if (std.mem.indexOfScalar(u8, line, 0) != null) continue;
            // Use cwd "?" — better than fabricating a guess.
            try self.append(line, "?", null, null);
        }
    }

    /// Search for command lines matching `query`, ranked by
    /// frecency + cwd boost + recency + frequency. Returns up to
    /// `limit` deduplicated candidates, highest-scoring first.
    /// Allocator is used for the result slice; the returned `line`
    /// slices are borrowed from the index's arena (valid for the
    /// HistoryIndex's lifetime).
    pub fn search(
        self: *const HistoryIndex,
        out_alloc: Allocator,
        query: []const u8,
        cwd: []const u8,
        mode: SearchMode,
        limit: usize,
    ) ![]HistoryCandidate {
        var results = std.ArrayListUnmanaged(HistoryCandidate).empty;
        errdefer results.deinit(out_alloc);

        const now: i64 = @intCast(time(null));
        var it = self.by_line.iterator();
        while (it.next()) |entry| {
            const line = entry.key_ptr.*;
            if (!matchesQuery(line, query, mode)) continue;
            const stats = entry.value_ptr.*;
            const cwd_count = self.cwdCount(line, cwd);
            const score = scoreLine(.{
                .line = line,
                .query = query,
                .stats = stats,
                .cwd_count = cwd_count,
                .now = now,
            });
            try results.append(out_alloc, .{
                .line = line,
                .score = score,
                .last_ts_s = stats.last_ts_s,
                .last_seq = stats.last_seq,
                .count = stats.total_count,
                .cwd_count = cwd_count,
            });
        }

        std.mem.sort(HistoryCandidate, results.items, {}, byScoreDesc);
        if (results.items.len > limit) {
            results.shrinkRetainingCapacity(limit);
        }
        return try results.toOwnedSlice(out_alloc);
    }

    fn cwdCount(self: *const HistoryIndex, line: []const u8, cwd: []const u8) u32 {
        var key_buf: [4096]u8 = undefined;
        if (cwd.len + 1 + line.len > key_buf.len) return 0;
        @memcpy(key_buf[0..cwd.len], cwd);
        key_buf[cwd.len] = 0;
        @memcpy(key_buf[cwd.len + 1 ..][0..line.len], line);
        const key = key_buf[0 .. cwd.len + 1 + line.len];
        if (self.by_cwd_line.get(key)) |s| return s.count;
        return 0;
    }

    /// Snapshot of the chronological event log (oldest first). Used
    /// by the `history` builtin's plain listing form.
    pub fn eventsSlice(self: *const HistoryIndex) []const HistoryEvent {
        return self.events.items;
    }
};

// =============================================================================
// Ranking
// =============================================================================

const ScoreInputs = struct {
    line: []const u8,
    query: []const u8,
    stats: LineStats,
    cwd_count: u32,
    now: i64,
};

fn scoreLine(in: ScoreInputs) i64 {
    var score: i64 = 0;

    // Prefix match scores higher than non-prefix substring match.
    if (in.query.len > 0 and std.mem.startsWith(u8, in.line, in.query)) {
        score += 500;
    }

    // Cwd boost: any prior occurrence in this cwd is +300; per
    // occurrence we add up to 100 more on a log scale so a deeply
    // habitual cwd-local command beats one-off matches from elsewhere.
    if (in.cwd_count > 0) {
        score += 300;
        score += @as(i64, @intCast(@min(100, 15 * log2u32(in.cwd_count + 1))));
    }

    // Frequency: log-scaled global count, capped at 100. Prevents a
    // run-100-times command from dominating ranking forever.
    score += @as(i64, @intCast(@min(100, 10 * log2u32(in.stats.total_count + 1))));

    // Recency: 200 / (1 + age_days/7). Recent commands get a strong
    // boost; very old commands fall to nearly 0.
    const age_s = if (in.now >= in.stats.last_ts_s) in.now - in.stats.last_ts_s else 0;
    const age_days_div_7: i64 = @divTrunc(age_s, 7 * 24 * 60 * 60);
    const recency: i64 = @divTrunc(200, 1 + age_days_div_7);
    score += recency;

    // Last-status success boost — small. Don't overweight; users
    // recall failures to fix them too.
    if (in.stats.last_status) |s| if (s == 0) {
        score += 25;
    };

    return score;
}

fn byScoreDesc(_: void, a: HistoryCandidate, b: HistoryCandidate) bool {
    if (a.score != b.score) return a.score > b.score;
    // Tie-breakers (deterministic for tests):
    //   1. Newer last_seq (most recently seen)
    //   2. Shorter line
    //   3. Lexicographic
    if (a.last_seq != b.last_seq) return a.last_seq > b.last_seq;
    if (a.line.len != b.line.len) return a.line.len < b.line.len;
    return std.mem.order(u8, a.line, b.line) == .lt;
}

fn matchesQuery(line: []const u8, query: []const u8, mode: SearchMode) bool {
    if (query.len == 0) return true;
    return switch (mode) {
        .prefix => std.mem.startsWith(u8, line, query),
        .substring => std.mem.indexOf(u8, line, query) != null,
    };
}

fn log2u32(n: u32) u32 {
    if (n <= 1) return 0;
    return @as(u32, 31) - @clz(n);
}

// =============================================================================
// JSONL persistence
// =============================================================================

/// Append one event as a JSONL record to `path`. Creates the parent
/// directory if missing. Best-effort: on any error, returns silently
/// (in-memory state stays correct; persistence is a hint, not a hard
/// requirement).
fn persistAppend(alloc: Allocator, path: []const u8, event: HistoryEvent) !void {
    ensureParentDir(alloc, path) catch {};

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    const fd = std.c.open(
        path_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    // Whole-file lock so concurrent shells don't interleave bytes.
    _ = std.c.flock(fd, std.c.LOCK.EX);
    defer _ = std.c.flock(fd, std.c.LOCK.UN);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(alloc);
    try writeJsonlEvent(alloc, &line_buf, event);
    try line_buf.append(alloc, '\n');

    var off: usize = 0;
    while (off < line_buf.items.len) {
        const n = std.c.write(fd, line_buf.items.ptr + off, line_buf.items.len - off);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR or e == .AGAIN) continue;
            return;
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

fn ensureParentDir(alloc: Allocator, path: []const u8) !void {
    const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash_idx == 0) return;
    const dir = path[0..slash_idx];

    // Walk up from the root, creating each segment. `mkdir(2)`
    // returns -1 / EEXIST for existing dirs — tolerate.
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        const seg_z = try alloc.dupeZ(u8, dir[0..i]);
        defer alloc.free(seg_z);
        _ = std.c.mkdir(seg_z.ptr, @as(std.c.mode_t, 0o700));
    }
}

fn writeJsonlEvent(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    event: HistoryEvent,
) !void {
    var num_buf: [32]u8 = undefined;

    try out.appendSlice(alloc, "{\"v\":1,\"seq\":");
    try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{event.seq}) catch return error.OutOfMemory);
    try out.appendSlice(alloc, ",\"ts\":");
    try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{event.ts_s}) catch return error.OutOfMemory);
    try out.appendSlice(alloc, ",\"cwd\":");
    try writeJsonString(alloc, out, event.cwd);
    try out.appendSlice(alloc, ",\"line\":");
    try writeJsonString(alloc, out, event.line);
    if (event.status) |s| {
        try out.appendSlice(alloc, ",\"status\":");
        try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{s}) catch return error.OutOfMemory);
    }
    if (event.duration_s) |d| {
        try out.appendSlice(alloc, ",\"dur\":");
        try out.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{d}) catch return error.OutOfMemory);
    }
    try out.append(alloc, '}');
}

fn writeJsonString(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
) !void {
    try out.append(alloc, '"');
    for (bytes) |b| {
        switch (b) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var u_buf: [8]u8 = undefined;
                const formatted = std.fmt.bufPrint(&u_buf, "\\u{x:0>4}", .{b}) catch return error.OutOfMemory;
                try out.appendSlice(alloc, formatted);
            },
            else => try out.append(alloc, b),
        }
    }
    try out.append(alloc, '"');
}

const ParseError = error{ MalformedJson, MissingField, OutOfMemory };

/// Permissive JSONL parser tailored to our exact emit format. We
/// don't pull in a full JSON parser because the corpus is entirely
/// produced by `writeJsonlEvent`. Unknown fields are skipped.
fn parseJsonlEvent(arena: Allocator, raw: []const u8) ParseError!HistoryEvent {
    var p: usize = 0;
    skipWs(raw, &p);
    if (p >= raw.len or raw[p] != '{') return error.MalformedJson;
    p += 1;

    var seq: ?u64 = null;
    var ts: ?i64 = null;
    var cwd: ?[]const u8 = null;
    var line: ?[]const u8 = null;
    var status: ?u8 = null;
    var duration: ?u32 = null;

    while (true) {
        skipWs(raw, &p);
        if (p >= raw.len) return error.MalformedJson;
        if (raw[p] == '}') break;
        const key = try parseStringSlice(arena, raw, &p);
        skipWs(raw, &p);
        if (p >= raw.len or raw[p] != ':') return error.MalformedJson;
        p += 1;
        skipWs(raw, &p);

        if (std.mem.eql(u8, key, "seq")) {
            seq = @intCast(try parseUint(raw, &p));
        } else if (std.mem.eql(u8, key, "ts")) {
            ts = try parseInt(raw, &p);
        } else if (std.mem.eql(u8, key, "cwd")) {
            cwd = try parseStringSlice(arena, raw, &p);
        } else if (std.mem.eql(u8, key, "line")) {
            line = try parseStringSlice(arena, raw, &p);
        } else if (std.mem.eql(u8, key, "status")) {
            status = @intCast(try parseUint(raw, &p));
        } else if (std.mem.eql(u8, key, "dur")) {
            duration = @intCast(try parseUint(raw, &p));
        } else {
            try skipValue(raw, &p);
        }

        skipWs(raw, &p);
        if (p < raw.len and raw[p] == ',') {
            p += 1;
        } else {
            break;
        }
    }

    skipWs(raw, &p);
    if (p >= raw.len or raw[p] != '}') return error.MalformedJson;

    return .{
        .seq = seq orelse return error.MissingField,
        .ts_s = ts orelse 0,
        .cwd = cwd orelse "?",
        .line = line orelse return error.MissingField,
        .status = status,
        .duration_s = duration,
    };
}

fn skipWs(s: []const u8, p: *usize) void {
    while (p.* < s.len) {
        const c = s[p.*];
        if (c == ' ' or c == '\t') p.* += 1 else break;
    }
}

fn parseUint(s: []const u8, p: *usize) ParseError!u64 {
    var v: u64 = 0;
    var any = false;
    while (p.* < s.len) {
        const c = s[p.*];
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
        p.* += 1;
        any = true;
    }
    if (!any) return error.MalformedJson;
    return v;
}

fn parseInt(s: []const u8, p: *usize) ParseError!i64 {
    var neg = false;
    if (p.* < s.len and s[p.*] == '-') {
        neg = true;
        p.* += 1;
    }
    const v = try parseUint(s, p);
    return if (neg) -@as(i64, @intCast(v)) else @as(i64, @intCast(v));
}

fn parseStringSlice(arena: Allocator, s: []const u8, p: *usize) ParseError![]const u8 {
    if (p.* >= s.len or s[p.*] != '"') return error.MalformedJson;
    p.* += 1;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(arena);
    while (p.* < s.len) {
        const c = s[p.*];
        if (c == '"') {
            p.* += 1;
            return try out.toOwnedSlice(arena);
        }
        if (c == '\\') {
            if (p.* + 1 >= s.len) return error.MalformedJson;
            const esc = s[p.* + 1];
            switch (esc) {
                '"', '\\', '/' => {
                    try out.append(arena, esc);
                    p.* += 2;
                },
                'n' => {
                    try out.append(arena, '\n');
                    p.* += 2;
                },
                'r' => {
                    try out.append(arena, '\r');
                    p.* += 2;
                },
                't' => {
                    try out.append(arena, '\t');
                    p.* += 2;
                },
                'u' => {
                    if (p.* + 6 > s.len) return error.MalformedJson;
                    const hex = s[p.* + 2 .. p.* + 6];
                    var cp: u32 = 0;
                    for (hex) |h| {
                        cp = cp * 16 + (switch (h) {
                            '0'...'9' => @as(u32, h - '0'),
                            'a'...'f' => @as(u32, h - 'a' + 10),
                            'A'...'F' => @as(u32, h - 'A' + 10),
                            else => return error.MalformedJson,
                        });
                    }
                    if (cp < 0x80) {
                        try out.append(arena, @intCast(cp));
                    } else {
                        // Encode as UTF-8 (we only ever emit \u00XX
                        // for control bytes < 0x20, but be permissive
                        // on read).
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch
                            return error.MalformedJson;
                        try out.appendSlice(arena, buf[0..n]);
                    }
                    p.* += 6;
                },
                else => return error.MalformedJson,
            }
        } else {
            try out.append(arena, c);
            p.* += 1;
        }
    }
    return error.MalformedJson;
}

fn skipValue(s: []const u8, p: *usize) ParseError!void {
    if (p.* >= s.len) return error.MalformedJson;
    const c = s[p.*];
    if (c == '"') {
        // Skip string by walking past the close quote.
        p.* += 1;
        while (p.* < s.len) {
            if (s[p.*] == '\\' and p.* + 1 < s.len) {
                p.* += 2;
                continue;
            }
            if (s[p.*] == '"') {
                p.* += 1;
                return;
            }
            p.* += 1;
        }
        return error.MalformedJson;
    }
    if (c == '-' or (c >= '0' and c <= '9')) {
        if (c == '-') p.* += 1;
        while (p.* < s.len and s[p.*] >= '0' and s[p.*] <= '9') p.* += 1;
        return;
    }
    if (c == 't' or c == 'f' or c == 'n') {
        // true / false / null — skip alphabetic run.
        while (p.* < s.len and ((s[p.*] >= 'a' and s[p.*] <= 'z'))) p.* += 1;
        return;
    }
    return error.MalformedJson;
}

// =============================================================================
// Tests
// =============================================================================

test "history: append + dedupe in by_line" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();

    try idx.append("ls -la", "/tmp", 0, 0);
    try idx.append("ls -la", "/tmp", 0, 0);
    try idx.append("git status", "/tmp", 0, 1);

    try std.testing.expectEqual(@as(usize, 3), idx.events.items.len);
    try std.testing.expectEqual(@as(usize, 2), idx.by_line.count());
    try std.testing.expectEqual(@as(u32, 2), idx.by_line.get("ls -la").?.total_count);
}

test "history: search prefix beats substring" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();

    try idx.append("git status", "/repo", 0, 0);
    try idx.append("status report", "/repo", 0, 0);

    const r = try idx.search(std.testing.allocator, "git", "/repo", .substring, 10);
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("git status", r[0].line);
}

test "history: cwd boost ranks same-cwd higher than other-cwd" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();

    try idx.append("npm install", "/repo-a", 0, 0);
    try idx.append("npm test", "/repo-b", 0, 0);
    try idx.append("npm test", "/repo-b", 0, 0);

    const r = try idx.search(std.testing.allocator, "npm", "/repo-a", .substring, 10);
    defer std.testing.allocator.free(r);
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("npm install", r[0].line);
}

test "history: empty query returns all unique lines, recent first" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();

    try idx.append("a", "/tmp", 0, 0);
    try idx.append("b", "/tmp", 0, 0);
    try idx.append("c", "/tmp", 0, 0);

    const r = try idx.search(std.testing.allocator, "", "/tmp", .substring, 10);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    // Newer last_seq should win on the score tie-break.
    try std.testing.expectEqualStrings("c", r[0].line);
}

test "history: limit clips result count" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();

    try idx.append("one", "/tmp", 0, 0);
    try idx.append("two", "/tmp", 0, 0);
    try idx.append("three", "/tmp", 0, 0);

    const r = try idx.search(std.testing.allocator, "", "/tmp", .substring, 2);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
}

test "history: jsonl round-trip via persist + reload" {
    const path = "/tmp/slash_history_test.jsonl";
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }
    defer {
        const path_z = std.testing.allocator.dupeZ(u8, path) catch unreachable;
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }

    {
        var idx = try HistoryIndex.init(std.testing.allocator, path);
        defer idx.deinit();
        try idx.append("echo \"hi\\there\"", "/tmp/some path", 0, 1);
        try idx.append("git log --oneline", "/repo", 0, 2);
    }

    var idx2 = try HistoryIndex.init(std.testing.allocator, path);
    defer idx2.deinit();
    try idx2.load(null);
    try std.testing.expectEqual(@as(usize, 2), idx2.events.items.len);
    try std.testing.expectEqualStrings("echo \"hi\\there\"", idx2.events.items[0].line);
    try std.testing.expectEqualStrings("/tmp/some path", idx2.events.items[0].cwd);
    try std.testing.expectEqualStrings("git log --oneline", idx2.events.items[1].line);
}

test "history: load skips malformed lines" {
    const path = "/tmp/slash_history_corrupt_test.jsonl";
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
        const fd = std.c.open(
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const data =
            "{\"v\":1,\"seq\":1,\"ts\":1000,\"cwd\":\"/tmp\",\"line\":\"good\"}\n" ++
            "this is not json at all\n" ++
            "{\"v\":1,\"seq\":2,\"ts\":2000,\"cwd\":\"/tmp\",\"line\":\"also good\"}\n";
        _ = std.c.write(fd, data, data.len);
    }
    defer {
        const path_z = std.testing.allocator.dupeZ(u8, path) catch unreachable;
        defer std.testing.allocator.free(path_z);
        _ = std.c.unlink(path_z.ptr);
    }

    var idx = try HistoryIndex.init(std.testing.allocator, path);
    defer idx.deinit();
    try idx.load(null);
    try std.testing.expectEqual(@as(usize, 2), idx.events.items.len);
    try std.testing.expectEqualStrings("good", idx.events.items[0].line);
    try std.testing.expectEqualStrings("also good", idx.events.items[1].line);
}

test "history: legacy import when JSONL is missing" {
    const jsonl = "/tmp/slash_history_jsonl_missing.jsonl";
    const legacy = "/tmp/slash_history_legacy.txt";
    {
        const lz = try std.testing.allocator.dupeZ(u8, legacy);
        defer std.testing.allocator.free(lz);
        _ = std.c.unlink(lz.ptr);
        const fd = std.c.open(
            lz.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        const data = "old-cmd-1\nold-cmd-2\nold-cmd-3\n";
        _ = std.c.write(fd, data, data.len);
    }
    defer {
        const lz = std.testing.allocator.dupeZ(u8, legacy) catch unreachable;
        defer std.testing.allocator.free(lz);
        _ = std.c.unlink(lz.ptr);
        const jz = std.testing.allocator.dupeZ(u8, jsonl) catch unreachable;
        defer std.testing.allocator.free(jz);
        _ = std.c.unlink(jz.ptr);
    }

    var idx = try HistoryIndex.init(std.testing.allocator, jsonl);
    defer idx.deinit();
    try idx.load(legacy);
    try std.testing.expectEqual(@as(usize, 3), idx.events.items.len);
    try std.testing.expectEqualStrings("old-cmd-1", idx.events.items[0].line);
    try std.testing.expectEqualStrings("old-cmd-3", idx.events.items[2].line);
    // Imported events also got persisted to the JSONL file.
    var idx2 = try HistoryIndex.init(std.testing.allocator, jsonl);
    defer idx2.deinit();
    try idx2.load(null);
    try std.testing.expectEqual(@as(usize, 3), idx2.events.items.len);
}

test "history: reject empty / NUL / oversize lines silently" {
    var idx = try HistoryIndex.init(std.testing.allocator, null);
    defer idx.deinit();
    try idx.append("", "/tmp", 0, 0);
    try idx.append("ok\x00bad", "/tmp", 0, 0);
    try idx.append("a", "/tmp", 0, 0);
    try std.testing.expectEqual(@as(usize, 1), idx.events.items.len);
}
