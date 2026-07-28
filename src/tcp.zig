//! TCP 传输层 — 帧协议 + SOCKS4a + 连接管理。
//!
//! 合并自: tcpf.zig (帧协议) + socks4.zig (SOCKS4a) + netconn.zig (连接抽象)
//!
//! Guest 和 Host 共享同一套网络层：
//!   - Guest:  TCP listen → SOCKS4a accept → Connection
//!   - Host:   TCP connect → SOCKS4a connect → Connection
//!
//! 帧格式: [4-byte BE length][payload]
//! SOCKS4a: VER(1) CMD(1) DSTPORT(2 BE) DSTIP(4 BE) USERID\0 [HOSTNAME\0]
//!
//! 每条 TCP 连接 = 一个请求-响应周期。连接关闭表示会话结束。

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;
const dpipe = @import("dpipe.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Frame Protocol
// ═══════════════════════════════════════════════════════════════════════════

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
        if (n < 0) return error.ConnectionClosed; // read error on dead socket
        if (n == 0) return total; // EOF
        total += @intCast(n);
    }
    return total;
}

/// 发送线程参数（用于大载荷测试避免 socketpair 死锁）。
const SendArgs = struct { fd: std.posix.socket_t, data: []const u8 };

/// 线程入口：发送帧。
fn sendInThread(args: SendArgs) void {
    sendFrame(args.fd, args.data) catch @panic("sendFrame failed in thread");
}

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS4a Protocol
// ═══════════════════════════════════════════════════════════════════════════

const SOCKS_VER: u8 = 0x04;
const SOCKS_CMD_CONNECT: u8 = 0x01;
const SOCKS_REP_OK: u8 = 0x5a;
const SOCKS_REP_REJECTED: u8 = 0x5b;

