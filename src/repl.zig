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
const history_mod = @import("history.zig");
const notice = @import("notice.zig");
const completion = @import("completion.zig");
const prompt_mod = @import("prompt.zig");

// libc bindings — `std.c` doesn't expose these in Zig 0.16.
extern "c" fn getpgrp() std.c.pid_t;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

/// Wall-clock seconds since the unix epoch via `gettimeofday(2)`.
/// Used to time accepted-line durations for the history index.
fn nowSeconds() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.sec));
}
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
    bootstrapInteractive(session);
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
                uninstallChildEventHandler();
                eval.hangupRemainingJobs(session);
                _ = std.c.write(1, "\n", 1);
                return status;
            }
            try pending.append(alloc, '\n');
            _ = try evaluatePending(session, alloc, &pending);
            uninstallChildEventHandler();
            eval.hangupRemainingJobs(session);
            return session.last_status;
        }

        try pending.appendSlice(alloc, read_buf[0..@intCast(n)]);
        if (pending.items.len == 0 or pending.items[pending.items.len - 1] != '\n')
            continue;

        _ = try evaluatePending(session, alloc, &pending);

        if (session.exit_request) |req| {
            eval.fireExitTrap(session, alloc, null) catch {};
            uninstallChildEventHandler();
            eval.hangupRemainingJobs(session);
            return req.toStatusByte();
        }
    }
}

// =============================================================================
// Raw-mode loop driven by zigline.Editor
// =============================================================================

fn runRaw(session: *session_mod.Session, alloc: Allocator) !u8 {
    // History (chronological Up/Down) — owned by us; passed to the
    // editor by reference. Path is `~/.slash/history`; failures leave
    // history in-memory only.
    const hist_path = resolveHistoryPath(alloc) catch null;
    defer if (hist_path) |p| alloc.free(p);

    var history = try zigline.History.init(alloc, .{
        .path = hist_path,
        .max_entries = 1000,
        .dedupe = .adjacent,
    });
    defer history.deinit();

    // HistoryIndex (slash-side metadata-rich store) — captures every
    // accepted line with cwd / ts / status / duration; persists JSONL
    // under XDG. On first run, imports the legacy flat-file so users
    // don't lose their history. Failures (no HOME, no XDG, mkdir
    // denied) leave the index in-memory only — basic Up/Down via the
    // chronological zigline History keeps working.
    const jsonl_path = resolveHistoryJsonlPath(alloc) catch null;
    defer if (jsonl_path) |p| alloc.free(p);
    var hist_idx = try history_mod.HistoryIndex.init(alloc, jsonl_path);
    hist_idx.load(hist_path) catch {};
    session.history = hist_idx;
    // From now on, session.deinit owns the HistoryIndex's lifetime.
    // We keep a pointer alias for capture-on-accept convenience.

    var hooks = SlashHooks{
        .session = session,
        .alloc = alloc,
        .history = &history,
    };
    defer hooks.cleanup();

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
        .hint = .{
            .ctx = @ptrCast(&hooks),
            .hintFn = hintHook,
        },
        .custom_action = .{
            .ctx = @ptrCast(&hooks),
            .invokeFn = customActionHook,
        },
        .transient_input = .{
            .ctx = @ptrCast(&hooks),
            .updateFn = transientSearchHook,
        },
    });
    defer editor.deinit();

    var pending = std.ArrayListUnmanaged(u8).empty;
    defer pending.deinit(alloc);

    var prompt_buf: [4096]u8 = undefined;
    while (true) {
        // Drain any pre-prompt notice (last command's non-zero exit
        // status) before rendering the prompt, so the prompt itself
        // stays uncluttered and the failure shows up on its own line
        // above. See `notice.zig` for format and dim-on-tty rendering.
        if (pending.items.len == 0) notice.pendingExitStatus(session);
        const prompt_text = if (pending.items.len == 0)
            slashPrompt(&prompt_buf, session)
        else
            "... ";
        const prompt = zigline.Prompt{
            .bytes = prompt_text,
            .width = promptDisplayWidth(prompt_text),
        };
        hooks.fresh_prompt = pending.items.len == 0;

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
                const start_s: i64 = nowSeconds();
                _ = try evaluatePending(session, alloc, &pending);
                const end_s: i64 = nowSeconds();
                // Parse incomplete → keep accumulating; show `... ` next.
                const incomplete = pending.items.len == before_len and pending.items.len > 0;
                // Record a history event for every accepted line. For
                // a complete command, attach the just-observed exit
                // status and duration. For a multi-line continuation,
                // both are unknown (the user hasn't finished the
                // construct yet). We still record the physical line
                // so chronological recall mirrors zigline's flat
                // history.
                if (line.len > 0) {
                    if (session.history) |*hist| {
                        var cwd_buf: [4096]u8 = undefined;
                        const cwd: []const u8 = if (getcwd(&cwd_buf, cwd_buf.len)) |p|
                            std.mem.sliceTo(p, 0)
                        else
                            "?";
                        const status: ?u8 = if (incomplete) null else session.last_status;
                        const duration: ?u32 = if (incomplete) null else blk: {
                            const d = end_s - start_s;
                            if (d < 0) break :blk 0;
                            break :blk @intCast(d);
                        };
                        hist.append(line, cwd, status, duration) catch {};
                    }
                }

                if (incomplete) continue;

                if (session.exit_request) |req| {
                    eval.fireExitTrap(session, alloc, null) catch {};
                    uninstallChildEventHandler();
                    eval.hangupRemainingJobs(session);
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
                    uninstallChildEventHandler();
                    eval.hangupRemainingJobs(session);
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
    /// Space pressed at command position — try to expand a session
    /// `str` before inserting the literal space (PLAN §12).
    expand_str_space = 2,
    /// Enter pressed at command position — expand a session `str`
    /// and accept the rewritten line in one editor action.
    expand_str_enter = 3,
    /// Up arrow / Ctrl-P — smart prefix-aware history navigation when
    /// the buffer is non-empty; chronological zigline history when
    /// the buffer is empty.
    smart_history_prev = 4,
    /// Down arrow / Ctrl-N — counterpart to `smart_history_prev`.
    smart_history_next = 5,
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
    // Plain Space (no modifiers): route through the `str` expansion
    // hook. The hook returns `replace_buffer` (with expansion plus a
    // trailing space) when a candidate is found and a matching `str`
    // is set, or `insert_text(" ")` to mimic the default character
    // insert. Bracketed-paste content goes through zigline's
    // `handlePaste`, not key dispatch, so this hook never fires for
    // pasted Space bytes — paste suppression is automatic.
    if (!key.mods.ctrl and !key.mods.alt and !key.mods.shift) {
        switch (key.code) {
            .char => |c| if (c == ' ') return zigline.Action{ .custom = @intFromEnum(ActionId.expand_str_space) },
            .enter => return zigline.Action{ .custom = @intFromEnum(ActionId.expand_str_enter) },
            else => {},
        }
    }

    // Up / Down (and Ctrl-P / Ctrl-N) — route to smart history
    // navigation. The handler decides between chronological zigline
    // history (empty buffer; preserves muscle memory) and smart
    // prefix-aware ranked search (non-empty buffer; surfaces the
    // command you actually want).
    switch (key.code) {
        .arrow_up => return zigline.Action{ .custom = @intFromEnum(ActionId.smart_history_prev) },
        .arrow_down => return zigline.Action{ .custom = @intFromEnum(ActionId.smart_history_next) },
        .char => |c| if (key.mods.ctrl and !key.mods.alt and !key.mods.shift) {
            if (c == 'p') return zigline.Action{ .custom = @intFromEnum(ActionId.smart_history_prev) };
            if (c == 'n') return zigline.Action{ .custom = @intFromEnum(ActionId.smart_history_next) };
        },
        else => {},
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
        .expand_str_space => expandStrSpace(allocator, request, hooks),
        .expand_str_enter => expandStrEnter(allocator, request, hooks),
        .smart_history_prev => smartHistoryPrev(allocator, request, hooks),
        .smart_history_next => smartHistoryNext(allocator, request, hooks),
    };
}

// =============================================================================
// Reverse-i-search — Ctrl-R transient input hook
// =============================================================================
//
// zigline's default emacs keymap binds Ctrl-R to
// `Action.transient_input_open`; while transient mode is active the
// editor handles the keystrokes, manages a separate query buffer, and
// renders the overlay. Slash's role is to take the live query and
// surface a ranked match against the persistent `HistoryIndex`.
//
// On accept, zigline replaces the main buffer with the preview text
// (one undoable Replace). The line is NOT submitted; the user must
// press Enter again to run it. That matches bash/zsh Ctrl-R UX and
// keeps slash from running a command the user only asked to find.
//
// The hook is consulted on every transient event:
//   - `.opened`      — fresh transient mode, query is empty
//   - `.query_changed` — user typed/deleted in the query
//   - `.next`        — Ctrl-R again, advance to the next older match
//   - `.aborted`     — Esc / Ctrl-G / Ctrl-C / EOF; clean up state

fn transientSearchHook(
    ctx_ptr: *anyopaque,
    request: zigline.TransientInputRequest,
) anyerror!zigline.TransientInputResult {
    const hooks: *SlashHooks = @ptrCast(@alignCast(ctx_ptr));
    return runTransientSearch(hooks, request);
}

fn runTransientSearch(
    hooks: *SlashHooks,
    request: zigline.TransientInputRequest,
) !zigline.TransientInputResult {
    if (request.event == .aborted) {
        hooks.search_state.deinit(hooks.alloc);
        return .{};
    }

    const idx = if (hooks.session.history) |*h| h else {
        const status = std.fmt.bufPrint(
            &hooks.search_state.status_buf,
            "(no history): ",
            .{},
        ) catch "(no history): ";
        return .{ .preview = null, .status = status };
    };

    switch (request.event) {
        .opened => {
            hooks.search_state.deinit(hooks.alloc);
            const status = std.fmt.bufPrint(
                &hooks.search_state.status_buf,
                "(reverse-i-search): ",
                .{},
            ) catch "(reverse-i-search): ";
            return .{ .preview = null, .status = status };
        },
        .query_changed => {
            var cwd_buf: [4096]u8 = undefined;
            const cwd: []const u8 = if (getcwd(&cwd_buf, cwd_buf.len)) |p|
                std.mem.sliceTo(p, 0)
            else
                "?";
            try hooks.search_state.refresh(hooks.alloc, idx, request.query, cwd);
        },
        .next => {
            if (hooks.search_state.results.len > 0) {
                if (hooks.search_state.cycle + 1 < hooks.search_state.results.len) {
                    hooks.search_state.cycle += 1;
                } else {
                    // Past the oldest match: surface the failing
                    // status while keeping the last preview pinned.
                    // Bash/zsh behave the same way — Ctrl-R past the
                    // bottom does not wrap.
                    const status = std.fmt.bufPrint(
                        &hooks.search_state.status_buf,
                        "(failing-i-search) `{s}': ",
                        .{request.query},
                    ) catch "(failing-i-search): ";
                    return .{
                        .preview = hooks.search_state.results[hooks.search_state.cycle].line,
                        .status = status,
                    };
                }
            }
        },
        .aborted => unreachable,
    }

    if (hooks.search_state.results.len > 0) {
        const status = std.fmt.bufPrint(
            &hooks.search_state.status_buf,
            "(reverse-i-search) `{s}': ",
            .{request.query},
        ) catch "(reverse-i-search): ";
        return .{
            .preview = hooks.search_state.results[hooks.search_state.cycle].line,
            .status = status,
        };
    }

    const status = if (request.query.len == 0)
        std.fmt.bufPrint(
            &hooks.search_state.status_buf,
            "(reverse-i-search): ",
            .{},
        ) catch "(reverse-i-search): "
    else
        std.fmt.bufPrint(
            &hooks.search_state.status_buf,
            "(failing-i-search) `{s}': ",
            .{request.query},
        ) catch "(failing-i-search): ";
    return .{ .preview = null, .status = status };
}

fn hintHook(
    ctx_ptr: *anyopaque,
    request: zigline.HintRequest,
) anyerror!?zigline.HintResult {
    const hooks: *SlashHooks = @ptrCast(@alignCast(ctx_ptr));
    if (!hooks.fresh_prompt) return null;
    if (request.cursor_byte != request.buffer.len) return null;
    if (request.buffer.len == 0) return null;

    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (getcwd(&cwd_buf, cwd_buf.len)) |p|
        std.mem.sliceTo(p, 0)
    else
        "?";

    const suffix = try historyHintSuffix(
        hooks.alloc,
        hooks.session,
        request.buffer,
        cwd,
    ) orelse return null;
    if (suffix.len == 0) return null;
    return zigline.HintResult{ .text = suffix };
}

fn historyHintSuffix(
    alloc: Allocator,
    session: *session_mod.Session,
    prefix: []const u8,
    cwd: []const u8,
) !?[]const u8 {
    if (prefix.len == 0) return null;
    const idx = if (session.history) |*h| h else return null;
    const results = try idx.search(alloc, prefix, cwd, .prefix, 8);
    defer alloc.free(results);
    for (results) |candidate| {
        const line = candidate.line;
        if (line.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        return line[prefix.len..];
    }
    return null;
}

test "hint: history prefix search returns only suffix" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("git status --short", "/repo", 0, 1);

    const suffix = try historyHintSuffix(std.testing.allocator, &s, "git st", "/repo");
    try std.testing.expectEqualStrings("atus --short", suffix.?);
}

test "hint: empty and exact prefixes produce no suggestion" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("git status", "/repo", 0, 1);

    try std.testing.expect(try historyHintSuffix(std.testing.allocator, &s, "", "/repo") == null);
    try std.testing.expect(try historyHintSuffix(std.testing.allocator, &s, "git status", "/repo") == null);
}

