//! UTM Monitor — Automatic VM IP sync tool
//!
//! Guest mode (default): UDP broadcast local IP + HTTP server
//! Host mode (--host): UDP listener + update /etc/hosts + management commands

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const guest = @import("guest.zig");
const host_mod = @import("host.zig");
const httpd = @import("httpd.zig");
const host_http = @import("host_http.zig");

// ── Windows Service integration types and externs (only compiled on Windows) ──
const windows = if (builtin.os.tag == .windows) std.os.windows else struct {
    pub const DWORD = u32;
    pub const BOOL = u32;
};

const SERVICE_WIN32_OWN_PROCESS = 0x00000010;
const SERVICE_RUNNING = 0x00000004;
const SERVICE_STOPPED = 0x00000001;
const SERVICE_ACCEPT_STOP = 0x00000001;
const SERVICE_CONTROL_STOP = 0x00000001;

const SERVICE_STATUS = extern struct {
    dwServiceType: u32,
    dwCurrentState: u32,
    dwControlsAccepted: u32,
    dwWin32ExitCode: u32,
    dwServiceSpecificExitCode: u32,
    dwCheckPoint: u32,
    dwWaitHint: u32,
};

const SERVICE_STATUS_HANDLE = *anyopaque;

const SvcMainFn = *const fn (dwNumServiceArgs: u32, lpServiceArgVectors: [*]?[*:0]const u16) callconv(.winapi) void;

const SERVICE_TABLE_ENTRYW = extern struct {
    lpServiceName: ?[*:0]const u16,
    lpServiceProc: ?SvcMainFn,
};

extern "advapi32" fn StartServiceCtrlDispatcherW(lpServiceStartTable: [*]const SERVICE_TABLE_ENTRYW) callconv(.winapi) u32;
extern "advapi32" fn RegisterServiceCtrlHandlerExW(lpServiceName: [*:0]const u16, lpHandlerProc: ?*const fn (dwControl: u32, dwEventType: u32, lpEventData: ?*anyopaque, lpContext: ?*anyopaque) callconv(.winapi) u32, lpContext: ?*anyopaque) callconv(.winapi) ?SERVICE_STATUS_HANDLE;
extern "advapi32" fn SetServiceStatus(hServiceStatus: ?SERVICE_STATUS_HANDLE, lpServiceStatus: *SERVICE_STATUS) callconv(.winapi) u32;

comptime {
    _ = @import("hosts_file.zig");
    _ = @import("broadcast.zig");
    _ = @import("install.zig");
    _ = @import("config.zig");
    _ = @import("mcp.zig");
    _ = @import("agent.zig");
}

/// CLI parse result
pub const CliArgs = struct {
    /// Whether in Host mode
    is_host: bool = false,
    /// UDP port (also used for TCP — unified on 2121)
    port: u16 = protocol.DEFAULT_PORT,
    /// Guest hostname (default: auto-detect hostname)
    hostname: ?[]const u8 = null,
    /// Host IP for Guest HTTP client (default: auto-detect via default gateway)
    host_ip: ?[]const u8 = null,
    /// hosts file path (host side)
    hosts_file: []const u8 = "/etc/hosts",
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
    /// Run as daemon via service manager (--svc, set by --install service configs)
    is_svc: bool = false,
    /// Run as foreground guest (stop service, run, restart on exit).
    /// When false and no management commands: run as daemon (pure guest, no service mgmt).
    /// This is the default mode when no flags are provided.

    // Management commands
    cmd_status: bool = false,
    cmd_version: bool = false,
    cmd_exec: bool = false,
    cmd_gen_init: bool = false,
    cmd_install: bool = false,
    cmd_uninstall: bool = false,
    /// Install as user-level service (LaunchAgent / user systemd) — for --agent
    is_user: bool = false,
    is_mcp: bool = false,
    exec_target: ?[]const u8 = null,
    exec_cmd: ?[]const u8 = null,
    gen_init_platform: ?[]const u8 = null,

    // Upload/download commands (Host mode, no external curl needed)
    cmd_upload: bool = false,
    upload_file: ?[]const u8 = null,
    upload_target: ?[]const u8 = null,
    cmd_download: bool = false,
    download_target: ?[]const u8 = null,
    download_remote: ?[]const u8 = null,
    download_local: ?[]const u8 = null,

    // exec-signal: send Ctrl+C to a running command
    cmd_exec_signal: bool = false,
    exec_signal_target: ?[]const u8 = null,
    exec_signal_cmd_id: ?[]const u8 = null,
};

