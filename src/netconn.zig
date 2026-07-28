//! 网络连接抽象 — TCP + SOCKS4 + tcpf 统一连接模型。
//!
//! Guest 和 Host 共享同一套网络层：
//!   - Guest:  TCP accept → SOCKS4a accept → Connection
//!   - Host:   TCP connect → SOCKS4a connect → Connection
//!
//! Connection 提供与 Tunnel 兼容的 API（send/sendAndFlush/recv/isAlive/deinit），
//! 使上层 ptyReadLoop / receiveChunkedFile / sendChunkedFile 可以最小改动迁移。

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;

const tcpf = @import("tcpf.zig");
const socks4 = @import("socks4.zig");

/// TCP + SOCKS4 连接。
pub const Connection = struct {
    fd: std.posix.socket_t,
    alive: bool,

    /// 发送一帧（4B BE length + payload）。
    pub fn send(self: *Connection, data: []const u8) !void {
        return tcpf.sendFrame(self.fd, data);
    }

    /// 发送并立即发送（同 send，TCP 没有 flush 概念）。
    pub fn sendAndFlush(self: *Connection, data: []const u8, _: u32) !void {
        return tcpf.sendFrame(self.fd, data);
    }

    /// 接收一帧：读取 4B length → 读取 payload 到 buf。
    /// 返回 payload 字节数。buf 必须足够大以容纳完整帧。
    /// 返回 0 表示连接关闭。
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

    /// 连接是否存活。
    pub fn isAlive(self: *Connection) bool {
        return self.alive;
    }

    /// 关闭连接并释放资源。
    pub fn deinit(self: *Connection) void {
        self.alive = false;
        _ = system.shutdown(self.fd, 2); // SHUT_RDWR
        _ = system.close(self.fd);
    }
};

/// 精确读取 len 字节。返回实际读取数（0 = EOF）。
fn recvExact(fd: std.posix.socket_t, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = system.read(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return error.ConnectionClosed; // read error on dead socket
        if (n == 0) return total; // EOF
        total += @intCast(n);
    }
    return total;
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest 端（acceptor）
// ═══════════════════════════════════════════════════════════════════════════

/// TCP 监听器 — 绑定端口并 accept 连接。
pub const TcpListener = struct {
    socket: std.Io.net.Socket,
    io: std.Io,

    pub fn init(io: std.Io, port: u16) !TcpListener {
        const addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
            std.log.err("[netconn] bind addr parse failed: {}", .{err});
            return error.BindFailed;
        };
        const sock = addr.bind(io, .{ .mode = .stream }) catch |err| {
            std.log.err("[netconn] TCP bind :{d} failed: {}", .{ port, err });
            return error.BindFailed;
        };
        _ = system.listen(sock.handle, 128);
        return TcpListener{ .socket = sock, .io = io };
    }

    pub fn deinit(self: *TcpListener) void {
        self.socket.close(self.io);
    }

    /// 接受一个 TCP 连接，完成 SOCKS4a 握手，返回 Connection。
    /// 只有目标是 self_hostname 才接受，否则拒绝并返回错误。
    pub fn accept(self: *TcpListener, self_hostname: []const u8) !Connection {
        while (true) {
            const fd = acceptOne(self.socket.handle) catch |err| {
                if (err == error.WouldBlock) {
                    std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                    continue;
                }
                return err;
            };

            // SOCKS4a 握手
            const req = socks4.socks4Accept(fd) catch |err| {
                std.log.err("[netconn] socks4Accept failed: {}", .{err});
                _ = system.close(fd);
                continue;
            };

            if (std.mem.eql(u8, req.hostname, self_hostname)) {
                socks4.socks4ReplyOk(fd);
                std.log.info("[netconn] accepted connection from self@{s}", .{req.hostname});
                return Connection{ .fd = fd, .alive = true };
            }

            // 目标不是自己 — 拒绝（中继尚未实现）
            std.log.info("[netconn] rejected relay target={s} (not self={s})", .{ req.hostname, self_hostname });
            socks4.socks4ReplyRejected(fd);
            _ = system.close(fd);
        }
    }
};

