// dpipe.zig — DuplexPipe abstraction
//
// Vtable-based polymorphic I/O interface that unifies TCP sockets, PTY shells,
// and file I/O behind a common read/write/close API. All I/O operations go
// through the DuplexPipe interface.
//
// DuplexPipe replaces the KCP-era tunnel.zig function pointer pattern (sendFn/recvFn)
// with a cleaner vtable design — the entire pipe is passed as a single value,
// no per-operation context capture needed.

const std = @import("std");
const zio = @import("zio");

// ── DuplexPipe 接口 ────────────────────────────────────────────

/// 管道操作的虚函数表。
/// 所有函数接收 *anyopaque ctx 作为第一参数 — 具体实现在 ctx 中存储其状态。
pub const VTable = struct {
    readFn: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    closeFn: *const fn (ctx: *anyopaque) void,
};

/// 双工管道 — 同时支持读写的全双工通道。
/// 类似于 Go 的 io.ReadWriteCloser 或 Rust 的 AsyncRead + AsyncWrite。
///
/// 值语义：DuplexPipe 是 16 字节（指针 + 指针），按值拷贝传递。
/// 调用者负责在 close() 之前保持 ctx 存活。
pub const DuplexPipe = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// 从管道读取数据。返回读取的字节数，0 表示 EOF。
    pub fn read(self: DuplexPipe, buf: []u8) anyerror!usize {
        return self.vtable.readFn(self.ctx, buf);
    }

    /// 向管道写入数据。保证全部写入或返回错误。
    pub fn write(self: DuplexPipe, data: []const u8) anyerror!void {
        return self.vtable.writeFn(self.ctx, data);
    }

    /// 关闭管道。关闭后不再进行读写操作。
    pub fn close(self: DuplexPipe) void {
        self.vtable.closeFn(self.ctx);
    }
};

// ── 双向中继 ──────────────────────────────────────────────────

/// 在管道 A 和 B 之间做全双工字节转发。
///
/// 使用 zio Group.spawnBlocking 启动两个并发任务：A→B 和 B→A，
/// 任一端 EOF 或出错时通知另一端停止，等待两个方向都退出后关闭双方管道。
///
/// 用于 file upload/download：Host 端 relay(TCP, FilePipe) 或
/// Guest 端 relay(ShellPipe, TCP)。
///
/// 缓冲大小 64KB。
pub fn relay(a: DuplexPipe, b: DuplexPipe) !void {
    const RelayBufferSize = 65536;

    // 共享停止标志 — 任一方向设置后另一方向在下个循环检测到
    var done = std.atomic.Value(bool).init(false);

    // 使用 zio Group 管理并发：spawnBlocking 在 thread pool 上运行
    // B→A 方向，当前线程运行 A→B 方向
    var g: zio.Group = .init;
    try g.spawnBlocking(relayOneWay, .{ a, b, &done, RelayBufferSize });

    // 当前线程: B → A（从 B 读，写到 A）
    relayOneWay(b, a, &done, RelayBufferSize);

    // 等待两个方向都结束
    g.wait() catch {};

    // 关闭双方
    a.close();
    b.close();
}

/// 单向中继：从 src 读，写到 dst，直到 EOF、错误、或 done 标志被设置。
fn relayOneWay(src: DuplexPipe, dst: DuplexPipe, done: *std.atomic.Value(bool), buf_size: usize) void {
    var buf: [65536]u8 = undefined;
    const buffer = buf[0..@min(buf_size, buf.len)];

    while (!done.load(.acquire)) {
        const n = src.read(buffer) catch {
            done.store(true, .release);
            break;
        };
        if (n == 0) {
            // EOF — 通知对方停止
            done.store(true, .release);
            break;
        }
        dst.write(buffer[0..n]) catch {
            done.store(true, .release);
            break;
        };
    }
}

// ── 测试用内存管道 (BytePipe) ─────────────────────────────────

/// 基于内存的 DuplexPipe 实现，用于测试。
/// 单线程使用 — 不做并发同步。
pub const BytePipe = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 可读数据缓冲区
    read_buf: std.ArrayList(u8),
    /// 读取位置
    read_pos: usize,

    pub fn create(allocator: std.mem.Allocator) !BytePipe {
        return BytePipe{
            .allocator = allocator,
            .read_buf = std.ArrayList(u8).empty,
            .read_pos = 0,
        };
    }

    pub fn deinit(self: *BytePipe) void {
        self.read_buf.deinit(self.allocator);
    }

    /// 写入数据到管道（便捷方法，供测试直接调用）。
    pub fn write(self: *BytePipe, data: []const u8) !void {
        try self.read_buf.appendSlice(self.allocator, data);
    }

    /// 从管道读取数据（便捷方法，供测试直接调用）。
    pub fn read(self: *BytePipe, buf: []u8) !usize {
        const available = self.read_buf.items.len - self.read_pos;
        if (available == 0) return 0;

        const n = @min(buf.len, available);
        @memcpy(buf[0..n], self.read_buf.items[self.read_pos .. self.read_pos + n]);
        self.read_pos += n;

        // 如果所有数据都已消费，重置缓冲区以回收空间
        if (self.read_pos >= self.read_buf.items.len) {
            self.read_buf.clearRetainingCapacity();
            self.read_pos = 0;
        }
        return n;
    }

    /// 从管道读取数据（vtable 实现）。
    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        var self: *BytePipe = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    /// 向管道写入数据（vtable 实现）。
    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        var self: *BytePipe = @ptrCast(@alignCast(ctx));
        return self.write(data);
    }

    /// 关闭管道 — 释放缓冲区（vtable 实现）。
    fn closeImpl(ctx: *anyopaque) void {
        var self: *BytePipe = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// 返回此 BytePipe 的 DuplexPipe 接口。
    /// 注意：返回的 DuplexPipe 拥有 BytePipe 的所有权 — close() 会释放它。
    pub fn toPipe(self: *BytePipe) DuplexPipe {
        return DuplexPipe{
            .ctx = self,
            .vtable = &byte_pipe_vtable,
        };
    }
};

