//! UDP broadcast module (Guest side)
//! Broadcast local hostname + IP + target + MAC to LAN every second

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const protocol = @import("protocol.zig");
const tunnel_mod = @import("tunnel.zig");
const tunproto = @import("tunproto.zig");
const mesh_mod = @import("mesh.zig");

/// Shared signal between udpDiscoveryListener (background thread) and
/// wsAnnounceLoop (main thread). When the UDP listener detects a version
/// mismatch from the Host broadcast, it sets `needed` to true.
pub const UpgradeSignal = struct {
    needed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

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

    var buf: [64]u8 = undefined;
    var read_buf: [64]u8 = undefined;
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
            std.debug.print("[broadcast] Failed to read MAC ({s}): {}\n", .{ path, err });
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
        std.debug.print("[broadcast] Physical NIC {s}: {s}\n", .{ name, ip });
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
            std.debug.print("[broadcast] IP not ready (attempt {}/{}), waiting {d}ms...\n", .{ attempt + 1, MAX_IP_RETRIES, IP_RETRY_DELAY_MS });
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

// ═══════════════════════════════════════════════════════════════════════════
// v0.11.0: pty session model — persistent pty per KCP tunnel connection
// ═══════════════════════════════════════════════════════════════════════════

// POSIX pty externs (available on macOS and Linux via libc)
extern "c" fn posix_openpt(flags: u32) std.posix.fd_t;
extern "c" fn grantpt(fd: std.posix.fd_t) c_int;
extern "c" fn unlockpt(fd: std.posix.fd_t) c_int;
extern "c" fn ptsname(fd: std.posix.fd_t) ?[*:0]u8;
extern "c" fn fork() std.posix.pid_t;
extern "c" fn setsid() std.posix.pid_t;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn open(path: [*:0]const u8, flags: u32, mode: u32) std.posix.fd_t;
extern "c" fn dup2(old: std.posix.fd_t, new: std.posix.fd_t) std.posix.fd_t;
extern "c" fn close(fd: std.posix.fd_t) c_int;
extern "c" fn kill(pid: std.posix.pid_t, sig: c_int) c_int;
extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: std.posix.fd_t, buf: [*]u8, count: usize) isize;

const O_RDWR: u32 = 2;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;

/// Pty session state: master fd + child pid + shell description.
/// On Windows, stdin_fd holds the write end of the stdin pipe.
const PtySession = struct {
    master_fd: std.posix.fd_t, // pty master (POSIX) or stdout_read pipe (Windows)
    child_pid: std.posix.pid_t, // child process id/handle
    shell: []const u8, // "bash --login" or "cmd.exe /k"
    stdin_fd: std.posix.fd_t, // Windows: stdin_write pipe handle (unused on POSIX)
};

/// Write data to the pty/stdin. Cross-platform wrapper.
fn ptyWrite(session: *const PtySession, data: []const u8) void {
    if (builtin.os.tag == .windows) {
        const WriteFile = @extern(
            *const fn (std.os.windows.HANDLE, [*]const u8, std.os.windows.DWORD, *std.os.windows.DWORD, ?*anyopaque) callconv(.winapi) std.os.windows.BOOL,
            .{ .name = "WriteFile", .library_name = "kernel32" },
        );
        var written: std.os.windows.DWORD = 0;
        _ = WriteFile(session.stdin_fd, data.ptr, @intCast(data.len), &written, null);
    } else {
        _ = write(session.master_fd, data.ptr, data.len);
    }
}

/// Read from the pty/stdout. Cross-platform wrapper. Returns bytes read or error.
fn ptyRead(master_fd: std.posix.fd_t, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const ReadFile = @extern(
            *const fn (std.os.windows.HANDLE, [*]u8, std.os.windows.DWORD, *std.os.windows.DWORD, ?*anyopaque) callconv(.winapi) std.os.windows.BOOL,
            .{ .name = "ReadFile", .library_name = "kernel32" },
        );
        var nread: std.os.windows.DWORD = 0;
        if (@intFromEnum(ReadFile(master_fd, buf.ptr, @intCast(buf.len), &nread, null)) == 0) {
            return error.ReadFailed;
        }
        return @intCast(nread);
    } else {
        const n = read(master_fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }
}

