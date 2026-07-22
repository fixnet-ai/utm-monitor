//! Host mode — unified HTTP server on port 2121.
//!
//! Single std.http.Server replaces UDP broadcast + TCP binary frames + MCP :2122.
//! Management commands (--status/--exec/--upload/--download) are HTTP clients.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const protocol = @import("protocol.zig");
const http = std.http;
const httpd = @import("httpd.zig");
const host_http = @import("host_http.zig");
const broadcast = @import("broadcast.zig");

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
    if (cli.cmd_kick) return cmdKick(block_io, gpa, cli.port, cli.kick_target.?);

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

    // --host: start HTTP server (v0.3.0 unified architecture)
    if (cli.is_host) {
        try startHttpHost(block_io, gpa, cli.port, cli.hosts_file, serve_dir);
        return;
    }

    // --mcp alone: deprecated; MCP available via --host HTTP on port 2121
    if (cli.is_mcp) {
        std.log.info("[host] --mcp deprecated; use --host for MCP on port 2121", .{});
        return;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management commands (stateless — discover via UDP, connect via TCP)
// ═══════════════════════════════════════════════════════════════════════════

fn cmdStatus(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    _ = port; // UDP discovery uses fixed port 2121, not the HTTP port

    // Bind UDP socket to random port for sending broadcasts + receiving responses
    const bind_addr = std.Io.net.IpAddress.parse("0.0.0.0", 0) catch |err| {
        std.debug.print("[status] Bind address parse error: {}\n", .{err});
        return err;
    };
    var socket = bind_addr.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
        std.debug.print("[status] UDP bind failed: {}\n", .{err});
        return err;
    };
    defer socket.close(block_io);

    // Collect all broadcast addresses: 255.255.255.255 + subnet-directed broadcasts
    var broadcast_addrs = broadcast.getSubnetBroadcasts(gpa) catch {
        std.debug.print("[status] Failed to collect broadcast addresses\n", .{});
        return error.OutOfMemory;
    };
    defer broadcast_addrs.deinit(gpa);

    // HashMap for dedup: hostname → GuestInfo
    var guests = std.StringHashMap(protocol.GuestInfo).init(gpa);
    defer {
        var it = guests.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(gpa);
        }
        guests.deinit();
    }

    std.debug.print("[status] Scanning LAN for UTM guests (UDP broadcast)...\n", .{});

    // Send 5 rounds of broadcasts at 1-second intervals, collect responses continuously
    const start = std.Io.Timestamp.now(block_io, .real);
    const deadline = start.nanoseconds + 5_000_000_000;
    var send_count: u8 = 0;
    var send_errors: u8 = 0;

    while (true) {
        const now = std.Io.Timestamp.now(block_io, .real);
        if (now.nanoseconds >= deadline) break;

        // Send broadcasts at t ≈ 0, 1, 2, 3, 4
        if (send_count < 5) {
            const elapsed = now.nanoseconds - start.nanoseconds;
            const next_send_time = @as(i96, @intCast(send_count)) * 1_000_000_000;
            if (elapsed >= next_send_time) {
                // Send to all collected broadcast addresses
                var any_failed = false;
                for (broadcast_addrs.items) |*bc_addr| {
                    if (socket.send(block_io, bc_addr, protocol.DISCOVERY_QUERY)) |_| {
                    } else |_| { any_failed = true; }
                }
                if (any_failed) {
                    send_errors += 1;
                    if (send_errors == 1) {
                        // Network changed? Rebind and retry once.
                        std.debug.print("[status] Send error(s) — rebinding...\n", .{});
                        socket.close(block_io);
                        socket = bind_addr.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err2| {
                            std.debug.print("[status] Rebind failed: {}\n", .{err2});
                            return err2;
                        };
                        // Retry all addresses after rebind
                        for (broadcast_addrs.items) |*bc_addr| {
                            if (socket.send(block_io, bc_addr, protocol.DISCOVERY_QUERY)) |_| {
                                send_errors = 0;
                            } else |err3| {
                                std.debug.print("[status] Send failed after rebind: {}\n", .{err3});
                                return err3;
                            }
                        }
                    }
                } else {
                    send_errors = 0;
                }
                send_count += 1;
            }
        }

        // Try receive with 1-second timeout
        const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(1), .clock = .awake } };
        var buf: [4096]u8 = undefined;
        const msg = socket.receiveTimeout(block_io, &buf, timeout) catch |err| {
            switch (err) {
                error.Timeout => continue,
                else => {
                    std.debug.print("[status] Receive error: {}\n", .{err});
                    continue;
                },
            }
        };

        // Parse response using existing text protocol format
        var parsed = protocol.GuestInfo.parse(gpa, msg.data) catch continue;

        // Dedup by hostname (first response wins)
        const result = guests.getOrPut(parsed.hostname) catch {
            parsed.deinit(gpa);
            continue;
        };
        if (result.found_existing) {
            parsed.deinit(gpa); // discard duplicate
        } else {
            result.value_ptr.* = parsed;
        }
    }

    // Display table
    if (guests.count() == 0) {
        std.debug.print("No UTM guests found on LAN.\n\n", .{});
        return;
    }

    std.debug.print("\n{s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s}\n", .{ "Hostname", "Target", "IP", "MAC", "Version", "Shell" });
    std.debug.print("{s:-<85}\n", .{""});
    var it = guests.iterator();
    while (it.next()) |kv| {
        const info = kv.value_ptr;
        std.debug.print("{s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s}\n", .{ info.hostname, info.target, info.ip, info.mac, info.version, info.shell });
    }
    std.debug.print("\n", .{});
}

