//! Unified cross-platform service management.
//!
//! Canonical install path:
//!   POSIX:   /opt/utmm/utmm
//!   Windows: C:\opt\utmm\utmm.exe
//!
//! Self-copy model: the running binary copies itself to the canonical path.
//! forceInstall() is always a full overwrite — stop → kill → copy → install → start.
//! No symlinks, no utmm.next staging files, no in-place rename of running binaries.

const builtin = @import("builtin");
const std = @import("std");
const fail = @import("fail.zig");
const install_mod = @import("install.zig");

/// POSIX canonical install path.
pub const CANONICAL_PATH_POSIX = "/opt/utmm/utmm";
/// Windows canonical install path.
pub const CANONICAL_PATH_WIN = "C:\\opt\\utmm\\utmm.exe";

/// Service names per platform and role.
const ServiceNames = struct {
    guest: []const u8,
    host: []const u8,
};

const SERVICE_NAMES = switch (builtin.os.tag) {
    .macos => ServiceNames{ .guest = "com.utmm.guest", .host = "com.utmm.host" },
    .linux => ServiceNames{ .guest = "utmm-guest", .host = "utmm-host" },
    .windows => ServiceNames{ .guest = "UTM-Monitor-Guest", .host = "UTM-Monitor-Host" },
    else => ServiceNames{ .guest = "utmm-guest", .host = "utmm-host" },
};

pub const ServiceRole = enum { guest, host };

fn svcName(role: ServiceRole) []const u8 {
    return switch (role) {
        .guest => SERVICE_NAMES.guest,
        .host => SERVICE_NAMES.host,
    };
}

/// Return the canonical install path for the current platform.
pub fn canonicalPath() []const u8 {
    if (builtin.os.tag == .windows) return CANONICAL_PATH_WIN;
    return CANONICAL_PATH_POSIX;
}

/// Return the directory portion of the canonical path.
pub fn canonicalDir() []const u8 {
    if (builtin.os.tag == .windows) return "C:\\opt\\utmm";
    return "/opt/utmm";
}

/// Check if the current process is running from the canonical path.
pub fn isAtCanonicalPath(io: std.Io) bool {
    var buf: [4096]u8 = undefined;
    const len = std.process.executablePath(io, &buf) catch return false;
    return std.mem.eql(u8, buf[0..len], canonicalPath());
}

// ═══════════════════════════════════════════════════════════════════════════
// Command helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Run a command using std.process.run. Returns true on success (exit code 0).
fn runCmd(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return true;
}

/// Run a command and return its stdout (caller owns), or null on failure.
fn runCmdStdout(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    alloc.free(result.stderr);
    return result.stdout;
}

/// Run a command and check its exit code. Returns true if exit code is 0.
fn runCmdCheckExit(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Service status queries
// ═══════════════════════════════════════════════════════════════════════════

/// Check if the service is currently running.
pub fn isRunning(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) bool {
    const name = svcName(role);
    return switch (builtin.os.tag) {
        .macos => blk: {
            const result = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
            if (result) |stdout| {
                defer alloc.free(stdout);
                break :blk std.mem.indexOf(u8, stdout, name) != null;
            }
            break :blk false;
        },
        .linux => blk: {
            break :blk runCmdCheckExit(alloc, io, &[_][]const u8{
                "systemctl", "is-active", "--quiet", name,
            });
        },
        .windows => blk: {
            const result = runCmdStdout(alloc, io, &[_][]const u8{
                "sc", "query", name,
            });
            if (result) |stdout| {
                defer alloc.free(stdout);
                break :blk std.mem.indexOf(u8, stdout, "RUNNING") != null;
            }
            break :blk false;
        },
        else => false,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Service lifecycle: install / uninstall / start / stop
// ═══════════════════════════════════════════════════════════════════════════

/// Install service configuration pointing to the canonical binary path.
/// Always overwrites existing config — no checks, no comparison.
pub fn install(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    // Clean up legacy service names first
    switch (builtin.os.tag) {
        .macos => {
            const legacy_labels = [_][]const u8{"com.utmm"};
            for (legacy_labels) |legacy| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{legacy});
                defer alloc.free(plist_path);
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", legacy });
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const legacy_names = [_][]const u8{"utmm"};
            for (legacy_names) |legacy| {
                _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "stop", legacy });
                _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "disable", legacy });
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{legacy});
                defer alloc.free(unit_path);
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
        },
        .windows => {
            const legacy_names = [_][]const u8{"UTM-Monitor"};
            for (legacy_names) |legacy| {
                _ = runCmd(alloc, io, &[_][]const u8{ "sc", "stop", legacy });
                _ = runCmd(alloc, io, &[_][]const u8{ "sc", "delete", legacy });
            }
        },
        else => {},
    }

    switch (builtin.os.tag) {
        .macos => try installMacOS(io, alloc, role, extra_args),
        .linux => try installLinux(io, alloc, role, extra_args),
        .windows => try installWindows(io, alloc, role, extra_args),
        else => fail.msg("install", "unsupported platform: {s}", .{@tagName(builtin.os.tag)}),
    }
}

