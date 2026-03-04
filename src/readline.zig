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

pub fn readLine(prompt: []const u8, history: *History) ?[]const u8 {
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
                    refreshLine(prompt, line_buf[0..len], cursor);
                }
            },
            27 => {
                var seq: [2]u8 = undefined;
                const n1 = posix.read(STDIN, seq[0..1]) catch return null;
                if (n1 == 0) continue;
                if (seq[0] != '[') continue;
                const n2 = posix.read(STDIN, seq[1..2]) catch return null;
                if (n2 == 0) continue;

                switch (seq[1]) {
                    'A' => {
                        if (hist_pos > 0) {
                            if (hist_pos == history.count) {
                                @memcpy(save_buf[0..len], line_buf[0..len]);
                                saved_len = len;
                            }
                            hist_pos -= 1;
                            const h = history.get(hist_pos);
                            len = @min(h.len, line_buf.len);
                            @memcpy(line_buf[0..len], h[0..len]);
                            cursor = len;
                            refreshLine(prompt, line_buf[0..len], cursor);
                        }
                    },
                    'B' => {
                        if (hist_pos < history.count) {
                            hist_pos += 1;
                            if (hist_pos == history.count) {
                                len = saved_len;
                                @memcpy(line_buf[0..len], save_buf[0..len]);
                            } else {
                                const h = history.get(hist_pos);
                                len = @min(h.len, line_buf.len);
                                @memcpy(line_buf[0..len], h[0..len]);
                            }
                            cursor = len;
                            refreshLine(prompt, line_buf[0..len], cursor);
                        }
                    },
                    'C' => {
                        if (cursor < len) {
                            cursor += 1;
                            writeAll("\x1b[C");
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
                        refreshLine(prompt, line_buf[0..len], cursor);
                    },
                    'F' => {
                        cursor = len;
                        refreshLine(prompt, line_buf[0..len], cursor);
                    },
                    '3' => {
                        var extra: [1]u8 = undefined;
                        _ = posix.read(STDIN, &extra) catch {};
                        if (extra[0] == '~' and cursor < len) {
                            std.mem.copyForwards(u8, line_buf[cursor..], line_buf[cursor + 1 .. len]);
                            len -= 1;
                            refreshLine(prompt, line_buf[0..len], cursor);
                        }
                    },
                    else => {},
                }
            },
            1 => {
                cursor = 0;
                refreshLine(prompt, line_buf[0..len], cursor);
            },
            5 => {
                cursor = len;
                refreshLine(prompt, line_buf[0..len], cursor);
            },
            11 => {
                len = cursor;
                refreshLine(prompt, line_buf[0..len], cursor);
            },
            21 => {
                std.mem.copyForwards(u8, line_buf[0..], line_buf[cursor..len]);
                len -= cursor;
                cursor = 0;
                refreshLine(prompt, line_buf[0..len], cursor);
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
                        if (cursor == len) {
                            const s: [1]u8 = .{ch};
                            writeAll(&s);
                        } else {
                            refreshLine(prompt, line_buf[0..len], cursor);
                        }
                    }
                }
            },
        }
    }
}

fn refreshLine(prompt: []const u8, line: []const u8, cursor: usize) void {
    writeAll("\r\x1b[K");
    writeAll(prompt);
    writeAll(line);
    const total = prompt.len + cursor;
    var move_buf: [32]u8 = undefined;
    const move = std.fmt.bufPrint(&move_buf, "\r\x1b[{d}C", .{total}) catch return;
    writeAll(move);
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
