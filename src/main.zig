//! Slash — A modern shell with Unix roots
//!
//! Usage:
//!   slash                    Start interactive REPL
//!   slash [script.slash]     Execute a script
//!   slash -c "command"       Execute a single command
//!
//! Options:
//!   -h, --help         Show help
//!   -v, --version      Show version
//!   -t, --tokens       Dump tokens
//!   -s, --sexp         Dump s-expressions
//!   -c CMD             Execute command string

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const exec = @import("exec.zig");
const readline = @import("readline.zig");
const prompt = @import("prompt.zig");
const history = @import("history.zig");

const parser = @import("parser.zig");
const Lexer = parser.Lexer;
const Token = parser.Token;
const TokenCat = parser.TokenCat;
const Parser = parser.Parser;
const Sexp = parser.Sexp;

const version = build_options.version;

// =============================================================================
// MAIN
// =============================================================================

pub fn main() !u8 {
    setupSignals();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            std.debug.print("slash: memory leaks detected\n", .{});
        }
    }
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var show_tokens = false;
    var show_sexp = false;
    var command_string: ?[]const u8 = null;
    var script_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            showHelp();
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("slash {s}\n", .{version});
            return 0;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tokens")) {
            show_tokens = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sexp")) {
            show_sexp = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) {
                command_string = args[i];
            } else {
                std.debug.print("Error: -c requires a command string\n", .{});
                return 1;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            script_path = arg;
            i += 1;
            break; // remaining args are script arguments
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            showHelp();
            return 1;
        }
    }

    // -c "command" mode
    if (command_string) |cmd| {
        if (show_tokens) {
            dumpTokens(cmd, "<cmd>");
            return 0;
        }
        if (show_sexp) {
            dumpSexp(alloc, cmd, .oneline);
            return 0;
        }
        var ev = exec.Shell.init(alloc);
        defer ev.deinit();
        ev.execLine(cmd);
        return ev.last_exit;
    }

    // Script mode
    if (script_path) |path| {
        const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Error reading '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        defer alloc.free(source);

        if (show_tokens) {
            dumpTokens(source, path);
            return 0;
        }
        if (show_sexp) {
            dumpSexp(alloc, source, .program);
            return 0;
        }
        var ev = exec.Shell.init(alloc);
        defer ev.deinit();
        ev.setScriptPath(path);
        if (i < args.len) ev.setArgs(args[i..]);
        ev.execSource(source);
        return ev.last_exit;
    }

    // Interactive REPL
    if (show_tokens or show_sexp) {
        std.debug.print("Error: --tokens/--sexp require a file or -c command\n", .{});
        return 1;
    }

    var ev = exec.Shell.init(alloc);
    defer ev.deinit();
    ev.initInteractive();
    try runRepl(alloc, &ev);
    return ev.last_exit;
}

// =============================================================================
// REPL
// =============================================================================

var repl_shell: ?*exec.Shell = null;

fn keyLookup(combo: []const u8) ?[]const u8 {
    if (repl_shell) |sh| return sh.lookupKeyBinding(combo);
    return null;
}

fn evalMathPreview(expr: []const u8) ?[]const u8 {
    if (repl_shell) |sh| return sh.tryEvalMath(expr);
    return null;
}

fn historySuggest(prefix: []const u8) ?[]const u8 {
    if (repl_shell) |sh| {
        if (sh.history_db) |hdb| return hdb.suggest(sh.allocator, prefix);
    }
    return null;
}

fn historySearchFn(alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 {
    if (repl_shell) |sh| {
        if (sh.history_db) |hdb| return hdb.search(alloc, query, limit);
    }
    return &.{};
}

fn needsContinuation(line: []const u8) bool {
    return @import("lexer.zig").lineNeedsContinuation(line);
}

var user_cmd_names_buf: [512][]const u8 = undefined;

fn getUserCmdNames() []const []const u8 {
    if (repl_shell) |sh| {
        var it = sh.user_cmds.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            if (i >= user_cmd_names_buf.len) break;
            user_cmd_names_buf[i] = entry.key_ptr.*;
            i += 1;
        }
        return user_cmd_names_buf[0..i];
    }
    return &.{};
}

var shell_var_names_buf: [512][]const u8 = undefined;

fn getShellVarNames() []const []const u8 {
    if (repl_shell) |sh| {
        var it = sh.vars.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            if (i >= shell_var_names_buf.len) break;
            shell_var_names_buf[i] = entry.key_ptr.*;
            i += 1;
        }
        return shell_var_names_buf[0..i];
    }
    return &.{};
}

fn keyExec(cmd: []const u8) void {
    if (repl_shell) |sh| {
        const source = sh.allocator.dupeZ(u8, cmd) catch return;
        defer sh.allocator.free(source);
        sh.execLine(source);
    }
}

