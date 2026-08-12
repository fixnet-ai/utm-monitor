//! UTM Monitor — Remote machine management via TCP/SOCKS5.
//!
//! Guest mode (default): LSA mesh broadcast + TCP listener on port 2121.
//!   Host connects to Guest via SOCKS5 proxy for exec/upload/download.
//! Host mode (--host): LSA node table + IPC socket for CLI/MCP commands.
//!
//! Self-copy model: binary copies itself to canonical path /opt/utmm/utmm[.exe].
//! Service lifecycle managed by utmmd supervisor (shm heartbeat + crash recovery).
//! All operations (except --version/--help) require root/Administrator.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const protocol = @import("protocol.zig");
const host_mod = @import("host.zig");
const guest = @import("guest.zig");
const svc = @import("svc.zig");
const fail = @import("fail.zig");
const mcp = @import("mcp.zig");
const shm = @import("shm.zig");
const sshpass = @import("sshpass.zig");

/// Embedded utmmd binary — compiled at build time, extracted at install time.
/// Target-specific: embed/{arch}-{os}/utmmd.bin, selected at comptime via builtin.
const utmmd_bin: []const u8 = switch (builtin.cpu.arch) {
    .aarch64 => switch (builtin.os.tag) {
        .linux => @as([]const u8, @embedFile("embed/aarch64-linux/utmmd.bin")),
        .macos => @as([]const u8, @embedFile("embed/aarch64-macos/utmmd.bin")),
        .windows => @as([]const u8, @embedFile("embed/aarch64-windows/utmmd.bin")),
        else => @compileError("unsupported OS for aarch64: " ++ @tagName(builtin.os.tag)),
    },
    .x86_64 => switch (builtin.os.tag) {
        .linux => @as([]const u8, @embedFile("embed/x86_64-linux/utmmd.bin")),
        .macos => @as([]const u8, @embedFile("embed/x86_64-macos/utmmd.bin")),
        .windows => @as([]const u8, @embedFile("embed/x86_64-windows/utmmd.bin")),
        else => @compileError("unsupported OS for x86_64: " ++ @tagName(builtin.os.tag)),
    },
    .x86 => switch (builtin.os.tag) {
        .linux => @as([]const u8, @embedFile("embed/x86-linux/utmmd.bin")),
        .windows => @as([]const u8, @embedFile("embed/x86-windows/utmmd.bin")),
        else => @compileError("unsupported OS for x86: " ++ @tagName(builtin.os.tag)),
    },
    else => @compileError("unsupported arch: " ++ @tagName(builtin.cpu.arch)),
};

/// SHA256 hex string of the embedded utmmd binary (64 chars, pre-computed by build.zig).
/// Used to determine whether the installed utmmd needs updating.
/// Target-specific: embed/{arch}-{os}/utmmd.sha256, selected at comptime via builtin.
const utmmd_sha256_hex: [:0]const u8 = switch (builtin.cpu.arch) {
    .aarch64 => switch (builtin.os.tag) {
        .linux => @embedFile("embed/aarch64-linux/utmmd.sha256"),
        .macos => @embedFile("embed/aarch64-macos/utmmd.sha256"),
        .windows => @embedFile("embed/aarch64-windows/utmmd.sha256"),
        else => @compileError("unsupported OS for aarch64: " ++ @tagName(builtin.os.tag)),
    },
    .x86_64 => switch (builtin.os.tag) {
        .linux => @embedFile("embed/x86_64-linux/utmmd.sha256"),
        .macos => @embedFile("embed/x86_64-macos/utmmd.sha256"),
        .windows => @embedFile("embed/x86_64-windows/utmmd.sha256"),
        else => @compileError("unsupported OS for x86_64: " ++ @tagName(builtin.os.tag)),
    },
    .x86 => switch (builtin.os.tag) {
        .linux => @embedFile("embed/x86-linux/utmmd.sha256"),
        .windows => @embedFile("embed/x86-windows/utmmd.sha256"),
        else => @compileError("unsupported OS for x86: " ++ @tagName(builtin.os.tag)),
    },
    else => @compileError("unsupported arch: " ++ @tagName(builtin.cpu.arch)),
};

