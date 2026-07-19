//! Guest mode orchestration
//! Start UDP broadcast loop + HTTP server + version check (three threads in parallel)

const std = @import("std");
const broadcast = @import("broadcast.zig");
const http_server = @import("http_server.zig");
const protocol = @import("protocol.zig");

/// Guest mode entry point (from std.process.Init)
pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli);
}

/// Guest mode entry point (called from Windows service or direct process start)
pub fn runWithIo(io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs) !void {

    // Collect system information
    var sysinfo = try broadcast.getSystemInfo(io, gpa);
    defer {
        gpa.free(sysinfo.hostname);
        gpa.free(sysinfo.ip);
        gpa.free(sysinfo.mac);
        gpa.free(sysinfo.iface_name);
    }
    // target is a compile-time constant, no need to free

    // If --hostname specified a custom name, override the auto-detected one
    if (cli.hostname) |n| {
        gpa.free(sysinfo.hostname);
        sysinfo.hostname = try gpa.dupe(u8, n);
    }

    std.debug.print("[guest] Hostname: {s}\n", .{sysinfo.hostname});
    std.debug.print("[guest] Target: {s}\n", .{sysinfo.target});
    std.debug.print("[guest] IP: {s}\n", .{sysinfo.ip});
    std.debug.print("[guest] MAC: {s}\n", .{sysinfo.mac});
    std.debug.print("[guest] Broadcast port: {d}\n", .{cli.port});
    std.debug.print("[guest] HTTP port: {d}\n", .{cli.http_port});

    // Ensure CWD is /opt/utmm/ (or C:\opt\utmm\ on Windows) so HTTP upload path
    // matches deployment destination. Windows Scheduled Tasks and services
    // default to C:\Windows\System32\ — explicitly redirect to C:\opt\utmm\.
    if (@import("builtin").os.tag == .windows) {
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

    // Start HTTP server thread
    const http_thread = try std.Thread.spawn(.{}, http_server.startServer, .{
        io,
        gpa,
        cli.http_port,
    });
    http_thread.detach();

    // Main thread runs broadcast loop.
    // is_svc: true when running as system daemon (--svc), enables self-upgrade.
    //         false when running in foreground, skips self-upgrade.
    try broadcast.broadcastLoop(io, cli.port, sysinfo, cli.http_port, cli.is_svc);
}
