//! UTM Monitor — Automatic VM IP sync tool
//!
//! Guest mode (default): mesh LSA + TCP/SOCKS4 connection to Host
//! Host mode (--host): ensures Host service is running
//!
//! Self-copy model: binary copies itself to canonical path /opt/utmm/utmm[.exe].
//! All operations (except --version/--help) require root/Administrator.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const host_mod = @import("host.zig");
const guest = @import("guest.zig");
const svc = @import("svc.zig");
const fail = @import("fail.zig");
const mcp = @import("mcp.zig");
const shm = @import("shm.zig");

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

comptime {
    _ = @import("lsa.zig");
    _ = @import("config.zig");
    _ = @import("tcp.zig");
    _ = @import("mcp.zig");
    _ = @import("host.zig");
    _ = svc;
    _ = fail;
}

/// CLI parse result
pub const CliArgs = struct {
    /// Whether in Host mode
    is_host: bool = false,
    /// Mesh UDP port (Host mode)
    port: u16 = protocol.DEFAULT_PORT,
    /// Mesh UDP port for LSA broadcast
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
    /// Enable automatic upgrade (Guest→Host version matching via LSA)
    auto_upgrade: bool = false,
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

    // Verify health-check command
    cmd_verify: bool = false,

    // Deploy command
    cmd_deploy: bool = false,
    deploy_target: ?[]const u8 = null,

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
        } else if (std.mem.eql(u8, arg, "--verify")) {
            cli.cmd_verify = true;
        } else if (std.mem.eql(u8, arg, "--deploy")) {
            cli.cmd_deploy = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                cli.deploy_target = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--ping")) {
            cli.cmd_ping = true;
            if (i + 1 < args.len) {
                i += 1;
                cli.ping_target = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            cli.save_config = true;
        } else if (std.mem.eql(u8, arg, "--auto-upgrade")) {
            cli.auto_upgrade = true;
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
        \\  --auto-upgrade      Enable automatic Guest→Host version matching via LSA
        \\
        \\Management commands (require Host service running):
        \\  --status            Query all online guest status
        \\  --verify            Health check: status + ping + exec echo for all guests
        \\  --deploy [TARGET]   Cross-compile, SCP, install & verify guest(s)
        \\  --ping TARGET       Ping a guest via mesh (Host→Guest or relayed)
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

    // ── 4. --svc: spawned by utmmd supervisor ──
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
        // Start heartbeat thread — updates shm.utmm_heartbeat every second.
        // utmmd monitors this; 10s timeout triggers restart.
        const hb_thread = if (shm_handle) |h|
            try std.Thread.spawn(.{}, heartbeatThread, .{h, init.io})
        else
            null;
        if (cli.is_host) {
            try host_mod.runWithIo(init.io, init.gpa, cli, null);
        } else {
            try guest.guestRunWithIo(init.io, init.gpa, cli, null);
        }
        // Cleanup — join heartbeat thread on exit
        if (hb_thread) |t| {
            if (shm_handle) |h| {
                h.utmm_state = @intFromEnum(shm.UtmmState.stopping);
            }
            t.join();
        }
        if (shm_handle) |h| {
            shm.detach(h);
        }
        return;
    }

    // ── 5. --install: force install service ──
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

    // ── 6. --uninstall: remove service ──
    if (cli.cmd_uninstall) {
        try svc.uninstall(init.io, init.gpa);
        return;
    }

    // ── 7. Ensure Host service for --host and management commands ──
    // --status, --exec, --upload, --download all need the Host daemon (IPC socket).
    // Auto-start it if not running so users and AI agents can go directly
    // from "utmm --exec vm cmd" without a separate "utmm --host" step.
    const needs_host = cli.is_host or cli.cmd_status or cli.cmd_exec or cli.cmd_ping
        or cli.cmd_upload or cli.cmd_download or cli.is_mcp or cli.cmd_verify
        or cli.cmd_deploy;
    if (needs_host) {
        const was_running = svc.isRunning(init.io, init.gpa, .host);
        var extra_args = try buildServiceArgs(init.gpa, cli, .host);
        defer {
            for (extra_args.items) |item| init.gpa.free(@constCast(item));
            extra_args.deinit(init.gpa);
        }

        if (svc.shouldUpdateUtmmd(init.io, init.gpa, .host, extra_args.items, utmmd_sha256_hex)) {
            // 3a path: utmmd needs update — extract + full forceInstall
            try extractUtmmd(init.io, init.gpa);
            svc.forceInstall(init.io, init.gpa, .host, extra_args.items);
            svc.saveUtmmdMeta(init.io, init.gpa, .host, extra_args.items, utmmd_sha256_hex);
        } else if (!was_running) {
            // 3b path: utmmd unchanged, just start the service (skip reinstall)
            std.log.info("[main] utmmd unchanged, starting service directly", .{});
            svc.start(init.io, init.gpa, .host) catch |err| {
                std.log.err("[main] start failed: {} — falling back to ensure", .{err});
                extractUtmmdIfMissing(init.io, init.gpa) catch {};
                svc.ensure(init.io, init.gpa, .host, extra_args.items);
            };
        }
        // else: utmmd fine and service already running; management cmds can proceed

        // --host alone (no management command): ensure + exit
        if (cli.is_host and !cli.cmd_status and !cli.cmd_exec and !cli.cmd_ping
            and !cli.cmd_upload and !cli.cmd_download
            and !cli.cmd_gen_init and !cli.save_config and !cli.is_mcp
            and !cli.cmd_verify and !cli.cmd_deploy) {
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
    if (cli.cmd_status or cli.cmd_exec or cli.cmd_ping or cli.cmd_upload or cli.cmd_download or cli.cmd_gen_init or cli.save_config or cli.cmd_verify or cli.cmd_deploy) {
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
    {
        const was_running = svc.isRunning(init.io, init.gpa, .guest);
        var extra_args_guest = try buildServiceArgs(init.gpa, cli, .guest);
        defer {
            for (extra_args_guest.items) |item| init.gpa.free(@constCast(item));
            extra_args_guest.deinit(init.gpa);
        }

        if (svc.shouldUpdateUtmmd(init.io, init.gpa, .guest, extra_args_guest.items, utmmd_sha256_hex)) {
            // 3a path: utmmd needs update — extract + full forceInstall
            try extractUtmmd(init.io, init.gpa);
            svc.forceInstall(init.io, init.gpa, .guest, extra_args_guest.items);
            svc.saveUtmmdMeta(init.io, init.gpa, .guest, extra_args_guest.items, utmmd_sha256_hex);
        } else if (!was_running) {
            // 3b path: utmmd unchanged, just start the service (skip reinstall)
            std.log.info("[main] utmmd unchanged, starting guest service directly", .{});
            svc.start(init.io, init.gpa, .guest) catch |err| {
                std.log.err("[main] start failed: {} — falling back to ensure", .{err});
                extractUtmmdIfMissing(init.io, init.gpa) catch {};
                svc.ensure(init.io, init.gpa, .guest, extra_args_guest.items);
            };
        }
    }
}

/// Write the embedded utmmd binary to the canonical service path.
/// Validates the binary type before writing. Always overwrites.
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
        } else {
            fail.err("extractUtmmd/rename", err);
        }
    };

    std.log.info("[main] utmmd extracted to {s} ({d} bytes)", .{ dest, utmmd_bin.len });
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

/// Heartbeat thread: updates shm.utmm_heartbeat every second.
/// utmmd monitors this field; 10s without update triggers restart.
fn heartbeatThread(h: *volatile shm.ShmLayout, io: std.Io) void {
    while (true) {
        const now = shm.nowMs(io);
        h.utmm_heartbeat = now;
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {
            std.log.err("[main] heartbeat sleep failed, exiting heartbeat thread", .{});
            break;
        };
    }
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
