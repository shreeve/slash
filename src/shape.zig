//! Slash — Shape layer.
//!
//! `Shape` is the parsed structure: semantic nodes with source spans,
//! source-faithful bytes, and trivia side-tabled. It is NOT executable.
//!
//! This module provides:
//!   - the full Shape type hierarchy (Phase 1 variants only)
//!   - `parse(source, alloc, sink) !Parsed` — end-to-end: source → Shape
//!   - `dump(root, writer)` — deterministic tree printer for golden tests
//!
//! See PLAN.md §3.1, §6.1–§6.2, §7 Rule 30 (no re-expansion), and §17.11
//! (snapshot determinism).
//!
//! Design notes (from the round with GPT-5.4 for Commit 3):
//!
//!   - Shape is source-faithful: `WordShape.TextPart.bytes` is the raw source
//!     slice, INCLUDING quote delimiters when the token was quoted. Decoding
//!     (strip quotes, resolve escapes) happens at Word lowering, not here.
//!   - `Flavor` replaces a `quoted: bool` so decoding rules (single vs double)
//!     stay explicit at the right layer.
//!   - Sequence uses **connector-to-next** encoding: each `SequenceItem`
//!     carries `next_op`, aligning with the grammar's tail accumulator flow.
//!     The grammar's retroactive `seq_bg` (wraps the PRECEDING item as
//!     detached) is resolved during Sexp → Shape conversion, so callers
//!     never see `seq_bg` at the Shape layer.
//!   - Conversion is strict: any malformed Sexp (grammar regression, lang
//!     module drift) fails closed with an error + diagnostic.
//!   - Spans are half-open `[start, end)`. Compounds are the hull of their
//!     non-nil children. Trailing nil tails do not contribute to span.

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
    bytes: []const u8, // raw source slice — INCLUDES outer quotes if quoted
    flavor: Flavor,
    span: Span,
};

/// Phase 1 only emits `.text`. Future phases add variable, command_subst,
/// process_subst_in, process_subst_out, and glob.
pub const WordPartShape = union(enum) {
    text: TextPart,
};

pub const WordShape = struct {
    parts: []const WordPartShape,
    span: Span,
};

// =============================================================================
// Redirects
// =============================================================================

pub const RedirectOp = enum {
    read, // <  target
    read_fd, // N< target (fd prefix stored in fd_src)
    write, // >  target
    write_fd, // N> target
    append, // >> target
    both, // &>  target   (stdout + stderr, truncate)
    both_append, // &>> target   (stdout + stderr, append)
    dup_out, // N>&M  (no target; fd_src carries the whole "N>&M" bytes)
    dup_in, // N<&M
};

pub const RedirectShape = struct {
    op: RedirectOp,
    /// Present for `read_fd`, `write_fd`, `dup_out`, `dup_in`. Points at the
    /// fd-prefix token's span so callers can slice the original source text
    /// to decode the numeric fd. See §22.2 for rules on ill-formed fds.
    fd_src: ?Span,
    /// Present for every op except `dup_out` / `dup_in`.
    target: ?WordShape,
    span: Span,
};

// =============================================================================
// Compound shapes
// =============================================================================

pub const CommandShape = struct {
    exe: WordShape,
    args: []const WordShape,
    redirects: []const RedirectShape,
    span: Span,
};

