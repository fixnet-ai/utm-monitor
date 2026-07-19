//! UDP broadcast module (Guest side)
//! Broadcast local hostname + IP + target + MAC to LAN every second

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

// libc network interface enumeration (getifaddrs)
const in_addr = extern struct { s_addr: u32 };

// BSD (macOS) vs Linux have different sockaddr layouts
const linux_sockaddr = builtin.os.tag == .linux;
const sockaddr = if (linux_sockaddr)
    extern struct { sa_family: u16, sa_data: [14]u8 }
else
    extern struct { sa_len: u8, sa_family: u8, sa_data: [14]u8 };

const sockaddr_in = if (linux_sockaddr)
    extern struct { sin_family: u16, sin_port: u16, sin_addr: in_addr, sin_zero: [8]u8 }
else
    extern struct { sin_len: u8, sin_family: u8, sin_port: u16, sin_addr: in_addr, sin_zero: [8]u8 };

// macOS AF_LINK sockaddr_dl (used to get MAC address)
const sockaddr_dl = extern struct {
    sdl_len: u8,
    sdl_family: u8,
    sdl_index: u16,
    sdl_type: u8,
    sdl_nlen: u8,
    sdl_alen: u8,
    sdl_slen: u8,
    sdl_data: [12]u8,
};
const AF_LINK = 18;

const ifaddrs = extern struct {
    ifa_next: ?*ifaddrs,
    ifa_name: [*:0]u8,
    ifa_flags: c_uint,
    ifa_addr: ?*sockaddr,
    ifa_netmask: ?*sockaddr,
    ifa_dstaddr: ?*sockaddr,
    ifa_data: ?*anyopaque,
};
const AF_INET = 2; // IPv4
extern "c" fn getifaddrs(ifap: *?*ifaddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*ifaddrs) void;

/// Collected system information
pub const SystemInfo = struct {
    hostname: []const u8,
    ip: []const u8,
    mac: []const u8,
    target: []const u8, // Zig target triplet
    iface_name: []const u8, // Physical NIC interface name
};

/// Zig target triplet (compile-time constant)
/// For Linux musl builds, appends -musl suffix to distinguish from glibc
fn zigTarget() []const u8 {
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "x86",
        else => @compileError("unsupported arch: " ++ @tagName(builtin.cpu.arch)),
    };
    const os_tag = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @compileError("unsupported os: " ++ @tagName(builtin.os.tag)),
    };
    // musl: statically linked, compatible with any Linux distro
    if (builtin.abi == .musl) {
        return arch ++ "-" ++ os_tag ++ "-musl";
    }
    return arch ++ "-" ++ os_tag;
}

/// Check if the interface name is a physical NIC (exclude tunnel/virtual interfaces)
fn isPhysicalInterface(name: []const u8) bool {
    const exclude_prefixes = [_][]const u8{
        "utun", "tun", "tap", "llw", "awdl",
        "bridge", "vmnet", "docker", "gif", "stf",
        "veth", "vboxnet", "virbr",
    };
    for (exclude_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    if (std.mem.eql(u8, name, "lo0") or std.mem.eql(u8, name, "lo")) return false;
    return true;
}

/// Read /sys file content (used for Linux MAC address)
/// sysfs file length() is unreliable, use fixed buffer + readSliceShort
fn readSysFs(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var read_buf: [64]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const n = try reader.interface.readSliceShort(&buf);
    return try allocator.dupe(u8, buf[0..n]);
}

/// Windows: use route print to get the IP address of the physical NIC
/// Parses `route print 0.0.0.0` output to extract the Interface column
/// (the local IP of the NIC that reaches the default gateway).
/// Falls back to PowerShell if route print fails.
fn getWindowsIp(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "route", "print", "0.0.0.0" },
    }) catch {
        return allocator.dupe(u8, "0.0.0.0");
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Route table format: Network  Netmask  Gateway  Interface  Metric
    //   0.0.0.0  0.0.0.0  192.168.64.1  192.168.64.2  25
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "0.0.0.0")) {
            var fields = std.mem.splitSequence(u8, trimmed, " ");
            _ = fields.next(); // 0.0.0.0 (network)
            _ = fields.next(); // 0.0.0.0 (netmask)
            _ = fields.next(); // gateway
            if (fields.next()) |iface_ip| {
                if (std.mem.containsAtLeast(u8, iface_ip, 1, ".")) {
                    return allocator.dupe(u8, iface_ip);
                }
            }
        }
    }

    // Fallback: try PowerShell
    const ps_result = std.process.run(allocator, io, .{
        .argv = &.{ "powershell", "-NoProfile", "-Command",
            "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch 'Loopback'} | Select-Object -First 1).IPAddress" },
    }) catch {
        return allocator.dupe(u8, "0.0.0.0");
    };
    defer {
        allocator.free(ps_result.stdout);
        allocator.free(ps_result.stderr);
    }
    const ps_trimmed = std.mem.trim(u8, ps_result.stdout, " \n\r\t");
    if (ps_trimmed.len > 0) return try allocator.dupe(u8, ps_trimmed);

    return allocator.dupe(u8, "0.0.0.0");
}

