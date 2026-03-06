//! Prompt — Format-string driven shell prompt
//!
//! Format escapes:
//!
//!   Colors
//!     %fg(#hex)   foreground color        %bg(#hex)   background color
//!     %r          reset all colors
//!
//!   Segments
//!     %>          Powerline arrow (U+E0B0)
//!     %$          prompt char: green $ if exit 0, red $ if non-zero
//!
//!   Data
//!     %t          time (HH:MM:SS)         %u          username
//!     %h          hostname (short)        %d          directory (~ abbreviated)
//!     %g          git branch + dirty      %e          exit code (non-zero only)
//!     %D          command duration (if > 1s)
//!
//!   Literal
//!     %%          literal %
//!
//!   Hex shorthand: #ba8c3f (6-digit), #f00 (3→6), #c (1→grayscale #cccccc)

const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const default_fmt =
    "%bg(#44556a)%fg(#c8d2dc) %t " ++
    "%bg(#5a7391)%fg(#44556a)%>" ++
    "%fg(#dce1eb) %u@%h " ++
    "%bg(#7891af)%fg(#5a7391)%>" ++
    "%fg(#f0f5fa) %d " ++
    "%r%fg(#7891af)%>" ++
    "%r ";

pub const Context = struct {
    last_exit: u8 = 0,
    duration_ms: u64 = 0,
};

var prompt_buf: [8192]u8 = undefined;

pub fn render(fmt: []const u8, ctx: Context) struct { str: []const u8, visible_len: usize } {
    const needs = scanSegments(fmt);

    var time_buf: [8]u8 = undefined;
    const time_str = if (needs.time) getTime(&time_buf) else "";
    const user = if (needs.user) (posix.getenv("USER") orelse "user") else "";
    var host_buf: [256]u8 = undefined;
    const host = if (needs.host) getHostname(&host_buf) else "";
    var cwd_buf: [4096]u8 = undefined;
    const cwd_raw = if (needs.dir or needs.git) (posix.getcwd(&cwd_buf) catch "?") else "";
    const home = if (needs.dir) (posix.getenv("HOME") orelse "") else "";
    var dir_buf: [4096]u8 = undefined;
    const dir = if (needs.dir) abbreviateHome(cwd_raw, home, &dir_buf) else "";
    var git_buf: [256]u8 = undefined;
    const git = if (needs.git) getGitInfo(&git_buf, cwd_raw) else "";
    var exit_buf: [4]u8 = undefined;
    const exit_str = if (needs.exit and ctx.last_exit != 0) std.fmt.bufPrint(&exit_buf, "{d}", .{ctx.last_exit}) catch "" else "";
    var dur_buf: [16]u8 = undefined;
    const dur_str = if (needs.duration) formatDuration(&dur_buf, ctx.duration_ms) else "";

    var out: usize = 0;
    var vis: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            switch (fmt[i + 1]) {
                'f' => {
                    if (parseFgBg(fmt, i, true)) |result| {
                        emit(&out, result.esc);
                        i = result.end;
                        continue;
                    }
                },
                'b' => {
                    if (parseFgBg(fmt, i, false)) |result| {
                        emit(&out, result.esc);
                        i = result.end;
                        continue;
                    }
                },
                'r' => { emit(&out, "\x1b[0m"); i += 2; continue; },
                '>' => { emit(&out, "\xee\x82\xb0"); vis += 1; i += 2; continue; },
                't' => { emitStr(&out, &vis, time_str); i += 2; continue; },
                'u' => { emitStr(&out, &vis, user); i += 2; continue; },
                'h' => { emitStr(&out, &vis, host); i += 2; continue; },
                'd' => { emitStr(&out, &vis, dir); i += 2; continue; },
                'g' => { emitStr(&out, &vis, git); i += 2; continue; },
                'e' => { emitStr(&out, &vis, exit_str); i += 2; continue; },
                'D' => { emitStr(&out, &vis, dur_str); i += 2; continue; },
                '$' => {
                    if (ctx.last_exit == 0)
                        emit(&out, "\x1b[32m$\x1b[0m")
                    else
                        emit(&out, "\x1b[31m$\x1b[0m");
                    vis += 1;
                    i += 2;
                    continue;
                },
                '%' => { emitByte(&out, &vis, '%'); i += 2; continue; },
                else => {},
            }
        }
        emitByte(&out, &vis, fmt[i]);
        i += 1;
    }

    return .{ .str = prompt_buf[0..out], .visible_len = vis };
}

