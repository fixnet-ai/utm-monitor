//! Download 端到端集成测试 — TCP loopback 上验证完整 download 协议流程
//!
//! 验证场景：
//! 1. 小文件下载 + 内容验证
//! 2. 下载大文件（流式传输验证）
//! 3. 零字节文件下载
//! 4. 下载失败（exit_code 非零）正确传递
//!
//! Guest 模拟器接收 download_cmd 帧 → 流式发送文件数据 → 发送 pty_exec_done

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

    // 步骤 1: 接收 download_cmd 帧
    const cmd_frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(cmd_frame);

    if (cmd_frame.len < 1 or cmd_frame[0] != @intFromEnum(protocol.MsgType.download_cmd)) return;

    const cmd = protocol.parseDownloadCmd(cmd_frame[1..]) orelse return;

    // 步骤 2: 流式发送文件数据（原始字节，不用帧封装）
    _ = common.sockWrite(cli_fd, file_data.ptr, file_data.len);

    // 步骤 3: 发送 pty_exec_done 帧（download 完成标记）
    const done_frame = protocol.buildPtyExecDone(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(done_frame);
    tcp.sendFrame(cli_fd, done_frame) catch return;

    result_ok.store(true, .release);
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

        // Host 端：连接 + 发送 download_cmd + 接收文件数据 + 接收 done
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

        // 发送 download_cmd 帧
        const cmd_frame = try protocol.buildDownloadCmd(alloc, "dl-1", "/tmp/download.txt");
        defer alloc.free(cmd_frame);
        try tcp.sendFrame(fd, cmd_frame);

        // 以 download 模式读取：先读完所有数据直到 pty_exec_done 帧
        // 简单做法：先读完所有可用数据，然后接收 done 帧
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        // 先接收固定长度的文件数据
        var rbuf: [65536]u8 = undefined;
        // Read file data — since we don't know the size, read until we'd get a frame
        // For the test we read the expected amount
        const file_n: usize = @intCast(common.sockRead(fd, &rbuf, test_data.len));
        tc.expectEqual(test_data.len, file_n, "收到完整文件数据");
        try received.appendSlice(alloc, rbuf[0..@intCast(file_n)]);
        tc.expectStr(test_data, received.items, "文件内容一致");

        // 接收 pty_exec_done
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

        // 生成 128KB 数据
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

        // 循环读取直到收到全部数据
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

        // 接收 pty_exec_done
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

        // 零字节：直接收 done 帧
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

        // 跳过文件数据（失败情况下也可能有部分输出）
        var rbuf: [4096]u8 = undefined;
        _ = common.sockRead(fd, &rbuf, test_data.len);

        // 接收失败的 done
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
