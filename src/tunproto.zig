//! Tunnel protocol — binary message framing for KCP tunnel communication.
//!
//! Replaces wsproto.zig after WebSocket removal (v0.11.0).
//! Messages are framed identically to wsproto: 1-byte type + type-specific payload.
//! String fields: null-terminated. Binary fields: 4-byte BE length prefix + data.
//! Integer fields: 4-byte BE.

const std = @import("std");

/// Tunnel protocol message types (inner payload inside KCP tunnel).
/// These flow over the KCP reliable transport — not directly on UDP :2121.
pub const MsgType = enum(u8) {
    // Host → Guest commands
    pty_spawn = 0x10, // Trigger pty shell creation (no payload)
    pty_exec_input = 0x11, // cmd_id(NT) + command_data
    signal_cmd = 0x12, // 1-byte signal (0=SIGINT, 1=SIGTERM)
    upload_data = 0x13, // cmd_id(NT) + path(NT) + file_data(len-prefixed blob)
    download_cmd = 0x14, // cmd_id(NT) + path(NT)

    // Guest → Host responses
    pty_exec_output = 0x15, // cmd_id(NT) + chunk_data
    pty_exec_done = 0x16, // cmd_id(NT) + exit_code(BE i32)
    upload_result = 0x17, // cmd_id(NT) + exit_code(BE i32)
    download_result = 0x18, // cmd_id(NT) + exit_code(BE i32) + file_data(len-prefixed blob)
};

// ═══════════════════════════════════════════════════════════════════════════
// Serialization helpers
// ═══════════════════════════════════════════════════════════════════════════

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

pub fn readString(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    const remaining = data[start..];
    const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return null;
    pos.* = start + end + 1;
    return remaining[0..end];
}

pub fn readBlob(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    const len = std.mem.readInt(u32, data[start..][0..4], .big);
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

// ═══════════════════════════════════════════════════════════════════════════
// Build functions — Host → Guest
// ═══════════════════════════════════════════════════════════════════════════

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

pub fn buildSignalCmd(allocator: std.mem.Allocator, signal: u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.signal_cmd));
    try buf.append(allocator, signal);
    return buf.toOwnedSlice(allocator);
}

pub fn buildUploadData(allocator: std.mem.Allocator, cmd_id: []const u8, path: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upload_data));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, path);
    try writeBlob(&buf, allocator, data);
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

// ═══════════════════════════════════════════════════════════════════════════
// Build functions — Guest → Host
// ═══════════════════════════════════════════════════════════════════════════

pub fn buildPtyExecOutput(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.pty_exec_output));
    try writeString(&buf, allocator, cmd_id);
    try buf.appendSlice(allocator, data);
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

pub fn buildDownloadResult(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.download_result));
    try writeString(&buf, allocator, cmd_id);
    try writeI32(&buf, allocator, exit_code);
    try writeBlob(&buf, allocator, data);
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Parse result structs
// ═══════════════════════════════════════════════════════════════════════════

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

pub const UploadDataData = struct {
    cmd_id: []const u8,
    path: []const u8,
    file_data: []const u8,
};

pub const UploadResultData = struct {
    cmd_id: []const u8,
    exit_code: i32,
};

pub const DownloadCmdData = struct {
    cmd_id: []const u8,
    path: []const u8,
};

pub const DownloadResultData = struct {
    cmd_id: []const u8,
    exit_code: i32,
    file_data: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// Parse functions
// ═══════════════════════════════════════════════════════════════════════════

pub fn parsePtyExecInput(data: []const u8) ?PtyExecInputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const command = data[pos..];
    return .{ .cmd_id = cmd_id, .command = command };
}

pub fn parsePtyExecOutput(data: []const u8) ?PtyExecOutputData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const payload = data[pos..];
    return .{ .cmd_id = cmd_id, .data = payload };
}

pub fn parsePtyExecDone(data: []const u8) ?PtyExecDoneData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code };
}

pub fn parseUploadData(data: []const u8) ?UploadDataData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    const file_data = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path, .file_data = file_data };
}

pub fn parseUploadResult(data: []const u8) ?UploadResultData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code };
}

pub fn parseDownloadCmd(data: []const u8) ?DownloadCmdData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path };
}

pub fn parseDownloadResult(data: []const u8) ?DownloadResultData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    const file_data = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code, .file_data = file_data };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

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

test "signal_cmd build" {
    const allocator = std.testing.allocator;
    const msg = try buildSignalCmd(allocator, 0); // SIGINT
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.signal_cmd), msg[0]);
    try std.testing.expectEqual(@as(usize, 2), msg.len);
    try std.testing.expectEqual(@as(u8, 0), msg[1]);
}

test "upload_data round-trip with binary data" {
    const allocator = std.testing.allocator;
    const binary = &[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD };
    const msg = try buildUploadData(allocator, "u1", "/tmp/test.bin", binary);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_data), msg[0]);
    const parsed = parseUploadData(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/tmp/test.bin", parsed.path);
    try std.testing.expectEqualSlices(u8, binary, parsed.file_data);
}

test "upload_data large file" {
    const allocator = std.testing.allocator;
    const large: [10000]u8 = [_]u8{0xAB} ** 10000;
    const msg = try buildUploadData(allocator, "u2", "/large.bin", &large);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_data), msg[0]);
    const parsed = parseUploadData(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("u2", parsed.cmd_id);
    try std.testing.expectEqualStrings("/large.bin", parsed.path);
    try std.testing.expectEqualSlices(u8, &large, parsed.file_data);
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

test "download_cmd round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildDownloadCmd(allocator, "d1", "/etc/hosts");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_cmd), msg[0]);
    const parsed = parseDownloadCmd(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("d1", parsed.cmd_id);
    try std.testing.expectEqualStrings("/etc/hosts", parsed.path);
}

test "download_result round-trip with binary data" {
    const allocator = std.testing.allocator;
    const binary = &[_]u8{ 0x00, 0x01, 0x02, 0xFF };
    const msg = try buildDownloadResult(allocator, "d1", 0, binary);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.download_result), msg[0]);
    const parsed = parseDownloadResult(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("d1", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, 0), parsed.exit_code);
    try std.testing.expectEqualSlices(u8, binary, parsed.file_data);
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
