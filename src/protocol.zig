//! Communication protocol definitions: message formats, constants, parse/build utilities

const std = @import("std");
const tcp = @import("tcp.zig");

/// Default UDP broadcast/listen + TCP message port (unified on 2121)
pub const DEFAULT_PORT: u16 = 2121;

/// UDP broadcast discovery query (sent by --status, received by Guest listener)
pub const DISCOVERY_QUERY = "ARE YOU OK?\r\n";

/// UDP broadcast discovery response prefix (Guest → sender, followed by key:value lines)
pub const DISCOVERY_RESPONSE_PREFIX = "ANNOUNCE\r\n";

// ──────────────────────────────────────────────────────────────────────────
// Mesh networking protocol
// ──────────────────────────────────────────────────────────────────────────

/// Unified mesh protocol message types (first-byte dispatch on UDP :2121).
/// LSA replaces the legacy "ARE YOU OK?" / "ANNOUNCE" text protocol.
pub const MESH_TYPE_LSA = 0x01; // Link-State Advertisement (heartbeat + node info + topology)
pub const MESH_TYPE_PING = 0x03; // Direct unicast reachability probe
pub const MESH_TYPE_PONG = 0x04; // Probe response

/// Legacy text protocol first byte ('A' = 0x41) — parsed for backward compat
pub const MESH_LEGACY_MAGIC: u8 = 'A';

/// LSA broadcast interval (ms). Every node broadcasts its own LSA at this rate.
pub const MESH_LSA_INTERVAL_MS: u32 = 2000;

/// Max relay hops (TTL) for LSA data. Prevents amplification attacks.
pub const MESH_MAX_TTL: u8 = 8;

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
// Legacy marker (v0.14.5 and earlier), updateHosts auto-cleans these
pub const HOSTS_MARKER_BEGIN_OLD = "# BEGIN UTM-MONITOR";
pub const HOSTS_MARKER_END_OLD = "# END UTM-MONITOR";

/// Program version number — embedded at compile time, displayed in --status.
/// Sourced from ver.txt at compile time via @embedFile.
const embedded_ver = @embedFile("ver.txt");
pub const VERSION: []const u8 = if (embedded_ver.len > 0 and embedded_ver[embedded_ver.len - 1] == '\n')
    embedded_ver[0 .. embedded_ver.len - 1]
else
    embedded_ver[0..embedded_ver.len :0];

/// Host auto-upgrade: when true, the Host daemon auto-pushes an upgrade binary
/// to any Guest whose LSA-advertised version differs from VERSION (per-Guest
/// 2-minute cooldown in host.zig). Default OFF — upgrades are on-demand only
/// (`utmm --upgrade <vm>` / `utmm --deploy`). Opt in at build time to enable
/// silent push-based upgrades; a Host with this on will replace binaries on any
/// older Guest it discovers, which is dangerous on shared/production networks.
pub const AUTO_UPGRADE = false;

