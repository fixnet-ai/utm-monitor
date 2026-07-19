//! Host mode orchestration — threaded I/O model.
//!
//! Two modes:
//!   1. Daemon (--host): UDP listener + /etc/hosts sync + auto-upgrade via std.Thread
//!   2. Management commands (--status/--exec/--upload/--download): stateless,
//!      discover guests via UDP broadcast, then talk directly to guest TCP port.
//!
//! No HTTP, no IPC — unified on port 2121 (UDP + TCP).

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const listener = @import("listener.zig");
const hosts_file = @import("hosts_file.zig");
const transport = @import("transport.zig");
const status_mod = @import("status.zig");
const broadcast = @import("broadcast.zig");

/// Shared guest entry type used across host daemon fibers
const GuestEntry = struct {
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    version: []const u8,
    shell: []const u8 = "unknown",
    /// Host version at last upgrade attempt — prevents re-triggering auto-upgrade
    /// every second when guest version hasn't changed but host was updated.
    last_upgrade_host_version: []const u8 = "0.0.0",
};

pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli);
}

pub fn runWithIo(block_io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs) !void {
    // --install / --uninstall: delegate to install module
    if (cli.cmd_install) {
        const install_mod = @import("install.zig");
        return install_mod.installSelf(block_io, gpa, cli.is_host, cli.hostname, cli.is_user);
    }
    if (cli.cmd_uninstall) {
        const install_mod = @import("install.zig");
        return install_mod.uninstallSelf(block_io, gpa, cli.is_user);
    }

    // --gen-init: generate init script
    if (cli.cmd_gen_init) {
        const install_mod = @import("install.zig");
        const platform_str = cli.gen_init_platform orelse "linux";
        const platform: install_mod.Platform = if (std.mem.eql(u8, platform_str, "macos"))
            .macos
        else if (std.mem.eql(u8, platform_str, "windows"))
            .windows
        else
            .linux;
        const script = install_mod.genInit(platform);
        std.debug.print("{s}", .{script});
        return;
    }

    // Management commands: stateless, no Host daemon needed
    if (cli.cmd_status) return cmdStatus(block_io, gpa, cli.port);
    if (cli.cmd_exec) return cmdExec(block_io, gpa, cli.port, cli.exec_target.?, cli.exec_cmd.?);
    if (cli.cmd_upload) return cmdUpload(block_io, gpa, cli.port, cli.upload_target.?, cli.upload_file.?);
    if (cli.cmd_download) return cmdDownload(block_io, gpa, cli.port, cli.download_target.?, cli.download_remote.?, cli.download_local.?);

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

    // Default serve_dir to exe directory if not specified (needed for auto-upgrade)
    const serve_dir = if (cli.serve_dir) |sd| sd else blk: {
        const exe_path = try std.process.executablePathAlloc(block_io, gpa);
        defer gpa.free(exe_path);
        const dir = std.fs.path.dirname(exe_path) orelse "/opt/utmm";
        break :blk try gpa.dupe(u8, dir);
    };
    defer if (cli.serve_dir == null) gpa.free(serve_dir);

    // --host --mcp: integrated mode (Host daemon + MCP in one process)
    if (cli.is_host and cli.is_mcp) {
        try runHostDaemon(block_io, gpa, cli.port, cli.hosts_file, serve_dir, true);
        return;
    }

    // --host: daemon mode
    if (cli.is_host) {
        try runHostDaemon(block_io, gpa, cli.port, cli.hosts_file, serve_dir, false);
        return;
    }

    // --mcp alone: adapter mode
    if (cli.is_mcp) {
        const mcp_mod = @import("mcp.zig");
        return mcp_mod.run(block_io, gpa);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management commands (stateless — discover via UDP, connect via TCP)
// ═══════════════════════════════════════════════════════════════════════════

fn cmdStatus(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    status_mod.queryStatus(block_io, gpa, port) catch |err| {
        if (err == error.AddressInUse) {
            // Host daemon is running; read its state file instead of re-binding
            if (readGuestStateFile(block_io, gpa)) |data| {
                defer gpa.free(data);
                std.debug.print("\n{s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s}\n", .{ "Hostname", "Target", "IP", "MAC", "Version", "Status" });
                std.debug.print("{s:-<85}\n", .{""});
                var lines = std.mem.splitScalar(u8, data, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    var fields = std.mem.splitScalar(u8, line, '\t');
                    const hostname = fields.next() orelse continue;
                    const target = fields.next() orelse continue;
                    const ip = fields.next() orelse continue;
                    const mac = fields.next() orelse continue;
                    const version = fields.next() orelse continue;
                    const ok = std.mem.eql(u8, version, protocol.VERSION);
                    std.debug.print("{s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s}\n", .{
                        hostname, target, ip, mac, version,
                        if (ok) "✓" else "⚠ upgradeable",
                    });
                }
                std.debug.print("\n", .{});
                return;
            } else |_| {}
        }
        return err;
    };
}

fn cmdExec(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, cmd: []const u8) !void {
    const ip = try discoverGuest(block_io, gpa, port, target) orelse {
        std.debug.print("[host] Guest '{s}' not found on network\n", .{target});
        return error.GuestNotFound;
    };
    defer gpa.free(ip);

    std.debug.print("[exec] Connecting to {s} ({s}:{d})\n", .{ target, ip, port });

    const addr = std.Io.net.IpAddress.parse(ip, port) catch |err| {
        std.debug.print("[exec] parseIp failed for {s}:{d}: {}\n", .{ ip, port, err });
        return err;
    };
    var stream = addr.connect(block_io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[exec] Failed to connect to {s}:{d}: {}\n", .{ ip, port, err });
        return err;
    };
    defer stream.close(block_io);

    var wbuf: [65536]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var writer = stream.writer(block_io, &wbuf);
    var reader = stream.reader(block_io, &rbuf);

    try transport.sendMessage(&writer, transport.MsgType.EXEC_REQ, cmd);
    writer.interface.flush() catch {};

    // Read response messages until EXEC_EXIT or error
    while (true) {
        const msg = transport.recvMessage(&reader, gpa) catch break;
        if (msg == null) break;
        defer gpa.free(msg.?.payload);

        switch (msg.?.msg_type) {
            transport.MsgType.EXEC_STDOUT => {
                std.debug.print("{s}", .{msg.?.payload});
            },
            transport.MsgType.EXEC_STDERR => {
                std.debug.print("{s}", .{msg.?.payload});
            },
            transport.MsgType.ERROR => {
                std.debug.print("[exec] Error: {s}\n", .{msg.?.payload});
                return error.RemoteError;
            },
            transport.MsgType.EXEC_EXIT => {
                if (msg.?.payload.len >= 4) {
                    const exit_code = std.mem.readInt(i32, msg.?.payload[0..4], .big);
                    if (exit_code != 0) std.process.exit(@intCast(exit_code));
                }
                return;
            },
            else => {},
        }
    }
}

fn cmdUpload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, local_file: []const u8) !void {
    const ip = try discoverGuest(block_io, gpa, port, target) orelse {
        std.debug.print("[host] Guest '{s}' not found on network\n", .{target});
        return error.GuestNotFound;
    };
    defer gpa.free(ip);

    // Read local file
    const file_data = std.Io.Dir.cwd().readFileAlloc(block_io, local_file, gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.debug.print("[upload] Cannot read {s}: {}\n", .{ local_file, err });
        return err;
    };
    defer gpa.free(file_data);

    const basename = std.fs.path.basename(local_file);

    // Build upload payload: filename\0<data>
    const payload = try gpa.alloc(u8, basename.len + 1 + file_data.len);
    defer gpa.free(payload);
    @memcpy(payload[0..basename.len], basename);
    payload[basename.len] = 0;
    @memcpy(payload[basename.len + 1 ..], file_data);

    const addr = std.Io.net.IpAddress.parse(ip, port) catch |err| {
        std.debug.print("[upload] parseIp failed: {}\n", .{err});
        return err;
    };
    var stream = addr.connect(block_io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[upload] Failed to connect: {}\n", .{err});
        return err;
    };
    defer stream.close(block_io);

    std.debug.print("[upload] Uploading → {s} ({s}:{d})...\n", .{ target, ip, port });

    var wbuf: [65536]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var writer = stream.writer(block_io, &wbuf);
    var reader = stream.reader(block_io, &rbuf);

    try transport.sendMessage(&writer, transport.MsgType.UPLOAD_REQ, payload);
    writer.interface.flush() catch {};

    const resp = (transport.recvMessage(&reader, gpa) catch null) orelse {
        std.debug.print("[upload] No response\n", .{});
        return error.NoResponse;
    };
    defer gpa.free(resp.payload);

    std.debug.print("{s}\n", .{resp.payload});
}

fn cmdDownload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, remote_file: []const u8, local_path: []const u8) !void {
    const ip = try discoverGuest(block_io, gpa, port, target) orelse {
        std.debug.print("[host] Guest '{s}' not found on network\n", .{target});
        return error.GuestNotFound;
    };
    defer gpa.free(ip);

    const addr = std.Io.net.IpAddress.parse(ip, port) catch |err| {
        std.debug.print("[download] parseIp failed: {}\n", .{err});
        return err;
    };
    var stream = addr.connect(block_io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[download] Failed to connect: {}\n", .{err});
        return err;
    };
    defer stream.close(block_io);

    std.debug.print("[download] Downloading {s} from {s} ({s}:{d}) → {s}...\n", .{ remote_file, target, ip, port, local_path });

    var wbuf: [65536]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var writer = stream.writer(block_io, &wbuf);
    var reader = stream.reader(block_io, &rbuf);

    try transport.sendMessage(&writer, transport.MsgType.FILE_REQ, remote_file);
    writer.interface.flush() catch {};

    // Receive FILE_RESP/EOF chunks and write to local file
    const file = try std.Io.Dir.cwd().createFile(block_io, local_path, .{});
    defer file.close(block_io);

    var total: usize = 0;

    while (true) {
        const msg = try transport.recvMessage(&reader, gpa) orelse return error.UnexpectedEOF;
        defer gpa.free(msg.payload);

        switch (msg.msg_type) {
            transport.MsgType.FILE_RESP => {
                var wb: [4096]u8 = undefined;
                var fw = file.writer(block_io, &wb);
                _ = try fw.interface.write(msg.payload);
                total += msg.payload.len;
            },
            transport.MsgType.EOF => {
                std.debug.print("[download] Received {d} bytes → {s}\n", .{ total, local_path });
                return;
            },
            transport.MsgType.ERROR => {
                std.debug.print("[download] Remote error: {s}\n", .{msg.payload});
                return error.RemoteError;
            },
            else => {
                std.debug.print("[download] Unexpected message type 0x{x}\n", .{msg.msg_type});
                return error.ProtocolError;
            },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Host daemon (--host): UDP listener + /etc/hosts sync + auto-upgrade
// ═══════════════════════════════════════════════════════════════════════════

fn runHostDaemon(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    hosts_path: []const u8,
    serve_dir: ?[]const u8,
    with_mcp: bool,
) !void {
    std.debug.print("[host] Starting daemon on port {d}\n", .{port});
    std.debug.print("[host] Hosts file: {s}\n", .{hosts_path});
    if (serve_dir) |sd| std.debug.print("[host] Serve dir: {s}\n", .{sd});

    // Shared guest list (accessible from UDP listener thread, no mutex needed
    // since only the listener thread writes; main thread only reads in MCP mode)
    var guests = std.StringHashMap(GuestEntry).init(gpa);
    defer {
        var it = guests.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value_ptr.hostname);
            gpa.free(entry.value_ptr.ip);
            gpa.free(entry.value_ptr.target);
            gpa.free(entry.value_ptr.mac);
            gpa.free(entry.value_ptr.version);
            gpa.free(entry.value_ptr.shell);
            gpa.free(entry.value_ptr.last_upgrade_host_version);
        }
        guests.deinit();
    }

    // Thread 1: UDP listener loop
    const listener_thread = try std.Thread.spawn(.{}, udpListenerThread, .{
        block_io, gpa, port, hosts_path, serve_dir, &guests,
    });

    // Main thread: wait (keep alive) or run MCP
    if (with_mcp) {
        // TODO: integrated MCP mode
        std.debug.print("[host] Integrated MCP mode not yet implemented\n", .{});
    }

    // Keep alive — sleep 60s at a time
    while (true) {
        std.Io.sleep(block_io, std.Io.Duration.fromSeconds(60), .awake) catch {};
    }

    // Unreachable, but join listener thread on clean shutdown path
    _ = listener_thread;
}

/// Thread: UDP listener — dispatches ANNOUNCE messages to hosts_file sync and auto-upgrade
fn udpListenerThread(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    hosts_path: []const u8,
    serve_dir: ?[]const u8,
    guests: *std.StringHashMap(GuestEntry),
) !void {
    const listen_addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
        std.debug.print("[host] Parse error: {}\n", .{err});
        return err;
    };
    var socket = listen_addr.bind(block_io, .{ .mode = .dgram }) catch |err| {
        std.debug.print("[host] UDP bind failed on {d}: {}\n", .{ port, err });
        return err;
    };
    defer socket.close(block_io);

    std.debug.print("[host] Listening on UDP {d}\n", .{port});

    var recv_buf: [2048]u8 = undefined;

    while (true) {
        processAnnounce(block_io, gpa, &socket, port, hosts_path, serve_dir, guests, &recv_buf) catch |err| {
            std.debug.print("[host] Error processing announce: {}\n", .{err});
            continue;
        };
    }
}