/// Embedded ssh.exe for Windows targets — extracted to canonical directory
/// so sshpass can always find it even when system OpenSSH is not in PATH.
/// Target-specific: embed/{arch}-{os}/ssh.exe, selected at comptime via builtin.
/// Empty on non-Windows. x86 (32-bit) reuses the x86_64 binary — CreateProcessW
/// handles cross-architecture launch, and 32-bit-only Windows is essentially extinct.
const ssh_exe_bin: []const u8 = if (builtin.os.tag == .windows) switch (builtin.cpu.arch) {
    .aarch64 => @embedFile("embed/aarch64-windows/ssh.exe"),
    .x86_64, .x86 => @embedFile("embed/x86_64-windows/ssh.exe"),
    else => &.{},
} else &.{};

comptime {
    _ = @import("lsa.zig");
    _ = @import("config.zig");
    _ = @import("tcp.zig");
    _ = @import("protocol.zig");
    _ = @import("socks5.zig");
    _ = @import("mcp.zig");
    _ = @import("host.zig");
    _ = @import("sshpass.zig");
    _ = svc;
    _ = fail;
}

/// CLI parse result
pub const CliArgs = struct {
    /// Whether in Host mode
    is_host: bool = false,
    /// TCP listen + UDP LSA port (Host and Guest, default 2121)
    port: u16 = protocol.DEFAULT_PORT,
    /// LSA broadcast UDP port (may differ from `port` for testing)
    mesh_port: u16 = protocol.DEFAULT_PORT,
    /// Direct peer LSA address for local testing (skip broadcast)
    peer_mesh: ?[]const u8 = null,
    /// Guest hostname (default: auto-detect)
    hostname: ?[]const u8 = null,
    /// Host IP override for Guest (default: auto-detect via default gateway)
    host_ip: ?[]const u8 = null,
    /// hosts file path (host side)
    hosts_file: []const u8 = if (builtin.os.tag == .windows)
        "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else
        "/etc/hosts",
    /// hosts marker comment text
    marker: []const u8 = protocol.HOSTS_MARKER_BEGIN,
    /// Log file path
    log_file: ?[]const u8 = null,
    /// Binary serve directory for Host upgrade push (--serve-dir), default: exe directory
    serve_dir: ?[]const u8 = null,
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

    // Ping command
    cmd_ping: bool = false,
    ping_target: ?[]const u8 = null,

    // Deploy command
    cmd_deploy: bool = false,
    deploy_target: ?[]const u8 = null,

    // Upgrade command
    cmd_upgrade: bool = false,
    upgrade_target: ?[]const u8 = null,

    // Upload/download commands
    cmd_upload: bool = false,
    upload_file: ?[]const u8 = null,
    upload_target: ?[]const u8 = null,
    cmd_download: bool = false,
    download_target: ?[]const u8 = null,
    download_remote: ?[]const u8 = null,
    download_local: ?[]const u8 = null,

    // sshpass subcommand
    cmd_sshpass: bool = false,
};

