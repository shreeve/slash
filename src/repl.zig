//! repl — interactive read-evaluate-print loop with raw-mode line editing.
//!
//! Two paths share a parse/lower/run helper:
//!
//!   - **Raw mode** (TTY-attached stdin): `runRaw` puts the terminal in
//!     character-at-a-time mode and drives a `LineEditor` that handles
//!     cursor movement, history recall, kill-to-end / kill-to-start,
//!     backspace, and the usual readline-style emacs keys. ANSI escape
//!     sequences for cursor movement are emitted directly to fd 1.
//!
//!   - **Cooked mode** (piped or non-TTY stdin): `runCooked` uses the
//!     kernel line discipline. One read per Enter; multi-line
//!     continuation accumulates into `pending` until `shape.parse`
//!     succeeds. Used by the headless test harness and shell scripts
//!     that pipe input into slash.
//!
//! `~/.slashrc` sourcing, signal handler installation, and the Ctrl-C
//! discipline are common to both paths. History persists to
//! `~/.slash/history`, one accepted line per file entry.

const std = @import("std");
const diag = @import("diagnostics.zig");
const shape = @import("shape.zig");
const program = @import("program.zig");
const session_mod = @import("session.zig");
const eval = @import("eval.zig");
const builtins = @import("builtins.zig");
const exec = @import("exec.zig");
const parser = @import("parser.zig");
const slash = @import("slash.zig");

pub const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Skip sourcing `~/.slashrc` at startup. Set by `--norc`.
    norc: bool = false,
};

pub fn run(
    session: *session_mod.Session,
    alloc: Allocator,
    options: Options,
) !u8 {
    installInteractiveSignalHandlers();
    if (!options.norc) try sourceRcFile(session, alloc);

    if (isStdinTty()) return runRaw(session, alloc);
    return runCooked(session, alloc);
}

// =============================================================================
// Cooked-mode loop (non-TTY stdin: piped scripts, test harness, etc.)
// =============================================================================

fn runCooked(session: *session_mod.Session, alloc: Allocator) !u8 {
    var pending = std.ArrayListUnmanaged(u8).empty;
    defer pending.deinit(alloc);

    var read_buf: [4096]u8 = undefined;

    while (true) {
        const prompt: []const u8 = if (pending.items.len == 0) "$ " else "... ";
        _ = std.c.write(1, prompt.ptr, prompt.len);

        const n = std.c.read(0, &read_buf, read_buf.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) {
                pending.clearRetainingCapacity();
                _ = std.c.write(1, "\n", 1);
                continue;
            }
            return 1;
        }
        if (n == 0) {
            if (pending.items.len == 0) {
                const status = session.last_status;
                eval.fireExitTrap(session, alloc, null) catch {};
                _ = std.c.write(1, "\n", 1);
                return status;
            }
            try pending.append(alloc, '\n');
            _ = try evaluatePending(session, alloc, &pending);
            return session.last_status;
        }

        try pending.appendSlice(alloc, read_buf[0..@intCast(n)]);
        if (pending.items.len == 0 or pending.items[pending.items.len - 1] != '\n')
            continue;

        _ = try evaluatePending(session, alloc, &pending);

        if (session.exit_request) |req| {
            eval.fireExitTrap(session, alloc, null) catch {};
            return req.toStatusByte();
        }
    }
}

// =============================================================================
// Raw-mode loop with line editor + history
// =============================================================================

fn runRaw(session: *session_mod.Session, alloc: Allocator) !u8 {
    var history = History.init(alloc);
    defer history.deinit();
    history.load() catch {};

    var pending = std.ArrayListUnmanaged(u8).empty;
    defer pending.deinit(alloc);

    var prompt_buf: [1024]u8 = undefined;
    while (true) {
        const prompt = if (pending.items.len == 0)
            renderPrompt(&prompt_buf, session)
        else
            "... ";
        const line = try readLine(alloc, prompt, &history);
        defer alloc.free(line);

        // Ctrl-D on an empty line returns null-equivalent (we use a
        // sentinel: empty line + line.eof = true). For now: empty line
        // && pending empty == EOF on a fresh prompt → exit.
        if (line.len == 1 and line[0] == 0x04) {
            if (pending.items.len == 0) {
                const status = session.last_status;
                eval.fireExitTrap(session, alloc, null) catch {};
                _ = std.c.write(1, "\n", 1);
                return status;
            }
            // Otherwise treat as cancel: drop the partial buffer.
            pending.clearRetainingCapacity();
            _ = std.c.write(1, "\n", 1);
            continue;
        }

        if (line.len == 1 and line[0] == 0x03) {
            // Ctrl-C: cancel any partial buffer, fresh prompt.
            pending.clearRetainingCapacity();
            _ = std.c.write(1, "\n", 1);
            continue;
        }

        try pending.appendSlice(alloc, line);
        try pending.append(alloc, '\n');

        // Try to evaluate; if incomplete, loop and prompt continuation.
        const before_len = pending.items.len;
        _ = try evaluatePending(session, alloc, &pending);
        // If pending wasn't reset, parse was incomplete — keep going.
        if (pending.items.len == before_len and pending.items.len > 0) continue;

        // A line that actually ran (or was a real parse error) is
        // worth saving to history. Reconstruct the source from the
        // line we just submitted; the trailing newline is dropped.
        if (line.len > 0) try history.append(line);

        if (session.exit_request) |req| {
            eval.fireExitTrap(session, alloc, null) catch {};
            return req.toStatusByte();
        }
    }
}