/// Process a single ANNOUNCE message (returns any error for the fiber to catch)
fn processAnnounce(
    io: std.Io,
    gpa: std.mem.Allocator,
    socket: anytype,
    port: u16,
    hosts_path: []const u8,
    serve_dir: ?[]const u8,
    guests: *std.StringHashMap(GuestEntry),
    recv_buf: *[2048]u8,
) !void {
    const msg_result = try socket.receive(io, recv_buf);
    const msg = msg_result.data;

    if (std.mem.indexOf(u8, msg, "ANNOUNCE") == null) return;

    const info = try protocol.GuestInfo.parse(gpa, msg);
    defer {
        gpa.free(info.hostname);
        gpa.free(info.ip);
        gpa.free(info.target);
        gpa.free(info.mac);
        gpa.free(info.version);
        if (info.shell.len > 0) gpa.free(info.shell);
    }

    // Extract source IP from UDP packet
    const src_ip = switch (msg_result.from) {
        .ip4 => |a| try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
        .ip6 => |a| try std.fmt.allocPrint(gpa, "{any}", .{a}),
    };
    defer gpa.free(src_ip);

    const use_src = std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.");
    const actual_ip = if (use_src) src_ip else info.ip;

    // Update or insert
    if (guests.getPtr(info.hostname)) |existing| {
        const ip_changed = !std.mem.eql(u8, existing.ip, actual_ip);
        const ver_changed = !std.mem.eql(u8, existing.version, info.version);

        var needs_sync = ip_changed;

        if (ver_changed) {
            gpa.free(existing.version);
            existing.version = try gpa.dupe(u8, info.version);
            needs_sync = true;
        }

        // Update shell if changed (guest may have been reinstalled with different shell)
        const shell = if (info.shell.len > 0) info.shell else shellFromTarget(info.target);
        if (!std.mem.eql(u8, existing.shell, shell)) {
            gpa.free(existing.shell);
            existing.shell = try gpa.dupe(u8, shell);
            needs_sync = true;
        }

        if (needs_sync) {
            try syncHostsFile(gpa, io, hosts_path, guests);
        }

        const host_version_mismatch = !std.mem.eql(u8, info.version, protocol.VERSION);
        const host_ver_upgraded = !std.mem.eql(u8, existing.last_upgrade_host_version, protocol.VERSION);

        // Trigger auto-upgrade when:
        // 1. Guest version changed AND mismatches host (guest older than host), OR
        // 2. Host version changed since last upgrade attempt (host newer than guest)
        if (host_version_mismatch and serve_dir != null and (ver_changed or host_ver_upgraded)) {
            try spawnAutoUpgrade(io, gpa, serve_dir.?, info.hostname, actual_ip, info.target, port);
            // Record that we attempted upgrade with current host version
            gpa.free(existing.last_upgrade_host_version);
            existing.last_upgrade_host_version = try gpa.dupe(u8, protocol.VERSION);
        }
    } else {
        std.debug.print("[host] 🆕 New guest: {s} ({s}) → {s}\n", .{ info.hostname, info.target, actual_ip });
        _ = try gpa.alloc(u8, 0); // dummy to bind allocator
        const shell = if (info.shell.len > 0) info.shell else shellFromTarget(info.target);
        const host_mismatch = !std.mem.eql(u8, info.version, protocol.VERSION);
        try guests.put(try gpa.dupe(u8, info.hostname), .{
            .hostname = try gpa.dupe(u8, info.hostname),
            .ip = try gpa.dupe(u8, actual_ip),
            .target = try gpa.dupe(u8, info.target),
            .mac = try gpa.dupe(u8, info.mac),
            .version = try gpa.dupe(u8, info.version),
            .shell = try gpa.dupe(u8, shell),
            .last_upgrade_host_version = if (host_mismatch and serve_dir != null) blk: {
                try spawnAutoUpgrade(io, gpa, serve_dir.?, info.hostname, actual_ip, info.target, port);
                break :blk try gpa.dupe(u8, protocol.VERSION);
            } else try gpa.dupe(u8, "0.0.0"),
        });
        try syncHostsFile(gpa, io, hosts_path, guests);
    }
}

