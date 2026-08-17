//! MCP tool handler core logic — extracted from ipc.zig server-side handlers.
//!
//! These functions contain the "real work" previously embedded in IPC handlers:
//! connect to Guest, execute commands, transfer files, build JSON responses.
//! By extracting them here, both HTTP MCP (mcp_http.zig + mcp.zig) and CLI
//! management commands (ipc.zig) share the same implementation — zero duplication.
//!
//! No IPC dependency. All functions operate on Host daemon state directly:
//! GuestTable, lsa.Mesh, protocol primitives.

const std = @import("std");
const builtin = @import("builtin");
const host_mod = @import("host.zig");
const ptcl = @import("protocol.zig");
const tcp = @import("tcp.zig");
const lsa = @import("lsa.zig");
const socks5 = @import("socks5.zig");

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers (shared by getGuestListJson + pingGuest)
// ═══════════════════════════════════════════════════════════════════════════

/// Build JSON guest list string from GuestTable. Caller owns returned memory.
pub fn getGuestListJson(gpa: std.mem.Allocator, state: *host_mod.GuestTable) ![]const u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(gpa);

    try json.appendSlice(gpa, "[");
    var first = true;
    for (state.guests.items) |g| {
        if (!first) try json.appendSlice(gpa, ",");
        first = false;
        try json.print(gpa, "{{\"hostname\":\"{s}\",\"role\":\"{s}\",\"target\":\"{s}\",\"ip\":\"{s}\",\"mac\":\"{s}\",\"version\":\"{s}\",\"shell\":\"{s}\",\"conpty\":\"{s}\",\"status\":\"{s}\",\"last_seen\":{d}}}", .{
            g.hostname, g.role, g.target, g.ip, g.mac, g.version, g.shell, g.conpty, g.status, g.last_seen,
        });
    }
    try json.appendSlice(gpa, "]");

    return json.toOwnedSlice(gpa);
}

// ═══════════════════════════════════════════════════════════════════════════
// Exec
// ═══════════════════════════════════════════════════════════════════════════

pub const ExecResult = struct {
    output: []const u8,
    exit_code: i32,

    pub fn deinit(self: *ExecResult, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
    }
};

/// execOnGuest 的收集器上下文：把流式输出累积到内存。
const OutputCollector = struct {
    gpa: std.mem.Allocator,
    output: std.ArrayList(u8),

    fn init(gpa: std.mem.Allocator) OutputCollector {
        return .{ .gpa = gpa, .output = std.ArrayList(u8).empty };
    }

    fn deinit(self: *OutputCollector) void {
        self.output.deinit(self.gpa);
    }

    fn onOutput(ctx: *anyopaque, data: []const u8) void {
        const self: *OutputCollector = @ptrCast(@alignCast(ctx));
        self.output.appendSlice(self.gpa, data) catch @panic("execOnGuest collector OOM");
    }
};

