//! TCP message framing protocol — length-prefixed messages over std.Io streams.
//!
//! Wire format:
//!   [4 bytes big-endian: payload length N][1 byte: message type][N bytes: payload]
//!
//! Two API layers:
//!   - sendMessage/recvMessage: generic, work with any writer/reader (std.Io, Stream.Writer/Reader)
//!   - streamFile/receiveFile: file transfer helpers

const std = @import("std");

/// Message type constants (replacing HTTP endpoints + IPC commands)
pub const MsgType = struct {
    pub const VERSION_REQ: u8 = 0x01;
    pub const VERSION_RESP: u8 = 0x02;
    pub const HEALTH_REQ: u8 = 0x03;
    pub const HEALTH_RESP: u8 = 0x04;
    pub const FILE_REQ: u8 = 0x05;
    pub const FILE_RESP: u8 = 0x06;
    pub const UPLOAD_REQ: u8 = 0x07;
    pub const UPLOAD_RESP: u8 = 0x08;
    pub const EXEC_REQ: u8 = 0x09;
    pub const EXEC_STDOUT: u8 = 0x0A;
    pub const EXEC_STDERR: u8 = 0x0B;
    pub const EXEC_EXIT: u8 = 0x0C;
    pub const ERROR: u8 = 0x0D;
    pub const EOF: u8 = 0xFF;
};

/// Maximum message payload size (50 MB — matches old HTTP limit)
pub const MAX_PAYLOAD: usize = 50 * 1024 * 1024;

/// Read exactly `len` bytes from a reader into buf.
/// Callers always pass a pointer. Handles types with .interface (Stream.Writer/Reader, File.Writer/Reader)
/// and plain Io.Reader (tests via .fixed()) transparently.
fn readAll(reader_ptr: anytype, buf: []u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        var vecs: [1][]u8 = .{buf[pos..]};
        const n = if (comptime @hasField(@TypeOf(reader_ptr.*), "interface"))
            try reader_ptr.interface.readVec(vecs[0..])
        else
            try reader_ptr.readVec(vecs[0..]);
        if (n == 0) return error.EndOfStream;
        pos += n;
    }
}

/// Write exactly `len` bytes from buf to a writer.
/// Callers always pass a pointer. Handles types with .interface (Stream.Writer, File.Writer)
/// and plain Io.Writer (tests via .fixed()) transparently.
fn writeAll(writer_ptr: anytype, buf: []const u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        var vecs: [1][]const u8 = .{buf[pos..]};
        const n = if (comptime @hasField(@TypeOf(writer_ptr.*), "interface"))
            try writer_ptr.interface.writeVec(vecs[0..])
        else
            try writer_ptr.writeVec(vecs[0..]);
        if (n == 0) return error.BrokenPipe;
        pos += n;
    }
}

/// Parse a 4-byte big-endian u32 from buf.
fn readU32Be(buf: *const [4]u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}

/// Write a u32 as 4-byte big-endian into buf.
fn writeU32Be(buf: *[4]u8, value: u32) void {
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate(value >> 16);
    buf[2] = @truncate(value >> 8);
    buf[3] = @truncate(value);
}

/// Send a framed message: [4-byte len][1-byte type][payload]
pub fn sendMessage(writer: anytype, msg_type: u8, payload: []const u8) !void {
    const total_len: u32 = @intCast(1 + payload.len); // type byte + payload
    var header: [5]u8 = undefined;
    writeU32Be(header[0..4], total_len);
    header[4] = msg_type;
    try writeAll(writer, &header);
    if (payload.len > 0) {
        try writeAll(writer, payload);
    }
}

/// Receive a framed message. Allocates payload (caller owns).
/// Returns null if the peer sent EOF (clean close).
pub fn recvMessage(reader: anytype, allocator: std.mem.Allocator) !?struct { msg_type: u8, payload: []u8 } {
    // Read 4-byte length header
    var len_buf: [4]u8 = undefined;
    readAll(reader, &len_buf) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    const total_len = readU32Be(&len_buf);

    if (total_len == 0) return error.EmptyMessage;
    if (total_len > MAX_PAYLOAD) return error.MessageTooLarge;

    // Read type byte
    var type_buf: [1]u8 = undefined;
    try readAll(reader, &type_buf);
    const msg_type = type_buf[0];

    const payload_len = total_len - 1;
    if (payload_len == 0) {
        return .{ .msg_type = msg_type, .payload = &.{} };
    }

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    readAll(reader, payload) catch |err| {
        allocator.free(payload);
        return err;
    };

    return .{ .msg_type = msg_type, .payload = payload };
}

