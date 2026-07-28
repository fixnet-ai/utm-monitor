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
/// Install-time singleton lock to serialize install/uninstall operations.
/// Uses OS-level advisory locks automatically released on process exit.
const InstallLock = struct {
    const path_posix = "/var/run/utmm-install.lock";
    const path_win = "C:\\opt\\utmm\\utmm-install.lock";

    var _locked: bool = false;

    pub fn acquire() !void {
        if (builtin.os.tag == .windows) {
            return acquireWindows();
        }
        return acquirePosix();
    }

    pub fn release() void {
        if (!_locked) return;
        if (builtin.os.tag == .windows) {
            releaseWindows();
        } else {
            releasePosix();
        }
        _locked = false;
    }

    // ──────────── POSIX: flock ────────────
    const O_CREAT: c_int = if (builtin.os.tag == .macos) 0x0200 else 0o100;
    const O_RDWR: c_int = if (builtin.os.tag == .macos) 0x0002 else 0o2;
    const LOCK_EX: c_int = 2;
    const LOCK_UN: c_int = 8;

    extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
    extern "c" fn flock(fd: c_int, operation: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;

    var posix_fd: c_int = -1;

    fn acquirePosix() !void {
        const fd = open(path_posix, O_CREAT | O_RDWR, 0o644);
        if (fd < 0) {
            std.log.err("[svc] install-lock: open failed", .{});
            return error.LockFailed;
        }
        if (flock(fd, LOCK_EX) != 0) {
            _ = close(fd);
            std.log.err("[svc] install-lock: flock failed", .{});
            return error.LockFailed;
        }
        posix_fd = fd;
        _locked = true;
    }

    fn releasePosix() void {
        _ = flock(posix_fd, LOCK_UN);
        _ = close(posix_fd);
        posix_fd = -1;
    }

    // ──────────── Windows: LockFileEx ────────────
    const w = std.os.windows;
    const DWORD = w.DWORD;
    const BOOL = w.BOOL;
    const HANDLE = w.HANDLE;
    const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 128;
    const OPEN_ALWAYS: DWORD = 4;
    const LOCKFILE_EXCLUSIVE_LOCK: DWORD = 0x00000002;

    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: DWORD,
        OffsetHigh: DWORD,
        hEvent: ?HANDLE,
    };

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn LockFileEx(
        hFile: HANDLE,
        dwFlags: DWORD,
        dwReserved: DWORD,
        nNumberOfBytesToLockLow: DWORD,
        nNumberOfBytesToLockHigh: DWORD,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn UnlockFileEx(
        hFile: HANDLE,
        dwReserved: DWORD,
        nNumberOfBytesToUnlockLow: DWORD,
        nNumberOfBytesToUnlockHigh: DWORD,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    var win_handle: HANDLE = undefined;

    fn acquireWindows() !void {
        // Convert path to UTF-16 (stack-allocated, path is short)
        var path_utf16: [128]u16 = [_]u16{0} ** 128;
        var i: usize = 0;
        for (path_win) |c| {
            path_utf16[i] = @intCast(c);
            i += 1;
        }
        path_utf16[i] = 0;

        const h = CreateFileW(
            @ptrCast(&path_utf16),
            GENERIC_READ | GENERIC_WRITE,
            0, // exclusive access
            null,
            OPEN_ALWAYS, // create if not exists
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == INVALID_HANDLE_VALUE) {
            std.log.err("[svc] install-lock: CreateFileW failed", .{});
            return error.LockFailed;
        }

        var overlapped: OVERLAPPED = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Offset = 0,
            .OffsetHigh = 0,
            .hEvent = null,
        };
        if (LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped) == 0) {
            _ = CloseHandle(h);
            std.log.err("[svc] install-lock: LockFileEx failed", .{});
            return error.LockFailed;
        }

        win_handle = h;
        _locked = true;
    }

    fn releaseWindows() void {
        var overlapped: OVERLAPPED = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Offset = 0,
            .OffsetHigh = 0,
            .hEvent = null,
        };
        _ = UnlockFileEx(win_handle, 0, 1, 0, &overlapped);
        _ = CloseHandle(win_handle);
    }
};
const protocol = @import("protocol.zig");

