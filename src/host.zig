//! Host mode — mesh networking daemon on UDP :2121 + TCP :2121.
//!
//! TCP per-command model with LSA broadcast + IPC socket + SOCKS5 forwarding.
//! Management commands (--status/--exec/--upload/--download) communicate via IPC socket.
//! TCP :2121 accepts SOCKS5 and dispatches: self→localhost relay, other→chained forward.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const protocol = @import("protocol.zig");
const guest = @import("guest.zig");
const lsa = @import("lsa.zig");
const tcp = @import("tcp.zig");
const svc = @import("svc.zig");
const arp = @import("arp.zig");
const sshpass = @import("sshpass.zig");

pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli, null);
}

pub fn runWithIo(block_io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs, shutdown: ?*std.atomic.Value(bool)) !void {
    // Management commands: stateless, no Host daemon needed
    if (cli.cmd_status) return cmdStatus(block_io, gpa, cli.port);
    if (cli.cmd_deploy) return cmdDeploy(block_io, gpa, cli.deploy_target);
    if (cli.cmd_ping) {
        const target = cli.ping_target orelse {
            std.debug.print("[ERROR] --ping requires a target hostname\n", .{});
            std.process.exit(1);
        };
        return cmdPing(block_io, gpa, cli.port, target);
    }
    if (cli.cmd_exec) return cmdExec(block_io, gpa, cli.port, cli.exec_target.?, cli.exec_cmd.?);
    if (cli.cmd_upload) return cmdUpload(block_io, gpa, cli.port, cli.upload_target.?, cli.upload_file.?);
    if (cli.cmd_download) return cmdDownload(block_io, gpa, cli.port, cli.download_target.?, cli.download_remote.?, cli.download_local.?);
    if (cli.cmd_upgrade) return cmdUpgrade(block_io, gpa, cli.port, cli.upgrade_target.?);
    // --gen-init
    if (cli.cmd_gen_init) {
        const platform_str = cli.gen_init_platform orelse "linux";
        const platform: svc.Platform = if (std.mem.eql(u8, platform_str, "macos"))
            .macos
        else if (std.mem.eql(u8, platform_str, "windows"))
            .windows
        else
            .linux;
        const script = svc.genInit(platform);
        std.debug.print("{s}", .{script});
        return;
    }
    // Default serve_dir to exe directory if not specified
    const serve_dir = if (cli.serve_dir) |sd| sd else blk: {
        const exe_path = try std.process.executablePathAlloc(block_io, gpa);
        defer gpa.free(exe_path);
        const dir = std.fs.path.dirname(exe_path) orelse svc.canonicalDir();
        break :blk try gpa.dupe(u8, dir);
    };
    defer if (cli.serve_dir == null) gpa.free(serve_dir);

    // Validate serve_dir: must be absolute and must not contain ".." traversal.
    if (!std.fs.path.isAbsolute(serve_dir)) {
        std.debug.print("[serve-dir] serve directory must be an absolute path, got: {s}\n", .{serve_dir});
        std.process.exit(1);
    }
    if (std.mem.indexOf(u8, serve_dir, "..") != null) {
        std.debug.print("[serve-dir] serve directory must not contain '..' traversal, got: {s}\n", .{serve_dir});
        std.process.exit(1);
    }

    // --host (via --svc): start Host daemon
    if (cli.is_host) {
        try startHost(block_io, gpa, cli.mesh_port, serve_dir, cli.peer_mesh, shutdown, cli.hostname);
        return;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management commands (stateless — discover via UDP, connect via TCP)
// ═══════════════════════════════════════════════════════════════════════════

fn cmdStatus(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    _ = port; // IPC handler — port reserved for future use
    const ipc_mod = @import("ipc.zig");

    // IPC handler
    const json_str = try ipc_mod.ipcStatus(block_io, gpa);
    defer gpa.free(json_str);

    // Parse JSON and print table
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("[status] JSON parse error: {}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    const guests = switch (parsed.value) {
        .array => |arr| arr,
        else => {
            std.debug.print("No UTM guests found.\n\n", .{});
            return;
        },
    };

    if (guests.items.len == 0) {
        std.debug.print("No UTM guests found.\n\n", .{});
        return;
    }

    // Format relative time for last_seen display
    const now_ns = std.Io.Timestamp.now(block_io, .real).nanoseconds;
    const now_ms = @as(i64, @intCast(@divFloor(now_ns, std.time.ns_per_ms)));
    const relTime = struct {
        fn fmt(ms: i64, now: i64) []const u8 {
            const diff = now - ms;
            if (diff < 1000) return "now";
            if (diff < 60_000) return "s"; // printed inline below
            if (diff < 3600_000) return "m";
            if (diff < 86400_000) return "h";
            return "d";
        }
    }.fmt;

    std.debug.print("\n{s: <6} {s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s: <10} {s: <8} {s: <7} {s}\n", .{ "Role", "Hostname", "Target", "IP", "MAC", "Version", "Status", "Shell", "ConPTY", "Last" });
    std.debug.print("{s:-<120}\n", .{""});
    for (guests.items) |guest_val| {
        const g = switch (guest_val) {
            .object => |o| o,
            else => continue,
        };
        const hostname = protocol.jsonGetString(g, "hostname") orelse "?";
        const role = protocol.jsonGetString(g, "role") orelse "?";
        const target = protocol.jsonGetString(g, "target") orelse "?";
        const ip = protocol.jsonGetString(g, "ip") orelse "?";
        const mac = protocol.jsonGetString(g, "mac") orelse "?";
        const version = protocol.jsonGetString(g, "version") orelse "?";
        const status = protocol.jsonGetString(g, "status") orelse "?";
        const shell = protocol.jsonGetString(g, "shell") orelse "?";
        const conpty = protocol.jsonGetString(g, "conpty") orelse "?";
        // Parse last_seen from JSON integer
        var last_seen: i64 = 0;
        if (g.get("last_seen")) |v| {
            if (v == .integer) last_seen = @intCast(v.integer);
        }
        const rel = relTime(last_seen, now_ms);
        const rel_val = if (std.mem.eql(u8, rel, "s"))
            @as(i64, @intCast(@divTrunc(now_ms - last_seen, 1000)))
        else if (std.mem.eql(u8, rel, "m"))
            @as(i64, @intCast(@divTrunc(now_ms - last_seen, 60_000)))
        else if (std.mem.eql(u8, rel, "h"))
            @as(i64, @intCast(@divTrunc(now_ms - last_seen, 3600_000)))
        else if (std.mem.eql(u8, rel, "d"))
            @as(i64, @intCast(@divTrunc(now_ms - last_seen, 86400_000)))
        else
            @as(i64, 0);
        std.debug.print("{s: <6} {s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s: <10} {s: <8} {s: <7}", .{ role, hostname, target, ip, mac, version, status, shell, conpty });
        if (rel_val > 0) {
            std.debug.print(" {d}{s}\n", .{ rel_val, rel });
        } else {
            std.debug.print(" {s}\n", .{rel});
        }
    }
    std.debug.print("\n", .{});
}

// ═══════════════════════════════════════════════════════════════════════════
// Deployment config & command
// ═══════════════════════════════════════════════════════════════════════════

/// VM deployment config entry.
const VmDeployConfig = struct {
    hostname: []const u8,
    target: []const u8, // Zig cross-compilation target triple
    ip: []const u8,
    user: []const u8,
    password: []const u8,
    /// Remote canonical dir (e.g. "/opt/utmm" or "C:\\opt\\utmm")
    remote_dir: []const u8,
};

/// Hard-coded VM deploy table. Override with utmm-deploy.json if present.
const VM_DEPLOY_TABLE: []const VmDeployConfig = &[_]VmDeployConfig{
    .{ .hostname = "linuxvm", .target = "aarch64-linux-musl", .ip = "192.168.64.2", .user = "root", .password = "111", .remote_dir = "/opt/utmm" },
    .{ .hostname = "macvm", .target = "aarch64-macos", .ip = "192.168.64.4", .user = "root", .password = "111", .remote_dir = "/opt/utmm" },
    .{ .hostname = "windowsvm", .target = "aarch64-windows", .ip = "192.168.65.2", .user = "Administrator", .password = "111", .remote_dir = "C:\\opt\\utmm" },
    .{ .hostname = "winx64", .target = "x86_64-windows", .ip = "192.168.3.108", .user = "Administrator", .password = "111", .remote_dir = "C:\\opt\\utmm" },
};

/// Look up a VM's remote canonical directory by hostname.
/// Returns null if hostname not found in VM_DEPLOY_TABLE.
fn vmRemoteDir(hostname: []const u8) ?[]const u8 {
    for (VM_DEPLOY_TABLE) |vm| {
        if (std.mem.eql(u8, vm.hostname, hostname)) return vm.remote_dir;
    }
    return null;
}

/// One-shot deploy: cross-compile → SCP → SSH install → verify.
/// Uses sshpass for non-interactive password auth.
fn cmdDeploy(io: std.Io, gpa: std.mem.Allocator, target_opt: ?[]const u8) !void {
    // ── 1. Look up VM(s) to deploy ──
    var deploy_list: std.ArrayListAligned(VmDeployConfig, null) = .empty;
    defer deploy_list.deinit(gpa);

    if (target_opt) |t| {
        var found = false;
        for (VM_DEPLOY_TABLE) |vm| {
            if (std.mem.eql(u8, vm.hostname, t)) {
                try deploy_list.append(gpa, vm);
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("[deploy] Unknown target: {s}\n", .{t});
            std.debug.print("Known targets:", .{});
            for (VM_DEPLOY_TABLE) |vm| {
                std.debug.print(" {s}", .{vm.hostname});
            }
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
    } else {
        // Deploy all
        for (VM_DEPLOY_TABLE) |vm| {
            try deploy_list.append(gpa, vm);
        }
    }

    if (deploy_list.items.len == 0) {
        std.debug.print("[deploy] No VMs to deploy.\n", .{});
        return;
    }

    // ── Check sshpass availability (needed for scp/ssh to remote VMs) ──
    const has_sshpass = blk: {
        const result = std.process.run(gpa, io, .{ .argv = &.{ "which", "sshpass" } }) catch break :blk false;
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        break :blk result.term == .exited and result.term.exited == 0;
    };
    if (!has_sshpass) {
        // sshpass is only needed for remote VM deployment (scp).
        // Local deployment (compile + copy to serve-dir) was already done by the
        // Host ensure step in main.zig — skip remote push with a clear warning.
        std.debug.print("[deploy] sshpass is required for non-interactive deployment to remote VMs.\n", .{});
        std.debug.print("[deploy] Local binaries have been copied to serve-dir.\n", .{});
        std.debug.print("[deploy] To push to VMs, install sshpass:\n", .{});
        std.debug.print("  brew install sshpass   (macOS)\n", .{});
        std.debug.print("  apt install sshpass    (Linux)\n", .{});
        return;
    }

    std.debug.print("\n[deploy] Targets ({d}):", .{deploy_list.items.len});
    for (deploy_list.items) |vm| {
        std.debug.print(" {s}", .{vm.hostname});
    }
    std.debug.print("\n\n", .{});

    // ── 2. Cross-compile all targets in parallel via zig build cross ──
    // Replaces the old serial per-target compilation loop.
    // zig build cross compiles all 8 deployment targets in one step.
    std.debug.print("[deploy] Cross-compiling all targets (parallel)...\n", .{});
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "build", "cross", "-Doptimize=ReleaseSafe" },
    }) catch |err| {
        std.debug.print("[deploy] zig build cross failed: {}\n", .{err});
        std.process.exit(1);
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("[deploy] Compile failed:\n{s}\n", .{result.stderr});
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        std.process.exit(1);
    }
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    std.debug.print("[deploy] All targets compiled.\n", .{});

    // Map target triple → binary path in zig-out/bin/
    var compiled = std.StringHashMap([]const u8).init(gpa);
    defer {
        var it = compiled.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value_ptr.*);
        }
        compiled.deinit();
    }

    for (deploy_list.items) |vm| {
        if (compiled.contains(vm.target)) continue;

        const bin_name = protocol.deploymentFilename(vm.target) orelse {
            std.debug.print("[deploy] Unknown target: {s}\n", .{vm.target});
            std.process.exit(1);
        };
        const bin_path = try std.fmt.allocPrint(gpa, "zig-out/bin/{s}", .{bin_name});
        try compiled.put(vm.target, bin_path);

        // Copy to serve-dir for future --upgrade use
        const serve_copy_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ svc.canonicalDir(), bin_name });
        defer gpa.free(serve_copy_path);
        std.Io.Dir.cwd().copyFile(bin_path, std.Io.Dir.cwd(), serve_copy_path, io, .{}) catch |err| {
            std.log.warn("[deploy] copy to serve-dir failed: {}", .{err});
        };
        std.debug.print("[deploy]   {s} -> serve-dir\n", .{bin_name});
    }

    // ── 3. SCP + install for each VM ──
    var success: usize = 0;
    var failed: usize = 0;

    for (deploy_list.items) |vm| {
        const bin_path = compiled.get(vm.target) orelse continue;

        std.debug.print("\n[deploy] === {s} ({s}) ===\n", .{ vm.hostname, vm.target });

        // Windows: use SMB/copy or skip — scp/ssh not available natively.
        // For now, provide manual instructions.
        if (std.mem.indexOf(u8, vm.target, "windows") != null) {
            std.debug.print("[deploy]   Windows target — manual deploy required.\n", .{});
            std.debug.print("[deploy]   Copy {s} → {s}@{s}:{s}/utmm-new.exe\n", .{ bin_path, vm.user, vm.ip, vm.remote_dir });
            std.debug.print("[deploy]   Then run: {s}\\utmm-new.exe --install --hostname {s}\n", .{ vm.remote_dir, vm.hostname });
            success += 1;
            continue;
        }

        // POSIX: use sshpass + scp
        const remote_tmp = try std.fmt.allocPrint(gpa, "{s}/utmm-new", .{vm.remote_dir});
        defer gpa.free(remote_tmp);

        const scp_target = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ vm.user, vm.ip });
        defer gpa.free(scp_target);

        // scp binary → VM
        std.debug.print("[deploy]   scp {s} → {s}:{s}...\n", .{ bin_path, scp_target, remote_tmp });
        const scp_dest = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ scp_target, remote_tmp });
        defer gpa.free(scp_dest);
        const scp_result = std.process.run(gpa, io, .{
            .argv = &.{ "sshpass", "-p", vm.password, "scp", bin_path, scp_dest },
        }) catch |err| {
            std.debug.print("[deploy]   scp failed: {}\n", .{err});
            failed += 1;
            continue;
        };
        if (scp_result.term != .exited or scp_result.term.exited != 0) {
            std.debug.print("[deploy]   scp failed:\n{s}\n", .{scp_result.stderr});
            gpa.free(scp_result.stdout);
            gpa.free(scp_result.stderr);
            failed += 1;
            continue;
        }
        gpa.free(scp_result.stdout);
        gpa.free(scp_result.stderr);

        // SSH: chmod +x + run --install
        std.debug.print("[deploy]   ssh install...\n", .{});
        const install_cmd = try std.fmt.allocPrint(gpa, "chmod +x {s} && {s} --install --hostname {s}", .{ remote_tmp, remote_tmp, vm.hostname });
        defer gpa.free(install_cmd);

        const ssh_result = std.process.run(gpa, io, .{
            .argv = &.{ "sshpass", "-p", vm.password, "ssh", scp_target, install_cmd },
        }) catch |err| {
            std.debug.print("[deploy]   ssh install failed: {}\n", .{err});
            failed += 1;
            continue;
        };
        if (ssh_result.term != .exited or ssh_result.term.exited != 0) {
            std.debug.print("[deploy]   ssh install failed:\n{s}\n", .{ssh_result.stderr});
            gpa.free(ssh_result.stdout);
            gpa.free(ssh_result.stderr);
            failed += 1;
            continue;
        }
        gpa.free(ssh_result.stdout);
        gpa.free(ssh_result.stderr);

        std.debug.print("[deploy]   {s} deployed successfully.\n", .{vm.hostname});
        success += 1;
    }

    // ── 4. Summary ──
    std.debug.print("\n[deploy] Done: {d} success, {d} failed (of {d})\n", .{ success, failed, deploy_list.items.len });
    if (failed > 0) {
        std.process.exit(1);
    }
}

