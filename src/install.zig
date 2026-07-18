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
///   Task Scheduler) for the --agent process. Otherwise install as system-level
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

    // ── User-level agent install ────────────────────────────────────────
    if (user_mode) {
        switch (platform) {
            .macos => {
                // Install as LaunchAgent (runs in user session with GUI access).
                // Uses osascript to open a Terminal window so the agent logs are visible.
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/Users/root";
                const agent_dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
                defer allocator.free(agent_dir);
                const plist_path = try std.fmt.allocPrint(allocator, "{s}/com.utmm-agent.plist", .{agent_dir});
                defer allocator.free(plist_path);

                // Create LaunchAgents directory if needed
                std.Io.Dir.cwd().createDir(io, agent_dir, @enumFromInt(0o755)) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };

                // Unload existing agent first (ignore errors)
                const uid = std.c.getuid();
                const gui_target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
                defer allocator.free(gui_target);
                if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", gui_target, plist_path } })) |_| {} else |_| {}

                // Write plist
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
                const file = try std.Io.Dir.cwd().createFile(io, plist_path, .{ .permissions = @enumFromInt(0o644) });
                defer file.close(io);
                var write_buf: [4096]u8 = undefined;
                var writer = file.writer(io, &write_buf);
                try writer.interface.print(
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>Label</key>
                    \\    <string>com.utmm-agent</string>
                    \\    <key>ProgramArguments</key>
                    \\    <array>
                    \\        <string>osascript</string>
                    \\        <string>-e</string>
                    \\        <string>tell app "Terminal" to do script "{s} --agent"</string>
                    \\    </array>
                    \\    <key>RunAtLoad</key>
                    \\    <true/>
                    \\    <key>KeepAlive</key>
                    \\    <true/>
                    \\</dict>
                    \\</plist>
                , .{svc_exe});
                try writer.interface.flush();

                // Load the agent immediately
                if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "load", plist_path } })) |_| {
                    std.debug.print("[install] macOS: agent plist written + loaded: {s}\n", .{plist_path});
                } else |_| {
                    std.debug.print("[install] macOS: agent plist written to {s}\n", .{plist_path});
                    std.debug.print("[install] run: launchctl load {s}\n", .{plist_path});
                }

                // Create desktop shortcut (double-click to install + launch agent)
                {
                    const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
                    defer allocator.free(desktop);
                    const cmd_path = try std.fmt.allocPrint(allocator, "{s}/UTM-Agent.command", .{desktop});
                    defer allocator.free(cmd_path);

                    std.Io.Dir.cwd().createDir(io, desktop, @enumFromInt(0o755)) catch {};
                    std.Io.Dir.cwd().deleteFile(io, cmd_path) catch {};
                    const cmd_file = try std.Io.Dir.cwd().createFile(io, cmd_path, .{ .permissions = @enumFromInt(0o755) });
                    defer cmd_file.close(io);
                    var cwb: [2048]u8 = undefined;
                    var cw = cmd_file.writer(io, &cwb);
                    try cw.interface.print(
                        \\#!/bin/bash
                        \\# UTM Agent — double-click to install & launch
                        \\cd "$(dirname "$0")" || true
                        \\echo "Installing UTM Agent..."
                        \\{s} --install --user
                        \\echo ""
                        \\echo "Starting UTM Agent..."
                        \\exec {s} --agent
                    , .{ svc_exe, svc_exe });
                    try cw.interface.flush();
                    std.debug.print("[install] macOS: desktop shortcut created: {s}\n", .{cmd_path});
                }
            },
            .linux => {
                // Install as user systemd service (runs in user session with GUI access).
                // Uses x-terminal-emulator to open a terminal window for visible agent logs.
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/root";
                const agent_dir = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user", .{home});
                defer allocator.free(agent_dir);
                const service_path = try std.fmt.allocPrint(allocator, "{s}/utmm-agent.service", .{agent_dir});
                defer allocator.free(service_path);

                // Create user systemd directory if needed
                std.Io.Dir.cwd().createDir(io, agent_dir, @enumFromInt(0o755)) catch |err| {
                    if (err != error.PathAlreadyExists and err != error.NotDir) {
                        // Try creating parent directories recursively
                        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
                        defer allocator.free(config_dir);
                        std.Io.Dir.cwd().createDir(io, config_dir, @enumFromInt(0o755)) catch |e| {
                            if (e != error.PathAlreadyExists) return e;
                        };
                        const systemd_dir = try std.fmt.allocPrint(allocator, "{s}/.config/systemd", .{home});
                        defer allocator.free(systemd_dir);
                        std.Io.Dir.cwd().createDir(io, systemd_dir, @enumFromInt(0o755)) catch |e2| {
                            if (e2 != error.PathAlreadyExists) return e2;
                        };
                        std.Io.Dir.cwd().createDir(io, agent_dir, @enumFromInt(0o755)) catch |e3| {
                            if (e3 != error.PathAlreadyExists) return e3;
                        };
                    }
                };

                const content = try std.fmt.allocPrint(allocator,
                    \\[Unit]
                    \\Description=UTM Monitor Agent (GUI-aware exec)
                    \\After=graphical-session.target
                    \\PartOf=graphical-session.target
                    \\
                    \\[Service]
                    \\Type=simple
                    \\ExecStart=/usr/bin/x-terminal-emulator -e "{s} --agent"
                    \\Restart=on-failure
                    \\RestartSec=5
                    \\
                    \\[Install]
                    \\WantedBy=default.target
                , .{svc_exe});
                defer allocator.free(content);

                std.Io.Dir.cwd().deleteFile(io, service_path) catch {};
                const file = try std.Io.Dir.cwd().createFile(io, service_path, .{ .permissions = @enumFromInt(0o644) });
                defer file.close(io);
                var write_buf: [4096]u8 = undefined;
                var writer = file.writer(io, &write_buf);
                try writer.interface.writeAll(content);
                try writer.interface.flush();

                // Reload user systemd and enable
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "daemon-reload" } })) |_| {} else |_| {}
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "enable", "utmm-agent.service" } })) |_| {
                    std.debug.print("[install] Linux: user agent service enabled\n", .{});
                } else |_| {}
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "start", "utmm-agent.service" } })) |_| {
                    std.debug.print("[install] Linux: user agent service started\n", .{});
                } else |_| {
                    std.debug.print("[install] Linux: run manually: systemctl --user enable --now utmm-agent\n", .{});
                }

                // Create desktop shortcut (double-click to install + launch agent)
                {
                    const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
                    defer allocator.free(desktop);
                    const dt_path = try std.fmt.allocPrint(allocator, "{s}/utmm-agent.desktop", .{desktop});
                    defer allocator.free(dt_path);

                    std.Io.Dir.cwd().createDir(io, desktop, @enumFromInt(0o755)) catch {};
                    std.Io.Dir.cwd().deleteFile(io, dt_path) catch {};
                    const dt_file = try std.Io.Dir.cwd().createFile(io, dt_path, .{ .permissions = @enumFromInt(0o755) });
                    defer dt_file.close(io);
                    var dwb: [2048]u8 = undefined;
                    var dw = dt_file.writer(io, &dwb);
                    try dw.interface.print(
                        \\[Desktop Entry]
                        \\Type=Application
                        \\Name=UTM Agent
                        \\Comment=UTM Monitor Agent — GUI-aware exec forwarding
                        \\Exec=bash -c "{s} --install --user; exec {s} --agent"
                        \\Terminal=true
                        \\Categories=Utility;
                    , .{ svc_exe, svc_exe });
                    try dw.interface.flush();
                    std.debug.print("[install] Linux: desktop shortcut created: {s}\n", .{dt_path});
                }
            },
            .windows => {
                // Install as user-level scheduled task (runs at logon with GUI access).
                // Uses `start "UTM Agent" cmd /k` to open a visible console window.
                const task_name = "UTM Agent";
                const task_cmd = try std.fmt.allocPrint(allocator, "cmd /c start \"UTM Agent\" cmd /k \"{s}\" --agent", .{svc_exe});
                defer allocator.free(task_cmd);

                // Delete existing task (ignore errors)
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "schtasks", "/delete", "/tn", task_name, "/f" },
                })) |_| {} else |_| {}

                // Create task: run at user logon
                std.debug.print("[install] Windows: creating scheduled task '{s}'...\n", .{task_name});
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "schtasks", "/create", "/tn", task_name, "/tr", task_cmd, "/sc", "onlogon", "/rl", "highest" },
                })) |_| {
                    std.debug.print("[install] Windows: agent scheduled task created (runs at next logon)\n", .{});
                    // Also start it now
                    if (std.process.run(allocator, io, .{
                        .argv = &.{ "schtasks", "/run", "/tn", task_name },
                    })) |_| {
                        std.debug.print("[install] Windows: agent started\n", .{});
                    } else |_| {}
                } else |_| {
                    std.debug.print("[install] Windows: failed to create task — create manually:\n", .{});
                    std.debug.print("[install]   schtasks /create /tn \"{s}\" /tr \"{s}\" /sc onlogon\n", .{ task_name, task_cmd });
                }

                // Create desktop shortcut for all users (double-click to install + launch agent)
                {
                    const desktop = "C:\\Users\\Public\\Desktop";
                    const bat_path = try std.fmt.allocPrint(allocator, "{s}\\UTM-Agent.bat", .{desktop});
                    defer allocator.free(bat_path);

                    std.Io.Dir.cwd().deleteFile(io, bat_path) catch {};
                    const bat_file = try std.Io.Dir.cwd().createFile(io, bat_path, .{ .permissions = @enumFromInt(0o644) });
                    defer bat_file.close(io);
                    var bwb: [2048]u8 = undefined;
                    var bw = bat_file.writer(io, &bwb);
                    try bw.interface.print(
                        \\@echo off
                        \\echo Installing UTM Agent...
                        \\"{s}" --install --user
                        \\echo.
                        \\echo Starting UTM Agent...
                        \\start "UTM Agent" cmd /k "{s} --agent"
                    , .{ svc_exe, svc_exe });
                    try bw.interface.flush();
                    std.debug.print("[install] Windows: desktop shortcut created: {s}\n", .{bat_path});
                }
            },
        }
        std.debug.print("[install] agent installation complete!\n", .{});
        return;
    }

    // ── System-level service install (daemon) ────────────────────────────
    switch (platform) {
        .macos => {
            const plist_dir = "/Library/LaunchDaemons";
            const plist_path = "/Library/LaunchDaemons/com.utmm.plist";

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

            if (is_host) {
                try writer.interface.print(
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>Label</key>
                    \\    <string>com.utmm</string>
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
                    \\    <string>/var/log/utmm-host.log</string>
                    \\</dict>
                    \\</plist>
                , .{svc_exe});
            } else {
                try writer.interface.print(
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>Label</key>
                    \\    <string>com.utmm</string>
                    \\    <key>ProgramArguments</key>
                    \\    <array>
                    \\        <string>{s}</string>
                , .{svc_exe});
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
                    \\    <string>/var/log/utmm.log</string>
                    \\</dict>
                    \\</plist>
                , .{});
            }
            try writer.interface.flush();

            // Load the service immediately
            if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "load", plist_path } })) |_| {
                std.debug.print("[install] macOS: plist written + loaded: {s}\n", .{plist_path});
            } else |_| {
                std.debug.print("[install] macOS: plist written to {s}\n", .{plist_path});
                std.debug.print("[install] run: sudo launchctl load {s}\n", .{plist_path});
            }
        },
        .linux => {
            const service_path = "/etc/systemd/system/utmm.service";
            const desc: []const u8 = if (is_host) "UTM Monitor Host Service" else "UTM Monitor Guest Service";
            const extra_args: []const u8 = if (is_host) " --host" else if (hostname_override) |h|
                try std.fmt.allocPrint(allocator, " --hostname {s}", .{h})
            else
                "";
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
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "enable", "utmm.service" } })) |_| {
                std.debug.print("[install] Linux: service enabled\n", .{});
            } else |_| {}
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "start", "utmm.service" } })) |_| {
                std.debug.print("[install] Linux: service started\n", .{});
            } else |_| {
                std.debug.print("[install] Linux: run manually: systemctl enable --now utmm\n", .{});
            }
        },
        .windows => {
            // Build binPath for sc create
            // sc has quirky syntax: "binPath= value" — the space after '=' is REQUIRED
            const svc_name = "UTM-Monitor";
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
                std.debug.print("[install] Windows: service started\n", .{});
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
    std.debug.print("[uninstall] detected platform: {s}, mode: {s}\n", .{ platform.asStr(), if (user_mode) "user-agent" else "system" });

    // ── User-level agent uninstall ──────────────────────────────────────
    if (user_mode) {
        switch (platform) {
            .macos => {
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/Users/root";
                const plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/com.utmm-agent.plist", .{home});
                defer allocator.free(plist_path);

                const uid = std.c.getuid();
                const gui_target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
                defer allocator.free(gui_target);
                // Unload the agent
                if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", gui_target, plist_path } })) |_| {} else |_| {}
                // Remove plist
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch |err| {
                    if (err != error.FileNotFound) {
                        std.debug.print("[uninstall] failed to remove agent plist: {}\n", .{err});
                    }
                };
                // Remove desktop shortcut
                const cmd_path = try std.fmt.allocPrint(allocator, "{s}/Desktop/UTM-Agent.command", .{home});
                defer allocator.free(cmd_path);
                std.Io.Dir.cwd().deleteFile(io, cmd_path) catch {};

                std.debug.print("[uninstall] macOS: agent unloaded, plist removed\n", .{});
            },
            .linux => {
                const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/root";
                const service_path = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/utmm-agent.service", .{home});
                defer allocator.free(service_path);

                // Stop and disable user service
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "stop", "utmm-agent.service" } })) |_| {} else |_| {}
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "disable", "utmm-agent.service" } })) |_| {} else |_| {}
                // Remove unit file
                std.Io.Dir.cwd().deleteFile(io, service_path) catch |err| {
                    if (err != error.FileNotFound) {
                        std.debug.print("[uninstall] failed to remove agent unit: {}\n", .{err});
                    }
                };
                if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "--user", "daemon-reload" } })) |_| {} else |_| {}

                // Remove desktop shortcut
                const dt_path = try std.fmt.allocPrint(allocator, "{s}/Desktop/utmm-agent.desktop", .{home});
                defer allocator.free(dt_path);
                std.Io.Dir.cwd().deleteFile(io, dt_path) catch {};

                std.debug.print("[uninstall] Linux: agent service stopped, unit removed\n", .{});
            },
            .windows => {
                const task_name = "UTM Agent";
                if (std.process.run(allocator, io, .{
                    .argv = &.{ "schtasks", "/delete", "/tn", task_name, "/f" },
                })) |_| {
                    std.debug.print("[uninstall] Windows: agent scheduled task removed\n", .{});
                } else |_| {
                    std.debug.print("[uninstall] Windows: failed to remove task (may not exist)\n", .{});
                }

                // Remove desktop shortcut
                const bat_path = "C:\\Users\\Public\\Desktop\\UTM-Agent.bat";
                std.Io.Dir.cwd().deleteFile(io, bat_path) catch {};
                std.debug.print("[uninstall] Windows: desktop shortcut removed\n", .{});
            },
        }
        std.debug.print("[uninstall] agent uninstall complete!\n", .{});
        return;
    }

    switch (platform) {
        .macos => {
            const plist_path = "/Library/LaunchDaemons/com.utmm.plist";

            // Unload the service
            if (std.process.run(allocator, io, .{ .argv = &.{ "launchctl", "bootout", "system", plist_path } })) |_| {} else |_| {}

            // Remove the plist file
            std.Io.Dir.cwd().deleteFile(io, plist_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.print("[uninstall] failed to remove plist: {}\n", .{err});
                }
            };
            std.debug.print("[uninstall] macOS: service unloaded, plist removed\n", .{});
        },
        .linux => {
            const service_name = "utmm.service";
            const service_path = "/etc/systemd/system/utmm.service";

            // Stop and disable
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "stop", service_name } })) |_| {} else |_| {}
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "disable", service_name } })) |_| {} else |_| {}

            // Remove the unit file
            std.Io.Dir.cwd().deleteFile(io, service_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.print("[uninstall] failed to remove unit file: {}\n", .{err});
                }
            };

            // Reload systemd
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "daemon-reload" } })) |_| {} else |_| {}

            std.debug.print("[uninstall] Linux: service stopped, unit file removed\n", .{});
        },
        .windows => {
            const svc_name = "UTM-Monitor";

            // Stop and delete the service
            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "stop", svc_name },
            })) |_| {} else |_| {}
            if (std.process.run(allocator, io, .{
                .argv = &.{ "sc", "delete", svc_name },
            })) |_| {} else |_| {}

            std.debug.print("[uninstall] Windows: service stopped and removed\n", .{});
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
