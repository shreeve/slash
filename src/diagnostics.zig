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