/// Parse command-line arguments
pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !CliArgs {
    var cli = CliArgs{};
    var i: usize = 1;

    // sshpass 子命令检测（必须在其他选项之前，因为 sshpass 有自己的参数解析）
    if (args.len > 1 and std.mem.eql(u8, args[1], "sshpass")) {
        cli.cmd_sshpass = true;
        return cli;
    }

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
                cli.upload_target = try std.ascii.allocLowerString(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--download")) {
            cli.cmd_download = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.download_target = try std.ascii.allocLowerString(allocator, args[i]);
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
                cli.exec_target = try std.ascii.allocLowerString(allocator, args[i]);
            }
            if (i + 1 < args.len) {
                i += 1;
                cli.exec_cmd = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--deploy")) {
            cli.cmd_deploy = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                cli.deploy_target = try std.ascii.allocLowerString(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--ping")) {
            cli.cmd_ping = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.ping_target = try std.ascii.allocLowerString(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--upgrade")) {
            cli.cmd_upgrade = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.upgrade_target = try std.ascii.allocLowerString(allocator, args[i]);
            }
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
                cli.hostname = try std.ascii.allocLowerString(allocator, args[i]);
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
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            if (i + 1 < args.len) {
                i += 1;
                cli.log_file = args[i];
            } else fail.msg("arg", "--log-file requires a value", .{});
        }
    }

    // ── Validate required parameters ──
    if (cli.cmd_ping and cli.ping_target == null) {
        fail.msg("arg", "--ping requires a target hostname", .{});
    }
    if (cli.cmd_exec and (cli.exec_target == null or cli.exec_cmd == null)) {
        fail.msg("arg", "--exec requires TARGET and COMMAND", .{});
    }
    if (cli.cmd_upload and (cli.upload_target == null or cli.upload_file == null)) {
        fail.msg("arg", "--upload requires FILE and TARGET", .{});
    }
    if (cli.cmd_download and (cli.download_target == null or cli.download_remote == null)) {
        fail.msg("arg", "--download requires TARGET REMOTE_PATH [LOCAL_PATH]", .{});
    }
    if (cli.cmd_upgrade and cli.upgrade_target == null) {
        fail.msg("arg", "--upgrade requires a target hostname", .{});
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
        \\  --mcp               Print MCP HTTP endpoint URL and ensure Host daemon
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
        \\  --serve-dir PATH    Binary serve directory for upgrade push (default: exe directory)
        \\  --marker TAG        Marker comment text (default "UTM-MONITOR")
        \\  --log-file PATH     Log file path
        \\
        \\Management commands (require Host service running):
        \\  --status            Query all online guest status
        \\  --deploy [TARGET]   Cross-compile, SCP, install & verify guest(s)
        \\  --ping TARGET       Ping a guest via LSA mesh (Host→Guest)
        \\  --exec TARGET CMD   Execute command on target guest
        \\  --upload FILE VM    Upload a file to Guest VM
        \\  --download VM REMOTE LOCAL  Download file from Guest VM
        \\  --upgrade VM        Push upgrade binary to Guest VM
        \\  --gen-init PLATFORM Generate auto-start script (linux/macos/windows)
        \\  --version           Show version info
        \\
        \\
        \\  sshpass [-p PASS|-f FILE|-d FD|-e] [-hV] command [args...]
        \\                    Non-interactive SSH password authentication
        \\                    -p PASS   Password from command line
        \\                    -f FILE   Password from file (first line)
        \\                    -d FD     Password from file descriptor
        \\                    -e        Password from SSHPASS env var
        \\                    -h        Show help and exit
        \\                    -V        Print version and exit
        \\                    ConPTY (Windows pseudo-terminal) support detected
        \\                    automatically — important for MCP SSH operations
        \\
        \\NOTE: All operations require root/Administrator privileges.
        \\  sshpass does not require root privileges.
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
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var cli = try parseArgs(allocator, args);

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

    // ── 3. sshpass: non-interactive SSH authentication (no admin needed) ──
    if (cli.cmd_sshpass) {
        sshpass.main(allocator, args);
    }

    // ── 4. Admin privilege check — required for everything below ──
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

    // ── 5. --svc: spawned by utmmd supervisor ──
    // utmmd creates shared memory before spawning us. Open it and register
    // our PID so utmmd can monitor our heartbeat.
    if (cli.is_svc) {
        var shm_handle: ?*volatile shm.ShmLayout = null;
        if (shm.open()) |h| {
            shm_handle = h;
            h.utmm_pid = svc.getOwnPid();
            h.utmm_state = @intFromEnum(shm.UtmmState.running);
            std.log.info("[main] shm connected, pid={d}", .{svc.getOwnPid()});
        } else |err| {
            std.log.warn("[main] shm.open failed: {} — running without supervisor heartbeat", .{err});
        }
        // 心跳在主 accept 循环中更新（不再使用独立线程）。
        // 这样 utmmd 能检测到阻塞的 utmm 进程：如果 accept 循环卡住，
        // 心跳停止更新 → utmmd 10s 超时触发重启。

        // Collect system info with BLOCKING init.io BEFORE creating zio Runtime.
        // zio's IOCP-based IO is incompatible with std.process.run on Windows
        // (route print, getmac, powershell hang when using IOCP IO).
        const sysinfo = guest.getSystemInfo(init.io, init.gpa) catch blk2: {
            std.log.err("[main] getSystemInfo failed — using fallback", .{});
            break :blk2 guest.SystemInfo{
                .hostname = try init.gpa.dupe(u8, "unknown"),
                .ip = try init.gpa.dupe(u8, "0.0.0.0"),
                .mac = try init.gpa.dupe(u8, "00:00:00:00:00:00"),
                .target = try init.gpa.dupe(u8, @tagName(builtin.cpu.arch)),
                .iface_name = try init.gpa.dupe(u8, "unknown"),
                .shell = try init.gpa.dupe(u8, "cmd.exe"),
            };
        };

        // Create zio async Runtime — replaces blocking init.io with coroutine-based I/O.
        // The Runtime owns the event loop and worker threads; rt.io() provides a
        // std.Io backed by async I/O (io_uring/epoll/kqueue/iocp) under the hood.
        // min_threads=8: IPC accept (1) + pushUpgrade (up to 4 concurrent) + handlers.
        var rt = try zio.Runtime.init(init.gpa, .{
            .thread_pool = .{ .min_threads = 8 },
        });
        defer rt.deinit();
        const rt_io = rt.io();

        if (cli.is_host) {
            try host_mod.runWithIo(rt, rt_io, init.gpa, cli, null, shm_handle);
        } else {
            try guest.guestRunWithIo(rt_io, init.gpa, cli, null, shm_handle, sysinfo);
        }
        if (shm_handle) |h| {
            h.utmm_state = @intFromEnum(shm.UtmmState.stopping);
            shm.detach(h);
        }
        return;
    }

    // ── 6. --install: force install service ──
    // Extract utmmd (the supervisor daemon) to canonical path, then
    // force-install it as the system service. utmmd manages utmm's lifecycle.
    if (cli.cmd_install) {
        const role: svc.ServiceRole = if (cli.is_host) .host else .guest;
        try extractUtmmd(init.io, init.gpa);
        var extra_args = try buildServiceArgs(init.gpa, cli, role);
        defer {
            for (extra_args.items) |item| init.gpa.free(@constCast(item));
            extra_args.deinit(init.gpa);
        }
        svc.forceInstall(init.io, init.gpa, role, extra_args.items);
        svc.saveUtmmdMeta(init.io, init.gpa, role, extra_args.items, utmmd_sha256_hex);
        return;
    }

    // ── 7. --uninstall: remove service ──
    if (cli.cmd_uninstall) {
        try svc.uninstall(init.io, init.gpa);
        return;
    }

    // ── 8. Ensure Host service for --host and management commands ──
    // --status, --exec, --upload, --download all need the Host daemon (IPC socket).
    // Auto-start it if not running so users and AI agents can go directly
    // from "utmm --exec vm cmd" without a separate "utmm --host" step.
    const needs_host = cli.is_host or cli.cmd_status or cli.cmd_exec or cli.cmd_ping
        or cli.cmd_upload or cli.cmd_download or cli.is_mcp
        or cli.cmd_deploy or cli.cmd_upgrade;
    if (needs_host) {
        const was_running = svc.isRunning(init.io, init.gpa, .host);
        var extra_args = try buildServiceArgs(init.gpa, cli, .host);
        defer {
            for (extra_args.items) |item| init.gpa.free(@constCast(item));
            extra_args.deinit(init.gpa);
        }

        if (svc.shouldUpdateUtmmd(init.io, init.gpa, utmmd_sha256_hex)) {
            // utmmd needs update — extract to temp, upgrade (disable→stop→kill→replace→enable→start)
            const tmp_path = try extractUtmmdToTemp(init.io, init.gpa);
            svc.upgradeUtmmd(init.io, init.gpa, .host, extra_args.items, tmp_path, utmmd_sha256_hex);
            init.gpa.free(tmp_path);
        } else if (!was_running) {
            // 3b path: utmmd unchanged, just start the service (skip reinstall)
            std.log.info("[main] utmmd unchanged, starting service directly", .{});
            svc.start(init.io, init.gpa, .host, extra_args.items) catch |err| {
                std.log.err("[main] start failed: {} — falling back to ensure", .{err});
                extractUtmmdIfMissing(init.io, init.gpa) catch {};
                svc.ensure(init.io, init.gpa, .host, extra_args.items);
            };
        }
        // else: utmmd fine and service already running; management cmds can proceed

        // --host alone (no management command): ensure + exit
        if (cli.is_host and !cli.cmd_status and !cli.cmd_exec and !cli.cmd_ping
            and !cli.cmd_upload and !cli.cmd_download
            and !cli.cmd_gen_init and !cli.is_mcp
            and !cli.cmd_deploy and !cli.cmd_upgrade) {
            return;
        }
        // If the service was just started, give it time to bind the IPC socket
        // and begin LSA broadcast before the management command connects.
        if (!was_running) {
            std.Io.sleep(init.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
    }

    // ── 9. Management commands ──
    if (cli.cmd_status or cli.cmd_exec or cli.cmd_ping or cli.cmd_upload or cli.cmd_download or cli.cmd_gen_init or cli.cmd_deploy or cli.cmd_upgrade) {
        cli.is_host = false; // reset: Host ensured above, run() just dispatches commands
        try host_mod.run(init, cli);
        return;
    }

    // ── 10. --mcp: print MCP HTTP endpoint (Host service already ensured above) ──
    if (cli.is_mcp) {
        std.debug.print("MCP endpoint: http://127.0.0.1:{d}/\n", .{cli.port});
        return;
    }

    // ── 11. Default: ensure Guest service is running ──
    {
        const was_running = svc.isRunning(init.io, init.gpa, .guest);
        var extra_args_guest = try buildServiceArgs(init.gpa, cli, .guest);
        defer {
            for (extra_args_guest.items) |item| init.gpa.free(@constCast(item));
            extra_args_guest.deinit(init.gpa);
        }

        if (svc.shouldUpdateUtmmd(init.io, init.gpa, utmmd_sha256_hex)) {
            const tmp_path = try extractUtmmdToTemp(init.io, init.gpa);
            svc.upgradeUtmmd(init.io, init.gpa, .guest, extra_args_guest.items, tmp_path, utmmd_sha256_hex);
            init.gpa.free(tmp_path);
        } else if (!was_running) {
            // 3b path: utmmd unchanged, just start the service (skip reinstall)
            std.log.info("[main] utmmd unchanged, starting guest service directly", .{});
            svc.start(init.io, init.gpa, .guest, extra_args_guest.items) catch |err| {
                std.log.err("[main] start failed: {} — falling back to ensure", .{err});
                extractUtmmdIfMissing(init.io, init.gpa) catch {};
                svc.ensure(init.io, init.gpa, .guest, extra_args_guest.items);
            };
        }
    }
}

/// Write the embedded utmmd binary to the canonical service path.
/// Validates the binary type before writing. Always overwrites.
/// 提取嵌入的 utmmd 到临时文件，返回路径（调用者负责 free）。
fn extractUtmmdToTemp(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const dest_dir = svc.canonicalDir();
    std.Io.Dir.cwd().createDirPath(io, dest_dir) catch |err| {
        fail.err("extractUtmmdTmp/mkdir", err);
    };
    const tmp_path = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\utmmd-new.exe", .{dest_dir})
    else
        try std.fmt.allocPrint(alloc, "{s}/utmmd-new", .{dest_dir});
    errdefer alloc.free(tmp_path);

    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    const cwd = std.Io.Dir.cwd();
    const dst = if (builtin.os.tag != .windows)
        cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = @enumFromInt(0o755) }) catch |err| {
            fail.err("extractUtmmdTmp/create", err);
        }
    else
        cwd.createFile(io, tmp_path, .{ .truncate = true }) catch |err| {
            fail.err("extractUtmmdTmp/create", err);
        };
    defer dst.close(io);

    var write_buf: [65536]u8 = undefined;
    var writer = dst.writer(io, &write_buf);
    writer.interface.writeAll(utmmd_bin) catch |err| { fail.err("extractUtmmdTmp/write", err); };
    writer.interface.flush() catch |err| { std.log.warn("[main] extractUtmmdTmp flush: {}", .{err}); };
    dst.sync(io) catch |err| { std.log.warn("[main] extractUtmmdTmp sync: {}", .{err}); };

    return tmp_path;
}

fn extractUtmmd(io: std.Io, alloc: std.mem.Allocator) !void {
    const dest = svc.canonicalSvcPath();
    const dest_dir = svc.canonicalDir();

    // Ensure canonical directory exists
    std.Io.Dir.cwd().createDirPath(io, dest_dir) catch |err| {
        fail.err("extractUtmmd/mkdir", err);
    };

    // Write to temp file first, then rename (atomic on same filesystem)
    const tmp_path = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\utmmd.tmp.exe", .{dest_dir})
    else
        try std.fmt.allocPrint(alloc, "{s}/utmmd.tmp", .{dest_dir});
    defer alloc.free(tmp_path);

    // Remove stale tmp file
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Write the embedded binary
    {
        const cwd = std.Io.Dir.cwd();
        const dst_file = if (builtin.os.tag != .windows)
            cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = @enumFromInt(0o755) })
        else
            cwd.createFile(io, tmp_path, .{ .truncate = true });
        const dst = dst_file catch |err| {
            fail.err("extractUtmmd/create", err);
        };
        defer dst.close(io);

        var write_buf: [65536]u8 = undefined;
        var writer = dst.writer(io, &write_buf);
        writer.interface.writeAll(utmmd_bin) catch |err| {
            fail.err("extractUtmmd/write", err);
        };
        writer.interface.flush() catch |err| {
            std.log.warn("[main] extractUtmmd flush: {}", .{err});
        };
        dst.sync(io) catch |err| {
            std.log.warn("[main] extractUtmmd sync: {}", .{err});
        };
    }

    // On Windows, if utmmd.exe is running (e.g. old service not cleanly stopped),
    // the rename below fails with AccessDenied. Kill utmmd first via Toolhelp API.
    if (builtin.os.tag == .windows) {
        svc.killUtmmd();
        // Brief sleep so the OS releases the file lock.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    }

    // Atomic rename tmp → dest
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dest, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        // On EXDEV (cross-filesystem), try copy+delete fallback
        if (err == error.CrossDevice) {
            copyFile(io, alloc, tmp_path, dest, builtin.os.tag != .windows) catch |err2| {
                fail.err("extractUtmmd/copy-fallback", err2);
            };
            // macOS: re-sign after copy
            if (builtin.os.tag == .macos) {
                const result = std.process.run(alloc, io, .{ .argv = &.{ "codesign", "--force", "--sign", "-", dest } });
                if (result) |r| {
                    alloc.free(r.stdout);
                    alloc.free(r.stderr);
                    if (r.term != .exited or r.term.exited != 0) {
                        std.log.warn("[main] extractUtmmd: codesign re-sign failed", .{});
                    }
                } else |_| {
                    std.log.warn("[main] extractUtmmd: codesign not found", .{});
                }
            }
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        } else if (builtin.os.tag == .windows and err == error.AccessDenied) {
            // Retry once after killing utmmd — file may still be locked briefly
            std.log.warn("[main] extractUtmmd rename AccessDenied after killUtmmd, retrying...", .{});
            svc.killUtmmd();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
            std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dest, io) catch |err2| {
                std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
                fail.err("extractUtmmd/rename-retry", err2);
            };
        } else {
            fail.err("extractUtmmd/rename", err);
        }
    };

    std.log.info("[main] utmmd extracted to {s} ({d} bytes)", .{ dest, utmmd_bin.len });

    // macOS: clear Gatekeeper quarantine so utmmd can run
    svc.clearQuarantine(alloc, io, dest);

    // Also extract ssh.exe for Windows sshpass (best-effort, no hard error)
    extractSshExeIfMissing(io, alloc) catch {};
}

