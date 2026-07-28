//! SOCKS4/4a 协议 — 统一的连接模型。
//!
//! 所有 TCP 连接通过 SOCKS4 发起，目标由 hostname 指定（SOCKS4a 扩展）。
//!   - 目标 == self → 接受连接，进入 tunproto 消息循环
//!   - 目标 != self → 代理转发（双向中继）
//!
//! SOCKS4a 帧格式:
//!   Client → Server:
//!     VER(1) CMD(1) DSTPORT(2 BE) DSTIP(4 BE) USERID\0 [HOSTNAME\0]
//!     SOCKS4a 标志: DSTIP = 0.0.0.x (x != 0)，后跟 hostname
//!   Server → Client:
//!     VER(1) REP(1) DSTPORT(2) DSTIP(4)

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;

// ═══════════════════════════════════════════════════════════════════════════
// Protocol constants
// ═══════════════════════════════════════════════════════════════════════════

const SOCKS_VER: u8 = 0x04;
const SOCKS_CMD_CONNECT: u8 = 0x01;
const SOCKS_REP_OK: u8 = 0x5a;
const SOCKS_REP_REJECTED: u8 = 0x5b;

/// 单个连接的最大 hostname 长度。
const MAX_HOSTNAME: usize = 256;

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS4a 连接请求（客户端发起）
// ═══════════════════════════════════════════════════════════════════════════

pub const Socks4Request = struct {
    hostname: []const u8,
    port: u16,
};

/// 发送 SOCKS4a 连接请求到目标地址。
/// 返回连接成功后的 TCP socket fd（调用者负责关闭）。
pub fn socks4Connect(
    io: std.Io,
    target_ip: std.Io.net.IpAddress,
    target_hostname: []const u8,
    target_port: u16,
) !std.Io.net.Stream {
    // 通过 std.Io.net 连接（跨平台 TCP）
    const stream = std.Io.net.IpAddress.connect(target_ip, io, .{}) catch |err| {
        return err;
    };
    errdefer stream.close(io);

    // SOCKS4a 请求: VER CMD PORT DSTIP(=0.0.0.1 for 4a) USERID\0 HOSTNAME\0
    var req_buf: [300]u8 = undefined;
    var pos: usize = 0;

    req_buf[pos] = SOCKS_VER;
    pos += 1;
    req_buf[pos] = SOCKS_CMD_CONNECT;
    pos += 1;
    std.mem.writeInt(u16, req_buf[pos..][0..2], target_port, .big);
    pos += 2;
    // SOCKS4a: DSTIP = 0.0.0.1（后面跟 hostname）
    req_buf[pos..][0..4].* = .{ 0, 0, 0, 1 };
    pos += 4;
    // USERID（空字符串，以 \0 结束）
    req_buf[pos] = 0;
    pos += 1;
    // HOSTNAME（null-terminated）
    @memcpy(req_buf[pos..][0..target_hostname.len], target_hostname);
    pos += target_hostname.len;
    req_buf[pos] = 0;
    pos += 1;

    // 通过 Socket handle 写入 SOCKS4a 请求
    const fd = stream.socket.handle;
    const w1 = system.write(fd, &req_buf, pos);
    if (w1 != pos) {
        stream.close(io);
        return error.Socks4SendFailed;
    }

    // 读取 SOCKS4 响应: VER(1) REP(1) DSTPORT(2) DSTIP(4) = 8 bytes
    var resp: [8]u8 = undefined;
    var off: usize = 0;
    while (off < 8) {
        const n = system.read(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) {
            stream.close(io);
            return error.Socks4ResponseTooShort;
        }
        off += @intCast(n);
    }
    if (resp[0] != 0x00) {
        stream.close(io);
        return error.Socks4BadVersion;
    }
    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        if (resp[1] == SOCKS_REP_REJECTED) return error.Socks4Rejected;
        return error.Socks4Failed;
    }

    return stream;
}

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS4 连接处理（服务端）
// ═══════════════════════════════════════════════════════════════════════════

