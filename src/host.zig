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
const mesh_mod = @import("mesh.zig");
const tunnel_mod = @import("tunnel.zig");

pub fn run(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return runWithIo(init.io, init.gpa, cli, null);
}

pub fn runWithIo(block_io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs, shutdown: ?*std.atomic.Value(bool)) !void {
    // Management commands: stateless, no Host daemon needed
    if (cli.cmd_status) return cmdStatus(block_io, gpa, cli.port);
    if (cli.cmd_exec) return cmdExec(block_io, gpa, cli.port, cli.exec_target.?, cli.exec_cmd.?);
    if (cli.cmd_upload) return cmdUpload(block_io, gpa, cli.port, cli.upload_target.?, cli.upload_file.?);
    if (cli.cmd_download) return cmdDownload(block_io, gpa, cli.port, cli.download_target.?, cli.download_remote.?, cli.download_local.?);
    // --gen-init
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

    // --host (via --svc): start HTTP server
    if (cli.is_host) {
        try startHttpHost(block_io, gpa, cli.port, cli.mesh_port, cli.hosts_file, serve_dir, cli.peer_mesh, shutdown);
        return;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Management commands (stateless — discover via UDP, connect via TCP)
// ═══════════════════════════════════════════════════════════════════════════

fn cmdStatus(block_io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    // Query the Host HTTP API for guest list (LSA-based discovery, v0.10.0+)
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/guests", .{port});
    defer gpa.free(url);

    var resp_buf: [8192]u8 = undefined;
    var resp_writer: std.Io.Writer = .fixed(&resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_writer,
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[status] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };

    if (result.status != .ok) {
        std.debug.print("[status] Error: HTTP {d}\n", .{@intFromEnum(result.status)});
        return error.StatusFailed;
    }

    // Parse JSON response: array of guest objects
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp_writer.buffered(), .{ .allocate = .alloc_always }) catch |err| {
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
        const g = guest_val.object;
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

fn cmdExec(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, cmd: []const u8) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/exec", .{port});
    defer gpa.free(url);

    const escaped_cmd = try httpd.jsonEscape(gpa, cmd);
    defer gpa.free(escaped_cmd);
    const body = try std.fmt.allocPrint(gpa, "{{\"vm\":\"{s}\",\"command\":\"{s}\"}}", .{ target, escaped_cmd });
    defer gpa.free(body);

    var redirect_buf: [4096]u8 = undefined;
    var transfer_buf: [4096]u8 = undefined;

    const uri = std.Uri.parse(url) catch |err| {
        std.debug.print("[exec] Bad URL: {s}\n", .{url});
        return err;
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[exec] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };
    defer req.deinit();

    req.sendBodyComplete(body) catch |err| {
        std.debug.print("[exec] sendBody failed: {}\n", .{err});
        return err;
    };

    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.debug.print("[exec] receiveHead failed: {}\n", .{err});
        return err;
    };

    if (response.head.status != .ok) {
        var err_body_buf: [4096]u8 = undefined;
        var err_reader = response.reader(&err_body_buf);
        const err_line = err_reader.takeDelimiter('\n') catch null orelse "unknown error";
        std.debug.print("[exec] Error ({d}): {s}\n", .{ @intFromEnum(response.head.status), err_line });
        return error.ExecFailed;
    }

    // Stream response body to stdout in real-time
    var body_reader = response.reader(&transfer_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(block_io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    // Pump chunks from HTTP body to stdout until EOF
    while (true) {
        const n = body_reader.stream(stdout, std.Io.Limit.limited(4096)) catch |err| {
            std.debug.print("[exec] read error: {}\n", .{err});
            break;
        };
        if (n == 0) break;
        stdout.flush() catch {};
    }
    stdout.flush() catch {};

    // Parse x-exit-code from trailers
    var exit_code: i32 = 0;
    var trailers = response.iterateTrailers();
    while (trailers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-exit-code")) {
            exit_code = std.fmt.parseInt(i32, h.value, 10) catch 0;
        }
    }

    if (exit_code != 0) {
        // Clamp to u8: negative or >255 → exit 1, otherwise @intCast
        const code: u8 = if (exit_code <= 0 or exit_code > 255) 1 else @intCast(exit_code);
        std.process.exit(code);
    }
}

fn cmdUpload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, local_file: []const u8) !void {
    // Read local file
    const file_data = std.Io.Dir.cwd().readFileAlloc(block_io, local_file, gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.debug.print("[upload] Cannot read {s}: {}\n", .{ local_file, err });
        return err;
    };
    defer gpa.free(file_data);

    // Compute SHA256 hash
    var sha256_hex: [64]u8 = undefined;
    var file_hash: []const u8 = "";
    {
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file_data, &sha256, .{});
        for (sha256, 0..) |b, j| {
            sha256_hex[j * 2] = "0123456789abcdef"[b >> 4];
            sha256_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
        }
        file_hash = &sha256_hex;
    }

    const basename = std.fs.path.basename(local_file);
    const dest = try std.fmt.allocPrint(gpa, "/opt/utmm/{s}", .{basename});
    defer gpa.free(dest);

    std.debug.print("[upload] Uploading {s} -> {s} ({s}) ({d} bytes, sha256={s})...\n", .{ local_file, target, dest, file_data.len, file_hash });

    // HTTP POST raw binary body with x-vm, x-path, x-file-hash headers
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/upload", .{port});
    defer gpa.free(url);

    var redirect_buf: [4096]u8 = undefined;

    const uri = std.Uri.parse(url) catch |err| {
        std.debug.print("[upload] Bad URL: {s}\n", .{url});
        return err;
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "x-vm", .value = target },
            .{ .name = "x-path", .value = dest },
            .{ .name = "x-file-hash", .value = file_hash },
            .{ .name = "Content-Type", .value = "application/octet-stream" },
        },
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[upload] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };
    defer req.deinit();

    req.sendBodyComplete(file_data) catch |err| {
        std.debug.print("[upload] sendBody failed: {}\n", .{err});
        return err;
    };

    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.debug.print("[upload] receiveHead failed: {}\n", .{err});
        return err;
    };

    if (response.head.status == .ok) {
        std.debug.print("[upload] OK\n", .{});
    } else {
        var err_body_buf: [4096]u8 = undefined;
        var err_reader = response.reader(&err_body_buf);
        const err_line = err_reader.takeDelimiter('\n') catch null orelse "unknown error";
        std.debug.print("[upload] Error ({d}): {s}\n", .{ @intFromEnum(response.head.status), err_line });
        return error.UploadFailed;
    }
}

