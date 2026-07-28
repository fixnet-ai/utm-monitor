//! UDP broadcast module (Guest side)
//! Broadcast local hostname + IP + target + MAC to LAN every second

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const protocol = @import("protocol.zig");
const tunproto = @import("tunproto.zig");
const mesh_mod = @import("mesh.zig");
const netconn = @import("netconn.zig");
const svc = @import("svc.zig");
const shm = @import("shm.zig");

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
// v0.11.0: pty session model — persistent pty per connection
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
/// Returns error.WriteFailed if the write fails (OS error or short write on Windows).
fn ptyWrite(session: *const PtySession, data: []const u8) error{ WriteFailed, Interrupted }!void {
    if (builtin.os.tag == .windows) {
        const WriteFile = @extern(
            *const fn (std.os.windows.HANDLE, [*]const u8, std.os.windows.DWORD, *std.os.windows.DWORD, ?*anyopaque) callconv(.winapi) std.os.windows.BOOL,
            .{ .name = "WriteFile", .library_name = "kernel32" },
        );
        var written: std.os.windows.DWORD = 0;
        if (@intFromEnum(WriteFile(session.stdin_fd, data.ptr, @intCast(data.len), &written, null)) == 0) {
            return error.WriteFailed;
        }
        if (written < data.len) {
            return error.WriteFailed;
        }
    } else {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = write(session.master_fd, data.ptr + offset, data.len - offset);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteFailed; // unexpected EOF on pty write
            offset += @intCast(n);
        }
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
    // lastIndexOf + validation (see state.zig).
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

/// Close a pty master fd. On Windows the fd is a pipe HANDLE from
/// CreatePipe — POSIX close() does nothing on it, so we must call
/// CloseHandle directly.
fn closePtyFd(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        const CloseHandle = @extern(
            *const fn (std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL,
            .{ .name = "CloseHandle", .library_name = "kernel32" },
        );
        _ = CloseHandle(@ptrCast(fd));
    } else {
        _ = close(fd);
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
    conn: *netconn.Connection,
    cmd_id: []const u8,
    dest_path: []const u8,
    expected_hash: []const u8,
) !void {
    // Create temp file in the same directory as destination.
    // Use random hex suffix to prevent TOCTOU symlink attacks.
    const dirname = std.fs.path.dirname(dest_path) orelse ".";
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    var temp_hex: [16]u8 = undefined;
    for (rand_bytes, 0..) |b, j| {
        temp_hex[j * 2] = "0123456789abcdef"[b >> 4];
        temp_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.utmm-{s}", .{ dirname, &temp_hex });
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
        if (!conn.isAlive()) {
            return error.TunnelDeadDuringUpload;
        }

        const n = conn.recv(&rbuf) catch |err| {
            std.log.err("[guest-mesh] Chunk recv error: {}", .{err});
            return err;
        };
        if (n == 0) {
            // Yield to give the TCP stack time to deliver more data.
            // Without this yield the tight recv loop starves the connection
            // from receiving new data. Large file transfers (>~1MB)
            // fail with timeout without this yield.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
            continue;
        }

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

                writer.interface.flush() catch |err| {
                    std.log.err("[guest-mesh] flush temp file failed: {}", .{err});
                    return error.WriteFailed;
                };

                // Verify SHA256 (incremental: sha256.update per chunk, final here)
                var hash: [32]u8 = undefined;
                sha256.final(&hash);
                const actual_hex = try hexHash(allocator, &hash);
                defer allocator.free(actual_hex);

                if (expected_hash.len > 0 and !std.mem.eql(u8, actual_hex, expected_hash)) {
                    std.log.err("[guest-mesh] Upload hash mismatch: got {s}, expected {s}", .{ actual_hex, expected_hash });
                    const resp = try tunproto.buildUploadResult(allocator, cmd_id, -1);
                    defer allocator.free(resp);
                    _ = conn.sendAndFlush(resp, 0) catch {};
                    return error.HashMismatch;
                }

                std.log.debug("[guest-mesh] Upload hash verified: {s}", .{actual_hex});

                // Atomic rename from temp to final path
                try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), dest_path, io);
                std.log.info("[guest-mesh] Upload complete: {s} ({d} bytes)", .{ dest_path, received });

                const resp = try tunproto.buildUploadResult(allocator, cmd_id, 0);
                defer allocator.free(resp);
                _ = conn.sendAndFlush(resp, 0) catch |e| {
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


/// Send a file as chunked transfer (download): open file, read MSS-aligned chunks,
/// send as file_chunk messages with incremental SHA256, finish with file_eof.
fn sendChunkedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    conn: *netconn.Connection,
    cmd_id: []const u8,
    path: []const u8,
) !void {
    // Chunk size: tunproto.FILE_CHUNK_DATA_MAX = 1200 bytes.
    // Each file_chunk maps to one tcpf frame, sent via sendAndFlush().
    //
    // Why 1200 bytes per chunk (not larger):
    //   - Low latency: ACK/interactive traffic can interleave between chunks.
    //   - Simpler protocol: each tcpf frame = one application chunk.
    //   - No fragmentation: app chunks don't get re-split by TCP.
    //
    // Trade-off vs larger chunks: more sendAndFlush() calls per file.
    // This is acceptable because files are typically < 100MB in practice.
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.log.err("[guest-mesh] Download open failed: {}", .{err});
        if (tunproto.buildFileEof(allocator, cmd_id, -1, 0, "")) |eof| {
            defer allocator.free(eof);
            _ = conn.sendAndFlush(eof, 0) catch {};
        } else |build_err| {
            std.log.err("[guest-mesh] buildFileEof failed for open error: {}", .{build_err});
        }
        return;
    };
    defer file.close(io);

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u32 = 0;
    var chunk_buf: [tunproto.FILE_CHUNK_DATA_MAX]u8 = undefined;
    var file_read_buf: [4096]u8 = undefined;  // disk read buffer, larger than chunk for efficiency
    var file_reader = file.reader(io, &file_read_buf);

    var chunk_count: u32 = 0;
    while (true) {
        const n = file_reader.interface.readSliceShort(&chunk_buf) catch |err2| {
            std.log.err("[guest-mesh] Download read error: {}", .{err2});
            if (tunproto.buildFileEof(allocator, cmd_id, -1, 0, "")) |eof| {
                defer allocator.free(eof);
                _ = conn.sendAndFlush(eof, 0) catch {};
            } else |build_err| {
                std.log.err("[guest-mesh] buildFileEof failed for read error: {}", .{build_err});
            }
            return err2;
        };
        if (n == 0) break; // EOF

        sha256.update(chunk_buf[0..n]);

        const chunk = try tunproto.buildFileChunk(allocator, cmd_id, chunk_buf[0..n]);
        defer allocator.free(chunk);
        _ = conn.sendAndFlush(chunk, 0) catch |e| {
            std.log.err("[guest-mesh] file_chunk send failed: {}", .{e});
            return e;
        };
        total += @intCast(n);
        chunk_count += 1;

        // Yield every 32 chunks to let the TCP stack process incoming ACKs.
        // Without this yield, the tight send loop can starve the connection.
        if (chunk_count % 32 == 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    }

    // Build hash and send file_eof
    var hash: [32]u8 = undefined;
    sha256.final(&hash);
    const hex = try hexHash(allocator, &hash);
    defer allocator.free(hex);

    std.log.info("[guest-mesh] Download complete: {s} ({d} bytes, sha256={s})", .{ path, total, hex });

    const eof = try tunproto.buildFileEof(allocator, cmd_id, 0, total, hex);
    defer allocator.free(eof);
    _ = conn.sendAndFlush(eof, 0) catch |e| {
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
// Guest TCP 主循环（替代 meshSessionLoop）
// ═══════════════════════════════════════════════════════════════════════════

/// Guest TCP 服务 — TCP + SOCKS4 + tcpf 替代 KCP tunnel。
///
/// 1. 启动 LSA/UDP 发现线程（mesh.zig）
/// 2. TCP 监听端口 2121
/// 3. accept 循环 → SOCKS4a 握手 → 处理命令
/// 4. 每命令独立连接，命令结束即关闭
pub fn guestTcpLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    upgrade: *UpgradeSignal,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    // ── LSA/UDP 发现线程 ──
    var mesh_opt: ?mesh_mod.Mesh = null;
    var mesh_thread: ?std.Thread = null;
    var mesh_socket_opt: ?std.Io.net.Socket = null;

    start_mesh: {
        var broadcast_addrs = getSubnetBroadcasts(allocator) catch |err| {
            std.log.err("[guest-tcp] getSubnetBroadcasts failed: {}", .{err});
            break :start_mesh;
        };

        if (peer_mesh) |pm| {
            if (protocol.parsePeerMeshAddr(pm)) |peer_addr| {
                broadcast_addrs.append(allocator, peer_addr) catch |err| {
                    std.log.err("[guest-tcp] append peer-mesh failed: {}", .{err});
                };
            } else {
                std.log.err("[guest-tcp] invalid --peer-mesh '{s}'", .{pm});
            }
        }

        var mesh_threaded = std.Io.Threaded.init(allocator, .{});
        const mesh_io = mesh_threaded.io();

        const bind_addr = std.Io.net.IpAddress.parse("0.0.0.0", mesh_port) catch |err| {
            std.log.err("[guest-tcp] Mesh bind addr parse: {}", .{err});
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        const mesh_socket = bind_addr.bind(mesh_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
            std.log.err("[guest-tcp] Mesh UDP bind :{d}: {}", .{ mesh_port, err });
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };
        mesh_socket_opt = mesh_socket;

        const node_id = if (peer_mesh != null)
            mesh_mod.deriveNodeId(info.mac, info.hostname) catch |err| {
                std.log.err("[guest-tcp] deriveNodeId: {}", .{err});
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            }
        else
            mesh_mod.parseNodeId(info.mac) catch |err| {
                std.log.err("[guest-tcp] parseNodeId: {}", .{err});
                mesh_socket.close(mesh_io);
                broadcast_addrs.deinit(allocator);
                break :start_mesh;
            };

        const node_info = std.fmt.allocPrint(allocator,
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:guest\nstatus:serving",
            .{ info.hostname, info.ip, info.target, protocol.VERSION, info.shell },
        ) catch |err| {
            std.log.err("[guest-tcp] node_info alloc: {}", .{err});
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        mesh_opt = mesh_mod.Mesh.init(allocator, node_id, node_info, mesh_socket, mesh_io, &upgrade.needed, broadcast_addrs, getSubnetBroadcasts, null, null, null) catch |err| {
            std.log.err("[guest-tcp] Mesh init: {}", .{err});
            allocator.free(node_info);
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(allocator);
            break :start_mesh;
        };

        mesh_thread = std.Thread.spawn(.{}, mesh_mod.Mesh.run, .{&mesh_opt.?}) catch |err| {
            std.log.err("[guest-tcp] Mesh thread spawn: {}", .{err});
            mesh_opt.?.deinit();
            mesh_socket.close(mesh_io);
            mesh_opt = null;
            break :start_mesh;
        };

        std.log.info("[guest-tcp] LSA mesh started on UDP :{d}", .{mesh_port});
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
        std.log.err("[guest-tcp] Mesh failed to start", .{});
        return error.MeshInitFailed;
    }

    // ── TCP accept 循环 ──
    var listener = netconn.TcpListener.init(io, mesh_port) catch |err| {
        std.log.err("[guest-tcp] TCP listen :{d} failed: {}", .{ mesh_port, err });
        return error.TcpBindFailed;
    };
    defer listener.deinit();

    std.log.info("[guest-tcp] TCP server listening on :{d}", .{mesh_port});

    while (true) {
        if (shutdown) |s| {
            if (s.load(.acquire)) {
                std.log.info("[guest-tcp] Shutdown requested", .{});
                break;
            }
        }

        // 检查升级信号
        if (upgrade.needed.load(.acquire)) {
            std.log.info("[guest-tcp] upgrade signal detected", .{});
            upgrade.needed.store(false, .release);
            // TODO: TCP 版本自动升级
        }

        // Accept SOCKS4 连接
        var conn = listener.accept(info.hostname) catch |err| {
            if (err == error.WouldBlock) continue;
            std.log.err("[guest-tcp] accept failed: {}", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };

        // 处理单条命令
        handleOneCommand(io, allocator, info, &conn, shutdown) catch |err| {
            std.log.err("[guest-tcp] handleOneCommand: {}", .{err});
        };
        conn.deinit();
    }
}

/// 处理一条命令（单个 TCP 连接）。
fn handleOneCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *netconn.Connection,
    shutdown: ?*std.atomic.Value(bool),
) !void {
    var rbuf: [262144]u8 = undefined;

    while (true) {
        if (shutdown) |s| {
            if (s.load(.acquire)) return;
        }
        if (!conn.isAlive()) return;

        const n = conn.recv(&rbuf) catch |err| {
            std.log.err("[guest-tcp] recv error: {}", .{err});
            return;
        };
        if (n == 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
            continue;
        }

        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        switch (msg_type) {
            @intFromEnum(tunproto.MsgType.pty_exec_input) => {
                // 执行命令并返回
                try handleExecCmd(io, allocator, info, conn, payload);
                return; // 命令完成，关闭连接
            },
            @intFromEnum(tunproto.MsgType.upload_cmd) => {
                if (tunproto.parseUploadCmd(payload)) |cmd| {
                    std.log.debug("[guest-tcp] Upload cmd: {s} ({d} bytes)", .{ cmd.path, cmd.file_size });
                    receiveChunkedFile(io, allocator, conn, cmd.cmd_id, cmd.path, cmd.file_hash) catch |e| {
                        std.log.err("[guest-tcp] Upload failed: {}", .{e});
                        const resp = tunproto.buildUploadResult(allocator, cmd.cmd_id, -1) catch continue;
                        defer allocator.free(resp);
                        _ = conn.sendAndFlush(resp, 0) catch {};
                    };
                }
                return;
            },
            @intFromEnum(tunproto.MsgType.download_cmd) => {
                if (tunproto.parseDownloadCmd(payload)) |cmd| {
                    std.log.info("[guest-tcp] Download cmd: {s}", .{cmd.path});
                    sendChunkedFile(io, allocator, conn, cmd.cmd_id, cmd.path) catch |e| {
                        std.log.err("[guest-tcp] Download failed: {}", .{e});
                        const eof = tunproto.buildFileEof(allocator, cmd.cmd_id, -1, 0, "") catch continue;
                        defer allocator.free(eof);
                        _ = conn.sendAndFlush(eof, 0) catch {};
                    };
                }
                return;
            },
            else => {
                std.log.info("[guest-tcp] Unknown msg type: {d}", .{msg_type});
                return;
            },
        }
    }
}

/// 处理单次 exec 命令：spawn shell → 写入命令 → 流式读取输出 → 发送 exec_done。
fn handleExecCmd(
    _io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    conn: *netconn.Connection,
    payload: []const u8,
) !void {
    _ = _io;
    const input = tunproto.parsePtyExecInput(payload) orelse {
        std.log.err("[guest-tcp] parsePtyExecInput failed", .{});
        return;
    };

    std.log.info("[guest-tcp] exec cmd_id={s} cmd={s}", .{ input.cmd_id, input.command });

    // 生成带 MDELIM 标记的命令
    const cmd_with_marker = try buildCmdWithMarker(allocator, input.command);
    defer allocator.free(cmd_with_marker);

    // Spawn shell（每命令新 shell）
    const pty = ptySpawn(allocator, info.shell) catch |err| {
        std.log.err("[guest-tcp] ptySpawn failed: {}", .{err});
        const done_msg = tunproto.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
        defer allocator.free(done_msg);
        _ = conn.sendAndFlush(done_msg, 0) catch {};
        return;
    };
    defer {
        allocator.free(pty.shell);
        killChild(pty.child_pid);
        closePtyFd(pty.master_fd);
    }

    // 写入命令到 pty
    ptyWrite(&pty, cmd_with_marker) catch |err| {
        std.log.err("[guest-tcp] ptyWrite failed: {}", .{err});
        const done_msg = tunproto.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
        defer allocator.free(done_msg);
        _ = conn.sendAndFlush(done_msg, 0) catch {};
        return;
    };

    // 流式读取 pty 输出 → 发送 pty_exec_output 帧
    var output_buf: [4096]u8 = undefined;
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(allocator);

    while (true) {
        const nr = ptyRead(pty.master_fd, &output_buf) catch |err| {
            std.log.err("[guest-tcp] ptyRead error: {}", .{err});
            break;
        };
        if (nr == 0) break; // EOF

        accumulated.appendSlice(allocator, output_buf[0..nr]) catch continue;

        // 扫描 MDELIM 标记
        if (scanForMarker(accumulated.items)) |exit_code| {
            // 发送最后一段输出（去掉标记部分）
            const marker_pos = std.mem.lastIndexOf(u8, accumulated.items, "MDELIM:") orelse accumulated.items.len;
            const clean_output = accumulated.items[0..marker_pos];
            if (clean_output.len > 0) {
                const output_msg = tunproto.buildPtyExecOutput(allocator, input.cmd_id, clean_output) catch continue;
                defer allocator.free(output_msg);
                _ = conn.sendAndFlush(output_msg, 0) catch {};
            }

            // 发送 exec_done
            const done_msg = tunproto.buildPtyExecDone(allocator, input.cmd_id, exit_code) catch break;
            defer allocator.free(done_msg);
            _ = conn.sendAndFlush(done_msg, 0) catch {};
            std.log.info("[guest-tcp] exec done: cmd_id={s} exit={d}", .{ input.cmd_id, exit_code });
            return;
        }
    }

    // pty 异常关闭（无 MDELIM 标记）
    const done_msg = tunproto.buildPtyExecDone(allocator, input.cmd_id, -1) catch return;
    defer allocator.free(done_msg);
    _ = conn.sendAndFlush(done_msg, 0) catch {};
    std.log.info("[guest-tcp] exec done (pty closed): cmd_id={s}", .{input.cmd_id});
}

/// 构建带 MDELIM 标记的命令行。
fn buildCmdWithMarker(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.allocPrint(allocator, "{s}\r\necho MDELIM:%ERRORLEVEL%\r\n", .{cmd});
    }
    return std.fmt.allocPrint(allocator, "{s}; echo MDELIM:$?\n", .{cmd});
}

/// 扫描累积输出中的 MDELIM 标记。返回 exit code，未找到返回 null。
fn scanForMarker(data: []const u8) ?i32 {
    const marker = "MDELIM:";
    const pos = std.mem.lastIndexOf(u8, data, marker) orelse return null;
    const after_marker = data[pos + marker.len ..];
    const end = std.mem.indexOfAny(u8, after_marker, "\r\n") orelse return null;
    const num_str = after_marker[0..end];
    return std.fmt.parseInt(i32, num_str, 10) catch null;
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
    // UpgradeSignal allows mesh LSA version check to signal the main loop
    // when a version mismatch is detected from Host broadcast.
    var upgrade_signal = UpgradeSignal{};
    try guestTcpLoop(io, gpa, sysinfo, &upgrade_signal, cli.mesh_port, cli.peer_mesh, shutdown);
}
