const std = @import("std");

pub const VERSION = "0.11.10";

// ── Tests ──────────────────────────────────────────────────────────────────

test "VERSION is defined" {
    try std.testing.expect(VERSION.len > 0);
}

test "VERSION follows semver" {
    // Check format: X.Y.Z
    var parts = std.mem.splitSequence(u8, VERSION, ".");
    const major = parts.next() orelse unreachable;
    const minor = parts.next() orelse unreachable;
    const patch = parts.next() orelse unreachable;

    // No leading zeros (except major="0" which is valid)
    if (major.len > 1) try std.testing.expect(major[0] != '0');
    if (minor.len > 1) try std.testing.expect(minor[0] != '0');
    if (patch.len > 1) try std.testing.expect(patch[0] != '0');

    // All numeric
    for (major) |c| try std.testing.expect(c >= '0' and c <= '9');
    for (minor) |c| try std.testing.expect(c >= '0' and c <= '9');
    for (patch) |c| try std.testing.expect(c >= '0' and c <= '9');

    // No more parts
    try std.testing.expect(parts.next() == null);
}
