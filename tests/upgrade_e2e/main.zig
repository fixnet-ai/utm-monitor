//! Upgrade 端到端集成测试 — TCP loopback 上验证 upgrade_cmd 协议流程
//!
//! 验证场景：
//! 1. upgrade_cmd → 二进制流 → upload_result (exit_code=0)
//! 2. upgrade_cmd 包含正确的 target + file_size + sha256_hex
//! 3. 大二进制文件（256KB）流式传输 + SHA256 校验
//! 4. upgrade_cmd 编解码往返
//!
//! Host 模拟器：TCP 监听 → 接收 upgrade_cmd → 发送 upload_result
//! Guest 客户端：connect → 发送 upgrade_cmd + 二进制 → 接收 upload_result

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

/// Guest 模拟器：接收 upgrade_cmd → 流式接收二进制 → 验证 SHA256 → 响应 upload_result
fn guestUpgradeSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    done: *std.atomic.Value(bool),
    result_ok: *std.atomic.Value(bool),
) void {
    _ = io;
    defer done.store(true, .release);

    const cli_fd = common.sockAccept(listen_fd) catch return;
    defer {
        common.sockShutdown(cli_fd, 2);
        common.sockClose(cli_fd);
    }

    // 步骤 1: 接收 upgrade_cmd 帧
    const cmd_frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(cmd_frame);

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.upgrade_cmd)) return;

    const cmd = protocol.parseUpgradeCmd(cmd_frame[1..]) orelse return;

    // 步骤 2: 流式接收二进制数据
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(allocator);

    var rbuf: [65536]u8 = undefined;
    var remaining: usize = cmd.file_size;

    while (remaining > 0) {
        const to_read = @min(remaining, rbuf.len);
        const raw_n = common.sockRead(cli_fd, &rbuf, to_read);
        if (raw_n <= 0) break;
        const n: usize = @intCast(raw_n);
        received.appendSlice(allocator, rbuf[0..n]) catch return;
        remaining -= n;
    }

    // 步骤 3: 验证 SHA256
    var computed_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(received.items, &computed_hash, .{});

    // 将 hex 转为字节数组用于比较
    var hex_buf: [64]u8 = undefined;
    _ = bytesToHex(&computed_hash, &hex_buf);

    const hash_ok = std.mem.eql(u8, cmd.sha256_hex, &hex_buf);
    const exit_code: i32 = if (hash_ok) @as(i32, 0) else @as(i32, -1);

    // 步骤 4: 发送 upload_result 响应
    const resp_frame = protocol.buildUploadResult(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(resp_frame);
    tcp.sendFrame(cli_fd, resp_frame) catch return;

    if (hash_ok) result_ok.store(true, .release);
}