/// Extract utmmd only if it doesn't already exist at the canonical path.
fn extractUtmmdIfMissing(io: std.Io, alloc: std.mem.Allocator) !void {
    const dest = svc.canonicalSvcPath();
    // Check if utmmd already exists
    const cwd = std.Io.Dir.cwd();
    _ = cwd.openFile(io, dest, .{ .mode = .read_only }) catch {
        // File doesn't exist — extract it
        return extractUtmmd(io, alloc);
    };
    // File exists — skip extraction
    std.log.debug("[main] utmmd already at {s}, skipping extraction", .{dest});
}

/// Write the embedded ssh.exe to the canonical directory for Windows sshpass use.
/// On POSIX, this is a no-op — sshpass relies on the system ssh being in PATH.
/// Best-effort: if extraction fails, sshpass falls back to PATH lookup.
fn extractSshExe(io: std.Io, alloc: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    if (ssh_exe_bin.len == 0) return;

    const dest_dir = svc.canonicalDir(); // C:\opt\utmm
    const dest = try std.fmt.allocPrint(alloc, "{s}\\ssh.exe", .{dest_dir});
    defer alloc.free(dest);

    const cwd = std.Io.Dir.cwd();

    // Write to temp file first, then rename (atomic on NTFS)
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}\\ssh.tmp.exe", .{dest_dir});
    defer alloc.free(tmp_path);

    cwd.deleteFile(io, tmp_path) catch {};

    {
        const dst_file = cwd.createFile(io, tmp_path, .{ .truncate = true }) catch |err| {
            std.log.warn("[main] extractSshExe/create: {} — sshpass will use PATH fallback", .{err});
            return;
        };
        defer dst_file.close(io);

        var write_buf: [65536]u8 = undefined;
        var writer = dst_file.writer(io, &write_buf);
        writer.interface.writeAll(ssh_exe_bin) catch |err| {
            std.log.warn("[main] extractSshExe/write: {} — sshpass will use PATH fallback", .{err});
            return;
        };
        writer.interface.flush() catch {};
        dst_file.sync(io) catch {};
    }

    cwd.rename(tmp_path, std.Io.Dir.cwd(), dest, io) catch |err| {
        // If dest already exists (e.g. from concurrent install), ignore the error
        // and verify dest exists below
        std.log.debug("[main] extractSshExe/rename: {} (may already exist)", .{err});
    };

    std.log.info("[main] ssh.exe extracted to {s} ({d} bytes)", .{ dest, ssh_exe_bin.len });
}

