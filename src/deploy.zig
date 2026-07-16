//! --deploy build+deploy + --watch file monitor auto-deploy (Host side)
//! Scan online Guests for target triplets, auto cross-compile and deploy
//! Uses built-in HTTP command channel + transfer, no external SSH/SCP needed

const std = @import("std");
const protocol = @import("protocol.zig");
const executor = @import("executor.zig");
const http_client = @import("http_client.zig");

/// Deployment target (discovered from ANNOUNCE)
pub const DeployTarget = struct {
    hostname: []const u8,
    target: []const u8, // Zig target triplet: aarch64-linux, ...
    ip: []const u8,
    http_port: u16, // HTTP server port (from ANNOUNCE)
    ssh: []const u8, // Kept for backward compatibility, no longer used for deployment
};

fn setReuseAddr(socket: std.Io.net.Socket) !void {
    if (@import("builtin").os.tag == .windows) return;
    const sol_socket = std.posix.SOL.SOCKET;
    const so_reuseaddr = std.posix.SO.REUSEADDR;
    const one = [_]u8{1, 0, 0, 0};
    try std.posix.setsockopt(socket.handle, sol_socket, so_reuseaddr, &one);
}

/// Scan online Guests for deployment targets
pub fn scanGuests(io: std.Io, allocator: std.mem.Allocator, port: u16) ![]DeployTarget {
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const socket = try listen_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer socket.close(io);
    setReuseAddr(socket) catch {};

    var targets: std.ArrayList(DeployTarget) = .empty;

    var recv_buf: [2048]u8 = undefined;
    const deadline = std.Io.Timestamp.now(io, .real).addDuration(std.Io.Duration.fromSeconds(3));

    while (std.Io.Timestamp.now(io, .real).nanoseconds < deadline.nanoseconds) {
        const msg_result = socket.receive(io, &recv_buf) catch break;
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") != null) {
            const info = protocol.GuestInfo.parse(allocator, msg) catch continue;

            // Extract real IP
            const real_ip = if (std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127."))
                switch (msg_result.from) {
                    .ip4 => |a| try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
                    .ip6 => |a| try std.fmt.allocPrint(allocator, "{any}", .{a}),
                }
            else
                info.ip;

            // Deduplicate by hostname
            var found = false;
            for (targets.items) |t| {
                if (std.mem.eql(u8, t.hostname, info.hostname)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                // Derive SSH address (backward compatibility, not used in new deployment flow)
                const ssh_user = if (std.mem.eql(u8, info.target[info.target.len - 7 ..], "windows")) "Administrator" else "root";
                const ssh_addr = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ ssh_user, info.hostname });

                try targets.append(allocator, .{
                    .hostname = info.hostname,
                    .target = info.target,
                    .ip = real_ip,
                    .http_port = info.http_port,
                    .ssh = ssh_addr,
                });
            } else {
                allocator.free(info.hostname);
                allocator.free(info.target);
                allocator.free(info.mac);
                allocator.free(info.version);
            }
        }
    }

    return targets.toOwnedSlice(allocator);
}

/// Build for target, return binary path (temp copy to avoid overwrite by subsequent builds)
pub fn buildBinary(io: std.Io, allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    const zig_cmd = if (target.len == 0)
        "zig build -Doptimize=ReleaseSafe"
    else
        try std.fmt.allocPrint(allocator, "zig build -Dtarget={s} -Doptimize=ReleaseSafe", .{target});

    std.debug.print("[deploy] Building: {s}\n", .{zig_cmd});
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", zig_cmd },
    });
    defer allocator.free(result.stdout);

    // Find the built binary in zig-out/bin/
    // After build.zig changes, the target-specific binary uses deployment filenames
    // (e.g. utmm-x86_64-linux, utmm-aarch64-macos, utmm-x86-windows.exe)
    const is_windows_target = std.mem.indexOf(u8, target, "windows") != null;
    const dst_ext: []const u8 = if (is_windows_target) ".exe" else "";
    const src_name = if (protocol.deploymentFilename(target)) |name|
        name
    else blk: {
        // Unknown target: fall back to old convention utmm-{target}
        break :blk try std.fmt.allocPrint(allocator, "utmm-{s}", .{target});
    };
    defer if (protocol.deploymentFilename(target) == null) allocator.free(src_name);

    const src_path = try std.fmt.allocPrint(allocator, "zig-out/bin/{s}", .{src_name});
    // Copy to temp path to avoid overwrite by subsequent builds
    const tmp_path = try std.fmt.allocPrint(allocator, "zig-out/bin/utmm-{s}{s}", .{ target, dst_ext });
    var cp_cmd: std.ArrayList(u8) = .empty;
    defer cp_cmd.deinit(allocator);
    try cp_cmd.print(allocator, "cp {s} {s}", .{ src_path, tmp_path });
    _ = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", cp_cmd.items },
    }) catch {
        // Fallback to original source path on cp failure
        allocator.free(tmp_path);
        return allocator.dupe(u8, src_path);
    };

    return tmp_path;
}

