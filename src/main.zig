//! Slash — entry point
//!
//! Commands. Pipelines. Jobs.
//!
//! Phase 1 in progress. Parser, Shape, Word, and Program are in place; the
//! executor (Job, process plumbing) lands in the next commit.
//!
//! Currently supported:
//!   slash -v / --version         Print version
//!   slash -h / --help            Print usage
//!   slash -s / --dump-sexp 'src' Raw parser s-expression
//!       --dump-shape 'src'       Lowered Shape tree
//!       --dump-program 'src'     Immutable Program kernel
//!
//! Not yet:
//!   slash                          Interactive REPL
//!   slash <file>                   Run a script
//!   slash -c 'src'                 Run a source string

const std = @import("std");
const build_options = @import("build_options");
const parser = @import("parser.zig");
const diag = @import("diagnostics.zig");
const shape = @import("shape.zig");
const program = @import("program.zig");

const DumpMode = enum { sexp, shape, program };

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var dump_source: ?[]const u8 = null;
    var dump_mode: DumpMode = .sexp;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("slash {s}\n", .{build_options.version});
            return 0;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        }

        const maybe_mode: ?DumpMode =
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dump-sexp")) .sexp
            else if (std.mem.eql(u8, arg, "--dump-shape")) .shape
            else if (std.mem.eql(u8, arg, "--dump-program")) .program
            else null;

        if (maybe_mode) |mode| {
            i += 1;
            if (i >= args.len) {
                std.debug.print("slash: {s} requires a source string argument\n", .{arg});
                return 2;
            }
            dump_source = args[i];
            dump_mode = mode;
            continue;
        }

        std.debug.print("slash: unknown option: {s}\n", .{arg});
        printUsage();
        return 2;
    }

    if (dump_source) |src| {
        return switch (dump_mode) {
            .sexp => dumpSexp(alloc, io, src),
            .shape => dumpShape(alloc, io, src),
            .program => dumpProgram(alloc, io, src),
        };
    }

    std.debug.print("slash {s} — Phase 1 scaffolding\n", .{build_options.version});
    std.debug.print("use --dump-sexp / --dump-shape / --dump-program '<source>', or --help\n", .{});
    return 0;
}

fn dumpSexp(alloc: std.mem.Allocator, io: std.Io, source: []const u8) !u8 {
    var p = parser.Parser.init(alloc, source);
    defer p.deinit();

    const tree = p.parseProgram() catch |err| {
        std.debug.print("slash: parse error: {s}\n", .{@errorName(err)});
        p.printError();
        return 1;
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    try tree.write(source, w);
    try w.writeAll("\n");
    try w.flush();
    return 0;
}

fn dumpShape(alloc: std.mem.Allocator, io: std.Io, source_text: []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = diag.Source{ .name = "<arg>", .text = source_text };
    const parsed = shape.parse(source, a, null) catch |err| {
        std.debug.print("slash: shape error: {s}\n", .{@errorName(err)});
        return 1;
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try shape.dump(parsed, &stdout.interface, .{});
    try stdout.interface.flush();
    return 0;
}

fn dumpProgram(alloc: std.mem.Allocator, io: std.Io, source_text: []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = diag.Source{ .name = "<arg>", .text = source_text };
    const parsed = shape.parse(source, a, null) catch |err| {
        std.debug.print("slash: shape error: {s}\n", .{@errorName(err)});
        return 1;
    };
    const ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = program.lower(parsed.root, &ctx, null) catch |err| {
        std.debug.print("slash: lower error: {s}\n", .{@errorName(err)});
        return 1;
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try program.dump(source, prog, &stdout.interface, .{});
    try stdout.interface.flush();
    return 0;
}

// Explicit test discovery — `zig build test` scans reachable decls, but
// without a reference in non-test code it may not pick up modules only used
// transitively. This makes every module's test block addressable.
test {
    _ = @import("diagnostics.zig");
    _ = @import("shape.zig");
    _ = @import("word.zig");
    _ = @import("program.zig");
    _ = @import("goldens.zig");
}

fn printUsage() void {
    std.debug.print(
        \\slash — a modern Unix shell. Commands. Pipelines. Jobs.
        \\
        \\Usage:
        \\  slash                     Start the interactive REPL   (not yet implemented)
        \\  slash <file>              Run a script                 (not yet implemented)
        \\  slash -c 'source'         Run a source string          (not yet implemented)
        \\
        \\Options:
        \\  -h, --help                Show this help and exit
        \\  -v, --version             Show version and exit
        \\  -s, --dump-sexp 'src'     Dump the s-expression for a source string
        \\      --dump-shape 'src'    Dump the Shape tree
        \\      --dump-program 'src'  Dump the lowered Program
        \\
    , .{});
}
