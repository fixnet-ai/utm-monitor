//! TCP transport layer: raw socket I/O, listen/accept, connect, connection limits.
//!
//! Pure transport — no frame protocol, no SOCKS5. Those live in:
//!   protocol.zig  — frame protocol (sendFrame/recvFrame) + Connection
//!   socks5.zig    — SOCKS5 protocol (parse/reply/connect/forward/relay)

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;
const dpipe = @import("dpipe.zig");

// ── POSIX externs for non-blocking connect + poll timeout ──
const posix_connect = @extern(*const fn (c_int, *const anyopaque, std.posix.socklen_t) callconv(.c) c_int, .{ .name = "connect" });
const posix_fcntl = @extern(*const fn (c_int, c_int, c_int) callconv(.c) c_int, .{ .name = "fcntl" });
const posix_poll = @extern(*const fn ([*]std.posix.pollfd, std.posix.nfds_t, c_int) callconv(.c) c_int, .{ .name = "poll" });
const posix_getsockopt = @extern(*const fn (c_int, c_int, c_int, *anyopaque, *std.posix.socklen_t) callconv(.c) c_int, .{ .name = "getsockopt" });
const posix_sendto = @extern(*const fn (c_int, *const anyopaque, usize, c_int, *const anyopaque, std.posix.socklen_t) callconv(.c) isize, .{ .name = "sendto" });
const posix_recvfrom = @extern(*const fn (c_int, *anyopaque, usize, c_int, *anyopaque, *std.posix.socklen_t) callconv(.c) isize, .{ .name = "recvfrom" });

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 0x0004;
const EINPROGRESS = 36;
const EALREADY = 37;
const EISCONN = 56;

// ═══════════════════════════════════════════════════════════════════════════
// Platform Socket Abstraction
// ═══════════════════════════════════════════════════════════════════════════

pub const socket_t = std.posix.socket_t;

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
/// EINTR (interrupted by signal).
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

// ── Winsock2 externs (ws2_32 linked by build.zig when target is Windows) ──
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
extern "ws2_32" fn select(nfds: c_int, readfds: ?*fd_set, writefds: ?*fd_set, exceptfds: ?*fd_set, timeout: ?*timeval) callconv(.winapi) c_int;
const ws2_select = select;
extern "ws2_32" fn getsockopt(s: std.posix.socket_t, level: c_int, optname: c_int, optval: *anyopaque, optlen: *c_int) callconv(.winapi) c_int;
const ws2_getsockopt = getsockopt;
extern "ws2_32" fn sendto(s: std.posix.socket_t, buf: [*]const u8, len: c_int, flags: c_int, to: *const anyopaque, tolen: c_int) callconv(.winapi) c_int;
const ws2_sendto = sendto;
extern "ws2_32" fn recvfrom(s: std.posix.socket_t, buf: [*]u8, len: c_int, flags: c_int, from: *anyopaque, fromlen: *c_int) callconv(.winapi) c_int;
const ws2_recvfrom = recvfrom;

var ws2_initialized = false;
fn ensureWinsock2() void {
    if (ws2_initialized) return;
    if (builtin.os.tag == .windows) {
        var wsdata: [400]u8 align(4) = [_]u8{0} ** 400;
        const rc = ws2_startup(0x0202, @ptrCast(&wsdata)); // request Winsock 2.2
        if (rc == 0) {
            ws2_initialized = true;
        }
    }
}

const AF_INET = 2;
const SOCK_STREAM = 1;
const SOCK_DGRAM = 2;
const IPPROTO_TCP = 6;
const IPPROTO_UDP = 17;
const SO_REUSEADDR = 0x0004;
const SO_ERROR = 0x1007;
const SOL_SOCKET = 0xffff;
const INVALID_SOCKET: std.posix.socket_t = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const timeval = extern struct {
    tv_sec: c_int,
    tv_usec: c_int,
};

