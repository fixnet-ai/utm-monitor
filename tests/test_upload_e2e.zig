//! Upload 端到端集成测试 — TCP loopback 上验证完整 upload 协议流程

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

    const cmd_frame = protocol.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(cmd_frame);

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.upload_cmd)) return;

    const cmd = protocol.parseUploadCmd(cmd_frame[1..]) orelse return;

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

    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(received.items, &sha, .{});
    // 生产语义：upload_cmd 的 hash 字段是 64 字符 hex 字符串（writeString 写、readString 读）。
    // 模拟器按同一语义比对，避免二进制哈希中的 0 字节被当作字符串终止符。
    var sha_hex: [64]u8 = undefined;
    _ = toHex(&sha_hex, &sha);
    if (!std.mem.eql(u8, cmd.file_hash, &sha_hex)) return;

    if (!std.mem.eql(u8, expected_data, received.items)) return;

    const result_frame = protocol.buildUploadResult(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(result_frame);
    protocol.sendFrame(cli_fd, result_frame) catch return;

    result_ok.store(true, .release);
}

fn computeSha256(data: []const u8) ![32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

/// 32 字节二进制哈希 → 64 字符小写 hex 字符串（与生产代码的 hex 语义一致）。
fn toHex(buf: *[64]u8, hash: *const [32]u8) []const u8 {
    for (hash, 0..) |b, i| {
        buf[i * 2] = "0123456789abcdef"[b >> 4];
        buf[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return buf;
}

pub fn test_upload_e2e(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
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
        var file_hash_hex: [64]u8 = undefined;

        const guest_thread = try std.Thread.spawn(.{}, guestUploadSimulator, .{
            io, alloc, listener.fd, test_data, 0, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-1", "/tmp/test.txt", @intCast(test_data.len), toHex(&file_hash_hex, &file_hash));
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        _ = common.sockWrite(fd, test_data.ptr, test_data.len);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
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
        var file_hash_hex: [64]u8 = undefined;

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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-2", "/tmp/err.txt", @intCast(test_data.len), toHex(&file_hash_hex, &file_hash));
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);
        _ = common.sockWrite(fd, test_data.ptr, test_data.len);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
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
        var file_hash_hex: [64]u8 = undefined;

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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-3", "/tmp/empty.txt", 0, toHex(&file_hash_hex, &file_hash));
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
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

    // ── 场景 4: 二进制文件上传 ──
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

        var binary_data: [256]u8 = undefined;
        for (&binary_data, 0..) |*b, i| {
            b.* = @intCast(i);
        }
        const file_hash = try computeSha256(&binary_data);
        var file_hash_hex: [64]u8 = undefined;

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

        const cmd_frame = try protocol.buildUploadCmd(alloc, "up-4", "/tmp/binary.bin", 256, toHex(&file_hash_hex, &file_hash));
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);
        _ = common.sockWrite(fd, &binary_data, binary_data.len);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
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
