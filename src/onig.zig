//! Oniguruma Regex Wrapper
//!
//! Thin Zig interface over the Oniguruma C API. Used by:
//!   - Generated lexer (pattern matching in next())
//!   - Evaluator (=~, !~, try pattern arms)

const std = @import("std");
const c = @cImport({
    @cInclude("oniguruma.h");
});

pub const Regex = struct {
    inner: c.OnigRegex,

    pub fn compile(pattern: []const u8) !Regex {
        var regex: c.OnigRegex = undefined;
        var einfo: c.OnigErrorInfo = undefined;
        const enc = c.ONIG_ENCODING_UTF8();
        const r = c.onig_new(
            &regex,
            pattern.ptr,
            pattern.ptr + pattern.len,
            c.ONIG_OPTION_NONE,
            enc,
            c.ONIG_SYNTAX_DEFAULT(),
            &einfo,
        );
        if (r != c.ONIG_NORMAL) return error.CompileError;
        return .{ .inner = regex };
    }

    /// Anchored match at position `pos` in `source`.
    /// Returns match length, or null if no match.
    pub fn matchAt(self: Regex, source: []const u8, pos: usize) ?usize {
        const r = c.onig_match(
            self.inner,
            source.ptr,
            source.ptr + source.len,
            source.ptr + pos,
            null,
            c.ONIG_OPTION_NONE,
        );
        if (r < 0) return null;
        return @intCast(r);
    }

    pub fn free(self: Regex) void {
        c.onig_free(self.inner);
    }
};

pub fn init() void {
    var encs = [_]c.OnigEncoding{c.ONIG_ENCODING_UTF8()};
    _ = c.onig_initialize(&encs, 1);
}

pub fn deinit() void {
    _ = c.onig_end();
}
