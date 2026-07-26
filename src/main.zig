//! UTM Monitor — Automatic VM IP sync tool
//!
//! Guest mode (default): mesh LSA + KCP tunnel to Host
//! Host mode (--host): ensures Host service is running
//!
//! Self-copy model: binary copies itself to canonical path /opt/utmm/utmm[.exe].
//! All operations (except --version/--help) require root/Administrator.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const host_mod = @import("host.zig");
const broadcast = @import("broadcast.zig");
const svc = @import("svc.zig");
const fail = @import("fail.zig");
const mcp = @import("mcp.zig");

comptime {
    _ = @import("hosts_file.zig");
    _ = @import("config.zig");
    _ = @import("kcp.zig");
    _ = @import("mesh.zig");
    _ = @import("tunnel.zig");
    _ = @import("tunproto.zig");
    _ = @import("lock.zig");
    _ = @import("mcp.zig");
    _ = svc;
    _ = fail;
}

/// CLI parse result
pub const CliArgs = struct {
    /// Whether in Host mode
    is_host: bool = false,
    /// HTTP server port (Host mode)
    port: u16 = protocol.DEFAULT_PORT,
    /// Mesh UDP port for LSA + KCP
    mesh_port: u16 = protocol.DEFAULT_PORT,
    /// Direct peer mesh address for local testing
    peer_mesh: ?[]const u8 = null,
    /// Guest hostname (default: auto-detect)
    hostname: ?[]const u8 = null,
    /// Host IP for Guest HTTP client (default: auto-detect via default gateway)
    host_ip: ?[]const u8 = null,
    /// hosts file path (host side)
    hosts_file: []const u8 = if (builtin.os.tag == .windows)
        "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else
        "/etc/hosts",
    /// hosts marker comment text
    marker: []const u8 = protocol.HOSTS_MARKER_BEGIN,
    /// Config file path
    config_path: ?[]const u8 = null,
    /// Log file path
    log_file: ?[]const u8 = null,
    /// HTTP serve directory for Host (--serve-dir), default: exe directory
    serve_dir: ?[]const u8 = null,
    /// Whether to save config
    save_config: bool = false,
    /// Run as daemon via service manager (--svc, set by service configs)
    is_svc: bool = false,

    // Management commands
    cmd_status: bool = false,
    cmd_version: bool = false,
    cmd_exec: bool = false,
    cmd_gen_init: bool = false,
    cmd_install: bool = false,
    cmd_uninstall: bool = false,
    is_mcp: bool = false,
    exec_target: ?[]const u8 = null,
    exec_cmd: ?[]const u8 = null,
    gen_init_platform: ?[]const u8 = null,

    // Upload/download commands
    cmd_upload: bool = false,
    upload_file: ?[]const u8 = null,
    upload_target: ?[]const u8 = null,
    cmd_download: bool = false,
    download_target: ?[]const u8 = null,
    download_remote: ?[]const u8 = null,
    download_local: ?[]const u8 = null,
};

/// Parse command-line arguments
pub fn parseArgs(args: []const [:0]const u8) !CliArgs {
    var cli = CliArgs{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--host")) {
            cli.is_host = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            cli.cmd_status = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            cli.cmd_version = true;
        } else if (std.mem.eql(u8, arg, "--gen-init")) {
            cli.cmd_gen_init = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.gen_init_platform = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--install")) {
            cli.cmd_install = true;
        } else if (std.mem.eql(u8, arg, "--svc")) {
            cli.is_svc = true;
        } else if (std.mem.eql(u8, arg, "--uninstall")) {
            cli.cmd_uninstall = true;
        } else if (std.mem.eql(u8, arg, "--upload")) {
            cli.cmd_upload = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.upload_file = args[i];
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.upload_target = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--download")) {
            cli.cmd_download = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.download_target = args[i];
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.download_remote = args[i];
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.download_local = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            cli.is_mcp = true;
        } else if (std.mem.eql(u8, arg, "--host-ip")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.host_ip = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--exec")) {
            cli.cmd_exec = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.exec_target = args[i];
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.exec_cmd = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            cli.save_config = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.port = try std.fmt.parseInt(u16, args[i], 10);
            } else fail.msg("arg", "--port requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--mesh-port")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.mesh_port = try std.fmt.parseInt(u16, args[i], 10);
            } else fail.msg("arg", "--mesh-port requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--peer-mesh")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.peer_mesh = args[i];
            } else fail.msg("arg", "--peer-mesh requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--hostname")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.hostname = args[i];
            } else fail.msg("arg", "--hostname requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--hosts-file")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.hosts_file = args[i];
            } else fail.msg("arg", "--hosts-file requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--serve-dir")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.serve_dir = args[i];
            } else fail.msg("arg", "--serve-dir requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--marker")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.marker = args[i];
            } else fail.msg("arg", "--marker requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.config_path = args[i];
            } else fail.msg("arg", "--config requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.log_file = args[i];
            } else fail.msg("arg", "--log-file requires a value", .{});
        }
    }

    return cli;
}

