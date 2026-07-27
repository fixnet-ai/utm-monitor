//! IPC module — Unix domain socket (POSIX) / Named pipe (Windows) transport
//! for CLI/MCP → Host daemon communication.
//!
//! The protocol is a lightweight binary framing scheme: 1-byte type + type-specific
//! payload, connection-per-request.
//! String fields: null-terminated. Binary fields: 4-byte BE length prefix + data.
//! Integer fields: 4-byte BE.
//!
//! ## Connection lifecycle
//!
//! Each CLI invocation opens a socket, sends one request, reads the response(s),
//! then closes. The server accepts connections in a loop and dispatches to shared
//! HostState handlers.
//!
//! ## Platform transport
//!
//! | Platform | Transport | Path |
//! |----------|-----------|------|
//! | macOS/Linux | Unix domain socket (SOCK_STREAM) | /var/run/utmm.sock |
//! | Windows     | Named pipe (PIPE_TYPE_BYTE)    | \\.\pipe\utmm     |

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════
// Windows API externs (removed from std.os.windows in Zig 0.16.0)
// ═══════════════════════════════════════════════════════════════════════════

const windows = struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = std.os.windows.DWORD;
    const LPVOID = ?*anyopaque;
    const LPCSTR = [*:0]const u8;
    const BOOL = i32;
    const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
    const CloseHandle = std.os.windows.CloseHandle;
    const GetLastError = std.os.windows.GetLastError;

    // Pipe open modes
    const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
    const PIPE_TYPE_BYTE: DWORD = 0x00000000;
    const PIPE_READMODE_BYTE: DWORD = 0x00000000;
    const PIPE_WAIT: DWORD = 0x00000000;
    const PIPE_UNLIMITED_INSTANCES: DWORD = 255;

    // File access
    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const OPEN_EXISTING: DWORD = 3;

    extern "kernel32" fn CreateNamedPipeA(
        lpName: LPCSTR,
        dwOpenMode: DWORD,
        dwPipeMode: DWORD,
        nMaxInstances: DWORD,
        nOutBufferSize: DWORD,
        nInBufferSize: DWORD,
        nDefaultTimeOut: DWORD,
        lpSecurityAttributes: LPVOID,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn ConnectNamedPipe(
        hNamedPipe: HANDLE,
        lpOverlapped: LPVOID,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateFileA(
        lpFileName: LPCSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: LPVOID,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: *DWORD,
        lpOverlapped: LPVOID,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: LPVOID,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn SetNamedPipeHandleState(
        hNamedPipe: HANDLE,
        lpMode: *DWORD,
        lpMaxCollectionCount: LPVOID,
        lpCollectDataTimeout: LPVOID,
    ) callconv(.winapi) BOOL;
};

// ═══════════════════════════════════════════════════════════════════════════
// Message types
// ═══════════════════════════════════════════════════════════════════════════

/// IPC request types (CLI/MCP → Host daemon)
pub const Request = enum(u8) {
    status = 0x01,
    exec = 0x02,
    ping = 0x03,
    upload = 0x04,
    download = 0x05,
    version = 0x06,
};

/// IPC response types (Host daemon → CLI/MCP)
pub const Response = enum(u8) {
    status = 0x10,
    exec_data = 0x11,
    exec_done = 0x12,
    ping = 0x13,
    ok = 0x14,
    download_data = 0x15,
    download_done = 0x16,
    version = 0x17,
    err = 0x7F,
};

// ═══════════════════════════════════════════════════════════════════════════
// Serialization helpers (duplicated from tunproto.zig to keep IPC isolated)
// ═══════════════════════════════════════════════════════════════════════════

pub const MAX_BLOB_LEN: u32 = 1024 * 1024; // 1 MB
pub const MAX_STRING_LEN: u32 = 8192; // 8 KB

pub fn writeString(buf: *std.ArrayList(u8), s: []const u8) !void {
    buf.appendSliceAssumeCapacity(s);
    buf.appendAssumeCapacity(0);
}

pub fn writeBlob(buf: *std.ArrayList(u8), data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    buf.appendSliceAssumeCapacity(&len_buf);
    buf.appendSliceAssumeCapacity(data);
}

pub fn writeI32(buf: *std.ArrayList(u8), v: i32) !void {
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &int_buf, v, .big);
    buf.appendSliceAssumeCapacity(&int_buf);
}

pub fn writeU32(buf: *std.ArrayList(u8), v: u32) !void {
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &int_buf, v, .big);
    buf.appendSliceAssumeCapacity(&int_buf);
}

pub fn readString(data: []const u8, pos: *usize) ?[]const u8 {
    return readStringMax(data, pos, MAX_STRING_LEN);
}

pub fn readStringMax(data: []const u8, pos: *usize, max_len: u32) ?[]const u8 {
    const start = pos.*;
    const remaining = data[start..];
    const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return null;
    if (end > max_len) return null;
    pos.* = start + end + 1;
    return remaining[0..end];
}

pub fn readBlob(data: []const u8, pos: *usize) ?[]const u8 {
    return readBlobMax(data, pos, MAX_BLOB_LEN);
}

pub fn readBlobMax(data: []const u8, pos: *usize, max_len: u32) ?[]const u8 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    const len = std.mem.readInt(u32, data[start..][0..4], .big);
    if (len > max_len) return null;
    const blob_start = start + 4;
    if (blob_start + len > data.len) return null;
    pos.* = blob_start + len;
    return data[blob_start..][0..len];
}

pub fn readI32(data: []const u8, pos: *usize) ?i32 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    pos.* = start + 4;
    return std.mem.readInt(i32, data[start..][0..4], .big);
}