test "hint: exact match does not mask longer prefix candidate" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("git status", "/repo", 0, 1);
    try s.history.?.append("git status --short", "/repo", 0, 1);

    const suffix = try historyHintSuffix(std.testing.allocator, &s, "git status", "/repo");
    try std.testing.expectEqualStrings(" --short", suffix.?);
}

// -----------------------------------------------------------------------------
// Reverse-i-search hook (Ctrl-R) — unit tests
// -----------------------------------------------------------------------------
//
// Drives `transientSearchHook` directly with synthetic events so the
// state machine is exercised without spinning up a real editor.

fn makeSearchHooks(s: *session_mod.Session, history: *zigline.History) SlashHooks {
    return SlashHooks{ .session = s, .alloc = std.testing.allocator, .history = history };
}

test "search: opened with no history → '(no history): '" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    const result = try transientSearchHook(@ptrCast(&hooks), .{
        .original_buffer = "",
        .original_cursor_byte = 0,
        .query = "",
        .query_cursor_byte = 0,
        .event = .opened,
    });
    try std.testing.expect(result.preview == null);
    try std.testing.expect(std.mem.indexOf(u8, result.status orelse "", "no history") != null);
}

test "search: query_changed surfaces the most-recent matching command" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("ls -la", "/repo", 0, 0);
    try s.history.?.append("git status", "/repo", 0, 0);
    try s.history.?.append("git log --oneline", "/repo", 0, 0);
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    _ = try transientSearchHook(@ptrCast(&hooks), .{
        .original_buffer = "",
        .original_cursor_byte = 0,
        .query = "",
        .query_cursor_byte = 0,
        .event = .opened,
    });
    const result = try transientSearchHook(@ptrCast(&hooks), .{
        .original_buffer = "",
        .original_cursor_byte = 0,
        .query = "git",
        .query_cursor_byte = 3,
        .event = .query_changed,
    });
    try std.testing.expect(result.preview != null);
    try std.testing.expect(std.mem.startsWith(u8, result.preview.?, "git "));
    try std.testing.expect(std.mem.indexOf(u8, result.status orelse "", "reverse-i-search") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.status orelse "", "git") != null);
}

test "search: .next advances to the next-older match" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("git status", "/repo", 0, 0);
    try s.history.?.append("git log --oneline", "/repo", 0, 0);
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "", .query_cursor_byte = 0, .event = .opened });
    const first = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "git", .query_cursor_byte = 3, .event = .query_changed });
    const second = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "git", .query_cursor_byte = 3, .event = .next });

    try std.testing.expect(first.preview != null);
    try std.testing.expect(second.preview != null);
    try std.testing.expect(!std.mem.eql(u8, first.preview.?, second.preview.?));
}

test "search: .next past the last match keeps preview, surfaces failing status" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("only one match", "/repo", 0, 0);
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "", .query_cursor_byte = 0, .event = .opened });
    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "match", .query_cursor_byte = 5, .event = .query_changed });
    const next = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "match", .query_cursor_byte = 5, .event = .next });

    try std.testing.expectEqualStrings("only one match", next.preview.?);
    try std.testing.expect(std.mem.indexOf(u8, next.status orelse "", "failing-i-search") != null);
}

test "search: empty query renders no preview" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("anything", "/repo", 0, 0);
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "", .query_cursor_byte = 0, .event = .opened });
    const result = try transientSearchHook(@ptrCast(&hooks), .{
        .original_buffer = "",
        .original_cursor_byte = 0,
        .query = "",
        .query_cursor_byte = 0,
        .event = .query_changed,
    });
    try std.testing.expect(result.preview == null);
}

test "search: aborted releases the candidate slice" {
    var s = try session_mod.Session.init(std.testing.allocator, @ptrCast(@alignCast(std.c.environ)), false);
    defer s.deinit();
    s.history = try history_mod.HistoryIndex.init(std.testing.allocator, null);
    try s.history.?.append("git status", "/repo", 0, 0);
    var h = try zigline.History.init(std.testing.allocator, .{});
    defer h.deinit();

    var hooks = makeSearchHooks(&s, &h);
    defer hooks.cleanup();

    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "", .query_cursor_byte = 0, .event = .opened });
    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "git", .query_cursor_byte = 3, .event = .query_changed });
    try std.testing.expect(hooks.search_state.results.len > 0);

    _ = try transientSearchHook(@ptrCast(&hooks), .{ .original_buffer = "", .original_cursor_byte = 0, .query = "git", .query_cursor_byte = 3, .event = .aborted });
    try std.testing.expectEqual(@as(usize, 0), hooks.search_state.results.len);
}

// =============================================================================
// Smart history navigation — prefix-aware ranked Up/Down
// =============================================================================
//
// The behavior matches GPT-5.5's design call:
//
//   - Empty buffer: chronological (zigline's flat-file `History`),
//     so muscle memory ("Up = last thing I ran") is preserved.
//
//   - Non-empty buffer: ranked search via `session.history`, prefix
//     mode. Up walks toward better-ranked matches; Down walks back
//     toward the originally-typed prefix. Ranking pulls from the
//     same `HistoryIndex` that backs the `history` builtin.
//
// Detection of "user edited mid-nav" relies on comparing the live
// buffer to the candidate we last pushed: if they differ, the user
// has typed and we treat the next Up as starting a fresh nav.

fn smartHistoryPrev(
    allocator: Allocator,
    request: zigline.CustomActionRequest,
    hooks: *SlashHooks,
) anyerror!zigline.CustomActionResult {
    // Empty buffer → chronological zigline history.
    if (request.buffer.len == 0) {
        hooks.resetNav();
        if (hooks.history.previous(request.buffer)) |prev| {
            return .{ .replace_buffer = try allocator.dupe(u8, prev) };
        }
        return .{ .insert_text = try allocator.dupe(u8, "") };
    }

    // Non-empty buffer → smart ranked nav.
    if (hooks.session.history) |*idx| {
        if (hooks.nav) |*nav| {
            const buf_matches_current = nav.idx >= 0 and
                @as(usize, @intCast(nav.idx)) < nav.results.len and
                std.mem.eql(u8, request.buffer, nav.results[@intCast(nav.idx)].line);
            if (!buf_matches_current) {
                // User edited mid-nav. Treat as fresh search.
                hooks.resetNav();
            }
        }

        if (hooks.nav == null) try beginNav(allocator, hooks, request.buffer, idx);
        if (hooks.nav) |*nav| {
            if (nav.results.len == 0) {
                return .{ .insert_text = try allocator.dupe(u8, "") };
            }
            // Advance toward older / lower-ranked results. Clamp at end.
            const next_idx: isize = if (nav.idx + 1 < @as(isize, @intCast(nav.results.len)))
                nav.idx + 1
            else
                nav.idx;
            nav.idx = next_idx;
            const line = nav.results[@intCast(nav.idx)].line;
            return .{ .replace_buffer = try allocator.dupe(u8, line) };
        }
    }

    // No HistoryIndex (non-interactive entry point misuse) — fall
    // back to zigline's history.
    if (hooks.history.previous(request.buffer)) |prev| {
        return .{ .replace_buffer = try allocator.dupe(u8, prev) };
    }
    return .{ .insert_text = try allocator.dupe(u8, "") };
}

fn smartHistoryNext(
    allocator: Allocator,
    request: zigline.CustomActionRequest,
    hooks: *SlashHooks,
) anyerror!zigline.CustomActionResult {
    // If we're in a smart-nav session, walk back through results
    // (newest → oldest reversed). At idx 0, restore the original
    // prefix the user had typed. Subsequent Down does nothing.
    if (hooks.nav) |*nav| {
        const buf_matches_current = nav.idx >= 0 and
            @as(usize, @intCast(nav.idx)) < nav.results.len and
            std.mem.eql(u8, request.buffer, nav.results[@intCast(nav.idx)].line);
        if (buf_matches_current) {
            if (nav.idx == 0) {
                // Step out of nav — restore the prefix the user had typed.
                const prefix_copy = try allocator.dupe(u8, nav.prefix);
                hooks.resetNav();
                return .{ .replace_buffer = prefix_copy };
            }
            nav.idx -= 1;
            const line = nav.results[@intCast(nav.idx)].line;
            return .{ .replace_buffer = try allocator.dupe(u8, line) };
        }
        hooks.resetNav();
    }

    // Otherwise: chronological zigline history Down (returns the
    // saved snapshot or the empty string).
    if (hooks.history.next()) |nx| {
        return .{ .replace_buffer = try allocator.dupe(u8, nx) };
    }
    return .{ .insert_text = try allocator.dupe(u8, "") };
}

