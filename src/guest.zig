//! Guest mode orchestration — zio-based fiber runtime.
//!
//! Starts two concurrent fibers:
//!   1. UDP broadcast loop (every 1s on port 2121, from broadcast.zig)
//!   2. TCP server (accept loop on port 2121, handles VERSION/HEALTH/FILE/UPLOAD/EXEC)
//!
//! Uses zio for async I/O — fiber-based concurrency, no thread-per-connection overhead.
//! Protocol: length-prefixed messages via transport.zig (replaces HTTP).
//!
//! Note: zio requires all fiber functions to return Io.Cancelable!void (only
//! error{Canceled}). We wrap external functions and catch non-Canceled errors
//! at the fiber boundary.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const broadcast = @import("broadcast.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

const Io = std.Io;

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
    }

    if (cli.hostname) |n| {
        gpa.free(sysinfo.hostname);
        sysinfo.hostname = try gpa.dupe(u8, n);
    }

    const port = cli.port;

    std.debug.print("[guest] Hostname: {s}\n", .{sysinfo.hostname});
    std.debug.print("[guest] Target: {s}\n", .{sysinfo.target});
    std.debug.print("[guest] IP: {s}\n", .{sysinfo.ip});
    std.debug.print("[guest] MAC: {s}\n", .{sysinfo.mac});
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

    // ── Initialize zio Runtime ────────────────────────────────────────────
    var rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var group: Io.Group = .init;
    defer group.cancel(io);

    // Fiber 1: UDP broadcast loop (wrapped for zio Cancelable return type)
    try group.concurrent(io, broadcastFiber, .{ io, port, sysinfo, cli.is_svc });

    // Main fiber: TCP server accept loop
    try tcpServerLoop(io, gpa, &group, port);
}

// ═══════════════════════════════════════════════════════════════════════════
// Broadcast fiber (wraps broadcast.broadcastLoop for zio Io.Cancelable!void)
// ═══════════════════════════════════════════════════════════════════════════

