//! keybinding — user-configurable key bindings (the `key` builtin's
//! parser, registry, and storage).
//!
//! Two binding forms:
//!
//!     key KEYSPEC bare-ident       # named editor action from the registry
//!     key KEYSPEC "literal text"   # type bytes; trailing `\n` = also accept
//!
//! The first form looks up `bare-ident` in `action_registry` and stores
//! the corresponding `zigline.Action`. The second form stores the
//! decoded byte string; at trigger time the bytes are inserted into
//! the buffer, and (if the last byte is `\n` or `\r`) the line is
//! accepted afterward.
//!
//! KEYSPEC syntax:
//!
//!     Chord        modifier-joined-with-hyphen + key, e.g. Ctrl-X,
//!                  Alt-Left, Ctrl-Alt-Right, Shift-F7. Modifier order
//!                  doesn't matter; `Ctrl-Alt-X` == `Alt-Ctrl-X`.
//!
//!     Synonyms     Esc-X, Meta-X, and Alt-X all canonicalize to the
//!                  same Meta-modified chord. Terminals emit identical
//!                  bytes (`\e X`) for all three, and zigline collapses
//!                  to one `KeyEvent` with `mods.alt = true`. Slash
//!                  prints canonical form as `Alt-X` in listings.
//!
//!     Multi-chord  Reserved syntax: `Ctrl-X,Ctrl-E` (comma between
//!                  chords). Parse-time diagnostic in v1; needs
//!                  zigline prefix-state primitive to ship.
//!
//!     Named keys   Up, Down, Left, Right, Home, End, PageUp,
//!                  PageDown, Tab, Enter, Backspace, Delete, Escape,
//!                  Space, F1..F12. Modifier-prefixed too:
//!                  `Alt-Left`, `Ctrl-F7`, etc.
//!
//! Conflict resolution: last `key` call wins. Listing prints in
//! canonical form regardless of how the user spelled it.

const std = @import("std");
const zigline = @import("zigline");

const Allocator = std.mem.Allocator;
pub const KeyEvent = zigline.KeyEvent;
pub const KeyCode = zigline.KeyCode;
pub const Modifiers = zigline.Modifiers;
pub const Action = zigline.Action;

// =============================================================================
// BindingKey — hashable normalized KeyEvent
// =============================================================================

/// A normalized, hashable form of `KeyEvent` for use as a hashmap key.
/// `KeyEvent` itself can't be a `std.AutoHashMap` key because its
/// `KeyCode.text` / `.unknown` variants carry slices (AutoHashMap
/// would hash by pointer, not contents). User bindings never bind
/// those variants anyway, so converting to a fixed-size key sidesteps
/// the issue.
pub const BindingKey = struct {
    code: CodeTag,
    /// Codepoint when `code == .char`. Zero otherwise.
    char: u21 = 0,
    /// Function key number (1..12) when `code == .function`. Zero otherwise.
    function: u8 = 0,
    mods: Modifiers,

    pub const CodeTag = enum(u8) {
        char,
        function,
        enter,
        tab,
        backspace,
        delete,
        escape,
        home,
        end,
        page_up,
        page_down,
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
        insert,
    };

    pub fn fromKeyEvent(ke: KeyEvent) ?BindingKey {
        const raw: BindingKey = switch (ke.code) {
            .char => |c| .{ .code = .char, .char = c, .mods = ke.mods },
            .function => |n| .{ .code = .function, .function = n, .mods = ke.mods },
            .enter => .{ .code = .enter, .mods = ke.mods },
            .tab => .{ .code = .tab, .mods = ke.mods },
            .backspace => .{ .code = .backspace, .mods = ke.mods },
            .delete => .{ .code = .delete, .mods = ke.mods },
            .escape => .{ .code = .escape, .mods = ke.mods },
            .home => .{ .code = .home, .mods = ke.mods },
            .end => .{ .code = .end, .mods = ke.mods },
            .page_up => .{ .code = .page_up, .mods = ke.mods },
            .page_down => .{ .code = .page_down, .mods = ke.mods },
            .arrow_up => .{ .code = .arrow_up, .mods = ke.mods },
            .arrow_down => .{ .code = .arrow_down, .mods = ke.mods },
            .arrow_left => .{ .code = .arrow_left, .mods = ke.mods },
            .arrow_right => .{ .code = .arrow_right, .mods = ke.mods },
            .insert => .{ .code = .insert, .mods = ke.mods },
            // .text (paste) and .unknown (untranslated escape) are never
            // bindable. The user can't realistically aim at "the paste
            // event" or "the sequence the terminal didn't recognize."
            .text, .unknown => return null,
        };
        return normalizeForLookup(raw);
    }
};