fn beginNav(
    _: Allocator,
    hooks: *SlashHooks,
    buffer: []const u8,
    idx: *history_mod.HistoryIndex,
) !void {
    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (getcwd(&cwd_buf, cwd_buf.len)) |p|
        std.mem.sliceTo(p, 0)
    else
        "?";

    const results = try idx.search(hooks.alloc, buffer, cwd, .prefix, 100);
    errdefer hooks.alloc.free(results);

    const prefix_copy = try hooks.alloc.dupe(u8, buffer);
    errdefer hooks.alloc.free(prefix_copy);

    hooks.nav = .{
        .prefix = prefix_copy,
        .results = results,
        .idx = -1,
    };
}

/// Space-key expansion hook. Returns the buffer rewritten with the
/// matched `str`'s RHS plus a trailing space, or `insert_text` of a
/// single space if no candidate matches or the candidate isn't set.
/// The trailing space is part of the rewrite (rather than a follow-up
/// insert) so zigline records the whole transformation as one undo
/// step.
///
/// Empty stored values are a real, distinct state: the candidate
/// gets *deleted* from the buffer (`prefix + "" + " " == prefix + " "`).
/// This is observably different from "name unset," which inserts a
/// literal space without disturbing the candidate.
fn expandStrSpace(
    allocator: Allocator,
    request: zigline.CustomActionRequest,
    hooks: *const SlashHooks,
) anyerror!zigline.CustomActionResult {
    const fallback_space = " ";
    const candidate = strCandidate(request.buffer, request.cursor_byte) orelse {
        return .{ .insert_text = try allocator.dupe(u8, fallback_space) };
    };
    const rhs = hooks.session.strs.lookup(candidate) orelse {
        return .{ .insert_text = try allocator.dupe(u8, fallback_space) };
    };

    const prefix_len = request.buffer.len - candidate.len;
    var out = try allocator.alloc(u8, prefix_len + rhs.len + 1);
    @memcpy(out[0..prefix_len], request.buffer[0..prefix_len]);
    @memcpy(out[prefix_len .. prefix_len + rhs.len], rhs);
    out[out.len - 1] = ' ';
    return .{ .replace_buffer = out };
}

/// Enter-key counterpart to `expandStrSpace`. If the buffer ends in a
/// command-position `str` name, accept the expansion as the line that
/// will be evaluated; otherwise behave like ordinary Enter.
fn expandStrEnter(
    allocator: Allocator,
    request: zigline.CustomActionRequest,
    hooks: *const SlashHooks,
) anyerror!zigline.CustomActionResult {
    const candidate = strCandidate(request.buffer, request.cursor_byte) orelse return .accept_line;
    const rhs = hooks.session.strs.lookup(candidate) orelse return .accept_line;

    const prefix_len = request.buffer.len - candidate.len;
    var out = try allocator.alloc(u8, prefix_len + rhs.len);
    @memcpy(out[0..prefix_len], request.buffer[0..prefix_len]);
    @memcpy(out[prefix_len..], rhs);
    return .{ .replace_buffer_and_accept = out };
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
        // Reset signal dispositions before execve. Ignored signals
        // (SIG_IGN) survive execve on POSIX — without this, the editor
        // would inherit the shell's interactive ignores for SIGINT,
        // SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE and Ctrl-C/Ctrl-Z
        // wouldn't work inside vim. (Handlers reset to SIG_DFL across
        // execve automatically; ignores do not. CHECKLIST §6.)
        //
        // Note: this fork path intentionally does NOT do the full
        // job-control discipline (setpgid + tcsetpgrp + termios save/
        // restore). The Ctrl-X "edit one command line" flow is meant
        // to be a quick modal pop into $EDITOR — slash blocks on
        // waitpid for the duration. Users who want a real editor
        // session type `vim` at the prompt, which goes through
        // `eval.serviceForeground` and gets the full discipline. If
        // the editor needs Ctrl-Z while inside the Ctrl-X popup, that
        // would require expanding this path; until then it's a
        // documented limitation, not a bug.
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const defaults = [_]std.c.SIG{
            .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD, .HUP,
        };
        for (defaults) |sig| std.posix.sigaction(sig, &sa, null);
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
    /// Reference to the editor's chronological history (zigline's
    /// flat-file `History`). Drives Up/Down when the buffer is
    /// empty (so muscle memory is preserved) and feeds
    /// `editInEditor`'s "Ctrl-X on empty buffer pre-fills the last
    /// command" behavior.
    history: *zigline.History,
    /// True when the active editor prompt is a new command line, false
    /// for continuation prompts that are still accumulating a compound
    /// form.
    fresh_prompt: bool = true,

    /// Smart-Up/Down navigation state. Populated on the first Up
    /// press while the buffer is non-empty, mutated as the user
    /// cycles, cleared when the user types something non-Up/Down or
    /// when Down walks back past the first match.
    nav: ?NavState = null,

    /// Live state for the Ctrl-R reverse-i-search overlay. Owns the
    /// candidate slice returned by `HistoryIndex.search` plus a small
    /// scratch buffer used to format the dim status line that zigline
    /// renders in transient mode.
    search_state: TransientSearchState = .{},

    fn resetNav(self: *SlashHooks) void {
        if (self.nav) |*n| n.deinit(self.alloc);
        self.nav = null;
    }

    fn cleanup(self: *SlashHooks) void {
        self.resetNav();
        self.search_state.deinit(self.alloc);
    }
};

/// Reverse-i-search bookkeeping for the zigline `transient_input`
/// hook. Owns the ranked-results slice and the formatted status text;
/// the line bytes inside the candidates are borrowed from the
/// `HistoryIndex` arena and live for the session's lifetime.
const TransientSearchState = struct {
    results: []history_mod.HistoryCandidate = &.{},
    /// Index into `results` advanced by Ctrl-R repeats.
    cycle: usize = 0,
    /// Backing buffer for the formatted status string; kept as a
    /// hook-scoped scratch area so the borrowed slice the hook hands
    /// back to zigline stays valid until the next call.
    status_buf: [256]u8 = undefined,

    fn deinit(self: *TransientSearchState, alloc: Allocator) void {
        if (self.results.len > 0) alloc.free(self.results);
        self.results = &.{};
        self.cycle = 0;
    }

    /// Rerun a substring search against `idx` for the live query and
    /// reset the cycle to the top match. Old results are freed first.
    fn refresh(
        self: *TransientSearchState,
        alloc: Allocator,
        idx: *const history_mod.HistoryIndex,
        query: []const u8,
        cwd: []const u8,
    ) !void {
        if (self.results.len > 0) alloc.free(self.results);
        self.results = &.{};
        self.cycle = 0;
        // Empty query → no preview. Avoid emitting the entire history
        // as a 5000-entry candidate set — wasteful, and bash/zsh
        // don't render anything for an empty Ctrl-R query either.
        if (query.len == 0) return;
        self.results = try idx.search(alloc, query, cwd, .substring, 100);
    }
};

/// Snapshot of an in-progress smart-history navigation. Owns the
/// captured prefix bytes and the search-result slice.
const NavState = struct {
    /// The buffer text at the moment Up was first pressed. Restored
    /// when Down walks back past the first result.
    prefix: []u8,
    /// Ranked search results — borrowed slices into `session.history`'s
    /// arena (valid for the session's lifetime). The outer slice
    /// itself is owned by `alloc`.
    results: []history_mod.HistoryCandidate,
    /// Position in `results`. -1 means "back to prefix" (Down past
    /// the start). Otherwise an index into `results`.
    idx: isize,

    fn deinit(self: *NavState, alloc: Allocator) void {
        alloc.free(self.prefix);
        alloc.free(self.results);
    }
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
    request: zigline.HighlightRequest,
) anyerror![]zigline.HighlightSpan {
    const hooks: *SlashHooks = @ptrCast(@alignCast(ctx_ptr));
    const palette = pickPalette(hooks.session);
    return highlightBuffer(allocator, request.buffer, request.cursor_byte, palette);
}

/// The highlighter core, separated from the hook entry so tests can
/// invoke it with an explicit palette and cursor without faking a
/// `SlashHooks` context.
///
/// Walks `parser.BaseLexer` tokens left-to-right, tracking a small
/// "command position" flag so non-keyword `.ident` tokens at the
/// start of a command get colored as commands and subsequent idents
/// get colored as arguments. The flag resets to true after any
/// command-starter (`;`, `|`, `&&`, `||`, `&`, `{`, `(`, `[`) and
/// after a control-flow keyword like `if`/`while`/`for`/`cmd`.
///
/// Bracket matching: when the cursor is on (or just past) a closing
/// bracket, find the matching opener and emit a styled span over it
/// instead of the normal operator style. (zigline's renderer drops
/// overlapping spans with a longer-on-equal-start tie-break, so we
/// substitute the bracket's own span rather than layering a second.)
fn highlightBuffer(
    allocator: Allocator,
    buffer: []const u8,
    cursor_byte: usize,
    palette: Palette,
) anyerror![]zigline.HighlightSpan {
    const match_pos = findMatchingBracket(buffer, cursor_byte);

    var spans: std.ArrayListUnmanaged(zigline.HighlightSpan) = .empty;
    errdefer spans.deinit(allocator);

    // Command-position tracker: true iff the next non-keyword `.ident`
    // is the start of a new command (not an argument). Starts true
    // (start of input is command position).
    var at_command_pos = true;

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
            try emitDqSpans(allocator, &spans, buffer, start, end, palette);
            at_command_pos = false;
            continue;
        }
        if (match_pos != null and match_pos.? == start and isOpenBracketTok(tok.cat)) {
            try spans.append(allocator, .{
                .start = start,
                .end = end,
                .style = .{ .fg = palette.bracket_match, .bold = true },
            });
            at_command_pos = isCommandStarter(tok.cat);
            continue;
        }

        // Special handling for `.ident`: distinguish keyword / command /
        // argument by current position.
        if (tok.cat == .ident) {
            const span_bytes = buffer[start..end];
            if (slash.keywordAs(span_bytes) != null) {
                try spans.append(allocator, .{
                    .start = start,
                    .end = end,
                    .style = .{ .fg = palette.keyword, .bold = true },
                });
                // Most slash keywords introduce another command (the
                // test of an `if`, the body of `for`, the name of `cmd`).
                // After a keyword, the next ident is again at command
                // position.
                at_command_pos = true;
                continue;
            }
            // NAME=value assignment: the BaseLexer the highlighter uses
            // splits `FOO=bar` into `.ident FOO` + `.assign =` + `.ident
            // bar`, but the slash parser (via the wrapper lexer) sees a
            // fused `.name_eq` covering `FOO=`. Mirror that semantic at
            // the highlight layer by coloring the ident as a variable
            // when an unquoted `=` (and not `==`) follows immediately.
            const followed_by_assign = end < buffer.len and
                buffer[end] == '=' and
                !(end + 1 < buffer.len and buffer[end + 1] == '=');
            if (followed_by_assign) {
                try spans.append(allocator, .{
                    .start = start,
                    .end = end,
                    .style = .{ .fg = palette.variable },
                });
                // The LHS does not consume the command-position slot —
                // a leading `FOO=value cmd` keeps `cmd` at command pos.
                continue;
            }
            const fg = if (at_command_pos) palette.command else palette.argument;
            const base_style = zigline.Style{ .fg = fg };
            if (containsGlobChar(span_bytes)) {
                try emitIdentWithGlobs(allocator, &spans, buffer, start, end, base_style, palette);
            } else {
                try spans.append(allocator, .{ .start = start, .end = end, .style = base_style });
            }
            at_command_pos = false;
            continue;
        }

        const style_opt = styleFor(tok, buffer[start..end], palette);
        if (style_opt) |style| {
            try spans.append(allocator, .{ .start = start, .end = end, .style = style });
        }
        // Sticky NAME_EQ: env-prefix keeps the state at command
        // position; argument-position NAME_EQ leaves us in argument
        // position. See `strCandidate` for the same reasoning.
        if (tok.cat != .name_eq) {
            at_command_pos = isCommandStarter(tok.cat);
        }
    }

    return spans.toOwnedSlice(allocator);
}

