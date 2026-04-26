//! Slash language module — Tag enum, keyword promotion, lexer wrapper.
//!
//! The lexer wrapper around the generated `BaseLexer` adds three responsibilities
//! that would clutter the grammar if done declaratively:
//!
//!   1. Comment trivia is dropped at the lexer boundary so the parser never
//!      sees it.
//!
//!   2. `IDENT '='` (no whitespace between, and no second `=` immediately
//!      after) fuses into a single `NAME_EQ` token. This is what makes
//!      env-prefix `FOO=bar cmd` and standalone assignment `x=5` work
//!      without LR(1) ambiguity. Loose `x = 5` parses as a command (`x`
//!      with args `=` and `5`); the shell rejects it with a clear "command
//!      not found".
//!
//!   3. Indentation tracks a stack of column levels and emits virtual
//!      `INDENT`/`OUTDENT` tokens at level changes. Spaces only — a tab
//!      in indentation is a hard error. The stack is suspended inside
//!      `(`, `{`, and `[` so multi-line bracketed forms aren't disrupted.
//!      Brace blocks `{ ... }` and indented blocks share one `block_form`
//!      production in the grammar, so `if cmd { body }` and
//!      `if cmd\n  body` produce the same Shape.

const std = @import("std");
const parser = @import("parser.zig");
pub const Token = parser.Token;
pub const TokenCat = parser.TokenCat;
const BaseLexer = parser.BaseLexer;

// =============================================================================
// Tag enum — every s-expression head emitted by the parser
// =============================================================================

pub const Tag = enum(u8) {
    // ---- Compound ----
    sequence,
    seq_always,
    seq_and,
    seq_or,
    seq_bg,
    pipeline,
    command,
    subshell,
    block,
    redirects,

    // ---- Words ----
    word,
    @"var",
    var_braced,
    cmd_subst,
    list_capture,
    scalar,
    list,
    words,

    // ---- Assignment / env-prefix ----
    env_binds,
    env_bind,
    assigns,

    // ---- Control flow ----
    @"if",
    @"else",
    elif,
    body,
    cond_and,
    cond_or,
    @"while",
    @"for",
    cmd_def,

    // ---- Redirects ----
    redir_read,
    redir_read_fd,
    redir_write,
    redir_write_fd,
    redir_append,
    redir_both,
    redir_both_append,
    redir_dup_out,
    redir_dup_in,
};

// =============================================================================
// Keyword promotion
// =============================================================================
//
// `@as ident = [keyword]` in the grammar invokes `keywordAs` for every IDENT
// lookahead. The returned `KeywordId` is mapped by the generated parser to
// the actual symbol id; if that symbol is legal in the current state, the
// IDENT is promoted to the keyword token and shifted.

pub const KeywordId = enum(u16) {
    IF,
    ELSE,
    WHILE,
    FOR,
    IN,
    CMD,
};

const keyword_map = std.StaticStringMap(KeywordId).initComptime(.{
    .{ "if", .IF },
    .{ "else", .ELSE },
    .{ "while", .WHILE },
    .{ "for", .FOR },
    .{ "in", .IN },
    .{ "cmd", .CMD },
});

pub fn keywordAs(text: []const u8) ?KeywordId {
    return keyword_map.get(text);
}

// =============================================================================
// Lexer wrapper
// =============================================================================