/// Parse "IP:port" string to net.IpAddress for local testing peer mesh.
/// Returns null on any parse failure.
pub fn parsePeerMeshAddr(s: []const u8) ?std.Io.net.IpAddress {
    const colon_idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const ip = s[0..colon_idx];
    const port_str = s[colon_idx + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    return std.Io.net.IpAddress.parse(ip, port) catch null;
}

/// Map Guest target triple → versioned deployment binary filename in serve-dir.
/// Filenames include the version suffix (e.g. utmm-aarch64-linux-0.11.19).
/// The version suffix ensures a Host never serves stale binaries to Guests.
/// Returns null for unknown targets (Host reports error on --upgrade in that case).
pub fn deploymentFilename(target: []const u8) ?[]const u8 {
    const mappings = [_]struct { target: []const u8, filename: []const u8 }{
        .{ .target = "aarch64-linux-musl", .filename = "utmm-aarch64-linux-" ++ VERSION },
        .{ .target = "x86_64-linux-musl",  .filename = "utmm-x86_64-linux-" ++ VERSION },
        .{ .target = "x86-linux-musl",     .filename = "utmm-x86-linux-" ++ VERSION },
        .{ .target = "aarch64-macos",      .filename = "utmm-aarch64-macos-" ++ VERSION },
        .{ .target = "x86_64-macos",       .filename = "utmm-x86_64-macos-" ++ VERSION },
        .{ .target = "x86-windows",        .filename = "utmm-x86-windows-" ++ VERSION ++ ".exe" },
        .{ .target = "x86_64-windows",     .filename = "utmm-x86_64-windows-" ++ VERSION ++ ".exe" },
        .{ .target = "aarch64-windows",    .filename = "utmm-aarch64-windows-" ++ VERSION ++ ".exe" },
        // Legacy (glibc Linux, pre-musl)
        .{ .target = "aarch64-linux",      .filename = "utmm-aarch64-linux-" ++ VERSION },
        .{ .target = "x86_64-linux",       .filename = "utmm-x86_64-linux-" ++ VERSION },
        .{ .target = "x86-linux",          .filename = "utmm-x86-linux-" ++ VERSION },
    };
    for (mappings) |m| {
        if (std.mem.eql(u8, target, m.target)) return m.filename;
    }
    return null;
}

test "deploymentFilename - known targets" {
    try std.testing.expectEqualStrings("utmm-aarch64-linux-" ++ VERSION, deploymentFilename("aarch64-linux-musl").?);
    try std.testing.expectEqualStrings("utmm-x86_64-linux-" ++ VERSION, deploymentFilename("x86_64-linux-musl").?);
    try std.testing.expectEqualStrings("utmm-x86_64-macos-" ++ VERSION, deploymentFilename("x86_64-macos").?);
    try std.testing.expectEqualStrings("utmm-aarch64-macos-" ++ VERSION, deploymentFilename("aarch64-macos").?);
    try std.testing.expectEqualStrings("utmm-x86-windows-" ++ VERSION ++ ".exe", deploymentFilename("x86-windows").?);
    try std.testing.expectEqualStrings("utmm-x86_64-windows-" ++ VERSION ++ ".exe", deploymentFilename("x86_64-windows").?);
    try std.testing.expectEqualStrings("utmm-aarch64-windows-" ++ VERSION ++ ".exe", deploymentFilename("aarch64-windows").?);
}

test "deploymentFilename - glibc targets" {
    try std.testing.expectEqualStrings("utmm-aarch64-linux-" ++ VERSION, deploymentFilename("aarch64-linux").?);
    try std.testing.expectEqualStrings("utmm-x86_64-linux-" ++ VERSION, deploymentFilename("x86_64-linux").?);
    try std.testing.expectEqualStrings("utmm-x86-linux-" ++ VERSION, deploymentFilename("x86-linux").?);
}

test "deploymentFilename - unknown target" {
    try std.testing.expectEqual(@as(?[]const u8, null), deploymentFilename("mips-linux"));
}

// ═══════════════════════════════════════════════════════════════════════════
// Wire protocol — binary message framing
// ═══════════════════════════════════════════════════════════════════════════
//
// Messages are framed: 1-byte type + type-specific payload.
// String fields: null-terminated. Binary fields: 4-byte BE length prefix + data.
// Integer fields: 4-byte BE.
//
// Wire protocol message types — carried over TCP/SOCKS5 via tcp frame protocol.

/// Wire protocol message types (inner payload inside tcp frames).
/// These flow over TCP/SOCKS5 connections — not directly on UDP :2121.
pub const MsgType = enum(u8) {
    // Host → Guest commands
    pty_spawn = 0x10,
    pty_exec_input = 0x11,
    _unused_0x12 = 0x12,
    _unused_0x13 = 0x13,
    download_cmd = 0x14,

    // Guest → Host responses
    pty_exec_output = 0x15,
    pty_exec_done = 0x16,
    upload_result = 0x17,
    _unused_0x18 = 0x18,

    // Host → Guest: upgrade push
    upgrade_cmd = 0x1a,
    _unused_0x19 = 0x19,

    // File transfer
    upload_cmd = 0x1b,

    // Guest → Host: download 校验结果（file_size + sha256_hex）
    download_result = 0x1c,
};

// ── Serialization helpers ──

pub const MAX_BLOB_LEN: u32 = 1024 * 1024;
pub const MAX_STRING_LEN: u32 = 8192;

fn writeString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
    try buf.append(allocator, 0);
}

fn writeBlob(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, data);
}

