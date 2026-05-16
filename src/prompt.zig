//! prompt — declarative prompt rendering for the interactive REPL.
//!
//! Providers read shell state (cwd, env, jobs, git metadata) and emit
//! prompt fragments into a fixed-buffer writer. Presets compose
//! providers into named layouts (`default`, `rich`, `minimal`).
//!
//! Selection (in priority order):
//!
//!   - `$PROMPT` — when set, the existing format-template path in
//!     `repl.zig` wins; this module is not consulted.
//!   - `$SLASH_PROMPT` — chooses one of the named presets below.
//!   - Otherwise: `default` (cwd + sigil; the same prompt slash
//!     shipped before this module landed). Existing users see no
//!     change unless they opt in.
//!
//! Presets:
//!
//!   - `default` — `cwd $ ` (or `cwd # ` for root). Backward-compatible
//!     baseline; no surprise for users without `$PROMPT`.
//!   - `rich`    — venv + remote-user + cwd + git branch + job count
//!     + sigil. Opt in via `$SLASH_PROMPT=rich`.
//!   - `minimal` — just the sigil. For users who prefer a single ` $ `.
//!
//! PLAN §12: providers must be bounded and fast. They never evaluate
//! slash code, never spawn child processes, and degrade silently to
//! emitting nothing on read errors so the user always sees a usable
//! prompt. The git provider reads `.git/HEAD` directly rather than
//! invoking `git`; the jobs provider reads from the in-memory
//! `JobTable`; venv and SSH detection are env-var lookups.

const std = @import("std");
const session_mod = @import("session.zig");

extern fn gethostname(buf: [*]u8, sz: usize) c_int;

pub const Preset = enum { default, rich, minimal };

const Provider = *const fn (w: *std.Io.Writer, session: *session_mod.Session) void;

/// Render `preset` into `buf` and return the written slice. Borrows
/// the buffer for the duration of the call; the result is valid until
/// the next render with the same buffer.
pub fn render(buf: []u8, session: *session_mod.Session, preset: Preset) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    const providers: []const Provider = switch (preset) {
        .default => &default_providers,
        .rich => &rich_providers,
        .minimal => &minimal_providers,
    };
    for (providers) |p| p(&w, session);
    return w.buffered();
}

/// Resolve which preset to render for the current session. Checks the
/// session var store first (for `export SLASH_PROMPT=...` set by
/// `~/.slashrc`), then the inherited environment.
pub fn selectPreset(session: *session_mod.Session) Preset {
    if (session.vars.get("SLASH_PROMPT")) |v| switch (v.value) {
        .scalar => |s| if (parsePreset(s)) |p| return p,
        else => {},
    };
    if (std.c.getenv("SLASH_PROMPT")) |env| {
        if (parsePreset(std.mem.span(env))) |p| return p;
    }
    return .default;
}

fn parsePreset(s: []const u8) ?Preset {
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "rich")) return .rich;
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    return null;
}

// =============================================================================
// Presets
// =============================================================================

const default_providers = [_]Provider{
    writeCwd,
    writeSigil,
};

const rich_providers = [_]Provider{
    writeVenv,
    writeRemoteUser,
    writeCwd,
    writeGit,
    writeJobs,
    writeSigil,
};

const minimal_providers = [_]Provider{
    writeSigil,
};

// =============================================================================
// Providers
// =============================================================================

/// Cwd, home-collapsed (`~/Code/slash`). Falls back to `?` on
/// `getcwd` failure so the user always sees something.
fn writeCwd(w: *std.Io.Writer, session: *session_mod.Session) void {
    _ = session;
    var cwd_buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&cwd_buf, cwd_buf.len);
    if (got == null) {
        w.writeAll("?") catch {};
        return;
    }
    const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
    var cwd: []const u8 = cwd_buf[0..len];

    if (std.c.getenv("HOME")) |home_env| {
        const home = std.mem.span(home_env);
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            w.writeAll("~") catch return;
            cwd = cwd[home.len..];
        }
    }
    w.writeAll(cwd) catch {};
}