fn installMacOS(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName(role);
    const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
    defer alloc.free(plist_path);

    const exe_path = canonicalPath();
    const env = install_mod.detectServiceEnv(.macos);

    // Build ProgramArguments string
    var args_list: std.ArrayListAligned(u8, null) = .empty;
    defer args_list.deinit(alloc);
    try args_list.appendSlice(alloc, "        <string>");
    try args_list.appendSlice(alloc, exe_path);
    try args_list.appendSlice(alloc, "</string>\n");
    try args_list.appendSlice(alloc, "        <string>--svc</string>\n");
    if (role == .host) {
        try args_list.appendSlice(alloc, "        <string>--host</string>\n");
    }
    for (extra_args) |arg| {
        try args_list.appendSlice(alloc, "        <string>");
        try args_list.appendSlice(alloc, arg);
        try args_list.appendSlice(alloc, "</string>\n");
    }

    const log_path = if (role == .host) "/var/log/utmm-host.log" else "/var/log/utmm-guest.log";

    const plist = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\{s}
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>SHELL</key>
        \\        <string>{s}</string>
        \\        <key>HOME</key>
        \\        <string>{s}</string>
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
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
    , .{ name, args_list.items, env.shell, env.home, log_path });
    defer alloc.free(plist);

    // Write plist file
    {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(io, plist_path, .{ .truncate = true }) catch |err| {
            fail.err("install/write-plist", err);
        };
        defer f.close(io);
        f.writeStreamingAll(io, plist) catch |err| {
            fail.err("install/write-plist-content", err);
        };
    }

    // Bootstrap
    if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path })) {
        fail.msg("install/launchctl-bootstrap", "failed to bootstrap {s}", .{name});
    }

    // Verify
    const list_out = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
    if (list_out) |stdout| {
        defer alloc.free(stdout);
        if (std.mem.indexOf(u8, stdout, name) == null) {
            fail.msg("install/verify", "service {s} not found in launchctl list after bootstrap", .{name});
        }
    }
    std.log.info("[svc] macOS service {s} installed", .{name});
}

