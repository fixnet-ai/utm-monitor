//! SOCKS4a 代理监听器 — 通用 TCP 连通层。
//!
//! Host 通过此模块向本地工具暴露 SOCKS4a 代理端口。外部工具（curl、浏览器、
//! SSH、git 等）配置代理后，可通过 Host 到达任何目标：
//!   - VM 网格中的 Guest（通过 GuestTable 解析 hostname）
//!   - 局域网中的其他机器
//!   - 互联网上的远程主机
//!
//! 与 tcp.zig 中内部使用的 SOCKS4a（Host→Guest 命令协议）不同，此模块提供
//! 标准的 SOCKS4a CONNECT 代理，对目标进行直连 TCP，不做 utmm 协议封装。
//!
//! 主机名解析优先级：GuestTable → /etc/hosts → 系统 DNS
//!
//! 安全性：代理仅绑定 127.0.0.1，不可从网络访问。

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;
const tcp = @import("tcp.zig");

// Socket constants (avoid std.c API churn across Zig versions)
const AF_INET = 2;
const SOCK_STREAM = 1;
const IPPROTO_TCP = 6;
const SO_REUSEADDR = 0x0004;
const SOL_SOCKET = 0xffff;

/// 主机名解析回调：ctx 由调用者提供（host.zig 传入 *GuestTable），
/// hostname 是要解析的目标主机名。
/// 返回 IP 字符串（由 ctx 管理生命周期，通常是 GuestTable 条目），
/// 或 null 表示未找到（调用者应回退到系统 DNS）。
pub const ResolveFn = *const fn (ctx: *anyopaque, hostname: []const u8) ?[]const u8;

/// SOCKS4a 代理主循环。
/// 绑定 localhost:port，accept 连接，每个连接 spawn 一个处理线程。
/// shutdown 为 true 时退出循环。
pub fn socksProxyRun(
    io: std.Io,
    port: u16,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
    shutdown: *std.atomic.Value(bool),
) void {
    // 绑定 localhost:port 并开始 accept 循环
    var listener = socksProxyBind(io, port) catch |err| {
        std.log.err("[socks-proxy] bind localhost:{d} failed: {}", .{ port, err });
        return;
    };
    defer socksProxyClose(&listener);

    std.log.info("[socks-proxy] SOCKS4a proxy listening on localhost:{d}", .{port});

    while (!shutdown.load(.acquire)) {
        const client_fd = socksProxyAccept(&listener, io) catch |err| {
            if (err == error.WouldBlock) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                continue;
            }
            std.log.err("[socks-proxy] accept error: {}", .{err});
            std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
            continue;
        };

        // 每个连接在独立线程中处理（detached，自清理）
        const thread = std.Thread.spawn(.{}, socksProxyHandleOne, .{
            io, client_fd, resolve_fn, resolve_ctx,
        }) catch {
            std.log.err("[socks-proxy] thread spawn failed", .{});
            tcp.sockClose(client_fd);
            continue;
        };
        thread.detach();
    }

    std.log.info("[socks-proxy] listener stopped", .{});
}

/// 处理一个 SOCKS4a 代理连接：解析请求 → 解析主机名 → 连接目标 → 中继。
/// 始终关闭 client_fd（在返回前由 socks4Relay 或错误路径关闭）。
fn socksProxyHandleOne(
    io: std.Io,
    client_fd: tcp.socket_t,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 1. 解析 SOCKS4a CONNECT 请求
    const request = tcp.socks4Accept(client_fd, gpa) catch {
        tcp.socks4ReplyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };
    defer gpa.free(request.hostname);

    // 2. 解析目标主机名
    const target_ip = resolveTargetIp(io, gpa, resolve_fn, resolve_ctx, request.hostname) catch {
        tcp.socks4ReplyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };
    defer gpa.free(target_ip);

    // 3. 直连 TCP 到目标 IP:port
    const target_fd = directConnect(io, target_ip, request.port) catch |err| {
        std.log.err("[socks-proxy] connect to {s}:{d} ({s}) failed: {}", .{
            request.hostname, request.port, target_ip, err,
        });
        tcp.socks4ReplyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };

    // 4. 发送 SOCKS4a OK 响应
    tcp.socks4ReplyOk(client_fd);

    // 5. 双向中继
    std.log.debug("[socks-proxy] relay: client ↔ {s}:{d} ({s})", .{
        request.hostname, request.port, target_ip,
    });
    tcp.socks4Relay(client_fd, target_fd);

    // socks4Relay 返回后关闭两端（任一侧关闭即退出）
    tcp.sockClose(target_fd);
    tcp.sockClose(client_fd);
}

/// 解析目标主机名：GuestTable → /etc/hosts → DNS。
fn resolveTargetIp(
    io: std.Io,
    gpa: std.mem.Allocator,
    resolve_fn: ResolveFn,
    resolve_ctx: *anyopaque,
    hostname: []const u8,
) ![]const u8 {
    // 已经是 IP 地址则直接返回
    if (std.Io.net.IpAddress.parse(hostname, 0) catch null) |_| {
        return gpa.dupe(u8, hostname);
    }

    // 优先：GuestTable（mesh VM 实时 IP）
    if (resolve_fn(resolve_ctx, hostname)) |ip| {
        return gpa.dupe(u8, ip);
    }

    // 回退：系统解析器（/etc/hosts → DNS）
    const resolved = std.Io.net.IpAddress.resolve(io, hostname, 0) catch |err| {
        std.log.debug("[socks-proxy] resolve({s}) failed: {}", .{ hostname, err });
        return error.HostnameResolutionFailed;
    };
    return switch (resolved) {
        .ip4 => |a| std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
        .ip6 => |a| std.fmt.allocPrint(gpa, "{}", .{a}), // IPv6: 使用默认格式
    };
}

