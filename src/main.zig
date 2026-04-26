//! slash — entry point.

const std = @import("std");
const build_options = @import("build_options");
const parser = @import("parser.zig");
const diag = @import("diagnostics.zig");
const shape = @import("shape.zig");
const program = @import("program.zig");
const session_mod = @import("session.zig");
const eval = @import("eval.zig");
const builtins = @import("builtins.zig");
const repl = @import("repl.zig");

const DumpMode = enum { sexp, shape, program };

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var dump_source: ?[]const u8 = null;
    var dump_mode: DumpMode = .sexp;
    var run_source: ?[]const u8 = null;
    var script_path: ?[]const u8 = null;
    var script_args: []const []const u8 = &.{};
    var norc = false;

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
        if (std.mem.eql(u8, arg, "--norc")) {
            norc = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("slash: -c requires a source string\n", .{});
                return 2;
            }
            run_source = args[i];
            continue;
        }

        const maybe_mode: ?DumpMode = if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dump-sexp"))
            .sexp
        else if (std.mem.eql(u8, arg, "--dump-shape"))
            .shape
        else if (std.mem.eql(u8, arg, "--dump-program"))
            .program
        else
            null;

        if (maybe_mode) |mode| {
            i += 1;
            if (i >= args.len) {
                std.debug.print("slash: {s} requires a source string\n", .{arg});
                return 2;
            }
            dump_source = args[i];
            dump_mode = mode;
            continue;
        }

        // Anything else: treat as a script path. Remaining args become $1..$N.
        script_path = arg;
        i += 1;
        if (i < args.len) script_args = args[i..];
        break;
    }

    if (run_source) |src| {
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(std.c.environ));
        return runSource(alloc, envp, "<-c>", src, &.{});
    }

    if (script_path) |path| {
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(std.c.environ));
        return runScript(alloc, envp, path, script_args);
    }

    if (dump_source) |src| {
        return switch (dump_mode) {
            .sexp => dumpSexp(alloc, io, src),
            .shape => dumpShape(alloc, io, src),
            .program => dumpProgram(alloc, io, src),
        };
    }

    // No script, no `-c`, no dump request — drop into the REPL.
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(std.c.environ));
    return runRepl(alloc, envp, .{ .norc = norc });
}

fn runRepl(
    alloc: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    options: repl.Options,
) !u8 {
    var session = try session_mod.Session.init(alloc, envp, true);
    defer session.deinit();
    builtins.installSession(&session);
    return repl.run(&session, alloc, options);
}

// =============================================================================
// `slash -c '<source>'`
// =============================================================================

fn runSource(
    alloc: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    name: []const u8,
    source_text: []const u8,
    script_args: []const []const u8,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = diag.Source{ .name = name, .text = source_text };

    var diag_list = diag.ListSink.init(a);
    const sink = diag_list.sink();

    const parsed = shape.parse(source, a, sink) catch {
        renderDiagnostics(diag_list.items.items);
        return 1;
    };
    const ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = program.lower(parsed.root, &ctx, sink) catch {
        renderDiagnostics(diag_list.items.items);
        return 1;
    };

    var session = try session_mod.Session.init(alloc, envp, false);
    defer session.deinit();
    builtins.installSession(&session);

    // Bind positional parameters.
    try session.vars.setScalar("0", name, false);
    for (script_args, 0..) |arg, i| {
        var keybuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "{d}", .{i + 1}) catch unreachable;
        try session.vars.setScalar(key, arg, false);
    }
    {
        var countbuf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&countbuf, "{d}", .{script_args.len}) catch unreachable;
        try session.vars.setScalar("#", count, false);
    }
    if (script_args.len > 0) try session.vars.setList("@", script_args, false);

    const result = eval.runForeground(prog, &session, a, null) catch |err| {
        std.debug.print("slash: eval error: {s}\n", .{@errorName(err)});
        eval.fireExitTrap(&session, a, null) catch {};
        return 1;
    };

    eval.fireExitTrap(&session, a, null) catch {};
    const final = session.exit_request orelse result;
    return final.toStatusByte();
}

