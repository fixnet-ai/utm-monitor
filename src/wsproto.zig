//! Binary WebSocket protocol for Guest↔Host communication.
//!
//! Each WebSocket binary frame:
//!   Byte 0: message type (u8)
//!   Remaining: type-specific payload
//!
//! String fields: null-terminated.
//! Binary fields: 4-byte big-endian length prefix + data.
//! Integer fields: 4-byte big-endian.

const std = @import("std");

pub const MsgType = enum(u8) {
    announce = 1, // guest→host: hostname, ip, target, mac, version, shell
    upload_req = 4, // host→guest: cmd_id, path, data
    upload_resp = 5, // guest→host: cmd_id, exit_code
    download_req = 6, // host→guest: cmd_id, path
    download_resp = 7, // guest→host: cmd_id, exit_code, data

    // v0.5.0: pty session model — persistent pty per WebSocket connection
    pty_spawn = 12, // host→guest: spawn pty session (no payload)
    pty_input = 13, // host→guest: cmd_id, stdin_data (raw bytes after null-term cmd_id)
    pty_output = 14, // guest→host: cmd_id, stdout_data (raw bytes after null-term cmd_id)
    pty_signal = 15, // host→guest: 1-byte signal (0=SIGINT/CtrlC, 1=SIGTERM, 2=SIGHUP)
    pty_resize = 16, // host→guest: rows(u16 BE) + cols(u16 BE)
};

/// Write a null-terminated string into buf.
fn writeString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
    try buf.append(allocator, 0);
}

/// Write a 4-byte big-endian u32 length-prefixed byte sequence into buf.
fn writeBlob(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, data);
}

/// Read a null-terminated string from data starting at pos. Advances pos past the null.
/// Returns null if no null byte found.
pub fn readString(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    const remaining = data[start..];
    const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return null;
    pos.* = start + end + 1;
    return remaining[0..end];
}

/// Read a length-prefixed blob from data starting at pos. Advances pos past the data.
/// Returns null if not enough data.
pub fn readBlob(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    const len = std.mem.readInt(u32, data[start..][0..4], .big);
    const blob_start = start + 4;
    if (blob_start + len > data.len) return null;
    pos.* = blob_start + len;
    return data[blob_start..][0..len];
}

/// Read a 4-byte big-endian i32 from data at pos. Advances pos.
pub fn readI32(data: []const u8, pos: *usize) ?i32 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    pos.* = start + 4;
    return std.mem.readInt(i32, data[start..][0..4], .big);
}

// ═══════════════════════════════════════════════════════════════════════════
// Build functions (allocates and returns complete binary frame)
// ═══════════════════════════════════════════════════════════════════════════

pub fn buildAnnounce(
    allocator: std.mem.Allocator,
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    version: []const u8,
    shell: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.announce));
    try writeString(&buf, allocator, hostname);
    try writeString(&buf, allocator, ip);
    try writeString(&buf, allocator, target);
    try writeString(&buf, allocator, mac);
    try writeString(&buf, allocator, version);
    try writeString(&buf, allocator, shell);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUploadReq(allocator: std.mem.Allocator, cmd_id: []const u8, path: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upload_req));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, path);
    try writeBlob(&buf, allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUploadResp(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upload_resp));
    try writeString(&buf, allocator, cmd_id);
    var exit_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &exit_buf, exit_code, .big);
    try buf.appendSlice(allocator, &exit_buf);
    return buf.toOwnedSlice(allocator);
}

pub fn buildDownloadReq(allocator: std.mem.Allocator, cmd_id: []const u8, path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.download_req));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, path);
    return buf.toOwnedSlice(allocator);
}

pub fn buildDownloadResp(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.download_resp));
    try writeString(&buf, allocator, cmd_id);
    var exit_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &exit_buf, exit_code, .big);
    try buf.appendSlice(allocator, &exit_buf);
    try writeBlob(&buf, allocator, data);
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// v0.5.0: pty session model — build functions
// ═══════════════════════════════════════════════════════════════════════════

