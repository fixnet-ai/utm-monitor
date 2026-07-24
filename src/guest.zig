//! Guest mode — WebSocket client (v0.3.1).
//!
//! Persistent WebSocket to Host /ws replaces HTTP announce polling.
//! Host pushes commands in real-time via binary WS frames.
//! Upload/download use raw binary frames (no encoding).

const std = @import("std");
const builtin = @import("builtin");
const broadcast = @import("broadcast.zig");

/// Guest mode entry point (from std.process.Init)
pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli);
}

/// Guest mode entry point (called from Windows service or direct process start).
pub fn runWithIo(io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs) !void {
    // Collect system information (sync, uses blocking Io for process.run etc.)
    var sysinfo = try broadcast.getSystemInfo(io, gpa);
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

    std.debug.print("[guest] Hostname: {s}\n", .{sysinfo.hostname});
    std.debug.print("[guest] Target: {s}\n", .{sysinfo.target});
    std.debug.print("[guest] IP: {s}\n", .{sysinfo.ip});
    std.debug.print("[guest] MAC: {s}\n", .{sysinfo.mac});
    std.debug.print("[guest] Shell: {s}\n", .{sysinfo.shell});

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

    // Build host URL from --host-ip or default gateway (pass empty string to auto-detect)
    const host_url = if (cli.host_ip) |ip| blk: {
        break :blk try std.fmt.allocPrint(gpa, "{s}", .{ip});
    } else "";

    // Mesh session loop — persistent KCP tunnel, real-time push.
    // UpgradeSignal allows mesh LSA version check to signal the main loop
    // when a version mismatch is detected from Host broadcast.
    var upgrade_signal = broadcast.UpgradeSignal{};
    try broadcast.meshSessionLoop(io, gpa, sysinfo, host_url, &upgrade_signal, cli.mesh_port, cli.peer_mesh);
}
