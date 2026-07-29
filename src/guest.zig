//! Guest 端模块 — 系统信息采集 + 命令处理 + LSA mesh 启动。
//!
//! Guest 在 TCP :2121 上侦听，通过 SOCKS4a 握手接受 Host 连接，
//! 每条 TCP 连接处理一条命令（exec/upload/download），命令结束即关闭连接。
//! 使用 dpipe 抽象层进行 Shell 管理和文件 I/O。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const protocol = @import("protocol.zig");
const lsa = @import("lsa.zig");
const tcp = @import("tcp.zig");
const svc = @import("svc.zig");
const shm = @import("shm.zig");
const dpipe = @import("dpipe.zig");
const dpipe_shell = @import("dpipe_shell.zig");
const dpipe_file = @import("dpipe_file.zig");

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
const IFF_UP = 0x1;
extern "c" fn getifaddrs(ifap: *?*ifaddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*ifaddrs) void;

/// Collected system information
pub const SystemInfo = struct {
    hostname: []const u8,
    ip: []const u8,
    mac: []const u8,
    target: []const u8, // Zig target triplet
    iface_name: []const u8, // Physical NIC interface name
    shell: []const u8, // Detected shell binary (e.g. /bin/zsh, cmd.exe)
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

/// Detect shell for command execution from $SHELL environment variable.
/// POSIX: reads $SHELL at startup, falls back to /bin/sh if unset.
/// Windows: always cmd.exe (no $SHELL equivalent).
fn detectShell(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return allocator.dupe(u8, "cmd.exe");
    }

    // Read $SHELL environment variable
    if (std.c.getenv("SHELL")) |sh| {
        const sh_slice = std.mem.sliceTo(sh, 0);
        if (sh_slice.len > 0) return allocator.dupe(u8, sh_slice);
    }

    return allocator.dupe(u8, "/bin/sh");
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

    var buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const n = try reader.interface.readSliceShort(&buf);
    const trimmed = std.mem.trimEnd(u8, buf[0..n], "\n\r");
    return try allocator.dupe(u8, trimmed);
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
            var fields = std.mem.tokenizeScalar(u8, trimmed, ' ');
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
            std.debug.print("[guest] Failed to read MAC ({s}): {}\n", .{ path, err });
            return allocator.dupe(u8, "00:00:00:00:00:00");
        };
        return content;
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
/// Enumerate physical NICs via getifaddrs(), return the first valid IPv4 address.
/// Returns null if no suitable interface found (getifaddrs failure, no IPv4 on
/// any physical NIC, or all addresses are 0.0.0.0 / loopback).
fn detectUnixIp(allocator: std.mem.Allocator) !?struct { ip: []const u8, iface_name: []const u8 } {
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) return null;
    defer freeifaddrs(ifap);

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
        const iface_name = try allocator.dupe(u8, name);
        std.debug.print("[guest] Physical NIC {s}: {s}\n", .{ name, ip });
        return .{ .ip = ip, .iface_name = iface_name };
    }
    return null;
}

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

    // Retry IP detection up to 5 times (1s apart) on all platforms.
    // DHCP may not have completed when the Guest service first starts,
    // causing getifaddrs() / route print to return no valid IPv4.
    // Without retry, the Guest embeds "0.0.0.0" in LSA broadcasts forever.
    const MAX_IP_RETRIES = 5;
    const IP_RETRY_DELAY_MS = 1000;
    var found_ip: ?[]const u8 = null;
    var found_iface: ?[]const u8 = null;
    var attempt: usize = 0;

    while (attempt < MAX_IP_RETRIES) : (attempt += 1) {
        if (attempt > 0) {
            std.debug.print("[guest] IP not ready (attempt {}/{}), waiting {d}ms...\n", .{ attempt + 1, MAX_IP_RETRIES, IP_RETRY_DELAY_MS });
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(IP_RETRY_DELAY_MS), .awake) catch {};
        }

        if (builtin.os.tag == .windows) {
            const ip = try getWindowsIp(io, allocator);
            if (!std.mem.eql(u8, ip, "0.0.0.0")) {
                found_ip = ip;
                break;
            }
            allocator.free(ip);
        } else {
            if (try detectUnixIp(allocator)) |result| {
                found_ip = result.ip;
                found_iface = result.iface_name;
                break;
            }
        }
    }

    const ip = found_ip orelse try allocator.dupe(u8, "0.0.0.0");
    const iface_name = found_iface orelse try allocator.dupe(u8, "unknown");

    // Get MAC
    const mac = if (builtin.os.tag == .windows)
        try getWindowsMac(io, allocator)
    else
        try getMacAddress(io, allocator, iface_name);
    const shell = try detectShell(allocator);

    return SystemInfo{
        .hostname = hostname,
        .ip = ip,
        .mac = mac,
        .target = target,
        .iface_name = iface_name,
        .shell = shell,
    };
}

