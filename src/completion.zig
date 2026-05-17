//! Slash-side tab completion specs and providers.
//!
//! Zigline owns the menu and buffer mutation. This module answers one
//! editor-time question: at this cursor position, which bounded candidates
//! clarify the command the user is typing?

const std = @import("std");
const parser = @import("parser.zig");
const session_mod = @import("session.zig");
const slash = @import("slash.zig");
const zigline = @import("zigline");
const stat = @import("stat.zig");

pub const Allocator = std.mem.Allocator;

pub const Request = struct {
    session: *session_mod.Session,
    buffer: []const u8,
    cursor_byte: usize,
};

const CandidateList = std.ArrayListUnmanaged(zigline.Candidate);

const QuoteMode = enum { none, single, double };

const WordContext = struct {
    replacement_start: usize,
    replacement_end: usize,
    prefix: []const u8,
    quote: QuoteMode,
    command_position: bool,
    command_name: ?[]const u8,
    arg_index: usize,
};

const CandidateSpec = struct {
    insert: []const u8,
    display: ?[]const u8 = null,
    kind: zigline.CandidateKind = .plain,
    append: ?u8 = null,
};

pub fn complete(allocator: Allocator, req: Request) !zigline.CompletionResult {
    const ctx = identifyContext(req.buffer, req.cursor_byte);
    var out: CandidateList = .empty;
    errdefer {
        for (out.items) |c| {
            allocator.free(c.insert);
            if (c.display) |d| allocator.free(d);
            if (c.description) |d| allocator.free(d);
        }
        out.deinit(allocator);
    }

    if (ctx.command_position) {
        try gatherCommandCandidates(allocator, req.session, ctx, &out);
    } else if (ctx.command_name) |name| {
        try gatherArgumentCandidates(allocator, req.session, name, req.buffer, ctx, &out);
    } else {
        try gatherPathCandidates(allocator, ctx, &out, .any);
    }

    sortCandidates(out.items);
    dedupeCandidates(allocator, &out);

    return .{
        .replacement_start = ctx.replacement_start,
        .replacement_end = ctx.replacement_end,
        .candidates = try out.toOwnedSlice(allocator),
    };
}

pub fn freeCandidates(allocator: Allocator, candidates: []zigline.Candidate) void {
    for (candidates) |c| {
        allocator.free(c.insert);
        if (c.display) |d| allocator.free(d);
        if (c.description) |d| allocator.free(d);
    }
    allocator.free(candidates);
}

fn identifyContext(buffer: []const u8, cursor_byte_raw: usize) WordContext {
    const cursor_byte = @min(cursor_byte_raw, buffer.len);
    var at_command_pos = true;
    var command_name: ?[]const u8 = null;
    var arg_index: usize = 0;

    var lex = parser.BaseLexer.init(buffer);
    while (true) {
        const tok = lex.next();
        if (tok.cat == .eof) break;

        const start: usize = @intCast(tok.pos);
        const end_unclamped = start + @as(usize, @intCast(tok.len));
        const end = @min(buffer.len, end_unclamped);
        if (start > cursor_byte) break;

        if (cursor_byte >= start and cursor_byte <= end and isWordToken(tok.cat)) {
            return contextInsideToken(buffer, cursor_byte, start, end, tok.cat, at_command_pos, command_name, arg_index);
        }

        if (end > cursor_byte) break;
        updateState(buffer[start..end], tok.cat, &at_command_pos, &command_name, &arg_index);
    }

    return .{
        .replacement_start = cursor_byte,
        .replacement_end = cursor_byte,
        .prefix = buffer[cursor_byte..cursor_byte],
        .quote = .none,
        .command_position = at_command_pos,
        .command_name = command_name,
        .arg_index = arg_index,
    };
}