// -----------------------------------------------------------------------------
// readLine: raw-mode keystroke processor
// -----------------------------------------------------------------------------

/// Read a single logical line in raw mode. Returns an allocated slice;
/// caller frees. The slice contains user-typed bytes only — no trailing
/// newline. Special cases:
///   - Ctrl-C → returns a single 0x03 byte
///   - Ctrl-D on empty line → returns a single 0x04 byte
fn readLine(
    alloc: Allocator,
    prompt: []const u8,
    history: *History,
) ![]u8 {
    var raw = try RawMode.enter();
    defer raw.leave();

    var editor = LineEditor.init(alloc, prompt);
    defer editor.deinit();

    try editor.render();

    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) {
                _ = std.c.write(1, "\r\n", 2);
                editor.buf.clearRetainingCapacity();
                editor.cursor = 0;
                try editor.render();
                continue;
            }
            return error.ReadFailed;
        }
        if (n == 0) {
            // Stdin closed mid-line. Treat as Ctrl-D.
            if (editor.buf.items.len == 0) {
                const out = try alloc.alloc(u8, 1);
                out[0] = 0x04;
                return out;
            }
            return editor.takeBuf(alloc);
        }

        const c = byte[0];

        switch (c) {
            0x03 => {
                // Ctrl-C
                _ = std.c.write(1, "^C\r\n", 4);
                const out = try alloc.alloc(u8, 1);
                out[0] = 0x03;
                return out;
            },
            0x04 => {
                // Ctrl-D
                if (editor.buf.items.len == 0) {
                    const out = try alloc.alloc(u8, 1);
                    out[0] = 0x04;
                    return out;
                }
                // Otherwise act as forward-delete.
                editor.deleteForward();
                try editor.render();
            },
            0x0a, 0x0d => {
                // Enter
                _ = std.c.write(1, "\r\n", 2);
                history.cursor = null;
                return editor.takeBuf(alloc);
            },
            0x08, 0x7f => {
                // Backspace
                editor.deleteBackward();
                try editor.render();
            },
            0x01 => { // Ctrl-A
                editor.cursor = 0;
                try editor.render();
            },
            0x05 => { // Ctrl-E
                editor.cursor = @intCast(editor.buf.items.len);
                try editor.render();
            },
            0x0b => { // Ctrl-K — kill to end
                editor.buf.shrinkRetainingCapacity(editor.cursor);
                try editor.render();
            },
            0x15 => { // Ctrl-U — kill to start
                if (editor.cursor > 0) {
                    const remaining = editor.buf.items[editor.cursor..];
                    std.mem.copyForwards(u8, editor.buf.items[0..remaining.len], remaining);
                    editor.buf.shrinkRetainingCapacity(remaining.len);
                    editor.cursor = 0;
                    try editor.render();
                }
            },
            0x17 => { // Ctrl-W — kill word backward
                editor.killWordBackward();
                try editor.render();
            },
            0x0c => { // Ctrl-L — clear screen
                _ = std.c.write(1, "\x1b[H\x1b[2J", 7);
                try editor.render();
            },
            0x09 => { // Tab — completion
                try handleTabCompletion(alloc, &editor);
            },
            0x1b => {
                // Escape sequence (arrow keys, etc.)
                var seq: [4]u8 = undefined;
                const got = std.c.read(0, &seq, 2);
                if (got < 2) {
                    // Bare ESC: ignore.
                    continue;
                }
                if (seq[0] != '[') continue;
                switch (seq[1]) {
                    'A' => { // Up
                        if (history.previous(editor.buf.items)) |entry| {
                            editor.replace(entry) catch {};
                            try editor.render();
                        }
                    },
                    'B' => { // Down
                        if (history.next()) |entry| {
                            editor.replace(entry) catch {};
                            try editor.render();
                        }
                    },
                    'C' => { // Right
                        if (editor.cursor < editor.buf.items.len) {
                            editor.cursor += 1;
                            try editor.render();
                        }
                    },
                    'D' => { // Left
                        if (editor.cursor > 0) {
                            editor.cursor -= 1;
                            try editor.render();
                        }
                    },
                    else => {},
                }
            },
            else => {
                if (c >= 0x20 or c >= 0x80) {
                    try editor.insert(c);
                    try editor.render();
                }
            },
        }
    }
}