pub fn readU32(data: []const u8, pos: *usize) ?u32 {
    const start = pos.*;
    if (start + 4 > data.len) return null;
    pos.* = start + 4;
    return std.mem.readInt(u32, data[start..][0..4], .big);
}

/// Read exactly one byte from the buffer. Returns null if empty.
pub fn readByte(data: []const u8, pos: *usize) ?u8 {
    if (pos.* >= data.len) return null;
    const b = data[pos.*];
    pos.* += 1;
    return b;
}

// ═══════════════════════════════════════════════════════════════════════════
// Platform transport
// ═══════════════════════════════════════════════════════════════════════════

/// Well-known socket path for the current platform.
pub fn socketPath() []const u8 {
    if (builtin.os.tag == .windows) {
        return "\\\\.\\pipe\\utmm";
    }
    return "/var/run/utmm.sock";
}

/// Null-terminated path for C API calls (unlink, chmod, CreateNamedPipeA, etc.).
/// String literals coerce directly to `[*:0]const u8` — no @ptrCast needed.
fn socketPathZ() [*:0]const u8 {
    if (builtin.os.tag == .windows) {
        return "\\\\.\\pipe\\utmm";
    }
    return "/var/run/utmm.sock";
}

/// POSIX: a connected Unix domain socket, wrapped for reading/writing.
/// Windows: a connected named pipe HANDLE.
pub const Connection = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.socket_t,

    pub fn close(self: Connection) void {
        if (builtin.os.tag == .windows) {
            windows.CloseHandle(self.fd);
        } else {
            _ = std.posix.system.close(self.fd);
        }
    }

    /// Read exactly `len` bytes into `buf`.
    /// Returns the number of bytes read, or an error.
    fn readFull(self: Connection, buf: []u8) !usize {
        _ = &self;
        if (builtin.os.tag == .windows) {
            // Use ReadFile for named pipe
            var nread: windows.DWORD = 0;
            const ok = windows.ReadFile(self.fd, buf.ptr, @intCast(buf.len), &nread, null);
            if (ok == 0) {
                const err = windows.GetLastError();
                if (err == .BROKEN_PIPE or err == .NO_DATA) return error.EndOfStream;
                return error.ReadFailed;
            }
            return nread;
        } else {
            return @intCast(std.posix.system.read(self.fd, buf.ptr, buf.len));
        }
    }

    /// Write all bytes in `buf` to the socket/pipe.
    fn writeAll(self: Connection, buf: []const u8) !void {
        _ = &self;
        if (builtin.os.tag == .windows) {
            var written: windows.DWORD = 0;
            _ = windows.WriteFile(self.fd, buf.ptr, @intCast(buf.len), &written, null);
        } else {
            _ = std.posix.system.write(self.fd, buf.ptr, buf.len);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Server (Host daemon side)
// ═══════════════════════════════════════════════════════════════════════════

/// Start the IPC server accept loop. Runs in its own background thread.
/// Blocks until `shutdown` is set, then closes the listener and returns.
///
/// `io`: caller's Io instance (shared across all Host threads).
/// `gpa`: allocator for connection buffers.
/// `state_ptr`: opaque pointer to state.HostState (avoid circular import).
/// `mesh_ptr`: opaque pointer to mesh.Mesh (for ping handler).
/// `shutdown`: atomic flag — when true, the server exits cleanly.
pub fn startServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    mesh_ptr: *anyopaque,
    shutdown: *std.atomic.Value(bool),
) !void {
    if (builtin.os.tag == .windows) {
        return startServerWindows(io, gpa, state_ptr, mesh_ptr, shutdown);
    }
    return startServerPosix(io, gpa, state_ptr, mesh_ptr, shutdown);
}

fn startServerPosix(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    mesh_ptr: *anyopaque,
    shutdown: *std.atomic.Value(bool),
) !void {
    const path = socketPath();

    // Remove stale socket file from a previous (crashed) run
    _ = std.posix.system.unlink(socketPathZ());

    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.posix.system.close(fd);

    var addr = std.c.sockaddr.un{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    const max_path = addr.path.len - 1;
    if (path.len > max_path) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);

    const addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.un);

    _ = std.posix.system.bind(
        fd,
        @ptrCast(&addr),
        addr_len,
    );

    // Only root (or same user) can connect
    _ = std.posix.system.chmod(socketPathZ(), 0o600);
    _ = std.posix.system.listen(fd, 8);

    std.log.info("[ipc] listening on {s}", .{path});

    // Accept loop
    while (!shutdown.load(.acquire)) {
        var client_addr: std.c.sockaddr = undefined;
        client_addr.family = std.posix.AF.UNIX;
        @memset(&client_addr.data, 0);
        if (builtin.os.tag == .macos or builtin.os.tag == .ios or builtin.os.tag == .watchos or builtin.os.tag == .tvos or builtin.os.tag == .visionos) {
            client_addr.len = @sizeOf(std.c.sockaddr);
        }
        var client_len: std.c.socklen_t = @sizeOf(std.c.sockaddr);
        const client_fd = std.posix.system.accept(fd, &client_addr, &client_len);

        // Check if shutdown was signaled during accept
        if (shutdown.load(.acquire)) {
            if (client_fd >= 0) _ = std.posix.system.close(client_fd);
            break;
        }

        if (client_fd < 0) {
            const err = std.posix.errno(client_fd);
            if (err == .INTR) continue;
            if (err == .AGAIN) continue;
            std.log.err("[ipc] accept failed: {}", .{err});
            continue;
        }

        // Spawn handler thread (detached — connection is short-lived)
        const conn: Connection = .{ .fd = client_fd };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, state_ptr, mesh_ptr, conn }) catch {
            std.log.err("[ipc] thread spawn failed", .{});
            conn.close();
            continue;
        };
        thread.detach();
    }
}