fn cmdPing(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8) !void {
    _ = port; // IPC handler — port reserved for future use
    const ipc_mod = @import("ipc.zig");

    // IPC handler
    const json = try ipc_mod.ipcPing(block_io, gpa, target);
    defer gpa.free(json);
    std.debug.print("{s}\n", .{json});
}

fn cmdExec(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, cmd: []const u8) !void {
    _ = port; // IPC handler — port reserved for future use
    const ipc_mod = @import("ipc.zig");

    // IPC handler
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(block_io, &stdout_buf);
    const stdout_iface = &stdout_writer.interface;

    const exit_code = try ipc_mod.ipcExec(block_io, gpa, target, cmd, stdout_iface);

    if (exit_code != 0) {
        const code: u8 = if (exit_code <= 0 or exit_code > 255) 1 else @intCast(exit_code);
        std.process.exit(code);
    }
}

fn cmdUpload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, local_file: []const u8) !void {
    _ = port; // IPC handler — port reserved for future use
    const ipc_mod = @import("ipc.zig");

    const basename = std.fs.path.basename(local_file);
    const remote_dir = vmRemoteDir(target) orelse "/opt/utmm";
    // Always use forward slash — Windows accepts both / and \ in file paths,
    // and the Host may not be running on Windows even when the Guest is.
    const dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ remote_dir, basename });
    defer gpa.free(dest);

    std.debug.print("[upload] Uploading {s} -> {s} ({s})...\n", .{ local_file, target, dest });

    // IPC handler
    try ipc_mod.ipcUpload(block_io, gpa, target, local_file, dest);
    std.debug.print("[upload] OK\n", .{});
}