fn writeI32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void {
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &int_buf, v, .big);
    try buf.appendSlice(allocator, &int_buf);
}

fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &int_buf, v, .big);
    try buf.appendSlice(allocator, &int_buf);
}

pub fn readString(data: []const u8, pos: *usize) ?[]const u8 {
    return readStringMax(data, pos, MAX_STRING_LEN);
}

pub fn readStringMax(data: []const u8, pos: *usize, max_len: u32) ?[]const u8 {
    const start = pos.*;
    const remaining = data[start..];
    const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return null;
    if (end > max_len) return null;
    pos.* = start + end + 1;
    return remaining[0..end];
}

pub fn readBlob(data: []const u8, pos: *usize) ?[]const u8 {
    return readBlobMax(data, pos, MAX_BLOB_LEN);
}

pub fn readBlobMax(data: []const u8, pos: *usize, max_len: u32) ?[]const u8 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    const len = std.mem.readInt(u32, data[start..][0..4], .big);
    if (len > max_len) return null;
    const blob_start = start + 4;
    if (blob_start + len > data.len) return null;
    pos.* = blob_start + len;
    return data[blob_start..][0..len];
}

pub fn readI32(data: []const u8, pos: *usize) ?i32 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    pos.* = start + 4;
    return std.mem.readInt(i32, data[start..][0..4], .big);
}

pub fn readU32(data: []const u8, pos: *usize) ?u32 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    pos.* = start + 4;
    return std.mem.readInt(u32, data[start..][0..4], .big);
}

// ── Build functions ──

pub fn buildPtySpawn(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_spawn));
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyExecInput(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_exec_input));
    try writeString(&buf, allocator, cmd_id);
    try buf.appendSlice(allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildDownloadCmd(allocator: std.mem.Allocator, cmd_id: []const u8, path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.download_cmd));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, path);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUploadCmd(allocator: std.mem.Allocator, cmd_id: []const u8, path: []const u8, file_size: u32, file_hash: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upload_cmd));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, path);
    try writeU32(&buf, allocator, file_size);
    try writeString(&buf, allocator, file_hash);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUpgradeCmd(allocator: std.mem.Allocator, cmd_id: []const u8, target: []const u8, file_size: u32, sha256_hex: []const u8, version: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upgrade_cmd));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, target);
    try writeU32(&buf, allocator, file_size);
    try writeString(&buf, allocator, sha256_hex);
    try writeString(&buf, allocator, version);
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyExecOutput(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_exec_output));
    try writeString(&buf, allocator, cmd_id);
    try writeBlob(&buf, allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyExecDone(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_exec_done));
    try writeString(&buf, allocator, cmd_id);
    try writeI32(&buf, allocator, exit_code);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUploadResult(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upload_result));
    try writeString(&buf, allocator, cmd_id);
    try writeI32(&buf, allocator, exit_code);
    return buf.toOwnedSlice(allocator);
}

/// 构建 download_result 帧：cmd_id(null-term) + file_size(u32 BE) + sha256_hex(null-term)。
/// 布局与 upload_cmd 的 file_size/hash 字段写法对称（hash 字段用 writeString 带 null 终止）。
pub fn buildDownloadResult(allocator: std.mem.Allocator, cmd_id: []const u8, file_size: u32, sha256_hex: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.download_result));
    try writeString(&buf, allocator, cmd_id);
    try writeU32(&buf, allocator, file_size);
    try writeString(&buf, allocator, sha256_hex);
    return buf.toOwnedSlice(allocator);
}

// ── Parse result structs ──

pub const PtyExecInputData = struct {
    cmd_id: []const u8,
    command: []const u8,
};

pub const PtyExecOutputData = struct {
    cmd_id: []const u8,
    data: []const u8,
};

pub const PtyExecDoneData = struct {
    cmd_id: []const u8,
    exit_code: i32,
};

pub const UploadResultData = struct {
    cmd_id: []const u8,
    exit_code: i32,
};

pub const DownloadResultData = struct {
    cmd_id: []const u8,
    file_size: u32,
    sha256_hex: []const u8,
};

pub const DownloadCmdData = struct {
    cmd_id: []const u8,
    path: []const u8,
};