const STATE_FILE = "/tmp/utmm-guests.tsv";

fn syncHostsFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    hosts_path: []const u8,
    guests: *std.StringHashMap(GuestEntry),
) !void {
    var entries: std.ArrayList(hosts_file.HostEntry) = .empty;
    defer entries.deinit(gpa);

    var it = guests.iterator();
    while (it.next()) |kv| {
        try entries.append(gpa, .{
            .ip = kv.value_ptr.ip,
            .name = kv.value_ptr.hostname,
        });
    }

    try hosts_file.updateHosts(io, gpa, hosts_path, entries.items);
    std.debug.print("[host] /etc/hosts synced ({d} guests)\n", .{guests.count()});

    // Write guest state file for --status fallback (avoids UDP port conflict)
    writeGuestStateFile(io, gpa, guests) catch {};
}

fn writeGuestStateFile(io: std.Io, gpa: std.mem.Allocator, guests: *std.StringHashMap(GuestEntry)) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    var it = guests.iterator();
    while (it.next()) |kv| {
        try buf.print(gpa, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            kv.value_ptr.hostname,
            kv.value_ptr.target,
            kv.value_ptr.ip,
            kv.value_ptr.mac,
            kv.value_ptr.version,
            kv.value_ptr.shell,
        });
    }

    const file = std.Io.Dir.cwd().createFile(io, STATE_FILE, .{ .permissions = @enumFromInt(0o644) }) catch return;
    defer file.close(io);
    var wb: [4096]u8 = undefined;
    var fw = file.writer(io, &wb);
    _ = fw.interface.write(buf.items) catch {};
}

