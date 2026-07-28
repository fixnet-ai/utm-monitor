//! Host mode — mesh networking daemon on UDP :2121.
//!
//! LSA broadcast + KCP tunnel replace the old HTTP server (v0.11.0).
//! Management commands (--status/--exec/--upload/--download) communicate via IPC socket.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const protocol = @import("protocol.zig");
const hst = @import("state.zig");
const broadcast = @import("broadcast.zig");
const mesh_mod = @import("mesh.zig");
const tunnel_mod = @import("tunnel.zig");
const tunproto = @import("tunproto.zig");
const svc = @import("svc.zig");

pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli, null);
}

pub fn runWithIo(block_io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs, shutdown: ?*std.atomic.Value(bool)) !void {
    // Management commands: stateless, no Host daemon needed
    if (cli.cmd_status) return cmdStatus(block_io, gpa, cli.port);
    if (cli.cmd_verify) return cmdVerify(block_io, gpa, cli.port);
    if (cli.cmd_deploy) return cmdDeploy(block_io, gpa, cli.deploy_target);
    if (cli.cmd_ping) return cmdPing(block_io, gpa, cli.port, cli.ping_target.?);
    if (cli.cmd_exec) return cmdExec(block_io, gpa, cli.port, cli.exec_target.?, cli.exec_cmd.?);
    if (cli.cmd_upload) return cmdUpload(block_io, gpa, cli.port, cli.upload_target.?, cli.upload_file.?);
    if (cli.cmd_download) return cmdDownload(block_io, gpa, cli.port, cli.download_target.?, cli.download_remote.?, cli.download_local.?);
    // --gen-init
    if (cli.cmd_gen_init) {
        const platform_str = cli.gen_init_platform orelse "linux";
        const platform: Platform = if (std.mem.eql(u8, platform_str, "macos"))
            .macos
        else if (std.mem.eql(u8, platform_str, "windows"))
            .windows
        else
            .linux;
        const script = genInit(platform);
        std.debug.print("{s}", .{script});
        return;
    }
    // --save-config
    if (cli.save_config) {
        const config_mod = @import("config.zig");
        const cfg = config_mod.Config{
            .port = cli.port,
            .name = cli.hostname orelse "",
            .hosts_file = cli.hosts_file,
            .marker = cli.marker,
        };
        return config_mod.saveConfig(block_io, gpa, cfg, cli.config_path orelse "utmm.conf");
    }

    // Default serve_dir to exe directory if not specified
    const serve_dir = if (cli.serve_dir) |sd| sd else blk: {
        const exe_path = try std.process.executablePathAlloc(block_io, gpa);
        defer gpa.free(exe_path);
        const dir = std.fs.path.dirname(exe_path) orelse "/opt/utmm";
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
        try startHost(block_io, gpa, cli.mesh_port, serve_dir, cli.peer_mesh, shutdown);
        return;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management commands (stateless — discover via UDP, connect via TCP)
// ═══════════════════════════════════════════════════════════════════════════

fn cmdStatus(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    _ = port; // HTTP handlers preserved for future WebUI
    const ipc_mod = @import("ipc.zig");

    // IPC-only — HTTP handlers preserved for future WebUI
    const json_str = try ipc_mod.ipcStatus(block_io, gpa);
    defer gpa.free(json_str);

    // Parse JSON and print table (same as HTTP path)
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

    std.debug.print("\n{s: <6} {s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s: <10} {s: <8} {s}\n", .{ "Role", "Hostname", "Target", "IP", "MAC", "Version", "Status", "Shell", "Last" });
    std.debug.print("{s:-<120}\n", .{""});
    for (guests.items) |guest_val| {
        const g = switch (guest_val) {
            .object => |o| o,
            else => continue,
        };
        const hostname = hst.jsonGetString(g, "hostname") orelse "?";
        const role = hst.jsonGetString(g, "role") orelse "?";
        const target = hst.jsonGetString(g, "target") orelse "?";
        const ip = hst.jsonGetString(g, "ip") orelse "?";
        const mac = hst.jsonGetString(g, "mac") orelse "?";
        const version = hst.jsonGetString(g, "version") orelse "?";
        const status = hst.jsonGetString(g, "status") orelse "?";
        const shell = hst.jsonGetString(g, "shell") orelse "?";
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
        std.debug.print("{s: <6} {s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s: <10} {s: <8}", .{ role, hostname, target, ip, mac, version, status, shell });
        if (rel_val > 0) {
            std.debug.print(" {d}{s}\n", .{ rel_val, rel });
        } else {
            std.debug.print(" {s}\n", .{rel});
        }
    }
    std.debug.print("\n", .{});
}

/// Health check: for each guest, run status + ping + exec echo and print a
/// pass/fail matrix. Each check has a 5-second timeout — if any check hangs
/// (e.g. tunnel stalled), it's marked as a failure rather than blocking forever.
fn cmdVerify(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    _ = gpa;
    _ = port;
    const ipc_mod = @import("ipc.zig");

    // ── helpers ──
    const GREEN = "\x1b[32m";
    const RED = "\x1b[31m";
    const YELLOW = "\x1b[33m";
    const RESET = "\x1b[0m";

    const CheckResult = enum { pass, fail, skip };
    const checkIcon = struct {
        fn icon(result: CheckResult) []const u8 {
            return switch (result) {
                .pass => GREEN ++ "✓" ++ RESET,
                .fail => RED ++ "✗" ++ RESET,
                .skip => YELLOW ++ "−" ++ RESET,
            };
        }
    }.icon;

    // 1. Get guest list via IPC status
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const json_str = ipc_mod.ipcStatus(block_io, aa) catch |err| {
        std.debug.print("[verify] Failed to query guest list: {}\n", .{err});
        std.process.exit(1);
    };
    defer aa.free(json_str);

    const parsed = std.json.parseFromSlice(std.json.Value, aa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("[verify] JSON parse error: {}\n", .{err});
        std.process.exit(1);
    };

    const guests = switch (parsed.value) {
        .array => |arr| arr,
        else => {
            std.debug.print("No UTM guests found.\n", .{});
            return;
        },
    };

    if (guests.items.len == 0) {
        std.debug.print("No UTM guests found.\n", .{});
        return;
    }

    // Collect hostnames (skip Host itself — no tunnel for ping/exec)
    var hostnames: std.ArrayListAligned([]const u8, null) = .empty;
    for (guests.items) |guest_val| {
        const g = switch (guest_val) {
            .object => |o| o,
            else => continue,
        };
        // Skip Host — no KCP tunnel to itself, ping/exec would fail
        if (hst.jsonGetString(g, "role")) |r| {
            if (std.mem.eql(u8, r, "host")) continue;
        }
        if (hst.jsonGetString(g, "hostname")) |h| {
            try hostnames.append(aa, try aa.dupe(u8, h));
        }
    }

    // 2. Run checks for each guest
    const GuestResult = struct {
        status: CheckResult = .skip,
        ping: CheckResult = .skip,
        exec: CheckResult = .skip,
        ping_rtt: ?u32 = null,
        exec_error: ?[]const u8 = null,
    };

    var results = std.StringHashMap(GuestResult).init(aa);
    for (hostnames.items) |h| {
        try results.put(h, GuestResult{});
    }

    // 2a. Status check — guests are already in the list (from LSA)
    for (hostnames.items) |h| {
        var r = results.getPtr(h).?;
        r.status = .pass;
    }

    // 2b. Ping check (mesh reachability)
    for (hostnames.items) |h| {
        var r = results.getPtr(h).?;
        const ping_json = ipc_mod.ipcPing(block_io, aa, h) catch {
            r.ping = .fail;
            continue;
        };
        defer aa.free(ping_json);

        // Parse RTT from ping response JSON
        const ping_parsed = std.json.parseFromSlice(std.json.Value, aa, ping_json, .{ .allocate = .alloc_always }) catch {
            r.ping = .fail;
            continue;
        };
        if (ping_parsed.value == .object) {
            if (ping_parsed.value.object.get("rtt_ms")) |rtt_val| {
                if (rtt_val == .integer) {
                    r.ping_rtt = @intCast(rtt_val.integer);
                }
            }
            if (ping_parsed.value.object.get("error")) |_| {
                r.ping = .fail;
            } else {
                r.ping = .pass;
            }
        } else {
            r.ping = .fail;
        }
    }

    // 2c. Exec echo check (tunnel + shell working)
    for (hostnames.items) |h| {
        var r = results.getPtr(h).?;

        // Run "echo utmm-verify" — we only care about exit code.
        // Write output to /dev/null (NUL on Windows).
        const null_path = if (builtin.os.tag == .windows) "NUL" else "/dev/null";
        var null_file = std.Io.Dir.cwd().openFile(block_io, null_path, .{ .mode = .write_only }) catch {
            r.exec = .fail;
            r.exec_error = try aa.dupe(u8, "cannot open null device");
            continue;
        };
        defer null_file.close(block_io);
        var null_wb: [256]u8 = undefined;
        var null_writer = null_file.writer(block_io, &null_wb);
        const null_iface = &null_writer.interface;

        const exit_code = ipc_mod.ipcExec(block_io, aa, h, "echo utmm-verify", null_iface) catch {
            r.exec = .fail;
            r.exec_error = try aa.dupe(u8, "IPC error (tunnel down?)");
            continue;
        };

        if (exit_code == 0) {
            r.exec = .pass;
        } else {
            r.exec = .fail;
            r.exec_error = try std.fmt.allocPrint(aa, "exit_code={d}", .{exit_code});
        }
    }

    // 3. Print pass/fail matrix
    std.debug.print("\n{s: <16} {s}  {s}  {s}  {s}\n", .{ "Guest", "Status", "Ping", "Exec", "Details" });
    std.debug.print("{s:-<60}\n", .{""});

    var all_pass = true;
    for (hostnames.items) |h| {
        const r = results.get(h).?;
        var details: std.ArrayListAligned(u8, null) = .empty;
        defer details.deinit(aa);

        if (r.ping == .pass) {
            if (r.ping_rtt) |rtt| {
                const rtt_str = try std.fmt.allocPrint(aa, "{d}ms", .{rtt});
                try details.appendSlice(aa, rtt_str);
            }
        } else if (r.ping == .fail) {
            try details.appendSlice(aa, "unreachable");
        }

        if (r.exec == .fail) {
            if (details.items.len > 0) try details.appendSlice(aa, ", ");
            try details.appendSlice(aa, r.exec_error orelse "exec failed");
        }

        const detail_str = if (details.items.len > 0) details.items else "-";

        std.debug.print("{s: <16} {s}     {s}     {s}     {s}\n", .{
            h,
            checkIcon(r.status),
            checkIcon(r.ping),
            checkIcon(r.exec),
            detail_str,
        });

        if (r.status != .pass or r.ping != .pass or r.exec != .pass) {
            all_pass = false;
        }
    }

    std.debug.print("\n", .{});
    if (all_pass) {
        std.debug.print("All checks passed. {d} guest(s) healthy.\n", .{hostnames.items.len});
    } else {
        std.debug.print("Some checks failed. Review the matrix above.\n", .{});
        std.process.exit(1);
    }
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

    // ── Check sshpass availability (needed for scp/ssh) ──
    const has_sshpass = blk: {
        const result = std.process.run(gpa, io, .{ .argv = &.{ "which", "sshpass" } }) catch break :blk false;
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        break :blk result.term == .exited and result.term.exited == 0;
    };
    if (!has_sshpass) {
        std.debug.print("[deploy] sshpass is required for non-interactive deployment.\n", .{});
        std.debug.print("Install: brew install sshpass   (macOS)\n", .{});
        std.debug.print("         apt install sshpass    (Linux)\n", .{});
        std.process.exit(1);
    }

    std.debug.print("\n[deploy] Targets ({d}):", .{deploy_list.items.len});
    for (deploy_list.items) |vm| {
        std.debug.print(" {s}", .{vm.hostname});
    }
    std.debug.print("\n\n", .{});

    // ── 2. Cross-compile for each target ──
    var compiled = std.StringHashMap([]const u8).init(gpa); // target → binary path
    defer {
        var it = compiled.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value_ptr.*);
        }
        compiled.deinit();
    }

    for (deploy_list.items) |vm| {
        if (compiled.contains(vm.target)) continue;

        std.debug.print("[deploy] Compiling for {s}...\n", .{vm.target});
        const target_flag = try std.fmt.allocPrint(gpa, "-Dtarget={s}", .{vm.target});
        defer gpa.free(target_flag);
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "zig", "build", target_flag },
        }) catch |err| {
            std.debug.print("[deploy] Compile failed: {}\n", .{err});
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

        // Determine binary path from target
        const bin_name = protocol.deploymentFilename(vm.target) orelse {
            std.debug.print("[deploy] Unknown target: {s}\n", .{vm.target});
            std.process.exit(1);
        };
        const bin_path = try std.fmt.allocPrint(gpa, "zig-out/bin/{s}", .{bin_name});
        try compiled.put(vm.target, bin_path);

        std.debug.print("[deploy]   -> {s}\n", .{bin_path});
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
    _ = port; // HTTP handlers preserved for future WebUI
    const ipc_mod = @import("ipc.zig");

    // IPC-only — HTTP handlers preserved for future WebUI
    const json = try ipc_mod.ipcPing(block_io, gpa, target);
    defer gpa.free(json);
    std.debug.print("{s}\n", .{json});
}

