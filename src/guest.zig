//! Guest 端模块 — 系统信息采集 + 命令处理 + LSA mesh 启动。
//!
//! Guest 在 TCP :2121 上侦听，通过 SOCKS5 握手接受 Host 连接，
//! 每条 TCP 连接处理一条命令（exec/upload/download），命令结束即关闭连接。
//! 使用 dpipe 抽象层进行 Shell 管理和文件 I/O。

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const Io = std.Io;
const net = std.Io.net;
const protocol = @import("protocol.zig");
const lsa = @import("lsa.zig");
const tcp = @import("tcp.zig");
const socks5 = @import("socks5.zig");
const svc = @import("svc.zig");
const dpipe = @import("dpipe.zig");
const dpipe_shell = @import("dpipe_shell.zig");
const dpipe_file = @import("dpipe_file.zig");
const sshpass = @import("sshpass.zig");
const shm = @import("shm.zig");

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
            std.log.err("[guest] read MAC failed: path={s} err={}", .{ path, err });
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

/// Check if an IPv4 address is in a known VM NAT range (QEMU/VirtualBox default).
/// These addresses are typically unreachable from the Host on multi-NIC VMs.
fn isLikelyVmNat(bytes: [4]u8) bool {
    // 10.0.2.0/24 — QEMU user-mode networking / VirtualBox NAT default
    if (bytes[0] == 10 and bytes[1] == 0 and bytes[2] == 2) return true;
    // 192.168.122.0/24 — libvirt default NAT
    if (bytes[0] == 192 and bytes[1] == 168 and bytes[2] == 122) return true;
    return false;
}

/// Physical NIC IP address and interface name detected by detectUnixIp.
const IpInfo = struct { ip: []const u8, iface_name: []const u8 };

/// One-stop system info collection: hostname + IP + MAC + target.
/// Enumerate physical NICs via getifaddrs(), prefer non-NAT addresses
/// (skip known VM NAT ranges like 10.0.2.x, 192.168.122.x).
/// Returns the first non-NAT physical IPv4, or the first physical IPv4 if all
/// are in NAT ranges. Returns null if no suitable interface found.
fn detectUnixIp(allocator: std.mem.Allocator) !?IpInfo {
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) return null;
    defer freeifaddrs(ifap);

    var fallback: ?IpInfo = null;

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
        std.log.info("[guest] physical NIC: iface={s} ip={s}", .{ name, ip });

        // Return immediately if this is a non-NAT address (preferred)
        if (!isLikelyVmNat(bytes)) {
            // 之前如果已保存 NAT fallback，释放其分配
            if (fallback) |*fb| {
                allocator.free(fb.ip);
                allocator.free(fb.iface_name);
                fallback = null;
            }
            return .{ .ip = ip, .iface_name = iface_name };
        }
        // Otherwise save as fallback and keep scanning for a better interface
        if (fallback == null) {
            fallback = .{ .ip = ip, .iface_name = iface_name };
        }
    }
    // All physical NICs are in VM NAT ranges — return the first one as fallback
    if (fallback) |fb| return fb;
    return null;
}

