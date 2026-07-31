//! TCP transport: frame protocol + SOCKS5 proxy + connection management + forwarding
//!
//! Guest 和 Host 共享同一套网络层：
//!   - 监听:    TCP listen → SOCKS5 accept → dispatch (self/forward/local)
//!   - 连接:    TCP connect → SOCKS5 connect → Connection
//!   - 转发:    SOCKS5 chain-forward → 目标节点 :2121 → 本地 relay
//!   - 本地:    127.0.0.1:port → relay
//!
//! 帧格式: [4-byte BE length][payload]
//! SOCKS5: auth(VER=5 NMETHODS METHOD) → VER(1) CMD(1) RSV(1) ATYP(1) [LEN(1) HOSTNAME] PORT(2 BE)
//!
//! 每条 TCP 连接 = 一个请求-响应周期。连接关闭表示会话结束。

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;
const dpipe = @import("dpipe.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Platform Socket Abstraction
// ═══════════════════════════════════════════════════════════════════════════
//
// socket_t is platform-dependent: c_int on POSIX, *anyopaque on Windows.
// system.read/write/close operate on c_int fds (POSIX) but NOT on Windows
// sockets — Winsock2 requires send/recv/closesocket. These inline wrappers
// branch at comptime so there is zero runtime overhead.

const socket_t = std.posix.socket_t;

/// Write data to a socket. POSIX: write(), Windows: send().
/// Returns number of bytes written, or -1 on fatal error.
/// Retries on EAGAIN (non-blocking socket, buffer full) and
/// EINTR (interrupted by signal).
pub inline fn sockWrite(fd: socket_t, buf: [*]const u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        return ws2_send(fd, buf, @intCast(len), 0);
    }
    while (true) {
        const n = system.write(fd, buf, len);
        if (n >= 0) return n;
        const e = std.posix.errno(n);
        if (e == .AGAIN or e == .INTR) continue;
        return n;
    }
}

/// Read data from a socket. POSIX: read(), Windows: recv().
/// Returns number of bytes read, 0 on EOF, or -1 on fatal error.
/// Retries on EAGAIN (non-blocking socket, no data yet) and
/// EINTR (interrupted by signal) — caller sees blocking read behavior
/// regardless of the socket's non-blocking flag.
pub inline fn sockRead(fd: socket_t, buf: [*]u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        return ws2_recv(fd, buf, @intCast(len), 0);
    }
    while (true) {
        const n = system.read(fd, buf, len);
        if (n >= 0) return n;
        const e = std.posix.errno(n);
        if (e == .AGAIN or e == .INTR) continue;
        return n;
    }
}

/// Check if a sockRead/sockWrite return value indicates an error (-1).
pub inline fn sockIsError(n: isize) bool {
    return n < 0;
}

/// Close a socket. POSIX: close(), Windows: closesocket() via ws2_32.
pub inline fn sockClose(fd: socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = ws2_closesocket(fd);
    } else {
        _ = system.close(fd);
    }
}

/// Shutdown a socket.
pub inline fn sockShutdown(fd: socket_t, how: i32) void {
    if (builtin.os.tag == .windows) {
        _ = ws2_shutdown(fd, how);
    } else {
        _ = system.shutdown(fd, how);
    }
}

