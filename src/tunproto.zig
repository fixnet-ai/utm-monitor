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
    pty_exec_input = 0x11, // cmd_id(NT) + command_data (Ctrl+C = 0x03 via stdin)
    _unused_0x12 = 0x12, // was signal_cmd — removed (stdin raw byte forwarding)
    _unused_0x13 = 0x13, // was upload_data — replaced by upload_cmd + file_chunk + file_eof
    download_cmd = 0x14, // cmd_id(NT) + path(NT)

    // Guest → Host responses
    pty_exec_output = 0x15, // cmd_id(NT) + chunk_data
    pty_exec_done = 0x16, // cmd_id(NT) + exit_code(BE i32)
    upload_result = 0x17, // cmd_id(NT) + exit_code(BE i32)
    _unused_0x18 = 0x18, // was upgrade_bin — replaced by file_chunk + file_eof

    // Guest → Host: upgrade request (Guest-initiated binary fetch from Host)
    upgrade_req = 0x19, // cmd_id(NT) + target(NT)
    // Host → Guest: upgrade binary response
    _unused_0x1a = 0x1a, // was upgrade_bin — replaced by file_chunk + file_eof

		// Chunked file transfer (replaces blob-in-message for upload/download/upgrade)
		upload_cmd = 0x1b, // Host→Guest: cmd_id(NT) + path(NT) + file_size(BE u32) + file_hash(NT)
		file_chunk = 0x1c, // Bidirectional: cmd_id(NT) + data(blob)
		file_eof = 0x1d, // Bidirectional: cmd_id(NT) + exit_code(BE i32) + file_size(BE u32) + file_hash(NT)
};

/// Max file data bytes per file_chunk message.
///
/// Sized so the entire file_chunk frame (type + cmd_id NT + blob prefix + data)
/// fits in one KCP segment (MSS = MTU 1266 - OVERHEAD 24 = 1242 bytes).
/// Each file_chunk maps 1:1 to a KCP segment — no KCP-level frg fragmentation,
/// no head-of-line blocking across segments within one chunk.
///
/// Frame overhead: type(1) + cmd_id(~24 with timestamp) + blob_len(4) ≈ 29.
/// MSS 1242 - 29 = 1213. Reserve margin to 1200 for safety.
pub const FILE_CHUNK_DATA_MAX: usize = 1200;

// ═══════════════════════════════════════════════════════════════════════════
// Serialization helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum blob length from untrusted network data (1 MB).
/// KCP messages are MTU-bounded (~1300 bytes), so any blob exceeding
/// this is either malicious or a protocol bug.
pub const MAX_BLOB_LEN: u32 = 1024 * 1024;

/// Maximum string length from untrusted network data (8 KB).
/// cmd_id paths are typically < 256 bytes; 8 KB allows for future
/// expansion while preventing memory exhaustion.
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

/// Read a null-terminated string with an explicit maximum length.
/// Returns null if the string exceeds max_len, no null terminator found,
/// or reads past the data boundary.
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

/// Read a length-prefixed blob with an explicit maximum size.
/// Returns null if the blob exceeds max_len or runs past the data boundary.
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

pub fn buildFileChunk(allocator: std.mem.Allocator, cmd_id: []const u8, data: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.file_chunk));
    try writeString(&buf, allocator, cmd_id);
    try writeBlob(&buf, allocator, data);
    return buf.toOwnedSlice(allocator);
}

pub fn buildFileEof(allocator: std.mem.Allocator, cmd_id: []const u8, exit_code: i32, file_size: u32, file_hash: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.file_eof));
    try writeString(&buf, allocator, cmd_id);
    try writeI32(&buf, allocator, exit_code);
    try writeU32(&buf, allocator, file_size);
    try writeString(&buf, allocator, file_hash);
    return buf.toOwnedSlice(allocator);
}


pub fn buildUpgradeReq(allocator: std.mem.Allocator, cmd_id: []const u8, target: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, @intFromEnum(MsgType.upgrade_req));
    try writeString(&buf, allocator, cmd_id);
    try writeString(&buf, allocator, target);
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

