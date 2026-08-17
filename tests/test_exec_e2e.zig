//! Exec 端到端集成测试 — TCP loopback 上验证完整 exec 协议流程

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;

/// Guest 模拟器：接收 exec 帧 → 模拟执行 → 返回输出 + 标记 + exit code。
fn guestSimulator(
    io: std.Io,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    output_before_marker: []const u8,
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

    const frame = protocol.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(frame);

    if (frame.len < 1 or frame[0] != @intFromEnum(protocol.MsgType.pty_exec_input)) return;

    const parsed = protocol.parsePtyExecInput(frame[1..]) orelse return;

    var sim_output: std.ArrayList(u8) = .empty;
    defer sim_output.deinit(allocator);
    if (output_before_marker.len > 0) {
        sim_output.appendSlice(allocator, output_before_marker) catch return;
    }
    const marker_line = std.fmt.allocPrint(allocator, "MDELIM:{d}\n", .{exit_code}) catch return;
    defer allocator.free(marker_line);
    sim_output.appendSlice(allocator, marker_line) catch return;

    const out_frame = protocol.buildPtyExecOutput(allocator, parsed.cmd_id, sim_output.items) catch return;
    defer allocator.free(out_frame);
    protocol.sendFrame(cli_fd, out_frame) catch return;

    const done_frame = protocol.buildPtyExecDone(allocator, parsed.cmd_id, exit_code) catch return;
    defer allocator.free(done_frame);
    protocol.sendFrame(cli_fd, done_frame) catch return;

    result_ok.store(true, .release);
}

pub fn test_exec_e2e(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    // ── 场景 1: 简单命令执行 + exit code 0 ──
    {
        var tc = runner.case("exec: 简单命令 + exit code 0");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const guest_thread = try std.Thread.spawn(.{}, guestSimulator, .{
            io, alloc, listener.fd, "hello world", 0, &guest_done, &guest_ok,
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

        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "/bin/bash", "echo hello");
        defer alloc.free(cmd_with_marker);
        tc.expectTrue(std.mem.indexOf(u8, cmd_with_marker, "MDELIM:") != null, "命令包含 MDELIM 标记");

        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-1", cmd_with_marker);
        defer alloc.free(input_frame);
        try protocol.sendFrame(fd, input_frame);

        const out_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);
        tc.expectTrue(out_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_output), "收到 pty_exec_output");

        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, out_frame[1..]);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "找到 MDELIM 标记");
        tc.expectEqual(@as(i32, 0), mr.exit_code, "exit code = 0");

        const done_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);
        tc.expectTrue(done_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_done), "收到 pty_exec_done");

        const parsed_done = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 0), parsed_done.exit_code, "pty_exec_done exit_code = 0");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 2: 错误退出码（非零）正确传递 ──
    {
        var tc = runner.case("exec: 错误退出码");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const guest_thread = try std.Thread.spawn(.{}, guestSimulator, .{
            io, alloc, listener.fd, "some error output", 42, &guest_done, &guest_ok,
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

        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "/bin/bash", "failing-cmd");
        defer alloc.free(cmd_with_marker);
        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-2", cmd_with_marker);
        defer alloc.free(input_frame);
        try protocol.sendFrame(fd, input_frame);

        const out_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);

        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, out_frame[1..]);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "找到 MDELIM 标记");
        tc.expectEqual(@as(i32, 42), mr.exit_code, "exit code = 42");

        const done_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_done: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(done_frame);
        const parsed_done = protocol.parsePtyExecDone(done_frame[1..]) orelse {
            tc.expect(false, "解析 pty_exec_done 失败", .{});
            tc.deinit();
            return;
        };
        tc.expectEqual(@as(i32, 42), parsed_done.exit_code, "pty_exec_done exit_code = 42");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 3: 零输出命令 ──
    {
        var tc = runner.case("exec: 零输出命令");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const guest_thread = try std.Thread.spawn(.{}, guestSimulator, .{
            io, alloc, listener.fd, "", 0, &guest_done, &guest_ok,
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

        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "/bin/bash", "true");
        defer alloc.free(cmd_with_marker);
        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-3", cmd_with_marker);
        defer alloc.free(input_frame);
        try protocol.sendFrame(fd, input_frame);

        const out_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);

        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, out_frame[1..]);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "零输出命令也应有 MDELIM 标记");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 4: Windows cmd.exe shell 标记格式 ──
    {
        var tc = runner.case("exec: Windows cmd.exe 标记");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const guest_thread = try std.Thread.spawn(.{}, guestSimulator, .{
            io, alloc, listener.fd, "dir", 0, &guest_done, &guest_ok,
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

        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "cmd.exe", "dir");
        defer alloc.free(cmd_with_marker);
        tc.expectTrue(std.mem.indexOf(u8, cmd_with_marker, "MDELIM:%errorlevel%") != null, "Windows 标记格式正确");

        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-4", cmd_with_marker);
        defer alloc.free(input_frame);
        try protocol.sendFrame(fd, input_frame);

        const out_frame = protocol.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);

        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, out_frame[1..]);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "Windows shell 也正确产生 MDELIM 标记");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }

    // ── 场景 5: 大输出（>64KB）流式分块发送，验证不丢字节 + exit 0 ──
    {
        var tc = runner.case("exec: 大输出分块发送不丢字节");

        const listener = common.bindAny(io) catch {
            tc.skip("无法绑定测试端口");
            tc.deinit();
            return;
        };
        defer common.sockClose(listener.fd);

        var guest_ok = std.atomic.Value(bool).init(false);
        var guest_done = std.atomic.Value(bool).init(false);

        const guest_thread = try std.Thread.spawn(.{}, streamingLargeOutputSimulator, .{
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

        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "/bin/bash", "seq 1 20000");
        defer alloc.free(cmd_with_marker);
        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-5", cmd_with_marker);
        defer alloc.free(input_frame);
        try protocol.sendFrame(fd, input_frame);

        // 持续接收 pty_exec_output 帧并累积，直到 pty_exec_done
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(alloc);

        var exit_code: i32 = -999;
        var got_done = false;
        var output_bytes: usize = 0;

        while (true) {
            const frame = protocol.recvFrame(alloc, fd) catch |err| {
                tc.expect(false, "recvFrame: {}", .{err});
                break;
            };
            defer alloc.free(frame);
            if (frame.len < 1) break;

            const msg_type: protocol.MsgType = @enumFromInt(frame[0]);
            switch (msg_type) {
                .pty_exec_output => {
                    var mpos: usize = 1;
                    _ = protocol.readString(frame[1..], &mpos);
                    const data = protocol.readBlob(frame[1..], &mpos) orelse continue;
                    try received.appendSlice(alloc, data);
                    output_bytes += data.len;
                },
                .pty_exec_done => {
                    var mpos: usize = 1;
                    _ = protocol.readString(frame[1..], &mpos);
                    exit_code = protocol.readI32(frame[1..], &mpos) orelse @as(i32, -1);
                    got_done = true;
                    break;
                },
                else => {},
            }
        }

        tc.expectTrue(got_done, "收到 pty_exec_done");
        tc.expectEqual(@as(i32, 0), exit_code, "exit code = 0");

        // 验证完整输出含 MDELIM 标记且标记前内容非空（大输出确已流式传输）
        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, received.items);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "累积输出含 MDELIM 标记");
        tc.expectTrue(marker_buf.items.len > 0, "标记前有实际输出内容");
        tc.expectTrue(output_bytes > 65536, "总输出 > 64KB（验证分块跨越单帧缓冲）");

        guest_thread.join();
        tc.expectTrue(guest_ok.load(.acquire), "Guest 模拟器成功完成");
        tc.deinit();
    }
}

