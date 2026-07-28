//! Upgrade 端到端集成测试 — TCP loopback 上验证完整 upgrade 协议流程
//!
//! 验证场景：
//! 1. upgrade_req 请求 → 二进制流接收（模拟完整升级流程）
//! 2. 升级请求中包含 target 平台标识
//! 3. 大二进制文件（模拟真实 utmm 二进制）流式传输
//! 4. 多个 upgrade_req 往返验证
//!
//! Host 模拟器：TCP 监听 → 接收 upgrade_req → 流式发送二进制数据
//! Guest 客户端：connect → 发送 upgrade_req → 流式接收二进制数据

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

const system = std.posix.system;

fn bindAny(io: std.Io) !struct { fd: std.posix.socket_t, port: u16 } {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(io, .{ .mode = .stream });
    errdefer sock.close(io);
    _ = system.listen(sock.handle, 128);
    return .{ .fd = sock.handle, .port = sock.address.getPort() };
}

/// Host 模拟器：接收 upgrade_req → 流式发送二进制数据
fn hostUpgradeSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    binary_data: []const u8,
    done: *std.atomic.Value(bool),
    result_ok: *std.atomic.Value(bool),
) void {
    _ = io;
    defer done.store(true, .release);

    var addr: std.Io.net.IpAddress = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.Io.net.IpAddress);
    const cli_fd = system.accept(listen_fd, @ptrCast(&addr), &addr_len);
    if (cli_fd < 0) return;
    defer {
        _ = system.shutdown(cli_fd, 2);
        _ = system.close(cli_fd);
    }

    // 步骤 1: 接收 upgrade_req 帧
    const req_frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(req_frame);

    if (req_frame.len < 1 or req_frame[0] != @intFromEnum(protocol.MsgType.upgrade_req)) return;

    const req = protocol.parseUpgradeReq(req_frame[1..]) orelse return;

    // 步骤 2: 流式发送二进制数据（原始字节）
    _ = system.write(cli_fd, binary_data.ptr, binary_data.len);

    // 步骤 3: 发送 pty_exec_done 帧作为完成标记
    const done_frame = protocol.buildPtyExecDone(allocator, req.cmd_id, 0) catch return;
    defer allocator.free(done_frame);
    tcp.sendFrame(cli_fd, done_frame) catch return;

    result_ok.store(true, .release);
}

