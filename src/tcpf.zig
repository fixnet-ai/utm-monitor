//! TCP 长度前缀帧协议。
//!
//! 替代 WebSocket/KCP 的消息定界。每条消息:
//!   [4-byte BE length][payload]
//!
//! length = payload 字节数（不含自身 4 字节前缀）。
//! max_frame = 16 MB — 允许大文件分块传输。
//!
//! 每条 TCP 连接 = 一个请求-响应周期。
//! 连接关闭表示会话结束。

const std = @import("std");
const system = std.posix.system;

/// 单帧最大 16 MB（供文件传输使用）。
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// 发送一帧：写入 4-byte BE length + payload。
pub fn sendFrame(fd: std.posix.socket_t, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    const n1 = system.write(fd, &len_buf, len_buf.len);
    if (n1 != 4) return error.SendFailed;
    const n2 = system.write(fd, data.ptr, data.len);
    if (n2 != data.len) return error.SendFailed;
}

/// 接收一帧：读取 4-byte BE length → 分配缓冲区 → 读取 payload。
/// 返回调用者拥有的内存（需用 allocator 释放）。
pub fn recvFrame(allocator: std.mem.Allocator, fd: std.posix.socket_t) ![]const u8 {
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

/// 精确读取 len 字节。返回实际读取数（0 = EOF）。
fn recvExact(fd: std.posix.socket_t, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = system.read(fd, buf.ptr + total, buf.len - total);
        if (n == 0) return total; // EOF
        total += @intCast(n);
    }
    return total;
}

/// 发送线程参数。
pub const SendArgs = struct { fd: std.posix.socket_t, data: []const u8 };

/// 线程入口：发送帧（避免大载荷 send 阻塞主线程）。
fn sendInThread(args: SendArgs) void {
    sendFrame(args.fd, args.data) catch @panic("sendFrame failed in thread");
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

/// 创建一对已连接的 socket（用于测试）。
/// 使用 Unix domain socket pair。
fn makePair() !struct { a: std.posix.socket_t, b: std.posix.socket_t } {
    var fds: [2]std.posix.socket_t = undefined;
    // AF_UNIX=1, SOCK_STREAM=1 on all platforms
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

test "sendFrame/recvFrame round-trip" {
    const allocator = std.testing.allocator;
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    const msg = "hello tcp frame";
    try sendFrame(pair.a, msg);

    const received = try recvFrame(allocator, pair.b);
    defer allocator.free(received);
    try std.testing.expectEqualStrings(msg, received);
}

test "recvFrame empty" {
    const allocator = std.testing.allocator;
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    // 关闭写入端 → recvFrame 读到 EOF
    _ = system.shutdown(pair.a, 1); // SHUT_WR=1
    const result = recvFrame(allocator, pair.b);
    try std.testing.expectError(error.ConnectionClosed, result);
}

test "recvFrame large payload" {
    const allocator = std.testing.allocator;
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    // 128 KB payload — must send in a thread to avoid deadlock:
    // socketpair kernel buffer (8KB on macOS) fills before receiver starts.
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
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
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
