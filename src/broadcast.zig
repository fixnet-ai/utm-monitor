//! UDP broadcast module (Guest side)
//! Broadcast local hostname + IP + target + MAC to LAN every second

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const wsclient = @import("wsclient.zig");
const wsproto_mod = @import("wsproto.zig");

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
// HTTP announce loop (v0.3.0: replaces UDP broadcast + TCP server)
// Guest POSTs /announce every 1s, processes pending commands from response.
// ═══════════════════════════════════════════════════════════════════════════

/// Timer thread: sends periodic announce to keep Host unblocked.
/// Used only on Windows (no poll). POSIX uses single-threaded poll loop.
fn runTimerThread(ctx: *TimerCtx) void {
    while (ctx.running) {
        ctx.conn.io.sleep(std.Io.Duration.fromNanoseconds(std.time.ns_per_s), .awake) catch {};
        if (!ctx.running) return;
        ctx.conn.writeFrame(ctx.msg, .binary) catch {
            ctx.running = false;
            return;
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// v0.5.0: pty session model — persistent pty per WebSocket connection
// ═══════════════════════════════════════════════════════════════════════════

// POSIX pty externs (available on macOS and Linux via libc)
extern "c" fn posix_openpt(flags: u32) std.posix.fd_t;
extern "c" fn grantpt(fd: std.posix.fd_t) c_int;
extern "c" fn unlockpt(fd: std.posix.fd_t) c_int;
extern "c" fn ptsname(fd: std.posix.fd_t) ?[*:0]u8;
extern "c" fn fork() std.posix.pid_t;
extern "c" fn setsid() std.posix.pid_t;
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
        _ = std.c.execve(shell_path.ptr, &argv, &[_:null]?[*:0]const u8{null});
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
    conn: *wsclient.WsConn,
    io: std.Io,
    allocator: std.mem.Allocator,
    active_cmd_id: *[]const u8,
    cmd_mutex: *std.Io.Mutex,
    pty_dead: *bool,
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
                pty_dead.* = true;
                if (builtin.os.tag == .windows) {
                    conn.writeFrame(&.{}, .ping) catch {};
                }
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
            pty_dead.* = true;
            // On Windows, send ping to wake main loop from readFrame
            if (builtin.os.tag == .windows) {
                conn.writeFrame(&.{}, .ping) catch {};
            }
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

        // Send pty_output frame
        const frame = wsproto_mod.buildPtyOutput(allocator, cmd_owned, buf[0..n]) catch continue;
        defer allocator.free(frame);
        conn.writeFrame(frame, .binary) catch |err| {
            std.log.err("[guest-pty] pty_output write error: {}", .{err});
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

const TimerCtx = struct {
    conn: *wsclient.WsConn,
    msg: []const u8,
    running: bool,
};

/// WebSocket announce loop: persistent WS connection to Host.
/// POSIX: single-threaded poll loop (no races).
/// Windows: timer thread + mutex-protected writes.
pub fn wsAnnounceLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    info: SystemInfo,
    host_url: []const u8,
) !void {
    const host: []const u8 = if (host_url.len > 0) host_url else blk: {
        const gw = getDefaultGateway(io, allocator) catch blk2: {
            break :blk2 try allocator.dupe(u8, "192.168.64.1");
        };
        break :blk gw;
    };
    defer if (host_url.len == 0) allocator.free(host);

    // Outer reconnect loop: connect, announce, spawn pty, process messages.
    // Any connection failure or pty death causes reconnect from scratch.
    var conn: wsclient.WsConn = undefined;
    while (true) {
        // Connect with retry backoff
        while (true) {
            std.log.info("[guest-ws] Connecting to {s}:{d}", .{ host, protocol.DEFAULT_PORT });
            conn = wsclient.WsConn.connect(io, allocator, host, protocol.DEFAULT_PORT) catch |err| {
                std.log.err("[guest-ws] Connect failed: {} — retrying in 3s", .{err});
                std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
                continue;
            };
            break;
        }

        // Send initial announce
        {
            const frame = try wsproto_mod.buildAnnounce(
                allocator, info.hostname, info.ip, info.target, info.mac, protocol.VERSION, info.shell,
            );
            defer allocator.free(frame);
            conn.writeFrame(frame, .binary) catch |err| {
                std.log.err("[guest-ws] Announce write failed: {}", .{err});
                conn.close();
                std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
                continue;
            };
        }

        std.log.info("[guest-ws] Connected and announced — waiting for pty_spawn", .{});

        // Wait for pty_spawn from Host
        var rbuf: [65536]u8 = undefined;
        const spawn_frame = blk: {
            while (true) {
                const f = conn.readFrame(&rbuf) catch |err| {
                    std.log.err("[guest-ws] pty_spawn read error: {}", .{err});
                    break :blk null;
                };
                if (f.opcode == .close) break :blk null;
                if (f.opcode == .binary and f.data.len > 0 and f.data[0] == @intFromEnum(wsproto_mod.MsgType.pty_spawn)) {
                    break :blk f;
                }
                // Ignore any other frames before pty_spawn
                std.log.debug("[guest-ws] Ignoring pre-spawn frame type={d}", .{f.data[0]});
            }
        };
        if (spawn_frame == null) {
            std.log.info("[guest-ws] No pty_spawn received, reconnecting...", .{});
            conn.close();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
            continue;
        }

        // Spawn pty session
        const shell = detectShell(allocator) catch "/bin/sh";
        defer allocator.free(shell);
        const pty = ptySpawn(allocator, shell) catch |err| {
            std.log.err("[guest-ws] ptySpawn failed: {}", .{err});
            conn.close();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
            continue;
        };

        defer {
            allocator.free(pty.shell);
            killChild(pty.child_pid);
            _ = close(pty.master_fd);
        }

        // Shared state between main loop and ptyReadLoop thread
        var active_cmd_id: []const u8 = &.{}; // current cmd_id for pty_output tagging
        var cmd_mutex: std.Io.Mutex = std.Io.Mutex.init;
        var pty_dead: bool = false;

        // Start ptyReadLoop thread
        {
            const thread_args = try allocator.create(struct {
                master_fd: std.posix.fd_t,
                conn: *wsclient.WsConn,
                io: std.Io,
                allocator: std.mem.Allocator,
                active_cmd_id: *[]const u8,
                cmd_mutex: *std.Io.Mutex,
                pty_dead: *bool,
            });
            thread_args.* = .{
                .master_fd = pty.master_fd,
                .conn = &conn,
                .io = io,
                .allocator = allocator,
                .active_cmd_id = &active_cmd_id,
                .cmd_mutex = &cmd_mutex,
                .pty_dead = &pty_dead,
            };
            const t = try std.Thread.spawn(.{}, ptyReadLoop, .{
                thread_args.master_fd,
                thread_args.conn,
                thread_args.io,
                thread_args.allocator,
                thread_args.active_cmd_id,
                thread_args.cmd_mutex,
                thread_args.pty_dead,
            });
            t.detach();
        }

    // Pre-build announce message — static data, reused every second
    const announce_msg = try wsproto_mod.buildAnnounce(
        allocator, info.hostname, info.ip, info.target, info.mac, protocol.VERSION, info.shell,
    );
    defer allocator.free(announce_msg);

    // Windows: start timer thread for periodic re-announce.
    // POSIX: use single-threaded poll loop (no race).
    var timer_ctx: if (builtin.os.tag == .windows) TimerCtx else struct {} = if (builtin.os.tag == .windows)
        TimerCtx{ .conn = &conn, .msg = announce_msg, .running = true }
    else
        .{};
    if (builtin.os.tag == .windows) {
        const timer_thread = std.Thread.spawn(.{}, runTimerThread, .{ &timer_ctx }) catch |err| {
            std.log.err("[guest-ws] Timer thread spawn failed: {}", .{err});
            return err;
        };
        timer_thread.detach();
    }
    defer if (builtin.os.tag == .windows) {
        timer_ctx.running = false;
    };

    while (true) {
        // POSIX: poll socket with 1s timeout. Windows: timer thread handles announces.
        if (builtin.os.tag != .windows and conn.leftover_len == 0) {
            var fds: [1]std.posix.pollfd = .{
                .{ .fd = conn.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const poll_n = std.posix.poll(&fds, 1000) catch |err| {
                std.log.err("[guest-ws] poll error: {}", .{err});
                break;
            };
            if (poll_n == 0) {
                conn.writeFrame(announce_msg, .binary) catch |err| {
                    std.log.err("[guest-ws] Announce write failed: {}", .{err});
                    break;
                };
                // Check pty_dead before continuing — ptyReadLoop may have detected EOF
                if (pty_dead) {
                    std.log.info("[guest-ws] Pty session ended (detected on poll timeout), reconnecting...", .{});
                    break;
                }
                continue;
            }
        }

        const frame = conn.readFrame(&rbuf) catch |err| {
            std.log.err("[guest-ws] Read error: {}", .{err});
            break;
        };

        switch (frame.opcode) {
            .binary => {
                if (frame.data.len == 0) continue;
                const msg_type: u8 = frame.data[0];
                const payload = frame.data[1..];

                switch (msg_type) {
                    @intFromEnum(wsproto_mod.MsgType.pty_input) => {
                        if (wsproto_mod.parsePtyInput(payload)) |input| {
                            // Update active_cmd_id under mutex
                            cmd_mutex.lock(io) catch {};
                            if (active_cmd_id.len > 0) allocator.free(active_cmd_id);
                            active_cmd_id = allocator.dupe(u8, input.cmd_id) catch &.{};
                            cmd_mutex.unlock(io);

                            // Write command data to pty master (stdin of shell)
                            ptyWrite(&pty, input.data);
                        }
                    },
                    @intFromEnum(wsproto_mod.MsgType.pty_signal) => {
                        if (payload.len > 0) {
                            killForegroundProcess(pty.master_fd, payload[0]);
                        }
                    },
                    @intFromEnum(wsproto_mod.MsgType.pty_resize) => {
                        if (wsproto_mod.parsePtyResize(payload)) |_| {
                            // TODO: apply terminal resize via TIOCSWINSZ
                        }
                    },
                    @intFromEnum(wsproto_mod.MsgType.upload_req) => {
                        if (wsproto_mod.parseUploadReq(payload)) |req| {
                            std.log.debug("[guest-ws] Upload: {s} ({d} bytes)", .{ req.path, req.file_data.len });
                            const exit_code: i32 = writeFile(io, allocator, req.path, req.file_data) catch |err| blk: {
                                std.log.err("[guest-ws] Upload write failed: {}", .{err});
                                break :blk -1;
                            };
                            const resp = wsproto_mod.buildUploadResp(allocator, req.cmd_id, exit_code) catch continue;
                            defer allocator.free(resp);
                            conn.writeFrame(resp, .binary) catch |err| {
                                std.log.err("[guest-ws] Upload resp write failed: {}", .{err});
                                break;
                            };
                        }
                    },
                    @intFromEnum(wsproto_mod.MsgType.download_req) => {
                        if (wsproto_mod.parseDownloadReq(payload)) |req| {
                            std.log.debug("[guest-ws] Download: {s}", .{req.path});
                            const file_content = readFileContent(io, allocator, req.path) catch |err| {
                                std.log.err("[guest-ws] Download read failed: {}", .{err});
                                const err_resp = wsproto_mod.buildDownloadResp(allocator, req.cmd_id, -1, "") catch continue;
                                defer allocator.free(err_resp);
                                conn.writeFrame(err_resp, .binary) catch {};
                                continue;
                            };
                            defer allocator.free(file_content);
                            const resp = wsproto_mod.buildDownloadResp(allocator, req.cmd_id, 0, file_content) catch continue;
                            defer allocator.free(resp);
                            conn.writeFrame(resp, .binary) catch |err| {
                                std.log.err("[guest-ws] Download resp write failed: {}", .{err});
                                break;
                            };
                        }
                    },
                    else => {
                        std.log.debug("[guest-ws] Unknown msg type: {d}", .{msg_type});
                    },
                }
            },
            .pong => {
                // Keepalive pong from Host — continue
            },
            .ping => {
                // Respond with pong
                conn.writeFrame(frame.data, .pong) catch {};
            },
            .close => {
                std.log.info("[guest-ws] Host requested close", .{});
                break;
            },
            else => {
                std.log.debug("[guest-ws] Unexpected opcode: {}", .{frame.opcode});
            },
        }

        // pty shell exited: reconnect for fresh session
        if (pty_dead) {
            std.log.info("[guest-ws] Pty session ended, reconnecting...", .{});
            break;
        }
    }

    std.log.info("[guest-ws] Disconnected, reconnecting in 3s...", .{});
    conn.close();
    std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
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

fn downloadAndUpgrade(io: std.Io, allocator: std.mem.Allocator, client: *std.http.Client, url_path: []const u8) !void {
    // Download the new binary
    var download_buf: [10 * 1024 * 1024]u8 = undefined;
    var download_writer: std.Io.Writer = .fixed(&download_buf);
    const result = try client.fetch(.{
        .location = .{ .url = url_path },
        .method = .GET,
        .response_writer = &download_writer,
        .keep_alive = false,
    });
    if (result.status != .ok) return error.DownloadFailed;

    const data = download_writer.buffered();
    if (data.len < 100 * 1024) return error.BinaryTooSmall;

    // Write utmm.next
    const install_dir = if (builtin.os.tag == .windows) "C:\\opt\\utmm" else "/opt/utmm";
    const next_name = if (builtin.os.tag == .windows) "utmm.next.exe" else "utmm.next";
    const next_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ install_dir, next_name });
    defer allocator.free(next_path);

    var dir = try std.Io.Dir.cwd().openDir(io, install_dir, .{});
    defer dir.close(io);
    var file = try dir.createFile(io, next_name, .{});
    defer file.close(io);
    var wb: [65536]u8 = undefined;
    var file_writer = file.writer(io, &wb);
    _ = try file_writer.interface.write(data);
    try file_writer.interface.flush();

    // Trigger self-upgrade by restarting
    std.log.info("[guest-http] Downloaded upgrade to {s} ({d} bytes) — restarting", .{ next_path, data.len });
    const restart_cmd = if (builtin.os.tag == .windows)
        "cmd /c move /Y C:\\opt\\utmm\\utmm.next.exe C:\\opt\\utmm\\utmm.exe && C:\\opt\\utmm\\utmm.exe --svc"
    else
        "mv /opt/utmm/utmm.next /opt/utmm/utmm && /opt/utmm/utmm --svc &";
    _ = std.process.run(std.heap.page_allocator, io, .{ .argv = &.{ "sh", "-c", restart_cmd } }) catch {};
    std.process.exit(0);
}
