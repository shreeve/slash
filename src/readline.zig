//! Readline — Line editor with raw terminal mode, arrow keys, and history
//!
//! Provides a readline() function that returns edited input lines.
//! Features: cursor movement, insert/delete, up/down history navigation.

const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");
const TokenCat = parser.TokenCat;
const Shell = @import("exec.zig").Shell;

const STDIN = posix.STDIN_FILENO;
const STDOUT = posix.STDOUT_FILENO;

pub const History = struct {
    const CAPACITY = 512;
    lines: [CAPACITY][]const u8 = .{""} ** CAPACITY,
    count: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) History {
        return .{ .alloc = alloc };
    }

    pub fn add(self: *History, line: []const u8) void {
        if (line.len == 0) return;
        if (self.count > 0 and std.mem.eql(u8, self.lines[(self.count - 1) % CAPACITY], line)) return;
        const copy = self.alloc.dupe(u8, line) catch return;
        const slot = self.count % CAPACITY;
        if (self.count >= CAPACITY and self.lines[slot].len > 0) {
            self.alloc.free(self.lines[slot]);
        }
        self.lines[slot] = copy;
        self.count += 1;
    }

    pub fn get(self: *const History, idx: usize) []const u8 {
        if (idx >= self.count) return "";
        if (self.count > CAPACITY and idx < self.count - CAPACITY) return "";
        return self.lines[idx % CAPACITY];
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
    eval_math: ?*const fn (expr: []const u8) ?[]const u8 = null,
    user_cmd_names: ?*const fn () []const []const u8 = null,
    shell_var_names: ?*const fn () []const []const u8 = null,
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
                if (ghost_text.len > 0) {
                    ghost_text = "";
                    refreshLine(line_buf[0..len], cursor);
                }
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
                    var del: usize = 1;
                    while (del < cursor and (line_buf[cursor - del] & 0xC0) == 0x80) del += 1;
                    std.mem.copyForwards(u8, line_buf[cursor - del ..], line_buf[cursor..len]);
                    len -= del;
                    cursor -= del;
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
                        const combo = std.fmt.bufPrint(&combo_buf, "esc-{c}", .{seq[0]}) catch continue;
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
                                updateGhost(line_buf[0..len]);
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
                                updateGhost(line_buf[0..len]);
                                refreshLine(line_buf[0..len], cursor);
                                break;
                            }
                            const h = history.get(search_pos);
                            if (saved_len == 0 or (h.len >= saved_len and std.mem.eql(u8, h[0..saved_len], save_buf[0..saved_len]))) {
                                hist_pos = search_pos;
                                len = @min(h.len, line_buf.len);
                                @memcpy(line_buf[0..len], h[0..len]);
                                cursor = len;
                                updateGhost(line_buf[0..len]);
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
                    const result = historySearch(kh);
                    if (result) |selected| {
                        len = @min(selected.len, line_buf.len);
                        @memcpy(line_buf[0..len], selected[0..len]);
                        cursor = len;
                    }
                    refreshLine(line_buf[0..len], cursor);
                }
            },
            16 => {
                // Ctrl+P: previous history entry (prefix-matching)
                if (hist_pos == history.count) {
                    @memcpy(save_buf[0..len], line_buf[0..len]);
                    saved_len = len;
                }
                var search_pos = hist_pos;
                while (search_pos > 0) {
                    search_pos -= 1;
                    const h = history.get(search_pos);
                    if (saved_len == 0 or (h.len >= saved_len and std.mem.eql(u8, h[0..saved_len], save_buf[0..saved_len]))) {
                        hist_pos = search_pos;
                        len = @min(h.len, line_buf.len);
                        @memcpy(line_buf[0..len], h[0..len]);
                        cursor = len;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                        break;
                    }
                }
            },
            14 => {
                // Ctrl+N: next history entry (prefix-matching)
                var search_pos = hist_pos;
                while (search_pos < history.count) {
                    search_pos += 1;
                    if (search_pos == history.count) {
                        hist_pos = search_pos;
                        len = saved_len;
                        @memcpy(line_buf[0..len], save_buf[0..len]);
                        cursor = len;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                        break;
                    }
                    const h = history.get(search_pos);
                    if (saved_len == 0 or (h.len >= saved_len and std.mem.eql(u8, h[0..saved_len], save_buf[0..saved_len]))) {
                        hist_pos = search_pos;
                        len = @min(h.len, line_buf.len);
                        @memcpy(line_buf[0..len], h[0..len]);
                        cursor = len;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                        break;
                    }
                }
            },
            9 => {
                // Tab: accept ghost suggestion OR complete
                if (ghost_text.len > 0 and cursor == len) {
                    if (len + ghost_text.len + 1 <= line_buf.len) {
                        @memcpy(line_buf[len..][0..ghost_text.len], ghost_text);
                        len += ghost_text.len;
                        line_buf[len] = ' ';
                        len += 1;
                        cursor = len;
                        ghost_text = "";
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                    }
                } else if (len > 0) {
                    const result = tabComplete(line_buf[0..len], cursor);
                    if (result.replacement.len > 0) {
                        const word_start = result.word_start;
                        const word_end = cursor;
                        const new_len = word_start + result.replacement.len + (len - word_end);
                        if (new_len < line_buf.len) {
                            if (word_end < len) std.mem.copyBackwards(u8, line_buf[word_start + result.replacement.len ..], line_buf[word_end..len]);
                            @memcpy(line_buf[word_start..][0..result.replacement.len], result.replacement);
                            len = new_len;
                            cursor = word_start + result.replacement.len;
                            ghost_text = "";
                            updateGhost(line_buf[0..len]);
                            refreshLine(line_buf[0..len], cursor);
                        }
                    } else if (result.matches > 1) {
                        showCompletions(line_buf[0..len], cursor, result.word_start);
                        refreshLine(line_buf[0..len], cursor);
                    }
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
                if (ch < 32) {
                    if (key_handler) |kh| {
                        var ctrl_buf: [16]u8 = undefined;
                        const ctrl_name = std.fmt.bufPrint(&ctrl_buf, "ctrl-{c}", .{ch + 'a' - 1}) catch "";
                        if (ctrl_name.len > 0) {
                            if (kh.lookup(ctrl_name)) |cmd_str| {
                                disableRawMode(orig);
                                writeAll("\n");
                                kh.exec(cmd_str);
                                writeAll(prompt);
                                const new_orig = enableRawMode() orelse return null;
                                _ = new_orig;
                                len = 0;
                                cursor = 0;
                                refreshLine(line_buf[0..len], cursor);
                                continue;
                            }
                        }
                    }
                } else if (ch >= 32) {
                    // Space after dir completion: replace trailing / with space
                    if (ch == ' ' and completed_dir_slash and cursor > 0 and cursor == len and line_buf[cursor - 1] == '/') {
                        line_buf[cursor - 1] = ' ';
                        completed_dir_slash = false;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                    } else {
                        completed_dir_slash = false;
                        const byte_count: usize = if (ch < 0x80) 1 else if (ch < 0xE0) 2 else if (ch < 0xF0) 3 else 4;
                        if (len + byte_count <= line_buf.len - 1) {
                            if (cursor < len) {
                                std.mem.copyBackwards(u8, line_buf[cursor + byte_count .. len + byte_count], line_buf[cursor..len]);
                            }
                            line_buf[cursor] = ch;
                            if (byte_count > 1) {
                                var extra: [3]u8 = undefined;
                                const got = posix.read(STDIN, extra[0 .. byte_count - 1]) catch 0;
                                for (0..got) |j| line_buf[cursor + 1 + j] = extra[j];
                            }
                            len += byte_count;
                            cursor += byte_count;
                            updateGhost(line_buf[0..len]);
                            refreshLine(line_buf[0..len], cursor);
                        }
                    }
                }
            },
        }
    }
}

