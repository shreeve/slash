//! Word — the lowered semantic word.
//!
//! Shape preserves source-faithful bytes (with outer quotes, undecoded
//! escapes); Word canonicalizes. A word is an ordered list of typed parts:
//! text, variable references, command substitutions, and globs. Final
//! argv strings are produced at evaluation time by expanding each part.

const std = @import("std");
const shape_mod = @import("shape.zig");
const program_mod = @import("program.zig");
const diag = @import("diagnostics.zig");

pub const Allocator = std.mem.Allocator;
pub const Span = diag.Span;

pub const Word = struct {
    parts: []const Part,
    span: Span,

    pub const Part = union(enum) {
        /// Canonicalized literal bytes — outer quotes stripped, supported
        /// escapes decoded.
        text: []const u8,
        /// Variable reference by bare name (`$name`, or `0..9`/`@`/`#`/`?`/`$`/`!`/`*`).
        variable: []const u8,
        /// Braced variable reference (`${name}` or `${name ?? default}`).
        /// `default` is the lowered Word evaluated only when the named
        /// variable resolves to an unset or empty value (PLAN §12).
        var_braced: VarBraced,
        /// Command substitution capturing the program's stdout as one
        /// scalar field (PLAN §7 Rule 29).
        cmd_subst: *const program_mod.Program,
        /// List capture (`@(...)`): the program's stdout splits on `\n`
        /// and each non-empty field becomes one argv entry. The
        /// distinct surface form keeps `$(...)` honest as a scalar form.
        list_capture: *const program_mod.Program,
        /// Process substitution. Materializes as `/dev/fd/N` at
        /// expansion time; the inner program runs as a side child
        /// connected to that fd (PLAN §6.2 / §7 Rule 25).
        proc_subst: ProcSubst,
        /// Glob pattern from an unquoted bare word containing `*`/`?`/`[...]`.
        glob: []const u8,
    };

    pub const ProcSubst = struct {
        dir: shape_mod.ProcSubstDir,
        body: *const program_mod.Program,
    };

    pub const VarBraced = struct {
        name: []const u8,
        default: ?*const Word,
    };
};

pub fn lowerWord(
    word_shape: shape_mod.WordShape,
    ctx: *const program_mod.LowerContext,
) !Word {
    var parts = try ctx.alloc.alloc(Word.Part, word_shape.parts.len);
    for (word_shape.parts, 0..) |part, i| {
        parts[i] = try lowerPart(part, ctx);
    }
    return .{ .parts = parts, .span = word_shape.span };
}

fn lowerPart(
    part: shape_mod.WordPartShape,
    ctx: *const program_mod.LowerContext,
) !Word.Part {
    return switch (part) {
        .text => |t| blk: {
            const out = if (t.cooked)
                try ctx.alloc.dupe(u8, t.bytes)
            else
                try canonicalizeText(t.bytes, t.flavor, ctx.alloc);
            // Per PLAN §7 Rule 9: globbing applies only to unquoted literal
            // parts. A bare-flavored text run containing `*` or `?` is
            // promoted to a `.glob` part so eval-time expansion can apply
            // filesystem matching. Quoted text (sq/dq) is never globbed.
            if (t.flavor == .bare and containsGlobMeta(out)) {
                break :blk Word.Part{ .glob = out };
            }
            break :blk Word.Part{ .text = out };
        },
        .variable => |v| Word.Part{ .variable = try ctx.alloc.dupe(u8, v.name) },
        .var_braced => |v| try lowerVarBraced(v.body, v.span, ctx),
        .cmd_subst => |c| blk: {
            const inner = try program_mod.lower(c.body.*, ctx, null);
            break :blk Word.Part{ .cmd_subst = inner };
        },
        .list_capture => |c| blk: {
            const inner = try program_mod.lower(c.body.*, ctx, null);
            break :blk Word.Part{ .list_capture = inner };
        },
        .proc_subst => |ps| blk: {
            const inner = try program_mod.lower(ps.body.*, ctx, null);
            break :blk Word.Part{ .proc_subst = .{ .dir = ps.dir, .body = inner } };
        },
        .glob => |g| Word.Part{ .glob = try ctx.alloc.dupe(u8, g.pattern) },
    };
}