/// Accept a connection on a listening socket. Returns the client socket.
/// On Windows: uses Winsock2 accept() returning a proper SOCKET handle
/// (compatible with ws2_recv/ws2_send), NOT an AFD kernel handle.
pub fn sockAccept(listen_fd: socket_t) !socket_t {
    if (builtin.os.tag == .windows) {
        var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        const raw = ws2_accept(listen_fd, @ptrCast(&addr), &addr_len);
        if (raw == INVALID_SOCKET) {
            return error.AcceptFailed;
        }
        return raw;
    }
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

/// Listen on a socket. POSIX: listen(), Windows: listen() from ws2_32.
pub inline fn sockListen(fd: socket_t, backlog: c_int) isize {
    if (builtin.os.tag == .windows) {
        return ws2_listen(fd, backlog);
    }
    return system.listen(fd, backlog);
}

// ── Winsock2 externs (ws2_32 linked by build.zig when target is Windows) ──
// All use callconv(.winapi) for correct 32-bit stdcall name decoration
// (@n suffix, e.g. _send@16). On 64-bit Windows, .winapi = .C (no-op).
//
// IMPORTANT: On Windows, Zig 0.16.0's Io.net APIs (listen/bind/accept) use AFD
// (Ancillary Function Driver) kernel handles, which are NOT compatible with
// Winsock2 recv/send. We MUST use raw Winsock2 socket creation + accept to get
// handles that work with ws2_recv/ws2_send.
extern "ws2_32" fn socket(af: c_int, type: c_int, protocol: c_int) callconv(.winapi) std.posix.socket_t;
const ws2_socket = socket;
extern "ws2_32" fn bind(s: std.posix.socket_t, name: *const anyopaque, namelen: std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_bind = bind;
extern "ws2_32" fn send(s: std.posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
const ws2_send = send;
extern "ws2_32" fn recv(s: std.posix.socket_t, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
const ws2_recv = recv;
extern "ws2_32" fn accept(s: std.posix.socket_t, addr: ?*anyopaque, addrlen: ?*std.posix.socklen_t) callconv(.winapi) std.posix.socket_t;
const ws2_accept = accept;
extern "ws2_32" fn listen(s: std.posix.socket_t, backlog: c_int) callconv(.winapi) c_int;
const ws2_listen = listen;
extern "ws2_32" fn closesocket(s: std.posix.socket_t) callconv(.winapi) c_int;
const ws2_closesocket = closesocket;
extern "ws2_32" fn shutdown(s: std.posix.socket_t, how: c_int) callconv(.winapi) c_int;
const ws2_shutdown = shutdown;
extern "ws2_32" fn setsockopt(s: std.posix.socket_t, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_int) callconv(.winapi) c_int;
const ws2_setsockopt = setsockopt;
extern "ws2_32" fn connect(s: std.posix.socket_t, name: *const anyopaque, namelen: std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_connect = connect;
extern "ws2_32" fn getsockname(s: std.posix.socket_t, name: *anyopaque, namelen: *std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_getsockname = getsockname;
extern "ws2_32" fn htons(hostshort: u16) callconv(.winapi) u16;
const ws2_htons = htons;
extern "ws2_32" fn ntohs(netshort: u16) callconv(.winapi) u16;
const ws2_ntohs = ntohs;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
const ws2_getLastError = WSAGetLastError;
extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) c_int;
const ws2_startup = WSAStartup;

/// Ensure Winsock2 is initialized (required for raw ws2_socket/ws2_recv etc.).
/// Zig 0.16.0 uses AFD kernel handles for its own I/O, NOT Winsock2, so we
/// must call WSAStartup ourselves. Safe to call multiple times.
var ws2_initialized = false;
fn ensureWinsock2() void {
    if (ws2_initialized) return;
    if (builtin.os.tag == .windows) {
        // WSDATA is 400 bytes — allocate on stack
        var wsdata: [400]u8 align(4) = [_]u8{0} ** 400;
        const rc = ws2_startup(0x0202, @ptrCast(&wsdata)); // request Winsock 2.2
        if (rc == 0) {
            ws2_initialized = true;
        }
    }
}

const AF_INET = 2;
const SOCK_STREAM = 1;
const IPPROTO_TCP = 6;
const SO_REUSEADDR = 0x0004;
const SOL_SOCKET = 0xffff;
const INVALID_SOCKET: std.posix.socket_t = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

/// Windows sockaddr_in — must match exactly what Winsock2 expects.
/// Zig's std.Io.net.IpAddress is a tagged union with a different layout
/// and cannot be cast directly to sockaddr.
const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = [_]u8{0} ** 8,
};

/// Create a pair of connected sockets (for testing).
/// On Windows, std.c.socketpair doesn't exist — uses TCP loopback instead.
pub fn makePair() !struct { a: socket_t, b: socket_t } {
    if (builtin.os.tag == .windows) {
        // TCP loopback pair using raw Winsock2 sockets (NOT Zig AFD handles).
        // Zig 0.16.0 Io.net APIs use AFD kernel handles incompatible with
        // ws2_recv/ws2_send. We use raw Winsock2 for both listener and client.
        ensureWinsock2();

        const listener = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) return error.SocketPairFailed;

        const reuse: c_int = 1;
        _ = ws2_setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        // Bind to 127.0.0.1:0
        var bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = 0, // OS assigns port
            .addr = 0x0100007f, // 127.0.0.1 in network byte order (big endian)
        };
        const br = ws2_bind(listener, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        // Get the assigned port
        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        _ = ws2_getsockname(listener, @ptrCast(&bind_addr), &addr_len);
        const port = ws2_ntohs(bind_addr.port);

        _ = ws2_listen(listener, 1);

        // Client connect to 127.0.0.1:port
        const client = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (client == INVALID_SOCKET) {
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        var conn_addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(port),
            .addr = 0x0100007f, // 127.0.0.1
        };
        const cr = ws2_connect(client, @ptrCast(&conn_addr), @sizeOf(sockaddr_in));
        if (cr != 0) {
            _ = ws2_closesocket(client);
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        const server = try sockAccept(listener);
        _ = ws2_closesocket(listener); // listener no longer needed

        return .{ .a = client, .b = server };
    }
    var fds: [2]socket_t = undefined;
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

/// 将 socket 设为非阻塞模式，用于测试 EAGAIN 重试路径。
/// POSIX: fcntl(F_SETFL, O_NONBLOCK)。Windows: ioctlsocket(FIONBIO)。
pub fn makeNonBlocking(fd: socket_t) void {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        var mode: std.os.windows.ULONG = 1;
        _ = ws2_ioctlsocket(fd, FIONBIO, &mode);
    } else {
        const NONBLOCK = if (builtin.os.tag == .linux) @as(c_int, 0x800) else @as(c_int, 0x4);
        const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | NONBLOCK);
    }
}

/// 创建一对非阻塞已连接 socket，用于测试 EAGAIN/WouldBlock 路径。
pub fn makeNonBlockingPair() !struct { a: socket_t, b: socket_t } {
    const pair = try makePair();
    makeNonBlocking(pair.a);
    makeNonBlocking(pair.b);
    return .{ .a = pair.a, .b = pair.b };
}

const FIONBIO: c_int = 0x8004667e;
extern "ws2_32" fn ioctlsocket(s: std.posix.socket_t, cmd: c_int, argp: *std.os.windows.ULONG) callconv(.winapi) c_int;
const ws2_ioctlsocket = ioctlsocket;

// ═══════════════════════════════════════════════════════════════════════════
// Frame Protocol
// ═══════════════════════════════════════════════════════════════════════════

/// 单帧最大 16 MB（供文件传输使用）。
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// 发送一帧：写入 4-byte BE length + payload。
pub fn sendFrame(fd: std.posix.socket_t, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    const n1 = sockWrite(fd, &len_buf, len_buf.len);
    if (n1 != 4) return error.SendFailed;
    const n2 = sockWrite(fd, data.ptr, data.len);
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
        const n = sockRead(fd, buf.ptr + total, buf.len - total);
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
// SOCKS5 Protocol (RFC 1928)
// ═══════════════════════════════════════════════════════════════════════════

const SOCKS_VER: u8 = 0x05;
const SOCKS_CMD_CONNECT: u8 = 0x01;
const SOCKS_AUTH_NOAUTH: u8 = 0x00;
const SOCKS_AUTH_NONE_ACCEPTABLE: u8 = 0xff;
const SOCKS_ATYP_IPV4: u8 = 0x01;
const SOCKS_ATYP_DOMAIN: u8 = 0x03;
const SOCKS_REP_OK: u8 = 0x00;
const SOCKS_REP_GENERAL_FAILURE: u8 = 0x01;

/// 单个连接的最大 hostname 长度。
pub const MAX_HOSTNAME: usize = 256;

pub const Socks5Request = struct {
    hostname: []const u8,
    port: u16,
};

/// 栈分配的 SOCKS5 请求读取结果。hostname 指向调用者缓冲区。
pub const Socks5RequestBuf = struct {
    hostname: []const u8,
    port: u16,
};

/// SOCKS5 认证协商（服务端）：读取客户端 method 列表，选择 NO AUTH。
fn socks5AuthAccept(fd: std.posix.socket_t) !void {
    // 读取 VER(1) + NMETHODS(1)
    var auth_hdr: [2]u8 = undefined;
    var off: usize = 0;
    while (off < 2) {
        const n = sockRead(fd, auth_hdr[off..].ptr, auth_hdr.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5AuthFailed;
        off += @intCast(n);
    }
    if (auth_hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    const nmethods = auth_hdr[1];

    // 读取 method 列表
    var methods: [256]u8 = undefined;
    if (nmethods > 0) {
        off = 0;
        while (off < nmethods) {
            const n = sockRead(fd, methods[off..].ptr, nmethods - off);
            if (sockIsError(n) or n == 0) return error.Socks5AuthFailed;
            off += @intCast(n);
        }
    }

    // 检查是否提供了 NO AUTH
    const found_noauth = for (methods[0..nmethods]) |m| {
        if (m == SOCKS_AUTH_NOAUTH) break true;
    } else false;

    if (!found_noauth) {
        const resp = [_]u8{ SOCKS_VER, SOCKS_AUTH_NONE_ACCEPTABLE };
        _ = sockWrite(fd, &resp, resp.len);
        return error.Socks5AuthNoMethod;
    }

    // 接受 NO AUTH
    const resp = [_]u8{ SOCKS_VER, SOCKS_AUTH_NOAUTH };
    const n = sockWrite(fd, &resp, resp.len);
    if (n != resp.len) return error.Socks5AuthFailed;
}

/// 读取 SOCKS5 请求到调用者提供的缓冲区，不发回复。
/// 内部完成认证协商 + 请求解析。hostname 写入 buf，返回 Socks5RequestBuf。
pub fn socks5ReadRequestBuf(fd: std.posix.socket_t, buf: []u8) !Socks5RequestBuf {
    // Phase 1: SOCKS5 auth negotiation
    try socks5AuthAccept(fd);

    // Phase 2: 读取请求头: VER(1) CMD(1) RSV(1) ATYP(1) = 4 bytes
    var hdr: [4]u8 = undefined;
    var off: usize = 0;
    while (off < 4) {
        const n = sockRead(fd, hdr[off..].ptr, hdr.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    if (hdr[1] != SOCKS_CMD_CONNECT) return error.Socks5BadCommand;
    if (hdr[3] != SOCKS_ATYP_DOMAIN) return error.Socks5DomainRequired;

    // Phase 3: 读取 hostname 长度 (1 byte) + hostname
    var len_byte: u8 = undefined;
    off = 0;
    while (off < 1) {
        const n = sockRead(fd, @as([*]u8, @ptrCast(&len_byte)), 1);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (len_byte == 0 or len_byte > MAX_HOSTNAME) return error.Socks5BadHostname;

    off = 0;
    while (off < len_byte) {
        const n = sockRead(fd, buf[off..].ptr, len_byte - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const hostname = buf[0..len_byte];

    // Phase 4: 读取 port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5RequestBuf{ .hostname = hostname, .port = dst_port };
}

/// 发送 SOCKS5 连接请求到目标地址（含认证协商）。
/// 返回连接成功后的 TCP socket fd（调用者负责关闭）。
pub fn socks5Connect(
    io: std.Io,
    target_ip: std.Io.net.IpAddress,
    target_hostname: []const u8,
    target_port: u16,
) !std.Io.net.Stream {
    const stream = std.Io.net.IpAddress.connect(&target_ip, io, .{ .mode = .stream }) catch |err| {
        return err;
    };
    errdefer stream.close(io);

    const fd = stream.socket.handle;
    try socks5SendRequest(fd, target_hostname, target_port);

    // 读取 SOCKS5 响应: VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(var) BND.PORT(2)
    // 最少 10 bytes（ATYP=IPv4 时）
    var resp: [10]u8 = undefined;
    var off: usize = 0;
    while (off < 10) {
        const n = sockRead(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) {
            stream.close(io);
            return error.Socks5ResponseTooShort;
        }
        off += @intCast(n);
    }
    if (resp[0] != SOCKS_VER) {
        stream.close(io);
        return error.Socks5BadVersion;
    }
    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        return error.Socks5Rejected;
    }

    return stream;
}

/// 从已 accept 的 TCP socket 读取 SOCKS5 请求（含认证协商），检查 hostname 是否匹配。
/// 匹配则发送 OK 响应并返回 true，否则发送拒绝响应并返回 false。
pub fn socks5CheckAndReply(fd: std.posix.socket_t, self_hostname: []const u8) !bool {
    var buf: [MAX_HOSTNAME]u8 = undefined;
    const req = try socks5ReadRequestBuf(fd, buf[0..]);
    if (std.mem.eql(u8, req.hostname, self_hostname)) {
        socks5ReplyOk(fd);
        return true;
    }
    socks5ReplyRejected(fd);
    return false;
}

/// 读取 SOCKS5 请求（含认证协商，仅用于测试）。
/// 返回的 Socks5Request.hostname 由 allocator 分配，调用者负责释放。
/// 生产代码请使用 socks5CheckAndReply 或 socks5ReadRequestBuf。
pub fn socks5Accept(fd: std.posix.socket_t, allocator: std.mem.Allocator) !Socks5Request {
    // Phase 1: SOCKS5 auth negotiation
    try socks5AuthAccept(fd);

    // Phase 2: 读取请求头: VER(1) CMD(1) RSV(1) ATYP(1) = 4 bytes
    var hdr: [4]u8 = undefined;
    var off: usize = 0;
    while (off < 4) {
        const n = sockRead(fd, hdr[off..].ptr, hdr.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    if (hdr[1] != SOCKS_CMD_CONNECT) return error.Socks5BadCommand;
    if (hdr[3] != SOCKS_ATYP_DOMAIN) return error.Socks5DomainRequired;

    // Phase 3: 读取 hostname 长度 (1 byte) + hostname
    var len_byte: u8 = undefined;
    off = 0;
    while (off < 1) {
        const n = sockRead(fd, @as([*]u8, @ptrCast(&len_byte)), 1);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (len_byte == 0 or len_byte > MAX_HOSTNAME) return error.Socks5BadHostname;

    var hn_buf: [MAX_HOSTNAME]u8 = undefined;
    off = 0;
    while (off < len_byte) {
        const n = sockRead(fd, hn_buf[off..].ptr, len_byte - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const hn = hn_buf[0..len_byte];

    // Phase 4: 读取 port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5Request{ .hostname = try allocator.dupe(u8, hn), .port = dst_port };
}

/// 发送 SOCKS5 成功响应（10 bytes）。
pub fn socks5ReplyOk(fd: std.posix.socket_t) void {
    const resp = [_]u8{
        SOCKS_VER, SOCKS_REP_OK, // VER, REP=success
        0x00, // RSV
        SOCKS_ATYP_IPV4, // ATYP=IPv4
        0x00, 0x00, 0x00, 0x00, // BND.ADDR = 0.0.0.0
        0x00, 0x00, // BND.PORT = 0
    };
    _ = sockWrite(fd, &resp, resp.len);
}

/// 发送 SOCKS5 拒绝响应（10 bytes）。
pub fn socks5ReplyRejected(fd: std.posix.socket_t) void {
    const resp = [_]u8{
        SOCKS_VER, SOCKS_REP_GENERAL_FAILURE, // VER, REP=failure
        0x00, // RSV
        SOCKS_ATYP_IPV4, // ATYP=IPv4
        0x00, 0x00, 0x00, 0x00, // BND.ADDR = 0.0.0.0
        0x00, 0x00, // BND.PORT = 0
    };
    _ = sockWrite(fd, &resp, resp.len);
}

/// SOCKS5 链式转发：连接下一跳节点，发送 SOCKS5 请求，成功后 relay。
/// 失败时发送拒绝响应给原始客户端。此函数不返回（void），适合在线程中调用。
pub fn socks5Forward(
    io: std.Io,
    client_fd: std.posix.socket_t,
    next_hop_ip: std.Io.net.IpAddress,
    target_hostname: []const u8,
    target_port: u16,
) void {
    const stream = socks5Connect(io, next_hop_ip, target_hostname, target_port) catch {
        socks5ReplyRejected(client_fd);
        sockClose(client_fd);
        return;
    };
    const next_fd = stream.socket.handle;
    // 不 close stream — fd 所有权转移给 socks5Relay

    socks5ReplyOk(client_fd);
    socks5Relay(client_fd, next_fd);
    sockClose(client_fd);
    sockClose(next_fd);
}

/// 本地 relay：连接 127.0.0.1:target_port，成功后 relay。
/// 失败时发送拒绝响应给客户端。此函数不返回（void），适合在线程中调用。
///
/// 使用原始 socket API（而非 Zig Io.net）确保返回的 fd 与 client_fd
/// 类型一致。Windows：Winsock2 SOCKET vs AFD 句柄不兼容。
pub fn socks5LocalRelay(io: std.Io, client_fd: std.posix.socket_t, target_port: u16) void {
    _ = io; // unused — raw sockets don't need Zig Io
    const local_fd = sockConnectLocalhost(target_port) catch {
        socks5ReplyRejected(client_fd);
        sockClose(client_fd);
        return;
    };

    socks5ReplyOk(client_fd);
    socks5Relay(client_fd, local_fd);
    sockClose(client_fd);
    sockClose(local_fd);
}

/// 连接 127.0.0.1:port，返回与 sockAccept 兼容的 socket fd。
/// Windows：使用 Winsock2 原始 socket（与 ws2_accept 兼容）。
/// POSIX：使用 system.socket + system.connect（与 system.accept 兼容）。
fn sockConnectLocalhost(port: u16) !socket_t {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        const fd = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd == INVALID_SOCKET) return error.ConnectFailed;
        var addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(port),
            .addr = 0x0100007f, // 127.0.0.1 in network byte order (big-endian)
        };
        const rc = ws2_connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_in));
        if (rc != 0) {
            _ = ws2_closesocket(fd);
            return error.ConnectFailed;
        }
        return fd;
    }
    // POSIX: raw socket + connect (compatible with system.accept fd)
    const fd = system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ConnectFailed;
    errdefer _ = system.close(fd);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0x0100007f, // 127.0.0.1 in network byte order
        .zero = [_]u8{0} ** 8,
    };
    const rc = system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (rc < 0) return error.ConnectFailed;
    return fd;
}

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 辅助函数
// ═══════════════════════════════════════════════════════════════════════════

/// 发送 SOCKS5 认证协商 + 连接请求（内部使用，通过 raw fd）。
fn socks5SendRequest(fd: std.posix.socket_t, hostname: []const u8, port: u16) !void {
    // Step 1: 发送认证协商 [0x05, 0x01, 0x00]（VER, 1 method, NO AUTH）
    const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
    const n1 = sockWrite(fd, &auth, auth.len);
    if (n1 != auth.len) return error.Socks5SendFailed;

    // Step 2: 读取认证响应 [0x05, 0x00]
    var auth_resp: [2]u8 = undefined;
    var off: usize = 0;
    while (off < 2) {
        const n = sockRead(fd, auth_resp[off..].ptr, auth_resp.len - off);
        if (sockIsError(n) or n == 0) return error.Socks5AuthFailed;
        off += @intCast(n);
    }
    if (auth_resp[0] != SOCKS_VER or auth_resp[1] != SOCKS_AUTH_NOAUTH) {
        return error.Socks5AuthFailed;
    }

    // Step 3: 构建并发送 SOCKS5 请求
    // VER(1) CMD(1) RSV(1) ATYP(1) LEN(1) HOSTNAME(N) PORT(2)
    var req: [270]u8 = undefined;
    var pos: usize = 0;
    req[pos] = SOCKS_VER;
    pos += 1;
    req[pos] = SOCKS_CMD_CONNECT;
    pos += 1;
    req[pos] = 0x00;
    pos += 1; // RSV
    req[pos] = SOCKS_ATYP_DOMAIN;
    pos += 1;
    req[pos] = @truncate(hostname.len);
    pos += 1; // 1-byte hostname length
    @memcpy(req[pos..][0..hostname.len], hostname);
    pos += hostname.len;
    std.mem.writeInt(u16, req[pos..][0..2], port, .big);
    pos += 2;

    const n2 = sockWrite(fd, &req, pos);
    if (n2 != pos) return error.Socks5SendFailed;
}

/// 双向中继：A ↔ B。两个线程各负责一个方向。
/// 一侧关闭时 shutdown 对端写端，避免半开连接。
pub fn socks5Relay(a_fd: std.posix.socket_t, b_fd: std.posix.socket_t) void {
    var a_to_b_done = std.atomic.Value(bool).init(false);

    const relay_thread = std.Thread.spawn(.{}, relayDir, .{ b_fd, a_fd, &a_to_b_done }) catch return;
    defer relay_thread.join();

    relayDir(a_fd, b_fd, &a_to_b_done);
}

fn relayDir(src: std.posix.socket_t, dst: std.posix.socket_t, done: *std.atomic.Value(bool)) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = sockRead(src, &buf, buf.len);
        if (n == 0) {
            sockShutdown(dst, 1); // SHUT_WR — 通知对端不再发送
            done.store(true, .release);
            return;
        }
        if (sockIsError(n)) {
            done.store(true, .release);
            return;
        }
        const w = sockWrite(dst, &buf, @intCast(n));
        if (sockIsError(w)) {
            done.store(true, .release);
            return;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Connection — TCP + SOCKS5 连接抽象
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
        sockShutdown(self.fd, 2); // SHUT_RDWR
        sockClose(self.fd);
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
    const n = sockRead(self.fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn tcpPipeWriteFn(ctx: *anyopaque, data: []const u8) anyerror!void {
    const self: *TcpPipeCtx = @ptrCast(@alignCast(ctx));
    const n = sockWrite(self.fd, data.ptr, data.len);
    if (n != data.len) return error.WriteFailed;
}

fn tcpPipeCloseFn(ctx: *anyopaque) void {
    const self: *TcpPipeCtx = @ptrCast(@alignCast(ctx));
    sockShutdown(self.fd, 2);
    sockClose(self.fd);
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
/// On POSIX: uses Io.net.Server (reuse_address + FD_CLOEXEC via fcntl).
/// On Windows: uses raw bind + sockListen (raw SOCKET handles compatible
/// with ws2_recv, avoiding overlapped I/O issues with Server.accept).
pub const TcpListener = struct {
    server: ?std.Io.net.Server = null,
    io: std.Io,
    listener_fd: socket_t = undefined,
    use_raw_accept: bool = false,
    port: u16 = 0,

    pub fn init(io: std.Io, port: u16) !TcpListener {
        const addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
            std.log.err("[tcp] bind addr parse failed: {}", .{err});
            return error.BindFailed;
        };

        // Windows: use raw Winsock2 socket (not Zig's AFD-based Io.net APIs).
        // Zig 0.16.0 uses AFD kernel handles for socket I/O, which are NOT
        // compatible with Winsock2 recv/send. Raw Winsock2 SOCKET handles
        // work with both WS2 and our sockRead/sockWrite wrappers.
        if (builtin.os.tag == .windows) {
            ensureWinsock2();
            const s = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (s == INVALID_SOCKET) {
                std.log.err("[tcp] ws2_socket failed: WSAGetLastError={d}", .{ws2_getLastError()});
                return error.BindFailed;
            }

            // SO_REUSEADDR — allow fast restart
            const reuse: c_int = 1;
            _ = ws2_setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

            // bind to 0.0.0.0:port using Windows sockaddr_in
            var bind_addr = sockaddr_in{
                .family = AF_INET,
                .port = ws2_htons(port),
                .addr = 0, // INADDR_ANY
            };
            const br = ws2_bind(s, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
            if (br != 0) {
                std.log.err("[tcp] ws2_bind :{d} failed: WSAGetLastError={d}", .{ port, ws2_getLastError() });
                _ = ws2_closesocket(s);
                return error.BindFailed;
            }

            // Get actual port (needed when port=0 for OS-assigned port)
            var actual_port = port;
            if (port == 0) {
                var name_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
                _ = ws2_getsockname(s, @ptrCast(&bind_addr), &name_len);
                actual_port = ws2_ntohs(bind_addr.port);
            }

            const lr = ws2_listen(s, 128);
            if (lr != 0) {
                std.log.err("[tcp] ws2_listen :{d} failed: WSAGetLastError={d}", .{ port, ws2_getLastError() });
                _ = ws2_closesocket(s);
                return error.BindFailed;
            }

            std.log.info("[tcp] raw Winsock2 TCP listener bound :{d}", .{actual_port});
            return TcpListener{ .server = null, .io = io, .listener_fd = s, .use_raw_accept = true, .port = actual_port };
        }

        // POSIX: addr.listen() gives us reuse_address and FD_CLOEXEC in one call.
        const server = addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = 128,
            .mode = .stream,
        }) catch |err| {
            std.log.err("[tcp] TCP listen :{d} failed: {}", .{ port, err });
            return error.BindFailed;
        };

        // Set FD_CLOEXEC on the listening socket — prevents dpipe_shell forked
        // children from inheriting it. An orphaned child holding the port causes
        // AddressInUse crash loop on restart.
        const sfd = server.socket.handle;
        const flags = std.c.fcntl(sfd, @intCast(std.posix.F.GETFD), @as(c_int, 0));
        _ = std.c.fcntl(sfd, @intCast(std.posix.F.SETFD), @as(c_int, flags | std.posix.FD_CLOEXEC));

        return TcpListener{ .server = server, .io = io, .listener_fd = sfd, .use_raw_accept = false, .port = server.socket.address.getPort() };
    }

    pub fn deinit(self: *TcpListener) void {
        if (self.use_raw_accept) {
            sockClose(self.listener_fd);
        } else {
            self.server.?.deinit(self.io);
        }
    }

    /// 接受一个 TCP 连接，返回 raw socket fd。
    /// SOCKS5 握手和 dispatch 由调用方处理（guest.zig / host.zig）。
    pub fn acceptRaw(self: *TcpListener) !std.posix.socket_t {
        while (true) {
            if (self.use_raw_accept) {
                return try sockAccept(self.listener_fd);
            }
            const stream = self.server.?.accept(self.io) catch |err| {
                if (err == error.WouldBlock) {
                    std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                    continue;
                }
                return error.AcceptFailed;
            };
            return stream.socket.handle;
        }
    }

    /// 接受一个 TCP 连接，完成 SOCKS5 握手，返回 Connection。
    /// 只有目标是 self_hostname 才接受，否则拒绝并返回错误。
    pub fn accept(self: *TcpListener, self_hostname: []const u8) !Connection {
        while (true) {
            const fd = try self.acceptRaw();

            // SOCKS5 握手
            const accepted = socks5CheckAndReply(fd, self_hostname) catch |err| {
                std.log.err("[tcp] socks5CheckAndReply failed: {}", .{err});
                sockClose(fd);
                continue;
            };

            if (accepted) {
                std.log.info("[tcp] accepted connection from self@{s}", .{self_hostname});
                return Connection{ .fd = fd, .alive = true };
            }

            // 目标不是自己 — 已由 socks5CheckAndReply 发送拒绝响应
            std.log.info("[tcp] rejected relay target (not self={s})", .{self_hostname});
            sockClose(fd);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Host 端 — Connector
// ═══════════════════════════════════════════════════════════════════════════

/// 连接到 Guest 并完成 SOCKS5 握手，返回 Connection。
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

    // 发送 SOCKS5 认证 + 请求
    try socks5SendRequest(fd, guest_hostname, port);

    // 读取 SOCKS5 响应（10 bytes）
    var resp: [10]u8 = undefined;
    var off: usize = 0;
    while (off < 10) {
        const n = sockRead(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) {
            stream.close(io);
            return error.Socks5ResponseTooShort;
        }
        off += @intCast(n);
    }

    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        std.log.err("[tcp] SOCKS5 rejected by {s}", .{guest_hostname});
        return error.Socks5Rejected;
    }

    // 不关闭 stream — fd 所有权转移给 Connection
    return Connection{ .fd = fd, .alive = true };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

// ── 帧协议测试 ──

test "sendFrame/recvFrame round-trip" {
    const allocator = std.testing.allocator;
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
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
        sockClose(pair.a);
        sockClose(pair.b);
    }

    sockShutdown(pair.a, 1); // SHUT_WR=1
    const result = recvFrame(allocator, pair.b);
    try std.testing.expectError(error.ConnectionClosed, result);
}

test "recvFrame large payload" {
    const allocator = std.testing.allocator;
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
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
        sockClose(pair.a);
        sockClose(pair.b);
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

// ── SOCKS5 协议测试 ──

test "socks5 handshake round-trip" {
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 客户端线程：发送 SOCKS5 认证 + 请求 → 验证响应
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            // Auth: [0x05, 0x01, 0x00]
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = sockWrite(fd, &auth, auth.len);
            // 读取 auth 响应
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }
            std.debug.assert(auth_resp[0] == SOCKS_VER);
            std.debug.assert(auth_resp[1] == SOCKS_AUTH_NOAUTH);

            // Request: VER CMD RSV ATYP=0x03 LEN=4 "test" PORT=2121
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT, // VER, CMD
                0x00, // RSV
                SOCKS_ATYP_DOMAIN, // ATYP=domain
                4, // hostname len
                't',  'e',  's',  't', // HOSTNAME
                0x08, 0x49, // PORT = 2121
            };
            _ = sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            if (off >= 2) {
                std.debug.assert(resp[0] == SOCKS_VER);
                std.debug.assert(resp[1] == SOCKS_REP_OK);
            }
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // 服务端：accept → 读取 SOCKS5 请求 → 发回应
    const request = try socks5Accept(pair.a, std.testing.allocator);
    defer std.testing.allocator.free(request.hostname);
    try std.testing.expectEqualStrings("test", request.hostname);
    try std.testing.expectEqual(@as(u16, 2121), request.port);

    socks5ReplyOk(pair.a);
}

test "socks5ReplyRejected" {
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    socks5ReplyRejected(pair.a);

    var resp: [10]u8 = [_]u8{0} ** 10;
    var off: usize = 0;
    while (off < 10) {
        const n = sockRead(pair.b, resp[off..].ptr, resp.len - off);
        if (n == 0) break;
        off += @intCast(n);
    }
    try std.testing.expect(resp[1] == SOCKS_REP_GENERAL_FAILURE);
}

test "socks5CheckAndReply matching hostname" {
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 客户端线程：发送正确 hostname 的 SOCKS5 请求
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="self"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                4, 's', 'e', 'l', 'f',
                0x08, 0x49, // PORT = 2121
            };
            _ = sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_OK);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // 服务端：socks5CheckAndReply 应匹配 "self" 返回 true + 发送 OK
    const accepted = try socks5CheckAndReply(pair.a, "self");
    try std.testing.expect(accepted);
}

test "socks5CheckAndReply mismatched hostname" {
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 客户端线程：发送 "intruder" hostname
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="intruder"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                8, 'i', 'n', 't', 'r', 'u', 'd', 'e', 'r',
                0x08, 0x49,
            };
            _ = sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_GENERAL_FAILURE);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // 服务端：socks5CheckAndReply 应不匹配并返回 false + 发送拒绝
    const accepted = try socks5CheckAndReply(pair.a, "self");
    try std.testing.expect(!accepted);
}

// ── Connection 测试 ──

test "Connection send/recv round-trip" {
    const pair = try makePair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
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
        sockClose(pair.b);
    }

    var conn = Connection{ .fd = pair.a, .alive = true };
    sockShutdown(pair.a, 2);
    sockClose(pair.a);

    var rbuf: [256]u8 = undefined;
    if (conn.recv(&rbuf)) |_| {} else |_| {}
    try std.testing.expect(!conn.isAlive());
}

// ── EAGAIN 回归测试 — 非阻塞 socket 上的 I/O 重试 ──
// 这些测试验证 sockRead/sockWrite 在非阻塞 socket 上正确重试 EAGAIN，
// 以及依赖它们的 sendFrame/recvFrame/recvExact/socks5CheckAndReply 等。
// Bug 背景：macOS kqueue 非阻塞 socket 上 system.read() 返回 EAGAIN 时，
// 旧代码直接当作错误处理，导致连接挂起/数据丢失。

test "sockRead retries on EAGAIN (non-blocking socket, delayed write)" {
    const pair = try makeNonBlockingPair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 在另一个线程延迟 50ms 后写入数据，模拟非阻塞 socket 上数据分包到达。
    // sockRead 在数据到达前会遇到 EAGAIN，必须重试直到数据可用。
    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            var t: std.Io.Threaded = .init_single_threaded;
            std.Io.sleep(t.io(), std.Io.Duration.fromMilliseconds(50), .real) catch {};
            _ = sockWrite(fd, "EAGAIN_OK", 9);
        }
    }.run, .{pair.b});
    defer writer_thread.join();

    var buf: [9]u8 = undefined;
    var off: usize = 0;
    while (off < buf.len) {
        const n = sockRead(pair.a, buf[off..].ptr, buf.len - off);
        if (n < 0) {
            // fatal error on test socket — should not happen
            @panic("sockRead returned error on non-blocking test socket");
        }
        if (n == 0) {
            // writer hasn't sent yet, should retry on EAGAIN internally
            continue;
        }
        off += @intCast(n);
    }
    try std.testing.expectEqualStrings("EAGAIN_OK", buf[0..]);
}

test "sendFrame/recvFrame on non-blocking socket" {
    const allocator = std.testing.allocator;
    const pair = try makeNonBlockingPair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 用线程发送避免 socketpair 缓冲区满导致的死锁
    const msg = "non-blocking frame test";
    const sender = try std.Thread.spawn(.{}, sendInThread, .{SendArgs{ .fd = pair.a, .data = msg }});
    defer sender.join();

    const received = try recvFrame(allocator, pair.b);
    defer allocator.free(received);
    try std.testing.expectEqualStrings(msg, received);
}

test "recvExact handles partial reads on non-blocking socket" {
    const pair = try makeNonBlockingPair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 写入 16 字节数据
    const data = "0123456789ABCDEF";
    _ = sockWrite(pair.b, data, data.len);

    // recvExact 在非阻塞 socket 上可能遇到部分读取（sockRead 返回 < buf.len），
    // 它必须循环直到读满。EAGAIN 重试在 sockRead 内部处理。
    var buf: [16]u8 = undefined;
    const n = try recvExact(pair.a, buf[0..]);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
}

test "socks5CheckAndReply on non-blocking socket" {
    const pair = try makeNonBlockingPair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    // 客户端线程发送 SOCKS5 认证+请求（hostname="nbself"）
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="nbself"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                6, 'n', 'b', 's', 'e', 'l', 'f',
                0x08, 0x49, // PORT = 2121
            };
            _ = sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_OK);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // 服务端在非阻塞 socket 上完成 SOCKS5 握手
    const accepted = try socks5CheckAndReply(pair.a, "nbself");
    try std.testing.expect(accepted);
}