/// Spawn a persistent pty with shell --login.
/// POSIX: posix_openpt → fork → setsid → dup2 → exec bash/zsh --login
/// Windows: CreatePipe + persistent cmd.exe /k (ConPTY fallback not yet implemented)
fn ptySpawn(allocator: std.mem.Allocator, shell: []const u8) !PtySession {
    if (builtin.os.tag == .windows) {
        return ptySpawnWindows(allocator);
    }

    // POSIX: open /dev/ptmx via posix_openpt
    const master = posix_openpt(O_RDWR);
    if (master < 0) {
        std.log.err("[guest-pty] posix_openpt failed", .{});
        return error.PtyOpenFailed;
    }
    errdefer _ = close(master);

    if (grantpt(master) != 0) {
        std.log.err("[guest-pty] grantpt failed", .{});
        return error.PtyGrantFailed;
    }
    if (unlockpt(master) != 0) {
        std.log.err("[guest-pty] unlockpt failed", .{});
        return error.PtyUnlockFailed;
    }

    const slave_name = ptsname(master) orelse {
        std.log.err("[guest-pty] ptsname returned null", .{});
        return error.PtyPtsnameFailed;
    };

    const pid = fork();
    if (pid < 0) {
        std.log.err("[guest-pty] fork failed", .{});
        return error.PtyForkFailed;
    }

    if (pid == 0) {
        // Child: setup controlling terminal and exec shell
        _ = setsid();

        const slave = open(slave_name, O_RDWR, 0);
        if (slave < 0) @panic("pty: open slave failed");

        // On macOS, TIOCSCTTY must be called before dup2
        const TIOCSCTTY: usize = if (builtin.os.tag == .macos) 0x20007461 else 0x540E;
        _ = std.c.ioctl(slave, TIOCSCTTY, @as(usize, 0));

        _ = dup2(slave, 0);
        _ = dup2(slave, 1);
        _ = dup2(slave, 2);
        _ = close(slave);
        _ = close(master);

        // Disable pty echo on slave (fd 0) before exec.
        // The host-side scanForMarker handles echoed text (lastIndexOf +
        // validation), but disabling ECHO here gives cleaner output.
        if (std.posix.tcgetattr(0)) |t| {
            var t2 = t;
            t2.lflag.ECHO = false;
            std.posix.tcsetattr(0, .NOW, t2) catch {};
        } else |_| {}

        // Detect shell: use user's $SHELL or fallback to /bin/sh
        const shell_path: [:0]const u8 = if (std.c.getenv("SHELL")) |sh| blk: {
            const s = std.mem.sliceTo(sh, 0);
            if (s.len > 0) break :blk @as([:0]const u8, @ptrCast(s[0..s.len :0]));
            break :blk "/bin/sh";
        } else "/bin/sh";

        const argv = [_:null]?[*:0]const u8{ shell_path.ptr, @as(?[*:0]const u8, @ptrFromInt(@intFromPtr("-l"))), null };
        _ = std.c.execve(shell_path.ptr, &argv, std.c.environ);
        @panic("pty: execve failed");
    }

    // Parent: disable pty echo so commands sent via pty_input are not
    // echoed back. Prevents MDELIM marker from matching echoed command text.
    // On Linux the master fd supports tcsetattr. On macOS/BSD the master
    // does not — the host-side scanForMarker handles echoed text via
    // lastIndexOf + validation (see httpd.zig).
    if (std.posix.tcgetattr(master)) |t| {
        var t2 = t;
        t2.lflag.ECHO = false;
        std.posix.tcsetattr(master, .NOW, t2) catch {};
    } else |_| {}

    // Parent: close slave, return session
    std.log.info("[guest-pty] pty spawned: master={d} shell={s} pid={d}", .{ master, shell, pid });
    return PtySession{
        .master_fd = master,
        .child_pid = pid,
        .shell = try allocator.dupe(u8, shell),
        .stdin_fd = 0,
    };
}