pub const UploadCmdData = struct {
    cmd_id: []const u8,
    path: []const u8,
    file_size: u32,
    file_hash: []const u8,
};

pub const UpgradeCmdData = struct {
    cmd_id: []const u8,
    target: []const u8,
    file_size: u32,
    sha256_hex: []const u8,
    version: []const u8,
};

// ── Parse functions ──
//
// CRITICAL CONVENTION: ALL parse*() functions start at pos=0 and expect data
// WITHOUT the leading type byte. Every dispatcher MUST pass `data[1..]`.

pub fn parsePtyExecInput(data: []const u8) ?PtyExecInputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const command = data[pos..];
    return .{ .cmd_id = cmd_id, .command = command };
}

pub fn parsePtyExecOutput(data: []const u8) ?PtyExecOutputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const payload = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .data = payload };
}

pub fn parsePtyExecDone(data: []const u8) ?PtyExecDoneData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code };
}

pub fn parseUploadResult(data: []const u8) ?UploadResultData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code };
}

pub fn parseDownloadResult(data: []const u8) ?DownloadResultData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const file_size = readU32(data, &pos) orelse return null;
    const sha256_hex = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .file_size = file_size, .sha256_hex = sha256_hex };
}

pub fn parseDownloadCmd(data: []const u8) ?DownloadCmdData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path };
}

pub fn parseUploadCmd(data: []const u8) ?UploadCmdData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    const file_size = readU32(data, &pos) orelse return null;
    const file_hash = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path, .file_size = file_size, .file_hash = file_hash };
}

pub fn parseUpgradeCmd(data: []const u8) ?UpgradeCmdData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const target = readString(data, &pos) orelse return null;
    const file_size = readU32(data, &pos) orelse return null;
    const sha256_hex = readString(data, &pos) orelse return null;
    const version = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .target = target, .file_size = file_size, .sha256_hex = sha256_hex, .version = version };
}

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

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Get a string field from a JSON object. Returns null if missing or wrong type.
pub fn jsonGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get an integer field from a JSON object.
pub fn jsonGetInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Build a simple JSON object string. Caller owns returned memory.
pub fn buildJson(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, fmt, args);
}

/// Escape a string for JSON (minimal — only handles the common cases).
pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, s.len);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try buf.print(allocator, "\\u{d:0>4}", .{c}),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Get a nested object field from a JSON object. Returns null if missing or wrong type.
pub fn jsonGetNestedObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |inner| inner,
        else => null,
    };
}

/// Append a JSON-RPC id value to a buffer (handles all id types).
pub fn jsonAppendId(list: *std.ArrayList(u8), allocator: std.mem.Allocator, id: std.json.Value) !void {
    switch (id) {
        .null => try list.appendSlice(allocator, "null"),
        .integer => |n| try list.print(allocator, "{d}", .{n}),
        .string => |s| try list.print(allocator, "\"{s}\"", .{s}),
        .float => |f| try list.print(allocator, "{d}", .{f}),
        .number_string => |s| try list.appendSlice(allocator, s),
        .bool => |b| try list.appendSlice(allocator, if (b) "true" else "false"),
        else => try list.appendSlice(allocator, "null"),
    }
}

/// Build a JSON-RPC success response.
pub fn jsonBuildResponse(allocator: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC error response.
pub fn jsonBuildError(allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id);
    try buf.print(allocator, ",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    const escaped_msg = try jsonEscape(allocator, message);
    defer allocator.free(escaped_msg);
    try buf.appendSlice(allocator, escaped_msg);
    try buf.appendSlice(allocator, "\"}}");
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Shell command helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Build command with appropriate MDELIM marker for the guest's shell.
/// POSIX (/bin/sh, /bin/bash, ...): uses "; echo MDELIM:$?\n"
/// Windows (cmd.exe): uses "& echo MDELIM:%errorlevel%\r\n"
pub fn buildCmdWithMarker(allocator: std.mem.Allocator, shell: []const u8, command: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, shell, "cmd.exe") != null) {
        return try std.fmt.allocPrint(allocator, "{s} & echo MDELIM:%errorlevel%\r\n", .{command});
    }
    return try std.fmt.allocPrint(allocator, "{s}; echo MDELIM:$?\n", .{command});
}