fn cmdUpgrade(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8) !void {
    _ = port;
    const ipc_mod = @import("ipc.zig");

    std.debug.print("[upgrade] Pushing upgrade binary to {s}...\n", .{target});

    try ipc_mod.ipcUpgrade(block_io, gpa, target);
    std.debug.print("[upgrade] OK\n", .{});
}

fn cmdDownload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, remote_file: []const u8, local_path: []const u8) !void {
    _ = port; // IPC handler — port reserved for future use
    const ipc_mod = @import("ipc.zig");

    std.debug.print("[download] Downloading {s} from {s} -> {s}...\n", .{ remote_file, target, local_path });

    // IPC handler
    // Write to temp file first, then rename atomically
    var rand_bytes: [8]u8 = undefined;
    block_io.random(&rand_bytes);
    var temp_hex: [16]u8 = undefined;
    for (rand_bytes, 0..) |b, j| {
        temp_hex[j * 2] = "0123456789abcdef"[b >> 4];
        temp_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const temp_path = try std.fmt.allocPrint(gpa, "{s}.{s}.utmm-tmp", .{ local_path, &temp_hex });
    defer gpa.free(temp_path);
    std.Io.Dir.cwd().deleteFile(block_io, temp_path) catch {};

    const tmp_file = try std.Io.Dir.cwd().createFile(block_io, temp_path, .{});
    defer tmp_file.close(block_io);
    var file_wb: [65536]u8 = undefined;
    var fw = tmp_file.writer(block_io, &file_wb);
    const file_iface = &fw.interface;

    const total_bytes = try ipc_mod.ipcDownload(block_io, gpa, target, remote_file, file_iface);

    file_iface.flush() catch {};

    // Atomic rename from temp to final path
    std.Io.Dir.cwd().deleteFile(block_io, local_path) catch {};
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), local_path, block_io);

    std.debug.print("[download] Received {d} bytes -> {s}\n", .{ total_bytes, local_path });
}

