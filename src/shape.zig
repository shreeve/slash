//! Shape — the parsed structure of a Slash source.
//!
//! Shape is purely structural and span-bearing. It is rich enough for
//! highlighting, completion, and formatting, but is NOT executable. The
//! Program lowering pass turns Shape into immutable executable semantics.
//!
//! Words are sequences of typed parts: literal text, variable references
//! (`$name`, `${...}`), command substitutions (`$(...)`), and globs.
//! Adjacent word atoms with no whitespace between them fuse into a single
//! Word with multiple parts — that's how `pre$x.bar` becomes one argv
//! element with three parts.

const std = @import("std");
const parser = @import("parser.zig");
const diag = @import("diagnostics.zig");
const slash = @import("slash.zig");

pub const Allocator = std.mem.Allocator;
pub const Span = diag.Span;
pub const Source = diag.Source;
pub const Sink = diag.Sink;
pub const cover = diag.cover;

// =============================================================================
// Word parts
// =============================================================================

pub const Flavor = enum { bare, single_quoted, double_quoted };

pub const TextPart = struct {
    /// Source slice. For `cooked = false`, bytes carry the original raw
    /// form (including outer quotes when quoted) and Word lowering does
    /// the quote-stripping/escape-decoding. For `cooked = true`, bytes
    /// are already decoded and Word lowering uses them as-is. The dq
    /// splitter emits cooked fragments with `flavor = .double_quoted`
    /// so glob detection still sees them as quoted (no expansion).
    bytes: []const u8,
    flavor: Flavor,
    cooked: bool = false,
    span: Span,
};

pub const VariablePart = struct {
    /// Bare name (no leading `$`). For `$@`, `$#`, etc., the name is the
    /// special character. For `$0..$9`, the name is the digit.
    name: []const u8,
    span: Span,
};

pub const VarBracedPart = struct {
    /// Interior between `${` and `}`. The expansion engine parses this
    /// at evaluation time to decide whether it's a bare name or a more
    /// elaborate form (`${name ?? default}`, etc.).
    body: []const u8,
    span: Span,
};

pub const CmdSubstPart = struct {
    /// The captured sequence inside `$( ... )`.
    body: *const Shape,
    span: Span,
};

pub const ListCapturePart = struct {
    /// The captured sequence inside `@( ... )`. Stdout splits on
    /// newlines (the empty trailing newline is dropped) and each
    /// resulting field becomes one argv element at expansion time.
    body: *const Shape,
    span: Span,
};

pub const ProcSubstDir = enum { input, output };

pub const ProcSubstPart = struct {
    /// `<(...)` produces input (its stdout reads from a pipe whose
    /// path is the argv element); `>(...)` consumes output the
    /// other way.
    dir: ProcSubstDir,
    body: *const Shape,
    span: Span,
};

pub const GlobPart = struct {
    /// The pattern as written (e.g. `*.txt`). Recovered from a bare
    /// text part containing unquoted glob metacharacters during Word
    /// lowering.
    pattern: []const u8,
    span: Span,
};

pub const WordPartShape = union(enum) {
    text: TextPart,
    variable: VariablePart,
    var_braced: VarBracedPart,
    cmd_subst: CmdSubstPart,
    list_capture: ListCapturePart,
    proc_subst: ProcSubstPart,
    glob: GlobPart,
};

pub const WordShape = struct {
    parts: []const WordPartShape,
    span: Span,
};

// =============================================================================
// Redirects
// =============================================================================

pub const RedirectOp = enum {
    read,
    read_fd,
    write,
    write_fd,
    append,
    both,
    both_append,
    dup_out,
    dup_in,
    heredoc,
    heredoc_lit,
};

pub const HeredocBody = struct {
    /// Body bytes still in their on-disk form. Dedent is computed and
    /// applied at Word lowering time so the source-faithful slice
    /// stays available for highlighting / completion.
    raw: []const u8,
    /// Column at which the closing tag appeared (1-indexed); becomes
    /// the dedent margin. Body lines have up to `dedent_col - 1`
    /// leading spaces stripped per line.
    dedent_col: u32,
    /// True for `<<TAG` (interpolating); false for `<<'TAG'` (literal).
    interpolating: bool,
    span: Span,
};

pub const RedirectShape = struct {
    op: RedirectOp,
    /// fd-prefix span for `_fd` and `dup_*` ops.
    fd_src: ?Span,
    /// File target (`null` for dup and heredoc ops).
    target: ?WordShape,
    /// Heredoc body (only for `heredoc` / `heredoc_lit` ops).
    heredoc: ?HeredocBody,
    span: Span,
};

// =============================================================================
// Assignments / env binds
// =============================================================================

pub const AssignValueShape = union(enum) {
    scalar: WordShape,
    list: []const WordShape,
};

pub const EnvBindShape = struct {
    /// Bare variable name (the trailing `=` of NAME_EQ is stripped).
    name: []const u8,
    value: AssignValueShape,
    span: Span,
};

pub const AssignsShape = struct {
    binds: []const EnvBindShape,
    span: Span,
};

// =============================================================================
// Compound shapes
// =============================================================================