// =============================================================================
// `slash <file>`
// =============================================================================
//
// Reads the file, skips a leading shebang line if present, and runs the
// remainder. `$0` is the script path; `$1..$N` are the trailing arguments.

fn runScript(
    alloc: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    path: []const u8,
    script_args: []const []const u8,
) !u8 {
    const max_size: usize = 64 * 1024 * 1024;
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        std.debug.print("slash: cannot open {s}\n", .{path});
        return 1;
    }
    defer _ = std.c.close(fd);

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            const e = std.c.errno(@as(c_int, -1));
            if (e == .INTR) continue;
            std.debug.print("slash: read error\n", .{});
            return 1;
        }
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..@intCast(n)]);
        if (buf.items.len > max_size) {
            std.debug.print("slash: script too large\n", .{});
            return 1;
        }
    }

    var src = buf.items;
    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
        src = if (nl < src.len) src[nl + 1 ..] else &.{};
    }

    return runSource(alloc, envp, path, src, script_args);
}

// =============================================================================
// Dumpers
// =============================================================================

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

/// Render every recorded diagnostic to stderr. Slash writes through
/// the raw POSIX fd because the rest of the eval pipeline already lives
/// on `std.c.*` and threading an `Io` purely for diagnostics would mean
/// touching the harness too.
fn renderDiagnostics(items: []const diag.Diagnostic) void {
    var buf: [4096]u8 = undefined;
    for (items) |d| {
        var stream = std.Io.Writer.fixed(&buf);
        diag.render(d, .snippet, &stream) catch continue;
        const bytes = stream.buffered();
        _ = std.c.write(2, bytes.ptr, bytes.len);
    }
}

fn dumpShape(alloc: std.mem.Allocator, io: std.Io, source_text: []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = diag.Source{ .name = "<arg>", .text = source_text };
    var diag_list = diag.ListSink.init(a);
    const sink = diag_list.sink();
    const parsed = shape.parse(source, a, sink) catch {
        renderDiagnostics(diag_list.items.items);
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
    var diag_list = diag.ListSink.init(a);
    const sink = diag_list.sink();
    const parsed = shape.parse(source, a, sink) catch {
        renderDiagnostics(diag_list.items.items);
        return 1;
    };
    const ctx = program.LowerContext{ .alloc = a, .source = source };
    const prog = program.lower(parsed.root, &ctx, sink) catch {
        renderDiagnostics(diag_list.items.items);
        return 1;
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try program.dump(source, prog, &stdout.interface, .{});
    try stdout.interface.flush();
    return 0;
}

test {
    _ = @import("diagnostics.zig");
    _ = @import("shape.zig");
    _ = @import("word.zig");
    _ = @import("program.zig");
    _ = @import("runtime.zig");
    _ = @import("exec.zig");
    _ = @import("job.zig");
    _ = @import("builtins.zig");
    _ = @import("session.zig");
    _ = @import("vars.zig");
    _ = @import("eval.zig");
    _ = @import("repl.zig");
    _ = @import("headless_tests.zig");
}

fn printUsage() void {
    std.debug.print(
        \\slash — a Unix shell with structured commands, composable pipelines, and first-class jobs.
        \\
        \\Usage:
        \\  slash                     Start an interactive shell (sources ~/.slashrc unless --norc)
        \\  slash <file> [args...]    Run a script with positional args bound to $1..$N
        \\  slash -c 'source'         Run a source string
        \\
        \\Options:
        \\  -h, --help                Show this help and exit
        \\  -v, --version             Show version and exit
        \\  -c 'src'                  Run a source string and exit with its status
        \\  --norc                    Do not source ~/.slashrc on interactive startup
        \\  -s, --dump-sexp 'src'     Dump the s-expression for a source string
        \\      --dump-shape 'src'    Dump the Shape tree
        \\      --dump-program 'src'  Dump the lowered Program
        \\
    , .{});
}