/// Normalize a `BindingKey` so two semantically-equivalent chords
/// hash to the same slot. Terminals can't distinguish `Ctrl-x` from
/// `Ctrl-X` (both transmit byte 0x18), and zigline's parser emits
/// the lowercase form for ctrl-modified ASCII letters. So a user
/// `key Ctrl-X foo` binding must match a runtime `KeyEvent{ char='x',
/// mods.ctrl=true }`. Lowercasing at both store time (in
/// `parseKeySpec`) and lookup time (here) makes the two sides agree
/// without depending on which one fires first or which case the
/// user happened to type.
pub fn normalizeForLookup(bk: BindingKey) BindingKey {
    if (bk.code != .char) return bk;
    if (!bk.mods.ctrl) return bk;
    if (bk.char >= 'A' and bk.char <= 'Z') {
        var out = bk;
        out.char = bk.char + 32; // ASCII to-lower
        return out;
    }
    return bk;
}

/// Pack a `BindingKey` into a `u64`. Used as the hash digest and to
/// guarantee that structurally-equal keys produce bit-identical
/// hashes regardless of struct padding. Field widths: code 5 bits
/// (16 variants → 4 bits, 1 slack), char 21 bits (Unicode max),
/// function 4 bits (1..12 → 4 bits), mods 3 bits. Total = 33 bits,
/// fits comfortably in 64.
fn packKey(k: BindingKey) u64 {
    var x: u64 = 0;
    x |= @as(u64, @intFromEnum(k.code)) & 0x1f;
    x |= (@as(u64, k.char) & 0x1f_ffff) << 5;
    x |= (@as(u64, k.function) & 0xf) << 26;
    if (k.mods.ctrl) x |= @as(u64, 1) << 30;
    if (k.mods.alt) x |= @as(u64, 1) << 31;
    if (k.mods.shift) x |= @as(u64, 1) << 32;
    return x;
}

/// Hash + eql for `std.HashMapUnmanaged(BindingKey, ...,
/// BindingKeyContext, ...)`. The hash routes through `packKey`
/// rather than `std.mem.asBytes(&k)` — the byte-slice form would
/// include struct padding (which `std.meta.eql` ignores), letting
/// two equal keys hash to different slots. The eql delegates to
/// `std.meta.eql` which compares field-by-field, ignoring padding.
pub const BindingKeyContext = struct {
    pub fn hash(_: BindingKeyContext, k: BindingKey) u64 {
        const packed_val = packKey(k);
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&packed_val));
    }
    pub fn eql(_: BindingKeyContext, a: BindingKey, b: BindingKey) bool {
        // Equality also goes through `packKey` so two keys that
        // hash equal are guaranteed to compare equal — defends
        // against any latent padding-comparison weirdness in
        // `std.meta.eql` over union/enum fields.
        return packKey(a) == packKey(b);
    }
};

// =============================================================================
// BindingTarget — what a triggered binding does
// =============================================================================

pub const BindingTarget = union(enum) {
    /// A pre-registered editor action (`zigline.Action` value).
    action: Action,
    /// Literal bytes inserted into the buffer when triggered. If the
    /// last byte is `\n` (or `\r`), the line is accepted after
    /// insertion — same convention as zsh `bindkey -s`.
    /// Allocator-owned; freed when the binding is replaced or unbound.
    literal: []const u8,
};

// =============================================================================
// BindingTable — what `Session` actually stores
// =============================================================================