/// Parse command-line arguments
pub fn parseArgs(args: []const [:0]const u8) !CliArgs {
    var cli = CliArgs{};
    var i: usize = 1; // Skip program name

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
        } else if (std.mem.eql(u8, arg, "--user")) {
            cli.is_user = true;
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
        } else if (std.mem.eql(u8, arg, "--exec-signal")) {
            cli.cmd_exec_signal = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.exec_signal_target = args[i];
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.exec_signal_cmd_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            cli.save_config = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < args.len) cli.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--hostname")) {
            i += 1;
            if (i < args.len) cli.hostname = args[i];
        } else if (std.mem.eql(u8, arg, "--hosts-file")) {
            i += 1;
            if (i < args.len) cli.hosts_file = args[i];
        } else if (std.mem.eql(u8, arg, "--serve-dir")) {
            i += 1;
            if (i < args.len) cli.serve_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--marker")) {
            i += 1;
            if (i < args.len) cli.marker = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i < args.len) cli.config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i < args.len) cli.log_file = args[i];
        }
    }

    return cli;
}

/// Print usage help
pub fn printHelp() void {
    const help =
        \\Usage: utmm [options]
        \\
        \\Mode selection:
        \\  --host              Run in Host mode (UDP listener + hosts management)
        \\  (no args)           Default Guest mode (stop service, foreground, restart on exit)
        \\  --svc               Run as daemon (launched by service manager, no service mgmt)
        \\
        \\Guest options:
        \\  --hostname NAME     Local hostname (auto-detect by default)
        \\  --host-ip IP        Host IP to connect to (auto-detect via gateway by default)
        \\  --port PORT         UDP broadcast + TCP server port (default 2121)
        \\  --log-file PATH     Log file path
        \\
        \\Host options:
        \\  --port PORT         UDP listen port (default 2121)
        \\  --hosts-file PATH   hosts file path (default /etc/hosts)
        \\  --serve-dir PATH    HTTP serve directory (default: exe directory)
        \\  --marker TAG        Marker comment text (default "UTM-MONITOR")
        \\  --config PATH       Config file path (default ./utmm.conf)
        \\  --log-file PATH     Log file path
        \\  --save-config       Save current parameters to config file
        \\
        \\Management commands (connect to persistent Host via IPC, no --host needed):
        \\  --status            Query all online guest status (with target/arch/os)
        \\  --exec TARGET CMD   Execute command on target guest (TARGET=hostname or FQDN)
        \\  --upload FILE VM    Upload a file to Guest VM (via HTTP, no curl needed)
        \\  --download VM REMOTE LOCAL  Download REMOTE from Guest VM → LOCAL file
        \\  --gen-init PLATFORM  Generate auto-start script (linux/macos/windows)
        \\  --install           Install as system service (daemon: utmm --host --install)
        \\  --install --user    Create desktop shortcut for foreground guest launcher
        \\  --uninstall         Remove system service (utmm --uninstall)
        \\  --uninstall --user  Remove desktop shortcut (utmm --uninstall --user)
        \\  --mcp               Deprecated; MCP now on --host HTTP :2121/mcp
        \\  --version           Show version info
        \\
        \\NOTE: --exec/--status/--upload/--download require a running Host background
        \\process (sudo utmm --host). Do NOT add --host to these commands — they
        \\talk to the Host via IPC, not by starting a new listener.
        \\
        \\Foreground Guest mode (default when no flags):
        \\  utmm                 Stop background service, run Guest in foreground,
        \\                       restart service on exit (Ctrl+C or close window)
        \\  utmm --hostname X    Override auto-detected hostname
        \\  utmm --install --user  Create desktop shortcut for foreground launcher
        \\
    ;
    std.debug.print("{s}", .{help});
}

/// Windows service globals — shared between service handler and service main
const SvcGlobals = struct {
    var status_handle: ?SERVICE_STATUS_HANDLE = null;
    var io_ptr: ?std.Io = null;
    var gpa_ptr: ?std.mem.Allocator = null;
    var cli_ptr: ?CliArgs = null;
};

fn svcCtrlHandler(dwControl: u32, _: u32, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) u32 {
    if (dwControl == SERVICE_CONTROL_STOP) {
        if (SvcGlobals.status_handle) |h| {
            var status = SERVICE_STATUS{
                .dwServiceType = SERVICE_WIN32_OWN_PROCESS,
                .dwCurrentState = SERVICE_STOPPED,
                .dwControlsAccepted = 0,
                .dwWin32ExitCode = 0,
                .dwServiceSpecificExitCode = 0,
                .dwCheckPoint = 0,
                .dwWaitHint = 0,
            };
            _ = SetServiceStatus(h, &status);
        }
        std.process.exit(0);
    }
    return 1;
}

