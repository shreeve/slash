//! repl — interactive REPL on top of zigline.
//!
//! Two paths share a parse/lower/run helper:
//!
//!   - **Raw mode** (TTY-attached stdin): drives a `zigline.Editor`
//!     for line editing, history, completion, and syntax highlighting.
//!     Slash supplies the `CompletionHook` (PATH + filesystem walk)
//!     and `HighlightHook` (BaseLexer-driven spans). Multi-line
//!     continuation is handled here: a parse failure that points at
//!     the very end of the buffer keeps the editor open with the
//!     `... ` continuation prompt.
//!
//!   - **Cooked mode** (piped or non-TTY stdin): uses the kernel
//!     line discipline. One read per Enter; multi-line continuation
//!     accumulates into `pending` until `shape.parse` succeeds. Used
//!     by the headless test harness and shell scripts that pipe
//!     input into slash.
//!
//! `~/.slashrc` sourcing, signal handler installation, and the Ctrl-C
//! discipline are common to both paths. History persists to
//! `~/.slash/history`, one accepted line per file entry.
//!
//! Line-editor surface (raw mode, key parsing, cursor + buffer state,
//! repaint, history navigation, tab-completion UI, syntax-highlight
//! SGR generation) is owned by zigline. Slash provides this file's
//! adapter — keymap, span-returning highlighter, replacement-range
//! completer, custom-action hook for Ctrl-X edit-in-editor — plus
//! its own parse/eval pipeline, prompt content, and signal policy.

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
const zigline = @import("zigline");

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
// Raw-mode loop driven by zigline.Editor
// =============================================================================

fn runRaw(session: *session_mod.Session, alloc: Allocator) !u8 {
    // History — owned by us; passed to the editor by reference. Path is
    // ~/.slash/history; failures (no HOME, can't mkdir) leave history
    // in-memory only.
    const hist_path = resolveHistoryPath(alloc) catch null;
    defer if (hist_path) |p| alloc.free(p);

    var history = try zigline.History.init(alloc, .{
        .path = hist_path,
        .max_entries = 1000,
        .dedupe = .adjacent,
    });
    defer history.deinit();

    var hooks = SlashHooks{
        .session = session,
        .alloc = alloc,
        .history = &history,
    };

    var editor = try zigline.Editor.init(alloc, .{
        .keymap = slash_keymap,
        .history = &history,
        .completion = .{
            .ctx = @ptrCast(&hooks),
            .completeFn = completionHook,
        },
        .highlight = .{
            .ctx = @ptrCast(&hooks),
            .highlightFn = highlightHook,
        },
        .custom_action = .{
            .ctx = @ptrCast(&hooks),
            .invokeFn = customActionHook,
        },
    });
    defer editor.deinit();

    var pending = std.ArrayListUnmanaged(u8).empty;
    defer pending.deinit(alloc);

    var prompt_buf: [1024]u8 = undefined;
    while (true) {
        const prompt_text = if (pending.items.len == 0)
            renderPrompt(&prompt_buf, session)
        else
            "... ";
        const prompt = zigline.Prompt.plain(prompt_text);

        const result = editor.readLine(prompt) catch |err| {
            std.debug.print("slash: readLine error: {s}\n", .{@errorName(err)});
            return 1;
        };

        switch (result) {
            .line => |line| {
                defer alloc.free(line);
                try pending.appendSlice(alloc, line);
                try pending.append(alloc, '\n');

                const before_len = pending.items.len;
                _ = try evaluatePending(session, alloc, &pending);
                // Parse incomplete → keep accumulating; show `... ` next.
                if (pending.items.len == before_len and pending.items.len > 0) continue;

                if (session.exit_request) |req| {
                    eval.fireExitTrap(session, alloc, null) catch {};
                    return req.toStatusByte();
                }
            },
            .interrupt => {
                // Ctrl-C: cancel any partial buffer, prompt fresh.
                pending.clearRetainingCapacity();
            },
            .eof => {
                if (pending.items.len == 0) {
                    const status = session.last_status;
                    eval.fireExitTrap(session, alloc, null) catch {};
                    return status;
                }
                pending.clearRetainingCapacity();
            },
        }
    }
}