/// `$ ` for normal users, `$#` for root. Always emits a leading space
/// so the cursor lands one column past the sigil regardless of which
/// providers ran before.
fn writeSigil(w: *std.Io.Writer, session: *session_mod.Session) void {
    _ = session;
    const ch: u8 = if (std.c.getuid() == 0) '#' else '$';
    w.writeAll(" ") catch {};
    w.writeByte(ch) catch {};
    w.writeAll(" ") catch {};
}

/// `(venv-name) ` when `$VIRTUAL_ENV` is set. Uses the env var's
/// basename — that matches Python's own venv-activation prompt.
/// Trailing slashes on `$VIRTUAL_ENV` are tolerated (e.g.
/// `/opt/myenv/` still surfaces as `(myenv)`).
fn writeVenv(w: *std.Io.Writer, session: *session_mod.Session) void {
    _ = session;
    const venv_env = std.c.getenv("VIRTUAL_ENV") orelse return;
    var trimmed: []const u8 = std.mem.span(venv_env);
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return;
    const base = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    if (base.len == 0) return;
    w.print("({s}) ", .{base}) catch {};
}

/// `user@host:` when the session looks remote (`$SSH_TTY` or
/// `$SSH_CONNECTION` set). Local sessions get nothing — there is
/// nothing useful to say.
fn writeRemoteUser(w: *std.Io.Writer, session: *session_mod.Session) void {
    _ = session;
    if (std.c.getenv("SSH_TTY") == null and std.c.getenv("SSH_CONNECTION") == null) return;

    const user = userName();
    var hostbuf: [256]u8 = undefined;
    if (gethostname(&hostbuf, hostbuf.len) != 0) return;
    const host_z: [*:0]const u8 = @ptrCast(&hostbuf);
    const host_full = std.mem.span(host_z);
    const dot = std.mem.indexOfScalar(u8, host_full, '.');
    const host = if (dot) |d| host_full[0..d] else host_full;
    w.print("{s}@{s}:", .{ user, host }) catch {};
}

fn userName() []const u8 {
    if (std.c.getenv("USER")) |u| return std.mem.span(u);
    if (std.c.getenv("LOGNAME")) |u| return std.mem.span(u);
    return "?";
}

/// ` (branch)` when the cwd is inside a git working tree. Walks up at
/// most 32 directories looking for a directory `.git/HEAD` and reads
/// up to 256 bytes. A `ref: refs/heads/X` body becomes the branch
/// name; a detached HEAD shows the first 7 chars of the commit SHA.
/// `.git` files (worktree / submodule pointers) silently render no
/// branch — the indirection cost would dwarf the value of a label.
fn writeGit(w: *std.Io.Writer, session: *session_mod.Session) void {
    _ = session;
    var cwd_buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&cwd_buf, cwd_buf.len);
    if (got == null) return;
    const cwd_len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
    var dir: []const u8 = cwd_buf[0..cwd_len];

    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        var path_buf: [4096]u8 = undefined;
        const head_path = std.fmt.bufPrintZ(&path_buf, "{s}/.git/HEAD", .{dir}) catch return;
        const fd = std.c.open(
            head_path.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            @as(std.c.mode_t, 0),
        );
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            writeGitBranch(w, fd);
            return;
        }
        if (dir.len <= 1) return; // reached root
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return;
        dir = if (slash == 0) dir[0..1] else dir[0..slash];
    }
}