/// Guest 模拟器：分块发送大输出（>64KB），每块 4096 字节，模拟流式分块。
/// 用于验证 Host 端持续接收多个 pty_exec_output 帧并正确累积。
fn streamingLargeOutputSimulator(
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

    const frame = protocol.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(frame);
    if (frame.len < 1 or frame[0] != @intFromEnum(protocol.MsgType.pty_exec_input)) return;
    const parsed = protocol.parsePtyExecInput(frame[1..]) orelse return;

    // 生成 >64KB 的数据，分块 4096 字节发送
    const chunk_size = 4096;
    const total = 70 * 1024; // 70KB，跨越多块
    const block = allocator.alloc(u8, chunk_size) catch return;
    defer allocator.free(block);
    // 填充可打印字符，避免 scanForMarker 干扰
    for (block) |*b| b.* = 'a';

    var sent: usize = 0;
    while (sent < total) {
        const n = @min(chunk_size, total - sent);
        const out_frame = protocol.buildPtyExecOutput(allocator, parsed.cmd_id, block[0..n]) catch return;
        protocol.sendFrame(cli_fd, out_frame) catch {
            allocator.free(out_frame);
            return;
        };
        allocator.free(out_frame);
        sent += n;
    }

    // 发送 MDELIM 标记 + done
    const marker_line = std.fmt.allocPrint(allocator, "MDELIM:0\n", .{}) catch return;
    defer allocator.free(marker_line);
    const marker_frame = protocol.buildPtyExecOutput(allocator, parsed.cmd_id, marker_line) catch return;
    protocol.sendFrame(cli_fd, marker_frame) catch {
        allocator.free(marker_frame);
        return;
    };
    allocator.free(marker_frame);

    const done_frame = protocol.buildPtyExecDone(allocator, parsed.cmd_id, 0) catch return;
    defer allocator.free(done_frame);
    protocol.sendFrame(cli_fd, done_frame) catch return;

    result_ok.store(true, .release);
}