/// Windows: use getmac command to get physical NIC MAC address
fn getWindowsMac(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "cmd", "/c", "getmac /fo csv /nh" },
    }) catch {
        return allocator.dupe(u8, "00:00:00:00:00:00");
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // getmac /fo csv /nh output example (without /v, only two columns):
    // "00-15-5D-00-00-08","\Device\Tcpip_{...}"
    // Take the first line, extract the first quoted field (MAC address)
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        // CSV format: "Name","MAC","Transport"
        var in_quotes: bool = false;
        var field_count: u8 = 0;
        var field_start: usize = 0;
        for (trimmed, 0..) |c, j| {
            if (c == '"') {
                if (in_quotes) {
                    in_quotes = false;
                    field_count += 1;
                    if (field_count == 1) {
                        // First quoted field = MAC address
                        const mac = trimmed[field_start + 1 .. j];
                        if (mac.len > 0 and !std.mem.eql(u8, mac, "N/A")) {
                            // getmac output uses '-' as separator, normalize to ':'
                            const normalized = try allocator.alloc(u8, mac.len);
                            for (mac, 0..) |mc, k| {
                                normalized[k] = if (mc == '-') ':' else mc;
                            }
                            return normalized;
                        }
                    }
                } else {
                    in_quotes = true;
                    field_start = j;
                }
            }
        }
    }

    // Fallback: try PowerShell Get-NetAdapter
    const ps_result = std.process.run(allocator, io, .{
        .argv = &.{ "powershell", "-NoProfile", "-Command",
            "(Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).MacAddress" },
    }) catch {
        return allocator.dupe(u8, "00:00:00:00:00:00");
    };
    defer {
        allocator.free(ps_result.stdout);
        allocator.free(ps_result.stderr);
    }
    const ps_trimmed = std.mem.trim(u8, ps_result.stdout, " \n\r\t");
    if (ps_trimmed.len > 0) return try allocator.dupe(u8, ps_trimmed);

    return allocator.dupe(u8, "00:00:00:00:00:00");
}

/// Get physical NIC MAC address
fn getMacAddress(io: std.Io, allocator: std.mem.Allocator, iface_name: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return getWindowsMac(io, allocator);
    }

    if (builtin.os.tag == .linux) {
        // Linux: read /sys/class/net/<iface>/address
        const path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/address", .{iface_name});
        defer allocator.free(path);

        const content = readSysFs(io, allocator, path) catch |err| {
            std.debug.print("[broadcast] Failed to read MAC ({s}): {}\n", .{ path, err });
            return allocator.dupe(u8, "00:00:00:00:00:00");
        };
        return std.mem.trim(u8, content, " \n\r");
    }

    // macOS: extract MAC from getifaddrs AF_LINK entries
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) {
        return allocator.dupe(u8, "00:00:00:00:00:00");
    }
    defer freeifaddrs(ifap);

    var current: ?*ifaddrs = ifap;
    while (current) |ifa| : (current = ifa.ifa_next) {
        if (ifa.ifa_addr == null) continue;

        const name = std.mem.span(ifa.ifa_name);
        if (!std.mem.eql(u8, name, iface_name)) continue;

        const addr = ifa.ifa_addr.?;
        if (addr.sa_family != AF_LINK) continue;

        const dl: *align(1) const sockaddr_dl = @ptrCast(addr);
        if (dl.sdl_alen == 0) continue;

        const start: usize = @intCast(dl.sdl_nlen);
        const len: usize = @intCast(dl.sdl_alen);
        const mac_bytes = dl.sdl_data[start .. start + len];
        return try std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            mac_bytes[0], mac_bytes[1], mac_bytes[2],
            mac_bytes[3], mac_bytes[4], mac_bytes[5],
        });
    }

    return allocator.dupe(u8, "00:00:00:00:00:00");
}