// ═══════════════════════════════════════════════════════════════════════════
// Host daemon (--host): Mesh LSA + TCP/SOCKS5 connections + IPC server
// ═══════════════════════════════════════════════════════════════════════════
fn startHost(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    mesh_port: u16,
    serve_dir: ?[]const u8,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
    hostname: ?[]const u8,
) !void {
    const sd = serve_dir orelse svc.canonicalDir();
    std.log.info("[host] daemon starting (mesh UDP :{d})", .{mesh_port});
    std.log.info("[host] serve dir: {s}", .{sd});

    // 清理 Guest crash 残留的升级临时文件
    svc.cleanupStaleUpgradeTmp(block_io);

    // 清理 Guest crash 残留的升级临时文件
    svc.cleanupStaleUpgradeTmp(block_io);

    // Initialize guest table
    var state = GuestTable.init(gpa, block_io);
    defer state.deinit();

    // Spawn mesh networking thread — replaces periodic UDP guest.
    // Mesh broadcasts LSA every 2s (version is informational — displayed in --status),
    // maintains guest topology via LSA database.
    var mesh_opt: ?lsa.Mesh = null;
    var mesh_thread: ?std.Thread = null;

    // Allocated copies for hostMainLoop (set inside start_mesh block)
    var host_ip_copy: []const u8 = &.{};
    var host_hostname_copy: []const u8 = &.{};

    start_mesh: {
        // Get Host's own system info for node identification
        var host_info = guest.getSystemInfo(block_io, gpa) catch |err| {
            std.log.err("[host] getSystemInfo failed: {}", .{err});
            break :start_mesh;
        };
        defer {
            gpa.free(host_info.hostname);
            gpa.free(host_info.ip);
            gpa.free(host_info.mac);
            // host_info.target is a compile-time constant from zigTarget()
            gpa.free(host_info.iface_name);
            gpa.free(host_info.shell);
        }

        // Override hostname if --hostname was specified (applies to host mode too)
        if (hostname) |n| {
            // getSystemInfo allocated hostname, but defer will free the original;
            // free old first, then allocate the override so defer frees the new one.
            gpa.free(host_info.hostname);
            host_info.hostname = try gpa.dupe(u8, n);
        }

        // Collect broadcast addresses
        var bc_addrs = guest.getSubnetBroadcasts(gpa) catch |err| {
            std.log.err("[host] getSubnetBroadcasts failed: {}", .{err});
            break :start_mesh;
        };

        // Add explicit peer mesh address for local testing (different mesh ports)
        if (peer_mesh) |pm| {
            if (protocol.parsePeerMeshAddr(pm)) |peer_addr| {
                bc_addrs.append(gpa, peer_addr) catch |err| {
                    std.log.err("[host] append peer-mesh addr failed: {}", .{err});
                };
            } else {
                std.log.err("[host] invalid --peer-mesh '{s}'", .{pm});
            }
        }

        // Dedicated Io for mesh background thread
        var mesh_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const mesh_io = mesh_threaded.io();

        // Bind UDP socket for mesh
        const bind_addr = std.Io.net.IpAddress.parse("0.0.0.0", mesh_port) catch |err| {
            std.log.err("[host] Mesh bind addr parse: {}", .{err});
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };
        const mesh_socket = bind_addr.bind(mesh_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
            std.log.err("[host] Mesh UDP bind :{d} failed: {}", .{ mesh_port, err });
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Parse Host MAC as mesh NodeId
        const node_id = lsa.parseNodeId(host_info.mac) catch |err| {
            std.log.err("[host] Mesh MAC parse '{s}': {}", .{ host_info.mac, err });
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Build node_info for LSA (Mesh.init() appends epoch internally)
        const node_info = std.fmt.allocPrint(gpa,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nconpty:{s}\nrole:host\nstatus:serving",
            .{ host_info.hostname, host_info.ip, host_info.target, protocol.VERSION, host_info.shell, if (sshpass.conptyAvailable()) "yes" else "no" },
        ) catch |err| {
            std.log.err("[host] Mesh node_info alloc: {}", .{err});
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Create mesh instance (epoch is auto-appended to node_info by init())
        mesh_opt = lsa.Mesh.init(gpa, node_id, node_info, mesh_socket, mesh_io, bc_addrs, guest.getSubnetBroadcasts) catch |err| {
            std.log.err("[host] Mesh init failed: {}", .{err});
            gpa.free(node_info);
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Spawn mesh.run() thread
        mesh_thread = std.Thread.spawn(.{}, lsa.Mesh.run, .{&mesh_opt.?}) catch |err| {
            std.log.err("[host] Mesh thread spawn failed: {}", .{err});
            mesh_opt.?.deinit();
            mesh_socket.close(mesh_io);
            mesh_opt = null;
            break :start_mesh;
        };

        std.log.info("[host] Mesh networking started (LSA on UDP :{d})", .{mesh_port});

        // Register Host itself in the guest table so --status shows it alongside guests
        const now_ms = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(block_io, .real).nanoseconds, std.time.ns_per_ms)));
        _ = state.upsert(
            host_info.hostname, host_info.ip, host_info.target,
            host_info.mac, protocol.VERSION, host_info.shell,
            if (sshpass.conptyAvailable()) "yes" else "no",
            "serving", "host", now_ms,
        );

        // Allocate copies of host IP/hostname for hostMainLoop (which outlives start_mesh block)
        host_ip_copy = try gpa.dupe(u8, host_info.ip);
        errdefer gpa.free(host_ip_copy);
        host_hostname_copy = try gpa.dupe(u8, host_info.hostname);
        errdefer gpa.free(host_hostname_copy);

    }

    // Spawn LSA manager thread — syncs LSA→guest table, triggers auto-upgrade.
    // Must spawn before the defer below so join() runs in correct order.
    var host_loop_thread = try std.Thread.spawn(.{}, hostMainLoop, .{ block_io, gpa, &state, &mesh_opt, host_ip_copy, host_hostname_copy });

    // Spawn IPC server thread — Unix domain socket (POSIX) / named pipe (Windows).
    // Shares HostState and Mesh with the mesh networking layer.
    var ipc_shutdown = std.atomic.Value(bool).init(false);
    const ipc_mod = @import("ipc.zig");
    var ipc_thread = try std.Thread.spawn(.{}, ipc_mod.startServer, .{
        block_io, gpa, @as(*anyopaque, @ptrCast(&state)), @as(*anyopaque, @ptrCast(&mesh_opt)), &ipc_shutdown,
    });

    // Spawn TCP listener thread — SOCKS5 accept + three-way dispatch.
    // Uses GuestTable.findByHostname for hostname→IP lookup.
    var tcp_thread = try std.Thread.spawn(.{}, hostTcpListen, .{
        block_io, gpa, &state, host_hostname_copy, mesh_port, shutdown,
    });

    defer {
        // 1. Signal all background threads to stop
        ipc_shutdown.store(true, .release);
        // 2. Signal mesh shutdown — hostMainLoop checks this each loop iteration
        if (mesh_opt) |*m| m.signalShutdown();

        // 3. Join threads (order: IPC → TCP → host loop → mesh)
        ipc_thread.join();
        tcp_thread.join();
        host_loop_thread.join();

        // 4. Join mesh thread after all consumers have exited
        if (mesh_thread) |t| {
            t.join();
        }

        // 5. Deinit mesh (safe: all threads using it have exited)
        if (mesh_opt) |*m| {
            const m_io = m.io;
            m.deinit();
            _ = m_io;
        }

        // 6. state.deinit() runs via its own defer (declared earlier, runs later)
    }

    // Block until shutdown — Host runs via Mesh + IPC threads
    if (shutdown) |flag| {
        while (!flag.load(.acquire)) {
            std.Io.sleep(block_io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
    } else {
        while (true) {
            std.Io.sleep(block_io, std.Io.Duration.fromSeconds(60), .awake) catch {};
        }
    }
}

/// Host TCP listener — SOCKS5 accept + three-way dispatch.
/// Uses GuestTable.findByHostname for hostname→IP lookup (vs guest's lsa.Mesh).
fn hostTcpListen(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *GuestTable,
    hostname: []const u8,
    mesh_port: u16,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    var listener = tcp.TcpListener.init(io, mesh_port) catch |err| {
        std.log.err("[host] TCP listen :{d} failed: {}", .{ mesh_port, err });
        return error.TcpBindFailed;
    };
    defer listener.deinit();

    var conn_limit = tcp.ConnLimit.init(tcp.DEFAULT_MAX_CONNS);
    std.log.info("[host] TCP SOCKS5 listener on :{d}", .{mesh_port});

    while (true) {
        if (shutdown) |s| {
            if (s.load(.acquire)) break;
        }

        const fd = listener.acceptRaw() catch |err| {
            if (err == error.WouldBlock) continue;
            std.log.err("[host] accept failed: {}", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };

        // 读取 SOCKS5 请求
        var req_buf: [tcp.MAX_HOSTNAME + 1]u8 = undefined;
        const req = tcp.socks5ReadRequestBuf(fd, req_buf[0..]) catch |err| {
            std.log.err("[host] SOCKS5 read failed: {}", .{err});
            tcp.sockClose(fd);
            continue;
        };

        // 三路 dispatch
        if (std.mem.eql(u8, req.hostname, hostname)) {
            // 目标是本机
            if (req.port == mesh_port) {
                // self:2121 — no utmm handler on Host side, just close
                tcp.socks5ReplyOk(fd);
                tcp.sockClose(fd);
                std.log.debug("[host] self:2121 (no handler)", .{});
            } else {
                // 本机 localhost relay — 连接限制计数
                if (!conn_limit.tryAcquire()) {
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                }
                errdefer conn_limit.release();
                const t = std.Thread.spawn(.{}, tcp.localRelayWithLimit, .{ io, fd, req.port, &conn_limit }) catch {
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                t.detach();
                std.log.info("[host] local relay :{d}", .{req.port});
            }
        } else {
            // 目标不是本机 — 链式 SOCKS5 转发
            if (state.findByHostname(req.hostname)) |guest_entry| {
                defer state.freeEntry(guest_entry);

                // 连接限制计数
                if (!conn_limit.tryAcquire()) {
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                }
                errdefer conn_limit.release();

                const next_hop = std.Io.net.IpAddress.parse(guest_entry.ip, mesh_port) catch {
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };

                const hn_copy = allocator.dupe(u8, req.hostname) catch {
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };

                const ctx = allocator.create(guest.ForwardCtx) catch {
                    allocator.free(hn_copy);
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                ctx.* = .{
                    .io = io,
                    .client_fd = fd,
                    .next_hop_ip = next_hop,
                    .hostname = hn_copy,
                    .target_port = req.port,
                    .allocator = allocator,
                    .limit = &conn_limit,
                };

                const t = std.Thread.spawn(.{}, guest.forwardThreadFn, .{ctx}) catch {
                    allocator.destroy(ctx);
                    allocator.free(hn_copy);
                    tcp.socks5ReplyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                t.detach();
                std.log.info("[host] forward {s}:{d} → {s}", .{ req.hostname, req.port, guest_entry.ip });
            } else {
                std.log.info("[host] no route to {s}", .{req.hostname});
                tcp.socks5ReplyRejected(fd);
                tcp.sockClose(fd);
            }
        }
    }
}

/// Parse a simple key:value line from LSA node_info.
fn parseNodeInfoLine(line: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':') {
        return line[key.len + 1 ..];
    }
    return null;
}

/// Background thread: periodically scans mesh LSAs for guest nodes
/// and syncs them to the guest table. No persistent TCP connections —
/// each exec/upload/download opens a fresh per-command TCP connection.
// ═══════════════════════════════════════════════════════════════════════════
// Auto-upgrade: push binary to Guest
// ═══════════════════════════════════════════════════════════════════════════

/// Cooldown between auto-upgrade attempts per Guest (ms).
const AUTO_UPGRADE_COOLDOWN_MS: i64 = 120_000; // 2 minutes

/// Tracks last auto-upgrade attempt timestamp per Guest hostname.
const LastUpgradeMap = std.StringHashMap(i64);

/// Connect to a Guest via TCP with ARP-based IP rediscovery on failure.
/// On primary connect failure, queries the system ARP table by MAC to find
/// the Guest's new IP (handles UTM VM IP address changes).
/// Returns a TCP connection or an error message string (caller does NOT own).
pub fn connectGuest(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *GuestTable,
    hostname: []const u8,
) !tcp.Connection {
    const guest_entry = state.findByHostname(hostname) orelse return error.GuestNotFound;
    defer state.freeEntry(guest_entry);

    return tcp.hostConnect(io, guest_entry.ip, hostname, protocol.DEFAULT_PORT) catch |primary_err| {
        std.log.warn("[arp] primary connect to {s} ({s}) failed: {}", .{ hostname, guest_entry.ip, primary_err });

        // ARP recovery: try to find new IP by MAC
        if (guest_entry.mac.len > 0) {
            const new_ip = arp.rediscoverIp(gpa, guest_entry.mac, guest_entry.ip) catch null;
            if (new_ip) |nip| {
                defer gpa.free(nip);
                std.log.info("[arp] rediscovered {s}: {s} -> {s}", .{ hostname, guest_entry.ip, nip });
                _ = state.updateIp(hostname, nip);

                return tcp.hostConnect(io, nip, hostname, protocol.DEFAULT_PORT) catch |retry_err| {
                    std.log.err("[arp] retry connect to {s} ({s}) also failed: {}", .{ hostname, nip, retry_err });
                    return retry_err;
                };
            }
        }

        return primary_err;
    };
}

/// Push an upgrade binary to a Guest.  Used by both manual --upgrade (IPC)
/// and automatic version-mismatch detection (LSA manager).
/// Returns an error string on failure (caller does NOT own), or null on success.
pub fn pushUpgrade(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *GuestTable,
    hostname: []const u8,
) ?[]const u8 {
    // 1. Look up Guest entry
    const guest_entry = state.findByHostname(hostname) orelse return "GuestNotFound";
    defer state.freeEntry(guest_entry);

    // 2. Determine deployment filename from target triple
    const filename = protocol.deploymentFilename(guest_entry.target) orelse {
        std.log.err("[auto-upgrade] unknown guest target: {s}", .{guest_entry.target});
        return "UnknownTarget";
    };

    // 3. Open binary from serve-dir（文件名含版本号，如 utmm-aarch64-linux-0.15.10）
    var path_buf: [512]u8 = undefined;
    const serve_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ svc.canonicalDir(), filename }) catch return "PathTooLong";

    const bin_file = std.Io.Dir.cwd().openFile(io, serve_path, .{ .mode = .read_only }) catch |err| {
        std.log.err("[auto-upgrade] open {s}: {}", .{ serve_path, err });
        std.log.err("[auto-upgrade] expected {s} in serve-dir — run 'zig build cross -Doptimize=ReleaseSafe && utmm --deploy' first", .{filename});
        return "BinaryNotFound: run zig build cross + deploy to populate serve-dir";
    };
    defer bin_file.close(io);

    // 4. Read and validate file size
    const file_size_b: u64 = (bin_file.stat(io) catch return "StatFailed").size;
    if (file_size_b == 0 or file_size_b > 50 * 1024 * 1024) {
        std.log.err("[auto-upgrade] invalid file size: {d}", .{file_size_b});
        return "InvalidBinary";
    }
    const file_size: u32 = @intCast(file_size_b);

    // 5. Read entire binary into memory
    const file_data = gpa.alloc(u8, file_size) catch return "AllocFailed";
    defer gpa.free(file_data);
    _ = bin_file.readPositionalAll(io, file_data, 0) catch |err| {
        std.log.err("[auto-upgrade] read {s}: {}", .{ serve_path, err });
        return "ReadFailed";
    };

    // 6. Compute SHA256
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(file_data);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);
    var sha256_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const h = "0123456789abcdef";
        sha256_hex[i * 2] = h[byte >> 4];
        sha256_hex[i * 2 + 1] = h[byte & 0x0f];
    }

    std.log.info("[auto-upgrade] {s} ({s}): {d} bytes, sha256={s}", .{ hostname, guest_entry.target, file_size, &sha256_hex });

    // 7. Connect to Guest via SOCKS5 (with ARP recovery)
    var tcp_conn = connectGuest(io, gpa, state, hostname) catch |err| {
        std.log.err("[auto-upgrade] TCP connect to {s} failed: {}", .{ hostname, err });
        return "GuestConnectFailed";
    };
    defer tcp_conn.deinit();

    // 8. Build and send upgrade_cmd frame
    const cmd_id = std.fmt.allocPrint(gpa, "up-{d}", .{@as(u64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds))}) catch return "AllocFailed";
    defer gpa.free(cmd_id);

    const up_frame = protocol.buildUpgradeCmd(gpa, cmd_id, guest_entry.target, file_size, &sha256_hex, protocol.VERSION) catch return "AllocFailed";
    defer gpa.free(up_frame);

    // Fire-and-forget: push upgrade_cmd + raw binary
    tcp_conn.sendAndFlush(up_frame, 0) catch |e| std.log.warn("[host] auto-upgrade send frame failed: {}", .{e});
    _ = tcp.sockWrite(tcp_conn.fd, file_data.ptr, file_size);

    std.log.info("[auto-upgrade] {s} pushed (fire-and-forget, {d} bytes)", .{ hostname, file_size });
    return null; // success
}

/// Thread entry point for auto-upgrade push: calls pushUpgrade then frees hostname.
fn pushUpgradeThread(
    io: std.Io,
    gpa: std.mem.Allocator,
    state: *GuestTable,
    hostname: []const u8,
) void {
    defer gpa.free(hostname);
    const err_msg = pushUpgrade(io, gpa, state, hostname);
    if (err_msg) |msg| {
        std.log.err("[auto-upgrade] pushUpgrade({s}) failed: {s}", .{ hostname, msg });
    }
}

fn hostMainLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *GuestTable,
    mesh_opt: *?lsa.Mesh,
    host_ip: []const u8,
    host_hostname: []const u8,
) void {
    defer allocator.free(host_ip);
    defer allocator.free(host_hostname);
    // Pre-allocated list for LSA snapshots (reused across iterations).
    var snapshots: std.ArrayList(struct { node_id: lsa.NodeId, info_copy: []const u8 }) = .empty;
    defer {
        for (snapshots.items) |s| allocator.free(s.info_copy);
        snapshots.deinit(allocator);
    }

    // Auto-upgrade cooldown map: hostname → last push timestamp (ms)
    var last_upgrade = LastUpgradeMap.init(allocator);
    defer {
        var it = last_upgrade.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        last_upgrade.deinit();
    }

    while (true) {
        // Check shutdown
        if (mesh_opt.*) |*m| {
            if (m.shutdown.load(.acquire)) break;
        } else break;

        // ── Phase 1: snapshot LSAs under lock ──
        if (mesh_opt.*) |*m| {
            m.lsas_mutex.lock(m.io) catch continue;
            defer m.lsas_mutex.unlock(m.io);

            // Clear previous snapshot
            for (snapshots.items) |s| allocator.free(s.info_copy);
            snapshots.clearRetainingCapacity();

            var lsa_it = m.lsas.iterator();
            while (lsa_it.next()) |entry| {
                // Skip self (Host node)
                if (std.mem.eql(u8, entry.key_ptr, &m.node_id)) continue;

                const info_copy = allocator.dupe(u8, entry.value_ptr.node_info) catch continue;
                snapshots.append(allocator, .{
                    .node_id = entry.key_ptr.*,
                    .info_copy = info_copy,
                }) catch {
                    allocator.free(info_copy);
                    continue;
                };
            }
        }

        // ── Phase 2: process snapshot outside lock ──
        for (snapshots.items) |s| {
            // Parse guest info from LSA node_info string
            var hostname: []const u8 = "";
            var ip: []const u8 = "";
            var target: []const u8 = "";
            var version: []const u8 = "";
            var shell: []const u8 = "";
            var mac_str: []const u8 = "";
            var status: []const u8 = "";
            var role: []const u8 = "";
            var conpty: []const u8 = "";

            var line_it = std.mem.splitScalar(u8, s.info_copy, '\n');
            while (line_it.next()) |line| {
                if (parseNodeInfoLine(line, "hostname")) |v| hostname = v;
                if (parseNodeInfoLine(line, "ip")) |v| ip = v;
                if (parseNodeInfoLine(line, "target")) |v| target = v;
                if (parseNodeInfoLine(line, "version")) |v| version = v;
                if (parseNodeInfoLine(line, "shell")) |v| shell = v;
                if (parseNodeInfoLine(line, "status")) |v| status = v;
                if (parseNodeInfoLine(line, "role")) |v| role = v;
                if (parseNodeInfoLine(line, "conpty")) |v| conpty = v;
            }

            if (hostname.len == 0 or ip.len == 0) continue;

            // Convert mesh NodeId to MAC string
            mac_str = std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                s.node_id[0], s.node_id[1], s.node_id[2],
                s.node_id[3], s.node_id[4], s.node_id[5],
            }) catch continue;
            defer allocator.free(mac_str);

            // Upsert to guest table and set mesh MAC
            const now_ms = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms)));
            const changed = state.upsert(hostname, ip, target, mac_str, version, shell, conpty, status, role, @intCast(now_ms));
            if (changed and hostname.len > 0) {
                state.setMeshMac(hostname, s.node_id);
                syncHosts(io, allocator, state, host_ip, host_hostname);
            }

            // ── Auto-upgrade: version mismatch → push ──
            if (protocol.AUTO_UPGRADE) {
                if (version.len > 0 and role.len > 0 and
                    !std.mem.eql(u8, version, protocol.VERSION) and
                    std.mem.eql(u8, role, "guest") and
                    !std.mem.eql(u8, status, "upgrading"))
                {
                    const in_cooldown = if (last_upgrade.get(hostname)) |last_ts|
                        (now_ms - last_ts) < AUTO_UPGRADE_COOLDOWN_MS
                    else
                        false;

                    if (!in_cooldown) {
                        std.log.info("[auto-upgrade] version mismatch: {s} v{s} != Host v{s}, pushing upgrade...", .{ hostname, version, protocol.VERSION });

                        const key_dupe = allocator.dupe(u8, hostname) catch continue;
                        last_upgrade.put(key_dupe, now_ms) catch {
                            allocator.free(key_dupe);
                            continue;
                        };

                        const push_hostname = allocator.dupe(u8, hostname) catch continue;
                        const thread = std.Thread.spawn(.{}, pushUpgradeThread, .{ io, allocator, state, push_hostname }) catch {
                            allocator.free(push_hostname);
                            continue;
                        };
                        thread.detach();
                    }
                }
            }
        }

        // Sleep 5s between scans
        std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .awake) catch {};
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// GuestTable — minimal guest registry
// ═══════════════════════════════════════════════════════════════════════════

