//! Guest mode orchestration — threaded I/O model.
//!
//! Starts two threads:
//!   1. UDP broadcast loop (every 1s on port 2121, from broadcast.zig)
//!   2. TCP server (accept loop on port 2121, handles VERSION/HEALTH/FILE/UPLOAD/EXEC)
//!
//! Uses std.Thread for concurrency — one thread per connection.
//! Protocol: length-prefixed messages via transport.zig (replaces HTTP).

const std = @import("std");
const builtin = @import("builtin");
const broadcast = @import("broadcast.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

const Io = std.Io;

/// Detected shell binary — set at startup by runWithIo, used by execPosix.
/// POSIX: e.g. "/bin/zsh" — exec adds "-l -c" for login environment.
/// Windows: "cmd.exe" — exec adds "/c".
var guest_shell: []const u8 = "/bin/sh";

/// Guest mode entry point (from std.process.Init)
pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli);
}

/// Guest mode entry point (called from Windows service or direct process start).
pub fn runWithIo(block_io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs) !void {

    // Collect system information (sync, uses blocking Io for process.run etc.)
    var sysinfo = try broadcast.getSystemInfo(block_io, gpa);
    defer {
        gpa.free(sysinfo.hostname);
        gpa.free(sysinfo.ip);
        gpa.free(sysinfo.mac);
        gpa.free(sysinfo.iface_name);
        gpa.free(sysinfo.shell);
    }

    if (cli.hostname) |n| {
        gpa.free(sysinfo.hostname);
        sysinfo.hostname = try gpa.dupe(u8, n);
    }

    // Store shell for use by exec handlers (with -l for login environment)
    guest_shell = sysinfo.shell;

    const port = cli.port;

    std.debug.print("[guest] Hostname: {s}\n", .{sysinfo.hostname});
    std.debug.print("[guest] Target: {s}\n", .{sysinfo.target});
    std.debug.print("[guest] IP: {s}\n", .{sysinfo.ip});
    std.debug.print("[guest] MAC: {s}\n", .{sysinfo.mac});
    std.debug.print("[guest] Shell: {s}\n", .{guest_shell});
    std.debug.print("[guest] Port: {d} (UDP broadcast + TCP)\n", .{port});

    // Ensure CWD is /opt/utmm/ (or C:\opt\utmm\ on Windows)
    if (builtin.os.tag == .windows) {
        const msvcrt = struct {
            extern "c" fn _chdir(path: [*:0]const u8) c_int;
        };
        _ = msvcrt._chdir("C:\\opt\\utmm\\");
    } else {
        const libc = struct {
            extern "c" fn chdir(path: [*:0]const u8) c_int;
        };
        _ = libc.chdir("/opt/utmm");
    }

    // ── Thread 1: UDP broadcast loop ──────────────────────────────────────
    // Clone sysinfo fields for the broadcast thread (thread-safe ownership)
    const bc_info = broadcast.SystemInfo{
        .hostname = try gpa.dupe(u8, sysinfo.hostname),
        .ip = try gpa.dupe(u8, sysinfo.ip),
        .mac = try gpa.dupe(u8, sysinfo.mac),
        .target = sysinfo.target,
        .iface_name = try gpa.dupe(u8, sysinfo.iface_name),
        .shell = try gpa.dupe(u8, sysinfo.shell),
    };
    const bc_thread = try std.Thread.spawn(.{}, broadcastThread, .{ block_io, port, bc_info, cli.is_svc });
    bc_thread.detach();

    // ── Main thread: TCP server accept loop ───────────────────────────────
    try tcpServerLoop(block_io, gpa, port);
}

// ═══════════════════════════════════════════════════════════════════════════
// Broadcast thread (wraps broadcast.broadcastLoop)
// ═══════════════════════════════════════════════════════════════════════════

