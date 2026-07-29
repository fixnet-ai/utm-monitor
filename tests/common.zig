//! 测试基础设施 — 共享工具，供所有集成测试使用。
//!
//! 提供 TestRunner (统计), TestCase (断言), TempDir (临时目录),
//! findFreePort (动态端口), isWindows (平台检测),
//! 跨平台 socket I/O 辅助 (sockRead/sockWrite/sockClose 等)。

const std = @import("std");
const builtin = @import("builtin");
const system = std.posix.system;

// ═══════════════════════════════════════════════════════════════════════════
// 跨平台 Socket I/O 抽象
// ═══════════════════════════════════════════════════════════════════════════
//
// socket_t is platform-dependent: c_int on POSIX, *anyopaque on Windows.
// system.read/write/close operate on c_int fds (POSIX) but NOT on Windows
// sockets — Winsock2 requires send/recv/closesocket. These inline wrappers
// branch at comptime so there is zero runtime overhead.
//
// IMPORTANT: On Windows, Zig 0.16.0's Io.net APIs (listen/bind/accept) use AFD
// (Ancillary Function Driver) kernel handles, which are NOT compatible with
// Winsock2 recv/send. We MUST use raw Winsock2 socket creation + accept to get
// handles that work with ws2_recv/ws2_send.

const socket_t = std.posix.socket_t;

/// Write data to a socket. POSIX: write(), Windows: send().
pub inline fn sockWrite(fd: socket_t, buf: [*]const u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        return ws2_send(fd, buf, @intCast(len), 0);
    }
    return system.write(fd, buf, len);
}

/// Read data from a socket. POSIX: read(), Windows: recv().
pub inline fn sockRead(fd: socket_t, buf: [*]u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        return ws2_recv(fd, buf, @intCast(len), 0);
    }
    return system.read(fd, buf, len);
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
        ensureWinsock2();
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
    if (fd < 0) return error.AcceptFailed;
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
extern "ws2_32" fn socket(af: c_int, type: c_int, protocol: c_int) callconv(.winapi) std.posix.socket_t;
const ws2_socket = socket;
extern "ws2_32" fn bind(s: std.posix.socket_t, name: *const anyopaque, namelen: std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_bind = bind;
extern "ws2_32" fn connect(s: std.posix.socket_t, name: *const anyopaque, namelen: std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_connect = connect;
extern "ws2_32" fn getsockname(s: std.posix.socket_t, name: *anyopaque, namelen: *std.posix.socklen_t) callconv(.winapi) c_int;
const ws2_getsockname = getsockname;
extern "ws2_32" fn setsockopt(s: std.posix.socket_t, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_int) callconv(.winapi) c_int;
const ws2_setsockopt = setsockopt;
extern "ws2_32" fn htons(hostshort: u16) callconv(.winapi) u16;
const ws2_htons = htons;
extern "ws2_32" fn ntohs(netshort: u16) callconv(.winapi) u16;
const ws2_ntohs = ntohs;
extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) c_int;
const ws2_startup = WSAStartup;
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

/// Ensure Winsock2 is initialized (required for raw ws2_socket/ws2_recv etc.).
/// Zig 0.16.0 uses AFD kernel handles for its own I/O, NOT Winsock2, so we
/// must call WSAStartup ourselves. Safe to call multiple times.
var ws2_initialized = false;
fn ensureWinsock2() void {
    if (ws2_initialized) return;
    if (builtin.os.tag == .windows) {
        var wsdata: [400]u8 align(4) = [_]u8{0} ** 400;
        const rc = ws2_startup(0x0202, @ptrCast(&wsdata));
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

/// 在 127.0.0.1:0 上创建 TCP 监听 socket。返回 socket fd + 实际端口。
pub fn bindAny(io: std.Io) !struct { fd: socket_t, port: u16 } {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        const s = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return error.BindFailed;

        const reuse: c_int = 1;
        _ = ws2_setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        var bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = 0,
            .addr = 0x0100007f, // 127.0.0.1
        };
        const br = ws2_bind(s, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            _ = ws2_closesocket(s);
            return error.BindFailed;
        }

        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        _ = ws2_getsockname(s, @ptrCast(&bind_addr), &addr_len);
        const port = ws2_ntohs(bind_addr.port);

        _ = ws2_listen(s, 128);
        return .{ .fd = s, .port = port };
    }
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(io, .{ .mode = .stream });
    errdefer sock.close(io);
    _ = sockListen(sock.handle, 128);
    return .{ .fd = sock.handle, .port = sock.address.getPort() };
}

/// 创建一对已连接的 socket（用于测试）。
/// Windows: TCP loopback 替代 (std.c.socketpair 不存在)。
pub fn makePair() !struct { a: socket_t, b: socket_t } {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();

        const listener = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) return error.SocketPairFailed;

        const reuse: c_int = 1;
        _ = ws2_setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        var bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = 0,
            .addr = 0x0100007f, // 127.0.0.1
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
            .addr = 0x0100007f, // 127.0.0.1
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

/// 测试运行器。累积通过/失败/跳过计数，输出结构化结果。
pub const TestRunner = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    current_name: []const u8 = "",

    /// 开始一个命名测试用例。打印 "  RUN: <name>"。
    pub fn case(self: *TestRunner, name: []const u8) TestCase {
        self.current_name = name;
        std.debug.print("  RUN: {s}\n", .{name});
        return TestCase{ .runner = self };
    }

    /// 打印汇总并返回是否全部通过。
    pub fn summary(self: *TestRunner) bool {
        const total = self.pass + self.fail + self.skip;
        std.debug.print("\nResults: {d} passed, {d} failed, {d} skipped (total: {d})\n", .{ self.pass, self.fail, self.skip, total });
        return self.fail == 0;
    }
};