fn contextInsideToken(
    buffer: []const u8,
    cursor_byte: usize,
    start: usize,
    end: usize,
    cat: parser.TokenCat,
    at_command_pos: bool,
    command_name: ?[]const u8,
    arg_index: usize,
) WordContext {
    var replacement_start = start;
    var quote: QuoteMode = .none;
    if ((cat == .string_sq or cat == .string_dq) and end > start and cursor_byte > start) {
        replacement_start = start + 1;
        quote = if (cat == .string_sq) .single else .double;
    } else if (start > 0 and buffer[start - 1] == '-' and (start == 1 or isAsciiSpace(buffer[start - 2]))) {
        replacement_start = start - 1;
    }
    return .{
        .replacement_start = replacement_start,
        .replacement_end = cursor_byte,
        .prefix = buffer[replacement_start..cursor_byte],
        .quote = quote,
        .command_position = at_command_pos,
        .command_name = command_name,
        .arg_index = arg_index,
    };
}

fn updateState(
    text: []const u8,
    cat: parser.TokenCat,
    at_command_pos: *bool,
    command_name: *?[]const u8,
    arg_index: *usize,
) void {
    if (cat == .ident) {
        if (slash.keywordAs(text) != null) {
            if (keywordTakesNameSlot(text)) {
                command_name.* = text;
                arg_index.* = 0;
                at_command_pos.* = false;
            } else {
                command_name.* = null;
                arg_index.* = 0;
                at_command_pos.* = true;
            }
            return;
        }
    }

    if (isWordToken(cat)) {
        if (at_command_pos.*) {
            command_name.* = text;
            arg_index.* = 0;
            at_command_pos.* = false;
        } else {
            arg_index.* += 1;
        }
        return;
    }

    if (cat == .name_eq) return;
    if (isCommandStarter(cat)) {
        command_name.* = null;
        arg_index.* = 0;
        at_command_pos.* = true;
    } else {
        at_command_pos.* = false;
    }
}

fn gatherCommandCandidates(
    allocator: Allocator,
    session: *session_mod.Session,
    ctx: WordContext,
    out: *CandidateList,
) !void {
    const specials = [_][]const u8{ "source", ".", "exec", "command" };
    for (specials) |name| try appendIfMatch(allocator, out, ctx, .{ .insert = name, .kind = .command, .append = ' ' });

    var bit = session.builtins.table.iterator();
    while (bit.next()) |e| {
        try appendIfMatch(allocator, out, ctx, .{ .insert = e.key_ptr.*, .kind = .command, .append = ' ' });
    }

    var dit = session.defs.table.keyIterator();
    while (dit.next()) |name| {
        try appendIfMatch(allocator, out, ctx, .{ .insert = name.*, .kind = .command, .append = ' ' });
    }

    if (session.strs.sortedNames(allocator)) |str_names| {
        defer allocator.free(str_names);
        for (str_names) |name| {
            try appendIfMatch(allocator, out, ctx, .{ .insert = name, .kind = .command, .append = ' ' });
        }
    } else |_| {
        // Completion is advisory; an allocation miss in one provider
        // should not suppress the rest of the candidate set.
    }

    try gatherPathCommands(allocator, ctx, out);
}

fn gatherArgumentCandidates(
    allocator: Allocator,
    session: *session_mod.Session,
    command_name: []const u8,
    buffer: []const u8,
    ctx: WordContext,
    out: *CandidateList,
) !void {
    if (std.mem.eql(u8, command_name, "cd")) {
        return gatherPathCandidates(allocator, ctx, out, .directories);
    }
    if (std.mem.eql(u8, command_name, "git")) {
        return gatherStatic(allocator, ctx, out, &git_subcommands, .plain, ' ');
    }
    if (std.mem.eql(u8, command_name, "ssh")) {
        return gatherStatic(allocator, ctx, out, &ssh_starters, .plain, ' ');
    }
    if (std.mem.eql(u8, command_name, "fg") or std.mem.eql(u8, command_name, "bg")) {
        return gatherJobSpecs(allocator, session, ctx, out);
    }
    if (std.mem.eql(u8, command_name, "kill")) {
        if (ctx.prefix.len > 0 and ctx.prefix[0] == '-') {
            return gatherSignals(allocator, ctx, out);
        }
        try gatherJobSpecs(allocator, session, ctx, out);
        return;
    }
    if (std.mem.eql(u8, command_name, "str")) {
        if (ctx.arg_index > 0 and std.mem.eql(u8, previousWhitespaceWord(buffer, ctx.replacement_start) orelse "", "-e")) {
            return gatherStrNames(allocator, session, ctx, out);
        }
        if (ctx.arg_index <= 1 and std.mem.eql(u8, ctx.prefix, "-")) {
            return appendIfMatch(allocator, out, ctx, .{ .insert = "-e", .append = ' ' });
        }
        return;
    }
    if (std.mem.eql(u8, command_name, "cmd")) {
        return gatherDefNames(allocator, session, ctx, out);
    }
    if (std.mem.eql(u8, command_name, "for") or std.mem.eql(u8, command_name, "match")) {
        return;
    }
    try gatherPathCandidates(allocator, ctx, out, .any);
}