fn startServerWindows(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    mesh_ptr: *anyopaque,
    shutdown: *std.atomic.Value(bool),
) !void {
    // Windows named pipe accept loop: each pipe instance handles one client.
    // We create a pipe, wait for a client, spawn a handler, then create the next pipe.
    while (!shutdown.load(.acquire)) {
        const pipe = windows.CreateNamedPipeA(
            socketPathZ(),
            windows.PIPE_ACCESS_DUPLEX,
            windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE | windows.PIPE_WAIT,
            windows.PIPE_UNLIMITED_INSTANCES,
            65536,
            65536,
            0,
            null,
        );

        if (pipe == windows.INVALID_HANDLE_VALUE) {
            std.log.err("[ipc] CreateNamedPipe failed", .{});
            return error.NamedPipeCreateFailed;
        }

        // Block until a client connects
        const connected = windows.ConnectNamedPipe(pipe, null);
        if (connected == 0) {
            const err = windows.GetLastError();
            if (err != .PIPE_CONNECTED) {
                std.log.err("[ipc] ConnectNamedPipe failed: {}", .{err});
                windows.CloseHandle(pipe);
                continue;
            }
        }

        if (shutdown.load(.acquire)) {
            windows.CloseHandle(pipe);
            break;
        }

        const conn: Connection = .{ .fd = pipe };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, state_ptr, mesh_ptr, conn }) catch {
            std.log.err("[ipc] thread spawn failed", .{});
            conn.close();
            continue;
        };
        thread.detach();
    }
}

/// Handle a single IPC connection. Reads the request, dispatches,
/// writes the response(s), then closes the connection.
fn handleConnection(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    mesh_ptr: *anyopaque,
    conn: Connection,
) void {
    defer conn.close();

    // Read the request type byte
    var type_buf: [1]u8 = undefined;
    _ = conn.readFull( &type_buf) catch return;
    const req_type: Request = @enumFromInt(type_buf[0]);

    // For upload: read header byte-by-byte to avoid consuming file data past the
    // header boundary. The file data follows and is read directly by handleUpload.
    if (req_type == .upload) {
        // Header: vm(NT) + path(NT) + hash(65 bytes incl null) + file_size(4 bytes).
        // Max: 256 + 1024 + 65 + 4 ≈ 1400 bytes. Read byte-by-byte for exact boundary.
        var hdr_buf: [1400]u8 = undefined;
        var hdr_pos: usize = 0;
        while (hdr_pos < hdr_buf.len) {
            const n = conn.readFull(hdr_buf[hdr_pos..hdr_pos+1]) catch break;
            if (n == 0) break;
            hdr_pos += n;
            if (hdr_pos > 70) {
                var pos: usize = 0;
                if (readString(hdr_buf[0..hdr_pos], &pos) == null) continue; // vm
                if (readString(hdr_buf[0..hdr_pos], &pos) == null) continue; // path
                if (readString(hdr_buf[0..hdr_pos], &pos) == null) continue; // hash
                if (pos + 4 <= hdr_pos) break; // got full header, no file data consumed
            }
        }
        if (hdr_pos > 0) {
            handleUpload(io, gpa, state_ptr, conn, hdr_buf[0..hdr_pos]);
        }
        return;
    }

    // For all other request types: read the full payload
    var read_buf: [65536]u8 = undefined;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    while (true) {
        const n = conn.readFull( read_buf[0..]) catch break;
        if (n == 0) break;
        payload.appendSlice(gpa, read_buf[0..n]) catch break;
    }

    switch (req_type) {
        .status => handleStatus(io, gpa, state_ptr, conn, payload.items),
        .exec => handleExec(io, gpa, state_ptr, conn, payload.items),
        .ping => handlePing(io, gpa, state_ptr, mesh_ptr, conn, payload.items),
        .download => handleDownload(io, gpa, state_ptr, conn, payload.items),
        .version => handleVersion(conn),
        .upload => unreachable, // handled above
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Server-side handlers (call into HostState)
// ═══════════════════════════════════════════════════════════════════════════

fn sendError(conn: Connection, msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    var w = std.ArrayList(u8).fromOwnedSlice(&buf);
    w.items.len = 0;
    w.appendAssumeCapacity(@intFromEnum(Response.err));
    writeString(&w, msg) catch return;
    conn.writeAll( w.items) catch {};
}

fn handleStatus(io: std.Io, gpa: std.mem.Allocator, state_ptr: *anyopaque, conn: Connection, _: []const u8) void {
    // state_ptr is *state.HostState — build JSON guest list via its public API
    const state = @as(*@import("state.zig").HostState, @ptrCast(@alignCast(state_ptr)));

    // Lock and collect guest info
    state.mutex.lock(io) catch {
        sendError(conn, "LockFailed");
        return;
    };
    defer state.mutex.unlock(io);

    // Build JSON manually from HostState guest table
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);

    json.appendSlice(gpa, "[") catch return;
    var first = true;
    for (state.guests.items) |g| {
        if (!first) json.appendSlice(gpa, ",") catch return;
        first = false;
        json.print(gpa, "{{\"hostname\":\"{s}\",\"role\":\"{s}\",\"target\":\"{s}\",\"ip\":\"{s}\",\"mac\":\"{s}\",\"version\":\"{s}\",\"shell\":\"{s}\",\"status\":\"{s}\",\"last_seen\":{d}}}", .{
            g.hostname, g.role, g.target, g.ip, g.mac, g.version, g.shell, g.status, g.last_seen,
        }) catch return;
    }
    json.appendSlice(gpa, "]") catch return;

    // Send response: [0x10][4-byte BE len][JSON]
    var response_buf: [4096]u8 = undefined;
    var w = std.ArrayList(u8).fromOwnedSlice(&response_buf);
    w.items.len = 0;
    w.appendAssumeCapacity(@intFromEnum(Response.status));
    writeBlob(&w, json.items) catch return;
    conn.writeAll( w.items) catch {};
}

fn handlePing(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    mesh_ptr: *anyopaque,
    conn: Connection,
    payload: []const u8,
) void {
    _ = gpa;
    _ = mesh_ptr; // Use state.mesh instead (same pattern as mesh handlers)
    var pos: usize = 0;
    const target = readString(payload, &pos) orelse {
        sendError(conn, "InvalidRequest: missing vm");
        return;
    };

    const state = @as(*@import("state.zig").HostState, @ptrCast(@alignCast(state_ptr)));

    // Get mesh pointer from state (same pattern as state.zig handlers)
    const mesh_mod2 = @import("mesh.zig");
    const mesh_ptr2 = state.mesh orelse {
        sendError(conn, "MeshNotAvailable");
        return;
    };
    const mesh = @as(*mesh_mod2.Mesh, @ptrCast(@alignCast(mesh_ptr2)));

    const node_id: ?[6]u8 = blk: {
        state.mutex.lock(io) catch {
            sendError(conn, "LockFailed");
            return;
        };
        defer state.mutex.unlock(io);
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, target)) {
                break :blk g.mesh_mac;
            }
        }
        break :blk null;
    };

    const nid = node_id orelse {
        // Guest not found — return JSON error
        var buf: [256]u8 = undefined;
        var w = std.ArrayList(u8).fromOwnedSlice(&buf);
        w.items.len = 0;
        w.appendAssumeCapacity(@intFromEnum(Response.ping));
        var err_buf: [128]u8 = undefined;
        const err_json = std.fmt.bufPrint(&err_buf, "{{\"error\":\"GuestNotFound\",\"hostname\":\"{s}\"}}", .{target}) catch {
            sendError(conn, "ResponseTooLarge");
            return;
        };
        writeBlob(&w, err_json) catch return;
        conn.writeAll( w.items) catch {};
        return;
    };

    // Ping via mesh (node_id is already [6]u8, no parsing needed)
    const rtt = mesh.pingAndWait(nid);
    const rtt_ms = rtt orelse 0;

    // Build JSON in a SEPARATE buffer from the response buffer
    // (json_buf and response_buf must not alias — appendAssumeCapacity
    //  overwrites buf[0] which would corrupt json if they share memory)
    var mac_buf: [18]u8 = undefined;
    const mac_str = mesh_mod2.formatNodeIdBuf(nid, &mac_buf);
    var json_buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf, "{{\"hostname\":\"{s}\",\"mac\":\"{s}\",\"rtt_ms\":{d}}}", .{ target, mac_str, rtt_ms }) catch {
        sendError(conn, "ResponseTooLarge");
        return;
    };

    var response_buf: [512]u8 = undefined;
    var w = std.ArrayList(u8).fromOwnedSlice(&response_buf);
    w.items.len = 0;
    w.appendAssumeCapacity(@intFromEnum(Response.ping));
    writeBlob(&w, json) catch return;
    conn.writeAll( w.items) catch {};
}