pub const Table = struct {
    alloc: Allocator,
    chord: std.HashMapUnmanaged(BindingKey, BindingTarget, BindingKeyContext, std.hash_map.default_max_load_percentage) = .empty,

    pub fn init(alloc: Allocator) Table {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Table) void {
        var it = self.chord.iterator();
        while (it.next()) |entry| {
            self.freeTarget(entry.value_ptr.*);
        }
        self.chord.deinit(self.alloc);
    }

    fn freeTarget(self: *Table, t: BindingTarget) void {
        switch (t) {
            .literal => |bytes| self.alloc.free(bytes),
            .action => {},
        }
    }

    /// Install or replace a chord binding. Takes ownership of any
    /// allocator-owned bytes in `target` (e.g. `.literal`).
    pub fn putChord(self: *Table, k: BindingKey, target: BindingTarget) !void {
        const gop = try self.chord.getOrPut(self.alloc, k);
        if (gop.found_existing) self.freeTarget(gop.value_ptr.*);
        gop.value_ptr.* = target;
    }

    /// Remove a chord binding. Returns true if a binding was present.
    pub fn removeChord(self: *Table, k: BindingKey) bool {
        if (self.chord.fetchRemove(k)) |kv| {
            self.freeTarget(kv.value);
            return true;
        }
        return false;
    }

    pub fn lookupChord(self: *const Table, k: BindingKey) ?BindingTarget {
        return self.chord.get(k);
    }

    /// Drop every binding. Used by `key --reset`.
    pub fn clearAll(self: *Table) void {
        var it = self.chord.iterator();
        while (it.next()) |entry| self.freeTarget(entry.value_ptr.*);
        self.chord.clearRetainingCapacity();
    }

    pub fn count(self: *const Table) usize {
        return self.chord.count();
    }
};

// =============================================================================
// Action registry — kebab-case name → zigline.Action
// =============================================================================

/// Custom-action IDs that aren't `zigline.Action` values but still
/// need to be addressable from `key` bindings. Slash defines these in
/// `repl.zig`'s `ActionId` enum and dispatches them via
/// `customActionHook`. The numeric values here must match the
/// `ActionId` enum's values; the actions module imports neither way
/// to avoid a cycle.
pub const SlashCustomAction = enum(u32) {
    edit_in_editor = 1,
    expand_str_space = 2,
    expand_str_enter = 3,
    smart_history_prev = 4,
    smart_history_next = 5,
    /// Reserved for the `key` builtin: triggered when a literal-text
    /// binding fires. Reads the stashed payload from the session.
    dispatch_user_literal = 6,
};

/// One action-registry entry. `kind` distinguishes "this is a real
/// zigline.Action" from "this dispatches through customAction with
/// a slash-specific ID."
pub const RegistryAction = union(enum) {
    builtin: Action,
    custom: SlashCustomAction,
};