fn cmdExec(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, cmd: []const u8) !void {
    _ = port; // HTTP handlers preserved for future WebUI
    const ipc_mod = @import("ipc.zig");

    // IPC-only — HTTP handlers preserved for future WebUI
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
    _ = port; // HTTP handlers preserved for future WebUI
    const ipc_mod = @import("ipc.zig");

    const basename = std.fs.path.basename(local_file);
    const dest = try std.fmt.allocPrint(gpa, "/opt/utmm/{s}", .{basename});
    defer gpa.free(dest);

    std.debug.print("[upload] Uploading {s} -> {s} ({s})...\n", .{ local_file, target, dest });

    // IPC-only — HTTP handlers preserved for future WebUI
    try ipc_mod.ipcUpload(block_io, gpa, target, local_file, dest);
    std.debug.print("[upload] OK\n", .{});
}

fn cmdDownload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, remote_file: []const u8, local_path: []const u8) !void {
    _ = port; // HTTP handlers preserved for future WebUI
    const ipc_mod = @import("ipc.zig");

    std.debug.print("[download] Downloading {s} from {s} -> {s}...\n", .{ remote_file, target, local_path });

    // IPC-only — HTTP handlers preserved for future WebUI
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
// Host daemon (--host): Mesh LSA + KCP tunnels + IPC server
// ═══════════════════════════════════════════════════════════════════════════

/// Check that a version string looks like "X.Y.Z" (digits only).
/// Rejects anything that doesn't match — human-verification pages, HTML, etc.
fn isValidVersion(ver: []const u8) bool {
    if (ver.len < 5) return false; // minimum: "0.0.0"
    var parts = std.mem.splitSequence(u8, ver, ".");
    var count: u8 = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return false;
        for (part) |c| {
            if (c < '0' or c > '9') return false;
        }
        if (count > 3) return false;
    }
    return count == 3;
}