/// Result of scanning accumulated pty output for MDELIM marker.
pub const MarkerResult = struct {
    exit_code: i32 = -1,
    found: bool = false,
};

/// Scan accumulated pty output for MDELIM:N\n marker.
/// If found, strips the marker from output and returns exit_code.
/// Uses lastIndexOf to handle macOS pty echo of the marker in command text.
pub fn scanForMarker(output: *std.ArrayList(u8)) MarkerResult {
    const haystack = output.items;
    const marker = "MDELIM:";

    // Use lastIndexOf: the real marker is always LAST in the output stream.
    const pos = std.mem.lastIndexOf(u8, haystack, marker) orelse return .{};

    // Validate exit code: region between MDELIM: and \n must contain
    // only digits and optional leading '-'.
    const after = pos + marker.len;
    if (after >= haystack.len) return .{};

    var ec: i32 = 0;
    var neg = false;
    var i: usize = after;
    var has_digit = false;
    while (i < haystack.len and haystack[i] != '\n') : (i += 1) {
        if (haystack[i] == '\r') {
            // CR before LF — skip, part of CRLF line ending
        } else if (haystack[i] == '-') {
            if (has_digit) return .{};
            neg = true;
        } else if (haystack[i] >= '0' and haystack[i] <= '9') {
            has_digit = true;
            ec = ec * 10 + @as(i32, @intCast(haystack[i] - '0'));
        } else {
            return .{};
        }
    }
    if (i >= haystack.len) return .{}; // No newline yet
    if (!has_digit) return .{};

    if (neg) ec = -ec;

    // Strip marker + exit code + newline
    output.shrinkRetainingCapacity(pos);

    return .{ .exit_code = ec, .found = true };
}

// ═══════════════════════════════════════════════════════════════════════════
// Frame Protocol
// ═══════════════════════════════════════════════════════════════════════════

/// Max frame size 16 MB (for file transfers).
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// Send a frame: write 4-byte BE length + payload.
pub fn sendFrame(fd: tcp.socket_t, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    const n1 = tcp.sockWrite(fd, &len_buf, len_buf.len);
    if (n1 != 4) return error.SendFailed;
    const n2 = tcp.sockWrite(fd, data.ptr, data.len);
    if (n2 != data.len) return error.SendFailed;
}

/// Receive a frame: read 4-byte BE length → allocate buffer → read payload.
/// Returns caller-owned memory (must free with allocator).
pub fn recvFrame(allocator: std.mem.Allocator, fd: tcp.socket_t) ![]const u8 {
    var len_buf: [4]u8 = undefined;
    const n = try recvExact(fd, &len_buf);
    if (n == 0) return error.ConnectionClosed;
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > MAX_FRAME) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    const m = try recvExact(fd, payload);
    if (m < len) return error.TruncatedFrame;
    return payload;
}

/// Read exactly len bytes. Returns actual read count (0 = EOF).
pub fn recvExact(fd: tcp.socket_t, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = tcp.sockRead(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return error.ConnectionClosed; // read error on dead socket
        if (n == 0) return total; // EOF
        total += @intCast(n);
    }
    return total;
}

/// Send thread args (for large-payload tests to avoid socketpair deadlock).
const SendArgs = struct { fd: tcp.socket_t, data: []const u8 };

/// Thread entry: send a frame.
fn sendInThread(args: SendArgs) void {
    sendFrame(args.fd, args.data) catch @panic("sendFrame failed in thread");
}

// ═══════════════════════════════════════════════════════════════════════════
// Connection — TCP + SOCKS5 framed connection abstraction
// ═══════════════════════════════════════════════════════════════════════════

