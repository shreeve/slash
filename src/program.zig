//! Slash — Program layer.
//!
//! A `Program` is the lowered executable semantics of a `Shape`. It is
//! IMMUTABLE after lowering (see PLAN.md §7 Rule 2) and contains no
//! syntactic sugar, no unresolved redirect syntax, and no ambiguous
//! execution structure (§7 Rule 31).
//!
//! Phase 1 variants only: `command`, `pipeline`, `sequence`, `subshell`,
//! `detached`. Control forms (`If`, `While`, `For`, `Define`) and
//! behavioral wrappers (`Retry`, `Timeout`, `Within`, `WithEnv`, `Parallel`)
//! are kernel forms that exist in the type system per PLAN §7 Rule 28 but
//! no surface syntax emits them yet.
//!
//! Sequences use connector-to-next encoding (PLAN §6.5) — each `SequenceItem`
//! carries `next_op` rather than `op_before`. This matches the grammar's
//! tail accumulator flow and keeps `seq_bg` lowering clean.

const std = @import("std");
const shape_mod = @import("shape.zig");
const word_mod = @import("word.zig");
const diag = @import("diagnostics.zig");

pub const Allocator = std.mem.Allocator;
pub const Span = diag.Span;
pub const Source = diag.Source;
pub const Sink = diag.Sink;
pub const Word = word_mod.Word;

// =============================================================================
// Redirect — semantic
// =============================================================================

pub const RedirectOp = enum {
    read,
    write,
    append,
    both_write,
    both_append,
    dup,
};

pub const Redirect = struct {
    op: RedirectOp,
    /// Resolved source fd for this redirect (what end of the child's fd
    /// table gets pointed somewhere else). `null` means "the default for
    /// this op": 0 for read, 1 for write/append, both 1+2 for `both*`.
    from_fd: ?u8,
    /// For dup forms, the destination fd that the source fd is dup'd to.
    /// For file-target forms, this is `null`; `target` carries the path.
    to_fd: ?u8,
    /// File target for `read`, `write`, `append`, `both_write`, `both_append`.
    /// `null` for `dup`.
    target: ?Word,
    span: Span,
};

// =============================================================================
// Command / Pipeline / Sequence
// =============================================================================

pub const EnvBind = struct {
    name: []const u8,
    value: Word,
};

pub const Command = struct {
    exe: Word,
    args: []const Word,
    env: []const EnvBind = &.{},
    cwd: ?Word = null,
    redirects: []const Redirect,
    span: Span,
};

pub const Pipeline = struct {
    stages: []const *const Program,
    /// PLAN §7 Rule 11 default. No surface syntax toggles this in Phase 1.
    pipefail: bool = true,
    span: Span,
};

pub const SequenceOp = enum { always, and_then, or_else };

pub const SequenceItem = struct {
    program: *const Program,
    /// `null` on the final item; all earlier items have a connector to the
    /// next one. Matches the grammar's tail accumulator flow.
    next_op: ?SequenceOp,
};

pub const Sequence = struct {
    items: []const SequenceItem,
    span: Span,
};

// =============================================================================
// Program union
// =============================================================================

pub const Program = union(enum) {
    command: Command,
    pipeline: Pipeline,
    sequence: Sequence,
    subshell: struct {
        body: *const Program,
        redirects: []const Redirect,
        span: Span,
    },
    detached: struct {
        body: *const Program,
        span: Span,
    },

    pub fn span(self: Program) Span {
        return switch (self) {
            .command => |c| c.span,
            .pipeline => |p| p.span,
            .sequence => |s| s.span,
            .subshell => |s| s.span,
            .detached => |d| d.span,
        };
    }
};

// =============================================================================
// Lowering context
// =============================================================================

pub const Features = struct {
    process_subst: bool = false,
    heredoc: bool = false,
    definitions: bool = false,
    conditionals: bool = false,
    loops: bool = false,
};

pub const LowerContext = struct {
    alloc: Allocator,
    source: Source,
    features: Features = .{},
};

// =============================================================================
// Lower
// =============================================================================

pub fn lower(shape: shape_mod.Shape, ctx: *const LowerContext, sink: ?Sink) !*const Program {
    return lowerShape(shape, ctx, sink);
}

fn lowerShape(shape: shape_mod.Shape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    return switch (shape) {
        .sequence => |s| try lowerSequence(s, ctx, sink),
        .pipeline => |p| try lowerPipeline(p, ctx, sink),
        .command => |c| try lowerCommand(c, ctx, sink),
        .subshell => |s| try lowerSubshell(s, ctx, sink),
        .detached => |d| try lowerDetached(d, ctx, sink),
        .word => {
            try diag.emit(sink, diag.make(
                .lower,
                .@"error",
                "LW0001",
                "a word cannot appear as a Program in Phase 1",
                ctx.source,
                shape.span(),
            ));
            return error.InvalidShape;
        },
    };
}