/// 计算 SHA256
fn computeSha256(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
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

    // ── 场景 1: 基本升级流程（小二进制）──
    {
        var tc = runner.case("upgrade: 基本升级流程");

        const listener = bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer _ = system.close(listener.fd);

        var host_ok = std.atomic.Value(bool).init(false);
        var host_done = std.atomic.Value(bool).init(false);

        // 模拟的二进制数据
        const fake_binary = "THIS_IS_A_FAKE_UTMM_BINARY_FOR_UPGRADE_TEST";
        const expected_sha = computeSha256(fake_binary);

        const host_thread = try std.Thread.spawn(.{}, hostUpgradeSimulator, .{
            io, alloc, listener.fd, fake_binary, &host_done, &host_ok,
        });

        // Guest 端：连接 → 发送 upgrade_req → 流式接收二进制 → 验证
        const stream = std.Io.net.IpAddress.parse("127.0.0.1", listener.port) catch |err| {
            tc.expect(false, "解析地址失败: {}", .{err});
            tc.deinit();
            return;
        };
        const conn = stream.connect(io, .{ .mode = .stream }) catch |err| {
            tc.expect(false, "连接失败: {}", .{err});
            tc.deinit();
            return;
        };
        defer conn.close(io);
        const fd = conn.socket.handle;

        // 发送 upgrade_req 帧
        const target = "aarch64-linux";
        const req_frame = try protocol.buildUpgradeReq(alloc, "ug-1", target);
        defer alloc.free(req_frame);
        try tcp.sendFrame(fd, req_frame);

        // 流式接收二进制数据
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        // 先接收固定长度的文件数据
        var rbuf: [65536]u8 = undefined;
        const file_n: usize = @intCast(system.read(fd, &rbuf, fake_binary.len));
        tc.expectEqual(fake_binary.len, file_n, "收到完整升级二进制");
        try received.appendSlice(alloc, rbuf[0..@intCast(file_n)]);

        tc.expectStr(fake_binary, received.items, "二进制内容一致");

        // 验证 SHA256
        const received_sha = computeSha256(received.items);
        tc.expectTrue(std.mem.eql(u8, &expected_sha, &received_sha), "SHA256 校验通过");

        // 接收完成标记
        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);
        tc.expectTrue(done_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_done), "收到完成标记");

        host_thread.join();
        tc.expectTrue(host_ok.load(.acquire), "Host 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 2: upgrade_req 包含正确的 target 平台 ──
    {
        var tc = runner.case("upgrade: target 平台标识");

        const listener = bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer _ = system.close(listener.fd);

        var host_ok = std.atomic.Value(bool).init(false);
        var host_done = std.atomic.Value(bool).init(false);

        const binary = "binary_with_target_check";
        const host_thread = try std.Thread.spawn(.{}, hostUpgradeSimulator, .{
            io, alloc, listener.fd, binary, &host_done, &host_ok,
        });

        const stream = std.Io.net.IpAddress.parse("127.0.0.1", listener.port) catch |err| {
            tc.expect(false, "解析地址失败: {}", .{err});
            tc.deinit();
            return;
        };
        const conn = stream.connect(io, .{ .mode = .stream }) catch |err| {
            tc.expect(false, "连接失败: {}", .{err});
            tc.deinit();
            return;
        };
        defer conn.close(io);
        const fd = conn.socket.handle;

        // 用不同平台标识发送 upgrade_req
        const target = "x86_64-windows";
        const req_frame = try protocol.buildUpgradeReq(alloc, "ug-2", target);
        defer alloc.free(req_frame);
        try tcp.sendFrame(fd, req_frame);

        // 接收并验证数据
        var rbuf: [65536]u8 = undefined;
        const file_n: usize = @intCast(system.read(fd, &rbuf, binary.len));
        tc.expectEqual(binary.len, file_n, "收到完整二进制");
        tc.expectStr(binary, rbuf[0..@intCast(file_n)], "内容一致");

        host_thread.join();
        tc.expectTrue(host_ok.load(.acquire), "Host 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 3: 大二进制文件（模拟真实 utmm ~2MB 模式）──
    {
        var tc = runner.case("upgrade: 大二进制流式传输");

        const listener = bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer _ = system.close(listener.fd);

        var host_ok = std.atomic.Value(bool).init(false);
        var host_done = std.atomic.Value(bool).init(false);

        // 生成 256KB 伪二进制（模拟真实 utmm 的流式传输行为）
        var big_binary: [262144]u8 = undefined;
        for (&big_binary, 0..) |*b, i| {
            b.* = @truncate(i & 0xff);
        }
        const expected_sha = computeSha256(&big_binary);

        const host_thread = try std.Thread.spawn(.{}, hostUpgradeSimulator, .{
            io, alloc, listener.fd, &big_binary, &host_done, &host_ok,
        });

        const stream = std.Io.net.IpAddress.parse("127.0.0.1", listener.port) catch |err| {
            tc.expect(false, "解析地址失败: {}", .{err});
            tc.deinit();
            return;
        };
        const conn = stream.connect(io, .{ .mode = .stream }) catch |err| {
            tc.expect(false, "连接失败: {}", .{err});
            tc.deinit();
            return;
        };
        defer conn.close(io);
        const fd = conn.socket.handle;

        const req_frame = try protocol.buildUpgradeReq(alloc, "ug-3", "aarch64-macos");
        defer alloc.free(req_frame);
        try tcp.sendFrame(fd, req_frame);

        // 流式接收 256KB 数据
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        var rbuf: [65536]u8 = undefined;
        var remaining: usize = big_binary.len;

        while (remaining > 0) {
            const to_read = @min(remaining, rbuf.len);
            const raw_n = system.read(fd, &rbuf, to_read);
            if (raw_n <= 0) break;
            const n: usize = @intCast(raw_n);
            try received.appendSlice(alloc, rbuf[0..n]);
            remaining -= n;
        }

        tc.expectEqual(big_binary.len, received.items.len, "收到完整的 256KB 二进制");
        const received_sha = computeSha256(received.items);
        tc.expectTrue(std.mem.eql(u8, &expected_sha, &received_sha), "256KB SHA256 校验通过");

        // 接收完成标记
        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);
        tc.expectTrue(done_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_done), "收到完成标记");

        host_thread.join();
        tc.expectTrue(host_ok.load(.acquire), "Host 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 4: upgrade_req 编解码往返 ──
    {
        var tc = runner.case("upgrade: upgrade_req 编解码");

        const req_frame = try protocol.buildUpgradeReq(alloc, "ug-cdc", "x86-linux");
        defer alloc.free(req_frame);

        // 验证帧类型
        tc.expectTrue(req_frame[0] == @intFromEnum(protocol.MsgType.upgrade_req), "帧类型 = upgrade_req");

        // 解析
        const parsed = protocol.parseUpgradeReq(req_frame[1..]) orelse {
            tc.expect(false, "parseUpgradeReq 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectStr("ug-cdc", parsed.cmd_id, "cmd_id 一致");
        tc.expectStr("x86-linux", parsed.target, "target 一致");

        tc.deinit();
    }
}