/// Tokens after which the next `.ident` returns to command position.
/// Note: `lparen`/`lbrace`/`lbracket` count as starters because slash
/// uses them to introduce subshells, blocks, and groupings — each
/// contains a fresh sequence of commands.
///
/// `name_eq` is intentionally NOT here: it's a sticky no-op rather
/// than a starter (handled by callers — see the comment at each call
/// site). In `FOO=1 ll`, `ll` is at command position because we
/// haven't yet consumed a leading word; in `echo FOO=ll`, `ll` is at
/// argument position because `echo` already consumed the leading
/// word slot. `last_cat` alone can't distinguish those two; the
/// state needs the additional "have we seen a leading word since
/// the last separator?" bit, which the call site tracks.
fn isCommandStarter(cat: parser.TokenCat) bool {
    return switch (cat) {
        .pipe,
        .semi,
        .and_and,
        .or_or,
        .amp,
        .lbrace,
        .lparen,
        .lbracket,
        => true,
        else => false,
    };
}

/// Slash keywords whose immediately-following IDENT is a *name slot*,
/// not a command-position word. After `cmd ll`, `for x`, or
/// `match val`, the IDENT names a definition/loop-variable/value, so
/// it must not be promoted to a command-position candidate that
/// would trigger `str` expansion. Keywords like `if`, `while`, `else`
/// are NOT in this set — what follows them IS at command position
/// (the test of the conditional / loop body).
///
/// `str` is intentionally absent: it isn't promoted by `keywordAs`
/// at all (the brace form goes through wrapper-emitted `STR_OPEN`,
/// not keyword promotion), so this branch never sees `str` and
/// listing it would be dead code.
fn keywordTakesNameSlot(name: []const u8) bool {
    return std.mem.eql(u8, name, "cmd") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "match");
}

fn isOpenBracketTok(cat: parser.TokenCat) bool {
    return switch (cat) {
        .lbrace, .lparen, .lbracket => true,
        else => false,
    };
}

/// Locate a candidate `str` LHS: a bare `.ident` that ends exactly at
/// `cursor_byte`, sits at command position, and is not a slash
/// keyword. Returns the byte slice of that ident, or `null` if no
/// such candidate exists.
///
/// Walks `parser.BaseLexer` and tracks an `at_command_pos` state
/// machine. Two subtleties:
///
///   - **Sticky NAME_EQ.** The fused `NAME=` token (e.g. `FOO=`)
///     keeps command position when we were already at command
///     position (env-prefix on a fresh simple-command) but does not
///     promote argument position back to command position. So
///     `FOO=1 ll<space>` expands `ll` (it's the leading word) but
///     `echo FOO=ll<space>` does NOT (it's an argument).
///
///   - **Keyword name slot.** After `cmd`/`for`/`match`, the next
///     IDENT is a definition/loop-variable/value name, not a
///     command-position word. Don't promote it.
///
/// Cursor must be at end-of-buffer; mid-buffer expansion would need
/// a zigline range-replace API which v0.3.x lacks.
pub fn strCandidate(buffer: []const u8, cursor_byte: usize) ?[]const u8 {
    if (cursor_byte != buffer.len) return null;
    if (buffer.len == 0) return null;

    var at_command_pos = true;
    var next_ident_is_name_slot = false;
    var lex = parser.BaseLexer.init(buffer);
    var candidate: ?[]const u8 = null;
    while (true) {
        const tok = lex.next();
        if (tok.cat == .eof) break;
        const start: usize = @intCast(tok.pos);
        const end_unclamped: usize = start + @as(usize, @intCast(tok.len));
        const end = @min(buffer.len, end_unclamped);

        if (tok.cat == .ident) {
            const span = buffer[start..end];
            if (slash.keywordAs(span) != null) {
                at_command_pos = true;
                next_ident_is_name_slot = keywordTakesNameSlot(span);
                candidate = null;
                continue;
            }
            if (next_ident_is_name_slot) {
                next_ident_is_name_slot = false;
                candidate = null;
                at_command_pos = false;
                continue;
            }
            if (at_command_pos and end == buffer.len) {
                candidate = span;
            } else {
                candidate = null;
            }
            at_command_pos = false;
            continue;
        }

        // Non-ident token. Update command-position state, but with
        // the sticky NAME_EQ rule: NAME_EQ leaves `at_command_pos`
        // unchanged (env-prefix preserves it; argument-position
        // doesn't promote it). All other non-starters reset to
        // false; starters reset to true.
        candidate = null;
        next_ident_is_name_slot = false;
        if (tok.cat != .name_eq) {
            at_command_pos = isCommandStarter(tok.cat);
        }
    }
    return candidate;
}

/// When the cursor sits on (or just past) a closing bracket, find the
/// byte offset of the matching opener. Returns `null` if the cursor
/// isn't on a close bracket, or if no matching opener is in scope
/// (unbalanced source).
///
/// Uses `parser.BaseLexer` to walk bracket tokens, so brackets inside
/// `"..."` strings, `'...'` strings, comments, heredoc bodies, and
/// `${...}`/`$(...)` (each is a single token at this level) are
/// automatically excluded from the matching search.
fn findMatchingBracket(buffer: []const u8, cursor_byte: usize) ?usize {
    // Cheap precondition: cursor must be on or just after a closing
    // bracket byte. Skips the lex walk for the typical keystroke.
    const on_close = cursor_byte < buffer.len and isCloseBracketByte(buffer[cursor_byte]);
    const after_close = cursor_byte > 0 and isCloseBracketByte(buffer[cursor_byte - 1]);
    if (!on_close and !after_close) return null;

    // Maintain three small stacks (brace / paren / bracket) of recent
    // unmatched-opener positions. Walk tokens left-to-right; on each
    // closer, pop the matching stack. The closer at `cursor_byte` (or
    // `cursor_byte - 1`) is our target — when we reach it, the top of
    // its stack is the match.
    const STACK_DEPTH = 32;
    var brace_stack: [STACK_DEPTH]u32 = undefined;
    var paren_stack: [STACK_DEPTH]u32 = undefined;
    var bracket_stack: [STACK_DEPTH]u32 = undefined;
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    var lex = parser.BaseLexer.init(buffer);
    while (true) {
        const tok = lex.next();
        if (tok.cat == .eof) break;
        const pos: usize = @intCast(tok.pos);

        // Did we reach the cursor's bracket?
        const target_hit =
            (on_close and pos == cursor_byte) or
            (after_close and pos == cursor_byte - 1);

        if (target_hit) {
            return switch (tok.cat) {
                .rbrace => if (brace_depth > 0) brace_stack[brace_depth - 1] else null,
                .rparen => if (paren_depth > 0) paren_stack[paren_depth - 1] else null,
                .rbracket => if (bracket_depth > 0) bracket_stack[bracket_depth - 1] else null,
                else => null, // cursor's byte is `}` etc. but lexer didn't tokenize it as a bracket
                // (probably inside a string/comment/heredoc) → no match
            };
        }

        switch (tok.cat) {
            .lbrace => if (brace_depth < STACK_DEPTH) {
                brace_stack[brace_depth] = @intCast(pos);
                brace_depth += 1;
            },
            .rbrace => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            .lparen => if (paren_depth < STACK_DEPTH) {
                paren_stack[paren_depth] = @intCast(pos);
                paren_depth += 1;
            },
            .rparen => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            .lbracket => if (bracket_depth < STACK_DEPTH) {
                bracket_stack[bracket_depth] = @intCast(pos);
                bracket_depth += 1;
            },
            .rbracket => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            else => {},
        }
    }

    return null;
}

fn isCloseBracketByte(b: u8) bool {
    return b == '}' or b == ')' or b == ']';
}

// -----------------------------------------------------------------------------
// Highlighter color palettes
// -----------------------------------------------------------------------------
//
// Slash uses 24-bit truecolor for the highlighter rather than the ANSI
// 8-color named palette so the rendered shade is identical regardless
// of the user's terminal theme. (Named colors get mapped to whatever
// the iTerm2 / Terminal.app / etc. profile defines, which can be
// anything from teal-instead-of-cyan to a near-invisible muddy gold.)
//
// Two palettes ship: `palette_dark` (Tokyonight-inspired, designed
// for dark terminal backgrounds) and `palette_light` (Solarized Light-
// inspired, designed for light backgrounds). Selection is via the
// `THEME` shell variable: `THEME=light` picks the light palette;
// anything else (including unset) picks dark.
//
// To customize, copy the constant body and tweak the RGB values, or
// set `THEME=light` in `~/.slashrc`. Per-token color customization
// (a hash from token category → color) is a slash 1.2 candidate.

const Palette = struct {
    keyword: zigline.Color,
    /// Color for command names (the first non-keyword ident at command
    /// position — start of input, or after `;`, `|`, `&&`, `||`, `&`,
    /// `{`, `(`, `[`, or a keyword like `if`/`while`).
    command: zigline.Color,
    /// Color for argument idents (any ident NOT at command position).
    argument: zigline.Color,
    integer: zigline.Color,
    string_literal: zigline.Color,
    /// Color for `$name` and `${...}` variable references. NAME=value
    /// assignments use the same color so the LHS of `FOO=bar` reads
    /// as "the variable being defined".
    variable: zigline.Color,
    /// Color for command and process substitution: `$(...)`, `@(...)`,
    /// `<(...)`, `>(...)`. Distinct from `variable` so a glance at a
    /// quoted string with both `$var` and `$(cmd)` distinguishes them.
    cmd_subst: zigline.Color,
    heredoc_body: zigline.Color,
    /// Color for redirect operators: `<`, `>`, `>>`, `&>`, `&>>`,
    /// `<<TAG`, and the `N<` / `N>` / `<&N` / `>&N` fd forms. Distinct
    /// from `operator` so I/O routing visually separates from control
    /// flow (`|`, `;`, `&&`, `||`, `&`, brackets).
    redirect: zigline.Color,
    /// Color for unquoted glob meta-characters inside bare-word idents:
    /// `*`, `?`, and `[...]` character classes. The literal portions
    /// of the same ident keep the command/argument color.
    glob: zigline.Color,
    operator: zigline.Color,
    comment: zigline.Color,
    err: zigline.Color,
    bracket_match: zigline.Color,
};

