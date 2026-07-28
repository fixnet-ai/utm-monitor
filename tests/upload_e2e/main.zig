//! Upload 端到端集成测试 — TCP loopback 上验证完整 upload 协议流程
//!
//! 验证场景：
//! 1. 小文件上传 + SHA256 验证
//! 2. 上传结果（exit_code）回传
//! 3. 零字节文件上传
//! 4. 二进制文件上传
//!
//! Guest 模拟器接收 upload_cmd 帧 → 读取原始文件字节 → 验证 SHA256 → 发送 upload_result

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

/// Guest 模拟器：接收 upload_cmd → 读取文件数据 → 验证 → 返回 upload_result
fn guestUploadSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    expected_data: []const u8,
    exit_code: i32,
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

    // 步骤 1: 接收 upload_cmd 帧
    const cmd_frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(cmd_frame);

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.upload_cmd)) return;

    const cmd = protocol.parseUploadCmd(cmd_frame[1..]) orelse return;

    // 步骤 2: 读取原始文件数据（file_size 字节）
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(allocator);

    var remaining: usize = @intCast(cmd.file_size);
    var rbuf: [65536]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(remaining, rbuf.len);
        const n = common.sockRead(cli_fd, &rbuf, to_read);
        if (n <= 0) return;
        received.appendSlice(allocator, rbuf[0..@intCast(n)]) catch return;
        remaining -= @intCast(n);
    }

    // 步骤 3: 验证 SHA256
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(received.items, &sha, .{});
    const expected_hash = cmd.file_hash;
    for (sha, 0..) |b, i| {
        if (b != expected_hash[i]) return; // SHA256 不匹配
    }

    // 步骤 4: 验证内容
    if (!std.mem.eql(u8, expected_data, received.items)) return;

    // 步骤 5: 发送 upload_result
    const result_frame = protocol.buildUploadResult(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(result_frame);
    tcp.sendFrame(cli_fd, result_frame) catch return;

    result_ok.store(true, .release);
}

/// 计算文件数据的 SHA256
fn computeSha256(data: []const u8) ![32]u8 {
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

    // ── 场景 1: 小文件上传 ──
    {
        var tc = runner.case("upload: 小文件上传 + SHA256 验证");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "Hello, upload protocol test!";
        const file_hash = try computeSha256(test_data);

        const guest_thread = try std.Thread.spawn(.{}, guestUploadSimulator, .{
            io, alloc, listener.fd, test_data, 0, &guest_done, &guest_ok,
        });

        // Host 端：连接 + 发送 upload_cmd + 原始文件数据 + 接收结果
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

        // 发送 upload_cmd 帧
        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-1", "/tmp/test.txt", @intCast(test_data.len), &file_hash);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        // 直接发送原始文件数据
        _ = common.sockWrite(fd,test_data.ptr, test_data.len);

        // 接收 upload_result
        const result_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);

        tc.expectTrue(result_frame[0] == @intFromEnum(protocol.MsgType.upload_result), "收到 upload_result");

        const result = protocol.parseUploadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 upload_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "upload exit_code = 0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 2: 上传结果错误码 ──
    {
        var tc = runner.case("upload: 错误退出码回传");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "error case";
        const file_hash = try computeSha256(test_data);

        const guest_thread = try std.Thread.spawn(.{}, guestUploadSimulator, .{
            io, alloc, listener.fd, test_data, 13, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-2", "/tmp/err.txt", @intCast(test_data.len), &file_hash);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);
        _ = common.sockWrite(fd,test_data.ptr, test_data.len);

        const result_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);

        const result = protocol.parseUploadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 upload_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 13), result.exit_code, "upload exit_code = 13");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 3: 零字节文件上传 ──
    {
        var tc = runner.case("upload: 零字节文件");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const empty_data: []const u8 = &.{};
        const file_hash = try computeSha256(empty_data);

        const guest_thread = try std.Thread.spawn(.{}, guestUploadSimulator, .{
            io, alloc, listener.fd, empty_data, 0, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-3", "/tmp/empty.txt", 0, &file_hash);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);
        // 零字节文件：不发送任何数据

        const result_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);

        tc.expectTrue(result_frame[0] == @intFromEnum(protocol.MsgType.upload_result), "收到 upload_result");
        const result = protocol.parseUploadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 upload_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "零字节文件上传成功");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 4: 二进制文件上传（含 null 字节）──
    {
        var tc = runner.case("upload: 二进制文件");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        // 生成包含所有字节值 0x00-0xFF 的二进制数据
        var binary_data: [256]u8 = undefined;
        for (&binary_data, 0..) |*b, i| {
            b.* = @intCast(i);
        }
        const file_hash = try computeSha256(&binary_data);

        const guest_thread = try std.Thread.spawn(.{}, guestUploadSimulator, .{
            io, alloc, listener.fd, &binary_data, 0, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-4", "/tmp/binary.bin", 256, &file_hash);
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);
        _ = common.sockWrite(fd,&binary_data, binary_data.len);

        const result_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv upload_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);

        const result = protocol.parseUploadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 upload_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), result.exit_code, "二进制文件上传成功");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }
}