var ghost_buf: [4096]u8 = undefined;
var completed_dir_slash = false;
var complete_buf: [4096]u8 = undefined;
var complete_list_buf: [32][]const u8 = undefined;
var complete_match_count: usize = 0;

const TabResult = struct {
    replacement: []const u8,
    word_start: usize,
    matches: usize,
};

fn tabComplete(line: []const u8, cursor: usize) TabResult {
    // Find the word being completed
    var word_start = cursor;
    while (word_start > 0 and line[word_start - 1] != ' ' and line[word_start - 1] != '\t') word_start -= 1;
    const prefix = line[word_start..cursor];
    if (prefix.len == 0) return .{ .replacement = "", .word_start = word_start, .matches = 0 };

    // Determine context
    const is_first_word = blk: {
        var i: usize = 0;
        while (i < word_start and (line[i] == ' ' or line[i] == '\t')) i += 1;
        break :blk i == word_start;
    };
    const is_variable = prefix.len > 0 and prefix[0] == '$';

    if (is_variable) return completeVariable(prefix, word_start);
    if (is_first_word) return completeCommand(prefix, word_start);
    return completePath(prefix, word_start);
}

var tilde_buf: [4096]u8 = undefined;

fn completePath(prefix: []const u8, word_start: usize) TabResult {
    // Split into directory and file prefix
    var dir_end: usize = 0;
    for (prefix, 0..) |ch, i| {
        if (ch == '/') dir_end = i + 1;
    }
    const dir_part = if (dir_end > 0) prefix[0..dir_end] else "";
    const file_prefix = prefix[dir_end..];
    // Expand ~ to $HOME
    const dir_path = if (dir_part.len > 0) blk: {
        if (dir_part.len >= 2 and dir_part[0] == '~' and dir_part[1] == '/') {
            const home = std.posix.getenv("HOME") orelse break :blk dir_part;
            break :blk std.fmt.bufPrint(&tilde_buf, "{s}{s}", .{ home, dir_part[1..] }) catch dir_part;
        }
        break :blk dir_part;
    } else ".";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch
        return .{ .replacement = "", .word_start = word_start, .matches = 0 };
    defer dir.close();

    var match_count: usize = 0;
    var single_match: []const u8 = "";
    var common_len: usize = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name[0] == '.' and (file_prefix.len == 0 or file_prefix[0] != '.')) continue;
        if (file_prefix.len == 0 or std.mem.startsWith(u8, entry.name, file_prefix)) {
            if (match_count < 32) {
                const full = if (dir_part.len > 0)
                    std.fmt.bufPrint(complete_buf[match_count * 128 ..][0..128], "{s}{s}", .{ dir_part, entry.name }) catch continue
                else
                    std.fmt.bufPrint(complete_buf[match_count * 128 ..][0..128], "{s}", .{entry.name}) catch continue;
                if (match_count == 0) {
                    single_match = full;
                    common_len = full.len;
                } else {
                    var cl: usize = 0;
                    while (cl < common_len and cl < full.len and single_match[cl] == full[cl]) cl += 1;
                    common_len = cl;
                }
                complete_list_buf[match_count] = full;
            }
            match_count += 1;
        }
    }

    complete_match_count = match_count;
    if (match_count == 0) return .{ .replacement = "", .word_start = word_start, .matches = 0 };
    if (match_count == 1) {
        // Check if it's a directory — append /
        const name = complete_list_buf[0];
        // Expand ~ for stat check
        var stat_path_buf: [4096]u8 = undefined;
        const check_path = if (name.len >= 2 and name[0] == '~' and name[1] == '/') blk: {
            const home = std.posix.getenv("HOME") orelse break :blk name;
            break :blk std.fmt.bufPrint(&stat_path_buf, "{s}{s}", .{ home, name[1..] }) catch name;
        } else name;
        const stat = std.fs.cwd().statFile(check_path) catch null;
        if (stat != null and stat.?.kind == .directory) {
            const trail_len = name.len + 1;
            if (trail_len < 128) {
                @memcpy(complete_buf[3968..][0..name.len], name);
                complete_buf[3968 + name.len] = '/';
                completed_dir_slash = true;
                return .{ .replacement = complete_buf[3968..][0..trail_len], .word_start = word_start, .matches = 1 };
            }
        }
        return .{ .replacement = name, .word_start = word_start, .matches = 1 };
    }
    // Multiple matches — complete common prefix
    if (common_len > prefix.len) {
        return .{ .replacement = single_match[0..common_len], .word_start = word_start, .matches = match_count };
    }
    return .{ .replacement = "", .word_start = word_start, .matches = match_count };
}