fn broadcastFiber(io: Io, port: u16, info: broadcast.SystemInfo, is_svc: bool) Io.Cancelable!void {
    broadcast.broadcastLoop(io, port, info, is_svc) catch |err| {
        std.debug.print("[guest] Broadcast fiber error: {}\n", .{err});
        return error.Canceled;
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TCP server (accept loop on main fiber)
// ═══════════════════════════════════════════════════════════════════════════

fn tcpServerLoop(io: Io, gpa: std.mem.Allocator, group: *Io.Group, port: u16) Io.Cancelable!void {
    const addr = Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
        std.debug.print("[guest] Failed to parse bind addr: {}\n", .{err});
        return error.Canceled;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[guest] Failed to listen on {d}: {}\n", .{ port, err });
        return error.Canceled;
    };
    defer server.deinit(io);

    std.debug.print("[guest] TCP server listening on port {d}\n", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("[guest] Accept error: {}\n", .{err});
            continue;
        };
        errdefer stream.close(io);

        group.concurrent(io, handleClient, .{ io, gpa, stream }) catch |err| {
            std.debug.print("[guest] Failed to spawn handler fiber: {}\n", .{err});
            stream.close(io);
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Per-connection TCP handler
// ═══════════════════════════════════════════════════════════════════════════

fn handleClient(io: Io, gpa: std.mem.Allocator, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);

    var read_buf: [65536]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    const msg = transport.recvMessage(&reader, gpa) catch |err| {
        std.debug.print("[guest] recvMessage error: {}\n", .{err});
        return;
    };
    if (msg == null) return;
    defer gpa.free(msg.?.payload);

    dispatchMessage(io, gpa, &writer, msg.?.msg_type, msg.?.payload) catch |err| {
        std.debug.print("[guest] dispatch error: {}\n", .{err});
        transport.sendString(&writer, transport.MsgType.ERROR, "Internal error") catch {};
    };

    // Flush buffered writer before stream closes — data must be sent before
    // the deferred stream.close() tears down the socket.
    writer.interface.flush() catch {};
}

fn dispatchMessage(
    io: Io,
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
            try transport.streamFile(writer, io, payload);
        },
        transport.MsgType.UPLOAD_REQ => {
            try handleUpload(io, writer, payload);
        },
        transport.MsgType.EXEC_REQ => {
            try handleExec(io, gpa, writer, payload);
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

fn handleUpload(io: Io, writer: anytype, payload: []const u8) !void {
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

    var file = std.Io.Dir.cwd().createFile(io, filename, .{ .permissions = @enumFromInt(0o755) }) catch |err| {
        try transport.sendString(writer, transport.MsgType.ERROR, "Cannot create file");
        return err;
    };
    defer file.close(io);

    var wb: [4096]u8 = undefined;
    var fw = file.writer(io, &wb);
    _ = fw.interface.write(file_data) catch {};
    fw.interface.flush() catch {};

    const written: usize = @intCast(file.length(io) catch file_data.len);
    var resp_buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "OK\n{d}", .{written}) catch "OK";
    try transport.sendString(writer, transport.MsgType.UPLOAD_RESP, resp);
    std.debug.print("[guest] Uploaded {s}: {d} bytes\n", .{ filename, written });
}

fn handleExec(io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    std.debug.print("[guest] EXEC: {s}\n", .{cmd});

    if (builtin.os.tag == .windows) {
        try execWindows(io, gpa, writer, cmd);
    } else {
        try execPosix(io, gpa, writer, cmd);
    }
}

fn execPosix(io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
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

fn execWindows(io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    const tid = std.Thread.getCurrentId();

    const tmp_stdout = std.fmt.allocPrint(gpa, "utmm_out_{d}.tmp", .{tid}) catch {
        try transport.sendString(writer, transport.MsgType.ERROR, "Alloc failed");
        return;
    };
    defer gpa.free(tmp_stdout);
    const tmp_stderr = std.fmt.allocPrint(gpa, "utmm_err_{d}.tmp", .{tid}) catch {
        try transport.sendString(writer, transport.MsgType.ERROR, "Alloc failed");
        return;
    };
    defer gpa.free(tmp_stderr);
    const tmp_bat = std.fmt.allocPrint(gpa, "utmm_cmd_{d}.bat", .{tid}) catch {
        try transport.sendString(writer, transport.MsgType.ERROR, "Alloc failed");
        return;
    };
    defer gpa.free(tmp_bat);

    // Write .bat file
    {
        const bat_file = std.Io.Dir.cwd().createFile(io, tmp_bat, .{ .permissions = @enumFromInt(0o644) }) catch |err| {
            try transport.sendString(writer, transport.MsgType.ERROR, "Cannot create batch file");
            return err;
        };
        defer bat_file.close(io);
        var wb: [4096]u8 = undefined;
        var bat_w = bat_file.writer(io, &wb);
        _ = bat_w.interface.write("@echo off\r\n") catch 0;
        _ = bat_w.interface.write(cmd) catch 0;
        _ = bat_w.interface.write("\r\n") catch 0;
        bat_w.interface.flush() catch {};
    }

    const stdout_f = std.Io.Dir.cwd().createFile(io, tmp_stdout, .{ .permissions = @enumFromInt(0o644) }) catch |err| {
        try transport.sendString(writer, transport.MsgType.ERROR, "Cannot create stdout file");
        return err;
    };
    const stderr_f = std.Io.Dir.cwd().createFile(io, tmp_stderr, .{ .permissions = @enumFromInt(0o644) }) catch |err| {
        stdout_f.close(io);
        try transport.sendString(writer, transport.MsgType.ERROR, "Cannot create stderr file");
        return err;
    };

    var child = std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", tmp_bat },
        .stdout = .{ .file = stdout_f },
        .stderr = .{ .file = stderr_f },
    }) catch |err| {
        stdout_f.close(io);
        stderr_f.close(io);
        try transport.sendString(writer, transport.MsgType.ERROR, "Spawn failed");
        return err;
    };

    stdout_f.close(io);
    stderr_f.close(io);

    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };

    if (std.Io.Dir.cwd().readFileAlloc(io, tmp_stdout, gpa, @enumFromInt(10 * 1024 * 1024))) |data| {
        if (data.len > 0) {
            try transport.sendMessage(writer, transport.MsgType.EXEC_STDOUT, data);
        }
        gpa.free(data);
    } else |_| {}

    if (std.Io.Dir.cwd().readFileAlloc(io, tmp_stderr, gpa, @enumFromInt(10 * 1024 * 1024))) |data| {
        if (data.len > 0) {
            try transport.sendMessage(writer, transport.MsgType.EXEC_STDERR, data);
        }
        gpa.free(data);
    } else |_| {}

    std.Io.Dir.cwd().deleteFile(io, tmp_stdout) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_stderr) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_bat) catch {};

    const exit_code: i32 = switch (term) {
        .exited => |code| @intCast(code),
        else => -1,
    };
    var exit_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &exit_buf, exit_code, .big);
    try transport.sendMessage(writer, transport.MsgType.EXEC_EXIT, &exit_buf);
}