pub const GuestEntry = struct {
    hostname: []const u8,
    role: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    version: []const u8,
    shell: []const u8,
    conpty: []const u8,
    status: []const u8,
    last_seen: i64,
    mesh_mac: ?[6]u8 = null,
};

pub const GuestTable = struct {
    guests: std.ArrayList(GuestEntry),
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) GuestTable {
        return .{
            .guests = .empty,
            .allocator = allocator,
            .io = io,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *GuestTable) void {
        for (self.guests.items) |*entry| {
            self.allocator.free(entry.hostname);
            self.allocator.free(entry.ip);
            self.allocator.free(entry.target);
            self.allocator.free(entry.mac);
            self.allocator.free(entry.version);
            if (entry.shell.len > 0) self.allocator.free(entry.shell);
            if (entry.conpty.len > 0) self.allocator.free(entry.conpty);
            if (entry.status.len > 0) self.allocator.free(entry.status);
            if (entry.role.len > 0) self.allocator.free(entry.role);
        }
        self.guests.deinit(self.allocator);
    }

    fn indexOf(self: *GuestTable, hostname: []const u8) ?usize {
        for (self.guests.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.hostname, hostname)) return i;
        }
        return null;
    }

    /// Returns a copy of the guest entry with all strings owned (duped).
    /// Caller must call freeEntry() to release the returned entry's memory.
    pub fn findByHostname(self: *GuestTable, hostname: []const u8) ?GuestEntry {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        const idx = self.indexOf(hostname) orelse return null;
        const src = self.guests.items[idx];
        return GuestEntry{
            .hostname = self.allocator.dupe(u8, src.hostname) catch return null,
            .ip = self.allocator.dupe(u8, src.ip) catch return null,
            .target = self.allocator.dupe(u8, src.target) catch return null,
            .mac = self.allocator.dupe(u8, src.mac) catch return null,
            .version = self.allocator.dupe(u8, src.version) catch return null,
            .shell = if (src.shell.len > 0) self.allocator.dupe(u8, src.shell) catch return null else "",
            .conpty = if (src.conpty.len > 0) self.allocator.dupe(u8, src.conpty) catch return null else "",
            .status = if (src.status.len > 0) self.allocator.dupe(u8, src.status) catch return null else "",
            .role = if (src.role.len > 0) self.allocator.dupe(u8, src.role) catch return null else "guest",
            .last_seen = src.last_seen,
            .mesh_mac = src.mesh_mac,
        };
    }

    /// Free all strings in an entry returned by findByHostname.
    pub fn freeEntry(self: *GuestTable, entry: GuestEntry) void {
        if (entry.hostname.len > 0) self.allocator.free(entry.hostname);
        if (entry.ip.len > 0) self.allocator.free(entry.ip);
        if (entry.target.len > 0) self.allocator.free(entry.target);
        if (entry.mac.len > 0) self.allocator.free(entry.mac);
        if (entry.version.len > 0) self.allocator.free(entry.version);
        if (entry.shell.len > 0) self.allocator.free(entry.shell);
        if (entry.conpty.len > 0) self.allocator.free(entry.conpty);
        if (entry.status.len > 0) self.allocator.free(entry.status);
        if (entry.role.len > 0) self.allocator.free(entry.role);
    }

    pub fn upsert(
        self: *GuestTable,
        hostname: []const u8,
        ip: []const u8,
        target: []const u8,
        mac: []const u8,
        version: []const u8,
        shell: []const u8,
        conpty: []const u8,
        status: []const u8,
        role: []const u8,
        last_seen: i64,
    ) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        if (self.indexOf(hostname)) |idx| {
            var changed = false;
            const existing = &self.guests.items[idx];

            // 更新各个字段：先 dupe 到临时变量，成功后释放旧值。
            // 不能先 free 再 dupe — dupe 失败会留下指向已释放内存的野指针。
            if (!std.mem.eql(u8, existing.ip, ip)) {
                const new_ip = self.allocator.dupe(u8, ip) catch return changed;
                self.allocator.free(existing.ip);
                existing.ip = new_ip;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.target, target)) {
                const new_target = self.allocator.dupe(u8, target) catch return changed;
                self.allocator.free(existing.target);
                existing.target = new_target;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.version, version)) {
                const new_ver = self.allocator.dupe(u8, version) catch return changed;
                self.allocator.free(existing.version);
                existing.version = new_ver;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.shell, shell)) {
                const new_shell = self.allocator.dupe(u8, shell) catch return changed;
                if (existing.shell.len > 0) self.allocator.free(existing.shell);
                existing.shell = new_shell;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.conpty, conpty)) {
                const new_conpty = self.allocator.dupe(u8, conpty) catch return changed;
                if (existing.conpty.len > 0) self.allocator.free(existing.conpty);
                existing.conpty = new_conpty;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.status, status)) {
                const new_status = self.allocator.dupe(u8, status) catch return changed;
                if (existing.status.len > 0) self.allocator.free(existing.status);
                existing.status = new_status;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.role, role)) {
                const new_role = self.allocator.dupe(u8, role) catch return changed;
                if (existing.role.len > 0) self.allocator.free(existing.role);
                existing.role = new_role;
                changed = true;
            }
            if (!std.mem.eql(u8, existing.mac, mac)) {
                const new_mac = self.allocator.dupe(u8, mac) catch return changed;
                self.allocator.free(existing.mac);
                existing.mac = new_mac;
                changed = true;
            }
            existing.last_seen = last_seen;
            return changed;
        }

        self.guests.append(self.allocator, .{
            .hostname = self.allocator.dupe(u8, hostname) catch hostname,
            .ip = self.allocator.dupe(u8, ip) catch ip,
            .target = self.allocator.dupe(u8, target) catch target,
            .mac = self.allocator.dupe(u8, mac) catch mac,
            .version = self.allocator.dupe(u8, version) catch version,
            .shell = if (shell.len > 0) self.allocator.dupe(u8, shell) catch shell else "",
            .conpty = if (conpty.len > 0) self.allocator.dupe(u8, conpty) catch conpty else "",
            .status = if (status.len > 0) self.allocator.dupe(u8, status) catch status else "",
            .role = if (role.len > 0) self.allocator.dupe(u8, role) catch role else "guest",
            .last_seen = last_seen,
        }) catch return false;
        return true;
    }

    pub fn remove(self: *GuestTable, hostname: []const u8) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        const idx = self.indexOf(hostname) orelse return;
        const entry = self.guests.swapRemove(idx);
        self.allocator.free(entry.hostname);
        self.allocator.free(entry.ip);
        self.allocator.free(entry.target);
        self.allocator.free(entry.mac);
        self.allocator.free(entry.version);
        if (entry.shell.len > 0) self.allocator.free(entry.shell);
        if (entry.conpty.len > 0) self.allocator.free(entry.conpty);
        if (entry.status.len > 0) self.allocator.free(entry.status);
        if (entry.role.len > 0) self.allocator.free(entry.role);
    }

    pub fn setMeshMac(self: *GuestTable, hostname: []const u8, mac_bytes: [6]u8) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        const idx = self.indexOf(hostname) orelse return;
        self.guests.items[idx].mesh_mac = mac_bytes;
    }

    /// 更新 Guest IP（用于 ARP 重发现后更新）。
    /// 返回 true 表示 IP 已变更，false 表示未变更或未找到。
    pub fn updateIp(self: *GuestTable, hostname: []const u8, new_ip: []const u8) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const idx = self.indexOf(hostname) orelse return false;
        const existing = &self.guests.items[idx];
        if (std.mem.eql(u8, existing.ip, new_ip)) return false;
        self.allocator.free(existing.ip);
        existing.ip = self.allocator.dupe(u8, new_ip) catch return false;
        return true;
    }
};