pub const Lexer = struct {
    base: BaseLexer,

    // Indentation tracking
    indent_level: u32 = 0,
    indent_stack: [64]u32 = [_]u32{0} ** 64,
    indent_depth: u8 = 0,
    pending_outdents: u8 = 0,
    queued: ?Token = null,
    last_cat: TokenCat = .eof,

    pub fn init(source: []const u8) Lexer {
        return .{ .base = BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.base.reset();
        self.indent_level = 0;
        self.indent_depth = 0;
        self.pending_outdents = 0;
        self.queued = null;
        self.last_cat = .eof;
    }

    pub fn next(self: *Lexer) Token {
        // Drain any queued virtual tokens first.
        if (self.queued) |q| {
            self.queued = null;
            self.last_cat = q.cat;
            return q;
        }
        if (self.pending_outdents > 0) {
            self.pending_outdents -= 1;
            const t = Token{
                .cat = .outdent,
                .pre = 0,
                .pos = @intCast(self.base.pos),
                .len = 0,
            };
            self.last_cat = .outdent;
            return t;
        }

        while (true) {
            const tok = self.base.next();

            // Drop comment trivia.
            if (tok.cat == .comment) continue;

            // Newlines: maybe become INDENT, OUTDENT(s), or stay as semi.
            if (tok.cat == .semi and self.isNewlineToken(tok)) {
                if (self.handleNewline(tok)) |result| {
                    // Suppress a leading-of-block SEMI: `{`/`INDENT` followed
                    // by a newline shouldn't manifest as a stray sequence
                    // separator before the first body statement.
                    if (result.cat == .semi and isBlockOpener(self.last_cat)) {
                        continue;
                    }
                    self.last_cat = result.cat;
                    return result;
                }
                continue;
            }

            // Drop SEMIs immediately following SEMIs (collapses a run of
            // newlines into a single statement separator).
            if (tok.cat == .semi and self.last_cat == .semi) continue;

            // EOF: flush any open indentation as OUTDENTs.
            if (tok.cat == .eof) {
                if (self.indent_depth > 0) {
                    self.pending_outdents = self.indent_depth - 1;
                    self.indent_depth = 0;
                    self.indent_level = 0;
                    self.queued = tok;
                    self.last_cat = .outdent;
                    return Token{
                        .cat = .outdent,
                        .pre = 0,
                        .pos = tok.pos,
                        .len = 0,
                    };
                }
                self.last_cat = .eof;
                return tok;
            }

            // NAME_EQ fusion: IDENT immediately followed by `=` (no whitespace
            // between) and not followed by another `=`. Fuse into one
            // NAME_EQ token whose source slice covers `name=`. The Shape
            // converter strips the trailing `=` to recover the bare name.
            if (tok.cat == .ident) {
                const after = tok.pos + tok.len;
                if (after < self.base.source.len and
                    self.base.source[after] == '=' and
                    (after + 1 >= self.base.source.len or
                        self.base.source[after + 1] != '='))
                {
                    self.base.pos = after + 1;
                    var fused = tok;
                    fused.cat = .name_eq;
                    fused.len += 1;
                    self.last_cat = .name_eq;
                    return fused;
                }
            }

            // Special-parameter variables: `$?`, `$$`, `$#`, `$@`, `$!`, `$*`.
            // The base lexer's auto-generated `$...` handling covers `${name}`,
            // `$alpha+`, and `$digit`, but doesn't cover the special params.
            // Fuse them in the wrapper from the err+`$` shape.
            if (tok.cat == .err and tok.len == 1 and
                tok.pos < self.base.source.len and
                self.base.source[tok.pos] == '$' and
                tok.pos + 1 < self.base.source.len)
            {
                const next_ch = self.base.source[tok.pos + 1];
                if (next_ch == '?' or next_ch == '#' or next_ch == '@' or
                    next_ch == '!' or next_ch == '*' or next_ch == '$')
                {
                    self.base.pos = tok.pos + 2;
                    var t = tok;
                    t.cat = .variable;
                    t.len = 2;
                    self.last_cat = .variable;
                    return t;
                }
            }

            // List-capture fusion: a bare `@` immediately followed by `(`
            // has to become a single `at_paren` token. The grammar says
            // so, but the auto-generated lexer dispatches LETTER-class
            // bytes (`@` is one) into `scanIdent` before reaching the
            // operator switch, so `@(` arrives here as an `ident` of
            // length 1 trailed by an `lparen`. Recover.
            if (tok.cat == .ident and tok.len == 1 and
                self.base.source[tok.pos] == '@' and
                tok.pos + 1 < self.base.source.len and
                self.base.source[tok.pos + 1] == '(')
            {
                self.base.pos = tok.pos + 2;
                self.base.paren += 1;
                var t = tok;
                t.cat = .at_paren;
                t.len = 2;
                self.last_cat = .at_paren;
                return t;
            }

            // Track bracket depth for indent suspension. The base lexer
            // already tracks `paren` and `brace` (from grammar `{paren++}`
            // actions); we add `bracket` here as a wrapper-side field.
            self.last_cat = tok.cat;
            return tok;
        }
    }

    fn isNewlineToken(self: *const Lexer, tok: Token) bool {
        if (tok.len == 0) return false;
        const ch = self.base.source[tok.pos];
        return ch == '\n' or ch == '\r';
    }

    /// True for tokens that introduce a block body and should swallow an
    /// immediately-following newline so the body parses cleanly.
    fn isBlockOpener(cat: TokenCat) bool {
        return switch (cat) {
            .lbrace, .lparen, .lbracket, .indent, .eof => true,
            else => false,
        };
    }

    /// Process a newline token. Returns:
    ///   - the original semi token (level unchanged)
    ///   - an INDENT token (level increased)
    ///   - an OUTDENT token, queueing more if multiple levels closed
    ///   - null to swallow (blank line; another newline will follow)
    fn handleNewline(self: *Lexer, nl: Token) ?Token {
        // Indentation is suspended inside (), {}, [] groupings.
        if (self.base.paren > 0 or self.base.brace > 0) return nl;

        // Skip blank/comment-only lines: scan past them and look at the
        // first content line's indent.
        var ws: u32 = 0;
        var p = self.base.pos;
        while (true) {
            ws = 0;
            while (p + ws < self.base.source.len) {
                const ch = self.base.source[p + ws];
                if (ch == ' ') {
                    ws += 1;
                } else if (ch == '\t') {
                    // Tabs in indentation are an error.
                    return Token{
                        .cat = .err,
                        .pre = 0,
                        .pos = @intCast(p + ws),
                        .len = 1,
                    };
                } else break;
            }
            if (p + ws >= self.base.source.len) {
                ws = 0;
                break; // EOF after whitespace
            }
            const next_ch = self.base.source[p + ws];
            if (next_ch == '\n' or next_ch == '\r') {
                // blank line; advance past and try again
                p = p + ws + 1;
                continue;
            }
            if (next_ch == '#') {
                // comment-only line; advance past comment + newline
                var q = p + ws;
                while (q < self.base.source.len and self.base.source[q] != '\n')
                    q += 1;
                if (q < self.base.source.len) q += 1;
                p = q;
                continue;
            }
            break;
        }

        const at_eof = p + ws >= self.base.source.len;

        if (!at_eof and ws > self.indent_level) {
            // Indent in: push current level, set new level, emit INDENT.
            if (self.indent_depth >= 63) return nl;
            self.indent_stack[self.indent_depth] = self.indent_level;
            self.indent_depth += 1;
            self.indent_level = ws;
            // Suppress the original newline; INDENT acts as the boundary.
            return Token{
                .cat = .indent,
                .pre = 0,
                .pos = nl.pos,
                .len = 0,
            };
        }

        if (ws < self.indent_level) {
            // Indent out: pop levels until we match. Emit OUTDENT(s),
            // followed by the original newline UNLESS the next non-
            // whitespace identifier is `else` — in that case the newline
            // is suppressed so the conditional flows naturally.
            var count: u8 = 0;
            var lvl = self.indent_level;
            while (lvl > ws) {
                if (self.indent_depth == 0) break;
                self.indent_depth -= 1;
                lvl = self.indent_stack[self.indent_depth];
                count += 1;
            }
            if (lvl != ws and !at_eof) {
                return Token{
                    .cat = .err,
                    .pre = 0,
                    .pos = nl.pos,
                    .len = 0,
                };
            }
            self.indent_level = ws;
            if (count > 0) {
                if (!sourceStartsWithElse(self.base.source, p + ws)) {
                    self.queued = nl;
                }
                self.pending_outdents = count - 1;
                return Token{
                    .cat = .outdent,
                    .pre = 0,
                    .pos = nl.pos,
                    .len = 0,
                };
            }
        }

        // Same level — original newline acts as statement separator.
        return nl;
    }
};

/// Continuation bytes of the bare-word class (matching the grammar's
/// ident rule: `[A-Za-z_./\-+~@%!*?:,^][A-Za-z0-9_./\-+~@%!*?:,^]*`).
fn isBareWordContinue(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9',
        '_', '.', '/', '-', '+', '~', '@', '%', '!', '*', '?', ':', ',', '^',
        => true,
        else => false,
    };
}

/// True if `source[pos..]` begins with the keyword `else` followed by a
/// non-identifier byte (so `elseif` doesn't match). Free helper because
/// it's pure source inspection with no Lexer state.
fn sourceStartsWithElse(source: []const u8, pos: usize) bool {
    if (pos + 4 > source.len) return false;
    if (!std.mem.eql(u8, source[pos .. pos + 4], "else")) return false;
    if (pos + 4 == source.len) return true;
    const next = source[pos + 4];
    return next == ' ' or next == '\t' or next == '\n' or
        next == '\r' or next == '{' or next == '#';
}