/// 单个测试用例作用域。defer deinit() 时自动记录通过/失败。
pub const TestCase = struct {
    runner: *TestRunner,
    failed: bool = false,
    skipped: bool = false,

    /// 断言条件为真。失败时记录消息。
    pub fn expect(self: *TestCase, ok: bool, comptime fmt: []const u8, args: anytype) void {
        if (!ok) {
            self.failed = true;
            std.debug.print("  FAIL: {s} — ", .{self.runner.current_name});
            std.debug.print(fmt, args);
            std.debug.print("\n", .{});
        }
    }

    /// 断言值为 true。
    pub fn expectTrue(self: *TestCase, actual: bool, comptime msg: []const u8) void {
        self.expect(actual, "{s} (expected true, got false)", .{msg});
    }

    /// 断言两个值相等。使用 == 操作符。
    pub fn expectEqual(self: *TestCase, expected: anytype, actual: @TypeOf(expected), comptime msg: []const u8) void {
        const ok = expected == actual;
        if (!ok) {
            self.failed = true;
            std.debug.print("  FAIL: {s} — {s}: expected {any}, got {any}\n", .{ self.runner.current_name, msg, expected, actual });
        }
    }

    /// 断言两个字符串相等。
    pub fn expectStr(self: *TestCase, expected: []const u8, actual: []const u8, comptime msg: []const u8) void {
        if (!std.mem.eql(u8, expected, actual)) {
            self.failed = true;
            std.debug.print("  FAIL: {s} — {s}: expected \"{s}\", got \"{s}\"\n", .{ self.runner.current_name, msg, expected, actual });
        }
    }

    /// 断言错误。
    pub fn expectError(self: *TestCase, expected_err: anyerror, actual: anyerror!void, comptime msg: []const u8) void {
        if (actual) {
            self.failed = true;
            std.debug.print("  FAIL: {s} — {s}: expected error.{s}, got success\n", .{ self.runner.current_name, msg, @errorName(expected_err) });
        } else |err| {
            if (err != expected_err) {
                self.failed = true;
                std.debug.print("  FAIL: {s} — {s}: expected error.{s}, got error.{s}\n", .{ self.runner.current_name, msg, @errorName(expected_err), @errorName(err) });
            }
        }
    }

    /// 标记测试为跳过（平台不支持等）。
    pub fn skip(self: *TestCase, comptime reason: []const u8) void {
        self.skipped = true;
        std.debug.print("  SKIP: {s} — {s}\n", .{ self.runner.current_name, reason });
    }

    /// defer deinit() 时调用：根据 failed/skipped 更新统计并打印结果。
    pub fn deinit(self: *TestCase) void {
        if (self.skipped) {
            self.runner.skip += 1;
        } else if (self.failed) {
            self.runner.fail += 1;
        } else {
            self.runner.pass += 1;
            std.debug.print("  PASS: {s}\n", .{self.runner.current_name});
        }
    }
};

/// 临时目录 — 创建在 /tmp (或 %TEMP%) 下，deinit 时自动清理。
pub const TempDir = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,

    /// 创建临时目录。prefix 用于标识（如 "utmm-test-"）。
    pub fn create(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8) !TempDir {
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        var hex: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}{x}", .{ std.mem.readInt(u64, &rand_bytes, .little), @as(u64, 0) }) catch unreachable;
        // 只用前 12 个 hex 字符
        const path = try std.fmt.allocPrint(allocator, "/tmp/{s}{s}", .{ prefix, hex[0..12] });
        errdefer allocator.free(path);
        try std.Io.Dir.cwd().createDir(io, path, .{ .permissions = @enumFromInt(0o755) });
        return TempDir{ .io = io, .allocator = allocator, .path = path };
    }

    /// 拼接路径。
    pub fn join(self: *TempDir, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, name });
    }

    /// 清理临时目录及其全部内容。
    pub fn deinit(self: *TempDir) void {
        // 先删除目录内文件
        self.deleteTree(self.path) catch {};
        self.allocator.free(self.path);
    }

    fn deleteTree(self: *TempDir, dir_path: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var iter = dir.iterate(self.io);
        while (try iter.next()) |entry| {
            const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer self.allocator.free(full);
            if (entry.kind == .directory) {
                try self.deleteTree(full);
            } else {
                dir.deleteFile(self.io, entry.name) catch {};
            }
        }
        std.Io.Dir.cwd().deleteDir(self.io, dir_path) catch {};
    }
};

/// 查找一个空闲 TCP 端口（绑定 :0 后读取实际端口号）。
pub fn findFreePort(io: std.Io) !u16 {
    if (builtin.os.tag == .windows) {
        ensureWinsock2();
        const s = ws2_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return error.BindFailed;

        var bind_addr = sockaddr_in{
            .family = AF_INET,
            .port = 0,
            .addr = 0x0100007f, // 127.0.0.1
        };
        const br = ws2_bind(s, @ptrCast(&bind_addr), @sizeOf(sockaddr_in));
        if (br != 0) {
            _ = ws2_closesocket(s);
            return error.BindFailed;
        }

        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_in);
        _ = ws2_getsockname(s, @ptrCast(&bind_addr), &addr_len);
        const port = ws2_ntohs(bind_addr.port);
        _ = ws2_closesocket(s);
        return port;
    }
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(io, .{ .mode = .stream });
    defer sock.close(io);
    return sock.address.getPort();
}

/// 是否 Windows 平台。
pub fn isWindows() bool {
    return builtin.os.tag == .windows;
}

/// 是否 macOS 平台。
pub fn isMacOS() bool {
    return builtin.os.tag == .macos;
}