fn handleExec(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    conn: Connection,
    payload: []const u8,
) void {
    var pos: usize = 0;
    const vm = readString(payload, &pos) orelse {
        sendError(conn, "InvalidRequest: missing vm");
        return;
    };
    const command = readString(payload, &pos) orelse {
        sendError(conn, "InvalidRequest: missing command");
        return;
    };

    const state = @as(*@import("state.zig").HostState, @ptrCast(@alignCast(state_ptr)));
    const tunproto = @import("tunproto.zig");

    // Get guest shell type
    const guest_shell = blk: {
        state.mutex.lock(io) catch {
            sendError(conn, "LockFailed");
            return;
        };
        defer state.mutex.unlock(io);
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, vm)) {
                break :blk gpa.dupe(u8, g.shell) catch {
                    sendError(conn, "AllocFailed");
                    return;
                };
            }
        }
        // Guest not found
        sendError(conn, "GuestNotFound");
        return;
    };
    defer gpa.free(guest_shell);

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
        break :blk std.fmt.allocPrint(gpa, "exec_{d}", .{ts}) catch {
            sendError(conn, "AllocFailed");
            return;
        };
    };
    defer gpa.free(cmd_id);

    // Build command with marker (shell-appropriate exit code capture)
    const cmd_with_marker = buildCmdWithMarker(gpa, guest_shell, command) catch {
        sendError(conn, "AllocFailed");
        return;
    };
    defer gpa.free(cmd_with_marker);

    // Build pty_exec_input frame
    const frame = tunproto.buildPtyExecInput(gpa, cmd_id, cmd_with_marker) catch {
        sendError(conn, "AllocFailed");
        return;
    };
    defer gpa.free(frame);

    // Create operation state and send via KCP tunnel
    state.createOpState(cmd_id) catch {
        sendError(conn, "OpStateFailed");
        return;
    };

    const tun = state.getGuestTunnel(vm) orelse {
        sendError(conn, "GuestNotConnected");
        return;
    };
    _ = tun.sendAndFlush(frame, tun.session.mesh.clock_ms) catch {
        sendError(conn, "TunnelSendFailed");
        return;
    };

    std.log.info("[ipc-exec] sent {s} to {s}", .{ cmd_id, vm });

    // Stream output: poll op_states, write RSP_EXEC_DATA frames, then RSP_EXEC_DONE
    while (true) {
        const chunk = blk: {
            state.mutex.lock(io) catch break :blk @as(?[]const u8, null);
            defer state.mutex.unlock(io);

            const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?[]const u8, null);

            if (op.output.items.len > op.sent_pos) {
                const start = op.sent_pos;
                op.sent_pos = op.output.items.len;
                break :blk op.output.items[start..];
            }

            if (op.done) break :blk @as(?[]const u8, &.{}); // done signal
            break :blk @as(?[]const u8, null);
        };

        if (chunk) |data| {
            if (data.len > 0) {
                var wbuf: [8192]u8 = undefined;
                var w = std.ArrayList(u8).fromOwnedSlice(&wbuf);
                w.items.len = 0;
                w.appendAssumeCapacity(@intFromEnum(Response.exec_data));
                writeBlob(&w, data) catch break;
                conn.writeAll( w.items) catch break;
            }
        } else {
            // Wait for more data
            state.wake_event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(10), .clock = .awake } }) catch break;
            state.wake_event.reset();
            continue;
        }

        // Check if done
        const done = blk: {
            state.mutex.lock(io) catch break :blk false;
            defer state.mutex.unlock(io);
            const op = state.op_states.getPtr(cmd_id) orelse break :blk true;
            break :blk op.done;
        };

        if (done) break;
    }

    // Get exit code and send RSP_EXEC_DONE
    const exit_code = blk: {
        state.mutex.lock(io) catch break :blk @as(i32, -1);
        defer state.mutex.unlock(io);
        const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(i32, -1);
        break :blk op.exit_code;
    };

    {
        var wbuf: [16]u8 = undefined;
        var w = std.ArrayList(u8).fromOwnedSlice(&wbuf);
        w.items.len = 0;
        w.appendAssumeCapacity(@intFromEnum(Response.exec_done));
        writeI32(&w, exit_code) catch {};
        conn.writeAll( w.items) catch {};
    }

    state.cleanupOpState(cmd_id);
    std.log.info("[ipc-exec] done {s} exit={d}", .{ cmd_id, exit_code });
}

