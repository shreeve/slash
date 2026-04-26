//! Program — the lowered, immutable executable semantics of a Shape.
//!
//! Program contains no syntactic sugar, no unresolved redirects, and no
//! ambiguous execution structure. Lowering normalizes compound-command
//! redirects and resolves block forms (brace and indent) into a single
//! Block kernel form. Program is the universe the evaluator operates on.

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
// Redirect
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
    /// Source fd whose entry in the child's fd table gets pointed somewhere
    /// else. `null` means "default for this op" (0 for read, 1 for write/
    /// append, both 1 and 2 for `both*`).
    from_fd: ?u8,
    /// For dup forms, the destination fd. For file-target forms, `null`
    /// (the path lives in `target`).
    to_fd: ?u8,
    target: ?Word,
    span: Span,
};

// =============================================================================
// Bindings, command, sequence, pipeline
// =============================================================================

pub const AssignValue = union(enum) {
    scalar: Word,
    list: []const Word,
};

pub const EnvBind = struct {
    name: []const u8,
    value: AssignValue,
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
    pipefail: bool = true,
    span: Span,
};

pub const SequenceOp = enum { always, and_then, or_else };

pub const SequenceItem = struct {
    program: *const Program,
    next_op: ?SequenceOp,
};

pub const Sequence = struct {
    items: []const SequenceItem,
    span: Span,
};

pub const Assigns = struct {
    binds: []const EnvBind,
    span: Span,
};

pub const Conditional = struct {
    cond: *const Program,
    then_body: *const Program,
    else_body: ?*const Program,
    redirects: []const Redirect = &.{},
    span: Span,
};

pub const While = struct {
    cond: *const Program,
    body: *const Program,
    redirects: []const Redirect = &.{},
    span: Span,
};