/// Build restart command (background execution, detached from process tree to avoid self-kill interruption)
/// hostname: Guest hostname, passed to new process via --hostname so it keeps the correct identity
fn buildRestartCommand(allocator: std.mem.Allocator, is_windows: bool, remote_path: []const u8, new_name: []const u8, final_name: []const u8, hostname: []const u8) ![]const u8 {
    if (is_windows) {
        // Windows: sleep → move → kill old → start new with --hostname
        return try std.fmt.allocPrint(allocator,
            \\cmd /c "ping -n 2 127.0.0.1 >nul & move /Y {s}\{s} {s}\{s} >nul 2>&1 & taskkill /f /im utmm.exe >nul 2>&1 & ping -n 2 127.0.0.1 >nul & start "" {s}\{s} --hostname {s}"
        , .{ remote_path, new_name, remote_path, final_name, remote_path, final_name, hostname });
    } else {
        // Linux/macOS: sleep → mv (replace running binary) → kill old → restart with --hostname
        // Order matters: move the .new into place first, THEN kill the old process.
        // The service manager (systemd/launchd) will restart the new binary automatically.
        // The --hostname flag ensures the new process keeps the correct identity.
        return try std.fmt.allocPrint(allocator,
            \\nohup sh -c 'sleep 1; mv {s}/{s} {s}/{s}; chmod +x {s}/{s}; pkill utmm; sleep 1; {s}/{s} --hostname {s} &' >/dev/null 2>&1 &
        , .{ remote_path, new_name, remote_path, final_name, remote_path, final_name, remote_path, final_name, hostname });
    }
}

/// Deploy binary to single target (uses built-in HTTP command channel + upload, no SSH needed)
pub fn deployToTarget(io: std.Io, allocator: std.mem.Allocator, target: DeployTarget, binary: []const u8) !void {
    const is_windows = std.mem.indexOf(u8, target.target, "windows") != null;
    const remote_path = if (is_windows) "C:\\opt\\utmm" else "/opt/utmm";
    const final_name = if (is_windows) "utmm.exe" else "utmm";
    const new_name = if (is_windows) "utmm.new.exe" else "utmm.new";

    std.debug.print("[deploy] Deploying to {s} ({s}, target={s}): {s} → {s}/{s}\n",
        .{ target.hostname, target.ip, target.target, binary, remote_path, final_name });

    // Step 1: Ensure remote directory exists (via TCP command channel)
    const mkdir_cmd = if (is_windows)
        try std.fmt.allocPrint(allocator, "if not exist \"{s}\" mkdir \"{s}\"", .{ remote_path, remote_path })
    else
        try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{remote_path});
    defer allocator.free(mkdir_cmd);

    _ = executor.execRemote(io, allocator, target.ip, target.http_port, mkdir_cmd) catch |err| {
        std.debug.print("[deploy] {s}: mkdir warning ({}) — continuing\n", .{ target.hostname, err });
    };

    // Step 2: HTTP upload (upload as .new temp file first)
    std.debug.print("[deploy] HTTP upload: {s} → {s}\n", .{ binary, new_name });
    _ = try http_client.uploadFile(io, allocator, target.ip, target.http_port, binary, new_name);

    // Step 3: Execute restart command (background replace + restart)
    const restart_cmd = try buildRestartCommand(allocator, is_windows, remote_path, new_name, final_name, target.hostname);
    defer allocator.free(restart_cmd);

    std.debug.print("[deploy] Sending restart command to {s}...\n", .{target.hostname});
    const restart_result = executor.execRemote(io, allocator, target.ip, target.http_port, restart_cmd);
    if (restart_result) |output| {
        allocator.free(output);
        std.debug.print("[deploy] {s} restart acknowledged\n", .{target.hostname});
    } else |err| {
        // Connection drop during restart is expected (pkill kills the HTTP server).
        // Other errors (refused, timeout, etc.) indicate the command was never delivered.
        if (err == error.ConnectionRefused or err == error.ConnectionTimedOut) {
            std.debug.print("[deploy] {s}: cannot connect to HTTP server — VM may be unreachable\n", .{target.hostname});
            return err;
        }
        std.debug.print("[deploy] {s}: restart connection closed (expected during process restart): {}\n", .{ target.hostname, err });
    }

    std.debug.print("[deploy] {s} deploy complete ✓\n", .{target.hostname});
}