fn rgb(r: u8, g: u8, b: u8) zigline.Color {
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

/// Tokyonight-inspired dark palette. Designed against terminal
/// backgrounds in the `#1a1b26 .. #2c2e3e` range. Foreground accents
/// stay legible on near-black without being blinding.
const palette_dark: Palette = .{
    .keyword = rgb(0xbb, 0x9a, 0xf7), //  soft purple
    .command = rgb(0x73, 0xda, 0xca), //  teal — distinct from keyword/string/operator
    .argument = rgb(0x9a, 0xa5, 0xce), //  muted blue-gray — readable but recedes
    .integer = rgb(0xff, 0x9e, 0x64), //  warm orange
    .string_literal = rgb(0x9e, 0xce, 0x6a), //  green
    .variable = rgb(0xe0, 0xaf, 0x68), //  amber
    .cmd_subst = rgb(0xc7, 0x92, 0xea), //  lavender — calls out `$(...)` against `$var`
    .heredoc_body = rgb(0x9e, 0xce, 0x6a), //  same as string
    .redirect = rgb(0x82, 0xaa, 0xff), //  saturated blue, distinct from operator cyan
    .glob = rgb(0xff, 0xc7, 0x77), //  saffron — warmer than integer orange
    .operator = rgb(0x89, 0xdd, 0xff), //  cyan-blue (legible against dark)
    .comment = rgb(0x56, 0x5f, 0x89), //  muted slate
    .err = rgb(0xf7, 0x76, 0x8e), //  rose
    .bracket_match = rgb(0xe0, 0xaf, 0x68), //  amber, same as variable
};

/// Solarized Light-inspired palette. Designed against backgrounds in
/// the `#fdf6e3 .. #eee8d5` range (cream / paper). Accents pick the
/// darker Solarized hues so they read as text-with-emphasis, not as
/// neon overlays.
const palette_light: Palette = .{
    .keyword = rgb(0x26, 0x8b, 0xd2), //  blue
    .command = rgb(0x2a, 0xa1, 0x98), //  Solarized cyan — distinct from blue
    .argument = rgb(0x65, 0x7b, 0x83), //  base00 — slightly darker than slate
    .integer = rgb(0xcb, 0x4b, 0x16), //  orange
    .string_literal = rgb(0x85, 0x99, 0x00), //  green
    .variable = rgb(0xb5, 0x89, 0x00), //  yellow / dark gold
    .cmd_subst = rgb(0x6c, 0x71, 0xc4), //  Solarized violet — distinct from blue/cyan
    .heredoc_body = rgb(0x85, 0x99, 0x00), //  green
    .redirect = rgb(0xd3, 0x36, 0x82), //  Solarized magenta — distinct from operator slate
    .glob = rgb(0xcb, 0x4b, 0x16), //  same orange as integer; rare overlap is fine
    .operator = rgb(0x58, 0x6e, 0x75), //  base01 — slate
    .comment = rgb(0x93, 0xa1, 0xa1), //  base1 — pale gray
    .err = rgb(0xdc, 0x32, 0x2f), //  red
    .bracket_match = rgb(0xb5, 0x89, 0x00), //  yellow, same as variable
};

/// Look up `THEME` from the session and return the matching palette.
/// Unknown / unset values fall back to dark.
fn pickPalette(session: *const session_mod.Session) Palette {
    if (session.vars.get("THEME")) |v| switch (v.value) {
        .scalar => |s| {
            if (std.mem.eql(u8, s, "light")) return palette_light;
        },
        .list => {},
    };
    return palette_dark;
}

fn styleFor(tok: parser.Token, span_bytes: []const u8, p: Palette) ?zigline.Style {
    return switch (tok.cat) {
        .ident => if (slash.keywordAs(span_bytes) != null)
            zigline.Style{ .fg = p.keyword, .bold = true }
        else
            null,
        .integer => zigline.Style{ .fg = p.integer },
        .string_sq => zigline.Style{ .fg = p.string_literal },
        .variable, .var_braced => zigline.Style{ .fg = p.variable },
        .name_eq, .assign => zigline.Style{ .fg = p.variable },
        .dollar_paren, .at_paren, .proc_sub_in, .proc_sub_out => zigline.Style{ .fg = p.cmd_subst },
        .heredoc_body => zigline.Style{ .fg = p.heredoc_body },
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
        => zigline.Style{ .fg = p.redirect },
        .pipe,
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
        => zigline.Style{ .fg = p.operator },
        .comment => zigline.Style{ .fg = p.comment, .italic = true },
        .err => zigline.Style{ .fg = p.err, .bold = true, .underline = true },
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
    p: Palette,
) !void {
    const green = zigline.Style{ .fg = p.string_literal };
    const yellow = zigline.Style{ .fg = p.variable };

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

/// True iff `s` contains an unquoted glob meta-character. Bare-word
/// `.ident` tokens never include backslash escapes (escaped chars
/// land in a different lexer state), so a literal scan is sufficient.
fn containsGlobChar(s: []const u8) bool {
    for (s) |c| if (c == '*' or c == '?' or c == '[') return true;
    return false;
}

/// Emit chunked sub-spans for an `.ident` that contains glob meta-
/// characters. Literal portions get `base_style`; `*`, `?`, and a
/// balanced `[...]` class get the palette's glob color. Spans stay
/// sorted and non-overlapping, which is what the zigline renderer
/// requires.
fn emitIdentWithGlobs(
    allocator: Allocator,
    spans: *std.ArrayListUnmanaged(zigline.HighlightSpan),
    buffer: []const u8,
    start: usize,
    end: usize,
    base_style: zigline.Style,
    p: Palette,
) !void {
    const glob_style = zigline.Style{ .fg = p.glob };
    var seg_start = start;
    var i = start;
    while (i < end) {
        const c = buffer[i];
        if (c == '*' or c == '?') {
            if (i > seg_start) try spans.append(allocator, .{
                .start = seg_start,
                .end = i,
                .style = base_style,
            });
            try spans.append(allocator, .{
                .start = i,
                .end = i + 1,
                .style = glob_style,
            });
            seg_start = i + 1;
            i += 1;
            continue;
        }
        if (c == '[') {
            // Find matching `]` within the same ident span. If absent,
            // treat the `[` as literal text — the lexer kept it inside
            // the ident, so the user gets a no-glob baseline render.
            const close = std.mem.indexOfScalarPos(u8, buffer[0..end], i + 1, ']');
            if (close) |x| {
                if (i > seg_start) try spans.append(allocator, .{
                    .start = seg_start,
                    .end = i,
                    .style = base_style,
                });
                try spans.append(allocator, .{
                    .start = i,
                    .end = x + 1,
                    .style = glob_style,
                });
                seg_start = x + 1;
                i = x + 1;
                continue;
            }
        }
        i += 1;
    }
    if (seg_start < end) try spans.append(allocator, .{
        .start = seg_start,
        .end = end,
        .style = base_style,
    });
}

// -----------------------------------------------------------------------------
// Completion — zigline adapter over slash-side specs/providers
// -----------------------------------------------------------------------------

fn completionHook(
    ctx_ptr: *anyopaque,
    allocator: Allocator,
    request: zigline.CompletionRequest,
) anyerror!zigline.CompletionResult {
    const hooks: *SlashHooks = @ptrCast(@alignCast(ctx_ptr));
    return completion.complete(allocator, .{
        .session = hooks.session,
        .buffer = request.buffer,
        .cursor_byte = request.cursor_byte,
    });
}

// =============================================================================
// History path resolver — kept slash-side because the location is
// slash-specific. Two paths in play:
//
//   - **Legacy flat file** at `~/.slash/history`: zigline's `History`
//     reads/writes this for chronological Up/Down navigation. Kept
//     for backward compatibility; existing users' history transfers
//     in transparently.
//
//   - **JSONL index** at `$XDG_DATA_HOME/slash/history.jsonl` (or
//     `~/.local/share/slash/history.jsonl` if XDG_DATA_HOME is
//     unset): the slash-side `HistoryIndex` reads/writes this for
//     metadata-rich storage that drives the `history` builtin and
//     (eventually) smart Up/Down + autosuggestions.
//
// On first run after the JSONL feature lands, the legacy file is
// imported into JSONL once (no metadata) so the user doesn't lose
// their history. Both paths fall back to in-memory only on
// resolution failure (no HOME, can't mkdir, etc.).
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

/// XDG-anchored path to the slash-side JSONL history index. Returns
/// `null` on env failures (no HOME, no XDG, permission denied at
/// mkdir). Caller owns the returned path.
fn resolveHistoryJsonlPath(allocator: Allocator) !?[]u8 {
    // Prefer XDG_DATA_HOME; fall back to ~/.local/share.
    var data_home: []u8 = undefined;
    var data_home_owned = false;
    if (std.c.getenv("XDG_DATA_HOME")) |xdg_ptr| {
        const xdg = std.mem.span(xdg_ptr);
        if (xdg.len > 0) {
            data_home = try allocator.dupe(u8, xdg);
            data_home_owned = true;
        } else {
            const home_ptr = std.c.getenv("HOME") orelse return null;
            const home = std.mem.span(home_ptr);
            if (home.len == 0) return null;
            data_home = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
            data_home_owned = true;
        }
    } else {
        const home_ptr = std.c.getenv("HOME") orelse return null;
        const home = std.mem.span(home_ptr);
        if (home.len == 0) return null;
        data_home = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        data_home_owned = true;
    }
    defer if (data_home_owned) allocator.free(data_home);

    const dir = try std.fmt.allocPrint(allocator, "{s}/slash", .{data_home});
    defer allocator.free(dir);
    return try std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{dir});
}

// =============================================================================
// Shared parse/lower/run helpers
// =============================================================================

/// Parse + lower + run the buffered source. Four outcomes:
///   - whitespace-only buffer → no-op, clear and return current status
///   - parse succeeds → run, clear buffer, return the result status
///   - parse fails AT EOF → buffer is incomplete; keep accumulating
///   - parse fails before EOF → real error; render and clear buffer
fn evaluatePending(
    session: *session_mod.Session,
    alloc: Allocator,
    pending: *std.ArrayListUnmanaged(u8),
) !u8 {
    // Whitespace-/comment-only input: pressing Enter on an empty (or
    // all-blanks) prompt is a real-world no-op. So is a line that
    // contains only `# blah` comments. Without this short-circuit,
    // the parser sees end-of-input where a statement was expected,
    // emits a diagnostic at the very end of the buffer, and
    // `isIncompleteParse` misreads that as "needs more input" —
    // putting the REPL into the `... ` continuation prompt forever.
    // Match bash/sh: comment-only or empty Enter returns to a fresh
    // prompt with no side effects.
    if (containsNoStatement(pending.items)) {
        pending.clearRetainingCapacity();
        return session.last_status;
    }

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

/// True if `text` contains no executable statement — only whitespace
/// (spaces, tabs, newlines, carriage returns) and `#`-to-end-of-line
/// comments. Used by `evaluatePending` to short-circuit Enter on
/// blank or comment-only lines.
///
/// Doesn't try to handle `#` inside quoted strings — if the user has
/// `"foo # bar"` on a line by itself, that line isn't a statement
/// either (it's a bare word that errors), but this helper would
/// route it through the normal parse path. The grammar will reject
/// it and the user will see the real error, which is correct.
fn containsNoStatement(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => i += 1,
            '#' => {
                // Skip to end of line.
                while (i < text.len and text[i] != '\n') i += 1;
            },
            else => return false,
        }
    }
    return true;
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

/// Interactive job-control bootstrap. Modeled after the APUE shell
/// initialization (CHECKLIST §5):
///
///   1. Open a stable handle to the controlling tty (CLOEXEC'd dup of
///      fd 2). Skipped when stderr isn't a tty — `slash | cat` and
///      headless runs simply leave `controlling_tty_fd` null.
///   2. Wait until we're the foreground process group: while
///      `tcgetpgrp(tty) != getpgrp()`, send SIGTTIN to ourselves so the
///      kernel suspends us until someone `fg`s our group. Prevents a
///      background-launched slash from yanking the terminal away from
///      whatever's currently in the foreground.
///   3. Install the interactive signal-ignores. SIGTTIN must be ignored
///      AFTER step 2 (we relied on its default suspend behavior there);
///      SIGTTOU must be ignored BEFORE the tcsetpgrp in step 5 so the
///      shell doesn't stop itself trying to set the foreground group
///      from a now-non-foreground context.
///   4. `setpgid(0, 0)` — make ourselves our own process-group leader.
///      Idempotent if we already are.
///   5. `tcsetpgrp(tty, getpgrp())` — claim the controlling-tty's
///      foreground group.
///   6. Update `session.controlling_tty_fd` and `session.shell_pgid`
///      with the post-bootstrap values, which is what `serviceForeground`
///      reads when handing the tty to/from foreground jobs.
fn bootstrapInteractive(session: *session_mod.Session) void {
    // Step 1: open + CLOEXEC the controlling-tty fd. fd 2 is the
    // conventional "stays connected to the user even if stdin/stdout
    // are redirected" fd. We dup it so subsequent `dup2(opened, 2)`
    // from a `2>file` redirect doesn't lose our handle.
    var tty_fd: ?std.c.fd_t = null;
    if (std.c.isatty(2) != 0) {
        const dup_fd = std.c.dup(2);
        if (dup_fd >= 0) {
            // FD_CLOEXEC so the handle doesn't leak across child execs.
            const flags = std.c.fcntl(dup_fd, std.c.F.GETFD);
            if (flags >= 0) {
                _ = std.c.fcntl(dup_fd, std.c.F.SETFD, flags | std.c.FD_CLOEXEC);
            }
            tty_fd = dup_fd;
        }
    }

    // Step 2: foreground-group acquisition loop. Skipped when there's
    // no controlling tty (non-interactive shape). Force SIGTTIN to its
    // DEFAULT disposition first — if we inherited it as IGN from a
    // parent shell, the loop would spin instead of suspending us.
    //
    // The cap is intentionally fatal: if we can't become foreground
    // within 100 SIGTTIN/resume cycles, something is structurally wrong
    // (orphaned process group, or our parent never `fg`'d us). Pressing
    // on with a `tcsetpgrp` despite the mismatch would risk stealing
    // the terminal from whoever currently owns it. Better to drop the
    // ctty handle and run as a non-interactive fallback.
    if (tty_fd) |fd| {
        var ttin_default: std.posix.Sigaction = .{
            .handler = .{ .handler = std.c.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TTIN, &ttin_default, null);

        var iters: u32 = 0;
        var acquired = false;
        while (iters < 100) : (iters += 1) {
            const fg = exec.tcGetPgrp(fd) orelse {
                // No controlling-tty foreground group — treat as
                // already-acquired so we proceed to setpgid/tcsetpgrp.
                acquired = true;
                break;
            };
            const my = getpgrp();
            if (fg == my) {
                acquired = true;
                break;
            }
            _ = std.c.kill(-my, .TTIN);
        }
        if (!acquired) {
            const msg = "slash: could not acquire foreground after 100 attempts; running non-interactive\n";
            _ = std.c.write(2, msg.ptr, msg.len);
            _ = std.c.close(fd);
            tty_fd = null;
        }
    }

    // Step 3: now safe to ignore the interactive job-control signals.
    installInteractiveSignalHandlers();

    // Step 4: become our own process-group leader. Tolerant of EPERM
    // (already a leader) and any other failure — best-effort.
    _ = std.c.setpgid(0, 0);

    // Step 5: claim the foreground process group on the controlling
    // tty. Safe now because SIGTTOU is ignored.
    if (tty_fd) |fd| {
        _ = exec.tcSetPgrp(fd, getpgrp());
    }

    // Step 6: publish the post-bootstrap values onto the session.
    session.shell_pgid = getpgrp();
    session.controlling_tty_fd = tty_fd;

    // Step 7: snapshot the shell's terminal modes (as inherited from
    // the parent shell, untouched) so they can be restored after
    // every foreground job. Programs like vim/less/Python REPL push
    // the tty into raw mode; without this snapshot, returning to the
    // shell prompt leaves Slash in whatever mode the last foreground
    // job was using.
    //
    // We deliberately DO NOT modify shell_termios here — modifying
    // the parent-inherited baseline confused zigline's saved-termios
    // bookkeeping (broke Ctrl-D EOF in the editor). The "user mode"
    // termios distinction (ECHOCTL etc.) is applied at the point of
    // handing the tty to a foreground job — see `terminal.giveToJob`.
    if (tty_fd) |fd| {
        if (std.posix.tcgetattr(fd)) |t| {
            session.shell_termios = t;
        } else |_| {}
    }

    // Step 8: install the SIGCHLD handler now that the session is in
    // place. The handler reads `builtins.currentSession()` — install
    // order matters: this must come AFTER `builtins.installSession`
    // (handled by the caller before invoking bootstrapInteractive).
    installChildEventHandler();
}

fn installInteractiveSignalHandlers() void {
    var ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    // PLAN §18: interactive shell ignores QUIT/TSTP/TTIN/TTOU so the
    // shell itself can't be stopped or quit by terminal-driven signals.
    // SIGPIPE is handled separately in `installShellSignalDefaults`
    // because non-interactive shells need that disposition too.
    const ignored = [_]std.c.SIG{ .QUIT, .TSTP, .TTIN, .TTOU };
    for (ignored) |sig| std.posix.sigaction(sig, &ignore, null);

    var int_action: std.posix.Sigaction = .{
        .handler = .{ .handler = sigintNoop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &int_action, null);
}

/// Signal dispositions every Slash invocation needs, regardless of
/// interactivity. Currently: ignore SIGPIPE so a builtin (printf, echo)
/// writing into a pipeline whose reader has exited doesn't take the
/// shell with it. Children restore the default disposition in
/// `exec.runChild` before `execve`, so external programs still see
/// normal POSIX SIGPIPE semantics.
pub fn installShellSignalDefaults() void {
    var ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &ignore, null);
}

/// Async-signal-safe body shared between the real SIGCHLD handler and
/// the focused unit test. Sets the pending flag with a swap (so the
/// caller can tell whether this was the first signal in this batch),
/// and pokes zigline's signal pipe ONLY on the first signal — coalesces
/// bursts (e.g. `for i in {1..100}; do work-stuff & done`) so the
/// editor doesn't redraw 100 times. Subsequent SIGCHLDs are silent
/// until `drainChildEvents` clears the flag.
///
/// Async-signal-safe primitives only: atomic swap, single one-byte
/// `write(2)` via `zigline.pokeActiveSignalPipe`. No allocation, no
/// locks, no Zig std formatting.
pub fn notifyChildEventFromSignal(session: *session_mod.Session) void {
    if (!session.child_event_pending.swap(true, .release)) {
        zigline.pokeActiveSignalPipe();
    }
}

/// SIGCHLD handler: dispatches to `notifyChildEventFromSignal` for the
/// shared signal-safe path. Does NOT reap, NOT allocate, NOT log.
/// Safe-point code in eval drains the flag and runs the actual
/// `waitpid` poll.
fn sigchldHandler(_: std.c.SIG) callconv(.c) void {
    const s = builtins.currentSession() orelse return;
    notifyChildEventFromSignal(s);
}

/// Install the SIGCHLD handler. Done at interactive bootstrap so it
/// only fires once we have a session installed (the handler reads
/// `current_session`). Non-interactive shapes don't install it —
/// reaping there happens via the existing safe-point polls in eval,
/// and there's no editor read to wake.
///
/// Notably we do NOT set `SA_NOCLDSTOP`: we want SIGCHLD on stop
/// and continue events too, so `Job.state` transitions (e.g., a
/// foreground process being SIGTSTP'd) are visible at safe points.
fn installChildEventHandler() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = sigchldHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    std.posix.sigaction(.CHLD, &sa, null);
}

/// Restore SIGCHLD to its default disposition. Called from REPL exit
/// paths just before `session.deinit` so a SIGCHLD arriving in the
/// teardown window doesn't dispatch through `currentSession()` to a
/// half-freed Session. The default disposition is harmless (kernel
/// reaps the child or leaves it as a zombie for the caller's wait).
pub fn uninstallChildEventHandler() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &sa, null);
}

