//! Slash — runtime types shared by exec, job, builtins, and eval.
//!
//! `Result` is the typed semantic result of any execution. It is the
//! internal currency for sequencing, short-circuit, builtins, and job
//! completion. The conversion to a POSIX `u8` status byte (PLAN §20.1)
//! happens only at process boundaries: shell process exit, `$?` exposure,
//! and the headless test harness.
//!
//! `Signal` aliases `std.c.SIG` so we get the platform's native typed
//! signal enum and don't fight the stdlib about it. PLAN §6.6 specifies a
//! literal enum with Linux-like values; the load-bearing rule is that
//! `Result.signaled` carries a typed signal (not a `u8`), not the exact
//! integer values. Cross-platform parity for the well-known signals
//! (HUP=1, INT=2, KILL=9, SEGV=11, PIPE=13, TERM=15) is preserved by
//! POSIX itself.

const std = @import("std");

pub const Signal = std.c.SIG;

pub const Result = union(enum) {
    exited: u8,
    signaled: Signal,

    pub fn ok(self: Result) bool {
        return switch (self) {
            .exited => |n| n == 0,
            .signaled => false,
        };
    }

    /// PLAN §20.1: `exited(n)` → `n & 0xFF`; `signaled(sig)` → `128 + sig`.
    pub fn toStatusByte(self: Result) u8 {
        return switch (self) {
            .exited => |n| n,
            .signaled => |sig| 128 +% @as(u8, @intCast(@intFromEnum(sig) & 0x7F)),
        };
    }
};

/// Decode a `waitpid` status word into a typed `Result` (or stop event).
/// Returns null when the status indicates a stopped child; callers in the
/// foreground wait loop should keep waiting on the same target.
pub const ChildState = union(enum) {
    exited: u8,
    signaled: Signal,
    stopped: Signal,
    continued,
};

pub fn decodeWaitStatus(raw: c_int) ChildState {
    const ux: u32 = @bitCast(raw);
    if (std.c.W.IFEXITED(ux)) return .{ .exited = std.c.W.EXITSTATUS(ux) };
    if (std.c.W.IFSIGNALED(ux)) return .{ .signaled = std.c.W.TERMSIG(ux) };
    if (std.c.W.IFSTOPPED(ux)) return .{ .stopped = std.c.W.STOPSIG(ux) };
    return .continued;
}

test "Result.ok and toStatusByte" {
    try std.testing.expect((Result{ .exited = 0 }).ok());
    try std.testing.expect(!(Result{ .exited = 1 }).ok());
    try std.testing.expectEqual(@as(u8, 0), (Result{ .exited = 0 }).toStatusByte());
    try std.testing.expectEqual(@as(u8, 42), (Result{ .exited = 42 }).toStatusByte());
    const sig: Signal = .INT;
    try std.testing.expectEqual(
        @as(u8, 128 + 2),
        (Result{ .signaled = sig }).toStatusByte(),
    );
}
