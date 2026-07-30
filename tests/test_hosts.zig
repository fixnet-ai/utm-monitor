//! /etc/hosts 文件同步集成测试
//!
//! 测试 lsa.updateHosts() 的核心功能：标记块写入、范围替换、原子写入、
//! 标记块外内容保留、空条目处理、多条目生成。这些测试验证 Phase 19
//! 合并后的 hosts 同步实现。

const std = @import("std");
const common = @import("common");
const testlib = @import("testlib");
const lsa = testlib.lsa;
const protocol = testlib.protocol;

const TestRunner = common.TestRunner;
const HOSTS_MARKER_BEGIN = protocol.HOSTS_MARKER_BEGIN;
const HOSTS_MARKER_END = protocol.HOSTS_MARKER_END;

/// Helper: build a test Io (single-threaded) for lsa.updateHosts calls.
fn testIo() std.Io {
    const ti = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return ti.threaded.io();
}

/// Helper: read file content, return null if doesn't exist.
fn readTestFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer file.close(io);
    const file_size = try file.length(io);
    const buf = try alloc.alloc(u8, @intCast(file_size));
    errdefer alloc.free(buf);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

/// Helper: write raw content to a file (overwrites).
fn writeTestFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    _ = try writer.interface.writeAll(content);
    try writer.interface.flush();
}

/// Helper: delete a file (ignore errors).
fn deleteTestFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Helper: assert failure in a test case (since TestCase has no fail method).
fn failCase(c: *common.TestCase, comptime fmt: []const u8, args: anytype) void {
    c.expect(false, fmt, args);
}