// =============================================================================
// Slash-side hooks — completion, syntax highlighting, custom actions
// =============================================================================

// Slash-defined custom-action IDs. Zigline's `Action.custom: u32` is the
// dispatch tag the keymap returns; the editor invokes `customActionHook`
// with this ID to run the action.
const ActionId = enum(u32) {
    edit_in_editor = 1,
};

// `execvp` isn't exposed in `std.c` for our target. Declare the minimum
// extern so `editInEditor` can spawn `$VISUAL`/`$EDITOR` by basename.
extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Slash's keymap. Intercepts Ctrl-X for the edit-in-editor action,
/// then falls through to zigline's default emacs bindings.
///
/// Note: Ctrl-X-E (the bash/emacs canonical sequence) requires
/// multi-keystroke sequence support which zigline doesn't yet ship.
/// Single-key Ctrl-X is the prototype binding until zigline adds the
/// binding-table API (their v1.0 blocker #2).
fn slashKeymapLookup(key: zigline.KeyEvent) ?zigline.Action {
    if (key.mods.ctrl) {
        switch (key.code) {
            .char => |c| switch (c) {
                'x' => return zigline.Action{ .custom = @intFromEnum(ActionId.edit_in_editor) },
                else => {},
            },
            else => {},
        }
    }
    return zigline.Keymap.defaultEmacs().lookup(key);
}

const slash_keymap: zigline.Keymap = .{ .lookupFn = slashKeymapLookup };

fn customActionHook(
    ctx_ptr: *anyopaque,
    allocator: Allocator,
    id: u32,
    request: zigline.CustomActionRequest,
    action_ctx: zigline.CustomActionContext,
) anyerror!zigline.CustomActionResult {
    const hooks: *SlashHooks = @ptrCast(@alignCast(ctx_ptr));
    return switch (@as(ActionId, @enumFromInt(id))) {
        .edit_in_editor => editInEditor(allocator, request, action_ctx, hooks),
    };
}