pub const UploadResultData = struct {
    cmd_id: []const u8,
    exit_code: i32,
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

pub const FileChunkData = struct {
    cmd_id: []const u8,
    data: []const u8,
};

pub const FileEofData = struct {
    cmd_id: []const u8,
    exit_code: i32,
    file_size: u32,
    file_hash: []const u8,
};

pub const UpgradeReqData = struct {
    cmd_id: []const u8,
    target: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// Parse functions
// ═══════════════════════════════════════════════════════════════════════════
//
// CRITICAL CONVENTION: ALL parse*() functions start at pos=0 and expect data
// WITHOUT the leading type byte. Every dispatcher MUST pass `data[1..]`.
//
//   switch (data[0]) {                  // type byte consumed here
//       @intFromEnum(.file_eof) => {
//           const eof = parseFileEof(data[1..]);  // ✓ correct
//           const eof = parseFileEof(data);       // ✗ BUG: 0x1D parsed as cmd_id[0]
//       },
//   }
//
// Forgetting to strip the type byte causes silent data corruption because
// readString starts at position 0 and reads the type byte as part of the
// first field. This was Finding 109 — parseFileEof(data) instead of
// parseFileEof(data[1..]) caused all downloads to hang indefinitely.
//
// Note: parsePtyExecOutput/PtyExecInput are exceptions — their last field
// captures the remaining bytes after the structured prefix (raw command
// or output), so they can technically tolerate an extra byte. Do NOT rely
// on this; always pass data[1..] to all parse functions.

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

pub fn parseUploadCmd(data: []const u8) ?UploadCmdData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const path = readString(data, &pos) orelse return null;
    const file_size = readU32(data, &pos) orelse return null;
    const file_hash = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .path = path, .file_size = file_size, .file_hash = file_hash };
}

pub fn parseFileChunk(data: []const u8) ?FileChunkData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const chunk_data = readBlob(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .data = chunk_data };
}

pub fn parseFileEof(data: []const u8) ?FileEofData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const exit_code = readI32(data, &pos) orelse return null;
    const file_size = readU32(data, &pos) orelse return null;
    const file_hash = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .exit_code = exit_code, .file_size = file_size, .file_hash = file_hash };
}


pub fn parseUpgradeReq(data: []const u8) ?UpgradeReqData {
    var pos: usize = 0;
    const cmd_id = readString(data, &pos) orelse return null;
    const target = readString(data, &pos) orelse return null;
    return .{ .cmd_id = cmd_id, .target = target };
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

test "upgrade_req round-trip" {
    const allocator = std.testing.allocator;
    const msg = try buildUpgradeReq(allocator, "up1", "aarch64-linux-musl");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.upgrade_req), msg[0]);
    const parsed = parseUpgradeReq(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("up1", parsed.cmd_id);
    try std.testing.expectEqualStrings("aarch64-linux-musl", parsed.target);
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

test "file_chunk round-trip" {
    const allocator = std.testing.allocator;
    const data = &[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD };
    const msg = try buildFileChunk(allocator, "fc1", data);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_chunk), msg[0]);
    const parsed = parseFileChunk(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("fc1", parsed.cmd_id);
    try std.testing.expectEqualSlices(u8, data, parsed.data);
}

test "file_chunk with MSS-aligned payload" {
    const allocator = std.testing.allocator;
    const chunk: [FILE_CHUNK_DATA_MAX]u8 = [_]u8{0xAB} ** FILE_CHUNK_DATA_MAX;
    const msg = try buildFileChunk(allocator, "fc2", &chunk);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_chunk), msg[0]);
    const parsed = parseFileChunk(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("fc2", parsed.cmd_id);
    try std.testing.expectEqualSlices(u8, &chunk, parsed.data);
        // Verify the full frame fits in one KCP segment (MSS = 1266 - 24 = 1242).
        try std.testing.expect(msg.len <= 1242);
}