/// One-stop system info collection: hostname + IP + MAC + target
pub fn getSystemInfo(io: std.Io, allocator: std.mem.Allocator) !SystemInfo {

    const target = zigTarget();

    // Get hostname
    const hostname: []const u8 = if (builtin.os.tag == .windows) blk: {
        const name_ptr = std.c.getenv("COMPUTERNAME");
        if (name_ptr) |ptr| {
            break :blk try allocator.dupe(u8, std.mem.span(ptr));
        }
        break :blk try allocator.dupe(u8, "unknown");
    } else blk: {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = try std.posix.gethostname(&buf);
        break :blk try allocator.dupe(u8, name);
    };

    // Windows: detect IP + MAC via OS commands
    if (builtin.os.tag == .windows) {
        const ip = try getWindowsIp(io, allocator);
        const mac = try getWindowsMac(io, allocator);
        return SystemInfo{
            .hostname = hostname,
            .ip = ip,
            .mac = mac,
            .target = target,
            .iface_name = try allocator.dupe(u8, "unknown"),
        };
    }

    // Unix: use getifaddrs() to enumerate interfaces, pick first physical NIC
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) {
        return SystemInfo{
            .hostname = hostname,
            .ip = try allocator.dupe(u8, "0.0.0.0"),
            .mac = try allocator.dupe(u8, "00:00:00:00:00:00"),
            .target = target,
            .iface_name = try allocator.dupe(u8, "unknown"),
        };
    }
    defer freeifaddrs(ifap);

    var found_ip: ?[]const u8 = null;
    var found_iface: ?[]const u8 = null;

    var current: ?*ifaddrs = ifap;
    while (current) |ifa| : (current = ifa.ifa_next) {
        if (ifa.ifa_addr == null) continue;

        const addr = ifa.ifa_addr.?;
        if (addr.sa_family != AF_INET) continue;

        const name = std.mem.span(ifa.ifa_name);
        if (!isPhysicalInterface(name)) continue;

        const sin = @as(*align(1) const sockaddr_in, @ptrCast(addr));
        const bytes = @as(*const [4]u8, @ptrCast(&sin.sin_addr)).*;

        if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0) continue;
        if (bytes[0] == 127) continue;

        const ip = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        found_ip = ip;
        found_iface = try allocator.dupe(u8, name);
        std.debug.print("[broadcast] Physical NIC {s}: {s}\n", .{ name, ip });
        break;
    }

    const ip = found_ip orelse try allocator.dupe(u8, "0.0.0.0");
    const iface_name = found_iface orelse try allocator.dupe(u8, "unknown");

    // Get MAC
    const mac = try getMacAddress(io, allocator, iface_name);

    return SystemInfo{
        .hostname = hostname,
        .ip = ip,
        .mac = mac,
        .target = target,
        .iface_name = iface_name,
    };
}

/// Get local default gateway IP
/// macOS: parse `route -n get default`
/// Linux: parse `/proc/net/route`
/// Windows: parse `route print`
pub fn getDefaultGateway(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => getGatewayMacOS(io, allocator),
        .linux => getGatewayLinux(io, allocator),
        .windows => getGatewayWindows(io, allocator),
        else => error.UnsupportedPlatform,
    };
}

fn getGatewayMacOS(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "route", "-n", "get", "default" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "gateway:")) {
            const gw = std.mem.trim(u8, trimmed["gateway:".len..], " \t");
            if (gw.len > 0) return try allocator.dupe(u8, gw);
        }
    }
    return error.GatewayNotFound;
}