/// Canonical install path for utmm (the managed process).
pub const CANONICAL_PATH_POSIX = "/opt/utmm/utmm";
pub const CANONICAL_PATH_WIN = "C:\\opt\\utmm\\utmm.exe";

/// Canonical install path for utmmd (the supervisor daemon / system service).
pub const CANONICAL_SVC_PATH_POSIX = "/opt/utmm/utmmd";
pub const CANONICAL_SVC_PATH_WIN = "C:\\opt\\utmm\\utmmd.exe";

/// Single service name — utmmd is the system service (v0.12.0+).
/// Guest and Host are mutually exclusive on one machine.
const SVC_NAME_MACOS = "com.utmmd";
const SVC_NAME_LINUX = "utmmd";
const SVC_NAME_WINDOWS = "UTM-MonitorD";

fn svcName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => SVC_NAME_MACOS,
        .linux => SVC_NAME_LINUX,
        .windows => SVC_NAME_WINDOWS,
        else => "utmmd",
    };
}

pub const ServiceRole = enum { guest, host };

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

/// Return the canonical install path for utmmd (the supervisor daemon).
pub fn canonicalSvcPath() []const u8 {
    if (builtin.os.tag == .windows) return CANONICAL_SVC_PATH_WIN;
    return CANONICAL_SVC_PATH_POSIX;
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

/// Run `launchctl bootout system/<name>` with the correct slash-separated
/// service target syntax. The space-separated form (`bootout system <name>`)
/// is not valid on macOS and always returns exit code 5 (EIO).
fn bootoutMacOS(alloc: std.mem.Allocator, io: std.Io, name: []const u8) void {
    const target = std.fmt.allocPrint(alloc, "system/{s}", .{name}) catch return;
    defer alloc.free(target);
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", target });
}

/// Run a command using std.process.run. Returns true on success (exit code 0).
fn runCmd(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
        std.log.debug("[svc] cmd spawn failed: {s}: {}", .{ argv[0], err });
        return false;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.debug("[svc] cmd non-zero exit: {s} {s} (term={})", .{ argv[0], argv[1], result.term });
        return false;
    }
    return true;
}