var cmd_match_buf: [32][128]u8 = undefined;
var cmd_match_count: usize = 0;

const PathCache = struct {
    names: [][]const u8 = &.{},
    path_hash: u64 = 0,
    alloc: std.mem.Allocator = std.heap.page_allocator,

    fn refresh(self: *PathCache) void {
        const path_env = std.posix.getenv("PATH") orelse "";
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";
        var hash_ctx = std.hash.Fnv1a_64.init();
        hash_ctx.update(path_env);
        hash_ctx.update("\x00");
        hash_ctx.update(cwd);
        const hash = hash_ctx.final();
        if (hash == self.path_hash and self.names.len > 0) return;
        self.path_hash = hash;

        for (self.names) |n| self.alloc.free(n);
        if (self.names.len > 0) self.alloc.free(self.names);

        var list: std.ArrayList([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();

        var path_iter = std.mem.splitScalar(u8, path_env, ':');
        while (path_iter.next()) |dir_path| {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (seen.contains(entry.name)) continue;
                var full_path_buf: [4096]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                std.posix.access(full_path, std.posix.X_OK) catch continue;
                const name = self.alloc.dupe(u8, entry.name) catch continue;
                list.append(self.alloc, name) catch continue;
                seen.put(name, {}) catch {};
            }
        }

        self.names = list.toOwnedSlice(self.alloc) catch &.{};
        std.mem.sort([]const u8, self.names, {}, lessThanStr);
    }
};

var path_cache: PathCache = .{};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn completeCommand(prefix: []const u8, word_start: usize) TabResult {
    cmd_match_count = 0;
    var common_len: usize = 0;

    for (Shell.builtin_names ++ Shell.keyword_names) |b| {
        if (std.mem.startsWith(u8, b, prefix)) {
            if (cmd_match_count < 32 and b.len < 128) {
                @memcpy(cmd_match_buf[cmd_match_count][0..b.len], b);
                complete_list_buf[cmd_match_count] = cmd_match_buf[cmd_match_count][0..b.len];
                if (cmd_match_count == 0) common_len = b.len else {
                    var cl: usize = 0;
                    while (cl < common_len and cl < b.len and cmd_match_buf[0][cl] == b[cl]) cl += 1;
                    common_len = cl;
                }
                cmd_match_count += 1;
            }
        }
    }

    path_cache.refresh();
    for (path_cache.names) |name| {
        if (cmd_match_count >= 32) break;
        if (std.mem.startsWith(u8, name, prefix) and name.len < 128) {
            @memcpy(cmd_match_buf[cmd_match_count][0..name.len], name);
            complete_list_buf[cmd_match_count] = cmd_match_buf[cmd_match_count][0..name.len];
            if (cmd_match_count == 0) common_len = name.len else {
                var cl: usize = 0;
                while (cl < common_len and cl < name.len and cmd_match_buf[0][cl] == name[cl]) cl += 1;
                common_len = cl;
            }
            cmd_match_count += 1;
        }
    }

    if (key_handler) |kh| {
        if (kh.user_cmd_names) |get_cmds| {
            for (get_cmds()) |name| {
                if (cmd_match_count >= 32) break;
                if (std.mem.startsWith(u8, name, prefix) and name.len < 128) {
                    @memcpy(cmd_match_buf[cmd_match_count][0..name.len], name);
                    complete_list_buf[cmd_match_count] = cmd_match_buf[cmd_match_count][0..name.len];
                    if (cmd_match_count == 0) common_len = name.len else {
                        var cl: usize = 0;
                        while (cl < common_len and cl < name.len and cmd_match_buf[0][cl] == name[cl]) cl += 1;
                        common_len = cl;
                    }
                    cmd_match_count += 1;
                }
            }
        }
    }

    complete_match_count = cmd_match_count;
    if (cmd_match_count == 0) return .{ .replacement = "", .word_start = word_start, .matches = 0 };
    if (cmd_match_count == 1) return .{ .replacement = complete_list_buf[0], .word_start = word_start, .matches = 1 };
    if (common_len > prefix.len) return .{ .replacement = cmd_match_buf[0][0..common_len], .word_start = word_start, .matches = cmd_match_count };
    return .{ .replacement = "", .word_start = word_start, .matches = cmd_match_count };
}

fn completeVariable(prefix: []const u8, word_start: usize) TabResult {
    const var_prefix = if (prefix.len > 1) prefix[1..] else "";
    const specials = [_][]const u8{ "$?", "$$", "$#", "$*", "$0", "$1", "$2", "$3", "$4", "$5", "$6", "$7", "$8", "$9" };

    var match_count: usize = 0;
    var first_match: []const u8 = "";

    for (specials) |s| {
        if (std.mem.startsWith(u8, s, prefix)) {
            if (match_count == 0) first_match = s;
            match_count += 1;
        }
    }

    if (var_prefix.len > 0) {
        const env = std.c.environ;
        var i: usize = 0;
        while (env[i]) |entry| : (i += 1) {
            if (match_count >= 32) break;
            const slice: [*]const u8 = @ptrCast(entry);
            var eq: usize = 0;
            while (slice[eq] != '=' and slice[eq] != 0) eq += 1;
            const name = slice[0..eq];
            if (std.mem.startsWith(u8, name, var_prefix)) {
                const full_len = 1 + name.len;
                if (full_len < 128) {
                    complete_buf[match_count * 128] = '$';
                    @memcpy(complete_buf[match_count * 128 + 1 ..][0..name.len], name);
                    const full = complete_buf[match_count * 128 ..][0..full_len];
                    if (match_count == 0) first_match = full;
                    complete_list_buf[match_count] = full;
                    match_count += 1;
                }
            }
        }
    }

    if (var_prefix.len > 0) {
        if (key_handler) |kh| {
            if (kh.shell_var_names) |get_vars| {
                for (get_vars()) |name| {
                    if (match_count >= 32) break;
                    if (std.mem.startsWith(u8, name, var_prefix)) {
                        const full_len = 1 + name.len;
                        if (full_len < 128) {
                            complete_buf[match_count * 128] = '$';
                            @memcpy(complete_buf[match_count * 128 + 1 ..][0..name.len], name);
                            const full = complete_buf[match_count * 128 ..][0..full_len];
                            if (match_count == 0) first_match = full;
                            if (match_count < 32) complete_list_buf[match_count] = full;
                            match_count += 1;
                        }
                    }
                }
            }
        }
    }

    if (match_count == 1) return .{ .replacement = first_match, .word_start = word_start, .matches = 1 };
    return .{ .replacement = "", .word_start = word_start, .matches = match_count };
}

fn showCompletions(line: []const u8, _: usize, _: usize) void {
    writeAll("\n");
    for (complete_list_buf[0..@min(complete_match_count, 32)]) |item| {
        writeAll(item);
        writeAll("  ");
    }
    writeAll("\n");
    writeAll(active_prompt);
    writeAll(line);
}

var suggest_cache: [4096]u8 = undefined;
var suggest_cache_len: usize = 0;

fn updateGhost(line: []const u8) void {
    ghost_text = "";
    if (line.len < 2) return;

    if (suggest_cache_len > line.len and
        std.mem.startsWith(u8, suggest_cache[0..suggest_cache_len], line))
    {
        const suffix = suggest_cache[line.len..suggest_cache_len];
        if (suffix.len <= ghost_buf.len) {
            @memcpy(ghost_buf[0..suffix.len], suffix);
            ghost_text = ghost_buf[0..suffix.len];
        }
        return;
    }

    if (key_handler) |kh| {
        if (kh.suggest) |suggest_fn| {
            if (suggest_fn(line)) |suggestion| {
                if (suggestion.len > line.len and std.mem.startsWith(u8, suggestion, line)) {
                    const n = @min(suggestion.len, suggest_cache.len);
                    @memcpy(suggest_cache[0..n], suggestion[0..n]);
                    suggest_cache_len = n;
                    const suffix = suggestion[line.len..];
                    if (suffix.len <= ghost_buf.len) {
                        @memcpy(ghost_buf[0..suffix.len], suffix);
                        ghost_text = ghost_buf[0..suffix.len];
                    }
                }
            } else {
                suggest_cache_len = 0;
            }
        }
    }
}

fn refreshLine(line: []const u8, cursor: usize) void {
    writeAll("\r\x1b[K");
    writeAll(active_prompt);
    writeColorized(line);
    // Inline math preview: show result for lines starting with =
    const math_shown = showMathPreview(line);
    if (!math_shown and ghost_text.len > 0 and cursor == line.len) {
        writeAll("\x1b[90m");
        writeAll(ghost_text);
        writeAll("\x1b[0m");
    }
    const total = active_prompt_len + cursor;
    var move_buf: [32]u8 = undefined;
    const move = std.fmt.bufPrint(&move_buf, "\r\x1b[{d}C", .{total}) catch return;
    writeAll(move);
}

var math_cache_line: [4096]u8 = undefined;
var math_cache_line_len: usize = 0;
var math_cache_result: [256]u8 = undefined;
var math_cache_result_len: usize = 0;
var math_cache_valid: bool = false;

fn showMathPreview(line: []const u8) bool {
    if (line.len < 2) return false;
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '=') return false;
    const expr = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (expr.len == 0) return false;

    if (math_cache_valid and line.len == math_cache_line_len and
        line.len <= math_cache_line.len and
        std.mem.eql(u8, line, math_cache_line[0..math_cache_line_len]))
    {
        if (math_cache_result_len > 0) {
            writeAll("  \x1b[90m= ");
            writeAll(math_cache_result[0..math_cache_result_len]);
            writeAll("\x1b[0m");
            return true;
        }
        return false;
    }

    var got_result = false;
    if (key_handler) |kh| {
        if (kh.eval_math) |eval_fn| {
            if (eval_fn(line)) |result| {
                writeAll("  \x1b[90m= ");
                writeAll(result);
                writeAll("\x1b[0m");
                const n = @min(result.len, math_cache_result.len);
                @memcpy(math_cache_result[0..n], result[0..n]);
                math_cache_result_len = n;
                got_result = true;
            }
        }
    }

    if (line.len <= math_cache_line.len) {
        @memcpy(math_cache_line[0..line.len], line);
        math_cache_line_len = line.len;
        math_cache_valid = true;
        if (!got_result) math_cache_result_len = 0;
    }

    return got_result;
}