fn installLinux(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName(role);
    const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
    defer alloc.free(unit_path);

    const exe_path = canonicalPath();
    const env = install_mod.detectServiceEnv(.linux);

    // Build ExecStart args
    var exec_args: std.ArrayListAligned(u8, null) = .empty;
    defer exec_args.deinit(alloc);
    try exec_args.appendSlice(alloc, exe_path);
    try exec_args.appendSlice(alloc, " --svc");
    if (role == .host) {
        try exec_args.appendSlice(alloc, " --host");
    }
    for (extra_args) |arg| {
        try exec_args.append(alloc, ' ');
        try exec_args.appendSlice(alloc, arg);
    }

    const unit = try std.fmt.allocPrint(alloc,
        \\[Unit]
        \\Description=UTM Monitor {s}
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL={s}
        \\Environment=HOME={s}
        \\ExecStart={s}
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
    , .{
        if (role == .host) "Host" else "Guest",
        env.shell,
        env.home,
        exec_args.items,
    });
    defer alloc.free(unit);

    // Write unit file
    {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(io, unit_path, .{ .truncate = true }) catch |err| {
            fail.err("install/write-unit", err);
        };
        defer f.close(io);
        f.writeStreamingAll(io, unit) catch |err| {
            fail.err("install/write-unit-content", err);
        };
    }

    // Reload and enable
    if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" })) {
        fail.msg("install/systemctl-daemon-reload", "daemon-reload failed", .{});
    }
    if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "enable", name })) {
        fail.msg("install/systemctl-enable", "enable {s} failed", .{name});
    }

    std.log.info("[svc] Linux service {s} installed", .{name});
}

fn installWindows(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName(role);
    const exe_path = canonicalPath();

    // Build binPath with quoted exe and args
    var bin_path: std.ArrayListAligned(u8, null) = .empty;
    defer bin_path.deinit(alloc);
    try bin_path.appendSlice(alloc, "\"");
    try bin_path.appendSlice(alloc, exe_path);
    try bin_path.appendSlice(alloc, "\" --svc");
    if (role == .host) {
        try bin_path.appendSlice(alloc, " --host");
    }
    for (extra_args) |arg| {
        try bin_path.append(alloc, ' ');
        try bin_path.appendSlice(alloc, arg);
    }

    // Delete old service if exists
    _ = runCmd(alloc, io, &[_][]const u8{ "sc", "stop", name });
    _ = runCmd(alloc, io, &[_][]const u8{ "sc", "delete", name });

    // Create service
    if (!runCmd(alloc, io, &[_][]const u8{
        "sc", "create", name,
        "binPath=", bin_path.items,
        "start=", "auto",
    })) {
        fail.msg("install/sc-create", "failed to create service {s}", .{name});
    }

    // Configure failure actions: 3 restarts then stop
    if (!runCmd(alloc, io, &[_][]const u8{
        "sc", "failure", name,
        "reset=", "30",
        "actions=", "restart/5000/restart/5000/restart/5000/none/5000",
    })) {
        fail.msg("install/sc-failure", "failed to configure failure actions for {s}", .{name});
    }

    // Add firewall rule
    const rule_name = "UTM Monitor";
    _ = runCmd(alloc, io, &[_][]const u8{
        "netsh", "advfirewall", "firewall", "delete", "rule",
        "name=" ++ rule_name,
    });
    if (!runCmd(alloc, io, &[_][]const u8{
        "netsh", "advfirewall", "firewall", "add", "rule",
        "name=" ++ rule_name,
        "dir=", "in",
        "action=", "allow",
        "program=", exe_path,
        "enable=", "yes",
    })) {
        fail.msg("install/firewall", "failed to add firewall rule", .{});
    }

    std.log.info("[svc] Windows service {s} installed", .{name});
}

/// Uninstall service: stop, remove config, delete binary.
pub fn uninstall(io: std.Io, alloc: std.mem.Allocator) !void {
    // Stop and remove all service names (current + legacy)
    switch (builtin.os.tag) {
        .macos => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "com.utmm" };
            for (all_names) |name| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", name });
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "utmm" };
            for (all_names) |name| {
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
                defer alloc.free(unit_path);
                _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
                _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "disable", name });
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
            _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" });
        },
        .windows => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "UTM-Monitor" };
            for (all_names) |name| {
                _ = runCmd(alloc, io, &[_][]const u8{ "sc", "stop", name });
                _ = runCmd(alloc, io, &[_][]const u8{ "sc", "delete", name });
            }
            // Remove firewall rules
            _ = runCmd(alloc, io, &[_][]const u8{
                "netsh", "advfirewall", "firewall", "delete", "rule",
                "name=UTM Monitor",
            });
        },
        else => {},
    }

    // Clean up retry counter files (macOS)
    if (builtin.os.tag == .macos) {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, "/var/run/utmm-guest.retry") catch {};
        cwd.deleteFile(io, "/var/run/utmm-host.retry") catch {};
    }

    // Delete binary
    const exe_path = canonicalPath();
    std.Io.Dir.cwd().deleteFile(io, exe_path) catch |err| {
        std.log.warn("[svc] could not delete binary at {s}: {}", .{ exe_path, err });
    };

    // Kill any remaining utmm processes
    killAllUtmm(io, alloc) catch {};

    std.log.info("[svc] uninstall complete", .{});
}