/// Run a command for best-effort cleanup — failure is expected and logged
/// at debug level (not warn, since many of these intentionally target
/// services/files that may not exist).
fn runCmdQuiet(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
        std.log.debug("[svc] cmd failed: {s} {s}: {}", .{ argv[0], argv[1], err });
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.debug("[svc] cmd non-zero exit: {s} {s}", .{ argv[0], argv[1] });
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
pub fn isRunning(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) bool {
    _ = _role;
    const name = svcName();
    return switch (builtin.os.tag) {
        .macos => blk: {
            const result = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
            if (result) |stdout| {
                defer alloc.free(stdout);
                var lines = std.mem.splitScalar(u8, stdout, '\n');
                while (lines.next()) |line| {
                    if (std.mem.indexOf(u8, line, name)) |_| {
                        const trimmed = std.mem.trimStart(u8, line, " \t");
                        if (trimmed.len > 0 and std.ascii.isDigit(trimmed[0])) {
                            break :blk true;
                        }
                        break;
                    }
                }
            }
            // Fallback: check if utmmd process is actually running.
            // launchctl load (legacy) may have started it without launchd
            // tracking the PID properly. pgrep catches this case.
            if (runCmdCheckExit(alloc, io, &[_][]const u8{
                "pgrep", "-f", "/opt/utmm/utmmd",
            })) {
                break :blk true;
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
                bootoutMacOS(alloc, io, legacy);
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
    const name = svcName();
    const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
    defer alloc.free(plist_path);

    const svc_path = canonicalSvcPath();
    const env = .{ .shell = "/bin/zsh", .home = "/var/root" };

    // Build ProgramArguments string: utmmd --role guest|host [extra_args...]
    var args_list: std.ArrayListAligned(u8, null) = .empty;
    defer args_list.deinit(alloc);
    try args_list.appendSlice(alloc, "        <string>");
    try args_list.appendSlice(alloc, svc_path);
    try args_list.appendSlice(alloc, "</string>\n");
    try args_list.appendSlice(alloc, "        <string>--role</string>\n");
    try args_list.appendSlice(alloc, if (role == .host)
        "        <string>host</string>\n"
    else
        "        <string>guest</string>\n");
    for (extra_args) |arg| {
        try args_list.appendSlice(alloc, "        <string>");
        try args_list.appendSlice(alloc, arg);
        try args_list.appendSlice(alloc, "</string>\n");
    }

    const log_path = "/var/log/utmmd.log";
    const err_log_path = "/var/log/utmmd-err.log";

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

    // Enable first to clear any persisted disabled flag from a previous
    // uninstall/disable cycle — must be done while the label still exists
    // in launchd's persistent state (before bootout removes it).
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
    // Bootout stale registration, then bootstrap fresh.
    // Without bootout, bootstrap fails with errno=5/17 when the service
    // label is already registered — even if not running.
    bootoutMacOS(alloc, io, name);
    // Bootstrap (also starts via RunAtLoad=true). Best-effort: bootstrap
    // may fail due to launchd throttle (EIO on recently-booted-out labels)
    // or transient errors. start() handles the full retry + fallback chain.
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path });

    std.log.info("[svc] macOS service {s} installed", .{name});
}

fn installLinux(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName();
    const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
    defer alloc.free(unit_path);

    const svc_path = canonicalSvcPath();
    const env = .{ .shell = "/bin/bash", .home = "/root" };

    // Build ExecStart args: utmmd --role guest|host [extra_args...]
    var exec_args: std.ArrayListAligned(u8, null) = .empty;
    defer exec_args.deinit(alloc);
    try exec_args.appendSlice(alloc, svc_path);
    try exec_args.appendSlice(alloc, " --role ");
    try exec_args.appendSlice(alloc, if (role == .host) "host" else "guest");
    for (extra_args) |arg| {
        try exec_args.append(alloc, ' ');
        try exec_args.appendSlice(alloc, arg);
    }

    const unit = try std.fmt.allocPrint(alloc,
        \\[Unit]
        \\Description=UTM Monitor Daemon ({s})
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL={s}
        \\Environment=HOME={s}
        \\ExecStart={s}
        \\WorkingDirectory=/opt/utmm
        \\StandardOutput=journal
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{
        if (role == .host) "host" else "guest",
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
    const name = svcName();
    const svc_path = canonicalSvcPath();

    // Build binPath: utmmd --svc --role guest|host [extra_args...]
    var bin_path: std.ArrayListAligned(u8, null) = .empty;
    defer bin_path.deinit(alloc);
    try bin_path.appendSlice(alloc, "\"");
    try bin_path.appendSlice(alloc, svc_path);
    try bin_path.appendSlice(alloc, "\" --svc --role ");
    try bin_path.appendSlice(alloc, if (role == .host) "host" else "guest");
    for (extra_args) |arg| {
        try bin_path.append(alloc, ' ');
        try bin_path.appendSlice(alloc, arg);
    }

    // Delete old service if exists
    runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name }); // best-effort: may not exist
    if (!runCmd(alloc, io, &[_][]const u8{ "sc", "delete", name })) {
        std.log.warn("[svc] sc delete {s} failed (may not be installed)", .{name});
    }

    // Create service — no failure actions (utmmd handles its own restart/backoff)
    if (!runCmd(alloc, io, &[_][]const u8{
        "sc", "create", name,
        "binPath=", bin_path.items,
        "start=", "auto",
    })) {
        fail.msg("install/sc-create", "failed to create service {s}", .{name});
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
        "program=", svc_path,
        "enable=", "yes",
    })) {
        fail.msg("install/firewall", "failed to add firewall rule", .{});
    }

    std.log.info("[svc] Windows service {s} installed", .{name});
}

