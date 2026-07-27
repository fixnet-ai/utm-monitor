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
const lock = @import("lock.zig");
const protocol = @import("protocol.zig");

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
    return result.term == .exited and result.term.exited == 0;
}

/// Run a command for best-effort cleanup — failure is expected and logged
/// at debug level (not warn, since many of these intentionally target
/// services/files that may not exist).
fn runCmdQuiet(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
        std.log.debug("[svc] cmd failed: {s}: {}", .{ argv[0], err });
        return;
    };
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.debug("[svc] cmd non-zero exit: {s}", .{argv[0]});
    }
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
                // launchctl list format: "PID\tExitCode\tName"
                // PID is "-" when loaded but not running. Look for the
                // service name line and verify the first column is a number.
                var lines = std.mem.splitScalar(u8, stdout, '\n');
                while (lines.next()) |line| {
                    if (std.mem.indexOf(u8, line, name)) |_| {
                        const trimmed = std.mem.trimStart(u8, line, " \t");
                        if (trimmed.len > 0 and std.ascii.isDigit(trimmed[0])) {
                            break :blk true;
                        }
                        break :blk false;
                    }
                }
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
                runCmdQuiet(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", legacy });
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const legacy_names = [_][]const u8{"utmm"};
            for (legacy_names) |legacy| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", legacy });
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", legacy });
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{legacy});
                defer alloc.free(unit_path);
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
        },
        .windows => {
            const legacy_names = [_][]const u8{"UTM-Monitor"};
            for (legacy_names) |legacy| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", legacy });
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", legacy });
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
    const env = .{ .shell = "/bin/zsh", .home = "/var/root" };

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
    const err_log_path = if (role == .host) "/var/log/utmm-host-err.log" else "/var/log/utmm-guest-err.log";

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
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
    , .{ name, args_list.items, env.shell, env.home, log_path, err_log_path });
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

    // Enable then bootstrap (also starts via RunAtLoad=true).
    // Enable clears any persisted disabled flag from a previous
    // uninstall/disable cycle.
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
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
    const env = .{ .shell = "/bin/bash", .home = "/root" };

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
    runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name }); // best-effort: may not exist
    if (!runCmd(alloc, io, &[_][]const u8{ "sc", "delete", name })) {
        std.log.warn("[svc] sc delete {s} failed (may not be installed)", .{name});
    }

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

    // Add firewall rule (delete any previous rule first, ignore error if not found)
    const rule_name = "UTM Monitor";
    runCmdQuiet(alloc, io, &[_][]const u8{
        "netsh", "advfirewall", "firewall", "delete", "rule",
        "name=" ++ rule_name,
    }); // best-effort: may not exist
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

/// Remove service configuration only (no binary deletion, no process killing).
/// Used as rollback when forceInstall's start step fails.
fn uninstallServiceConfig(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) void {
    const name = svcName(role);
    switch (builtin.os.tag) {
        .macos => {
            const plist_path = std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name}) catch return;
            defer alloc.free(plist_path);
            runCmdQuiet(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", name });
            std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
        },
        .linux => {
            const unit_path = std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name}) catch return;
            defer alloc.free(unit_path);
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", name });
            std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" });
        },
        .windows => {
            runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name });
            runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", name });
            runCmdQuiet(alloc, io, &[_][]const u8{
                "netsh", "advfirewall", "firewall", "delete", "rule",
                "name=UTM Monitor",
            });
        },
        else => {},
    }
}