const byte_pipe_vtable = VTable{
    .readFn = BytePipe.readImpl,
    .writeFn = BytePipe.writeImpl,
    .closeFn = BytePipe.closeImpl,
};

// ── 测试 ──────────────────────────────────────────────────────

const testing = std.testing;

test "dpipe vtable dispatch round-trip" {
    var bp = try BytePipe.create(testing.allocator);

    const pipe = bp.toPipe();
    try pipe.write("hello");
    try pipe.write(" world");

    // read 返回所有可用数据（最多 buf 大小）
    var buf: [32]u8 = undefined;
    const n1 = try pipe.read(&buf);
    try testing.expectEqual(@as(usize, 11), n1);
    try testing.expectEqualStrings("hello world", buf[0..n1]);

    // 数据已全部读取，再读返回 0 (EOF)
    const n2 = try pipe.read(&buf);
    try testing.expectEqual(@as(usize, 0), n2);

    pipe.close();
}

test "dpipe close invokes vtable closeFn" {
    // 使用带标志的结构体验证 close 被调用
    const CloseTracker = struct {
        closed: bool,
        fn readImpl(_: *anyopaque, _: []u8) anyerror!usize {
            return 0;
        }
        fn writeImpl(_: *anyopaque, _: []const u8) anyerror!void {}
        fn closeImpl(ctx: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }
    };

    const tracker_vtable = VTable{
        .readFn = CloseTracker.readImpl,
        .writeFn = CloseTracker.writeImpl,
        .closeFn = CloseTracker.closeImpl,
    };

    var tracker = CloseTracker{ .closed = false };
    const pipe = DuplexPipe{ .ctx = &tracker, .vtable = &tracker_vtable };

    try testing.expect(!tracker.closed);
    pipe.close();
    try testing.expect(tracker.closed);
}

test "dpipe relay one-directional transfer" {
    // 测试单向 relayOneWay：创建 source pipe（有数据）和 sink pipe（空），
    // relayOneWay(source, sink) → sink 收到全部数据。

    var src = try BytePipe.create(testing.allocator);
    var dst = try BytePipe.create(testing.allocator);

    try src.write("hello from source");

    var done = std.atomic.Value(bool).init(false);
    relayOneWay(src.toPipe(), dst.toPipe(), &done, 4096);

    // 验证数据被转发
    var buf: [64]u8 = undefined;
    const n = try dst.read(&buf);
    try testing.expectEqual(@as(usize, 17), n);
    try testing.expectEqualStrings("hello from source", buf[0..n]);

    // 确认已读完
    const n2 = try dst.read(&buf);
    try testing.expectEqual(@as(usize, 0), n2);

    // relayOneWay 不调用 close — 手动释放
    src.toPipe().close();
    dst.toPipe().close();
}

test "dpipe relayOneWay propagates read error" {
    // 测试当 src.read() 返回错误时 done 标志被设置。
    const ErrorPipe = struct {
        fn readImpl(_: *anyopaque, _: []u8) anyerror!usize {
            return error.BrokenPipe;
        }
        fn writeImpl(_: *anyopaque, _: []const u8) anyerror!void {}
        fn closeImpl(_: *anyopaque) void {}
    };

    const error_vtable = VTable{
        .readFn = ErrorPipe.readImpl,
        .writeFn = ErrorPipe.writeImpl,
        .closeFn = ErrorPipe.closeImpl,
    };

    var dummy: u8 = 0;
    const src: DuplexPipe = .{ .ctx = &dummy, .vtable = &error_vtable };

    var dst = try BytePipe.create(testing.allocator);
    const dst_pipe = dst.toPipe();

    var done = std.atomic.Value(bool).init(false);
    relayOneWay(src, dst_pipe, &done, 4096);

    // 错误被捕获，done 标志被设置
    try testing.expect(done.load(.acquire));

    // 清理
    dst_pipe.close();
}

test "dpipe relayOneWay eof propagation" {
    // 空 src pipe → relayOneWay 立即读到 EOF → 设置 done 标志

    var src = try BytePipe.create(testing.allocator);
    var dst = try BytePipe.create(testing.allocator);

    var done = std.atomic.Value(bool).init(false);
    relayOneWay(src.toPipe(), dst.toPipe(), &done, 4096);

    // EOF 被检测到，done 标志被设置
    try testing.expect(done.load(.acquire));

    // dst 应该是空的（没有数据被转发）
    var buf: [8]u8 = undefined;
    const n = try dst.read(&buf);
    try testing.expectEqual(@as(usize, 0), n);

    src.toPipe().close();
    dst.toPipe().close();
}
