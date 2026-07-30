//! Download 端到端集成测试 — TCP loopback 上验证完整 download 协议流程

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

/// Guest 模拟器：接收 download_cmd → 流式发送文件数据 → 发送 pty_exec_done
fn guestDownloadSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    file_data: []const u8,
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

    const cmd_frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(cmd_frame);

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.download_cmd)) return;

    const cmd = protocol.parseDownloadCmd(cmd_frame[1..]) orelse return;

    _ = common.sockWrite(cli_fd, file_data.ptr, file_data.len);

    const done_frame = protocol.buildPtyExecDone(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(done_frame);
    tcp.sendFrame(cli_fd, done_frame) catch return;

    result_ok.store(true, .release);
}

pub fn test_download_e2e(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    // ── 场景 1: 小文件下载 ──
    {
        var tc = runner.case("download: 小文件下载");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "Download protocol test data!";

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-1", "/tmp/download.txt");
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        var rbuf: [65536]u8 = undefined;
        const file_n: usize = @intCast(common.sockRead(fd, &rbuf, test_data.len));
        tc.expectEqual(test_data.len, file_n, "收到完整文件数据");
        try received.appendSlice(alloc, rbuf[0..@intCast(file_n)]);
        tc.expectStr(test_data, received.items, "文件内容一致");

        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);

        tc.expectTrue(done_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_done), "收到 pty_exec_done");
        const done_data = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), done_data.exit_code, "download exit_code = 0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 2: 大文件下载（流式）──
    {
        var tc = runner.case("download: 大文件流式下载");

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

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, &big_data, 0, &guest_done, &guest_ok,
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
        try tcp.sendFrame(fd, cmd_frame);

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

        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);

        const done_data = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), done_data.exit_code, "大文件 download exit_code = 0");

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

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-3", "/tmp/empty.dat");
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);

        tc.expectTrue(done_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_done), "零字节文件返回 done 帧");
        const done_data = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), done_data.exit_code, "零字节 exit_code = 0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 4: 下载失败退出码传递 ──
    {
        var tc = runner.case("download: 失败退出码");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const test_data = "file not found";

        const guest_thread = try std.Thread.spawn(.{}, guestDownloadSimulator, .{
            io, alloc, listener.fd, test_data, 1, &guest_done, &guest_ok,
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

        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-4", "/nonexistent/file");
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        var rbuf: [4096]u8 = undefined;
        _ = common.sockRead(fd, &rbuf, test_data.len);

        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);

        const done_data = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 1), done_data.exit_code, "download exit_code = 1（失败）");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }
}