pub fn getSystemInfo(io: std.Io, allocator: std.mem.Allocator) !SystemInfo {

    const target = zigTarget();

    // Get hostname (lowercased, FQDN suffix like .local stripped for consistency)
    const hostname: []const u8 = blk: {
        const raw = if (builtin.os.tag == .windows) blk2: {
            const name_ptr = std.c.getenv("COMPUTERNAME");
            break :blk2 if (name_ptr) |ptr|
                try allocator.dupe(u8, std.mem.span(ptr))
            else
                try allocator.dupe(u8, "unknown");
        } else blk2: {
            var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const name = try std.posix.gethostname(&buf);
            break :blk2 try allocator.dupe(u8, name);
        };
        // Lowercase + strip FQDN suffix (e.g. "LAPTOP.local" → "laptop")
        for (raw) |*c| c.* = std.ascii.toLower(c.*);
        if (std.mem.indexOfScalar(u8, raw, '.')) |dot_pos| {
            break :blk raw[0..dot_pos];
        }
        break :blk raw;
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
            std.log.info("[guest] IP not ready: attempt={}/{}, waiting={d}ms", .{ attempt + 1, MAX_IP_RETRIES, IP_RETRY_DELAY_MS });
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
        std.log.warn("[guest] read /proc/net/route failed: {}", .{err});
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

test "isLikelyVmNat - QEMU/VirtualBox default" {
    try std.testing.expect(isLikelyVmNat(.{ 10, 0, 2, 15 }));
    // IPs on 10.0.2.0/24 should match
    try std.testing.expect(isLikelyVmNat(.{ 10, 0, 2, 1 }));
    try std.testing.expect(isLikelyVmNat(.{ 10, 0, 2, 254 }));
}

test "isLikelyVmNat - libvirt default" {
    try std.testing.expect(isLikelyVmNat(.{ 192, 168, 122, 1 }));
    try std.testing.expect(isLikelyVmNat(.{ 192, 168, 122, 100 }));
}

test "isLikelyVmNat - non-NAT addresses" {
    try std.testing.expect(!isLikelyVmNat(.{ 192, 168, 64, 6 }));
    try std.testing.expect(!isLikelyVmNat(.{ 192, 168, 105, 2 }));
    try std.testing.expect(!isLikelyVmNat(.{ 192, 168, 5, 15 }));
    try std.testing.expect(!isLikelyVmNat(.{ 172, 16, 0, 1 }));
    try std.testing.expect(!isLikelyVmNat(.{ 10, 1, 0, 1 }));
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

test "partialMarkerKeepLen - no marker prefix,全部可发送" {
    // 尾部与 MDELIM: 无前缀关系 → 全部可发送
    try std.testing.expectEqual(@as(usize, 5), partialMarkerKeepLen("hello"));
    try std.testing.expectEqual(@as(usize, 3), partialMarkerKeepLen("abc"));
    try std.testing.expectEqual(@as(usize, 0), partialMarkerKeepLen(""));
}

test "partialMarkerKeepLen - 尾部是 MDELIM 前缀的保留" {
    // "data MDEL" → 尾部 "MDEL" 是 "MDELIM:" 前缀，保留 4 字节
    try std.testing.expectEqual(@as(usize, 5), partialMarkerKeepLen("data MDEL"));
    // "data MDELI" → 保留 5 字节
    try std.testing.expectEqual(@as(usize, 5), partialMarkerKeepLen("data MDELI"));
    // "data MDELIM" → 保留 6 字节
    try std.testing.expectEqual(@as(usize, 5), partialMarkerKeepLen("data MDELIM"));
    // "data M" → 保留 1 字节
    try std.testing.expectEqual(@as(usize, 5), partialMarkerKeepLen("data M"));
}

test "partialMarkerKeepLen - 尾部非前缀字符则全部发送" {
    // "data X" → 'X' 不是 "MDELIM:" 任意前缀 → 全部发送
    try std.testing.expectEqual(@as(usize, 6), partialMarkerKeepLen("data X"));
    // "data preM" → 尾部 "M" 是 "MDELIM:" 前缀 → 保留 1 字节，发送前 8 字节
    try std.testing.expectEqual(@as(usize, 8), partialMarkerKeepLen("data preM"));
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest TCP 主循环（替代 meshSessionLoop）
// ═══════════════════════════════════════════════════════════════════════════

/// Guest TCP 服务 — TCP listener + dpipe relay，每命令独立连接。
///
/// 1. 启动 LSA/UDP 发现线程（lsa.zig）
/// 2. TCP 监听端口 2121
/// 3. accept 循环 → SOCKS5 握手 → 处理命令
/// 4. 每命令独立连接，命令结束即关闭

/// Periodic /etc/hosts sync for Guest: self + gateway entries.
/// Runs every 30 seconds to keep the hosts file current even if
/// the Host IP changes (unlikely but possible in UTM networks).
fn guestHostsSync(
    zio_io_unused: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    shutdown: ?*std.atomic.Value(bool),
) void {
    _ = zio_io_unused;
    // Use a separate blocking IO for getDefaultGateway (which calls
    // std.process.run) and for sleep. zio's IOCP-based IO on Windows
    // does not support blocking std.process.run or std.Io.sleep.
    var block_threaded = std.Io.Threaded.init(allocator, .{});
    const block_io = block_threaded.io();

    while (true) {
        // Sleep first — no rush on initial startup
        std.Io.sleep(block_io, std.Io.Duration.fromSeconds(30), .awake) catch break;
        if (shutdown) |s| {
            if (s.load(.acquire)) break;
        }

        // Resolve gateway IP (Host IP in UTM network)
        const gateway_ip = getDefaultGateway(block_io, allocator) catch |err| {
            std.log.warn("[guest] hostsSync: getDefaultGateway failed: {}", .{err});
            continue;
        };
        defer allocator.free(gateway_ip);

        // Build entries: self + gateway
        var entries: std.ArrayList(lsa.HostEntry) = .empty;
        defer entries.deinit(allocator);

        if (info.ip.len > 0 and info.hostname.len > 0) {
            entries.append(allocator, .{ .ip = info.ip, .name = info.hostname }) catch continue;
        }
        if (gateway_ip.len > 0) {
            entries.append(allocator, .{ .ip = gateway_ip, .name = "gateway" }) catch continue;
        }

        const hosts_path = if (builtin.os.tag == .windows)
            "C:\\Windows\\System32\\drivers\\etc\\hosts"
        else
            "/etc/hosts";
        lsa.updateHosts(block_io, allocator, hosts_path, entries.items) catch |err| {
            std.log.warn("[guest] hostsSync: updateHosts {s}: {}", .{ hosts_path, err });
        };
    }
}

/// SOCKS5 转发线程上下文（堆分配，detach 线程负责释放）。
pub const ForwardCtx = struct {
    io: std.Io,
    client_fd: std.posix.socket_t,
    next_hop_ip: std.Io.net.IpAddress,
    hostname: []const u8,
    target_port: u16,
    allocator: std.mem.Allocator,
    limit: ?*tcp.ConnLimit = null,

    fn maybeReleaseLimit(self: *const ForwardCtx) void {
        if (self.limit) |l| l.release();
    }
};

/// 转发 detach 线程入口：释放 ctx 并调用 socks5Forward。
pub fn forwardThreadFn(ctx: *ForwardCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.allocator.free(ctx.hostname);
    defer ctx.maybeReleaseLimit();
    socks5.forward(ctx.io, ctx.client_fd, ctx.next_hop_ip, ctx.hostname, ctx.target_port);
}

pub fn guestTcpLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
    shm_handle: ?*volatile shm.ShmLayout,
) !void {
    // ── LSA/UDP 发现线程 ──
    var mesh_opt: ?lsa.Mesh = null;
    var mesh_thread: ?std.Thread = null;
    var mesh_socket_opt: ?std.Io.net.Socket = null;
    var hosts_sync_handle: ?std.Thread = null;

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

        const mesh_socket = tcp.createMeshUdpSocket(mesh_port) catch |err| {
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
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nconpty:{s}\nrole:guest\nstatus:serving",
            .{ info.hostname, info.ip, info.target, protocol.VERSION, info.shell, if (sshpass.conptyAvailable()) "yes" else "no" },
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
        if (hosts_sync_handle) |*h| {
            // Signal shutdown to break the sleep loop, then join
            if (shutdown) |s| s.store(true, .release);
            h.join();
        }
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

    // ── Periodic /etc/hosts sync ──
    // Use std.Thread.spawn instead of zio.spawnBlocking because guestHostsSync
    // calls std.Io.sleep() which requires the zio event loop. On Windows (IOCP),
    // spawnBlocking tasks cannot use event-loop-dependent IO operations.
    // TODO: switch to zio.spawnBlocking once zio supports async ops in blocking tasks.
    hosts_sync_handle = std.Thread.spawn(.{}, guestHostsSync, .{ io, allocator, info, shutdown }) catch null;

    // ── TCP accept 循环 ──
    var listener = tcp.TcpListener.init(io, mesh_port) catch |err| {
        std.log.err("[guest] TCP listen :{d} failed: {}", .{ mesh_port, err });
        return error.TcpBindFailed;
    };
    defer listener.deinit();

    var conn_limit = tcp.ConnLimit.init(tcp.DEFAULT_MAX_CONNS);
    var group: zio.Group = .init;
    std.log.info("[guest] TCP server listening on :{d}", .{mesh_port});

    while (true) {
        if (shutdown) |s| {
            if (s.load(.acquire)) {
                std.log.info("[guest] Shutdown requested", .{});
                break;
            }
        }

        // 更新心跳 — utmmd 监控此字段，10s 无更新触发重启。
        // 放在 accept 循环顶部确保每次循环迭代都刷新心跳。
        if (shm_handle) |h| {
            shm.writeUtmmHeartbeat(h, io);
        }

        // Accept TCP 连接（不含 SOCKS5 握手）
        const fd = listener.acceptRaw() catch |err| {
            if (err == error.WouldBlock) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                continue;
            }
            std.log.err("[guest] accept failed: {}", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };

        // 读取 SOCKS5 请求
        var req_buf: [tcp.MAX_HOSTNAME + 1]u8 = undefined;
        const req = socks5.readRequestBuf(fd, req_buf[0..]) catch |err| {
            std.log.err("[guest] SOCKS5 read failed: {}", .{err});
            tcp.sockClose(fd);
            continue;
        };

        // BIND / UDP_ASSOCIATE — handle before hostname-based routing
        if (req.cmd == socks5.SOCKS_CMD_BIND or req.cmd == socks5.SOCKS_CMD_UDP_ASSOCIATE) {
            if (!conn_limit.tryAcquire()) {
                socks5.replyRejected(fd);
                tcp.sockClose(fd);
                continue;
            }
            if (req.cmd == socks5.SOCKS_CMD_BIND) {
                group.spawnBlocking(socks5.socks5BindWithLimit, .{ io, fd, &conn_limit }) catch {
                    conn_limit.release();
                    socks5.replyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                std.log.info("[guest] BIND accepted", .{});
            } else {
                group.spawnBlocking(socks5.udpAssociateWithLimit, .{ io, fd, &conn_limit }) catch {
                    conn_limit.release();
                    socks5.replyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                std.log.info("[guest] UDP ASSOCIATE accepted", .{});
            }
            continue;
        }

        // 三路 dispatch（CMD=CONNECT）
        if (std.mem.eql(u8, req.hostname, info.hostname)) {
            // 目标是本机
            if (req.port == mesh_port) {
                // utmm 内部帧协议 — 连接限制计数，名额所有权随线程转移
                if (!conn_limit.tryAcquire()) {
                    socks5.replyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                }
                socks5.replyOk(fd);
                // 帧命令（exec 可能运行数分钟）移出 accept 循环 — 内联处理会阻塞
                // 循环，使该 Guest 的所有后续命令排队。std.Thread.spawn + detach
                // （先例 guestHostsSync）：分钟级阻塞任务不占 zio 线程池槽；
                // 线程独占 fd 与 limit 名额，命令结束或断连取消后自清理。
                const task = GuestCmdTask{
                    .io = io,
                    .allocator = allocator,
                    .info = info,
                    .fd = fd,
                    .shutdown = shutdown,
                    .shm_handle = shm_handle,
                    .limit = &conn_limit,
                };
                if (std.Thread.spawn(.{}, guestCmdThread, .{task})) |t| {
                    t.detach();
                } else |_| {
                    std.log.err("[guest] cmd thread spawn failed", .{});
                    tcp.sockClose(fd);
                    conn_limit.release();
                }
                continue;
            } else {
                // 本机 localhost relay — 连接限制计数
                if (!conn_limit.tryAcquire()) {
                    socks5.replyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                }
                errdefer conn_limit.release();
                group.spawnBlocking(socks5.localRelayWithLimit, .{ io, fd, req.port, &conn_limit }) catch {
                    socks5.replyRejected(fd);
                    tcp.sockClose(fd);
                    continue;
                };
                std.log.info("[guest] local relay :{d}", .{req.port});
            }
        } else {
            // 目标不是本机 — Guest 不做链式转发，统一经 Host (gateway) 中转
            std.log.info("[guest] reject non-self target {s}:{d}", .{ req.hostname, req.port });
            socks5.replyRejected(fd);
            tcp.sockClose(fd);
        }
    }
}

/// 帧命令线程任务：fd 与连接限制名额所有权随线程转移。
const GuestCmdTask = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    fd: tcp.socket_t,
    shutdown: ?*std.atomic.Value(bool),
    shm_handle: ?*volatile shm.ShmLayout,
    limit: *tcp.ConnLimit,
};

/// 每连接独立线程处理一条帧命令（exec/upload/download/upgrade）。
/// detach：命令结束（或断连取消）后自清理 fd 与 limit 名额。
/// 生命周期与既有 localRelay 任务一致：进程退出即终点（guestTcpLoop
/// 返回 = 服务停止 = 进程退出），limit 指针不会先于线程失效。
fn guestCmdThread(task: GuestCmdTask) void {
    defer task.limit.release();
    var conn = protocol.Connection{ .fd = task.fd, .alive = true };
    defer conn.deinit(); // shutdown + close 恰好一次
    handleOneCommand(task.io, task.allocator, task.info, &conn, task.shutdown, task.shm_handle) catch |err| {
        std.log.err("[guest] handleOneCommand: {}", .{err});
    };
}

/// 处理一条命令（单个 TCP 连接）。
/// 每条连接处理一条命令，命令结束即关闭。
pub fn handleOneCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *protocol.Connection,
    shutdown: ?*std.atomic.Value(bool),
    shm_handle: ?*volatile shm.ShmLayout,
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
            try handleExecCmd(io, allocator, info, conn, payload, shm_handle);
        },
        @intFromEnum(protocol.MsgType.upload_cmd) => {
            try handleUpload(io, allocator, conn, payload, shm_handle);
        },
        @intFromEnum(protocol.MsgType.download_cmd) => {
            try handleDownload(io, allocator, conn, payload, shm_handle);
        },
        @intFromEnum(protocol.MsgType.upgrade_cmd) => {
            try handleUpgradeCmd(io, allocator, conn, payload, shm_handle);
        },
        else => {
            std.log.info("[guest] Unknown msg type: {d}", .{msg_type});
        },
    }
}

/// exec 断连 watcher 参数（按值拷贝进线程）。
/// Host 发完首帧后本连接不再有数据 — conn 上任何可读事件（EOF/错误/垃圾
/// 字节）= Host 侧已断开（其 execOnGuestStream 在客户端断连时 shutdown 本连接）。
const ConnWatch = struct {
    fd: tcp.socket_t,
    done: *std.atomic.Value(bool),
    shell: dpipe.DuplexPipe,
    cmd_id: []const u8,

    fn run(w: @This()) void {
        // 轮询模式（250ms）：Windows 下接受的 SOCKET 继承监听端的 FIONBIO
        // 非阻塞模式，裸 sockRead 会在 WSAEWOULDBLOCK 上忙转。
        while (!w.done.load(.acquire)) {
            if (!tcp.sockPollReadable(w.fd, 250)) continue;
            var b: [1]u8 = undefined;
            _ = tcp.sockRead(w.fd, &b, 1);
            // 主线程 done.store 先于其 sockShutdown — 唤醒后再查一次，
            // 已结束即为自然完成，不得误杀
            if (w.done.load(.acquire)) return;
            std.log.warn("[guest] exec cancelled (host disconnect): cmd_id={s}", .{w.cmd_id});
            dpipe_shell.requestKill(w.shell);
            return;
        }
    }
};

/// 处理 exec 命令：dpipe_shell 创建 shell → 写入命令 → 流式读取输出 → 发送 exec_done。
pub fn handleExecCmd(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *protocol.Connection,
    payload: []const u8,
    shm_handle: ?*volatile shm.ShmLayout,
) !void {
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
        _ = conn.sendAndFlush(done_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
        return;
    };
    defer shell.close();

    // 断连取消 watcher：触发即杀 shell 进程组（requestKill → 主循环阻塞的
    // shell.read 得到 EOF 退出，走"shell 异常关闭"收尾）。
    var conn_done = std.atomic.Value(bool).init(false);
    const cw = ConnWatch{ .fd = conn.fd, .done = &conn_done, .shell = shell, .cmd_id = input.cmd_id };
    const conn_watcher = std.Thread.spawn(.{}, ConnWatch.run, .{cw}) catch null;
    defer {
        // 自然结束路径：done 先于 shutdown 置位 — watcher 被唤醒后必先见
        // done=true，不会误判取消。join 先于 defer shell.close()（LIFO），
        // ShellCtx 在 join 期间仍有效；conn 的 close 由外层 guestCmdThread 稍后执行。
        conn_done.store(true, .release);
        tcp.sockShutdown(conn.fd, 2); // 立即唤醒 watcher 的 poll 等待
        if (conn_watcher) |t| t.join();
    }

    // 写入命令到 shell（命令已由 Host 端 ipc.zig buildCmdWithMarker 添加 MDELIM 标记）
    shell.write(input.command) catch |err| {
        std.log.err("[guest] shell write failed: {}", .{err});
        const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
        defer allocator.free(done_msg);
        _ = conn.sendAndFlush(done_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
        return;
    };

    // 流式读取 shell 输出 → 分块发送 pty_exec_output 帧。
    // 每块输出在确认不含 MDELIM 标记前缀后立即发送，避免：
    //   1. 全量累积导致单帧超过 Host 接收缓冲（BufferTooSmall → 输出丢失）
    //   2. shell 异常退出（EOF）时已累积输出丢失
    var output_buf: [4096]u8 = undefined;
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(allocator);

    while (true) {
        // 更新心跳 — 长时间运行的命令可能在 shell.read() 阻塞。
        // 每次成功读取后刷新心跳，避免 utmmd 误判超时。
        if (shm_handle) |h| {
            shm.writeUtmmHeartbeat(h, io);
        }

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
                _ = conn.sendAndFlush(output_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
            }

            const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, marker_result.exit_code) catch break;
            defer allocator.free(done_msg);
            _ = conn.sendAndFlush(done_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
            std.log.info("[guest] exec done: cmd_id={s} exit={d}", .{ input.cmd_id, marker_result.exit_code });
            return;
        }

        // 未命中：把确定不含部分标记的前缀立即发送，只保留尾部可能是
        // "MDELIM:" 前缀（1~6 字节）的部分，避免标记被跨块拆断。
        const send_len = partialMarkerKeepLen(accumulated.items);
        if (send_len > 0) {
            const chunk = accumulated.items[0..send_len];
            const output_msg = protocol.buildPtyExecOutput(allocator, input.cmd_id, chunk) catch continue;
            defer allocator.free(output_msg);
            _ = conn.sendAndFlush(output_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
            // 移除已发送部分，仅保留尾部前缀
            std.mem.copyForwards(u8, accumulated.items[0 .. accumulated.items.len - send_len], accumulated.items[send_len..]);
            accumulated.shrinkRetainingCapacity(accumulated.items.len - send_len);
        }
    }

    // shell 异常关闭（无 MDELIM 标记）——先把剩余累积输出发出（修 Bug 2），再发 done
    if (accumulated.items.len > 0) {
        const output_msg = protocol.buildPtyExecOutput(allocator, input.cmd_id, accumulated.items) catch {
            const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
            defer allocator.free(done_msg);
            _ = conn.sendAndFlush(done_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
            return;
        };
        defer allocator.free(output_msg);
        _ = conn.sendAndFlush(output_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
    }

    const done_msg = protocol.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
    defer allocator.free(done_msg);
    _ = conn.sendAndFlush(done_msg, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
    std.log.info("[guest] exec done (shell closed): cmd_id={s}", .{input.cmd_id});
}

/// 计算可安全发送的字节数：返回 accumulated 前缀中"确定不含部分 MDELIM 标记"的长度。
/// 尾部最多保留 6 字节（可能是 "MDELIM:" 的任意前缀），其余全部可发送。
/// 若尾部与 "MDELIM:" 无任何前缀关系，则全部可发送（返回 items.len）。
fn partialMarkerKeepLen(items: []const u8) usize {
    const marker = "MDELIM:";
    // 尾部最多检查 marker.len - 1 = 6 字节（完整 7 字节标记在上层已 scanForMarker 命中剥离）
    const max_tail = marker.len - 1;
    const tail_start = if (items.len > max_tail) items.len - max_tail else 0;
    const tail = items[tail_start..];

    // 找到尾部能匹配 marker 前缀的最长长度
    var keep: usize = 0;
    var i: usize = tail.len;
    while (i > 0) : (i -= 1) {
        // tail[tail.len - i ..] 是尾部最后 i 字节；若它等于 marker[0..i] 则为前缀
        const suffix = tail[tail.len - i ..];
        if (std.mem.eql(u8, suffix, marker[0..i])) {
            keep = i;
            break;
        }
    }

    return items.len - keep;
}

/// 从 TCP 连接读取并丢弃指定字节数。
/// 用于同版本升级跳过时消费 Host 已发送的二进制流。
fn discardBytes(fd: tcp.socket_t, remaining: u32) !void {
    var buf: [65536]u8 = undefined;
    var left: u64 = remaining;
    while (left > 0) {
        const to_read: usize = @min(buf.len, @as(usize, @intCast(left)));
        const nr = tcp.sockRead(fd, &buf, to_read);
        if (nr <= 0) return error.ReadFailed;
        left -= @intCast(nr);
    }
}

/// 通用文件接收：从 TCP 连接读取二进制流，写入 {prefix}.<sha256>.tmp 临时文件。
/// 使用 OS 排他锁（flock/dwShareMode=0），进程崩溃时自动释放。
/// 成功返回锁（仍持有）和路径；调用者决定 release 还是 release+rename。
/// 失败时已自动 cleanup（releaseAndDelete），调用者只需发送错误响应。
fn receiveFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: tcp.socket_t,
    comptime prefix: []const u8,
    expected_sha256: []const u8,
    file_size: u32,
    shm_handle: ?*volatile shm.ShmLayout,
) !struct { lock: svc.UpgradeLock, path: []const u8 } {
    const tmp_path = svc.UpgradeLock.tmpPath(allocator, prefix, expected_sha256) catch |err| {
        std.log.err("[guest] {s}: alloc tmp path: {}", .{ prefix, err });
        return error.OutOfMemory;
    };
    errdefer allocator.free(tmp_path);

    var lock = svc.UpgradeLock.create(tmp_path) catch |err| {
        std.log.err("[guest] {s}: create locked file {s}: {}", .{ prefix, tmp_path, err });
        return error.LockFailed;
    };

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining: u32 = file_size;
    var buf: [65536]u8 = undefined;

    while (remaining > 0) {
        // 更新心跳 — 大文件传输可能超过 10s，需在循环中刷新。
        if (shm_handle) |h| {
            shm.writeUtmmHeartbeat(h, io);
        }

        const to_read = @min(buf.len, remaining);
        const nr = tcp.sockRead(fd, &buf, to_read);
        if (nr <= 0) {
            std.log.err("[guest] {s}: short read ({d} remaining)", .{ prefix, remaining });
            lock.releaseAndDelete(tmp_path);
            return error.ShortRead;
        }
        const slice = buf[0..@intCast(nr)];
        hasher.update(slice);
        lock.writeAll(slice) catch |err| {
            std.log.err("[guest] {s}: write file: {}", .{ prefix, err });
            lock.releaseAndDelete(tmp_path);
            return error.WriteFailed;
        };
        remaining -= @intCast(nr);
    }

    // SHA256 校验
    var computed: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&computed);

    var hex_buf: [64]u8 = undefined;
    for (computed, 0..) |byte, i| {
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    if (!std.mem.eql(u8, expected_sha256, &hex_buf)) {
        std.log.err("[guest] {s}: SHA256 mismatch", .{prefix});
        lock.releaseAndDelete(tmp_path);
        return error.HashMismatch;
    }

    std.log.info("[guest] {s}: SHA256 verified, {d} bytes → {s}", .{ prefix, file_size, tmp_path });
    return .{ .lock = lock, .path = tmp_path };
}

/// 处理 upload：upload_cmd 帧后的原始字节 → receiveFile → rename 到目标路径。
pub fn handleUpload(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *protocol.Connection,
    payload: []const u8,
    shm_handle: ?*volatile shm.ShmLayout,
) !void {
    const cmd = protocol.parseUploadCmd(payload) orelse {
        std.log.err("[guest] parseUploadCmd failed", .{});
        return;
    };

    std.log.info("[guest] upload: cmd_id={s} path={s} size={d}", .{ cmd.cmd_id, cmd.path, cmd.file_size });

    // 接收文件流 → upload.<sha256>.tmp（OS 排他锁 + 文件名内嵌 SHA256）
    const result = receiveFile(io, allocator, conn.fd, "upload", cmd.file_hash, cmd.file_size, shm_handle) catch |err| {
        std.log.err("[guest] upload receive failed: {}", .{err});
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
        return;
    };
    defer allocator.free(result.path);

    // 释放锁并 rename 到目标路径
    result.lock.release();

    // 文件 I/O 使用独立 Threaded Io（Windows IOCP 不兼容 rename/deleteFile）
    var file_threaded = std.Io.Threaded.init(allocator, .{});
    const file_io = file_threaded.io();

    std.Io.Dir.cwd().deleteFile(file_io, cmd.path) catch {};
    const cwd = std.Io.Dir.cwd();
    cwd.rename(result.path, cwd, cmd.path, file_io) catch |err| {
        if (err == error.CrossDevice) {
            dpipe_file.copyAndDelete(file_io, result.path, cmd.path) catch |ce| {
                std.log.err("[guest] upload cross-device copy failed: {}", .{ce});
                const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
                defer allocator.free(resp);
                _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
                return;
            };
        } else {
            std.log.err("[guest] upload rename failed: {}", .{err});
            const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
            defer allocator.free(resp);
            _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
            return;
        }
    };

    std.log.info("[guest] upload complete: {s}", .{cmd.path});
    const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, 0) catch return;
    defer allocator.free(resp);
    _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
}

/// 处理 upgrade_cmd（Host→Guest 直推升级）：接收二进制流 → SHA256 校验 →
/// 写入 utmm-upgrade.<sha256hex>.tmp。utmmd 扫描发现 .tmp 文件后全权执行
/// 杀进程→替换→重启流程，Guest 不参与后续步骤。
pub fn handleUpgradeCmd(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *protocol.Connection,
    payload: []const u8,
    shm_handle: ?*volatile shm.ShmLayout,
) !void {
    const cmd = protocol.parseUpgradeCmd(payload) orelse {
        std.log.err("[guest] parseUpgradeCmd failed", .{});
        return;
    };

    std.log.info("[guest] upgrade: cmd_id={s} target={s} size={d} version={s}", .{ cmd.cmd_id, cmd.target, cmd.file_size, cmd.version });

    // 同版本检测：如果推送的版本与当前运行版本相同，跳过升级。
    // 必须先消费 Host 已发送的二进制流再发送响应，否则 Host sockWrite 可能因
    // TCP 接收窗口满而失败（Host 在发送 upgrade_cmd frame 后立即流式推送二进制数据）。
    if (std.mem.eql(u8, cmd.version, protocol.VERSION)) {
        std.log.info("[guest] upgrade: same version ({s}), discarding {d} bytes", .{ cmd.version, cmd.file_size });
        discardBytes(conn.fd, cmd.file_size) catch |err| {
            std.log.warn("[guest] upgrade: discard failed: {}", .{err});
        };
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, 0) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
        return;
    }

    // 接收文件流 → utmm-upgrade.<sha256>.tmp
    const result = receiveFile(io, allocator, conn.fd, "utmm-upgrade", cmd.sha256_hex, cmd.file_size, shm_handle) catch |err| {
        std.log.err("[guest] upgrade receive failed: {}", .{err});
        const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, -1) catch return;
        defer allocator.free(resp);
        _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});
        return;
    };
    defer allocator.free(result.path);

    // 发送成功响应，释放锁（文件保留在磁盘，utmmd 接管后续步骤）
    const resp = protocol.buildUploadResult(allocator, cmd.cmd_id, 0) catch return;
    defer allocator.free(resp);
    _ = conn.sendAndFlush(resp, 0) catch |e| std.log.warn("[guest] send failed: {}", .{e});

    result.lock.release();
    std.log.info("[guest] upgrade: file ready, lock released — signaling utmmd to apply", .{});

    // 把 .tmp 全路径写入 SHM cmd_data，utmmd 直接用——无需扫描目录。
    // 这绕过了 findUpgradeTmpPosix 在 Linux 上的 walker 兼容性问题。
    if (shm_handle) |h| {
        shm.writeCmdPath(h, result.path);
        shm.writeCmd(h, .restart, .pending);
    }
}

