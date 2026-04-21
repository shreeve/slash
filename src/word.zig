//! Slash — Word layer.
//!
//! A `Word` is the lowered semantic word. `Shape` preserves source-faithful
//! bytes (with outer quotes, undecoded escapes); `Word` canonicalizes.
//!
//! Phase 1: words have exactly one text part. No variables, no command
//! substitution, no process substitution, no globs. The only work this
//! module does is strip quote delimiters and decode escapes so the Program
//! layer can carry a clean argv template.
//!
//! See PLAN.md §3.2, §6.3, §7 Rules 3–9 (argv/expansion/globbing contract).

const std = @import("std");
const shape_mod = @import("shape.zig");
const diag = @import("diagnostics.zig");

pub const Allocator = std.mem.Allocator;
pub const Span = diag.Span;

pub const Word = struct {
    parts: []const Part,
    span: Span,

    pub const Part = union(enum) {
        /// Canonicalized text — outer quotes stripped, supported escapes
        /// decoded. Phase 1 is always a single text part.
        text: []const u8,
    };
};

/// Lower a `WordShape` into a canonicalized `Word`. The returned `Word.Part`
/// bytes are allocated from `alloc` when escape decoding or quote stripping
/// produces bytes that differ from the source slice. In all other cases the
/// slice aliases the original source (no copy).
pub fn lowerWord(shape: shape_mod.WordShape, alloc: Allocator) !Word {
    // Phase 1: exactly one text part per word (enforced by shape layer).
    std.debug.assert(shape.parts.len == 1);
    const part = shape.parts[0].text;

    const canonical: []const u8 = switch (part.flavor) {
        .bare => part.bytes,
        .single_quoted => try decodeSingle(alloc, part.bytes),
        .double_quoted => try decodeDouble(alloc, part.bytes),
    };

    const parts = try alloc.alloc(Word.Part, 1);
    parts[0] = .{ .text = canonical };
    return .{ .parts = parts, .span = shape.span };
}

/// Strip outer single-quote delimiters and collapse `''` → `'`.
/// Expects `bytes` to start with `'` and end with `'`.
fn decodeSingle(alloc: Allocator, bytes: []const u8) ![]u8 {
    std.debug.assert(bytes.len >= 2 and bytes[0] == '\'' and bytes[bytes.len - 1] == '\'');
    const inner = bytes[1 .. bytes.len - 1];
    // Fast path: no doubled quotes → aliasing dupe.
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

/// Strip outer double-quote delimiters and decode recognized backslash
/// escapes. Phase 1 scope for escapes: `\"`, `\\`, `\n`, `\t`, `\r`, `\$`,
/// `\0`. Unrecognized `\x` sequences are preserved verbatim (both bytes).
/// Expects `bytes` to start with `"` and end with `"`.
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
                    // Unknown escape: keep both bytes verbatim.
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

// =============================================================================
// Tests
// =============================================================================

test "bare word aliases source bytes" {
    const alloc = std.testing.allocator;
    const span = Span{ .start = 0, .end = 3 };
    const bytes = "abc";
    const parts = try alloc.alloc(shape_mod.WordPartShape, 1);
    defer alloc.free(parts);
    parts[0] = .{ .text = .{ .bytes = bytes, .flavor = .bare, .span = span } };
    const ws = shape_mod.WordShape{ .parts = parts, .span = span };

    const w = try lowerWord(ws, alloc);
    defer alloc.free(w.parts);
    try std.testing.expectEqualStrings("abc", w.parts[0].text);
}

test "single-quoted strips delimiters and collapses doubled quotes" {
    const alloc = std.testing.allocator;
    const span = Span{ .start = 0, .end = 8 };
    const bytes = "'it''s'";
    const parts = try alloc.alloc(shape_mod.WordPartShape, 1);
    defer alloc.free(parts);
    parts[0] = .{ .text = .{ .bytes = bytes, .flavor = .single_quoted, .span = span } };
    const ws = shape_mod.WordShape{ .parts = parts, .span = span };

    const w = try lowerWord(ws, alloc);
    defer alloc.free(w.parts);
    defer alloc.free(w.parts[0].text);
    try std.testing.expectEqualStrings("it's", w.parts[0].text);
}

test "double-quoted decodes basic escapes" {
    const alloc = std.testing.allocator;
    const span = Span{ .start = 0, .end = 14 };
    const bytes = "\"a\\n\\tb\\\"c\"";
    const parts = try alloc.alloc(shape_mod.WordPartShape, 1);
    defer alloc.free(parts);
    parts[0] = .{ .text = .{ .bytes = bytes, .flavor = .double_quoted, .span = span } };
    const ws = shape_mod.WordShape{ .parts = parts, .span = span };

    const w = try lowerWord(ws, alloc);
    defer alloc.free(w.parts);
    defer alloc.free(w.parts[0].text);
    try std.testing.expectEqualStrings("a\n\tb\"c", w.parts[0].text);
}
