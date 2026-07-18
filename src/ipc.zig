//! IPC module — In-process command channel for Host
//!
//! Persistent Host process accepts local management commands via TCP 127.0.0.1:12347,
//! eliminating --status/--exec port conflicts with UDP listener.
//!
//! Protocol (text, request-response, close=EOF):
//!   Client → Server: <COMMAND>\n\n
//!   Server → Client: OK\n<output><EOF>  or  ERR\n<error><EOF>

const std = @import("std");

/// IPC control port (localhost only)
pub const IPC_PORT: u16 = 12347;

/// Shared state: Guest list in Host process + concurrency protection
pub const SharedState = struct {
    guests: *std.ArrayList(@import("listener.zig").GuestState),
    mutex: *std.Io.Mutex,
};

/// Command handler: receives command text, returns response text (caller frees)
pub const Handler = *const fn (*anyopaque, []const u8) anyerror![]const u8;

/// Client: connect to running Host, send command, return response body as heap-allocated string.
/// Caller owns the returned slice. Returns HostNotRunning on failure.
pub fn sendCommandRaw(io: std.Io, allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", IPC_PORT) catch |err| {
        std.debug.print("[ipc] Failed to parse address: {}\n", .{err});
        return error.HostNotRunning;
    };
    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[ipc] Host not running (port {d}): {}\n", .{ IPC_PORT, err });
        return error.HostNotRunning;
    };
    defer stream.close(io);

    // Send command (terminated with \n\n)
    {
        var wb: [1024]u8 = undefined;
        var writer = stream.writer(io, &wb);
        writer.interface.print("{s}\n\n", .{command}) catch |err| {
            std.debug.print("[ipc] Send failed: {}\n", .{err});
            return error.IpcFailed;
        };
        writer.interface.flush() catch {};
    }

    // Read response byte-by-byte until EOF
    var resp: std.ArrayList(u8) = .empty;
    // errdefer handles cleanup on error returns; explicit deinit only on success path
    errdefer resp.deinit(allocator);

    {
        var rb: [4096]u8 = undefined;
        var reader = stream.reader(io, &rb);
        while (true) {
            const byte = reader.interface.takeByte() catch break;
            resp.append(allocator, byte) catch |err| {
                std.debug.print("[ipc] Failed to read response: {}\n", .{err});
                return error.IpcFailed;
            };
        }
    }

    const items = resp.items;
    if (items.len < 3) {
        std.debug.print("[ipc] Invalid response format\n", .{});
        return error.IpcFailed;
    }

    if (std.mem.startsWith(u8, items, "OK\n")) {
        // Return body after OK\n (skip "OK\n", caller owns)
        const body = items[3..];
        const result = try allocator.dupe(u8, body);
        resp.deinit(allocator);
        return result;
    } else if (std.mem.startsWith(u8, items, "ERR\n")) {
        const err_msg = items[4..];
        // trimmed is a slice into resp.items; errdefer cleans up after print
        const trimmed = std.mem.trim(u8, err_msg, " \n\r");
        if (trimmed.len > 0) {
            std.debug.print("[ipc] Host error: {s}\n", .{trimmed});
        }
        return error.IpcFailed;
    } else {
        if (items.len > 0) {
            std.debug.print("[ipc] Unknown response: {s}\n", .{items[0..@min(items.len, 80)]});
        }
        return error.IpcFailed;
    }
}