// -----------------------------------------------------------------------------
// LineEditor — buffer + cursor + render
// -----------------------------------------------------------------------------

const LineEditor = struct {
    alloc: Allocator,
    buf: std.ArrayListUnmanaged(u8),
    cursor: u32,
    prompt: []const u8,

    fn init(alloc: Allocator, prompt: []const u8) LineEditor {
        return .{
            .alloc = alloc,
            .buf = .empty,
            .cursor = 0,
            .prompt = prompt,
        };
    }

    fn deinit(self: *LineEditor) void {
        self.buf.deinit(self.alloc);
    }

    fn insert(self: *LineEditor, c: u8) !void {
        try self.buf.insert(self.alloc, self.cursor, c);
        self.cursor += 1;
    }

    fn deleteBackward(self: *LineEditor) void {
        if (self.cursor == 0) return;
        _ = self.buf.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
    }

    fn deleteForward(self: *LineEditor) void {
        if (self.cursor >= self.buf.items.len) return;
        _ = self.buf.orderedRemove(self.cursor);
    }

    fn killWordBackward(self: *LineEditor) void {
        if (self.cursor == 0) return;
        var end = self.cursor;
        while (end > 0 and isSpace(self.buf.items[end - 1])) : (end -= 1) {}
        while (end > 0 and !isSpace(self.buf.items[end - 1])) : (end -= 1) {}
        const start = end;
        const remaining = self.buf.items[self.cursor..];
        std.mem.copyForwards(u8, self.buf.items[start..][0..remaining.len], remaining);
        const new_len = start + @as(u32, @intCast(remaining.len));
        self.buf.shrinkRetainingCapacity(new_len);
        self.cursor = start;
    }

    fn replace(self: *LineEditor, replacement: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.alloc, replacement);
        self.cursor = @intCast(self.buf.items.len);
    }

    /// Hand the accumulated bytes to the caller; reset internal state.
    fn takeBuf(self: *LineEditor, alloc: Allocator) ![]u8 {
        const out = try alloc.dupe(u8, self.buf.items);
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        return out;
    }

    /// Redraw the input line in place: cursor to column 0, write the
    /// prompt + tokenized-and-colored buffer, clear to end of line,
    /// then place the cursor at `cursor` printable columns past the
    /// end of the prompt. ANSI escape sequences are zero-width on
    /// terminal cells, so the cursor positioning stays in sync with
    /// the user's typed-byte count.
    fn render(self: *const LineEditor) !void {
        var out_buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);
        try w.writeByte('\r');
        try w.writeAll(self.prompt);
        writeColored(&w, self.buf.items) catch {
            // If the colored render runs out of buffer (~16 KB worth
            // of input + escapes), fall back to plain bytes so the
            // user can still see what they're typing.
            w = std.Io.Writer.fixed(&out_buf);
            try w.writeByte('\r');
            try w.writeAll(self.prompt);
            try w.writeAll(self.buf.items);
        };
        // Clear to end of line.
        try w.writeAll("\x1b[K");
        // Move cursor to column (prompt + cursor).
        const total_cols: usize = self.prompt.len + self.cursor;
        try w.writeByte('\r');
        if (total_cols > 0) {
            try w.print("\x1b[{d}C", .{total_cols});
        }
        const bytes = w.buffered();
        _ = std.c.write(1, bytes.ptr, bytes.len);
    }
};

// =============================================================================
// Syntax highlighting
// =============================================================================
//
// Token-based, driven by the existing `parser.BaseLexer`. ANSI escape
// sequences are zero-width on the terminal, so we splice them around
// the user's typed bytes without disturbing the line editor's
// column-counting math.
//
// Color map (matches PLAN §10's expected palette):
//
//   bold cyan      keywords (if / else / while / for / cmd / in)
//   yellow         variables, ${...}, $(...), @(...), integer literals
//   green          string literals (sq, dq, heredoc bodies)
//   dim white      pipes, redirects, separators, brackets/braces/parens
//   dim gray       comments
//   red underline  unrecognized bytes (lex `err`)
//   default        identifiers, NAME_EQ, plain `=`
//
// Inside double-quoted strings, `$var` / `${...}` / `$(...)` should
// flip back to yellow inside the green run. The token stream gives us
// `string_dq` as one chunk; `recolorDoubleQuoted` walks the body and
// emits per-segment colors so the highlighting is faithful to the
// dq splitter's interpretation at parse time.

