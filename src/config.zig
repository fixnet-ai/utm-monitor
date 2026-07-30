//! Logging system
//! --log-file: log output to file

const std = @import("std");

/// Log level
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn asStr(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Logger
pub const Logger = struct {
    file: ?std.Io.File = null,
    write_buf: [4096]u8 = undefined,

    /// Create file logger
    pub fn init(io: std.Io, path: []const u8) !Logger {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
        return Logger{ .file = file };
    }

    /// Write log
    pub fn log(self: *Logger, io: std.Io, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (self.file) |*f| {
            var w = f.writer(&self.write_buf);
            w.interface.print("[{s}] {s}: ", .{ std.Io.Timestamp.now(io, .real), level.asStr() }) catch return;
            w.interface.print(fmt, args) catch return;
            w.interface.print("\n", .{}) catch return;
            w.interface.flush() catch return;
        }
        // Also output to stdout
        if (level != .debug) {
            std.debug.print("[{s}] {s}: ", .{ std.Io.Timestamp.now(io, .real), level.asStr() });
            std.debug.print(fmt, args);
            std.debug.print("\n", .{});
        }
    }

    pub fn deinit(self: *Logger, io: std.Io) void {
        if (self.file) |*f| {
            f.close(io);
        }
    }
};

test "LogLevel order" {
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}

test "LogLevel enum values" {
    _ = LogLevel.debug;
    _ = LogLevel.info;
    _ = LogLevel.warn;
    _ = LogLevel.err;
}