/// Open the current line in `$VISUAL` (or `$EDITOR`, or `vi`) via a
/// temp file. The spawn runs inside `withCookedMode`, which brackets
/// pause/resume of raw mode with proper error propagation. If the
/// editor exits non-zero (`:cq` in vim, segfault, exec failed) the
/// buffer is left untouched. Trailing whitespace from the editor is
/// stripped.
///
/// **Empty-buffer behavior** (zigline ≥ v0.1.5): when the user hits
/// Ctrl-X with nothing typed, the temp file is pre-filled with the
/// most-recent history entry — the bash `fc -e`/`Ctrl-X-Ctrl-E` "edit
/// my last command" pattern. Falls back to an empty file if history
/// is empty.
fn editInEditor(
    allocator: Allocator,
    request: zigline.CustomActionRequest,
    action_ctx: zigline.CustomActionContext,
    hooks: *const SlashHooks,
) anyerror!zigline.CustomActionResult {
    // Decide what bytes go into the temp file.
    //   - non-empty buffer → edit the buffer in place
    //   - empty buffer + history available → pre-fill with last entry
    //   - empty buffer + no history → start with an empty file
    const initial_text: []const u8 = if (request.buffer.len > 0)
        request.buffer
    else if (hooks.history.lastEntry()) |last|
        last
    else
        "";

    // Write the chosen bytes to a temp file. Use the pid to keep
    // concurrent slash processes from colliding.
    var path_buf: [128]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/slash-edit-{d}.sh",
        .{std.c.getpid()},
    );

    {
        const fd = std.c.open(
            tmp_path.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (fd < 0) return error.OpenFailed;
        defer _ = std.c.close(fd);
        var off: usize = 0;
        while (off < initial_text.len) {
            const n = std.c.write(fd, initial_text.ptr + off, initial_text.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
    defer _ = std.c.unlink(tmp_path.ptr);

    // Spawn the editor with raw mode paused. `withCookedMode` brackets
    // pause + spawn + resume; pause failure stops everything, spawn
    // failure propagates, and a failure to re-enter raw mode after a
    // successful spawn surfaces as the returned error (no silent
    // swallow). Returns the editor's exit code.
    const exit_code = try action_ctx.withCookedMode(tmp_path, spawnEditor);
    if (exit_code != 0) return .no_op;

    // Read the edited content back.
    const fd = std.c.open(tmp_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        try bytes.appendSlice(allocator, chunk[0..@intCast(n)]);
    }

    // Strip trailing newlines / carriage returns. Most editors append
    // a final \n; some emit \r\n; some emit a double \n.
    var content = try bytes.toOwnedSlice(allocator);
    while (content.len > 0 and (content[content.len - 1] == '\n' or
        content[content.len - 1] == '\r'))
    {
        content = try allocator.realloc(content, content.len - 1);
    }

    return .{ .replace_buffer = content };
}

/// Fork + execvp `$VISUAL`/`$EDITOR`/`vi` to edit `tmp_path`, wait
/// for it. Runs inside `withCookedMode` so the editor sees a normal
/// TTY. Returns the exit status (`0` = saved, anything else =
/// signaled / non-zero exit / exec failure).
fn spawnEditor(tmp_path: [:0]const u8) anyerror!u8 {
    const editor_env: [*:0]const u8 = std.c.getenv("VISUAL") orelse
        std.c.getenv("EDITOR") orelse
        @ptrCast("vi");
    var argv = [_:null]?[*:0]const u8{ editor_env, tmp_path.ptr };

    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = execvp(editor_env, &argv);
        std.c._exit(127);
    }

    var status: c_int = 0;
    while (true) {
        const r = std.c.waitpid(child, &status, 0);
        if (r >= 0) break;
        const e = std.c.errno(r);
        if (e == .INTR) continue;
        return error.WaitFailed;
    }

    const ux: u32 = @bitCast(status);
    if (!std.c.W.IFEXITED(ux)) return 1; // signaled / stopped → treat as cancel
    return std.c.W.EXITSTATUS(ux);
}

/// Context shared with the completion, highlight, and custom-action
/// hooks. Keeps `*anyopaque` casts honest at the boundary.
const SlashHooks = struct {
    session: *session_mod.Session,
    alloc: Allocator,
    /// Reference to the editor's history. Used by `editInEditor` to
    /// pre-fill the temp file with the most-recent command when the
    /// user hits Ctrl-X on an empty buffer (zigline ≥ v0.1.5).
    history: *zigline.History,
};

// -----------------------------------------------------------------------------
// Highlight — span-returning adapter over parser.BaseLexer
// -----------------------------------------------------------------------------
//
// The previous slash highlighter emitted ANSI escape sequences directly.
// zigline expects semantic spans (`HighlightSpan`); the renderer owns
// SGR generation. Spans must be sorted ascending by `start` and
// non-overlapping. For string_dq tokens, the body is walked so that
// `$var` / `${...}` / `$(...)` references emit yellow spans inside the
// surrounding green-string spans.

fn highlightHook(
    ctx_ptr: *anyopaque,
    allocator: Allocator,
    buffer: []const u8,
) anyerror![]zigline.HighlightSpan {
    _ = ctx_ptr;
    var spans: std.ArrayListUnmanaged(zigline.HighlightSpan) = .empty;
    errdefer spans.deinit(allocator);

    var lex = parser.BaseLexer.init(buffer);
    while (true) {
        const tok = lex.next();
        if (tok.cat == .eof) break;
        const start: usize = @intCast(tok.pos);
        const end_unclamped: usize = @as(usize, @intCast(tok.pos)) +
            @as(usize, @intCast(tok.len));
        const end = @min(buffer.len, end_unclamped);
        if (end <= start) continue;

        if (tok.cat == .string_dq) {
            try emitDqSpans(allocator, &spans, buffer, start, end);
            continue;
        }
        const style = styleFor(tok, buffer[start..end]) orelse continue;
        try spans.append(allocator, .{ .start = start, .end = end, .style = style });
    }

    return spans.toOwnedSlice(allocator);
}

fn styleFor(tok: parser.Token, span_bytes: []const u8) ?zigline.Style {
    return switch (tok.cat) {
        .ident => if (slash.keywordAs(span_bytes) != null)
            zigline.Style{ .fg = .{ .basic = .cyan }, .bold = true }
        else
            null,
        .integer => zigline.Style{ .fg = .{ .basic = .yellow } },
        .string_sq => zigline.Style{ .fg = .{ .basic = .green } },
        .variable, .var_braced, .dollar_paren, .at_paren => zigline.Style{ .fg = .{ .basic = .yellow } },
        .heredoc_body => zigline.Style{ .fg = .{ .basic = .green } },
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
        .lparen,
        .rparen,
        .lbrace,
        .rbrace,
        .lbracket,
        .rbracket,
        .semi,
        .and_and,
        .or_or,
        .amp,
        .comment,
        => zigline.Style{ .fg = .{ .basic = .white }, .dim = true },
        .err => zigline.Style{ .fg = .{ .basic = .red }, .bold = true, .underline = true },
        else => null,
    };
}

/// Walk a `"..."` token's body and emit alternating green / yellow
/// spans for the literal text and embedded `$var` / `${...}` /
/// `$(...)` references. Spans must remain non-overlapping (zigline's
/// renderer drops any inner span enclosed by an earlier-kept one),
/// so the body is split into sequential ranges rather than a wrapping
/// dq span with var spans inside.
fn emitDqSpans(
    allocator: Allocator,
    spans: *std.ArrayListUnmanaged(zigline.HighlightSpan),
    buffer: []const u8,
    start: usize,
    end: usize,
) !void {
    const green = zigline.Style{ .fg = .{ .basic = .green } };
    const yellow = zigline.Style{ .fg = .{ .basic = .yellow } };

    // The token covers `"..."` (or `"...` when the closing quote is
    // missing). Walk the interior; emit a green span up to each `$var`
    // boundary, then a yellow span for the var, then continue.
    var seg_start = start;
    var i = start + 1; // skip opening quote
    while (i < end) {
        const c = buffer[i];
        if (c == '\\' and i + 1 < end) {
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < end) {
            const n = buffer[i + 1];
            if (n == '{') {
                const close_rel = std.mem.indexOfScalarPos(u8, buffer[0..end], i + 2, '}');
                const var_end = if (close_rel) |x| x + 1 else end;
                if (i > seg_start) try spans.append(allocator, .{
                    .start = seg_start,
                    .end = i,
                    .style = green,
                });
                try spans.append(allocator, .{ .start = i, .end = var_end, .style = yellow });
                seg_start = var_end;
                i = var_end;
                continue;
            }
            if (n == '(') {
                var depth: u32 = 1;
                var j = i + 2;
                while (j < end) : (j += 1) {
                    if (buffer[j] == '(') depth += 1;
                    if (buffer[j] == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const var_end = if (j < end) j + 1 else end;
                if (i > seg_start) try spans.append(allocator, .{
                    .start = seg_start,
                    .end = i,
                    .style = green,
                });
                try spans.append(allocator, .{ .start = i, .end = var_end, .style = yellow });
                seg_start = var_end;
                i = var_end;
                continue;
            }
            if (isVarRefStart(n)) {
                var j = i + 2;
                while (j < end and isVarRefCont(buffer[j])) : (j += 1) {}
                if (i > seg_start) try spans.append(allocator, .{
                    .start = seg_start,
                    .end = i,
                    .style = green,
                });
                try spans.append(allocator, .{ .start = i, .end = j, .style = yellow });
                seg_start = j;
                i = j;
                continue;
            }
            if (isSpecialVarChar(n)) {
                if (i > seg_start) try spans.append(allocator, .{
                    .start = seg_start,
                    .end = i,
                    .style = green,
                });
                try spans.append(allocator, .{ .start = i, .end = i + 2, .style = yellow });
                seg_start = i + 2;
                i += 2;
                continue;
            }
        }
        i += 1;
    }
    if (seg_start < end) try spans.append(allocator, .{
        .start = seg_start,
        .end = end,
        .style = green,
    });
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

// -----------------------------------------------------------------------------
// Completion — replacement-range adapter over PATH + filesystem walk
// -----------------------------------------------------------------------------

fn completionHook(
    ctx_ptr: *anyopaque,
    allocator: Allocator,
    request: zigline.CompletionRequest,
) anyerror!zigline.CompletionResult {
    _ = ctx_ptr;
    const ctx = identifyCompletionContext(request.buffer, request.cursor_byte);

    var raw: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (raw.items) |s| allocator.free(s);
        raw.deinit(allocator);
    }

    switch (ctx.kind) {
        .command => try gatherCommandCandidates(allocator, ctx.prefix, &raw),
        .file => try gatherFileCandidates(allocator, ctx.prefix, &raw),
    }

    var candidates: std.ArrayListUnmanaged(zigline.Candidate) = .empty;
    errdefer {
        for (candidates.items) |c| {
            allocator.free(c.insert);
            if (c.display) |d| allocator.free(d);
        }
        candidates.deinit(allocator);
    }

    for (raw.items) |label| {
        // A trailing '/' on a candidate means "directory". Strip the
        // marker for `insert` and re-attach via the per-candidate
        // append rule the renderer will apply when only one matches.
        const is_dir = label.len > 0 and label[label.len - 1] == '/';
        const insert_text = try allocator.dupe(u8, if (is_dir) label[0 .. label.len - 1] else label);
        try candidates.append(allocator, .{
            .insert = insert_text,
            .kind = if (ctx.kind == .command) .command else if (is_dir) .directory else .file,
            .append = if (is_dir) '/' else if (ctx.kind == .command) ' ' else null,
        });
    }

    return .{
        .replacement_start = request.cursor_byte - ctx.prefix.len,
        .replacement_end = request.cursor_byte,
        .candidates = try candidates.toOwnedSlice(allocator),
    };
}

const CompletionKind = enum { command, file };

const CompletionContext = struct {
    kind: CompletionKind,
    /// Bytes of the partial token under the cursor.
    prefix: []const u8,
};

fn identifyCompletionContext(buf: []const u8, cursor_byte: usize) CompletionContext {
    var token_start = cursor_byte;
    while (token_start > 0) {
        const c = buf[token_start - 1];
        if (isSpace(c) or c == '|' or c == ';' or c == '&' or c == '(' or c == '{') break;
        token_start -= 1;
    }
    const prefix = buf[token_start..cursor_byte];

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
    allocator: Allocator,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    const path_env = std.c.getenv("PATH") orelse return;
    const path_str = std.mem.span(path_env);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit(allocator);
    }

    var dirs = std.mem.splitScalar(u8, path_str, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        try enumerateMatching(allocator, dir, prefix, out, &seen, .require_executable);
    }
}

fn gatherFileCandidates(
    allocator: Allocator,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    const slash_idx = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_part: []const u8 = if (slash_idx) |i| prefix[0 .. i + 1] else "";
    const base_part: []const u8 = if (slash_idx) |i| prefix[i + 1 ..] else prefix;
    const dir_path: []const u8 = if (dir_part.len == 0) "." else dir_part;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit(allocator);
    }

    try enumerateMatching(allocator, dir_path, base_part, out, &seen, .any);

    if (dir_part.len > 0) {
        for (out.items) |*cand| {
            const old = cand.*;
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_part, old });
            allocator.free(old);
            cand.* = combined;
        }
    }
}