/// Collect all broadcast addresses for UDP discovery.
/// Always includes 255.255.255.255. On POSIX, also enumerates local IPv4
/// interfaces and computes subnet-directed broadcast addresses.
/// Caller owns returned ArrayList (must deinit).
pub fn getSubnetBroadcasts(allocator: std.mem.Allocator) !std.ArrayList(std.Io.net.IpAddress) {
    var list: std.ArrayList(std.Io.net.IpAddress) = .empty;

    // Always include limited broadcast
    try list.append(allocator, std.Io.net.IpAddress{
        .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = protocol.DEFAULT_PORT },
    });

    if (builtin.os.tag == .windows) return list;

    // POSIX: enumerate interfaces via getifaddrs
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) return list;
    defer freeifaddrs(ifap);

    var ifa = ifap;
    while (ifa) |entry| : (ifa = entry.ifa_next) {
        if (entry.ifa_addr == null or entry.ifa_netmask == null) continue;
        if (entry.ifa_addr.?.sa_family != AF_INET) continue;
        if (entry.ifa_flags & IFF_UP == 0) continue;

        const sin = @as(*align(1) const sockaddr_in, @ptrCast(entry.ifa_addr));
        const sin_mask = @as(*align(1) const sockaddr_in, @ptrCast(entry.ifa_netmask));

        const ip: u32 = sin.sin_addr.s_addr; // host byte order (LE on macOS/Linux aarch64/x86_64)
        const mask: u32 = sin_mask.sin_addr.s_addr;

        // Skip loopback and zero addr (check in network byte order)
        const ip_be: u32 = @byteSwap(ip);
        if (ip == 0 or (ip_be >> 24) == 127) continue;

        const bc: u32 = ip | ~mask;
        // Normalize to big-endian for octet extraction
        const bc_be: u32 = @byteSwap(bc);
        if (bc_be == 0 or bc_be == 0xFFFFFFFF) continue; // invalid or already covered
        if (bc_be == ip_be) continue; // /32 point-to-point

        const bytes: [4]u8 = .{
            @truncate((bc_be >> 24) & 0xFF),
            @truncate((bc_be >> 16) & 0xFF),
            @truncate((bc_be >> 8) & 0xFF),
            @truncate(bc_be & 0xFF),
        };

        // Dedup
        var dup = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, &existing.ip4.bytes, &bytes)) { dup = true; break; }
        }
        if (!dup) {
            try list.append(allocator, std.Io.net.IpAddress{
                .ip4 = .{ .bytes = bytes, .port = protocol.DEFAULT_PORT },
            });
        }
    }
    return list;
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
        std.debug.print("[guest] Failed to read /proc/net/route: {}\n", .{err});
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
    // Use dedicated Threaded I/O — the passed-in io may be global_single_threaded
    // (Allocator.failing) on Windows service context, causing OutOfMemory in processSpawnWindows.
    _ = io;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const block_io = threaded.io();

    const result = try std.process.run(allocator, block_io, .{
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
                // Windows route table format: Network Netmask Gateway Interface Metric
                // Uses tokenize (not splitSequence) — fields are separated by
                // multiple spaces; splitSequence(" ") yields empty strings.
                var fields = std.mem.tokenizeScalar(u8, trimmed, ' ');
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


test "detectShell - returns valid string" {
    const shell = try detectShell(std.testing.allocator);
    defer std.testing.allocator.free(shell);
    // On POSIX, should be at least "/bin/sh" or the value of $SHELL
    try std.testing.expect(shell.len > 0);
}

test "detectShell - windows returns cmd.exe" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shell = try detectShell(std.testing.allocator);
    defer std.testing.allocator.free(shell);
    try std.testing.expectEqualStrings("cmd.exe", shell);
}

test "isPhysicalInterface - real interfaces" {
    try std.testing.expect(isPhysicalInterface("eth0"));
    try std.testing.expect(isPhysicalInterface("en0"));
    try std.testing.expect(isPhysicalInterface("wlan0"));
    try std.testing.expect(isPhysicalInterface("Ethernet"));
    try std.testing.expect(isPhysicalInterface("Wi-Fi"));
}

test "isPhysicalInterface - virtual interfaces excluded" {
    try std.testing.expect(!isPhysicalInterface("utun0"));
    try std.testing.expect(!isPhysicalInterface("tun0"));
    try std.testing.expect(!isPhysicalInterface("tap0"));
    try std.testing.expect(!isPhysicalInterface("llw0"));
    try std.testing.expect(!isPhysicalInterface("awdl0"));
    try std.testing.expect(!isPhysicalInterface("bridge0"));
    try std.testing.expect(!isPhysicalInterface("vmnet0"));
    try std.testing.expect(!isPhysicalInterface("docker0"));
    try std.testing.expect(!isPhysicalInterface("gif0"));
    try std.testing.expect(!isPhysicalInterface("stf0"));
    try std.testing.expect(!isPhysicalInterface("veth0"));
    try std.testing.expect(!isPhysicalInterface("vboxnet0"));
    try std.testing.expect(!isPhysicalInterface("virbr0"));
}

test "isPhysicalInterface - loopback excluded" {
    try std.testing.expect(!isPhysicalInterface("lo0"));
    try std.testing.expect(!isPhysicalInterface("lo"));
}

test "zigTarget - valid format" {
    const target = zigTarget();
    try std.testing.expect(target.len > 0);
    // Should contain arch (aarch64, x86_64, or x86)
    try std.testing.expect(
        std.mem.startsWith(u8, target, "aarch64") or
            std.mem.startsWith(u8, target, "x86_64") or
            std.mem.startsWith(u8, target, "x86"),
    );
    // Should contain OS
    try std.testing.expect(
        std.mem.containsAtLeast(u8, target, 1, "linux") or
            std.mem.containsAtLeast(u8, target, 1, "macos") or
            std.mem.containsAtLeast(u8, target, 1, "windows"),
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest TCP 主循环（替代 meshSessionLoop）
// ═══════════════════════════════════════════════════════════════════════════

/// Guest TCP 服务 — TCP listener + dpipe relay，每命令独立连接。
///
/// 1. 启动 LSA/UDP 发现线程（lsa.zig）
/// 2. TCP 监听端口 2121
/// 3. accept 循环 → SOCKS4a 握手 → 处理命令
/// 4. 每命令独立连接，命令结束即关闭
pub fn guestTcpLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    // ── LSA/UDP 发现线程 ──
    var mesh_opt: ?lsa.Mesh = null;
    var mesh_thread: ?std.Thread = null;
    var mesh_socket_opt: ?std.Io.net.Socket = null;

    start_mesh: {
        var broadcast_addrs = getSubnetBroadcasts(allocator) catch |err| {
            std.log.err("[guest] getSubnetBroadcasts failed: {}", .{err});
            break :start_mesh;
        };

        if (peer_mesh) |pm| {
            if (protocol.parsePeerMeshAddr(pm)) |peer_addr| {
                broadcast_addrs.append(allocator, peer_addr) catch |err| {
                    std.log.err("[guest] append peer-mesh failed: {}", .{err});
                };
            } else {
                std.log.err("[guest] invalid --peer-mesh '{s}'", .{pm});
            }
        }

        var mesh_threaded = std.Io.Threaded.init(allocator, .{});
        const mesh_io = mesh_threaded.io();

        const bind_addr = std.Io.net.IpAddress.parse("0.0.0.0", mesh_port) catch |err| {
            std.log.err("[guest] Mesh bind addr parse: {}", .{err});
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        const mesh_socket = bind_addr.bind(mesh_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
            std.log.err("[guest] Mesh UDP bind :{d}: {}", .{ mesh_port, err });
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        mesh_socket_opt = mesh_socket;

        const node_id = if (peer_mesh != null)
            lsa.deriveNodeId(info.mac, info.hostname) catch |err| {
                std.log.err("[guest] deriveNodeId: {}", .{err});
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            }
        else
            lsa.parseNodeId(info.mac) catch |err| {
                std.log.err("[guest] parseNodeId: {}", .{err});
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            };

        const node_info = std.fmt.allocPrint(allocator,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:guest\nstatus:serving",
            .{ info.hostname, info.ip, info.target, protocol.VERSION, info.shell },
        ) catch |err| {
            std.log.err("[guest] node_info alloc: {}", .{err});
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        mesh_opt = lsa.Mesh.init(allocator, node_id, node_info, mesh_socket, mesh_io, broadcast_addrs, getSubnetBroadcasts) catch |err| {
            std.log.err("[guest] Mesh init: {}", .{err});
            allocator.free(node_info);
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        mesh_thread = std.Thread.spawn(.{}, lsa.Mesh.run, .{&mesh_opt.?}) catch |err| {
            std.log.err("[guest] Mesh thread spawn: {}", .{err});
            mesh_opt.?.deinit();
            mesh_socket.close(mesh_io);
            mesh_opt = null;
            break :start_mesh;
        };

        std.log.info("[guest] LSA mesh started on UDP :{d}", .{mesh_port});
    }

    defer {
        if (mesh_thread) |t| {
            if (mesh_opt) |*m| m.signalShutdown();
            t.join();
        }
        if (mesh_opt) |*m| {
            const m_io = m.io;
            m.deinit();
            if (mesh_socket_opt) |s| s.close(m_io);
        }
    }

    if (mesh_opt == null) {
        std.log.err("[guest] Mesh failed to start", .{});
        return error.MeshInitFailed;
    }

    // ── TCP accept 循环 ──
    var listener = tcp.TcpListener.init(io, mesh_port) catch |err| {
        std.log.err("[guest] TCP listen :{d} failed: {}", .{ mesh_port, err });
        return error.TcpBindFailed;
    };
    defer listener.deinit();

    std.log.info("[guest] TCP server listening on :{d}", .{mesh_port});

    while (true) {
        if (shutdown) |s| {
            if (s.load(.acquire)) {
                std.log.info("[guest] Shutdown requested", .{});
                break;
            }
        }

        // Accept SOCKS4 连接
        var conn = listener.accept(info.hostname) catch |err| {
            if (err == error.WouldBlock) continue;
            std.log.err("[guest] accept failed: {}", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };

        // 处理单条命令
        handleOneCommand(io, allocator, info, &conn, shutdown) catch |err| {
            std.log.err("[guest] handleOneCommand: {}", .{err});
        };
        conn.deinit();
    }
}

/// 处理一条命令（单个 TCP 连接）。
/// 每条连接处理一条命令，命令结束即关闭。
fn handleOneCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *tcp.Connection,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    var rbuf: [262144]u8 = undefined;

    if (shutdown) |s| {
        if (s.load(.acquire)) return;
    }
    if (!conn.isAlive()) return;

    const n = conn.recv(&rbuf) catch |err| {
        std.log.err("[guest] recv error: {}", .{err});
        return;
    };
    if (n == 0) return;

    const msg_type: u8 = rbuf[0];
    const payload = rbuf[1..n];

    switch (msg_type) {
        @intFromEnum(protocol.MsgType.pty_exec_input) => {
            try handleExecCmd(io, allocator, info, conn, payload);
        },
        @intFromEnum(protocol.MsgType.upload_cmd) => {
            try handleUpload(io, allocator, conn, payload);
        },
        @intFromEnum(protocol.MsgType.download_cmd) => {
            try handleDownload(io, allocator, conn, payload);
        },
        @intFromEnum(protocol.MsgType.upgrade_cmd) => {
            try handleUpgradeCmd(io, allocator, conn, payload);
        },
        else => {
            std.log.info("[guest] Unknown msg type: {d}", .{msg_type});
        },
    }
}

/// 处理 exec 命令：dpipe_shell 创建 shell → 写入命令 → 流式读取输出 → 发送 exec_done。
fn handleExecCmd(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *tcp.Connection,
    payload: []const u8,
) !void {
    _ = io;
    const input = protocol.parsePtyExecInput(payload) orelse {
        std.log.err("[guest] parsePtyExecInput failed", .{});
        return;
    };

    std.log.info("[guest] exec cmd_id={s} cmd={s}", .{ input.cmd_id, input.command });

    // 使用 dpipe_shell 创建 shell 管道
    const shell = dpipe_shell.create(allocator, info.shell) catch |err| {
        std.log.err("[guest] dpipe_shell.create failed: {}", .{err});
        const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
        defer allocator.free(done_msg);
        _ = conn.sendAndFlush(done_msg, 0) catch {};
        return;
    };
    defer shell.close();

    // 写入命令到 shell（命令已由 Host 端 ipc.zig buildCmdWithMarker 添加 MDELIM 标记）
    shell.write(input.command) catch |err| {
        std.log.err("[guest] shell write failed: {}", .{err});
        const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
        defer allocator.free(done_msg);
        _ = conn.sendAndFlush(done_msg, 0) catch {};
        return;
    };

    // 流式读取 shell 输出 → 发送 pty_exec_output 帧
    var output_buf: [4096]u8 = undefined;
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(allocator);

    while (true) {
        const nr = shell.read(&output_buf) catch |err| {
            std.log.err("[guest] shell read error: {}", .{err});
            break;
        };
        if (nr == 0) break; // EOF

        accumulated.appendSlice(allocator, output_buf[0..nr]) catch continue;

        // 扫描 MDELIM 标记（protocol.scanForMarker 会剥离标记）
        const marker_result = protocol.scanForMarker(&accumulated);
        if (marker_result.found) {
            if (accumulated.items.len > 0) {
                const output_msg = protocol.buildPtyExecOutput(allocator, input.cmd_id, accumulated.items) catch continue;
                defer allocator.free(output_msg);
                _ = conn.sendAndFlush(output_msg, 0) catch {};
            }

            const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, marker_result.exit_code) catch break;
            defer allocator.free(done_msg);
            _ = conn.sendAndFlush(done_msg, 0) catch {};
            std.log.info("[guest] exec done: cmd_id={s} exit={d}", .{ input.cmd_id, marker_result.exit_code });
            return;
        }
    }

    // shell 异常关闭（无 MDELIM 标记）
    const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
    defer allocator.free(done_msg);
    _ = conn.sendAndFlush(done_msg, 0) catch {};
    std.log.info("[guest] exec done (shell closed): cmd_id={s}", .{input.cmd_id});
}

/// 处理 upload：upload_cmd 帧后的原始字节 → dpipe_file.writeFile → upload_result。
fn handleUpload(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *tcp.Connection,
    payload: []const u8,
) !void {
    const cmd = protocol.parseUploadCmd(payload) orelse {
        std.log.err("[guest] parseUploadCmd failed", .{});
        return;
    };

    std.log.info("[guest] upload: cmd_id={s} path={s} size={d}", .{ cmd.cmd_id, cmd.path, cmd.file_size });

    // 创建目标管道（写入 temp 文件，验证 SHA256，atomic rename）
    const file_pipe = dpipe_file.writeFile(allocator, io, cmd.path, cmd.file_hash) catch |err| {
        std.log.err("[guest] writeFile failed: {}", .{err});
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch {};
        return;
    };
    // defer file_pipe.close(); — 在 line 1078 显式关闭，避免双 close

    // 从 TCP 直接读取原始字节（无帧协议）→ 写入 file_pipe
    var buf: [65536]u8 = undefined;
    var remaining: u32 = cmd.file_size;
    while (remaining > 0) {
        const to_read = @min(buf.len, remaining);
        const nr = tcp.sockRead(conn.fd, buf[0..to_read].ptr, to_read);
        if (nr <= 0) {
            std.log.err("[guest] upload: short read ({d} remaining)", .{remaining});
            break;
        }
        file_pipe.write(buf[0..@intCast(nr)]) catch |err| {
            std.log.err("[guest] upload: write failed: {}", .{err});
            break;
        };
        remaining -= @intCast(nr);
    }

    // close 验证 SHA256 + atomic rename
    file_pipe.close();

    const exit_code: i32 = if (remaining == 0) 0 else -1;
    std.log.info("[guest] upload result: cmd_id={s} exit={d}", .{ cmd.cmd_id, exit_code });
    const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, exit_code) catch return;
    defer allocator.free(resp);
    _ = conn.sendAndFlush(resp, 0) catch {};
}

/// 处理 upgrade_cmd（Host→Guest 直推升级）：接收二进制流 → SHA256 校验 → 通知 utmmd。
/// 流程与 upload 类似，但写入固定路径 /opt/utmm/utmm.new 并信号通知 utmmd。
fn handleUpgradeCmd(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *tcp.Connection,
    payload: []const u8,
) !void {
    const cmd = protocol.parseUpgradeCmd(payload) orelse {
        std.log.err("[guest] parseUpgradeCmd failed", .{});
        return;
    };

    std.log.info("[guest] upgrade: cmd_id={s} target={s} size={d}", .{ cmd.cmd_id, cmd.target, cmd.file_size });

    const tmp_path = if (@import("builtin").os.tag == .windows)
        "C:\\opt\\utmm\\utmm.new.exe"
    else
        "/opt/utmm/utmm.new";

    // 清理可能残留的旧 temp 文件
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // 创建 temp 文件
    var write_buf: [65536]u8 = undefined;
    const tmp_file = if (@import("builtin").os.tag != .windows)
        std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = @enumFromInt(0o755) })
    else
        std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    const file = tmp_file catch |err| {
        std.log.err("[guest] upgrade: create temp file {s}: {}", .{ tmp_path, err });
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch {};
        return;
    };
    defer file.close(io);

    // 增量 SHA256 计算
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining: u32 = cmd.file_size;
    while (remaining > 0) {
        const to_read = @min(write_buf.len, remaining);
        const nr = tcp.sockRead(conn.fd, &write_buf, to_read);
        if (nr <= 0) {
            std.log.err("[guest] upgrade: short read ({d} remaining)", .{remaining});
            break;
        }
        const slice = write_buf[0..@intCast(nr)];
        hasher.update(slice);
        _ = file.writeStreamingAll(io, slice) catch |err| {
            std.log.err("[guest] upgrade: write temp file: {}", .{err});
            break;
        };
        remaining -= @intCast(nr);
    }

    file.close(io);

    if (remaining != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch {};
        return;
    }

    // SHA256 校验
    var computed_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&computed_hash);

    // 比较 hex - cmd.sha256_hex 是 64 字符的 hex 字符串
    var hex_buf: [64]u8 = undefined;
    for (computed_hash, 0..) |byte, i| {
        const h = "0123456789abcdef";
        hex_buf[i * 2] = h[byte >> 4];
        hex_buf[i * 2 + 1] = h[byte & 0x0f];
    }
    const hash_ok = std.mem.eql(u8, cmd.sha256_hex, &hex_buf);
    if (!hash_ok) {
        std.log.err("[guest] upgrade: SHA256 mismatch", .{});
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch {};
        return;
    }

    std.log.info("[guest] upgrade: SHA256 verified, {d} bytes → {s}", .{ cmd.file_size, tmp_path });

    // 发送成功响应
    const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, 0) catch return;
    defer allocator.free(resp);
    _ = conn.sendAndFlush(resp, 0) catch {};

    // 通过 shm 通知 utmmd 执行升级
    if (shm.open()) |h| {
        defer shm.detach(h);
        h.cmd = @intFromEnum(shm.Cmd.upgrade);
        @memset(&h.cmd_data, 0);
        const copy_len = @min(tmp_path.len, h.cmd_data.len - 1);
        @memcpy(h.cmd_data[0..copy_len], tmp_path[0..copy_len]);
        h.utmm_state = @intFromEnum(shm.UtmmState.stopping);
        std.log.info("[guest] upgrade: utmmd signalled, exiting for restart", .{});
    } else |err| {
        std.log.err("[guest] upgrade: shm.open failed: {}", .{err});
    }
}

