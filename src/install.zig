//! System service installation and auto-start script generation
//! Supports three platforms: macOS (launchd), Linux (systemd), Windows (Registry)

const std = @import("std");
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
        \\    <string>com.utm-monitor</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/utmm/utmm</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <true/>
        \\    <key>StandardOutPath</key>
        \\    <string>/var/log/utm-monitor.log</string>
        \\</dict>
        \\</plist>
        \\<!-- Install to: /Library/LaunchDaemons/com.utm-monitor.plist -->
        \\<!-- Load with: sudo launchctl load /Library/LaunchDaemons/com.utm-monitor.plist -->
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
        \\:: UTM Monitor auto-start script
        \\:: Save this script as C:\opt\utmm\startup.bat
        \\:: and create a "run at system startup" task in Task Scheduler:
        \\::   schtasks /create /tn "UTM-Monitor" /tr "C:\opt\utmm\utmm.exe" /sc onstart /rl highest
        \\@echo off
        \\cd /d C:\opt\utmm\
        \\start /b utmm.exe
        ,
    };
}

/// Self-install as system service (auto-detect platform)
pub fn installSelf(io: std.Io, allocator: std.mem.Allocator, is_host: bool) !void {
    const platform = Platform.detect();
    std.debug.print("[install] detected platform: {s}, mode: {s}\n", .{ platform.asStr(), if (is_host) "host" else "guest" });

    // Get current executable path
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];

    switch (platform) {
        .macos => {
            const plist_dir = "/Library/LaunchDaemons";
            const plist_path = "/Library/LaunchDaemons/com.utm-monitor.plist";

            // Create LaunchDaemons directory if needed
            std.Io.Dir.cwd().createDir(io, plist_dir, @enumFromInt(0o755)) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            // Write plist (remove existing first)
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
                    \\    <string>com.utm-monitor</string>
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
                    \\    <string>/var/log/utm-monitor-host.log</string>
                    \\</dict>
                    \\</plist>
                , .{exe_path});
            } else {
                try writer.interface.print(genInit(.macos), .{});
            }
            try writer.interface.flush();

            std.debug.print("[install] macOS: plist written to {s}\n", .{plist_path});
            std.debug.print("[install] run: sudo launchctl load {s}\n", .{plist_path});
        },
        .linux => {
            const service_path = "/etc/systemd/system/utm-monitor.service";
            const desc: []const u8 = if (is_host) "UTM Monitor Host Service" else "UTM Monitor Guest Service";

            const content = if (is_host) blk: {
                // Compute working directory from exe path for Host mode
                const exe_dir = std.fs.path.dirname(exe_path) orelse "/opt/utmm";
                break :blk try std.fmt.allocPrint(allocator,
                    \\[Unit]
                    \\Description={s}
                    \\After=network.target
                    \\
                    \\[Service]
                    \\Type=simple
                    \\ExecStart={s} --host
                    \\WorkingDirectory={s}
                    \\Restart=always
                    \\RestartSec=5
                    \\StandardOutput=journal
                    \\
                    \\[Install]
                    \\WantedBy=multi-user.target
                , .{ desc, exe_path, exe_dir });
            } else blk: {
                break :blk try std.fmt.allocPrint(allocator,
                    \\[Unit]
                    \\Description={s}
                    \\After=network.target
                    \\
                    \\[Service]
                    \\Type=simple
                    \\ExecStart={s}
                    \\Restart=always
                    \\RestartSec=5
                    \\StandardOutput=journal
                    \\
                    \\[Install]
                    \\WantedBy=multi-user.target
                , .{ desc, exe_path });
            };
            defer allocator.free(content);

            std.Io.Dir.cwd().deleteFile(io, service_path) catch {};
            const file = try std.Io.Dir.cwd().createFile(io, service_path, .{ .permissions = @enumFromInt(0o644) });
            defer file.close(io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(io, &write_buf);
            try writer.interface.writeAll(content);
            try writer.interface.flush();

            std.debug.print("[install] Linux: systemd unit written to {s}\n", .{service_path});
            std.debug.print("[install] run: systemctl enable utm-monitor && systemctl start utm-monitor\n", .{});
        },
        .windows => {
            const args: []const u8 = if (is_host) " --host" else "";
            std.debug.print("[install] Windows: please manually create scheduled task:\n", .{});
            std.debug.print("[install]   schtasks /create /tn \"UTM-Monitor\" /tr \"{s}{s}\" /sc onstart /rl highest\n", .{ exe_path, args });
        },
    }

    std.debug.print("[install] installation complete!\n", .{});
}

/// Uninstall system service (auto-detect platform)
pub fn uninstallSelf(io: std.Io, allocator: std.mem.Allocator) !void {
    const platform = Platform.detect();
    std.debug.print("[uninstall] detected platform: {s}\n", .{platform.asStr()});

    switch (platform) {
        .macos => {
            const plist_path = "/Library/LaunchDaemons/com.utm-monitor.plist";

            // Unload the service (needs sudo)
            if (std.process.run(allocator, io, .{ .argv = &.{ "/bin/sh", "-c", "launchctl unload " ++ plist_path } })) |_| {} else |_| {}

            // Remove the plist file
            std.Io.Dir.cwd().deleteFile(io, plist_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.print("[uninstall] failed to remove plist: {}\n", .{err});
                }
            };
            std.debug.print("[uninstall] macOS: service unloaded, plist removed from {s}\n", .{plist_path});
        },
        .linux => {
            const service_name = "utm-monitor.service";
            const service_path = "/etc/systemd/system/utm-monitor.service";

            // Stop and disable the service
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "stop", service_name } })) |_| {} else |_| {}
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "disable", service_name } })) |_| {} else |_| {}

            // Reload systemd
            if (std.process.run(allocator, io, .{ .argv = &.{ "systemctl", "daemon-reload" } })) |_| {} else |_| {}

            // Remove the unit file
            std.Io.Dir.cwd().deleteFile(io, service_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.print("[uninstall] failed to remove unit file: {}\n", .{err});
                }
            };
            std.debug.print("[uninstall] Linux: service stopped, unit file removed\n", .{});
        },
        .windows => {
            // Delete the scheduled task
            if (std.process.run(allocator, io, .{
                .argv = &.{ "schtasks", "/delete", "/tn", "UTM-Monitor", "/f" },
            })) |_| {} else |_| {}
            std.debug.print("[uninstall] Windows: scheduled task removed\n", .{});
        },
    }

    // Kill running processes AFTER removing config files (best-effort, may kill self)
    killRunning(io, allocator, platform) catch {};

    std.debug.print("[uninstall] uninstall complete!\n", .{});
}

/// Kill running utm-monitor processes (best-effort)
fn killRunning(io: std.Io, allocator: std.mem.Allocator, platform: Platform) !void {
    switch (platform) {
        .macos, .linux => {
            if (std.process.run(allocator, io, .{ .argv = &.{ "pkill", "-9", "utm-monitor" } })) |_| {} else |_| {}
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
    try std.testing.expect(std.mem.indexOf(u8, script, "com.utm-monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "plist") != null);
}

test "genInit - windows" {
    const script = genInit(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "utmm.exe") != null);
}

test "uninstallSelf - signature" { _ = uninstallSelf; }