/// Sync /etc/hosts with all known guests + gateway entry. Uses lsa.updateHosts
/// which does temp-file + atomic rename for safe concurrent writes.
fn syncHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *GuestTable,
    gateway_ip: []const u8,
    gateway_name: []const u8,
) void {
    var entries: std.ArrayList(lsa.HostEntry) = .empty;
    defer entries.deinit(allocator);

    // Gateway entry first (Host's own IP for Host mode)
    if (gateway_ip.len > 0 and gateway_name.len > 0) {
        entries.append(allocator, .{ .ip = gateway_ip, .name = gateway_name }) catch return;
    }

    // Lock and collect all guest entries (skip Host itself — already added as gateway above)
    state.mutex.lock(io) catch return;
    defer state.mutex.unlock(io);
    for (state.guests.items) |g| {
        if (g.ip.len > 0 and g.hostname.len > 0) {
            // Skip Host's own entry added at line 594 to avoid duplicate with gateway entry
            if (gateway_ip.len > 0 and std.mem.eql(u8, g.ip, gateway_ip)) continue;
            entries.append(allocator, .{ .ip = g.ip, .name = g.hostname }) catch continue;
        }
    }

    lsa.updateHosts(io, allocator, "/etc/hosts", entries.items) catch |err| {
        std.log.err("[host] updateHosts /etc/hosts: {}", .{err});
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// GuestTable tests
// ═══════════════════════════════════════════════════════════════════════════

/// Helper: create a single-threaded Io for tests (needed by GuestTable mutex).
fn testIo() std.Io {
    const ti = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return ti.threaded.io();
}

test "GuestTable init and deinit" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 0), table.guests.items.len);
}