/// Print usage help
pub fn printHelp() void {
    const help =
        \\Usage: utmm [options]
        \\
        \\Service management:
        \\  --install           Force install as system auto-start service (guest or host)
        \\  --uninstall         Remove system service and binary
        \\
        \\Mode selection:
        \\  --host              Ensure Host service is running (auto-installs if needed)
        \\  (no args)           Ensure Guest service is running (auto-installs if needed)
        \\  --svc               Internal: run as daemon (set by service manager)
        \\
        \\Guest options:
        \\  --hostname NAME     Local hostname (auto-detect by default)
        \\  --host-ip IP        Host IP to connect to (auto-detect via gateway by default)
        \\  --port PORT         Service port (default 2121)
        \\  --mesh-port PORT    Mesh UDP port (default 2121)
        \\  --peer-mesh ADDR    Direct peer mesh address for local testing
        \\  --log-file PATH     Log file path
        \\
        \\Host options:
        \\  --port PORT         Service port (default 2121)
        \\  --hosts-file PATH   hosts file path (default /etc/hosts)
        \\  --serve-dir PATH    HTTP serve directory (default: exe directory)
        \\  --marker TAG        Marker comment text (default "UTM-MONITOR")
        \\  --config PATH       Config file path
        \\  --log-file PATH     Log file path
        \\  --save-config       Save current parameters to config file
        \\
        \\Management commands (require Host service running):
        \\  --status            Query all online guest status
        \\  --exec TARGET CMD   Execute command on target guest
        \\  --upload FILE VM    Upload a file to Guest VM
        \\  --download VM REMOTE LOCAL  Download file from Guest VM
        \\  --gen-init PLATFORM Generate auto-start script (linux/macos/windows)
        \\  --version           Show version info
        \\
        \\NOTE: All operations require root/Administrator privileges.
        \\  POSIX: sudo utmm ...
        \\  Windows: Run as Administrator
        \\
        \\Install paths:
        \\  POSIX:   /opt/utmm/utmm
        \\  Windows: C:\\opt\\utmm\\utmm.exe
        \\
    ;
    std.debug.print("{s}", .{help});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var cli = try parseArgs(args);

    // ── 1. --version: print and exit (no admin needed) ──
    if (cli.cmd_version) {
        std.debug.print("utmm v{s}\n", .{protocol.VERSION});
        return;
    }

    // ── 2. --help: print and exit (no admin needed) ──
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        printHelp();
        return;
    }

    // ── 3. Admin privilege check — required for everything below ──
    if (!isAdmin()) {
        if (builtin.os.tag == .windows) {
            std.debug.print(
                \\[ERROR] Administrator privileges required.
                \\Please run this program as Administrator (right-click → "Run as Administrator").
                \\
            , .{});
        } else {
            std.debug.print(
                \\[ERROR] Root privileges required.
                \\Please run with: sudo utmm ...
                \\
            , .{});
        }
        std.process.exit(1);
    }

    // ── 4. --svc: run as daemon (internal flag set by service manager) ──
    if (cli.is_svc) {
        if (builtin.os.tag == .macos) {
            const role: svc.ServiceRole = if (cli.is_host) .host else .guest;
            svc.checkRetryLimit(init.io, init.gpa, role);
        }
        if (builtin.os.tag == .windows) {
            return svc.winServiceRun(
                init.io,
                init.gpa,
                cli.is_host,
                cli.hostname,
                cli.port,
                cli.mesh_port,
                cli.peer_mesh,
                cli.host_ip,
            );
        }
        // POSIX (non-macOS): run directly — service manager launched us
        if (cli.is_host) {
            try host_mod.runWithIo(init.io, init.gpa, cli, null);
        } else {
            try broadcast.guestRunWithIo(init.io, init.gpa, cli, null);
        }
        return;
    }

    // ── 5. --install: force install service ──
    if (cli.cmd_install) {
        const role: svc.ServiceRole = if (cli.is_host) .host else .guest;
        var extra_args = try buildServiceArgs(init.gpa, cli);
        defer extra_args.deinit(init.gpa);
        svc.forceInstall(init.io, init.gpa, role, extra_args.items);
        return;
    }

    // ── 6. --uninstall: remove service ──
    if (cli.cmd_uninstall) {
        try svc.uninstall(init.io, init.gpa);
        return;
    }

    // ── 7. Ensure Host service for --host and management commands ──
    // --status, --exec, --upload, --download all need the Host HTTP server.
    // Auto-start it if not running so users and AI agents can go directly
    // from "utmm --exec vm cmd" without a separate "utmm --host" step.
    const needs_host = cli.is_host or cli.cmd_status or cli.cmd_exec
        or cli.cmd_upload or cli.cmd_download or cli.is_mcp;
    if (needs_host) {
        const was_running = svc.isRunning(init.io, init.gpa, .host);
        var extra_args = try buildServiceArgs(init.gpa, cli);
        defer extra_args.deinit(init.gpa);
        svc.ensure(init.io, init.gpa, .host, extra_args.items);
        // --host alone (no management command): ensure + exit
        if (cli.is_host and !cli.cmd_status and !cli.cmd_exec
            and !cli.cmd_upload and !cli.cmd_download
            and !cli.cmd_gen_init and !cli.save_config and !cli.is_mcp) {
            return;
        }
        // If the service was just started, give it time to bind the HTTP port
        // before the management command connects. Service managers return before
        // the process has fully initialized.
        if (!was_running) {
            std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
    }

    // ── 8. Management commands ──
    if (cli.cmd_status or cli.cmd_exec or cli.cmd_upload or cli.cmd_download or cli.cmd_gen_init or cli.save_config) {
        cli.is_host = false; // management commands don't need --host
        try host_mod.run(init, cli);
        return;
    }

    // ── 9. --mcp: stdio MCP server (Host service already ensured above) ──
    if (cli.is_mcp) {
        try mcp.run(init.io, init.gpa, cli.port);
        return;
    }

    // ── 10. Default: ensure Guest service is running ──
    var extra_args_guest = try buildServiceArgs(init.gpa, cli);
    defer extra_args_guest.deinit(init.gpa);
    svc.ensure(init.io, init.gpa, .guest, extra_args_guest.items);
}