/// Start the service.
pub fn start(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) !void {
    const name = svcName(role);
    switch (builtin.os.tag) {
        .macos => {
            const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
            defer alloc.free(plist_path);
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path })) {
                fail.msg("start/launchctl-bootstrap", "failed to bootstrap {s}", .{name});
            }
            // Verify
            const list_out = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
            if (list_out) |stdout| {
                defer alloc.free(stdout);
                if (std.mem.indexOf(u8, stdout, name) == null) {
                    fail.msg("start/verify", "service {s} not found in launchctl list after bootstrap", .{name});
                }
            }
        },
        .linux => {
            if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "start", name })) {
                fail.msg("start/systemctl-start", "failed to start {s}", .{name});
            }
        },
        .windows => {
            if (!runCmd(alloc, io, &[_][]const u8{ "sc", "start", name })) {
                fail.msg("start/sc-start", "failed to start {s}", .{name});
            }
        },
        else => fail.msg("start", "unsupported platform", .{}),
    }
    std.log.info("[svc] {s} started", .{name});
}

/// Stop the service.
pub fn stop(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) !void {
    const name = svcName(role);
    switch (builtin.os.tag) {
        .macos => {
            _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", name });
        },
        .linux => {
            _ = runCmd(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
        },
        .windows => {
            _ = runCmd(alloc, io, &[_][]const u8{ "sc", "stop", name });
        },
        else => {},
    }
}

/// Kill all utmm processes (except self) — best-effort, never fails.
fn killAllUtmm(io: std.Io, alloc: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .macos, .linux => {
            _ = runCmd(alloc, io, &[_][]const u8{ "pkill", "-9", "utmm" });
        },
        .windows => {
            _ = runCmd(alloc, io, &[_][]const u8{ "taskkill", "/f", "/im", "utmm.exe" });
        },
        else => {},
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Self-copy: copy current binary to canonical path
// ═══════════════════════════════════════════════════════════════════════════

/// Copy the current process binary to the canonical install path.
/// Uses tmp file + rename for atomic replacement.
pub fn selfCopy(io: std.Io, alloc: std.mem.Allocator) !void {
    const dest = canonicalPath();

    // Get current executable path
    var self_buf: [4096]u8 = undefined;
    const self_len = std.process.executablePath(io, &self_buf) catch |err| {
        fail.err("selfCopy/executablePath", err);
    };
    const self_path = self_buf[0..self_len];

    // Already at canonical path — nothing to do
    if (std.mem.eql(u8, self_path, dest)) {
        std.log.info("[svc] already at canonical path", .{});
        return;
    }

    // Ensure canonical directory exists
    const dest_dir = canonicalDir();
    std.Io.Dir.cwd().createDirPath(io, dest_dir) catch |err| {
        fail.err("selfCopy/mkdir", err);
    };

    // Copy to temp file first, then rename (atomic on same filesystem)
    const tmp_path = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\utmm.tmp.exe", .{dest_dir})
    else
        try std.fmt.allocPrint(alloc, "{s}/utmm.tmp", .{dest_dir});
    defer alloc.free(tmp_path);

    // Remove stale tmp file
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Copy with executable permissions on POSIX (chmod removed in Zig 0.16.0)
    copyFile(io, alloc, self_path, tmp_path, builtin.os.tag != .windows) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail.err("selfCopy/copy", err);
    };

    // Atomic rename tmp → dest
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dest, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        // On EXDEV (cross-filesystem), try copy+delete fallback
        if (err == error.CrossDevice) {
            copyFile(io, alloc, tmp_path, dest, builtin.os.tag != .windows) catch |err2| {
                fail.err("selfCopy/copy-fallback", err2);
            };
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        } else {
            fail.err("selfCopy/rename", err);
        }
    };

    std.log.info("[svc] self-copied to canonical path {s}", .{dest});
}