fn writeColored(w: anytype, bytes: []const u8) !void {
    var lex = parser.BaseLexer.init(bytes);
    var last_pos: u32 = 0;
    while (true) {
        const tok = lex.next();
        if (tok.cat == .eof) break;
        if (tok.pos > last_pos and tok.pos <= bytes.len) {
            try w.writeAll(bytes[last_pos..tok.pos]);
        }
        const span = bytes[tok.pos..@min(tok.pos + tok.len, @as(u32, @intCast(bytes.len)))];
        try writeColoredToken(w, tok, span);
        last_pos = tok.pos + tok.len;
        if (last_pos > bytes.len) last_pos = @intCast(bytes.len);
    }
    if (last_pos < bytes.len) try w.writeAll(bytes[last_pos..]);
}

fn writeColoredToken(w: anytype, tok: parser.Token, span: []const u8) !void {
    const code = colorCodeFor(tok, span);
    if (tok.cat == .string_dq) {
        try recolorDoubleQuoted(w, span);
        return;
    }
    if (code.len == 0) {
        try w.writeAll(span);
        return;
    }
    try w.print("\x1b[{s}m{s}\x1b[0m", .{ code, span });
}

fn colorCodeFor(tok: parser.Token, span: []const u8) []const u8 {
    return switch (tok.cat) {
        .ident => if (slash.keywordAs(span) != null) "1;36" else "",
        .integer => "33",
        .string_sq, .string_dq => "32",
        .variable, .var_braced, .dollar_paren, .at_paren => "33",
        .heredoc_body => "32",
        .pipe,
        .lt,
        .gt,
        .gt_gt,
        .amp_gt,
        .amp_gt_gt,
        .fd_lt,
        .fd_gt,
        .fd_dup_out,
        .fd_dup_in,
        .heredoc_open,
        .heredoc_open_lit,
        .proc_sub_in,
        .proc_sub_out,
        => "2;37",
        .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket => "2;37",
        .semi, .and_and, .or_or, .amp => "2;37",
        .comment => "2;37",
        .err => "1;4;31",
        else => "",
    };
}