pub fn test_hosts(io: std.Io, alloc: std.mem.Allocator, runner: *TestRunner) !void {
    _ = io;

    // Use "./" prefix so dirname returns "." not null (updateHosts rename relies on this)
    const test_file = "./.test-hosts-sync.tmp";
    const test_io = testIo();

    // Cleanup from any previous failed run
    deleteTestFile(test_io, test_file);
    const tmp_file = try std.mem.concat(alloc, u8, &.{ test_file, ".tmp" });
    defer alloc.free(tmp_file);
    deleteTestFile(test_io, tmp_file);

    // ── 场景 1: 基本条目生成（新文件） ─────────────────────────────────────────

    {
        var c = runner.case("hosts: basic entries, new file");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.64.6", .name = "linuxvm" },
            .{ .ip = "192.168.65.4", .name = "macvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, HOSTS_MARKER_BEGIN) != null, "contains begin marker");
        c.expectTrue(std.mem.indexOf(u8, content, HOSTS_MARKER_END) != null, "contains end marker");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6  linuxvm") != null, "contains linuxvm entry");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.65.4  macvm") != null, "contains macvm entry");
        c.expectTrue(!std.mem.eql(u8, content, ""), "file is not empty");
    }

    // ── 场景 2: gateway 条目 ───────────────────────────────────────────────────

    {
        var c = runner.case("hosts: gateway entry");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.64.1", .name = "gateway" },
            .{ .ip = "192.168.64.6", .name = "linuxvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.1  gateway") != null, "contains gateway entry");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6  linuxvm") != null, "contains linuxvm entry");
    }

    // ── 场景 3: 标记块范围替换（更新已有条目，不追加） ─────────────────────────

    {
        var c = runner.case("hosts: marker block replacement (no append)");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        // Write initial hosts file with marker block
        const initial =
            \\127.0.0.1  localhost
            \\# UTM-MONITOR-BEGIN
            \\192.168.64.6  linuxvm
            \\# UTM-MONITOR-END
            \\
        ;
        try writeTestFile(test_io, test_file, initial);

        // Update with different entries — should replace, not append
        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.65.4", .name = "macvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, "127.0.0.1  localhost") != null, "localhost preserved");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.65.4  macvm") != null, "macvm entry exists");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6  linuxvm") == null, "old linuxvm entry removed");
        // Should only have ONE marker block
        c.expectEqual(
            @as(usize, 1),
            countOccurrences(content, HOSTS_MARKER_BEGIN),
            "exactly one begin marker",
        );
        c.expectEqual(
            @as(usize, 1),
            countOccurrences(content, HOSTS_MARKER_END),
            "exactly one end marker",
        );
    }

    // ── 场景 4: 空条目列表 ─────────────────────────────────────────────────────

    {
        var c = runner.case("hosts: empty entries list");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        // Write initial hosts file with existing content
        const initial =
            \\127.0.0.1  localhost
            \\# UTM-MONITOR-BEGIN
            \\192.168.64.6  linuxvm
            \\# UTM-MONITOR-END
            \\
        ;
        try writeTestFile(test_io, test_file, initial);

        // Update with empty entries — markers should remain but block is empty
        const entries = [_]lsa.HostEntry{};
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, "127.0.0.1  localhost") != null, "localhost preserved");
        c.expectTrue(std.mem.indexOf(u8, content, HOSTS_MARKER_BEGIN) != null, "begin marker exists");
        c.expectTrue(std.mem.indexOf(u8, content, HOSTS_MARKER_END) != null, "end marker exists");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6") == null, "old linuxvm removed");
    }

    // ── 场景 5: 标记块外内容保留 ───────────────────────────────────────────────

    {
        var c = runner.case("hosts: content outside marker block preserved");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        const prelude =
            \\# Custom DNS entries
            \\10.0.0.1  my-internal-server.local
            \\10.0.0.2  another-host.local
            \\
        ;

        const initial = try std.mem.concat(alloc, u8, &.{
            prelude,
            HOSTS_MARKER_BEGIN, "\n",
            "192.168.64.6  linuxvm\n",
            HOSTS_MARKER_END, "\n",
        });
        defer alloc.free(initial);
        try writeTestFile(test_io, test_file, initial);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.65.4", .name = "macvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        // Check pre-marker content preserved
        c.expectTrue(std.mem.indexOf(u8, content, "10.0.0.1  my-internal-server.local") != null, "custom entry 1 preserved");
        c.expectTrue(std.mem.indexOf(u8, content, "10.0.0.2  another-host.local") != null, "custom entry 2 preserved");
        // Check new entry in marker block
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.65.4  macvm") != null, "macvm entry exists");
        // Check old entry removed
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6") == null, "old linuxvm removed");
    }

    // ── 场景 6: 多条目生成（含 Windows 主机名） ──────────────────────────────

    {
        var c = runner.case("hosts: multiple entries with mixed hostnames");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.64.6", .name = "linuxvm" },
            .{ .ip = "192.168.65.4", .name = "macvm" },
            .{ .ip = "192.168.64.3", .name = "windowsvm" },
            .{ .ip = "192.168.64.1", .name = "gateway" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6  linuxvm") != null, "linuxvm");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.65.4  macvm") != null, "macvm");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.3  windowsvm") != null, "windowsvm");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.1  gateway") != null, "gateway");
        c.expectEqual(@as(usize, 1), countOccurrences(content, HOSTS_MARKER_BEGIN), "exactly one begin marker");
    }

    // ── 场景 7: 原子写入（.tmp 文件不留存） ──────────────────────────────────

    {
        var c = runner.case("hosts: atomic write, no tmp file left behind");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);
        defer deleteTestFile(test_io, tmp_file);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.64.6", .name = "linuxvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        // Target file should exist
        const verify_content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "target file should exist: {}", .{err});
            return;
        };
        alloc.free(verify_content);

        // Tmp file should NOT exist
        const tmp_exists = blk: {
            const f = std.Io.Dir.cwd().openFile(test_io, tmp_file, .{}) catch break :blk false;
            f.close(test_io);
            break :blk true;
        };
        c.expectTrue(!tmp_exists, "tmp file should not exist after atomic rename");
    }

    // ── 场景 8: 已存在文件无标记块时追加 ─────────────────────────────────────

    {
        var c = runner.case("hosts: append marker block to file without existing markers");
        defer c.deinit();
        defer deleteTestFile(test_io, test_file);

        const existing =
            \\127.0.0.1  localhost
            \\::1  localhost
            \\
        ;
        try writeTestFile(test_io, test_file, existing);

        const entries = [_]lsa.HostEntry{
            .{ .ip = "192.168.64.6", .name = "linuxvm" },
        };
        lsa.updateHosts(test_io, alloc, test_file, &entries) catch |err| {
            failCase(&c, "updateHosts failed: {}", .{err});
            return;
        };

        const content = readTestFile(test_io, alloc, test_file) catch |err| {
            failCase(&c, "read file failed: {}", .{err});
            return;
        };
        defer alloc.free(content);

        c.expectTrue(std.mem.indexOf(u8, content, "127.0.0.1  localhost") != null, "localhost preserved");
        c.expectTrue(std.mem.indexOf(u8, content, HOSTS_MARKER_BEGIN) != null, "begin marker appended");
        c.expectTrue(std.mem.indexOf(u8, content, "192.168.64.6  linuxvm") != null, "linuxvm entry");
        // Original content should appear BEFORE the marker block
        const maybe_marker = std.mem.indexOf(u8, content, HOSTS_MARKER_BEGIN);
        if (maybe_marker) |marker_pos| {
            const localhost_pos = std.mem.indexOf(u8, content, "127.0.0.1");
            c.expectTrue(localhost_pos != null and localhost_pos.? < marker_pos, "original content before marker block");
        } else {
            failCase(&c, "marker not found", .{});
        }
    }
}

/// Count occurrences of a substring in haystack.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |p| {
        count += 1;
        pos = p + needle.len;
    }
    return count;
}
