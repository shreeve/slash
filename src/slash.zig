//! Slash Language Helper
//!
//! Provides Tag enum for AST node types and keyword matching functions
//! used by the generated parser. Each @as directive in the grammar
//! requires a corresponding _id enum and _as matching function.

const std = @import("std");

// =============================================================================
// TAG ENUM (AST Node Types)
// =============================================================================

pub const Tag = enum(u8) {
    // Structure
    program,
    block,
    cmd,

    // Pipeline and composition
    pipe,
    pipe_err,
    @"and",
    @"or",
    seq,
    bg,
    not,
    subshell,

    // Redirections
    redir_out,
    redir_append,
    redir_in,
    redir_err,
    redir_err_app,
    redir_both,
    redir_dup,
    herestring,

    // Heredocs
    heredoc_literal,
    heredoc_interp,
    heredoc_lang,

    // Process substitution and capture
    procsub_in,
    procsub_out,
    capture,

    // Variables
    assign,
    unset,

    // Conditionals
    @"if",
    unless,
    @"else",

    // Comparison
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    match,
    nomatch,

    // Loops
    @"for",
    @"while",
    until,

    // Pattern matching
    @"try",
    arm,
    arm_else,

    // Expressions
    neg,
    default,

    // User commands
    cmd_def,
    cmd_del,
    cmd_show,
    cmd_list,

    // Key bindings
    key,
    key_del,

    // Shell options
    set,
    set_reset,
    set_show,
    set_list,

    // Builtins
    @"test",
    exit,
    @"break",
    @"continue",
    shift,
    source,

    nil,
    _,
};

// =============================================================================
// KEYWORD MATCHING
// =============================================================================
//
// Each @as = [ident, NAME] directive in the grammar requires:
//   - NAME_id: enum with at least one variant
//   - NAME_as(text) -> ?NAME_id: exact match function
//
// Slash keywords are case-sensitive exact matches (unlike MUMPS
// which supports case-insensitive abbreviations).

pub const if_id = enum(u16) { IF = 0 };
pub const unless_id = enum(u16) { UNLESS = 0 };
pub const else_id = enum(u16) { ELSE = 0 };
pub const for_id = enum(u16) { FOR = 0 };
pub const in_id = enum(u16) { IN = 0 };
pub const while_id = enum(u16) { WHILE = 0 };
pub const until_id = enum(u16) { UNTIL = 0 };
pub const try_id = enum(u16) { TRY = 0 };
pub const and_id = enum(u16) { AND = 0 };
pub const or_id = enum(u16) { OR = 0 };
pub const not_id = enum(u16) { NOT = 0 };
pub const xor_id = enum(u16) { XOR = 0 };
pub const cmd_id = enum(u16) { CMD = 0 };
pub const key_id = enum(u16) { KEY = 0 };
pub const set_id = enum(u16) { SET = 0 };
pub const test_id = enum(u16) { TEST = 0 };
pub const source_id = enum(u16) { SOURCE = 0 };
pub const exit_id = enum(u16) { EXIT = 0 };
pub const break_id = enum(u16) { BREAK = 0 };
pub const continue_id = enum(u16) { CONTINUE = 0 };
pub const shift_id = enum(u16) { SHIFT = 0 };

pub fn if_as(name: []const u8) ?if_id {
    return if (std.mem.eql(u8, name, "if")) .IF else null;
}

pub fn unless_as(name: []const u8) ?unless_id {
    return if (std.mem.eql(u8, name, "unless")) .UNLESS else null;
}

pub fn else_as(name: []const u8) ?else_id {
    return if (std.mem.eql(u8, name, "else")) .ELSE else null;
}

pub fn for_as(name: []const u8) ?for_id {
    return if (std.mem.eql(u8, name, "for")) .FOR else null;
}

pub fn in_as(name: []const u8) ?in_id {
    return if (std.mem.eql(u8, name, "in")) .IN else null;
}

pub fn while_as(name: []const u8) ?while_id {
    return if (std.mem.eql(u8, name, "while")) .WHILE else null;
}

pub fn until_as(name: []const u8) ?until_id {
    return if (std.mem.eql(u8, name, "until")) .UNTIL else null;
}

pub fn try_as(name: []const u8) ?try_id {
    return if (std.mem.eql(u8, name, "try")) .TRY else null;
}

pub fn and_as(name: []const u8) ?and_id {
    return if (std.mem.eql(u8, name, "and")) .AND else null;
}

pub fn or_as(name: []const u8) ?or_id {
    return if (std.mem.eql(u8, name, "or")) .OR else null;
}

pub fn not_as(name: []const u8) ?not_id {
    return if (std.mem.eql(u8, name, "not")) .NOT else null;
}

pub fn xor_as(name: []const u8) ?xor_id {
    return if (std.mem.eql(u8, name, "xor")) .XOR else null;
}

pub fn cmd_as(name: []const u8) ?cmd_id {
    return if (std.mem.eql(u8, name, "cmd")) .CMD else null;
}

pub fn key_as(name: []const u8) ?key_id {
    return if (std.mem.eql(u8, name, "key")) .KEY else null;
}

pub fn set_as(name: []const u8) ?set_id {
    return if (std.mem.eql(u8, name, "set")) .SET else null;
}

pub fn test_as(name: []const u8) ?test_id {
    return if (std.mem.eql(u8, name, "test")) .TEST else null;
}

pub fn source_as(name: []const u8) ?source_id {
    return if (std.mem.eql(u8, name, "source")) .SOURCE else null;
}

pub fn exit_as(name: []const u8) ?exit_id {
    return if (std.mem.eql(u8, name, "exit")) .EXIT else null;
}

pub fn break_as(name: []const u8) ?break_id {
    return if (std.mem.eql(u8, name, "break")) .BREAK else null;
}

pub fn continue_as(name: []const u8) ?continue_id {
    return if (std.mem.eql(u8, name, "continue")) .CONTINUE else null;
}

pub fn shift_as(name: []const u8) ?shift_id {
    return if (std.mem.eql(u8, name, "shift")) .SHIFT else null;
}
