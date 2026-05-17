//! carapace — completion delegation to carapace-bin.
//!
//! [carapace](https://github.com/carapace-sh/carapace-bin) is a multi-shell
//! completion binary covering ~1100 modern CLIs (git, docker, kubectl,
//! cargo, gh, terraform, ...). Slash uses it as the long-tail completion
//! ecosystem: when none of `src/completion.zig`'s hardcoded specs match
//! the typed command, this module is consulted before falling through to
//! generic path/filename completion.
//!
//! Wire protocol:
//!   carapace <command> nushell <argv...>
//!
//! The `nushell` shell-format is chosen because its output is plain JSON
//! (`[{"value": "...", "display": "...", "description": "..."}, ...]`),
//! which parses without bash-format quoting heuristics. The format is
//! shell-agnostic data; Slash does not depend on nushell itself.
//!
//! Discipline (per `AGENTS.md`/§14 and GPT-5.5 design review):
//!   - `null` return = carapace unavailable / failed / unknown command;
//!     caller falls through to other completion paths.
//!   - `[]` return = carapace returned authoritatively zero candidates;
//!     caller MUST NOT fall through (would inject garbage menus).
//!   - 250 ms timeout per Tab. 1 MiB output cap. Child runs in its own
//!     process group so grandchildren (git, docker, ...) are reaped on
//!     timeout/cap overrun.
//!   - The `carapace` binary path is cached for the session on first
//!     successful probe. A negative result is cached for only 5 seconds,
//!     so `brew install carapace` mid-session "just works" on the next
//!     Tab after the TTL elapses.

const std = @import("std");
const exec = @import("exec.zig");

pub const Allocator = std.mem.Allocator;

pub const Candidate = struct {
    /// The replacement text for the partial argument being completed.
    /// Often includes a trailing space when the completion is "final"
    /// (i.e., advances the user to the next argument).
    value: []const u8,
    /// What the menu displays. May equal `value` minus trailing space.
    display: []const u8,
    /// Optional tooltip-style description; carapace fills this for many
    /// candidates (e.g., git branch commit subject, command summary).
    description: ?[]const u8 = null,
};

const max_output_bytes: usize = 1 * 1024 * 1024;
const timeout_ms: u32 = 250;
const negative_cache_ttl_ms: i64 = 5_000;

// Process-lifetime cache for the carapace binary path. `path` is owned
// by `cache_allocator` and lives until process exit. `checked_at_ms`
// timestamps the last unsuccessful probe so a brief install gap doesn't
// permanently disable carapace for the rest of the session.
const ProbeState = enum { unknown, found, missing };
const Probe = struct {
    state: ProbeState = .unknown,
    path: ?[*:0]const u8 = null,
    checked_at_ms: i64 = 0,
};

// Slash's interactive loop is single-threaded; no mutex required. If a
// future async-completion path multi-threads this module, this is the
// place to add a `std.atomic.Mutex` and serialize `probe` access.
var probe: Probe = .{};
const cache_allocator: Allocator = std.heap.c_allocator;

