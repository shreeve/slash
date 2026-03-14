//! Regex — Zig wrapper over libc POSIX regex (ERE)
//!
//! Used by the executor for =~, !~, try pattern arms, and glob expansion.
//! The lexer no longer uses regex — it uses generated char-class dispatch.

const std = @import("std");
const c = @cImport(@cInclude("regex.h"));

pub const Regex = struct {
    inner: c.regex_t,

    pub fn compile(pattern: []const u8) !Regex {
        return compileWithOpts(pattern, c.REG_EXTENDED | c.REG_NOSUB);
    }

    pub fn compileIgnoreCase(pattern: []const u8) !Regex {
        return compileWithOpts(pattern, c.REG_EXTENDED | c.REG_NOSUB | c.REG_ICASE);
    }

    fn compileWithOpts(pattern: []const u8, flags: c_int) !Regex {
        var pat_buf: [4096]u8 = undefined;
        if (pattern.len >= pat_buf.len) return error.CompileError;
        @memcpy(pat_buf[0..pattern.len], pattern);
        pat_buf[pattern.len] = 0;
        var self: Regex = undefined;
        if (c.regcomp(&self.inner, @ptrCast(&pat_buf), flags) != 0)
            return error.CompileError;
        return self;
    }

    pub fn search(self: *const Regex, source: []const u8) bool {
        var buf: [8192]u8 = undefined;
        if (source.len < buf.len) {
            @memcpy(buf[0..source.len], source);
            buf[source.len] = 0;
            return c.regexec(&self.inner, @ptrCast(&buf), 0, null, 0) == 0;
        }
        const alloc = std.heap.page_allocator;
        const z = alloc.alloc(u8, source.len + 1) catch return false;
        defer alloc.free(z);
        @memcpy(z[0..source.len], source);
        z[source.len] = 0;
        return c.regexec(&self.inner, @ptrCast(z.ptr), 0, null, 0) == 0;
    }

    pub fn free(self: *Regex) void {
        c.regfree(&self.inner);
    }
};