/// Copy src to dst. Uses 64KB chunks. If make_executable is true,
/// sets 755 permissions on the destination file (POSIX only).
fn copyFile(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, make_executable: bool) !void {
    _ = alloc;
    const cwd = std.Io.Dir.cwd();
    const src = cwd.openFile(io, src_path, .{ .mode = .read_only }) catch |err| {
        fail.err("selfCopy/open-src", err);
    };
    defer src.close(io);

    const dst_file = if (make_executable and builtin.os.tag != .windows)
        cwd.createFile(io, dst_path, .{ .truncate = true, .permissions = @enumFromInt(0o755) })
    else
        cwd.createFile(io, dst_path, .{ .truncate = true });
    const dst = dst_file catch |err| {
        fail.err("selfCopy/create-dst", err);
    };
    defer dst.close(io);

    var buf: [65536]u8 = undefined;
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = src.reader(io, &read_buf);
    var writer = dst.writer(io, &write_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch |err| {
            fail.err("selfCopy/read", err);
        };
        if (n == 0) break;
        writer.interface.writeAll(buf[0..n]) catch |err| {
            fail.err("selfCopy/write", err);
        };
    }
    writer.interface.flush() catch {};

    // fsync to ensure data is on disk before rename
    dst.sync(io) catch {};
}

// ═══════════════════════════════════════════════════════════════════════════
// Core operations: forceInstall / ensure
// ═══════════════════════════════════════════════════════════════════════════

/// Force install — unconditional overwrite.
/// Stops any running service, kills all utmm processes, copies self to
/// canonical path, registers service config, and starts the service.
/// Fail-fast: any unexpected error calls fail() and does not return.
pub fn forceInstall(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName(role);
    std.log.info("[svc] force installing {s}...", .{name});

    // 1. Stop any running service (ignore errors — may not be installed)
    stop(io, alloc, role) catch |err| {
        std.log.warn("[svc] stop before install: {} (continuing)", .{err});
    };

    // 2. Kill any lingering utmm processes
    killAllUtmm(io, alloc) catch {};

    // 3. Copy self to canonical path
    selfCopy(io, alloc) catch |err| {
        fail.err("forceInstall/selfCopy", err);
    };

    // 4. Install/overwrite service configuration
    install(io, alloc, role, extra_args) catch |err| {
        fail.err("forceInstall/install", err);
    };

    // 5. Start service
    start(io, alloc, role) catch |err| {
        fail.err("forceInstall/start", err);
    };

    std.log.info("[svc] {s} installed and running", .{name});
}

/// Ensure the service is installed and running.
/// If already running: log and return.
/// If not running: call forceInstall.
pub fn ensure(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName(role);
    if (isRunning(io, alloc, role)) {
        std.log.info("[svc] {s} service already running", .{name});
        std.debug.print("utmm {s} service is running.\n", .{if (role == .host) "host" else "guest"});
        return;
    }
    std.log.info("[svc] {s} service not running — force installing...", .{name});
    forceInstall(io, alloc, role, extra_args);
}

// ═══════════════════════════════════════════════════════════════════════════
// macOS retry counter — prevents infinite restart loops
// ═══════════════════════════════════════════════════════════════════════════

