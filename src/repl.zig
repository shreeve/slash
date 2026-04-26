//! repl — interactive read-evaluate-print loop.
//!
//! v0 takes input from the kernel line discipline (cooked mode), one
//! buffered chunk per `read`. Lines accumulate into `pending` until
//! `shape.parse` succeeds; an EOF-anchored parse failure means the
//! user is mid-block and we keep asking for more, otherwise the
//! diagnostic is rendered and the buffer is cleared.
//!
//! Raw-mode line editing, history, syntax highlighting, and tab
//! completion live downstream of this scaffold (PLAN §4 phase 5);
//! this module is the boundary that unblocks them.

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
    /// When true, skip sourcing `~/.slashrc` at startup. Set by `--norc`.
    norc: bool = false,
};

pub fn run(
    session: *session_mod.Session,
    alloc: Allocator,
    options: Options,
) !u8 {
    installInteractiveSignalHandlers();
    if (!options.norc) try sourceRcFile(session, alloc);

    var pending = std.ArrayListUnmanaged(u8).empty;
    defer pending.deinit(alloc);

    var read_buf: [4096]u8 = undefined;

    while (true) {
        // Render prompt — primary if buffer is empty, continuation
        // otherwise. Direct write to fd 1 keeps the prompt out of the
        // way of any buffered stdio.
        const prompt: []const u8 = if (pending.items.len == 0) "$ " else "... ";
        _ = std.c.write(1, prompt.ptr, prompt.len);

        const n = std.c.read(0, &read_buf, read_buf.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return 1;
        }
        if (n == 0) {
            // EOF on stdin (Ctrl-D on an empty line, or the input file
            // ran out). Honor any registered EXIT trap on the way out.
            if (pending.items.len == 0) {
                const status = session.last_status;
                eval.fireExitTrap(session, alloc, null) catch {};
                _ = std.c.write(1, "\n", 1);
                return status;
            }
            // Flush whatever's pending as one final statement.
            try pending.append(alloc, '\n');
            _ = try evaluatePending(session, alloc, &pending);
            return session.last_status;
        }

        try pending.appendSlice(alloc, read_buf[0..@intCast(n)]);

        // Quick exit: Ctrl-C delivered during read returns EINTR above
        // and we loop. Otherwise process the buffer once it ends in a
        // newline (the kernel's line discipline gives us one read per
        // line in cooked mode).
        if (pending.items.len == 0 or pending.items[pending.items.len - 1] != '\n')
            continue;

        const status_before = try evaluatePending(session, alloc, &pending);
        _ = status_before;

        if (session.exit_request) |req| {
            eval.fireExitTrap(session, alloc, null) catch {};
            return req.toStatusByte();
        }
    }
}

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
        // Decide between "incomplete" and "real error" by comparing
        // the diagnostic's primary span start against the buffer end.
        // EOF-anchored failures mean the user is mid-statement.
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

/// At the prompt the parent shell ignores `SIGINT`/`SIGTSTP`/etc. so
/// stray Ctrl-C / Ctrl-Z presses don't kill or suspend slash itself —
/// the foreground job's process group still receives the signal via
/// the controlling terminal. Children reset to defaults before exec
/// already (see `exec.resetSignalDefaults`).
fn installInteractiveSignalHandlers() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const ignored = [_]std.c.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU };
    for (ignored) |sig| std.posix.sigaction(sig, &sa, null);
}

/// Source `~/.slashrc` if it exists. The body runs in shell context,
/// just like the `source` builtin, so any vars/cmd defs/exports it
/// installs survive into the REPL session.
fn sourceRcFile(session: *session_mod.Session, alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const home_env = std.c.getenv("HOME") orelse return;
    const home = std.mem.span(home_env);
    if (home.len == 0) return;

    const path = try std.fmt.allocPrint(a, "{s}/.slashrc", .{home});
    const path_z = try a.dupeZ(u8, path);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return; // missing rc file is fine, not an error
    defer _ = std.c.close(fd);

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return;
        }
        if (n == 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }

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