pub const For = struct {
    binding: []const u8,
    items: []const Word,
    body: *const Program,
    redirects: []const Redirect = &.{},
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
    /// `{ ... }` — runs in the current shell context. The child sequence
    /// can mutate Session state. Compound redirects on a redirected block
    /// are normalized into a subshell at lowering, so this form never
    /// carries redirects directly when reached at runtime — but the field
    /// stays for symmetry and for forms that don't need normalization.
    block: struct {
        body: *const Program,
        redirects: []const Redirect,
        span: Span,
    },
    detached: struct {
        body: *const Program,
        span: Span,
    },
    assigns: Assigns,
    conditional: Conditional,
    @"while": While,
    @"for": For,

    pub fn span(self: Program) Span {
        return switch (self) {
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

// =============================================================================
// Lowering context
// =============================================================================

pub const Features = struct {
    process_subst: bool = false,
    heredoc: bool = false,
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
        .block => |b| try lowerBlock(b, ctx, sink),
        .detached => |d| try lowerDetached(d, ctx, sink),
        .assigns => |a| try lowerAssigns(a, ctx, sink),
        .conditional => |c| try lowerConditional(c, ctx, sink),
        .@"while" => |w| try lowerWhile(w, ctx, sink),
        .@"for" => |f| try lowerFor(f, ctx, sink),
        .word => {
            try diag.emit(sink, diag.make(
                .lower,
                .@"error",
                "LW0001",
                "a word cannot appear as a Program",
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
    const exe = try word_mod.lowerWord(c.exe, ctx);
    var args = try ctx.alloc.alloc(Word, c.args.len);
    for (c.args, 0..) |a, i| args[i] = try word_mod.lowerWord(a, ctx);
    var reds = try ctx.alloc.alloc(Redirect, c.redirects.len);
    for (c.redirects, 0..) |r, i| reds[i] = try lowerRedirect(r, ctx);
    var env = try ctx.alloc.alloc(EnvBind, c.env.len);
    for (c.env, 0..) |b, i| env[i] = try lowerEnvBind(b, ctx);
    return put(ctx.alloc, .{ .command = .{
        .exe = exe,
        .args = args,
        .env = env,
        .cwd = null,
        .redirects = reds,
        .span = c.span,
    } });
}

fn lowerSubshell(s: shape_mod.SubshellShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(s.body.*, ctx, sink);
    var reds = try ctx.alloc.alloc(Redirect, s.redirects.len);
    for (s.redirects, 0..) |r, i| reds[i] = try lowerRedirect(r, ctx);
    return put(ctx.alloc, .{ .subshell = .{ .body = body, .redirects = reds, .span = s.span } });
}

fn lowerBlock(b: shape_mod.BlockShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(b.body.*, ctx, sink);
    if (b.redirects.len == 0) {
        return put(ctx.alloc, .{ .block = .{
            .body = body,
            .redirects = &.{},
            .span = b.span,
        } });
    }
    // A redirected block is normalized into a subshell so the redirects
    // attach to a forked-child fd table rather than the parent shell's.
    var reds = try ctx.alloc.alloc(Redirect, b.redirects.len);
    for (b.redirects, 0..) |r, i| reds[i] = try lowerRedirect(r, ctx);
    return put(ctx.alloc, .{ .subshell = .{ .body = body, .redirects = reds, .span = b.span } });
}

fn lowerDetached(d: shape_mod.DetachedShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(d.body.*, ctx, sink);
    return put(ctx.alloc, .{ .detached = .{ .body = body, .span = d.span } });
}

fn lowerAssigns(a: shape_mod.AssignsShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    _ = sink;
    var binds = try ctx.alloc.alloc(EnvBind, a.binds.len);
    for (a.binds, 0..) |b, i| binds[i] = try lowerEnvBind(b, ctx);
    return put(ctx.alloc, .{ .assigns = .{ .binds = binds, .span = a.span } });
}

fn lowerConditional(c: shape_mod.ConditionalShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const cond = try lowerShape(c.cond.*, ctx, sink);
    const then_body = try lowerShape(c.then_body.*, ctx, sink);
    var else_body: ?*const Program = null;
    if (c.else_body) |eb| else_body = try lowerShape(eb.*, ctx, sink);
    return put(ctx.alloc, .{ .conditional = .{
        .cond = cond,
        .then_body = then_body,
        .else_body = else_body,
        .redirects = &.{},
        .span = c.span,
    } });
}

fn lowerWhile(w: shape_mod.WhileShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const cond = try lowerShape(w.cond.*, ctx, sink);
    const body = try lowerShape(w.body.*, ctx, sink);
    return put(ctx.alloc, .{ .@"while" = .{
        .cond = cond,
        .body = body,
        .redirects = &.{},
        .span = w.span,
    } });
}

fn lowerFor(f: shape_mod.ForShape, ctx: *const LowerContext, sink: ?Sink) anyerror!*const Program {
    const body = try lowerShape(f.body.*, ctx, sink);
    var items = try ctx.alloc.alloc(Word, f.items.len);
    for (f.items, 0..) |it, i| items[i] = try word_mod.lowerWord(it, ctx);
    return put(ctx.alloc, .{ .@"for" = .{
        .binding = try ctx.alloc.dupe(u8, f.binding),
        .items = items,
        .body = body,
        .redirects = &.{},
        .span = f.span,
    } });
}

fn lowerEnvBind(b: shape_mod.EnvBindShape, ctx: *const LowerContext) !EnvBind {
    const name = try ctx.alloc.dupe(u8, b.name);
    const value: AssignValue = switch (b.value) {
        .scalar => |w| AssignValue{ .scalar = try word_mod.lowerWord(w, ctx) },
        .list => |ws| blk: {
            var out = try ctx.alloc.alloc(Word, ws.len);
            for (ws, 0..) |w, i| out[i] = try word_mod.lowerWord(w, ctx);
            break :blk AssignValue{ .list = out };
        },
    };
    return .{ .name = name, .value = value };
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
    if (r.fd_src) |span| {
        const bytes = ctx.source.text[span.start..span.end];
        from_fd = parseLeadingFd(bytes);
        if (r.op == .dup_out or r.op == .dup_in) {
            to_fd = parseTrailingFd(bytes);
        }
    }

    var target: ?Word = null;
    if (r.target) |t| target = try word_mod.lowerWord(t, ctx);

    return .{
        .op = op,
        .from_fd = from_fd,
        .to_fd = to_fd,
        .target = target,
        .span = r.span,
    };
}

fn parseLeadingFd(bytes: []const u8) ?u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') i += 1;
    if (i == 0) return null;
    return std.fmt.parseInt(u8, bytes[0..i], 10) catch null;
}

fn parseTrailingFd(bytes: []const u8) ?u8 {
    if (bytes.len == 0) return null;
    var j: usize = bytes.len;
    while (j > 0 and bytes[j - 1] >= '0' and bytes[j - 1] <= '9') j -= 1;
    if (j == bytes.len) return null;
    return std.fmt.parseInt(u8, bytes[j..], 10) catch null;
}

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

pub const DumpOptions = struct { spans: bool = false };

pub fn dump(source: Source, program: *const Program, w: *Writer, opts: DumpOptions) WriteError!void {
    try dumpProgram(source, program, 0, w, opts);
}

fn dumpProgram(source: Source, p: *const Program, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    switch (p.*) {
        .command => |c| try dumpCommand(c, depth, w, opts),
        .pipeline => |pl| try dumpPipeline(source, pl, depth, w, opts),
        .sequence => |s| try dumpSequence(source, s, depth, w, opts),
        .subshell => |sb| try dumpSubshellLike("subshell", source, sb.body, sb.redirects, sb.span, depth, w, opts),
        .block => |b| try dumpSubshellLike("block", source, b.body, b.redirects, b.span, depth, w, opts),
        .detached => |d| try dumpDetached(source, d, depth, w, opts),
        .assigns => |a| try dumpAssigns(a, depth, w, opts),
        .conditional => |c| try dumpConditional(source, c, depth, w, opts),
        .@"while" => |x| try dumpWhile(source, x, depth, w, opts),
        .@"for" => |x| try dumpFor(source, x, depth, w, opts),
    }
}

fn dumpCommand(c: Command, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
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
                for (ws) |it| try dumpWordParts(it, depth + 3, w);
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
    for (c.redirects) |r| try dumpRedirect(r, depth + 1, w, opts);
}

fn dumpWordParts(word: Word, depth: u32, w: *Writer) WriteError!void {
    for (word.parts) |part| {
        try indent(w, depth);
        switch (part) {
            .text => |t| try w.print("text {s}\n", .{t}),
            .variable => |name| try w.print("var {s}\n", .{name}),
            .var_braced => |vb| {
                if (vb.default == null) {
                    try w.print("var_braced {s}\n", .{vb.name});
                } else {
                    try w.print("var_braced {s} ??\n", .{vb.name});
                    for (vb.default.?.parts) |dp| {
                        try indent(w, depth + 1);
                        switch (dp) {
                            .text => |t| try w.print("text {s}\n", .{t}),
                            .variable => |n| try w.print("var {s}\n", .{n}),
                            else => try w.writeAll("<other>\n"),
                        }
                    }
                }
            },
            .cmd_subst => try w.writeAll("cmd_subst\n"),
            .glob => |pat| try w.print("glob {s}\n", .{pat}),
        }
    }
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

fn dumpSubshellLike(
    label: []const u8,
    source: Source,
    body: *const Program,
    reds: []const Redirect,
    span: Span,
    depth: u32,
    w: *Writer,
    opts: DumpOptions,
) WriteError!void {
    try w.writeAll(label);
    try maybeSpan(span, w, opts);
    try w.writeByte('\n');
    try dumpProgram(source, body, depth + 1, w, opts);
    for (reds) |r| try dumpRedirect(r, depth + 1, w, opts);
}

fn dumpDetached(source: Source, d: anytype, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("detached");
    try maybeSpan(d.span, w, opts);
    try w.writeByte('\n');
    try dumpProgram(source, d.body, depth + 1, w, opts);
}

fn dumpAssigns(a: Assigns, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("assigns");
    try maybeSpan(a.span, w, opts);
    try w.writeByte('\n');
    for (a.binds) |b| {
        try indent(w, depth + 1);
        try w.print("bind {s}\n", .{b.name});
        switch (b.value) {
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

fn dumpConditional(source: Source, c: Conditional, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("conditional");
    try maybeSpan(c.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("cond\n");
    try dumpProgram(source, c.cond, depth + 2, w, opts);
    try indent(w, depth + 1);
    try w.writeAll("then\n");
    try dumpProgram(source, c.then_body, depth + 2, w, opts);
    if (c.else_body) |eb| {
        try indent(w, depth + 1);
        try w.writeAll("else\n");
        try dumpProgram(source, eb, depth + 2, w, opts);
    }
}

fn dumpWhile(source: Source, x: While, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.writeAll("while");
    try maybeSpan(x.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("cond\n");
    try dumpProgram(source, x.cond, depth + 2, w, opts);
    try indent(w, depth + 1);
    try w.writeAll("body\n");
    try dumpProgram(source, x.body, depth + 2, w, opts);
}

fn dumpFor(source: Source, x: For, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try w.print("for {s}", .{x.binding});
    try maybeSpan(x.span, w, opts);
    try w.writeByte('\n');
    try indent(w, depth + 1);
    try w.writeAll("items\n");
    for (x.items) |it| try dumpWordParts(it, depth + 2, w);
    try indent(w, depth + 1);
    try w.writeAll("body\n");
    try dumpProgram(source, x.body, depth + 2, w, opts);
}

fn dumpRedirect(r: Redirect, depth: u32, w: *Writer, opts: DumpOptions) WriteError!void {
    try indent(w, depth);
    try w.print("redir {s}", .{@tagName(r.op)});
    if (r.from_fd) |n| try w.print(" from_fd={d}", .{n});
    if (r.to_fd) |n| try w.print(" to_fd={d}", .{n});
    if (r.target) |t| {
        switch (t.parts[0]) {
            .text => |bytes| try w.print(" target={s}", .{bytes}),
            .variable => |name| try w.print(" target=$" ++ "{s}", .{name}),
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
