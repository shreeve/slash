//! keyboards — physical-keyboard → terminal-byte mapping
//! tables, used by `slashKeymapLookup` to reverse-resolve compose
//! characters back to their Option-letter origin.
//!
//! Why this exists:
//!
//! macOS Terminal.app and iTerm2 default to sending the *compose
//! character* when Option is held with a letter — Option+L emits
//! `¬` (U+00AC, two UTF-8 bytes) instead of `\e l` (the "Meta"
//! byte-prefix every Unix shell expects). The user can flip
//! "Use Option as Meta key" in their terminal preferences to fix
//! it, but that requires reaching out of slash, and the user has
//! reasonably objected to needing to. So:
//!
//!   - A user writes `key Option-L "ls -la\n"` in `.slashrc`.
//!   - Slash stores the binding under the canonical `Alt-l` slot.
//!   - At runtime, the user presses Option-L.
//!   - Terminal sends `\xc2\xac`; zigline decodes to
//!     `KeyEvent { .char = 0xAC }`.
//!   - `slashKeymapLookup` direct-misses on the codepoint, then
//!     consults the active layout's reverse table: `0xAC` →
//!     `'l'`, synthesizes a `BindingKey { .char='l', .alt=true }`,
//!     retries the lookup — hits, fires.
//!
//! The result: `key Option-L ...` works regardless of terminal
//! config, on any macOS.
//!
//! Pluggability: a `Layout` is a thin record of `name` +
//! `composeToOptionLetter` function pointer. Adding `us-dvorak`,
//! `de-qwertz`, etc. is a new file + adding it to the registry.
//! Selection is via `$SLASH_KEYBOARD` (handled in `Session.init`
//! — not yet wired to env; defaults to `us_qwerty`).

const std = @import("std");

pub const Layout = struct {
    name: []const u8,
    /// Reverse mapping: a Unicode codepoint that macOS Terminal /
    /// iTerm2 emits when Option+letter is pressed (with Option
    /// configured as the "compose" key, the macOS default) back
    /// to the lowercase ASCII letter that produced it. Returns
    /// `null` if no Option-letter on this layout emits the
    /// codepoint — common for codepoints the user typed via some
    /// other path (paste, IME, etc.).
    composeToOptionLetter: *const fn (cp: u21) ?u8,
};

/// The default layout. macOS Terminal.app and iTerm2 ship with US-
/// QWERTY virtual keyboard active for most users; the Option-letter
/// → codepoint mapping below is what those keyboards emit in the
/// default "compose" mode.
pub const us_qwerty: Layout = .{
    .name = "us-qwerty",
    .composeToOptionLetter = usQwertyReverse,
};

/// Map a US-QWERTY Option-letter compose codepoint back to its
/// originating letter. Built from the macOS layout table; verify
/// any entry by running `key --probe` and pressing Option+X.
///
/// Dead keys (Option+E acute, Option+I circumflex, Option+N tilde,
/// Option+U diaeresis) emit no standalone codepoint — they wait
/// for the next character to combine with. So they have no entry
/// here, and `key Option-E foo` style bindings only fire via the
/// terminal-Meta path. `keyFn` warns at bind time when a dead key
/// is the target.
fn usQwertyReverse(cp: u21) ?u8 {
    return switch (cp) {
        // Lowercase letters
        0x00E5 => 'a', // å
        0x222B => 'b', // ∫
        0x00E7 => 'c', // ç
        0x2202 => 'd', // ∂
        // Option+E is a dead key (´ combining acute) — no mapping.
        0x0192 => 'f', // ƒ
        0x00A9 => 'g', // ©
        0x02D9 => 'h', // ˙
        // Option+I is a dead key (ˆ circumflex) — no mapping.
        0x2206 => 'j', // ∆
        0x02DA => 'k', // ˚
        0x00AC => 'l', // ¬
        0x00B5 => 'm', // µ
        // Option+N is a dead key (˜ tilde) — no mapping.
        0x00F8 => 'o', // ø
        0x03C0 => 'p', // π
        0x0153 => 'q', // œ
        0x00AE => 'r', // ®
        0x00DF => 's', // ß
        0x2020 => 't', // †
        // Option+U is a dead key (¨ diaeresis) — no mapping.
        0x221A => 'v', // √
        0x2211 => 'w', // ∑
        0x2248 => 'x', // ≈
        0x00A5 => 'y', // ¥
        0x03A9 => 'z', // Ω

        // Uppercase letters (Option+Shift+letter). Reverse map to
        // the LOWERCASE letter, since `Alt-modified` letters
        // case-fold in `normalizeForLookup`. Pressing Option-Shift+L
        // should fire the same binding as Option+L.
        0x00C5 => 'a', // Å
        0x0131 => 'b', // ı
        0x00C7 => 'c', // Ç
        0x00CE => 'd', // Î
        0x00CF => 'f', // Ï
        0x02DD => 'g', // ˝
        0x00D3 => 'h', // Ó
        0x00D4 => 'j', // Ô
        0x00D2 => 'l', // Ò
        0x00C2 => 'm', // Â
        0x00D8 => 'o', // Ø
        0x220F => 'p', // ∏
        0x0152 => 'q', // Œ
        0x2030 => 'r', // ‰
        0x00CD => 's', // Í
        0x02C7 => 't', // ˇ
        0x25CA => 'v', // ◊
        0x201E => 'w', // „
        0x02DB => 'x', // ˛
        0x00C1 => 'y', // Á
        0x00B8 => 'z', // ¸

        else => null,
    };
}

