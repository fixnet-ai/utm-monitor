//! Self-upgrade mode — entered when the executable is named utmm-old[.exe]
//! or when --update-url is passed.
//!
//! Steps (same logic for macOS, Linux, Windows):
//! 1. Stop the utmm service (so auto-restart doesn't interfere)
//! 2. Force-kill all utmm processes (excluding self: utmm-old ≠ utmm)
//! 3. Download new binary via HTTP (Zig std.http.Client, no curl)
//! 4. Replace old binary on disk
//! 5. Start the utmm service
//! 6. Exit

const std = @import("std");
const builtin = @import("builtin");

/// Upgrade mode entry point.
/// Called from main() when --update-url is set or exe name contains "-old".
pub fn run(init: std.process.Init, update_url: []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;

    std.log.info("[upgrade] Starting upgrade mode, url={s}", .{update_url});

    // 1. Stop the service
    stopService(io, gpa) catch |err| {
        std.log.err("[upgrade] Failed to stop service: {}", .{err});
        // Continue — best-effort
    };

    // Small delay to let service stop fully
    std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};

    // 2. Kill all utmm processes (excluding self)
    killUtmmProcesses(io, gpa) catch |err| {
        std.log.err("[upgrade] Failed to kill processes: {}", .{err});
        // Continue — best-effort
    };

    // Small delay after killing
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    // 3. Download new binary
    const data = downloadBinary(io, gpa, update_url) catch |err| {
        std.log.err("[upgrade] Download failed: {}", .{err});
        // Try to restart service before giving up
        startService(io, gpa) catch {};
        return err;
    };
    defer gpa.free(data);

    std.log.info("[upgrade] Downloaded {d} bytes", .{data.len});

    // 4. Replace old binary
    replaceBinary(io, gpa, data) catch |err| {
        std.log.err("[upgrade] Replace failed: {}", .{err});
        // Try to restart service before giving up
        startService(io, gpa) catch {};
        return err;
    };

    std.log.info("[upgrade] Binary replaced successfully", .{});

    // 5. Start service
    startService(io, gpa) catch |err| {
        std.log.err("[upgrade] Failed to start service: {}", .{err});
        return err;
    };

    std.log.info("[upgrade] Upgrade complete, exiting", .{});

    // 6. Exit
    std.process.exit(0);
}

/// Run a command via std.process.run and free the output buffers.
fn runCmd(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) void {
    if (std.process.run(gpa, io, .{ .argv = argv })) |result| {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    } else |_| {}
}

/// Stop the utmm guest service via platform service manager.
fn stopService(io: std.Io, gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        runCmd(io, gpa, &.{ "sc", "stop", "UTM-Monitor-Guest" });
    } else if (builtin.os.tag == .macos) {
        runCmd(io, gpa, &.{ "launchctl", "bootout", "system", "/Library/LaunchDaemons/com.utmm.guest.plist" });
    } else {
        // Linux (systemd)
        runCmd(io, gpa, &.{ "systemctl", "stop", "utmm-guest" });
    }
}

/// Force-kill all utmm processes, excluding self (utmm-old).
fn killUtmmProcesses(io: std.Io, gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        // taskkill /im utmm.exe — exact filename match, won't match utmm-old.exe
        runCmd(io, gpa, &.{ "taskkill", "/f", "/im", "utmm.exe" });
    } else {
        // pkill -9 -x utmm — exact process name match, won't match utmm-old
        runCmd(io, gpa, &.{ "pkill", "-9", "-x", "utmm" });
    }
}

/// Download new binary from the given URL via HTTP.
/// Returns heap-allocated data (caller frees).
fn downloadBinary(io: std.Io, gpa: std.mem.Allocator, url: []const u8) ![]const u8 {
    const max_download = 20 * 1024 * 1024; // 20 MB
    const download_buf = try gpa.alloc(u8, max_download);
    defer gpa.free(download_buf);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var writer: std.Io.Writer = .fixed(download_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer,
        .keep_alive = false,
    });

    if (result.status != .ok) {
        std.log.err("[upgrade] HTTP status: {}", .{result.status});
        return error.DownloadFailed;
    }

    const data = writer.buffered();

    if (data.len < 100 * 1024) {
        std.log.err("[upgrade] Binary too small: {d} bytes", .{data.len});
        return error.BinaryTooSmall;
    }

    if (data.len >= max_download) {
        std.log.err("[upgrade] Binary exceeds max size", .{});
        return error.BufferFull;
    }

    // Copy to a properly-sized buffer
    const result_data = try gpa.dupe(u8, data);
    return result_data;
}

/// Replace the current utmm binary with the downloaded data.
fn replaceBinary(io: std.Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const install_dir = if (builtin.os.tag == .windows) "C:\\opt\\utmm" else "/opt/utmm";
    const next_name = if (builtin.os.tag == .windows) "utmm.next.exe" else "utmm.next";
    const target_name = if (builtin.os.tag == .windows) "utmm.exe" else "utmm";

    // Build full paths
    const next_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ install_dir, next_name });
    defer gpa.free(next_path);
    const target_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ install_dir, target_name });
    defer gpa.free(target_path);

    // Write downloaded data to utmm.next
    var dir = try std.Io.Dir.cwd().openDir(io, install_dir, .{});
    defer dir.close(io);

    // Delete existing next file if present
    dir.deleteFile(io, next_name) catch {};

    var next_file = try dir.createFile(io, next_name, .{});
    defer next_file.close(io);
    try next_file.writeStreamingAll(io, data);

    // chmod +x on POSIX (no shell — direct syscall)
    if (builtin.os.tag != .windows) {
        const chmod_rc = std.c.chmod(@ptrCast(next_path), 0o755);
        if (chmod_rc != 0) {
            std.log.err("[upgrade] chmod failed: errno={}", .{std.c._errno().*});
            return error.ChmodFailed;
        }
    }

    // Replace target with next
    if (builtin.os.tag == .windows) {
        // On Windows: delete old target, rename next to target
        // The old utmm.exe process is already killed, so this should succeed
        dir.deleteFile(io, target_name) catch {};
        try dir.rename(next_name, dir, target_name, io);
    } else {
        // POSIX: rename is atomic on same filesystem
        try dir.rename(next_name, dir, target_name, io);
    }
}

/// Start the utmm guest service via platform service manager.
fn startService(io: std.Io, gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        runCmd(io, gpa, &.{ "sc", "start", "UTM-Monitor-Guest" });
    } else if (builtin.os.tag == .macos) {
        runCmd(io, gpa, &.{ "launchctl", "bootstrap", "system", "/Library/LaunchDaemons/com.utmm.guest.plist" });
    } else {
        // Linux (systemd)
        runCmd(io, gpa, &.{ "systemctl", "start", "utmm-guest" });
    }
}