/// 处理 download：dpipe_file.readFile → 原始字节流发送到 TCP。
fn handleDownload(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *tcp.Connection,
    payload: []const u8,
) !void {
    const cmd = protocol.parseDownloadCmd(payload) orelse {
        std.log.err("[guest] parseDownloadCmd failed", .{});
        return;
    };

    std.log.info("[guest] download: cmd_id={s} path={s}", .{ cmd.cmd_id, cmd.path });

    // 创建读取管道
    const file_pipe = dpipe_file.readFile(allocator, io, cmd.path) catch |err| {
        std.log.err("[guest] readFile failed: {}", .{err});
        // 发送空文件（0字节）作为错误信号
        return;
    };
    defer file_pipe.close();

    // 从 file_pipe 流式读取 → 写入 TCP（原始字节）
    var buf: [65536]u8 = undefined;
    while (true) {
        const nr = file_pipe.read(&buf) catch |err| {
            std.log.err("[guest] download read error: {}", .{err});
            break;
        };
        if (nr == 0) break; // EOF

        _ = tcp.sockWrite(conn.fd, buf[0..nr].ptr, nr);
    }

    std.log.info("[guest] download complete: {s}", .{cmd.path});
}


// ═══════════════════════════════════════════════════════════════════════════
// Guest mode entry points (曾 guest.zig)
// ═══════════════════════════════════════════════════════════════════════════

