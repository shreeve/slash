//! Minimal portable file-stat shim.
//!
//! Zig 0.16's `std.c.Stat` is `void` on Linux (the standard library
//! intentionally drops the platform-variant `struct stat` and steers
//! Linux callers toward `statx`). Slash needs a tiny subset — file
//! kind (regular/directory) and size — across both Linux and macOS.
//!
//! On Linux we go through the modern `statx(2)` syscall (kernel ABI
//! is stable across architectures; no glibc symbol-versioning to
//! navigate). On macOS we use `std.c.fstatat(AT.FDCWD, …)` which
//! is exposed by Zig's std.c on Darwin targets.
//!
//! The returned `Info` is intentionally narrow. Callers that need
//! more (permission bits, mtime, blocks, …) should extend it and
//! widen the backend masks as needed.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum { file, directory, other };

pub const Info = struct {
    kind: Kind,
    size: u64,
};

/// Look up `path_z` (NUL-terminated, relative or absolute) and
/// return its kind + size, or `null` on any stat failure.
pub fn statPath(path_z: [*:0]const u8) ?Info {
    return switch (comptime builtin.target.os.tag) {
        .linux => statxLinux(path_z),
        else => statMac(path_z),
    };
}

fn statxLinux(path_z: [*:0]const u8) ?Info {
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const mask = linux.STATX{ .TYPE = true, .SIZE = true };
    const rc = linux.statx(linux.AT.FDCWD, path_z, 0, mask, &stx);
    // Kernel syscall convention: ≥ 0 success, < 0 negated errno when
    // cast back to signed. statx writes nothing on error.
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return null;
    const ifmt: u16 = stx.mode & 0o170000;
    const kind: Kind = switch (ifmt) {
        0o040000 => .directory,
        0o100000 => .file,
        else => .other,
    };
    return .{ .kind = kind, .size = stx.size };
}

fn statMac(path_z: [*:0]const u8) ?Info {
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) != 0) return null;
    const ifmt = st.mode & std.c.S.IFMT;
    const kind: Kind = if (ifmt == std.c.S.IFDIR)
        .directory
    else if (ifmt == std.c.S.IFREG)
        .file
    else
        .other;
    return .{ .kind = kind, .size = @intCast(st.size) };
}

test "portable_stat: . is a directory" {
    const info = statPath(".") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Kind.directory, info.kind);
}

test "portable_stat: missing path returns null" {
    try std.testing.expect(statPath("/this/path/should/not/exist/slash/stat") == null);
}