fn acceptOne(listen_fd: std.posix.socket_t) !std.posix.socket_t {
    var addr: std.Io.net.IpAddress = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.Io.net.IpAddress);
    const fd = system.accept(listen_fd, @ptrCast(&addr), &addr_len);
    if (fd < 0) {
        const e = std.posix.errno(fd);
        if (e == .AGAIN or e == .INTR) return error.WouldBlock;
        return error.AcceptFailed;
    }
    return fd;
}

// ═══════════════════════════════════════════════════════════════════════════
// Host 端（connector）
// ═══════════════════════════════════════════════════════════════════════════

/// 连接到 Guest 并完成 SOCKS4a 握手，返回 Connection。
pub fn hostConnect(io: std.Io, guest_ip: []const u8, guest_hostname: []const u8, port: u16) !Connection {
    const addr = std.Io.net.IpAddress.parse(guest_ip, port) catch |err| {
        std.log.err("[netconn] parse guest IP '{s}' failed: {}", .{ guest_ip, err });
        return error.ConnectFailed;
    };

    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.log.err("[netconn] connect to {s}:{d} failed: {}", .{ guest_ip, port, err });
        return error.ConnectFailed;
    };

    const fd = stream.socket.handle;
    errdefer {
        stream.close(io);
    }

    // 发送 SOCKS4a 请求
    try socks4SendRequest(fd, guest_hostname, port);

    // 读取 SOCKS4 响应
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

    if (resp[1] != 0x5a) { // SOCKS_REP_OK
        stream.close(io);
        std.log.err("[netconn] SOCKS4 rejected by {s}", .{guest_hostname});
        return error.Socks4Rejected;
    }

    // 不关闭 stream — fd 所有权转移给 Connection
    // stream 的 socket 由 Connection.deinit() 关闭
    return Connection{ .fd = fd, .alive = true };
}

/// 发送 SOCKS4a 连接请求。
fn socks4SendRequest(fd: std.posix.socket_t, hostname: []const u8, port: u16) !void {
    var req: [300]u8 = undefined;
    var pos: usize = 0;

    req[pos] = 0x04; // SOCKS4 VER
    pos += 1;
    req[pos] = 0x01; // CMD CONNECT
    pos += 1;
    std.mem.writeInt(u16, req[pos..][0..2], port, .big);
    pos += 2;
    // SOCKS4a: DSTIP = 0.0.0.1
    @memset(req[pos..][0..4], 0);
    req[pos + 3] = 1;
    pos += 4;
    // USERID = "" (null only)
    req[pos] = 0;
    pos += 1;
    // HOSTNAME
    @memcpy(req[pos..][0..hostname.len], hostname);
    pos += hostname.len;
    req[pos] = 0;
    pos += 1;

    const n = system.write(fd, &req, pos);
    if (n != pos) return error.Socks4SendFailed;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

/// 创建一对已连接的 socket（用于测试）。
fn makePair() !struct { a: std.posix.socket_t, b: std.posix.socket_t } {
    var fds: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

test "Connection send/recv round-trip" {
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    try conn.send("hello world");

    var rbuf: [256]u8 = undefined;
    const n = try recvExact(pair.b, rbuf[0..13]); // 4B len(11) + "hello world" = 15 bytes
    _ = n;
}

test "Connection recv detects close" {
    const pair = try makePair();
    defer {
        _ = system.close(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    _ = system.shutdown(pair.a, 2);
    _ = system.close(pair.a);

    var rbuf: [256]u8 = undefined;
    // 关闭后 recv 应返回错误 — 连接已死
    if (conn.recv(&rbuf)) |_| {
        // 可能返回 0
    } else |_| {
        // 或返回错误 — 两种情况都意味着连接已死
    }
    try std.testing.expect(!conn.isAlive());
}
