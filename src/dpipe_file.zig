// dpipe_file.zig — 文件 I/O 封装为 DuplexPipe
//
// readFile(path):  只读管道，read() 返回文件内容块
// writeFile(path, expected_hash): 只写管道，write() 写入 temp 文件，
//   close() 时验证 SHA256 + atomic rename

const std = @import("std");
const dpipe = @import("dpipe.zig");
const svc = @import("svc.zig");

// ── 只读文件管道 ──────────────────────────────────────────────

const ReadFileCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: std.Io.File,
};

/// 打开文件用于流式读取。read() 返回文件内容块，write() 返回错误。
/// close() 关闭文件描述符并释放资源。
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !dpipe.DuplexPipe {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);

    const ctx = try allocator.create(ReadFileCtx);
    ctx.* = ReadFileCtx{
        .allocator = allocator,
        .io = io,
        .path = try allocator.dupe(u8, path),
        .file = file,
    };

    return dpipe.DuplexPipe{
        .ctx = ctx,
        .vtable = &read_file_vtable,
    };
}

fn readFileFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const self: *ReadFileCtx = @ptrCast(@alignCast(ctx));
    // 使用 readStreaming 直接读取文件。在 EOF 时返回 0
    // 文件末尾或读取错误 → 返回 0 (EOF)
    const n = self.file.readStreaming(self.io, &.{buf}) catch {
        return 0;
    };
    return n;
}

fn readFileWriteFn(_: *anyopaque, _: []const u8) anyerror!void {
    return error.ReadOnly;
}

fn readFileCloseFn(ctx: *anyopaque) void {
    const self: *ReadFileCtx = @ptrCast(@alignCast(ctx));
    self.file.close(self.io);
    self.allocator.free(self.path);
    self.allocator.destroy(self);
}

const read_file_vtable = dpipe.VTable{
    .readFn = readFileFn,
    .writeFn = readFileWriteFn,
    .closeFn = readFileCloseFn,
};

// ── 只写文件管道 ──────────────────────────────────────────────

const WriteFileCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dest_path: []const u8,
    temp_path: []const u8,
    file: std.Io.File,
    sha256: std.crypto.hash.sha2.Sha256,
    expected_hash: []const u8, // empty = no verification
    written: usize,
};

/// 创建文件写入管道。数据通过 write() 写入临时文件。
///
/// close() 时：
///   - 计算 SHA256
///   - 如果 expected_hash 非空：比较哈希，不匹配则删除 temp 并返回错误
///   - Atomic rename temp → dest_path
///   - 释放资源
///
/// expected_hash: SHA256 十六进制字符串，空字符串或 null 表示跳过验证。
pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest_path: []const u8,
    expected_hash: []const u8,
) !dpipe.DuplexPipe {
    // 在系统临时目录中创建随机临时文件
    const dirname = svc.tempDir();
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    var temp_hex: [16]u8 = undefined;
    for (rand_bytes, 0..) |b, j| {
        temp_hex[j * 2] = "0123456789abcdef"[b >> 4];
        temp_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.utmm-{s}", .{ dirname, &temp_hex });
    errdefer allocator.free(temp_path);

    // 清理可能残留的 temp 文件
    std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    errdefer {
        file.close(io);
        allocator.free(temp_path);
    }

    const ctx = try allocator.create(WriteFileCtx);
    ctx.* = WriteFileCtx{
        .allocator = allocator,
        .io = io,
        .dest_path = try allocator.dupe(u8, dest_path),
        .temp_path = temp_path,
        .file = file,
        .sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
        .expected_hash = try allocator.dupe(u8, expected_hash),
        .written = 0,
    };

    return dpipe.DuplexPipe{
        .ctx = ctx,
        .vtable = &write_file_vtable,
    };
}

fn writeFileReadFn(_: *anyopaque, _: []u8) anyerror!usize {
    return error.WriteOnly;
}

fn writeFileWriteFn(ctx: *anyopaque, data: []const u8) anyerror!void {
    const self: *WriteFileCtx = @ptrCast(@alignCast(ctx));

    // 更新 SHA256
    self.sha256.update(data);

    // 写入 temp 文件（直接使用 writeStreamingAll）
    try self.file.writeStreamingAll(self.io, data);
    self.written += data.len;
}

fn writeFileCloseFn(ctx: *anyopaque) void {
    const self: *WriteFileCtx = @ptrCast(@alignCast(ctx));
    defer {
        self.allocator.free(self.dest_path);
        self.allocator.free(self.temp_path);
        self.allocator.free(self.expected_hash);
        self.allocator.destroy(self);
    }

    // 完成 SHA256 计算
    var hash: [32]u8 = undefined;
    self.sha256.final(&hash);

    // 验证哈希（如果提供了 expected_hash）
    if (self.expected_hash.len > 0) {
        const actual_hex = hexHashLeak(self.allocator, &hash) catch {
            // 哈希计算失败 — 删除 temp 文件
            self.file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, self.temp_path) catch {};
            return;
        };
        defer self.allocator.free(actual_hex);

        if (!std.mem.eql(u8, actual_hex, self.expected_hash)) {
            std.log.debug("[dpipe-file] hash mismatch: expected={s} actual={s}", .{ self.expected_hash, actual_hex });
            self.file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, self.temp_path) catch {};
            return;
        }
    }

    // 关闭 temp 文件，然后 atomic rename
    self.file.close(self.io);

    // 删除可能已存在的目标文件，然后 rename
    std.Io.Dir.cwd().deleteFile(self.io, self.dest_path) catch {};
    const cwd = std.Io.Dir.cwd();
    cwd.rename(self.temp_path, cwd, self.dest_path, self.io) catch |e| {
        if (e == error.CrossDevice) {
            // 跨文件系统：先 copy 再删除 temp
            copyAndDelete(self.io, self.temp_path, self.dest_path) catch |ce| {
                std.log.err("[dpipe-file] cross-device copy failed: {} temp={s} dest={s}", .{ ce, self.temp_path, self.dest_path });
            };
        } else {
            std.log.err("[dpipe-file] rename failed: {} temp={s} dest={s}", .{ e, self.temp_path, self.dest_path });
        }
    };
}