/// True if the given letter (lowercase ASCII) is a dead-key
/// position on US-QWERTY — Option+letter emits no standalone
/// codepoint, so a binding for `Option-<letter>` can't be
/// reverse-resolved from the compose-char path. The binding still
/// works via the terminal-Meta path (`\e <letter>` bytes).
pub fn isDeadKey(layout: *const Layout, letter: u8) bool {
    // Layout-aware future: each layout grows its own dead-key set.
    // For now `us_qwerty` is the only layout; check by name.
    if (std.mem.eql(u8, layout.name, "us-qwerty")) {
        return switch (letter) {
            'e', 'i', 'n', 'u', 'E', 'I', 'N', 'U' => true,
            else => false,
        };
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "us_qwerty: Option+L compose char (¬) reverses to 'l'" {
    try std.testing.expectEqual(@as(?u8, 'l'), us_qwerty.composeToOptionLetter(0x00AC));
}

test "us_qwerty: Option+Shift+L (Ò) also reverses to 'l' (case-folded)" {
    // Shift-modified Option-letter chars reverse to the lowercase
    // letter so they hit the same case-folded `Alt-l` binding slot.
    try std.testing.expectEqual(@as(?u8, 'l'), us_qwerty.composeToOptionLetter(0x00D2));
}

test "us_qwerty: a few sample mappings" {
    const cases = .{
        .{ @as(u21, 0x00E5), @as(u8, 'a') }, // å
        .{ @as(u21, 0x2202), @as(u8, 'd') }, // ∂
        .{ @as(u21, 0x00F8), @as(u8, 'o') }, // ø
        .{ @as(u21, 0x03A9), @as(u8, 'z') }, // Ω
    };
    inline for (cases) |pair| {
        try std.testing.expectEqual(@as(?u8, pair[1]), us_qwerty.composeToOptionLetter(pair[0]));
    }
}

test "us_qwerty: dead-key letters return null on reverse" {
    // Option+E/I/N/U emit no standalone codepoint, so no entry
    // exists in the reverse table for them. The dead-key combining
    // diacritics themselves (acute, circumflex, tilde, diaeresis)
    // could conceptually be entries, but they're more likely typed
    // by paste/IME than by Option-key, so we omit them.
    try std.testing.expect(isDeadKey(&us_qwerty, 'e'));
    try std.testing.expect(isDeadKey(&us_qwerty, 'i'));
    try std.testing.expect(isDeadKey(&us_qwerty, 'n'));
    try std.testing.expect(isDeadKey(&us_qwerty, 'u'));
    // Uppercase too — case-insensitive for ergonomics
    try std.testing.expect(isDeadKey(&us_qwerty, 'E'));
    // Normal Option-letter positions are not dead.
    try std.testing.expect(!isDeadKey(&us_qwerty, 'l'));
    try std.testing.expect(!isDeadKey(&us_qwerty, 'a'));
}

test "us_qwerty: unmapped codepoints return null" {
    // Plain ASCII has no Option-key origin.
    try std.testing.expectEqual(@as(?u8, null), us_qwerty.composeToOptionLetter('a'));
    // Random Unicode the user might type literally.
    try std.testing.expectEqual(@as(?u8, null), us_qwerty.composeToOptionLetter(0x1F600)); // 😀
    try std.testing.expectEqual(@as(?u8, null), us_qwerty.composeToOptionLetter('你'));
}
