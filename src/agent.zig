//! Foreground Guest mode — the default when utmm is launched with no arguments.
//!
//! Design:
//!   utmm
//!     1. Stop the background system service (sc / launchctl / systemctl)
//!     2. Run Guest mode in the foreground (UDP broadcast + HTTP server)
//!     3. When the window is closed or Ctrl+C pressed, restart the service
//!
//! Because this runs in the user's login session (not Session 0 on Windows),
//! exec commands forwarded through the Guest HTTP server NATURALLY have GUI
//! access.  No separate TCP forwarding port is needed.
//!
//! System daemons use --svc to bypass this stop/restart logic and run guest
//! directly — that's how launchd/systemd/SCM start the background service.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const guest = @import("guest.zig");
const main = @import("main.zig");

/// Run the foreground guest: if stdout is a terminal, print banner, stop the
/// background service, run guest interactively, and restart service on exit.
/// If stdout is NOT a terminal (e.g. launched by systemd/launchd without --svc),
/// fall back to plain daemon mode — backward compatible with old service configs.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    hostname_override: ?[]const u8,
    port: u16,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
) !void {
    // Detect whether we're in an interactive terminal (TTY).
    // If not, we were likely launched by a service manager without --svc
    // (old config). Fall back to daemon mode.
    const is_tty: bool = if (builtin.os.tag == .windows)
        // Windows: check if process has a console window
        blk: {
            const kernel32 = struct {
                extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
            };
            break :blk kernel32.GetConsoleWindow() != null;
        }
    else
        // POSIX: check if stdout is a terminal
        blk: {
            const libc = struct {
                extern "c" fn isatty(fd: c_int) c_int;
            };
            break :blk libc.isatty(1) != 0;
        };

    if (!is_tty) {
        // Daemon mode — no service management, just run guest directly.
        // Set is_svc = true so the broadcast loop enables self-upgrade checks
        // (we skip the Windows SCM entry point, but still act as a daemon).
        const cli = main.CliArgs{
            .port = port,
            .mesh_port = mesh_port,
            .peer_mesh = peer_mesh,
            .hostname = hostname_override,
            .is_svc = true,
        };
        return guest.runWithIo(io, gpa, cli);
    }

    // ── Foreground mode (TTY) ────────────────────────────────────────────
    const banner =
        \\╔══════════════════════════════════════════════════════╗
        \\║  utmm guest v{0s}
        \\╠══════════════════════════════════════════════════════╣
        \\║  Taking over from background service...
        \\║  Close this window to restart the background service.
        \\╚══════════════════════════════════════════════════════╝
        \\
    ;
    std.debug.print(banner, .{protocol.VERSION});

    // ── Stop background service ──────────────────────────────────────────
    stopBackgroundService(io, gpa);

    // ── Always restart service on exit ───────────────────────────────────
    defer restartBackgroundService(io, gpa);

    // Install signal/ctrl handler so we restart even on Ctrl+C / window close
    installShutdownHandler(io, gpa);

    // ── Run Guest in foreground ──────────────────────────────────────────
    // Same ports as the service — the agent takes over completely.
    const cli = main.CliArgs{
        .port = port,
        .mesh_port = mesh_port,
        .peer_mesh = peer_mesh,
        .hostname = hostname_override,
    };
    try guest.runWithIo(io, gpa, cli);
}

// ═══════════════════════════════════════════════════════════════════════════
// Service start/stop helpers (use default system sudo behavior)
// ═══════════════════════════════════════════════════════════════════════════

fn stopBackgroundService(io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.print("[guest] Stopping background service...\n", .{});

    if (builtin.os.tag == .windows) {
        // Use a dedicated Threaded instance with a real allocator.
        // global_single_threaded uses Allocator.failing, which causes
        // OutOfMemory in processSpawnWindows's internal ArenaAllocator.
        var threaded = std.Io.Threaded.init(gpa, .{});
        const block_io = threaded.io();
        // sc stop returns non-zero if already stopped — ignore errors
        if (std.process.run(gpa, block_io, .{ .argv = &.{ "sc", "stop", "UTM-Monitor" } })) |r| {
            _ = r;
            std.debug.print("[guest] Service stopped.\n", .{});
        } else |_| {
            std.debug.print("[guest] Service was not running (or stop failed).\n", .{});
        }
        // Give the service time to fully stop and release ports
        std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real) catch {};
    } else if (builtin.os.tag == .macos) {
        if (std.process.run(gpa, io, .{
            .argv = &.{ "sudo", "launchctl", "bootout", "system", "/Library/LaunchDaemons/com.utmm.plist" },
        })) |_| {
            std.debug.print("[guest] Service stopped.\n", .{});
        } else |_| {
            std.debug.print("[guest] Service was not running (or bootout failed).\n", .{});
        }
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real) catch {};
    } else {
        // Linux
        if (std.process.run(gpa, io, .{ .argv = &.{ "sudo", "systemctl", "stop", "utmm" } })) |_| {
            std.debug.print("[guest] Service stopped.\n", .{});
        } else |_| {
            std.debug.print("[guest] Service was not running (or stop failed).\n", .{});
        }
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real) catch {};
    }
}

