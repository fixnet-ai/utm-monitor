//! Configuration persistence and logging system
//! --save-config: save current parameters to config file
//! --log-file: log output to file

const std = @import("std");

/// Configuration items
pub const Config = struct {
    port: u16 = 2121,
    name: []const u8 = "",
    hosts_file: []const u8 = "/etc/hosts",
    marker: []const u8 = "UTM-MONITOR",

    /// VM SSH configuration — deployment-specific, empty by default.
    vms: []const VmConfig = &.{},
};

/// Single VM configuration
pub const VmConfig = struct {
    name: []const u8,
    ssh: []const u8,
    path: []const u8,
};

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

/// Save configuration to file
pub fn saveConfig(io: std.Io, _: std.mem.Allocator, config: Config, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.print("# UTM Monitor config file\n", .{});
    try writer.interface.print("port={d}\n", .{config.port});
    try writer.interface.print("port={d}\n", .{config.port});
    try writer.interface.print("name={s}\n", .{config.name});
    try writer.interface.print("hosts_file={s}\n", .{config.hosts_file});
    try writer.interface.print("marker={s}\n", .{config.marker});

    for (config.vms) |vm| {
        try writer.interface.print("vm.{s}.ssh={s}\n", .{ vm.name, vm.ssh });
        try writer.interface.print("vm.{s}.path={s}\n", .{ vm.name, vm.path });
    }

    try writer.interface.flush();
    std.debug.print("[config] configuration saved to {s}\n", .{path});
}

/// Load configuration from file
pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Config {
    _ = io;
    _ = allocator;
    _ = path;
    // Simplified implementation: return default config
    // TODO: full config file parsing implementation
    return Config{};
}

test "Config default port is 2121" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u16, 2121), cfg.port);
}

test "Config default empty name" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.name);
}

test "Config default hosts_file" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("/etc/hosts", cfg.hosts_file);
}

test "Config default marker" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("UTM-MONITOR", cfg.marker);
}

test "Config default no VMs" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(usize, 0), cfg.vms.len);
}

test "Config custom port" {
    const cfg = Config{ .port = 8080 };
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
}

test "VmConfig fields" {
    const vm = VmConfig{ .name = "test", .ssh = "ssh cmd", .path = "/opt/app" };
    try std.testing.expectEqualStrings("test", vm.name);
    try std.testing.expectEqualStrings("ssh cmd", vm.ssh);
    try std.testing.expectEqualStrings("/opt/app", vm.path);
}

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
