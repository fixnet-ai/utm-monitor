//! Communication protocol definitions: message formats, constants, parse/build utilities

const std = @import("std");

/// Default UDP broadcast/listen + TCP message port (unified on 2121)
pub const DEFAULT_PORT: u16 = 2121;

/// UDP broadcast discovery query (sent by --status, received by Guest listener)
pub const DISCOVERY_QUERY = "ARE YOU OK?\r\n";

/// UDP broadcast discovery response prefix (Guest → sender, followed by key:value lines)
pub const DISCOVERY_RESPONSE_PREFIX = "ANNOUNCE\r\n";

// ──────────────────────────────────────────────────────────────────────────
// Mesh networking protocol (v0.10.0)
// ──────────────────────────────────────────────────────────────────────────

/// Unified mesh protocol message types (first-byte dispatch on UDP :2121).
/// LSA replaces the legacy "ARE YOU OK?" / "ANNOUNCE" text protocol.
pub const MESH_TYPE_LSA = 0x01; // Link-State Advertisement (heartbeat + node info + topology)
pub const MESH_TYPE_KCP = 0x02; // KCP reliable data
pub const MESH_TYPE_PING = 0x03; // Direct unicast reachability probe
pub const MESH_TYPE_PONG = 0x04; // Probe response

/// Legacy text protocol first byte ('A' = 0x41) — parsed for backward compat
pub const MESH_LEGACY_MAGIC: u8 = 'A';

/// LSA broadcast interval (ms). Every node broadcasts its own LSA at this rate.
pub const MESH_LSA_INTERVAL_MS: u32 = 2000;

/// Max relay hops (TTL) for LSA and KCP data. Prevents amplification attacks.
pub const MESH_MAX_TTL: u8 = 8;

/// KCP/MTU constants
pub const MESH_MTU: u32 = 1300; // Max mesh payload (avoids fragmentation)
pub const MESH_KCP_OVERHEAD: u32 = 24; // KCP header size in bytes
pub const MESH_MSS: u32 = MESH_MTU - MESH_KCP_OVERHEAD; // ~1276 bytes

/// Build a discovery query with Host version appended.
/// Format: "ARE YOU OK?\r\n{version}\r\n"
/// Backward-compatible: old Guests that don't parse the version line still respond to "ARE YOU OK?".
pub fn buildDiscoveryQuery(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}{s}\r\n", .{ DISCOVERY_QUERY, version });
}

/// Parse Host version from a discovery query.
/// New format: "ARE YOU OK?\r\n0.7.0\r\n" → returns "0.7.0"
/// Old format: "ARE YOU OK?\r\n" → returns null (no version line)
/// Returns null if the data doesn't contain a second line after "ARE YOU OK?".
pub fn parseDiscoveryVersion(data: []const u8) ?[]const u8 {
    // Must start with "ARE YOU OK?"
    const query_needle = "ARE YOU OK?";
    if (!std.mem.startsWith(u8, data, query_needle)) return null;

    // Skip the query and optional \r\n
    var rest = data[query_needle.len..];
    if (rest.len >= 2 and std.mem.eql(u8, rest[0..2], "\r\n")) {
        rest = rest[2..];
    } else if (rest.len >= 1 and rest[0] == '\n') {
        rest = rest[1..];
    } else {
        // No line ending after query — old format, no version
        return null;
    }

    // Extract version line (up to \r or \n)
    const version_end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    if (version_end == 0) return null;

    // Version should look like "0.7.0" — basic sanity check
    const version = rest[0..version_end];
    if (version.len < 3) return null;

    return version;
}

/// /etc/hosts marker block
pub const HOSTS_MARKER_BEGIN = "# UTM-MONITOR-BEGIN";
pub const HOSTS_MARKER_END = "# UTM-MONITOR-END";

/// Program version number — bump to trigger auto-upgrade
pub const VERSION = "0.11.11";

/// Parse "IP:port" string to net.IpAddress for local testing peer mesh.
/// Returns null on any parse failure.
pub fn parsePeerMeshAddr(s: []const u8) ?std.Io.net.IpAddress {
    const colon_idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const ip = s[0..colon_idx];
    const port_str = s[colon_idx + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    return std.Io.net.IpAddress.parse(ip, port) catch null;
}

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

test "buildDiscoveryQuery and parseDiscoveryVersion — new format" {
    const allocator = std.testing.allocator;
    const query = try buildDiscoveryQuery(allocator, "0.7.0");
    defer allocator.free(query);

    // Should contain both the query and the version
    try std.testing.expect(std.mem.startsWith(u8, query, "ARE YOU OK?\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, query, "0.7.0") != null);

    // Parse back
    const version = parseDiscoveryVersion(query);
    try std.testing.expect(version != null);
    try std.testing.expectEqualStrings("0.7.0", version.?);
}

test "parseDiscoveryVersion — old format (no version)" {
    const version = parseDiscoveryVersion("ARE YOU OK?\r\n");
    try std.testing.expectEqual(@as(?[]const u8, null), version);
}

test "parseDiscoveryVersion — old format with just newline" {
    const version = parseDiscoveryVersion("ARE YOU OK?\n");
    try std.testing.expectEqual(@as(?[]const u8, null), version);
}

test "parseDiscoveryVersion — not a discovery query" {
    const version = parseDiscoveryVersion("ANNOUNCE\r\nhostname: vm\r\n");
    try std.testing.expectEqual(@as(?[]const u8, null), version);
}

test "parseDiscoveryVersion — empty version line" {
    const version = parseDiscoveryVersion("ARE YOU OK?\r\n\r\n");
    try std.testing.expectEqual(@as(?[]const u8, null), version);
}

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