/// Windows pty: CreatePipe + persistent cmd.exe /k.
fn ptySpawnWindows(allocator: std.mem.Allocator) !PtySession {
    const w = std.os.windows;
    const BOOL = w.BOOL;
    const HANDLE = w.HANDLE;
    const DWORD = w.DWORD;
    const LPVOID = w.LPVOID;
    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: DWORD,
        dwThreadId: DWORD,
    };

    const CreatePipe = @extern(
        *const fn (phReadPipe: *HANDLE, phWritePipe: *HANDLE, lpPipeAttributes: ?*w.SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL,
        .{ .name = "CreatePipe", .library_name = "kernel32" },
    );
    const SetHandleInformation = @extern(
        *const fn (hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL,
        .{ .name = "SetHandleInformation", .library_name = "kernel32" },
    );
    const CloseHandle = @extern(
        *const fn (hObject: HANDLE) callconv(.winapi) BOOL,
        .{ .name = "CloseHandle", .library_name = "kernel32" },
    );
    const CreateProcessW = @extern(
        *const fn (lpApplicationName: ?[*:0]const u16, lpCommandLine: [*:0]u16, lpProcessAttributes: ?*w.SECURITY_ATTRIBUTES, lpThreadAttributes: ?*w.SECURITY_ATTRIBUTES, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?LPVOID, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *w.STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) BOOL,
        .{ .name = "CreateProcessW", .library_name = "kernel32" },
    );
    const SetConsoleOutputCP = @extern(
        *const fn (wCodePageID: w.UINT) callconv(.winapi) w.BOOL,
        .{ .name = "SetConsoleOutputCP", .library_name = "kernel32" },
    );
    const SetConsoleCP_ext = @extern(
        *const fn (wCodePageID: w.UINT) callconv(.winapi) w.BOOL,
        .{ .name = "SetConsoleCP", .library_name = "kernel32" },
    );

    const HANDLE_FLAG_INHERIT: DWORD = 1;

    var sa: w.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
        .bInheritHandle = @enumFromInt(1),
        .lpSecurityDescriptor = null,
    };

    var stdin_read: HANDLE = undefined;
    var stdin_write: HANDLE = undefined;
    if (@intFromEnum(CreatePipe(&stdin_read, &stdin_write, &sa, 0)) == 0) {
        return error.PipeCreateFailed;
    }
    errdefer { _ = CloseHandle(stdin_read); _ = CloseHandle(stdin_write); }

    // Don't inherit the write end of stdin pipe
    _ = SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);

    var stdout_read: HANDLE = undefined;
    var stdout_write: HANDLE = undefined;
    if (@intFromEnum(CreatePipe(&stdout_read, &stdout_write, &sa, 0)) == 0) {
        return error.PipeCreateFailed;
    }
    errdefer { _ = CloseHandle(stdout_read); _ = CloseHandle(stdout_write); }

    _ = SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    si.hStdInput = stdin_read;
    si.hStdOutput = stdout_write;
    si.hStdError = stdout_write;
    si.dwFlags |= w.STARTF_USESTDHANDLES;

    var pi: PROCESS_INFORMATION = undefined;

    // Best-effort: set UTF-8 code page on our console BEFORE spawning cmd.exe.
    // If utmm runs as a service (no console), these calls fail silently and
    // we rely on the "chcp 65001" in the cmd command line below instead.
    _ = SetConsoleOutputCP(65001);
    _ = SetConsoleCP_ext(65001);

    // Convert UTF-8 command line to null-terminated UTF-16LE for CreateProcessW.
    // std.unicode.utf8ToUtf16LeWithNull was removed in Zig 0.16.0.
    const cmd_u8 = "cmd.exe /k chcp 65001 >nul & set LANG=en_US.UTF-8";
    const cmd_utf16 = try allocator.alloc(u16, cmd_u8.len + 1); // +1 for null
    defer allocator.free(cmd_utf16);
    const end_idx = try std.unicode.utf8ToUtf16Le(cmd_utf16, cmd_u8);
    cmd_utf16[end_idx] = 0; // null terminate

    if (@intFromEnum(CreateProcessW(null, @as([*:0]u16, @ptrCast(cmd_utf16.ptr)), null, null, @enumFromInt(1), 0, null, null, &si, &pi)) == 0) {
        return error.ProcessCreateFailed;
    }

    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(stdin_read);
    _ = CloseHandle(stdout_write);

    std.log.info("[guest-pty] Windows pipe pty: cmd.exe /k (UTF-8) pid={d}", .{pi.dwProcessId});

    return PtySession{
        .master_fd = stdout_read,
        .child_pid = pi.hProcess,
        .shell = try allocator.dupe(u8, "cmd.exe /k chcp 65001 >nul & set LANG=en_US.UTF-8"),
        .stdin_fd = stdin_write,
    };
}