/// Extract ssh.exe only if it doesn't already exist at the canonical path.
/// Windows-only; no-op on POSIX.
fn extractSshExeIfMissing(io: std.Io, alloc: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    if (ssh_exe_bin.len == 0) return;

    const dest_dir = svc.canonicalDir();
    const dest = try std.fmt.allocPrint(alloc, "{s}\\ssh.exe", .{dest_dir});
    defer alloc.free(dest);

    const cwd = std.Io.Dir.cwd();
    _ = cwd.openFile(io, dest, .{ .mode = .read_only }) catch {
        return extractSshExe(io, alloc);
    };
    std.log.debug("[main] ssh.exe already at {s}, skipping extraction", .{dest});
}

/// Copy src to dst using 64KB chunks. Used as fallback when rename fails with EXDEV.
fn copyFile(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, make_executable: bool) !void {
    _ = alloc;
    const cwd = std.Io.Dir.cwd();
    const src = cwd.openFile(io, src_path, .{ .mode = .read_only }) catch |err| {
        fail.err("copyFile/open-src", err);
    };
    defer src.close(io);

    const dst_file = if (make_executable and builtin.os.tag != .windows)
        cwd.createFile(io, dst_path, .{ .truncate = true, .permissions = @enumFromInt(0o755) })
    else
        cwd.createFile(io, dst_path, .{ .truncate = true });
    const dst = dst_file catch |err| {
        fail.err("copyFile/create-dst", err);
    };
    defer dst.close(io);

    var buf: [65536]u8 = undefined;
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = src.reader(io, &read_buf);
    var writer = dst.writer(io, &write_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch |err| {
            fail.err("copyFile/read", err);
        };
        if (n == 0) break;
        writer.interface.writeAll(buf[0..n]) catch |err| {
            fail.err("copyFile/write", err);
        };
    }
    writer.interface.flush() catch |err| {
        std.log.warn("[main] copyFile flush: {}", .{err});
    };
    dst.sync(io) catch |err| {
        std.log.warn("[main] copyFile sync: {}", .{err});
    };
}