fn previousWhitespaceWord(buffer: []const u8, cursor_byte_raw: usize) ?[]const u8 {
    var i = @min(cursor_byte_raw, buffer.len);
    while (i > 0 and isAsciiSpace(buffer[i - 1])) i -= 1;
    if (i == 0) return null;
    const end = i;
    while (i > 0 and !isAsciiSpace(buffer[i - 1])) i -= 1;
    return buffer[i..end];
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

const git_subcommands = [_][]const u8{
    "add",    "bisect", "branch", "checkout", "clone", "commit",
    "diff",   "fetch",  "grep",   "init",     "log",   "merge",
    "pull",   "push",   "rebase", "remote",   "reset", "restore",
    "status", "switch", "tag",
};

const ssh_starters = [_][]const u8{
    "-4", "-6", "-A", "-a", "-C", "-f", "-i", "-l", "-N", "-p", "-T", "-v",
};

const signal_names = [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",  "TRAP", "ABRT", "BUS",
    "FPE",  "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM",
    "TERM", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "CHLD",
};

fn gatherStatic(
    allocator: Allocator,
    ctx: WordContext,
    out: *CandidateList,
    values: []const []const u8,
    kind: zigline.CandidateKind,
    append: ?u8,
) !void {
    for (values) |v| try appendIfMatch(allocator, out, ctx, .{ .insert = v, .kind = kind, .append = append });
}

fn gatherSignals(allocator: Allocator, ctx: WordContext, out: *CandidateList) !void {
    for (signal_names) |name| {
        const dashed = try std.fmt.allocPrint(allocator, "-{s}", .{name});
        defer allocator.free(dashed);
        try appendIfMatch(allocator, out, ctx, .{ .insert = dashed, .append = ' ' });
    }
}

fn gatherStrNames(allocator: Allocator, session: *session_mod.Session, ctx: WordContext, out: *CandidateList) !void {
    const names = try session.strs.sortedNames(allocator);
    defer allocator.free(names);
    for (names) |name| try appendIfMatch(allocator, out, ctx, .{ .insert = name, .append = ' ' });
}

fn gatherDefNames(allocator: Allocator, session: *session_mod.Session, ctx: WordContext, out: *CandidateList) !void {
    var it = session.defs.table.keyIterator();
    while (it.next()) |name| try appendIfMatch(allocator, out, ctx, .{ .insert = name.*, .append = ' ' });
}

fn gatherJobSpecs(allocator: Allocator, session: *session_mod.Session, ctx: WordContext, out: *CandidateList) !void {
    for (session.jobs.list()) |j| {
        if (j.processes.len == 0) continue;
        switch (j.state) {
            .done => continue,
            else => {},
        }
        const insert = try std.fmt.allocPrint(allocator, "%{d}", .{j.id});
        defer allocator.free(insert);
        const display = if (j.command_text) |cmd|
            try std.fmt.allocPrint(allocator, "%{d} {s}", .{ j.id, cmd })
        else
            try std.fmt.allocPrint(allocator, "%{d}", .{j.id});
        defer allocator.free(display);
        try appendIfMatch(allocator, out, ctx, .{ .insert = insert, .display = display, .append = ' ' });
    }
}

const PathMode = enum { any, directories };

fn gatherPathCandidates(
    allocator: Allocator,
    ctx: WordContext,
    out: *CandidateList,
    mode: PathMode,
) !void {
    const prefix = ctx.prefix;
    const slash_idx = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_part: []const u8 = if (slash_idx) |i| prefix[0 .. i + 1] else "";
    const base_part: []const u8 = if (slash_idx) |i| prefix[i + 1 ..] else prefix;
    const dir_path: []const u8 = if (dir_part.len == 0) "." else dir_part;
    try enumerateDir(allocator, dir_path, dir_part, base_part, ctx, out, mode, false);
}

fn gatherPathCommands(allocator: Allocator, ctx: WordContext, out: *CandidateList) !void {
    const path_env = std.c.getenv("PATH") orelse return;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        try enumerateDir(allocator, dir, "", ctx.prefix, ctx, out, .any, true);
    }
}

