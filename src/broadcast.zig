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
        const shell = try detectShell(allocator);
        return SystemInfo{
            .hostname = hostname,
            .ip = ip,
            .mac = mac,
            .target = target,
            .iface_name = try allocator.dupe(u8, "unknown"),
            .shell = shell,
        };
    }

    // Unix: use getifaddrs() to enumerate interfaces, pick first physical NIC
    var ifap: ?*ifaddrs = undefined;
    if (getifaddrs(&ifap) != 0) {
        const shell = try detectShell(allocator);
        return SystemInfo{
            .hostname = hostname,
            .ip = try allocator.dupe(u8, "0.0.0.0"),
            .mac = try allocator.dupe(u8, "00:00:00:00:00:00"),
            .target = target,
            .iface_name = try allocator.dupe(u8, "unknown"),
            .shell = shell,
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

test "getDefaultGateway - signature" { _ = getDefaultGateway; }

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

    // Convert UTF-8 command line to null-terminated UTF-16LE for CreateProcessW.
    // std.unicode.utf8ToUtf16LeWithNull was removed in Zig 0.16.0.
    const cmd_u8 = "cmd.exe /k";
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

    std.log.info("[guest-pty] Windows pipe pty: cmd.exe /k pid={d}", .{pi.dwProcessId});

    return PtySession{
        .master_fd = stdout_read,
        .child_pid = pi.hProcess,
        .shell = try allocator.dupe(u8, "cmd.exe /k"),
        .stdin_fd = stdin_write,
    };
}

/// Kill foreground process group on pty (pty_signal handler).
fn killForegroundProcess(master_fd: std.posix.fd_t, signal: u8) void {
    _ = master_fd;
    _ = signal;
    // TODO: tcgetpgrp(master_fd) → kill(-pgrp, sig)
    // For now, signal delivery via pty_signal frame is a stub.
    // Closing the WS connection (--kick) implicitly kills the shell via SIGHUP.
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

        // Send pty_exec_output frame via tunnel
        const frame = tunproto.buildPtyExecOutput(allocator, cmd_owned, buf[0..n]) catch continue;
        defer allocator.free(frame);
        _ = tun.send(frame) catch |err| {
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
) !void {
    // Extract Host IP from host_url for LSA version check filtering.
    // host_url format: "http://IP:PORT" — strip to just the IP.
    const host_gateway_ip = extractHostIp(host_url);

    // Start mesh networking thread (LSA broadcast + KCP data dispatch).
    // Mesh owns UDP :2121 for LSA + KCP relay + PING/PONG.
    var mesh_opt: ?mesh_mod.Mesh = null;
    var mesh_thread: ?std.Thread = null;
    var mesh_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var mesh_socket_opt: ?net.Socket = null;

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

        // Dedicated Io for mesh background thread (required on all platforms)
        const mesh_io = mesh_threaded.io();

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
            "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}",
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
        mesh_threaded.deinit();
    }

    if (mesh_opt == null) {
        std.log.err("[guest-mesh] Mesh failed to start, exiting", .{});
        return error.MeshInitFailed;
    }

    // Main loop: wait for Host tunnel, process commands, handle reconnect.
    while (true) {
        // Wait for Host to establish a KCP tunnel and send pty_spawn
        var tunnel = waitForHostTunnel(io, allocator, &mesh_opt) catch |err| {
            std.log.err("[guest-mesh] waitForHostTunnel failed: {}", .{err});
            continue;
        };

        // Read pty_spawn from Host
        const spawn_ok = blk: {
            var rbuf: [4096]u8 = undefined;
            while (true) {
                const n = tunnel.recv(&rbuf) catch |err| {
                    std.log.err("[guest-mesh] pty_spawn recv error: {}", .{err});
                    break :blk false;
                };
                if (n == 0) {
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                    continue;
                }
                if (n > 0 and rbuf[0] == @intFromEnum(tunproto.MsgType.pty_spawn)) {
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
        const shell = detectShell(allocator) catch "/bin/sh";
        defer allocator.free(shell);
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

        std.log.info("[guest-mesh] Pty session started, entering command loop", .{});

        // Command dispatch loop
        var rbuf: [65536]u8 = undefined;
        while (!pty_dead.load(.acquire)) {
            // Check auto-upgrade signal before blocking recv.
            // Skip when peer_mesh is set (local testing mode — network LSAs
            // from other machines may have version mismatches unrelated to us).
            if (peer_mesh == null and upgrade.needed.load(.acquire)) {
                std.log.info("[upgrade] Version mismatch, triggering self-upgrade", .{});
                const gw = getDefaultGateway(io, allocator) catch "192.168.64.1";
                defer if (!std.mem.eql(u8, gw, "192.168.64.1")) allocator.free(gw);
                const bin_name = protocol.deploymentFilename(info.target) orelse "utmm";
                const upgrade_url = std.fmt.allocPrint(allocator,
                    "http://{s}:{d}/bin/{s}", .{ gw, protocol.DEFAULT_PORT, bin_name }) catch break;
                defer allocator.free(upgrade_url);
                triggerSelfUpgrade(io, allocator, upgrade_url) catch |err| {
                    std.log.err("[upgrade] triggerSelfUpgrade failed: {}", .{err});
                };
                break;
            }

            const n = tunnel.recv(&rbuf) catch |err| {
                std.log.err("[guest-mesh] tunnel recv error: {}", .{err});
                break;
            };
            if (n == 0) {
                // No data — short sleep then retry
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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
                        cmd_mutex.lock(io) catch {};
                        if (active_cmd_id.len > 0) allocator.free(active_cmd_id);
                        active_cmd_id = allocator.dupe(u8, input.cmd_id) catch &.{};
                        cmd_mutex.unlock(io);

                        // Write command data to pty master (stdin of shell)
                        ptyWrite(&pty, input.command);
                    }
                },
                @intFromEnum(tunproto.MsgType.signal_cmd) => {
                    if (payload.len > 0) {
                        killForegroundProcess(pty.master_fd, payload[0]);
                    }
                },
                @intFromEnum(tunproto.MsgType.upload_data) => {
                    if (tunproto.parseUploadData(payload)) |req| {
                        std.log.debug("[guest-mesh] Upload: {s} ({d} bytes)", .{ req.path, req.file_data.len });
                        const exit_code: i32 = writeFile(io, allocator, req.path, req.file_data) catch |err2| blk2: {
                            std.log.err("[guest-mesh] Upload write failed: {}", .{err2});
                            break :blk2 -1;
                        };
                        const resp = tunproto.buildUploadResult(allocator, req.cmd_id, exit_code) catch |err2| {
                            std.log.err("[guest-mesh] buildUploadResult failed: {}", .{err2});
                            continue;
                        };
                        defer allocator.free(resp);
                        _ = tunnel.send(resp) catch |e| {
                            std.log.err("[guest-mesh] upload_result send failed: {}", .{e});
                        };
                    }
                },
                @intFromEnum(tunproto.MsgType.download_cmd) => {
                    if (tunproto.parseDownloadCmd(payload)) |req| {
                        std.log.debug("[guest-mesh] Download: {s}", .{req.path});
                        const file_content = readFileContent(io, allocator, req.path) catch |err2| {
                            std.log.err("[guest-mesh] Download read failed: {}", .{err2});
                            const err_resp = tunproto.buildDownloadResult(allocator, req.cmd_id, -1, "") catch continue;
                            defer allocator.free(err_resp);
                            _ = tunnel.send(err_resp) catch {};
                            continue;
                        };
                        defer allocator.free(file_content);
                        const resp = tunproto.buildDownloadResult(allocator, req.cmd_id, 0, file_content) catch |err2| {
                            std.log.err("[guest-mesh] buildDownloadResult failed: {}", .{err2});
                            continue;
                        };
                        defer allocator.free(resp);
                        _ = tunnel.send(resp) catch |e| {
                            std.log.err("[guest-mesh] download_result send failed: {}", .{e});
                        };
                    }
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
            m.sessions_mutex.lock(m.io) catch {};
            const count = m.sessions.count();
            if (count > 0) {
                var it = m.sessions.iterator();
                while (it.next()) |entry| {
                    const sess = entry.value_ptr.*;
                    const peek = sess.kcp_inst.peekSize();
                    if (peek > 0) {
                        m.sessions_mutex.unlock(m.io);
                        return tunnel_mod.Tunnel.init(allocator, io, sess);
                    }
                }
            }
            m.sessions_mutex.unlock(m.io);
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    }
}
/// Write data to file. Returns 0 on success, -1 on failure.
fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !i32 {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var wb: [65536]u8 = undefined;
    var writer = file.writer(io, &wb);
    _ = try writer.interface.write(data);
    try writer.interface.flush();
    return 0;
}

/// Read file content. Caller owns returned string.
fn readFileContent(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, @enumFromInt(50 * 1024 * 1024));
}

/// Copy current executable to utmm-old[.exe], launch it as a detached process
/// with --update-url, then exit. The utmm-old process handles the actual upgrade.
fn triggerSelfUpgrade(io: std.Io, allocator: std.mem.Allocator, upgrade_url: []const u8) !void {

    // Get current executable path
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    const old_name = if (builtin.os.tag == .windows) "utmm-old.exe" else "utmm-old";
    const old_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ exe_dir, old_name });
    defer allocator.free(old_path);

    std.log.info("[upgrade] Copying self to {s}", .{old_path});

    // Copy current exe to utmm-old (overwrite any previous copy)
    const max_copy = 20 * 1024 * 1024;
    const copy_buf = try allocator.alloc(u8, max_copy);
    defer allocator.free(copy_buf);

    var src = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
    defer src.close(io);

    const exe_size = try src.readPositionalAll(io, copy_buf, 0);
    if (exe_size >= max_copy) return error.BinaryTooLarge;

    // Delete old utmm-old if exists, then create new and write copy
    std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
    {
        var dst = try std.Io.Dir.cwd().createFile(io, old_path, .{});
        defer dst.close(io);
        try dst.writeStreamingAll(io, copy_buf[0..exe_size]);
    }
    // dst is now closed — file handle released before spawn

    // chmod +x on POSIX (direct syscall, no shell)
    if (builtin.os.tag != .windows) {
        const chmod_rc = std.c.chmod(@ptrCast(old_path), 0o755);
        if (chmod_rc != 0) {
            std.log.err("[upgrade] chmod failed: errno={}", .{std.c._errno().*});
            return error.ChmodFailed;
        }
    }

    // Launch utmm-old as detached process
    std.log.info("[upgrade] Launching utmm-old with url={s}", .{upgrade_url});

    if (builtin.os.tag == .windows) {
        // Use std.process.spawn for proper detached process launch
        _ = std.process.spawn(io, .{
            .argv = &.{ old_path, "--update-url", upgrade_url },
        }) catch |err| {
            std.log.err("[upgrade] Failed to launch utmm-old: {}", .{err});
            return error.LaunchFailed;
        };
    } else {
        // POSIX: fork + setsid + execve — detached background process
        const old_path_z = try allocator.dupeZ(u8, old_path);
        defer allocator.free(old_path_z);
        const upgrade_url_z = try allocator.dupeZ(u8, upgrade_url);
        defer allocator.free(upgrade_url_z);

        const pid = fork();
        if (pid == 0) {
            // Child: detach from parent session
            _ = setsid();

            const argv = [_:null]?[*:0]const u8{ old_path_z.ptr, "--update-url", upgrade_url_z.ptr };
            _ = execve(old_path_z.ptr, &argv, std.c.environ);
            // execve failed
            std.process.exit(1);
        } else if (pid < 0) {
            std.log.err("[upgrade] fork failed", .{});
            return error.LaunchFailed;
        }
        // Parent: child runs independently, continue
    }

    std.process.exit(0);
}

test "getSubnetBroadcasts - signature" { _ = getSubnetBroadcasts; }