pub const PipelineShape = struct {
    stages: []const Shape, // Command or Subshell
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

pub const DetachedShape = struct {
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
    detached: DetachedShape,

    pub fn span(self: Shape) Span {
        return switch (self) {
            .word => |w| w.span,
            .command => |c| c.span,
            .pipeline => |p| p.span,
            .sequence => |s| s.span,
            .subshell => |s| s.span,
            .detached => |d| d.span,
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
// Parse entry point
// =============================================================================

/// `parse` returns `anyerror` because its diagnostic sink is type-erased —
/// sinks for REPL, file output, or test accumulators all have different
/// error sets. Narrow error typing can be revisited once we see what
/// concrete sinks need to propagate.
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

    // The parser's Sexp is arena-backed; convert into our caller-provided
    // allocator so the Shape outlives the parser.
    const root = try convertShape(alloc, source, sexp, sink);
    return Parsed{
        .source = source,
        .root = root,
        .trivia = &.{},
    };
}

// =============================================================================
// Sexp → Shape conversion (strict)
// =============================================================================

/// Dispatch on the head tag of a list-shaped Sexp.
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
        else => {
            try emitBadShape(source, sexp, sink, "unexpected head tag at top level");
            return error.InvalidShape;
        },
    };
}

/// The grammar root is always `(sequence ITEM TAIL...)`. `items` is the
/// children after the head tag. The trailing `(seq_always)` nil and all
/// `seq_bg` wrapping are resolved here so that every `SequenceItemShape`
/// is a concrete program with a connector-to-next op.
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

    // Accumulator pass: walk `first + tails`, producing a flat list with
    // next_op connectors. `current` carries the item we haven't committed yet.
    var list = std.ArrayListUnmanaged(SequenceItemShape).empty;
    defer list.deinit(alloc);

    var current = try convertStage(alloc, source, items[0], sink);

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const tail_items = try expectList(items[i], source, sink);
        const tail_head = try expectTag(tail_items[0], source, sink);
        const payload = if (tail_items.len >= 2) tail_items[1] else parser.Sexp.nil;

        switch (tail_head) {
            .seq_always, .seq_and, .seq_or => {
                // Trailing `(seq_always)` / `(seq_and)` / `(seq_or)` with
                // nil payload is pure grammar noise (a trailing `;`, `\n`,
                // `&&`, or `||` with nothing after it). It commits `current`
                // with `next_op = null` — the connector is a lie since
                // there's no next item.
                if (payload == .nil) {
                    try list.append(alloc, .{ .program = current, .next_op = null });
                    return finishSequence(alloc, &list, full_span);
                }
                const op: SequenceOp = switch (tail_head) {
                    .seq_always => .always,
                    .seq_and => .and_then,
                    .seq_or => .or_else,
                    else => unreachable,
                };
                try list.append(alloc, .{ .program = current, .next_op = op });
                current = try convertStage(alloc, source, payload, sink);
            },
            .seq_bg => {
                // Retroactive wrap: the CURRENT item becomes `Detached(current)`.
                const body_ptr = try alloc.create(Shape);
                body_ptr.* = current;
                const detached = Shape{ .detached = .{
                    .body = body_ptr,
                    .span = current.span(),
                } };
                if (payload == .nil) {
                    // `foo &` at end of sequence: one detached item, no successor.
                    try list.append(alloc, .{ .program = detached, .next_op = null });
                    return finishSequence(alloc, &list, full_span);
                }
                // `foo & bar`: detached item, then bar with default (always) op.
                try list.append(alloc, .{ .program = detached, .next_op = .always });
                current = try convertStage(alloc, source, payload, sink);
            },
            else => {
                try emitBadShape(source, items[i], sink, "unexpected sequence tail tag");
                return error.InvalidShape;
            },
        }
    }

    // Loop fell through: `current` has no tail after it, so it's the final
    // item with next_op = null.
    try list.append(alloc, .{ .program = current, .next_op = null });
    return finishSequence(alloc, &list, full_span);
}

fn finishSequence(
    alloc: Allocator,
    list: *std.ArrayListUnmanaged(SequenceItemShape),
    full_span: Span,
) anyerror!SequenceShape {
    return .{
        .items = try list.toOwnedSlice(alloc),
        .span = full_span,
    };
}

/// A sequence item is a pipeline stage, which in this grammar lowers to
/// `command`, `pipeline`, or `subshell`. A pipeline is not a valid Shape
/// node inside a sequence item slot by itself — but our grammar actually
/// emits `(pipeline ...)` directly in that slot, so we accept it.
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
        else => {
            try emitBadShape(source, sexp, sink, "expected command, pipeline, or subshell");
            return error.InvalidShape;
        },
    };
}