/// Reset the lazy detection cache. Test-only hook; not called by the
/// REPL. Lets unit tests force a re-probe without process restart.
pub fn resetProbeCache() void {
    if (probe.path) |p| {
        const slice = std.mem.span(p);
        cache_allocator.free(slice);
    }
    probe = .{};
}

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Delegate argument completion for `command` (the carapace completer
/// name — typically `basename(argv[0])`) to carapace-bin. `argv` is the
/// command's argv as typed so far, including argv[0] and a final
/// (possibly empty) string for the partial argument under the cursor.
///
/// Returns:
///   - null  if carapace is unavailable, the command is unknown to it,
///           the helper times out, or any parse/spawn failure occurs.
///           The caller should fall through to its other completion
///           paths.
///   - slice if carapace responded successfully. The slice MAY BE EMPTY,
///           which means carapace knows this command and reports no
///           candidates at this position. The caller MUST treat an
///           empty slice as authoritative and NOT fall through.
///
/// Caller frees with `freeResult`.
pub fn complete(
    allocator: Allocator,
    command: []const u8,
    argv: []const []const u8,
) ?[]Candidate {
    if (command.len == 0) return null;
    const exe = resolveExe() orelse return null;

    // Carapace expects the completer name as a bare command (no path).
    // `command` from the caller is already basenamed via `basenameOf`.
    var argv_buf = std.ArrayList(?[*:0]const u8).empty;
    defer cleanupArgvBuf(allocator, &argv_buf);

    appendArg(allocator, &argv_buf, exe) catch return null;
    appendArg(allocator, &argv_buf, command) catch return null;
    appendArg(allocator, &argv_buf, "nushell") catch return null;
    for (argv) |a| appendArg(allocator, &argv_buf, a) catch return null;
    argv_buf.append(allocator, null) catch return null;

    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);

    var envp_buf = std.ArrayList(?[*:0]const u8).empty;
    defer envp_buf.deinit(allocator);
    var i: usize = 0;
    while (std.c.environ[i] != null) : (i += 1) {
        envp_buf.append(allocator, std.c.environ[i]) catch return null;
    }
    envp_buf.append(allocator, null) catch return null;
    const envp_z: [*:null]const ?[*:0]const u8 = @ptrCast(envp_buf.items.ptr);

    const captured = exec.spawnAndCapture(
        allocator,
        argv_z,
        envp_z,
        max_output_bytes,
        timeout_ms,
    ) catch return null;
    defer allocator.free(captured);

    // Empirically: carapace emits an empty stdout for commands it doesn't
    // have a spec for, and `[]` for commands it knows but with no matches
    // at this position. The two cases need different handling — unknown
    // commands fall through to other completion paths (so `mycmd <Tab>`
    // still gives filename completion), while empty-but-known is
    // authoritative (so `git zzzzz<Tab>` doesn't pollute the menu).
    var only_whitespace = true;
    for (captured) |c| if (!isJsonSpace(c)) {
        only_whitespace = false;
        break;
    };
    if (only_whitespace) return null;

    return parseNushellJson(allocator, captured) catch null;
}

pub fn freeResult(allocator: Allocator, candidates: []Candidate) void {
    for (candidates) |c| {
        allocator.free(c.value);
        allocator.free(c.display);
        if (c.description) |d| allocator.free(d);
    }
    allocator.free(candidates);
}

/// Return the basename of an executable path: `/usr/local/bin/docker`
/// → `docker`, `git` → `git`. Used by the caller to translate the typed
/// command into the carapace completer name.
pub fn basenameOf(command: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, command, '/')) |i| {
        return command[i + 1 ..];
    }
    return command;
}

// =============================================================================
// Internal helpers
// =============================================================================

fn appendArg(
    allocator: Allocator,
    buf: *std.ArrayList(?[*:0]const u8),
    text: []const u8,
) !void {
    const dup = try allocator.allocSentinel(u8, text.len, 0);
    @memcpy(dup[0..text.len], text);
    try buf.append(allocator, dup.ptr);
}

fn cleanupArgvBuf(allocator: Allocator, buf: *std.ArrayList(?[*:0]const u8)) void {
    // Free each NUL-terminated arg we appended. The carapace `exe`
    // path is the first entry; it was duped from cache_allocator-owned
    // memory, but `appendArg` re-duped from `allocator`. Free with
    // `allocator` to match.
    for (buf.items) |item_opt| {
        if (item_opt) |p| {
            const slice = std.mem.span(p);
            allocator.free(slice);
        }
    }
    buf.deinit(allocator);
}

fn resolveExe() ?[]const u8 {
    const now_ms = monotonicMs();

    switch (probe.state) {
        .found => {
            if (probe.path) |p| return std.mem.span(p);
            return null;
        },
        .missing => {
            if (now_ms - probe.checked_at_ms < negative_cache_ttl_ms) return null;
        },
        .unknown => {},
    }

    if (findOnPath(cache_allocator, "carapace")) |abs| {
        probe.state = .found;
        probe.path = abs.ptr;
        probe.checked_at_ms = now_ms;
        return abs;
    } else {
        probe.state = .missing;
        probe.path = null;
        probe.checked_at_ms = now_ms;
        return null;
    }
}