/// Build extra CLI arguments to embed in service config (--hostname, --port, etc.)
fn buildServiceArgs(alloc: std.mem.Allocator, cli: CliArgs) !std.ArrayListAligned([]const u8, null) {
    var args: std.ArrayListAligned([]const u8, null) = .empty;
    errdefer args.deinit(alloc);

    if (cli.hostname) |h| {
        const arg = try alloc.dupe(u8, "--hostname");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
        const val = try alloc.dupe(u8, h);
        errdefer alloc.free(val);
        try args.append(alloc, val);
    }
    if (cli.host_ip) |h| {
        const arg = try alloc.dupe(u8, "--host-ip");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
        const val = try alloc.dupe(u8, h);
        errdefer alloc.free(val);
        try args.append(alloc, val);
    }
    if (cli.port != protocol.DEFAULT_PORT) {
        const arg = try alloc.dupe(u8, "--port");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
        const port_str = try std.fmt.allocPrint(alloc, "{d}", .{cli.port});
        errdefer alloc.free(port_str);
        try args.append(alloc, port_str);
    }
    if (cli.mesh_port != protocol.DEFAULT_PORT) {
        const arg = try alloc.dupe(u8, "--mesh-port");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
        const port_str = try std.fmt.allocPrint(alloc, "{d}", .{cli.mesh_port});
        errdefer alloc.free(port_str);
        try args.append(alloc, port_str);
    }
    if (cli.peer_mesh) |p| {
        const arg = try alloc.dupe(u8, "--peer-mesh");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
        const val = try alloc.dupe(u8, p);
        errdefer alloc.free(val);
        try args.append(alloc, val);
    }

    return args;
}