fn readGuestStateFile(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, STATE_FILE, gpa, @enumFromInt(64 * 1024));
}

const AutoUpgradeArgs = struct {
    serve_dir: []const u8,
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    port: u16,
};

fn spawnAutoUpgrade(
    _: std.Io,
    gpa: std.mem.Allocator,
    serve_dir: []const u8,
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    port: u16,
) !void {
    // Clone data for background thread
    const args = try gpa.create(AutoUpgradeArgs);
    args.serve_dir = try gpa.dupe(u8, serve_dir);
    args.hostname = try gpa.dupe(u8, hostname);
    args.ip = try gpa.dupe(u8, ip);
    args.target = try gpa.dupe(u8, target);
    args.port = port;

    const thread = try std.Thread.spawn(.{}, doAutoUpgrade, .{gpa, args});
    thread.detach();
}

fn doAutoUpgrade(gpa: std.mem.Allocator, args: *AutoUpgradeArgs) !void {
    defer {
        gpa.free(args.serve_dir);
        gpa.free(args.hostname);
        gpa.free(args.ip);
        gpa.free(args.target);
        gpa.destroy(args);
    }

    // Use a dedicated Threaded instance with a real allocator.
    // global_single_threaded uses Allocator.failing, which causes OutOfMemory.
    var threaded = std.Io.Threaded.init(gpa, .{});
    const block_io = threaded.io();

    // Target is passed directly from the ANNOUNCE handler — no need to read
    // the state file (which also had a race condition with state file writes).
    const target = args.target;

    const bin_name = protocol.deploymentFilename(target) orelse {
        std.debug.print("[upgrade] Unknown target {s} for {s}, skipping\n", .{ target, args.hostname });
        return;
    };

    const serve_path = std.fs.path.join(gpa, &.{ args.serve_dir, bin_name }) catch |err| {
        std.debug.print("[upgrade] Path join error: {}\n", .{err});
        return;
    };
    defer gpa.free(serve_path);

    std.debug.print("[upgrade] Reading {s} for {s}\n", .{ serve_path, args.hostname });
    const bin_data = std.Io.Dir.cwd().readFileAlloc(block_io, serve_path, gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.debug.print("[upgrade] Cannot read {s}: {}\n", .{ serve_path, err });
        return;
    };
    defer gpa.free(bin_data);

    // Build upload payload: "utmm.next\0<binary data>"
    const upload_name: []const u8 = if (std.mem.indexOf(u8, target, "windows") != null) "utmm.next.exe" else "utmm.next";
    const upload_payload = try gpa.alloc(u8, upload_name.len + 1 + bin_data.len);
    defer gpa.free(upload_payload);
    @memcpy(upload_payload[0..upload_name.len], upload_name);
    upload_payload[upload_name.len] = 0;
    @memcpy(upload_payload[upload_name.len + 1 ..], bin_data);

    const addr = std.Io.net.IpAddress.parse(args.ip, args.port) catch |err| {
        std.debug.print("[upgrade] Parse error: {}\n", .{err});
        return;
    };
    var stream = addr.connect(block_io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[upgrade] Failed to connect to {s}:{d}: {}\n", .{ args.hostname, args.port, err });
        return;
    };
    defer stream.close(block_io);

    std.debug.print("[upgrade] Uploading v{any} to {s} ({s})\n", .{ @import("ver.zig").VERSION, args.hostname, args.ip });

    var wbuf: [65536]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var writer = stream.writer(block_io, &wbuf);
    var reader = stream.reader(block_io, &rbuf);

    // Upload the binary
    transport.sendMessage(&writer, transport.MsgType.UPLOAD_REQ, upload_payload) catch |err| {
        std.debug.print("[upgrade] Upload send error: {}\n", .{err});
        return;
    };
    writer.interface.flush() catch {};

    const resp = transport.recvMessage(&reader, gpa) catch |err| {
        std.debug.print("[upgrade] Upload response error: {}\n", .{err});
        return;
    } orelse {
        std.debug.print("[upgrade] No upload response\n", .{});
        return;
    };
    defer gpa.free(resp.payload);
    std.debug.print("[upgrade] Upload response: {s}\n", .{resp.payload});

    // Send exec command for safe rename + restart (platform-specific)
    const restart_cmd = restartCommand(gpa, target) catch {
        std.debug.print("[upgrade] Cannot build restart command\n", .{});
        return;
    };
    defer gpa.free(restart_cmd);

    transport.sendMessage(&writer, transport.MsgType.EXEC_REQ, restart_cmd) catch |err| {
        std.debug.print("[upgrade] Restart command error: {}\n", .{err});
        return;
    };
    writer.interface.flush() catch {};
    std.debug.print("[upgrade] Sent restart command to {s}\n", .{args.hostname});
}