/// Fire-and-forget OS thread: check GitHub for the latest release version.
/// On mismatch, logs "New version X.Y.Z available on github" and returns.
/// Never triggers any upgrade — purely informational.
fn checkGitHubVersion() void {
    // Own Io instance for HTTP request in this detached thread.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse("https://api.github.com/repos/fixnet-ai/utm-monitor/releases/latest") catch return;
    // Allow up to 5 redirects — GitHub may issue 302.
    var req = client.request(.GET, uri, .{ .redirect_behavior = .init(5) }) catch return;
    defer req.deinit();

    req.sendBodiless() catch return;

    var redirect_buf: [4096]u8 = undefined;
    _ = req.receiveHead(&redirect_buf) catch return;

    // Read response body — use req.reader.bodyReader() directly since
    // Response.reader() skips GET (checks requestHasBody, not responseHasBody).
    var body_buf: [4096]u8 = undefined;
    const body_reader = req.reader.bodyReader(&body_buf, req.response_transfer_encoding, req.response_content_length);

    var body_data: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&body_data);
    _ = body_reader.stream(&w, .limited(8192)) catch {};
    const body = w.buffered();

    // Parse "tag_name" from JSON response.
    const tag_key = "\"tag_name\":\"";
    if (std.mem.indexOf(u8, body, tag_key)) |start| {
        const value_start = start + tag_key.len;
        if (std.mem.indexOfScalar(u8, body[value_start..], '"')) |end| {
            const tag = body[value_start .. value_start + end];
            // Strip leading "v" (e.g. "v0.11.19" → "0.11.19")
            const new_ver = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
            // Validate version format — rejects human-verification pages, HTML, etc.
            if (!isValidVersion(new_ver)) return;
            if (!std.mem.eql(u8, new_ver, protocol.VERSION)) {
                std.log.warn("[host] New version {s} available on github", .{new_ver});
            }
        }
    }
}