fn containsGlobMeta(bytes: []const u8) bool {
    for (bytes) |c| switch (c) {
        '*', '?' => return true,
        else => {},
    };
    return false;
}

// =============================================================================
// `${name}` / `${name ?? default}` lowering
// =============================================================================
//
// The body bytes of `${...}` come straight from the lexer with no inner
// parsing; the splitter here promotes them to a structured `VarBraced`.
// The body's name is required (everything up to optional `??`); the
// default — if present — is itself parsed as a Word. Defaults support
// literal text, escape decoding (`\n`, `\t`, `\$`, ...), bare and special
// variable references (`$name`, `$?`, `$@`, ...), and double-quoted/
// single-quoted segments. They do not nest another `${...}` form; that
// would require feeding bytes back through the main parser and is out of
// scope for the narrow PLAN §12 form.

fn lowerVarBraced(
    body: []const u8,
    span: shape_mod.Span,
    ctx: *const program_mod.LowerContext,
) !Word.Part {
    if (findFallbackOp(body)) |idx| {
        const name = std.mem.trim(u8, body[0..idx], " \t");
        const default_text = std.mem.trim(u8, body[idx + 2 ..], " \t");
        const default_word = try parseDefaultWord(default_text, span, ctx.alloc);
        return .{ .var_braced = .{
            .name = try ctx.alloc.dupe(u8, name),
            .default = default_word,
        } };
    }
    const name = std.mem.trim(u8, body, " \t");
    return .{ .var_braced = .{
        .name = try ctx.alloc.dupe(u8, name),
        .default = null,
    } };
}

/// Find the first `??` operator outside of any quoted region. Returns
/// the byte index of the first `?`, or null if no fallback operator is
/// present in the body.
fn findFallbackOp(body: []const u8) ?usize {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"' or c == '\'') {
            const quote = c;
            i += 1;
            while (i < body.len and body[i] != quote) {
                if (quote == '"' and body[i] == '\\' and i + 1 < body.len) i += 1;
                i += 1;
            }
            if (i < body.len) i += 1;
            continue;
        }
        if (c == '?' and i + 1 < body.len and body[i + 1] == '?') return i;
        i += 1;
    }
    return null;
}

