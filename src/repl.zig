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

// libc binding — `std.c` doesn't expose `getpgrp` in Zig 0.16.
extern "c" fn getpgrp() std.c.pid_t;
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
                eval.hangupRemainingJobs(session);
                _ = std.c.write(1, "\n", 1);
                return status;
            }
            try pending.append(alloc, '\n');
            _ = try evaluatePending(session, alloc, &pending);
            eval.hangupRemainingJobs(session);
            return session.last_status;
        }

        try pending.appendSlice(alloc, read_buf[0..@intCast(n)]);
        if (pending.items.len == 0 or pending.items[pending.items.len - 1] != '\n')
            continue;

        _ = try evaluatePending(session, alloc, &pending);

        if (session.exit_request) |req| {
            eval.fireExitTrap(session, alloc, null) catch {};
            eval.hangupRemainingJobs(session);
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

    var prompt_buf: [4096]u8 = undefined;
    while (true) {
        const prompt_text = if (pending.items.len == 0)
            slashPrompt(&prompt_buf, session)
        else
            "... ";
        const prompt = zigline.Prompt{
            .bytes = prompt_text,
            .width = promptDisplayWidth(prompt_text),
        };

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
        // Reset signal dispositions before execve. Ignored signals
        // (SIG_IGN) survive execve on POSIX — without this, the editor
        // would inherit the shell's interactive ignores for SIGINT,
        // SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE and Ctrl-C/Ctrl-Z
        // wouldn't work inside vim. (Handlers reset to SIG_DFL across
        // execve automatically; ignores do not. CHECKLIST §6.)
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
            const fg = if (at_command_pos) palette.command else palette.argument;
            try spans.append(allocator, .{
                .start = start,
                .end = end,
                .style = .{ .fg = fg },
            });
            at_command_pos = false;
            continue;
        }

        const style_opt = styleFor(tok, buffer[start..end], palette);
        if (style_opt) |style| {
            try spans.append(allocator, .{ .start = start, .end = end, .style = style });
        }
        at_command_pos = isCommandStarter(tok.cat);
    }

    return spans.toOwnedSlice(allocator);
}

/// Tokens after which the next `.ident` returns to command position.
/// Note: `lparen`/`lbrace`/`lbracket` count as starters because slash
/// uses them to introduce subshells, blocks, and groupings — each
/// contains a fresh sequence of commands.
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

fn isOpenBracketTok(cat: parser.TokenCat) bool {
    return switch (cat) {
        .lbrace, .lparen, .lbracket => true,
        else => false,
    };
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
    variable: zigline.Color,
    heredoc_body: zigline.Color,
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
    .heredoc_body = rgb(0x9e, 0xce, 0x6a), //  same as string
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
    .heredoc_body = rgb(0x85, 0x99, 0x00), //  green
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
        .variable, .var_braced, .dollar_paren, .at_paren => zigline.Style{ .fg = p.variable },
        .heredoc_body => zigline.Style{ .fg = p.heredoc_body },
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
    // Whitespace-only input: pressing Enter on an empty (or all-blanks)
    // prompt is a real-world no-op. Without this short-circuit, the
    // parser sees end-of-input where a statement was expected, emits
    // a diagnostic at the very end of the buffer, and `isIncompleteParse`
    // misreads that as "needs more input" — putting the REPL into the
    // `... ` continuation prompt forever. Match bash/sh: empty Enter
    // returns to a fresh prompt with no side effects.
    const trimmed = std.mem.trim(u8, pending.items, " \t\n\r");
    if (trimmed.len == 0) {
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

    // Step 7: snapshot the shell's terminal modes so they can be
    // restored after every foreground job. Programs like vim/less/
    // Python REPL push the tty into raw mode; without this snapshot,
    // returning to the shell prompt leaves Slash in whatever mode the
    // last foreground job was using.
    if (tty_fd) |fd| {
        if (std.posix.tcgetattr(fd)) |t| {
            session.shell_termios = t;
        } else |_| {}
    }
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
//   2. **Built-in default** — home-collapsed PWD + ` [N]` for nonzero
//      last-status + ` $ ` (or ` # ` for root). Pure ASCII bytes; width
//      equals byte length.
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
fn slashPrompt(buf: []u8, session: *const session_mod.Session) []const u8 {
    if (session.vars.get("PROMPT")) |v| switch (v.value) {
        .scalar => |raw| return expandPromptFormat(buf, session, raw),
        .list => {},
    };
    return renderDefaultPrompt(buf, session);
}

/// Built-in default prompt. Pure ASCII; byte length == display width.
fn renderDefaultPrompt(buf: []u8, session: *const session_mod.Session) []const u8 {
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