/// 跨文件系统复制 + 删除源文件。
fn copyAndDelete(io: std.Io, src: []const u8, dst: []const u8) !void {
    const sf = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer sf.close(io);
    const df = try std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer df.close(io);

    var rdbuf: [65536]u8 = undefined;
    var wrbuf: [65536]u8 = undefined;
    var r = sf.reader(io, &rdbuf);
    var w = df.writer(io, &wrbuf);
    while (true) {
        const n = r.interface.readSliceShort(&rdbuf) catch return error.ReadFailed;
        if (n == 0) break;
        w.interface.writeAll(rdbuf[0..n]) catch return error.WriteFailed;
    }
    w.interface.flush() catch {};
    df.sync(io) catch {};
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
}

const write_file_vtable = dpipe.VTable{
    .readFn = writeFileReadFn,
    .writeFn = writeFileWriteFn,
    .closeFn = writeFileCloseFn,
};

/// 计算 SHA256 哈希的十六进制表示。调用者拥有返回的字符串。
fn hexHashLeak(allocator: std.mem.Allocator, hash: *const [32]u8) ![]const u8 {
    var hex: [64]u8 = undefined;
    for (hash, 0..) |b, j| {
        hex[j * 2] = "0123456789abcdef"[b >> 4];
        hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return try allocator.dupe(u8, &hex);
}

// ── 测试 ──────────────────────────────────────────────────────

const testing = std.testing;

test "dpipe_file readFile basic" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // 创建测试文件
    const test_path = "/tmp/utmm-dpipe-test-read.txt";
    {
        const file = try std.Io.Dir.cwd().createFile(io, test_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello from dpipe_file");
    }
    defer std.Io.Dir.cwd().deleteFile(io, test_path) catch {};

    // readFile 管道
    const pipe = try readFile(testing.allocator, io, test_path);
    defer pipe.close();

    var buf: [64]u8 = undefined;
    const n = try pipe.read(&buf);
    try testing.expectEqualStrings("hello from dpipe_file", buf[0..n]);

    // 第二次读应返回 0 (EOF)
    const n2 = try pipe.read(&buf);
    try testing.expectEqual(@as(usize, 0), n2);

    // write 应返回 ReadOnly 错误
    try testing.expectError(error.ReadOnly, pipe.write("nope"));
}

test "dpipe_file writeFile with hash verification" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const test_path = "/tmp/utmm-dpipe-test-write.txt";

    // 预先计算期望的哈希
    const expected_data = "test data for writeFile";
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    sha256.update(expected_data);
    var expected_hash: [32]u8 = undefined;
    sha256.final(&expected_hash);
    const expected_hex = try hexHashLeak(testing.allocator, &expected_hash);
    defer testing.allocator.free(expected_hex);

    // writeFile 管道
    const pipe = try writeFile(testing.allocator, io, test_path, expected_hex);
    defer {
        std.Io.Dir.cwd().deleteFile(io, test_path) catch {};
    }

    // read 应返回 WriteOnly 错误
    var buf: [4]u8 = undefined;
    try testing.expectError(error.WriteOnly, pipe.read(&buf));

    // 写入数据
    try pipe.write(expected_data);

    // close 验证哈希并 rename
    pipe.close();

    // 验证文件已创建且内容正确
    const file = try std.Io.Dir.cwd().openFile(io, test_path, .{});
    defer file.close(io);
    var content: [64]u8 = undefined;
    const n = try file.readStreaming(io, &.{content[0..]});
    try testing.expectEqualStrings(expected_data, content[0..n]);
}

test "dpipe_file writeFile hash mismatch" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const test_path = "/tmp/utmm-dpipe-test-mismatch.txt";

    // 使用错误的哈希
    const wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000";

    const pipe = try writeFile(testing.allocator, io, test_path, wrong_hash);

    // 写入数据
    try pipe.write("some data");

    // close 时发现哈希不匹配 — 应删除 temp 文件，不创建目标文件
    pipe.close();

    // 验证目标文件不存在
    const result = std.Io.Dir.cwd().openFile(io, test_path, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "dpipe_file writeFile without hash" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const test_path = "/tmp/utmm-dpipe-test-nohash.txt";
    defer std.Io.Dir.cwd().deleteFile(io, test_path) catch {};

    // 空哈希字符串 = 跳过验证
    const pipe = try writeFile(testing.allocator, io, test_path, "");

    const data = "no verification needed";
    try pipe.write(data);
    pipe.close();

    // 验证文件已创建
    const file = try std.Io.Dir.cwd().openFile(io, test_path, .{});
    defer file.close(io);
    var content: [64]u8 = undefined;
    const n = try file.readStreaming(io, &.{content[0..]});
    try testing.expectEqualStrings(data, content[0..n]);
}