fn handleVersion(conn: Connection) void {
    const protocol = @import("protocol.zig");
    var buf: [128]u8 = undefined;
    var w = std.ArrayList(u8).fromOwnedSlice(&buf);
    w.items.len = 0;
    w.appendAssumeCapacity(@intFromEnum(Response.version));
    writeString(&w, protocol.VERSION) catch return;
    conn.writeAll( w.items) catch {};
}

fn handleUpload(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    conn: Connection,
    header: []const u8,
) void {
    var pos: usize = 0;
    const vm = readString(header, &pos) orelse {
        sendError(conn, "InvalidRequest: missing vm");
        return;
    };
    const dest_path = readString(header, &pos) orelse {
        sendError(conn, "InvalidRequest: missing path");
        return;
    };
    const file_hash = readString(header, &pos) orelse {
        sendError(conn, "InvalidRequest: missing hash");
        return;
    };
    const file_size = readU32(header, &pos) orelse {
        sendError(conn, "InvalidRequest: missing file_size");
        return;
    };

    const state = @as(*@import("state.zig").HostState, @ptrCast(@alignCast(state_ptr)));
    const tunproto = @import("tunproto.zig");

    // Get guest tunnel
    const tun = state.getGuestTunnel(vm) orelse {
        sendError(conn, "GuestNotConnected");
        return;
    };

    // Generate cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
        break :blk std.fmt.allocPrint(gpa, "upload_{d}", .{ts}) catch {
            sendError(conn, "AllocFailed");
            return;
        };
    };
    defer gpa.free(cmd_id);

    // Create op state for upload result tracking
    state.createOpState(cmd_id) catch {
        sendError(conn, "OpStateFailed");
        return;
    };
    defer state.cleanupOpState(cmd_id);

    // Send upload_cmd via KCP tunnel — use sendAndFlush to atomically
    // lock+send+flush+unlock, preventing race with mesh thread flush.
    const up_cmd = tunproto.buildUploadCmd(gpa, cmd_id, dest_path, file_size, file_hash) catch {
        sendError(conn, "AllocFailed");
        return;
    };
    defer gpa.free(up_cmd);
    const clock_ms = tun.session.mesh.clock_ms;
    _ = tun.sendAndFlush(up_cmd, clock_ms) catch {
        sendError(conn, "TunnelSendFailed");
        return;
    };

    // Read file data from connection in 8KB chunks and send via KCP.
    // Use lock()+sendLocked()+flushLocked()+unlock() for batch efficiency
    // (same pattern as state.zig handleUpload).
    var file_buf: [tunproto.FILE_CHUNK_DATA_MAX]u8 = undefined;
    var total_sent: u32 = 0;
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    tun.lock() catch {
        sendError(conn, "TunnelLockFailed");
        return;
    };
    defer tun.unlock();
    while (total_sent < file_size) {
        const to_read: usize = @min(file_buf.len, file_size - total_sent);
        const n = conn.readFull(file_buf[0..to_read]) catch {
            sendError(conn, "FileReadFailed");
            return;
        };
        if (n == 0) break;

        sha.update(file_buf[0..n]);

        const chunk = tunproto.buildFileChunk(gpa, cmd_id, file_buf[0..n]) catch {
            sendError(conn, "AllocFailed");
            return;
        };
        defer gpa.free(chunk);
        _ = tun.sendLocked(chunk) catch {
            sendError(conn, "TunnelSendFailed");
            return;
        };
        total_sent += @intCast(n);
    }
    tun.flushLocked(tun.session.mesh.clock_ms);

    // Send file_eof
    var final_hash: [32]u8 = undefined;
    sha.final(&final_hash);
    var hash_hex: [64]u8 = undefined;
    for (final_hash, 0..) |b, j| {
        hash_hex[j * 2] = "0123456789abcdef"[b >> 4];
        hash_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const eof = tunproto.buildFileEof(gpa, cmd_id, 0, total_sent, &hash_hex) catch {
        sendError(conn, "AllocFailed");
        return;
    };
    defer gpa.free(eof);
    _ = tun.sendLocked(eof) catch {
        sendError(conn, "TunnelSendFailed");
        return;
    };
    tun.flushLocked(tun.session.mesh.clock_ms);

    // Release tunnel lock and give mesh thread time to deliver EOF.
    // Same pattern as handleUpload in state.zig — fire-and-forget, no wait for
    // upload_result. The Guest processes asynchronously.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    // Send OK response (match state.zig handler behavior)
    var ok_buf: [1]u8 = undefined;
    ok_buf[0] = @intFromEnum(Response.ok);
    conn.writeAll( &ok_buf) catch {};
}

