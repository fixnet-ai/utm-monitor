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

/// Execute a command on a guest. Returns accumulated output + exit code.
/// Caller owns ExecResult.output (free with ExecResult.deinit).
pub fn execOnGuest(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *host_mod.GuestTable,
    vm: []const u8,
    command: []const u8,
) !ExecResult {
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

    // Receive loop: accumulate pty_exec_output, return on pty_exec_done
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var rbuf: [65536]u8 = undefined;
    var exit_code: i32 = 0;
    var got_done = false;

    while (true) {
        const nr = tcp_conn.recv(&rbuf) catch |err| {
            if (err == error.ConnectionClosed) break;
            std.log.err("[mcp-handler-exec] recv error: {}", .{err});
            break;
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
                    try output.appendSlice(gpa, data);
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

    return ExecResult{
        .output = if (got_done) try output.toOwnedSlice(gpa) else blk: {
            // Connection closed without pty_exec_done — return -1 exit code
            exit_code = -1;
            break :blk try output.toOwnedSlice(gpa);
        },
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
    // Open local file and compute SHA256
    const local_file = std.Io.Dir.cwd().openFile(io, local_path, .{}) catch |err| {
        std.log.err("[mcp-handler-upload] open {s}: {}", .{ local_path, err });
        return error.FileOpenFailed;
    };
    defer local_file.close(io);

    const file_stat = local_file.stat(io) catch return error.FileStatFailed;
    const file_size: u32 = @intCast(file_stat.size);

    // Compute SHA256 via positional read (doesn't change seek position)
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var hash_buf: [32768]u8 = undefined;
    var pos: u64 = 0;
    while (true) {
        const nr = local_file.readPositional(io, &.{&hash_buf}, pos) catch return error.FileReadFailed;
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
        const n = local_file.readPositional(io, &.{file_rbuf[0..to_read]}, pos) catch {
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

    // Receive raw file bytes (unframed — guest sends raw bytes after download_cmd)
    var rbuf: [65536]u8 = undefined;
    var total_bytes: u32 = 0;
    while (true) {
        const nr = tcp.sockRead(tcp_conn.fd, rbuf[0..].ptr, rbuf.len);
        if (nr <= 0) break; // EOF or error

        const data = rbuf[0..@intCast(nr)];
        file_writer.writeAll(data) catch |err| {
            std.log.err("[mcp-handler-download] writer error: {}", .{err});
            return error.WriteFailed;
        };
        total_bytes += @intCast(nr);
    }

    std.log.info("[mcp-handler-download] done {s}", .{cmd_id});
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