/// Build the platform-specific restart command for auto-upgrade, based on guest target.
/// On Windows: write a batch file that does atomic rename after the current process exits,
/// then restart via the scheduled task. Running .exe files are locked on Windows,
/// so rename must happen outside the current process.
fn restartCommand(gpa: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, target, "windows") != null) {
        // Write upgrade batch file, then launch it detached before exiting.
        // The batch file: waits → renames .next.exe → .exe → restarts via schtasks
        return gpa.dupe(u8,
            \\(echo @echo off && echo ping -n 3 127.0.0.1 ^>nul && echo cd /d C:\opt\utmm && echo del /f utmm.old.exe 2^>nul && echo ren utmm.exe utmm.old.exe && echo ren utmm.next.exe utmm.exe && echo schtasks /run /tn utmm-guest && echo del "%%~f0" 2^>nul) > C:\opt\utmm\_upgrade.bat && start "" /b cmd /c C:\opt\utmm\_upgrade.bat && taskkill /f /im utmm.exe
        );
    }
    if (std.mem.indexOf(u8, target, "macos") != null) {
        return gpa.dupe(u8,
            \\mv /opt/utmm/utmm /opt/utmm/utmm.old 2>/dev/null;
            \\mv /opt/utmm/utmm.next /opt/utmm/utmm;
            \\chmod +x /opt/utmm/utmm;
            \\launchctl kickstart system/com.utmm.guest 2>/dev/null || pkill utmm 2>/dev/null
        );
    }
    // Default: Linux
    return gpa.dupe(u8,
        \\mv /opt/utmm/utmm /opt/utmm/utmm.old 2>/dev/null;
        \\mv /opt/utmm/utmm.next /opt/utmm/utmm;
        \\chmod +x /opt/utmm/utmm;
        \\systemctl restart utmm 2>/dev/null || service utmm restart 2>/dev/null
    );
}