fn cmdExec(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, cmd: []const u8) !void {
    // HTTP client: POST /exec to Host
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/exec", .{port});
    defer gpa.free(url);

    const escaped_cmd = try httpd.jsonEscape(gpa, cmd);
    defer gpa.free(escaped_cmd);
    const body = try std.fmt.allocPrint(gpa, "{{\"vm\":\"{s}\",\"command\":\"{s}\"}}", .{ target, escaped_cmd });
    defer gpa.free(body);

    var resp_buf: [65536]u8 = undefined;
    var resp_writer: std.Io.Writer = .fixed(&resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &resp_writer,
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[exec] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };

    const resp_body = resp_writer.buffered();
    if (result.status != .ok) {
        std.debug.print("[exec] Error: {s}\n", .{resp_body});
        return error.ExecFailed;
    }

    // Parse result JSON
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp_body, .{ .allocate = .alloc_always }) catch {
        std.debug.print("{s}", .{resp_body});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("{s}", .{resp_body});
            return;
        },
    };

    if (obj.get("error")) |_| {
        std.debug.print("[exec] Error: {s}\n", .{resp_body});
        return error.ExecFailed;
    }

    const stdout_str = httpd.jsonGetString(obj, "stdout") orelse "";
    const stderr_str = httpd.jsonGetString(obj, "stderr") orelse "";
    const exit_code = httpd.jsonGetInt(obj, "exit") orelse 0;

    if (stdout_str.len > 0) std.debug.print("{s}", .{stdout_str});
    if (stderr_str.len > 0) std.debug.print("{s}", .{stderr_str});
    if (exit_code != 0) std.process.exit(if (exit_code < 0) @as(u8, 1) else @intCast(exit_code));
}

fn cmdKick(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/kick", .{port});
    defer gpa.free(url);

    const body = try std.fmt.allocPrint(gpa, "{{\"vm\":\"{s}\"}}", .{target});
    defer gpa.free(body);

    var resp_buf: [4096]u8 = undefined;
    var resp_writer: std.Io.Writer = .fixed(&resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &resp_writer,
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[kick] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };

    if (result.status == .ok) {
        std.debug.print("[kick] Kicked {s}\n", .{target});
    } else {
        std.debug.print("[kick] Error: {s}\n", .{resp_writer.buffered()});
        return error.KickFailed;
    }
}