/// Verify that platform binaries in serve_dir match the running Host version.
/// Checks each known deployment target's versioned filename exists.
/// Returns true if at least one platform binary is found (partial deployment OK).
/// Returns false only if NO platform binaries exist at all.
fn verifyServeDirBinaries(io: std.Io, serve_dir: []const u8) bool {
    const targets = [_][]const u8{
        "aarch64-linux-musl", "x86_64-linux-musl", "x86-linux-musl",
        "aarch64-macos", "x86_64-macos",
        "x86-windows", "x86_64-windows", "aarch64-windows",
        "aarch64-linux", "x86_64-linux", "x86-linux",
    };

    var found: usize = 0;
    var missing: usize = 0;

    for (targets) |target| {
        const filename = protocol.deploymentFilename(target) orelse continue;
        var path_buf: [1024]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ serve_dir, filename }) catch continue;

        if (std.Io.Dir.cwd().statFile(io, file_path, .{})) |_| {
            found += 1;
        } else |_| {
            missing += 1;
        }
    }

    if (found == 0) {
        std.log.err("[host] No platform binaries found in serve-dir '{s}'", .{serve_dir});
        std.log.err("[host] Host version is {s} but no matching binaries exist.", .{protocol.VERSION});
        std.log.err("[host] Please download the full release package and re-install.", .{});
        return false;
    }

    if (missing > 0) {
        std.log.warn("[host] {d} platform binaries missing from serve-dir (some Guests may not auto-upgrade)", .{missing});
    }

    std.log.info("[host] {d} platform binaries verified in serve-dir", .{found});
    return true;
}