/// Uninstall service: acquire lock, stop, remove config, delete binary.
pub fn uninstall(io: std.Io, alloc: std.mem.Allocator) !void {
    lock.acquire(io, alloc) catch |err| {
        fail.err("uninstall/lock", err);
    };
    defer lock.release(io);

    // Stop and remove all service names (current + legacy)
    switch (builtin.os.tag) {
        .macos => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "com.utmm" };
            for (all_names) |name| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);
                runCmdQuiet(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", name });
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "utmm" };
            for (all_names) |name| {
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
                defer alloc.free(unit_path);
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", name });
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" });
        },
        .windows => {
            const all_names = [_][]const u8{ SERVICE_NAMES.guest, SERVICE_NAMES.host, "UTM-Monitor" };
            for (all_names) |name| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name });
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", name });
            }
            // Remove firewall rules
            runCmdQuiet(alloc, io, &[_][]const u8{
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
    killAllUtmm(io, alloc) catch |err| {
        std.log.warn("[svc] uninstall killAllUtmm failed: {}", .{err});
    };

    std.log.info("[svc] uninstall complete", .{});
}

/// Start the service.
pub fn start(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) !void {
    const name = svcName(role);
    switch (builtin.os.tag) {
        .macos => {
            // If already running, do nothing. Otherwise kickstart (restarts
            // a loaded-but-dead service) or bootstrap (loads from scratch).
            // installMacOS already bootstraps the service, so start is
            // normally a no-op; kickstart handles the edge case where the
            // service was installed but later stopped.
            if (isRunning(io, alloc, role)) {
                std.log.info("[svc] {s} already running in start()", .{name});
                return;
            }
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "kickstart", "-k", "system", name })) {
                // kickstart failed — service may not be loaded.
                // Add a short delay to let launchd finish processing a prior
                // bootout before trying bootstrap (avoids errno=2/5, Finding 128).
                std.log.info("[svc] kickstart failed, waiting 500ms before bootstrap...", .{});
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });

                // Retry bootstrap up to 3 times with 1-second delays.
                // launchd may still be processing a prior bootout; retries
                // resolve transient errno=2/5 failures (Finding 123 + 128).
                var bootstrapped = false;
                for (0..3) |attempt| {
                    if (runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path })) {
                        bootstrapped = true;
                        std.log.info("[svc] bootstrap succeeded on attempt {d}", .{attempt + 1});
                        break;
                    }
                    std.log.warn("[svc] bootstrap attempt {d}/3 failed, retrying in 1s...", .{attempt + 1});
                    std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch break;
                }

                if (!bootstrapped) {
                    fail.msg("start/launchctl-bootstrap", "failed to bootstrap {s} after 3 attempts", .{name});
                }
            }
            // Verify — give launchd a moment to register the service
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
            const list_out = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
            if (list_out) |stdout| {
                defer alloc.free(stdout);
                if (std.mem.indexOf(u8, stdout, name) == null) {
                    fail.msg("start/verify", "service {s} not found in launchctl list after start", .{name});
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
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", "system", name })) {
                std.log.warn("[svc] stop {s}: bootout returned non-zero (may not be running)", .{name});
            }
        },
        .linux => {
            if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "stop", name })) {
                std.log.warn("[svc] stop {s}: systemctl stop returned non-zero (may not be running)", .{name});
            }
        },
        .windows => {
            if (!runCmd(alloc, io, &[_][]const u8{ "sc", "stop", name })) {
                std.log.warn("[svc] stop {s}: sc stop returned non-zero (may not be running)", .{name});
            }
        },
        else => {},
    }
}