/// Remove service configuration only (no binary deletion, no process killing).
/// Used as rollback when forceInstall's start step fails.
fn uninstallServiceConfig(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) void {
    _ = _role;
    const name = svcName();
    switch (builtin.os.tag) {
        .macos => {
            const plist_path = std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name}) catch return;
            defer alloc.free(plist_path);
            bootoutMacOS(alloc, io, name);
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
    InstallLock.acquire() catch |err| {
        fail.err("uninstall/lock", err);
    };
    defer InstallLock.release();

    // Stop and remove all service names (current + legacy)
    switch (builtin.os.tag) {
        .macos => {
            const all_names = [_][]const u8{ SVC_NAME_MACOS, "com.utmm.guest", "com.utmm.host", "com.utmm" };
            for (all_names) |name| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);
                bootoutMacOS(alloc, io, name);
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const all_names = [_][]const u8{ SVC_NAME_LINUX, "utmm-guest", "utmm-host", "utmm" };
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
            const all_names = [_][]const u8{ SVC_NAME_WINDOWS, "UTM-Monitor-Guest", "UTM-Monitor-Host", "UTM-Monitor" };
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

    // Delete binaries (both utmm and utmmd)
    const exe_path = canonicalPath();
    std.Io.Dir.cwd().deleteFile(io, exe_path) catch |err| {
        std.log.warn("[svc] could not delete binary at {s}: {}", .{ exe_path, err });
    };
    const svc_path = canonicalSvcPath();
    if (!std.mem.eql(u8, svc_path, exe_path)) {
        std.Io.Dir.cwd().deleteFile(io, svc_path) catch |err| {
            std.log.warn("[svc] could not delete utmmd binary at {s}: {}", .{ svc_path, err });
        };
    }

    // Kill any remaining utmm processes
    killAllUtmm(io, alloc) catch |err| {
        std.log.warn("[svc] uninstall killAllUtmm failed: {}", .{err});
    };

    std.log.info("[svc] uninstall complete", .{});
}

/// Start utmmd directly as a background process (no launchd/systemd/SCM).
/// Fallback for environments where the service manager is unavailable or
/// restricted (e.g. UTM macOS VMs with SIP-enforced launchd limits).
fn startDirect(alloc: std.mem.Allocator, io: std.Io, role: ServiceRole) !void {
    const svc_path = canonicalSvcPath();
    const role_str = if (role == .host) "host" else "guest";
    // Append & so the shell backgrounds the process and returns immediately.
    // runCmd waits for the shell to exit, which with & happens instantly.
    const cmd = try std.fmt.allocPrint(alloc, "{s} --role {s} > /var/log/utmmd.log 2>&1 &", .{ svc_path, role_str });
    defer alloc.free(cmd);
    std.log.info("[svc] starting utmmd directly: {s}", .{cmd});

    if (builtin.os.tag == .windows) {
        _ = runCmd(alloc, io, &[_][]const u8{ "cmd", "/c", "start", "/b", svc_path, "--role", role_str });
    } else {
        _ = runCmd(alloc, io, &[_][]const u8{ "sh", "-c", cmd });
    }
    // Don't fail — best-effort background start. Give it a moment.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
}

/// Start the service.
pub fn start(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole) !void {
    const name = svcName();
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
            var launched_via_launchd = true;
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "kickstart", "-k", "system", name })) {
                // kickstart failed — service may not be loaded or already
                // in a broken state. Enable first to clear any persisted
                // disabled flag (must be done while label is still registered),
                // then bootout stale registration, then bootstrap fresh.
                std.log.info("[svc] kickstart failed, re-registering service...", .{});
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
                bootoutMacOS(alloc, io, name);
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);

                // Retry bootstrap up to 3 times with 1-second delays.
                // launchd may still be processing a prior bootout; retries
                // resolve transient failures.
                // Note: bootstrap may return exit 0 even when it prints
                // "Bootstrap failed: 5" to stderr, so we verify in
                // launchctl list below — don't trust exit code alone.
                var bootstrapped = false;
                for (0..3) |attempt| {
                    if (runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path })) {
                        // Verify bootstrap actually worked (not just exit 0)
                        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                        if (runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" })) |list| {
                            defer alloc.free(list);
                            if (std.mem.indexOf(u8, list, name) != null) {
                                bootstrapped = true;
                                std.log.info("[svc] bootstrap succeeded on attempt {d}", .{attempt + 1});
                                break;
                            }
                        }
                        std.log.warn("[svc] bootstrap attempt {d}: exit 0 but service not in launchctl list", .{attempt + 1});
                    } else {
                        std.log.warn("[svc] bootstrap attempt {d}/3 failed (non-zero exit), retrying in 1s...", .{attempt + 1});
                    }
                    std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch break;
                }
                if (!bootstrapped) {
                    // launchd bootstrap unavailable — start utmmd directly.
                    // Common in UTM macOS VMs where bootstrap may fail with
                    // "5: Input/output error" due to shm creation issues.
                    std.log.warn("[svc] bootstrap failed, starting utmmd directly...", .{});
                    try startDirect(alloc, io, role);
                    launched_via_launchd = false;
                }
            }
            // Verify launchd registration (skip if we fell back to startDirect).
            if (launched_via_launchd) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                const list_out = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
                if (list_out) |stdout| {
                    defer alloc.free(stdout);
                    if (std.mem.indexOf(u8, stdout, name) == null) {
                        fail.msg("start/verify", "service {s} not found in launchctl list after start", .{name});
                    }
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
pub fn stop(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) !void {
    _ = _role;
    const name = svcName();
    switch (builtin.os.tag) {
        .macos => {
            const target = std.fmt.allocPrint(alloc, "system/{s}", .{name}) catch return;
            defer alloc.free(target);
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", target })) {
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

extern "c" fn getpid() c_int;

/// Get our own process ID, cross-platform.
pub fn getOwnPid() u32 {
    if (builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    return @intCast(getpid());
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
    InstallLock.acquire() catch |err| {
        fail.err("forceInstall/lock", err);
    };
    defer InstallLock.release();
    forceInstallInternal(io, alloc, role, extra_args);
}

/// Force-install without acquiring the lock (caller must hold it).
fn forceInstallInternal(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName();
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
    const name = svcName();
    if (isRunning(io, alloc, role)) {
        std.log.info("[svc] {s} service already running", .{name});
        std.debug.print("utmm {s} service is running.\n", .{if (role == .host) "host" else "guest"});
        return;
    }
    std.log.info("[svc] {s} service not running — acquiring lock...", .{name});
    InstallLock.acquire() catch |err| {
        fail.err("ensure/lock", err);
    };
    defer InstallLock.release();
    forceInstallInternal(io, alloc, role, extra_args);
}


// ═══════════════════════════════════════════════════════════════════════════
// utmmd 安装优化：hash 比对 + config 持久化
// ═══════════════════════════════════════════════════════════════════════════

/// Config file path — stored alongside the canonical binary.
fn configFilePath() []const u8 {
    if (builtin.os.tag == .windows) return "C:\\opt\\utmm\\utmm.conf";
    return "/opt/utmm/utmm.conf";
}

/// Read a single key=value from the config file. Returns null if not found.
fn readConfigValue(io: std.Io, alloc: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const path = configFilePath();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var rbuf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const n = reader.interface.readSliceShort(&rbuf) catch return null;
    const content = rbuf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const k = trimmed[0..eq_pos];
            const v = trimmed[eq_pos + 1 ..];
            if (std.mem.eql(u8, k, key)) {
                return alloc.dupe(u8, v) catch null;
            }
        }
    }
    return null;
}

/// Write/update a key=value pair in the config file. Creates the file if missing.
/// Preserves existing entries; replaces the key if already present.
fn writeConfigValue(io: std.Io, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const path = configFilePath();
    const cwd = std.Io.Dir.cwd();

    // Ensure directory exists
    const dirname = canonicalDir();
    cwd.createDirPath(io, dirname) catch {};

    // Read existing content
    const existing = readFullFile(io, alloc, path) orelse &.{};
    defer if (existing.len > 0) alloc.free(existing);

    // Write back with updated key
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}/utmm.conf.tmp", .{dirname});
    defer alloc.free(tmp_path);

    const dst = try cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = @enumFromInt(0o644) });
    defer dst.close(io);
    var wb: [4096]u8 = undefined;
    var writer = dst.writer(io, &wb);

    var found = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            try writer.interface.print("{s}\n", .{line});
            continue;
        }
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const k = trimmed[0..eq_pos];
            if (std.mem.eql(u8, k, key)) {
                try writer.interface.print("{s}={s}\n", .{ key, value });
                found = true;
                continue;
            }
        }
        try writer.interface.print("{s}\n", .{line});
    }
    if (!found) {
        try writer.interface.print("{s}={s}\n", .{ key, value });
    }
    writer.interface.flush() catch {};
    dst.sync(io) catch {};

    // Atomic rename
    cwd.rename(tmp_path, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// Read entire file content, or null if not found.
fn readFullFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var rbuf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const n = reader.interface.readSliceShort(&rbuf) catch return null;
    return alloc.dupe(u8, rbuf[0..n]) catch null;
}