fn runRepl(alloc: std.mem.Allocator, ev: *exec.Shell) !void {
    if (std.posix.getenv("HOME")) |home| {
        var path_buf: [4096]u8 = undefined;
        const rc = std.fmt.bufPrint(&path_buf, "{s}/.slashrc", .{home}) catch null;
        if (rc) |p| ev.sourceFile(p);
    }

    repl_shell = ev;
    readline.setKeyHandler(.{ .lookup = &keyLookup, .exec = &keyExec, .search = &historySearchFn, .suggest = &historySuggest, .eval_math = &evalMathPreview, .user_cmd_names = &getUserCmdNames, .shell_var_names = &getShellVarNames });

    const hdb = history.Db.open() catch null;
    defer if (hdb) |h| h.close();
    ev.history_db = hdb;

    var hist = readline.History.init(alloc);
    defer hist.deinit();
    var last_duration_ms: u64 = 0;

    while (true) {
        ev.reapAndReport();
        const fmt = if (ev.lookupScopedValue("PROMPT")) |val|
            switch (val) {
                .scalar => |text| text,
                .argv => prompt.default_fmt,
            }
        else
            prompt.default_fmt;
        const ctx = prompt.Context{ .last_exit = ev.last_exit, .duration_ms = last_duration_ms };
        const ps = prompt.render(fmt, ctx);
        const line = readline.readLineEx(ps.str, ps.visible_len, &hist) orelse return;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "=")) {
            std.debug.print("\x1b[A\r\x1b[K", .{});
            continue;
        }

        // Bare digit 1-9: jump to j-list entry
        if (trimmed.len == 1 and trimmed[0] >= '1' and trimmed[0] <= '9') {
            ev.builtinJumpTo(trimmed[0] - '1');
            continue;
        }

        if (std.mem.eql(u8, trimmed, "exit")) {
            var has_jobs = false;
            for (&ev.jobs) |slot| {
                if (slot != null) { has_jobs = true; break; }
            }
            if (has_jobs) {
                std.debug.print("slash: there are running or stopped jobs\n", .{});
                ev.reapAndReport();
                continue;
            }
            return;
        }

        // Multi-line continuation: if line needs a block, collect more lines until blank
        var multi_buf: std.ArrayList(u8) = .empty;
        defer multi_buf.deinit(alloc);
        multi_buf.appendSlice(alloc, trimmed) catch {};

        if (needsContinuation(trimmed)) {
            while (true) {
                const cont = readline.readLine("... ", &hist) orelse break;
                const ct = std.mem.trim(u8, cont, " \t\r");
                if (ct.len == 0) break;
                multi_buf.append(alloc, '\n') catch {};
                multi_buf.appendSlice(alloc, cont) catch {};
            }
            multi_buf.append(alloc, '\n') catch {};
        }

        const full_line = multi_buf.items;
        hist.add(full_line);

        const source = try alloc.dupeZ(u8, full_line);
        defer alloc.free(source);

        const t0 = std.time.milliTimestamp();
        if (std.mem.indexOfScalar(u8, full_line, '\n') != null)
            ev.execSource(source)
        else
            ev.execLine(source);
        const t1 = std.time.milliTimestamp();
        last_duration_ms = @intCast(@max(0, t1 - t0));

        if (exec.Shell.exit_requested) return;

        if (hdb) |h| {
            if (full_line.len == 0 or full_line[0] != ' ') {
                var cwd_buf: [4096]u8 = undefined;
                const cwd = std.posix.getcwd(&cwd_buf) catch "";
                h.record(full_line, cwd, ev.last_exit, last_duration_ms);
            }
        }
    }
}

// =============================================================================
// TOKEN DUMP
// =============================================================================

fn dumpTokens(source: []const u8, label: []const u8) void {
    std.debug.print("--- tokens: {s} ---\n", .{label});

    var lex = Lexer.init(source);
    while (true) {
        const tok = lex.next();
        std.debug.print("{s:>16}  {s}\n", .{ @tagName(tok.cat), lex.text(tok) });
        if (tok.cat == .eof) break;
    }
}

// =============================================================================
// S-EXPRESSION DUMP
// =============================================================================

const ParseMode = enum { program, oneline };

fn dumpSexp(alloc: std.mem.Allocator, source: []const u8, mode: ParseMode) void {
    var p = Parser.init(alloc, source);
    defer p.deinit();

    const result = switch (mode) {
        .program => p.parseProgram(),
        .oneline => p.parseOneline(),
    } catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return;
    };

    var write_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&write_buf);
    const w = &stdout_writer.interface;
    result.write(source, w) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

// =============================================================================
// SIGNALS
// =============================================================================

fn setupSignals() void {
    const ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ign, null);
    posix.sigaction(posix.SIG.QUIT, &ign, null);
    posix.sigaction(posix.SIG.TSTP, &ign, null);
    posix.sigaction(posix.SIG.TTOU, &ign, null);
    posix.sigaction(posix.SIG.TTIN, &ign, null);
}

// =============================================================================
// HELP
// =============================================================================

fn showHelp() void {
    const help =
        \\Usage: slash [options] [script]
        \\
        \\A modern shell with Unix roots.
        \\
        \\Options:
        \\  -h, --help         Show this help
        \\  -v, --version      Show version
        \\  -t, --tokens       Dump lexer tokens
        \\  -s, --sexp         Dump parsed s-expressions
        \\  -c CMD             Execute a single command string
        \\
        \\With no arguments, starts an interactive REPL.
        \\
    ;
    std.debug.print("{s}", .{help});
}