/// `string_dq` covers the entire `"..."` token. Walk the interior to
/// recolor `$name`, `${...}`, and `$(...)` segments back to yellow on
/// top of the green base. Mirrors the splitter in `shape.splitDoubleQuoted`
/// closely enough that what the user sees matches what gets parsed.
fn recolorDoubleQuoted(w: anytype, span: []const u8) !void {
    if (span.len < 2 or span[0] != '"') {
        try w.print("\x1b[32m{s}\x1b[0m", .{span});
        return;
    }
    // Open quote.
    try w.writeAll("\x1b[32m\"");

    const body = span[1 .. if (span[span.len - 1] == '"') span.len - 1 else span.len];
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            // Escape sequence — keep green, advance two bytes.
            try w.writeAll(body[i .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < body.len) {
            const n = body[i + 1];
            if (n == '{') {
                const close = std.mem.indexOfScalarPos(u8, body, i + 2, '}');
                const end_idx = if (close) |x| x + 1 else body.len;
                try w.print("\x1b[0m\x1b[33m{s}\x1b[0m\x1b[32m", .{body[i..end_idx]});
                i = end_idx;
                continue;
            }
            if (n == '(') {
                var depth: u32 = 1;
                var j = i + 2;
                while (j < body.len) : (j += 1) {
                    if (body[j] == '(') depth += 1;
                    if (body[j] == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const end_idx = if (j < body.len) j + 1 else body.len;
                try w.print("\x1b[0m\x1b[33m{s}\x1b[0m\x1b[32m", .{body[i..end_idx]});
                i = end_idx;
                continue;
            }
            if (isVarRefStart(n)) {
                var j = i + 2;
                while (j < body.len and isVarRefCont(body[j])) : (j += 1) {}
                try w.print("\x1b[0m\x1b[33m{s}\x1b[0m\x1b[32m", .{body[i..j]});
                i = j;
                continue;
            }
            if (isSpecialVarChar(n)) {
                try w.print("\x1b[0m\x1b[33m{s}\x1b[0m\x1b[32m", .{body[i .. i + 2]});
                i += 2;
                continue;
            }
        }
        try w.writeByte(c);
        i += 1;
    }

    // Close quote (if present).
    if (span.len >= 2 and span[span.len - 1] == '"') {
        try w.writeByte('"');
    }
    try w.writeAll("\x1b[0m");
}

fn isVarRefStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isVarRefCont(c: u8) bool {
    return isVarRefStart(c) or (c >= '0' and c <= '9');
}

fn isSpecialVarChar(c: u8) bool {
    return switch (c) {
        '0'...'9', '?', '#', '@', '!', '*', '$' => true,
        else => false,
    };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

// =============================================================================
// Tab completion
// =============================================================================
//
// Two contexts:
//   - command position: prefix is the first word on the line (or right
//     after `;`, `&&`, `||`, `|`, `(`, `{`). Candidates: PATH executables
//     plus the small set of always-available names slash recognizes
//     (builtins land elsewhere; the binary doesn't currently expose a
//     `BuiltinSet` enumerator, so for v0 we just complete against PATH
//     and let the user lean on `type` for builtin discovery).
//   - argument position: prefix is everything after the most recent
//     space; candidates are filesystem entries matching the prefix.
//
// On a single match: insert the remainder plus a trailing `/` (dir) or
// space (file). On multiple matches: emit a fresh line of candidates
// and redraw the editor.

fn handleTabCompletion(alloc: Allocator, editor: *LineEditor) !void {
    const ctx = identifyCompletionContext(editor.buf.items, editor.cursor);

    var candidates = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (candidates.items) |c| alloc.free(c);
        candidates.deinit(alloc);
    }

    switch (ctx.kind) {
        .command => try gatherCommandCandidates(alloc, ctx.prefix, &candidates),
        .file => try gatherFileCandidates(alloc, ctx.prefix, &candidates),
    }

    if (candidates.items.len == 0) return;

    if (candidates.items.len == 1) {
        const match = candidates.items[0];
        const suffix = match[ctx.prefix.len..];
        for (suffix) |c| try editor.insert(c);
        // Add `/` for directories, space otherwise — for command
        // candidates the trailing space lands the user in argv space.
        const last = match[match.len - 1];
        if (last != '/') try editor.insert(' ');
        try editor.render();
        return;
    }

    // Multiple matches: print them, then redraw the editor.
    _ = std.c.write(1, "\r\n", 2);
    for (candidates.items, 0..) |c, i| {
        _ = std.c.write(1, c.ptr, c.len);
        if (i + 1 < candidates.items.len) _ = std.c.write(1, "  ", 2);
    }
    _ = std.c.write(1, "\r\n", 2);
    try editor.render();

    // If the candidates share a common prefix longer than the user's
    // current prefix, insert the shared portion to bring the user
    // closer to a unique match.
    const common = longestCommonPrefix(candidates.items);
    if (common.len > ctx.prefix.len) {
        const extra = common[ctx.prefix.len..];
        for (extra) |c| try editor.insert(c);
        try editor.render();
    }
}

const CompletionKind = enum { command, file };

const CompletionContext = struct {
    kind: CompletionKind,
    /// Bytes of the partial token under the cursor (everything from the
    /// last whitespace / separator up to the cursor).
    prefix: []const u8,
};

fn identifyCompletionContext(buf: []const u8, cursor: u32) CompletionContext {
    // Walk back to find the start of the current token.
    var token_start: u32 = cursor;
    while (token_start > 0) {
        const c = buf[token_start - 1];
        if (isSpace(c) or c == '|' or c == ';' or c == '&' or c == '(' or c == '{') break;
        token_start -= 1;
    }
    const prefix = buf[token_start..cursor];

    // Walk back further from token_start across whitespace to look at
    // what came before. If we hit a separator (or beginning of buffer),
    // we're at command position.
    var p = token_start;
    while (p > 0 and isSpace(buf[p - 1])) p -= 1;
    if (p == 0) return .{ .kind = .command, .prefix = prefix };
    const prev = buf[p - 1];
    if (prev == ';' or prev == '|' or prev == '&' or prev == '(' or prev == '{') {
        return .{ .kind = .command, .prefix = prefix };
    }
    return .{ .kind = .file, .prefix = prefix };
}

fn gatherCommandCandidates(
    alloc: Allocator,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    const path_env = std.c.getenv("PATH") orelse return;
    const path_str = std.mem.span(path_env);

    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit(alloc);
    }

    var dirs = std.mem.splitScalar(u8, path_str, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        try enumerateMatching(alloc, dir, prefix, out, &seen, .require_executable);
    }
}

fn gatherFileCandidates(
    alloc: Allocator,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    // Split into directory + basename.
    const slash_idx = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_part: []const u8 = if (slash_idx) |i| prefix[0 .. i + 1] else "";
    const base_part: []const u8 = if (slash_idx) |i| prefix[i + 1 ..] else prefix;
    const dir_path: []const u8 = if (dir_part.len == 0) "." else dir_part;

    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit(alloc);
    }

    try enumerateMatching(alloc, dir_path, base_part, out, &seen, .any);

    // Re-attach the directory part to each candidate.
    if (dir_part.len > 0) {
        for (out.items) |*cand| {
            const old = cand.*;
            const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ dir_part, old });
            alloc.free(old);
            cand.* = combined;
        }
    }
}