/// Derive shell from target for backwards compatibility (old guests don't report shell).
fn shellFromTarget(target: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target, "windows") != null) return "cmd.exe";
    return "/bin/sh";
}

/// Look up a guest's target triple from the state file.
fn lookupGuestTargetInStateFile(io: std.Io, gpa: std.mem.Allocator, hostname: []const u8) ![]const u8 {
    const data = try readGuestStateFile(io, gpa);
    defer gpa.free(data);

    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitSequence(u8, line, "\t");
        const h = fields.next() orelse continue;
        const t = fields.next() orelse continue;
        if (std.mem.eql(u8, h, hostname)) {
            return gpa.dupe(u8, t);
        }
    }
    return error.GuestNotFound;
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest discovery via UDP (used by management commands)
// ═══════════════════════════════════════════════════════════════════════════

fn discoverGuest(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8) !?[]const u8 {
    // Try UDP discovery first
    const udp_result = discoverGuestViaUdp(block_io, gpa, port, target) catch null;
    if (udp_result) |ip| return ip;

    // Fallback: UDP port is in use (Host daemon running) → read state file
    const sf_result = lookupGuestInStateFile(block_io, gpa, target) catch null;
    if (sf_result) |ip| {
        std.debug.print("[discover] Found {s} via state file: {s}\n", .{ target, ip });
        return ip;
    }

    return null;
}