/// 流式执行 Guest 命令：每收到一块 pty_exec_output 立即回调 on_output。
/// 返回 exit_code；连接在 pty_exec_done 前关闭时返回 -1（已收到的输出仍经回调流出）。
pub fn execOnGuestStream(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    vm: []const u8,
    command: []const u8,
    on_output: *const fn (ctx: *anyopaque, data: []const u8) void,
    ctx: *anyopaque,
) !i32 {
    // Per-command TCP connection (with ARP recovery)
    var tcp_conn = try host_mod.connectGuest(io, gpa, state, vm);
    defer tcp_conn.deinit();

    // Look up guest for shell (needed for buildCmdWithMarker)
    const guest = state.findByHostname(vm) orelse return error.GuestNotFound;
    defer state.freeEntry(guest);

    // Generate cmd_id
    const cmd_id = try std.fmt.allocPrint(gpa, "exec_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(cmd_id);

    // Build command with marker
    const cmd_with_marker = try ptcl.buildCmdWithMarker(gpa, guest.shell, command);
    defer gpa.free(cmd_with_marker);

    // Build and send pty_exec_input frame
    const frame = try ptcl.buildPtyExecInput(gpa, cmd_id, cmd_with_marker);
    defer gpa.free(frame);
    try tcp_conn.sendAndFlush(frame, 0);

    std.log.info("[mcp-handler-exec] sent {s} to {s}", .{ cmd_id, vm });

    // Receive loop: stream pty_exec_output via callback, return on pty_exec_done
    var rbuf: [65536]u8 = undefined;
    var exit_code: i32 = 0;
    var got_done = false;

    while (true) {
        const nr = tcp_conn.recv(&rbuf) catch |err| {
            if (err == error.ConnectionClosed) break;
            // 流式分块后单帧最大约 4KB+6B（Guest 端已分块），BufferTooSmall 不应再出现。
            // 一旦出现即表示协议不变量被破坏，属于设计上不该发生的意外状态，立即 panic 暴露。
            if (err == error.BufferTooSmall) {
                @panic("exec recv BufferTooSmall: frame exceeds 64KB receive buffer after streaming chunking");
            }
            @panic("exec recv unexpected error");
        };
        if (nr == 0) break;

        const msg_type: ptcl.MsgType = @enumFromInt(rbuf[0]);

        switch (msg_type) {
            .pty_exec_output => {
                // Parse: type + cmd_id(null-term) + data_blob(4-byte BE len)
                var mpos: usize = 1;
                _ = readString(rbuf[0..nr], &mpos); // skip cmd_id
                const data = readBlob(rbuf[0..nr], &mpos) orelse continue;
                if (data.len > 0) {
                    on_output(ctx, data);
                }
            },
            .pty_exec_done => {
                var mpos: usize = 1;
                _ = readString(rbuf[0..nr], &mpos); // skip cmd_id
                exit_code = readI32(rbuf[0..nr], &mpos) orelse @as(i32, -1);
                got_done = true;
                std.log.info("[mcp-handler-exec] done {s} exit={d}", .{ cmd_id, exit_code });
                break;
            },
            else => continue,
        }
    }

    return if (got_done) exit_code else -1;
}

/// Execute a command on a guest. Returns accumulated output + exit code.
/// Caller owns ExecResult.output (free with ExecResult.deinit).
pub fn execOnGuest(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    vm: []const u8,
    command: []const u8,
) !ExecResult {
    var collector = OutputCollector.init(gpa);
    defer collector.deinit();
    const exit_code = try execOnGuestStream(io, gpa, state, vm, command, OutputCollector.onOutput, &collector);
    return ExecResult{
        .output = try collector.output.toOwnedSlice(gpa),
        .exit_code = exit_code,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Ping
// ═══════════════════════════════════════════════════════════════════════════

/// Ping a guest via mesh. Returns JSON string: {"hostname":"...","mac":"...","rtt_ms":N}
/// Caller owns returned memory.
pub fn pingGuest(
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    mesh_ptr: ?*anyopaque,
    vm: []const u8,
) ![]const u8 {
    const mesh = @as(*lsa.Mesh, @ptrCast(@alignCast(mesh_ptr orelse return error.NoMeshState)));

    // Find guest mesh_mac
    const node_id: ?[6]u8 = blk: {
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, vm)) {
                break :blk g.mesh_mac;
            }
        }
        break :blk null;
    };

    const nid = node_id orelse return error.GuestNotFound;

    // Ping via mesh
    const rtt = mesh.pingAndWait(nid);
    const rtt_ms = rtt orelse 0;

    var mac_buf: [18]u8 = undefined;
    const mac_str = lsa.formatNodeIdBuf(nid, &mac_buf);

    return std.fmt.allocPrint(gpa, "{{\"hostname\":\"{s}\",\"mac\":\"{s}\",\"rtt_ms\":{d}}}", .{ vm, mac_str, rtt_ms });
}

// ═══════════════════════════════════════════════════════════════════════════
// Upload
// ═══════════════════════════════════════════════════════════════════════════