fn enumerateDir(
    allocator: Allocator,
    dir_path: []const u8,
    dir_part: []const u8,
    base_part: []const u8,
    ctx: WordContext,
    out: *CandidateList,
    mode: PathMode,
    require_executable: bool,
) !void {
    var dir_buf: [4096]u8 = undefined;
    if (dir_path.len >= dir_buf.len) return;
    @memcpy(dir_buf[0..dir_path.len], dir_path);
    dir_buf[dir_path.len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(&dir_buf);

    const dirp = std.c.opendir(dir_z) orelse return;
    defer _ = std.c.closedir(dirp);

    while (true) {
        const ent = std.c.readdir(dirp) orelse break;
        const name = direntName(ent);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name[0] == '.' and (base_part.len == 0 or base_part[0] != '.')) continue;
        if (!std.mem.startsWith(u8, name, base_part)) continue;

        var full_buf: [8192]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}\x00", .{ dir_path, name }) catch continue;
        const full_z: [*:0]const u8 = @ptrCast(full.ptr);
        // Portable kind check; statx on Linux + fstatat on macOS.
        const info_opt = stat.statPath(full_z);
        const is_dir = if (info_opt) |info| info.kind == .directory else false;

        if (mode == .directories and !is_dir) continue;
        if (require_executable and std.c.access(full_z, std.c.X_OK) != 0) continue;

        const raw_insert = if (dir_part.len == 0)
            name
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_part, name });
        defer if (dir_part.len != 0) allocator.free(raw_insert);

        const insert = try quotePathCandidate(allocator, ctx, raw_insert);
        defer allocator.free(insert);

        try appendCandidate(allocator, out, .{
            .insert = insert,
            .kind = if (require_executable) .command else if (is_dir) .directory else .file,
            .append = if (is_dir) '/' else if (require_executable) ' ' else null,
        });
    }
}

fn appendIfMatch(
    allocator: Allocator,
    out: *CandidateList,
    ctx: WordContext,
    spec: CandidateSpec,
) !void {
    if (!std.mem.startsWith(u8, spec.insert, ctx.prefix)) return;
    try appendCandidate(allocator, out, spec);
}

fn appendCandidate(
    allocator: Allocator,
    out: *CandidateList,
    spec: CandidateSpec,
) !void {
    try out.append(allocator, .{
        .insert = try allocator.dupe(u8, spec.insert),
        .display = if (spec.display) |d| try allocator.dupe(u8, d) else null,
        .description = null,
        .kind = spec.kind,
        .append = spec.append,
    });
}

fn quotePathCandidate(allocator: Allocator, ctx: WordContext, raw: []const u8) ![]u8 {
    return switch (ctx.quote) {
        .none => try escapeBarePath(allocator, raw),
        .double => try escapeDoubleQuotedPath(allocator, raw),
        .single => try escapeSingleQuotedPath(allocator, raw),
    };
}