fn sigintNoop(_: std.c.SIG) callconv(.c) void {}

fn isStdinTty() bool {
    return std.c.isatty(0) != 0;
}

// =============================================================================
// Prompt rendering
// =============================================================================
//
// Two paths:
//
//   1. **User-defined `$PROMPT`** — set in `~/.slashrc` or interactively.
//      The string is treated as a *format template* with `%`-substitutions
//      (see `expandPromptFormat`). Embedded ANSI escape sequences (`\e[...m`)
//      are honored verbatim — `displayWidth` strips them when computing
//      the wrap-aware column count zigline needs.
//
//   2. **Preset path** — `prompt_mod.render` composes a preset (default,
//      rich, or minimal) from a fixed list of providers. `$SLASH_PROMPT`
//      selects the preset; unset means `default` (cwd + sigil — the
//      backward-compatible legacy prompt). `rich` opts into venv +
//      remote-user + cwd + git + jobs + sigil. Pure ASCII; width
//      equals byte length for ASCII content, with multi-byte UTF-8
//      counted by codepoint.
//
// `slashPrompt` dispatches between the two; `runRaw` calls it once per
// prompt boundary and constructs the `zigline.Prompt` directly so the
// `width` field reflects display columns (not bytes).
//
// Format codes for user `$PROMPT`:
//
//     %u  / %n        username (from $USER, or getuid+getpwuid)
//     %h  / %m        hostname (short — truncated at first dot)
//     %H              hostname (full FQDN)
//     %w  / %~        cwd, home-collapsed (`~/Code/slash`)
//     %W              cwd basename (`slash`)
//     %d              date as `Mon Apr 27`
//     %t              time as `HH:MM:SS`
//     %T              time as `HH:MM`
//     %D{strftime}    time with user-supplied strftime format
//     %$              `$` for normal users, `#` for root
//     %?              last command's exit status as a raw integer
//     %%              literal `%`
//
// Color codes (zsh-style; emit ANSI SGR transparently):
//
//     %F{#ecede8}     foreground = 24-bit truecolor RGB
//     %F{red}         foreground = ANSI 8-color name
//     %F{}  / %f      reset foreground to terminal default
//     %K{#43669d}     background = 24-bit truecolor RGB
//     %K{cyan}        background = ANSI 8-color name
//     %K{}  / %k      reset background to terminal default
//
// Names accepted: black, red, green, yellow, blue, magenta, cyan, white.
//
// Anything else (including `%` followed by an unknown code) emits
// literally so users can mix arbitrary text without escaping noise.