/// Guest mode entry point (from std.process.Init)
pub fn guestRun(init: std.process.Init, cli: @import("main.zig").CliArgs) !void {
    return guestRunWithIo(init.io, init.gpa, cli, null);
}

/// Guest mode entry point (called from Windows service or direct process start).
/// shutdown is an optional atomic flag — when set (Windows service stop), the
/// mesh session loop exits cleanly so the SCM receives STOPPED instead of a
/// broken pipe error.
pub fn guestRunWithIo(io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs, shutdown: ?*std.atomic.Value(bool)) !void {
    // Collect system information (sync, uses blocking Io for process.run etc.)
    var sysinfo = try getSystemInfo(io, gpa);
    defer {
        gpa.free(sysinfo.hostname);
        gpa.free(sysinfo.ip);
        gpa.free(sysinfo.mac);
        gpa.free(sysinfo.iface_name);
        gpa.free(sysinfo.shell);
    }

    if (cli.hostname) |n| {
        gpa.free(sysinfo.hostname);
        sysinfo.hostname = try gpa.dupe(u8, n);
    }

    std.debug.print("[guest] Hostname: {s}\n", .{sysinfo.hostname});
    std.debug.print("[guest] Target: {s}\n", .{sysinfo.target});
    std.debug.print("[guest] IP: {s}\n", .{sysinfo.ip});
    std.debug.print("[guest] MAC: {s}\n", .{sysinfo.mac});
    std.debug.print("[guest] Shell: {s}\n", .{sysinfo.shell});

    // Ensure CWD is /opt/utmm/ (or C:\opt\utmm\ on Windows)
    if (builtin.os.tag == .windows) {
        const msvcrt = struct {
            extern "c" fn _chdir(path: [*:0]const u8) c_int;
        };
        if (msvcrt._chdir("C:\\opt\\utmm\\") != 0) {
            std.log.warn("[guest] chdir to C:\\opt\\utmm failed", .{});
        }
    } else {
        const libc = struct {
            extern "c" fn chdir(path: [*:0]const u8) c_int;
        };
        if (libc.chdir("/opt/utmm") != 0) {
            std.log.warn("[guest] chdir to /opt/utmm failed", .{});
        }
    }

    // TCP session loop — per-command TCP connections with SOCKS4 handshake.
    try guestTcpLoop(io, gpa, sysinfo, cli.mesh_port, cli.peer_mesh, shutdown);
}