/// Check restart count on macOS. If we've restarted >= 3 times,
/// exit(0) so launchd stops restarting us.
/// Uses a simple counter file — resetRetryCounter() clears it after
/// the service runs successfully.
pub fn checkRetryLimit(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) void {
    if (builtin.os.tag != .macos) return;

    const retry_path = retryCounterPath(alloc, role) catch return;
    defer alloc.free(retry_path);

    var count: u32 = 0;

    // Read existing counter
    if (std.Io.Dir.cwd().readFileAlloc(io, retry_path, alloc, std.Io.Limit.limited(1024))) |content| {
        defer alloc.free(content);
        count = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n\r"), 10) catch 0;
    } else |_| {}

    count += 1;

    if (count > 3) {
        std.log.err("[svc] Too many restart attempts ({d}), stopping.", .{count});
        std.Io.Dir.cwd().deleteFile(io, retry_path) catch {};
        std.process.exit(0);
    }

    // Write updated counter
    const new_content = std.fmt.allocPrint(alloc, "{d}\n", .{count}) catch return;
    defer alloc.free(new_content);
    std.Io.Dir.cwd().deleteFile(io, retry_path) catch {};
    const f = std.Io.Dir.cwd().createFile(io, retry_path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io, new_content) catch {};

    std.log.info("[svc] retry count {d}/3", .{count});
}

/// Reset retry counter after successful startup (macOS only).
pub fn resetRetryCounter(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) void {
    if (builtin.os.tag != .macos) return;
    const retry_path = retryCounterPath(alloc, role) catch return;
    defer alloc.free(retry_path);
    std.Io.Dir.cwd().deleteFile(io, retry_path) catch {};
    std.log.info("[svc] retry counter reset", .{});
}

