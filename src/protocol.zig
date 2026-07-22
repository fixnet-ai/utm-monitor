//! Communication protocol definitions: message formats, constants, parse/build utilities

const std = @import("std");
const ver = @import("ver.zig");

/// Default UDP broadcast/listen + TCP message port (unified on 2121)
pub const DEFAULT_PORT: u16 = 2121;

/// UDP broadcast discovery query (sent by --status, received by Guest listener)
pub const DISCOVERY_QUERY = "ARE YOU OK?\r\n";

/// UDP broadcast discovery response prefix (Guest → sender, followed by key:value lines)
pub const DISCOVERY_RESPONSE_PREFIX = "ANNOUNCE\r\n";

/// /etc/hosts marker block
pub const HOSTS_MARKER_BEGIN = "# UTM-MONITOR-BEGIN";
pub const HOSTS_MARKER_END = "# UTM-MONITOR-END";

/// Program version number (from ver.zig — bump to trigger auto-upgrade)
pub const VERSION = ver.VERSION;

/// Map Guest target triple → deployment binary filename in serve-dir
/// Returns null for unknown targets (Host skips auto-upgrade in that case)
pub fn deploymentFilename(target: []const u8) ?[]const u8 {
    const mappings = [_]struct { target: []const u8, filename: []const u8 }{
        .{ .target = "aarch64-linux-musl", .filename = "utmm-aarch64-linux" },
        .{ .target = "x86_64-linux-musl",  .filename = "utmm-x86_64-linux" },
        .{ .target = "x86-linux-musl",     .filename = "utmm-x86-linux" },
        .{ .target = "aarch64-macos",      .filename = "utmm-aarch64-macos" },
        .{ .target = "x86_64-macos",       .filename = "utmm-x86_64-macos" },
        .{ .target = "x86-windows",        .filename = "utmm-x86-windows.exe" },
        .{ .target = "x86_64-windows",     .filename = "utmm-x86_64-windows.exe" },
        .{ .target = "aarch64-windows",    .filename = "utmm-aarch64-windows.exe" },
        // Legacy (glibc Linux, pre-musl)
        .{ .target = "aarch64-linux",      .filename = "utmm-aarch64-linux" },
        .{ .target = "x86_64-linux",       .filename = "utmm-x86_64-linux" },
        .{ .target = "x86-linux",          .filename = "utmm-x86-linux" },
    };
    for (mappings) |m| {
        if (std.mem.eql(u8, target, m.target)) return m.filename;
    }
    return null;
}

test "deploymentFilename - known targets" {
    try std.testing.expectEqualStrings("utmm-aarch64-linux", deploymentFilename("aarch64-linux-musl").?);
    try std.testing.expectEqualStrings("utmm-x86_64-linux", deploymentFilename("x86_64-linux-musl").?);
    try std.testing.expectEqualStrings("utmm-x86_64-macos", deploymentFilename("x86_64-macos").?);
    try std.testing.expectEqualStrings("utmm-aarch64-macos", deploymentFilename("aarch64-macos").?);
    try std.testing.expectEqualStrings("utmm-x86-windows.exe", deploymentFilename("x86-windows").?);
    try std.testing.expectEqualStrings("utmm-x86_64-windows.exe", deploymentFilename("x86_64-windows").?);
    try std.testing.expectEqualStrings("utmm-aarch64-windows.exe", deploymentFilename("aarch64-windows").?);
}

test "deploymentFilename - legacy glibc targets" {
    try std.testing.expectEqualStrings("utmm-aarch64-linux", deploymentFilename("aarch64-linux").?);
    try std.testing.expectEqualStrings("utmm-x86_64-linux", deploymentFilename("x86_64-linux").?);
    try std.testing.expectEqualStrings("utmm-x86-linux", deploymentFilename("x86-linux").?);
}

test "deploymentFilename - unknown target" {
    try std.testing.expectEqual(@as(?[]const u8, null), deploymentFilename("mips-linux"));
}

/// Message type
pub const MsgType = enum {
    announce, // guest → host: broadcast own info
    ping, // host → guest: request immediate announce reply
    exec_req, // host → guest: remote command request
    exec_resp, // guest → host: remote command response

    pub fn asStr(self: MsgType) []const u8 {
        return switch (self) {
            .announce => "ANNOUNCE",
            .ping => "PING",
            .exec_req => "EXEC",
            .exec_resp => "OK",
        };
    }
};

/// Parsed Guest info
pub const GuestInfo = struct {
    hostname: []const u8,
    ip: []const u8,
    target: []const u8, // Zig target triplet: aarch64-linux, x86_64-windows, ...
    mac: []const u8, // Physical NIC MAC
    version: []const u8 = VERSION,
    shell: []const u8 = "", // Detected shell binary (e.g. /bin/zsh, cmd.exe) — always heap after parse()

    /// Free all heap-allocated fields. Safe to call on zero-initialized GuestInfo.
    pub fn deinit(self: *GuestInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.hostname);
        allocator.free(self.ip);
        allocator.free(self.target);
        allocator.free(self.mac);
        allocator.free(self.version);
        if (self.shell.len > 0) allocator.free(self.shell);
        self.* = undefined;
    }

    /// Build FQDN for /etc/hosts: <hostname>.<target>.utm
    pub fn fqdn(self: GuestInfo, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}.{s}.utm", .{ self.hostname, self.target });
    }

    /// Parse GuestInfo from message lines
    /// Format: key: value (one key-value pair per line)
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !GuestInfo {
        var info = GuestInfo{
            .hostname = "unknown",
            .ip = "0.0.0.0",
            .target = "unknown",
            .mac = "00:00:00:00:00:00",
        };

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " ");
                const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");

                if (std.mem.eql(u8, key, "hostname")) {
                    info.hostname = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "ip")) {
                    info.ip = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "target")) {
                    info.target = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "mac")) {
                    info.mac = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "version")) {
                    info.version = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "shell")) {
                    info.shell = try allocator.dupe(u8, value);
                }
            }
        }

        // Note: shell stays "" if not present in ANNOUNCE (old Guest).
        // Callers must check info.shell.len > 0 and apply their own fallback.
        return info;
    }
};

// ========== Tests ==========

test "GuestInfo.parse" {
    const allocator = std.testing.allocator;
    const msg =
        \\ANNOUNCE
        \\hostname: testvm
        \\target: aarch64-linux
        \\mac: aa:bb:cc:dd:ee:ff
        \\ip: 192.168.1.100
        \\version: 1.1.0
        \\
    ;
    const info = try GuestInfo.parse(allocator, msg);
    defer {
        allocator.free(info.hostname);
        allocator.free(info.ip);
        allocator.free(info.target);
        allocator.free(info.mac);
        allocator.free(info.version);
        if (info.shell.len > 0) allocator.free(info.shell);
    }

    try std.testing.expectEqualStrings("testvm", info.hostname);
    try std.testing.expectEqualStrings("aarch64-linux", info.target);
    try std.testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", info.mac);
    try std.testing.expectEqualStrings("192.168.1.100", info.ip);
    try std.testing.expectEqualStrings("", info.shell); // empty when ANNOUNCE has no shell: line
}

test "GuestInfo.fqdn" {
    const allocator = std.testing.allocator;
    const info = GuestInfo{
        .hostname = "mybox",
        .ip = "10.0.0.1",
        .target = "aarch64-linux",
        .mac = "00:00:00:00:00:00",
    };
    const name = try info.fqdn(allocator);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("mybox.aarch64-linux.utm", name);
}