/// Get our own process ID, cross-platform.
fn getOwnPid() u32 {
    if (builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    return @intCast(std.posix.system.getpid());
}

/// Kill all utmm processes (except self) — best-effort, never fails.
/// Uses pgrep/tasklist to enumerate PIDs, filtering out our own PID
/// so the installer doesn't kill itself (Finding 139).
fn killAllUtmm(io: std.Io, alloc: std.mem.Allocator) !void {
    const my_pid = getOwnPid();
    switch (builtin.os.tag) {
        .macos, .linux => {
            // Enumerate PIDs with pgrep; fall back to pkill if unavailable.
            const out = runCmdStdout(alloc, io, &[_][]const u8{ "pgrep", "-x", "utmm" }) orelse {
                std.log.warn("[svc] pgrep -x utmm failed, falling back to pkill", .{});
                runCmdQuiet(alloc, io, &[_][]const u8{ "pkill", "-9", "-x", "utmm" });
                return;
            };
            defer alloc.free(out);
            var killed: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |pid_str| {
                const pid = std.fmt.parseInt(u32, std.mem.trim(u8, pid_str, " \r"), 10) catch continue;
                if (pid == my_pid) {
                    std.log.debug("[svc] killAllUtmm: skipping own PID {d}", .{pid});
                    continue;
                }
                std.log.info("[svc] killAllUtmm: killing PID {d}", .{pid});
                _ = runCmdQuiet(alloc, io, &[_][]const u8{ "kill", "-9", pid_str });
                killed += 1;
            }
            if (killed > 0) {
                std.log.info("[svc] killAllUtmm: killed {d} process(es)", .{killed});
            }
        },
        .windows => {
            // Enumerate PIDs with tasklist; fall back to taskkill /im if unavailable.
            const out = runCmdStdout(alloc, io, &[_][]const u8{
                "tasklist", "/fi", "imagename eq utmm.exe", "/fo", "csv", "/nh",
            }) orelse {
                std.log.warn("[svc] tasklist failed, falling back to taskkill /im", .{});
                runCmdQuiet(alloc, io, &[_][]const u8{ "taskkill", "/f", "/im", "utmm.exe" });
                return;
            };
            defer alloc.free(out);
            var killed: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r");
                if (trimmed.len < 2) continue;
                // CSV format: "utmm.exe","1234","Console","1","12,345 K"
                var csv_iter = std.mem.splitScalar(u8, trimmed, ',');
                _ = csv_iter.next(); // skip image name
                const pid_field = csv_iter.next() orelse continue;
                const pid_str = std.mem.trim(u8, pid_field, " \"\r");
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;
                if (pid == my_pid) {
                    std.log.debug("[svc] killAllUtmm: skipping own PID {d}", .{pid});
                    continue;
                }
                std.log.info("[svc] killAllUtmm: killing PID {d}", .{pid});
                _ = runCmdQuiet(alloc, io, &[_][]const u8{ "taskkill", "/f", "/pid", pid_str });
                killed += 1;
            }
            if (killed > 0) {
                std.log.info("[svc] killAllUtmm: killed {d} process(es)", .{killed});
            }
        },
        else => {},
    }
}

/// Count utmm processes other than our own PID.
/// Returns 0 if no other utmm processes are running.
fn countOtherUtmmProcesses(alloc: std.mem.Allocator, io: std.Io, my_pid: u32) !usize {
    switch (builtin.os.tag) {
        .macos, .linux => {
            const out = runCmdStdout(alloc, io, &[_][]const u8{ "pgrep", "-x", "utmm" }) orelse return 0;
            defer alloc.free(out);
            var count: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |pid_str| {
                const pid = std.fmt.parseInt(u32, std.mem.trim(u8, pid_str, " \r"), 10) catch continue;
                if (pid != my_pid) count += 1;
            }
            return count;
        },
        .windows => {
            const out = runCmdStdout(alloc, io, &[_][]const u8{
                "tasklist", "/fi", "imagename eq utmm.exe", "/fo", "csv", "/nh",
            }) orelse return 0;
            defer alloc.free(out);
            var count: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r");
                if (trimmed.len < 2) continue;
                var csv_iter = std.mem.splitScalar(u8, trimmed, ',');
                _ = csv_iter.next(); // skip image name
                const pid_field = csv_iter.next() orelse continue;
                const pid_str = std.mem.trim(u8, pid_field, " \"\r");
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;
                if (pid != my_pid) count += 1;
            }
            return count;
        },
        else => return 0,
    }
}