pub const Connection = struct {
    fd: tcp.socket_t,
    alive: bool,

    /// Send a frame (4B BE length + payload).
    pub fn send(self: *Connection, data: []const u8) !void {
        return sendFrame(self.fd, data);
    }

    /// Send and flush (same as send — TCP has no flush concept).
    pub fn sendAndFlush(self: *Connection, data: []const u8, _: u32) !void {
        return sendFrame(self.fd, data);
    }

    /// Receive a frame: read 4B length → read payload into buf.
    /// Returns payload byte count. buf must be large enough for the full frame.
    /// Returns 0 if connection closed.
    pub fn recv(self: *Connection, buf: []u8) !usize {
        var len_buf: [4]u8 = undefined;
        const nr = recvExact(self.fd, &len_buf) catch |err| {
            if (err == error.ConnectionClosed) {
                self.alive = false;
                return 0;
            }
            return err;
        };
        if (nr == 0) {
            self.alive = false;
            return 0;
        }
        const len = std.mem.readInt(u32, &len_buf, .big);
        if (len > buf.len) return error.BufferTooSmall;

        return recvExact(self.fd, buf[0..len]) catch |err| {
            if (err == error.ConnectionClosed) {
                self.alive = false;
                return 0;
            }
            return err;
        };
    }

    /// Whether connection is alive.
    pub fn isAlive(self: *Connection) bool {
        return self.alive;
    }

    /// Close connection and release resources.
    pub fn deinit(self: *Connection) void {
        self.alive = false;
        tcp.sockShutdown(self.fd, 2); // SHUT_RDWR
        tcp.sockClose(self.fd);
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

// ── Wire protocol tests ──

test "pty_spawn build" {
    const allocator = std.testing.allocator;
    const msg = try buildPtySpawn(allocator);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_spawn), msg[0]);
    try std.testing.expectEqual(@as(usize, 1), msg.len);
}

test "pty_exec_input round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyExecInput(allocator, "cmd1", "echo hello\n");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_exec_input), msg[0]);
    const parsed = parsePtyExecInput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd1", parsed.cmd_id);
    try std.testing.expectEqualStrings("echo hello\n", parsed.command);
}

test "pty_exec_input with MDELIM" {
    const allocator = std.testing.allocator;
    const cmd = "uname -a; echo MDELIM:$?\n";
    const msg = try buildPtyExecInput(allocator, "x1", cmd);
    defer allocator.free(msg);
    const parsed = parsePtyExecInput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed.cmd_id);
    try std.testing.expectEqualStrings(cmd, parsed.command);
}

test "upload_result round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildUploadResult(allocator, "u1", 0);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_result), msg[0]);
    const parsed = parseUploadResult(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u1", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, 0), parsed.exit_code);
}

test "upload_result with error code" {
    const allocator = std.testing.allocator;
    const msg = try buildUploadResult(allocator, "u3", -1);
    defer allocator.free(msg);
    const parsed = parseUploadResult(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u3", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, -1), parsed.exit_code);
}

test "download_result round-trip" {
    const allocator = std.testing.allocator;
    const hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const msg = try buildDownloadResult(allocator, "dr1", 1048576, hash);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_result), msg[0]);
    const parsed = parseDownloadResult(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("dr1", parsed.cmd_id);
    try std.testing.expectEqual(@as(u32, 1048576), parsed.file_size);
    try std.testing.expectEqualStrings(hash, parsed.sha256_hex);
}

test "download_result empty hash" {
    const allocator = std.testing.allocator;
    const msg = try buildDownloadResult(allocator, "dr2", 0, "");
    defer allocator.free(msg);
    const parsed = parseDownloadResult(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("dr2", parsed.cmd_id);
    try std.testing.expectEqual(@as(u32, 0), parsed.file_size);
    try std.testing.expectEqualStrings("", parsed.sha256_hex);
}

test "download_cmd round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildDownloadCmd(allocator, "d1", "/etc/hosts");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_cmd), msg[0]);
    const parsed = parseDownloadCmd(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("d1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/etc/hosts", parsed.path);
}

test "pty_exec_output round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyExecOutput(allocator, "cmd2", "hello world");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_exec_output), msg[0]);
    const parsed = parsePtyExecOutput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd2", parsed.cmd_id);
    try std.testing.expectEqualStrings("hello world", parsed.data);
}

test "pty_exec_output with MDELIM marker" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyExecOutput(allocator, "cmd3", "hello\nMDELIM:0\n");
    defer allocator.free(msg);
    const parsed = parsePtyExecOutput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd3", parsed.cmd_id);
    try std.testing.expectEqualStrings("hello\nMDELIM:0\n", parsed.data);
}

test "pty_exec_done round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyExecDone(allocator, "cmd4", 42);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_exec_done), msg[0]);
    const parsed = parsePtyExecDone(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd4", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, 42), parsed.exit_code);
}