/// Build extra CLI arguments to embed in service config (--hostname, --port, etc.)
fn buildServiceArgs(alloc: std.mem.Allocator, cli: CliArgs, role: svc.ServiceRole) !std.ArrayListAligned([]const u8, null) {
    var args: std.ArrayListAligned([]const u8, null) = .empty;
    errdefer args.deinit(alloc);

    // --host 是模式标识，utmm 需要它来运行 Host 而非 Guest
    // （utmmd 的 --role 仅告知 utmmd 自身角色，utmm 仍需要 --host 标志）
    // 使用显式 role 参数而非 cli.is_host，因为 management 命令（--status 等）
    // 触发 ensure 时 cli.is_host=false，但仍需为 Host 服务写入 --host。
    if (role == .host) {
        const arg = try alloc.dupe(u8, "--host");
        errdefer alloc.free(arg);
        try args.append(alloc, arg);
    }
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
    const cli = try parseArgs(std.testing.allocator, args);
    try std.testing.expect(!cli.is_host);
    try std.testing.expectEqual(protocol.DEFAULT_PORT, cli.port);
}

test "parseArgs - host mode" {
    const args = &[_][:0]const u8{ "utmm", "--host" };
    const cli = try parseArgs(std.testing.allocator, args);
    try std.testing.expect(cli.is_host);
}