test "GuestTable upsert and findByHostname" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "serving", "guest", 1000);
    try std.testing.expectEqual(@as(usize, 1), table.guests.items.len);

    const found = table.findByHostname("linuxvm");
    defer if (found != null) table.freeEntry(found.?);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("192.168.64.2", found.?.ip);
    try std.testing.expectEqualStrings("aarch64-linux-musl", found.?.target);
    try std.testing.expectEqualStrings("/bin/bash", found.?.shell);
    try std.testing.expectEqual(@as(i64, 1000), found.?.last_seen);

    const missing = table.findByHostname("nonexist");
    try std.testing.expect(missing == null);
}

test "GuestTable upsert updates existing guest" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "", "guest", 1000);
    const changed = table.upsert("linuxvm", "192.168.64.3", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.14.0", "/bin/zsh", "yes", "serving", "guest", 2000);

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), table.guests.items.len);

    const found = table.findByHostname("linuxvm").?;
    defer table.freeEntry(found);
    try std.testing.expectEqualStrings("192.168.64.3", found.ip);
    try std.testing.expectEqualStrings("0.14.0", found.version);
    try std.testing.expectEqualStrings("/bin/zsh", found.shell);
    try std.testing.expectEqualStrings("serving", found.status);
    try std.testing.expectEqual(@as(i64, 2000), found.last_seen);
}