/// 直连 TCP 到目标 IP:port，返回 socket fd。
fn directConnect(io: std.Io, ip: []const u8, port: u16) !tcp.socket_t {
    const addr = std.Io.net.IpAddress.parse(ip, port) catch |err| {
        std.log.err("[socks-proxy] parse IP '{s}' failed: {}", .{ ip, err });
        return error.ConnectFailed;
    };

    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        return err;
    };

    const fd = stream.socket.handle;
    // 不关闭 stream — fd 所有权转移给调用者
    return fd;
}

// ═══════════════════════════════════════════════════════════════════════════
// 平台抽象的 TCP Listener（仅绑定 127.0.0.1）
// ═══════════════════════════════════════════════════════════════════════════

const SocksProxyListener = struct {
    server: ?std.Io.net.Server = null,
    io: std.Io,
    listener_fd: tcp.socket_t = undefined,

    fn deinit(self: *SocksProxyListener) void {
        if (builtin.os.tag == .windows) {
            tcp.sockClose(self.listener_fd);
        } else {
            if (self.server) |*s| s.deinit(self.io);
        }
    }
};

fn socksProxyBind(io: std.Io, port: u16) !SocksProxyListener {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch |err| {
        std.log.err("[socks-proxy] bind addr parse failed: {}", .{err});
        return error.BindFailed;
    };

    if (builtin.os.tag == .windows) {
        // Windows：原始 Winsock2 socket（与 tcp.TcpListener 相同的模式）
        const s = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) {
            std.log.err("[socks-proxy] ws2_socket failed: {}", .{ws2_getLastError()});
            return error.BindFailed;
        }

        const reuse: c_int = 1;
        _ = ws2_setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        const bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = ws2_htons(port),
            .addr = ws2_htonl(0x7F000001), // 127.0.0.1 in network byte order
        };
        const br = ws2_bind(s, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            std.log.err("[socks-proxy] ws2_bind localhost:{d} failed: {}", .{ port, ws2_getLastError() });
            _ = ws2_closesocket(s);
            return error.BindFailed;
        }

        if (ws2_listen(s, 32) != 0) {
            std.log.err("[socks-proxy] ws2_listen failed: {}", .{ws2_getLastError()});
            _ = ws2_closesocket(s);
            return error.BindFailed;
        }

        return SocksProxyListener{ .io = io, .listener_fd = s };
    }

    // POSIX：使用 std.Io.net.Server
    const server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 32 }) catch |err| {
        std.log.err("[socks-proxy] listen localhost:{d} failed: {}", .{ port, err });
        return error.BindFailed;
    };

    return SocksProxyListener{ .io = io, .server = server };
}

fn socksProxyAccept(listener: *SocksProxyListener, io: std.Io) !tcp.socket_t {
    if (builtin.os.tag == .windows) {
        // Windows：原始 Winsock2 accept
        const fd = ws2_accept(listener.listener_fd, null, null);
        if (fd == INVALID_SOCKET) {
            const err = ws2_getLastError();
            if (err == WSAEWOULDBLOCK) return error.WouldBlock;
            std.log.err("[socks-proxy] ws2_accept failed: {}", .{err});
            return error.AcceptFailed;
        }
        return fd;
    }

    // POSIX：Server.accept
    const conn = listener.server.?.accept(io) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        return err;
    };
    return conn.socket.handle;
}

fn socksProxyClose(listener: *SocksProxyListener) void {
    listener.deinit();
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows Winsock2 函数声明
// ═══════════════════════════════════════════════════════════════════════════

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = [_]u8{0} ** 8,
};

const INVALID_SOCKET: std.posix.socket_t = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const WSAEWOULDBLOCK: c_int = 10035;

extern "ws2_32" fn ws2_socket(af: c_int, type_: c_int, protocol: c_int) callconv(.winapi) std.posix.socket_t;
extern "ws2_32" fn ws2_bind(s: std.posix.socket_t, name: *const anyopaque, namelen: std.posix.socklen_t) callconv(.winapi) c_int;
extern "ws2_32" fn ws2_listen(s: std.posix.socket_t, backlog: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn ws2_accept(s: std.posix.socket_t, addr: ?*anyopaque, addrlen: ?*std.posix.socklen_t) callconv(.winapi) std.posix.socket_t;
extern "ws2_32" fn ws2_setsockopt(s: std.posix.socket_t, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn ws2_closesocket(s: std.posix.socket_t) callconv(.winapi) c_int;
extern "ws2_32" fn ws2_htons(hostshort: u16) callconv(.winapi) u16;
extern "ws2_32" fn ws2_htonl(hostlong: u32) callconv(.winapi) u32;
extern "ws2_32" fn ws2_getLastError() callconv(.winapi) c_int;
extern "ws2_32" fn ws2_getsockname(s: std.posix.socket_t, name: *anyopaque, namelen: *std.posix.socklen_t) callconv(.winapi) c_int;