pub const CommandShape = struct {
    env: []const EnvBindShape,
    exe: WordShape,
    args: []const WordShape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const PipelineShape = struct {
    stages: []const Shape,
    span: Span,
};

pub const SequenceOp = enum { always, and_then, or_else };

pub const SequenceItemShape = struct {
    program: Shape,
    next_op: ?SequenceOp,
};

pub const SequenceShape = struct {
    items: []const SequenceItemShape,
    span: Span,
};

pub const SubshellShape = struct {
    body: *const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const BlockShape = struct {
    body: *const Shape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const DetachedShape = struct {
    body: *const Shape,
    span: Span,
};

pub const ConditionalShape = struct {
    cond: *const Shape,
    then_body: *const Shape,
    /// Either another `ConditionalShape` (chained `else if`) or a Shape
    /// containing the else block's body. `null` means no else clause.
    else_body: ?*const Shape,
    span: Span,
};

pub const WhileShape = struct {
    cond: *const Shape,
    body: *const Shape,
    span: Span,
};

pub const ForShape = struct {
    binding: []const u8,
    items: []const WordShape,
    body: *const Shape,
    span: Span,
};

pub const CmdDefShape = struct {
    name: []const u8,
    body: *const Shape,
    span: Span,
};

/// `str NAME { body }`. The body is opaque raw bytes captured by the
/// lexer wrapper — no inner shape tree, no parsing. The bytes are
/// stored verbatim in the StrTable at eval time and replayed onto
/// the editor buffer when the user triggers expansion. See PLAN §12.
pub const StrDefShape = struct {
    name: []const u8,
    /// Source bytes between the matched braces, with leading and
    /// trailing horizontal whitespace (space/tab) trimmed at lower
    /// time. Internal whitespace is preserved exactly.
    body: []const u8,
    span: Span,
};

/// `match SUBJECT { arms... }`. Subject is one word; each arm has one or
/// more patterns (literal grammar atoms — see PLAN §12) and a body. The
/// runtime tries arms in source order and runs the first arm whose
/// pattern set matches the subject's expanded value. With no match,
/// `match` exits 0 and runs nothing.
pub const MatchArmShape = struct {
    patterns: []const WordShape,
    body: *const Shape,
    span: Span,
};

pub const MatchShape = struct {
    subject: WordShape,
    arms: []const MatchArmShape,
    span: Span,
};

// =============================================================================
// Shape union
// =============================================================================

pub const Shape = union(enum) {
    word: WordShape,
    command: CommandShape,
    pipeline: PipelineShape,
    sequence: SequenceShape,
    subshell: SubshellShape,
    block: BlockShape,
    detached: DetachedShape,
    assigns: AssignsShape,
    conditional: ConditionalShape,
    @"while": WhileShape,
    @"for": ForShape,
    @"match": MatchShape,
    cmd_def: CmdDefShape,
    str_def: StrDefShape,

    pub fn span(self: Shape) Span {
        return switch (self) {
            .word => |w| w.span,
            .command => |c| c.span,
            .pipeline => |p| p.span,
            .sequence => |s| s.span,
            .subshell => |s| s.span,
            .block => |b| b.span,
            .detached => |d| d.span,
            .assigns => |a| a.span,
            .conditional => |c| c.span,
            .@"while" => |w| w.span,
            .@"for" => |f| f.span,
            .@"match" => |m| m.span,
            .cmd_def => |d| d.span,
            .str_def => |d| d.span,
        };
    }
};

pub const Trivia = struct {
    kind: enum { whitespace, comment },
    span: Span,
};

pub const Parsed = struct {
    source: Source,
    root: Shape,
    trivia: []const Trivia,
};

// =============================================================================
// Public parse
// =============================================================================

pub fn parse(source: Source, alloc: Allocator, sink: ?Sink) !Parsed {
    var p = parser.Parser.init(alloc, source.text);
    defer p.deinit();

    const sexp = p.parseProgram() catch {
        // Build a span pointing at the offending token. For an
        // unexpected EOF, point at the end of the source so the caret
        // lands somewhere sensible.
        const tok = p.current;
        const start: u32 = @min(tok.pos, @as(u32, @intCast(source.text.len)));
        const end: u32 = if (tok.cat == .eof)
            start
        else
            @min(start + @max(tok.len, 1), @as(u32, @intCast(source.text.len)));
        const span = diag.Span{ .start = start, .end = end };

        // Allocate the message from the caller's arena so its lifetime
        // outlives `parse`. The diagnostic itself keeps the slice; the
        // arena stays alive long enough for the caller to render.
        const msg = std.fmt.allocPrint(
            alloc,
            "unexpected {s}",
            .{@tagName(tok.cat)},
        ) catch "parse error";

        // Code allocation is per-error class; use SH0001 as a generic
        // fallback so callers can match on it. Future code split can
        // break out specific categories without breaking existing tests.
        try diag.emit(sink, diag.make(
            .shape, .@"error", "SH0001", msg, source, span,
        ));
        return error.ParserError;
    };

    const root = try convertShape(alloc, source, sexp, sink);
    return Parsed{
        .source = source,
        .root = root,
        .trivia = &.{},
    };
}

// =============================================================================
// Sexp → Shape
// =============================================================================

fn convertShape(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!Shape {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    return switch (head) {
        .sequence => Shape{ .sequence = try convertSequence(alloc, source, items[1..], spanOfList(items), sink) },
        .command => Shape{ .command = try convertCommand(alloc, source, items[1..], sink) },
        .pipeline => Shape{ .pipeline = try convertPipeline(alloc, source, items[1..], sink) },
        .subshell => Shape{ .subshell = try convertSubshell(alloc, source, items[1..], sink) },
        .block => Shape{ .block = try convertBlock(alloc, source, items[1..], sink) },
        .assigns => Shape{ .assigns = try convertAssigns(alloc, source, items[1..], spanOfList(items), sink) },
        .@"if" => Shape{ .conditional = try convertConditional(alloc, source, items[1..], sink) },
        .@"while" => Shape{ .@"while" = try convertWhile(alloc, source, items[1..], sink) },
        .@"for" => Shape{ .@"for" = try convertFor(alloc, source, items[1..], sink) },
        .@"match" => Shape{ .@"match" = try convertMatch(alloc, source, items[1..], sink) },
        .cmd_def => Shape{ .cmd_def = try convertCmdDef(alloc, source, items[1..], sink) },
        .str_def => Shape{ .str_def = try convertStrDef(source, items[1..], sink) },
        else => {
            try emitBadShape(source, sexp, sink, "unexpected head tag at top level");
            return error.InvalidShape;
        },
    };
}

// ---- sequence ---------------------------------------------------------------

fn convertSequence(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    full_span: Span,
    sink: ?Sink,
) anyerror!SequenceShape {
    if (items.len == 0) {
        try emitBadShape(source, .nil, sink, "empty sequence");
        return error.InvalidShape;
    }

    var list = std.ArrayListUnmanaged(SequenceItemShape).empty;
    defer list.deinit(alloc);

    // Pending item: the current "trailing" Shape that will become the
    // next emitted SequenceItem once we see the connector to the next
    // item (or end-of-sequence).
    var pending: ?Shape = try convertStage(alloc, source, items[0], sink);

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const tail_items = try expectList(items[i], source, sink);
        const tail_head = try expectTag(tail_items[0], source, sink);
        const payload = if (tail_items.len >= 2) tail_items[1] else parser.Sexp.nil;

        switch (tail_head) {
            .seq_always, .seq_and, .seq_or => {
                if (payload == .nil) {
                    // Empty separator. Commit pending with no connector and
                    // continue looking for the next item.
                    if (pending) |p| try list.append(alloc, .{ .program = p, .next_op = null });
                    pending = null;
                    continue;
                }
                const op: SequenceOp = switch (tail_head) {
                    .seq_always => .always,
                    .seq_and => .and_then,
                    .seq_or => .or_else,
                    else => unreachable,
                };
                if (pending) |p| {
                    try list.append(alloc, .{ .program = p, .next_op = op });
                }
                pending = try convertStage(alloc, source, payload, sink);
            },
            .seq_bg => {
                if (pending) |p| {
                    const body_ptr = try alloc.create(Shape);
                    body_ptr.* = p;
                    const detached = Shape{ .detached = .{
                        .body = body_ptr,
                        .span = p.span(),
                    } };
                    if (payload == .nil) {
                        try list.append(alloc, .{ .program = detached, .next_op = null });
                        pending = null;
                        continue;
                    }
                    try list.append(alloc, .{ .program = detached, .next_op = .always });
                    pending = try convertStage(alloc, source, payload, sink);
                } else if (payload != .nil) {
                    // Lone `& item` after a blank: treat the bound item as
                    // a new pending; the `&` has nothing to wrap.
                    pending = try convertStage(alloc, source, payload, sink);
                }
            },
            else => {
                try emitBadShape(source, items[i], sink, "unexpected sequence tail tag");
                return error.InvalidShape;
            },
        }
    }

    if (pending) |p| try list.append(alloc, .{ .program = p, .next_op = null });
    return finishSequence(alloc, &list, full_span);
}

fn finishSequence(
    alloc: Allocator,
    list: *std.ArrayListUnmanaged(SequenceItemShape),
    full_span: Span,
) !SequenceShape {
    return .{
        .items = try list.toOwnedSlice(alloc),
        .span = full_span,
    };
}

/// A sequence item (or pipeline stage).
fn convertStage(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!Shape {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    return switch (head) {
        .command => Shape{ .command = try convertCommand(alloc, source, items[1..], sink) },
        .pipeline => Shape{ .pipeline = try convertPipeline(alloc, source, items[1..], sink) },
        .subshell => Shape{ .subshell = try convertSubshell(alloc, source, items[1..], sink) },
        .block => Shape{ .block = try convertBlock(alloc, source, items[1..], sink) },
        .assigns => Shape{ .assigns = try convertAssigns(alloc, source, items[1..], spanOfList(items), sink) },
        .@"if" => Shape{ .conditional = try convertConditional(alloc, source, items[1..], sink) },
        .@"while" => Shape{ .@"while" = try convertWhile(alloc, source, items[1..], sink) },
        .@"for" => Shape{ .@"for" = try convertFor(alloc, source, items[1..], sink) },
        .@"match" => Shape{ .@"match" = try convertMatch(alloc, source, items[1..], sink) },
        .cmd_def => Shape{ .cmd_def = try convertCmdDef(alloc, source, items[1..], sink) },
        .str_def => Shape{ .str_def = try convertStrDef(source, items[1..], sink) },
        else => {
            try emitBadShape(source, sexp, sink, "expected a command, pipeline, subshell, block, assignment, or control form");
            return error.InvalidShape;
        },
    };
}

// ---- command ----------------------------------------------------------------

fn convertCommand(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!CommandShape {
    if (children.len < 2) {
        try emitBadShape(source, .nil, sink, "command requires env-binds slot and an exe");
        return error.InvalidShape;
    }

    // First child is either nil (no env binds) or `(env_binds ...)`.
    var env_binds: []const EnvBindShape = &.{};
    if (children[0] != .nil) {
        const env_items = try expectList(children[0], source, sink);
        _ = try expectHeadTag(env_items, .env_binds, source, sink);
        var binds = try alloc.alloc(EnvBindShape, env_items.len - 1);
        for (env_items[1..], 0..) |b, i| binds[i] = try convertEnvBind(alloc, source, b, sink);
        env_binds = binds;
    }

    const exe = try convertWordOrAtomToWord(alloc, source, children[1], sink);

    var args_list = std.ArrayListUnmanaged(WordShape).empty;
    defer args_list.deinit(alloc);
    var redirs_list = std.ArrayListUnmanaged(RedirectShape).empty;
    defer redirs_list.deinit(alloc);

    var i: usize = 2;
    while (i < children.len) : (i += 1) {
        const child = children[i];
        const child_items = try expectList(child, source, sink);
        const tag = try expectTag(child_items[0], source, sink);
        if (isWordAtomTag(tag)) {
            try args_list.append(alloc, try convertWordOrAtomToWord(alloc, source, child, sink));
        } else if (isRedirectTag(tag)) {
            try redirs_list.append(alloc, try convertRedirect(alloc, source, child, tag, child_items[1..], sink));
        } else {
            try emitBadShape(source, child, sink, "unexpected child in command");
            return error.InvalidShape;
        }
    }

    // Word concatenation (PLAN: `pre$x.bar` is one argv element). Fuse
    // adjacent word atoms whose source spans are touching (end of one
    // == start of next) into a single Word with multiple parts.
    const fused_args = try fuseAdjacentWords(alloc, args_list.items);

    const span_end = blk: {
        if (redirs_list.items.len > 0) break :blk redirs_list.items[redirs_list.items.len - 1].span.end;
        if (fused_args.len > 0) break :blk fused_args[fused_args.len - 1].span.end;
        break :blk exe.span.end;
    };

    return .{
        .env = env_binds,
        .exe = exe,
        .args = fused_args,
        .redirects = try redirs_list.toOwnedSlice(alloc),
        .span = .{ .start = exe.span.start, .end = span_end },
    };
}

fn fuseAdjacentWords(alloc: Allocator, words: []const WordShape) ![]const WordShape {
    if (words.len <= 1) return alloc.dupe(WordShape, words);

    var out = std.ArrayListUnmanaged(WordShape).empty;
    defer out.deinit(alloc);

    var current = words[0];
    var current_parts = std.ArrayListUnmanaged(WordPartShape).empty;
    defer current_parts.deinit(alloc);
    try current_parts.appendSlice(alloc, current.parts);

    for (words[1..]) |w| {
        if (w.span.start == current.span.end) {
            // Adjacent — fuse.
            try current_parts.appendSlice(alloc, w.parts);
            current.span.end = w.span.end;
        } else {
            current.parts = try alloc.dupe(WordPartShape, current_parts.items);
            try out.append(alloc, current);
            current = w;
            current_parts.clearRetainingCapacity();
            try current_parts.appendSlice(alloc, w.parts);
        }
    }
    current.parts = try alloc.dupe(WordPartShape, current_parts.items);
    try out.append(alloc, current);

    return out.toOwnedSlice(alloc);
}

// ---- pipeline ---------------------------------------------------------------

fn convertPipeline(
    alloc: Allocator,
    source: Source,
    stages: []const parser.Sexp,
    sink: ?Sink,
) anyerror!PipelineShape {
    if (stages.len < 2) {
        try emitBadShape(source, .nil, sink, "pipeline requires at least two stages");
        return error.InvalidShape;
    }
    var out = try alloc.alloc(Shape, stages.len);
    for (stages, 0..) |st, i| out[i] = try convertStage(alloc, source, st, sink);
    return .{
        .stages = out,
        .span = cover(out[0].span(), out[out.len - 1].span()),
    };
}

// ---- subshell / block -------------------------------------------------------

fn convertSubshell(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!SubshellShape {
    if (children.len == 0) {
        try emitBadShape(source, .nil, sink, "subshell requires a body");
        return error.InvalidShape;
    }
    const body = try convertShape(alloc, source, children[0], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    var redirs = std.ArrayListUnmanaged(RedirectShape).empty;
    defer redirs.deinit(alloc);
    if (children.len >= 2 and children[1] != .nil) {
        try collectRedirects(alloc, source, children[1], &redirs, sink);
    }

    const span_end = if (redirs.items.len > 0)
        redirs.items[redirs.items.len - 1].span.end
    else
        body.span().end;

    return .{
        .body = body_ptr,
        .redirects = try redirs.toOwnedSlice(alloc),
        .span = .{ .start = body.span().start, .end = span_end },
    };
}

fn convertBlock(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!BlockShape {
    if (children.len == 0) {
        try emitBadShape(source, .nil, sink, "block requires a body");
        return error.InvalidShape;
    }
    const body = try convertShape(alloc, source, children[0], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    var redirs = std.ArrayListUnmanaged(RedirectShape).empty;
    defer redirs.deinit(alloc);
    if (children.len >= 2 and children[1] != .nil) {
        try collectRedirects(alloc, source, children[1], &redirs, sink);
    }

    const span_end = if (redirs.items.len > 0)
        redirs.items[redirs.items.len - 1].span.end
    else
        body.span().end;

    return .{
        .body = body_ptr,
        .redirects = try redirs.toOwnedSlice(alloc),
        .span = .{ .start = body.span().start, .end = span_end },
    };
}

fn collectRedirects(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    out: *std.ArrayListUnmanaged(RedirectShape),
    sink: ?Sink,
) !void {
    const items = try expectList(sexp, source, sink);
    _ = try expectHeadTag(items, .redirects, source, sink);
    for (items[1..]) |r| {
        const r_items = try expectList(r, source, sink);
        const tag = try expectTag(r_items[0], source, sink);
        try out.append(alloc, try convertRedirect(alloc, source, r, tag, r_items[1..], sink));
    }
}

// ---- conditional / loops ----------------------------------------------------

fn convertConditional(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!ConditionalShape {
    if (children.len < 2 or children.len > 3) {
        try emitBadShape(source, .nil, sink, "conditional requires cond, then-body, optional else-body");
        return error.InvalidShape;
    }

    const cond = try convertCond(alloc, source, children[0], sink);
    const cond_ptr = try alloc.create(Shape);
    cond_ptr.* = cond;

    const then_body_shape = try convertBody(alloc, source, children[1], sink);
    const then_body_ptr = try alloc.create(Shape);
    then_body_ptr.* = then_body_shape;

    var else_ptr: ?*Shape = null;
    if (children.len == 3 and children[2] != .nil) {
        const else_items = try expectList(children[2], source, sink);
        const else_tag = try expectTag(else_items[0], source, sink);
        switch (else_tag) {
            .@"else" => {
                if (else_items.len < 2) {
                    try emitBadShape(source, children[2], sink, "else missing body");
                    return error.InvalidShape;
                }
                const eb_shape = try convertBody(alloc, source, else_items[1], sink);
                const p = try alloc.create(Shape);
                p.* = eb_shape;
                else_ptr = p;
            },
            .elif => {
                // Nested conditional. The Sexp wraps the inner `if`.
                if (else_items.len < 2) {
                    try emitBadShape(source, children[2], sink, "elif missing inner conditional");
                    return error.InvalidShape;
                }
                const inner = try convertShape(alloc, source, else_items[1], sink);
                const p = try alloc.create(Shape);
                p.* = inner;
                else_ptr = p;
            },
            else => {
                try emitBadShape(source, children[2], sink, "unexpected else_part tag");
                return error.InvalidShape;
            },
        }
    }

    const then_end = then_body_shape.span().end;
    const total_end = if (else_ptr) |ep| ep.*.span().end else then_end;

    return .{
        .cond = cond_ptr,
        .then_body = then_body_ptr,
        .else_body = else_ptr,
        .span = .{ .start = cond.span().start, .end = total_end },
    };
}

fn convertWhile(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WhileShape {
    if (children.len != 2) {
        try emitBadShape(source, .nil, sink, "while requires cond and body");
        return error.InvalidShape;
    }
    const cond = try convertCond(alloc, source, children[0], sink);
    const cond_ptr = try alloc.create(Shape);
    cond_ptr.* = cond;

    const body = try convertBody(alloc, source, children[1], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    return .{
        .cond = cond_ptr,
        .body = body_ptr,
        .span = .{ .start = cond.span().start, .end = body.span().end },
    };
}

fn convertStrDef(
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!StrDefShape {
    if (children.len != 2) {
        try emitBadShape(source, .nil, sink, "str definition requires a name and a body");
        return error.InvalidShape;
    }
    const name_span = try expectSrcSpan(children[0], source, sink);
    const name = source.text[name_span.start..name_span.end];
    const body_span = try expectSrcSpan(children[1], source, sink);

    // Trim leading/trailing horizontal whitespace from the captured
    // body bytes (per the design — `{ x }` and `{x}` produce the same
    // stored value). Internal whitespace is preserved exactly.
    const raw = source.text[body_span.start..body_span.end];
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and (raw[lo] == ' ' or raw[lo] == '\t')) : (lo += 1) {}
    while (hi > lo and (raw[hi - 1] == ' ' or raw[hi - 1] == '\t')) : (hi -= 1) {}
    const trimmed = raw[lo..hi];

    return .{
        .name = name,
        .body = trimmed,
        .span = .{ .start = name_span.start, .end = body_span.end },
    };
}

fn convertCmdDef(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!CmdDefShape {
    if (children.len != 2) {
        try emitBadShape(source, .nil, sink, "cmd definition requires a name and a body");
        return error.InvalidShape;
    }
    const name_span = try expectSrcSpan(children[0], source, sink);
    const name = source.text[name_span.start..name_span.end];

    const body = try convertBody(alloc, source, children[1], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    return .{
        .name = name,
        .body = body_ptr,
        .span = .{ .start = name_span.start, .end = body.span().end },
    };
}

fn convertFor(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!ForShape {
    if (children.len != 3) {
        try emitBadShape(source, .nil, sink, "for requires binding, items, body");
        return error.InvalidShape;
    }
    // children[0] is the binding IDENT (a `.src` source token)
    const binding_span = try expectSrcSpan(children[0], source, sink);
    const binding = source.text[binding_span.start..binding_span.end];

    // children[1] is `(words word_atom+)`
    const words_items = try expectList(children[1], source, sink);
    _ = try expectHeadTag(words_items, .words, source, sink);
    var items_list = try alloc.alloc(WordShape, words_items.len - 1);
    for (words_items[1..], 0..) |w, i|
        items_list[i] = try convertWordOrAtomToWord(alloc, source, w, sink);

    const body = try convertBody(alloc, source, children[2], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    return .{
        .binding = binding,
        .items = items_list,
        .body = body_ptr,
        .span = .{ .start = binding_span.start, .end = body.span().end },
    };
}

fn convertMatch(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!MatchShape {
    if (children.len != 2) {
        try emitBadShape(source, .nil, sink, "match requires subject and arm-block");
        return error.InvalidShape;
    }

    const subject = try convertWordOrAtomToWord(alloc, source, children[0], sink);

    // children[1] is `(match_arms arm1 arm2 ...)` from the LBRACE/INDENT
    // wrapper; the spread-collector strips the wrapping list.
    const arms_items = try expectList(children[1], source, sink);
    _ = try expectHeadTag(arms_items, .match_arms, source, sink);

    if (arms_items.len < 2) {
        try emitBadShape(source, children[1], sink, "match requires at least one arm");
        return error.InvalidShape;
    }

    var arms = try alloc.alloc(MatchArmShape, arms_items.len - 1);
    for (arms_items[1..], 0..) |arm_sexp, i|
        arms[i] = try convertMatchArm(alloc, source, arm_sexp, sink);

    const total_span: Span = .{
        .start = subject.span.start,
        .end = arms[arms.len - 1].span.end,
    };
    return .{ .subject = subject, .arms = arms, .span = total_span };
}

fn convertMatchArm(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!MatchArmShape {
    const items = try expectList(sexp, source, sink);
    _ = try expectHeadTag(items, .match_arm, source, sink);
    if (items.len != 3) {
        try emitBadShape(source, sexp, sink, "match arm needs patterns and body");
        return error.InvalidShape;
    }

    // items[1] is `(words word_atom+)` (one or more patterns).
    const words_items = try expectList(items[1], source, sink);
    _ = try expectHeadTag(words_items, .words, source, sink);
    if (words_items.len < 2) {
        try emitBadShape(source, items[1], sink, "match arm needs at least one pattern");
        return error.InvalidShape;
    }
    var patterns = try alloc.alloc(WordShape, words_items.len - 1);
    for (words_items[1..], 0..) |w, i|
        patterns[i] = try convertWordOrAtomToWord(alloc, source, w, sink);

    const body = try convertBody(alloc, source, items[2], sink);
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    return .{
        .patterns = patterns,
        .body = body_ptr,
        .span = .{ .start = patterns[0].span.start, .end = body.span().end },
    };
}

/// `cond_chain` resolves to either a single pipeline/command or to a chain
/// of `cond_and`/`cond_or` reductions wrapping pipelines. We canonicalize
/// chains into `SequenceShape` with `and_then`/`or_else` connectors.
fn convertCond(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!Shape {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    return switch (head) {
        .cond_and, .cond_or => Shape{ .sequence = try convertCondChain(alloc, source, sexp, sink) },
        else => convertStage(alloc, source, sexp, sink),
    };
}

fn convertCondChain(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!SequenceShape {
    var list = std.ArrayListUnmanaged(SequenceItemShape).empty;
    defer list.deinit(alloc);
    var span_total: Span = .{ .start = 0, .end = 0 };
    var first = true;

    try flattenCondChain(alloc, source, sexp, &list, sink);

    if (list.items.len > 0) {
        span_total = list.items[0].program.span();
        for (list.items) |it| {
            const s = it.program.span();
            if (first) {
                span_total = s;
                first = false;
            } else {
                span_total = cover(span_total, s);
            }
        }
    }

    return .{
        .items = try list.toOwnedSlice(alloc),
        .span = span_total,
    };
}

fn flattenCondChain(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    out: *std.ArrayListUnmanaged(SequenceItemShape),
    sink: ?Sink,
) anyerror!void {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    switch (head) {
        .cond_and, .cond_or => {
            // Left-associated: (cond_and (cond_and a b) c) → flatten as a, b, c
            try flattenCondChain(alloc, source, items[1], out, sink);
            // The previous item's connector is set to the operator HERE.
            const op: SequenceOp = switch (head) {
                .cond_and => .and_then,
                .cond_or => .or_else,
                else => unreachable,
            };
            const last = &out.items[out.items.len - 1];
            last.next_op = op;

            const right_shape = try convertStage(alloc, source, items[2], sink);
            try out.append(alloc, .{ .program = right_shape, .next_op = null });
        },
        else => {
            const shape = try convertStage(alloc, source, sexp, sink);
            try out.append(alloc, .{ .program = shape, .next_op = null });
        },
    }
}

fn convertBody(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!Shape {
    // body is `(body sequence)`; unwrap the sequence directly.
    const items = try expectList(sexp, source, sink);
    _ = try expectHeadTag(items, .body, source, sink);
    if (items.len < 2) {
        try emitBadShape(source, sexp, sink, "body missing inner sequence");
        return error.InvalidShape;
    }
    return try convertShape(alloc, source, items[1], sink);
}

// ---- assigns ---------------------------------------------------------------

fn convertAssigns(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    full_span: Span,
    sink: ?Sink,
) anyerror!AssignsShape {
    if (children.len == 0) {
        try emitBadShape(source, .nil, sink, "assigns requires at least one binding");
        return error.InvalidShape;
    }
    var binds = try alloc.alloc(EnvBindShape, children.len);
    for (children, 0..) |b, i| binds[i] = try convertEnvBind(alloc, source, b, sink);
    return .{ .binds = binds, .span = full_span };
}

fn convertEnvBind(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!EnvBindShape {
    const items = try expectList(sexp, source, sink);
    _ = try expectHeadTag(items, .env_bind, source, sink);
    if (items.len != 3) {
        try emitBadShape(source, sexp, sink, "env_bind expects NAME_EQ and assign_value");
        return error.InvalidShape;
    }
    // items[1] is the NAME_EQ source token; the source slice ends with `=`
    const name_span = try expectSrcSpan(items[1], source, sink);
    const raw = source.text[name_span.start..name_span.end];
    if (raw.len == 0 or raw[raw.len - 1] != '=') {
        try emitBadShape(source, sexp, sink, "env_bind name must end with '='");
        return error.InvalidShape;
    }
    const name = raw[0 .. raw.len - 1];

    // items[2] is `(scalar word_atom)` or `(list word_atom*)`
    const value = try convertAssignValue(alloc, source, items[2], sink);
    const value_span = switch (value) {
        .scalar => |w| w.span,
        .list => |ws| if (ws.len > 0) cover(ws[0].span, ws[ws.len - 1].span) else name_span,
    };

    return .{
        .name = name,
        .value = value,
        .span = .{ .start = name_span.start, .end = value_span.end },
    };
}

fn convertAssignValue(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!AssignValueShape {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    return switch (head) {
        .scalar => blk: {
            if (items.len != 2) {
                try emitBadShape(source, sexp, sink, "scalar expects one word_atom");
                return error.InvalidShape;
            }
            const w = try convertWordOrAtomToWord(alloc, source, items[1], sink);
            break :blk AssignValueShape{ .scalar = w };
        },
        .list => blk: {
            var ws = try alloc.alloc(WordShape, items.len - 1);
            for (items[1..], 0..) |it, i|
                ws[i] = try convertWordOrAtomToWord(alloc, source, it, sink);
            break :blk AssignValueShape{ .list = ws };
        },
        else => {
            try emitBadShape(source, sexp, sink, "expected scalar or list assign value");
            return error.InvalidShape;
        },
    };
}

// ---- word / atom ------------------------------------------------------------

/// A `word_atom` becomes a Word with a single part. Adjacent atoms get
/// fused later (in `fuseAdjacentWords`).
fn convertWordOrAtomToWord(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    const items = try expectList(sexp, source, sink);
    const head = try expectTag(items[0], source, sink);
    return switch (head) {
        .word => try convertWordPart(alloc, source, items, sink),
        .@"var" => try convertVariableAtom(alloc, source, items, sink),
        .var_braced => try convertVarBracedAtom(alloc, source, items, sink),
        .cmd_subst => try convertCmdSubstAtom(alloc, source, items, sink),
        .list_capture => try convertListCaptureAtom(alloc, source, items, sink),
        .proc_sub_in => try convertProcSubAtom(alloc, source, items, .input, sink),
        .proc_sub_out => try convertProcSubAtom(alloc, source, items, .output, sink),
        else => {
            try emitBadShape(source, sexp, sink, "expected word_atom variant");
            return error.InvalidShape;
        },
    };
}

fn convertWordPart(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    if (items.len != 2) {
        try emitBadShape(source, items[0], sink, "word must have exactly one source child");
        return error.InvalidShape;
    }
    const tok_src = try expectSrc(items[1], source, sink);
    const span = Span{ .start = tok_src.pos, .end = tok_src.pos + tok_src.len };
    const bytes = source.text[span.start..span.end];
    const flavor: Flavor = if (bytes.len == 0)
        .bare
    else switch (bytes[0]) {
        '\'' => .single_quoted,
        '"' => .double_quoted,
        else => .bare,
    };

    // Double-quoted strings interpolate `$name`, `${...}`, and `$(...)` —
    // the body is split into typed parts at Shape time. Escapes are
    // decoded inline. Outer flavor=double_quoted is preserved on the
    // first text fragment (if any) so the Word lowering round-trip is
    // observable in tests; subsequent fragments use .bare since their
    // bytes are already cooked.
    if (flavor == .double_quoted) {
        const parts = try splitDoubleQuoted(alloc, source, bytes, span, sink);
        return .{ .parts = parts, .span = span };
    }

    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .text = .{ .bytes = bytes, .flavor = flavor, .span = span } };
    return .{ .parts = parts, .span = span };
}

// =============================================================================
// Double-quoted string interpolation
// =============================================================================
//
// A `"..."` lexer token is one byte run. The Shape converter walks the
// interior, decoding escapes and splitting on `$name`, `${name}`, and
// `$(...)` to produce a list of typed `WordPartShape` items. The Word
// layer concatenates them at runtime; list-typed variables in the middle
// of a quoted string are caught at expansion time.
//
// Escape table (matching word.zig's decodeDouble):
//   \"  → "
//   \\  → \
//   \n  → newline
//   \t  → tab
//   \r  → carriage return
//   \$  → $ (literal — no interpolation)
//   \0  → NUL
//   \X  → \X verbatim (unknown escape)

fn splitDoubleQuoted(
    alloc: Allocator,
    source: Source,
    bytes: []const u8,
    full_span: Span,
    sink: ?Sink,
) ![]WordPartShape {
    std.debug.assert(bytes.len >= 2 and bytes[0] == '"' and bytes[bytes.len - 1] == '"');
    const body = bytes[1 .. bytes.len - 1];
    const body_start: u32 = full_span.start + 1;

    var parts = std.ArrayListUnmanaged(WordPartShape).empty;
    defer parts.deinit(alloc);
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    defer text_buf.deinit(alloc);
    var text_run_start: usize = 0;

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];

        if (c == '\\' and i + 1 < body.len) {
            const n = body[i + 1];
            const decoded: u8 = switch (n) {
                '"' => '"',
                '\\' => '\\',
                '$' => '$',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'e' => 0x1b, // ESC — for ANSI escape sequences
                '0' => 0,
                else => {
                    try text_buf.append(alloc, c);
                    try text_buf.append(alloc, n);
                    i += 2;
                    continue;
                },
            };
            try text_buf.append(alloc, decoded);
            i += 2;
            continue;
        }

        // List capture inside a dq string: `@(...)`.
        if (c == '@' and i + 1 < body.len and body[i + 1] == '(') {
            var depth: u32 = 1;
            var j = i + 2;
            while (j < body.len) {
                const ch = body[j];
                if (ch == '"') {
                    j += 1;
                    while (j < body.len and body[j] != '"') {
                        if (body[j] == '\\' and j + 1 < body.len) j += 1;
                        j += 1;
                    }
                    if (j < body.len) j += 1;
                    continue;
                }
                if (ch == '\'') {
                    j += 1;
                    while (j < body.len and body[j] != '\'') j += 1;
                    if (j < body.len) j += 1;
                    continue;
                }
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                j += 1;
            }
            if (j < body.len and depth == 0) {
                try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, i);

                const inner_bytes = body[i + 2 .. j];
                const inner_source = Source{ .name = source.name, .text = inner_bytes };
                var p = parser.Parser.init(alloc, inner_bytes);
                defer p.deinit();
                const inner_sexp = p.parseProgram() catch {
                    try emitBadShape(source, .nil, sink, "parse error in `@(...)` inside double-quoted string");
                    try text_buf.append(alloc, '@');
                    i += 1;
                    continue;
                };
                const inner_shape = try convertShape(alloc, inner_source, inner_sexp, sink);
                const body_ptr = try alloc.create(Shape);
                body_ptr.* = inner_shape;

                const part_span = Span{
                    .start = body_start + @as(u32, @intCast(i)),
                    .end = body_start + @as(u32, @intCast(j + 1)),
                };
                try parts.append(alloc, .{ .list_capture = .{
                    .body = body_ptr,
                    .span = part_span,
                } });
                i = j + 1;
                text_run_start = i;
                continue;
            }
            // No matching close-paren — treat the `@` as literal text.
            try text_buf.append(alloc, '@');
            i += 1;
            continue;
        }

        if (c == '$' and i + 1 < body.len) {
            const n = body[i + 1];

            // ${name} — braced reference (interior left for runtime parsing)
            if (n == '{') {
                var j = i + 2;
                while (j < body.len and body[j] != '}') : (j += 1) {}
                if (j < body.len) {
                    try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, i);
                    const interior = body[i + 2 .. j];
                    const part_span = Span{
                        .start = body_start + @as(u32, @intCast(i)),
                        .end = body_start + @as(u32, @intCast(j + 1)),
                    };
                    try parts.append(alloc, .{ .var_braced = .{
                        .body = try alloc.dupe(u8, interior),
                        .span = part_span,
                    } });
                    i = j + 1;
                    text_run_start = i;
                    continue;
                }
                // unterminated; emit a diagnostic and treat the `$` as text
                try emitBadShape(source, .nil, sink, "unterminated `${...}` in double-quoted string");
                try text_buf.append(alloc, '$');
                i += 1;
                continue;
            }

            // $(...) — command substitution. Find matching `)` honoring
            // nested parentheses inside the captured body.
            if (n == '(') {
                var depth: u32 = 1;
                var j = i + 2;
                while (j < body.len) {
                    const ch = body[j];
                    if (ch == '"') {
                        // Skip a nested string entirely so its parens are
                        // ignored by depth tracking. Honor backslash.
                        j += 1;
                        while (j < body.len and body[j] != '"') {
                            if (body[j] == '\\' and j + 1 < body.len) j += 1;
                            j += 1;
                        }
                        if (j < body.len) j += 1;
                        continue;
                    }
                    if (ch == '\'') {
                        j += 1;
                        while (j < body.len and body[j] != '\'') j += 1;
                        if (j < body.len) j += 1;
                        continue;
                    }
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    j += 1;
                }
                if (j < body.len and depth == 0) {
                    try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, i);

                    const inner_bytes = body[i + 2 .. j];
                    const inner_source = Source{ .name = source.name, .text = inner_bytes };
                    var p = parser.Parser.init(alloc, inner_bytes);
                    defer p.deinit();
                    const inner_sexp = p.parseProgram() catch {
                        try emitBadShape(source, .nil, sink, "parse error in `$(...)` inside double-quoted string");
                        try text_buf.append(alloc, '$');
                        i += 1;
                        continue;
                    };
                    const inner_shape = try convertShape(alloc, inner_source, inner_sexp, sink);
                    const body_ptr = try alloc.create(Shape);
                    body_ptr.* = inner_shape;

                    const part_span = Span{
                        .start = body_start + @as(u32, @intCast(i)),
                        .end = body_start + @as(u32, @intCast(j + 1)),
                    };
                    try parts.append(alloc, .{ .cmd_subst = .{
                        .body = body_ptr,
                        .span = part_span,
                    } });
                    i = j + 1;
                    text_run_start = i;
                    continue;
                }
                try emitBadShape(source, .nil, sink, "unterminated `$(...)` in double-quoted string");
                try text_buf.append(alloc, '$');
                i += 1;
                continue;
            }

            // $name — identifier-style reference
            if (isVarNameStart(n)) {
                try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, i);
                var j = i + 2;
                while (j < body.len and isVarNameCont(body[j])) : (j += 1) {}
                const name = body[i + 1 .. j];
                const part_span = Span{
                    .start = body_start + @as(u32, @intCast(i)),
                    .end = body_start + @as(u32, @intCast(j)),
                };
                try parts.append(alloc, .{ .variable = .{
                    .name = try alloc.dupe(u8, name),
                    .span = part_span,
                } });
                i = j;
                text_run_start = i;
                continue;
            }

            // $0..$9 / $? / $$ / $# / $@ / $! / $* — single-byte specials
            if (isSpecialVarChar(n)) {
                try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, i);
                const name = body[i + 1 .. i + 2];
                const part_span = Span{
                    .start = body_start + @as(u32, @intCast(i)),
                    .end = body_start + @as(u32, @intCast(i + 2)),
                };
                try parts.append(alloc, .{ .variable = .{
                    .name = try alloc.dupe(u8, name),
                    .span = part_span,
                } });
                i += 2;
                text_run_start = i;
                continue;
            }
        }

        // Plain byte (or lonely `$` at end of string).
        try text_buf.append(alloc, c);
        i += 1;
    }

    // Flush any trailing text run.
    try flushTextRun(alloc, &parts, &text_buf, body_start, text_run_start, body.len);

    // Empty `""` produces a single empty-text part so the resulting Word
    // is observably an empty argv element rather than a missing one.
    if (parts.items.len == 0) {
        try parts.append(alloc, .{ .text = .{
            .bytes = "",
            .flavor = .double_quoted,
            .cooked = true,
            .span = full_span,
        } });
    }

    return parts.toOwnedSlice(alloc);
}

fn flushTextRun(
    alloc: Allocator,
    parts: *std.ArrayListUnmanaged(WordPartShape),
    text_buf: *std.ArrayListUnmanaged(u8),
    body_start: u32,
    text_run_start: usize,
    body_offset_now: usize,
) !void {
    if (text_buf.items.len == 0) return;
    const cooked = try alloc.dupe(u8, text_buf.items);
    const part_span = Span{
        .start = body_start + @as(u32, @intCast(text_run_start)),
        .end = body_start + @as(u32, @intCast(body_offset_now)),
    };
    try parts.append(alloc, .{ .text = .{
        .bytes = cooked,
        .flavor = .double_quoted,
        .cooked = true,
        .span = part_span,
    } });
    text_buf.clearRetainingCapacity();
}

fn isVarNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isVarNameCont(c: u8) bool {
    return isVarNameStart(c) or (c >= '0' and c <= '9');
}

fn isSpecialVarChar(c: u8) bool {
    return switch (c) {
        '0'...'9', '?', '#', '@', '!', '*', '$' => true,
        else => false,
    };
}

fn convertVariableAtom(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    const tok_src = try expectSrc(items[1], source, sink);
    const span = Span{ .start = tok_src.pos, .end = tok_src.pos + tok_src.len };
    const raw = source.text[span.start..span.end];
    if (raw.len < 2 or raw[0] != '$') {
        try emitBadShape(source, items[0], sink, "variable must start with $");
        return error.InvalidShape;
    }
    const name = raw[1..];
    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .variable = .{ .name = name, .span = span } };
    return .{ .parts = parts, .span = span };
}

fn convertVarBracedAtom(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    const tok_src = try expectSrc(items[1], source, sink);
    const span = Span{ .start = tok_src.pos, .end = tok_src.pos + tok_src.len };
    const raw = source.text[span.start..span.end];
    if (raw.len < 3 or raw[0] != '$' or raw[1] != '{' or raw[raw.len - 1] != '}') {
        try emitBadShape(source, items[0], sink, "var_braced source must be `${...}`");
        return error.InvalidShape;
    }
    const body = raw[2 .. raw.len - 1];
    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .var_braced = .{ .body = body, .span = span } };
    return .{ .parts = parts, .span = span };
}

fn convertCmdSubstAtom(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    if (items.len != 2) {
        try emitBadShape(source, items[0], sink, "cmd_subst expects one body");
        return error.InvalidShape;
    }
    // The body is a sequence inside $( ... ).
    const body = try convertShape(alloc, source, items[1], sink);
    const body_span = body.span();

    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;

    // The full span covers the `$(...)` enclosing tokens. We don't have
    // a direct handle to the open `$(` token here; the body span is a
    // close-enough approximation for diagnostics.
    const span = body_span;

    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .cmd_subst = .{ .body = body_ptr, .span = span } };
    return .{ .parts = parts, .span = span };
}

fn convertListCaptureAtom(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    if (items.len != 2) {
        try emitBadShape(source, items[0], sink, "list_capture expects one body");
        return error.InvalidShape;
    }
    const body = try convertShape(alloc, source, items[1], sink);
    const body_span = body.span();
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;
    const span = body_span;
    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .list_capture = .{ .body = body_ptr, .span = span } };
    return .{ .parts = parts, .span = span };
}

fn convertProcSubAtom(
    alloc: Allocator,
    source: Source,
    items: []const parser.Sexp,
    dir: ProcSubstDir,
    sink: ?Sink,
) anyerror!WordShape {
    if (items.len != 2) {
        try emitBadShape(source, items[0], sink, "proc_subst expects one body");
        return error.InvalidShape;
    }
    const body = try convertShape(alloc, source, items[1], sink);
    const body_span = body.span();
    const body_ptr = try alloc.create(Shape);
    body_ptr.* = body;
    const span = body_span;
    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .proc_subst = .{ .dir = dir, .body = body_ptr, .span = span } };
    return .{ .parts = parts, .span = span };
}

// ---- redirects --------------------------------------------------------------

fn convertRedirect(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    tag: slash.Tag,
    payload: []const parser.Sexp,
    sink: ?Sink,
) anyerror!RedirectShape {
    const op: RedirectOp = switch (tag) {
        .redir_read => .read,
        .redir_read_fd => .read_fd,
        .redir_write => .write,
        .redir_write_fd => .write_fd,
        .redir_append => .append,
        .redir_both => .both,
        .redir_both_append => .both_append,
        .redir_dup_out => .dup_out,
        .redir_dup_in => .dup_in,
        .redir_heredoc => .heredoc,
        .redir_heredoc_lit => .heredoc_lit,
        else => {
            try emitBadShape(source, sexp, sink, "unexpected redirect tag");
            return error.InvalidShape;
        },
    };

    var fd_src: ?Span = null;
    var target: ?WordShape = null;
    var heredoc: ?HeredocBody = null;
    var start: u32 = std.math.maxInt(u32);
    var end: u32 = 0;

    switch (op) {
        .read, .write, .append, .both, .both_append => {
            if (payload.len != 1) {
                try emitBadShape(source, sexp, sink, "redirect missing target");
                return error.InvalidShape;
            }
            const t = try convertWordOrAtomToWord(alloc, source, payload[0], sink);
            target = t;
            start = t.span.start;
            end = t.span.end;
        },
        .read_fd, .write_fd => {
            if (payload.len != 2) {
                try emitBadShape(source, sexp, sink, "fd redirect missing target");
                return error.InvalidShape;
            }
            const fd = try expectSrcSpan(payload[0], source, sink);
            fd_src = fd;
            const t = try convertWordOrAtomToWord(alloc, source, payload[1], sink);
            target = t;
            start = fd.start;
            end = t.span.end;
        },
        .dup_out, .dup_in => {
            if (payload.len != 1) {
                try emitBadShape(source, sexp, sink, "dup redirect malformed");
                return error.InvalidShape;
            }
            const fd = try expectSrcSpan(payload[0], source, sink);
            fd_src = fd;
            start = fd.start;
            end = fd.end;
        },
        .heredoc, .heredoc_lit => {
            if (payload.len != 2) {
                try emitBadShape(source, sexp, sink, "heredoc redirect malformed");
                return error.InvalidShape;
            }
            const open_span = try expectSrcSpan(payload[0], source, sink);
            const body_span = try expectSrcSpan(payload[1], source, sink);
            heredoc = .{
                .raw = source.text[body_span.start..body_span.end],
                .dedent_col = computeHeredocDedentCol(source.text, body_span.end),
                .interpolating = (op == .heredoc),
                .span = body_span,
            };
            start = open_span.start;
            end = body_span.end;
        },
    }

    return .{
        .op = op,
        .fd_src = fd_src,
        .target = target,
        .heredoc = heredoc,
        .span = .{ .start = start, .end = end },
    };
}

/// Walk past the body to find the closing-tag line and return the
/// 1-indexed column at which the tag's first non-whitespace byte sits.
/// The body span ends right before the closing line, so `body_end` is
/// the start of the closing tag's leading whitespace.
fn computeHeredocDedentCol(source: []const u8, body_end: u32) u32 {
    var col: u32 = 1;
    var i = body_end;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {
        col += 1;
    }
    return col;
}

// =============================================================================
// Sexp helpers
// =============================================================================

fn isWordAtomTag(tag: slash.Tag) bool {
    return switch (tag) {
        .word, .@"var", .var_braced, .cmd_subst, .list_capture, .proc_sub_in, .proc_sub_out => true,
        else => false,
    };
}

fn isRedirectTag(tag: slash.Tag) bool {
    return switch (tag) {
        .redir_read,
        .redir_read_fd,
        .redir_write,
        .redir_write_fd,
        .redir_append,
        .redir_both,
        .redir_both_append,
        .redir_dup_out,
        .redir_dup_in,
        .redir_heredoc,
        .redir_heredoc_lit,
        => true,
        else => false,
    };
}

fn expectList(sexp: parser.Sexp, source: Source, sink: ?Sink) ![]const parser.Sexp {
    return switch (sexp) {
        .list => |items| if (items.len > 0) items else {
            try emitBadShape(source, sexp, sink, "empty list");
            return error.InvalidShape;
        },
        else => {
            try emitBadShape(source, sexp, sink, "expected list");
            return error.InvalidShape;
        },
    };
}

fn expectTag(sexp: parser.Sexp, source: Source, sink: ?Sink) !slash.Tag {
    return switch (sexp) {
        .tag => |t| t,
        else => {
            try emitBadShape(source, sexp, sink, "expected tag");
            return error.InvalidShape;
        },
    };
}

fn expectHeadTag(items: []const parser.Sexp, expected: slash.Tag, source: Source, sink: ?Sink) !void {
    const got = try expectTag(items[0], source, sink);
    if (got != expected) {
        try emitBadShape(source, items[0], sink, "unexpected head tag");
        return error.InvalidShape;
    }
}

const SrcRef = struct { pos: u32, len: u16, id: u16 };

fn expectSrc(sexp: parser.Sexp, source: Source, sink: ?Sink) !SrcRef {
    return switch (sexp) {
        .src => |s| .{ .pos = s.pos, .len = s.len, .id = s.id },
        else => {
            try emitBadShape(source, sexp, sink, "expected source token");
            return error.InvalidShape;
        },
    };
}

fn expectSrcSpan(sexp: parser.Sexp, source: Source, sink: ?Sink) !Span {
    return switch (sexp) {
        .src => |s| .{ .start = s.pos, .end = s.pos + s.len },
        else => {
            try emitBadShape(source, sexp, sink, "expected source token");
            return error.InvalidShape;
        },
    };
}

fn emitBadShape(source: Source, _: parser.Sexp, sink: ?Sink, message: []const u8) !void {
    try diag.emit(sink, diag.make(
        .shape,
        .@"error",
        "SH0100",
        message,
        source,
        null,
    ));
}

fn spanOfList(items: []const parser.Sexp) Span {
    var start: u32 = std.math.maxInt(u32);
    var end: u32 = 0;
    for (items) |it| {
        const s_opt: ?Span = switch (it) {
            .src => |s| .{ .start = s.pos, .end = s.pos + s.len },
            .list => |child_items| if (child_items.len > 0) spanOfList(child_items) else null,
            else => null,
        };
        if (s_opt) |s| {
            if (s.start < start) start = s.start;
            if (s.end > end) end = s.end;
        }
    }
    if (start == std.math.maxInt(u32)) start = 0;
    return .{ .start = start, .end = end };
}

// =============================================================================
// Dump (deterministic)
// =============================================================================

const Writer = std.Io.Writer;
const WriteError = Writer.Error;

pub const DumpOptions = struct {
    spans: bool = false,
};

pub fn dump(parsed: Parsed, w: *Writer, opts: DumpOptions) WriteError!void {
    try dumpShape(parsed.source, parsed.root, 0, w, opts);
}

fn dumpShape(source: Source, s: Shape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    switch (s) {
        .word => |ws| try dumpWord(ws, w, opts),
        .command => |c| try dumpCommand(source, c, depth, w, opts),
        .pipeline => |p| try dumpPipeline(source, p, depth, w, opts),
        .sequence => |q| try dumpSequence(source, q, depth, w, opts),
        .subshell => |sb| try dumpSubshell(source, sb, depth, w, opts),
        .block => |b| try dumpBlock(source, b, depth, w, opts),
        .detached => |d| try dumpDetached(source, d, depth, w, opts),
        .assigns => |a| try dumpAssigns(source, a, depth, w, opts),
        .conditional => |c| try dumpConditional(source, c, depth, w, opts),
        .@"while" => |x| try dumpWhile(source, x, depth, w, opts),
        .@"for" => |x| try dumpFor(source, x, depth, w, opts),
        .@"match" => |x| try dumpMatch(source, x, depth, w, opts),
        .cmd_def => |d| try dumpCmdDef(source, d, depth, w, opts),
        .str_def => |d| try dumpStrDef(d, depth, w, opts),
    }
}

fn dumpWord(ws: WordShape, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("word");
    try maybeSpan(ws.span, w, opts);
    try w.writeByte('\n');
    // Note: parts dumped inline — but typical word has exactly one part.
    for (ws.parts) |part| try dumpPartInline(part, w);
}

fn dumpPartInline(part: WordPartShape, w: *Writer) WriteError!void {
    switch (part) {
        .text => |t| try w.print("  text {s} {s}\n", .{ @tagName(t.flavor), t.bytes }),
        .variable => |v| try w.print("  var {s}\n", .{v.name}),
        .var_braced => |v| try w.print("  var_braced {s}\n", .{v.body}),
        .cmd_subst => try w.writeAll("  cmd_subst <body>\n"),
        .list_capture => try w.writeAll("  list_capture <body>\n"),
        .proc_subst => |ps| try w.print("  proc_subst {s} <body>\n", .{@tagName(ps.dir)}),
        .glob => |g| try w.print("  glob {s}\n", .{g.pattern}),
    }
}

fn dumpCommand(source: Source, c: CommandShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("command");
    try maybeSpan(c.span, w, opts);
    try w.writeByte('\n');
    for (c.env) |bind| {
        try indent(w, depth + 1);
        try w.print("env {s}\n", .{bind.name});
        switch (bind.value) {
            .scalar => |sc| {
                try indent(w, depth + 2);
                try w.writeAll("scalar\n");
                try dumpWordParts(sc, depth + 3, w);
            },
            .list => |ws| {
                try indent(w, depth + 2);
                try w.writeAll("list\n");
                for (ws) |item| try dumpWordParts(item, depth + 3, w);
            },
        }
    }
    try indent(w, depth + 1);
    try w.writeAll("exe\n");
    try dumpWordParts(c.exe, depth + 2, w);
    for (c.args) |a| {
        try indent(w, depth + 1);
        try w.writeAll("arg\n");
        try dumpWordParts(a, depth + 2, w);
    }
    for (c.redirects) |r| try dumpRedirect(source, r, depth + 1, w, opts);
}

fn dumpWordParts(ws: WordShape, depth: u32, w: *Writer) WriteError!void {
    for (ws.parts) |part| {
        try indent(w, depth);
        switch (part) {
            .text => |t| try w.print("text {s} {s}\n", .{ @tagName(t.flavor), t.bytes }),
            .variable => |v| try w.print("var {s}\n", .{v.name}),
            .var_braced => |v| try w.print("var_braced {s}\n", .{v.body}),
            .cmd_subst => try w.writeAll("cmd_subst\n"),
            .list_capture => try w.writeAll("list_capture\n"),
            .proc_subst => |ps| try w.print("proc_subst {s}\n", .{@tagName(ps.dir)}),
            .glob => |g| try w.print("glob {s}\n", .{g.pattern}),
        }
    }
}

fn dumpPipeline(source: Source, p: PipelineShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("pipeline");
    try maybeSpan(p.span, w, opts);
    try w.writeByte('\n');
    for (p.stages) |st| try dumpShape(source, st, depth + 1, w, opts);
}

fn dumpSequence(source: Source, q: SequenceShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("sequence");
    try maybeSpan(q.span, w, opts);
    try w.writeByte('\n');
    for (q.items) |it| {
        try indent(w, depth + 1);
        if (it.next_op) |op| {
            try w.print("item next={s}\n", .{@tagName(op)});
        } else {
            try w.writeAll("item\n");
        }
        try dumpShape(source, it.program, depth + 2, w, opts);
    }
}

fn dumpSubshell(source: Source, s: SubshellShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("subshell");
    try maybeSpan(s.span, w, opts);
    try w.writeByte('\n');
    try dumpShape(source, s.body.*, depth + 1, w, opts);
    for (s.redirects) |r| try dumpRedirect(source, r, depth + 1, w, opts);
}

fn dumpBlock(source: Source, b: BlockShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("block");
    try maybeSpan(b.span, w, opts);
    try w.writeByte('\n');
    try dumpShape(source, b.body.*, depth + 1, w, opts);
    for (b.redirects) |r| try dumpRedirect(source, r, depth + 1, w, opts);
}

fn dumpDetached(source: Source, d: DetachedShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("detached");
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try dumpShape(source, d.body.*, depth + 1, w, opts);
}

fn dumpAssigns(source: Source, a: AssignsShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    _ = source;
    try w.writeAll("assigns");
    try maybeSpan(a.span, w, opts);
    try w.writeByte('\n');
    for (a.binds) |bind| {
        try indent(w, depth + 1);
        try w.print("bind {s}\n", .{bind.name});
        switch (bind.value) {
            .scalar => |sc| {
                try indent(w, depth + 2);
                try w.writeAll("scalar\n");
                try dumpWordParts(sc, depth + 3, w);
            },
            .list => |ws| {
                try indent(w, depth + 2);
                try w.writeAll("list\n");
                for (ws) |it| try dumpWordParts(it, depth + 3, w);
            },
        }
    }
}

fn dumpConditional(source: Source, c: ConditionalShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("conditional");
    try maybeSpan(c.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("cond\n");
    try dumpShape(source, c.cond.*, depth + 2, w, opts);
    try indent(w, depth + 1);
    try w.writeAll("then\n");
    try dumpShape(source, c.then_body.*, depth + 2, w, opts);
    if (c.else_body) |eb| {
        try indent(w, depth + 1);
        try w.writeAll("else\n");
        try dumpShape(source, eb.*, depth + 2, w, opts);
    }
}

fn dumpWhile(source: Source, x: WhileShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("while");
    try maybeSpan(x.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("cond\n");
    try dumpShape(source, x.cond.*, depth + 2, w, opts);
    try indent(w, depth + 1);
    try w.writeAll("body\n");
    try dumpShape(source, x.body.*, depth + 2, w, opts);
}

fn dumpFor(source: Source, x: ForShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.print("for {s}", .{x.binding});
    try maybeSpan(x.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("items\n");
    for (x.items) |it| try dumpWordParts(it, depth + 2, w);
    try indent(w, depth + 1);
    try w.writeAll("body\n");
    try dumpShape(source, x.body.*, depth + 2, w, opts);
}

fn dumpMatch(source: Source, m: MatchShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("match");
    try maybeSpan(m.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("subject\n");
    try dumpWordParts(m.subject, depth + 2, w);
    for (m.arms) |arm| {
        try indent(w, depth + 1);
        try w.writeAll("arm\n");
        try indent(w, depth + 2);
        try w.writeAll("patterns\n");
        for (arm.patterns) |p| try dumpWordParts(p, depth + 3, w);
        try indent(w, depth + 2);
        try w.writeAll("body\n");
        try dumpShape(source, arm.body.*, depth + 3, w, opts);
    }
}

fn dumpCmdDef(source: Source, d: CmdDefShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.print("cmd_def {s}", .{d.name});
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("body\n");
    try dumpShape(source, d.body.*, depth + 2, w, opts);
}

fn dumpStrDef(d: StrDefShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.print("str_def {s}", .{d.name});
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.print("body {d} bytes: {s}\n", .{ d.body.len, d.body });
}

fn dumpRedirect(source: Source, r: RedirectShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    try w.print("redir {s}", .{@tagName(r.op)});
    if (r.fd_src) |s| {
        const bytes = source.text[s.start..s.end];
        try w.print(" fd={s}", .{bytes});
    }
    if (r.target) |t| {
        // Print the first part for compact display.
        const part = t.parts[0];
        switch (part) {
            .text => |tx| try w.print(" target={s} {s}", .{ @tagName(tx.flavor), tx.bytes }),
            .variable => |v| try w.print(" target=var {s}", .{v.name}),
            else => try w.writeAll(" target=<word>"),
        }
    }
    try maybeSpan(r.span, w, opts);
    try w.writeByte('\n');
}

fn indent(w: *Writer, depth: u32) WriteError!void {
    var i: u32 = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

fn maybeSpan(s: Span, w: *Writer, opts: DumpOptions) WriteError!void {
    if (opts.spans) try w.print(" [{d}..{d})", .{ s.start, s.end });
}