const SegmentNeeds = struct {
    time: bool = false,
    user: bool = false,
    host: bool = false,
    dir: bool = false,
    git: bool = false,
    exit: bool = false,
    duration: bool = false,
};

fn scanSegments(fmt: []const u8) SegmentNeeds {
    var needs: SegmentNeeds = .{};
    var i: usize = 0;
    while (i + 1 < fmt.len) {
        if (fmt[i] == '%') {
            switch (fmt[i + 1]) {
                't' => needs.time = true,
                'u' => needs.user = true,
                'h' => needs.host = true,
                'd' => needs.dir = true,
                'g' => needs.git = true,
                'e' => needs.exit = true,
                'D' => needs.duration = true,
                '$' => needs.exit = true,
                else => {},
            }
            i += 2;
        } else {
            i += 1;
        }
    }
    return needs;
}

// --- output helpers ---

fn emit(out: *usize, s: []const u8) void {
    if (out.* + s.len > prompt_buf.len) return;
    @memcpy(prompt_buf[out.*..][0..s.len], s);
    out.* += s.len;
}

fn emitStr(out: *usize, vis: *usize, s: []const u8) void {
    emit(out, s);
    vis.* += s.len;
}

fn emitByte(out: *usize, vis: *usize, byte: u8) void {
    if (out.* < prompt_buf.len) {
        prompt_buf[out.*] = byte;
        out.* += 1;
        vis.* += 1;
    }
}

// --- %fg(#hex) / %bg(#hex) parser ---

const ColorResult = struct { esc: []const u8, end: usize };

var esc_buf: [64]u8 = undefined;

fn parseFgBg(fmt: []const u8, start: usize, is_fg: bool) ?ColorResult {
    const prefix = if (is_fg) "fg(" else "bg(";
    const after_pct = start + 1;
    if (after_pct + prefix.len > fmt.len) return null;
    if (!std.mem.eql(u8, fmt[after_pct .. after_pct + prefix.len], prefix)) return null;

    const open = after_pct + prefix.len;
    const close = std.mem.indexOfScalarPos(u8, fmt, open, ')') orelse return null;
    const color_str = fmt[open..close];

    const rgb = parseHex(color_str) orelse return null;
    const code: u8 = if (is_fg) 38 else 48;
    const esc = std.fmt.bufPrint(&esc_buf, "\x1b[{d};2;{d};{d};{d}m", .{
        code, rgb[0], rgb[1], rgb[2],
    }) catch return null;

    return .{ .esc = esc, .end = close + 1 };
}

fn parseHex(s: []const u8) ?[3]u8 {
    if (s.len == 0 or s[0] != '#') return null;
    const hex = s[1..];
    return switch (hex.len) {
        6 => .{ hex2(hex[0..2]), hex2(hex[2..4]), hex2(hex[4..6]) },
        3 => .{ hex1(hex[0]) * 17, hex1(hex[1]) * 17, hex1(hex[2]) * 17 },
        1 => .{ hex1(hex[0]) * 17, hex1(hex[0]) * 17, hex1(hex[0]) * 17 },
        else => null,
    };
}

fn hex2(pair: *const [2]u8) u8 {
    return (hex1(pair[0]) << 4) | hex1(pair[1]);
}

fn hex1(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0,
    };
}

// --- data providers ---

fn getTime(buf: *[8]u8) []const u8 {
    var now: c.time_t = c.time(null);
    const tm: *c.struct_tm = c.localtime(&now) orelse return "??:??:??";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u8, @intCast(tm.tm_hour)),
        @as(u8, @intCast(tm.tm_min)),
        @as(u8, @intCast(tm.tm_sec)),
    }) catch "??:??:??";
}