pub fn buildPtySpawn(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_spawn));
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyInput(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_input));
    try writeString(&buf, allocator, cmd_id);
    try buf.appendSlice(allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyOutput(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_output));
    try writeString(&buf, allocator, cmd_id);
    try buf.appendSlice(allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtySignal(allocator: std.mem.Allocator, signal: u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_signal));
    try buf.append(allocator, signal);
    return buf.toOwnedSlice(allocator);
}

pub fn buildPtyResize(allocator: std.mem.Allocator, rows: u16, cols: u16) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_resize));
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(u16, int_buf[0..2], rows, .big);
    std.mem.writeInt(u16, int_buf[2..4], cols, .big);
    try buf.appendSlice(allocator, &int_buf);
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Parse functions
// ═══════════════════════════════════════════════════════════════════════════

pub const AnnounceData = struct {
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    version: []const u8,
    shell: []const u8,
};

pub fn parseAnnounce(data: []const u8) ?AnnounceData {
    var pos: usize = 0;
    const hostname = readString(data, &pos) orelse return null;
    const ip = readString(data, &pos) orelse return null;
    const target = readString(data, &pos) orelse return null;
    const mac = readString(data, &pos) orelse return null;
    const version = readString(data, &pos) orelse return null;
    const shell = readString(data, &pos) orelse return null;
    return .{ .hostname = hostname, .ip = ip, .target = target, .mac = mac, .version = version, .shell = shell };
}

pub const UploadReqData = struct {
    cmd_id: []const u8,
    path: []const u8,
    file_data: []const u8,
};

pub fn parseUploadReq(data: []const u8) ?UploadReqData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    const file_data = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path, .file_data = file_data };
}

pub const UploadRespData = struct {
    cmd_id: []const u8,
    exit_code: i32,
};

pub fn parseUploadResp(data: []const u8) ?UploadRespData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code };
}

pub const DownloadReqData = struct {
    cmd_id: []const u8,
    path: []const u8,
};

pub fn parseDownloadReq(data: []const u8) ?DownloadReqData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path };
}

pub const DownloadRespData = struct {
    cmd_id: []const u8,
    exit_code: i32,
    file_data: []const u8,
};

pub fn parseDownloadResp(data: []const u8) ?DownloadRespData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    const file_data = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code, .file_data = file_data };
}

// ═══════════════════════════════════════════════════════════════════════════
// v0.5.0: pty session model — parse functions
// ═══════════════════════════════════════════════════════════════════════════

pub const PtyOutputData = struct {
    cmd_id: []const u8,
    data: []const u8,
};

pub fn parsePtyOutput(data: []const u8) ?PtyOutputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const payload = data[pos..];
    return .{ .cmd_id = cmd_id, .data = payload };
}

pub const PtyInputData = struct {
    cmd_id: []const u8,
    data: []const u8,
};

pub fn parsePtyInput(data: []const u8) ?PtyInputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const payload = data[pos..];
    return .{ .cmd_id = cmd_id, .data = payload };
}

pub const PtyResizeData = struct {
    rows: u16,
    cols: u16,
};

pub fn parsePtyResize(data: []const u8) ?PtyResizeData {
    if (data.len < 4) return null;
    const rows = std.mem.readInt(u16, data[0..2], .big);
    const cols = std.mem.readInt(u16, data[2..4], .big);
    return .{ .rows = rows, .cols = cols };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "announce round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildAnnounce(allocator, "testvm", "10.0.0.1", "aarch64-linux", "aa:bb:cc:dd:ee:ff", "0.5.0", "/bin/sh");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.announce), msg[0]);
    const parsed = parseAnnounce(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("testvm", parsed.hostname);
    try std.testing.expectEqualStrings("10.0.0.1", parsed.ip);
    try std.testing.expectEqualStrings("aarch64-linux", parsed.target);
    try std.testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", parsed.mac);
    try std.testing.expectEqualStrings("0.5.0", parsed.version);
    try std.testing.expectEqualStrings("/bin/sh", parsed.shell);
}

test "upload round-trip with binary data" {
    const allocator = std.testing.allocator;
    const binary_data = &[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD };
    const msg = try buildUploadReq(allocator, "u1", "/tmp/test.bin", binary_data);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_req), msg[0]);
    const parsed = parseUploadReq(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/tmp/test.bin", parsed.path);
    try std.testing.expectEqualSlices(u8, binary_data, parsed.file_data);
}