fn writeGitBranch(w: *std.Io.Writer, fd: c_int) void {
    var head_buf: [256]u8 = undefined;
    const n = std.c.read(fd, &head_buf, head_buf.len);
    if (n <= 0) return;
    const head: []const u8 = head_buf[0..@intCast(n)];
    const trimmed = std.mem.trim(u8, head, " \r\n\t");
    const ref_prefix = "ref: refs/heads/";
    const branch: []const u8 = if (std.mem.startsWith(u8, trimmed, ref_prefix))
        trimmed[ref_prefix.len..]
    else if (trimmed.len >= 7)
        trimmed[0..7]
    else
        trimmed;
    if (branch.len == 0) return;
    w.print(" ({s})", .{branch}) catch {};
}

/// ` [Nj]` when N is the count of jobs that are either stopped or
/// detached and still alive. Hidden when N is zero so the prompt
/// stays quiet during normal interactive use.
fn writeJobs(w: *std.Io.Writer, session: *session_mod.Session) void {
    var count: usize = 0;
    for (session.jobs.list()) |j| {
        if (j.processes.len == 0) continue;
        switch (j.state) {
            .stopped => count += 1,
            .running, .pending => if (j.detached) {
                count += 1;
            },
            .done => {},
        }
    }
    if (count == 0) return;
    w.print(" [{d}j]", .{count}) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "prompt: parsePreset round-trips known names" {
    try testing.expectEqual(Preset.default, parsePreset("default").?);
    try testing.expectEqual(Preset.rich, parsePreset("rich").?);
    try testing.expectEqual(Preset.minimal, parsePreset("minimal").?);
    try testing.expect(parsePreset("plain") == null);
    try testing.expect(parsePreset("") == null);
}

test "prompt: minimal preset renders just the sigil" {
    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var buf: [128]u8 = undefined;
    const out = render(&buf, &s, .minimal);
    try testing.expectEqualStrings(if (std.c.getuid() == 0) " # " else " $ ", out);
}

test "prompt: default preset emits cwd then sigil" {
    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var buf: [4096]u8 = undefined;
    const out = render(&buf, &s, .default);
    try testing.expect(std.mem.endsWith(u8, out, " $ ") or std.mem.endsWith(u8, out, " # "));
    try testing.expect(out.len > " $ ".len);
    // Default must NOT include rich-only fragments — backward compat.
    try testing.expect(!std.mem.startsWith(u8, out, "("));
}

test "prompt: rich preset includes venv basename when VIRTUAL_ENV is set" {
    _ = setenv("VIRTUAL_ENV", "/tmp/slash-prompt-test/myenv", 1);
    defer _ = unsetenv("VIRTUAL_ENV");

    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var buf: [4096]u8 = undefined;
    const out = render(&buf, &s, .rich);
    try testing.expect(std.mem.startsWith(u8, out, "(myenv) "));
}

test "prompt: rich preset tolerates trailing slash on VIRTUAL_ENV" {
    _ = setenv("VIRTUAL_ENV", "/tmp/slash-prompt-test/myenv/", 1);
    defer _ = unsetenv("VIRTUAL_ENV");

    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var buf: [4096]u8 = undefined;
    const out = render(&buf, &s, .rich);
    try testing.expect(std.mem.startsWith(u8, out, "(myenv) "));
}

test "prompt: rich preset omits venv when VIRTUAL_ENV unset" {
    _ = unsetenv("VIRTUAL_ENV");
    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var buf: [4096]u8 = undefined;
    const out = render(&buf, &s, .rich);
    try testing.expect(!std.mem.startsWith(u8, out, "("));
}

test "prompt: selectPreset honors SLASH_PROMPT env" {
    _ = setenv("SLASH_PROMPT", "minimal", 1);
    defer _ = unsetenv("SLASH_PROMPT");
    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    try testing.expectEqual(Preset.minimal, selectPreset(&s));
}

test "prompt: selectPreset falls through to default for unknown values" {
    _ = setenv("SLASH_PROMPT", "fancy", 1);
    defer _ = unsetenv("SLASH_PROMPT");
    var s = try session_mod.Session.init(testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    try testing.expectEqual(Preset.default, selectPreset(&s));
}