const EnumerateMode = enum { any, require_executable };

fn enumerateMatching(
    alloc: Allocator,
    dir_path: []const u8,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
    seen: *std.StringHashMapUnmanaged(void),
    mode: EnumerateMode,
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
        // Hidden files only if the prefix asks for them explicitly.
        if (name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;

        // For command candidates, require X_OK on the full path.
        if (mode == .require_executable) {
            var full_buf: [8192]u8 = undefined;
            const full = std.fmt.bufPrint(&full_buf, "{s}/{s}\x00", .{ dir_path, name }) catch continue;
            const full_z: [*:0]const u8 = @ptrCast(full.ptr);
            if (std.c.access(full_z, std.c.X_OK) != 0) continue;
        }

        // Dedup by name (per-prefix; cross-PATH-dir dups are merged).
        const key = try alloc.dupe(u8, name);
        const gop = try seen.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            continue;
        }

        // For file candidates that are directories, decorate with `/`.
        var label_buf: [4096]u8 = undefined;
        var label = name;
        if (mode == .any) {
            var path_buf: [8192]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}\x00", .{ dir_path, name }) catch name;
            const path_z: [*:0]const u8 = @ptrCast(path.ptr);
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) == 0 and
                (st.mode & std.c.S.IFMT) == std.c.S.IFDIR)
            {
                const decorated = std.fmt.bufPrint(&label_buf, "{s}/", .{name}) catch name;
                label = decorated;
            }
        }
        try out.append(alloc, try alloc.dupe(u8, label));
    }
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

fn longestCommonPrefix(items: []const []u8) []const u8 {
    if (items.len == 0) return "";
    var n: usize = items[0].len;
    for (items[1..]) |s| {
        const m = @min(n, s.len);
        var i: usize = 0;
        while (i < m and items[0][i] == s[i]) : (i += 1) {}
        n = i;
        if (n == 0) break;
    }
    return items[0][0..n];
}

// -----------------------------------------------------------------------------
// RawMode — termios save/restore
// -----------------------------------------------------------------------------

const RawMode = struct {
    saved: std.c.termios,

    fn enter() !RawMode {
        var saved: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &saved) != 0) return error.NotATty;
        var raw = saved;
        // ICANON off → byte at a time; ECHO off → we render ourselves.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        // Keep ISIG on so Ctrl-C delivers SIGINT (caught by our no-op
        // handler, which interrupts the read).
        raw.lflag.ISIG = true;
        // Disable input mapping we don't want: CR→NL translation, etc.
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        // Read returns as soon as 1 byte is available.
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        if (std.c.tcsetattr(0, .NOW, &raw) != 0) return error.SetattrFailed;
        return .{ .saved = saved };
    }

    fn leave(self: RawMode) void {
        _ = std.c.tcsetattr(0, .NOW, &self.saved);
    }
};

fn isStdinTty() bool {
    return std.c.isatty(0) != 0;
}

// =============================================================================
// Prompt rendering
// =============================================================================
//
// Default prompt: home-collapsed PWD, optional non-zero last status,
// then `$ ` (or `# ` for root). Colors via ANSI: cwd in cyan, status
// in red. `\x01`/`\x02` aren't used because we always recompute the
// rendered prompt before each prompt boundary; the line editor's
// `total_cols` accounting just needs the printable byte count, which
// `cwd.len + 2` gives directly when no escapes are present.

fn renderPrompt(buf: []u8, session: *const session_mod.Session) []const u8 {
    var w = std.Io.Writer.fixed(buf);

    // PWD with home collapsed.
    var cwd_buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&cwd_buf, cwd_buf.len);
    var cwd: []const u8 = "?";
    if (got != null) {
        const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
        cwd = cwd_buf[0..len];
    }

    // Home collapse.
    if (std.c.getenv("HOME")) |home_env| {
        const home = std.mem.span(home_env);
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            w.writeAll("~") catch return "$ ";
            cwd = cwd[home.len..];
        }
    }
    w.writeAll(cwd) catch return "$ ";

    // Last status (only if non-zero).
    if (session.last_status != 0) {
        w.print(" [{d}]", .{session.last_status}) catch {};
    }

    // Suffix — root gets `#`, everyone else gets `$`.
    const suffix: []const u8 = if (std.c.getuid() == 0) " # " else " $ ";
    w.writeAll(suffix) catch return "$ ";

    return w.buffered();
}