const FD_SETSIZE = 64;
const fd_set = extern struct {
    fd_count: u32,
    fd_array: [FD_SETSIZE]std.posix.socket_t,
};

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
        ensureWinsock2();

        const listener = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) return error.SocketPairFailed;

        const reuse: c_int = 1;
        _ = ws2_setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        var bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = 0, // OS assigns port
            .addr = 0x0100007f, // 127.0.0.1 in network byte order
        };
        const br = ws2_bind(listener, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        _ = ws2_getsockname(listener, @ptrCast(&bind_addr), &addr_len);
        const port = ws2_ntohs(bind_addr.port);

        _ = ws2_listen(listener, 1);

        const client = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (client == INVALID_SOCKET) {
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        var conn_addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(port),
            .addr = 0x0100007f,
        };
        const cr = ws2_connect(client, @ptrCast(&conn_addr), @sizeOf(sockaddr_in));
        if (cr != 0) {
            _ = ws2_closesocket(client);
            _ = ws2_closesocket(listener);
            return error.SocketPairFailed;
        }

        const server = try sockAccept(listener);
        _ = ws2_closesocket(listener);

        return .{ .a = client, .b = server };
    }
    var fds: [2]socket_t = undefined;
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

/// Set socket to non-blocking mode, for testing EAGAIN retry paths.
/// POSIX: fcntl(F_SETFL, O_NONBLOCK). Windows: ioctlsocket(FIONBIO).
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

/// Create a pair of non-blocking connected sockets for EAGAIN/WouldBlock tests.
pub fn makeNonBlockingPair() !struct { a: socket_t, b: socket_t } {
    const pair = try makePair();
    makeNonBlocking(pair.a);
    makeNonBlocking(pair.b);
    return .{ .a = pair.a, .b = pair.b };
}

const FIONBIO: c_int = @bitCast(@as(std.os.windows.ULONG, 0x8004667e));
extern "ws2_32" fn ioctlsocket(s: std.posix.socket_t, cmd: c_int, argp: *std.os.windows.ULONG) callconv(.winapi) c_int;
const ws2_ioctlsocket = ioctlsocket;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Default TCP connect timeout (ms).
pub const TCP_CONNECT_TIMEOUT_MS = 2000;

/// Max hostname length per connection.
pub const MAX_HOSTNAME: usize = 256;

/// Connection limit counter. Accept loops use atomic ops to control concurrency.
pub const ConnLimit = struct {
    count: std.atomic.Value(u32),
    max: u32,

    pub fn init(max: u32) ConnLimit {
        return .{ .count = std.atomic.Value(u32).init(0), .max = max };
    }

    /// Try to acquire a connection slot. Returns true on success, false at limit.
    pub fn tryAcquire(self: *ConnLimit) bool {
        const c = self.count.fetchAdd(1, .monotonic);
        if (c >= self.max) {
            _ = self.count.fetchSub(1, .monotonic);
            return false;
        }
        return true;
    }

    /// Release a connection slot.
    pub fn release(self: *ConnLimit) void {
        _ = self.count.fetchSub(1, .monotonic);
    }
};

/// Default max concurrent connections.
pub const DEFAULT_MAX_CONNS: u32 = 128;

// ═══════════════════════════════════════════════════════════════════════════
// TCP Connect with Timeout
// ═══════════════════════════════════════════════════════════════════════════

const SockAddr = union(enum) {
    in4: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,
};

fn ipToSockAddr(addr: std.Io.net.IpAddress) SockAddr {
    return switch (addr) {
        .ip4 => |ip4| .{ .in4 = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = std.mem.readInt(u32, &ip4.bytes, .little),
            .zero = [_]u8{0} ** 8,
        } },
        .ip6 => |ip6| .{ .in6 = .{
            .family = std.posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, ip6.port),
            .flowinfo = ip6.flow,
            .addr = ip6.bytes,
            .scope_id = ip6.interface.index,
        } },
    };
}

/// TCP connect with timeout. Uses non-blocking connect + poll/select.
pub fn connectTcp(io2: std.Io, addr: *const std.Io.net.IpAddress, timeout_ms: u32) !std.Io.net.Stream {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        return connectTcpWindows(addr, timeout_ms);
    }
    return connectTcpPosix(io2, addr, timeout_ms);
}

