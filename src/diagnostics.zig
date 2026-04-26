//! Slash — diagnostics model.
//!
//! One diagnostic type spans every phase: shape, lower, eval, exec, job.
//! Diagnostics are data, not strings. A single optional `Sink` is threaded
//! through the top-level request APIs; no global logger, no callback chain.
//!
//! See PLAN.md §16 for the full contract, §16.5 for the per-phase policy,
//! and §16.3 for the error-code convention (SH/LW/EV/EX/JB prefixes).

const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32, // half-open: covers source[start..end]
};

pub const Source = struct {
    name: []const u8, // file path, "<repl>", "<arg>", "<-c>"
    text: []const u8, // immutable UTF-8
};

pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,
};

pub const Phase = enum {
    shape, // lex + parse
    lower,
    eval,
    exec,
    job,
};

pub const Related = struct {
    message: []const u8,
    source: Source,
    span: Span,
};

pub const Diagnostic = struct {
    phase: Phase,
    severity: Severity,
    code: ?[]const u8, // "SH0001", "LW0004", etc. — see §16.3
    message: []const u8,
    source: Source,
    span: ?Span,
    notes: []const []const u8 = &.{},
    related: []const Related = &.{},
};

/// Type-erased sink. One canonical emit path for every phase.
pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, diag: Diagnostic) anyerror!void,

    pub fn emit(self: Sink, diag: Diagnostic) !void {
        return self.emitFn(self.ctx, diag);
    }
};

/// ArrayList-backed sink. Tests use this to assert on diagnostic count,
/// code, span, and severity without depending on rendered prose.
pub const ListSink = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn init(alloc: std.mem.Allocator) ListSink {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ListSink) void {
        self.items.deinit(self.alloc);
    }

    pub fn sink(self: *ListSink) Sink {
        return .{
            .ctx = self,
            .emitFn = struct {
                fn call(ctx: *anyopaque, diag: Diagnostic) !void {
                    const s: *ListSink = @ptrCast(@alignCast(ctx));
                    try s.items.append(s.alloc, diag);
                }
            }.call,
        };
    }

    pub fn hasErrors(self: *const ListSink) bool {
        for (self.items.items) |d| switch (d.severity) {
            .@"error", .fatal => return true,
            else => {},
        };
        return false;
    }
};

/// Compact factory. Callers use this to build diagnostics inline without
/// repeating field names.
pub fn make(
    phase: Phase,
    severity: Severity,
    code: ?[]const u8,
    message: []const u8,
    source: Source,
    span: ?Span,
) Diagnostic {
    return .{
        .phase = phase,
        .severity = severity,
        .code = code,
        .message = message,
        .source = source,
        .span = span,
    };
}

/// Emit into an optional sink. Callers pass `null` when they don't care
/// (e.g. in the REPL's default path).
pub fn emit(sink: ?Sink, diag: Diagnostic) !void {
    if (sink) |s| try s.emit(diag);
}

/// Aggregate check — `true` if any diagnostic is error-level or worse.
pub fn hasErrors(diags: []const Diagnostic) bool {
    for (diags) |d| switch (d.severity) {
        .@"error", .fatal => return true,
        else => {},
    };
    return false;
}

// =============================================================================
// Span helpers
// =============================================================================

/// Hull of two spans.
pub fn cover(a: Span, b: Span) Span {
    return .{
        .start = @min(a.start, b.start),
        .end = @max(a.end, b.end),
    };
}

/// 1-indexed line + column for a byte offset into a source. Returns
/// `{ line: 1, column: 1 }` when offset is past end-of-source.
pub const LineCol = struct { line: u32, column: u32 };