/// Wait up to `timeout_ms` for all other utmm processes to exit.
/// Returns true if no other utmm processes remain, false on timeout.
/// Placed between stop() and killAllUtmm() so selfCopy has a clean
/// filesystem — prevents "Text file busy" on Linux (Finding 135).
fn waitForProcessExit(io: std.Io, alloc: std.mem.Allocator, timeout_ms: u64) bool {
    const my_pid = getOwnPid();
    const poll_interval_ms: u64 = 100;
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        const remaining = countOtherUtmmProcesses(alloc, io, my_pid) catch |err| {
            std.log.debug("[svc] countOtherUtmmProcesses error: {} (continuing wait)", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch return false;
            elapsed += poll_interval_ms;
            continue;
        };

        if (remaining == 0) {
            std.log.info("[svc] all other utmm processes exited after {d}ms", .{elapsed});
            return true;
        }

        std.log.info("[svc] waiting for {d} other utmm process(es) to exit... ({d}ms elapsed)", .{ remaining, elapsed });
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch return false;
        elapsed += poll_interval_ms;
    }

    std.log.warn("[svc] timeout after {d}ms — proceeding with killAllUtmm", .{elapsed});
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// Binary type validation — prevent cross-platform binary overwrite
// ═══════════════════════════════════════════════════════════════════════════

/// Binary magic numbers for platform detection.
const MAGIC_ELF = [4]u8{ 0x7f, 'E', 'L', 'F' };
const MAGIC_MACHO64 = [4]u8{ 0xcf, 0xfa, 0xed, 0xfe }; // 64-bit LE
const MAGIC_MACHO32 = [4]u8{ 0xce, 0xfa, 0xed, 0xfe }; // 32-bit LE
const MAGIC_PE = [2]u8{ 'M', 'Z' };

/// Return a human-readable description of the binary format detected in `head`.
fn describeBinary(head: []const u8) []const u8 {
    if (head.len >= 2 and std.mem.eql(u8, head[0..2], &MAGIC_PE)) return "PE (Windows)";
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], &MAGIC_ELF)) return "ELF (Linux)";
    if (head.len >= 4 and (std.mem.eql(u8, head[0..4], &MAGIC_MACHO64) or
        std.mem.eql(u8, head[0..4], &MAGIC_MACHO32))) return "Mach-O (macOS)";
    return "unknown format";
}