test "parseArgs - default guest mode" {
    const args = &[_][:0]const u8{"utmm"};
    const cli = try parseArgs(args);
    try std.testing.expect(!cli.is_host);
    try std.testing.expectEqual(protocol.DEFAULT_PORT, cli.port);
}

test "parseArgs - host mode" {
    const args = &[_][:0]const u8{ "utmm", "--host" };
    const cli = try parseArgs(args);
    try std.testing.expect(cli.is_host);
}

test "parseArgs - custom port" {
    const args = &[_][:0]const u8{ "utmm", "--port", "9999" };
    const cli = try parseArgs(args);
    try std.testing.expectEqual(@as(u16, 9999), cli.port);
}

test "parseArgs - management commands" {
    const args = &[_][:0]const u8{ "utmm", "--status" };
    const cli = try parseArgs(args);
    try std.testing.expect(cli.cmd_status);
}

test "parseArgs - exec command" {
    const args = &[_][:0]const u8{ "utmm", "--exec", "mybox", "uptime" };
    const cli = try parseArgs(args);
    try std.testing.expect(cli.cmd_exec);
    try std.testing.expectEqualStrings("mybox", cli.exec_target.?);
    try std.testing.expectEqualStrings("uptime", cli.exec_cmd.?);
}

test "parseArgs - hostname" {
    const args = &[_][:0]const u8{ "utmm", "--hostname", "my-custom-box" };
    const cli = try parseArgs(args);
    try std.testing.expectEqualStrings("my-custom-box", cli.hostname.?);
}

test "parseArgs - version" {
    const args = &[_][:0]const u8{ "utmm", "--version" };
    const cli = try parseArgs(args);
    try std.testing.expect(cli.cmd_version);
}

// ═══════════════════════════════════════════════════════════════════════════
// Admin privilege check (曾 priv.zig)
// ═══════════════════════════════════════════════════════════════════════════

/// Check whether the current process has admin/root privileges.
fn isAdmin() bool {
    if (builtin.os.tag == .windows) {
        return isWindowsAdmin();
    }
    return std.c.geteuid() == 0;
}

/// Windows: check token membership in the Administrators group (S-1-5-32-544).
fn isWindowsAdmin() bool {
    const w = std.os.windows;
    const BOOL = w.BOOL;
    const HANDLE = w.HANDLE;

    const NtAuthority: [6]u8 = [_]u8{ 0, 0, 0, 0, 0, 5 };
    const SECURITY_BUILTIN_DOMAIN_RID: u32 = 32;
    const DOMAIN_ALIAS_RID_ADMINS: u32 = 544;

    const AllocateAndInitializeSid = @extern(
        *const fn (pIdentifierAuthority: *const [6]u8, nSubAuthorityCount: u8, nSubAuthority0: u32, nSubAuthority1: u32, nSubAuthority2: u32, nSubAuthority3: u32, nSubAuthority4: u32, nSubAuthority5: u32, nSubAuthority6: u32, nSubAuthority7: u32, ppSid: *?*anyopaque) callconv(.winapi) BOOL,
        .{ .name = "AllocateAndInitializeSid", .library_name = "advapi32" },
    );
    const FreeSid = @extern(
        *const fn (pSid: ?*anyopaque) callconv(.winapi) ?*anyopaque,
        .{ .name = "FreeSid", .library_name = "advapi32" },
    );
    const CheckTokenMembership = @extern(
        *const fn (TokenHandle: ?HANDLE, SidToCheck: ?*anyopaque, IsMember: *BOOL) callconv(.winapi) BOOL,
        .{ .name = "CheckTokenMembership", .library_name = "advapi32" },
    );

    var admin_sid: ?*anyopaque = null;
    if (@intFromEnum(AllocateAndInitializeSid(
        @ptrCast(&NtAuthority),
        2,
        SECURITY_BUILTIN_DOMAIN_RID,
        DOMAIN_ALIAS_RID_ADMINS,
        0, 0, 0, 0, 0, 0,
        &admin_sid,
    )) == 0) return false;
    defer _ = FreeSid(admin_sid);

    var is_member: BOOL = .FALSE;
    _ = CheckTokenMembership(null, admin_sid, &is_member);
    return is_member != .FALSE;
}

test "isAdmin does not crash" {
    _ = isAdmin();
}

test "isAdmin returns bool" {
    const result = isAdmin();
    _ = switch (result) {
        true => "admin",
        false => "not admin",
    };
}