fn getGatewayLinux(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const content = readSysFs(io, allocator, "/proc/net/route") catch |err| {
        std.debug.print("[broadcast] Failed to read /proc/net/route: {}\n", .{err});
        return error.GatewayNotFound;
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    // First line is the header, skip it
    _ = lines.next();

    while (lines.next()) |line| {
        var fields = std.mem.splitSequence(u8, line, "\t");
        const iface = fields.next() orelse continue;
        _ = iface;
        const dest = fields.next() orelse continue;
        const gw_hex = fields.next() orelse continue;

        // Default route: Destination == "00000000" and Gateway is non-zero
        if (!std.mem.eql(u8, dest, "00000000")) continue;
        const gw_int = std.fmt.parseInt(u32, gw_hex, 16) catch continue;
        if (gw_int == 0) continue;

        // Little-endian decode: 0x0100A8C0 → 192.168.0.1
        const b0: u8 = @truncate(gw_int & 0xFF);
        const b1: u8 = @truncate((gw_int >> 8) & 0xFF);
        const b2: u8 = @truncate((gw_int >> 16) & 0xFF);
        const b3: u8 = @truncate((gw_int >> 24) & 0xFF);
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ b0, b1, b2, b3 });
    }
    return error.GatewayNotFound;
}

fn getGatewayWindows(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "route", "print", "0.0.0.0" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var found_header = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!found_header) {
            if (std.mem.startsWith(u8, trimmed, "0.0.0.0")) {
                found_header = true;
                // This line may already contain the gateway
                var fields = std.mem.splitSequence(u8, trimmed, " ");
                // Windows route table format: Network Netmask Gateway Interface Metric
                // 0.0.0.0  0.0.0.0  192.168.64.1  192.168.64.2  25
                _ = fields.next(); // 0.0.0.0
                _ = fields.next(); // 0.0.0.0 (netmask)
                if (fields.next()) |gw| {
                    if (std.mem.containsAtLeast(u8, gw, 1, ".")) {
                        return try allocator.dupe(u8, gw);
                    }
                }
            }
            continue;
        }
    }
    return error.GatewayNotFound;
}

test "getDefaultGateway - signature" { _ = getDefaultGateway; }

/// Guest broadcast loop
/// is_svc: true when running as system daemon (--svc), enables self-upgrade.
///         false when running in foreground (user terminal), skips self-upgrade
///         to avoid race condition with defer service restart.
pub fn broadcastLoop(
    io: std.Io,
    port: u16,
    info: SystemInfo,
    http_port: u16,
    is_svc: bool,
) !void {
    const broadcast_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);

    // Bind to the physical NIC IP (not 0.0.0.0) to ensure broadcast goes out the correct interface
    const bind_ip = if (std.mem.eql(u8, info.ip, "0.0.0.0")) "0.0.0.0" else info.ip;
    const bind_addr = try std.Io.net.IpAddress.parse(bind_ip, 0);
    const socket = bind_addr.bind(io, .{
        .mode = .dgram,
        .allow_broadcast = true,
    }) catch |err| {
        std.debug.print("[broadcast] Bind {s}:0 failed: {}, falling back to 0.0.0.0\n", .{ bind_ip, err });
        const fallback = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
        return broadcastLoopFallback(io, port, info, http_port, fallback, is_svc);
    };
    defer socket.close(io);

    // Build message
    const announce_info = protocol.GuestInfo{
        .hostname = info.hostname,
        .ip = info.ip,
        .target = info.target,
        .mac = info.mac,
        .http_port = http_port,
    };
    var msg_buf: [1024]u8 = undefined;
    var msg_writer: std.Io.Writer = .fixed(&msg_buf);
    try protocol.buildAnnounce(&msg_writer, announce_info);
    const msg = msg_writer.buffered();

    while (true) {
        // ── Self-upgrade check (daemon only) ────────────────────────
        // Host uploads utmm.next; daemon Guest auto-detects and self-upgrades.
        // Foreground mode skips this — the background service handles upgrades
        // when it restarts after the user closes the terminal window.
        if (is_svc) try checkSelfUpgrade(io, &info);

        socket.send(io, &broadcast_addr, msg) catch |err| {
            std.debug.print("[broadcast] Send failed: {}\n", .{err});
        };
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real);
    }
}

