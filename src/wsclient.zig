//! Minimal WebSocket client for Guest→Host connection.
//!
//! Implements RFC 6455 WebSocket handshake + frame read/write.
//! Client-to-server frames are masked (required by RFC).
//! Server-to-client frames are unmasked.

const std = @import("std");
const builtin = @import("builtin");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Frame = struct {
    opcode: Opcode,
    data: []const u8,
};

/// TCP stream wrapper for WebSocket I/O.
pub const WsConn = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    /// Protects writeFrame on Windows (timer thread + main thread).
    write_mutex: if (builtin.os.tag == .windows) std.Io.Mutex else void = if (builtin.os.tag == .windows) std.Io.Mutex.init else {},
    /// Leftover bytes from HTTP handshake reader buffer. These are WebSocket
    /// frame bytes that the Io.Reader pre-fetched past the `\r\n\r\n` boundary.
    /// Must be consumed by the first readFrame() call before new socket reads.
    handshake_leftover: [15]u8 = [_]u8{0} ** 15,
    handshake_leftover_len: u4 = 0,

    /// Connect to Host and perform WebSocket upgrade handshake.
    pub fn connect(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16) !WsConn {
        const addr = try std.Io.net.IpAddress.parse(host, port);
        var stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        // Generate WebSocket key from timestamp (16 pseudo-random bytes base64-encoded)
        var key_buf: [24]u8 = undefined;
        {
            var rnd_buf: [16]u8 = undefined;
            const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
            std.mem.writeInt(u64, rnd_buf[0..8], @intCast(ts), .big);
            std.mem.writeInt(u64, rnd_buf[8..16], @intCast(ts ^ 0xDEADBEEF_CAFE1234), .big);
            _ = std.base64.standard.Encoder.encode(&key_buf, &rnd_buf);
        }
        const ws_key = key_buf[0..24]; // base64(16 bytes) = 24 chars

        // Send HTTP upgrade request — use separate format buffer and writer buffer
        // to avoid @memcpy alias (writer buffer can't be same as data being written)
        var req_buf: [4096]u8 = undefined;
        var wr_buf: [4096]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf,
            "GET /ws HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ host, port, ws_key },
        );
        {
            var writer = stream.writer(io, &wr_buf);
            _ = try writer.interface.write(req);
            try writer.interface.flush();
        }

        // Read HTTP response using Io.Reader (cross-platform).
        // On Windows, socket handles are AFD kernel handles (not Winsock SOCKET),
        // so std.c.recv (ws2_32) can't read from them — must use the Io abstraction.
        // Io.Reader buffers internally (16 bytes), so after finding \r\n\r\n
        // we must save leftover buffered bytes as WebSocket frame prefix.
        var rbuf: [16]u8 = undefined;
        var reader = stream.reader(io, &rbuf);

        var out_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < out_buf.len) {
            var byte_writer: std.Io.Writer = .fixed(out_buf[total..][0..1]);
            reader.interface.streamExact(&byte_writer, 1) catch |err| {
                std.log.err("[wsclient] Read HTTP response failed: {}", .{err});
                stream.close(io);
                return error.WebSocketHandshakeFailed;
            };
            total += 1;
            // HTTP headers end with \r\n\r\n
            if (total >= 4 and
                std.mem.eql(u8, out_buf[total - 4 .. total], "\r\n\r\n")) break;
        }
        if (total >= out_buf.len) {
            std.log.err("[wsclient] HTTP response too large", .{});
            stream.close(io);
            return error.WebSocketHandshakeFailed;
        }

        // Save leftover bytes from reader buffer — these are WebSocket frame
        // data pre-fetched by the 16-byte Io.Reader buffer past \r\n\r\n.
        const leftover = reader.interface.buffer[reader.interface.seek..reader.interface.end];
        var leftover_arr: [15]u8 = undefined;
        const leftover_len: u4 = if (leftover.len > 0) @intCast(@min(leftover.len, 15)) else 0;
        if (leftover_len > 0) @memcpy(leftover_arr[0..leftover_len], leftover[0..leftover_len]);

        const resp = out_buf[0..total];

        // Verify 101 Switching Protocols
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) {
            std.log.err("[wsclient] Unexpected response: {s}", .{resp});
            stream.close(io);
            return error.WebSocketHandshakeFailed;
        }

        // Find Sec-WebSocket-Accept header to verify
        const accept_key = extractHeader(resp, "sec-websocket-accept:");
        if (accept_key) |ak| {
            var sha1 = std.crypto.hash.Sha1.init(.{});
            sha1.update(ws_key);
            sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
            var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            sha1.final(&digest);
            var expected: [28]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&expected, &digest);
            if (!std.mem.eql(u8, ak, &expected)) {
                std.log.err("[wsclient] Accept key mismatch", .{});
                stream.close(io);
                return error.WebSocketHandshakeFailed;
            }
        }

        _ = allocator;
        return .{
            .stream = stream,
            .io = io,
            .write_mutex = if (builtin.os.tag == .windows) std.Io.Mutex.init else {},
            .handshake_leftover = leftover_arr,
            .handshake_leftover_len = leftover_len,
        };
    }

    fn extractHeader(resp: []const u8, name: []const u8) ?[]const u8 {
        // Case-insensitive search
        var lower_buf: [4096]u8 = undefined;
        @memcpy(lower_buf[0..resp.len], resp);
        for (lower_buf[0..resp.len]) |*c| c.* = std.ascii.toLower(c.*);
        const lower = lower_buf[0..resp.len];
        const pos = std.mem.indexOf(u8, lower, name) orelse return null;
        const start = pos + name.len;
        const end = std.mem.indexOfScalarPos(u8, resp, start, '\r') orelse resp.len;
        return std.mem.trim(u8, resp[start..end], " ");
    }

    pub fn close(self: *WsConn) void {
        // Send close frame
        self.writeFrame(&.{}, .close) catch {};
        self.stream.close(self.io);
    }

    /// Write a WebSocket frame (client→server, must mask).
    /// On Windows: mutex-protected (timer thread + main thread can both write).
    /// On POSIX: single-threaded, no lock needed.
    pub fn writeFrame(self: *WsConn, data: []const u8, opcode: Opcode) !void {
        if (builtin.os.tag == .windows) {
            self.write_mutex.lock(self.io) catch {};
            defer self.write_mutex.unlock(self.io);
        }
        const mask_key: [4]u8 = blk: {
            const ts: u32 = @truncate(@as(u64, @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds)));
            var k: [4]u8 = undefined;
            std.mem.writeInt(u32, &k, ts ^ 0xA5A5A5A5, .big);
            break :blk k;
        };

        // Build header in a small buffer
        var hdr_buf: [14]u8 = undefined;
        var hdr_len: usize = 0;

        // Byte 0: FIN + opcode
        hdr_buf[0] = @as(u8, 0x80) | @intFromEnum(opcode);
        hdr_len = 1;

        // Byte 1: MASK + length
        if (data.len <= 125) {
            hdr_buf[1] = 0x80 | @as(u8, @intCast(data.len));
            hdr_len = 2;
        } else if (data.len <= 65535) {
            hdr_buf[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr_buf[2..4], @intCast(data.len), .big);
            hdr_len = 4;
        } else {
            hdr_buf[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr_buf[2..10], @intCast(data.len), .big);
            hdr_len = 10;
        }

        // Mask key
        @memcpy(hdr_buf[hdr_len..][0..4], &mask_key);
        hdr_len += 4;

        // Write header + masked payload using a Writer
        var wbuf: [64]u8 = undefined;
        var writer = self.stream.writer(self.io, &wbuf);
        _ = try writer.interface.write(hdr_buf[0..hdr_len]);

        // Write masked payload in chunks
        var chunk_buf: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, chunk_buf.len);
            for (chunk_buf[0..chunk_len], 0..) |*byte, i| {
                byte.* = data[offset + i] ^ mask_key[(offset + i) % 4];
            }
            _ = try writer.interface.write(chunk_buf[0..chunk_len]);
            offset += chunk_len;
        }
        try writer.interface.flush();
    }

    /// Read exact number of bytes into dest from a persistent reader.
    /// Uses the reader's internal buffer — must be called with the SAME reader
    /// across multiple calls to avoid buffer-discard data loss.
    fn readExactFrom(reader: anytype, dest: []u8) !void {
        var writer: std.Io.Writer = .fixed(dest);
        try reader.streamExact(&writer, dest.len);
    }

    /// Read a WebSocket frame (server→client, unmasked).
    /// `buf` is caller-provided buffer. Returned `data` points into `buf`.
    /// Uses a SINGLE persistent reader so buffered data is not lost between
    /// the multiple sub-reads (header, extended length, mask, payload).
    pub fn readFrame(self: *WsConn, buf: []u8) !Frame {
        // If we have handshake leftover bytes, prepend them to the stream by
        // wrapping the Io.Reader. This is needed because the HTTP response
        // reader pre-fetches bytes past \r\n\r\n into its 16-byte buffer.
        const PrefixReader = struct {
            prefix: []const u8,
            reader: *std.Io.Reader,

            pub fn streamExact(
                self2: *@This(),
                w: *std.Io.Writer,
                n: usize,
            ) std.Io.Reader.StreamError!void {
                var remaining = n;
                if (self2.prefix.len > 0) {
                    const take = @min(self2.prefix.len, remaining);
                    w.writeAll(self2.prefix[0..take]) catch return error.WriteFailed;
                    self2.prefix = self2.prefix[take..];
                    remaining -= take;
                }
                if (remaining > 0) {
                    try std.Io.Reader.streamExact(self2.reader, w, remaining);
                }
            }
        };

        // Persistent reader — must NOT go out of scope until all sub-reads are done.
        // Each sub-read (header, ext_len, mask, payload) goes through this reader's
        // buffer so excess bytes are preserved for the next sub-read.
        var rbuf: [128]u8 = undefined;
        var net_reader = self.stream.reader(self.io, &rbuf);

        const leftover_len = self.handshake_leftover_len;
        self.handshake_leftover_len = 0; // consume once

        var prefixed = PrefixReader{
            .prefix = self.handshake_leftover[0..leftover_len],
            .reader = &net_reader.interface,
        };

        // Read header (min 2 bytes)
        var hdr_buf: [2]u8 = undefined;
        try readExactFrom(&prefixed, &hdr_buf);
        const h0: u8 = hdr_buf[0];
        const h1: u8 = hdr_buf[1];

        const opcode: Opcode = @enumFromInt(h0 & 0x0F);
        const masked: bool = (h1 & 0x80) != 0;
        var payload_len: usize = h1 & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readExactFrom(&prefixed, &ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readExactFrom(&prefixed, &ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }

        // Masking key (if present)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            try readExactFrom(&prefixed, &mask_key);
        }

        // Read payload
        if (payload_len > buf.len) return error.BufferTooSmall;
        try readExactFrom(&prefixed, buf[0..payload_len]);

        // Unmask if needed
        if (masked) {
            for (buf[0..payload_len], 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        return .{ .opcode = opcode, .data = buf[0..payload_len] };
    }
};