/// 单个连接的最大 hostname 长度。
const MAX_HOSTNAME: usize = 256;

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
    const stream = std.Io.net.IpAddress.connect(&target_ip, io, .{ .mode = .stream }) catch |err| {
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

/// 从已 accept 的 TCP socket 读取 SOCKS4a 请求。
/// 返回目标 hostname + port。
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
// SOCKS4a 辅助函数
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

/// 发送 SOCKS4a 连接请求（内部使用，通过 raw fd）。
fn socks4SendRequest(fd: std.posix.socket_t, hostname: []const u8, port: u16) !void {
    var req: [300]u8 = undefined;
    var pos: usize = 0;

    req[pos] = SOCKS_VER;
    pos += 1;
    req[pos] = SOCKS_CMD_CONNECT;
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

/// 双向中继：A ↔ B。两个线程各负责一个方向。
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
// Connection — TCP + SOCKS4 连接抽象
// ═══════════════════════════════════════════════════════════════════════════

pub const Connection = struct {
    fd: std.posix.socket_t,
    alive: bool,

    /// 发送一帧（4B BE length + payload）。
    pub fn send(self: *Connection, data: []const u8) !void {
        return sendFrame(self.fd, data);
    }

    /// 发送并立即发送（同 send，TCP 没有 flush 概念）。
    pub fn sendAndFlush(self: *Connection, data: []const u8, _: u32) !void {
        return sendFrame(self.fd, data);
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

// ═══════════════════════════════════════════════════════════════════════════
// DuplexPipe 适配器 — 将原始 socket fd 包装为 dpipe.DuplexPipe
// ═══════════════════════════════════════════════════════════════════════════

const TcpPipeCtx = struct {
    fd: std.posix.socket_t,
    allocator: std.mem.Allocator,
};

fn tcpPipeReadFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const self: *TcpPipeCtx = @ptrCast(@alignCast(ctx));
    const n = system.read(self.fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn tcpPipeWriteFn(ctx: *anyopaque, data: []const u8) anyerror!void {
    const self: *TcpPipeCtx = @ptrCast(@alignCast(ctx));
    const n = system.write(self.fd, data.ptr, data.len);
    if (n != data.len) return error.WriteFailed;
}

fn tcpPipeCloseFn(ctx: *anyopaque) void {
    const self: *TcpPipeCtx = @ptrCast(@alignCast(ctx));
    _ = system.shutdown(self.fd, 2);
    _ = system.close(self.fd);
    self.allocator.destroy(self);
}

const tcp_pipe_vtable = dpipe.VTable{
    .readFn = tcpPipeReadFn,
    .writeFn = tcpPipeWriteFn,
    .closeFn = tcpPipeCloseFn,
};

/// 将 socket fd 包装为 dpipe.DuplexPipe（原始字节流，无帧协议）。
/// close() 会关闭 socket 并释放 ctx 内存。
pub fn duplexPipe(fd: std.posix.socket_t, allocator: std.mem.Allocator) !dpipe.DuplexPipe {
    const ctx = try allocator.create(TcpPipeCtx);
    ctx.* = .{ .fd = fd, .allocator = allocator };
    return dpipe.DuplexPipe{ .ctx = ctx, .vtable = &tcp_pipe_vtable };
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest 端 — TCP Listener
// ═══════════════════════════════════════════════════════════════════════════

/// TCP 监听器 — 绑定端口并 accept 连接。
pub const TcpListener = struct {
    socket: std.Io.net.Socket,
    io: std.Io,

    pub fn init(io: std.Io, port: u16) !TcpListener {
        const addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
            std.log.err("[tcp] bind addr parse failed: {}", .{err});
            return error.BindFailed;
        };
        const sock = addr.bind(io, .{ .mode = .stream }) catch |err| {
            std.log.err("[tcp] TCP bind :{d} failed: {}", .{ port, err });
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
            const req = socks4Accept(fd) catch |err| {
                std.log.err("[tcp] socks4Accept failed: {}", .{err});
                _ = system.close(fd);
                continue;
            };

            if (std.mem.eql(u8, req.hostname, self_hostname)) {
                socks4ReplyOk(fd);
                std.log.info("[tcp] accepted connection from self@{s}", .{req.hostname});
                return Connection{ .fd = fd, .alive = true };
            }

            // 目标不是自己 — 拒绝
            std.log.info("[tcp] rejected relay target={s} (not self={s})", .{ req.hostname, self_hostname });
            socks4ReplyRejected(fd);
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
// Host 端 — Connector
// ═══════════════════════════════════════════════════════════════════════════

/// 连接到 Guest 并完成 SOCKS4a 握手，返回 Connection。
pub fn hostConnect(io: std.Io, guest_ip: []const u8, guest_hostname: []const u8, port: u16) !Connection {
    const addr = std.Io.net.IpAddress.parse(guest_ip, port) catch |err| {
        std.log.err("[tcp] parse guest IP '{s}' failed: {}", .{ guest_ip, err });
        return error.ConnectFailed;
    };

    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.log.err("[tcp] connect to {s}:{d} failed: {}", .{ guest_ip, port, err });
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

    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        std.log.err("[tcp] SOCKS4 rejected by {s}", .{guest_hostname});
        return error.Socks4Rejected;
    }

    // 不关闭 stream — fd 所有权转移给 Connection
    return Connection{ .fd = fd, .alive = true };
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

// ── 帧协议测试 ──

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

// ── SOCKS4a 协议测试 ──

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

// ── Connection 测试 ──

test "Connection send/recv round-trip" {
    const pair = try makePair();
    defer {
        _ = system.close(pair.a);
        _ = system.close(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    try conn.send("hello world");

    var rbuf: [256]u8 = undefined;
    // 对端读取 4B header + payload 验证帧格式正确
    const nr = try recvExact(pair.b, rbuf[0..15]);
    try std.testing.expect(nr == 15);
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
    if (conn.recv(&rbuf)) |_| {} else |_| {}
    try std.testing.expect(!conn.isAlive());
}