const EnumerateMode = enum { any, require_executable };

fn enumerateMatching(
    allocator: Allocator,
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
        if (name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;

        if (mode == .require_executable) {
            var full_buf: [8192]u8 = undefined;
            const full = std.fmt.bufPrint(&full_buf, "{s}/{s}\x00", .{ dir_path, name }) catch continue;
            const full_z: [*:0]const u8 = @ptrCast(full.ptr);
            if (std.c.access(full_z, std.c.X_OK) != 0) continue;
        }

        const key = try allocator.dupe(u8, name);
        const gop = try seen.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            continue;
        }

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
        try out.append(allocator, try allocator.dupe(u8, label));
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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

// =============================================================================
// History path resolver — kept slash-side because the location is
// slash-specific (`~/.slash/history`). Falls back to in-memory only on
// failure.
// =============================================================================

fn resolveHistoryPath(allocator: Allocator) !?[]u8 {
    const home_env = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_env);
    if (home.len == 0) return null;

    const dir = try std.fmt.allocPrint(allocator, "{s}/.slash", .{home});
    defer allocator.free(dir);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    _ = std.c.mkdir(dir_z.ptr, 0o700);

    return try std.fmt.allocPrint(allocator, "{s}/history", .{dir});
}

// =============================================================================
// Shared parse/lower/run helpers
// =============================================================================