fn cmdDownload(block_io: std.Io, gpa: std.mem.Allocator, port: u16, target: []const u8, remote_file: []const u8, local_path: []const u8) !void {
    std.debug.print("[download] Downloading {s} from {s} -> {s}...\n", .{ remote_file, target, local_path });

    // HTTP POST with x-vm and x-path headers, stream raw binary response to file
    var client: std.http.Client = .{ .allocator = gpa, .io = block_io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/download", .{port});
    defer gpa.free(url);

    var redirect_buf: [4096]u8 = undefined;
    var transfer_buf: [4096]u8 = undefined;

    const uri = std.Uri.parse(url) catch |err| {
        std.debug.print("[download] Bad URL: {s}\n", .{url});
        return err;
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "x-vm", .value = target },
            .{ .name = "x-path", .value = remote_file },
        },
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("[download] HTTP request failed: {} — is Host running?\n", .{err});
        return err;
    };
    defer req.deinit();

    // Send "{}" instead of empty body to avoid Zig 0.16.0 respondStreaming
    // panic on empty POST body + keep_alive=false (Server.discardBody unreachable).
    var empty_body = [2]u8{ '{', '}' };
    req.sendBodyComplete(&empty_body) catch |err| {
        std.debug.print("[download] sendBody failed: {}\n", .{err});
        return err;
    };

    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.debug.print("[download] receiveHead failed: {}\n", .{err});
        return err;
    };

    if (response.head.status != .ok) {
        var err_body_buf: [4096]u8 = undefined;
        var err_reader = response.reader(&err_body_buf);
        const err_line = err_reader.takeDelimiter('\n') catch null orelse "unknown error";
        std.debug.print("[download] Error ({d}): {s}\n", .{ @intFromEnum(response.head.status), err_line });
        return error.DownloadFailed;
    }

    // Stream response body to temp file first (atomic rename after hash verify)
    const temp_path = try std.fmt.allocPrint(gpa, "{s}.utmm-tmp", .{local_path});
    defer gpa.free(temp_path);
    std.Io.Dir.cwd().deleteFile(block_io, temp_path) catch {};

    const tmp_file = try std.Io.Dir.cwd().createFile(block_io, temp_path, .{});
    defer tmp_file.close(block_io);
    var file_wb: [65536]u8 = undefined;
    var fw = tmp_file.writer(block_io, &file_wb);
    const file_iface = &fw.interface;

    var body_reader = response.reader(&transfer_buf);
    var total_bytes: usize = 0;
    while (true) {
        const n = body_reader.stream(file_iface, std.Io.Limit.limited(65536)) catch |err| {
            std.debug.print("[download] read error: {}\n", .{err});
            break;
        };
        if (n == 0) break;
        total_bytes += n;
        file_iface.flush() catch {};
    }
    file_iface.flush() catch {};

    // Parse x-exit-code, x-file-hash, x-file-size from trailers
    var exit_code: i32 = 1;
    var file_hash: []const u8 = "";
    var file_size: u32 = 0;
    var trailers = response.iterateTrailers();
    while (trailers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-exit-code")) {
            exit_code = std.fmt.parseInt(i32, h.value, 10) catch 1;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "x-file-hash")) {
            file_hash = h.value;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "x-file-size")) {
            file_size = @intCast(std.fmt.parseInt(u64, h.value, 10) catch 0);
        }
    }

    if (exit_code != 0) {
        std.debug.print("[download] Guest returned error, exit code {d}\n", .{exit_code});
        std.Io.Dir.cwd().deleteFile(block_io, temp_path) catch {};
        return error.DownloadFailed;
    }

    // Verify hash if provided
    if (file_hash.len > 0 and total_bytes > 0) {
        const tmp_content = try std.Io.Dir.cwd().readFileAlloc(block_io, temp_path, gpa, @enumFromInt(50 * 1024 * 1024));
        defer gpa.free(tmp_content);
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(tmp_content, &sha256, .{});
        var actual_hex: [64]u8 = undefined;
        for (sha256, 0..) |b, j| {
            actual_hex[j * 2] = "0123456789abcdef"[b >> 4];
            actual_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
        }
        if (!std.mem.eql(u8, &actual_hex, file_hash)) {
            std.debug.print("[download] Hash mismatch! expected={s} actual={s}\n", .{ file_hash, &actual_hex });
            std.Io.Dir.cwd().deleteFile(block_io, temp_path) catch {};
            return error.HashMismatch;
        }
        std.debug.print("[download] Hash verified: {s}\n", .{file_hash});
    }

    // Atomic rename from temp to final path
    std.Io.Dir.cwd().deleteFile(block_io, local_path) catch {};
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), local_path, block_io);

    std.debug.print("[download] Received {d} bytes -> {s}\n", .{ total_bytes, local_path });
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP Host daemon (--host): unified HTTP server on :2121 (v0.3.0)
// ═══════════════════════════════════════════════════════════════════════════

