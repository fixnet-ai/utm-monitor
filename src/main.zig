//! UTM Monitor — Automatic VM IP sync tool
//!
//! Guest mode (default): UDP broadcast local IP + HTTP server
//! Host mode (--host): UDP listener + update /etc/hosts + management commands

const std = @import("std");
const protocol = @import("protocol.zig");
const guest = @import("guest.zig");
const host_mod = @import("host.zig");

comptime {
    _ = @import("hosts_file.zig");
    _ = @import("broadcast.zig");
    _ = @import("listener.zig");
    _ = @import("http_server.zig");
    _ = @import("http_client.zig");
    _ = @import("host_http.zig");
    _ = @import("install.zig");
    _ = @import("config.zig");
    _ = @import("status.zig");
    _ = @import("executor.zig");
    _ = @import("deploy.zig");
    _ = @import("ipc.zig");
    _ = @import("mcp.zig");
}

/// CLI parse result
pub const CliArgs = struct {
    /// Whether in Host mode
    is_host: bool = false,
    /// UDP port
    port: u16 = protocol.DEFAULT_PORT,
    /// HTTP server port (guest + host side)
    http_port: u16 = protocol.DEFAULT_HTTP_PORT,
    /// Guest hostname (default: auto-detect hostname)
    hostname: ?[]const u8 = null,
    /// hosts file path (host side)
    hosts_file: []const u8 = "/etc/hosts",
    /// hosts marker comment text
    marker: []const u8 = protocol.HOSTS_MARKER_BEGIN,
    /// Config file path
    config_path: ?[]const u8 = null,
    /// Log file path
    log_file: ?[]const u8 = null,
    /// Watch directory (--watch)
    watch_path: ?[]const u8 = null,
    /// HTTP serve directory for Host (--serve-dir), default: exe directory
    serve_dir: ?[]const u8 = null,
    /// Whether to save config
    save_config: bool = false,

    // Management commands
    cmd_status: bool = false,
    cmd_version: bool = false,
    cmd_deploy: bool = false,
    cmd_exec: bool = false,
    cmd_gen_init: bool = false,
    cmd_install: bool = false,
    cmd_uninstall: bool = false,
    is_mcp: bool = false,
    exec_target: ?[]const u8 = null,
    exec_cmd: ?[]const u8 = null,
    gen_init_platform: ?[]const u8 = null,
    deploy_target: ?[]const u8 = null,

    // Upload/download commands (Host mode, no external curl needed)
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
    var i: usize = 1; // Skip program name

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--host")) {
            cli.is_host = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            cli.cmd_status = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            cli.cmd_version = true;
        } else if (std.mem.eql(u8, arg, "--deploy")) {
            cli.cmd_deploy = true;
            // Optional target parameter
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                cli.deploy_target = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--gen-init")) {
            cli.cmd_gen_init = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.gen_init_platform = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--install")) {
            cli.cmd_install = true;
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
        } else if (std.mem.eql(u8, arg, "--watch")) {
            // --watch may take optional path
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                cli.watch_path = args[i];
            } else {
                cli.watch_path = ".";
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < args.len) cli.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--http-port")) {
            i += 1;
            if (i < args.len) {
                cli.http_port = try std.fmt.parseInt(u16, args[i], 10);
            }
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
        \\  (no args)           Default Guest mode (UDP broadcast + HTTP server)
        \\
        \\Guest options:
        \\  --hostname NAME     Local hostname (auto-detect by default)
        \\  --port PORT         UDP broadcast port (default 12345)
        \\  --http-port PORT    HTTP server port (default 2121)
        \\  --log-file PATH     Log file path
        \\
        \\Host options:
        \\  --port PORT         UDP listen port (default 12345)
        \\  --hosts-file PATH   hosts file path (default /etc/hosts)
        \\  --serve-dir PATH    HTTP serve directory (default: exe directory)
        \\  --marker TAG        Marker comment text (default "UTM-MONITOR")
        \\  --config PATH       Config file path (default ./utmm.conf)
        \\  --log-file PATH     Log file path
        \\  --watch [PATH]      Watch source directory for auto-deploy (default off)
        \\  --save-config       Save current parameters to config file
        \\
        \\Host management commands:
        \\  --status            Query all online guest status (with target/arch/os)
        \\  --exec TARGET CMD   Execute command on target guest (TARGET=hostname or FQDN)
        \\  --deploy [TARGET]   Auto compile+deploy to online guests (optional hostname)
        \\  --upload FILE VM    Upload a file to Guest VM (via HTTP, no curl needed)
        \\  --download VM REMOTE LOCAL  Download REMOTE from Guest VM → LOCAL file
        \\  --gen-init PLATFORM  Generate auto-start script (linux/macos/windows)
        \\  --install           Install as system service (Guest: auto-start; Host: with --host)
        \\  --uninstall         Remove system service (works in both Guest and Host mode)
        \\  --mcp               Serve MCP JSON-RPC over stdio for Claude Code integration
        \\                      (with --host: integrated mode, one process; without: IPC adapter)
        \\  --version           Show version info
        \\
    ;
    std.debug.print("{s}", .{help});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = try parseArgs(args);

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
    // --mcp alone: adapter mode (connect to Host IPC)
    const mcp = @import("mcp.zig");
    if (cli.is_mcp and !cli.is_host and !cli.cmd_status and !cli.cmd_deploy and !cli.cmd_exec and !cli.cmd_upload and !cli.cmd_download and !cli.cmd_gen_init and !cli.save_config and !cli.cmd_install and !cli.cmd_uninstall) {
        try mcp.run(init.io, init.gpa);
        return;
    }

    // --install/--uninstall work in both host and guest mode (install.zig uses cli.is_host)
    if (cli.is_host or cli.cmd_status or cli.cmd_deploy or cli.cmd_exec or cli.cmd_upload or cli.cmd_download or cli.cmd_gen_init or cli.save_config or cli.is_mcp) {
        try host_mod.run(init, cli);
    } else if (cli.cmd_install or cli.cmd_uninstall) {
        try host_mod.run(init, cli);
    } else {
        try guest.run(init, cli);
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

test "parseArgs - custom ports" {
    const args = &[_][:0]const u8{ "utmm", "--port", "9999", "--http-port", "2122" };
    const cli = try parseArgs(args);
    try std.testing.expectEqual(@as(u16, 9999), cli.port);
    try std.testing.expectEqual(@as(u16, 2122), cli.http_port);
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

test "parseArgs - watch default path" {
    const args = &[_][:0]const u8{ "utmm", "--host", "--watch" };
    const cli = try parseArgs(args);
    try std.testing.expectEqualStrings(".", cli.watch_path.?);
}

test "parseArgs - watch custom path" {
    const args = &[_][:0]const u8{ "utmm", "--host", "--watch", "./src" };
    const cli = try parseArgs(args);
    try std.testing.expectEqualStrings("./src", cli.watch_path.?);
}

test "parseArgs - version" {
    const args = &[_][:0]const u8{ "utmm", "--version" };
    const cli = try parseArgs(args);
    try std.testing.expect(cli.cmd_version);
}