/// Parse + lower + run the buffered source. Three outcomes:
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
//
// At the prompt the parent shell catches `SIGINT` so any stray signal
// to the shell process group doesn't kill it. The line editor's
// Ctrl-C handling is independent — zigline turns `ISIG` off in raw
// mode, so the byte 0x03 reaches the editor's keymap rather than
// becoming a SIGINT. SIGTSTP / SIGTTIN / SIGTTOU stay ignored so a
// stray Ctrl-Z doesn't suspend slash. Children reset to defaults
// before exec already (see `exec.resetSignalDefaults`).

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

fn isStdinTty() bool {
    return std.c.isatty(0) != 0;
}

// =============================================================================
// Prompt rendering
// =============================================================================
//
// Default prompt: home-collapsed PWD, optional non-zero last status,
// then `$ ` (or `# ` for root). Pure ASCII bytes — no embedded ANSI —
// so `Prompt.plain` (which sets `width = bytes.len`) is correct.

fn renderPrompt(buf: []u8, session: *const session_mod.Session) []const u8 {
    var w = std.Io.Writer.fixed(buf);

    var cwd_buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&cwd_buf, cwd_buf.len);
    var cwd: []const u8 = "?";
    if (got != null) {
        const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
        cwd = cwd_buf[0..len];
    }

    if (std.c.getenv("HOME")) |home_env| {
        const home = std.mem.span(home_env);
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            w.writeAll("~") catch return "$ ";
            cwd = cwd[home.len..];
        }
    }
    w.writeAll(cwd) catch return "$ ";

    if (session.last_status != 0) {
        w.print(" [{d}]", .{session.last_status}) catch {};
    }

    const suffix: []const u8 = if (std.c.getuid() == 0) " # " else " $ ";
    w.writeAll(suffix) catch return "$ ";

    return w.buffered();
}

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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
// Tests — span-based highlighter
// =============================================================================

