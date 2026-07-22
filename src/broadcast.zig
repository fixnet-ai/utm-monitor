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

/// Cross-platform child process termination.
/// POSIX: killpg(SIGTERM), fallback to kill(SIGTERM).
/// Windows: OpenProcess + TerminateProcess (no process group concept for schtasks).
fn killChildProcess(pid: std.posix.pid_t) void {
    switch (builtin.os.tag) {
        .windows => {
            const TerminateProcess = @extern(
                *const fn (std.os.windows.HANDLE, std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
                .{ .name = "TerminateProcess", .library_name = "kernel32" },
            );
            _ = TerminateProcess(pid, 1);
        },
        .linux, .macos => {
            const pgid = -@as(std.posix.pid_t, @intCast(pid));
            std.posix.kill(pgid, std.posix.SIG.TERM) catch {
                std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            };
        },
        else => @compileError("unsupported OS for killChildProcess"),
    }
}

const TimerCtx = struct {
    conn: *wsclient.WsConn,
    msg: []const u8,
    running: bool,
};

/// Thread args for exec stdout poll loop. Spawned as detached thread —
/// reads child stdout, writes exec_stdout/exec_exit to WebSocket.
/// main loop handles stdin and signal delivery via shared handles.
const ExecStdoutThreadArgs = struct {
    stdout_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    conn: *wsclient.WsConn,
    io: std.Io,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
    exec_done: *bool,
};

/// Thread: poll child stdout, send exec_stdout frames. Detect child exit
/// via waitpid, send exec_exit frame. Never reads WebSocket (main loop does).
fn execStdoutThread(args: *ExecStdoutThreadArgs) void {
    defer {
        args.allocator.free(args.cmd_id);
        args.allocator.destroy(args);
    }

    var stdout_buf: [4096]u8 = undefined;

    while (true) {
        var fds: [1]std.posix.pollfd = .{
            .{ .fd = args.stdout_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 500) catch |err| {
            std.log.err("[guest-ws] exec stdout poll: {}", .{err});
            break;
        };

        // Non-blocking check: child exited?
        var exit_status: i32 = 0;
        const waited = std.c.waitpid(args.child_pid, &exit_status, std.c.W.NOHANG);
        if (waited < 0) {
            std.log.err("[guest-ws] exec waitpid error", .{});
            break;
        }
        if (waited > 0) {
            // Drain remaining buffered stdout
            drainStdoutToWs(args.stdout_fd, &stdout_buf, args.conn, args.allocator, args.cmd_id) catch {};

            const exit_code: i32 = if (std.c.W.IFEXITED(@bitCast(exit_status)))
                @as(i32, std.c.W.EXITSTATUS(@bitCast(exit_status)))
            else if (std.c.W.IFSIGNALED(@bitCast(exit_status)))
                128 + @as(i32, @intCast(@intFromEnum(std.c.W.TERMSIG(@bitCast(exit_status)))))
            else
                @as(i32, -1);

            const frame = wsproto_mod.buildExecExit(args.allocator, args.cmd_id, exit_code) catch break;
            defer args.allocator.free(frame);
            args.conn.writeFrame(frame, .binary) catch |err| {
                std.log.err("[guest-ws] exec_exit write: {}", .{err});
            };
            std.log.debug("[guest-ws] Exec done: cmd_id={s} exit={d}", .{ args.cmd_id, exit_code });
            args.exec_done.* = true;
            break;
        }

        // Child stdout → exec_stdout frame to Host
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            drainStdoutToWs(args.stdout_fd, &stdout_buf, args.conn, args.allocator, args.cmd_id) catch |err| {
                std.log.err("[guest-ws] exec stdout read: {}", .{err});
                break;
            };
        }
    }
}

/// Thread args for Windows exec stdout reader.
/// Uses WaitForSingleObject + ReadFile (no POSIX poll/waitpid).
const WindowsExecThreadArgs = struct {
    process_handle: std.os.windows.HANDLE,
    stdout_handle: std.os.windows.HANDLE,
    conn: *wsclient.WsConn,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
    threaded: std.Io.Threaded, // owned by thread, deinited on exit
    exec_done: *bool,
};

/// Thread: blocking ReadFile from child stdout pipe, send exec_stdout frames.
/// When pipe closes (child exited): WaitForSingleObject + GetExitCodeProcess,
/// send exec_exit frame. Cleanup: close handles, deinit Threaded.
fn windowsExecThread(args: *WindowsExecThreadArgs) void {
    defer {
        args.allocator.free(args.cmd_id);
        args.threaded.deinit();
        args.allocator.destroy(args);
    }

    const win = std.os.windows;
    const ReadFile = @extern(
        *const fn (win.HANDLE, [*]u8, win.DWORD, *win.DWORD, ?*anyopaque) callconv(.winapi) win.BOOL,
        .{ .name = "ReadFile", .library_name = "kernel32" },
    );
    const WaitForSingleObject = @extern(
        *const fn (win.HANDLE, win.DWORD) callconv(.winapi) win.DWORD,
        .{ .name = "WaitForSingleObject", .library_name = "kernel32" },
    );
    const GetExitCodeProcess = @extern(
        *const fn (win.HANDLE, *win.DWORD) callconv(.winapi) win.BOOL,
        .{ .name = "GetExitCodeProcess", .library_name = "kernel32" },
    );
    var buf: [4096]u8 = undefined;

    while (true) {
        var bytes_read: win.DWORD = 0;
        // Blocking read from child stdout pipe.
        // Returns 0 when pipe is closed (child exited) or on error.
        const result = ReadFile(args.stdout_handle, &buf, buf.len, &bytes_read, null);
        if (@intFromEnum(result) == 0) break;
        if (bytes_read > 0) {
            const frame = wsproto_mod.buildExecStdout(args.allocator, args.cmd_id, buf[0..@intCast(bytes_read)]) catch break;
            defer args.allocator.free(frame);
            args.conn.writeFrame(frame, .binary) catch break;
        }
    }

    // Wait for process to fully exit and retrieve exit code
    _ = WaitForSingleObject(args.process_handle, std.math.maxInt(u32));
    var exit_code: win.DWORD = 0;
    _ = GetExitCodeProcess(args.process_handle, &exit_code);
    win.CloseHandle(args.process_handle);
    win.CloseHandle(args.stdout_handle);

    const frame = wsproto_mod.buildExecExit(args.allocator, args.cmd_id, @as(i32, @bitCast(exit_code))) catch return;
    defer args.allocator.free(frame);
    args.conn.writeFrame(frame, .binary) catch |err| {
        std.log.err("[guest-ws] exec_exit write (win): {}", .{err});
    };
    std.log.debug("[guest-ws] Exec done (win): cmd_id={s} exit={d}", .{ args.cmd_id, exit_code });
    args.exec_done.* = true;
    // On Windows, main loop has no poll timeout — it blocks on readFrame.
    // Send a ping so the Host responds with a pong, waking readFrame.
    // std.http.WebSocket.readSmallMessage auto-handles ping→pong per RFC 6455.
    args.conn.writeFrame(&.{}, .ping) catch {};
}

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

    // Outer reconnect loop: connect, announce, process messages.
    // Any connection failure causes reconnect from scratch.
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

        std.log.info("[guest-ws] Connected and announced", .{});

    // Pre-build announce message — static data, reused every second
    const announce_msg = try wsproto_mod.buildAnnounce(
        allocator, info.hostname, info.ip, info.target, info.mac, protocol.VERSION, info.shell,
    );
    defer allocator.free(announce_msg);

    var rbuf: [65536]u8 = undefined;

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

    // Active exec state: when threaded exec is running, main loop needs
    // access to child stdin pipe and pid for signal/stdin delivery.
    var active_stdin: ?std.Io.File = null;
    var active_pid: ?std.posix.pid_t = null;
    // Set by exec thread after exec_exit sent; main loop detects and reconnects.
    var exec_done: bool = false;
    defer {
        // Clean up child if connection lost during exec
        if (active_pid) |pid| {
            killChildProcess(pid);
        }
    }

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
                // Check exec_done before continuing — thread may have set it during poll
                if (exec_done) {
                    std.log.info("[guest-ws] Exec completed (detected on poll timeout), flushing and reconnecting...", .{});
                    std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
                    break;
                }
                continue;
            }
            std.log.info("[guest-ws] poll returned {d}", .{poll_n});
        }

        const frame = conn.readFrame(&rbuf) catch |err| {
            std.log.err("[guest-ws] Read error: {}", .{err});
            break;
        };

        if (frame.opcode == .binary and frame.data.len > 0) {
            std.log.info("[guest-ws] Frame type={d} len={d}", .{ frame.data[0], frame.data.len });
        }

        switch (frame.opcode) {
            .binary => {
                if (frame.data.len == 0) continue;
                const msg_type: u8 = frame.data[0];
                const payload = frame.data[1..];

                switch (msg_type) {
                    @intFromEnum(wsproto_mod.MsgType.exec_start) => {
                        if (wsproto_mod.parseExecStart(payload)) |req| {
                            std.log.debug("[guest-ws] Exec stream: cmd_id={s} cmd={s}", .{ req.cmd_id, req.command });
                            spawnExecStream(&conn, io, allocator, req.cmd_id, req.command, &active_stdin, &active_pid, &exec_done) catch |err| {
                                std.log.err("[guest-ws] Exec stream spawn failed: {}", .{err});
                                // Send error exit so Host doesn't wait forever
                                const err_frame = wsproto_mod.buildExecExit(allocator, req.cmd_id, -1) catch continue;
                                defer allocator.free(err_frame);
                                conn.writeFrame(err_frame, .binary) catch {};
                            };
                        }
                    },
                    @intFromEnum(wsproto_mod.MsgType.exec_stdin) => {
                        if (wsproto_mod.parseExecStdin(payload)) |stdin_req| {
                            if (active_stdin) |stdin_pipe| {
                                var wb: [4096]u8 = undefined;
                                var writer = stdin_pipe.writer(io, &wb);
                                _ = writer.interface.write(stdin_req.data) catch {};
                                writer.interface.flush() catch {};
                            }
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

        // exec completed: flush TCP (200ms) so Host receives exec_exit,
        // then disconnect and reconnect for fresh shell session
        if (exec_done) {
            std.log.info("[guest-ws] Exec completed, flushing and reconnecting...", .{});
            std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};
            break;
        }

        }

        std.log.info("[guest-ws] Disconnected, reconnecting in 3s...", .{});
        conn.close();
        std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Spawn child process and launch stdout thread. Main loop continues
/// to send re-announce messages (unblocking Host's readSmallMessage) and
/// handles exec_stdin/exec_signal delivery via active_stdin/active_pid.
/// POSIX: poll(WS+stdout) single-threaded loop.
/// Windows: WaitForSingleObject + ReadFile in dedicated thread.
fn spawnExecStream(
    conn: *wsclient.WsConn,
    io: std.Io,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
    command: []const u8,
    active_stdin: *?std.Io.File,
    active_pid: *?std.posix.pid_t,
    exec_done: *bool,
) !void {
    const shell = detectShell(allocator) catch "/bin/sh";
    defer allocator.free(shell);

    const merged_cmd = try std.fmt.allocPrint(allocator, "{s} 2>&1", .{command});
    defer allocator.free(merged_cmd);

    if (builtin.os.tag == .windows) {
        return spawnExecStreamWindows(conn, allocator, cmd_id, merged_cmd, active_stdin, active_pid, exec_done);
    }

    // ── POSIX path ──
    const shell_args: []const []const u8 = &.{ shell, "-l", "-c", merged_cmd };

    const child = try std.process.spawn(io, .{
        .argv = shell_args,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0, // new process group → kill(-pid, sig) works
    });

    // Store handles for main loop (stdin writes, signal delivery)
    active_stdin.* = child.stdin.?;
    active_pid.* = child.id.?;

    // Build thread args (thread owns cmd_id copy)
    const thread_args = try allocator.create(ExecStdoutThreadArgs);
    thread_args.* = .{
        .stdout_fd = child.stdout.?.handle,
        .child_pid = child.id.?,
        .conn = conn,
        .io = io,
        .allocator = allocator,
        .cmd_id = try allocator.dupe(u8, cmd_id),
        .exec_done = exec_done,
    };

    const t = try std.Thread.spawn(.{}, execStdoutThread, .{thread_args});
    t.detach();

    std.log.debug("[guest-ws] Exec thread spawned: cmd_id={s}", .{cmd_id});
}

/// Windows: spawn child with Threaded I/O, launch windowsExecThread.
/// Stderr merged into stdout via cmd.exe 2>&1 (already in merged_cmd).
fn spawnExecStreamWindows(
    conn: *wsclient.WsConn,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
    merged_cmd: []const u8,
    active_stdin: *?std.Io.File,
    active_pid: *?std.posix.pid_t,
    exec_done: *bool,
) !void {
    // Use dedicated Threaded I/O for process operations in service context.
    // global_single_threaded uses Allocator.failing → OutOfMemory in processSpawnWindows.
    var threaded = std.Io.Threaded.init(allocator, .{});
    const block_io = threaded.io();

    const child = try std.process.spawn(block_io, .{
        .argv = &.{ "cmd.exe", "/c", merged_cmd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Store handles for main loop (stdin writes, signal delivery).
    // On Windows, pid_t is HANDLE — child.id is the process handle.
    const process_handle = child.id orelse return error.NoProcessHandle;
    active_stdin.* = child.stdin.?;
    active_pid.* = process_handle;

    const stdout_handle = child.stdout.?.handle;

    const thread_args = try allocator.create(WindowsExecThreadArgs);
    thread_args.* = .{
        .process_handle = process_handle,
        .stdout_handle = stdout_handle,
        .conn = conn,
        .allocator = allocator,
        .cmd_id = try allocator.dupe(u8, cmd_id),
        .threaded = threaded, // transferred to thread, deinited on exit
        .exec_done = exec_done,
    };

    const t = try std.Thread.spawn(.{}, windowsExecThread, .{thread_args});
    t.detach();

    std.log.debug("[guest-ws] Exec thread spawned (win): cmd_id={s}", .{cmd_id});
}

/// Read from child stdout fd and send as exec_stdout frame. Returns bytes read.
fn drainStdoutToWs(
    fd: std.posix.fd_t,
    buf: []u8,
    conn: *wsclient.WsConn,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
) !void {
    const n = try std.posix.read(fd, buf);
    if (n == 0) return; // EOF
    const frame = try wsproto_mod.buildExecStdout(allocator, cmd_id, buf[0..n]);
    defer allocator.free(frame);
    try conn.writeFrame(frame, .binary);
}

/// Deprecated: replaced by spawnExecStream + execStdoutThread.
/// Kept for reference; will be removed in cleanup.
fn handleExecStream(
    conn: *wsclient.WsConn,
    io: std.Io,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
    command: []const u8,
) !void {
    const shell = detectShell(allocator) catch "/bin/sh";
    defer allocator.free(shell);

    // Merge stderr into stdout via shell redirect — ensures correct output ordering
    const merged_cmd = try std.fmt.allocPrint(allocator, "{s} 2>&1", .{command});
    defer allocator.free(merged_cmd);

    const shell_args: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", merged_cmd }
    else
        &.{ shell, "-l", "-c", merged_cmd };

    var child = try std.process.spawn(io, .{
        .argv = shell_args,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var child_alive = true;
    defer if (child_alive) child.kill(io); // clean up if we exit early (poll error, WS read error, etc.)

    const stdin_pipe = child.stdin.?;
    const stdout_pipe = child.stdout.?;

    var stdout_buf: [4096]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    const ws_fd = conn.stream.socket.handle;
    const stdout_fd = stdout_pipe.handle;

    while (true) {
        if (builtin.os.tag == .windows) {
            @compileError("TODO: streaming exec on Windows — use reader thread for child pipes");
        }
        var fds: [2]std.posix.pollfd = .{
            .{ .fd = ws_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const poll_n = std.posix.poll(&fds, 1000) catch |err| {
            std.log.err("[guest-ws] exec poll: {}", .{err});
            break;
        };
        // Heartbeat on timeout: send empty exec_stdout to unblock Host's
        // readSmallMessage so it can drain signals. Must be a .binary frame
        // that Host processes — pong is silently consumed inside
        // readSmallMessage, and ping is returned but skipped by dispatch.
        if (poll_n == 0) {
            const hb_frame = wsproto_mod.buildExecStdout(allocator, cmd_id, &.{}) catch |err| {
                std.log.err("[guest-ws] heartbeat build failed: {}", .{err});
                continue;
            };
            defer allocator.free(hb_frame);
            conn.writeFrame(hb_frame, .binary) catch |err| {
                std.log.err("[guest-ws] heartbeat write failed: {}", .{err});
            };
            continue;
        }

        // Non-blocking check: child exited?
        var exit_status: i32 = 0;
        const waited = std.c.waitpid(child.id.?, &exit_status, std.c.W.NOHANG);
        if (waited < 0) {
            std.log.err("[guest-ws] exec waitpid error", .{});
            break;
        }
        if (waited > 0) {
            child_alive = false; // child already reaped, don't kill in defer
            // Drain remaining buffered stdout before sending exit
            drainStdout(stdout_fd, &stdout_buf, conn, allocator, cmd_id) catch {};
            const exit_code: i32 = if (std.c.W.IFEXITED(@bitCast(exit_status)))
                @as(i32, std.c.W.EXITSTATUS(@bitCast(exit_status)))
            else if (std.c.W.IFSIGNALED(@bitCast(exit_status)))
                128 + @as(i32, @intCast(@intFromEnum(std.c.W.TERMSIG(@bitCast(exit_status)))))
            else
                @as(i32, -1);
            const frame = try wsproto_mod.buildExecExit(allocator, cmd_id, exit_code);
            defer allocator.free(frame);
            conn.writeFrame(frame, .binary) catch |err| {
                std.log.err("[guest-ws] exec_exit write: {}", .{err});
                return err;
            };
            std.log.debug("[guest-ws] Exec done: cmd_id={s} exit={d}", .{ cmd_id, exit_code });
            break;
        }

        // WebSocket: exec_stdin or exec_signal from Host
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const frame = conn.readFrame(&rbuf) catch |err| {
                std.log.err("[guest-ws] exec ws read: {}", .{err});
                break;
            };
            switch (frame.opcode) {
                .binary => {
                    if (frame.data.len == 0) continue;
                    switch (frame.data[0]) {
                        @intFromEnum(wsproto_mod.MsgType.exec_stdin) => {
                            if (wsproto_mod.parseExecStdin(frame.data[1..])) |stdin_req| {
                                var wb: [4096]u8 = undefined;
                                var writer = stdin_pipe.writer(io, &wb);
                                _ = writer.interface.write(stdin_req.data) catch {};
                                writer.interface.flush() catch {};
                            }
                        },
                        @intFromEnum(wsproto_mod.MsgType.exec_signal) => {
                            if (wsproto_mod.parseExecSignal(frame.data[1..])) |sig| {
                                sendSignal(io, &child, sig.signal);
                            }
                        },
                        else => {},
                    }
                },
                .ping => conn.writeFrame(frame.data, .pong) catch {},
                .pong => {},
                .close => {
                    std.log.info("[guest-ws] Host requested close during exec", .{});
                    break;
                },
                else => {},
            }
        }

        // Child stdout → exec_stdout frame to Host
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            drainStdout(stdout_fd, &stdout_buf, conn, allocator, cmd_id) catch |err| {
                std.log.err("[guest-ws] exec stdout read: {}", .{err});
                break;
            };
        }
    }
}

/// Read from child stdout fd and send as exec_stdout frame. Returns bytes read.
fn drainStdout(
    fd: std.posix.fd_t,
    buf: []u8,
    conn: *wsclient.WsConn,
    allocator: std.mem.Allocator,
    cmd_id: []const u8,
) !void {
    const n = try std.posix.read(fd, buf);
    if (n == 0) return; // EOF
    const frame = try wsproto_mod.buildExecStdout(allocator, cmd_id, buf[0..n]);
    defer allocator.free(frame);
    try conn.writeFrame(frame, .binary);
}

/// Forward signal to child process.
fn sendSignal(io: std.Io, child: *std.process.Child, signal: u8) void {
    switch (signal) {
        0 => { // SIGINT
            if (builtin.os.tag != .windows) {
                std.posix.kill(child.id.?, std.posix.SIG.INT) catch {};
            } else {
                child.kill(io);
            }
        },
        1 => { // SIGTERM
            child.kill(io);
        },
        else => {
            std.log.debug("[guest-ws] Unknown signal: {d}", .{signal});
        },
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