/// Compute SHA256 of a file at the given path. Returns hex string or null on error.
fn fileSha256Hex(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var read_buf: [65536]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return null;
        if (n == 0) break;
        sha.update(buf[0..n]);
    }

    var hash: [32]u8 = undefined;
    sha.final(&hash);

    var hex: [64]u8 = undefined;
    for (hash, 0..) |b, j| {
        hex[j * 2] = "0123456789abcdef"[b >> 4];
        hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return alloc.dupe(u8, &hex) catch null;
}

/// Build the args string that was used to install utmmd.
/// This is the canonical form stored in config for comparison.
fn buildArgsString(alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try buf.appendSlice(alloc, if (role == .host) "--role host" else "--role guest");
    for (extra_args) |arg| {
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, arg);
    }
    return buf.toOwnedSlice(alloc);
}

/// Check whether the installed utmmd needs updating.
/// Returns true if utmmd should be reinstalled (binary missing, hash differs, or args changed).
pub fn shouldUpdateUtmmd(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8, comptime embedded_sha256_hex: []const u8) bool {
    const svc_path = canonicalSvcPath();

    // Check 1: binary must exist
    const installed_hash = fileSha256Hex(io, alloc, svc_path) orelse {
        std.log.debug("[svc] utmmd binary missing at {s}, needs install", .{svc_path});
        return true;
    };
    defer alloc.free(installed_hash);

    // Check 2: hash must match embedded
    if (!std.mem.eql(u8, installed_hash, embedded_sha256_hex)) {
        std.log.debug("[svc] utmmd hash differs (installed={s}, embedded={s}), needs update", .{ installed_hash[0..@min(installed_hash.len, 16)], embedded_sha256_hex[0..@min(embedded_sha256_hex.len, 16)] });
        return true;
    }

    // Check 3: args must match stored config
    const current_args = buildArgsString(alloc, role, extra_args) catch return true;
    defer alloc.free(current_args);

    if (readConfigValue(io, alloc, "utmmd_args")) |stored_args| {
        defer alloc.free(stored_args);
        if (!std.mem.eql(u8, stored_args, current_args)) {
            std.log.debug("[svc] utmmd args changed (stored=''{s}'' current=''{s}''), needs reinstall", .{ stored_args, current_args });
            return true;
        }
    }
    // If no stored args entry but utmmd exists and hash matches, assume OK

    return false;
}

/// Save utmmd metadata to config file after successful install.
pub fn saveUtmmdMeta(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8, comptime embedded_sha256_hex: []const u8) void {
    writeConfigValue(io, alloc, "utmmd_sha256", embedded_sha256_hex) catch |err| {
        std.log.warn("[svc] failed to save utmmd_sha256: {}", .{err});
    };
    const args_str = buildArgsString(alloc, role, extra_args) catch return;
    defer alloc.free(args_str);
    writeConfigValue(io, alloc, "utmmd_args", args_str) catch |err| {
        std.log.warn("[svc] failed to save utmmd_args: {}", .{err});
    };
}


// ═══════════════════════════════════════════════════════════════════════════
// Platform detection + init script generation (moved from host.zig, Task 9)
// ═══════════════════════════════════════════════════════════════════════════

/// Supported operating system platforms for init script generation.
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

test "Platform.detect returns valid platform" {
    const p = Platform.detect();
    _ = switch (p) {
        .macos, .linux, .windows => true,
    };
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
