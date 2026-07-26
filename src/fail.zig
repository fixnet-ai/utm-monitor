//! Fast-fail helper — print error context and exit immediately.
//!
//! Every unexpected error should call fail.err() or fail.msg().
//! No swallowing errors, no graceful degradation — fail fast, fail loud.
//!
//! Output goes to both std.log.err (structured logging) and stderr (always visible).

const builtin = @import("builtin");
const std = @import("std");

/// Print "[ERROR] <feature>: <zig_error_name>" with system error info, then exit(1).
/// On POSIX appends errno+strerror. On Windows appends GetLastError.
pub fn err(feature: []const u8, e: anyerror) noreturn {
    const name = @errorName(e);
    std.log.err("[{s}] {s}", .{ feature, name });
    std.debug.print("[ERROR] {s}: {s}", .{ feature, name });
    printSysError();
    std.debug.print("\n", .{});
    std.process.exit(1);
}

/// Print "[ERROR] <feature>: <message>" with system error info, then exit(1).
pub fn msg(feature: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err("[{s}] " ++ fmt, .{feature} ++ args);
    std.debug.print("[ERROR] {s}: ", .{feature});
    std.debug.print(fmt, args);
    printSysError();
    std.debug.print("\n", .{});
    std.process.exit(1);
}

fn printSysError() void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const en = std.c._errno().*;
            if (en != 0) {
                // std.c.strerror was removed in Zig 0.16.0 — call libc directly
                const strerror = @extern(*const fn (c_int) callconv(.c) [*:0]const u8, .{ .name = "strerror" });
                const err_msg = strerror(en);
                const msg_slice = std.mem.sliceTo(err_msg, 0);
                std.debug.print(" (errno={d}: {s})", .{ en, msg_slice });
            }
        },
        .windows => {
            const gle = std.os.windows.GetLastError();
            if (@intFromEnum(gle) != 0) {
                std.debug.print(" (GetLastError={d})", .{@intFromEnum(gle)});
            }
        },
        else => {},
    }
}

test "fail.err prints and exits" {
    // Can't easily test noreturn functions in unit tests without process isolation.
    // Verified manually: fail.err("test", error.Dummy) prints the expected message.
}

test "fail.msg prints and exits" {
    // Same as above — noreturn functions are hard to unit-test.
}
