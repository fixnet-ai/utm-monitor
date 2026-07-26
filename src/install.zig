//! System service init script generation and platform detection.
//!
//! Service installation/uninstallation is now handled by svc.zig.
//! This module provides genInit() templates and platform detection helpers.

const std = @import("std");
const builtin = @import("builtin");

/// Supported operating system platforms
pub const Platform = enum {
    linux,
    macos,
    windows,

    pub fn detect() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .linux,
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

/// Generate auto-start script/config template for the given platform.
pub fn genInit(platform: Platform) []const u8 {
    return switch (platform) {
        .macos =>
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.utmm.guest</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/utmm/utmm</string>
        \\        <string>--svc</string>
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>SHELL</key>
        \\        <string>/bin/zsh</string>
        \\        <key>HOME</key>
        \\        <string>/var/root</string>
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
        \\    <string>/var/log/utmm-guest.log</string>
        \\</dict>
        \\</plist>
        \\
        \\<!-- Install: sudo cp this file to /Library/LaunchDaemons/com.utmm.guest.plist -->
        \\<!-- Load:    sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmm.guest.plist -->
        \\
        \\<!-- Host mode: replace --svc with --svc --host, change Label/Log to utmm-host -->
        ,
        .linux =>
        \\[Unit]
        \\Description=UTM Monitor Guest Service
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL=/bin/bash
        \\Environment=HOME=/root
        \\ExecStart=/opt/utmm/utmm --svc
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
        \\<!-- Install: sudo cp this file to /etc/systemd/system/utmm-guest.service -->
        \\<!-- Enable:  sudo systemctl daemon-reload && sudo systemctl enable utmm-guest -->
        \\
        \\<!-- Host mode: add --host to ExecStart, change Description to Host -->
        ,
        .windows =>
        \\:: UTM Monitor Guest auto-start service
        \\::
        \\:: Install: sc create "UTM-Monitor-Guest" binPath= "\"C:\opt\utmm\utmm.exe\" --svc" start= auto
        \\::           sc failure "UTM-Monitor-Guest" reset=30 actions=restart/5000/restart/5000/restart/5000/none/5000
        \\::           sc start "UTM-Monitor-Guest"
        \\:: Remove:  sc stop "UTM-Monitor-Guest" & sc delete "UTM-Monitor-Guest"
        \\
        \\:: Host mode: replace UTM-Monitor-Guest with UTM-Monitor-Host, add --host to binPath
        ,
    };
}

/// Detect the shell and home directory for service environment.
pub fn detectServiceEnv(platform: Platform) struct { shell: []const u8, home: []const u8 } {
    return .{ .shell = defaultShell(platform), .home = defaultHome(platform) };
}

fn defaultShell(platform: Platform) []const u8 {
    return switch (platform) {
        .macos => "/bin/zsh",
        .linux => "/bin/bash",
        .windows => "cmd.exe",
    };
}

fn defaultHome(platform: Platform) []const u8 {
    return switch (platform) {
        .macos => "/var/root",
        .linux => "/root",
        .windows => "C:\\",
    };
}

test "Platform.detect returns valid platform" {
    const p = Platform.detect();
    _ = switch (p) {
        .macos, .linux, .windows => true,
    };
}

test "defaultShell - linux" {
    try std.testing.expectEqualStrings("/bin/bash", defaultShell(.linux));
}

test "defaultShell - macos" {
    try std.testing.expectEqualStrings("/bin/zsh", defaultShell(.macos));
}

test "defaultShell - windows" {
    try std.testing.expectEqualStrings("cmd.exe", defaultShell(.windows));
}

test "defaultHome - linux" {
    try std.testing.expectEqualStrings("/root", defaultHome(.linux));
}

test "defaultHome - macos" {
    try std.testing.expectEqualStrings("/var/root", defaultHome(.macos));
}

test "defaultHome - windows" {
    try std.testing.expectEqualStrings("C:\\", defaultHome(.windows));
}

test "genInit - linux has systemd service" {
    const script = genInit(.linux);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Unit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--svc") != null);
}

test "genInit - macos has launchd plist" {
    const script = genInit(.macos);
    try std.testing.expect(std.mem.indexOf(u8, script, "com.utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "plist") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--svc") != null);
}

test "genInit - windows has sc command" {
    const script = genInit(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "sc create") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "UTM-Monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "C:\\opt\\utmm\\utmm.exe") != null);
}
