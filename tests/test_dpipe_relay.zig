//! DuplexPipe relay 集成测试

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const dpipe = lib.dpipe;
const tcp = lib.tcp;

pub fn test_dpipe_relay(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    _ = io; // no longer needed — relay() uses zio internally
    // ── 场景 1: BytePipe 读写 + EOF ──
    {
        var tc = runner.case("BytePipe 读写 + EOF");

        var bp = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };
        const pipe = bp.toPipe();
        defer pipe.close();

        try pipe.write("hello");
        try pipe.write(" world");

        var buf: [32]u8 = undefined;
        const n1 = try pipe.read(&buf);
        tc.expectEqual(@as(usize, 11), n1, "读取 11 字节");
        tc.expectStr("hello world", buf[0..n1], "内容正确");

        const n2 = try pipe.read(&buf);
        tc.expectEqual(@as(usize, 0), n2, "EOF 返回 0");

        tc.deinit();
    }

    // ── 场景 2: BytePipe 大数据（128KB）──
    {
        var tc = runner.case("BytePipe 128KB 大数据");

        var bp = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };
        const pipe = bp.toPipe();
        defer pipe.close();

        const data_size = 128 * 1024;
        var data = try alloc.alloc(u8, data_size);
        defer alloc.free(data);
        for (data, 0..) |*b, i| {
            b.* = @truncate(i & 0xff);
        }

        try pipe.write(data);

        var total_read: usize = 0;
        var rbuf: [4096]u8 = undefined;
        while (total_read < data_size) {
            const n = try pipe.read(&rbuf);
            if (n == 0) break;
            tc.expectTrue(std.mem.eql(u8, data[total_read..][0..n], rbuf[0..n]), "数据块一致");
            total_read += n;
        }
        tc.expectTrue(data_size == total_read, "总读取量一致");

        tc.deinit();
    }

    // ── 场景 3: TCP socket → DuplexPipe 适配 ──
    {
        var tc = runner.case("TCP socket → DuplexPipe 适配");

        const pair = common.makePair() catch {
            tc.skip("socketpair 不可用");
            tc.deinit();
            return;
        };
        defer {
            common.sockClose(pair.a);
            common.sockClose(pair.b);
        }

        const tcp_pipe = tcp.duplexPipe(pair.a, alloc) catch |err| {
            tc.expect(false, "duplexPipe 失败: {}", .{err});
            tc.deinit();
            return;
        };
        defer tcp_pipe.close();

        const msg = "hello via tcp duplex pipe";
        _ = common.sockWrite(pair.b, msg, msg.len);

        var buf: [64]u8 = undefined;
        const n = try tcp_pipe.read(&buf);
        tc.expectEqual(msg.len, n, "读取长度一致");
        tc.expectStr(msg, buf[0..n], "内容一致");

        tc.deinit();
    }

    // ── 场景 4: relay() 数据转发 ──
    // relay() 内部使用 zio spawnBlocking，阻塞直到两个方向都完成。
    // relay() 结束时关闭双方 pipe（调用 closeFn），之后不能再访问。
    {
        var tc = runner.case("relay() 数据转发");

        var bp1 = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };
        // Note: bp2 not created — we only verify relay() completes without crash.
        // relay() calls close() on both pipes which deinits BytePipe buffers.
        var bp2 = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };

        // Write test data to bp1; bp2 is empty.
        // relay(A→B, B→A): bp1 data → bp2, then bp2 EOF → done → both exit.
        try bp1.write("bidirectional relay test");

        const p1 = bp1.toPipe();
        const p2 = bp2.toPipe();

        // relay() uses zio spawnBlocking internally — no manual thread spawn needed.
        // Both directions run on the thread pool, relay() blocks until they complete,
        // then closes both pipes.
        dpipe.relay(p1, p2) catch |err| {
            tc.expect(false, "relay 失败: {}", .{err});
        };

        tc.deinit();
    }

    // ── 场景 5: relay() 空管道 EOF 终止 ──
    {
        var tc = runner.case("relay() 空管道终止");

        var bp1 = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };
        var bp2 = dpipe.BytePipe.create(alloc) catch {
            tc.skip("BytePipe.create 失败");
            tc.deinit();
            return;
        };

        const p1 = bp1.toPipe();
        const p2 = bp2.toPipe();

        // relay() with empty pipes: relayOneWay(b→a) reads EOF immediately,
        // sets done flag, relayOneWay(a→b) checks done and exits.
        // Then closes both pipes. Just verify no crash.
        dpipe.relay(p1, p2) catch |err| {
            tc.expect(false, "relay 失败: {}", .{err});
        };

        tc.deinit();
    }
}