test "full flow: spawn → exec_input → output → done" {
    const allocator = std.testing.allocator;

    const spawn = try buildPtySpawn(allocator);
    defer allocator.free(spawn);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_spawn), spawn[0]);

    const input = try buildPtyExecInput(allocator, "x1", "uname -a; echo MDELIM:$?\n");
    defer allocator.free(input);
    const parsed_input = parsePtyExecInput(input[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed_input.cmd_id);

    const output = try buildPtyExecOutput(allocator, "x1", "Linux\nMDELIM:0\n");
    defer allocator.free(output);
    const parsed_out = parsePtyExecOutput(output[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed_out.cmd_id);
    try std.testing.expectEqualStrings("Linux\nMDELIM:0\n", parsed_out.data);

    const done = try buildPtyExecDone(allocator, "x1", 0);
    defer allocator.free(done);
    const parsed_done = parsePtyExecDone(done[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed_done.cmd_id);
    try std.testing.expectEqual(@as(i32, 0), parsed_done.exit_code);
}

test "pty_exec_output with binary data" {
    const allocator = std.testing.allocator;
    const binary = &[_]u8{ 0x00, 0x01, 0xFF, 0xFE };
    const msg = try buildPtyExecOutput(allocator, "b1", binary);
    defer allocator.free(msg);
    const parsed = parsePtyExecOutput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("b1", parsed.cmd_id);
    try std.testing.expectEqualSlices(u8, binary, parsed.data);
}

test "upgrade_cmd round-trip" {
    const allocator = std.testing.allocator;
    const hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const msg = try buildUpgradeCmd(allocator, "up1", "aarch64-linux-musl", 1048576, hash, VERSION);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upgrade_cmd), msg[0]);
    const parsed = parseUpgradeCmd(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("up1", parsed.cmd_id);
    try std.testing.expectEqualStrings("aarch64-linux-musl", parsed.target);
    try std.testing.expectEqual(@as(u32, 1048576), parsed.file_size);
    try std.testing.expectEqualStrings(hash, parsed.sha256_hex);
    try std.testing.expectEqualStrings(VERSION, parsed.version);
}

test "upload_cmd round-trip" {
    const allocator = std.testing.allocator;
    const hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const msg = try buildUploadCmd(allocator, "uc1", "/tmp/test.bin", 1024, hash);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_cmd), msg[0]);
    const parsed = parseUploadCmd(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("uc1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/tmp/test.bin", parsed.path);
    try std.testing.expectEqual(@as(u32, 1024), parsed.file_size);
    try std.testing.expectEqualStrings(hash, parsed.file_hash);
}

test "readBlobMax - respects max_len" {
    var buf: [4 + 8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 8, .big);
    @memset(buf[4..12], 0xAB);

    var pos: usize = 0;
    const blob = readBlobMax(&buf, &pos, 8) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 8), blob.len);

    pos = 0;
    try std.testing.expect(readBlobMax(&buf, &pos, 4) == null);
}

test "readBlobMax - returns null on len=0xFFFFFFFF (would exceed max)" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xFFFFFFFF, .big);
    var pos: usize = 0;
    try std.testing.expect(readBlobMax(&buf, &pos, MAX_BLOB_LEN) == null);
}

test "readBlobMax - returns null on truncated data" {
    var buf: [4 + 2]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 8, .big);
    var pos: usize = 0;
    try std.testing.expect(readBlobMax(&buf, &pos, 16) == null);
}

test "readStringMax - respects max_len" {
    const s: [6]u8 = "hello".* ++ [_]u8{0};
    var pos: usize = 0;
    const result = readStringMax(&s, &pos, 5) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("hello", result);

    pos = 0;
    try std.testing.expect(readStringMax(&s, &pos, 3) == null);
}

test "readStringMax - returns null on missing null terminator" {
    const s: [4]u8 = "test".*;
    var pos: usize = 0;
    try std.testing.expect(readStringMax(&s, &pos, MAX_STRING_LEN) == null);
}

test "readBlob - default max is MAX_BLOB_LEN" {
    var buf: [4 + 4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 4, .big);
    @memset(buf[4..8], 0xCD);
    var pos: usize = 0;
    const blob = readBlob(&buf, &pos) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 4), blob.len);
}

