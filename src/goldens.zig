//! Golden snapshot tests.
//!
//! Each case embeds its source and expected dump at comptime via
//! `@embedFile`, so no runtime filesystem access is required and the
//! tests run identically on every platform.
//!
//! Determinism guarantees (PLAN §17.11):
//!   - line endings are `\n` only (enforced in the dump code)
//!   - field order is fixed (no map iteration, no pointer addresses)
//!   - spans are omitted by default; span correctness lives in dedicated
//!     table-driven tests
//!
//! To add a case: drop `foo.sl` + `foo.shape` into `tests/shape/basic/`
//! and/or `foo.program` into `tests/program/basic/`, then add a line to
//! the case list below. To regenerate after an intentional dump change,
//! run the slash binary locally:
//!
//!   ./bin/slash --dump-shape   "$(cat tests/shape/basic/foo.sl)"   > tests/shape/basic/foo.shape
//!   ./bin/slash --dump-program "$(cat tests/program/basic/foo.sl)" > tests/program/basic/foo.program

const std = @import("std");
const diag = @import("diagnostics.zig");
const shape = @import("shape.zig");
const program = @import("program.zig");

const ShapeCase = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
};

const ProgramCase = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8,
};

const shape_cases: []const ShapeCase = &.{
    .{
        .name = "command",
        .source = @embedFile("goldens/shape/basic/command.sl"),
        .expected = @embedFile("goldens/shape/basic/command.shape"),
    },
    .{
        .name = "pipeline",
        .source = @embedFile("goldens/shape/basic/pipeline.sl"),
        .expected = @embedFile("goldens/shape/basic/pipeline.shape"),
    },
    .{
        .name = "redirects",
        .source = @embedFile("goldens/shape/basic/redirects.sl"),
        .expected = @embedFile("goldens/shape/basic/redirects.shape"),
    },
    .{
        .name = "detached",
        .source = @embedFile("goldens/shape/basic/detached.sl"),
        .expected = @embedFile("goldens/shape/basic/detached.shape"),
    },
    .{
        .name = "subshell",
        .source = @embedFile("goldens/shape/basic/subshell.sl"),
        .expected = @embedFile("goldens/shape/basic/subshell.shape"),
    },
};

const program_cases: []const ProgramCase = &.{
    .{
        .name = "command",
        .source = @embedFile("goldens/program/basic/command.sl"),
        .expected = @embedFile("goldens/program/basic/command.program"),
    },
    .{
        .name = "pipeline",
        .source = @embedFile("goldens/program/basic/pipeline.sl"),
        .expected = @embedFile("goldens/program/basic/pipeline.program"),
    },
    .{
        .name = "redirects",
        .source = @embedFile("goldens/program/basic/redirects.sl"),
        .expected = @embedFile("goldens/program/basic/redirects.program"),
    },
    .{
        .name = "detached",
        .source = @embedFile("goldens/program/basic/detached.sl"),
        .expected = @embedFile("goldens/program/basic/detached.program"),
    },
    .{
        .name = "subshell",
        .source = @embedFile("goldens/program/basic/subshell.sl"),
        .expected = @embedFile("goldens/program/basic/subshell.program"),
    },
};

test "shape goldens" {
    const alloc = std.testing.allocator;
    var failures: u32 = 0;
    for (shape_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const src = diag.Source{ .name = case.name, .text = case.source };
        const parsed = try shape.parse(src, a, null);

        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try shape.dump(parsed, &out.writer, .{});

        if (!std.mem.eql(u8, out.written(), case.expected)) {
            std.debug.print("FAIL shape/{s}\n--- expected ---\n{s}--- actual ---\n{s}\n", .{
                case.name, case.expected, out.written(),
            });
            failures += 1;
        }
    }
    if (failures > 0) return error.GoldenMismatch;
}

test "program goldens" {
    const alloc = std.testing.allocator;
    var failures: u32 = 0;
    for (program_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const src = diag.Source{ .name = case.name, .text = case.source };
        const parsed = try shape.parse(src, a, null);
        const ctx = program.LowerContext{ .alloc = a, .source = src };
        const prog = try program.lower(parsed.root, &ctx, null);

        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try program.dump(src, prog, &out.writer, .{});

        if (!std.mem.eql(u8, out.written(), case.expected)) {
            std.debug.print("FAIL program/{s}\n--- expected ---\n{s}--- actual ---\n{s}\n", .{
                case.name, case.expected, out.written(),
            });
            failures += 1;
        }
    }
    if (failures > 0) return error.GoldenMismatch;
}
