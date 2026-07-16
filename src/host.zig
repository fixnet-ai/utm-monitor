//! Host mode orchestration
//! Management commands forwarded via IPC to persistent Host process, eliminating port conflicts
//! Persistent mode: UDP listener + HTTP server + IPC service, three threads in parallel

const std = @import("std");
const listener = @import("listener.zig");
const hosts_file = @import("hosts_file.zig");
const protocol = @import("protocol.zig");
const host_http = @import("host_http.zig");
const broadcast = @import("broadcast.zig");
const status_mod = @import("status.zig");
const executor = @import("executor.zig");
const deploy_mod = @import("deploy.zig");
const install_mod = @import("install.zig");
const config_mod = @import("config.zig");
const ipc = @import("ipc.zig");
const mcp = @import("mcp.zig");
const http_client = @import("http_client.zig");

/// Host mode entry point
pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    const io = init.io;
    const gpa = init.gpa;

    // ── Management commands: forward via IPC to running Host ────
    if (cli.cmd_status) {
        ipc.sendCommand(io, gpa, "STATUS") catch {
            // Host not running, fallback to direct UDP listen mode
            try status_mod.queryStatus(io, gpa, cli.port);
        };
        return;
    }
    if (cli.cmd_version) {
        return;
    }
    if (cli.cmd_deploy) {
        const cmd = if (cli.deploy_target) |t|
            try std.fmt.allocPrint(gpa, "DEPLOY\n{s}", .{t})
        else
            "DEPLOY";
        defer if (cli.deploy_target != null) gpa.free(cmd);

        ipc.sendCommand(io, gpa, cmd) catch {
            // Host not running, fallback to direct mode
            try deploy_mod.deployAll(io, gpa, cli.port, cli.deploy_target);
        };
        return;
    }
    if (cli.cmd_exec) {
        const target_name = cli.exec_target orelse {
            std.debug.print("Usage: utmm --host --exec <hostname> <command>\n", .{});
            return;
        };
        const exec_cmd = cli.exec_cmd orelse {
            std.debug.print("Usage: utmm --host --exec <hostname> <command>\n", .{});
            return;
        };

        const cmd = try std.fmt.allocPrint(gpa, "EXEC\n{s}\n{s}", .{ target_name, exec_cmd });
        defer gpa.free(cmd);

        ipc.sendCommand(io, gpa, cmd) catch {
            // Host not running, fallback to direct UDP PING + TCP exec
            std.debug.print("[exec] Querying target {s}...\n", .{target_name});
            const target_info = executor.resolveGuest(io, gpa, cli.port, target_name) catch |err| {
                std.debug.print("[exec] Guest {s} not found: {}\n", .{ target_name, err });
                return;
            };
            defer {
                gpa.free(target_info.hostname);
                gpa.free(target_info.ip);
                gpa.free(target_info.target);
                gpa.free(target_info.mac);
                gpa.free(target_info.version);
            }

            std.debug.print("[exec] Connecting to {s} ({s}:{d})\n", .{ target_info.hostname, target_info.ip, target_info.http_port });
            const result = executor.execRemote(io, gpa, target_info.ip, target_info.http_port, exec_cmd) catch |err| {
                std.debug.print("[exec] Execution failed: {}\n", .{err});
                return;
            };
            defer gpa.free(result);
            std.debug.print("{s}\n", .{result});
        };
        return;
    }
    if (cli.cmd_gen_init) {
        const platform_str = cli.gen_init_platform orelse "linux";
        const platform = if (std.mem.eql(u8, platform_str, "macos"))
            install_mod.Platform.macos
        else if (std.mem.eql(u8, platform_str, "windows"))
            install_mod.Platform.windows
        else
            install_mod.Platform.linux;

        std.debug.print("{s}", .{install_mod.genInit(platform)});
        return;
    }
    if (cli.cmd_install) {
        try install_mod.installSelf(io, gpa, cli.is_host);
        return;
    }
    if (cli.cmd_uninstall) {
        try install_mod.uninstallSelf(io, gpa);
        return;
    }
    if (cli.cmd_upload) {
        const local_file = cli.upload_file orelse {
            std.debug.print("Usage: utmm --host --upload <file> <vm>\n", .{});
            return;
        };
        const target_name = cli.upload_target orelse {
            std.debug.print("Usage: utmm --host --upload <file> <vm>\n", .{});
            return;
        };

        // Try IPC first (Host running), fallback to direct UDP resolve
        const cmd = try std.fmt.allocPrint(gpa, "UPLOAD\n{s}\n{s}\n{s}", .{ target_name, std.fs.path.basename(local_file), local_file });
        defer gpa.free(cmd);

        ipc.sendCommand(io, gpa, cmd) catch {
            std.debug.print("[upload] Resolving {s}...\n", .{target_name});
            const target_info = executor.resolveGuest(io, gpa, cli.port, target_name) catch |err| {
                std.debug.print("[upload] Guest {s} not found: {}\n", .{ target_name, err });
                return;
            };
            defer {
                gpa.free(target_info.hostname);
                gpa.free(target_info.ip);
                gpa.free(target_info.target);
                gpa.free(target_info.mac);
                gpa.free(target_info.version);
            }

            const remote_name = std.fs.path.basename(local_file);
            std.debug.print("[upload] Uploading {s} → {s} ({s}:{d})...\n", .{ local_file, target_info.hostname, target_info.ip, target_info.http_port });
            const bytes = http_client.uploadFile(io, gpa, target_info.ip, target_info.http_port, local_file, remote_name) catch |err| {
                std.debug.print("[upload] Upload failed: {}\n", .{err});
                return;
            };
            std.debug.print("[upload] OK — {d} bytes written to /opt/utmm/{s} on {s}\n", .{ bytes, remote_name, target_info.hostname });
        };
        return;
    }
    if (cli.cmd_download) {
        const target_name = cli.download_target orelse {
            std.debug.print("Usage: utmm --host --download <vm> <remote_file> [local_path]\n", .{});
            return;
        };
        const remote_file = cli.download_remote orelse {
            std.debug.print("Usage: utmm --host --download <vm> <remote_file> [local_path]\n", .{});
            return;
        };
        const local_path = cli.download_local orelse remote_file;

        // Try IPC first
        const cmd = try std.fmt.allocPrint(gpa, "DOWNLOAD\n{s}\n{s}\n{s}", .{ target_name, remote_file, local_path });
        defer gpa.free(cmd);

        ipc.sendCommand(io, gpa, cmd) catch {
            std.debug.print("[download] Resolving {s}...\n", .{target_name});
            const target_info = executor.resolveGuest(io, gpa, cli.port, target_name) catch |err| {
                std.debug.print("[download] Guest {s} not found: {}\n", .{ target_name, err });
                return;
            };
            defer {
                gpa.free(target_info.hostname);
                gpa.free(target_info.ip);
                gpa.free(target_info.target);
                gpa.free(target_info.mac);
                gpa.free(target_info.version);
            }

            std.debug.print("[download] Downloading {s} from {s} ({s}:{d}) → {s}...\n", .{ remote_file, target_info.hostname, target_info.ip, target_info.http_port, local_path });
            const bytes = http_client.downloadFile(io, gpa, target_info.ip, target_info.http_port, remote_file, local_path) catch |err| {
                std.debug.print("[download] Download failed: {}\n", .{err});
                return;
            };
            std.debug.print("[download] OK — {d} bytes saved to {s}\n", .{ bytes, local_path });
        };
        return;
    }
    if (cli.save_config) {
        const config_path = cli.config_path orelse "./utmm.conf";
        try config_mod.saveConfig(io, gpa, config_mod.Config{}, config_path);
        return;
    }

    // ── Persistent listen mode ─────────────────────────────────
    std.debug.print("[host] Listening for Guest broadcasts...\n", .{});

    // Shared state: Guest list + mutex (listener thread writes, IPC thread reads)
    var guests: std.ArrayList(listener.GuestState) = .empty;
    defer {
        for (guests.items) |g| {
            gpa.free(g.hostname);
            gpa.free(g.ip);
            gpa.free(g.target);
            gpa.free(g.mac);
            gpa.free(g.version);
        }
        guests.deinit(gpa);
    }

    var mutex: std.Io.Mutex = std.Io.Mutex.init;

    // ── Determine serve directory (needed by callback for auto-upgrade) ──
    const serve_dir: []const u8 = if (cli.serve_dir) |sd| sd else blk: {
        if (@import("builtin").os.tag == .windows) {
            break :blk gpa.dupe(u8, "C:\\opt\\utmm") catch ".";
        } else {
            break :blk gpa.dupe(u8, "/opt/utmm") catch ".";
        }
    };
    // NOTE: serve_dir is intentionally never freed — used by the detached HTTP thread and callback

    // Callback context
    const CbContext = struct {
        guests: *std.ArrayList(listener.GuestState),
        mutex: *std.Io.Mutex,
        io_val: std.Io,
        gpa_val: std.mem.Allocator,
        hosts_path: []const u8,
        serve_dir: []const u8,
        upgrading: std.StringHashMap(void),
    };
    var cb_ctx = CbContext{
        .guests = &guests,
        .mutex = &mutex,
        .io_val = io,
        .gpa_val = gpa,
        .hosts_path = cli.hosts_file,
        .serve_dir = serve_dir,
        .upgrading = std.StringHashMap(void).init(gpa),
    };
    defer cb_ctx.upgrading.deinit();

    const onIpChanged = listener.OnIpChanged{
        .context = &cb_ctx,
        .callFn = struct {
            fn cb(context: ?*anyopaque, old: ?listener.GuestState, new_state: listener.GuestState) void {
                _ = old;
                const ptr: *CbContext = @ptrCast(@alignCast(context.?));

                var version_mismatch = false;
                var guest_ip: []const u8 = undefined;
                var guest_http_port: u16 = undefined;
                var guest_target: []const u8 = undefined;
                var guest_hostname: []const u8 = undefined;

                {
                    ptr.mutex.lock(ptr.io_val) catch {};
                    defer ptr.mutex.unlock(ptr.io_val);

                    // Update or add GuestState entry
                    var found = false;
                    for (ptr.guests.items) |*g| {
                        if (std.mem.eql(u8, g.hostname, new_state.hostname)) {
                            if (!std.mem.eql(u8, g.ip, new_state.ip)) {
                                ptr.gpa_val.free(g.ip);
                                g.ip = ptr.gpa_val.dupe(u8, new_state.ip) catch return;
                                g.last_seen = new_state.last_seen;
                            }
                            // Update version in tracked state (so --status shows current)
                            if (!std.mem.eql(u8, g.version, new_state.version)) {
                                ptr.gpa_val.free(g.version);
                                g.version = ptr.gpa_val.dupe(u8, new_state.version) catch return;
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const copy = listener.GuestState{
                            .hostname = ptr.gpa_val.dupe(u8, new_state.hostname) catch return,
                            .ip = ptr.gpa_val.dupe(u8, new_state.ip) catch return,
                            .target = ptr.gpa_val.dupe(u8, new_state.target) catch return,
                            .mac = ptr.gpa_val.dupe(u8, new_state.mac) catch return,
                            .http_port = new_state.http_port,
                            .version = ptr.gpa_val.dupe(u8, new_state.version) catch return,
                            .last_seen = new_state.last_seen,
                        };
                        ptr.guests.append(ptr.gpa_val, copy) catch return;
                    }

                    // ── IP dedup ───────────────────────────────────────
                    // Each IP belongs to at most one guest at a time.
                    // If another guest (different hostname) shares this IP,
                    // evict it — its IP was taken over by a new guest.
                    {
                        var j: usize = 0;
                        while (j < ptr.guests.items.len) {
                            const g = ptr.guests.items[j];
                            if (!std.mem.eql(u8, g.hostname, new_state.hostname) and
                                std.mem.eql(u8, g.ip, new_state.ip))
                            {
                                ptr.gpa_val.free(g.hostname);
                                ptr.gpa_val.free(g.ip);
                                ptr.gpa_val.free(g.target);
                                ptr.gpa_val.free(g.mac);
                                ptr.gpa_val.free(g.version);
                                _ = ptr.guests.orderedRemove(j);
                                // Don't increment — orderedRemove shifted elements down
                            } else {
                                j += 1;
                            }
                        }
                    }

                    // Build HostEntry list → update /etc/hosts
                    var host_entries: std.ArrayList(hosts_file.HostEntry) = .empty;
                    defer {
                        for (host_entries.items) |e| {
                            ptr.gpa_val.free(e.name);
                        }
                        host_entries.deinit(ptr.gpa_val);
                    }

                    for (ptr.guests.items) |g| {
                        const fqdn = g.fqdn(ptr.gpa_val) catch continue;
                        host_entries.append(ptr.gpa_val, .{
                            .name = fqdn,
                            .ip = ptr.gpa_val.dupe(u8, g.ip) catch {
                                ptr.gpa_val.free(fqdn);
                                continue;
                            },
                        }) catch {
                            ptr.gpa_val.free(fqdn);
                            continue;
                        };
                    }

                    hosts_file.updateHosts(ptr.io_val, ptr.gpa_val, ptr.hosts_path, host_entries.items) catch |err| {
                        std.debug.print("[host] Failed to update hosts file: {}\n", .{err});
                    };

                    // Check version mismatch for auto-upgrade
                    version_mismatch = !std.mem.eql(u8, new_state.version, protocol.VERSION);
                    if (version_mismatch) {
                        guest_ip = ptr.gpa_val.dupe(u8, new_state.ip) catch return;
                        guest_http_port = new_state.http_port;
                        guest_target = ptr.gpa_val.dupe(u8, new_state.target) catch return;
                        guest_hostname = ptr.gpa_val.dupe(u8, new_state.hostname) catch return;
                    }
                }

                // Auto-upgrade: outside mutex lock (HTTP operations take seconds)
                if (version_mismatch) {
                    defer {
                        ptr.gpa_val.free(guest_ip);
                        ptr.gpa_val.free(guest_target);
                        ptr.gpa_val.free(guest_hostname);
                    }

                    // Debounce: skip if already upgrading this guest
                    if (ptr.upgrading.contains(guest_hostname)) return;
                    ptr.upgrading.put(guest_hostname, {}) catch return;
                    defer _ = ptr.upgrading.remove(guest_hostname);

                    std.debug.print("[host] ⚡ Version mismatch: {s} ({s} v{s}) → auto-upgrading to v{s}...\n", .{
                        guest_hostname, guest_target, new_state.version, protocol.VERSION,
                    });

                    autoUpgrade(
                        ptr.io_val,
                        ptr.gpa_val,
                        ptr.serve_dir,
                        guest_hostname,
                        guest_ip,
                        guest_http_port,
                        guest_target,
                    ) catch |err| {
                        std.debug.print("[host] Auto-upgrade {s} failed: {}\n", .{ guest_hostname, err });
                    };
                }
            }
        }.cb,
    };

    // Start Host-side HTTP server
    const host_ip: ?[]const u8 = blk: {
        const sys = broadcast.getSystemInfo(io, gpa) catch {
            std.debug.print("[host] Failed to get local IP, HTTP /update disabled\n", .{});
            break :blk null;
        };
        defer {
            gpa.free(sys.hostname);
            gpa.free(sys.mac);
            gpa.free(sys.iface_name);
        }
        if (std.mem.eql(u8, sys.ip, "0.0.0.0")) {
            gpa.free(sys.ip);
            break :blk null;
        }
        break :blk sys.ip;
    };
    defer if (host_ip) |ip| gpa.free(ip);

    // Write VERSION file to serve directory
    std.Io.Dir.cwd().createDir(io, serve_dir, @enumFromInt(0o755)) catch {};
    if (std.Io.Dir.cwd().createFile(io, b: {
        var p: [512]u8 = undefined;
        break :b try std.fmt.bufPrint(&p, "{s}/VERSION", .{serve_dir});
    }, .{ .permissions = @enumFromInt(0o644) })) |f| {
        var wb: [32]u8 = undefined;
        var fw = f.writer(io, &wb);
        fw.interface.print("utmm v{s}\n", .{protocol.VERSION}) catch {};
        fw.interface.flush() catch {};
        f.close(io);
    } else |_| {
        std.debug.print("[host] Cannot write {s}/VERSION\n", .{serve_dir});
    }

    // Start Host HTTP server (replaces old FTP server — Guests check version/update here)
    const http_thread = try std.Thread.spawn(.{}, host_http.startServer, .{
        io,
        gpa,
        host_http.Config{
            .port = cli.http_port,
            .serve_dir = serve_dir,
            .host_ip = host_ip,
        },
    });
    http_thread.detach();
    std.debug.print("[host] HTTP server started on port {d} (serving {s}/)\n", .{ cli.http_port, serve_dir });

    // Start IPC service thread (handles --status/--exec/--deploy forwarding)
    const IpcCtx = struct {
        guests: *std.ArrayList(listener.GuestState),
        mutex: *std.Io.Mutex,
        io: std.Io,
        allocator: std.mem.Allocator,
        port: u16,
    };
    var ipc_ctx = IpcCtx{
        .guests = &guests,
        .mutex = &mutex,
        .io = io,
        .allocator = gpa,
        .port = cli.port,
    };

    const ipc_thread = try std.Thread.spawn(.{}, ipc.startServer, .{
        io,
        gpa,
        &ipc_ctx,
        ipcHandler,
    });
    ipc_thread.detach();

    if (cli.is_mcp) {
        // Integrated mode: detach UDP listener to its own thread, MCP on main
        const listener_thread = try std.Thread.spawn(.{}, listener.listenLoop, .{ io, gpa, cli.port, onIpChanged });
        listener_thread.detach();
        std.debug.print("[host] MCP integrated mode — UDP listener in thread, MCP stdio on main\n", .{});
        try mcp.runDirect(io, gpa, &ipc_ctx, ipcHandler);
    } else {
        // Main thread: UDP listen loop
        try listener.listenLoop(io, gpa, cli.port, onIpChanged);
    }
}

/// IPC command handler (runs in IPC thread)
fn ipcHandler(ctx: *anyopaque, cmd: []const u8) anyerror![]const u8 {
    const IpcCtx = struct {
        guests: *std.ArrayList(listener.GuestState),
        mutex: *std.Io.Mutex,
        io: std.Io,
        allocator: std.mem.Allocator,
        port: u16,
    };
    const state: *IpcCtx = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, cmd, "STATUS")) {
        state.mutex.lock(state.io) catch {};
        defer state.mutex.unlock(state.io);

        // Copy GuestState slice from ArrayList for formatting function
        const snapshot = try state.allocator.dupe(listener.GuestState, state.guests.items);
        defer state.allocator.free(snapshot);

        return status_mod.formatStatusTable(state.allocator, snapshot);
    }

    if (std.mem.eql(u8, cmd, "STATUS_JSON")) {
        state.mutex.lock(state.io) catch {};
        defer state.mutex.unlock(state.io);

        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(state.allocator, "{\"guests\":[");
        var first = true;
        for (state.guests.items) |g| {
            if (!first) try buf.appendSlice(state.allocator, ",");
            first = false;
            const ok = std.mem.eql(u8, g.version, protocol.VERSION);
            try buf.print(state.allocator,
                \\{{"hostname":"{s}","ip":"{s}","target":"{s}","mac":"{s}","http_port":{d},"version":"{s}","online":true,"upgradable":{s}}}
            , .{
                g.hostname, g.ip, g.target, g.mac,
                g.http_port, g.version,
                if (ok) "false" else "true",
            });
        }
        try buf.appendSlice(state.allocator, "]}");
        return buf.toOwnedSlice(state.allocator);
    }

    if (std.mem.startsWith(u8, cmd, "EXEC\n")) {
        const rest = cmd["EXEC\n".len..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.InvalidCommand;
        const hostname = rest[0..nl];
        const exec_cmd = rest[nl + 1 ..];

        // Look up from shared Guest list
        state.mutex.lock(state.io) catch {};
        const guest = executor.findGuest(state.guests.items, hostname);
        state.mutex.unlock(state.io);

        if (guest == null) return error.GuestNotFound;

        const g = guest.?;
        std.debug.print("[ipc] EXEC {s} → {s}:{d}: {s}\n", .{ hostname, g.ip, g.http_port, exec_cmd });

        const result = try executor.execRemote(state.io, state.allocator, g.ip, g.http_port, exec_cmd);
        return std.fmt.allocPrint(state.allocator, "{s}\n", .{result});
    }

    if (std.mem.startsWith(u8, cmd, "DEPLOY")) {
        const specific: ?[]const u8 = if (cmd.len > "DEPLOY".len and cmd["DEPLOY".len] == '\n')
            blk: {
                const name = cmd["DEPLOY\n".len..];
                break :blk if (name.len > 0) name else null;
            }
        else
            null;

        // Build DeployTarget list from shared Guest list
        state.mutex.lock(state.io) catch {};
        var targets: std.ArrayList(deploy_mod.DeployTarget) = .empty;
        defer {
            for (targets.items) |t| {
                state.allocator.free(t.hostname);
                state.allocator.free(t.ip);
                state.allocator.free(t.ssh);
            }
            targets.deinit(state.allocator);
        }

        for (state.guests.items) |g| {
            if (specific != null and !std.mem.eql(u8, g.hostname, specific.?)) continue;
            // Build ssh field (backward compatibility, not used in new deployments)
            const ssh_user = if (std.mem.indexOf(u8, g.target, "windows") != null) "Administrator" else "root";
            const ssh = try std.fmt.allocPrint(state.allocator, "{s}@{s}", .{ ssh_user, g.hostname });
            try targets.append(state.allocator, .{
                .hostname = try state.allocator.dupe(u8, g.hostname),
                .target = g.target,
                .ip = try state.allocator.dupe(u8, g.ip),
                .http_port = g.http_port,
                .ssh = ssh,
            });
        }
        state.mutex.unlock(state.io);

        if (targets.items.len == 0) {
            return try state.allocator.dupe(u8, "No matching online Guest\n");
        }

        try deploy_mod.deployWithTargets(state.io, state.allocator, targets.items, specific);
        return try state.allocator.dupe(u8, "Deploy complete\n");
    }

    if (std.mem.startsWith(u8, cmd, "UPLOAD\n")) {
        const rest = cmd["UPLOAD\n".len..];
        const nl1 = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.InvalidCommand;
        const hostname = rest[0..nl1];
        const remainder = rest[nl1 + 1 ..];
        const nl2 = std.mem.indexOfScalar(u8, remainder, '\n') orelse return error.InvalidCommand;
        const remote_name = remainder[0..nl2];
        const local_file = remainder[nl2 + 1 ..];

        state.mutex.lock(state.io) catch {};
        const guest = executor.findGuest(state.guests.items, hostname);
        state.mutex.unlock(state.io);

        if (guest == null) return error.GuestNotFound;
        const g = guest.?;
        std.debug.print("[ipc] UPLOAD {s} → {s}:{d}/upload?filename={s}\n", .{ local_file, g.ip, g.http_port, remote_name });

        const bytes = try http_client.uploadFile(state.io, state.allocator, g.ip, g.http_port, local_file, remote_name);
        return std.fmt.allocPrint(state.allocator, "OK — {d} bytes written to /opt/utmm/{s} on {s}\n", .{ bytes, remote_name, hostname });
    }
    if (std.mem.startsWith(u8, cmd, "DOWNLOAD\n")) {
        const rest = cmd["DOWNLOAD\n".len..];
        const nl1 = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.InvalidCommand;
        const hostname = rest[0..nl1];
        const remainder = rest[nl1 + 1 ..];
        const nl2 = std.mem.indexOfScalar(u8, remainder, '\n') orelse return error.InvalidCommand;
        const remote_file = remainder[0..nl2];
        const local_path = remainder[nl2 + 1 ..];

        state.mutex.lock(state.io) catch {};
        const guest = executor.findGuest(state.guests.items, hostname);
        state.mutex.unlock(state.io);

        if (guest == null) return error.GuestNotFound;
        const g = guest.?;
        std.debug.print("[ipc] DOWNLOAD {s}:{d}/bin/{s} → {s}\n", .{ g.ip, g.http_port, remote_file, local_path });

        const bytes = try http_client.downloadFile(state.io, state.allocator, g.ip, g.http_port, remote_file, local_path);
        return std.fmt.allocPrint(state.allocator, "OK — {d} bytes saved to {s}\n", .{ bytes, local_path });
    }

    return error.UnknownCommand;
}