/// Fallback: bind 0.0.0.0 for broadcast
fn broadcastLoopFallback(
    io: std.Io,
    port: u16,
    info: SystemInfo,
    http_port: u16,
    bind_addr: std.Io.net.IpAddress,
    is_svc: bool,
) !void {
    const broadcast_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);
    const socket = try bind_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer socket.close(io);

    const announce_info = protocol.GuestInfo{
        .hostname = info.hostname,
        .ip = info.ip,
        .target = info.target,
        .mac = info.mac,
        .http_port = http_port,
    };
    var msg_buf: [1024]u8 = undefined;
    var msg_writer: std.Io.Writer = .fixed(&msg_buf);
    try protocol.buildAnnounce(&msg_writer, announce_info);
    const msg = msg_writer.buffered();

    while (true) {
        // ── Self-upgrade check (daemon only) ────────────────────────
        if (is_svc) try checkSelfUpgrade(io, &info);

        socket.send(io, &broadcast_addr, msg) catch |err| {
            std.debug.print("[broadcast] Send failed: {}\n", .{err});
        };
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real);
    }
}

/// Check for staged upgrade binary (utmm.next) and self-upgrade if found.
/// The Host uploads the new binary as "utmm.next"; the Guest detects it
/// on its next broadcast cycle, swaps it in safely, and restarts itself.
///
/// Cross-platform safe rename strategy:
///   Linux/macOS:
///     1. Rename old binary out of the way   (utmm → utmm.old)
///     2. Rename new binary into place       (utmm.next → utmm)
///     3. Spawn restart script (cleans up .old after old process exits)
///     4. exit(0) — supervisor (launchd/systemd) restarts us
///
///   Windows (different strategy — .exe files are locked when running):
///     1. Spawn batch script BEFORE we exit (so it outlives us)
///     2. exit(0) — SCM marks service stopped, lock released
///     3. Batch script: wait → delete old .exe → rename .next → start service
///
/// This works on all platforms because:
///   Linux:   rename() is a directory op — old inode stays alive
///   macOS:   same as Linux; SIP won't SIGKILL new binary (different inode)
///   Windows: .exe is locked while running; script handles rename after exit
fn checkSelfUpgrade(io: std.Io, info: *const SystemInfo) !void {
    const new_name: []const u8 = if (builtin.os.tag == .windows) "utmm.next.exe" else "utmm.next";
    const final_name: []const u8 = if (builtin.os.tag == .windows) "utmm.exe" else "utmm";
    const old_name: []const u8 = if (builtin.os.tag == .windows) "utmm.old.exe" else "utmm.old";
    const install_dir: []const u8 = if (builtin.os.tag == .windows) "C:\\opt\\utmm" else "/opt/utmm";
    const bat_name: []const u8 = "_upgrade.bat";

    // Open the install directory for relative-path operations.
    // Using CWD with absolute paths breaks on Windows services (CWD is System32).
    const dir = std.Io.Dir.cwd().openDir(io, install_dir, .{}) catch |err| {
        std.debug.print("[broadcast] Self-upgrade: cannot open {s}: {}\n", .{ install_dir, err });
        return;
    };
    defer dir.close(io);

    // Check if staged file exists
    const file = dir.openFile(io, new_name, .{}) catch return;
    const file_size = file.length(io) catch 0;
    file.close(io);

    // Sanity check: file must be at least 100KB (not a partial upload)
    if (file_size < 100 * 1024) return;

    std.debug.print("[broadcast] 🔄 Self-upgrade: staged {s}/{s} ({d} bytes)\n", .{ install_dir, new_name, file_size });

    // Step 1: Move old binary out of the way (utmm → utmm.old)
    // Step 2: Place new binary at the target name (utmm.next → utmm)
    if (builtin.os.tag == .windows) {
        // On Windows, running .exe files are locked — we cannot rename
        // the current binary while it's executing.  Instead we schedule
        // everything via a batch script that runs AFTER we exit.
        //
        // Strategy (all in _upgrade.bat, launched detached before exit):
        //   1. Wait for our process to die       (ping -n 3 127.0.0.1)
        //   2. Delete stale .old if present
        //   3. Rename current .exe → .old        (now unlocked)
        //   4. Rename .next → .exe
        //   5. Start the service with the new binary
        //   6. Self-delete the batch file
        //
        // This avoids the "file in use" problem entirely — all renames
        // happen after we exit, when the .exe lock is released.

        const bat_full_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\\{s}", .{ install_dir, bat_name });
        defer std.heap.page_allocator.free(bat_full_path);

        if (dir.createFile(io, bat_name, .{ .permissions = @enumFromInt(0o644) })) |bat_file| {
            var wb: [1024]u8 = undefined;
            var bat_writer = bat_file.writer(io, &wb);
            bat_writer.interface.print(
                \\@echo off
                \\ping -n 3 127.0.0.1 >nul
                \\cd /d {0s}
                \\del /f {1s} 2>nul
                \\ren {2s} {1s}
                \\if errorlevel 1 goto :failed
                \\ren {3s} {2s}
                \\if errorlevel 1 goto :failed
                \\sc start UTM-Monitor
                \\del "%~f0" 2>nul
                \\exit /b 0
                \\:failed
                \\echo Upgrade failed — .next may still be staged
                \\del "%~f0" 2>nul
                \\exit /b 1
                \\
            , .{ install_dir, old_name, final_name, new_name }) catch {};
            bat_writer.interface.flush() catch {};
            bat_file.close(io);
        } else |_| {
            std.debug.print("[broadcast] Self-upgrade: cannot write {s}\n", .{bat_name});
            return;
        }
    } else {
        // Unix: rename() is always safe (directory entry operation)
        dir.deleteFile(io, old_name) catch {};
        dir.rename(final_name, dir, old_name, io) catch |err| {
            std.debug.print("[broadcast] Self-upgrade: rename {s} → {s} failed: {}\n", .{ final_name, old_name, err });
            return;
        };
        dir.rename(new_name, dir, final_name, io) catch |err| {
            std.debug.print("[broadcast] Self-upgrade: rename {s} → {s} failed: {}\n", .{ new_name, final_name, err });
            dir.rename(old_name, dir, final_name, io) catch {};
            return;
        };
    }

    // Make executable and clear quarantine (Unix only)
    if (builtin.os.tag != .windows) {
        // Use full paths for chmod/xattr (they handle absolute paths fine)
        const final_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ install_dir, final_name }) catch return;
        defer std.heap.page_allocator.free(final_path);

        if (std.process.run(std.heap.page_allocator, io, .{
            .argv = &.{ "chmod", "+x", final_path },
        })) |_| {} else |_| {}

        if (builtin.os.tag == .macos) {
            if (std.process.run(std.heap.page_allocator, io, .{
                .argv = &.{ "xattr", "-d", "com.apple.quarantine", final_path },
            })) |_| {} else |_| {}
        }
    }

    // Step 3: Spawn restart script (detached, survives our exit).
    if (builtin.os.tag == .windows) {
        // The batch file was already written above (before the renames).
        // Now just spawn it and exit.
        const bat_full_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}\\{s}", .{ install_dir, bat_name }) catch return;
        defer std.heap.page_allocator.free(bat_full_path);
        _ = std.process.spawn(io, .{
            .argv = &.{ "cmd", "/c", bat_full_path },
        }) catch {};
    } else {
        const old_full_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ install_dir, old_name }) catch return;
        defer std.heap.page_allocator.free(old_full_path);
        const final_full_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ install_dir, final_name }) catch return;
        defer std.heap.page_allocator.free(final_full_path);

        const restart_cmd = std.fmt.allocPrint(
            std.heap.page_allocator,
            "nohup sh -c 'sleep 2; rm -f \"{s}\"; {s} --hostname {s} &' >/dev/null 2>&1 &",
            .{ old_full_path, final_full_path, info.hostname },
        ) catch return;
        defer std.heap.page_allocator.free(restart_cmd);
        _ = std.process.run(std.heap.page_allocator, io, .{ .argv = &.{ "sh", "-c", restart_cmd } }) catch {};
    }

    std.debug.print("[broadcast] Self-upgrade complete — restarting with new binary\n", .{});
    std.process.exit(0);
}