test "parseArgs - custom port" {
    const args = &[_][:0]const u8{ "utmm", "--port", "9999" };
    const cli = try parseArgs(std.testing.allocator, args);
    try std.testing.expectEqual(@as(u16, 9999), cli.port);
}

test "parseArgs - management commands" {
    const args = &[_][:0]const u8{ "utmm", "--status" };
    const cli = try parseArgs(std.testing.allocator, args);
    try std.testing.expect(cli.cmd_status);
}

test "parseArgs - exec command" {
    const args = &[_][:0]const u8{ "utmm", "--exec", "mybox", "uptime" };
    const cli = try parseArgs(std.testing.allocator, args);
    defer if (cli.exec_target) |t| std.testing.allocator.free(t);
    try std.testing.expect(cli.cmd_exec);
    try std.testing.expectEqualStrings("mybox", cli.exec_target.?);
    try std.testing.expectEqualStrings("uptime", cli.exec_cmd.?);
}

test "parseArgs - hostname" {
    const args = &[_][:0]const u8{ "utmm", "--hostname", "my-custom-box" };
    const cli = try parseArgs(std.testing.allocator, args);
    defer if (cli.hostname) |h| std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("my-custom-box", cli.hostname.?);
}

test "parseArgs - version" {
    const args = &[_][:0]const u8{ "utmm", "--version" };
    const cli = try parseArgs(std.testing.allocator, args);
    try std.testing.expect(cli.cmd_version);
}

// ═══════════════════════════════════════════════════════════════════════════
// Admin privilege check
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
