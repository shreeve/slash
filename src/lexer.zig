//! Slash Lexer Utilities
//!
//! Higher-level tokenization support built on top of the generated lexer
//! in parser.zig. Provides:
//!
//!   - Token stream helpers (peek, classification, source text)
//!   - Syntax highlighting categories for interactive use
//!   - Indent/outdent tracking for script mode
//!
//! The generated Lexer (in parser.zig) handles raw tokenization from the
//! grammar rules. This module adds semantic awareness specific to the
//! slash shell that the grammar engine cannot express.

const std = @import("std");
const parser = @import("parser.zig");
const Token = parser.Token;
const TokenCat = parser.TokenCat;
const Lexer = parser.Lexer;

// =============================================================================
// HIGHLIGHT CATEGORY
// =============================================================================

/// Semantic categories for syntax highlighting.
/// The terminal renderer maps these to ANSI color codes.
pub const Highlight = enum {
    normal,
    command,
    argument,
    path,
    keyword,
    string,
    variable,
    number,
    operator,
    redirect,
    pipe,
    comment,
    err,
};

/// Map a token category to a highlight category.
pub fn highlightFor(cat: TokenCat) Highlight {
    return switch (cat) {
        .ident => .command,
        .string_sq, .string_dq => .string,
        .variable, .var_braced, .dollar => .variable,
        .integer, .real => .number,
        .comment => .comment,
        .pipe, .pipe_err => .pipe,
        .redir_out, .redir_append, .redir_in, .redir_err, .redir_err_app, .redir_both, .redir_fd, .redir_dup => .redirect,
        .and_sym, .or_sym, .not_sym, .eq, .ne, .lt, .gt, .le, .ge, .match, .nomatch => .operator,
        .plus, .minus, .star, .slash, .percent, .power, .assign, .default_op => .operator,
        .herestring, .heredoc_sq, .heredoc_dq, .heredoc_bt, .heredoc_end, .heredoc_body => .string,
        .proc_sub_in, .proc_sub_out => .redirect,
        .err => .err,
        else => .normal,
    };
}

// =============================================================================
// TOKEN STREAM
// =============================================================================

/// A buffered token stream with one-token lookahead and source text access.
pub const TokenStream = struct {
    lexer: Lexer,
    source: []const u8,
    current: Token,
    peeked: bool,
    peek_tok: Token,

    pub fn init(source: []const u8) TokenStream {
        var lex = Lexer.init(source);
        const first = lex.next();
        return .{
            .lexer = lex,
            .source = source,
            .current = first,
            .peeked = false,
            .peek_tok = undefined,
        };
    }

    /// Advance to the next token, returning the current one.
    pub fn advance(self: *TokenStream) Token {
        const tok = self.current;
        if (self.peeked) {
            self.current = self.peek_tok;
            self.peeked = false;
        } else {
            self.current = self.lexer.next();
        }
        return tok;
    }

    /// Peek at the next token without consuming it.
    pub fn peek(self: *TokenStream) Token {
        if (!self.peeked) {
            self.peek_tok = self.lexer.next();
            self.peeked = true;
        }
        return self.peek_tok;
    }

    /// Get the source text for a token.
    pub fn text(self: *const TokenStream, tok: Token) []const u8 {
        return self.source[tok.pos..][0..tok.len];
    }

    /// Check if the current token is EOF.
    pub fn atEnd(self: *const TokenStream) bool {
        return self.current.cat == .eof;
    }
};

// =============================================================================
// LINE TOKENIZER (for syntax highlighting)
// =============================================================================

/// Tokenize a single line and return highlight spans.
/// Used by the interactive prompt for live syntax highlighting.
pub const Span = struct {
    start: u32,
    len: u16,
    highlight: Highlight,
};

pub fn tokenizeLine(source: []const u8, buf: []Span) []Span {
    var lex = Lexer.init(source);
    var count: usize = 0;
    var first_cmd = true;

    while (count < buf.len) {
        const tok = lex.next();
        if (tok.cat == .eof or tok.cat == .newline) break;

        var hl = highlightFor(tok.cat);

        if (tok.cat == .ident and first_cmd) {
            hl = .command;
            first_cmd = false;
        } else if (tok.cat == .ident and !first_cmd) {
            hl = .argument;
        }

        if (tok.cat == .pipe or tok.cat == .pipe_err or
            tok.cat == .and_sym or tok.cat == .or_sym or
            tok.cat == .semi)
        {
            first_cmd = true;
        }

        buf[count] = .{ .start = tok.pos, .len = tok.len, .highlight = hl };
        count += 1;
    }

    return buf[0..count];
}