/// Scan online guests and build+deploy per target
pub fn deployAll(io: std.Io, allocator: std.mem.Allocator, port: u16, specific: ?[]const u8) !void {
    std.debug.print("[deploy] Scanning online Guests...\n", .{});

    const guests = try scanGuests(io, allocator, port);
    defer {
        for (guests) |g| {
            allocator.free(g.hostname);
            allocator.free(g.ip);
            allocator.free(g.ssh);
        }
        allocator.free(guests);
    }

    try deployWithTargets(io, allocator, guests, specific);
}

/// Build+deploy using known DeployTarget list (for IPC reuse, skips UDP scan)
pub fn deployWithTargets(io: std.Io, allocator: std.mem.Allocator, guests: []DeployTarget, specific: ?[]const u8) !void {
    if (guests.len == 0) {
        std.debug.print("[deploy] No online Guests, skipping\n", .{});
        return;
    }

    std.debug.print("[deploy] Found {d} online Guests:\n", .{guests.len});
    for (guests) |g| {
        std.debug.print("  - {s} ({s}) → {s}\n", .{ g.hostname, g.target, g.ip });
    }

    // Collect unique targets that need building
    var unique_targets: std.ArrayList([]const u8) = .empty;
    defer {
        for (unique_targets.items) |t| {
            allocator.free(t);
        }
        unique_targets.deinit(allocator);
    }

    for (guests) |g| {
        if (specific != null and !std.mem.eql(u8, g.hostname, specific.?)) continue;

        var seen = false;
        for (unique_targets.items) |t| {
            if (std.mem.eql(u8, t, g.target)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try unique_targets.append(allocator, try allocator.dupe(u8, g.target));
        }
    }

    if (unique_targets.items.len == 0) {
        std.debug.print("[deploy] No matching Guest\n", .{});
        return;
    }

    // Build per target → deploy to corresponding guests
    var compiled: std.StringHashMap([]const u8) = .init(allocator);
    defer {
        var it = compiled.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        compiled.deinit();
    }

    for (unique_targets.items) |target_triple| {
        const binary = try buildBinary(io, allocator, target_triple);
        try compiled.put(target_triple, binary);
    }

    // Deploy one by one
    for (guests) |g| {
        if (specific != null and !std.mem.eql(u8, g.hostname, specific.?)) continue;

        const binary = compiled.get(g.target) orelse {
            std.debug.print("[deploy] Build artifact for {s} not found, skipping\n", .{g.hostname});
            continue;
        };

        deployToTarget(io, allocator, g, binary) catch |err| {
            std.debug.print("[deploy] {s} deploy failed: {}\n", .{ g.hostname, err });
        };
    }

    std.debug.print("[deploy] All deployments complete!\n", .{});
}

/// --watch file monitor auto-deploy
pub fn watchLoop(io: std.Io, allocator: std.mem.Allocator, port: u16, watch_path: []const u8) !void {
    std.debug.print("[watch] Watching: {s}\n  (Ctrl+C to exit)\n", .{watch_path});

    var last_mtime: i128 = 0;

    while (true) {
        var latest_mtime: i128 = 0;
        var dir = try std.Io.Dir.cwd().openDir(io, watch_path, .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".zig")) {
                const stat = try dir.statFile(io, entry.name);
                const mtime = stat.modified;
                if (mtime > latest_mtime) {
                    latest_mtime = mtime;
                }
            }
        }

        if (latest_mtime > last_mtime and last_mtime > 0) {
            std.debug.print("\n[watch] File change detected, auto-deploying...\n", .{});
            deployAll(io, allocator, port, null) catch |err| {
                std.debug.print("[watch] Deploy failed: {}\n", .{err});
            };
            std.debug.print("[watch] Waiting for next change...\n", .{});
        }

        last_mtime = latest_mtime;
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    }
}

test "scanGuests" { _ = scanGuests; }
test "deployAll" { _ = deployAll; }
test "deployWithTargets" { _ = deployWithTargets; }
test "watchLoop" { _ = watchLoop; }
test "buildRestartCommand - linux" {
    const allocator = std.testing.allocator;
    const cmd = try buildRestartCommand(allocator, false, "/opt/utmm", "utmm.new", "utmm", "linuxvm");
    defer allocator.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "nohup") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "utmm.new") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "--hostname linuxvm") != null);
}
test "buildRestartCommand - windows" {
    const allocator = std.testing.allocator;
    const cmd = try buildRestartCommand(allocator, true, "C:\\opt\\utmm", "utmm.new.exe", "utmm.exe", "windowsvm");
    defer allocator.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ping -n 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "taskkill") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "--hostname windowsvm") != null);
}
test "DeployTarget fields" {
    const dt = DeployTarget{
        .hostname = "test", .target = "aarch64-linux", .ip = "10.0.0.1",
        .http_port = 2121, .ssh = "root@test",
    };
    try std.testing.expectEqual(@as(u16, 2121), dt.http_port);
}