test "highlight: keywords get cyan + bold span" {
    const alloc = std.testing.allocator;
    const spans = try highlightHook(@ptrFromInt(0xdeadbeef), alloc, "if true { echo hi }");
    defer alloc.free(spans);

    var saw_keyword = false;
    var saw_dim = false;
    for (spans) |s| {
        if (s.style.bold) {
            if (s.style.fg) |fg| {
                if (fg == .basic and fg.basic == .cyan) saw_keyword = true;
            }
        }
        if (s.style.dim) saw_dim = true;
    }
    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_dim);
}

test "highlight: dq with embedded $var emits alternating green/yellow spans" {
    const alloc = std.testing.allocator;
    const spans = try highlightHook(@ptrFromInt(0xdeadbeef), alloc, "echo \"hi $name\"");
    defer alloc.free(spans);

    var has_green = false;
    var has_yellow = false;
    for (spans) |s| {
        if (s.style.fg) |fg| {
            if (fg == .basic and fg.basic == .green) has_green = true;
            if (fg == .basic and fg.basic == .yellow) has_yellow = true;
        }
    }
    try std.testing.expect(has_green);
    try std.testing.expect(has_yellow);
}

test "highlight: comment is dim" {
    const alloc = std.testing.allocator;
    const spans = try highlightHook(@ptrFromInt(0xdeadbeef), alloc, "echo a # trailing");
    defer alloc.free(spans);
    var saw_dim = false;
    for (spans) |s| if (s.style.dim) {
        saw_dim = true;
    };
    try std.testing.expect(saw_dim);
}

