//! Agent — user-session TCP server for GUI-aware exec on Guest VMs
//!
//! The Guest background service (launchd / systemd / Task Scheduler) runs in
//! the system session (Session 0 on Windows) and cannot interact with the
//! desktop.  The Agent is a companion process that runs in the user's login
//! session — launched via a user-level auto-start item with a visible terminal
//! window — and takes over `/exec` commands so they can open GUI apps.
//!
//! Data flow:
//!   Host --HTTP POST /exec--> Guest HTTP server (2121)
//!     --> try Agent forwarding (127.0.0.1:2123)
//!       --> Agent execs in user session (GUI-capable)
//!       --> returns result to HTTP server --> Host
//!     --> fallback: direct exec (current behaviour, no GUI)
//!
//! Protocol (TCP, request-response, close = EOF):
//!   HTTP server → Agent: EXEC\n<cmd>\n\n
//!   Agent → HTTP server: OK\n<output><EOF>  or  ERR\n<error><EOF>

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

/// Result of executing a command.
const ExecResult = std.process.RunResult;

/// Run the Agent: open terminal window, print banner, listen for exec commands.
/// This function is the entry point for `utmm --agent`.  It blocks forever.
pub fn run(io: std.Io, gpa: std.mem.Allocator) !void {
    // ── Banner ───────────────────────────────────────────────────────────
    const banner =
        \\╔══════════════════════════════════════════════════════╗
        \\║  utmm agent v{0s}
        \\╠══════════════════════════════════════════════════════╣
        \\║  Listening on 127.0.0.1:{1d}
        \\║  Waiting for exec commands from Guest HTTP server...
        \\╚══════════════════════════════════════════════════════╝
        \\
    ;
    std.debug.print(banner, .{ protocol.VERSION, protocol.AGENT_PORT });

    // ── TCP server ───────────────────────────────────────────────────────
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", protocol.AGENT_PORT) catch |err| {
        std.debug.print("[agent] FATAL: cannot parse address: {}\n", .{err});
        return err;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[agent] FATAL: cannot bind port {d}: {}\n", .{ protocol.AGENT_PORT, err });
        std.debug.print("[agent] Is another agent already running?\n", .{});
        return err;
    };
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("[agent] accept error: {}\n", .{err});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, stream }) catch |err| {
            std.debug.print("[agent] thread spawn error: {}\n", .{err});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// Handle one agent connection: read EXEC\n<cmd>\n\n → exec → return result.
fn handleConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
    defer stream.close(io);

    // ── Read command (until \n\n) ──────────────────────────────────────
    var cmd_buf: [65536]u8 = undefined;
    var cmd_len: usize = 0;
    {
        var rb: [4096]u8 = undefined;
        var reader = stream.reader(io, &rb);
        while (cmd_len < cmd_buf.len - 1) {
            const byte = reader.interface.takeByte() catch break;
            cmd_buf[cmd_len] = byte;
            cmd_len += 1;
            if (cmd_len >= 2 and
                cmd_buf[cmd_len - 2] == '\n' and
                cmd_buf[cmd_len - 1] == '\n') break;
        }
    }
    if (cmd_len < 2) return;

    // Strip trailing \n\n
    const raw_cmd = cmd_buf[0 .. cmd_len - 2];

    // Skip "EXEC\n" prefix if present (protocol: EXEC\n<cmd>\n\n)
    const cmd = if (std.mem.startsWith(u8, raw_cmd, "EXEC\n"))
        raw_cmd["EXEC\n".len..]
    else
        raw_cmd;

    std.debug.print("[agent] EXEC: {s}\n", .{cmd});

    // ── Execute the command in user session ─────────────────────────────
    const result = execInUserSession(gpa, io, cmd) catch |err| {
        var wb: [256]u8 = undefined;
        var writer = stream.writer(io, &wb);
        writer.interface.print("ERR\n{}\n", .{err}) catch {};
        writer.interface.flush() catch {};
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // ── Send response ──────────────────────────────────────────────────
    {
        var wb: [65536]u8 = undefined;
        var writer = stream.writer(io, &wb);
        if (result.term == .exited and result.term.exited == 0) {
            writer.interface.print("OK\n{s}", .{result.stdout}) catch {};
        } else {
            writer.interface.print("ERR\n{s}", .{result.stderr}) catch {};
        }
        writer.interface.flush() catch {};
    }
}

/// Execute a command in the user's desktop session.
/// The Agent runs as a user-level process (LaunchAgent / user systemd /
/// user Task Scheduler), so commands it spawns inherit the user's GUI session.
fn execInUserSession(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8) !ExecResult {
    if (builtin.os.tag == .windows) {
        return execWindows(gpa, io, cmd);
    }
    const shell: []const u8 = "/bin/sh";
    const shell_arg: []const u8 = "-c";
    return std.process.run(gpa, io, .{
        .argv = &[_][]const u8{ shell, shell_arg, cmd },
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows exec — file-based stdout/stderr to avoid pipe-inheritance hangs.
// Same approach as http_server.execWindows.
// ═══════════════════════════════════════════════════════════════════════════

fn execWindows(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8) !ExecResult {
    const tid: usize = @intCast(std.Thread.getCurrentId());

    const tmp_stdout = try std.fmt.allocPrint(gpa, "utmm_agent_out_{d}.tmp", .{tid});
    defer gpa.free(tmp_stdout);
    const tmp_stderr = try std.fmt.allocPrint(gpa, "utmm_agent_err_{d}.tmp", .{tid});
    defer gpa.free(tmp_stderr);
    const tmp_bat = try std.fmt.allocPrint(gpa, "utmm_agent_cmd_{d}.bat", .{tid});
    defer gpa.free(tmp_bat);

    // Write command to .bat file
    {
        const bat_file = try std.Io.Dir.cwd().createFile(io, tmp_bat, .{ .permissions = @enumFromInt(0o644) });
        defer bat_file.close(io);
        var wb: [4096]u8 = undefined;
        var writer = bat_file.writer(io, &wb);
        _ = try writer.interface.write("@echo off\r\n");
        _ = try writer.interface.write(cmd);
        _ = try writer.interface.write("\r\n");
        try writer.interface.flush();
    }

    const stdout_file = try std.Io.Dir.cwd().createFile(io, tmp_stdout, .{ .permissions = @enumFromInt(0o644) });
    errdefer {
        stdout_file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_stdout) catch {};
    }
    const stderr_file = try std.Io.Dir.cwd().createFile(io, tmp_stderr, .{ .permissions = @enumFromInt(0o644) });
    errdefer {
        stderr_file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_stderr) catch {};
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", tmp_bat },
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
    });
    stdout_file.close(io);
    stderr_file.close(io);

    const term = try child.wait(io);

    var stdout: []u8 = &.{};
    var stderr: []u8 = &.{};
    if (std.Io.Dir.cwd().readFileAlloc(io, tmp_stdout, gpa, @enumFromInt(1024 * 1024))) |data| {
        stdout = data;
    } else |_| {}
    if (std.Io.Dir.cwd().readFileAlloc(io, tmp_stderr, gpa, @enumFromInt(1024 * 1024))) |data| {
        stderr = data;
    } else |_| {}

    std.Io.Dir.cwd().deleteFile(io, tmp_stdout) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_stderr) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_bat) catch {};

    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

test "agent run" {
    _ = run;
}