extern fn gethostname(buf: [*]u8, sz: usize) c_int;
extern fn time(out: ?*c_long) c_long;
// `struct tm` isn't surfaced by `std.c` in Zig 0.16; we treat it as
// opaque since slash never reads its fields directly.
const Tm = opaque {};
extern fn localtime(t: *const c_long) ?*const Tm;
extern fn strftime(buf: [*]u8, sz: usize, fmt: [*:0]const u8, tm: *const Tm) usize;

/// Top-level entry: dispatch to user-defined `$PROMPT` if set, else
/// the built-in default. Returns a slice into `buf`.
///
/// The pre-prompt status notice (`slash: exit N`) is drained by
/// `notice.pendingExitStatus` *before* this function is called, so
/// neither the user prompt nor the default prompt has to worry about
/// surfacing the badge. `%?` in `$PROMPT` still expands to the raw
/// status integer for users who want to compose their own indicator.
fn slashPrompt(buf: []u8, session: *session_mod.Session) []const u8 {
    if (session.vars.get("PROMPT")) |v| switch (v.value) {
        .scalar => |raw| return expandPromptFormat(buf, session, raw),
        .list => {},
    };
    return prompt_mod.render(buf, session, prompt_mod.selectPreset(session));
}

/// Expand `%`-codes in `raw` against the current shell state, writing
/// the result into `buf`. Embedded ANSI escapes (`\e[...m` etc.) pass
/// through verbatim. Unknown `%X` codes emit literally.
///
/// Codes that take a `{...}` argument (`%F`, `%K`, `%D`) are parsed
/// before the simple-code switch; if the closing brace is missing, the
/// `%X{` is emitted literally.
fn expandPromptFormat(buf: []u8, session: *const session_mod.Session, raw: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '%' or i + 1 >= raw.len) {
            w.writeByte(c) catch return w.buffered();
            i += 1;
            continue;
        }
        const code = raw[i + 1];

        // Codes that take a {...} argument.
        if (code == 'F' or code == 'K' or code == 'D') {
            if (parseBraces(raw, i + 2)) |b| {
                switch (code) {
                    'F' => {
                        if (parsePromptColor(b.content)) |col| writePromptFg(&w, col);
                    },
                    'K' => {
                        if (parsePromptColor(b.content)) |col| writePromptBg(&w, col);
                    },
                    'D' => {
                        var fmt_buf: [128]u8 = undefined;
                        if (b.content.len + 1 <= fmt_buf.len) {
                            @memcpy(fmt_buf[0..b.content.len], b.content);
                            fmt_buf[b.content.len] = 0;
                            const fmt_z: [*:0]const u8 = @ptrCast(&fmt_buf);
                            writePromptTimeFmt(&w, fmt_z);
                        }
                    },
                    else => unreachable,
                }
                i = b.end;
                continue;
            }
            // No closing brace → emit `%X` literally and resume.
            w.writeByte('%') catch return w.buffered();
            w.writeByte(code) catch return w.buffered();
            i += 2;
            continue;
        }

        // Simple no-argument codes.
        i += 2;
        switch (code) {
            '%' => w.writeByte('%') catch return w.buffered(),
            'u', 'n' => writePromptUsername(&w),
            'h', 'm' => writePromptHostname(&w, .short),
            'H' => writePromptHostname(&w, .full),
            'w', '~' => writePromptCwd(&w, .home_collapsed),
            'W' => writePromptCwd(&w, .basename),
            'd' => writePromptTimeFmt(&w, "%a %b %d"),
            't' => writePromptTimeFmt(&w, "%H:%M:%S"),
            'T' => writePromptTimeFmt(&w, "%H:%M"),
            '$' => {
                const ch: u8 = if (std.c.getuid() == 0) '#' else '$';
                w.writeByte(ch) catch return w.buffered();
            },
            '?' => {
                w.print("{d}", .{session.last_status}) catch return w.buffered();
            },
            'f' => w.writeAll("\x1b[39m") catch return w.buffered(),
            'k' => w.writeAll("\x1b[49m") catch return w.buffered(),
            else => {
                // Unknown code: emit `%X` literally so users can include
                // stray `%` signs without escaping every one.
                w.writeByte('%') catch return w.buffered();
                w.writeByte(code) catch return w.buffered();
            },
        }
    }
    return w.buffered();
}

// -----------------------------------------------------------------------------
// Color parsing for %F{...} / %K{...}
// -----------------------------------------------------------------------------

const PromptColor = union(enum) {
    /// 24-bit truecolor RGB (used for `%F{#xxxxxx}` / `%K{#xxxxxx}`).
    rgb: struct { r: u8, g: u8, b: u8 },
    /// ANSI 8-color name (`%F{red}` / `%K{cyan}` etc.). Stored as 0..7.
    named: u3,
    /// `%F{}` / `%K{}` — reset to terminal default.
    default,
};

/// Locate `{...}` starting at `start`. Returns the inner content slice
/// and the byte offset just past the closing `}`. Returns null when
/// `start` doesn't point at `{` or no closing brace is found.
fn parseBraces(raw: []const u8, start: usize) ?struct { content: []const u8, end: usize } {
    if (start >= raw.len or raw[start] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, raw, start + 1, '}') orelse return null;
    return .{ .content = raw[start + 1 .. close], .end = close + 1 };
}

fn parsePromptColor(content: []const u8) ?PromptColor {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len == 0) return .default;

    if (trimmed[0] == '#' and trimmed.len == 7) {
        const r = std.fmt.parseInt(u8, trimmed[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, trimmed[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, trimmed[5..7], 16) catch return null;
        return PromptColor{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    const named = colorByName(trimmed) orelse return null;
    return PromptColor{ .named = named };
}

fn colorByName(name: []const u8) ?u3 {
    if (std.mem.eql(u8, name, "black")) return 0;
    if (std.mem.eql(u8, name, "red")) return 1;
    if (std.mem.eql(u8, name, "green")) return 2;
    if (std.mem.eql(u8, name, "yellow")) return 3;
    if (std.mem.eql(u8, name, "blue")) return 4;
    if (std.mem.eql(u8, name, "magenta")) return 5;
    if (std.mem.eql(u8, name, "cyan")) return 6;
    if (std.mem.eql(u8, name, "white")) return 7;
    return null;
}

fn writePromptFg(w: *std.Io.Writer, color: PromptColor) void {
    switch (color) {
        .rgb => |c| w.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch {},
        .named => |n| w.print("\x1b[3{d}m", .{@as(u8, n)}) catch {},
        .default => w.writeAll("\x1b[39m") catch {},
    }
}

fn writePromptBg(w: *std.Io.Writer, color: PromptColor) void {
    switch (color) {
        .rgb => |c| w.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch {},
        .named => |n| w.print("\x1b[4{d}m", .{@as(u8, n)}) catch {},
        .default => w.writeAll("\x1b[49m") catch {},
    }
}

fn writePromptUsername(w: *std.Io.Writer) void {
    if (std.c.getenv("USER")) |u| {
        w.writeAll(std.mem.span(u)) catch {};
        return;
    }
    if (std.c.getenv("LOGNAME")) |u| {
        w.writeAll(std.mem.span(u)) catch {};
        return;
    }
    w.writeAll("?") catch {};
}

const HostKind = enum { short, full };

fn writePromptHostname(w: *std.Io.Writer, kind: HostKind) void {
    var hostbuf: [256]u8 = undefined;
    if (gethostname(&hostbuf, hostbuf.len) != 0) {
        w.writeAll("?") catch {};
        return;
    }
    const z: [*:0]const u8 = @ptrCast(&hostbuf);
    const full = std.mem.span(z);
    if (kind == .short) {
        const dot = std.mem.indexOfScalar(u8, full, '.');
        const short = if (dot) |d| full[0..d] else full;
        w.writeAll(short) catch {};
    } else {
        w.writeAll(full) catch {};
    }
}

const CwdKind = enum { home_collapsed, basename };

fn writePromptCwd(w: *std.Io.Writer, kind: CwdKind) void {
    var cwd_buf: [4096]u8 = undefined;
    const got = std.c.getcwd(&cwd_buf, cwd_buf.len);
    if (got == null) {
        w.writeAll("?") catch {};
        return;
    }
    const len = std.mem.len(@as([*:0]u8, @ptrCast(got)));
    var cwd: []const u8 = cwd_buf[0..len];

    if (kind == .basename) {
        if (std.mem.lastIndexOfScalar(u8, cwd, '/')) |i| {
            const base = cwd[i + 1 ..];
            const display = if (base.len == 0) cwd else base;
            w.writeAll(display) catch {};
        } else {
            w.writeAll(cwd) catch {};
        }
        return;
    }

    if (std.c.getenv("HOME")) |home_env| {
        const home = std.mem.span(home_env);
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            w.writeAll("~") catch return;
            cwd = cwd[home.len..];
        }
    }
    w.writeAll(cwd) catch {};
}

fn writePromptTimeFmt(w: *std.Io.Writer, fmt: [*:0]const u8) void {
    var t: c_long = time(null);
    const tm = localtime(&t) orelse {
        w.writeAll("?") catch {};
        return;
    };
    var buf: [64]u8 = undefined;
    const n = strftime(&buf, buf.len, fmt, tm);
    if (n == 0) return;
    w.writeAll(buf[0..n]) catch {};
}

/// ANSI-aware display width: walks `bytes` and counts printable
/// columns, skipping CSI (`\x1b[...{letter}`), SS3 (`\x1bO{letter}`),
/// and OSC (`\x1b]...{BEL or ST}`) escape sequences entirely.
///
/// For the printable portion, this counts bytes (one column per byte)
/// — which is correct for ASCII prompts and undercounts wide characters
/// (CJK, most emoji). zigline's renderer applies its own grapheme-aware
/// width on the buffer; the prompt width only needs to be roughly right
/// for prompts that stay within the ASCII range. v1.0 acceptable; a
/// follow-on would route printable spans through zigline's grapheme
/// helper.
fn promptDisplayWidth(bytes: []const u8) usize {
    var i: usize = 0;
    var w: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == 0x1b and i + 1 < bytes.len) {
            const next = bytes[i + 1];
            if (next == '[') {
                // CSI: skip until a final byte in 0x40..0x7e.
                i += 2;
                while (i < bytes.len) {
                    const b = bytes[i];
                    i += 1;
                    if (b >= 0x40 and b <= 0x7e) break;
                }
                continue;
            }
            if (next == 'O') {
                // SS3: one final byte.
                i += 3;
                continue;
            }
            if (next == ']') {
                // OSC: skip until BEL (0x07) or ST (ESC \\).
                i += 2;
                while (i < bytes.len) {
                    const b = bytes[i];
                    if (b == 0x07) {
                        i += 1;
                        break;
                    }
                    if (b == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            // Unknown escape: skip the next byte too.
            i += 2;
            continue;
        }
        // Printable byte. Skip multi-byte UTF-8 continuation bytes so
        // we count one column per UTF-8 codepoint rather than per byte.
        // (Wide-cell content like CJK is undercounted; see comment above.)
        if (c >= 0x80 and c < 0xc0) {
            i += 1;
            continue;
        }
        w += 1;
        i += 1;
    }
    return w;
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

/// Test helper: invoke `highlightHook` against a buffer with the cursor
/// implicitly at the end (the common shape — typing left-to-right). For
/// tests that exercise cursor-sensitive features (bracket matching), use
/// `highlightHookAt` directly with an explicit cursor byte.
fn highlightHookEnd(alloc: Allocator, buffer: []const u8) anyerror![]zigline.HighlightSpan {
    return highlightBuffer(alloc, buffer, buffer.len, palette_dark);
}

fn highlightHookAt(alloc: Allocator, buffer: []const u8, cursor_byte: usize) anyerror![]zigline.HighlightSpan {
    return highlightBuffer(alloc, buffer, cursor_byte, palette_dark);
}

test "highlight: keywords get keyword-color + bold span" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "if true { echo hi }");
    defer alloc.free(spans);

    // The `if` keyword should be a bold span whose fg matches the
    // dark palette's keyword color. Brackets `{` and `}` should be
    // styled too (operator color), but no specific assertion needed
    // beyond "they exist."
    var saw_keyword_bold = false;
    var saw_operator = false;
    for (spans) |s| {
        if (s.style.bold) {
            if (s.style.fg) |fg| {
                if (fg == .rgb and fg.rgb.r == palette_dark.keyword.rgb.r and
                    fg.rgb.g == palette_dark.keyword.rgb.g and
                    fg.rgb.b == palette_dark.keyword.rgb.b) saw_keyword_bold = true;
            }
        }
        if (s.style.fg) |fg| {
            if (fg == .rgb and fg.rgb.r == palette_dark.operator.rgb.r) saw_operator = true;
        }
    }
    try std.testing.expect(saw_keyword_bold);
    try std.testing.expect(saw_operator);
}

test "highlight: dq with embedded $var emits string + variable colors" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "echo \"hi $name\"");
    defer alloc.free(spans);

    var has_string = false;
    var has_variable = false;
    for (spans) |s| {
        if (s.style.fg) |fg| {
            if (fg == .rgb) {
                if (fg.rgb.r == palette_dark.string_literal.rgb.r and
                    fg.rgb.g == palette_dark.string_literal.rgb.g and
                    fg.rgb.b == palette_dark.string_literal.rgb.b) has_string = true;
                if (fg.rgb.r == palette_dark.variable.rgb.r and
                    fg.rgb.g == palette_dark.variable.rgb.g and
                    fg.rgb.b == palette_dark.variable.rgb.b) has_variable = true;
            }
        }
    }
    try std.testing.expect(has_string);
    try std.testing.expect(has_variable);
}