/// Client: connect to running Host, send command, print result to stdout.
/// Returns HostNotRunning on failure (caller should fallback to direct mode)
pub fn sendCommand(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !void {
    const body = try sendCommandRaw(io, allocator, command);
    defer allocator.free(body);
    if (body.len > 0) {
        std.debug.print("{s}", .{body});
    }
}

/// Server: runs in a dedicated thread, accepts IPC connections.
/// Each connection is handled in its own thread so a slow exec
/// (e.g., Windows cmd.exe hang) doesn't block --status and other commands.
/// Retries bind on transient port conflicts (TIME_WAIT, etc.) up to 30 seconds.
pub fn startServer(io: std.Io, allocator: std.mem.Allocator, ctx: *anyopaque, handler: Handler) !void {
    const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", IPC_PORT);

    // Retry bind with backoff — port may be in TIME_WAIT from a previous instance.
    // Without this, launchd fast-restart cycles cause the IPC server to die silently.
    var server: std.Io.net.Server = undefined;
    var bind_ok = false;
    for (0..30) |attempt| {
        server = listen_addr.listen(io, .{ .reuse_address = true }) catch |err| {
            std.debug.print("[ipc] bind port {d} failed (attempt {d}/30): {}\n", .{ IPC_PORT, attempt + 1, err });
            std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real) catch {};
            continue;
        };
        bind_ok = true;
        break;
    }
    if (!bind_ok) {
        std.debug.print("[ipc] FATAL: could not bind port {d} after 30 attempts\n", .{IPC_PORT});
        return error.PortUnavailable;
    }
    defer server.deinit(io);

    std.debug.print("[ipc] IPC server started on 127.0.0.1:{d}\n", .{IPC_PORT});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("[ipc] accept failed: {}\n", .{err});
            continue;
        };
        // Spawn a thread per connection — prevents a slow HTTP exec
        // from serializing all subsequent IPC commands.
        const t = std.Thread.spawn(.{}, handleConnectionThread, .{ io, allocator, stream, ctx, handler }) catch |err| {
            std.debug.print("[ipc] Failed to spawn connection thread: {}\n", .{err});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// Thread entry point: wraps handleConnection with error logging.
fn handleConnectionThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    ctx: *anyopaque,
    handler: Handler,
) void {
    handleConnection(io, allocator, stream, ctx, handler) catch |err| {
        std.debug.print("[ipc] Connection handling failed: {}\n", .{err});
    };
}

/// Set receive timeout on a socket (Unix only — POSIX timeval via setsockopt).
/// Best-effort — failures are silently ignored (timeout is a safety net, not critical).
/// On Windows this is a no-op: Zig 0.16 Io abstraction doesn't expose the raw SOCKET handle.
fn setRecvTimeout(socket: std.Io.net.Socket, timeout_secs: u32) void {
    if (@import("builtin").os.tag != .windows) {
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_secs),
            .usec = 0,
        };
        _ = std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

/// IPC connection read timeout (seconds). A dead client that never sends \n\n
/// will be disconnected after this duration, preventing thread leaks.
const IPC_RECV_TIMEOUT_SECS: u32 = 30;

/// Handle single IPC connection: read command → call handler → return result → close
fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    ctx: *anyopaque,
    handler: Handler,
) !void {
    defer stream.close(io);

    // Set a read timeout so a dead/malicious client can't hold a thread forever.
    setRecvTimeout(stream.socket, IPC_RECV_TIMEOUT_SECS);

    // Read command (until \n\n)
    var cmd_buf: [4096]u8 = undefined;
    var cmd_len: usize = 0;

    {
        var rb: [1024]u8 = undefined;
        var reader = stream.reader(io, &rb);
        while (cmd_len < cmd_buf.len - 1) {
            const byte = reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            cmd_buf[cmd_len] = byte;
            cmd_len += 1;
            // Detect end marker \n\n
            if (cmd_len >= 2 and cmd_buf[cmd_len - 2] == '\n' and cmd_buf[cmd_len - 1] == '\n') {
                break;
            }
        }
    }

    if (cmd_len < 2) return;

    // Strip trailing \n\n
    const cmd = cmd_buf[0 .. cmd_len - 2];

    // Call handler
    const response = handler(ctx, cmd) catch |err| {
        // Return error response
        var wb: [256]u8 = undefined;
        var writer = stream.writer(io, &wb);
        writer.interface.print("ERR\n{}\n", .{err}) catch {};
        writer.interface.flush() catch {};
        return;
    };
    defer allocator.free(response);

    // Send success response
    {
        var wb: [4096]u8 = undefined;
        var writer = stream.writer(io, &wb);
        writer.interface.print("OK\n{s}", .{response}) catch {};
        writer.interface.flush() catch {};
    }
}

test "IPC_PORT" {
    try std.testing.expectEqual(@as(u16, 12347), IPC_PORT);
}

test "SharedState fields" {
    _ = SharedState;
}

test "sendCommand signature" {
    _ = sendCommand;
}

test "startServer signature" {
    _ = startServer;
}