fn connectTcpPosix(io2: std.Io, addr: *const std.Io.net.IpAddress, timeout_ms: u32) !std.Io.net.Stream {
    _ = io2;
    const domain: u32 = switch (addr.*) {
        .ip4 => @as(u32, @intCast(std.posix.AF.INET)),
        .ip6 => @as(u32, @intCast(std.posix.AF.INET6)),
    };

    const fd = system.socket(domain, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ConnectFailed;
    errdefer sockClose(fd);

    const old_flags = posix_fcntl(@intCast(fd), F_GETFL, 0);
    if (old_flags < 0) return error.ConnectFailed;
    _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags | O_NONBLOCK);

    const cr: isize = switch (addr.*) {
        .ip4 => |ip4| blk: {
            const sa = std.posix.sockaddr.in{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = std.mem.readInt(u32, &ip4.bytes, .little),
                .zero = [_]u8{0} ** 8,
            };
            break :blk posix_connect(@intCast(fd), @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
        },
        .ip6 => |ip6| blk: {
            const sa = std.posix.sockaddr.in6{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            break :blk posix_connect(@intCast(fd), @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in6));
        },
    };

    if (cr < 0) {
        const e = std.posix.errno(cr);
        if (e != .INPROGRESS and e != .ALREADY) {
            _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);
            return error.ConnectFailed;
        }
    }

    var pfd: [1]std.posix.pollfd = .{.{ .fd = @intCast(fd), .events = std.posix.POLL.OUT, .revents = 0 }};
    const poll_ret = posix_poll(&pfd, 1, @intCast(timeout_ms));
    if (poll_ret < 0) {
        _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);
        return error.ConnectFailed;
    }
    if (poll_ret == 0) {
        _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);
        return error.ConnectTimeout;
    }

    var so_err: c_int = 0;
    var so_err_len: std.posix.socklen_t = @sizeOf(c_int);
    if (posix_getsockopt(@intCast(fd), SOL_SOCKET, SO_ERROR, @ptrCast(&so_err), &so_err_len) < 0) {
        _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);
        return error.ConnectFailed;
    }
    if (so_err != 0) {
        _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);
        return error.ConnectFailed;
    }

    _ = posix_fcntl(@intCast(fd), F_SETFL, old_flags);

    return std.Io.net.Stream{ .socket = .{ .handle = fd, .address = addr.* } };
}

fn connectTcpWindows(addr: *const std.Io.net.IpAddress, timeout_ms: u32) !std.Io.net.Stream {
    const domain: u16 = switch (addr.*) {
        .ip4 => AF_INET,
        .ip6 => 23, // AF_INET6
    };

    const fd = ws2_socket(domain, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET) return error.ConnectFailed;
    errdefer _ = ws2_closesocket(fd);

    var mode: std.os.windows.ULONG = 1;
    _ = ws2_ioctlsocket(fd, FIONBIO, &mode);

    const sa = ipToSockAddr(addr.*);
    const cr: c_int = switch (sa) {
        .in4 => |*v4| ws2_connect(fd, @ptrCast(v4), @sizeOf(sockaddr_in)),
        .in6 => |*v6| ws2_connect(fd, @ptrCast(v6), @sizeOf(std.posix.sockaddr.in6)),
    };
    if (cr != 0) {
        if (ws2_getLastError() != 10035) { // WSAEWOULDBLOCK
            return error.ConnectFailed;
        }
    }

    var tv: timeval = .{
        .tv_sec = @intCast(timeout_ms / 1000),
        .tv_usec = @intCast((timeout_ms % 1000) * 1000),
    };
    var wfds: fd_set = .{ .fd_count = 0, .fd_array = undefined };
    wfds.fd_array[0] = fd;
    wfds.fd_count = 1;

    const sel_ret = ws2_select(0, null, &wfds, null, &tv);
    if (sel_ret == 0) {
        _ = ws2_closesocket(fd);
        return error.ConnectTimeout;
    }
    if (sel_ret < 0) {
        return error.ConnectFailed;
    }

    var so_err: c_int = 0;
    var so_err_len: c_int = @sizeOf(c_int);
    if (ws2_getsockopt(fd, SOL_SOCKET, SO_ERROR, @ptrCast(&so_err), &so_err_len) != 0) {
        return error.ConnectFailed;
    }
    if (so_err != 0) {
        _ = ws2_closesocket(fd);
        return error.ConnectFailed;
    }

    mode = 0;
    _ = ws2_ioctlsocket(fd, FIONBIO, &mode);

    return std.Io.net.Stream{ .socket = .{ .handle = fd, .address = addr.* } };
}

/// Connect to 127.0.0.1:port, returning a socket fd compatible with sockAccept.
/// Windows: uses Winsock2 raw socket (compatible with ws2_accept).
/// POSIX: uses system.socket + system.connect (compatible with system.accept).
pub fn sockConnectLocalhost(port: u16) !socket_t {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        const fd = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd == INVALID_SOCKET) return error.ConnectFailed;
        var addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(port),
            .addr = 0x0100007f, // 127.0.0.1 in network byte order
        };
        const rc = ws2_connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_in));
        if (rc != 0) {
            _ = ws2_closesocket(fd);
            return error.ConnectFailed;
        }
        return fd;
    }
    const fd = system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ConnectFailed;
    errdefer _ = system.close(fd);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0x0100007f,
        .zero = [_]u8{0} ** 8,
    };
    const rc = system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (rc < 0) return error.ConnectFailed;
    return fd;
}

