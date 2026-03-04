//! Readline — Line editor with raw terminal mode, arrow keys, and history
//!
//! Provides a readline() function that returns edited input lines.
//! Features: cursor movement, insert/delete, up/down history navigation.

const std = @import("std");
const posix = std.posix;

const STDIN = posix.STDIN_FILENO;
const STDOUT = posix.STDOUT_FILENO;

pub const History = struct {
    lines: [512][]const u8 = .{""} ** 512,
    count: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) History {
        return .{ .alloc = alloc };
    }

    pub fn add(self: *History, line: []const u8) void {
        if (line.len == 0) return;
        if (self.count > 0 and std.mem.eql(u8, self.lines[(self.count - 1) % 512], line)) return;
        const copy = self.alloc.dupe(u8, line) catch return;
        self.lines[self.count % 512] = copy;
        self.count += 1;
    }

    pub fn get(self: *const History, idx: usize) []const u8 {
        if (idx >= self.count) return "";
        return self.lines[idx % 512];
    }
};

var line_buf: [4096]u8 = undefined;
var save_buf: [4096]u8 = undefined;
var active_prompt: []const u8 = "$ ";
var active_prompt_len: usize = 2;
var ghost_text: []const u8 = "";

pub const KeyHandler = struct {
    lookup: *const fn (combo: []const u8) ?[]const u8,
    exec: *const fn (cmd: []const u8) void,
    search: ?*const fn (alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 = null,
    suggest: ?*const fn (prefix: []const u8) ?[]const u8 = null,
};

var key_handler: ?KeyHandler = null;

pub fn setKeyHandler(handler: KeyHandler) void {
    key_handler = handler;
}

pub fn readLineEx(prompt_str: []const u8, prompt_visible_len: usize, history: *History) ?[]const u8 {
    return readLineInner(prompt_str, prompt_visible_len, history);
}

pub fn readLine(prompt_str: []const u8, history: *History) ?[]const u8 {
    return readLineInner(prompt_str, prompt_str.len, history);
}

fn readLineInner(prompt: []const u8, prompt_len: usize, history: *History) ?[]const u8 {
    active_prompt = prompt;
    active_prompt_len = prompt_len;

    const orig = enableRawMode() orelse return null;
    defer disableRawMode(orig);

    var len: usize = 0;
    var cursor: usize = 0;
    var hist_pos: usize = history.count;
    var saved_len: usize = 0;

    writeAll(prompt);

    while (true) {
        var c: [1]u8 = undefined;
        const n = posix.read(STDIN, &c) catch return null;
        if (n == 0) return null;

        switch (c[0]) {
            '\r', '\n' => {
                writeAll("\n");
                if (len == 0) return "";
                return line_buf[0..len];
            },
            3 => {
                writeAll("^C\n");
                len = 0;
                cursor = 0;
                hist_pos = history.count;
                writeAll(prompt);
            },
            4 => {
                if (len == 0) {
                    writeAll("\n");
                    return null;
                }
            },
            127, 8 => {
                if (cursor > 0) {
                    std.mem.copyForwards(u8, line_buf[cursor - 1 ..], line_buf[cursor..len]);
                    len -= 1;
                    cursor -= 1;
                    updateGhost(line_buf[0..len]);
                    refreshLine(line_buf[0..len], cursor);
                }
            },
            27 => {
                var seq: [2]u8 = undefined;
                const n1 = posix.read(STDIN, seq[0..1]) catch return null;
                if (n1 == 0) continue;
                if (seq[0] != '[') {
                    // ESC + char — check key bindings
                    if (key_handler) |kh| {
                        var combo_buf: [16]u8 = undefined;
                        const combo = std.fmt.bufPrint(&combo_buf, "esc+{c}", .{seq[0]}) catch continue;
                        if (kh.lookup(combo)) |cmd| {
                            disableRawMode(orig);
                            writeAll("\n");
                            kh.exec(cmd);
                            writeAll(prompt);
                            const new_orig = enableRawMode() orelse return null;
                            _ = new_orig;
                            // Clear and restart line for clean state after command
                            len = 0;
                            cursor = 0;
                            refreshLine(line_buf[0..len], cursor);
                        }
                    }
                    continue;
                }
                const n2 = posix.read(STDIN, seq[1..2]) catch return null;
                if (n2 == 0) continue;

                switch (seq[1]) {
                    'A' => {
                        if (hist_pos == history.count) {
                            @memcpy(save_buf[0..len], line_buf[0..len]);
                            saved_len = len;
                        }
                        // Search backward for matching prefix
                        var search_pos = hist_pos;
                        while (search_pos > 0) {
                            search_pos -= 1;
                            const h = history.get(search_pos);
                            if (saved_len == 0 or (h.len >= saved_len and std.mem.eql(u8, h[0..saved_len], save_buf[0..saved_len]))) {
                                hist_pos = search_pos;
                                len = @min(h.len, line_buf.len);
                                @memcpy(line_buf[0..len], h[0..len]);
                                cursor = len;
                                refreshLine(line_buf[0..len], cursor);
                                break;
                            }
                        }
                    },
                    'B' => {
                        // Search forward for matching prefix
                        var search_pos = hist_pos;
                        while (search_pos < history.count) {
                            search_pos += 1;
                            if (search_pos == history.count) {
                                hist_pos = search_pos;
                                len = saved_len;
                                @memcpy(line_buf[0..len], save_buf[0..len]);
                                cursor = len;
                                refreshLine(line_buf[0..len], cursor);
                                break;
                            }
                            const h = history.get(search_pos);
                            if (saved_len == 0 or (h.len >= saved_len and std.mem.eql(u8, h[0..saved_len], save_buf[0..saved_len]))) {
                                hist_pos = search_pos;
                                len = @min(h.len, line_buf.len);
                                @memcpy(line_buf[0..len], h[0..len]);
                                cursor = len;
                                refreshLine(line_buf[0..len], cursor);
                                break;
                            }
                        }
                    },
                    'C' => {
                        if (cursor < len) {
                            cursor += 1;
                            writeAll("\x1b[C");
                        } else if (ghost_text.len > 0) {
                            if (len + ghost_text.len <= line_buf.len) {
                                @memcpy(line_buf[len..][0..ghost_text.len], ghost_text);
                                len += ghost_text.len;
                                cursor = len;
                                ghost_text = "";
                                refreshLine(line_buf[0..len], cursor);
                            }
                        }
                    },
                    'D' => {
                        if (cursor > 0) {
                            cursor -= 1;
                            writeAll("\x1b[D");
                        }
                    },
                    'H' => {
                        cursor = 0;
                        refreshLine(line_buf[0..len], cursor);
                    },
                    'F' => {
                        cursor = len;
                        refreshLine(line_buf[0..len], cursor);
                    },
                    '3' => {
                        var extra: [1]u8 = undefined;
                        _ = posix.read(STDIN, &extra) catch {};
                        if (extra[0] == '~' and cursor < len) {
                            std.mem.copyForwards(u8, line_buf[cursor..], line_buf[cursor + 1 .. len]);
                            len -= 1;
                            refreshLine(line_buf[0..len], cursor);
                        }
                    },
                    else => {},
                }
            },
            18 => {
                // Ctrl+R: history search
                if (key_handler) |kh| {
                    disableRawMode(orig);
                    const result = historySearch(kh);
                    const new_orig = enableRawMode() orelse return null;
                    _ = new_orig;
                    if (result) |selected| {
                        @memcpy(line_buf[0..selected.len], selected);
                        len = selected.len;
                        cursor = len;
                    }
                    refreshLine(line_buf[0..len], cursor);
                }
            },
            1 => {
                cursor = 0;
                refreshLine(line_buf[0..len], cursor);
            },
            5 => {
                cursor = len;
                refreshLine(line_buf[0..len], cursor);
            },
            11 => {
                len = cursor;
                refreshLine(line_buf[0..len], cursor);
            },
            21 => {
                std.mem.copyForwards(u8, line_buf[0..], line_buf[cursor..len]);
                len -= cursor;
                cursor = 0;
                refreshLine(line_buf[0..len], cursor);
            },
            else => |ch| {
                if (ch >= 32 and ch < 127) {
                    if (len < line_buf.len - 1) {
                        if (cursor < len) {
                            std.mem.copyBackwards(u8, line_buf[cursor + 1 .. len + 1], line_buf[cursor..len]);
                        }
                        line_buf[cursor] = ch;
                        len += 1;
                        cursor += 1;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                    }
                }
            },
        }
    }
}

var ghost_buf: [4096]u8 = undefined;

fn updateGhost(line: []const u8) void {
    ghost_text = "";
    if (line.len < 2) return;
    if (key_handler) |kh| {
        if (kh.suggest) |suggest_fn| {
            if (suggest_fn(line)) |suggestion| {
                if (suggestion.len > line.len and std.mem.startsWith(u8, suggestion, line)) {
                    const suffix = suggestion[line.len..];
                    if (suffix.len <= ghost_buf.len) {
                        @memcpy(ghost_buf[0..suffix.len], suffix);
                        ghost_text = ghost_buf[0..suffix.len];
                    }
                }
            }
        }
    }
}

fn refreshLine(line: []const u8, cursor: usize) void {
    writeAll("\r\x1b[K");
    writeAll(active_prompt);
    writeAll(line);
    if (ghost_text.len > 0 and cursor == line.len) {
        writeAll("\x1b[90m");
        writeAll(ghost_text);
        writeAll("\x1b[0m");
    }
    const total = active_prompt_len + cursor;
    var move_buf: [32]u8 = undefined;
    const move = std.fmt.bufPrint(&move_buf, "\r\x1b[{d}C", .{total}) catch return;
    writeAll(move);
}

fn historySearch(kh: KeyHandler) ?[]const u8 {
    const search_fn = kh.search orelse return null;
    var query_buf: [256]u8 = undefined;
    var qlen: usize = 0;
    var selected: usize = 0;
    var results: [][]const u8 = &.{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Initial results (empty query = recent)
    results = search_fn(alloc, "", 10);

    while (true) {
        // Clear overlay area and draw
        writeAll("\r\n\x1b[J"); // newline + clear below
        writeAll("\x1b[7m History Search: \x1b[0m ");
        writeAll(query_buf[0..qlen]);
        writeAll("\n");
        for (results, 0..) |cmd, i| {
            if (i == selected) writeAll("\x1b[7m") else writeAll("  ");
            writeAll(cmd);
            if (i == selected) writeAll("\x1b[0m");
            writeAll("\n");
        }
        // Move cursor back up to search line
        var up_buf: [16]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "\x1b[{d}A", .{results.len + 1}) catch break;
        writeAll(up);
        var col_buf: [16]u8 = undefined;
        const col = std.fmt.bufPrint(&col_buf, "\r\x1b[{d}C", .{19 + qlen}) catch break;
        writeAll(col);

        // Read input
        var ch: [1]u8 = undefined;
        const n = posix.read(STDIN, &ch) catch break;
        if (n == 0) break;

        switch (ch[0]) {
            '\r', '\n' => {
                // Accept selection
                clearOverlay(results.len + 1);
                if (selected < results.len) {
                    const r = alloc.dupe(u8, results[selected]) catch return null;
                    @memcpy(save_buf[0..r.len], r);
                    return save_buf[0..r.len];
                }
                return null;
            },
            27 => {
                // ESC or arrow keys
                var seq: [2]u8 = undefined;
                const n1 = posix.read(STDIN, seq[0..1]) catch break;
                if (n1 > 0 and seq[0] == '[') {
                    const n2 = posix.read(STDIN, seq[1..2]) catch break;
                    if (n2 > 0) {
                        if (seq[1] == 'A' and selected > 0) selected -= 1; // up
                        if (seq[1] == 'B' and selected + 1 < results.len) selected += 1; // down
                    }
                } else {
                    // Plain ESC — cancel
                    clearOverlay(results.len + 1);
                    return null;
                }
            },
            127, 8 => {
                if (qlen > 0) {
                    qlen -= 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = search_fn(alloc, query_buf[0..qlen], 10);
                }
            },
            3 => {
                // Ctrl+C — cancel
                clearOverlay(results.len + 1);
                return null;
            },
            else => |byte| {
                if (byte >= 32 and byte < 127 and qlen < query_buf.len) {
                    query_buf[qlen] = byte;
                    qlen += 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = search_fn(alloc, query_buf[0..qlen], 10);
                }
            },
        }
    }
    clearOverlay(results.len + 1);
    return null;
}

fn clearOverlay(lines: usize) void {
    var buf: [16]u8 = undefined;
    writeAll("\r\n\x1b[J");
    const up = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{lines}) catch return;
    writeAll(up);
    writeAll("\r\x1b[K");
}

fn writeAll(data: []const u8) void {
    _ = posix.write(STDOUT, data) catch {};
}

fn enableRawMode() ?posix.termios {
    const orig = posix.tcgetattr(STDIN) catch return null;
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(STDIN, .NOW, raw) catch return null;
    return orig;
}

fn disableRawMode(orig: posix.termios) void {
    posix.tcsetattr(STDIN, .NOW, orig) catch {};
}
