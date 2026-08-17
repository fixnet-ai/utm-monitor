//! Download 端到端集成测试 — TCP loopback 上验证完整 download 协议流程

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

/// Guest 模拟器：接收 download_cmd → 发送 download_result（含哈希）→ 流式发送文件数据。
/// send_data 为实际发往对端的字节（可注入篡改以测试哈希不匹配）。
fn guestDownloadSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    send_data: []const u8,
    advertised_hash: []const u8,
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

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.download_cmd)) return;

    const cmd = protocol.parseDownloadCmd(cmd_frame[1..]) orelse return;

    // 先发 download_result（file_size = send_data.len，哈希 = advertised_hash）。
    const result_frame = protocol.buildDownloadResult(allocator, cmd.cmd_id, @intCast(send_data.len), advertised_hash) catch return;
    defer allocator.free(result_frame);
    protocol.sendFrame(cli_fd, result_frame) catch return;

    // 再流式发原始字节。
    _ = common.sockWrite(cli_fd, send_data.ptr, send_data.len);

    result_ok.store(true, .release);
}

fn hexHash(data: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex: [64]u8 = undefined;
    for (&hash, 0..) |b, i| {
        hex[i * 2] = "0123456789abcdef"[b >> 4];
        hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return hex;
}

pub fn test_download_e2e(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    // ── 场景 1: 小文件下载 + 哈希校验通过 ──
    {
        var tc = runner.case("download: 小文件下载 + 哈希校验");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "Download protocol test data!";
        const expected_hash = hexHash(test_data);

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, test_data, &expected_hash, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-1", "/tmp/download.txt");
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        // 先收 download_result 帧，校验 file_size 与哈希。
        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv download_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);
        tc.expectTrue(result_frame[0] == @intFromEnum(protocol.MsgType.download_result), "收到 download_result");
        const result = protocol.parseDownloadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 download_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(u32, @intCast(test_data.len)), result.file_size, "file_size 一致");
        tc.expectStr(&expected_hash, result.sha256_hex, "sha256_hex 一致");

        // 再收原始字节，读满 file_size。
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);
        var rbuf: [65536]u8 = undefined;
        const file_n: usize = @intCast(common.sockRead(fd, &rbuf, test_data.len));
        tc.expectEqual(test_data.len, file_n, "收到完整文件数据");
        try received.appendSlice(alloc, rbuf[0..@intCast(file_n)]);
        tc.expectStr(test_data, received.items, "文件内容一致");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 2: 大文件下载（流式 + 哈希校验）──
    {
        var tc = runner.case("download: 大文件流式下载 + 哈希校验");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        var big_data: [131072]u8 = undefined;
        for (&big_data, 0..) |*b, i| {
            b.* = @truncate(i & 0xff);
        }
        const expected_hash = hexHash(&big_data);

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, &big_data, &expected_hash, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-2", "/tmp/big.dat");
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv download_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);
        const result = protocol.parseDownloadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 download_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(u32, @intCast(big_data.len)), result.file_size, "file_size 一致");

        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        var remaining: usize = big_data.len;
        var rbuf: [65536]u8 = undefined;
        while (remaining > 0) {
            const to_read = @min(remaining, rbuf.len);
            const raw_n = common.sockRead(fd, &rbuf, to_read);
            if (raw_n <= 0) break;
            const n: usize = @intCast(raw_n);
            try received.appendSlice(alloc, rbuf[0..n]);
            remaining -= n;
        }

        tc.expectEqual(big_data.len, received.items.len, "收到完整的 128KB 数据");
        tc.expectTrue(std.mem.eql(u8, &big_data, received.items), "128KB 数据内容一致");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 3: 零字节文件下载 ──
    {
        var tc = runner.case("download: 零字节文件");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const empty_data: []const u8 = &.{};
        const expected_hash = hexHash(empty_data);

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, empty_data, &expected_hash, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-3", "/tmp/empty.dat");
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv download_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);
        tc.expectTrue(result_frame[0] == @intFromEnum(protocol.MsgType.download_result), "零字节文件返回 download_result 帧");
        const result = protocol.parseDownloadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 download_result 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(u32, 0), result.file_size, "零字节 file_size = 0");
        tc.expectStr(&expected_hash, result.sha256_hex, "零字节哈希一致");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 4: 篡改字节导致哈希不匹配 ──
    {
        var tc = runner.case("download: 篡改字节哈希不匹配");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "tamper detection data!";
        const expected_hash = hexHash(test_data); // 广告的是未被篡改的哈希

        // 发送的数据与广告哈希不一致（末尾字符不同）→ Host 应检测到哈希不匹配。
        const tampered_data = "tamper detection data?";

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, tampered_data, &expected_hash, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-4", "/tmp/tamper.txt");
        defer alloc.free(cmd_frame);
        try protocol.sendFrame(fd, cmd_frame);

        const result_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv download_result: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(result_frame);
        const result = protocol.parseDownloadResult(result_frame[1..]) orelse {
            tc.expect(false, "解析 download_result 失败", .{});
            tc.deinit();
            return;
        };

        // 读满 file_size 的原始字节。
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);
        var rbuf: [65536]u8 = undefined;
        const file_n: usize = @intCast(common.sockRead(fd, &rbuf, result.file_size));
        try received.appendSlice(alloc, rbuf[0..@intCast(file_n)]);

        // 收到的数据哈希与广告哈希不一致 → 校验应失败。
        const actual_hash = hexHash(received.items);
        tc.expectTrue(!std.mem.eql(u8, &actual_hash, result.sha256_hex), "收到数据哈希与广告哈希不一致（校验应触发）");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }
}