// ═══════════════════════════════════════════════════════════════════════════
// UDP Transport — create, send, receive
// ═══════════════════════════════════════════════════════════════════════════

/// UDP destination address (IPv4 only).
pub const UdpAddr = struct {
    ip: [4]u8,
    port: u16,
};

/// Create a UDP socket bound to a random port (0.0.0.0:0).
/// Returns the socket fd. Use getBoundPort() to retrieve the assigned port.
pub fn createUdpSocket() !socket_t {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        const s = ws2_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) return error.SocketCreateFailed;
        var addr = sockaddr_in{
            .family = AF_INET,
            .port = 0,
            .addr = 0,
        };
        const br = ws2_bind(s, @ptrCast(&addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            _ = ws2_closesocket(s);
            return error.BindFailed;
        }
        return s;
    }
    const s = system.socket(std.posix.AF.INET, SOCK_DGRAM, 0);
    if (s < 0) return error.SocketCreateFailed;
    errdefer _ = system.close(s);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = 0,
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };
    const addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (system.bind(s, @ptrCast(&addr), addr_len) < 0) return error.BindFailed;
    return s;
}

/// Get the bound port of a socket (TCP or UDP).
pub fn getBoundPort(fd: socket_t) !u16 {
    if (builtin.os.tag == .windows) {
        var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        if (ws2_getsockname(fd, @ptrCast(&addr), &addr_len) != 0) return error.GetSockNameFailed;
        return ws2_ntohs(addr.port);
    }
    var addr: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in);
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (system.getsockname(fd, @ptrCast(&addr), &addr_len) < 0) return error.GetSockNameFailed;
    return std.mem.bigToNative(u16, addr.port);
}

/// Send raw bytes to a UDP destination address.
pub fn sendUdpTo(fd: socket_t, data: []const u8, to: UdpAddr) !void {
    if (builtin.os.tag == .windows) {
        var addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(to.port),
            .addr = std.mem.readInt(u32, &to.ip, .big),
        };
        const n = ws2_sendto(fd, data.ptr, @intCast(data.len), 0, @ptrCast(&addr), @sizeOf(sockaddr_in));
        if (n < 0) return error.SendFailed;
        return;
    }
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, to.port),
        .addr = std.mem.readInt(u32, &to.ip, .big),
        .zero = [_]u8{0} ** 8,
    };
    const sw = posix_sendto(@intCast(fd), data.ptr, data.len, 0, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (sw < 0) return error.SendFailed;
    if (@as(usize, @intCast(sw)) != data.len) return error.SendFailed;
}