/// 字节数组转 hex 字符串
fn bytesToHex(src: []const u8, dst: []u8) []u8 {
    const hex_chars = "0123456789abcdef";
    for (src, 0..) |byte, i| {
        dst[i * 2] = hex_chars[byte >> 4];
        dst[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return dst[0 .. src.len * 2];
}

/// 计算 SHA256 hex
fn computeSha256Hex(allocator: std.mem.Allocator, data: []const u8) []const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const hex = bytesToHex(&hash, &hex_buf);
    return allocator.dupe(u8, hex) catch @panic("OOM");
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

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const fake_binary = "THIS_IS_A_FAKE_UTMM_BINARY_FOR_UPGRADE_TEST";
        const sha256_hex = computeSha256Hex(alloc, fake_binary);
        defer alloc.free(sha256_hex);

        const guest_thread = try std.Thread.spawn(.{}, guestUpgradeSimulator, .{
            io, alloc, listener.fd, &guest_done, &guest_ok,
        });

        // Host 端：连接 → 发送 upgrade_cmd → 流式发送二进制 → 接收 upload_result
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

        // 发送 upgrade_cmd 帧
        const cmd_frame = try protocol.buildUpgradeCmd(alloc, "ug-1", "aarch64-linux", @intCast(fake_binary.len), sha256_hex);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        // 流式发送二进制数据
        _ = common.sockWrite(fd, fake_binary.ptr, fake_binary.len);

        // 接收 upload_result 响应
        const resp_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(resp_frame);

        tc.expectTrue(resp_frame[0] == @intFromEnum(protocol.MsgType.upload_result), "响应类型 = upload_result");

        const result = protocol.parseUploadResult(resp_frame[1..]) orelse {
            tc.expect(false, "parseUploadResult 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "exit_code=0 表示成功");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器 SHA256 校验通过");
        tc.deinit();
    }

    // ── 场景 2: upgrade_cmd 包含正确的 target + file_size + sha256_hex ──
    {
        var tc = runner.case("upgrade: target + file_size + sha256");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const binary = "binary_with_target_x86_64_windows";
        const sha256_hex = computeSha256Hex(alloc, binary);
        defer alloc.free(sha256_hex);

        const guest_thread = try std.Thread.spawn(.{}, guestUpgradeSimulator, .{
            io, alloc, listener.fd, &guest_done, &guest_ok,
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

        // 使用 x86_64-windows 平台标识
        const cmd_frame = try protocol.buildUpgradeCmd(alloc, "ug-2", "x86_64-windows", @intCast(binary.len), sha256_hex);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        _ = common.sockWrite(fd, binary.ptr, binary.len);

        const resp_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(resp_frame);

        const result = protocol.parseUploadResult(resp_frame[1..]) orelse {
            tc.expect(false, "parseUploadResult 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "x86_64-windows target exit_code=0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest SHA256 校验通过");
        tc.deinit();
    }

    // ── 场景 3: 大二进制文件（256KB）流式传输 ──
    {
        var tc = runner.case("upgrade: 大二进制流式传输");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        // 生成 256KB 伪二进制
        var big_binary: [262144]u8 = undefined;
        for (&big_binary, 0..) |*b, i| {
            b.* = @truncate(i & 0xff);
        }
        const sha256_hex = computeSha256Hex(alloc, &big_binary);
        defer alloc.free(sha256_hex);

        const guest_thread = try std.Thread.spawn(.{}, guestUpgradeSimulator, .{
            io, alloc, listener.fd, &guest_done, &guest_ok,
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

        // 发送 upgrade_cmd 带完整 256KB 元数据
        const cmd_frame = try protocol.buildUpgradeCmd(alloc, "ug-3", "aarch64-macos", @intCast(big_binary.len), sha256_hex);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        // 流式发送 256KB
        var sent: usize = 0;
        var wbuf: [65536]u8 = undefined;
        while (sent < big_binary.len) {
            const chunk = @min(big_binary.len - sent, wbuf.len);
            @memcpy(wbuf[0..chunk], big_binary[sent..][0..chunk]);
            const wn = common.sockWrite(fd, &wbuf, chunk);
            sent += @intCast(wn);
        }
        tc.expectEqual(big_binary.len, sent, "发送完整的 256KB 二进制");

        // 接收 upload_result
        const resp_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(resp_frame);

        const result = protocol.parseUploadResult(resp_frame[1..]) orelse {
            tc.expect(false, "parseUploadResult 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "256KB exit_code=0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "256KB SHA256 校验通过");
        tc.deinit();
    }

    // ── 场景 4: upgrade_cmd 编解码往返 ──
    {
        var tc = runner.case("upgrade: upgrade_cmd 编解码");

        const sha256_hex = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6";
        const cmd_frame = try protocol.buildUpgradeCmd(alloc, "ug-cdc", "x86-linux", 1234567, sha256_hex);
        defer alloc.free(cmd_frame);

        // 验证帧类型
        tc.expectTrue(cmd_frame[0] == @intFromEnum(protocol.MsgType.upgrade_cmd), "帧类型 = upgrade_cmd");

        // 解析
        const parsed = protocol.parseUpgradeCmd(cmd_frame[1..]) orelse {
            tc.expect(false, "parseUpgradeCmd 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectStr("ug-cdc", parsed.cmd_id, "cmd_id 一致");
        tc.expectStr("x86-linux", parsed.target, "target 一致");
        tc.expectEqual(@as(u32, 1234567), parsed.file_size, "file_size 一致");
        tc.expectStr(sha256_hex, parsed.sha256_hex, "sha256_hex 一致");

        tc.deinit();
    }
}
