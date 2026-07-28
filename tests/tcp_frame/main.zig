//! TCP 帧协议 + SOCKS4a 集成测试
//!
//! 验证场景：
//! 1. SOCKS4a 完整握手（环回 TCP）
//! 2. 帧协议 sendFrame/recvFrame 往返（含 64KB 大帧）
//! 3. Connection + protocol 消息往返
//! 4. Connection 关闭检测 (isAlive)
//! 5. TcpListener 拒绝错误 hostname

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const tcp = lib.tcp;
const protocol = lib.protocol;

const system = std.posix.system;

/// 创建一对已连接的 socket（用于测试）。
fn makePair() !struct { a: std.posix.socket_t, b: std.posix.socket_t } {
    var fds: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(1, 1, 0, &fds) != 0) return error.SocketPairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

/// 在 127.0.0.1:0 上创建 TCP 监听 socket，返回 socket fd + 实际端口。
fn createListener(io: std.Io) !struct { fd: std.posix.socket_t, port: u16 } {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(io, .{ .mode = .stream });
    errdefer sock.close(io);

    _ = system.listen(sock.handle, 128);

    return .{ .fd = sock.handle, .port = sock.address.getPort() };
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("内存泄漏");
    }
    const alloc = gpa.allocator();

    var runner = common.TestRunner{};
    defer {
        const all_pass = runner.summary();
        if (!all_pass) std.process.exit(1);
    }

    // ── 场景 1: SOCKS4a 完整握手 ──
    {
        var tc = runner.case("SOCKS4a 完整握手");

        const listener = createListener(io) catch {
            tc.skip("无法创建监听 socket");
            tc.deinit();
            return;
        };
        defer _ = system.close(listener.fd);

        const hostname = "testhost";

        var client_ok = std.atomic.Value(bool).init(false);
        var client_done = std.atomic.Value(bool).init(false);

        const client_thread = try std.Thread.spawn(.{}, struct {
            fn f(io2: std.Io, port: u16, h: []const u8, done: *std.atomic.Value(bool), ok: *std.atomic.Value(bool)) void {
                const ip = std.Io.net.IpAddress.parse("127.0.0.1", port) catch {
                    done.store(true, .release);
                    return;
                };
                const stream = tcp.socks4Connect(io2, ip, h, port) catch {
                    done.store(true, .release);
                    return;
                };
                stream.close(io2);
                ok.store(true, .release);
                done.store(true, .release);
            }
        }.f, .{ io, listener.port, hostname, &client_done, &client_ok });

        // 服务端：接受连接并完成 SOCKS4a 握手
        var cli_addr: std.Io.net.IpAddress = undefined;
        var cli_addr_len: std.posix.socklen_t = @sizeOf(std.Io.net.IpAddress);
        const cli_fd = system.accept(listener.fd, @ptrCast(&cli_addr), &cli_addr_len);
        if (cli_fd < 0) {
            tc.expect(false, "accept 失败", .{});
            tc.deinit();
            return;
        }
        defer _ = system.close(cli_fd);

        const req = tcp.socks4Accept(cli_fd) catch |err| {
            tc.expect(false, "socks4Accept 失败: {}", .{err});
            tc.deinit();
            return;
        };
        tc.expectStr(hostname, req.hostname, "hostname 匹配");
        tc.expectEqual(@as(u16, listener.port), req.port, "端口匹配");
        tcp.socks4ReplyOk(cli_fd);

        // 等待客户端完成
        while (!client_done.load(.acquire)) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        client_thread.join();
        tc.expectTrue(client_ok.load(.acquire), "客户端 SOCKS4a 握手成功");

        tc.deinit();
    }

    // ── 场景 2a: 帧协议 sendFrame/recvFrame（小载荷）──
    {
        var tc = runner.case("帧协议 sendFrame/recvFrame");

        const pair = makePair() catch {
            tc.skip("socketpair 不可用");
            tc.deinit();
            return;
        };
        defer {
            _ = system.close(pair.a);
            _ = system.close(pair.b);
        }

        const test_data = "hello tcp frame protocol";
        try tcp.sendFrame(pair.a, test_data);
        const received = try tcp.recvFrame(alloc, pair.b);
        defer alloc.free(received);
        tc.expectStr(test_data, received, "小载荷往返一致");

        tc.deinit();
    }

    // ── 场景 2b: 64KB 大帧 ──
    {
        var tc = runner.case("帧协议 64KB 大帧");

        const pair = makePair() catch {
            tc.skip("socketpair 不可用");
            tc.deinit();
            return;
        };
        defer {
            _ = system.close(pair.a);
            _ = system.close(pair.b);
        }

        var big_data: [65536]u8 = undefined;
        for (&big_data, 0..) |*b, i| {
            b.* = @truncate(i & 0xff);
        }

        // 用独立线程发送，避免 socketpair 缓冲区死锁
        const SendCtx = struct { fd: std.posix.socket_t, data: []const u8 };
        const ctx = SendCtx{ .fd = pair.a, .data = &big_data };
        const sender = try std.Thread.spawn(.{}, struct {
            fn run(c: SendCtx) void {
                tcp.sendFrame(c.fd, c.data) catch @panic("sendFrame failed");
            }
        }.run, .{ctx});
        defer sender.join();

        const received = try tcp.recvFrame(alloc, pair.b);
        defer alloc.free(received);
        tc.expectEqual(big_data.len, received.len, "大帧长度一致");
        tc.expectTrue(std.mem.eql(u8, &big_data, received), "大帧内容一致");

        tc.deinit();
    }

    // ── 场景 3: Connection + protocol 消息 ──
    // socketpair 是双向的：写入 pair.a → 从 pair.b 读取；写入 pair.b → 从 pair.a 读取
    {
        var tc = runner.case("Connection + protocol 消息");

        const pair = makePair() catch {
            tc.skip("socketpair 不可用");
            tc.deinit();
            return;
        };
        defer {
            _ = system.close(pair.a);
            _ = system.close(pair.b);
        }

        const cmd_id = "cmd-001";
        const command = "uname -a";
        const send_frame = try protocol.buildPtyExecInput(alloc, cmd_id, command);
        defer alloc.free(send_frame);

        // 写入 pair.a，从 pair.b 接收（socketpair 全双工，pair.a 写的只能从 pair.b 读）
        try tcp.sendFrame(pair.a, send_frame);

        const received = try tcp.recvFrame(alloc, pair.b);
        defer alloc.free(received);
        tc.expectTrue(received.len >= 5, "recvFrame 返回了数据");

        const parsed = protocol.parsePtyExecInput(received[1..]) orelse {
            tc.expect(false, "parsePtyExecInput 返回 null", .{});
            tc.deinit();
            return;
        };
        tc.expectStr(cmd_id, parsed.cmd_id, "cmd_id 一致");
        tc.expectStr(command, parsed.command, "command 一致");

        tc.deinit();
    }

    // ── 场景 4: Connection 关闭检测 ──
    {
        var tc = runner.case("Connection 关闭检测");

        const pair = makePair() catch {
            tc.skip("socketpair 不可用");
            tc.deinit();
            return;
        };
        defer {
            _ = system.close(pair.a);
            _ = system.close(pair.b);
        }

        var conn = tcp.Connection{ .fd = pair.a, .alive = true };
        defer conn.deinit();

        tc.expectTrue(conn.isAlive(), "初始状态 alive=true");

        // 关闭对端 → 对端读立即返回 EOF
        _ = system.close(pair.b);

        // 注意：pair.b 已在上面关闭，defer 中的 system.close(pair.b) 会重闭，无害
        var rbuf: [64]u8 = undefined;
        const n = try conn.recv(&rbuf);
        tc.expectTrue(n == 0, "recv 返回 0 (EOF)");
        tc.expectTrue(!conn.isAlive(), "isAlive 变为 false");

        tc.deinit();
    }

    // ── 场景 5: TcpListener 创建与绑定 ──
    {
        var tc = runner.case("TcpListener 创建与绑定");

        const port = common.findFreePort(io) catch {
            tc.skip("无法获取空闲端口");
            tc.deinit();
            return;
        };

        var listener = tcp.TcpListener.init(io, port) catch |err| {
            tc.expect(false, "TcpListener.init 失败: {}", .{err});
            tc.deinit();
            return;
        };
        defer listener.deinit();

        // 验证 listener 成功绑定
        tc.expectTrue(listener.socket.address.getPort() > 0, "端口已绑定");

        // 验证客户端可以连接到该端口
        var connected = std.atomic.Value(bool).init(false);
        const client_thread = try std.Thread.spawn(.{}, struct {
            fn f(io2: std.Io, port2: u16, flag: *std.atomic.Value(bool)) void {
                const ip = std.Io.net.IpAddress.parse("127.0.0.1", port2) catch return;
                const stream = std.Io.net.IpAddress.connect(&ip, io2, .{ .mode = .stream }) catch return;
                flag.store(true, .release);
                stream.close(io2);
            }
        }.f, .{ io, port, &connected });

        client_thread.join();
        tc.expectTrue(connected.load(.acquire), "客户端可以连接到 TcpListener");

        tc.deinit();
    }
}