/// Receive raw bytes from UDP, returning data length and source address.
/// Returns { n: bytes_received, from: source_address }.
pub fn recvUdpFrom(fd: socket_t, buf: []u8) !struct { n: usize, from: UdpAddr } {
    if (builtin.os.tag == .windows) {
        var from: sockaddr_in = std.mem.zeroes(sockaddr_in);
        var from_len: c_int = @sizeOf(sockaddr_in);
        const n = ws2_recvfrom(fd, buf.ptr, @intCast(buf.len), 0, @ptrCast(&from), &from_len);
        if (n < 0) return error.RecvFailed;
        const ip_bytes: [4]u8 = @bitCast(from.addr);
        return .{
            .n = @intCast(n),
            .from = .{ .ip = @bitCast(ip_bytes), .port = ws2_ntohs(from.port) },
        };
    }
    var from: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in);
    var from_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    const rn = posix_recvfrom(@intCast(fd), buf.ptr, buf.len, 0, @ptrCast(&from), &from_len);
    if (rn < 0) return error.RecvFailed;
    const n: usize = @intCast(rn);
    const ip_bytes: [4]u8 = @bitCast(from.addr);
    return .{
        .n = n,
        .from = .{ .ip = @bitCast(ip_bytes), .port = std.mem.bigToNative(u16, from.port) },
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TCP Accept With Timeout — for SOCKS5 BIND
// ═══════════════════════════════════════════════════════════════════════════

/// Accept a TCP connection with timeout (ms). For SOCKS5 BIND.
/// Returns accepted fd and the peer's address.
/// On timeout, returns error.WouldBlock.
pub fn sockAcceptTimeout(listen_fd: socket_t, timeout_ms: u32) !struct { fd: socket_t, addr: UdpAddr } {
    if (builtin.os.tag == .windows) {
        var tv: timeval = .{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        var rfds: fd_set = .{ .fd_count = 0, .fd_array = [_]std.posix.socket_t{0} ** FD_SETSIZE };
        rfds.fd_array[0] = listen_fd;
        rfds.fd_count = 1;
        const sel_ret = ws2_select(0, &rfds, null, null, &tv);
        if (sel_ret == 0) return error.WouldBlock;
        if (sel_ret < 0) return error.AcceptFailed;

        var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        const raw = ws2_accept(listen_fd, @ptrCast(&addr), &addr_len);
        if (raw == INVALID_SOCKET) return error.AcceptFailed;
        const ip_bytes: [4]u8 = @bitCast(addr.addr);
        return .{
            .fd = raw,
            .addr = .{ .ip = @bitCast(ip_bytes), .port = ws2_ntohs(addr.port) },
        };
    }
    // POSIX: use poll
    var pfd: [1]std.posix.pollfd = .{.{ .fd = @intCast(listen_fd), .events = std.posix.POLL.IN, .revents = 0 }};
    const poll_ret = posix_poll(&pfd, 1, @intCast(timeout_ms));
    if (poll_ret < 0) return error.AcceptFailed;
    if (poll_ret == 0) return error.WouldBlock;

    var addr: std.Io.net.IpAddress = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.Io.net.IpAddress);
    const client_fd = system.accept(listen_fd, @ptrCast(&addr), &addr_len);
    if (client_fd < 0) return error.AcceptFailed;

    const peer_ip: [4]u8 = switch (addr) {
        .ip4 => |ip4| ip4.bytes,
        .ip6 => return error.AddressTypeNotSupported,
    };
    const peer_port: u16 = switch (addr) {
        .ip4 => |ip4| ip4.port,
        .ip6 => return error.AddressTypeNotSupported,
    };
    return .{
        .fd = client_fd,
        .addr = .{ .ip = peer_ip, .port = peer_port },
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// DuplexPipe Adapter — wraps raw socket fd as dpipe.DuplexPipe
// ═══════════════════════════════════════════════════════════════════════════

const TcpPipeCtx = struct {
    fd: socket_t,
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

/// Wrap a socket fd as dpipe.DuplexPipe (raw byte stream, no frame protocol).
/// close() closes the socket and frees ctx memory.
pub fn duplexPipe(fd: socket_t, allocator: std.mem.Allocator) !dpipe.DuplexPipe {
    const ctx = try allocator.create(TcpPipeCtx);
    ctx.* = .{ .fd = fd, .allocator = allocator };
    return dpipe.DuplexPipe{ .ctx = ctx, .vtable = &tcp_pipe_vtable };
}

// ═══════════════════════════════════════════════════════════════════════════
// TCP Listener
// ═══════════════════════════════════════════════════════════════════════════

/// TCP listener — bind port and accept connections.
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

        if (builtin.os.tag == .windows) {
            ensureWinsock2();
            const s = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (s == INVALID_SOCKET) {
                std.log.err("[tcp] ws2_socket failed: WSAGetLastError={d}", .{ws2_getLastError()});
                return error.BindFailed;
            }

            const reuse: c_int = 1;
            _ = ws2_setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

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

        const server = addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = 128,
            .mode = .stream,
        }) catch |err| {
            std.log.err("[tcp] TCP listen :{d} failed: {}", .{ port, err });
            return error.BindFailed;
        };

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

    /// Accept a TCP connection, returning raw socket fd.
    /// SOCKS5 handshake and dispatch are handled by the caller (guest.zig / host.zig).
    pub fn acceptRaw(self: *TcpListener) !socket_t {
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
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "sockRead retries on EAGAIN (non-blocking socket, delayed write)" {
    const pair = try makeNonBlockingPair();
    defer {
        sockClose(pair.a);
        sockClose(pair.b);
    }

    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: socket_t) void {
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
            @panic("sockRead returned error on non-blocking test socket");
        }
        if (n == 0) {
            continue;
        }
        off += @intCast(n);
    }
    try std.testing.expectEqualStrings("EAGAIN_OK", buf[0..]);
}
