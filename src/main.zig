//! Slash — entry point
//!
//! Commands. Pipelines. Jobs.
//!
//! Phase 1 scaffolding. This binary currently prints its version and exits.
//! Future flags (see PLAN.md §10, §22.1):
//!   slash                Start the interactive REPL   (not yet)
//!   slash <file>         Run a script non-interactively (not yet)
//!   slash -c 'source'    Run a source string           (not yet)
//!   slash -v / --version Print version                 (this file)

const std = @import("std");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("slash {s}\n", .{build_options.version});
            return 0;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        }
    }

    // Phase 1 scaffolding: no commands are runnable yet. Print the banner so
    // `zig build run` proves the toolchain is wired up end to end.
    std.debug.print("slash {s} — Phase 1 scaffolding\n", .{build_options.version});
    std.debug.print("(no source given; parser, shape, program, and eval are not yet implemented)\n", .{});
    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\slash — a modern Unix shell. Commands. Pipelines. Jobs.
        \\
        \\Usage:
        \\  slash                 Start the interactive REPL   (not yet implemented)
        \\  slash <file>          Run a script                 (not yet implemented)
        \\  slash -c 'source'     Run a source string          (not yet implemented)
        \\
        \\Options:
        \\  -h, --help            Show this help and exit
        \\  -v, --version         Show version and exit
        \\
    , .{});
}