fn parseDefaultWord(
    text: []const u8,
    span: shape_mod.Span,
    alloc: Allocator,
) !*const Word {
    var parts = std.ArrayListUnmanaged(Word.Part).empty;
    defer parts.deinit(alloc);

    var text_buf = std.ArrayListUnmanaged(u8).empty;
    defer text_buf.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (c == '\\' and i + 1 < text.len) {
            const decoded: u8 = switch (text[i + 1]) {
                '\\' => '\\',
                '$' => '$',
                '"' => '"',
                '\'' => '\'',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => {
                    try text_buf.append(alloc, c);
                    try text_buf.append(alloc, text[i + 1]);
                    i += 2;
                    continue;
                },
            };
            try text_buf.append(alloc, decoded);
            i += 2;
            continue;
        }

        if (c == '\'') {
            // Single-quoted: literal up to the next `'`. No interpolation.
            i += 1;
            while (i < text.len and text[i] != '\'') {
                try text_buf.append(alloc, text[i]);
                i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }

        if (c == '"') {
            // Double-quoted: same escape table as bare context, plus the
            // contained `$name` / `$?` etc. interpolate. Closes at the
            // next unescaped `"`.
            i += 1;
            while (i < text.len and text[i] != '"') {
                if (text[i] == '\\' and i + 1 < text.len) {
                    const dn: u8 = switch (text[i + 1]) {
                        '\\' => '\\',
                        '$' => '$',
                        '"' => '"',
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '0' => 0,
                        else => {
                            try text_buf.append(alloc, text[i]);
                            try text_buf.append(alloc, text[i + 1]);
                            i += 2;
                            continue;
                        },
                    };
                    try text_buf.append(alloc, dn);
                    i += 2;
                    continue;
                }
                if (text[i] == '$' and i + 1 < text.len) {
                    if (consumeVarRef(text, i, alloc, &parts, &text_buf)) |new_i| {
                        i = new_i;
                        continue;
                    }
                }
                try text_buf.append(alloc, text[i]);
                i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }

        if (c == '$' and i + 1 < text.len) {
            if (consumeVarRef(text, i, alloc, &parts, &text_buf)) |new_i| {
                i = new_i;
                continue;
            }
        }

        try text_buf.append(alloc, c);
        i += 1;
    }

    if (text_buf.items.len > 0) {
        try parts.append(alloc, .{ .text = try alloc.dupe(u8, text_buf.items) });
    }

    if (parts.items.len == 0) {
        try parts.append(alloc, .{ .text = try alloc.dupe(u8, "") });
    }

    const word = try alloc.create(Word);
    word.* = .{
        .parts = try parts.toOwnedSlice(alloc),
        .span = span,
    };
    return word;
}

/// Try to consume a variable reference at `text[at]` (which must be `$`).
/// On success, flush any pending text run, append a `.variable` part, and
/// return the new offset. On failure (not a recognized var prefix), return
/// null so the caller can fall through to literal handling.
fn consumeVarRef(
    text: []const u8,
    at: usize,
    alloc: Allocator,
    parts: *std.ArrayListUnmanaged(Word.Part),
    text_buf: *std.ArrayListUnmanaged(u8),
) ?usize {
    const next = text[at + 1];
    if (isVarStart(next)) {
        var j = at + 2;
        while (j < text.len and isVarCont(text[j])) : (j += 1) {}
        flushPendingText(parts, text_buf, alloc) catch return null;
        const name = alloc.dupe(u8, text[at + 1 .. j]) catch return null;
        parts.append(alloc, .{ .variable = name }) catch return null;
        return j;
    }
    if (isSpecialVarChar(next)) {
        flushPendingText(parts, text_buf, alloc) catch return null;
        const name = alloc.dupe(u8, text[at + 1 .. at + 2]) catch return null;
        parts.append(alloc, .{ .variable = name }) catch return null;
        return at + 2;
    }
    return null;
}

fn flushPendingText(
    parts: *std.ArrayListUnmanaged(Word.Part),
    text_buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
) !void {
    if (text_buf.items.len == 0) return;
    const cooked = try alloc.dupe(u8, text_buf.items);
    try parts.append(alloc, .{ .text = cooked });
    text_buf.clearRetainingCapacity();
}

fn isVarStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isVarCont(c: u8) bool {
    return isVarStart(c) or (c >= '0' and c <= '9');
}

fn isSpecialVarChar(c: u8) bool {
    return switch (c) {
        '0'...'9', '?', '#', '@', '!', '*', '$' => true,
        else => false,
    };
}

fn canonicalizeText(bytes: []const u8, flavor: shape_mod.Flavor, alloc: Allocator) ![]const u8 {
    return switch (flavor) {
        .bare => alloc.dupe(u8, bytes),
        .single_quoted => decodeSingle(alloc, bytes),
        .double_quoted => decodeDouble(alloc, bytes),
    };
}

fn decodeSingle(alloc: Allocator, bytes: []const u8) ![]u8 {
    std.debug.assert(bytes.len >= 2 and bytes[0] == '\'' and bytes[bytes.len - 1] == '\'');
    const inner = bytes[1 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\'') == null) return alloc.dupe(u8, inner);
    var out = try alloc.alloc(u8, inner.len);
    var w: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        out[w] = c;
        w += 1;
        if (c == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') i += 1;
    }
    return alloc.realloc(out, w);
}

fn decodeDouble(alloc: Allocator, bytes: []const u8) ![]u8 {
    std.debug.assert(bytes.len >= 2 and bytes[0] == '"' and bytes[bytes.len - 1] == '"');
    const inner = bytes[1 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return alloc.dupe(u8, inner);
    var out = try alloc.alloc(u8, inner.len);
    var w: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            const n = inner[i + 1];
            const decoded: u8 = switch (n) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '$' => '$',
                '0' => 0,
                else => {
                    out[w] = c;
                    w += 1;
                    out[w] = n;
                    w += 1;
                    i += 2;
                    continue;
                },
            };
            out[w] = decoded;
            w += 1;
            i += 2;
            continue;
        }
        out[w] = c;
        w += 1;
        i += 1;
    }
    return alloc.realloc(out, w);
}