fn handleDownload(
    io: std.Io,
    gpa: std.mem.Allocator,
    state_ptr: *anyopaque,
    conn: Connection,
    payload: []const u8,
) void {
    var pos: usize = 0;
    const vm = readString(payload, &pos) orelse {
        sendError(conn, "InvalidRequest: missing vm");
        return;
    };
    const remote_path = readString(payload, &pos) orelse {
        sendError(conn, "InvalidRequest: missing path");
        return;
    };

    const state = @as(*@import("state.zig").HostState, @ptrCast(@alignCast(state_ptr)));
    const tunproto = @import("tunproto.zig");

    const tun = state.getGuestTunnel(vm) orelse {
        sendError(conn, "GuestNotConnected");
        return;
    };

    // Generate cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
        break :blk std.fmt.allocPrint(gpa, "download_{d}", .{ts}) catch {
            sendError(conn, "AllocFailed");
            return;
        };
    };
    defer gpa.free(cmd_id);

    // Create op state for download
    state.createOpState(cmd_id) catch {
        sendError(conn, "OpStateFailed");
        return;
    };
    defer state.cleanupOpState(cmd_id);

    // Send download_cmd via KCP tunnel
    const dl_cmd = tunproto.buildDownloadCmd(gpa, cmd_id, remote_path) catch {
        sendError(conn, "AllocFailed");
        return;
    };
    defer gpa.free(dl_cmd);
    _ = tun.sendAndFlush(dl_cmd, tun.session.mesh.clock_ms) catch {
        sendError(conn, "TunnelSendFailed");
        return;
    };

    std.log.info("[ipc-download] requested {s} from {s}", .{ cmd_id, vm });

    // Stream output: poll op_states, write RSP_DOWNLOAD_DATA frames, then RSP_DOWNLOAD_DONE
    var exit_code: i32 = -1;

    while (true) {
        const chunk = blk: {
            state.mutex.lock(io) catch break :blk @as(?[]const u8, null);
            defer state.mutex.unlock(io);

            const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?[]const u8, null);

            if (op.output.items.len > op.sent_pos) {
                const start = op.sent_pos;
                op.sent_pos = op.output.items.len;
                break :blk op.output.items[start..];
            }

            if (op.done) {
                exit_code = op.exit_code;
                // Parse file_size and hash from download_meta if available
                if (op.output.items.len > 0) {
                    break :blk @as(?[]const u8, &.{}); // done signal
                }
                break :blk @as(?[]const u8, &.{}); // done signal
            }
            break :blk @as(?[]const u8, null);
        };

        if (chunk) |data| {
            if (data.len > 0) {
                var wbuf: [8192]u8 = undefined;
                var w = std.ArrayList(u8).fromOwnedSlice(&wbuf);
                w.items.len = 0;
                w.appendAssumeCapacity(@intFromEnum(Response.download_data));
                writeBlob(&w, data) catch break;
                conn.writeAll( w.items) catch break;
            }
        } else {
            state.wake_event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(10), .clock = .awake } }) catch break;
            state.wake_event.reset();
            continue;
        }

        const done = blk: {
            state.mutex.lock(io) catch break :blk false;
            defer state.mutex.unlock(io);
            const op = state.op_states.getPtr(cmd_id) orelse break :blk true;
            break :blk op.done;
        };

        if (done) break;
    }

    // Get final exit code and metadata
    {
        state.mutex.lock(io) catch {};
        defer state.mutex.unlock(io);
        if (state.op_states.getPtr(cmd_id)) |op| {
            exit_code = op.exit_code;
        }
    }

    // Send RSP_DOWNLOAD_DONE
    {
        var wbuf: [32]u8 = undefined;
        var w = std.ArrayList(u8).fromOwnedSlice(&wbuf);
        w.items.len = 0;
        w.appendAssumeCapacity(@intFromEnum(Response.download_done));
        writeI32(&w, exit_code) catch {};
        writeU32(&w, 0) catch {}; // file_size (not tracked — data streamed above)
        w.appendAssumeCapacity(0); // empty hash
        conn.writeAll( w.items) catch {};
    }

    std.log.info("[ipc-download] done {s} exit={d}", .{ cmd_id, exit_code });
}