fn isKeyword(word: []const u8) bool {
    for (Shell.keyword_names) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn tokenColor(cat: TokenCat, text: []const u8) ?[]const u8 {
    return switch (cat) {
        .string_sq, .string_dq => "\x1b[32m",
        .variable, .var_braced => "\x1b[36m",
        .integer, .real => "\x1b[35m",
        .flag => "\x1b[96m",
        .pipe, .pipe_err, .and_sym, .or_sym, .semi, .bg => "\x1b[33m",
        .redir_out, .redir_append, .redir_in, .redir_err, .redir_err_app, .redir_both, .redir_dup, .herestring => "\x1b[33m",
        .assign, .eq, .ne, .le, .ge, .match, .nomatch => "\x1b[33m",
        .regex => "\x1b[31m",
        .comment => "\x1b[90m",
        .not_sym => "\x1b[33m",
        .dollar_paren, .proc_sub_in, .proc_sub_out => "\x1b[36m",
        .err => "\x1b[31;4m",
        .ident => if (isKeyword(text)) "\x1b[34m" else null,
        else => null,
    };
}

fn writeColorized(line: []const u8) void {
    if (line.len == 0) return;

    var lex = parser.Lexer.init(line);
    var pos: usize = 0;

    while (true) {
        const tok = lex.next();
        const tok_start: usize = tok.pos;
        const tok_end: usize = @min(tok_start + tok.len, line.len);

        if (tok_start > pos) writeAll(line[pos..tok_start]);

        if (tok.cat == .eof) {
            if (pos < line.len) writeAll(line[pos..]);
            break;
        }

        const text = lex.text(tok);
        if (tokenColor(tok.cat, text)) |color| {
            writeAll(color);
            writeAll(text);
            writeAll("\x1b[0m");
        } else {
            writeAll(text);
        }
        pos = tok_end;
    }
}

const OverlayItem = struct { text: []const u8, suffix: []const u8 };

var overlay_return_buf: [4096]u8 = undefined;

fn overlaySearch(
    title: []const u8,
    title_width: usize,
    searchFn: *const fn (std.mem.Allocator, []const u8) []OverlayItem,
) ?OverlayItem {
    var query_buf: [256]u8 = undefined;
    var qlen: usize = 0;
    var selected: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var results = searchFn(alloc, "");
    var first_draw = true;

    while (true) {
        if (first_draw) { writeAll("\n"); first_draw = false; } else writeAll("\r");
        writeAll("\x1b[J");
        writeAll(title);
        writeAll(query_buf[0..qlen]);
        writeAll("\n");
        for (results, 0..) |item, i| {
            if (i == selected) writeAll("\x1b[7m") else writeAll("  ");
            writeAll(item.text);
            if (i == selected) writeAll("\x1b[0m");
            writeAll(item.suffix);
            writeAll("\n");
        }
        var up_buf: [16]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "\x1b[{d}A", .{results.len + 1}) catch break;
        writeAll(up);
        var col_buf: [16]u8 = undefined;
        const col = std.fmt.bufPrint(&col_buf, "\r\x1b[{d}C", .{title_width + qlen}) catch break;
        writeAll(col);

        var ch: [1]u8 = undefined;
        const n = posix.read(STDIN, &ch) catch break;
        if (n == 0) break;

        switch (ch[0]) {
            '\r', '\n', 9 => {
                clearOverlay();
                if (selected < results.len) {
                    var item = results[selected];
                    const tlen = @min(item.text.len, overlay_return_buf.len);
                    @memcpy(overlay_return_buf[0..tlen], item.text[0..tlen]);
                    item.text = overlay_return_buf[0..tlen];
                    return item;
                }
                return null;
            },
            27 => {
                var seq: [2]u8 = undefined;
                const n1 = posix.read(STDIN, seq[0..1]) catch break;
                if (n1 > 0 and seq[0] == '[') {
                    const n2 = posix.read(STDIN, seq[1..2]) catch break;
                    if (n2 > 0) {
                        if (seq[1] == 'A' and selected > 0) selected -= 1;
                        if (seq[1] == 'B' and selected + 1 < results.len) selected += 1;
                    }
                } else {
                    clearOverlay();
                    return null;
                }
            },
            127, 8 => {
                if (qlen > 0) {
                    qlen -= 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = searchFn(alloc, query_buf[0..qlen]);
                }
            },
            3 => { clearOverlay(); return null; },
            else => |byte| {
                if (byte >= 32 and byte < 127 and qlen < query_buf.len) {
                    query_buf[qlen] = byte;
                    qlen += 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = searchFn(alloc, query_buf[0..qlen]);
                }
            },
        }
    }
    clearOverlay();
    return null;
}

var overlay_items_buf: [32]OverlayItem = undefined;

fn historySearch(kh: KeyHandler) ?[]const u8 {
    const search_fn = kh.search orelse return null;
    const wrapper = struct {
        var saved_fn: *const fn (std.mem.Allocator, []const u8, usize) [][]const u8 = undefined;
        fn search(alloc: std.mem.Allocator, query: []const u8) []OverlayItem {
            const results = saved_fn(alloc, query, 10);
            for (results, 0..) |text, i| {
                if (i >= 32) break;
                overlay_items_buf[i] = .{ .text = text, .suffix = "" };
            }
            return overlay_items_buf[0..@min(results.len, 32)];
        }
    };
    wrapper.saved_fn = search_fn;
    const result = overlaySearch("\x1b[7m History Search: \x1b[0m ", 19, &wrapper.search) orelse return null;
    const len = @min(result.text.len, save_buf.len);
    @memcpy(save_buf[0..len], result.text[0..len]);
    return save_buf[0..len];
}

fn clearOverlay() void {
    writeAll("\r\x1b[J");
    writeAll("\x1b[A");
    writeAll("\r");
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