fn convertCommand(
    alloc: Allocator,
    source: Source,
    children: []const parser.Sexp,
    sink: ?Sink,
) anyerror!CommandShape {
    if (children.len == 0) {
        try emitBadShape(source, .nil, sink, "command requires at least an exe");
        return error.InvalidShape;
    }
    const exe = try convertWord(alloc, source, children[0], sink);
    var args_list = std.ArrayListUnmanaged(WordShape).empty;
    defer args_list.deinit(alloc);
    var redirs_list = std.ArrayListUnmanaged(RedirectShape).empty;
    defer redirs_list.deinit(alloc);

    for (children[1..]) |child| {
        const list_items = try expectList(child, source, sink);
        const tag = try expectTag(list_items[0], source, sink);
        if (tag == .word) {
            try args_list.append(alloc, try convertWord(alloc, source, child, sink));
        } else {
            try redirs_list.append(alloc, try convertRedirect(alloc, source, child, tag, list_items[1..], sink));
        }
    }

    const span_end = blk: {
        if (redirs_list.items.len > 0) break :blk redirs_list.items[redirs_list.items.len - 1].span.end;
        if (args_list.items.len > 0) break :blk args_list.items[args_list.items.len - 1].span.end;
        break :blk exe.span.end;
    };

    return .{
        .exe = exe,
        .args = try args_list.toOwnedSlice(alloc),
        .redirects = try redirs_list.toOwnedSlice(alloc),
        .span = .{ .start = exe.span.start, .end = span_end },
    };
}

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
        // The grammar emits `(redirects REDIR+)` for the optional trailing
        // redirect list; unpack into our flat array.
        const redir_items = try expectList(children[1], source, sink);
        _ = try expectHeadTag(redir_items, .redirects, source, sink);
        for (redir_items[1..]) |r| {
            const r_items = try expectList(r, source, sink);
            const tag = try expectTag(r_items[0], source, sink);
            try redirs.append(alloc, try convertRedirect(alloc, source, r, tag, r_items[1..], sink));
        }
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
            // payload = (word SRC)
            if (payload.len != 1) {
                try emitBadShape(source, sexp, sink, "redirect missing target");
                return error.InvalidShape;
            }
            const t = try convertWord(alloc, source, payload[0], sink);
            target = t;
            start = t.span.start;
            end = t.span.end;
        },
        .read_fd, .write_fd => {
            // payload = SRC (fd-prefix token), (word SRC) (target)
            if (payload.len != 2) {
                try emitBadShape(source, sexp, sink, "fd redirect missing target");
                return error.InvalidShape;
            }
            const fd = try expectSrcSpan(payload[0], source, sink);
            fd_src = fd;
            const t = try convertWord(alloc, source, payload[1], sink);
            target = t;
            start = fd.start;
            end = t.span.end;
        },
        .dup_out, .dup_in => {
            // payload = SRC (fd-prefix token)
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

fn convertWord(
    alloc: Allocator,
    source: Source,
    sexp: parser.Sexp,
    sink: ?Sink,
) anyerror!WordShape {
    const items = try expectList(sexp, source, sink);
    _ = try expectHeadTag(items, .word, source, sink);
    if (items.len != 2) {
        try emitBadShape(source, sexp, sink, "word must have exactly one source child");
        return error.InvalidShape;
    }
    const tok_src = switch (items[1]) {
        .src => |s| s,
        else => {
            try emitBadShape(source, sexp, sink, "word child must be a source token");
            return error.InvalidShape;
        },
    };
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

// =============================================================================
// Sexp helpers
// =============================================================================

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

/// Best-effort span for an entire list — used when we can't point at a
/// single child (e.g. for the top-level sequence).
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
// Deterministic dumper
// =============================================================================

pub const DumpOptions = struct {
    spans: bool = false, // default: omit spans per PLAN §17.11
};

const Writer = std.Io.Writer;
const WriteError = Writer.Error;

pub fn dump(parsed: Parsed, w: *Writer, opts: DumpOptions) WriteError!void {
    try dumpShape(parsed.source, parsed.root, 0, w, opts);
}

fn dumpShape(source: Source, s: Shape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    switch (s) {
        .word => |ws| try dumpWord(source, ws, w, opts),
        .command => |c| try dumpCommand(source, c, depth, w, opts),
        .pipeline => |p| try dumpPipeline(source, p, depth, w, opts),
        .sequence => |q| try dumpSequence(source, q, depth, w, opts),
        .subshell => |sb| try dumpSubshell(source, sb, depth, w, opts),
        .detached => |d| try dumpDetached(source, d, depth, w, opts),
    }
}

fn dumpWord(source: Source, ws: WordShape, w: *Writer, opts: DumpOptions) WriteError!void {
    _ = source;
    const part = ws.parts[0].text;
    try w.print("word {s} {s}", .{ @tagName(part.flavor), part.bytes });
    try maybeSpan(ws.span, w, opts);
    try w.writeByte('\n');
}

fn dumpCommand(source: Source, c: CommandShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("command");
    try maybeSpan(c.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("exe ");
    const part = c.exe.parts[0].text;
    try w.print("{s} {s}\n", .{ @tagName(part.flavor), part.bytes });
    for (c.args) |a| {
        try indent(w, depth + 1);
        try w.writeAll("arg ");
        const ap = a.parts[0].text;
        try w.print("{s} {s}\n", .{ @tagName(ap.flavor), ap.bytes });
    }
    for (c.redirects) |r| try dumpRedirect(source, r, depth + 1, w, opts);
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

fn dumpDetached(source: Source, d: DetachedShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("detached");
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try dumpShape(source, d.body.*, depth + 1, w, opts);
}

fn dumpRedirect(source: Source, r: RedirectShape, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    try w.print("redir {s}", .{@tagName(r.op)});
    if (r.fd_src) |s| {
        const bytes = source.text[s.start..s.end];
        try w.print(" fd={s}", .{bytes});
    }
    if (r.target) |t| {
        const part = t.parts[0].text;
        try w.print(" target={s} {s}", .{ @tagName(part.flavor), part.bytes });
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

// =============================================================================
// Tests
// =============================================================================

fn dumpToString(alloc: Allocator, parsed: Parsed) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try dump(parsed, &out.writer, .{});
    return alloc.dupe(u8, out.written());
}

test "parse and dump a simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = Source{ .name = "<test>", .text = "echo hello" };
    const parsed = try parse(source, alloc, null);
    const got = try dumpToString(alloc, parsed);

    const expected =
        "sequence\n" ++
        "  item\n" ++
        "    command\n" ++
        "      exe bare echo\n" ++
        "      arg bare hello\n";
    try std.testing.expectEqualStrings(expected, got);
}

test "parse pipeline with redirects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = Source{ .name = "<test>", .text = "grep foo < in > out" };
    const parsed = try parse(source, alloc, null);
    const got = try dumpToString(alloc, parsed);

    try std.testing.expect(std.mem.indexOf(u8, got, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "redir read target=bare in") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "redir write target=bare out") != null);
}

test "foo & bar wraps preceding item as detached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = Source{ .name = "<test>", .text = "sleep 10 & echo done" };
    const parsed = try parse(source, alloc, null);
    const got = try dumpToString(alloc, parsed);

    try std.testing.expect(std.mem.indexOf(u8, got, "item next=always") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "detached") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "arg bare done") != null);
}
