//! Slash — entry point
//!
//! Commands. Pipelines. Jobs.
//!
//! Phase 1 scaffolding. Grammar and parser land in Commit 2; execution
//! (shape → program → job) lands in Commits 3 and 4.
//!
//! Currently supported:
//!   slash -v / --version           Print version
//!   slash -h / --help              Print usage
//!   slash -s / --dump-sexp 'src'   Parse a source string, dump the s-expression
//!
//! Not yet (landing in later commits of Phase 1):
//!   slash                          Interactive REPL
//!   slash <file>                   Run a script
//!   slash -c 'src'                 Run a source string

const std = @import("std");
const build_options = @import("build_options");
const parser = @import("parser.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var dump_source: ?[]const u8 = null;

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
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dump-sexp")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("slash: {s} requires a source string argument\n", .{arg});
                return 2;
            }
            dump_source = args[i];
            continue;
        }
        std.debug.print("slash: unknown option: {s}\n", .{arg});
        printUsage();
        return 2;
    }

    if (dump_source) |src| {
        return dumpSexp(alloc, io, src);
    }

    // No flags: Phase 1 scaffolding banner.
    std.debug.print("slash {s} — Phase 1 scaffolding\n", .{build_options.version});
    std.debug.print("use --dump-sexp '<source>' to parse, or --help for options\n", .{});
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

fn printUsage() void {
    std.debug.print(
        \\slash — a modern Unix shell. Commands. Pipelines. Jobs.
        \\
        \\Usage:
        \\  slash                     Start the interactive REPL   (not yet implemented)
        \\  slash <file>              Run a script                 (not yet implemented)
        \\  slash -c 'source'         Run a source string          (not yet implemented)
        \\  slash -s 'source'         Parse and dump the s-expression
        \\
        \\Options:
        \\  -h, --help                Show this help and exit
        \\  -v, --version             Show version and exit
        \\  -s, --dump-sexp 'src'     Dump the s-expression for a source string
        \\
    , .{});
}
