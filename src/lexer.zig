//! Lexer — Shell-specific lexer extensions
//!
//! Wraps the generated BaseLexer (from parser.zig) with:
//!   - Heredoc body collection and margin stripping
//!   - INDENT/OUTDENT emission for indentation blocks
//!   - Regex literal scanning (~|pattern|flags)
//!
//! The BaseLexer handles regex-based token matching (matchRules).
//! This module adds the stateful logic that can't be expressed as simple rules.

const std = @import("std");
const parser = @import("parser.zig");
pub const Token = parser.Token;
pub const TokenCat = parser.TokenCat;
const BaseLexer = parser.BaseLexer;

pub const Lexer = struct {
    base: BaseLexer,

    // Heredoc state
    hd_type: u8 = 0,
    hd_margin: u32 = 0,
    hd_scanned: bool = false,
    hd_buf: [64]Token = undefined,
    hd_buf_count: u8 = 0,
    hd_buf_pos: u8 = 0,

    // Indent state
    indent_level: u32 = 0,
    indent_stack: [64]u32 = .{0} ** 64,
    indent_depth: u8 = 0,
    indent_pending: u8 = 0,
    indent_queued: ?Token = null,
    indent_trailing_newline: bool = false,

    // Regex context
    last_cat: TokenCat = .eof,

    pub fn init(source: []const u8) Lexer {
        return .{ .base = BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.base.reset();
        self.hd_type = 0;
        self.hd_margin = 0;
        self.hd_scanned = false;
        self.hd_buf_count = 0;
        self.hd_buf_pos = 0;
        self.indent_level = 0;
        self.indent_depth = 0;
        self.indent_pending = 0;
        self.indent_queued = null;
        self.indent_trailing_newline = false;
        self.last_cat = .eof;
    }

    // Expose source for external use
    pub fn getSource(self: *const Lexer) []const u8 {
        return self.base.source;
    }

    pub fn next(self: *Lexer) Token {
        if (self.indent_queued) |q| {
            self.indent_queued = null;
            return q;
        }
        if (self.indent_pending > 0) {
            self.indent_pending -= 1;
            if (self.indent_pending == 0 and self.indent_trailing_newline) {
                self.indent_trailing_newline = false;
                self.indent_queued = Token{ .cat = .newline, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
            }
            return Token{ .cat = .outdent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        }
        if (self.hd_type == 0 and self.hd_buf_pos < self.hd_buf_count) {
            const tok = self.hd_buf[self.hd_buf_pos];
            self.hd_buf_pos += 1;
            if (self.hd_buf_pos >= self.hd_buf_count) {
                self.hd_buf_count = 0;
                self.hd_buf_pos = 0;
            }
            return tok;
        }
        if (self.hd_type != 0) {
            return self.collectHeredocLine();
        }

        // Regex context check after =~ / !~
        var ws_skip: u32 = 0;
        while (self.base.pos + ws_skip < self.base.source.len and
            (self.base.source[self.base.pos + ws_skip] == ' ' or self.base.source[self.base.pos + ws_skip] == '\t'))
            ws_skip += 1;
        const rx_pos = self.base.pos + ws_skip;
        if ((self.last_cat == .match or self.last_cat == .nomatch) and rx_pos < self.base.source.len) {
            const ch = self.base.source[rx_pos];
            if (ch == '~' and rx_pos + 1 < self.base.source.len) {
                const d = self.base.source[rx_pos + 1];
                if (!std.ascii.isAlphanumeric(d) and d != ' ' and d != '\t' and d != '\n') {
                    self.base.pos = rx_pos;
                    const result = self.collectRegex();
                    self.last_cat = result.cat;
                    return result;
                }
            } else if (!std.ascii.isAlphanumeric(ch) and ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != '$') {
                self.base.pos = rx_pos;
                const result = self.collectRegexBare();
                self.last_cat = result.cat;
                return result;
            }
        }

        // Standalone regex: ~<delim> where delim is not / or alnum (peek past whitespace)
        {
            var wp: u32 = self.base.pos;
            while (wp < self.base.source.len and (self.base.source[wp] == ' ' or self.base.source[wp] == '\t')) wp += 1;
            if (wp + 1 < self.base.source.len and self.base.source[wp] == '~') {
                const rd = self.base.source[wp + 1];
                if (!std.ascii.isAlphanumeric(rd) and rd != '/' and rd != ' ' and rd != '\t' and rd != '\n' and rd != '\r' and rd != '_') {
                    const ws_count: u8 = @intCast(@min(wp - self.base.pos, 255));
                    self.base.pos = wp;
                    var result = self.collectRegex();
                    result.pre = ws_count;
                    self.last_cat = result.cat;
                    return result;
                }
            }
        }

        // Math context: after = (assign), intercept operators and numbers that
        // would otherwise be grabbed by ident/glob/path patterns.
        if (self.base.math != 0) {
            var mp: u32 = self.base.pos;
            while (mp < self.base.source.len and (self.base.source[mp] == ' ' or self.base.source[mp] == '\t')) mp += 1;
            if (mp < self.base.source.len) {
                const mch = self.base.source[mp];
                const ws_pre: u8 = @intCast(@min(mp - self.base.pos, 255));
                if (mch == '/' or mch == '^') {
                    self.base.pos = mp + 1;
                    self.last_cat = if (mch == '/') .slash else .power;
                    return Token{ .cat = self.last_cat, .pre = ws_pre, .pos = @intCast(mp), .len = 1 };
                }
                if (mch == '*') {
                    if (mp + 1 < self.base.source.len and self.base.source[mp + 1] == '*') {
                        self.base.pos = mp + 2;
                        self.last_cat = .power;
                        return Token{ .cat = .power, .pre = ws_pre, .pos = @intCast(mp), .len = 2 };
                    }
                    self.base.pos = mp + 1;
                    self.last_cat = .star;
                    return Token{ .cat = .star, .pre = ws_pre, .pos = @intCast(mp), .len = 1 };
                }
                if (mch >= '0' and mch <= '9') {
                    var end = mp + 1;
                    while (end < self.base.source.len and self.base.source[end] >= '0' and self.base.source[end] <= '9') end += 1;
                    if (end < self.base.source.len and self.base.source[end] == '.' and
                        end + 1 < self.base.source.len and self.base.source[end + 1] >= '0' and self.base.source[end + 1] <= '9')
                    {
                        end += 1;
                        while (end < self.base.source.len and self.base.source[end] >= '0' and self.base.source[end] <= '9') end += 1;
                        self.base.pos = end;
                        self.last_cat = .real;
                        return Token{ .cat = .real, .pre = ws_pre, .pos = @intCast(mp), .len = @intCast(end - mp) };
                    }
                    self.base.pos = end;
                    self.last_cat = .integer;
                    return Token{ .cat = .integer, .pre = ws_pre, .pos = @intCast(mp), .len = @intCast(end - mp) };
                }
            }
        }

        var tok = self.base.matchRules();

        // lparen_tight is only meaningful after an ident (for cmd name(params)).
        // Everywhere else (start of line, after operators), convert to regular lparen.
        if (tok.cat == .lparen_tight and self.last_cat != .ident) {
            tok.cat = .lparen;
        }

        self.last_cat = tok.cat;

        if (tok.cat == .newline) return self.handleIndent(tok);

        if (tok.cat == .eof and self.indent_depth > 0) {
            self.indent_pending = self.indent_depth;
            self.indent_depth = 0;
            self.indent_level = 0;
            self.indent_trailing_newline = true;
            return Token{ .cat = .newline, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        }

        if (tok.cat == .heredoc_sq or tok.cat == .heredoc_dq or tok.cat == .heredoc_bt) {
            self.hd_type = switch (tok.cat) {
                .heredoc_sq => 1,
                .heredoc_dq => 2,
                .heredoc_bt => 3,
                else => 0,
            };
            self.hd_margin = 0;
            self.hd_scanned = false;
            self.hd_buf_count = 0;
            self.hd_buf_pos = 0;
            while (true) {
                const t = self.base.matchRules();
                if (t.cat == .newline or t.cat == .eof) break;
                if (self.hd_buf_count < 64) {
                    self.hd_buf[self.hd_buf_count] = t;
                    self.hd_buf_count += 1;
                }
            }
            return tok;
        }
        return tok;
    }

    fn collectHeredocLine(self: *Lexer) Token {
        if (self.base.pos >= self.base.source.len) {
            self.hd_type = 0;
            return Token{ .cat = .eof, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        }
        var ws: u32 = 0;
        while (self.base.pos + ws < self.base.source.len and
            (self.base.source[self.base.pos + ws] == ' ' or self.base.source[self.base.pos + ws] == '\t'))
            ws += 1;
        const content_start = self.base.pos + ws;
        const delim: []const u8 = switch (self.hd_type) {
            1 => "'''",
            2 => "\"\"\"",
            3 => "```",
            else => "",
        };
        if (!self.hd_scanned) {
            self.hd_scanned = true;
            var scan = self.base.pos;
            while (scan < self.base.source.len) {
                var sws: u32 = 0;
                while (scan + sws < self.base.source.len and
                    (self.base.source[scan + sws] == ' ' or self.base.source[scan + sws] == '\t'))
                    sws += 1;
                const sc = scan + sws;
                if (sc + delim.len <= self.base.source.len and std.mem.eql(u8, self.base.source[sc..][0..delim.len], delim)) {
                    self.hd_margin = sws;
                    break;
                }
                while (scan < self.base.source.len and self.base.source[scan] != '\n') scan += 1;
                if (scan < self.base.source.len) scan += 1;
            }
        }
        if (content_start + delim.len <= self.base.source.len) {
            const candidate = self.base.source[content_start..][0..delim.len];
            if (std.mem.eql(u8, candidate, delim)) {
                const after = content_start + @as(u32, @intCast(delim.len));
                const is_closing = after >= self.base.source.len or
                    self.base.source[after] == '\n' or self.base.source[after] == ' ' or
                    self.base.source[after] == '\t' or self.base.source[after] == '|' or
                    self.base.source[after] == '\r';
                if (is_closing) {
                    const close_cat: TokenCat = switch (self.hd_type) {
                        1 => .heredoc_sq,
                        2 => .heredoc_dq,
                        3 => .heredoc_end,
                        else => .err,
                    };
                    self.base.pos = after;
                    self.hd_type = 0;
                    while (self.base.pos < self.base.source.len and
                        (self.base.source[self.base.pos] == ' ' or self.base.source[self.base.pos] == '\t'))
                        self.base.pos += 1;
                    if (self.base.pos < self.base.source.len and self.base.source[self.base.pos] != '\n' and self.base.source[self.base.pos] != '\r') {
                        while (true) {
                            const t = self.base.matchRules();
                            if (t.cat == .newline) {
                                if (self.hd_buf_count < 64) { self.hd_buf[self.hd_buf_count] = t; self.hd_buf_count += 1; }
                                break;
                            }
                            if (t.cat == .eof) break;
                            if (self.hd_buf_count < 64) { self.hd_buf[self.hd_buf_count] = t; self.hd_buf_count += 1; }
                        }
                    }
                    return Token{ .cat = close_cat, .pre = @intCast(@min(ws, 255)), .pos = @intCast(content_start), .len = @intCast(delim.len) };
                }
            }
        }
        var line_end = self.base.pos;
        while (line_end < self.base.source.len and self.base.source[line_end] != '\n') line_end += 1;
        const strip = @min(ws, self.hd_margin);
        const body_start = self.base.pos + strip;
        const body_len = if (line_end > body_start) line_end - body_start else 0;
        self.base.pos = line_end;
        if (self.base.pos < self.base.source.len and self.base.source[self.base.pos] == '\n') self.base.pos += 1;
        return Token{ .cat = .heredoc_body, .pre = 0, .pos = @intCast(body_start), .len = @intCast(body_len) };
    }

    fn handleIndent(self: *Lexer, nl_tok: Token) Token {
        var ws: u32 = 0;
        while (self.base.pos + ws < self.base.source.len) {
            const ch = self.base.source[self.base.pos + ws];
            if (ch == ' ' or ch == '\t') { ws += 1; } else break;
        }
        if (self.base.pos + ws >= self.base.source.len or self.base.source[self.base.pos + ws] == '\n' or
            self.base.source[self.base.pos + ws] == '\r' or self.base.source[self.base.pos + ws] == '#')
            return nl_tok;
        if (ws > self.indent_level) {
            if (self.indent_depth < 63) {
                self.indent_stack[self.indent_depth] = self.indent_level;
                self.indent_depth += 1;
            }
            self.indent_level = ws;
            return Token{ .cat = .indent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        } else if (ws < self.indent_level) {
            var count: u8 = 0;
            while (self.indent_depth > 0 and self.indent_stack[self.indent_depth - 1] >= ws) {
                self.indent_depth -= 1;
                count += 1;
            }
            self.indent_level = ws;
            if (count > 0) {
                self.indent_pending = count;
                self.indent_trailing_newline = !self.nextTokenIsElse();
                return nl_tok;
            }
            return nl_tok;
        }
        return nl_tok;
    }

    fn nextTokenIsElse(self: *const Lexer) bool {
        var probe = self.base;
        const tok = probe.matchRules();
        return tok.cat == .ident and std.mem.eql(u8, probe.text(tok), "else");
    }

    fn collectRegexBare(self: *Lexer) Token {
        return self.scanRegex(self.base.pos);
    }

    fn collectRegex(self: *Lexer) Token {
        const start = self.base.pos;
        self.base.pos += 1;
        const result = self.scanRegex(start);
        if (result.cat == .err) self.base.pos = start + 1;
        return result;
    }

    fn scanRegex(self: *Lexer, start: u32) Token {
        const delim = self.base.source[self.base.pos];
        self.base.pos += 1;
        while (self.base.pos < self.base.source.len) {
            const ch = self.base.source[self.base.pos];
            if (ch == '\\' and self.base.pos + 1 < self.base.source.len) {
                self.base.pos += 2;
                continue;
            }
            if (ch == delim) {
                self.base.pos += 1;
                while (self.base.pos < self.base.source.len) {
                    const f = self.base.source[self.base.pos];
                    if (f == 'g' or f == 'i' or f == 'm' or f == 's' or f == 'u' or f == 'x') {
                        self.base.pos += 1;
                    } else break;
                }
                return Token{ .cat = .regex, .pre = 0, .pos = @intCast(start), .len = @intCast(self.base.pos - start) };
            }
            if (ch == '\n') break;
            self.base.pos += 1;
        }
        return Token{ .cat = .err, .pre = 0, .pos = @intCast(start), .len = 1 };
    }
};
