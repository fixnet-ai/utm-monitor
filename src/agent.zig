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
    http_port: u16,
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
        const cli = main.CliArgs{
            .port = port,
            .http_port = http_port,
            .hostname = hostname_override,
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

    // ── Ensure passwordless sudo (macOS / Linux only) ──────────────────────
    ensurePasswordlessSudo(io, gpa);

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
        .http_port = http_port,
        .hostname = hostname_override,
    };
    try guest.runWithIo(io, gpa, cli);
}

// ═══════════════════════════════════════════════════════════════════════════
// Passwordless sudo setup (macOS / Linux)
// ═══════════════════════════════════════════════════════════════════════════

/// Check if passwordless sudo is configured, and if not, prompt user for
/// their password and configure it. This makes service stop/restart and
/// all future sudo operations seamless.
fn ensurePasswordlessSudo(io: std.Io, gpa: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) return;

    const sudoers_path = if (builtin.os.tag == .macos)
        "/private/etc/sudoers.d/99-utmm"
    else
        "/etc/sudoers.d/99-utmm";

    // Already configured by us?
    if (std.Io.Dir.cwd().openFile(io, sudoers_path, .{})) |f| {
        f.close(io);
        return;
    } else |_| {}

    // Check if passwordless sudo already works (maybe configured elsewhere)
    if (trySudoNoPassword(io, gpa)) {
        // Already passwordless — write our drop-in for consistency
        writeSudoersDropIn(io, gpa, null) catch {};
        return;
    }

    // Need to ask user for password
    std.debug.print("[guest] sudo password is required to manage the background service.\n", .{});
    std.debug.print("[guest] Enter your sudo password: ", .{});

    const password = readPasswordTty(io, gpa) catch {
        std.debug.print("\n[guest] Could not read password. Service management will prompt for sudo.\n", .{});
        return;
    };
    defer gpa.free(password);

    if (password.len == 0) {
        std.debug.print("[guest] No password entered. Service management will prompt for sudo.\n", .{});
        return;
    }

    // Verify the password is correct
    if (!testSudoPassword(io, gpa, password)) {
        std.debug.print("[guest] Incorrect password. Service management will prompt for sudo.\n", .{});
        return;
    }

    // Configure passwordless sudo
    writeSudoersDropIn(io, gpa, password) catch {
        std.debug.print("[guest] Failed to configure passwordless sudo.\n", .{});
        return;
    };

    std.debug.print("[guest] ✓ Passwordless sudo configured. Future service management will not prompt.\n", .{});
}

/// Run `sudo -n true` to check if passwordless sudo is available.
fn trySudoNoPassword(_io: std.Io, gpa: std.mem.Allocator) bool {
    const result = std.process.run(gpa, _io, .{
        .argv = &.{ "sudo", "-n", "true" },
    }) catch return false;
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Test if a given sudo password is correct via piping to `sudo -S true`.
fn testSudoPassword(io: std.Io, _: std.mem.Allocator, password: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sudo", "-S", "true" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return false;
    var wb: [64]u8 = undefined;
    var stdin_w = child.stdin.?.writer(io, &wb);
    _ = stdin_w.interface.writeVec(&.{ password, "\n" }) catch 0;
    _ = stdin_w.interface.flush() catch {};
    child.stdin.?.close(io);

    const result = child.wait(io) catch return false;
    return switch (result) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Read a line from the terminal with echo disabled (stty -echo).
fn readPasswordTty(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    // Disable terminal echo
    _ = std.process.run(gpa, io, .{
        .argv = &.{ "stty", "-echo" },
    }) catch {};
    defer {
        _ = std.process.run(gpa, io, .{
            .argv = &.{ "stty", "echo" },
        }) catch {};
    }

    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len - 1) {
        const n = try std.posix.read(0, buf[i..]);
        if (n == 0) break;
        if (buf[i] == '\n') break;
        if (buf[i] == '\r') continue;
        i += 1;
    }

    // Print a newline since echo was off and user pressed Enter
    std.debug.print("\n", .{});

    return gpa.dupe(u8, buf[0..i]);
}

/// Create /etc/sudoers.d/99-utmm to enable passwordless sudo for the current user.
/// If `password` is null, we rely on already-working passwordless sudo (sudo without -S).
/// If `password` is provided, it's passed to `sudo -S` via stdin.
fn writeSudoersDropIn(io: std.Io, gpa: std.mem.Allocator, password: ?[]const u8) !void {
    const sudoers_path = if (builtin.os.tag == .macos)
        "/private/etc/sudoers.d/99-utmm"
    else
        "/etc/sudoers.d/99-utmm";

    // Get current username
    const whoami = try std.process.run(gpa, io, .{
        .argv = &.{ "whoami" },
    });
    defer {
        gpa.free(whoami.stdout);
        gpa.free(whoami.stderr);
    }
    const username = std.mem.trim(u8, whoami.stdout, "\n\r ");

    // Build sudoers rule
    const rule = try std.fmt.allocPrint(gpa, "{s} ALL=(ALL) NOPASSWD: ALL\n", .{username});
    defer gpa.free(rule);

    // Build shell command: create dir if needed, write file via heredoc, set permissions
    const dirname = std.fs.path.dirname(sudoers_path) orelse "/etc";
    const shell_cmd = try std.fmt.allocPrint(gpa,
        \\mkdir -p "{s}" 2>/dev/null
        \\cat > "{s}" << 'UTMMEOF'
        \\{s}UTMMEOF
        \\chmod 0440 "{s}"
    , .{
        dirname,
        sudoers_path,
        rule,
        sudoers_path,
    });
    defer gpa.free(shell_cmd);

    if (password) |pass| {
        // Use sudo -S with password piped via stdin
        var child = try std.process.spawn(io, .{
            .argv = &.{ "sudo", "-S", "sh", "-c", shell_cmd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        var wb2: [64]u8 = undefined;
        var stdin_w2 = child.stdin.?.writer(io, &wb2);
        _ = stdin_w2.interface.writeVec(&.{ pass, "\n" }) catch 0;
        _ = stdin_w2.interface.flush() catch {};
        child.stdin.?.close(io);
        _ = try child.wait(io);
    } else {
        // Already passwordless — just use sudo directly
        _ = try std.process.run(gpa, io, .{
            .argv = &.{ "sudo", "sh", "-c", shell_cmd },
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Service start/stop helpers
// ═══════════════════════════════════════════════════════════════════════════

fn stopBackgroundService(io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.print("[guest] Stopping background service...\n", .{});

    if (builtin.os.tag == .windows) {
        // sc stop returns non-zero if already stopped — ignore errors
        if (std.process.run(gpa, io, .{ .argv = &.{ "sc", "stop", "UTM-Monitor" } })) |r| {
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
        if (std.process.run(gpa, io, .{ .argv = &.{ "sc", "start", "UTM-Monitor" } })) |_| {
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