fn lowerSequence(s: shape_mod.SequenceShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    var items = try ctx.alloc.alloc(SequenceItem, s.items.len);
    for (s.items, 0..) |item, i| {
        const prog = try lowerShape(item.program, ctx, sink);
        items[i] = .{
            .program = prog,
            .next_op = if (item.next_op) |op| mapSequenceOp(op) else null,
        };
    }
    return put(ctx.alloc, .{ .sequence = .{ .items = items, .span = s.span } });
}

fn mapSequenceOp(op: shape_mod.SequenceOp) SequenceOp {
    return switch (op) {
        .always => .always,
        .and_then => .and_then,
        .or_else => .or_else,
    };
}

fn lowerPipeline(p: shape_mod.PipelineShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    var stages = try ctx.alloc.alloc(*const Program, p.stages.len);
    for (p.stages, 0..) |st, i| stages[i] = try lowerShape(st, ctx, sink);
    return put(ctx.alloc, .{ .pipeline = .{ .stages = stages, .pipefail = true, .span = p.span } });
}

fn lowerCommand(c: shape_mod.CommandShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    _ = sink;
    const exe = try word_mod.lowerWord(c.exe, ctx.alloc);
    var args = try ctx.alloc.alloc(Word, c.args.len);
    for (c.args, 0..) |a, i| args[i] = try word_mod.lowerWord(a, ctx.alloc);
    var reds = try ctx.alloc.alloc(Redirect, c.redirects.len);
    for (c.redirects, 0..) |r, i| reds[i] = try lowerRedirect(r, ctx);
    return put(ctx.alloc, .{ .command = .{
        .exe = exe,
        .args = args,
        .env = &.{},
        .cwd = null,
        .redirects = reds,
        .span = c.span,
    } });
}

fn lowerSubshell(s: shape_mod.SubshellShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(s.body.*, ctx, sink);
    var reds = try ctx.alloc.alloc(Redirect, s.redirects.len);
    for (s.redirects, 0..) |r, i| reds[i] = try lowerRedirect(r, ctx);
    return put(ctx.alloc, .{ .subshell = .{
        .body = body,
        .redirects = reds,
        .span = s.span,
    } });
}

fn lowerDetached(d: shape_mod.DetachedShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(d.body.*, ctx, sink);
    return put(ctx.alloc, .{ .detached = .{ .body = body, .span = d.span } });
}

fn lowerRedirect(r: shape_mod.RedirectShape, ctx: *const LowerContext) !Redirect {
    const op: RedirectOp = switch (r.op) {
        .read, .read_fd => .read,
        .write, .write_fd => .write,
        .append => .append,
        .both => .both_write,
        .both_append => .both_append,
        .dup_out, .dup_in => .dup,
    };

    var from_fd: ?u8 = null;
    var to_fd: ?u8 = null;

    // Decode the fd prefix for any form that carries one.
    if (r.fd_src) |span| {
        const bytes = ctx.source.text[span.start..span.end];
        from_fd = parseLeadingFd(bytes);

        // Dup forms also carry a destination fd encoded in the same token.
        if (r.op == .dup_out or r.op == .dup_in) {
            to_fd = parseTrailingFd(bytes);
        }
    }

    var target: ?Word = null;
    if (r.target) |t| target = try word_mod.lowerWord(t, ctx.alloc);

    return .{
        .op = op,
        .from_fd = from_fd,
        .to_fd = to_fd,
        .target = target,
        .span = r.span,
    };
}

/// Decode a leading decimal fd prefix (e.g. `"2>"` → `2`, `"10>&1"` → `10`).
/// Returns `null` if the token does not start with a digit.
fn parseLeadingFd(bytes: []const u8) ?u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') i += 1;
    if (i == 0) return null;
    return std.fmt.parseInt(u8, bytes[0..i], 10) catch null;
}

/// Decode a trailing decimal fd from a dup token (e.g. `"2>&1"` → `1`,
/// `"3<&10"` → `10`). Scans back from the end.
fn parseTrailingFd(bytes: []const u8) ?u8 {
    if (bytes.len == 0) return null;
    var j: usize = bytes.len;
    while (j > 0 and bytes[j - 1] >= '0' and bytes[j - 1] <= '9') j -= 1;
    if (j == bytes.len) return null;
    return std.fmt.parseInt(u8, bytes[j..], 10) catch null;
}

/// Allocate a Program on the arena and return a pointer to it.
fn put(alloc: Allocator, p: Program) !*const Program {
    const slot = try alloc.create(Program);
    slot.* = p;
    return slot;
}

// =============================================================================
// Dump
// =============================================================================