fn retryCounterPath(alloc: std.mem.Allocator, role: ServiceRole) ![]const u8 {
    const suffix = if (role == .host) "host" else "guest";
    // Try /var/run first, fall back to /tmp
    const path = try std.fmt.allocPrint(alloc, "/var/run/utmm-{s}.retry", .{suffix});
    return path;
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows SCM integration
// ═══════════════════════════════════════════════════════════════════════════

const windows = std.os.windows;

const SERVICE_WIN32_OWN_PROCESS = 0x00000010;
const SERVICE_ACCEPT_STOP = 0x00000001;
const SERVICE_CONTROL_STOP = 0x00000001;
const SERVICE_RUNNING = 0x00000004;
const SERVICE_STOP_PENDING = 0x00000003;
const SERVICE_STOPPED = 0x00000001;

const SERVICE_STATUS = extern struct {
    dwServiceType: u32,
    dwCurrentState: u32,
    dwControlsAccepted: u32,
    dwWin32ExitCode: u32,
    dwServiceSpecificExitCode: u32,
    dwCheckPoint: u32,
    dwWaitHint: u32,
};

const SERVICE_STATUS_HANDLE = *anyopaque;

const SvcMainFn = *const fn (dwNumServiceArgs: u32, lpServiceArgVectors: [*]?[*:0]const u16) callconv(.winapi) void;

const SERVICE_TABLE_ENTRYW = extern struct {
    lpServiceName: ?[*:0]const u16,
    lpServiceProc: ?SvcMainFn,
};

extern "advapi32" fn StartServiceCtrlDispatcherW(lpServiceStartTable: [*]const SERVICE_TABLE_ENTRYW) callconv(.winapi) u32;
extern "advapi32" fn RegisterServiceCtrlHandlerExW(lpServiceName: [*:0]const u16, lpHandlerProc: ?*const fn (dwControl: u32, dwEventType: u32, lpEventData: ?*anyopaque, lpContext: ?*anyopaque) callconv(.winapi) u32, lpContext: ?*anyopaque) callconv(.winapi) ?SERVICE_STATUS_HANDLE;
extern "advapi32" fn SetServiceStatus(hServiceStatus: ?SERVICE_STATUS_HANDLE, lpServiceStatus: *SERVICE_STATUS) callconv(.winapi) u32;

const SvcGlobals = struct {
    var io: std.Io = undefined;
    var gpa: std.mem.Allocator = undefined;
    var is_host: bool = false;
    var hostname_override: ?[]const u8 = null;
    var port: u16 = 2121;
    var mesh_port: u16 = 2121;
    var peer_mesh: ?[]const u8 = null;
    var host_ip: ?[]const u8 = null;
    var status_handle: ?SERVICE_STATUS_HANDLE = null;
    var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
};

fn svcCtrlHandler(dwControl: u32, _: u32, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) u32 {
    if (dwControl == SERVICE_CONTROL_STOP) {
        var status = std.mem.zeroes(SERVICE_STATUS);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_STOP_PENDING;
        status.dwControlsAccepted = 0;
        status.dwWaitHint = 30000;
        _ = SetServiceStatus(SvcGlobals.status_handle, &status);

        SvcGlobals.shutdown_flag.store(true, .release);
        return 0;
    }
    return 0;
}

fn svcMain(_: u32, _: [*]?[*:0]const u16) callconv(.winapi) void {
    const svc_name_utf16 = [_:0]u16{ 'u', 't', 'm', 'm', 0 };
    const h = RegisterServiceCtrlHandlerExW(&svc_name_utf16, svcCtrlHandler, null);
    SvcGlobals.status_handle = h;

    if (h) |handle| {
        var status = std.mem.zeroes(SERVICE_STATUS);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_RUNNING;
        status.dwControlsAccepted = SERVICE_ACCEPT_STOP;
        _ = SetServiceStatus(handle, &status);
    }

    const host_mod = @import("host.zig");
    const guest_mod = @import("guest.zig");

    if (SvcGlobals.is_host) {
        host_mod.runWithIo(SvcGlobals.io, SvcGlobals.gpa, .{
            .is_host = true,
            .port = SvcGlobals.port,
            .mesh_port = SvcGlobals.mesh_port,
            .peer_mesh = SvcGlobals.peer_mesh,
            .hostname = SvcGlobals.hostname_override,
            .host_ip = SvcGlobals.host_ip,
        }, &SvcGlobals.shutdown_flag) catch |err| {
            std.log.err("[svc] host run failed: {}", .{err});
        };
    } else {
        guest_mod.runWithIo(SvcGlobals.io, SvcGlobals.gpa, .{
            .hostname = SvcGlobals.hostname_override,
            .port = SvcGlobals.port,
            .mesh_port = SvcGlobals.mesh_port,
            .peer_mesh = SvcGlobals.peer_mesh,
            .host_ip = SvcGlobals.host_ip,
        }, &SvcGlobals.shutdown_flag) catch |err| {
            std.log.err("[svc] guest run failed: {}", .{err});
        };
    }

    if (h) |handle| {
        var status = std.mem.zeroes(SERVICE_STATUS);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_STOPPED;
        status.dwControlsAccepted = 0;
        _ = SetServiceStatus(handle, &status);
    }
}

/// Run as a Windows service via SCM.
pub fn winServiceRun(
    sys_io: std.Io,
    gpa: std.mem.Allocator,
    is_host: bool,
    hostname_override: ?[]const u8,
    port: u16,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
    host_ip: ?[]const u8,
) !void {
    SvcGlobals.io = sys_io;
    SvcGlobals.gpa = gpa;
    SvcGlobals.is_host = is_host;
    SvcGlobals.hostname_override = hostname_override;
    SvcGlobals.port = port;
    SvcGlobals.mesh_port = mesh_port;
    SvcGlobals.peer_mesh = peer_mesh;
    SvcGlobals.host_ip = host_ip;

    const svc_name_utf16 = [_:0]u16{ 'u', 't', 'm', 'm', 0 };
    var svc_table = [2]SERVICE_TABLE_ENTRYW{
        .{ .lpServiceName = &svc_name_utf16, .lpServiceProc = svcMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (StartServiceCtrlDispatcherW(&svc_table) == 0) {
        std.debug.print("[svc] StartServiceCtrlDispatcher failed (error: {})\n", .{windows.GetLastError()});
        return error.ServiceDispatchFailed;
    }
}