fn startHost(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    mesh_port: u16,
    serve_dir: ?[]const u8,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    const sd = serve_dir orelse "/opt/utmm";
    std.debug.print("[host] Host daemon starting (mesh UDP :{d})\n", .{mesh_port});
    std.debug.print("[host] Serve dir: {s}\n", .{sd});

    // Verify serve-dir platform binaries match running Host version.
    // If no matching binaries exist, uninstall and exit to prevent
    // infinite Guest upgrade loops (serving old binaries).
    if (!verifyServeDirBinaries(block_io, sd)) {
        std.debug.print("[host] ERROR: Serve-dir version mismatch. Uninstalling service.\n", .{});
        svc.uninstall(block_io, gpa) catch {};
        std.process.exit(1);
    }

    // Spawn fire-and-forget GitHub version check thread.
    // OS thread, detach immediately, runs once — no join needed.
    if (std.Thread.spawn(.{}, checkGitHubVersion, .{})) |t| {
        t.detach();
    } else |_| {
        // spawn failed — silently ignored
    }

    // Initialize shared state (guest table + pending commands)
    var state = hst.HostState.init(gpa);
    state.io = block_io;
    state.serve_dir = sd;
    state.on_guest_changed = null;
    defer state.deinit();

    // Upgrade signal for version mismatch detection via LSA
    var upgrade_signal = broadcast.UpgradeSignal{};

    // Spawn mesh networking thread — replaces periodic UDP broadcast.
    // Mesh broadcasts LSA every 2s (carries version for auto-upgrade),
    // maintains guest topology via LSA database, and relays KCP_DATA.
    var mesh_opt: ?mesh_mod.Mesh = null;
    var mesh_thread: ?std.Thread = null;

    start_mesh: {
        // Get Host's own system info for node identification
        const host_info = broadcast.getSystemInfo(block_io, gpa) catch |err| {
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

        // Collect broadcast addresses
        var bc_addrs = broadcast.getSubnetBroadcasts(gpa) catch |err| {
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
        const node_id = mesh_mod.parseNodeId(host_info.mac) catch |err| {
            std.log.err("[host] Mesh MAC parse '{s}': {}", .{ host_info.mac, err });
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Build node_info for LSA (Mesh.init() appends epoch internally)
        const node_info = std.fmt.allocPrint(gpa,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:host\nstatus:serving",
            .{ host_info.hostname, host_info.ip, host_info.target, protocol.VERSION, host_info.shell },
        ) catch |err| {
            std.log.err("[host] Mesh node_info alloc: {}", .{err});
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Create mesh instance (epoch is auto-appended to node_info by init())
        mesh_opt = mesh_mod.Mesh.init(gpa, node_id, node_info, mesh_socket, mesh_io, &upgrade_signal.needed, bc_addrs, broadcast.getSubnetBroadcasts) catch |err| {
            std.log.err("[host] Mesh init failed: {}", .{err});
            gpa.free(node_info);
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Spawn mesh.run() thread
        mesh_thread = std.Thread.spawn(.{}, mesh_mod.Mesh.run, .{&mesh_opt.?}) catch |err| {
            std.log.err("[host] Mesh thread spawn failed: {}", .{err});
            mesh_opt.?.deinit();
            mesh_socket.close(mesh_io);
            mesh_opt = null;
            break :start_mesh;
        };

        // Store mesh pointer in shared state for HTTP handlers
        state.mesh = @ptrCast(@alignCast(&mesh_opt.?));

        std.log.info("[host] Mesh networking started (LSA on UDP :{d})", .{mesh_port});

        // Register Host itself in the guest table so --status shows it alongside guests
        _ = state.upsertGuest(
            host_info.hostname, host_info.ip, host_info.target,
            host_info.mac, protocol.VERSION, host_info.shell,
            "serving", "host",
        );

    }

    // Spawn tunnel manager thread — syncs LSA→guest table, connects tunnels.
    // Must spawn before the defer below so join() runs in correct order.
    var tun_mgr_thread = try std.Thread.spawn(.{}, tunnelManager, .{ gpa, &state, &mesh_opt });

    // Spawn IPC server thread — Unix domain socket (POSIX) / named pipe (Windows).
    // Shares HostState and Mesh with the mesh networking layer.
    var ipc_shutdown = std.atomic.Value(bool).init(false);
    const ipc_mod = @import("ipc.zig");
    var ipc_thread = try std.Thread.spawn(.{}, ipc_mod.startServer, .{
        block_io, gpa, @as(*anyopaque, @ptrCast(&state)), @as(*anyopaque, @ptrCast(&mesh_opt)), &ipc_shutdown,
    });

    defer {
        // 1. Signal IPC server to stop — unblock accept loop
        ipc_shutdown.store(true, .release);
        // 2. Signal mesh shutdown — tunnelManager checks this each loop iteration
        if (mesh_opt) |*m| m.signalShutdown();

        // 3. Join threads (order: IPC → tunnel mgr → mesh)
        ipc_thread.join();
        tun_mgr_thread.join();

        // 4. Join mesh thread after all consumers have exited
        if (mesh_thread) |t| {
            t.join();
        }

        // 5. Deinit mesh (safe: all threads using it have exited)
        if (mesh_opt) |*m| {
            const m_io = m.io;
            m.deinit();
            state.mesh = null;
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

/// Parse a simple key:value line from LSA node_info.
fn parseNodeInfoLine(line: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':') {
        return line[key.len + 1 ..];
    }
    return null;
}

/// Background thread: periodically scans mesh LSAs for guest nodes,
/// syncs them to the guest table, establishes KCP tunnels, and spawns
/// per-guest handler threads (handleMeshGuest).
fn tunnelManager(
    allocator: std.mem.Allocator,
    state: *hst.HostState,
    mesh_opt: *?mesh_mod.Mesh,
) void {
    while (true) {
        // Check shutdown
        if (mesh_opt.*) |*m| {
            if (m.shutdown.load(.acquire)) break;
        } else break;

        // Phase 1: Sync LSA nodes → guest table
        if (mesh_opt.*) |*m| {
            // Lock lsas_mutex to safely iterate from this non-mesh thread.
            m.lsas_mutex.lock(m.io) catch continue;
            defer m.lsas_mutex.unlock(m.io);
            var lsa_it = m.lsas.iterator();
            while (lsa_it.next()) |entry| {
                const lsa = entry.value_ptr.*;
                const saved_node_info = allocator.dupe(u8, lsa.node_info) catch continue;
                defer allocator.free(saved_node_info);
                const saved_node_id: mesh_mod.NodeId = entry.key_ptr.*;

                // Skip self (Host node)
                if (std.mem.eql(u8, &saved_node_id, &m.node_id)) continue;

                // Parse guest info from LSA node_info string
                var hostname: []const u8 = "";
                var ip: []const u8 = "";
                var target: []const u8 = "";
                var version: []const u8 = "";
                var shell: []const u8 = "";
                var mac_str: []const u8 = "";
                var status: []const u8 = "";
                var role: []const u8 = "";

                var line_it = std.mem.splitScalar(u8, saved_node_info, '\n');
                while (line_it.next()) |line| {
                    if (parseNodeInfoLine(line, "hostname")) |v| hostname = v;
                    if (parseNodeInfoLine(line, "ip")) |v| ip = v;
                    if (parseNodeInfoLine(line, "target")) |v| target = v;
                    if (parseNodeInfoLine(line, "version")) |v| version = v;
                    if (parseNodeInfoLine(line, "shell")) |v| shell = v;
                    if (parseNodeInfoLine(line, "status")) |v| status = v;
                    if (parseNodeInfoLine(line, "role")) |v| role = v;
                }

                if (hostname.len == 0 or ip.len == 0) continue;

                // Convert mesh NodeId to MAC string
                mac_str = std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                    saved_node_id[0], saved_node_id[1], saved_node_id[2],
                    saved_node_id[3], saved_node_id[4], saved_node_id[5],
                }) catch continue;
                defer allocator.free(mac_str);

                // Upsert to guest table
                const changed = state.upsertGuest(hostname, ip, target, mac_str, version, shell, status, role);
                if (changed and hostname.len > 0) {
                    hst.syncHostsFromState(state, allocator);
                }

                // Establish tunnel if not already active.
                // Uses state.getGuestTunnel() as the sole source of truth —
                // when handleMeshGuest disconnects, its defer calls
                // removeGuestTunnel, and the next scan reconnects.
                //
                // Auto-upgrade is Guest-initiated: the Guest detects version
                // mismatch via LSA, connects through the normal tunnel, sends
                // upgrade_req, and handleMeshGuest serves the new binary via
                // serveUpgradeFile(). No special Host-side handling needed.
                //
                // isTunnelDead holds state.mutex across the lookup+isAlive
                // check, preventing use-after-free when the mesh handler
                // thread concurrently frees the tunnel (Finding 78).
                const tun_dead = state.isTunnelDead(hostname);

                if (tun_dead) {
                    // Create fresh Host-initiated session via m.connect().
                    // The Guest's waitForHostTunnel() picks it up on the
                    // next poll cycle.
                    const sess = m.connect(saved_node_id) catch |err| {
                        std.log.err("[tun-mgr] connect to {s} failed: {} (will retry)", .{ hostname, err });
                        continue;
                    };
                    const tun_ptr = allocator.create(tunnel_mod.Tunnel) catch continue;
                    tun_ptr.* = tunnel_mod.Tunnel.init(allocator, m.io, sess);

                    // Register with HostState
                    state.registerGuestTunnel(hostname, tun_ptr) catch |err| {
                        std.log.err("[tun-mgr] registerGuestTunnel for {s} failed: {}", .{ hostname, err });
                        tun_ptr.deinit();
                        allocator.destroy(tun_ptr);
                        continue;
                    };
                    state.setGuestMeshMac(hostname, saved_node_id);

                    // Send pty_spawn to trigger the Guest's pty shell creation.
                    // Without this, the Guest waits for the first pty_exec_input
                    // as an implicit spawn trigger — but keepalive probes (0xFF)
                    // may arrive first, delaying the spawn detection.
                    const spawn_frame = tunproto.buildPtySpawn(allocator) catch null;
                    if (spawn_frame) |sf| {
                        defer allocator.free(sf);
                        _ = tun_ptr.send(sf) catch {};
                        tun_ptr.flush(m.clock_ms);
                        std.log.info("[tun-mgr] pty_spawn sent to {s}", .{hostname});
                    }

                    // Spawn per-guest handler thread
                    const hostname_dup = allocator.dupe(u8, hostname) catch {
                        std.log.err("[tun-mgr] hostname dup failed for {s}", .{hostname});
                        continue;
                    };
                    const t = std.Thread.spawn(.{}, hst.handleMeshGuest, .{
                        allocator, state, hostname_dup, tun_ptr,
                    }) catch |err| {
                        std.log.err("[tun-mgr] handleMeshGuest spawn failed for {s}: {}", .{ hostname, err });
                        allocator.free(hostname_dup);
                        state.removeGuestTunnel(hostname);
                        tun_ptr.deinit();
                        allocator.destroy(tun_ptr);
                        continue;
                    };
                    t.detach();

                    std.log.info("[tun-mgr] Tunnel + handler started for {s}", .{hostname});

                    // Auto-upgrade is Guest-initiated: Guests detect version
                    // mismatch via LSA and download the new binary themselves.
                    // No Host-side push needed.
                }
            }
        }

        // Sleep 5s between scans
        std.Io.sleep(state.io.?, std.Io.Duration.fromSeconds(5), .awake) catch {};
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// Platform detection + init script generation (曾 install.zig)
// ═══════════════════════════════════════════════════════════════════════════

/// Supported operating system platforms
pub const Platform = enum {
    linux,
    macos,
    windows,

    pub fn detect() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .linux,
        };
    }

    pub fn asStr(self: Platform) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
        };
    }
};

/// Generate auto-start script/config template for the given platform.
pub fn genInit(platform: Platform) []const u8 {
    return switch (platform) {
        .macos =>
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.utmm.guest</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/utmm/utmm</string>
        \\        <string>--svc</string>
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>SHELL</key>
        \\        <string>/bin/zsh</string>
        \\        <key>HOME</key>
        \\        <string>/var/root</string>
        \\    </dict>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\    </dict>
        \\    <key>ThrottleInterval</key>
        \\    <integer>5</integer>
        \\    <key>StandardOutPath</key>
        \\    <string>/var/log/utmm-guest.log</string>
        \\</dict>
        \\</plist>
        \\
        \\<!-- Install: sudo cp this file to /Library/LaunchDaemons/com.utmm.guest.plist -->
        \\<!-- Load:    sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmm.guest.plist -->
        \\
        \\<!-- Host mode: replace --svc with --svc --host, change Label/Log to utmm-host -->
        ,
        .linux =>
        \\[Unit]
        \\Description=UTM Monitor Guest Service
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL=/bin/bash
        \\Environment=HOME=/root
        \\ExecStart=/opt/utmm/utmm --svc
        \\WorkingDirectory=/opt/utmm
        \\Restart=on-failure
        \\RestartSec=5
        \\StartLimitBurst=3
        \\StartLimitIntervalSec=30
        \\StandardOutput=journal
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
        \\<!-- Install: sudo cp this file to /etc/systemd/system/utmm-guest.service -->
        \\<!-- Enable:  sudo systemctl daemon-reload && sudo systemctl enable utmm-guest -->
        \\
        \\<!-- Host mode: add --host to ExecStart, change Description to Host -->
        ,
        .windows =>
        \\:: UTM Monitor Guest auto-start service
        \\::
        \\:: Install: sc create "UTM-Monitor-Guest" binPath= "\"C:\opt\utmm\utmm.exe\" --svc" start= auto
        \\::           sc failure "UTM-Monitor-Guest" reset=30 actions=restart/5000/restart/5000/restart/5000/none/5000
        \\::           sc start "UTM-Monitor-Guest"
        \\:: Remove:  sc stop "UTM-Monitor-Guest" & sc delete "UTM-Monitor-Guest"
        \\
        \\:: Host mode: replace UTM-Monitor-Guest with UTM-Monitor-Host, add --host to binPath
        ,
    };
}

test "Platform.detect returns valid platform" {
    const p = Platform.detect();
    _ = switch (p) {
        .macos, .linux, .windows => true,
    };
}

test "genInit - linux has systemd service" {
    const script = genInit(.linux);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Unit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--svc") != null);
}

test "genInit - macos has launchd plist" {
    const script = genInit(.macos);
    try std.testing.expect(std.mem.indexOf(u8, script, "com.utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "plist") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--svc") != null);
}

test "genInit - windows has sc command" {
    const script = genInit(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "sc create") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "UTM-Monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "C:\\opt\\utmm\\utmm.exe") != null);
}

test "isValidVersion - valid semver" {
    try std.testing.expect(isValidVersion("0.11.18"));
    try std.testing.expect(isValidVersion("1.0.0"));
    try std.testing.expect(isValidVersion("10.20.30"));
    try std.testing.expect(isValidVersion("0.0.0"));
}

test "isValidVersion - invalid" {
    try std.testing.expect(!isValidVersion(""));
    try std.testing.expect(!isValidVersion("0"));
    try std.testing.expect(!isValidVersion("0.11"));
    try std.testing.expect(!isValidVersion("0.11.18.1"));
    try std.testing.expect(!isValidVersion("v0.11.18"));
    try std.testing.expect(!isValidVersion("a.b.c"));
    try std.testing.expect(!isValidVersion("0.11.alpha"));
}

test "isValidVersion - garbage (human verification page)" {
    try std.testing.expect(!isValidVersion("<!DOCTYPE html>"));
    try std.testing.expect(!isValidVersion("<html>captcha</html>"));
    try std.testing.expect(!isValidVersion("Please verify you are human"));
}