test "GuestTable upsert detects MAC change" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "", "guest", 1000);
    // Change only the MAC address — should be detected
    const changed = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "11:22:33:44:55:66", "0.13.0", "/bin/bash", "yes", "", "guest", 2000);

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), table.guests.items.len);

    const found = table.findByHostname("linuxvm").?;
    defer table.freeEntry(found);
    try std.testing.expectEqualStrings("11:22:33:44:55:66", found.mac);
}

test "GuestTable upsert no-change returns false" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "serving", "guest", 1000);
    const changed = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "serving", "guest", 1000);

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(usize, 1), table.guests.items.len);
}

test "GuestTable remove" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "", "guest", 1000);
    _ = table.upsert("macvm", "192.168.64.4", "aarch64-macos", "11:22:33:44:55:66", "0.13.0", "/bin/zsh", "yes", "", "guest", 2000);
    try std.testing.expectEqual(@as(usize, 2), table.guests.items.len);

    table.remove("linuxvm");
    try std.testing.expectEqual(@as(usize, 1), table.guests.items.len);
    try std.testing.expect(table.findByHostname("linuxvm") == null);
    const mac_found = table.findByHostname("macvm");
    defer if (mac_found != null) table.freeEntry(mac_found.?);
    try std.testing.expect(mac_found != null);

    table.remove("nonexist");
}

test "GuestTable setMeshMac" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "", "guest", 1000);
    try std.testing.expect(table.guests.items[0].mesh_mac == null);

    const mac: [6]u8 = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    table.setMeshMac("linuxvm", mac);
    try std.testing.expect(table.guests.items[0].mesh_mac != null);
    try std.testing.expectEqual(mac, table.guests.items[0].mesh_mac.?);

    table.setMeshMac("nonexist", mac);
}

test "GuestTable findByHostname after update" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("winx64", "192.168.3.1", "x86_64-windows", "ff:ee:dd:cc:bb:aa", "0.13.0", "cmd.exe", "yes", "upgrading", "guest", 3000);

    const found = table.findByHostname("winx64").?;
    defer table.freeEntry(found);
    try std.testing.expectEqualStrings("cmd.exe", found.shell);
    try std.testing.expectEqualStrings("upgrading", found.status);
    try std.testing.expectEqualStrings("x86_64-windows", found.target);
    try std.testing.expectEqual(@as(i64, 3000), found.last_seen);
}

test "GuestTable updateIp" {
    const allocator = std.testing.allocator;
    var table = GuestTable.init(allocator, testIo());
    defer table.deinit();

    _ = table.upsert("linuxvm", "192.168.64.2", "aarch64-linux-musl", "aa:bb:cc:dd:ee:ff", "0.13.0", "/bin/bash", "yes", "", "guest", 1000);

    // updateIp: change IP
    try std.testing.expect(table.updateIp("linuxvm", "192.168.64.99"));
    const found = table.findByHostname("linuxvm").?;
    defer table.freeEntry(found);
    try std.testing.expectEqualStrings("192.168.64.99", found.ip);

    // updateIp: no change
    try std.testing.expect(!table.updateIp("linuxvm", "192.168.64.99"));

    // updateIp: nonexistent hostname
    try std.testing.expect(!table.updateIp("noexist", "10.0.0.1"));
}