/// Read first 4 bytes of a binary and verify the magic matches the current platform.
/// Call before selfCopy to prevent accidental cross-platform binary overwrite
/// (e.g. deploying an ELF binary to a macOS host).
fn validateBinaryType(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(io, path, .{ .mode = .read_only }) catch |err| {
        fail.err("validateBinary/open", err);
    };
    defer f.close(io);

    var head: [4]u8 = [_]u8{0} ** 4;
    var read_buf: [256]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    const n = reader.interface.readSliceShort(&head) catch |err| {
        fail.err("validateBinary/read", err);
    };

    if (n < 4) {
        fail.msg("validateBinary", "file too small ({d} bytes) to be a valid binary", .{n});
    }

    switch (builtin.os.tag) {
        .linux => {
            if (!std.mem.eql(u8, &head, &MAGIC_ELF)) {
                fail.msg("validateBinary", "expected ELF (Linux) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        .macos => {
            if (!std.mem.eql(u8, &head, &MAGIC_MACHO64) and
                !std.mem.eql(u8, &head, &MAGIC_MACHO32))
            {
                fail.msg("validateBinary", "expected Mach-O (macOS) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        .windows => {
            if (!std.mem.eql(u8, head[0..2], &MAGIC_PE)) {
                fail.msg("validateBinary", "expected PE (Windows) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        else => {}, // Unknown platform — skip check
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Self-copy: copy current binary to canonical path
// ═══════════════════════════════════════════════════════════════════════════

/// Copy the current process binary to the canonical install path.
/// Uses tmp file + rename for atomic replacement.
/// Validates binary magic before copying to prevent cross-platform mistakes.
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

    // Validate binary matches current platform before copying
    validateBinaryType(io, self_path) catch |err| {
        fail.err("selfCopy/binary-check", err);
    };

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
            // macOS: copyFile destroys the ad-hoc code signature.
            // Re-sign so launchd doesn't kill the process on next bootstrap.
            if (builtin.os.tag == .macos) {
                if (!runCmd(alloc, io, &[_][]const u8{ "codesign", "--force", "--sign", "-", dest })) {
                    std.log.warn("[svc] selfCopy: codesign re-sign failed — ad-hoc signature may be missing", .{});
                }
            }
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
    writer.interface.flush() catch |err| {
        std.log.warn("[svc] copyFile flush failed: {}", .{err});
    };

    // fsync to ensure data is on disk before rename
    dst.sync(io) catch |err| {
        std.log.warn("[svc] copyFile sync failed: {}", .{err});
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Core operations: forceInstall / ensure
// ═══════════════════════════════════════════════════════════════════════════

/// Copy platform-specific deployment binaries from the source exe directory
/// to the canonical install directory (serve-dir). Only called for Host mode —
/// these binaries are served to Guests for auto-upgrade.
///
/// Best-effort: missing source files are skipped with a warning.
/// Skips the source binary itself (the one we just selfCopy'd).
fn copySiblingBinariesToServeDir(io: std.Io, alloc: std.mem.Allocator, src_dir: []const u8) void {
    const dst_dir = canonicalDir();

    // If source and destination are the same directory, nothing to do.
    if (std.mem.eql(u8, src_dir, dst_dir)) {
        std.log.info("[svc] Platform binaries already in serve-dir, skipping copy.", .{});
        return;
    }

    var src_dir_handle = std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch |err| {
        std.log.warn("[svc] Cannot open source dir {s}: {} — skipping platform binary copy", .{ src_dir, err });
        return;
    };
    defer src_dir_handle.close(io);

    var iter = src_dir_handle.iterate();
    var copied: usize = 0;

    while (true) {
        const entry = iter.next(io) catch {
            std.log.warn("[svc] Failed to iterate source dir", .{});
            break;
        } orelse break;
        const name = entry.name;
        // Match platform binary files: utmm-* or utmm*.exe
        if (!std.mem.startsWith(u8, name, "utmm-") and !(std.mem.startsWith(u8, name, "utmm") and std.mem.endsWith(u8, name, ".exe"))) {
            continue;
        }
        // Skip the main binary (utmm or utmm.exe)
        if (std.mem.eql(u8, name, "utmm") or std.mem.eql(u8, name, "utmm.exe")) continue;

        const src_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, name }) catch continue;
        defer alloc.free(src_path);
        const dst_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, name }) catch continue;
        defer alloc.free(dst_path);

        copyFile(io, alloc, src_path, dst_path, builtin.os.tag != .windows) catch |err| {
            std.log.warn("[svc] Failed to copy {s}: {}", .{name, err});
            continue;
        };
        std.log.info("[svc] Copied {s} to serve-dir", .{name});
        copied += 1;
    }

    if (copied > 0) {
        std.log.info("[svc] Copied {d} platform binaries to serve-dir", .{copied});
    } else {
        std.log.warn("[svc] No platform binaries found in source directory {s} — Host will not serve upgrades.", .{src_dir});
    }
}

/// Force install — unconditional overwrite.
/// Stops any running service, kills all utmm processes, copies self to
/// canonical path, registers service config, and starts the service.
/// Fail-fast: any unexpected error calls fail() and does not return.
/// Force-install the service (public entry point, acquires singleton lock).
/// Called from main.zig --install path.
pub fn forceInstall(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    lock.acquire(io, alloc) catch |err| {
        fail.err("forceInstall/lock", err);
    };
    defer lock.release(io);
    forceInstallInternal(io, alloc, role, extra_args);
}

/// Force-install without acquiring the lock (caller must hold it).
fn forceInstallInternal(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName(role);
    const dest_path = canonicalPath();
    std.log.info("[svc] force installing {s}...", .{name});

    // 1. Stop any running service (ignore errors — may not be installed)
    stop(io, alloc, role) catch |err| {
        std.log.warn("[svc] stop before install: {} (continuing)", .{err});
    };

    // 1.5. Wait for old processes to fully exit before touching the binary.
    // On Linux, systemctl stop may return before the process has released
    // its file descriptors, causing selfCopy to fail with "Text file busy".
    // 5-second timeout covers the typical case; killAllUtmm handles stragglers.
    _ = waitForProcessExit(io, alloc, 5000);

    // 2. Kill any lingering utmm processes (now PID-aware; excludes self)
    killAllUtmm(io, alloc) catch |err| {
        std.log.warn("[svc] forceInstall killAllUtmm failed: {}", .{err});
    };

    // 3. Copy self to canonical path
    selfCopy(io, alloc) catch |err| {
        fail.err("forceInstall/selfCopy", err);
    };

    // 3.5. Host mode: copy platform binaries + ver.txt to serve-dir
    // so Guests can auto-upgrade to the correct version.
    if (role == .host) {
        var src_buf: [4096]u8 = undefined;
        if (std.process.executablePath(io, &src_buf)) |src_len| {
            const src_dir = std.fs.path.dirname(src_buf[0..src_len]) orelse ".";
            copySiblingBinariesToServeDir(io, alloc, src_dir);
        } else |_| {
            std.log.warn("[svc] Cannot get exe path — platform binary copy skipped.", .{});
        }
    }

    // 4. Install/overwrite service configuration.
    // If this fails, remove the binary we just copied so the system isn't
    // left in a state with a binary but no service.
    install(io, alloc, role, extra_args) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, dest_path) catch |rm_err| {
            std.log.warn("[svc] cleanup binary after install failure: {}", .{rm_err});
        };
        fail.err("forceInstall/install", err);
    };

    // 5. Start service.
    // Don't rollback on failure — binary and service config are already in
    // place. System-level recovery (Restart=on-failure, KeepAlive, reboot,
    // or manual intervention) can bring the service back. Deleting everything
    // leaves the VM unreachable with no recovery path — especially critical
    // for auto-upgrade where the old Guest process was already killed.
    start(io, alloc, role) catch |err| {
        std.log.err("[svc] start failed for {s}: {} — binary and config preserved, not rolling back", .{ name, err });
        fail.err("forceInstall/start", err);
    };

    std.log.info("[svc] {s} installed and running", .{name});
}

/// Ensure the service is installed and running.
/// If already running: log and return.
/// If not running: acquire singleton lock, then call forceInstallInternal.
pub fn ensure(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName(role);
    if (isRunning(io, alloc, role)) {
        std.log.info("[svc] {s} service already running", .{name});
        std.debug.print("utmm {s} service is running.\n", .{if (role == .host) "host" else "guest"});
        return;
    }
    std.log.info("[svc] {s} service not running — acquiring lock...", .{name});
    lock.acquire(io, alloc) catch |err| {
        fail.err("ensure/lock", err);
    };
    defer lock.release(io);
    forceInstallInternal(io, alloc, role, extra_args);
}

// ═══════════════════════════════════════════════════════════════════════════
// macOS retry counter — prevents infinite restart loops
// ═══════════════════════════════════════════════════════════════════════════

/// Check restart count on macOS. If we've restarted >= 3 times within a
/// short window, exit(0) so launchd stops restarting us.
///
/// Purpose: prevent infinite crash loops (service crashes on start →
/// launchd restarts → crashes again → …). The counter is scoped to a time
/// window: if the counter file is older than 120 seconds, the service
/// ran successfully for a while (or was killed intentionally — e.g.
/// upgrade, kickstart), so the counter resets to 1.
///
/// Call resetRetryCounter() after the service fully initializes (mesh up,
/// HTTP serving) to clear hot-restart state.
pub fn checkRetryLimit(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) void {
    if (builtin.os.tag != .macos) return;

    const retry_path = retryCounterPath(alloc, role) catch return;
    defer alloc.free(retry_path);

    var count: u32 = 0;
    var should_reset: bool = false;

    // Read existing counter with time-window check
    if (std.Io.Dir.cwd().statFile(io, retry_path, .{})) |st| {
        // If the counter file is older than 120 seconds, the previous run
        // ran successfully for a meaningful interval — this isn't a crash
        // loop. Reset the count so intentional restarts (upgrade, testing)
        // aren't penalized.
        const now = std.Io.Timestamp.now(io, .awake);
        const age_ns: i96 = now.nanoseconds - st.mtime.nanoseconds;
        if (age_ns > 120 * std.time.ns_per_s) {
            should_reset = true;
        }
        if (std.Io.Dir.cwd().readFileAlloc(io, retry_path, alloc, std.Io.Limit.limited(1024))) |content| {
            defer alloc.free(content);
            count = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n\r"), 10) catch 0;
        } else |_| {}
    } else |_| {}

    if (should_reset) {
        count = 0;
        std.log.info("[svc] retry counter stale (>{d}s), resetting", .{120});
    }

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

/// Windows only: check for a pending upgrade (.new file) from a previous
/// auto-upgrade attempt. If found, replace the running binary and restart.
/// Returns true if upgrade was applied (caller should exit), false otherwise.
pub fn checkPendingUpgradeWindows(io: std.Io, alloc: std.mem.Allocator) bool {
    if (builtin.os.tag != .windows) return false;

    const exe_path = canonicalPath();
    const new_path = std.fmt.allocPrint(alloc, "{s}.new", .{exe_path}) catch {
        std.log.err("[svc] allocPrint for upgrade path failed", .{});
        return false;
    };
    defer alloc.free(new_path);

    if (std.Io.Dir.cwd().statFile(io, new_path, .{})) |_| {
        std.log.info("[svc] pending upgrade found at {s}", .{new_path});
    } else |_| {
        return false;
    }

    // Delete old .exe (file is memory-mapped, directory entry can be replaced)
    std.Io.Dir.cwd().deleteFile(io, exe_path) catch |err| {
        std.log.err("[svc] cannot delete old .exe: {} — will retry next restart", .{err});
        std.process.exit(42);
    };

    // Rename .new → .exe
    std.Io.Dir.cwd().rename(new_path, std.Io.Dir.cwd(), exe_path, io) catch |err| {
        std.log.err("[svc] upgrade rename failed: {}", .{err});
        std.process.exit(42);
    };

    std.log.info("[svc] upgrade finalized. restarting...", .{});
    std.process.exit(0);
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

const MAX_SVC_NAME_UTF16 = 64; // "UTM-Monitor-Guest" = 17 chars + null = 18 u16

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
    var svc_name_utf16: [MAX_SVC_NAME_UTF16]u16 = [_]u16{0} ** MAX_SVC_NAME_UTF16;
};

fn svcCtrlHandler(dwControl: u32, _: u32, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) u32 {
    if (dwControl == SERVICE_CONTROL_STOP) {
        // Immediate hard-stop: report STOPPED to SCM and exit the process.
        // Graceful shutdown via shutdown_flag + thread join is unreliable on
        // Windows — the ptyReadLoop blocks in ReadFile which ARM64 AFD
        // cannot cancel, and the mesh timer self-wake has timing races.
        // Tracked as deferred: graceful Windows service shutdown (Finding 103).
        var status = std.mem.zeroes(SERVICE_STATUS);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_STOPPED;
        status.dwControlsAccepted = 0;
        _ = SetServiceStatus(SvcGlobals.status_handle, &status);

        std.process.exit(0);
    }
    return 0;
}

fn svcMain(_: u32, _: [*]?[*:0]const u16) callconv(.winapi) void {
    const h = RegisterServiceCtrlHandlerExW(@ptrCast(&SvcGlobals.svc_name_utf16), svcCtrlHandler, null);
    SvcGlobals.status_handle = h;

    if (h) |handle| {
        var status = std.mem.zeroes(SERVICE_STATUS);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_RUNNING;
        status.dwControlsAccepted = SERVICE_ACCEPT_STOP;
        _ = SetServiceStatus(handle, &status);
    }

    const host_mod = @import("host.zig");
    const broadcast_mod = @import("broadcast.zig");

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
        broadcast_mod.guestRunWithIo(SvcGlobals.io, SvcGlobals.gpa, .{
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

    // Build correct UTF-16 service name from role
    const svc_name_utf8 = svcName(if (is_host) .host else .guest);
    var i: usize = 0;
    for (svc_name_utf8) |c| {
        if (i >= MAX_SVC_NAME_UTF16 - 1) break;
        SvcGlobals.svc_name_utf16[i] = @intCast(c);
        i += 1;
    }
    SvcGlobals.svc_name_utf16[i] = 0;

    var svc_table = [2]SERVICE_TABLE_ENTRYW{
        .{ .lpServiceName = @ptrCast(&SvcGlobals.svc_name_utf16), .lpServiceProc = svcMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (StartServiceCtrlDispatcherW(&svc_table) == 0) {
        std.debug.print("[svc] StartServiceCtrlDispatcher failed (error: {})\n", .{windows.GetLastError()});
        return error.ServiceDispatchFailed;
    }
}

// ========== Tests ==========

test "describeBinary - ELF" {
    const head = [_]u8{ 0x7f, 'E', 'L', 'F' };
    try std.testing.expectEqualStrings("ELF (Linux)", describeBinary(&head));
}

test "describeBinary - Mach-O 64-bit" {
    const head = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe };
    try std.testing.expectEqualStrings("Mach-O (macOS)", describeBinary(&head));
}

test "describeBinary - Mach-O 32-bit" {
    const head = [_]u8{ 0xce, 0xfa, 0xed, 0xfe };
    try std.testing.expectEqualStrings("Mach-O (macOS)", describeBinary(&head));
}

test "describeBinary - PE" {
    const head = [_]u8{ 'M', 'Z', 0, 0 };
    try std.testing.expectEqualStrings("PE (Windows)", describeBinary(&head));
}

test "describeBinary - unknown" {
    const head = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "describeBinary - short slice" {
    const head = [_]u8{'M'};
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "describeBinary - empty slice" {
    const head = [_]u8{};
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "magic constants - ELF" {
    try std.testing.expectEqual(@as(u8, 0x7f), MAGIC_ELF[0]);
    try std.testing.expectEqual(@as(u8, 'E'), MAGIC_ELF[1]);
    try std.testing.expectEqual(@as(u8, 'L'), MAGIC_ELF[2]);
    try std.testing.expectEqual(@as(u8, 'F'), MAGIC_ELF[3]);
}

test "magic constants - Mach-O 64 LE" {
    // 0xFEEDFACF in little-endian
    try std.testing.expectEqual(@as(u8, 0xcf), MAGIC_MACHO64[0]);
    try std.testing.expectEqual(@as(u8, 0xfa), MAGIC_MACHO64[1]);
    try std.testing.expectEqual(@as(u8, 0xed), MAGIC_MACHO64[2]);
    try std.testing.expectEqual(@as(u8, 0xfe), MAGIC_MACHO64[3]);
}

test "magic constants - PE" {
    try std.testing.expectEqual(@as(u8, 'M'), MAGIC_PE[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), MAGIC_PE[1]);
}