/// Build command string with shell-appropriate exit code marker.
fn buildCmdWithMarker(gpa: std.mem.Allocator, shell: []const u8, command: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, shell, "cmd.exe") != null) {
        return std.fmt.allocPrint(gpa, "{s} & echo MDELIM:%errorlevel%\r\n", .{command});
    }
    return std.fmt.allocPrint(gpa, "{s}; echo MDELIM:$?\n", .{command});
}

// ═══════════════════════════════════════════════════════════════════════════
// Client API (CLI and MCP use these to talk to the Host daemon)
// ═══════════════════════════════════════════════════════════════════════════

/// Connect to the Host daemon IPC socket. Returns a Connection.
pub fn clientConnect(io: std.Io) !Connection {
    if (builtin.os.tag == .windows) {
        return clientConnectWindows(io);
    }
    return clientConnectPosix(io);
}

fn clientConnectPosix(io: std.Io) !Connection {
    _ = io;
    const path = socketPath();

    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.IpcConnectFailed;
    errdefer _ = std.posix.system.close(fd);

    var addr = std.c.sockaddr.un{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    const addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.un);

    const result = std.posix.system.connect(fd, @ptrCast(&addr), addr_len);
    if (result < 0) {
        const err = std.posix.errno(result);
        _ = std.posix.system.close(fd);
        return switch (err) {
            .NOENT, .CONNREFUSED => error.IpcNotRunning,
            else => error.IpcConnectFailed,
        };
    }

    return Connection{ .fd = fd };
}

fn clientConnectWindows(io: std.Io) !Connection {
    _ = io;

    const pipe = windows.CreateFileA(
        socketPathZ(),
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0, // no sharing
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );

    if (pipe == windows.INVALID_HANDLE_VALUE) {
        const err = windows.GetLastError();
        if (err == .FILE_NOT_FOUND or err == .PIPE_BUSY) return error.IpcNotRunning;
        return error.IpcConnectFailed;
    }

    // Set pipe to byte mode
    var mode: windows.DWORD = windows.PIPE_READMODE_BYTE;
    _ = windows.SetNamedPipeHandleState(pipe, &mode, null, null);

    return Connection{ .fd = pipe };
}