fn getHostname(buf: *[256]u8) []const u8 {
    const raw = c.gethostname(buf, buf.len);
    if (raw == 0) {
        const slice: []const u8 = buf;
        const end = std.mem.indexOfScalar(u8, slice, 0) orelse buf.len;
        const name = buf[0..end];
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
        return name;
    }
    return posix.getenv("HOSTNAME") orelse posix.getenv("HOST") orelse "localhost";
}

fn abbreviateHome(path: []const u8, home: []const u8, buf: *[4096]u8) []const u8 {
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        buf[0] = '~';
        const rest = path[home.len..];
        if (rest.len > 0 and 1 + rest.len <= buf.len) {
            @memcpy(buf[1 .. 1 + rest.len], rest);
            return buf[0 .. 1 + rest.len];
        }
        return "~";
    }
    return path;
}

/// Reads .git/HEAD to get branch name, walks up from cwd.
/// Returns "branch *" if dirty (index modified), "branch" if clean, "" if not a repo.
fn getGitInfo(buf: *[256]u8, cwd: []const u8) []const u8 {
    var path_buf: [4096]u8 = undefined;

    // Walk up directory tree to find .git
    var dir = cwd;
    while (true) {
        const head = openGitHead(&path_buf, dir) orelse {
            if (std.mem.lastIndexOfScalar(u8, dir, '/')) |sep| {
                if (sep == 0) break;
                dir = dir[0..sep];
                continue;
            }
            break;
        };
        defer head.close();

        var head_buf: [256]u8 = undefined;
        const n = head.read(&head_buf) catch return "";
        const content = std.mem.trimRight(u8, head_buf[0..n], "\n\r ");

        const ref_prefix = "ref: refs/heads/";
        const branch = if (std.mem.startsWith(u8, content, ref_prefix))
            content[ref_prefix.len..]
        else if (content.len >= 8)
            content[0..8] // detached HEAD — show short hash
        else
            return "";

        // Check for dirty state: .git/index mtime vs HEAD mtime
        const dirty = checkDirty(&path_buf, dir);
        const suffix: []const u8 = if (dirty) " *" else "";

        if (branch.len + suffix.len > buf.len) return "";
        @memcpy(buf[0..branch.len], branch);
        @memcpy(buf[branch.len..][0..suffix.len], suffix);
        return buf[0 .. branch.len + suffix.len];
    }
    return "";
}

fn openGitHead(path_buf: *[4096]u8, dir: []const u8) ?std.fs.File {
    const suffix = "/.git/HEAD";
    if (dir.len + suffix.len > path_buf.len) return null;
    @memcpy(path_buf[0..dir.len], dir);
    @memcpy(path_buf[dir.len..][0..suffix.len], suffix);
    return std.fs.openFileAbsolute(path_buf[0 .. dir.len + suffix.len], .{}) catch null;
}

/// Dirty check: index mtime differs from HEAD mtime indicates staged changes.
fn checkDirty(path_buf: *[4096]u8, git_dir: []const u8) bool {
    const head_suffix = "/.git/HEAD";
    if (git_dir.len + head_suffix.len > path_buf.len) return false;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    @memcpy(path_buf[git_dir.len..][0..head_suffix.len], head_suffix);
    const head_file = std.fs.openFileAbsolute(path_buf[0 .. git_dir.len + head_suffix.len], .{}) catch return false;
    defer head_file.close();
    const head_stat = head_file.stat() catch return false;

    const idx_suffix = "/.git/index";
    @memcpy(path_buf[git_dir.len..][0..idx_suffix.len], idx_suffix);
    const idx_file = std.fs.openFileAbsolute(path_buf[0 .. git_dir.len + idx_suffix.len], .{}) catch return false;
    defer idx_file.close();
    const idx_stat = idx_file.stat() catch return false;

    return idx_stat.mtime != head_stat.mtime;
}

fn formatDuration(buf: *[16]u8, ms: u64) []const u8 {
    if (ms < 1000) return "";
    if (ms < 60_000) {
        const secs = @as(f64, @floatFromInt(ms)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "";
    }
    const total_secs = ms / 1000;
    const mins = total_secs / 60;
    const secs = total_secs % 60;
    return std.fmt.bufPrint(buf, "{d}m{d}s", .{ mins, secs }) catch "";
}