test "highlight: comment is italicized with comment-color" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "echo a # trailing");
    defer alloc.free(spans);
    var saw_comment = false;
    for (spans) |s| if (s.style.italic) {
        if (s.style.fg) |fg| {
            if (fg == .rgb and fg.rgb.r == palette_dark.comment.rgb.r) saw_comment = true;
        }
    };
    try std.testing.expect(saw_comment);
}

fn paletteColorsEqual(a: zigline.Color, b: zigline.Color) bool {
    if (a != .rgb or b != .rgb) return false;
    return a.rgb.r == b.rgb.r and a.rgb.g == b.rgb.g and a.rgb.b == b.rgb.b;
}

fn spanWithColor(spans: []const zigline.HighlightSpan, color: zigline.Color) ?zigline.HighlightSpan {
    for (spans) |s| {
        if (s.style.fg) |fg| if (paletteColorsEqual(fg, color)) return s;
    }
    return null;
}

test "highlight: command substitution uses cmd_subst color, not variable" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "echo $(date)");
    defer alloc.free(spans);

    const cmd = spanWithColor(spans, palette_dark.cmd_subst);
    try std.testing.expect(cmd != null);
    try std.testing.expect(spanWithColor(spans, palette_dark.variable) == null);
}

test "highlight: $var keeps variable color when sibling $(...) uses cmd_subst" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "echo $name $(date)");
    defer alloc.free(spans);

    try std.testing.expect(spanWithColor(spans, palette_dark.variable) != null);
    try std.testing.expect(spanWithColor(spans, palette_dark.cmd_subst) != null);
}

test "highlight: redirect operators use redirect color, not operator" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "cmd > out 2>&1 | tee log");
    defer alloc.free(spans);

    try std.testing.expect(spanWithColor(spans, palette_dark.redirect) != null);
    // The pipe MUST stay in the operator class; it is control flow,
    // not I/O routing. Its span is exactly one byte at the `|` offset.
    var saw_pipe_as_operator = false;
    for (spans) |s| {
        if (s.start == "cmd > out 2>&1 ".len and s.end == s.start + 1) {
            if (s.style.fg) |fg| {
                if (paletteColorsEqual(fg, palette_dark.operator)) saw_pipe_as_operator = true;
            }
        }
    }
    try std.testing.expect(saw_pipe_as_operator);
}

test "highlight: heredoc open uses redirect color" {
    const alloc = std.testing.allocator;
    const spans = try highlightHookEnd(alloc, "cat <<EOF\nhello\nEOF");
    defer alloc.free(spans);
    try std.testing.expect(spanWithColor(spans, palette_dark.redirect) != null);
}

test "highlight: glob `*` inside an ident gets a sub-span with glob color" {
    const alloc = std.testing.allocator;
    const buf = "ls *.zig";
    const spans = try highlightHookEnd(alloc, buf);
    defer alloc.free(spans);

    // Expect: command `ls` (command color) + glob `*` (glob) + literal `.zig` (argument).
    var saw_glob = false;
    var saw_arg_after = false;
    for (spans) |s| {
        if (s.start == 3 and s.end == 4) {
            if (s.style.fg) |fg| {
                if (paletteColorsEqual(fg, palette_dark.glob)) saw_glob = true;
            }
        }
        if (s.start == 4 and s.end == 8) {
            if (s.style.fg) |fg| {
                if (paletteColorsEqual(fg, palette_dark.argument)) saw_arg_after = true;
            }
        }
    }
    try std.testing.expect(saw_glob);
    try std.testing.expect(saw_arg_after);
}

test "highlight: NAME= assignment uses variable color on the ident" {
    const alloc = std.testing.allocator;
    const buf = "FOO=bar cmd";
    const spans = try highlightHookEnd(alloc, buf);
    defer alloc.free(spans);

    var saw_assign = false;
    for (spans) |s| {
        if (s.start == 0 and s.end == 3) {
            if (s.style.fg) |fg| {
                if (paletteColorsEqual(fg, palette_dark.variable)) saw_assign = true;
            }
        }
    }
    try std.testing.expect(saw_assign);
}

test "highlight: bare `==` does NOT promote a leading ident to variable color" {
    const alloc = std.testing.allocator;
    const buf = "test FOO == bar";
    const spans = try highlightHookEnd(alloc, buf);
    defer alloc.free(spans);

    // `FOO` is an argument here; it must NOT be variable-colored just
    // because `=` follows somewhere on the line.
    for (spans) |s| {
        if (s.start == 5 and s.end == 8) {
            if (s.style.fg) |fg| {
                try std.testing.expect(!paletteColorsEqual(fg, palette_dark.variable));
            }
        }
    }
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
        const spans = try highlightHookEnd(alloc, buf);
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
    const spans = try highlightHookEnd(alloc, buf);
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

// -----------------------------------------------------------------------------
// Bracket matching — unit tests for findMatchingBracket
// -----------------------------------------------------------------------------

test "bracket: cursor on } finds matching {" {
    // "if true { x }"  → cursor on the closing } at byte 12
    // matching { is at byte 8.
    const buf = "if true { x }";
    try std.testing.expectEqual(@as(?usize, 8), findMatchingBracket(buf, 12));
}

test "bracket: cursor just past } finds matching {" {
    const buf = "if true { x }";
    // cursor at byte 13 (just past `}`)
    try std.testing.expectEqual(@as(?usize, 8), findMatchingBracket(buf, 13));
}

test "bracket: nested braces match the inner pair" {
    //  byte: 0         1         2
    //        0123456789012345678901
    const buf = "{ outer { inner } x }";
    // Cursor on the inner `}` at byte 16 → match is the inner `{` at byte 8.
    try std.testing.expectEqual(@as(?usize, 8), findMatchingBracket(buf, 16));
    // Cursor on the outer `}` at byte 20 → match is the outer `{` at byte 0.
    try std.testing.expectEqual(@as(?usize, 0), findMatchingBracket(buf, 20));
}

test "bracket: parens and square brackets work too" {
    try std.testing.expectEqual(@as(?usize, 0), findMatchingBracket("(a b)", 4));
    try std.testing.expectEqual(@as(?usize, 0), findMatchingBracket("[a b]", 4));
}

test "bracket: cursor on non-bracket returns null" {
    try std.testing.expectEqual(@as(?usize, null), findMatchingBracket("hello world", 5));
}

test "bracket: brackets inside strings are ignored" {
    //         0         1
    //         0123456789012345
    const buf = "echo \"} 1 2 3 \"";
    // The literal `}` byte at position 6 is INSIDE the dq string. The
    // lexer tokenizes the whole `"...}..."` as one `.string_dq` token.
    // Cursor on byte 6 sees a `}` byte, but no bracket-token at that
    // position → null.
    try std.testing.expectEqual(@as(?usize, null), findMatchingBracket(buf, 6));
}

test "bracket: unbalanced source returns null" {
    // Closing without opener.
    try std.testing.expectEqual(@as(?usize, null), findMatchingBracket("} no opener", 0));
}

test "bracket: highlightHook emits bold span on matching opener" {
    const alloc = std.testing.allocator;
    // Cursor just past the closing `}` (byte 14) → matcher should bolden
    // the opening `{` at byte 9.
    const buf = "if true { x }";
    const spans = try highlightHookAt(alloc, buf, buf.len);
    defer alloc.free(spans);

    // `{` is at byte 8 in `"if true { x }"`.
    var found_bold_at_8 = false;
    for (spans) |s| {
        if (s.start == 8 and s.end == 9 and s.style.bold) found_bold_at_8 = true;
    }
    try std.testing.expect(found_bold_at_8);
}

test "bracket: cursor not on a bracket emits no bold span on the openers" {
    const alloc = std.testing.allocator;
    // Cursor mid-buffer, not on any bracket. Existing dim style on the
    // brackets should fire, but no bold-on-opener span.
    const buf = "if true { x }";
    const spans = try highlightHookAt(alloc, buf, 5);
    defer alloc.free(spans);

    for (spans) |s| {
        if (s.start == 8 and s.end == 9) {
            try std.testing.expect(!s.style.bold);
        }
    }
}
