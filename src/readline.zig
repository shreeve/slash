//! Readline — Line editor with raw terminal mode, arrow keys, and history
//!
//! Provides a readline() function that returns edited input lines.
//! Features: cursor movement, insert/delete, up/down history navigation.

const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");
const TokenCat = parser.TokenCat;

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

pub const PaletteResult = struct {
    text: []const u8,
    kind: enum { history, directory, command },
};

pub const KeyHandler = struct {
    lookup: *const fn (combo: []const u8) ?[]const u8,
    exec: *const fn (cmd: []const u8) void,
    search: ?*const fn (alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 = null,
    suggest: ?*const fn (prefix: []const u8) ?[]const u8 = null,
    palette: ?*const fn (alloc: std.mem.Allocator, query: []const u8) []PaletteResult = null,
    eval_math: ?*const fn (expr: []const u8) ?[]const u8 = null,
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
                    const result = historySearch(kh);
                    if (result) |selected| {
                        @memcpy(line_buf[0..selected.len], selected);
                        len = selected.len;
                        cursor = len;
                    }
                    refreshLine(line_buf[0..len], cursor);
                }
            },
            16 => {
                // Ctrl+P: command palette
                if (key_handler) |kh| {
                    if (kh.palette != null) {
                        const result = paletteSearch(kh);
                        if (result) |r| {
                            switch (r.kind) {
                                .history, .command => {
                                    @memcpy(line_buf[0..r.text.len], r.text);
                                    len = r.text.len;
                                    cursor = len;
                                },
                                .directory => {
                                    @memcpy(line_buf[0..2], "cd");
                                    line_buf[2] = ' ';
                                    @memcpy(line_buf[3..][0..r.text.len], r.text);
                                    len = 3 + r.text.len;
                                    cursor = len;
                                },
                            }
                        }
                        ghost_text = "";
                        refreshLine(line_buf[0..len], cursor);
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
                if (ch >= 32 and ch < 127) {
                    // Space after dir completion: replace trailing / with space
                    if (ch == ' ' and completed_dir_slash and cursor > 0 and cursor == len and line_buf[cursor - 1] == '/') {
                        line_buf[cursor - 1] = ' ';
                        completed_dir_slash = false;
                        updateGhost(line_buf[0..len]);
                        refreshLine(line_buf[0..len], cursor);
                    } else {
                        completed_dir_slash = false;
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
                    entry.name;
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

fn completeCommand(prefix: []const u8, word_start: usize) TabResult {
    const builtins = [_][]const u8{ "cd", "echo", "true", "false", "type", "pwd", "jobs", "fg", "bg", "dirs", "history", "j", "exit", "source", "set", "cmd", "key", "test", "shift", "break", "continue", "exec", "if", "unless", "for", "while", "until", "try" };

    cmd_match_count = 0;
    var common_len: usize = 0;

    for (builtins) |b| {
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

    const path_env = std.posix.getenv("PATH") orelse "";
    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir_path| {
        if (cmd_match_count >= 32) break;
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (std.mem.startsWith(u8, entry.name, prefix) and entry.name.len < 128) {
                if (cmd_match_count < 32) {
                    @memcpy(cmd_match_buf[cmd_match_count][0..entry.name.len], entry.name);
                    complete_list_buf[cmd_match_count] = cmd_match_buf[cmd_match_count][0..entry.name.len];
                    if (cmd_match_count == 0) common_len = entry.name.len else {
                        var cl: usize = 0;
                        while (cl < common_len and cl < entry.name.len and cmd_match_buf[0][cl] == entry.name[cl]) cl += 1;
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

    // Check environment variables
    if (var_prefix.len > 0) {
        const env = std.c.environ;
        var i: usize = 0;
        while (env[i]) |entry| : (i += 1) {
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
                    if (match_count < 32) complete_list_buf[match_count] = full;
                    match_count += 1;
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

fn showMathPreview(line: []const u8) bool {
    if (line.len < 2) return false;
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '=') return false;
    // Must have something after =
    const expr = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (expr.len == 0) return false;
    if (key_handler) |kh| {
        if (kh.eval_math) |eval_fn| {
            if (eval_fn(line)) |result| {
                writeAll("  \x1b[90m= ");
                writeAll(result);
                writeAll("\x1b[0m");
                return true;
            }
        }
    }
    return false;
}

const keywords = [_][]const u8{ "if", "unless", "else", "for", "in", "while", "until", "try", "and", "or", "not", "xor", "cmd", "key", "set", "test", "source", "exit", "exec", "break", "continue", "shift" };

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
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

    var lex = parser.BaseLexer.init(line);
    var pos: usize = 0;

    while (true) {
        const tok = lex.matchRules();
        const tok_start: usize = tok.pos;
        const tok_end: usize = @min(tok_start + tok.len, line.len);

        if (tok_start > pos) writeAll(line[pos..tok_start]);

        if (tok.cat == .eof) {
            if (pos < line.len) writeAll(line[pos..]);
            break;
        }

        const text = line[tok_start..tok_end];
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

fn historySearch(kh: KeyHandler) ?[]const u8 {
    const search_fn = kh.search orelse return null;
    var query_buf: [256]u8 = undefined;
    var qlen: usize = 0;
    var selected: usize = 0;
    var results: [][]const u8 = &.{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var first_draw = true;

    results = search_fn(alloc, "", 10);

    while (true) {
        if (first_draw) {
            writeAll("\n");
            first_draw = false;
        } else {
            writeAll("\r");
        }
        writeAll("\x1b[J");
        writeAll("\x1b[7m History Search: \x1b[0m ");
        writeAll(query_buf[0..qlen]);
        writeAll("\n");
        for (results, 0..) |cmd, i| {
            if (i == selected) writeAll("\x1b[7m") else writeAll("  ");
            writeAll(cmd);
            if (i == selected) writeAll("\x1b[0m");
            writeAll("\n");
        }
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

var palette_buf: [4096]u8 = undefined;

fn stablePaletteResult(r: PaletteResult) PaletteResult {
    const len = @min(r.text.len, palette_buf.len);
    @memcpy(palette_buf[0..len], r.text[0..len]);
    return .{ .text = palette_buf[0..len], .kind = r.kind };
}

fn paletteSearch(kh: KeyHandler) ?PaletteResult {
    const palette_fn = kh.palette orelse return null;
    var query_buf: [256]u8 = undefined;
    var qlen: usize = 0;
    var selected: usize = 0;
    var results: []PaletteResult = &.{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    results = palette_fn(alloc, "");
    var first_draw = true;

    while (true) {
        if (first_draw) {
            writeAll("\n");
            first_draw = false;
        } else {
            writeAll("\r");
        }
        writeAll("\x1b[J");
        writeAll("\x1b[7m Palette: \x1b[0m ");
        writeAll(query_buf[0..qlen]);
        writeAll("\n");
        for (results, 0..) |r, i| {
            if (i == selected) writeAll("\x1b[7m") else writeAll("  ");
            writeAll(r.text);
            if (i == selected) writeAll("\x1b[0m");
            const kind_str = switch (r.kind) {
                .history => "  \x1b[90m(history)\x1b[0m",
                .directory => "  \x1b[90m(dir)\x1b[0m",
                .command => "  \x1b[90m(cmd)\x1b[0m",
            };
            writeAll(kind_str);
            writeAll("\n");
        }
        var up_buf: [16]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "\x1b[{d}A", .{results.len + 1}) catch break;
        writeAll(up);
        var col_buf: [16]u8 = undefined;
        const col = std.fmt.bufPrint(&col_buf, "\r\x1b[{d}C", .{12 + qlen}) catch break;
        writeAll(col);

        var ch: [1]u8 = undefined;
        const n = posix.read(STDIN, &ch) catch break;
        if (n == 0) break;

        switch (ch[0]) {
            '\r', '\n' => {
                clearOverlay(results.len + 1);
                if (selected < results.len) return stablePaletteResult(results[selected]);
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
                    clearOverlay(results.len + 1);
                    return null;
                }
            },
            127, 8 => {
                if (qlen > 0) {
                    qlen -= 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = palette_fn(alloc, query_buf[0..qlen]);
                }
            },
            9 => {
                // Tab — paste to prompt (same as Enter for palette)
                clearOverlay(results.len + 1);
                if (selected < results.len) return stablePaletteResult(results[selected]);
                return null;
            },
            3 => {
                clearOverlay(results.len + 1);
                return null;
            },
            else => |byte| {
                if (byte >= 32 and byte < 127 and qlen < query_buf.len) {
                    query_buf[qlen] = byte;
                    qlen += 1;
                    selected = 0;
                    _ = arena.reset(.retain_capacity);
                    results = palette_fn(alloc, query_buf[0..qlen]);
                }
            },
        }
    }
    clearOverlay(results.len + 1);
    return null;
}

fn clearOverlay(lines: usize) void {
    _ = lines;
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
