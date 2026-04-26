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

    while (true) {
        const prompt: []const u8 = if (pending.items.len == 0) "$ " else "... ";
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
    /// prompt + buffer, clear to end of line, then place the cursor at
    /// `cursor` columns past the end of the prompt.
    fn render(self: *const LineEditor) !void {
        var out_buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&out_buf);
        // CR — move to column 0.
        try w.writeByte('\r');
        try w.writeAll(self.prompt);
        try w.writeAll(self.buf.items);
        // Clear to end of line.
        try w.writeAll("\x1b[K");
        // Move cursor: CR then move forward (prompt width + cursor).
        // Width counts bytes here; multibyte glyphs may end up off by
        // a column with terminal renderers — acceptable for v0.
        const total_cols: usize = self.prompt.len + self.cursor;
        try w.writeByte('\r');
        if (total_cols > 0) {
            try w.print("\x1b[{d}C", .{total_cols});
        }
        const bytes = w.buffered();
        _ = std.c.write(1, bytes.ptr, bytes.len);
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
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