const registry_map = std.StaticStringMap(RegistryAction).initComptime(.{
    // Text editing.
    .{ "delete-backward", RegistryAction{ .builtin = .delete_backward } },
    .{ "delete-forward", RegistryAction{ .builtin = .delete_forward } },
    .{ "kill-to-start", RegistryAction{ .builtin = .kill_to_start } },
    .{ "kill-to-end", RegistryAction{ .builtin = .kill_to_end } },
    .{ "kill-word-backward", RegistryAction{ .builtin = .kill_word_backward } },
    .{ "kill-word-forward", RegistryAction{ .builtin = .kill_word_forward } },

    // Movement.
    .{ "backward-char", RegistryAction{ .builtin = .move_left } },
    .{ "forward-char", RegistryAction{ .builtin = .move_right } },
    .{ "word-backward", RegistryAction{ .builtin = .move_word_left } },
    .{ "word-forward", RegistryAction{ .builtin = .move_word_right } },
    .{ "beginning-of-line", RegistryAction{ .builtin = .move_to_start } },
    .{ "end-of-line", RegistryAction{ .builtin = .move_to_end } },

    // History.
    .{ "history-prev", RegistryAction{ .builtin = .history_prev } },
    .{ "history-next", RegistryAction{ .builtin = .history_next } },
    .{ "history-first", RegistryAction{ .builtin = .history_first } },
    .{ "history-last", RegistryAction{ .builtin = .history_last } },
    .{ "yank-last-arg", RegistryAction{ .builtin = .yank_last_arg } },

    // Completion + hints.
    .{ "complete", RegistryAction{ .builtin = .complete } },
    .{ "accept-hint", RegistryAction{ .builtin = .accept_hint } },

    // Transient input (Ctrl-R reverse-i-search overlay).
    .{ "reverse-i-search", RegistryAction{ .builtin = .transient_input_open } },
    .{ "transient-input", RegistryAction{ .builtin = .transient_input_open } },

    // Line lifecycle.
    .{ "accept-line", RegistryAction{ .builtin = .accept_line } },
    .{ "cancel-line", RegistryAction{ .builtin = .cancel_line } },
    .{ "eof", RegistryAction{ .builtin = .eof } },

    // Display.
    .{ "clear-screen", RegistryAction{ .builtin = .clear_screen } },
    .{ "redraw", RegistryAction{ .builtin = .redraw } },

    // Job control.
    .{ "suspend-self", RegistryAction{ .builtin = .suspend_self } },

    // Kill ring.
    .{ "yank", RegistryAction{ .builtin = .yank } },
    .{ "yank-pop", RegistryAction{ .builtin = .yank_pop } },

    // Undo / redo.
    .{ "undo", RegistryAction{ .builtin = .undo } },
    .{ "redo", RegistryAction{ .builtin = .redo } },

    // Text transforms.
    .{ "transpose-chars", RegistryAction{ .builtin = .transpose_chars } },
    .{ "capitalize-word", RegistryAction{ .builtin = .capitalize_word } },
    .{ "upper-case-word", RegistryAction{ .builtin = .upper_case_word } },
    .{ "lower-case-word", RegistryAction{ .builtin = .lower_case_word } },
    .{ "squeeze-whitespace", RegistryAction{ .builtin = .squeeze_whitespace } },

    // Quoted insert (next byte literal).
    .{ "quoted-insert", RegistryAction{ .builtin = .quoted_insert } },

    // Slash-specific.
    .{ "edit-in-editor", RegistryAction{ .custom = .edit_in_editor } },
    .{ "history-prev-prefix", RegistryAction{ .custom = .smart_history_prev } },
    .{ "history-next-prefix", RegistryAction{ .custom = .smart_history_next } },
});

pub fn lookupAction(name: []const u8) ?RegistryAction {
    return registry_map.get(name);
}

/// Iterator-style listing for `key --actions`. Returns the
/// registry's keys in `StaticStringMap`'s packed order (empirically
/// shortest-first; not alphabetical). Callers that want sorted
/// output sort post-hoc — see `keyListActions` in `builtins.zig`.
pub fn actionNames() []const []const u8 {
    return registry_map.keys();
}

// =============================================================================
// KeySpec parser
// =============================================================================

pub const ParseError = error{
    EmptyKeySpec,
    UnknownModifier,
    UnknownKey,
    MultiChordNotSupported,
    InvalidEscape,
};

/// Parse a symbolic keyspec like `Ctrl-X`, `Alt-Left`, `Ctrl-Alt-F7`
/// into a `BindingKey`. Case-insensitive modifier names; case-
/// preserving final key (`A` vs `a` differ — terminals send the
/// shifted ASCII for `A`).
pub fn parseKeySpec(text: []const u8) ParseError!BindingKey {
    if (text.len == 0) return error.EmptyKeySpec;
    // Reject multi-chord sequences with a precise message — the
    // syntax is reserved for v2 when zigline ships prefix-pending
    // state.
    if (std.mem.indexOfScalar(u8, text, ',') != null) {
        return error.MultiChordNotSupported;
    }

    var mods: Modifiers = .{};
    var rest = text;

    // Eat any number of `Modifier-` prefixes. Order is free; we
    // canonicalize at format time.
    while (splitFirstHyphen(rest)) |sp| {
        const mod_name = sp.head;
        if (matchModifier(mod_name)) |m| {
            switch (m) {
                .ctrl => mods.ctrl = true,
                .alt => mods.alt = true,
                .shift => mods.shift = true,
            }
            rest = sp.tail;
            continue;
        }
        break;
    }

    if (rest.len == 0) return error.UnknownKey;

    // `rest` is now the key name (no more modifiers).
    if (matchNamedKey(rest)) |code| {
        return normalizeForLookup(codeToBindingKey(code, mods));
    }
    if (matchFunctionKey(rest)) |n| {
        return normalizeForLookup(.{ .code = .function, .function = n, .mods = mods });
    }
    // Single character — most common case (`Ctrl-X`, `Alt-P`).
    // ASCII-only for now; Unicode bindings are exotic and zsh doesn't
    // support them portably either.
    if (rest.len == 1) {
        const c = rest[0];
        if (c < 0x20 or c >= 0x7f) return error.UnknownKey;
        return normalizeForLookup(.{ .code = .char, .char = @as(u21, c), .mods = mods });
    }
    return error.UnknownKey;
}

