//! Slash — language module for the generated parser.
//!
//! This file is the small hand-written counterpart to `src/parser.zig` (which
//! Nexus generates from `slash.grammar`). It exposes:
//!
//!   - `Tag` — the enum of semantic node types referenced by grammar actions.
//!     Every s-expression head used on the right-hand side of a Nexus action
//!     must be declared here, and nothing else.
//!
//!   - `keywordAs` — Phase 1 has no context-sensitive keywords (no `if`,
//!     `while`, `for`, `cmd`), so this unconditionally returns `null`. The
//!     grammar has no `@as` directive so this is never actually called at
//!     runtime; it exists for the Nexus contract and forward compatibility.
//!
//!   - `Lexer` — a trivial pass-through wrapper around `BaseLexer`. Phase 1
//!     needs no context-sensitive lexing (no heredocs, no indentation, no
//!     regex literals), but the generated parser always accesses state
//!     through `self.lexer.base`, so a wrapper is required even when it
//!     adds no logic. Phases 3+ will extend this wrapper as features land.

const std = @import("std");
const parser = @import("parser.zig");

/// Semantic node tags for Slash s-expressions.
///
/// Grouped by role. Keep this list tight: every entry must have a use site
/// in `slash.grammar`. See PLAN.md §6.2 for the Shape variants these map
/// onto in the next lowering step.
pub const Tag = enum(u8) {
    // ------------------------------------------------------------------
    // Compound nodes — produced by parser actions
    // ------------------------------------------------------------------

    /// Top-level list of items with interleaved tails.
    sequence,

    /// Sequence tail — unconditional continuation (separator `;` or newline).
    /// Bound element is either the next item or `_` when the separator was
    /// trailing with nothing after it.
    seq_always,

    /// Sequence tail — continue only on zero exit (`&&`).
    seq_and,

    /// Sequence tail — continue only on non-zero / signaled exit (`||`).
    seq_or,

    /// Sequence tail — background marker (`&`). shape.zig wraps the
    /// PRECEDING item as detached and then treats the bound element, if
    /// present, as a normal next item with `;` semantics.
    seq_bg,

    /// Multi-stage pipeline (pipefail per PLAN §7 Rule 11).
    pipeline,

    /// Single-process command: `(command exe arg* redirect*)`.
    command,

    /// Subshell body with optional trailing redirects.
    subshell,

    /// Wrapper around a non-empty list of redirects attached to a compound
    /// form (currently only subshell in Phase 1).
    redirects,

    /// Atomic word. Phase 1 words are one source token; the single child is
    /// a `.src` reference into the original source whose category determines
    /// whether it was bare, single-, or double-quoted.
    word,

    // ------------------------------------------------------------------
    // Redirects — one tag per kind, dispatched by shape.zig.
    //
    // The `_fd` suffix indicates an explicit numeric fd prefix; the raw
    // token text (e.g. "2>", "3<") can be recovered by slicing the source
    // at the .src.pos / .src.len of the first child.
    // ------------------------------------------------------------------

    redir_read,          // <  target
    redir_read_fd,       // N< target
    redir_write,         // >  target
    redir_write_fd,      // N> target
    redir_append,        // >> target   (N>> deferred to Phase 3)
    redir_both,          // &>  target  (stdout + stderr, truncate)
    redir_both_append,   // &>> target  (stdout + stderr, append)
    redir_dup_out,       // N>&M
    redir_dup_in,        // N<&M
};

/// Keyword promotion hook. Nexus calls this when the parser encounters an
/// `ident` token in a state where the grammar's `@as ident = [...]` chain
/// would consult the lang module. Phase 1 has no `@as` directive, so this
/// function is never reached at runtime; the stub is kept for the Nexus
/// contract so that adding keyword-style features later is a local edit.
pub fn keywordAs(text: []const u8, symbol: u16) ?u16 {
    _ = text;
    _ = symbol;
    return null;
}

/// Pass-through lexer wrapper. The generated parser always accesses state via
/// `self.lexer.base`, so even a minimal wrapper requires a `base` field. No
/// shell-specific logic happens here in Phase 1; context-sensitive behavior
/// (heredocs, indentation, regex reclassification) will be added in later
/// phases as those features enter the grammar.
pub const Lexer = struct {
    base: parser.BaseLexer,

    pub fn init(source: []const u8) Lexer {
        return .{ .base = parser.BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: parser.Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.base.reset();
    }

    /// Drop `comment` tokens at the lexer boundary so they never reach the
    /// parser. Phase 1 treats comments as pure trivia. When later phases
    /// need comments for round-trippable formatting they should be surfaced
    /// through `Parsed.trivia` (see PLAN.md §6.1), not by re-emitting them.
    pub fn next(self: *Lexer) parser.Token {
        while (true) {
            const tok = self.base.next();
            if (tok.cat != .comment) return tok;
        }
    }
};