/// Auto-upgrade a Guest whose version doesn't match Host's version.
/// Host uploads the new binary as utmm.new; the Guest detects it in its
/// broadcast loop (checkSelfUpgrade) and self-upgrades. No restart command
/// needed — the Guest handles its own lifecycle.
fn autoUpgrade(
    io: std.Io,
    gpa: std.mem.Allocator,
    serve_dir: []const u8,
    hostname: []const u8,
    ip: []const u8,
    http_port: u16,
    target: []const u8,
) !void {
    // Map Guest target triple → deployment filename
    const bin_name = protocol.deploymentFilename(target) orelse {
        std.debug.print("[host] Auto-upgrade {s}: unknown target '{s}', skipping\n", .{ hostname, target });
        return;
    };
    const is_windows = std.mem.indexOf(u8, target, "windows") != null;

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ serve_dir, bin_name });
    defer gpa.free(bin_path);

    // Verify binary exists in serve directory
    if (std.Io.Dir.cwd().openFile(io, bin_path, .{})) |f| {
        f.close(io);
    } else |_| {
        std.debug.print("[host] Auto-upgrade {s}: binary not found at {s}, skipping\n", .{ hostname, bin_path });
        return;
    }

    // Upload new binary as utmm.new — Guest's broadcast loop will detect it
    // and self-upgrade via checkSelfUpgrade() within 1 second
    const new_name: []const u8 = if (is_windows) "utmm.new.exe" else "utmm.new";
    std.debug.print("[host] Auto-upgrade {s}: uploading {s} → {s}:{d}\n", .{ hostname, bin_path, ip, http_port });
    _ = try http_client.uploadFile(io, gpa, ip, http_port, bin_path, new_name);

    std.debug.print("[host] Auto-upgrade {s}: binary uploaded as {s} ✓ (Guest will self-upgrade)\n", .{ hostname, new_name });
}