test "upload_resp round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildUploadResp(allocator, "u1", 0);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_resp), msg[0]);
    const parsed = parseUploadResp(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u1", parsed.cmd_id);
    try std.testing.expectEqual(0, parsed.exit_code);
}

test "download round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildDownloadReq(allocator, "d1", "/etc/hosts");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_req), msg[0]);
    const parsed = parseDownloadReq(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("d1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/etc/hosts", parsed.path);
}

test "download_resp with binary data" {
    const allocator = std.testing.allocator;
    const binary_data = &[_]u8{ 0x00, 0x01, 0x02, 0xFF };
    const msg = try buildDownloadResp(allocator, "d1", 0, binary_data);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_resp), msg[0]);
    const parsed = parseDownloadResp(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("d1", parsed.cmd_id);
    try std.testing.expectEqual(0, parsed.exit_code);
    try std.testing.expectEqualSlices(u8, binary_data, parsed.file_data);
}

test "pty_spawn build" {
    const allocator = std.testing.allocator;
    const msg = try buildPtySpawn(allocator);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_spawn), msg[0]);
    try std.testing.expectEqual(@as(usize, 1), msg.len);
}

test "pty_input round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyInput(allocator, "cmd1", "echo hello\n");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_input), msg[0]);
    const parsed = parsePtyInput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd1", parsed.cmd_id);
    try std.testing.expectEqualStrings("echo hello\n", parsed.data);
}

test "pty_output round-trip with binary data" {
    const allocator = std.testing.allocator;
    const binary = &[_]u8{ 0x00, 0x01, 0xFF, 0xFE };
    const msg = try buildPtyOutput(allocator, "cmd2", binary);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_output), msg[0]);
    const parsed = parsePtyOutput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd2", parsed.cmd_id);
    try std.testing.expectEqualSlices(u8, binary, parsed.data);
}

test "pty_output with MDELIM marker" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyOutput(allocator, "cmd3", "hello\nMDELIM:0\n");
    defer allocator.free(msg);
    const parsed = parsePtyOutput(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("cmd3", parsed.cmd_id);
    try std.testing.expectEqualStrings("hello\nMDELIM:0\n", parsed.data);
}

test "pty_signal build" {
    const allocator = std.testing.allocator;
    const msg = try buildPtySignal(allocator, 0); // SIGINT
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_signal), msg[0]);
    try std.testing.expectEqual(@as(u8, 1), msg.len - 1);
    try std.testing.expectEqual(@as(u8, 0), msg[1]);
}

test "pty_resize round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildPtyResize(allocator, 80, 24);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_resize), msg[0]);
    const parsed = parsePtyResize(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 80), parsed.rows);
    try std.testing.expectEqual(@as(u16, 24), parsed.cols);
}

test "pty full flow: spawn → input → output → signal" {
    const allocator = std.testing.allocator;

    const spawn = try buildPtySpawn(allocator);
    defer allocator.free(spawn);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_spawn), spawn[0]);

    const input = try buildPtyInput(allocator, "x1", "uname -a; echo MDELIM:$?\n");
    defer allocator.free(input);
    const parsed_input = parsePtyInput(input[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed_input.cmd_id);
    try std.testing.expectEqualStrings("uname -a; echo MDELIM:$?\n", parsed_input.data);

    const output = try buildPtyOutput(allocator, "x1", "Linux\nMDELIM:0\n");
    defer allocator.free(output);
    const parsed_out = parsePtyOutput(output[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("x1", parsed_out.cmd_id);
    try std.testing.expectEqualStrings("Linux\nMDELIM:0\n", parsed_out.data);

    const sig = try buildPtySignal(allocator, 0);
    defer allocator.free(sig);
    try std.testing.expectEqual(@intFromEnum(MsgType.pty_signal), sig[0]);
}