test "file_eof round-trip (success)" {
    const allocator = std.testing.allocator;
    const hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6abcd";
    const msg = try buildFileEof(allocator, "fe1", 0, 4096, hash);
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_eof), msg[0]);
    const parsed = parseFileEof(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("fe1", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, 0), parsed.exit_code);
    try std.testing.expectEqual(@as(u32, 4096), parsed.file_size);
    try std.testing.expectEqualStrings(hash, parsed.file_hash);
}

test "file_eof round-trip (error)" {
    const allocator = std.testing.allocator;
    const msg = try buildFileEof(allocator, "fe2", -1, 0, "");
    defer allocator.free(msg);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_eof), msg[0]);
    const parsed = parseFileEof(msg[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("fe2", parsed.cmd_id);
    try std.testing.expectEqual(@as(i32, -1), parsed.exit_code);
    try std.testing.expectEqual(@as(u32, 0), parsed.file_size);
    try std.testing.expectEqualStrings("", parsed.file_hash);
}

test "chunked file transfer flow: upload_cmd → file_chunk × N → file_eof" {
    const allocator = std.testing.allocator;
    const file_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    // Step 1: upload_cmd
    const cmd = try buildUploadCmd(allocator, "flow1", "/tmp/data.bin", 16, file_hash);
    defer allocator.free(cmd);
    try std.testing.expectEqual(@intFromEnum(MsgType.upload_cmd), cmd[0]);
    const parsed_cmd = parseUploadCmd(cmd[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("flow1", parsed_cmd.cmd_id);
    try std.testing.expectEqualStrings("/tmp/data.bin", parsed_cmd.path);
    try std.testing.expectEqual(@as(u32, 16), parsed_cmd.file_size);
    try std.testing.expectEqualStrings(file_hash, parsed_cmd.file_hash);

    // Step 2: two file_chunks
    const chunk1_data = &[_]u8{0x00} ** 8;
    const chunk1 = try buildFileChunk(allocator, "flow1", chunk1_data);
    defer allocator.free(chunk1);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_chunk), chunk1[0]);
    const parsed_chunk1 = parseFileChunk(chunk1[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("flow1", parsed_chunk1.cmd_id);
    try std.testing.expectEqualSlices(u8, chunk1_data, parsed_chunk1.data);

    const chunk2_data = &[_]u8{0xFF} ** 8;
    const chunk2 = try buildFileChunk(allocator, "flow1", chunk2_data);
    defer allocator.free(chunk2);
    const parsed_chunk2 = parseFileChunk(chunk2[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("flow1", parsed_chunk2.cmd_id);
    try std.testing.expectEqualSlices(u8, chunk2_data, parsed_chunk2.data);

    // Step 3: file_eof
    const eof = try buildFileEof(allocator, "flow1", 0, 16, file_hash);
    defer allocator.free(eof);
    try std.testing.expectEqual(@intFromEnum(MsgType.file_eof), eof[0]);
    const parsed_eof = parseFileEof(eof[1..]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("flow1", parsed_eof.cmd_id);
    try std.testing.expectEqual(@as(i32, 0), parsed_eof.exit_code);
    try std.testing.expectEqual(@as(u32, 16), parsed_eof.file_size);
    try std.testing.expectEqualStrings(file_hash, parsed_eof.file_hash);
}

test "readBlobMax - respects max_len" {
    // Build a blob with 8 bytes of data
    var buf: [4 + 8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 8, .big);
    @memset(buf[4..12], 0xAB);

    var pos: usize = 0;
    const blob = readBlobMax(&buf, &pos, 8) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 8), blob.len);

    // Same blob but with max_len=4 should fail
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
    std.mem.writeInt(u32, buf[0..4], 8, .big); // claims 8 bytes but only 2 follow
    var pos: usize = 0;
    try std.testing.expect(readBlobMax(&buf, &pos, 16) == null);
}

test "readStringMax - respects max_len" {
    const s: [6]u8 = "hello".* ++ [_]u8{0};
    var pos: usize = 0;
    const result = readStringMax(&s, &pos, 5) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("hello", result);

    // Same string with max_len=3 should fail
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