fn findOnPath(allocator: Allocator, name: []const u8) ?[:0]const u8 {
    const path_env_z = std.c.getenv("PATH") orelse return null;
    const path_env = std.mem.span(path_env_z);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |segment_raw| {
        const segment = if (segment_raw.len == 0) "." else segment_raw;
        const total = segment.len + 1 + name.len;
        const candidate = allocator.allocSentinel(u8, total, 0) catch continue;
        @memcpy(candidate[0..segment.len], segment);
        candidate[segment.len] = '/';
        @memcpy(candidate[segment.len + 1 ..][0..name.len], name);

        if (std.c.access(candidate.ptr, std.c.X_OK) == 0) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

// =============================================================================
// Nushell-format JSON parser
// =============================================================================

const NushellCandidate = struct {
    value: ?[]const u8 = null,
    display: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

fn parseNushellJson(allocator: Allocator, raw: []const u8) ![]Candidate {
    var trimmed_start: usize = 0;
    while (trimmed_start < raw.len and isJsonSpace(raw[trimmed_start])) : (trimmed_start += 1) {}
    var trimmed_end: usize = raw.len;
    while (trimmed_end > trimmed_start and isJsonSpace(raw[trimmed_end - 1])) : (trimmed_end -= 1) {}
    const trimmed = raw[trimmed_start..trimmed_end];

    if (trimmed.len == 0) return &[_]Candidate{};

    // Carapace sometimes emits a JSON object on error or `null`.
    // Both translate to "no candidates."
    if (trimmed[0] != '[') return &[_]Candidate{};

    var parsed = std.json.parseFromSlice(
        []NushellCandidate,
        allocator,
        trimmed,
        .{ .ignore_unknown_fields = true },
    ) catch return &[_]Candidate{};
    defer parsed.deinit();

    var out = try allocator.alloc(Candidate, parsed.value.len);
    var n_written: usize = 0;
    errdefer {
        for (out[0..n_written]) |c| {
            allocator.free(c.value);
            allocator.free(c.display);
            if (c.description) |d| allocator.free(d);
        }
        allocator.free(out);
    }

    for (parsed.value) |raw_c| {
        const value = raw_c.value orelse continue;
        const display_text = raw_c.display orelse stripTrailingSpace(value);
        const desc_text = raw_c.description;

        const v_owned = try allocator.dupe(u8, value);
        errdefer allocator.free(v_owned);
        const d_owned = try allocator.dupe(u8, display_text);
        errdefer allocator.free(d_owned);
        const x_owned: ?[]u8 = if (desc_text) |d| try allocator.dupe(u8, d) else null;

        out[n_written] = .{
            .value = v_owned,
            .display = d_owned,
            .description = x_owned,
        };
        n_written += 1;
    }

    // Shrink if some entries lacked a `value` field.
    if (n_written < out.len) {
        const final = try allocator.realloc(out, n_written);
        return final;
    }
    return out;
}

fn stripTrailingSpace(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') : (end -= 1) {}
    return s[0..end];
}

fn isJsonSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// =============================================================================
// Tests
// =============================================================================

test "basenameOf: bare command" {
    try std.testing.expectEqualStrings("git", basenameOf("git"));
}

test "basenameOf: abs path" {
    try std.testing.expectEqualStrings("docker", basenameOf("/usr/local/bin/docker"));
}

test "basenameOf: trailing slash treated as suffix" {
    try std.testing.expectEqualStrings("", basenameOf("/usr/bin/"));
}

test "stripTrailingSpace: leaves interior alone" {
    try std.testing.expectEqualStrings("a b", stripTrailingSpace("a b "));
    try std.testing.expectEqualStrings("a", stripTrailingSpace("a   "));
    try std.testing.expectEqualStrings("", stripTrailingSpace("   "));
}

test "parseNushellJson: empty array" {
    const out = try parseNushellJson(std.testing.allocator, "[]");
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseNushellJson: single candidate with display + description" {
    const raw =
        \\[{"value":"checkout ","display":"checkout","description":"Switch branches"}]
    ;
    const out = try parseNushellJson(std.testing.allocator, raw);
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("checkout ", out[0].value);
    try std.testing.expectEqualStrings("checkout", out[0].display);
    try std.testing.expectEqualStrings("Switch branches", out[0].description.?);
}

test "parseNushellJson: missing display falls back to value-minus-trailing-space" {
    const raw =
        \\[{"value":"checkout "}]
    ;
    const out = try parseNushellJson(std.testing.allocator, raw);
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("checkout", out[0].display);
    try std.testing.expect(out[0].description == null);
}

test "parseNushellJson: skips entries without a value field" {
    const raw =
        \\[{"display":"orphan"},{"value":"keep "}]
    ;
    const out = try parseNushellJson(std.testing.allocator, raw);
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("keep ", out[0].value);
}

test "parseNushellJson: tolerates unknown fields" {
    const raw =
        \\[{"value":"x ","display":"x","style":"bold","extra":42}]
    ;
    const out = try parseNushellJson(std.testing.allocator, raw);
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("x ", out[0].value);
}

test "parseNushellJson: object response (carapace error) collapses to empty" {
    const out = try parseNushellJson(std.testing.allocator, "{\"error\":\"unknown\"}");
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseNushellJson: garbage collapses to empty" {
    const out = try parseNushellJson(std.testing.allocator, "not json");
    defer freeResult(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