fn svcMain(_: u32, _: [*]?[*:0]const u16) callconv(.winapi) void {
    const svc_name_utf16 = [_:0]u16{ 'U', 'T', 'M', '-', 'M', 'o', 'n', 'i', 't', 'o', 'r', 0 };
    const h = RegisterServiceCtrlHandlerExW(&svc_name_utf16, svcCtrlHandler, null);
    SvcGlobals.status_handle = h;

    if (h) |handle| {
        var status = SERVICE_STATUS{
            .dwServiceType = SERVICE_WIN32_OWN_PROCESS,
            .dwCurrentState = SERVICE_RUNNING,
            .dwControlsAccepted = SERVICE_ACCEPT_STOP,
            .dwWin32ExitCode = 0,
            .dwServiceSpecificExitCode = 0,
            .dwCheckPoint = 0,
            .dwWaitHint = 0,
        };
        _ = SetServiceStatus(handle, &status);
    }

    const svc_io = SvcGlobals.io_ptr orelse @panic("io_ptr not set");
    const svc_gpa = SvcGlobals.gpa_ptr orelse @panic("gpa_ptr not set");
    const svc_cli = SvcGlobals.cli_ptr orelse @panic("cli_ptr not set");

    if (svc_cli.is_host) {
        host_mod.runWithIo(svc_io, svc_gpa, svc_cli) catch |err| {
            std.debug.print("[svc] host run failed: {}\n", .{err});
        };
    } else {
        guest.runWithIo(svc_io, svc_gpa, svc_cli) catch |err| {
            std.debug.print("[svc] guest run failed: {}\n", .{err});
        };
    }

    if (h) |handle| {
        var status = SERVICE_STATUS{
            .dwServiceType = SERVICE_WIN32_OWN_PROCESS,
            .dwCurrentState = SERVICE_STOPPED,
            .dwControlsAccepted = 0,
            .dwWin32ExitCode = 0,
            .dwServiceSpecificExitCode = 0,
            .dwCheckPoint = 0,
            .dwWaitHint = 0,
        };
        _ = SetServiceStatus(handle, &status);
    }
}

/// Windows service entry point — runs Guest/Host loop as a proper Windows service.
/// Called when binary is started with --svc flag (added by sc create on --install).
fn winServiceRun(io: std.Io, gpa: std.mem.Allocator, cli: CliArgs) !void {
    SvcGlobals.io_ptr = io;
    SvcGlobals.gpa_ptr = gpa;
    SvcGlobals.cli_ptr = cli;

    const svc_name_utf16 = [_:0]u16{ 'U', 'T', 'M', '-', 'M', 'o', 'n', 'i', 't', 'o', 'r', 0 };
    var svc_table = [2]SERVICE_TABLE_ENTRYW{
        .{ .lpServiceName = &svc_name_utf16, .lpServiceProc = svcMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    const ok = StartServiceCtrlDispatcherW(&svc_table);
    if (ok == 0) {
        std.debug.print("[svc] StartServiceCtrlDispatcher failed (error: {})\n", .{std.os.windows.GetLastError()});
        return error.ServiceStartFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var cli = try parseArgs(args);

    // --svc (internal): run as system daemon — no service stop/restart.
    // On Windows this registers with SCM; on POSIX it just runs guest directly.
    // Must be checked before anything else so the service manager gets a clean
    // guest process without foreground mode's service management logic.
    if (cli.is_svc) {
        if (builtin.os.tag == .windows) {
            return winServiceRun(init.io, init.gpa, cli);
        }
        // POSIX: service manager launched us — just run guest directly
        try guest.run(init, cli);
        return;
    }

    // --version (single-line machine-readable format, for version sync script parsing)
    if (cli.cmd_version) {
        std.debug.print("utmm v{s}\n", .{protocol.VERSION});
        return;
    }

    // --help
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        printHelp();
        return;
    }

    // Mode dispatch
    // --mcp alone (no --host): MCP now integrated into Host HTTP server.
    // Redirect to --host which always serves /mcp on port 2121.
    if (cli.is_mcp and !cli.is_host and !cli.cmd_status and !cli.cmd_exec and !cli.cmd_upload and !cli.cmd_download and !cli.cmd_gen_init and !cli.save_config and !cli.cmd_install and !cli.cmd_uninstall and !cli.cmd_exec_signal) {
        std.log.info("[main] --mcp deprecated; MCP available via --host on port 2121. Use 'utmm --host' instead.", .{});
        return;
    }

    // Fault tolerance: --host is meaningless (and potentially confusing) when
    // used with management commands (--exec/--status/--upload/--download).
    // These commands always talk to the persistent Host via IPC first;
    // --host here would misleadingly suggest "run a new host instance".
    if (cli.cmd_exec or cli.cmd_status or cli.cmd_upload or cli.cmd_download or cli.cmd_exec_signal) {
        cli.is_host = false;
    }

    // --install/--uninstall work in both host and guest mode (install.zig uses cli.is_host)
    if (cli.is_host or cli.cmd_status or cli.cmd_exec or cli.cmd_upload or cli.cmd_download or cli.cmd_gen_init or cli.save_config or cli.is_mcp or cli.cmd_exec_signal) {
        try host_mod.run(init, cli);
    } else if (cli.cmd_install or cli.cmd_uninstall) {
        try host_mod.run(init, cli);
    } else {
        // Default Guest mode (foreground): stop background service, run Guest in
        // foreground with visible terminal, restart service on exit (Ctrl+C / close).
        // This gives the user GUI-aware exec access (runs in user session, not daemon).
        // System daemons use --svc to skip the stop/restart logic.
        const agent = @import("agent.zig");
        try agent.run(init.io, init.gpa, cli.hostname, cli.port);
    }
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