// -----------------------------------------------------------------------------
// History — persistent flat-file
// -----------------------------------------------------------------------------

const History = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Cursor into `entries` while the user navigates Up/Down. `null`
    /// means we're on the live editing line, not in the history.
    cursor: ?usize = null,
    /// Snapshot of the live editing line when the user first hit Up,
    /// so Down past the end of history restores what they typed.
    snapshot: ?[]const u8 = null,
    path: ?[]u8 = null,

    fn init(alloc: Allocator) History {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *History) void {
        for (self.entries.items) |e| self.alloc.free(e);
        self.entries.deinit(self.alloc);
        if (self.snapshot) |s| self.alloc.free(s);
        if (self.path) |p| self.alloc.free(p);
    }

    fn load(self: *History) !void {
        try self.resolvePath();
        const path = self.path orelse return;
        const path_z = try self.alloc.dupeZ(u8, path);
        defer self.alloc.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return; // missing history is fine

        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n < 0) break;
            if (n == 0) break;
            try buf.appendSlice(self.alloc, chunk[0..@intCast(n)]);
        }
        _ = std.c.close(fd);

        var it = std.mem.splitScalar(u8, buf.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const dup = try self.alloc.dupe(u8, line);
            try self.entries.append(self.alloc, dup);
        }
    }

    fn append(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.entries.items.len > 0) {
            // Skip exact duplicates of the previous entry.
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, line)) {
                self.persistAppend(line) catch {};
                return;
            }
        }
        const dup = try self.alloc.dupe(u8, line);
        try self.entries.append(self.alloc, dup);
        self.persistAppend(line) catch {};
    }

    /// Step one entry back. `current` is the user's in-progress edit;
    /// it gets snapshotted so a later Down past the end can restore it.
    fn previous(self: *History, current: []const u8) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            if (self.snapshot) |s| self.alloc.free(s);
            self.snapshot = self.alloc.dupe(u8, current) catch null;
            self.cursor = self.entries.items.len;
        }
        if (self.cursor.? == 0) return null;
        self.cursor = self.cursor.? - 1;
        return self.entries.items[self.cursor.?];
    }

    fn next(self: *History) ?[]const u8 {
        const cur = self.cursor orelse return null;
        if (cur + 1 < self.entries.items.len) {
            self.cursor = cur + 1;
            return self.entries.items[cur + 1];
        }
        // Past the end → restore the snapshot (or empty).
        self.cursor = null;
        if (self.snapshot) |s| return s;
        return "";
    }

    fn resolvePath(self: *History) !void {
        const home_env = std.c.getenv("HOME") orelse return;
        const home = std.mem.span(home_env);
        const dir = try std.fmt.allocPrint(self.alloc, "{s}/.slash", .{home});
        defer self.alloc.free(dir);
        const dir_z = try self.alloc.dupeZ(u8, dir);
        defer self.alloc.free(dir_z);
        _ = std.c.mkdir(dir_z.ptr, 0o700);

        self.path = try std.fmt.allocPrint(self.alloc, "{s}/history", .{dir});
    }

    fn persistAppend(self: *History, line: []const u8) !void {
        const path = self.path orelse return;
        const path_z = try self.alloc.dupeZ(u8, path);
        defer self.alloc.free(path_z);
        const fd = std.c.open(
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, line.ptr, line.len);
        _ = std.c.write(fd, "\n", 1);
    }
};

// =============================================================================
// Shared parse/lower/run helpers
// =============================================================================

/// Parse + lower + run the buffered source. Distinguishes three
/// outcomes:
///   - parse succeeds → run, clear buffer, return the result status
///   - parse fails AT EOF → buffer is incomplete; keep accumulating
///   - parse fails before EOF → real error; render and clear buffer
fn evaluatePending(
    session: *session_mod.Session,
    alloc: Allocator,
    pending: *std.ArrayListUnmanaged(u8),
) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var diag_list = diag.ListSink.init(a);
    const source = diag.Source{ .name = "<repl>", .text = pending.items };
    const parsed = shape.parse(source, a, diag_list.sink()) catch {
        if (isIncompleteParse(diag_list.items.items, pending.items.len)) {
            return session.last_status;
        }
        renderDiagnostics(diag_list.items.items);
        pending.clearRetainingCapacity();
        session.last_status = 1;
        return 1;
    };

    const lower_ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = program.lower(parsed.root, &lower_ctx, diag_list.sink()) catch {
        renderDiagnostics(diag_list.items.items);
        pending.clearRetainingCapacity();
        session.last_status = 1;
        return 1;
    };

    const result = eval.runForeground(prog, session, a, null) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "slash: eval error: {s}\n", .{@errorName(err)}) catch "slash: eval error\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        pending.clearRetainingCapacity();
        session.last_status = 1;
        return 1;
    };

    pending.clearRetainingCapacity();
    return result.toStatusByte();
}

