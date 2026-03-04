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

pub fn main() !void {
    setupSignals();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
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
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("slash {s}\n", .{version});
            return;
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
                return;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            script_path = arg;
            i += 1;
            break; // remaining args are script arguments
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            showHelp();
            return;
        }
    }

    // -c "command" mode
    if (command_string) |cmd| {
        if (show_tokens) {
            dumpTokens(cmd, "<cmd>");
            return;
        }
        if (show_sexp) {
            dumpSexp(alloc, cmd, .oneline);
            return;
        }
        var ev = exec.Shell.init(alloc);
        defer ev.deinit();
        ev.execLine(cmd);
        return;
    }

    // Script mode
    if (script_path) |path| {
        const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Error reading '{s}': {s}\n", .{ path, @errorName(err) });
            return;
        };
        defer alloc.free(source);

        if (show_tokens) {
            dumpTokens(source, path);
            return;
        }
        if (show_sexp) {
            dumpSexp(alloc, source, .program);
            return;
        }
        var ev = exec.Shell.init(alloc);
        defer ev.deinit();
        if (i < args.len) ev.setArgs(args[i..]);
        ev.execSource(source);
        return;
    }

    // Interactive REPL
    if (show_tokens or show_sexp) {
        std.debug.print("Error: --tokens/--sexp require a file or -c command\n", .{});
        return;
    }

    var ev = exec.Shell.init(alloc);
    defer ev.deinit();
    ev.initInteractive();
    try runRepl(alloc, &ev);
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

fn paletteFn(alloc: std.mem.Allocator, query: []const u8) []readline.PaletteResult {
    var results: std.ArrayList(readline.PaletteResult) = .empty;
    if (repl_shell) |sh| {
        // History results
        if (sh.history_db) |hdb| {
            const hist_results = hdb.search(alloc, query, 5);
            for (hist_results) |cmd| {
                results.append(alloc, .{ .text = cmd, .kind = .history }) catch {};
            }
        }
        // Directory results
        if (sh.history_db) |hdb| {
            const dir_results = hdb.frecency(alloc, query, 3);
            for (dir_results) |d| {
                results.append(alloc, .{ .text = d.path, .kind = .directory }) catch {};
            }
        }
        // User command results
        var it = sh.user_cmds.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (query.len == 0 or std.mem.indexOf(u8, name, query) != null) {
                results.append(alloc, .{ .text = name, .kind = .command }) catch {};
            }
        }
    }
    return results.items;
}

fn historySearchFn(alloc: std.mem.Allocator, query: []const u8, limit: usize) [][]const u8 {
    if (repl_shell) |sh| {
        if (sh.history_db) |hdb| return hdb.search(alloc, query, limit);
    }
    return &.{};
}

fn needsContinuation(line: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, line, " \t");
    if (trimmed.len == 0) return false;

    // Backslash continuation
    if (trimmed[trimmed.len - 1] == '\\') return true;

    // Open brace without close
    var brace_depth: i32 = 0;
    for (trimmed) |ch| {
        if (ch == '{') brace_depth += 1;
        if (ch == '}') brace_depth -= 1;
    }
    if (brace_depth > 0) return true;

    // Lines starting with block keywords that don't have a body on this line
    const block_keywords = [_][]const u8{ "if", "unless", "for", "while", "until", "try" };
    for (block_keywords) |kw| {
        if (std.mem.startsWith(u8, trimmed, kw) and
            (trimmed.len == kw.len or trimmed[kw.len] == ' ' or trimmed[kw.len] == '\t'))
        {
            // Has a brace block on this line? No continuation needed.
            if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
            return true;
        }
    }
    // "else" at end of line (after closing brace or standalone)
    if (std.mem.endsWith(u8, trimmed, " else") or std.mem.eql(u8, trimmed, "else")) return true;

    // cmd definition with params: cmd name(...) or cmd name
    if (trimmed.len > 4 and std.mem.startsWith(u8, trimmed, "cmd ")) {
        if (trimmed[trimmed.len - 1] == ')') return true;
        // cmd name (no body on this line — check it's not cmd name -)
        if (trimmed[trimmed.len - 1] != '-') {
            const after_cmd = std.mem.trimLeft(u8, trimmed[4..], " \t");
            // If it's just "cmd name" with no operators, it needs a body
            for (after_cmd) |ch| {
                if (ch == '{' or ch == ';' or ch == '|') return false;
            }
            return true;
        }
    }

    return false;
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
    readline.setKeyHandler(.{ .lookup = &keyLookup, .exec = &keyExec, .search = &historySearchFn, .suggest = &historySuggest, .palette = &paletteFn, .eval_math = &evalMathPreview });
    ev.recordDir();

    const hdb = history.Db.open() catch null;
    defer if (hdb) |h| h.close();
    ev.history_db = hdb;

    var hist = readline.History.init(alloc);
    var last_duration_ms: u64 = 0;

    while (true) {
        ev.reapAndReport();
        const fmt = ev.vars.get("PROMPT") orelse prompt.default_fmt;
        const ctx = prompt.Context{ .last_exit = ev.last_exit, .duration_ms = last_duration_ms };
        const ps = prompt.render(fmt, ctx);
        const line = readline.readLineEx(ps.str, ps.visible_len, &hist) orelse return;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "=")) {
            std.debug.print("\x1b[A\r\x1b[K", .{});
            continue;
        }

        if (std.mem.eql(u8, trimmed, "exit")) return;

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

        if (hdb) |h| {
            var cwd_buf: [4096]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";
            h.record(trimmed, cwd, ev.last_exit, last_duration_ms);
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