fn escapeBarePath(allocator: Allocator, raw: []const u8) ![]u8 {
    var extra: usize = 0;
    for (raw) |c| {
        if (needsBareEscape(c)) extra += 1;
    }
    var out = try allocator.alloc(u8, raw.len + extra);
    var w: usize = 0;
    for (raw) |c| {
        if (needsBareEscape(c)) {
            out[w] = '\\';
            w += 1;
        }
        out[w] = c;
        w += 1;
    }
    return out;
}

fn escapeDoubleQuotedPath(allocator: Allocator, raw: []const u8) ![]u8 {
    var extra: usize = 0;
    for (raw) |c| {
        if (c == '\\' or c == '"' or c == '$') extra += 1;
    }
    var out = try allocator.alloc(u8, raw.len + extra);
    var w: usize = 0;
    for (raw) |c| {
        if (c == '\\' or c == '"' or c == '$') {
            out[w] = '\\';
            w += 1;
        }
        out[w] = c;
        w += 1;
    }
    return out;
}

fn escapeSingleQuotedPath(allocator: Allocator, raw: []const u8) ![]u8 {
    var extra: usize = 0;
    for (raw) |c| {
        if (c == '\'') extra += 1;
    }
    var out = try allocator.alloc(u8, raw.len + extra);
    var w: usize = 0;
    for (raw) |c| {
        out[w] = c;
        w += 1;
        if (c == '\'') {
            out[w] = '\'';
            w += 1;
        }
    }
    return out;
}

fn needsBareEscape(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\\', '\'', '"', '$', '&', '|', ';', '<', '>', '(', ')', '{', '}', '[', ']', '*', '?', '!' => true,
        else => false,
    };
}

fn sortCandidates(items: []zigline.Candidate) void {
    std.mem.sort(zigline.Candidate, items, {}, lessCandidate);
}

fn lessCandidate(_: void, a: zigline.Candidate, b: zigline.Candidate) bool {
    return std.mem.order(u8, a.insert, b.insert) == .lt;
}

fn dedupeCandidates(allocator: Allocator, out: *CandidateList) void {
    if (out.items.len < 2) return;
    var write: usize = 1;
    var i: usize = 1;
    while (i < out.items.len) : (i += 1) {
        if (std.mem.eql(u8, out.items[i].insert, out.items[write - 1].insert)) {
            allocator.free(out.items[i].insert);
            if (out.items[i].display) |d| allocator.free(d);
            if (out.items[i].description) |d| allocator.free(d);
            continue;
        }
        out.items[write] = out.items[i];
        write += 1;
    }
    out.shrinkRetainingCapacity(write);
}

fn isWordToken(cat: parser.TokenCat) bool {
    return switch (cat) {
        .ident, .integer, .string_sq, .string_dq, .variable, .var_braced, .err => true,
        else => false,
    };
}

fn isCommandStarter(cat: parser.TokenCat) bool {
    return switch (cat) {
        .pipe, .semi, .and_and, .or_or, .amp, .lbrace, .lparen, .lbracket => true,
        else => false,
    };
}

fn keywordTakesNameSlot(name: []const u8) bool {
    return std.mem.eql(u8, name, "cmd") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "match");
}

fn direntName(ent: anytype) []const u8 {
    const T = @TypeOf(ent.*);
    if (@hasField(T, "namlen")) {
        const len: usize = ent.namlen;
        return ent.name[0..len];
    }
    const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
    return std.mem.span(name_ptr);
}

test "completion: context uses lexer command positions" {
    const ctx = identifyContext("echo hi; git ", "echo hi; git ".len);
    try std.testing.expect(!ctx.command_position);
    try std.testing.expectEqualStrings("git", ctx.command_name.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.arg_index);
}

test "completion: quoted path prefix starts after quote" {
    const ctx = identifyContext("cd \"src", "cd \"src".len);
    try std.testing.expectEqual(@as(usize, 4), ctx.replacement_start);
    try std.testing.expectEqualStrings("src", ctx.prefix);
    try std.testing.expectEqual(QuoteMode.double, ctx.quote);
}

