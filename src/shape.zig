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
    /// Raw source slice, INCLUDING outer quotes if quoted.
    /// Quote stripping and escape decoding happen at Word lowering.
    bytes: []const u8,
    flavor: Flavor,
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
};

pub const RedirectShape = struct {
    op: RedirectOp,
    /// fd-prefix span for `_fd` and `dup_*` ops.
    fd_src: ?Span,
    /// File target (`null` for dup ops).
    target: ?WordShape,
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

    const sexp = p.parseProgram() catch |err| {
        try diag.emit(sink, diag.make(
            .shape,
            .@"error",
            "SH0001",
            @errorName(err),
            source,
            null,
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
    const parts = try alloc.alloc(WordPartShape, 1);
    parts[0] = .{ .text = .{ .bytes = bytes, .flavor = flavor, .span = span } };
    return .{ .parts = parts, .span = span };
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
        else => {
            try emitBadShape(source, sexp, sink, "unexpected redirect tag");
            return error.InvalidShape;
        },
    };

    var fd_src: ?Span = null;
    var target: ?WordShape = null;
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
    }

    return .{
        .op = op,
        .fd_src = fd_src,
        .target = target,
        .span = .{ .start = start, .end = end },
    };
}

// =============================================================================
// Sexp helpers
// =============================================================================

fn isWordAtomTag(tag: slash.Tag) bool {
    return switch (tag) {
        .word, .@"var", .var_braced, .cmd_subst => true,
        else => false,
    };
}

fn isRedirectTag(tag: slash.Tag) bool {
    return switch (tag) {
        .redir_read, .redir_read_fd, .redir_write, .redir_write_fd, .redir_append, .redir_both, .redir_both_append, .redir_dup_out, .redir_dup_in => true,
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