/// 从已 accept 的 TCP socket 读取 SOCKS4a 请求。
/// 返回目标 hostname + port。
/// 注意：不发送响应 — 调用者需在判断目标后调用 socks4ReplyOk 或 socks4ReplyRejected。
pub fn socks4Accept(fd: std.posix.socket_t) !Socks4Request {
    // 读取固定头: VER(1) CMD(1) DSTPORT(2) DSTIP(4) = 8 bytes
    var hdr: [8]u8 = undefined;
    var off: usize = 0;
    while (off < 8) {
        const n = system.read(fd, hdr[off..].ptr, hdr.len - off);
        if (n == 0) return error.Socks4HeaderTooShort;
        off += @intCast(n);
    }
    if (hdr[0] != SOCKS_VER) return error.Socks4BadVersion;
    if (hdr[1] != SOCKS_CMD_CONNECT) return error.Socks4BadCommand;

    const dst_port = std.mem.readInt(u16, hdr[2..4], .big);
    const dst_ip3 = hdr[7]; // SOCKS4a: DSTIP[3] != 0

    // 跳过 USERID（null-terminated string）
    _ = try readUntilNull(fd);

    // SOCKS4a: 如果 DSTIP[3] != 0，读取目标 hostname
    if (dst_ip3 != 0) {
        const hn = try readUntilNull(fd);
        if (hn.len == 0 or hn.len > MAX_HOSTNAME) return error.Socks4BadHostname;
        return Socks4Request{ .hostname = hn, .port = dst_port };
    }
    // 标准 SOCKS4: 使用 IP 地址（回退路径）
    return error.Socks4aRequired;
}

/// 发送 SOCKS4 成功响应。
pub fn socks4ReplyOk(fd: std.posix.socket_t) void {
    const resp = [_]u8{ 0x00, SOCKS_REP_OK, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    _ = system.write(fd, &resp, resp.len);
}

/// 发送 SOCKS4 拒绝响应。
pub fn socks4ReplyRejected(fd: std.posix.socket_t) void {
    const resp = [_]u8{ 0x00, SOCKS_REP_REJECTED, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    _ = system.write(fd, &resp, resp.len);
}

// ═══════════════════════════════════════════════════════════════════════════
// 双向中继（代理转发）
// ═══════════════════════════════════════════════════════════════════════════

/// 双向中继：A ↔ B。
/// 两个线程各负责一个方向。
pub fn socks4Relay(a_fd: std.posix.socket_t, b_fd: std.posix.socket_t) !void {
    var a_to_b_done = std.atomic.Value(bool).init(false);

    const relay_thread = try std.Thread.spawn(.{}, relayDir, .{ b_fd, a_fd, &a_to_b_done });
    defer relay_thread.join();

    relayDir(a_fd, b_fd, &a_to_b_done);
}

fn relayDir(src: std.posix.socket_t, dst: std.posix.socket_t, done: *std.atomic.Value(bool)) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = system.read(src, &buf, buf.len);
        if (n == 0) {
            done.store(true, .release);
            return;
        }
        _ = system.write(dst, &buf, @intCast(n));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// I/O helpers
// ═══════════════════════════════════════════════════════════════════════════

/// 逐字节读取直到遇到 null 字节。返回不含 null 的内容。
/// 返回的 buffer 仅在下一次调用 readUntilNull 前有效。
fn readUntilNull(fd: std.posix.socket_t) ![]const u8 {
    var buf: [MAX_HOSTNAME + 64]u8 = undefined;
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: u8 = undefined;
        const n = system.read(fd, @as([*]u8, @ptrCast(&byte)), 1);
        if (n == 0) return buf[0..pos];
        if (byte == 0) return buf[0..pos];
        buf[pos] = byte;
        pos += 1;
    }
    return buf[0..pos];
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

/// 创建一对已连接的 socket（用于测试）。
fn makePair() !struct { a: std.posix.socket_t, b: std.posix.socket_t } {
    var fds: [2]std.posix.socket_t = undefined;
    // AF_UNIX=1, SOCK_STREAM=1 on all platforms
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

test "socks4a handshake round-trip" {
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    // 客户端线程：发送 SOCKS4a 请求 → 验证响应
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT, // VER, CMD
                0x08, 0x49, // PORT = 2121
                0x00, 0x00, 0x00, 0x01, // DSTIP = 0.0.0.1 (SOCKS4a)
                0, // USERID = "" (null only)
                't',  'e',  's',  't',  0, // HOSTNAME
            };
            _ = system.write(fd, &req, req.len);

            var resp: [8]u8 = [_]u8{0} ** 8;
            var off: usize = 0;
            while (off < 8) {
                const n = system.read(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            if (off >= 2) {
                std.debug.assert(resp[0] == 0x00);
                std.debug.assert(resp[1] == SOCKS_REP_OK);
            }
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // 服务端：accept → 读取 SOCKS4a 请求 → 发回应
    const request = try socks4Accept(pair.a);
    try std.testing.expectEqualStrings("test", request.hostname);
    try std.testing.expectEqual(@as(u16, 2121), request.port);

    socks4ReplyOk(pair.a);
}

test "socks4ReplyRejected" {
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    socks4ReplyRejected(pair.a);

    var resp: [8]u8 = [_]u8{0} ** 8;
    var off: usize = 0;
    while (off < 8) {
        const n = system.read(pair.b, resp[off..].ptr, resp.len - off);
        if (n == 0) break;
        off += @intCast(n);
    }
    try std.testing.expect(resp[1] == SOCKS_REP_REJECTED);
}