/// Upload a file to a guest. Opens local_path, computes SHA256, streams to guest
/// via per-command TCP connection. Returns error on failure.
pub fn uploadToGuest(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    vm: []const u8,
    local_path: []const u8,
    remote_path: []const u8,
) !void {
    // 文件 I/O 必须使用独立 Threaded Io — ctx.io 是 zio 事件循环 Io，
    // 不支持在线程池线程中执行文件系统操作（epoll 不支持，kqueue 非线程安全）。
    // 与 handleVmSshpass 一致的模式。
    var file_threaded = std.Io.Threaded.init(gpa, .{});
    const file_io = file_threaded.io();

    // Open local file and compute SHA256
    const local_file = std.Io.Dir.cwd().openFile(file_io, local_path, .{}) catch |err| {
        std.log.err("[mcp-handler-upload] open {s}: {}", .{ local_path, err });
        return error.FileOpenFailed;
    };
    defer local_file.close(file_io);

    const file_stat = local_file.stat(file_io) catch return error.FileStatFailed;
    const file_size: u32 = @intCast(file_stat.size);

    // Compute SHA256 via positional read (doesn't change seek position)
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var hash_buf: [32768]u8 = undefined;
    var pos: u64 = 0;
    while (true) {
        const nr = local_file.readPositional(file_io, &.{&hash_buf}, pos) catch return error.FileReadFailed;
        if (nr == 0) break;
        sha.update(hash_buf[0..nr]);
        pos += nr;
    }
    var file_hash: [32]u8 = undefined;
    sha.final(&file_hash);

    // Format hash as hex string
    var hash_hex_buf: [64]u8 = undefined;
    for (&file_hash, 0..) |b, i| {
        hash_hex_buf[i * 2] = "0123456789abcdef"[b >> 4];
        hash_hex_buf[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const hash_hex = hash_hex_buf[0..64];

    // Per-command TCP connection (with ARP recovery)
    std.log.info("[mcp-handler-upload] connecting to vm='{s}' path='{s}'", .{ vm, remote_path });
    var tcp_conn = host_mod.connectGuest(io, gpa, state, vm) catch |err| {
        std.log.err("[mcp-handler-upload] TCP connect to {s} failed: {}", .{ vm, err });
        return err;
    };
    defer tcp_conn.deinit();

    // Generate cmd_id
    const cmd_id = try std.fmt.allocPrint(gpa, "upload_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(cmd_id);

    // Send upload_cmd frame (framed)
    const up_cmd = try ptcl.buildUploadCmd(gpa, cmd_id, remote_path, file_size, hash_hex);
    defer gpa.free(up_cmd);
    try tcp_conn.sendAndFlush(up_cmd, 0);

    // Stream file bytes via positional read (starts from offset 0 again)
    var file_rbuf: [65536]u8 = undefined;
    var total_sent: u32 = 0;
    pos = 0;
    while (total_sent < file_size) {
        const to_read: usize = @min(file_rbuf.len, file_size - total_sent);
        const n = local_file.readPositional(file_io, &.{file_rbuf[0..to_read]}, pos) catch {
            std.log.err("[mcp-handler-upload] local read failed", .{});
            return error.FileReadFailed;
        };
        if (n == 0) break;

        // Track position for next read
        pos += n;
        total_sent += @intCast(n);

        // Write n bytes to TCP socket with retry on short writes.
        var written: usize = 0;
        while (written < n) {
            const w = tcp.sockWrite(tcp_conn.fd, file_rbuf[written..n].ptr, n - written);
            if (w < 0) {
                std.log.err("[mcp-handler-upload] sockWrite failed: error={d}", .{w});
                return error.WriteFailed;
            }
            if (w == 0) {
                std.log.err("[mcp-handler-upload] sockWrite returned 0 (connection closed)", .{});
                return error.WriteFailed;
            }
            written += @intCast(w);
        }
    }

    // Receive upload_result frame (framed)
    const nr = tcp_conn.recv(&file_rbuf) catch |err| {
        std.log.err("[mcp-handler-upload] recv upload_result: {}", .{err});
        return error.UploadResultFailed;
    };
    if (nr > 0 and file_rbuf[0] == @intFromEnum(ptcl.MsgType.upload_result)) {
        var mpos: usize = 1;
        _ = readString(file_rbuf[0..nr], &mpos); // skip cmd_id
        const exit_code = readI32(file_rbuf[0..nr], &mpos) orelse @as(i32, -1);
        if (exit_code != 0) {
            std.log.err("[mcp-handler-upload] upload failed: exit={d}", .{exit_code});
            return error.UploadFailed;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Download
// ═══════════════════════════════════════════════════════════════════════════

/// Download a file from a guest, writing to the provided writer.
/// Returns total bytes written. Caller manages writer lifecycle.
pub fn downloadFromGuest(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    vm: []const u8,
    remote_path: []const u8,
    file_writer: anytype,
) !u32 {
    // Per-command TCP connection (with ARP recovery)
    var tcp_conn = host_mod.connectGuest(io, gpa, state, vm) catch |err| {
        std.log.err("[mcp-handler-download] TCP connect to {s} failed: {}", .{ vm, err });
        return err;
    };
    defer tcp_conn.deinit();

    // Generate cmd_id
    const cmd_id = try std.fmt.allocPrint(gpa, "download_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(cmd_id);

    // Send download_cmd frame (framed)
    const dl_cmd = try ptcl.buildDownloadCmd(gpa, cmd_id, remote_path);
    defer gpa.free(dl_cmd);
    try tcp_conn.sendAndFlush(dl_cmd, 0);

    std.log.info("[mcp-handler-download] requested {s} from {s}", .{ cmd_id, vm });

    // 先收 download_result 帧（cmd_id + file_size + sha256_hex），确定期望长度与哈希。
    var rbuf: [65536]u8 = undefined;
    const result_frame_nr = tcp_conn.recv(&rbuf) catch |err| {
        std.log.err("[mcp-handler-download] recv download_result: {}", .{err});
        return error.DownloadResultFailed;
    };
    if (result_frame_nr == 0 or rbuf[0] != @intFromEnum(ptcl.MsgType.download_result)) {
        std.log.err("[mcp-handler-download] missing download_result frame", .{});
        return error.DownloadResultFailed;
    }
    const result = ptcl.parseDownloadResult(rbuf[0..result_frame_nr][1..]) orelse {
        std.log.err("[mcp-handler-download] parseDownloadResult failed", .{});
        return error.DownloadResultFailed;
    };
    const expected_size: u32 = result.file_size;

    // 增量 SHA256 校验：边收原始字节边写文件，读满 file_size 即停（不再依赖 EOF）。
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes: u32 = 0;
    while (total_bytes < expected_size) {
        const to_read: usize = @min(rbuf.len, expected_size - total_bytes);
        const nr = tcp.sockRead(tcp_conn.fd, rbuf[0..].ptr, to_read);
        if (nr <= 0) {
            // 连接提前 EOF：数据读满 size 之前连接关闭 = 错误。
            std.log.err("[mcp-handler-download] premature EOF: got {d}/{d} bytes", .{ total_bytes, expected_size });
            return error.TruncatedDownload;
        }
        const data = rbuf[0..@intCast(nr)];
        sha.update(data);
        file_writer.writeAll(data) catch |err| {
            std.log.err("[mcp-handler-download] writer error: {}", .{err});
            return error.WriteFailed;
        };
        total_bytes += @intCast(nr);
    }

    // 比对哈希，不匹配报错。
    var actual_hash: [32]u8 = undefined;
    sha.final(&actual_hash);
    var actual_hex_buf: [64]u8 = undefined;
    for (&actual_hash, 0..) |b, i| {
        actual_hex_buf[i * 2] = "0123456789abcdef"[b >> 4];
        actual_hex_buf[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    if (!std.mem.eql(u8, actual_hex_buf[0..], result.sha256_hex)) {
        std.log.err("[mcp-handler-download] hash mismatch: expected={s} actual={s}", .{ result.sha256_hex, actual_hex_buf[0..] });
        return error.HashMismatch;
    }

    std.log.info("[mcp-handler-download] done {s} bytes={d}", .{ cmd_id, total_bytes });
    return total_bytes;
}

// ═══════════════════════════════════════════════════════════════════════════
// Protocol parsing helpers (mirrored from ipc.zig)
// ═══════════════════════════════════════════════════════════════════════════

fn readString(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    const len = std.mem.indexOfScalarPos(u8, data, start, 0) orelse return null;
    pos.* = len + 1;
    return data[start..len];
}

fn readBlob(data: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + 4 > data.len) return null;
    const len = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    if (pos.* + len > data.len) return null;
    const blob = data[pos.*..][0..len];
    pos.* += len;
    return blob;
}

fn readI32(data: []const u8, pos: *usize) ?i32 {
    if (pos.* + 4 > data.len) return null;
    const val = std.mem.readInt(i32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return val;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "readString" {
    const data: [5]u8 = .{ 'h', 'i', 0, 'x', 'y' };
    var pos: usize = 0;
    const s = readString(&data, &pos);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("hi", s.?);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "readString: null terminator at start" {
    const data: [3]u8 = .{ 0, 'a', 'b' };
    var pos: usize = 0;
    const s = readString(&data, &pos);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("", s.?);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readBlob" {
    var data: [10]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], @as(u32, 3), .big);
    data[4] = 'f';
    data[5] = 'o';
    data[6] = 'o';
    data[7] = 0;
    data[8] = 0;
    data[9] = 0;
    var pos: usize = 0;
    const blob = readBlob(&data, &pos);
    try std.testing.expect(blob != null);
    try std.testing.expectEqualStrings("foo", blob.?);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "readI32" {
    var data: [4]u8 = undefined;
    std.mem.writeInt(i32, &data, @as(i32, -42), .big);
    var pos: usize = 0;
    const val = readI32(&data, &pos);
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i32, -42), val.?);
    try std.testing.expectEqual(@as(usize, 4), pos);
}