/// Thread: continuously read pty master_fd, send pty_output frames to Host.
/// Runs for entire WS connection lifetime. Sets pty_dead on EOF (shell exited).
fn ptyReadLoop(
    master_fd: std.posix.fd_t,
    tun: *tunnel_mod.Tunnel,
    io: std.Io,
    allocator: std.mem.Allocator,
    active_cmd_id: *[]const u8,
    cmd_mutex: *std.Io.Mutex,
    pty_dead: *std.atomic.Value(bool),
) void {
    var buf: [4096]u8 = undefined;

    while (true) {
        // POSIX: poll master_fd with 100ms timeout to check pty_dead
        if (builtin.os.tag != .windows) {
            var fds: [1]std.posix.pollfd = .{
                .{ .fd = master_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, 100) catch |err| {
                std.log.err("[guest-pty] pty poll error: {}", .{err});
                break;
            };

            // POLL.HUP: shell process exited (or never started).
            // Poll returns immediately with HUP set, so we must handle
            // it before the POLL.IN check — otherwise we spin at 100% CPU.
            if (fds[0].revents & std.posix.POLL.HUP != 0) {
                std.log.info("[guest-pty] pty hangup (shell exited)", .{});
                pty_dead.store(true, .release);
                break;
            }
            if (fds[0].revents & std.posix.POLL.IN == 0) continue;
        }

        const n = ptyRead(master_fd, &buf) catch |err| {
            std.log.err("[guest-pty] pty read error: {}", .{err});
            break;
        };

        if (n == 0) {
            // EOF: shell process exited
            std.log.info("[guest-pty] pty EOF (shell exited)", .{});
            pty_dead.store(true, .release);
            break;
        }

        // Read current cmd_id under mutex
        cmd_mutex.lock(io) catch continue;
        const cmd_id = active_cmd_id.*;
        const cmd_owned = allocator.dupe(u8, cmd_id) catch {
            cmd_mutex.unlock(io);
            continue;
        };
        cmd_mutex.unlock(io);
        defer allocator.free(cmd_owned);

        // Send pty_exec_output frame via tunnel with immediate flush.
        // On Windows, the mesh loop uses blocking receive() without timeout,
        // so periodicTasks (which normally flushes KCP) only runs when a
        // packet arrives. Without immediate flush, output data would sit in
        // KCP snd_queue until the next incoming packet (up to 5s delay).
        // sendAndFlush() triggers kcp.update() which calls the output callback
        // to transmit queued segments via UDP immediately.
        const frame = tunproto.buildPtyExecOutput(allocator, cmd_owned, buf[0..n]) catch continue;
        defer allocator.free(frame);
        _ = tun.sendAndFlush(frame, tun.session.mesh.clock_ms) catch |err| {
            std.log.err("[guest-pty] pty_exec_output send error: {}", .{err});
            break;
        };
    }
}

/// Cross-platform child process termination (for pty cleanup).
fn killChild(pid: std.posix.pid_t) void {
    switch (builtin.os.tag) {
        .windows => {
            const TerminateProcess = @extern(
                *const fn (std.os.windows.HANDLE, std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
                .{ .name = "TerminateProcess", .library_name = "kernel32" },
            );
            _ = TerminateProcess(pid, 1);
        },
        .linux, .macos => {
            _ = kill(pid, SIGKILL);
            // Reap child to prevent zombie processes.
            // After SIGKILL the child should exit immediately, so blocking waitpid is fine.
            _ = std.posix.system.waitpid(pid, null, 0);
        },
        else => @compileError("unsupported OS for killChild"),
    }
}

/// Extract bare IP from host_url. Input format: "http://IP:PORT" → "IP".
/// Returns empty string if parsing fails (safe default: no upgrade filtering on error).
fn extractHostIp(host_url: []const u8) []const u8 {
    // Strip "http://" prefix
    const without_scheme = if (std.mem.startsWith(u8, host_url, "http://"))
        host_url["http://".len..]
    else
        host_url;
    // Find port separator
    const colon = std.mem.indexOfScalar(u8, without_scheme, ':') orelse return without_scheme;
    return without_scheme[0..colon];
}

pub fn meshSessionLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    host_url: []const u8,
    upgrade: *UpgradeSignal,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    // Extract Host IP from host_url for LSA version check filtering.
    // host_url format: "http://IP:PORT" — strip to just the IP.
    const host_gateway_ip = extractHostIp(host_url);

    // Start mesh networking thread (LSA broadcast + KCP data dispatch).
    // Mesh owns UDP :2121 for LSA + KCP relay + PING/PONG.
    var mesh_opt: ?mesh_mod.Mesh = null;
    var mesh_thread: ?std.Thread = null;
    var mesh_socket_opt: ?net.Socket = null;

    // Create a dedicated Io.Threaded for mesh background thread.
    // The main init.io does not support cross-thread concurrent I/O on
    // Windows, causing error.ConcurrencyUnavailable when
    // socket.receiveTimeout() is called from the mesh thread.
    // Using a dedicated instance ensures the socket and its I/O operations
    // live on the same Io, avoiding the cross-thread issue.
    var mesh_threaded = std.Io.Threaded.init(allocator, .{});
    const mesh_io = mesh_threaded.io();

    start_mesh: {
        // Collect broadcast addresses (subnet-directed + 255.255.255.255)
        var broadcast_addrs = getSubnetBroadcasts(allocator) catch |err| {
            std.log.err("[guest-mesh] getSubnetBroadcasts failed: {}", .{err});
            break :start_mesh;
        };

        // Add explicit peer mesh address for local testing (different mesh ports)
        if (peer_mesh) |pm| {
            if (protocol.parsePeerMeshAddr(pm)) |peer_addr| {
                broadcast_addrs.append(allocator, peer_addr) catch |err| {
                    std.log.err("[guest-mesh] append peer-mesh '{s}': {}", .{ pm, err });
                };
            } else {
                std.log.err("[guest-mesh] invalid --peer-mesh '{s}'", .{pm});
            }
        }

        // Bind UDP socket for mesh
        const bind_addr = net.IpAddress.parse("0.0.0.0", mesh_port) catch |err| {
            std.log.err("[guest-mesh] Mesh bind addr parse failed: {}", .{err});
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        const mesh_socket = bind_addr.bind(mesh_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
            std.log.err("[guest-mesh] Mesh UDP bind :{d} failed: {}", .{ mesh_port, err });
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        mesh_socket_opt = mesh_socket;

        // Parse MAC as mesh NodeId.
        // When peer_mesh is set (local testing, same machine as Host),
        // derive a unique NodeId from MAC+hostname to avoid collision.
        const node_id = if (peer_mesh != null)
            mesh_mod.deriveNodeId(info.mac, info.hostname) catch |err| {
                std.log.err("[guest-mesh] deriveNodeId '{s}'+'{s}' failed: {}", .{ info.mac, info.hostname, err });
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            }
        else
            mesh_mod.parseNodeId(info.mac) catch |err| {
                std.log.err("[guest-mesh] Mesh MAC parse '{s}' failed: {}", .{ info.mac, err });
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            };

        // Build node_info string for LSA broadcast
        const node_info = std.fmt.allocPrint(allocator,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:guest\nstatus:serving",
            .{ info.hostname, info.ip, info.target, protocol.VERSION, info.shell },
        ) catch |err| {
            std.log.err("[guest-mesh] Mesh node_info alloc failed: {}", .{err});
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        // Create mesh instance (mesh takes ownership of node_info and broadcast_addrs)
        mesh_opt = mesh_mod.Mesh.init(allocator, node_id, node_info, mesh_socket, mesh_io, &upgrade.needed, broadcast_addrs, host_gateway_ip) catch |err| {
            std.log.err("[guest-mesh] Mesh init failed: {}", .{err});
            allocator.free(node_info);
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        // Spawn mesh.run() in background thread
        mesh_thread = std.Thread.spawn(.{}, mesh_mod.Mesh.run, .{&mesh_opt.?}) catch |err| {
            std.log.err("[guest-mesh] Mesh thread spawn failed: {}", .{err});
            mesh_opt.?.deinit();
            mesh_socket.close(mesh_io);
            mesh_opt = null;
            break :start_mesh;
        };

        std.log.info("[guest-mesh] Mesh networking started (LSA on UDP :{d})", .{mesh_port});
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
        std.log.err("[guest-mesh] Mesh failed to start, exiting", .{});
        return error.MeshInitFailed;
    }

    // Helper: check shutdown flag without namespace-qualifying the type
    const checkShutdown = struct {
        fn check(s: ?*std.atomic.Value(bool)) bool {
            if (s) |ptr| return ptr.load(.acquire);
            return false;
        }
    }.check;

    // Main loop: wait for Host tunnel, process commands, handle reconnect.
    while (true) {
        if (checkShutdown(shutdown)) {
            std.log.info("[guest-mesh] Shutdown requested, exiting", .{});
            break;
        }

        // Wait for Host to establish a KCP tunnel and send pty_spawn
        var tunnel = waitForHostTunnel(io, allocator, &mesh_opt) catch |err| {
            std.log.err("[guest-mesh] waitForHostTunnel failed: {}", .{err});
            continue;
        };

        // Read initial frame from Host. Usually pty_spawn, but on Host
        // restart the old command loop may have already consumed it and
        // the next frame is pty_exec_input. Accept either as the spawn
        // trigger, and buffer a pre-consumed exec command for delivery
        // after the pty is ready.
        var pending_cmd_id: []const u8 = &.{};
        var pending_cmd_data: []const u8 = &.{};
        defer {
            if (pending_cmd_id.len > 0) allocator.free(pending_cmd_id);
            if (pending_cmd_data.len > 0) allocator.free(pending_cmd_data);
        }

        const spawn_ok = blk: {
            var rbuf: [4096]u8 = undefined;
            while (true) {
                if (checkShutdown(shutdown)) break :blk false;
                const n = tunnel.recv(&rbuf) catch |err| {
                    std.log.err("[guest-mesh] pty_spawn recv error: {}", .{err});
                    break :blk false;
                };
                if (n == 0) {
                    if (!tunnel.isAlive()) {
                        std.log.info("[guest-mesh] Tunnel dead before pty_spawn", .{});
                        break :blk false;
                    }
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                    continue;
                }
                if (n > 0 and rbuf[0] == @intFromEnum(tunproto.MsgType.pty_spawn)) {
                    break :blk true;
                }
                // Host restart race: old command loop consumed pty_spawn,
                // next frame is pty_exec_input. Accept as implicit spawn
                // and buffer the command for delivery after pty is ready.
                if (n > 0 and rbuf[0] == @intFromEnum(tunproto.MsgType.pty_exec_input)) {
                    std.log.info("[guest-mesh] pty exec before spawn (reconnect race), buffering", .{});
                    if (tunproto.parsePtyExecInput(rbuf[1..n])) |input| {
                        pending_cmd_id = allocator.dupe(u8, input.cmd_id) catch &.{};
                        pending_cmd_data = allocator.dupe(u8, input.command) catch &.{};
                    }
                    break :blk true;
                }
                std.log.debug("[guest-mesh] Ignoring pre-spawn frame type={d}", .{rbuf[0]});
            }
        };
        if (!spawn_ok) {
            std.log.info("[guest-mesh] No pty_spawn received, waiting for reconnect...", .{});
            tunnel.deinit();
            continue;
        }

        // Spawn pty session
        // detectShell only fails on OOM; "/bin/sh" is a compile-time literal.
        // Track allocation origin so defer free doesn't release .rodata memory.
        var shell_is_heap = true;
        const shell = detectShell(allocator) catch blk: {
            shell_is_heap = false;
            break :blk "/bin/sh";
        };
        defer if (shell_is_heap) allocator.free(shell);
        const pty = ptySpawn(allocator, shell) catch |err| {
            std.log.err("[guest-mesh] ptySpawn failed: {}", .{err});
            tunnel.deinit();
            continue;
        };
        defer {
            allocator.free(pty.shell);
            killChild(pty.child_pid);
            _ = close(pty.master_fd);
        }

        // Shared state between main loop and ptyReadLoop thread
        var active_cmd_id: []const u8 = &.{};
        var cmd_mutex: std.Io.Mutex = std.Io.Mutex.init;
        var pty_dead: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        // Start ptyReadLoop thread
        {
            const t = try std.Thread.spawn(.{}, ptyReadLoop, .{
                pty.master_fd,
                &tunnel,
                io,
                allocator,
                &active_cmd_id,
                &cmd_mutex,
                &pty_dead,
            });
            t.detach();
        }

        // Deliver any exec command buffered from reconnect race
        if (pending_cmd_data.len > 0) {
            cmd_mutex.lock(io) catch continue;
            if (active_cmd_id.len > 0) allocator.free(active_cmd_id);
            active_cmd_id = pending_cmd_id;
            pending_cmd_id = &.{}; // ownership transferred
            cmd_mutex.unlock(io);
            ptyWrite(&pty, pending_cmd_data);
        }

        std.log.info("[guest-mesh] Pty session started, entering command loop", .{});

        // Command dispatch loop — uses 256KB fixed buffer.
        // File transfers (upload/download/upgrade) use chunked protocol:
        // upload_cmd + file_chunk × N + file_eof, avoiding full-file buffering.
        var rbuf: [262144]u8 = undefined;
        while (!pty_dead.load(.acquire)) {
            // Check Windows service shutdown signal before blocking recv.
            if (checkShutdown(shutdown)) {
                std.log.info("[guest-mesh] Shutdown requested, exiting command loop", .{});
                break;
            }

            if (!tunnel.isAlive()) {
                std.log.info("[guest-mesh] Tunnel dead (keepalive), reconnecting", .{});
                break;
            }

            const n = tunnel.recv(&rbuf) catch |err| {
                std.log.err("[guest-mesh] tunnel recv error: {}", .{err});
                break;
            };
            if (n == 0 or rbuf[0] == 0) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                continue;
            }

            const msg_type: u8 = rbuf[0];
            const payload = rbuf[1..n];

            switch (msg_type) {
                @intFromEnum(tunproto.MsgType.pty_spawn) => {
                    std.log.info("[guest-mesh] pty re-spawn requested", .{});
                    break;
                },
                @intFromEnum(tunproto.MsgType.pty_exec_input) => {
                    if (tunproto.parsePtyExecInput(payload)) |input| {
                        // Update active_cmd_id under mutex
                        cmd_mutex.lock(io) catch continue;
                        if (active_cmd_id.len > 0) allocator.free(active_cmd_id);
                        active_cmd_id = allocator.dupe(u8, input.cmd_id) catch &.{};
                        cmd_mutex.unlock(io);

                        // Write command data to pty master (stdin of shell).
                        // Ctrl+C (0x03) and other control chars are forwarded
                        // through pty stdin — termios generates signal automatically.
                        ptyWrite(&pty, input.command);
                    }
                },
                @intFromEnum(tunproto.MsgType.upload_cmd) => {
                    if (tunproto.parseUploadCmd(payload)) |cmd| {
                        std.log.debug("[guest-mesh] Upload cmd: {s} ({d} bytes, hash={s})", .{ cmd.path, cmd.file_size, cmd.file_hash });
                        receiveChunkedFile(io, allocator, &tunnel, cmd.cmd_id, cmd.path, cmd.file_hash) catch |e| {
                            std.log.err("[guest-mesh] Upload receive failed: {}", .{e});
                            const resp = tunproto.buildUploadResult(allocator, cmd.cmd_id, -1) catch continue;
                            defer allocator.free(resp);
                            _ = tunnel.sendAndFlush(resp, tunnel.session.mesh.clock_ms) catch {};
                        };
                    }
                },
                @intFromEnum(tunproto.MsgType.download_cmd) => {
                    if (tunproto.parseDownloadCmd(payload)) |cmd| {
                        std.log.debug("[guest-mesh] Download cmd: {s}", .{cmd.path});
                        sendChunkedFile(io, allocator, &tunnel, cmd.cmd_id, cmd.path) catch |e| {
                            std.log.err("[guest-mesh] Download send failed: {}", .{e});
                            const eof = tunproto.buildFileEof(allocator, cmd.cmd_id, -1, 0, "") catch continue;
                            defer allocator.free(eof);
                            _ = tunnel.sendAndFlush(eof, tunnel.session.mesh.clock_ms) catch {};
                        };
                    }
                },
                @intFromEnum(tunproto.MsgType.file_chunk) => {
                    std.log.debug("[guest-mesh] Unexpected file_chunk in command loop (ignored)", .{});
                },
                @intFromEnum(tunproto.MsgType.file_eof) => {
                    std.log.debug("[guest-mesh] Unexpected file_eof in command loop (ignored)", .{});
                },
                else => {
                    std.log.debug("[guest-mesh] Unknown msg type: {d}", .{msg_type});
                },
            }
        }

        std.log.info("[guest-mesh] Pty session ended, waiting for reconnect...", .{});
        tunnel.deinit();
    }
}

/// Wait for Host to establish a KCP tunnel via mesh.
fn waitForHostTunnel(io: std.Io, allocator: std.mem.Allocator, mesh_opt: *?mesh_mod.Mesh) !tunnel_mod.Tunnel {
    while (true) {
        if (mesh_opt.*) |*m| {
            m.sessions_mutex.lock(m.io) catch continue;
            const count = m.sessions.count();
            if (count > 0) {
                var it = m.sessions.iterator();
                while (it.next()) |entry| {
                    const sess = entry.value_ptr.*;
                    const peek = sess.kcp_inst.peekSize();
                    if (peek > 0) {
                        m.sessions_mutex.unlock(m.io);
                        return tunnel_mod.Tunnel.init(allocator, m.io, sess);
                    }
                }
            }
            m.sessions_mutex.unlock(m.io);
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    }
}
/// Convert 32-byte SHA256 hash to hex string. Caller owns returned string.
pub fn hexHash(allocator: std.mem.Allocator, hash: *const [32]u8) ![]const u8 {
    var hex: [64]u8 = undefined;
    for (hash, 0..) |b, j| {
        hex[j * 2] = "0123456789abcdef"[b >> 4];
        hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return try allocator.dupe(u8, &hex);
}

/// Receive a chunked file transfer (upload): create temp file, receive
/// file_chunk messages and write incrementally, verify SHA256 on file_eof,
/// rename temp → final, send upload_result.
fn receiveChunkedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    tun: *tunnel_mod.Tunnel,
    cmd_id: []const u8,
    dest_path: []const u8,
    expected_hash: []const u8,
) !void {
    // Create temp file in the same directory as destination
    const dirname = std.fs.path.dirname(dest_path) orelse ".";
    const basename = std.fs.path.basename(dest_path);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.utmm-tmp-{s}", .{ dirname, basename });
    defer allocator.free(temp_path);

    std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    defer temp_file.close(io);
    var wb: [65536]u8 = undefined;
    var writer = temp_file.writer(io, &wb);

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var received: u32 = 0;

    // Inner loop: receive file_chunk + file_eof
    var rbuf: [262144]u8 = undefined;
    while (true) {
        if (!tun.isAlive()) {
            return error.TunnelDeadDuringUpload;
        }

        const n = tun.recv(&rbuf) catch |err| {
            std.log.err("[guest-mesh] Chunk recv error: {}", .{err});
            return err;
        };
        if (n == 0) continue;

        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        switch (msg_type) {
            @intFromEnum(tunproto.MsgType.file_chunk) => {
                const chunk = tunproto.parseFileChunk(payload) orelse {
                    std.log.err("[guest-mesh] Failed to parse file_chunk", .{});
                    return error.ParseFailed;
                };
                if (!std.mem.eql(u8, chunk.cmd_id, cmd_id)) {
                    std.log.debug("[guest-mesh] Ignoring file_chunk for other cmd_id: {s}", .{chunk.cmd_id});
                    continue;
                }

                _ = writer.interface.write(chunk.data) catch |e| {
                    std.log.err("[guest-mesh] Write chunk failed: {}", .{e});
                    return error.WriteFailed;
                };
                sha256.update(chunk.data);
                received += @intCast(chunk.data.len);
            },
            @intFromEnum(tunproto.MsgType.file_eof) => {
                const eof = tunproto.parseFileEof(payload) orelse {
                    std.log.err("[guest-mesh] Failed to parse file_eof", .{});
                    return error.ParseFailed;
                };
                if (!std.mem.eql(u8, eof.cmd_id, cmd_id)) {
                    std.log.debug("[guest-mesh] Ignoring file_eof for other cmd_id: {s}", .{eof.cmd_id});
                    continue;
                }

                writer.interface.flush() catch {};

                // Verify SHA256 (incremental: sha256.update per chunk, final here)
                var hash: [32]u8 = undefined;
                sha256.final(&hash);
                const actual_hex = try hexHash(allocator, &hash);
                defer allocator.free(actual_hex);

                if (expected_hash.len > 0 and !std.mem.eql(u8, actual_hex, expected_hash)) {
                    std.log.err("[guest-mesh] Upload hash mismatch: got {s}, expected {s}", .{ actual_hex, expected_hash });
                    const resp = try tunproto.buildUploadResult(allocator, cmd_id, -1);
                    defer allocator.free(resp);
                    _ = tun.sendAndFlush(resp, tun.session.mesh.clock_ms) catch {};
                    return error.HashMismatch;
                }

                std.log.debug("[guest-mesh] Upload hash verified: {s}", .{actual_hex});

                // Atomic rename from temp to final path
                try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), dest_path, io);
                std.log.info("[guest-mesh] Upload complete: {s} ({d} bytes)", .{ dest_path, received });

                const resp = try tunproto.buildUploadResult(allocator, cmd_id, 0);
                defer allocator.free(resp);
                _ = tun.sendAndFlush(resp, tun.session.mesh.clock_ms) catch |e| {
                    std.log.err("[guest-mesh] upload_result send failed: {}", .{e});
                };
                return;
            },
            @intFromEnum(tunproto.MsgType.pty_exec_input) => {
                // pty commands may arrive during file transfer — ignore them;
                // the Host should serialize file transfers and exec commands.
                std.log.debug("[guest-mesh] Ignoring pty_exec_input during chunked receive", .{});
                continue;
            },
            else => {
                std.log.debug("[guest-mesh] Ignoring msg type {d} during chunked receive", .{msg_type});
                continue;
            },
        }
    }
}

/// Send a file as chunked transfer (download): open file, read 8KB chunks,
/// send as file_chunk messages with incremental SHA256, finish with file_eof.
fn sendChunkedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    tun: *tunnel_mod.Tunnel,
    cmd_id: []const u8,
    path: []const u8,
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.log.err("[guest-mesh] Download open failed: {}", .{err});
        const eof = try tunproto.buildFileEof(allocator, cmd_id, -1, 0, "");
        defer allocator.free(eof);
        _ = tun.sendAndFlush(eof, tun.session.mesh.clock_ms) catch {};
        return;
    };
    defer file.close(io);

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u32 = 0;
    var chunk_buf: [8192]u8 = undefined;
    var file_read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_read_buf);

    while (true) {
        const n = file_reader.interface.readSliceShort(&chunk_buf) catch |err2| {
            std.log.err("[guest-mesh] Download read error: {}", .{err2});
            const eof = try tunproto.buildFileEof(allocator, cmd_id, -1, 0, "");
            defer allocator.free(eof);
            _ = tun.sendAndFlush(eof, tun.session.mesh.clock_ms) catch {};
            return err2;
        };
        if (n == 0) break; // EOF

        sha256.update(chunk_buf[0..n]);

        const chunk = try tunproto.buildFileChunk(allocator, cmd_id, chunk_buf[0..n]);
        defer allocator.free(chunk);
        _ = tun.send(chunk) catch |e| {
            std.log.err("[guest-mesh] file_chunk send failed: {}", .{e});
            return e;
        };
        total += @intCast(n);
    }

    // Build hash and send file_eof
    var hash: [32]u8 = undefined;
    sha256.final(&hash);
    const hex = try hexHash(allocator, &hash);
    defer allocator.free(hex);

    std.log.info("[guest-mesh] Download complete: {s} ({d} bytes, sha256={s})", .{ path, total, hex });

    const eof = try tunproto.buildFileEof(allocator, cmd_id, 0, total, hex);
    defer allocator.free(eof);
    _ = tun.sendAndFlush(eof, tun.session.mesh.clock_ms) catch |e| {
        std.log.err("[guest-mesh] file_eof send failed: {}", .{e});
    };
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

    // Build host URL from --host-ip or default gateway (pass empty string to auto-detect)
    const host_url = if (cli.host_ip) |ip| blk: {
        break :blk try std.fmt.allocPrint(gpa, "{s}", .{ip});
    } else "";

    // Mesh session loop — persistent KCP tunnel, real-time push.
    // UpgradeSignal allows mesh LSA version check to signal the main loop
    // when a version mismatch is detected from Host broadcast.
    var upgrade_signal = UpgradeSignal{};
    try meshSessionLoop(io, gpa, sysinfo, host_url, &upgrade_signal, cli.mesh_port, cli.peer_mesh, shutdown);
}