fn restartBackgroundService(io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.print("[guest] Restarting background service...\n", .{});

    if (builtin.os.tag == .windows) {
        // Use a dedicated Threaded instance with a real allocator.
        var threaded = std.Io.Threaded.init(gpa, .{});
        const block_io = threaded.io();
        if (std.process.run(gpa, block_io, .{ .argv = &.{ "sc", "start", "UTM-Monitor" } })) |_| {
            std.debug.print("[guest] Service restarted.\n", .{});
        } else |_| {
            std.debug.print("[guest] WARNING: failed to restart service (sc start).\n", .{});
        }
    } else if (builtin.os.tag == .macos) {
        if (std.process.run(gpa, io, .{
            .argv = &.{ "sudo", "launchctl", "load", "/Library/LaunchDaemons/com.utmm.plist" },
        })) |_| {
            std.debug.print("[guest] Service restarted.\n", .{});
        } else |_| {
            std.debug.print("[guest] WARNING: failed to restart service (launchctl load).\n", .{});
        }
    } else {
        // Linux
        if (std.process.run(gpa, io, .{ .argv = &.{ "sudo", "systemctl", "start", "utmm" } })) |_| {
            std.debug.print("[guest] Service restarted.\n", .{});
        } else |_| {
            std.debug.print("[guest] WARNING: failed to restart service (systemctl start).\n", .{});
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Signal / Ctrl handler — restart service even on unclean exit
// ═══════════════════════════════════════════════════════════════════════════

/// Global state for signal handler access (set once before guest loop).
var g_io: ?std.Io = null;
var g_gpa: ?std.mem.Allocator = null;

fn installShutdownHandler(io: std.Io, gpa: std.mem.Allocator) void {
    g_io = io;
    g_gpa = gpa;

    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                handler: ?*const fn (u32) callconv(.winapi) u32,
                add: u32,
            ) callconv(.winapi) u32;
        };
        _ = kernel32.SetConsoleCtrlHandler(winCtrlHandler, 1);
    } else {
        // POSIX: catch SIGINT, SIGTERM, SIGHUP
        // Use SA_RESETHAND so the handler fires once, then reverts to default.
        // This is safe because we're about to exit anyway.
        const SA = struct {
            extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
        };
        _ = SA.signal(2, posixShutdownHandler); // SIGINT
        _ = SA.signal(15, posixShutdownHandler); // SIGTERM
        _ = SA.signal(1, posixShutdownHandler); // SIGHUP
    }
}

fn posixShutdownHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    // Restart service — libc system() call, pragmatic for signal context.
    // Declare extern to avoid std.c.system portability issues.
    const libc = struct {
        extern "c" fn system(command: [*:0]const u8) c_int;
    };
    if (builtin.os.tag == .macos) {
        _ = libc.system("sudo launchctl load /Library/LaunchDaemons/com.utmm.plist");
    } else if (builtin.os.tag != .windows) {
        _ = libc.system("sudo systemctl start utmm");
    }
    // Use raw exit to avoid any Zig runtime cleanup in signal context
    std.process.exit(0);
}

fn winCtrlHandler(dwCtrlType: u32) callconv(.winapi) u32 {
    // CTRL_CLOSE_EVENT = 2, CTRL_C_EVENT = 0, CTRL_BREAK_EVENT = 1
    _ = dwCtrlType;
    // Restart service — use system() for simplicity
    const kernel32 = struct {
        extern "kernel32" fn system(cmd: [*:0]const u8) callconv(.winapi) c_int;
    };
    _ = kernel32.system("sc start UTM-Monitor");
    return 1; // TRUE = event handled
}

test "agent run" {
    _ = run;
}