/// Read all response data from the connection into a buffer.
fn clientReadAll(conn: Connection, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = conn.readFull( &read_buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        try buf.appendSlice(gpa, read_buf[0..n]);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// High-level client functions (used by CLI and MCP)
// ═══════════════════════════════════════════════════════════════════════════

/// Execute a command on a Guest via the Host daemon.
/// Streams output to `stdout_writer` and returns the exit code.
pub fn ipcExec(io: std.Io, gpa: std.mem.Allocator, vm: []const u8, cmd: []const u8, stdout_writer: *std.Io.Writer) !i32 {
    const conn = try clientConnect(io);
    defer conn.close();

    // Build request: [0x02]["vm\0"]["cmd\0"]
    var req_buf: [8192]u8 = undefined;
    var req = std.ArrayList(u8).fromOwnedSlice(&req_buf);
    req.items.len = 0;
    req.appendAssumeCapacity(@intFromEnum(Request.exec));
    try writeString(&req, vm);
    try writeString(&req, cmd);
    try conn.writeAll( req.items);

    // Close write half so server knows the request is complete.
    // On Windows, we don't have shutdown(SHUT_WR) — server uses pipe EOF.
    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    // Read response frames
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    while (pos < resp.items.len) {
        const type_byte = readByte(resp.items, &pos) orelse break;
        const rtype: Response = @enumFromInt(type_byte);

        switch (rtype) {
            .exec_data => {
                const data = readBlob(resp.items, &pos) orelse break;
                _ = stdout_writer.write(data) catch {};
                try stdout_writer.flush();
            },
            .exec_done => {
                const ec = readI32(resp.items, &pos) orelse break;
                return ec;
            },
            .err => {
                const msg = readString(resp.items, &pos) orelse "UnknownError";
                std.log.err("[ipc] exec error: {s}", .{msg});
                return error.IpcError;
            },
            else => return error.IpcProtocolError,
        }
    }
    return error.IpcProtocolError;
}

/// Get guest status list as a raw JSON string (caller owns memory).
pub fn ipcStatus(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const conn = try clientConnect(io);
    defer conn.close();

    // Send CMD_STATUS
    var req: [1]u8 = undefined;
    req[0] = @intFromEnum(Request.status);
    try conn.writeAll( &req);

    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    const type_byte = readByte(resp.items, &pos) orelse return error.IpcProtocolError;
    const rtype: Response = @enumFromInt(type_byte);
    switch (rtype) {
        .status => {
            const json = readBlob(resp.items, &pos) orelse return error.IpcProtocolError;
            return gpa.dupe(u8, json);
        },
        .err => {
            const msg = readString(resp.items, &pos) orelse "UnknownError";
            std.log.err("[ipc] status error: {s}", .{msg});
            return error.IpcError;
        },
        else => return error.IpcProtocolError,
    }
}

/// Ping a Guest via the Host daemon. Returns the JSON response string (caller owns memory).
pub fn ipcPing(io: std.Io, gpa: std.mem.Allocator, vm: []const u8) ![]const u8 {
    const conn = try clientConnect(io);
    defer conn.close();

    // Send CMD_PING
    var req_buf: [256]u8 = undefined;
    var req = std.ArrayList(u8).fromOwnedSlice(&req_buf);
    req.items.len = 0;
    req.appendAssumeCapacity(@intFromEnum(Request.ping));
    try writeString(&req, vm);
    try conn.writeAll( req.items);

    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    const type_byte = readByte(resp.items, &pos) orelse return error.IpcProtocolError;
    const rtype: Response = @enumFromInt(type_byte);
    switch (rtype) {
        .ping => {
            const json = readBlob(resp.items, &pos) orelse return error.IpcProtocolError;
            return gpa.dupe(u8, json);
        },
        .err => {
            const msg = readString(resp.items, &pos) orelse "UnknownError";
            std.log.err("[ipc] ping error: {s}", .{msg});
            return error.IpcError;
        },
        else => return error.IpcProtocolError,
    }
}

/// Upload a file to a Guest via the Host daemon.
/// `local_path`: path on the Host's filesystem to read.
/// `remote_path`: destination path on the Guest (e.g., "/opt/utmm/file.txt").
pub fn ipcUpload(io: std.Io, gpa: std.mem.Allocator, vm: []const u8, local_path: []const u8, remote_path: []const u8) !void {
    // Read local file
    const file_data = std.Io.Dir.cwd().readFileAlloc(io, local_path, gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.log.err("[ipc] Cannot read {s}: {}", .{ local_path, err });
        return err;
    };
    defer gpa.free(file_data);

    // Compute SHA256
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file_data, &sha256, .{});
    var sha256_hex: [64]u8 = undefined;
    for (sha256, 0..) |b, j| {
        sha256_hex[j * 2] = "0123456789abcdef"[b >> 4];
        sha256_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }

    const conn = try clientConnect(io);
    defer conn.close();

    // Build request: [0x04][vm\0][path\0][hash\0][file_size u32][raw file data]
    const header_size = 1 + (vm.len + 1) + (remote_path.len + 1) + (64 + 1) + 4;
    var req = try std.ArrayList(u8).initCapacity(gpa, header_size + file_data.len);
    defer req.deinit(gpa);

    req.appendAssumeCapacity(@intFromEnum(Request.upload));
    try writeString(&req, vm);
    try writeString(&req, remote_path);
    try writeString(&req, &sha256_hex);
    try writeU32(&req, @intCast(file_data.len));
    req.appendSliceAssumeCapacity(file_data);
    try conn.writeAll( req.items);

    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    // Read response
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    const type_byte = readByte(resp.items, &pos) orelse return error.IpcProtocolError;
    const rtype: Response = @enumFromInt(type_byte);
    switch (rtype) {
        .ok => return,
        .err => {
            const msg = readString(resp.items, &pos) orelse "UnknownError";
            std.log.err("[ipc] upload error: {s}", .{msg});
            return error.IpcError;
        },
        else => return error.IpcProtocolError,
    }
}

/// Download a file from a Guest via the Host daemon.
/// Streams file data to `file_writer`, verifies SHA256 hash.
/// Returns the number of bytes received.
pub fn ipcDownload(
    io: std.Io,
    gpa: std.mem.Allocator,
    vm: []const u8,
    remote_path: []const u8,
    file_writer: *std.Io.Writer,
) !u32 {
    const conn = try clientConnect(io);
    defer conn.close();

    // Build request: [0x05][vm\0][path\0]
    var req_buf: [1024]u8 = undefined;
    var req = std.ArrayList(u8).fromOwnedSlice(&req_buf);
    req.items.len = 0;
    req.appendAssumeCapacity(@intFromEnum(Request.download));
    try writeString(&req, vm);
    try writeString(&req, remote_path);
    try conn.writeAll( req.items);

    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    // Read response frames
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    var total_bytes: u32 = 0;
    while (pos < resp.items.len) {
        const type_byte = readByte(resp.items, &pos) orelse break;
        const rtype: Response = @enumFromInt(type_byte);

        switch (rtype) {
            .download_data => {
                const data = readBlob(resp.items, &pos) orelse break;
                _ = file_writer.write(data) catch {};
                try file_writer.flush();
                total_bytes += @intCast(data.len);
            },
            .download_done => {
                const exit_code = readI32(resp.items, &pos) orelse break;
                _ = readU32(resp.items, &pos); // file_size from server
                _ = readString(resp.items, &pos); // hash from server
                if (exit_code != 0) {
                    std.log.err("[ipc] download failed: exit_code={d}", .{exit_code});
                    return error.IpcDownloadFailed;
                }
                return total_bytes;
            },
            .err => {
                const msg = readString(resp.items, &pos) orelse "UnknownError";
                std.log.err("[ipc] download error: {s}", .{msg});
                return error.IpcError;
            },
            else => return error.IpcProtocolError,
        }
    }
    return error.IpcProtocolError;
}

/// Get Host daemon version.
pub fn ipcVersion(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const conn = try clientConnect(io);
    defer conn.close();

    var req: [1]u8 = undefined;
    req[0] = @intFromEnum(Request.version);
    try conn.writeAll( &req);

    if (builtin.os.tag != .windows) {
        _ = std.posix.system.shutdown(conn.fd, std.posix.SHUT.WR);
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try clientReadAll(conn, gpa, &resp);

    var pos: usize = 0;
    const type_byte = readByte(resp.items, &pos) orelse return error.IpcProtocolError;
    const rtype: Response = @enumFromInt(type_byte);
    switch (rtype) {
        .version => {
            const ver = readString(resp.items, &pos) orelse return error.IpcProtocolError;
            return gpa.dupe(u8, ver);
        },
        .err => {
            const msg = readString(resp.items, &pos) orelse "UnknownError";
            std.log.err("[ipc] version error: {s}", .{msg});
            return error.IpcError;
        },
        else => return error.IpcProtocolError,
    }
}