fn startHttpHost(
    block_io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    mesh_port: u16,
    hosts_path: []const u8,
    serve_dir: ?[]const u8,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    _ = hosts_path;

    const sd = serve_dir orelse "/opt/utmm";
    std.debug.print("[host] HTTP server on 0.0.0.0:{d}\n", .{port});
    std.debug.print("[host] Serve dir: {s}\n", .{sd});
    if (port < 1024 and builtin.os.tag != .windows) {
        std.debug.print("[host] NOTE: port {d} < 1024 — run with sudo or 'setcap cap_net_bind_service=+ep' on Linux\n", .{port});
    }

    // Build router with all endpoints
    var router = httpd.Router{};
    // Order matters: longer prefixes first, "/" last (prefix match)
    try router.add(gpa, .GET, "/api/guests", host_http.handleApiGuests);
    try router.add(gpa, .POST, "/download", host_http.handleDownload);
    try router.add(gpa, .POST, "/upload", host_http.handleUpload);
    try router.add(gpa, .POST, "/exec", host_http.handleExec);
    // Guest discovery now via mesh LSA — /announce and /ws removed
    try router.add(gpa, .GET, "/bin/", host_http.handleBin);
    try router.add(gpa, .GET, "/version", host_http.handleVersion);
    try router.add(gpa, .POST, "/mcp", host_http.handleMcp);
    try router.add(gpa, .GET, "/", host_http.handleRoot);

    // Initialize shared state (guest table + pending commands)
    var state = httpd.HostState.init(gpa);
    state.io = block_io;
    state.serve_dir = sd;
    // Set callback for /etc/hosts sync
    state.on_guest_changed = null; // TODO: wire up hosts sync
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

        // Build node_info for LSA
        const node_info = std.fmt.allocPrint(gpa,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:host\nstatus:serving",
            .{ host_info.hostname, host_info.ip, host_info.target, protocol.VERSION, host_info.shell },
        ) catch |err| {
            std.log.err("[host] Mesh node_info alloc: {}", .{err});
            mesh_socket.close(mesh_io);
            bc_addrs.deinit(gpa);
            break :start_mesh;
        };

        // Create mesh instance
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
    }

    defer {
        if (mesh_thread) |t| {
            if (mesh_opt) |*m| m.signalShutdown();
            t.join();
        }
        if (mesh_opt) |*m| {
            const m_io = m.io;
            m.deinit();
            state.mesh = null;
            _ = m_io;
        }
    }

    // Spawn tunnel manager thread — syncs LSA→guest table, connects tunnels
    var tun_mgr_thread = try std.Thread.spawn(.{}, tunnelManager, .{ gpa, &state, &mesh_opt });
    tun_mgr_thread.detach();

    // Block forever in HTTP accept loop
    try httpd.serve(block_io, gpa, &router, &state, port, shutdown);
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
            // NOTE: iterating m.lsas from a non-mesh thread has a race
            // with mesh.run() replacing LSA entries (e.g. upgrade restart).
            // Duplicate node_info + node_id to avoid use-after-free.
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
                    host_http.syncHostsFromState(state, allocator);
                }

                // Phase 2: Establish tunnel if not already active.
                // Uses state.getGuestTunnel() as the sole source of truth —
                // when handleMeshGuest disconnects, its defer calls
                // removeGuestTunnel, and the next scan reconnects.
                //
                // When status changes to "upgrading" (utmm-old takes over),
                // force-replace the old tunnel immediately instead of waiting
                // for KCP keepalive timeout on the dead Guest connection.
                //
                // For upgrading guests: prefer a Guest-initiated session (created
                // via the Guest's m.connect()) over creating a new Host-initiated
                // session. This avoids the dual-session mismatch that causes
                // tunnel death during file transfer.
                const upgrading = std.mem.eql(u8, status, "upgrading");
                const existing_tun = state.getGuestTunnel(hostname);
                const status_just_changed = changed and upgrading;
                const tun_dead = existing_tun != null and !existing_tun.?.isAlive();

                // Check if a Guest-initiated session (different conv) is now
                // available — happens when the Host restarts, creates a fallback
                // session via m.connect(), then the Guest reconnects with its
                // own session. We must switch to the Guest's session or data
                // flows through mismatched conv IDs and exec hangs.
                const guest_session_available = if (existing_tun != null and !tun_dead) blk: {
                    const tun_conv = existing_tun.?.session.conv;
                    var found: bool = false;
                    m.sessions_mutex.lock(m.io) catch break :blk false;
                    defer m.sessions_mutex.unlock(m.io);
                    var s_it = m.sessions.iterator();
                    while (s_it.next()) |s_entry| {
                        if (std.mem.eql(u8, &s_entry.value_ptr.*.remote, &saved_node_id)) {
                            if (s_entry.key_ptr.* != tun_conv) {
                                found = true;
                                break;
                            }
                        }
                    }
                    break :blk found;
                } else false;

                if (existing_tun == null or tun_dead or status_just_changed or guest_session_available) {
                    if (existing_tun != null) {
                        std.log.info("[tun-mgr] {s} tunnel replace (dead={}, upgrading={}, guestSession={})", .{ hostname, tun_dead, status_just_changed, guest_session_available });
                        state.removeGuestTunnel(hostname);
                    }

                    // Always prefer a Guest-initiated session to avoid the
                    // dual-session mismatch that causes exec hangs.
                    //
                    // Host and Guest each call m.connect() with their own
                    // nonce+connect_counter, producing different conv IDs.
                    // If handleMeshGuest uses the Host-created session but
                    // the Guest sends data on its own session, output never
                    // reaches the Host — the two sessions operate independently.
                    //
                    // Solution: search sessions table for one whose `remote`
                    // matches this Guest. This is the session created by
                    // handleKcpData when the Guest's first KCP packet arrived.
                    //
                    // For upgrading guests: only accept sessions with pending
                    // data (upgrade_req). Stale sessions from the previous
                    // Guest instance have no data and are skipped.
                    var sess: ?*mesh_mod.MeshSession = null;
                    {
                        m.sessions_mutex.lock(m.io) catch continue;
                        defer m.sessions_mutex.unlock(m.io);

                        var s_it = m.sessions.iterator();
                        while (s_it.next()) |s_entry| {
                            if (std.mem.eql(u8, &s_entry.value_ptr.*.remote, &saved_node_id)) {
                                if (upgrading and s_entry.value_ptr.*.kcp_inst.peekSize() < 0) {
                                    std.log.info("[tun-mgr] {s} skipping stale session conv={d} (no data)", .{ hostname, s_entry.key_ptr.* });
                                    continue;
                                }
                                sess = s_entry.value_ptr.*;
                                std.log.info("[tun-mgr] {s} using guest-initiated session conv={d}", .{ hostname, s_entry.key_ptr.* });
                                break;
                            }
                        }
                    }

                    if (sess == null) {
                        if (upgrading) {
                            // Upgrading Guest hasn't sent upgrade_req yet — wait
                            continue;
                        }
                        // No Guest-initiated session yet — create Host-initiated
                        // session as fallback. The Guest may still connect later;
                        // when it does, the next tunnelManager scan will replace
                        // this session with the Guest-initiated one.
                        sess = m.connect(saved_node_id) catch |err| {
                            std.log.err("[tun-mgr] connect to {s} failed: {} (will retry)", .{ hostname, err });
                            continue;
                        };
                    }
                    const tun_ptr = allocator.create(tunnel_mod.Tunnel) catch continue;
                    tun_ptr.* = tunnel_mod.Tunnel.init(allocator, m.io, sess.?);

                    // Register with HostState
                    state.registerGuestTunnel(hostname, tun_ptr) catch |err| {
                        std.log.err("[tun-mgr] registerGuestTunnel for {s} failed: {}", .{ hostname, err });
                        tun_ptr.deinit();
                        allocator.destroy(tun_ptr);
                        continue;
                    };

                    // Spawn per-guest handler thread
                    const hostname_dup = allocator.dupe(u8, hostname) catch {
                        std.log.err("[tun-mgr] hostname dup failed for {s}", .{hostname});
                        continue;
                    };
                    const t = std.Thread.spawn(.{}, host_http.handleMeshGuest, .{
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
                }
            }
        }

        // Sleep 5s between scans
        std.Io.sleep(state.io.?, std.Io.Duration.fromSeconds(5), .awake) catch {};
    }
}