fn cmdUpload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, local_file: []const u8) !void {
    // Read local file
    const file_data = std.Io.Dir.cwd().readFileAlloc(block_io, local_file, gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.debug.print("[upload] Cannot read {s}: {}\n", .{ local_file, err });
        return err;
    };
    defer gpa.free(file_data);

    const basename = std.fs.path.basename(local_file);
    const dest = try std.fmt.allocPrint(gpa, "/opt/utmm/{s}", .{basename});
    defer gpa.free(dest);

    std.debug.print("[upload] Uploading {s} → {s} ({s})...\n", .{ local_file, target, dest });

    // HTTP POST to Host
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/upload", .{port});
    defer gpa.free(url);

    const escaped_data = try httpd.jsonEscape(gpa, file_data);
    defer gpa.free(escaped_data);
    const body = try std.fmt.allocPrint(gpa,
        "{{\"vm\":\"{s}\",\"path\":\"{s}\",\"data\":\"{s}\"}}",
        .{ target, dest, escaped_data },
    );
    defer gpa.free(body);

    var resp_buf: [4096]u8 = undefined;
    var resp_writer: std.Io.Writer = .fixed(&resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &resp_writer,
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[upload] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };

    const resp_body = resp_writer.buffered();
    if (result.status == .ok) {
        std.debug.print("[upload] OK: {s}\n", .{resp_body});
    } else {
        std.debug.print("[upload] Error: {s}\n", .{resp_body});
        return error.UploadFailed;
    }
}

fn cmdDownload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, remote_file: []const u8, local_path: []const u8) !void {
    std.debug.print("[download] Downloading {s} from {s} → {s}...\n", .{ remote_file, target, local_path });

    // HTTP POST to Host
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/download", .{port});
    defer gpa.free(url);

    const body = try std.fmt.allocPrint(gpa, "{{\"vm\":\"{s}\",\"path\":\"{s}\"}}", .{ target, remote_file });
    defer gpa.free(body);

    var resp_buf: [65536]u8 = undefined;
    var resp_writer: std.Io.Writer = .fixed(&resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &resp_writer,
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[download] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };

    const resp_body = resp_writer.buffered();
    if (result.status != .ok) {
        std.debug.print("[download] Error: {s}\n", .{resp_body});
        return error.DownloadFailed;
    }

    // Parse result JSON for "data" field
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp_body, .{ .allocate = .alloc_always }) catch {
        std.debug.print("[download] Invalid JSON response\n", .{});
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("[download] Unexpected response\n", .{});
            return error.ProtocolError;
        },
    };

    if (obj.get("error")) |_| {
        std.debug.print("[download] Host error: {s}\n", .{resp_body});
        return error.DownloadFailed;
    }

    const data = httpd.jsonGetString(obj, "data") orelse "";
    const size = httpd.jsonGetInt(obj, "size") orelse 0;

    // Write to local file
    const local_file = try std.Io.Dir.cwd().createFile(block_io, local_path, .{});
    defer local_file.close(block_io);
    var wb: [65536]u8 = undefined;
    var fw = local_file.writer(block_io, &wb);
    _ = try fw.interface.write(data);
    try fw.interface.flush();

    std.debug.print("[download] Received {d} bytes → {s}\n", .{ size, local_path });
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP Host daemon (--host): unified HTTP server on :2121 (v0.3.0)
// ═══════════════════════════════════════════════════════════════════════════

fn startHttpHost(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    hosts_path: []const u8,
    serve_dir: ?[]const u8,
) !void {
    _ = hosts_path;

    const sd = serve_dir orelse "/opt/utmm";
    std.debug.print("[host] HTTP server on 0.0.0.0:{d}\n", .{port});
    std.debug.print("[host] Serve dir: {s}\n", .{sd});

    // Build router with all endpoints
    var router = httpd.Router{};
    // Order matters: longer prefixes first, "/" last (prefix match)
    try router.add(gpa, .GET, "/api/guests", host_http.handleApiGuests);
    try router.add(gpa, .POST, "/download", host_http.handleDownload);
    try router.add(gpa, .POST, "/upload", host_http.handleUpload);
    try router.add(gpa, .POST, "/kick", host_http.handleKick);
    try router.add(gpa, .POST, "/exec", host_http.handleExec);
    try router.add(gpa, .POST, "/announce", host_http.handleAnnounce);
    try router.add(gpa, .GET, "/ws", host_http.handleWebSocket);
    try router.add(gpa, .GET, "/bin/", host_http.handleBin);
    try router.add(gpa, .POST, "/mcp", host_http.handleMcp);
    try router.add(gpa, .GET, "/", host_http.handleRoot);

    // Initialize shared state (guest table + pending commands)
    var state = httpd.HostState.init(gpa);
    state.io = block_io;
    state.serve_dir = sd;
    // Set callback for /etc/hosts sync
    state.on_guest_changed = null; // TODO: wire up hosts sync
    defer state.deinit();

    // Block forever in HTTP accept loop
    try httpd.serve(block_io, gpa, &router, &state, port);
}