pub fn lineColumn(source: Source, offset: u32) LineCol {
    const off = @min(offset, @as(u32, @intCast(source.text.len)));
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    while (i < off) : (i += 1) {
        if (source.text[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

// =============================================================================
// Rendering
// =============================================================================

pub const RenderStyle = enum {
    /// One-line summary suitable for compact log output.
    single_line,
    /// Multi-line snippet with the offending line and a caret.
    snippet,
};

/// Render a `Diagnostic` for a human reader. The output ends with a
/// newline. The writer is `std.Io.Writer` (the standard interface used
/// elsewhere in Slash).
pub fn render(diag: Diagnostic, style: RenderStyle, writer: anytype) !void {
    switch (style) {
        .single_line => try renderSingleLine(diag, writer),
        .snippet => try renderSnippet(diag, writer),
    }
}

fn renderSingleLine(diag: Diagnostic, writer: anytype) !void {
    const sev = severityWord(diag.severity);
    if (diag.span) |sp| {
        const lc = lineColumn(diag.source, sp.start);
        if (diag.code) |code| {
            try writer.print("{s}[{s}]: {s} at {s}:{d}:{d}\n", .{
                sev, code, diag.message, diag.source.name, lc.line, lc.column,
            });
        } else {
            try writer.print("{s}: {s} at {s}:{d}:{d}\n", .{
                sev, diag.message, diag.source.name, lc.line, lc.column,
            });
        }
    } else {
        if (diag.code) |code| {
            try writer.print("{s}[{s}]: {s}\n", .{ sev, code, diag.message });
        } else {
            try writer.print("{s}: {s}\n", .{ sev, diag.message });
        }
    }
}

fn renderSnippet(diag: Diagnostic, writer: anytype) !void {
    const sev = severityWord(diag.severity);
    if (diag.code) |code| {
        try writer.print("{s}[{s}]: {s}\n", .{ sev, code, diag.message });
    } else {
        try writer.print("{s}: {s}\n", .{ sev, diag.message });
    }
    if (diag.span) |sp| {
        const lc = lineColumn(diag.source, sp.start);
        try writer.print("  --> {s}:{d}:{d}\n", .{ diag.source.name, lc.line, lc.column });
        try writeSourceSnippet(diag.source, sp, writer);
    }
    for (diag.notes) |n| try writer.print("   = note: {s}\n", .{n});
}

fn writeSourceSnippet(source: Source, span: Span, writer: anytype) !void {
    // Identify the line that contains `span.start` and print it with a
    // caret pointing at the column. Non-printable bytes are passed
    // through verbatim — the underlying terminal is responsible for
    // rendering them sensibly.
    const text = source.text;
    const start = @min(span.start, @as(u32, @intCast(text.len)));
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < start) : (i += 1) {
        if (text[i] == '\n') line_start = i + 1;
    }
    var line_end: u32 = start;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

    const lc = lineColumn(source, span.start);
    try writer.print("{d:>4} | {s}\n", .{ lc.line, text[line_start..line_end] });
    try writer.writeAll("     | ");
    var col: u32 = 1;
    while (col < lc.column) : (col += 1) try writer.writeByte(' ');
    const end = @min(span.end, line_end);
    const width: u32 = if (end > span.start) end - span.start else 1;
    try writer.writeByte('^');
    var k: u32 = 1;
    while (k < width) : (k += 1) try writer.writeByte('~');
    try writer.writeByte('\n');
}

fn severityWord(sev: Severity) []const u8 {
    return switch (sev) {
        .note => "note",
        .warning => "warning",
        .@"error" => "error",
        .fatal => "fatal",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "ListSink records diagnostics" {
    var list = ListSink.init(std.testing.allocator);
    defer list.deinit();

    const src = Source{ .name = "<test>", .text = "" };
    try list.sink().emit(make(.shape, .@"error", "SH0001", "unexpected token", src, null));
    try list.sink().emit(make(.shape, .warning, null, "shadow warning", src, null));

    try std.testing.expectEqual(@as(usize, 2), list.items.items.len);
    try std.testing.expect(list.hasErrors());
}

test "cover joins two spans" {
    const a = Span{ .start = 10, .end = 20 };
    const b = Span{ .start = 15, .end = 25 };
    const c = cover(a, b);
    try std.testing.expectEqual(@as(u32, 10), c.start);
    try std.testing.expectEqual(@as(u32, 25), c.end);
}

test "lineColumn returns 1-indexed line and column" {
    const src = Source{ .name = "<test>", .text = "abc\ndef\nghi" };
    try std.testing.expectEqual(LineCol{ .line = 1, .column = 1 }, lineColumn(src, 0));
    try std.testing.expectEqual(LineCol{ .line = 1, .column = 4 }, lineColumn(src, 3));
    try std.testing.expectEqual(LineCol{ .line = 2, .column = 1 }, lineColumn(src, 4));
    try std.testing.expectEqual(LineCol{ .line = 3, .column = 2 }, lineColumn(src, 9));
}

test "render: single_line includes code and location" {
    const src = Source{ .name = "<x>", .text = "foo bar" };
    const d = make(.shape, .@"error", "SH0001", "boom", src, .{ .start = 4, .end = 7 });
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try render(d, .single_line, &stream);
    const got = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "[SH0001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "<x>:1:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "boom") != null);
}

test "render: snippet draws caret under the span start" {
    const src = Source{ .name = "<x>", .text = "echo > " };
    const d = make(.shape, .@"error", "SH0001", "unexpected eof", src, .{ .start = 7, .end = 7 });
    var buf: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try render(d, .snippet, &stream);
    const got = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "echo > ") != null);
    // Caret column should be 1-indexed at byte offset 7, which is the
    // first column past the trailing space — column 8.
    try std.testing.expect(std.mem.indexOf(u8, got, "<x>:1:8") != null);
}

test "shape.parse emits SH0001 with span on parse error" {
    const shape = @import("shape.zig");
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var list = ListSink.init(a);
    const src = Source{ .name = "<test>", .text = "| echo nope" };

    const result = shape.parse(src, a, list.sink());
    try std.testing.expectError(error.ParserError, result);
    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);

    const d = list.items.items[0];
    try std.testing.expectEqualStrings("SH0001", d.code.?);
    try std.testing.expectEqual(@as(u32, 0), d.span.?.start);
    try std.testing.expectEqual(@as(u32, 1), d.span.?.end);
}