test "completion: dash flag prefix includes leading dash" {
    const ctx = identifyContext("kill -K", "kill -K".len);
    try std.testing.expectEqualStrings("-K", ctx.prefix);
    try std.testing.expectEqual(@as(usize, 5), ctx.replacement_start);
}

test "completion: newline restores command position" {
    const ctx = identifyContext("echo hi\nec", "echo hi\nec".len);
    try std.testing.expect(ctx.command_position);
    try std.testing.expectEqualStrings("ec", ctx.prefix);
}

test "completion: git subcommands are static candidates" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "git ch",
        .cursor_byte = "git ch".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    try expectCandidate(r.candidates, "checkout");
}

test "completion: cd candidates are directories only" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "cd sr",
        .cursor_byte = "cd sr".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    const c = findCandidate(r.candidates, "src").?;
    try std.testing.expectEqual(zigline.CandidateKind.directory, c.kind);
    try std.testing.expectEqual(@as(?u8, '/'), c.append);
}

test "completion: kill dash lists signal names" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "kill -",
        .cursor_byte = "kill -".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    try expectCandidate(r.candidates, "-KILL");
}

test "completion: env-prefix command position includes builtins" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "FOO=1 ec",
        .cursor_byte = "FOO=1 ec".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    try expectCandidate(r.candidates, "echo");
}

test "completion: str erase lists defined str names" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    try s.strs.set("ll", "ls -lAh");
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "str -e l",
        .cursor_byte = "str -e l".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    try expectCandidate(r.candidates, "ll");
}

test "completion: command position includes builtins and str names" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    try s.strs.set("ll", "ls -lAh");

    const built = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "ec",
        .cursor_byte = "ec".len,
    });
    defer freeCandidates(std.testing.allocator, built.candidates);
    try expectCandidate(built.candidates, "echo");

    const str = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "l",
        .cursor_byte = "l".len,
    });
    defer freeCandidates(std.testing.allocator, str.candidates);
    try expectCandidate(str.candidates, "ll");
}

test "completion: name-slot keywords do not fall through to path candidates" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    const r = try complete(std.testing.allocator, .{
        .session = &s,
        .buffer = "for s",
        .cursor_byte = "for s".len,
    });
    defer freeCandidates(std.testing.allocator, r.candidates);
    try std.testing.expectEqual(@as(usize, 0), r.candidates.len);
}

test "completion: bare path inserts escape spaces" {
    const ctx = WordContext{
        .replacement_start = 0,
        .replacement_end = 2,
        .prefix = "my",
        .quote = .none,
        .command_position = false,
        .command_name = "cd",
        .arg_index = 0,
    };
    const escaped = try quotePathCandidate(std.testing.allocator, ctx, "my dir");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("my\\ dir", escaped);
}

test "completion: path matching uses raw text before quote escaping" {
    var out: CandidateList = .empty;
    defer {
        for (out.items) |c| {
            std.testing.allocator.free(c.insert);
            if (c.display) |d| std.testing.allocator.free(d);
        }
        out.deinit(std.testing.allocator);
    }

    const ctx = WordContext{
        .replacement_start = 4,
        .replacement_end = 5,
        .prefix = "$",
        .quote = .double,
        .command_position = false,
        .command_name = "echo",
        .arg_index = 0,
    };
    const quoted = try quotePathCandidate(std.testing.allocator, ctx, "$file");
    defer std.testing.allocator.free(quoted);
    try appendCandidate(std.testing.allocator, &out, .{ .insert = quoted });
    try std.testing.expectEqualStrings("\\$file", out.items[0].insert);
}

fn expectCandidate(candidates: []const zigline.Candidate, insert: []const u8) !void {
    if (findCandidate(candidates, insert) != null) return;
    std.debug.print("missing completion candidate: {s}\n", .{insert});
    for (candidates) |c| std.debug.print("  {s}\n", .{c.insert});
    return error.TestExpectedEqual;
}

fn findCandidate(candidates: []const zigline.Candidate, insert: []const u8) ?zigline.Candidate {
    for (candidates) |c| {
        if (std.mem.eql(u8, c.insert, insert)) return c;
    }
    return null;
}