const Modifier = enum { ctrl, alt, shift };

fn matchModifier(name: []const u8) ?Modifier {
    if (eqIgnoreCase(name, "ctrl") or eqIgnoreCase(name, "control"))
        return .ctrl;
    if (eqIgnoreCase(name, "alt") or eqIgnoreCase(name, "meta") or eqIgnoreCase(name, "esc"))
        return .alt;
    if (eqIgnoreCase(name, "shift"))
        return .shift;
    return null;
}

fn matchNamedKey(name: []const u8) ?BindingKey.CodeTag {
    if (eqIgnoreCase(name, "up") or eqIgnoreCase(name, "arrow-up")) return .arrow_up;
    if (eqIgnoreCase(name, "down") or eqIgnoreCase(name, "arrow-down")) return .arrow_down;
    if (eqIgnoreCase(name, "left") or eqIgnoreCase(name, "arrow-left")) return .arrow_left;
    if (eqIgnoreCase(name, "right") or eqIgnoreCase(name, "arrow-right")) return .arrow_right;
    if (eqIgnoreCase(name, "home")) return .home;
    if (eqIgnoreCase(name, "end")) return .end;
    if (eqIgnoreCase(name, "pageup") or eqIgnoreCase(name, "page-up")) return .page_up;
    if (eqIgnoreCase(name, "pagedown") or eqIgnoreCase(name, "page-down")) return .page_down;
    if (eqIgnoreCase(name, "tab")) return .tab;
    if (eqIgnoreCase(name, "enter") or eqIgnoreCase(name, "return")) return .enter;
    if (eqIgnoreCase(name, "backspace")) return .backspace;
    if (eqIgnoreCase(name, "delete") or eqIgnoreCase(name, "del")) return .delete;
    // `Esc` (no `-suffix`) is the literal Escape key. The
    // `Esc-X` form goes through the modifier-prefix path above
    // and becomes `Alt-X`. Single-token `Esc` here is just an
    // alias for the dedicated Escape key.
    if (eqIgnoreCase(name, "escape") or eqIgnoreCase(name, "esc")) return .escape;
    if (eqIgnoreCase(name, "space")) return .char; // special: returns char tag with ' '
    if (eqIgnoreCase(name, "insert") or eqIgnoreCase(name, "ins")) return .insert;
    return null;
}

fn matchFunctionKey(name: []const u8) ?u8 {
    if (name.len < 2 or name.len > 3) return null;
    if (name[0] != 'F' and name[0] != 'f') return null;
    var n: u32 = 0;
    for (name[1..]) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n < 1 or n > 12) return null;
    return @intCast(n);
}

fn codeToBindingKey(code: BindingKey.CodeTag, mods: Modifiers) BindingKey {
    // The `space` key is exposed as a named key for ergonomics
    // (`key Space some-action` reads better than `key " " ...`),
    // but it lives in the `.char` arm of the union with codepoint
    // 0x20.
    if (code == .char) {
        return .{ .code = .char, .char = ' ', .mods = mods };
    }
    return .{ .code = code, .mods = mods };
}

const HyphenSplit = struct { head: []const u8, tail: []const u8 };

