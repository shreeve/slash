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
        /// Braced variable reference body — interior of `${...}`.
        var_braced: []const u8,
        /// Command substitution capturing the program's stdout.
        cmd_subst: *const program_mod.Program,
        /// Glob pattern from an unquoted bare word containing `*`/`?`/`[...]`.
        glob: []const u8,
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
        .var_braced => |v| Word.Part{ .var_braced = try ctx.alloc.dupe(u8, v.body) },
        .cmd_subst => |c| blk: {
            const inner = try program_mod.lower(c.body.*, ctx, null);
            break :blk Word.Part{ .cmd_subst = inner };
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
