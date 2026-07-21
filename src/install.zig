//! System service installation and auto-start script generation
//! Supports three platforms: macOS (launchd), Linux (systemd), Windows (sc)
//!
//! Design: --install/--uninstall are the SINGLE source of truth for service
//! management on ALL platforms. Install scripts (install.sh/install.bat) only
//! create the runtime environment (download, mkdir, symlink) and delegate to
//! --install for service creation.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

/// Supported operating system platforms
pub const Platform = enum {
    linux,
    macos,
    windows,

    pub fn detect() Platform {
        return switch (@import("builtin").os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .linux, // default linux
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

/// Generate auto-start script/config
pub fn genInit(platform: Platform) []const u8 {
    return switch (platform) {
        .macos =>
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.utmm</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/utmm/utmm</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <true/>
        \\    <key>StandardOutPath</key>
        \\    <string>/var/log/utmm.log</string>
        \\</dict>
        \\</plist>
        \\<!-- Install to: /Library/LaunchDaemons/com.utmm.plist -->
        \\<!-- Load with: sudo launchctl load /Library/LaunchDaemons/com.utmm.plist -->
        ,
        .linux =>
        \\[Unit]
        \\Description=UTM Monitor Guest Service
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart=/opt/utmm/utmm
        \\Restart=always
        \\RestartSec=5
        \\StandardOutput=journal
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        ,
        .windows =>
        \\:: UTM Monitor auto-start service
        \\:: Install with: sc create "UTM-Monitor" binPath= "\"C:\opt\utmm\utmm.exe\" --svc" start= auto
        \\::              sc start "UTM-Monitor"
        \\:: Remove with:  sc stop "UTM-Monitor" & sc delete "UTM-Monitor"
        ,
    };
}

/// Self-install as system service (auto-detect platform).
/// hostname_override: if provided, baked into the service command line so
/// the process starts with the correct --hostname on every boot.
/// user_mode: if true, install as user-level auto-start (LaunchAgent / user systemd /
///   Task Scheduler) for the foreground guest. Otherwise install as system-level
///   daemon (LaunchDaemon / system systemd / Windows service).
pub fn installSelf(
    io: std.Io,
    allocator: std.mem.Allocator,
    is_host: bool,
    hostname_override: ?[]const u8,
    user_mode: bool,
) !void {
    const platform = Platform.detect();
    std.debug.print("[install] detected platform: {s}, mode: {s}\n", .{ platform.asStr(), if (is_host) "host" else "guest" });

    // Get current executable path to determine install directory.
    // IMPORTANT: the OS resolves symlinks, so we extract the directory from the
    // resolved path and construct the CANONICAL symlink path. Auto-upgrade
    // replaces the symlink target, so the service MUST run via the symlink
    // (e.g. /opt/utmm/utmm), NOT the architecture-specific binary name
    // (e.g. /opt/utmm/utmm-aarch64-linux).
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];
    const exe_dir = std.fs.path.dirname(exe_path) orelse "/opt/utmm";

    // Canonical service binary path (the symlink, which auto-upgrade replaces)
    const svc_exe: []const u8 = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}/utmm.exe", .{exe_dir})
    else
        try std.fmt.allocPrint(allocator, "{s}/utmm", .{exe_dir});
    defer allocator.free(svc_exe);

    // ── User-level foreground guest install (desktop shortcut) ──────────
    if (user_mode) {
        // Default mode (no flags) = foreground guest: stop service, run, restart on exit.
        // Just pass --hostname if we have a custom one to override auto-detection.
        const fg_cmd: []const u8 = if (hostname_override) |h|
            try std.fmt.allocPrint(allocator, "{s} --hostname {s}", .{ svc_exe, h })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{svc_exe});
        defer allocator.free(fg_cmd);

        switch (platform) {
            .macos => {
                // Foreground guest is manual, on-demand — no auto-start service.
                // Just create a desktop shortcut to open the guest in Terminal.
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/Users/root";

                // Clean up any leftover LaunchAgent from previous versions
                {
                    const agent_dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
                    defer allocator.free(agent_dir);
                    const plist_path = try std.fmt.allocPrint(allocator, "{s}/com.utmm-agent.plist", .{agent_dir});
                    defer allocator.free(plist_path);
                    const uid: u32 = if (builtin.os.tag != .windows) std.c.getuid() else 0;
                    const gui_target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
                    defer allocator.free(gui_target);
                    if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", gui_target, plist_path } })) |_| {} else |_| {}
                    std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
                }

                // Create desktop shortcut (double-click to launch guest in Terminal)
                {
                    const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
                    defer allocator.free(desktop);
                    const cmd_path = try std.fmt.allocPrint(allocator, "{s}/UTMM.command", .{desktop});
                    defer allocator.free(cmd_path);
                    // Also clean up old names from previous versions
                    const old_agent = try std.fmt.allocPrint(allocator, "{s}/UTMM-Agent.command", .{desktop});
                    defer allocator.free(old_agent);
                    std.Io.Dir.cwd().deleteFile(io, old_agent) catch {};
                    const old_guest = try std.fmt.allocPrint(allocator, "{s}/UTMM-Guest.command", .{desktop});
                    defer allocator.free(old_guest);
                    std.Io.Dir.cwd().deleteFile(io, old_guest) catch {};

                    std.Io.Dir.cwd().createDir(io, desktop, @enumFromInt(0o755)) catch {};
                    std.Io.Dir.cwd().deleteFile(io, cmd_path) catch {};
                    const cmd_file = try std.Io.Dir.cwd().createFile(io, cmd_path, .{ .permissions = @enumFromInt(0o755) });
                    defer cmd_file.close(io);
                    var cwb: [2048]u8 = undefined;
                    var cw = cmd_file.writer(io, &cwb);
                    try cw.interface.print(
                        \\#!/bin/bash
                        \\# UTMM Guest — foreground launcher (GUI-aware exec forwarding)
                        \\cd "$(dirname "$0")" || true
                        \\exec {s}
                    , .{fg_cmd});
                    try cw.interface.flush();
                    std.debug.print("[install] macOS: guest desktop shortcut created: {s}\n", .{cmd_path});
                }
            },
            .linux => {
                // Foreground guest is manual, on-demand — no auto-start service.
                // Just create a desktop shortcut to open the guest in a terminal.
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/root";

                // Clean up any leftover user systemd from previous versions
                {
                    const service_path = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/utmm-agent.service", .{home});
                    defer allocator.free(service_path);
                    if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "stop", "utmm-agent.service" } })) |_| {} else |_| {}
                    if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "disable", "utmm-agent.service" } })) |_| {} else |_| {}
                    std.Io.Dir.cwd().deleteFile(io, service_path) catch {};
                    if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "daemon-reload" } })) |_| {} else |_| {}
                }

                // Create desktop shortcut (double-click to launch guest in terminal)
                {
                    const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
                    defer allocator.free(desktop);
                    const dt_path = try std.fmt.allocPrint(allocator, "{s}/utmm.desktop", .{desktop});
                    defer allocator.free(dt_path);
                    // Also clean up old name from versions before v0.1.24
                    const old_dt_path = try std.fmt.allocPrint(allocator, "{s}/utmm-agent.desktop", .{desktop});
                    defer allocator.free(old_dt_path);
                    std.Io.Dir.cwd().deleteFile(io, old_dt_path) catch {};
                    const old_guest_dt = try std.fmt.allocPrint(allocator, "{s}/utmm-guest.desktop", .{desktop});
                    defer allocator.free(old_guest_dt);
                    std.Io.Dir.cwd().deleteFile(io, old_guest_dt) catch {};

                    std.Io.Dir.cwd().createDir(io, desktop, @enumFromInt(0o755)) catch {};
                    std.Io.Dir.cwd().deleteFile(io, dt_path) catch {};
                    const dt_file = try std.Io.Dir.cwd().createFile(io, dt_path, .{ .permissions = @enumFromInt(0o755) });
                    defer dt_file.close(io);
                    var dwb: [2048]u8 = undefined;
                    var dw = dt_file.writer(io, &dwb);
                    try dw.interface.print(
                        \\[Desktop Entry]
                        \\Type=Application
                        \\Name=UTMM
                        \\Comment=UTMM Monitor — foreground guest
                        \\Exec=bash -c "exec {s}"
                        \\Terminal=true
                        \\Categories=Utility;
                    , .{fg_cmd});
                    try dw.interface.flush();
                    std.debug.print("[install] Linux: guest desktop shortcut created: {s}\n", .{dt_path});
                }
            },
            .windows => {
                // Foreground guest is a manual, on-demand tool — no auto-start.
                // Just create a desktop shortcut that opens the guest terminal window.
                {
                    const desktop = "C:\\Users\\Public\\Desktop";
                    const bat_path = try std.fmt.allocPrint(allocator, "{s}\\UTMM.bat", .{desktop});
                    defer allocator.free(bat_path);
                    // Also clean up old name from versions before v0.1.24
                    const old_bat_path = try std.fmt.allocPrint(allocator, "{s}\\UTMM-Agent.bat", .{desktop});
                    defer allocator.free(old_bat_path);
                    std.Io.Dir.cwd().deleteFile(io, old_bat_path) catch {};

                    std.Io.Dir.cwd().deleteFile(io, bat_path) catch {};
                    const bat_file = try std.Io.Dir.cwd().createFile(io, bat_path, .{ .permissions = @enumFromInt(0o644) });
                    defer bat_file.close(io);
                    var bwb: [2048]u8 = undefined;
                    var bw = bat_file.writer(io, &bwb);
                    try bw.interface.print(
                        \\@echo off
                        \\chcp 65001 > nul
                        \\{s}
                    , .{fg_cmd});
                    try bw.interface.flush();
                    std.debug.print("[install] Windows: guest desktop shortcut created: {s}\n", .{bat_path});
                }
            },
        }
        std.debug.print("[install] guest installation complete!\n", .{});
        return;
    }

    // ── System-level service install (daemon) ────────────────────────────
    switch (platform) {
        .macos => {
            const label: []const u8 = if (is_host) "com.utmm.host" else "com.utmm.guest";
            const plist_dir = "/Library/LaunchDaemons";
            const plist_path = try std.fmt.allocPrint(allocator, "/Library/LaunchDaemons/{s}.plist", .{label});
            defer allocator.free(plist_path);

            // Create LaunchDaemons directory if needed
            std.Io.Dir.cwd().createDir(io, plist_dir, @enumFromInt(0o755)) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            // Unload existing service first (ignore errors)
            if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", "system", plist_path } })) |_| {} else |_| {}

            // Write plist
            std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            const file = try std.Io.Dir.cwd().createFile(io, plist_path, .{ .permissions = @enumFromInt(0o644) });
            defer file.close(io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(io, &write_buf);

            const log_path: []const u8 = if (is_host) "/var/log/utmm-host.log" else "/var/log/utmm-guest.log";

            if (is_host) {
                try writer.interface.print(
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>Label</key>
                    \\    <string>{s}</string>
                    \\    <key>ProgramArguments</key>
                    \\    <array>
                    \\        <string>{s}</string>
                    \\        <string>--host</string>
                    \\    </array>
                    \\    <key>RunAtLoad</key>
                    \\    <true/>
                    \\    <key>KeepAlive</key>
                    \\    <true/>
                    \\    <key>StandardOutPath</key>
                    \\    <string>{s}</string>
                    \\</dict>
                    \\</plist>
                , .{ label, svc_exe, log_path });
            } else {
                try writer.interface.print(
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>Label</key>
                    \\    <string>{s}</string>
                    \\    <key>ProgramArguments</key>
                    \\    <array>
                    \\        <string>{s}</string>
                    \\        <string>--svc</string>
                , .{ label, svc_exe });
                try writer.interface.flush();
                if (hostname_override) |h| {
                    try writer.interface.print("        <string>--hostname</string>\n        <string>{s}</string>\n", .{h});
                }
                try writer.interface.print(
                    \\    </array>
                    \\    <key>RunAtLoad</key>
                    \\    <true/>
                    \\    <key>KeepAlive</key>
                    \\    <true/>
                    \\    <key>StandardOutPath</key>
                    \\    <string>{s}</string>
                    \\</dict>
                    \\</plist>
                , .{log_path});
            }
            try writer.interface.flush();

            // Bootstrap the service (launchctl load is deprecated since macOS 10.10)
            if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootstrap", "system", plist_path } })) |_| {
                std.debug.print("[install] macOS: {s} plist bootstrapped: {s}\n", .{ label, plist_path });
            } else |_| {
                std.debug.print("[install] macOS: plist written to {s}\n", .{plist_path});
                std.debug.print("[install] run: sudo launchctl bootstrap system {s}\n", .{plist_path});
            }
        },
        .linux => {
            const svc_name: []const u8 = if (is_host) "utmm-host" else "utmm-guest";
            const service_path = try std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}.service", .{svc_name});
            defer allocator.free(service_path);

            const desc: []const u8 = if (is_host) "UTM Monitor Host Service" else "UTM Monitor Guest Service";
            const extra_args: []const u8 = if (is_host) " --host" else if (hostname_override) |h|
                try std.fmt.allocPrint(allocator, " --svc --hostname {s}", .{h})
            else
                " --svc";
            const content = try std.fmt.allocPrint(allocator,
                \\[Unit]
                \\Description={s}
                \\After=network.target
                \\
                \\[Service]
                \\Type=simple
                \\ExecStart={s}{s}
                \\WorkingDirectory={s}
                \\Restart=always
                \\RestartSec=5
                \\StandardOutput=journal
                \\
                \\[Install]
                \\WantedBy=multi-user.target
            , .{ desc, svc_exe, extra_args, exe_dir });
            defer allocator.free(content);

            std.Io.Dir.cwd().deleteFile(io, service_path) catch {};
            const file = try std.Io.Dir.cwd().createFile(io, service_path, .{ .permissions = @enumFromInt(0o644) });
            defer file.close(io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(io, &write_buf);
            try writer.interface.writeAll(content);
            try writer.interface.flush();

            std.debug.print("[install] Linux: systemd unit written to {s}\n", .{service_path});

            // Reload, enable, and start
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "daemon-reload" } })) |_| {} else |_| {}
            const full_name = try std.fmt.allocPrint(allocator, "{s}.service", .{svc_name});
            defer allocator.free(full_name);
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "enable", full_name } })) |_| {
                std.debug.print("[install] Linux: {s} enabled\n", .{svc_name});
            } else |_| {}
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "start", full_name } })) |_| {
                std.debug.print("[install] Linux: {s} started\n", .{svc_name});
            } else |_| {
                std.debug.print("[install] Linux: run manually: systemctl enable --now {s}\n", .{svc_name});
            }
        },
        .windows => {
            // Build binPath for sc create
            // sc has quirky syntax: "binPath= value" — the space after '=' is REQUIRED
            const svc_name: []const u8 = if (is_host) "UTM-Monitor-Host" else "UTM-Monitor-Guest";
            const extra_args: []const u8 = if (is_host) " --host" else if (hostname_override) |h|
                try std.fmt.allocPrint(allocator, " --hostname {s}", .{h})
            else
                "";

            const bin_path = try std.fmt.allocPrint(allocator, "\"{s}\" --svc{s}", .{ svc_exe, extra_args });
            defer allocator.free(bin_path);

            // Stop and delete existing service (ignore errors)
            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "stop", svc_name },
            })) |_| {} else |_| {}
            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "delete", svc_name },
            })) |_| {} else |_| {}

            // Create service: auto-start, runs in its own session (survives SSH disconnect)
            std.debug.print("[install] Windows: creating service '{s}'...\n", .{svc_name});
            std.debug.print("[install]   binPath= {s}\n", .{bin_path});

            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "create", svc_name, "binPath=", bin_path, "start=", "auto" },
            })) |r| {
                std.debug.print("[install] Windows: service created\n", .{});
                _ = r;
            } else |_| {
                std.debug.print("[install] Windows: failed to create service — create manually:\n", .{});
                std.debug.print("[install]   sc create \"{s}\" binPath= \"{s}\" start= auto\n", .{ svc_name, bin_path });
                return;
            }

            // Start the service immediately
            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "start", svc_name },
            })) |_| {
                std.debug.print("[install] Windows: {s} started\n", .{svc_name});
            } else |_| {
                std.debug.print("[install] Windows: start manually: sc start \"{s}\"\n", .{svc_name});
            }
        },
    }

    std.debug.print("[install] installation complete!\n", .{});
}