/// Send a string message (convenience for VERSION_RESP, HEALTH_RESP, ERROR).
pub fn sendString(writer: anytype, msg_type: u8, text: []const u8) !void {
    try sendMessage(writer, msg_type, text);
}

/// Stream a file to the peer in FILE_RESP chunks + EOF marker.
/// Chunk size: 64KB. After all chunks, sends EOF message.
pub fn streamFile(writer: anytype, io: std.Io, file_path: []const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        try sendString(writer, MsgType.ERROR, "File not found");
        return err;
    };
    defer file.close(io);

    const file_len = file.length(io) catch 0;

    var fbuf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_len) {
        const to_read = @min(fbuf.len, file_len - offset);
        const n = file.readPositionalAll(io, fbuf[0..to_read], offset) catch break;
        if (n == 0) break;
        try sendMessage(writer, MsgType.FILE_RESP, fbuf[0..n]);
        offset += n;
    }

    // EOF marker
    try sendMessage(writer, MsgType.EOF, &.{});
}

/// Receive FILE_RESP/EOF chunks and write to a file. Returns total bytes written.
pub fn receiveFile(reader: anytype, io: std.Io, allocator: std.mem.Allocator, dest_path: []const u8) !usize {
    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
    defer file.close(io);

    var total: usize = 0;

    while (true) {
        const msg = try recvMessage(reader, allocator) orelse return error.UnexpectedEOF;
        defer allocator.free(msg.payload);

        switch (msg.msg_type) {
            MsgType.FILE_RESP => {
                var wb: [4096]u8 = undefined;
                var fw = file.writer(io, &wb);
                _ = try fw.interface.write(msg.payload);
                total += msg.payload.len;
            },
            MsgType.EOF => {
                return total;
            },
            MsgType.ERROR => {
                std.debug.print("[transport] Remote error: {s}\n", .{msg.payload});
                return error.RemoteError;
            },
            else => {
                std.debug.print("[transport] Unexpected message type 0x{x} during file receive\n", .{msg.msg_type});
                return error.ProtocolError;
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "sendMessage / recvMessage roundtrip" {
    const allocator = std.testing.allocator;

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed(buf[0..]);

    try sendMessage(&writer, MsgType.VERSION_RESP, "1.0.0");
    try sendMessage(&writer, MsgType.HEALTH_RESP, "OK");

    const msg1 = try recvMessage(&reader, allocator);
    try std.testing.expect(msg1 != null);
    defer allocator.free(msg1.?.payload);
    try std.testing.expectEqual(MsgType.VERSION_RESP, msg1.?.msg_type);
    try std.testing.expectEqualStrings("1.0.0", msg1.?.payload);

    const msg2 = try recvMessage(&reader, allocator);
    try std.testing.expect(msg2 != null);
    defer allocator.free(msg2.?.payload);
    try std.testing.expectEqual(MsgType.HEALTH_RESP, msg2.?.msg_type);
    try std.testing.expectEqualStrings("OK", msg2.?.payload);
}

test "sendMessage / recvMessage empty payload" {
    const allocator = std.testing.allocator;

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed(buf[0..]);

    try sendMessage(&writer, MsgType.EOF, &.{});

    const msg = try recvMessage(&reader, allocator);
    try std.testing.expect(msg != null);
    defer allocator.free(msg.?.payload);
    try std.testing.expectEqual(MsgType.EOF, msg.?.msg_type);
    try std.testing.expectEqual(@as(usize, 0), msg.?.payload.len);
}

test "recvMessage returns null on clean close" {
    const allocator = std.testing.allocator;

    // Empty buffer — immediate EOF
    const buf: [0]u8 = .{};
    var reader: std.Io.Reader = .fixed(&buf);

    const msg = try recvMessage(&reader, allocator);
    try std.testing.expect(msg == null);
}

test "sendMessage large payload" {
    const allocator = std.testing.allocator;

    const payload = try allocator.alloc(u8, 100000);
    defer allocator.free(payload);
    @memset(payload, 0xAB);

    const buf = try allocator.alloc(u8, 100000 + 5);
    defer allocator.free(buf);

    var writer: std.Io.Writer = .fixed(buf);
    try sendMessage(&writer, MsgType.FILE_RESP, payload);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    const msg = try recvMessage(&reader, allocator);
    try std.testing.expect(msg != null);
    defer allocator.free(msg.?.payload);
    try std.testing.expectEqual(MsgType.FILE_RESP, msg.?.msg_type);
    try std.testing.expectEqual(@as(usize, 100000), msg.?.payload.len);
}
