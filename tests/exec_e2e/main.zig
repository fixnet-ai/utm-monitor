//! Exec 端到端集成测试 — TCP loopback 上验证完整 exec 协议流程
//!
//! 验证场景：
//! 1. 命令执行 + MDELIM 标记 + exit code 回传（模拟 POSIX shell）
//! 2. 标记在输出中间（模拟部分输出后找到标记）
//! 3. 零输出命令 + 标记解析
//! 4. 错误退出码（非零）正确传递
//!
//! 不 fork 真实 shell — 用线程序模拟 Guest 端行为，验证协议层完整正确性。

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

    // Accept 客户端连接
    const cli_fd = common.sockAccept(listen_fd) catch return;
    defer {
        common.sockShutdown(cli_fd, 2);
        common.sockClose(cli_fd);
    }

    // 接收 pty_exec_input 帧
    const frame = tcp.recvFrame(allocator, cli_fd) catch return;
    defer allocator.free(frame);

    if (frame.len < 1 or frame[0] != @intFromEnum(protocol.MsgType.pty_exec_input)) return;

    const parsed = protocol.parsePtyExecInput(frame[1..]) orelse return;

    // 模拟执行：输出 + MDELIM 标记
    // 模拟 pty 输出：自定义输出 + MDELIM 标记行
    var sim_output: std.ArrayList(u8) = .empty;
    defer sim_output.deinit(allocator);
    if (output_before_marker.len > 0) {
        sim_output.appendSlice(allocator, output_before_marker) catch return;
    }
    // 追加 MDELIM:N\n
    const marker_line = std.fmt.allocPrint(allocator, "MDELIM:{d}\n", .{exit_code}) catch return;
    defer allocator.free(marker_line);
    sim_output.appendSlice(allocator, marker_line) catch return;

    // 发送 pty_exec_output
    const out_frame = protocol.buildPtyExecOutput(allocator, parsed.cmd_id, sim_output.items) catch return;
    defer allocator.free(out_frame);
    tcp.sendFrame(cli_fd, out_frame) catch return;

    // 发送 pty_exec_done
    const done_frame = protocol.buildPtyExecDone(allocator, parsed.cmd_id, exit_code) catch return;
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

        // ── Host 端：连接 + 发送命令 + 接收结果 ──
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

        // 构建带标记的命令
        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "/bin/bash", "echo hello");
        defer alloc.free(cmd_with_marker);
        tc.expectTrue(std.mem.indexOf(u8, cmd_with_marker, "MDELIM:") != null, "命令包含 MDELIM 标记");

        // 发送 pty_exec_input 帧
        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-1", cmd_with_marker);
        defer alloc.free(input_frame);
        try tcp.sendFrame(fd, input_frame);

        // 接收 pty_exec_output
        const out_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);
        tc.expectTrue(out_frame[0] == @intFromEnum(protocol.MsgType.pty_exec_output), "收到 pty_exec_output");

        // 扫描 MDELIM 标记提取 exit code
        var marker_buf: std.ArrayList(u8) = .empty;
        try marker_buf.appendSlice(alloc, out_frame[1..]);
        defer marker_buf.deinit(alloc);
        const mr = protocol.scanForMarker(&marker_buf);
        tc.expectTrue(mr.found, "找到 MDELIM 标记");
        tc.expectEqual(@as(i32, 0), mr.exit_code, "exit code = 0");

        // 接收 pty_exec_done
        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
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
        try tcp.sendFrame(fd, input_frame);

        // 接收输出
        const out_frame = tcp.recvFrame(alloc, fd) catch |err| {
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

        // 接收 done
        const done_frame = tcp.recvFrame(alloc, fd) catch |err| {
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
        try tcp.sendFrame(fd, input_frame);

        const out_frame = tcp.recvFrame(alloc, fd) catch |err| {
            tc.expect(false, "recv pty_exec_output: {}", .{err});
            tc.deinit();
            return;
        };
        defer alloc.free(out_frame);

        // 输出中应只包含 MDELIM 标记
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

        // 使用 Windows shell 构建标记
        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, "cmd.exe", "dir");
        defer alloc.free(cmd_with_marker);
        // Windows 标记格式: "& echo MDELIM:%errorlevel%\r\n"
        tc.expectTrue(std.mem.indexOf(u8, cmd_with_marker, "MDELIM:%errorlevel%") != null, "Windows 标记格式正确");

        const input_frame = try protocol.buildPtyExecInput(alloc, "cmd-4", cmd_with_marker);
        defer alloc.free(input_frame);
        try tcp.sendFrame(fd, input_frame);

        const out_frame = tcp.recvFrame(alloc, fd) catch |err| {
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
}