// -----------------------------------------------------------------------------
// Highlighter contract — non-overlap regression net
// -----------------------------------------------------------------------------
//
// zigline's renderer normalizes spans by sorting them and dropping any that
// overlap an earlier-kept span (`renderer.zig:normalizeSpans`). If slash's
// highlighter emits a "wrapping" span (e.g. one big `string_dq` span over
// the entire `"..."` followed by inner `$var` spans), the inner spans get
// silently dropped and the user sees a single color where slash intended
// alternation. This test pins the alternating-non-overlapping shape across
// every category-mix slash highlighter is expected to handle, so a future
// edit to `emitDqSpans` or `styleFor` that accidentally re-introduces a
// wrapping span fails loud.

fn assertSpansWellFormed(spans: []const zigline.HighlightSpan, buffer_len: usize) !void {
    var prev_end: usize = 0;
    for (spans) |s| {
        try std.testing.expect(s.start >= prev_end); // sorted, non-overlapping
        try std.testing.expect(s.end > s.start); // non-empty
        try std.testing.expect(s.end <= buffer_len); // in bounds
        prev_end = s.end;
    }
}

test "highlight: spans well-formed across slash's full input matrix" {
    const alloc = std.testing.allocator;

    const cases = [_][]const u8{
        // empty + minimal
        "",
        "echo hi",

        // keywords + delimiters
        "if true { echo x }",
        "for x in 1 2 3 { echo $x }",
        "x=1; y=2 && echo $y || echo nope",

        // strings + variables
        "echo 'literal'",
        "echo \"hello\"",
        "echo \"hi $name\"", // the case the constraint matters for
        "echo \"a ${name} b\"",
        "echo \"a $(date) b\"",
        "echo \"a $x b $y c\"", // multiple vars in one dq

        // multiple dq tokens on one line
        "echo \"a $x\" \"b $y\"",

        // var + cmd-sub + at-paren (lists)
        "echo $name ${name} $(echo hi) @(echo a b)",

        // pipes + redirects
        "ls -la | head -3 | wc -l > /tmp/out 2>&1",

        // heredoc
        "cat <<EOF\nhello\nEOF",

        // comments
        "echo a # trailing comment",
        "# leading comment only",

        // mixed everything — the stress case
        "if [[ -n \"$x\" ]] { for y in $(ls) { echo \"y=$y\" } }",
    };

    for (cases) |buf| {
        const spans = try highlightHook(@ptrFromInt(0xdeadbeef), alloc, buf);
        defer alloc.free(spans);
        assertSpansWellFormed(spans, buf.len) catch |e| {
            std.debug.print("highlighter failed well-formedness on: \"{s}\"\n", .{buf});
            std.debug.print("emitted {d} spans:\n", .{spans.len});
            for (spans, 0..) |s, idx| {
                std.debug.print("  [{d}] start={d} end={d}\n", .{ idx, s.start, s.end });
            }
            return e;
        };
    }
}

test "highlight: dq with embedded $var produces strict alternation (no wrapping span)" {
    const alloc = std.testing.allocator;
    const buf = "echo \"hi $name there\"";
    const spans = try highlightHook(@ptrFromInt(0xdeadbeef), alloc, buf);
    defer alloc.free(spans);

    // Find the dq-region spans (style is green or yellow). The dq token
    // covers `"hi $name there"` from byte 5 to byte 21; we expect at
    // least three spans within that range — a green prefix, a yellow
    // var, and a green suffix — none of which overlap.
    var dq_spans: std.ArrayListUnmanaged(zigline.HighlightSpan) = .empty;
    defer dq_spans.deinit(alloc);
    for (spans) |s| {
        if (s.start >= 5 and s.end <= 21) try dq_spans.append(alloc, s);
    }
    try std.testing.expect(dq_spans.items.len >= 3);

    // No span fully encloses another. (zigline's normalizer would drop
    // the inner one if it did, and slash would silently lose the var
    // highlighting.)
    for (dq_spans.items, 0..) |outer, i| {
        for (dq_spans.items, 0..) |inner, j| {
            if (i == j) continue;
            const fully_contains = outer.start <= inner.start and outer.end >= inner.end;
            const equal = outer.start == inner.start and outer.end == inner.end;
            try std.testing.expect(!fully_contains or equal);
        }
    }
}