fn splitFirstHyphen(s: []const u8) ?HyphenSplit {
    const idx = std.mem.indexOfScalar(u8, s, '-') orelse return null;
    return .{ .head = s[0..idx], .tail = s[idx + 1 ..] };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// =============================================================================
// Canonical formatting (for `key` listing)
// =============================================================================

/// Format a `BindingKey` back into its canonical text form. Writes
/// `Ctrl-X`, `Alt-Left`, `Shift-F7`, etc. Output never includes
/// `Esc-` / `Meta-` synonyms (those collapse to `Alt-`).
pub fn formatKey(k: BindingKey, w: anytype) !void {
    if (k.mods.ctrl) try w.writeAll("Ctrl-");
    if (k.mods.alt) try w.writeAll("Alt-");
    if (k.mods.shift) try w.writeAll("Shift-");
    switch (k.code) {
        .char => {
            if (k.char == ' ') {
                try w.writeAll("Space");
            } else {
                try w.writeByte(@intCast(k.char));
            }
        },
        .function => try w.print("F{d}", .{k.function}),
        .enter => try w.writeAll("Enter"),
        .tab => try w.writeAll("Tab"),
        .backspace => try w.writeAll("Backspace"),
        .delete => try w.writeAll("Delete"),
        .escape => try w.writeAll("Escape"),
        .home => try w.writeAll("Home"),
        .end => try w.writeAll("End"),
        .page_up => try w.writeAll("PageUp"),
        .page_down => try w.writeAll("PageDown"),
        .arrow_up => try w.writeAll("Up"),
        .arrow_down => try w.writeAll("Down"),
        .arrow_left => try w.writeAll("Left"),
        .arrow_right => try w.writeAll("Right"),
        .insert => try w.writeAll("Insert"),
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseKeySpec: simple Ctrl-X (normalized to lowercase)" {
    // Ctrl-modified ASCII letters always store lowercase — see the
    // `normalizeForLookup` doc-comment for why. Terminals can't
    // distinguish Ctrl-X from Ctrl-x on the wire, and zigline emits
    // the lowercase form.
    const k = try parseKeySpec("Ctrl-X");
    try std.testing.expectEqual(BindingKey.CodeTag.char, k.code);
    try std.testing.expectEqual(@as(u21, 'x'), k.char);
    try std.testing.expect(k.mods.ctrl);
    try std.testing.expect(!k.mods.alt);
}

test "parseKeySpec: Alt and Meta and Esc are synonyms" {
    const a = try parseKeySpec("Alt-P");
    const m = try parseKeySpec("Meta-P");
    const e = try parseKeySpec("Esc-P");
    try std.testing.expect(std.meta.eql(a, m));
    try std.testing.expect(std.meta.eql(a, e));
    try std.testing.expect(a.mods.alt);
}

test "parseKeySpec: case-insensitive modifiers; ctrl-letter forced lowercase" {
    // Modifiers are case-insensitive (`Ctrl-` and `ctrl-` parse the
    // same). For ctrl-modified letters the final char is forced
    // lowercase by `normalizeForLookup` regardless of how the user
    // spelled it — both `Ctrl-X` and `Ctrl-x` end up identical.
    const lower = try parseKeySpec("ctrl-x");
    const upper = try parseKeySpec("Ctrl-X");
    try std.testing.expectEqual(@as(u21, 'x'), lower.char);
    try std.testing.expectEqual(@as(u21, 'x'), upper.char);
    try std.testing.expect(std.meta.eql(lower, upper));
}

test "parseKeySpec: Alt-modified letters PRESERVE case (no normalization)" {
    // No ctrl modifier → no normalization. `Alt-X` and `Alt-x` are
    // distinguishable on modern terminals; user gets what they typed.
    const alt_lower = try parseKeySpec("Alt-x");
    const alt_upper = try parseKeySpec("Alt-X");
    try std.testing.expectEqual(@as(u21, 'x'), alt_lower.char);
    try std.testing.expectEqual(@as(u21, 'X'), alt_upper.char);
    try std.testing.expect(!std.meta.eql(alt_lower, alt_upper));
}

test "parseKeySpec: multi-modifier chord" {
    const k = try parseKeySpec("Ctrl-Alt-Right");
    try std.testing.expect(k.mods.ctrl);
    try std.testing.expect(k.mods.alt);
    try std.testing.expectEqual(BindingKey.CodeTag.arrow_right, k.code);
}

test "parseKeySpec: function key" {
    const k = try parseKeySpec("F7");
    try std.testing.expectEqual(BindingKey.CodeTag.function, k.code);
    try std.testing.expectEqual(@as(u8, 7), k.function);
}

test "parseKeySpec: modifier-prefixed function key" {
    const k = try parseKeySpec("Shift-F12");
    try std.testing.expectEqual(@as(u8, 12), k.function);
    try std.testing.expect(k.mods.shift);
}

test "parseKeySpec: named keys" {
    const inputs = .{
        .{ "Up", BindingKey.CodeTag.arrow_up },
        .{ "Down", BindingKey.CodeTag.arrow_down },
        .{ "Left", BindingKey.CodeTag.arrow_left },
        .{ "Right", BindingKey.CodeTag.arrow_right },
        .{ "Home", BindingKey.CodeTag.home },
        .{ "End", BindingKey.CodeTag.end },
        .{ "Tab", BindingKey.CodeTag.tab },
        .{ "Enter", BindingKey.CodeTag.enter },
        .{ "Backspace", BindingKey.CodeTag.backspace },
        .{ "Escape", BindingKey.CodeTag.escape },
    };
    inline for (inputs) |pair| {
        const k = try parseKeySpec(pair[0]);
        try std.testing.expectEqual(pair[1], k.code);
    }
}

test "parseKeySpec: Space is a char with codepoint 0x20" {
    const k = try parseKeySpec("Space");
    try std.testing.expectEqual(BindingKey.CodeTag.char, k.code);
    try std.testing.expectEqual(@as(u21, ' '), k.char);
}

test "parseKeySpec: rejects multi-chord with a descriptive error" {
    const result = parseKeySpec("Ctrl-X,Ctrl-E");
    try std.testing.expectError(error.MultiChordNotSupported, result);
}

test "parseKeySpec: rejects empty input" {
    try std.testing.expectError(error.EmptyKeySpec, parseKeySpec(""));
}

test "parseKeySpec: rejects unknown key" {
    try std.testing.expectError(error.UnknownKey, parseKeySpec("Ctrl-Banana"));
}

test "formatKey: canonical Alt- not Esc-" {
    const k = try parseKeySpec("Esc-P");
    var buf: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatKey(k, &stream);
    try std.testing.expectEqualStrings("Alt-P", stream.buffered());
}

test "formatKey: multi-modifier formatting is stable" {
    const k = try parseKeySpec("Alt-Ctrl-Right");
    var buf: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatKey(k, &stream);
    // Modifiers always emit in Ctrl/Alt/Shift order regardless of
    // how the user spelled them — this lets `key` listing be sorted
    // deterministically.
    try std.testing.expectEqualStrings("Ctrl-Alt-Right", stream.buffered());
}

test "BindingKey.fromKeyEvent: char roundtrips" {
    const ke = KeyEvent{ .code = .{ .char = 'x' }, .mods = .{ .ctrl = true } };
    const k = BindingKey.fromKeyEvent(ke).?;
    try std.testing.expectEqual(BindingKey.CodeTag.char, k.code);
    try std.testing.expectEqual(@as(u21, 'x'), k.char);
    try std.testing.expect(k.mods.ctrl);
}

test "BindingKey.fromKeyEvent: text/unknown variants are unbindable" {
    const ke1 = KeyEvent{ .code = .{ .text = "abc" } };
    const ke2 = KeyEvent{ .code = .{ .unknown = "??" } };
    try std.testing.expect(BindingKey.fromKeyEvent(ke1) == null);
    try std.testing.expect(BindingKey.fromKeyEvent(ke2) == null);
}

test "Table: putChord then lookupChord" {
    const alloc = std.testing.allocator;
    var t = Table.init(alloc);
    defer t.deinit();

    const k = try parseKeySpec("Ctrl-X");
    try t.putChord(k, .{ .action = .move_left });
    const found = t.lookupChord(k).?;
    try std.testing.expect(found == .action);
    try std.testing.expect(found.action == .move_left);
}

test "Table: putChord replaces and frees previous literal" {
    const alloc = std.testing.allocator;
    var t = Table.init(alloc);
    defer t.deinit();

    const k = try parseKeySpec("Alt-G");
    try t.putChord(k, .{ .literal = try alloc.dupe(u8, "git status\n") });
    try t.putChord(k, .{ .literal = try alloc.dupe(u8, "git log\n") });
    const found = t.lookupChord(k).?;
    try std.testing.expectEqualStrings("git log\n", found.literal);
}

test "Table: removeChord frees the literal" {
    const alloc = std.testing.allocator;
    var t = Table.init(alloc);
    defer t.deinit();

    const k = try parseKeySpec("Alt-L");
    try t.putChord(k, .{ .literal = try alloc.dupe(u8, "ls -la\n") });
    try std.testing.expect(t.removeChord(k));
    try std.testing.expect(t.lookupChord(k) == null);
}

test "lookupAction: kebab-case names resolve" {
    try std.testing.expect(lookupAction("word-backward") != null);
    try std.testing.expect(lookupAction("accept-line") != null);
    try std.testing.expect(lookupAction("history-prev-prefix") != null);
    try std.testing.expect(lookupAction("nonexistent-action") == null);
}

test "parseKeySpec: Ctrl-X stores lowercase char (matches zigline event)" {
    // SHOWSTOPPER GUARD: terminals/zigline emit `Ctrl-X` events with
    // `.char = 'x'` (lowercase) because byte 0x18 doesn't distinguish
    // case. If we stored uppercase here, every `key Ctrl-X foo`
    // binding would silently fail to fire.
    const k = try parseKeySpec("Ctrl-X");
    try std.testing.expectEqual(@as(u21, 'x'), k.char);
    try std.testing.expect(k.mods.ctrl);
}

test "parseKeySpec: Alt-X preserves case (no ctrl modifier to collide)" {
    const k = try parseKeySpec("Alt-X");
    try std.testing.expectEqual(@as(u21, 'X'), k.char);
}

test "parseKeySpec: Esc (bare) aliases the Escape key" {
    const k = try parseKeySpec("Esc");
    try std.testing.expectEqual(BindingKey.CodeTag.escape, k.code);
    try std.testing.expect(!k.mods.alt);
}

test "BindingKey.fromKeyEvent: Ctrl event with uppercase char normalizes to lower" {
    // Defensive: even if zigline ever delivered uppercase, normalize.
    const ke = KeyEvent{ .code = .{ .char = 'X' }, .mods = .{ .ctrl = true } };
    const k = BindingKey.fromKeyEvent(ke).?;
    try std.testing.expectEqual(@as(u21, 'x'), k.char);
}

test "Table: Ctrl-X stored uppercase still hits Ctrl-X event delivered lowercase" {
    // End-to-end of the normalization invariant: a user typed
    // `key Ctrl-X foo` and pressed Ctrl-X — the stored binding and
    // the runtime event must canonicalize to the same hashmap key.
    const alloc = std.testing.allocator;
    var t = Table.init(alloc);
    defer t.deinit();

    const stored = try parseKeySpec("Ctrl-X");
    try t.putChord(stored, .{ .action = .move_left });

    const event = BindingKey.fromKeyEvent(.{
        .code = .{ .char = 'x' },
        .mods = .{ .ctrl = true },
    }).?;
    try std.testing.expect(t.lookupChord(event) != null);
}

test "BindingKeyContext: equal keys hash to the same slot (padding-safe)" {
    // Two structurally-equal keys built independently MUST hash the
    // same; the previous `std.mem.asBytes(&k)`-based hash included
    // struct padding and would have failed this.
    const ctx = BindingKeyContext{};
    const a = BindingKey{ .code = .char, .char = 'q', .function = 0, .mods = .{ .alt = true } };
    const b = BindingKey{ .code = .char, .char = 'q', .function = 0, .mods = .{ .alt = true } };
    try std.testing.expectEqual(ctx.hash(a), ctx.hash(b));
    try std.testing.expect(ctx.eql(a, b));
}