/// True if every error-level diagnostic points at the very end of the
/// buffer, which is what the parser produces when it runs out of input
/// inside an open brace, paren, bracket, or unterminated heredoc.
fn isIncompleteParse(items: []const diag.Diagnostic, buffer_len: usize) bool {
    var saw_error = false;
    for (items) |d| switch (d.severity) {
        .@"error", .fatal => {
            saw_error = true;
            const span = d.span orelse return false;
            if (span.start < buffer_len -| 1) return false;
        },
        else => {},
    };
    return saw_error;
}

fn renderDiagnostics(items: []const diag.Diagnostic) void {
    var buf: [4096]u8 = undefined;
    for (items) |d| {
        var stream = std.Io.Writer.fixed(&buf);
        diag.render(d, .snippet, &stream) catch continue;
        const bytes = stream.buffered();
        _ = std.c.write(2, bytes.ptr, bytes.len);
    }
}

// =============================================================================
// Signal discipline
// =============================================================================

/// At the prompt the parent shell catches `SIGINT` so Ctrl-C
/// interrupts the pending `read` (we'll see EINTR and clear the
/// in-flight buffer) without actually killing the shell. `SIGTSTP`
/// / `SIGTTIN` / `SIGTTOU` stay ignored so a stray Ctrl-Z doesn't
/// suspend slash. Children reset to defaults before exec already
/// (see `exec.resetSignalDefaults`).
fn installInteractiveSignalHandlers() void {
    var ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const ignored = [_]std.c.SIG{ .QUIT, .TSTP, .TTIN, .TTOU };
    for (ignored) |sig| std.posix.sigaction(sig, &ignore, null);

    var int_action: std.posix.Sigaction = .{
        .handler = .{ .handler = sigintNoop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &int_action, null);
}

fn sigintNoop(_: std.c.SIG) callconv(.c) void {}

// =============================================================================
// rc-file sourcing
// =============================================================================

fn sourceRcFile(session: *session_mod.Session, alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const home_env = std.c.getenv("HOME") orelse return;
    const home = std.mem.span(home_env);
    if (home.len == 0) return;

    const path = try std.fmt.allocPrint(a, "{s}/.slashrc", .{home});
    const path_z = try a.dupeZ(u8, path);

    const fd = std.c.open(
        path_z.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        @as(std.c.mode_t, 0),
    );
    if (fd < 0) return;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            _ = std.c.close(fd);
            return;
        }
        if (n == 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    _ = std.c.close(fd);

    const source = diag.Source{ .name = path, .text = buf.items };
    var sink_list = diag.ListSink.init(a);
    const parsed = shape.parse(source, a, sink_list.sink()) catch {
        renderDiagnostics(sink_list.items.items);
        return;
    };
    const lower_ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = program.lower(parsed.root, &lower_ctx, sink_list.sink()) catch {
        renderDiagnostics(sink_list.items.items);
        return;
    };
    _ = eval.runForeground(prog, session, a, null) catch {};
}

// =============================================================================
// Tests
// =============================================================================

test "highlight: keywords get bold cyan" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeColored(&w, "if true { echo hi }");
    const out = w.buffered();
    // `if` (keyword), `true` and `echo` (idents), strings (none here),
    // braces (dim). Expect at least one bold-cyan and one dim escape.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;36m") != null); // keyword
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;37m") != null); // braces
}

test "highlight: variables and strings" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeColored(&w, "x=hello; echo $x 'lit'");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[33m") != null); // $x yellow
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[32m") != null); // 'lit' green
}

test "highlight: dq with embedded $var flips back to yellow" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeColored(&w, "echo \"hello $name\"");
    const out = w.buffered();
    // Should contain a green→yellow transition for the inner $name.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[33m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$name") != null);
}

test "highlight: comment is dim" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeColored(&w, "echo a # trailing comment");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "# trailing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;37m") != null);
}

test "highlight: bytes pass through unchanged when stripped of escapes" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const input = "for x in 1 2 3 { echo $x }";
    try writeColored(&w, input);
    const out = w.buffered();
    // Stripping ANSI escapes should give back exactly the input.
    var stripped: [256]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b) {
            // Skip until 'm'.
            while (i < out.len and out[i] != 'm') : (i += 1) {}
            continue;
        }
        stripped[len] = out[i];
        len += 1;
    }
    try std.testing.expectEqualStrings(input, stripped[0..len]);
}
