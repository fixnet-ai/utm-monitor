//! Host mode — unified HTTP server on port 2121.
//!
//! Single std.http.Server replaces UDP broadcast + TCP binary frames on port 2121.
//! Management commands (--status/--exec/--upload/--download) are HTTP clients.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const protocol = @import("protocol.zig");
const http = std.http;
const httpd = @import("httpd.zig");
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

    std.debug.print("\n{s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s}\n", .{ "Hostname", "Target", "IP", "MAC", "Version", "Shell" });
    std.debug.print("{s:-<85}\n", .{""});
    for (guests.items) |guest_val| {
        const g = switch (guest_val) {
            .object => |o| o,
            else => continue,
        };
        const hostname = httpd.jsonGetString(g, "hostname") orelse "?";
        const target = httpd.jsonGetString(g, "target") orelse "?";
        const ip = httpd.jsonGetString(g, "ip") orelse "?";
        const mac = httpd.jsonGetString(g, "mac") orelse "?";
        const version = httpd.jsonGetString(g, "version") orelse "?";
        const shell = httpd.jsonGetString(g, "shell") orelse "?";
        std.debug.print("{s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s}\n", .{ hostname, target, ip, mac, version, shell });
    }
    std.debug.print("\n", .{});
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

    // Initialize shared state (guest table + pending commands)
    var state = httpd.HostState.init(gpa);
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
        mesh_opt = mesh_mod.Mesh.init(gpa, node_id, node_info, mesh_socket, mesh_io, &upgrade_signal.needed, bc_addrs, "") catch |err| {
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
        svc.resetRetryCounter(block_io, gpa, .host);
    }

    // Spawn tunnel manager thread — syncs LSA→guest table, connects tunnels.
    // Must spawn before the defer below so join() runs in correct order.
    var tun_mgr_thread = try std.Thread.spawn(.{}, tunnelManager, .{ gpa, &state, &mesh_opt });

    // Spawn IPC server thread — Unix domain socket (POSIX) / named pipe (Windows).
    // Shares HostState and Mesh with the HTTP server.
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
    state: *httpd.HostState,
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

                // Only process Guest nodes (skip other Host instances)
                if (std.mem.eql(u8, role, "host")) continue;

                if (hostname.len == 0 or ip.len == 0) continue;

                // Convert mesh NodeId to MAC string
                mac_str = std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                    saved_node_id[0], saved_node_id[1], saved_node_id[2],
                    saved_node_id[3], saved_node_id[4], saved_node_id[5],
                }) catch continue;
                defer allocator.free(mac_str);

                // Upsert to guest table
                const changed = state.upsertGuest(hostname, ip, target, mac_str, version, shell, status);
                if (changed and hostname.len > 0) {
                    httpd.syncHostsFromState(state, allocator);
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
                    const t = std.Thread.spawn(.{}, httpd.handleMeshGuest, .{
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