/// 处理 download：stat + hash pre-pass → 发送 download_result 帧 → 流式读文件发原始字节。
pub fn handleDownload(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *protocol.Connection,
    payload: []const u8,
    shm_handle: ?*volatile shm.ShmLayout,
) !void {
    const cmd = protocol.parseDownloadCmd(payload) orelse {
        std.log.err("[guest] parseDownloadCmd failed", .{});
        return;
    };

    std.log.info("[guest] download: cmd_id={s} path={s}", .{ cmd.cmd_id, cmd.path });

    // 使用独立的 blocking I/O（Windows zio IOCP 不兼容文件 I/O）
    var file_threaded = std.Io.Threaded.init(allocator, .{});
    const file_io = file_threaded.io();

    // 打开文件，stat 大小，positional read 全文件算 SHA256（不改变 seek 位置，与 upload 对称）。
    const file = std.Io.Dir.cwd().openFile(file_io, cmd.path, .{}) catch |err| {
        std.log.err("[guest] download openFile failed: {} path={s}", .{ err, cmd.path });
        return;
    };
    defer file.close(file_io);

    const file_stat = file.stat(file_io) catch |err| {
        std.log.err("[guest] download stat failed: {} path={s}", .{ err, cmd.path });
        return;
    };
    const file_size: u32 = @intCast(file_stat.size);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var hash_buf: [65536]u8 = undefined;
    var pos: u64 = 0;
    while (pos < file_size) {
        const to_read: usize = @min(hash_buf.len, file_size - pos);
        const nr = file.readPositional(file_io, &.{hash_buf[0..to_read]}, pos) catch |err| {
            std.log.err("[guest] download hash pre-pass read failed: {}", .{err});
            return;
        };
        if (nr == 0) break;
        sha.update(hash_buf[0..nr]);
        pos += nr;
    }
    var file_hash: [32]u8 = undefined;
    sha.final(&file_hash);

    var hash_hex_buf: [64]u8 = undefined;
    for (&file_hash, 0..) |b, i| {
        hash_hex_buf[i * 2] = "0123456789abcdef"[b >> 4];
        hash_hex_buf[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const hash_hex = hash_hex_buf[0..64];

    // 发送 download_result 帧：cmd_id + file_size + sha256_hex。
    const resp = protocol.buildDownloadResult(allocator, cmd.cmd_id, file_size, hash_hex) catch |err| {
        std.log.err("[guest] buildDownloadResult failed: {}", .{err});
        return;
    };
    defer allocator.free(resp);
    _ = conn.sendAndFlush(resp, 0) catch |e| {
        std.log.warn("[guest] download_result send failed: {}", .{e});
        return;
    };

    // 创建读取管道，流式读文件发原始字节（从文件头重新读，竞态与 upload 对称，不额外处理）。
    const file_pipe = dpipe_file.readFile(allocator, file_io, cmd.path) catch |err| {
        std.log.err("[guest] readFile failed: {}", .{err});
        return;
    };
    defer file_pipe.close();

    // 从 file_pipe 流式读取 → 写入 TCP（原始字节）
    var buf: [65536]u8 = undefined;
    while (true) {
        // 更新心跳 — 大文件下载可能超过 10s，需在循环中刷新。
        if (shm_handle) |h| {
            shm.writeUtmmHeartbeat(h, io);
        }

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
    // Collect system info using blocking init.io BEFORE creating zio Runtime.
    // zio's IOCP-based IO is incompatible with std.process.run on Windows.
    const sysinfo = try getSystemInfo(init.io, init.gpa);
    return guestRunWithIo(init.io, init.gpa, cli, null, null, sysinfo);
}

/// Guest mode entry point (called from Windows service or direct process start).
/// shutdown is an optional atomic flag — when set (Windows service stop), the
/// mesh session loop exits cleanly so the SCM receives STOPPED instead of a
/// broken pipe error.
/// pre_sysinfo: pre-collected SystemInfo (must be collected with BLOCKING io).
/// 启动时清理残留的临时文件（升级/上传失败遗留）。
/// 扫描 canonicalDir 和 tempDir，删除 `.utmm-*` 和 `.utmm-upgrade-*` 前缀的文件。
fn cleanupStaleTempFiles(io: std.Io, alloc: std.mem.Allocator) void {
    svc.cleanupStaleUpgradeTmp(io, alloc);

    const dirs = [_][]const u8{ svc.canonicalDir(), svc.tempDir() };
    const prefixes = [_][]const u8{ ".utmm-upgrade-", ".utmm-" };

    for (dirs) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch continue;
        defer dir.close(io);

        var walker = dir.walk(alloc) catch continue;
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.basename;
            for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, name, prefix)) {
                    dir.deleteFile(io, name) catch {};
                    std.log.debug("[guest] cleanup: removed stale {s}/{s}", .{ dir_path, name });
                    break;
                }
            }
        }
    }
}

pub fn guestRunWithIo(io: std.Io, gpa: std.mem.Allocator, cli: @import("main.zig").CliArgs, shutdown: ?*std.atomic.Value(bool), shm_handle: ?*volatile shm.ShmLayout, pre_sysinfo: SystemInfo) !void {
    // 启动时清理残留 temp 文件（升级失败/Crash 遗留）
    cleanupStaleTempFiles(io, gpa);
    // Use pre-collected system info (gathered with blocking IO to avoid
    // zio IOCP incompatibility with std.process.run on Windows).
    var sysinfo = pre_sysinfo;
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

    std.log.info("[guest] system: hostname={s} target={s} ip={s} mac={s} shell={s}", .{ sysinfo.hostname, sysinfo.target, sysinfo.ip, sysinfo.mac, sysinfo.shell });

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

    // TCP session loop — per-command TCP connections with SOCKS5 handshake.
    try guestTcpLoop(io, gpa, sysinfo, cli.mesh_port, cli.peer_mesh, shutdown, shm_handle);
}