const Writer = std.Io.Writer;
const WriteError = Writer.Error;

pub const DumpOptions = struct {
    spans: bool = false,
};

pub fn dump(source: Source, program: *const Program, w: *Writer, opts: DumpOptions) WriteError!void {
    try dumpProgram(source, program, 0, w, opts);
}

fn dumpProgram(source: Source, p: *const Program, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    switch (p.*) {
        .command => |c| try dumpCommand(source, c, depth, w, opts),
        .pipeline => |pl| try dumpPipeline(source, pl, depth, w, opts),
        .sequence => |s| try dumpSequence(source, s, depth, w, opts),
        .subshell => |sb| try dumpSubshell(source, sb, depth, w, opts),
        .detached => |d| try dumpDetached(source, d, depth, w, opts),
    }
}

fn dumpCommand(source: Source, c: Command, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    _ = source;
    try w.writeAll("command");
    try maybeSpan(c.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.print("exe {s}\n", .{c.exe.parts[0].text});
    for (c.args) |a| {
        try indent(w, depth + 1);
        try w.print("arg {s}\n", .{a.parts[0].text});
    }
    for (c.redirects) |r| try dumpRedirect(r, depth + 1, w, opts);
}

fn dumpPipeline(source: Source, p: Pipeline, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("pipeline");
    if (p.pipefail) try w.writeAll(" pipefail=on");
    try maybeSpan(p.span, w, opts);
    try w.writeByte('\n');
    for (p.stages) |st| try dumpProgram(source, st, depth + 1, w, opts);
}

fn dumpSequence(source: Source, s: Sequence, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("sequence");
    try maybeSpan(s.span, w, opts);
    try w.writeByte('\n');
    for (s.items) |it| {
        try indent(w, depth + 1);
        if (it.next_op) |op| {
            try w.print("item next={s}\n", .{@tagName(op)});
        } else {
            try w.writeAll("item\n");
        }
        try dumpProgram(source, it.program, depth + 2, w, opts);
    }
}

fn dumpSubshell(source: Source, s: anytype, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("subshell");
    try maybeSpan(s.span, w, opts);
    try w.writeByte('\n');
    try dumpProgram(source, s.body, depth + 1, w, opts);
    for (s.redirects) |r| try dumpRedirect(r, depth + 1, w, opts);
}

fn dumpDetached(source: Source, d: anytype, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("detached");
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try dumpProgram(source, d.body, depth + 1, w, opts);
}

fn dumpRedirect(r: Redirect, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    try w.print("redir {s}", .{@tagName(r.op)});
    if (r.from_fd) |n| try w.print(" from_fd={d}", .{n});
    if (r.to_fd) |n| try w.print(" to_fd={d}", .{n});
    if (r.target) |t| try w.print(" target={s}", .{t.parts[0].text});
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

fn lowerFromSource(alloc: Allocator, text: []const u8) !struct { parsed: shape_mod.Parsed, prog: *const Program } {
    const source = Source{ .name = "<test>", .text = text };
    const parsed = try shape_mod.parse(source, alloc, null);
    const ctx = LowerContext{ .alloc = alloc, .source = source };
    const prog = try lower(parsed.root, &ctx, null);
    return .{ .parsed = parsed, .prog = prog };
}

fn dumpToString(alloc: Allocator, source: Source, p: *const Program) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try dump(source, p, &out.writer, .{});
    return alloc.dupe(u8, out.written());
}

test "lower simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = try lowerFromSource(alloc, "echo hi");
    const got = try dumpToString(alloc, r.parsed.source, r.prog);

    const expected =
        "sequence\n" ++
        "  item\n" ++
        "    command\n" ++
        "      exe echo\n" ++
        "      arg hi\n";
    try std.testing.expectEqualStrings(expected, got);
}

test "lower pipeline with fd redirects decodes fds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = try lowerFromSource(alloc, "cmd 2> err 3>&2");
    const got = try dumpToString(alloc, r.parsed.source, r.prog);

    try std.testing.expect(std.mem.indexOf(u8, got, "redir write from_fd=2 target=err") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "redir dup from_fd=3 to_fd=2") != null);
}

test "foo & bar lowers to detached + always" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = try lowerFromSource(alloc, "sleep 10 & echo done");
    const got = try dumpToString(alloc, r.parsed.source, r.prog);

    try std.testing.expect(std.mem.indexOf(u8, got, "item next=always") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "detached") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "arg done") != null);
}

test "quoted word canonicalized at Program layer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = try lowerFromSource(alloc, "echo \"hi\\n\"");
    const got = try dumpToString(alloc, r.parsed.source, r.prog);
    // The double-quoted escape \n should have been decoded to a real newline.
    try std.testing.expect(std.mem.indexOf(u8, got, "arg hi\n") != null);
}