fn broadcastThread(block_io: Io, port: u16, info: broadcast.SystemInfo, is_svc: bool) !void {
    broadcast.broadcastLoop(block_io, port, info, is_svc) catch |err| {
        std.debug.print("[guest] Broadcast thread error: {}\n", .{err});
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TCP server (accept loop on main thread)
// ═══════════════════════════════════════════════════════════════════════════

fn tcpServerLoop(block_io: Io, gpa: std.mem.Allocator, port: u16) !void {
    const addr = Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
        std.debug.print("[guest] Failed to parse bind addr: {}\n", .{err});
        return err;
    };
    var server = addr.listen(block_io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[guest] Failed to listen on {d}: {}\n", .{ port, err });
        return err;
    };
    defer server.deinit(block_io);

    std.debug.print("[guest] TCP server listening on port {d}\n", .{port});

    while (true) {
        const stream = server.accept(block_io) catch |err| {
            std.debug.print("[guest] Accept error: {}\n", .{err});
            continue;
        };
        errdefer stream.close(block_io);

        const conn_thread = std.Thread.spawn(.{}, handleClient, .{ block_io, gpa, stream }) catch |err| {
            std.debug.print("[guest] Failed to spawn handler thread: {}\n", .{err});
            stream.close(block_io);
            continue;
        };
        conn_thread.detach();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Per-connection TCP handler
// ═══════════════════════════════════════════════════════════════════════════

fn handleClient(block_io: Io, gpa: std.mem.Allocator, stream: Io.net.Stream) !void {
    defer stream.close(block_io);

    var read_buf: [65536]u8 = undefined;
    var reader = stream.reader(block_io, &read_buf);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(block_io, &write_buf);

    const msg = transport.recvMessage(&reader, gpa) catch |err| {
        std.debug.print("[guest] recvMessage error: {}\n", .{err});
        return;
    };
    if (msg == null) return;
    defer gpa.free(msg.?.payload);

    dispatchMessage(block_io, gpa, &writer, msg.?.msg_type, msg.?.payload) catch |err| {
        std.debug.print("[guest] dispatch error: {}\n", .{err});
        transport.sendString(&writer, transport.MsgType.ERROR, "Internal error") catch {};
    };

    // Flush buffered writer before stream closes — data must be sent before
    // the deferred stream.close() tears down the socket.
    writer.interface.flush() catch {};
}

fn dispatchMessage(
    block_io: Io,
    gpa: std.mem.Allocator,
    writer: anytype,
    msg_type: u8,
    payload: []const u8,
) !void {
    switch (msg_type) {
        transport.MsgType.VERSION_REQ => {
            try transport.sendString(writer, transport.MsgType.VERSION_RESP, protocol.VERSION);
        },
        transport.MsgType.HEALTH_REQ => {
            try transport.sendString(writer, transport.MsgType.HEALTH_RESP, "OK");
        },
        transport.MsgType.FILE_REQ => {
            if (std.mem.indexOfScalar(u8, payload, '/') != null or
                std.mem.indexOfScalar(u8, payload, '\\') != null)
            {
                try transport.sendString(writer, transport.MsgType.ERROR, "Invalid filename");
                return;
            }
            try transport.streamFile(writer, block_io, payload);
        },
        transport.MsgType.UPLOAD_REQ => {
            try handleUpload(block_io, writer, payload);
        },
        transport.MsgType.EXEC_REQ => {
            try handleExec(block_io, gpa, writer, payload);
        },
        else => {
            std.debug.print("[guest] Unknown message type: 0x{x}\n", .{msg_type});
            try transport.sendString(writer, transport.MsgType.ERROR, "Unknown message type");
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Message handlers
// ═══════════════════════════════════════════════════════════════════════════

fn handleUpload(block_io: Io, writer: anytype, payload: []const u8) !void {
    const null_pos = std.mem.indexOfScalar(u8, payload, 0) orelse {
        try transport.sendString(writer, transport.MsgType.ERROR, "Invalid upload format");
        return;
    };
    const filename = payload[0..null_pos];
    const file_data = payload[null_pos + 1 ..];

    if (std.mem.indexOfScalar(u8, filename, '/') != null or
        std.mem.indexOfScalar(u8, filename, '\\') != null)
    {
        try transport.sendString(writer, transport.MsgType.ERROR, "Invalid filename");
        return;
    }

    var file = std.Io.Dir.cwd().createFile(block_io, filename, .{}) catch |err| {
        try transport.sendString(writer, transport.MsgType.ERROR, "Cannot create file");
        return err;
    };
    defer file.close(block_io);

    var wb: [4096]u8 = undefined;
    var fw = file.writer(block_io, &wb);
    _ = fw.interface.write(file_data) catch {};

    const written: u64 = file.length(block_io) catch file_data.len;
    var resp_buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "OK\n{d}", .{written}) catch "OK";
    try transport.sendString(writer, transport.MsgType.UPLOAD_RESP, resp);
    std.debug.print("[guest] Uploaded {s}: {d} bytes\n", .{ filename, written });
}

fn handleExec(block_io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    std.debug.print("[guest] EXEC: {s}\n", .{cmd});

    if (builtin.os.tag == .windows) {
        try execWindows(gpa, writer, cmd);
    } else {
        try execPosix(block_io, gpa, writer, cmd);
    }
}

fn execPosix(block_io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    const result = std.process.run(gpa, block_io, .{
        .argv = &.{ guest_shell, "-l", "-c", cmd },
    }) catch |err| {
        try transport.sendString(writer, transport.MsgType.ERROR, "Execution failed");
        return err;
    };
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }

    if (result.stdout.len > 0) {
        try transport.sendMessage(writer, transport.MsgType.EXEC_STDOUT, result.stdout);
    }
    if (result.stderr.len > 0) {
        try transport.sendMessage(writer, transport.MsgType.EXEC_STDERR, result.stderr);
    }

    const exit_code: i32 = switch (result.term) {
        .exited => |code| @intCast(code),
        .signal => @as(i32, -1),
        .stopped => @as(i32, -2),
        .unknown => @as(i32, -3),
    };
    var exit_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &exit_buf, exit_code, .big);
    try transport.sendMessage(writer, transport.MsgType.EXEC_EXIT, &exit_buf);
}

fn execWindows(gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    // On Windows, the process I/O context (global_single_threaded) uses
    // Allocator.failing, which causes OutOfMemory in processSpawnWindows.
    // Use a dedicated Threaded instance with a real allocator.
    var threaded = std.Io.Threaded.init(gpa, .{});
    const block_io = threaded.io();
    const result = std.process.run(gpa, block_io, .{
        .argv = &.{ "cmd.exe", "/c", cmd },
    }) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Execution failed: {s}", .{@errorName(err)}) catch "Execution failed";
        try transport.sendString(writer, transport.MsgType.ERROR, err_msg);
        return err;
    };
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }

    if (result.stdout.len > 0) {
        try transport.sendMessage(writer, transport.MsgType.EXEC_STDOUT, result.stdout);
    }
    if (result.stderr.len > 0) {
        try transport.sendMessage(writer, transport.MsgType.EXEC_STDERR, result.stderr);
    }

    const exit_code: i32 = switch (result.term) {
        .exited => |code| @intCast(code),
        .signal, .stopped, .unknown => @as(i32, -1),
    };
    var exit_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &exit_buf, exit_code, .big);
    try transport.sendMessage(writer, transport.MsgType.EXEC_EXIT, &exit_buf);
}