test "readString - default max is MAX_STRING_LEN" {
    const s: [6]u8 = "hello".* ++ [_]u8{0};
    var pos: usize = 0;
    const result = readString(&s, &pos) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("hello", result);
}

// ── Frame protocol tests ──

test "sendFrame/recvFrame round-trip" {
    const allocator = std.testing.allocator;
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    const msg = "hello tcp frame";
    try sendFrame(pair.a, msg);

    const received = try recvFrame(allocator, pair.b);
    defer allocator.free(received);
    try std.testing.expectEqualStrings(msg, received);
}

test "recvFrame empty" {
    const allocator = std.testing.allocator;
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    tcp.sockShutdown(pair.a, 1); // SHUT_WR=1
    const result = recvFrame(allocator, pair.b);
    try std.testing.expectError(error.ConnectionClosed, result);
}

test "recvFrame large payload" {
    const allocator = std.testing.allocator;
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    const large = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(large);
    @memset(large, 0xAB);

    const sender = try std.Thread.spawn(.{}, sendInThread, .{SendArgs{ .fd = pair.a, .data = large }});
    defer sender.join();

    const received = try recvFrame(allocator, pair.b);
    defer allocator.free(received);
    try std.testing.expectEqual(large.len, received.len);
    try std.testing.expectEqualSlices(u8, large, received);
}

test "recvFrame multiple frames" {
    const allocator = std.testing.allocator;
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    try sendFrame(pair.a, "first");
    try sendFrame(pair.a, "second");

    const r1 = try recvFrame(allocator, pair.b);
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("first", r1);

    const r2 = try recvFrame(allocator, pair.b);
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("second", r2);
}

// ── Connection tests ──

test "Connection send/recv round-trip" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    try conn.send("hello world");

    var rbuf: [256]u8 = undefined;
    // Peer reads 4B header + payload to verify correct frame format
    const nr = try recvExact(pair.b, rbuf[0..15]);
    try std.testing.expect(nr == 15);
}

test "Connection recv detects close" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    tcp.sockShutdown(pair.a, 2);
    tcp.sockClose(pair.a);

    var rbuf: [256]u8 = undefined;
    if (conn.recv(&rbuf)) |_| {} else |_| {}
    try std.testing.expect(!conn.isAlive());
}

// ── EAGAIN regression tests — non-blocking socket I/O retry ──

test "sockRead retries on EAGAIN (non-blocking socket, delayed write)" {
    const pair = try tcp.makeNonBlockingPair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Writer thread delays 50ms then writes, simulating split packet arrival.
    // sockRead must retry on EAGAIN until data is available.
    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            var t: std.Io.Threaded = .init_single_threaded;
            std.Io.sleep(t.io(), std.Io.Duration.fromMilliseconds(50), .real) catch {};
            _ = tcp.sockWrite(fd, "EAGAIN_OK", 9);
        }
    }.run, .{pair.b});
    defer writer_thread.join();

    var buf: [9]u8 = undefined;
    var off: usize = 0;
    while (off < buf.len) {
        const n = tcp.sockRead(pair.a, buf[off..].ptr, buf.len - off);
        if (n < 0) {
            @panic("sockRead returned error on non-blocking test socket");
        }
        if (n == 0) {
            continue;
        }
        off += @intCast(n);
    }
    try std.testing.expectEqualStrings("EAGAIN_OK", buf[0..]);
}

test "sendFrame/recvFrame on non-blocking socket" {
    const allocator = std.testing.allocator;
    const pair = try tcp.makeNonBlockingPair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    const msg = "non-blocking frame test";
    const sender = try std.Thread.spawn(.{}, sendInThread, .{SendArgs{ .fd = pair.a, .data = msg }});
    defer sender.join();

    const received = try recvFrame(allocator, pair.b);
    defer allocator.free(received);
    try std.testing.expectEqualStrings(msg, received);
}

test "recvExact handles partial reads on non-blocking socket" {
    const pair = try tcp.makeNonBlockingPair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    const data = "0123456789ABCDEF";
    _ = tcp.sockWrite(pair.b, data, data.len);

    var buf: [16]u8 = undefined;
    const n = try recvExact(pair.a, buf[0..]);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
}