/// Uninstall system service (auto-detect platform)
/// user_mode: if true, uninstall the user-level agent instead of the system daemon.
pub fn uninstallSelf(io: std.Io, allocator: std.mem.Allocator, user_mode: bool) !void {
    const platform = Platform.detect();
    std.debug.print("[uninstall] detected platform: {s}, mode: {s}\n", .{ platform.asStr(), if (user_mode) "user-guest" else "system" });

    // ── User-level agent uninstall ──────────────────────────────────────
    if (user_mode) {
        switch (platform) {
            .macos => {
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/Users/root";

                // Clean up leftover LaunchAgent from previous versions
                const plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/com.utmm-agent.plist", .{home});
                defer allocator.free(plist_path);
                const uid: u32 = if (builtin.os.tag != .windows) std.c.getuid() else 0;
                const gui_target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
                defer allocator.free(gui_target);
                if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", gui_target, plist_path } })) |_| {} else |_| {}
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};

                // Remove desktop shortcuts (all historical names)
                for ([_][]const u8{ "UTMM-Agent.command", "UTMM-Guest.command", "UTMM.command" }) |name| {
                    const path = try std.fmt.allocPrint(allocator, "{s}/Desktop/{s}", .{ home, name });
                    defer allocator.free(path);
                    std.Io.Dir.cwd().deleteFile(io, path) catch {};
                }

                // Kill any running guest
                if (std.process.run(allocator, io, .{ .argv = &.{ "pkill", "-9", "-f", "utmm" } })) |_| {} else |_| {}

                std.debug.print("[uninstall] macOS: guest cleaned up\n", .{});
            },
            .linux => {
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/root";

                // Clean up leftover user systemd from previous versions
                const service_path = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/utmm-agent.service", .{home});
                defer allocator.free(service_path);
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "stop", "utmm-agent.service" } })) |_| {} else |_| {}
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "disable", "utmm-agent.service" } })) |_| {} else |_| {}
                std.Io.Dir.cwd().deleteFile(io, service_path) catch {};
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "daemon-reload" } })) |_| {} else |_| {}

                // Remove desktop shortcuts (all historical names)
                for ([_][]const u8{ "utmm-agent.desktop", "utmm-guest.desktop", "utmm.desktop" }) |name| {
                    const path = try std.fmt.allocPrint(allocator, "{s}/Desktop/{s}", .{ home, name });
                    defer allocator.free(path);
                    std.Io.Dir.cwd().deleteFile(io, path) catch {};
                }

                // Kill any running guest
                if (std.process.run(allocator, io, .{ .argv = &.{ "pkill", "-9", "-f", "utmm" } })) |_| {} else |_| {}

                std.debug.print("[uninstall] Linux: guest cleaned up\n", .{});
            },
            .windows => {
                // Clean up any leftover Task Scheduler from previous versions
                const task_name = "UTMM Agent";
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "schtasks", "/delete", "/tn", task_name, "/f" },
                })) |_| {} else |_| {}

                // Remove desktop shortcuts (both old and new names)
                const old_bat = "C:\\Users\\Public\\Desktop\\UTMM-Agent.bat";
                std.Io.Dir.cwd().deleteFile(io, old_bat) catch {};
                const new_bat = "C:\\Users\\Public\\Desktop\\UTMM.bat";
                std.Io.Dir.cwd().deleteFile(io, new_bat) catch {};

                // Kill any running guest
                if (std.process.run(allocator, io, .{ .argv = &.{ "taskkill", "/f", "/im", "utmm.exe" } })) |_| {} else |_| {}

                std.debug.print("[uninstall] Windows: guest cleaned up\n", .{});
            },
        }
        std.debug.print("[uninstall] guest uninstall complete!\n", .{});
        return;
    }

    switch (platform) {
        .macos => {
            // Unload and remove both old (com.utmm) and new (com.utmm.host / com.utmm.guest) plists
            const labels = [_][]const u8{ "com.utmm", "com.utmm.host", "com.utmm.guest" };
            for (labels) |label| {
                const plist_path = try std.fmt.allocPrint(allocator, "/Library/LaunchDaemons/{s}.plist", .{label});
                defer allocator.free(plist_path);
                if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", "system", plist_path } })) |_| {} else |_| {}
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
            std.debug.print("[uninstall] macOS: services unloaded, plists removed\n", .{});
        },
        .linux => {
            // Stop, disable, and remove both old (utmm) and new (utmm-host / utmm-guest) units
            const svc_names = [_][]const u8{ "utmm", "utmm-host", "utmm-guest" };
            for (svc_names) |name| {
                const full_name = try std.fmt.allocPrint(allocator, "{s}.service", .{name});
                defer allocator.free(full_name);
                const unit_path = try std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}", .{full_name});
                defer allocator.free(unit_path);
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "stop", full_name } })) |_| {} else |_| {}
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "disable", full_name } })) |_| {} else |_| {}
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "daemon-reload" } })) |_| {} else |_| {}
            std.debug.print("[uninstall] Linux: services stopped, unit files removed\n", .{});
        },
        .windows => {
            // Stop and delete both old (UTM-Monitor) and new (UTM-Monitor-Host / UTM-Monitor-Guest) services
            const svc_names = [_][]const u8{ "UTM-Monitor", "UTM-Monitor-Host", "UTM-Monitor-Guest" };
            for (svc_names) |svc_name| {
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "sc", "stop", svc_name },
                })) |_| {} else |_| {}
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "sc", "delete", svc_name },
                })) |_| {} else |_| {}
            }
            std.debug.print("[uninstall] Windows: services stopped and removed\n", .{});
        },
    }

    // Kill running processes AFTER removing config files (best-effort, may kill self)
    killRunning(io, allocator, platform) catch {};

    std.debug.print("[uninstall] uninstall complete!\n", .{});
}

/// Kill running utmm processes (best-effort)
fn killRunning(io: std.Io, allocator: std.mem.Allocator, platform: Platform) !void {
    switch (platform) {
        .macos, .linux => {
            if (std.process.run(allocator, io, .{ .argv = &.{ "pkill", "-9", "utmm" } })) |_| {} else |_| {}
        },
        .windows => {
            if (std.process.run(allocator, io, .{ .argv = &.{ "taskkill", "/f", "/im", "utmm.exe" } })) |_| {} else |_| {}
        },
    }
}

test "Platform.detect" {
    _ = Platform.detect();
}

test "genInit - linux" {
    const script = genInit(.linux);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Unit]") != null);
}

test "genInit - macos" {
    const script = genInit(.macos);
    try std.testing.expect(std.mem.indexOf(u8, script, "com.utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "plist") != null);
}

test "genInit - windows" {
    const script = genInit(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "sc create") != null);
}

test "uninstallSelf - signature" { _ = uninstallSelf; }