/// Discover guest by binding UDP port and listening for ANNOUNCE
fn discoverGuestViaUdp(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8) !?[]const u8 {
    // Bind to broadcast port and listen for ANNOUNCE messages
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var socket = listen_addr.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
        std.debug.print("[discover] UDP bind failed: {}\n", .{err});
        return error.BindFailed;
    };
    defer socket.close(block_io);

    // Also send a PING to provoke immediate response
    {
        const bc_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);
        const bind_ip = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
        var bc_socket = try bind_ip.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true });
        defer bc_socket.close(block_io);
        var ping_buf: [64]u8 = undefined;
        var ping_writer: std.Io.Writer = .fixed(&ping_buf);
        try protocol.buildPing(&ping_writer);
        bc_socket.send(block_io, &bc_addr, ping_writer.buffered()) catch {};
    }

    var recv_buf: [2048]u8 = undefined;
    const deadline_ns = std.Io.Timestamp.now(block_io, .real).nanoseconds + 3_000_000_000;
    var result: ?[]const u8 = null;

    while (std.Io.Timestamp.now(block_io, .real).nanoseconds < deadline_ns) {
        const msg_result = socket.receive(block_io, &recv_buf) catch break;
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") == null) continue;

        const info = protocol.GuestInfo.parse(gpa, msg) catch continue;
        defer {
            gpa.free(info.hostname);
            gpa.free(info.ip);
            gpa.free(info.target);
            gpa.free(info.mac);
            gpa.free(info.version);
            gpa.free(info.shell);
        }

        // Match by hostname or FQDN
        if (std.mem.eql(u8, info.hostname, target)) {
            const fqdn = try info.fqdn(gpa);
            defer gpa.free(fqdn);
            if (std.mem.eql(u8, fqdn, target) or std.mem.eql(u8, info.hostname, target)) {
                const src_ip = switch (msg_result.from) {
                    .ip4 => |a| try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
                    .ip6 => |a| try std.fmt.allocPrint(gpa, "{any}", .{a}),
                };
                const use_src = std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.");
                result = if (use_src) src_ip else try gpa.dupe(u8, info.ip);
                break;
            }
        }
    }

    return result;
}

/// Look up a guest's IP from the state file (written by Host daemon)
fn lookupGuestInStateFile(block_io: std.Io, gpa: std.mem.Allocator, target: []const u8) !?[]const u8 {
    const data = readGuestStateFile(block_io, gpa) catch return null;
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const hostname = fields.next() orelse continue;
        // Compare hostname (first field) against target
        if (std.mem.eql(u8, hostname, target)) {
            // Also match FQDN: hostname.local
            _ = fields.next(); // skip target arch
            const ip = fields.next() orelse continue;
            return try gpa.dupe(u8, ip);
        }
        // Match FQDN: target like "linuxvm.local" matches hostname "linuxvm"
        if (std.mem.startsWith(u8, target, hostname) and target.len > hostname.len and target[hostname.len] == '.') {
            _ = fields.next(); // skip target arch
            const ip = fields.next() orelse continue;
            return try gpa.dupe(u8, ip);
        }
    }
    return null;
}
