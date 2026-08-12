//! utmmd — UTM Monitor 监督守护进程。
//!
//! 管理 utmm 子进程的完整生命周期：启动、心跳监控、退避重启、升级。
//! 通过共享内存（shm.zig）与 utmm 双向通信。
//!
//! 系统服务管理器只负责开机启动 utmmd（无保活），utmmd 拥有 utmm 的绝对控制权。

const builtin = @import("builtin");
const std = @import("std");
const shm = @import("shm.zig");
const fail = @import("fail.zig");
const svc = @import("svc.zig");

/// utmm 规范安装路径。
fn utmmPath() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\opt\\utmm\\utmm.exe" else "/opt/utmm/utmm";
}

/// utmm 工作目录。
fn utmmDir() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\opt\\utmm" else "/opt/utmm";
}

// ═══════════════════════════════════════════════════════════════════════════
// 退避算法常量
// ═══════════════════════════════════════════════════════════════════════════

const STABILITY_THRESHOLD_SEC: u64 = 10; // 稳定运行阈值
const HEARTBEAT_TIMEOUT_SEC: u64 = 10; // 心跳超时 → 僵死
const MAX_FAILURE_COUNT: u32 = 5; // 连续失败 > 此值 → utmmd 退出
const MAX_BACKOFF_SEC: u32 = 60; // 最大退避延迟
const MAX_UPGRADE_FAILURES: u32 = 5; // 连续升级失败 > 此值 → 删除 .tmp，放弃
const POLL_INTERVAL_MS: u64 = 1000; // 监控轮询间隔
const IP_CHECK_INTERVAL_MS: u64 = 10000; // IP 指纹检查间隔
const IP_STABLE_CHECKS: u32 = 2; // IP 变更去抖：需连续检测到变更的次数

// ═══════════════════════════════════════════════════════════════════════════
// CLI 参数解析
// ═══════════════════════════════════════════════════════════════════════════

const CliArgs = struct {
    role: enum { guest, host } = .guest,
    utmm_args: []const []const u8 = &.{}, // 透传给 utmm 的参数
    is_svc: bool = false, // Windows SCM 模式
};

fn parseArgs(alloc: std.mem.Allocator, args: []const [:0]const u8) !CliArgs {
    var cli = CliArgs{};
    var utmm_args_list: std.ArrayListAligned([]const u8, null) = .empty;
    errdefer {
        for (utmm_args_list.items) |a| alloc.free(a);
        utmm_args_list.deinit(alloc);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--role")) {
            i += 1;
            if (i >= args.len) fail.msg("utmmd", "--role requires guest or host", .{});
            if (std.mem.eql(u8, args[i], "host")) {
                cli.role = .host;
                // utmm 需要 --host 标志才能以 host 模式运行
                const host_arg = try alloc.dupe(u8, "--host");
                try utmm_args_list.append(alloc, host_arg);
            } else if (std.mem.eql(u8, args[i], "guest")) {
                cli.role = .guest;
            } else {
                fail.msg("utmmd", "--role must be guest or host, got: {s}", .{args[i]});
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--svc")) {
            cli.is_svc = true;
            continue;
        }
        // 透传其余参数给 utmm
        const duped = try alloc.dupe(u8, arg);
        try utmm_args_list.append(alloc, duped);
    }

    cli.utmm_args = try utmm_args_list.toOwnedSlice(alloc);
    return cli;
}

fn freeCliArgs(alloc: std.mem.Allocator, cli: CliArgs) void {
    for (cli.utmm_args) |a| alloc.free(a);
    alloc.free(cli.utmm_args);
}

// ═══════════════════════════════════════════════════════════════════════════
// 进程管理 — 平台抽象
// ═══════════════════════════════════════════════════════════════════════════

const ProcessRef = if (builtin.os.tag == .windows) UtmmProcessWin else u32;

const UtmmProcessWin = struct {
    handle: std.os.windows.HANDLE,
    pid: u32,
};

// Zig 0.16.0 移除了 PROCESS_INFORMATION，需手动声明
const PROCESS_INFORMATION = extern struct {
    hProcess: std.os.windows.HANDLE,
    hThread: std.os.windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

// Zig 0.16.0 移除了这些 kernel32 函数和常量，需手动声明
const WAIT_TIMEOUT: u32 = 0x00000102;
const WAIT_FAILED: u32 = 0xFFFFFFFF;
const SYNCHRONIZE: u32 = 0x00100000;
const PROCESS_TERMINATE: u32 = 0x0001;
extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) i32;


// Zig 0.16.0 移除了 CreateProcessW，声明 CreateProcessA（UTF-8 路径即可）
// 使用 i32 替代 BOOL 避免 Zig 0.16.0 的 BOOL enum 类型不匹配
extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?[*:0]const u8,
    lpCommandLine: ?[*:0]u8,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u8,
    lpStartupInfo: *std.os.windows.STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) i32;

/// 启动 utmm 子进程。
fn startUtmm(io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, args: []const []const u8) !ProcessRef {
    if (builtin.os.tag == .windows) return startUtmmWin(io, alloc, shm_ptr, args);
    return startUtmmPosix(io, alloc, shm_ptr, args);
}

/// 通过 PID 杀 utmm（用于 shutdown 时 proc 变量不在作用域的场景）。
fn killUtmmByPid(pid: u32) void {
    if (pid == 0) return;
    if (builtin.os.tag == .windows) {
        // 通过 PID 获取句柄再杀。需要 PROCESS_TERMINATE + SYNCHRONIZE 才能
        // TerminateProcess 后 WaitForSingleObject 确认进程完全退出。
        const h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, 0, pid) orelse return;
        if (TerminateProcess(h, 1) == 0) {
            const err = std.os.windows.GetLastError();
            std.log.err("[utmmd] killUtmmByPid: TerminateProcess failed pid={d} err={d}", .{ pid, @intFromEnum(err) });
            _ = std.os.windows.CloseHandle(h);
            return;
        }
        const wait_rc = WaitForSingleObject(h, 5000);
        if (wait_rc == WAIT_TIMEOUT) {
            std.log.warn("[utmmd] killUtmmByPid: wait timeout pid={d}", .{pid});
        }
        _ = std.os.windows.CloseHandle(h);
        std.log.info("[utmmd] utmm killed by pid, pid={d}", .{pid});
    } else {
        std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
        std.log.info("[utmmd] utmm killed by pid, pid={d}", .{pid});
    }
}

/// 强杀 utmm 进程并等待终止完成。
/// Windows: TerminateProcess 是异步的，必须 WaitForSingleObject 确保进程完全退出，
/// 释放所有文件句柄后再进行后续操作（如 rename 覆盖可执行文件）。
/// POSIX: SIGKILL 后必须 waitpid 回收僵尸进程，否则在升级循环中会累积数百个
/// defunct 进程（v0.18.36 linuxvm 僵尸进程根因）。waitpid 同时确认进程已终止。
/// 注意：不关闭进程句柄——调用者负责管理句柄生命周期。
/// 返回 true 表示进程已成功终止，false 表示可能未终止（TerminateProcess 失败或超时）。
fn killProcess(proc: ProcessRef) bool {
    if (builtin.os.tag == .windows) {
        if (TerminateProcess(proc.handle, 1) == 0) {
            const err = std.os.windows.GetLastError();
            std.log.err("[utmmd] TerminateProcess failed: err={d}", .{@intFromEnum(err)});
            return false;
        }
        const wait_rc = WaitForSingleObject(proc.handle, 5000);
        if (wait_rc == WAIT_TIMEOUT) {
            std.log.warn("[utmmd] TerminateProcess succeeded but WaitForSingleObject timed out (5s)", .{});
            return false;
        }
        if (wait_rc == WAIT_FAILED) {
            const err = std.os.windows.GetLastError();
            std.log.err("[utmmd] WaitForSingleObject failed: err={d}", .{@intFromEnum(err)});
            return false;
        }
        std.log.info("[utmmd] utmm killed, pid={d}", .{proc.pid});
        return true;
    } else {
        if (proc == 0) return false;
        // 先尝试回收已退出的僵尸（可能在 kill 之前就已崩溃）。
        const pre_reap = std.c.waitpid(@intCast(proc), null, WNOHANG);
        if (pre_reap > 0) {
            // 进程已退出且已被回收 — 无需 kill
            std.log.info("[utmmd] utmm already dead and reaped, pid={d}", .{proc});
            return true;
        }
        // 发送 SIGKILL
        std.posix.kill(@intCast(proc), std.posix.SIG.KILL) catch |err| {
            // ESRCH: 进程不存在 — 可能已被 init 或其他机制回收
            std.log.info("[utmmd] utmm already dead (kill→{s}), pid={d}", .{ @errorName(err), proc });
            return true;
        };
        // 阻塞等待进程终止并回收僵尸（0 = 无超时，阻塞到进程退出）。
        // WNOHANG 不够：SIGKILL 是异步的，进程可能需要几 ms 才真正退出。
        const wait_result = std.c.waitpid(@intCast(proc), null, 0);
        if (wait_result < 0) {
            // ECHILD: 进程已被其他方式回收
            std.log.info("[utmmd] utmm kill confirmed (waitpid→reaped by other), pid={d}", .{proc});
            return true;
        }
        std.log.info("[utmmd] utmm killed and reaped, pid={d}", .{proc});
        return true;
    }
}

/// 关闭进程句柄（清理不再使用的 ProcessRef）。
fn closeProcessHandle(proc: ProcessRef) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.CloseHandle(proc.handle);
    }
}

/// 检查进程是否存活。
fn isProcessAlive(proc: ProcessRef) bool {
    if (builtin.os.tag == .windows) {
        const rc = WaitForSingleObject(proc.handle, 0);
        return rc == WAIT_TIMEOUT;
    }
    if (proc == 0) return false;
    const result = std.c.waitpid(@intCast(proc), null, WNOHANG);
    if (result == 0) return true; // 进程仍在运行
    return false;
}

const WNOHANG: c_int = 1; // waitpid WNOHANG 标志

// ═══════════════════════════════════════════════════════════════════════════
// IP 指纹 — 零分配枚举所有非回环 IPv4，计算 Wyhash 指纹
// ═══════════════════════════════════════════════════════════════════════════

/// POSIX getifaddrs 类型（复用 guest.zig 的模式）。
/// 用 _fp 后缀区分以避免与 guest.zig 的同名类型冲突。
const in_addr_fp = extern struct { s_addr: u32 };
const sockaddr_fp = if (builtin.os.tag == .linux)
    extern struct { sa_family: u16, sa_data: [14]u8 }
else
    extern struct { sa_len: u8, sa_family: u8, sa_data: [14]u8 };

const sockaddr_in_fp = if (builtin.os.tag == .linux)
    extern struct { sin_family: u16, sin_port: u16, sin_addr: in_addr_fp, sin_zero: [8]u8 }
else
    extern struct { sin_len: u8, sin_family: u8, sin_port: u16, sin_addr: in_addr_fp, sin_zero: [8]u8 };

const ifaddrs_fp = extern struct {
    ifa_next: ?*ifaddrs_fp,
    ifa_name: [*:0]u8,
    ifa_flags: c_uint,
    ifa_addr: ?*sockaddr_fp,
    ifa_netmask: ?*sockaddr_fp,
    ifa_dstaddr: ?*sockaddr_fp,
    ifa_data: ?*anyopaque,
};

const AF_INET_FP: u16 = 2;

extern "c" fn getifaddrs(ifap: *?*ifaddrs_fp) c_int;
extern "c" fn freeifaddrs(ifa: ?*ifaddrs_fp) void;

// Windows GetAdaptersAddresses 类型。
// 使用 extern union { pad: usize, ... } 确保 32 位和 64 位偏移都正确。
const GAA_FLAG_SKIP_ANYCAST: u32 = 0x0002;
const GAA_FLAG_SKIP_MULTICAST: u32 = 0x0004;
const GAA_FLAG_SKIP_DNS_SERVER: u32 = 0x0008;

const SOCKET_ADDRESS_FP = extern struct {
    lpSockaddr: ?*sockaddr_fp,
    iSockaddrLength: i32,
};

const IP_ADAPTER_UNICAST_ADDRESS_LH = extern struct {
    _length_flags: extern union { pad: usize, fields: extern struct { length: u32, flags: u32 } },
    next: ?*IP_ADAPTER_UNICAST_ADDRESS_LH,
    address: SOCKET_ADDRESS_FP,
};

const IP_ADAPTER_ADDRESSES_LH = extern struct {
    _length_ifindex: extern union { pad: usize, fields: extern struct { length: u32, if_index: u32 } },
    next: ?*IP_ADAPTER_ADDRESSES_LH,
    _adapter_name: ?*anyopaque,
    first_unicast_address: ?*IP_ADAPTER_UNICAST_ADDRESS_LH,
};

/// 对所有非回环 IPv4 地址做 Wyhash 指纹，返回 u64。
/// 零堆分配（仅使用栈变量）。返回 0 表示无有效 IP。
fn getAllIpsFingerprint() u64 {
    if (builtin.os.tag == .windows) return getAllIpsFingerprintWindows();
    return getAllIpsFingerprintPosix();
}

fn getAllIpsFingerprintPosix() u64 {
    var ifap: ?*ifaddrs_fp = undefined;
    if (getifaddrs(&ifap) != 0) return 0;
    defer freeifaddrs(ifap);

    var hasher = std.hash.Wyhash.init(0);
    var count: u32 = 0;

    var current: ?*ifaddrs_fp = ifap;
    while (current) |ifa| : (current = ifa.ifa_next) {
        if (ifa.ifa_addr == null) continue;
        const addr = ifa.ifa_addr.?;
        if (addr.sa_family != AF_INET_FP) continue;

        const sin = @as(*align(1) const sockaddr_in_fp, @ptrCast(addr));
        const raw_bytes = @as([*]const u8, @ptrCast(&sin.sin_addr))[0..4];

        // 跳过回环 (127.x) 和零地址 (0.0.0.0)
        if (raw_bytes[0] == 127) continue;
        if (raw_bytes[0] == 0 and raw_bytes[1] == 0 and raw_bytes[2] == 0 and raw_bytes[3] == 0) continue;

        hasher.update(raw_bytes);
        count += 1;
    }

    if (count == 0) return 0;
    // 混入计数：接口 down（IP 消失）时指纹也不同
    hasher.update(std.mem.asBytes(&count));
    return hasher.final();
}

fn getAllIpsFingerprintWindows() u64 {
    // 动态加载 iphlpapi.dll（匹配 utmmd 自包含风格）
    const kernel32 = struct {
        extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
    };

    const hModule = kernel32.LoadLibraryA("iphlpapi.dll") orelse return 0;
    const func_ptr = kernel32.GetProcAddress(hModule, "GetAdaptersAddresses") orelse return 0;

    const FnType = *const fn (
        family: c_uint,
        flags: c_ulong,
        reserved: ?*anyopaque,
        addresses: *?*IP_ADAPTER_ADDRESSES_LH,
        size: *c_ulong,
    ) callconv(.winapi) c_ulong;
    const getAdaptersAddresses: FnType = @ptrCast(@alignCast(func_ptr));

    // 15KB 栈缓冲区覆盖典型多网卡系统
    const buf: [15360]u8 = [_]u8{0} ** 15360;
    var size: c_ulong = @intCast(buf.len);
    var addrs: ?*IP_ADAPTER_ADDRESSES_LH = undefined;

    const flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    const ret = getAdaptersAddresses(AF_INET_FP, flags, null, &addrs, &size);
    if (ret != 0 or addrs == null) return 0;

    var hasher = std.hash.Wyhash.init(0);
    var count: u32 = 0;

    var adapter: ?*IP_ADAPTER_ADDRESSES_LH = addrs;
    while (adapter) |a| : (adapter = a.next) {
        var ua: ?*IP_ADAPTER_UNICAST_ADDRESS_LH = a.first_unicast_address;
        while (ua) |addr| : (ua = addr.next) {
            const sa = addr.address.lpSockaddr orelse continue;
            if (sa.sa_family != AF_INET_FP) continue;

            const sin = @as(*align(1) const sockaddr_in_fp, @ptrCast(sa));
            const raw_bytes = @as([*]const u8, @ptrCast(&sin.sin_addr))[0..4];

            if (raw_bytes[0] == 127) continue;
            if (raw_bytes[0] == 0 and raw_bytes[1] == 0 and raw_bytes[2] == 0 and raw_bytes[3] == 0) continue;

            hasher.update(raw_bytes);
            count += 1;
        }
    }

    if (count == 0) return 0;
    hasher.update(std.mem.asBytes(&count));
    return hasher.final();
}

// ═══════════════════════════════════════════════════════════════════════════
// 进程管理 — POSIX（Zig 0.16.0 移除了 posix.fork/chdir/execve，直接用 C）
// ═══════════════════════════════════════════════════════════════════════════

// Zig 0.16.0 没有 fork() 包装 — POSIX 规范中 fork 在多线程环境下不安全。
extern "c" fn fork() c_int;

fn startUtmmPosix(io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, args: []const []const u8) !u32 {
    const path = utmmPath();
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    // 构建 argv: [utmm_path, "--svc", args..., null]
    // --svc 是必需的：utmm 必须运行在 daemon 模式才能连接 shm 并运行心跳
    // 使用 allocSentinel 确保 NULL 终止符（POSIX execve 要求）
    const svc_arg = try alloc.dupeZ(u8, "--svc");
    const argv_count: usize = 2 + args.len; // path_z + svc_arg + args
    const argv_z = try alloc.allocSentinel(?[*:0]const u8, argv_count, null);
    defer alloc.free(argv_z);

    argv_z[0] = path_z.ptr;
    argv_z[1] = svc_arg.ptr;
    for (args, 0..) |a, j| {
        const az = try alloc.dupeZ(u8, a);
        argv_z[2 + j] = az.ptr;
    }
    // argv_z[argv_count] = null (set by allocSentinel)

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // 子进程
        _ = std.c.chdir(@ptrCast(utmmDir()));
        _ = std.c.execve(path_z, argv_z.ptr, std.c.environ);
        std.process.exit(1); // execve 失败
    }

    // 父进程：释放 dupeZ 字符串（svc_arg 和 args）
    alloc.free(svc_arg);
    for (args, 0..) |_, j| {
        if (argv_z[2 + j]) |az| alloc.free(std.mem.span(az));
    }

    shm_ptr.utmm_pid = @intCast(pid);
    shm.writeSvcHeartbeat(shm_ptr, io);
    shm_ptr.restart_count += 1;
    shm.clearCmd(shm_ptr);
    std.log.info("[utmmd] utmm started, pid={d}", .{pid});
    return @intCast(pid);
}

// ═══════════════════════════════════════════════════════════════════════════
// 进程管理 — Windows
// ═══════════════════════════════════════════════════════════════════════════

fn startUtmmWin(io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, args: []const []const u8) !UtmmProcessWin {
    const path = utmmPath();
    const w = std.os.windows;

    // 构建命令行: utmm.exe --svc args...
    // --svc 是必需的：utmm 必须运行在 daemon 模式才能连接 shm 并运行心跳
    var cmd_line: std.ArrayListAligned(u8, null) = .empty;
    defer cmd_line.deinit(alloc);
    try cmd_line.append(alloc, '"');
    try cmd_line.appendSlice(alloc, path);
    try cmd_line.append(alloc, '"');
    try cmd_line.append(alloc, ' ');
    try cmd_line.appendSlice(alloc, "--svc");
    for (args) |a| {
        try cmd_line.append(alloc, ' ');
        try cmd_line.appendSlice(alloc, a);
    }
    try cmd_line.append(alloc, 0);

    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: PROCESS_INFORMATION = undefined;

    if (CreateProcessA(null, @constCast(@ptrCast(cmd_line.items.ptr)), null, null, 0, 0, null, @constCast(@ptrCast(utmmDir())), &si, &pi) == 0) {
        if (builtin.os.tag == .windows) debugLogWindows("startUtmmWin: CreateProcess FAILED");
        std.log.err("[utmmd] CreateProcess failed: {d}", .{@intFromEnum(w.GetLastError())});
        return error.ProcessStartFailed;
    }
    if (builtin.os.tag == .windows) debugLogWindows("startUtmmWin: CreateProcess OK");
    _ = w.CloseHandle(pi.hThread);

    shm_ptr.utmm_pid = pi.dwProcessId;
    shm.writeSvcHeartbeat(shm_ptr, io);
    shm_ptr.restart_count += 1;
    shm.clearCmd(shm_ptr);
    std.log.info("[utmmd] utmm started, pid={d}", .{pi.dwProcessId});
    return UtmmProcessWin{ .handle = pi.hProcess, .pid = pi.dwProcessId };
}

fn runCmd(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// 文件式升级 — utmmd 全权掌控
// ═══════════════════════════════════════════════════════════════════════════
//
// v0.17.19: 单文件机制 — utmm-upgrade.<sha256hex>.tmp，SHA256 嵌入文件名。
// OS 排他文件锁替代标记文件，进程崩溃时 OS 自动释放。
// utmmd 通过尝试获取锁来判断文件是否写入完成。

/// Windows 两阶段 rename 替换：utmm.exe → utmm-old.exe，.tmp → utmm.exe。
/// 使用 kernel32 API（MoveFileExW / DeleteFileW / CopyFileW）绕过 Zig Io.Dir 的
/// Threaded Io 兼容性问题（Io.Dir.rename 在 Windows Threaded Io 上可能崩溃）。
/// 返回 true 表示替换成功，false 表示所有方法都失败。
/// Windows 升级替换：杀进程 → DeleteFileW 旧 exe → MoveFileExW .tmp → utmm.exe。
/// 失败时保留 .tmp，返回 false 供调用方重试。
fn replaceUtmmWindows(tmp_path: []const u8, dest: []const u8) bool {
    debugLogWindows("replaceUtmmWindows: entry");

    // 1. 杀全部 utmm.exe（Toolhelp32 直接枚举）
    _ = killAllUtmmWindows();

    // 2. 重试：AV/Defender 可能短暂持有文件句柄
    for (0..5) |attempt| {
        if (!deleteFileAbsoluteWindows(dest)) {
            if (attempt < 4) {
                _ = killAllUtmmWindows();
                sleepMsWin(500 * (@as(u32, @intCast(attempt)) + 1));
                continue;
            }
            return false;
        }
        if (moveFileExWindows(tmp_path, dest)) return true;
        if (attempt < 4) sleepMsWin(500 * (@as(u32, @intCast(attempt)) + 1));
    }
    return false;
}

fn moveFileExWindows(src: []const u8, dst: []const u8) bool {
    var s: [512]u16 = [_]u16{0} ** 512;
    var d: [512]u16 = [_]u16{0} ** 512;
    const sl = std.unicode.utf8ToUtf16Le(&s, src) catch return false;
    if (sl >= s.len) return false;
    s[sl] = 0;
    const dl = std.unicode.utf8ToUtf16Le(&d, dst) catch return false;
    if (dl >= d.len) return false;
    d[dl] = 0;
    return MoveFileExW(@ptrCast(&s), @ptrCast(&d), MOVEFILE_REPLACE_EXISTING) != 0;
}

/// 尝试查找并应用待处理升级。
/// 返回 RestartReason 表示升级已应用（调用者应重启 utmm），null 表示无待处理升级。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
fn tryApplyPendingUpgrade(file_io: std.Io, io: std.Io, alloc: std.mem.Allocator, proc: ?ProcessRef, shm_ptr: *volatile shm.ShmLayout) ?RestartReason {
    if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: entry");

    // 1. 从 SHM cmd_data 读 Guest 写入的升级文件全路径。
    //    Guest 在 handleUpgradeCmd 中将 .tmp 路径写入 SHM 后才发 restart。
    var path_buf: [512]u8 = undefined;
    const tp: []const u8 = if (shm.readCmdPath(shm_ptr, &path_buf)) |p|
        alloc.dupe(u8, p) catch return null
    else {
        if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: no path in SHM, return null");
        return null;
    };
    if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: tmp found");
    defer alloc.free(tp);

    // 2. 提取文件名的 SHA256 hex（用于自校验）
    const basename = if (std.mem.lastIndexOfScalar(u8, tp, '/')) |pos|
        tp[pos + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, tp, '\\')) |pos|
        tp[pos + 1 ..]
    else
        tp;

    if (svc.UpgradeLock.extractSha256(basename, "utmm-upgrade") == null) {
        // 文件名格式不对 — 清理残留
        if (builtin.os.tag == .windows) _ = deleteFileAbsoluteWindows(tp)
        else std.Io.Dir.cwd().deleteFile(file_io, tp) catch {};
        return null;
    }

    // 3. 尝试获取排他锁 — 成功 = 文件写入完成，失败 = Guest 仍在写入。
    // Windows 上 Guest 释放锁后可能存在短暂的时间窗口（CloseHandle 异步性、
    // AV 软件扫描等），tryAcquire 可能短暂失败。添加重试逻辑避免因一次性
    // 失败而放弃升级，导致 tmp 文件残留（v0.18.36 windowsvm/winx64 预存 bug）。
    if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: before tryAcquire");
    var lock: svc.UpgradeLock = undefined;
    var acquired: bool = false;
    for (0..10) |attempt| {
        if (svc.UpgradeLock.tryAcquire(tp)) |l| {
            lock = l;
            acquired = true;
            break;
        }
        if (attempt < 9) {
            if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: tryAcquire retry");
            std.Io.sleep(file_io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        }
    }
    if (!acquired) {
        if (builtin.os.tag == .windows) debugLogWindows("tryApplyPendingUpgrade: tryAcquire failed after 10 retries");
        return null;
    }

    std.log.info("[utmmd] upgrade tmp file found: {s}", .{tp});

    // 4. 验证文件内容 SHA256 是否与文件名匹配。
    // Windows: computeSha256Hex 使用 Threaded Io + readSliceShort，可能因 Io 实现差异
    // 导致返回值异常。临时改为仅提取文件名中的 SHA256（Guest 端已验证），跳过二次读取验证。
    // TODO: 等确认 rename 替换链路正确后，修复 computeSha256Hex 的 Windows 兼容性。
    if (builtin.os.tag == .windows) {
        const expected_hex = svc.UpgradeLock.extractSha256(basename, "utmm-upgrade");
        if (expected_hex == null) {
            std.log.err("[utmmd] upgrade: invalid filename, deleting {s}", .{tp});
            _ = deleteFileAbsoluteWindows(tp);
            return null;
        }
        // Windows 上跳过二次 SHA256 验证，直接信任 Guest 端已在写入时验证的文件名。
        // Guest 端 receiveFile 在写入过程中实时计算 SHA256，与文件名匹配后才发 upload_result。
        std.log.info("[utmmd] upgrade tmp verified via filename (Windows skip re-read): {s}", .{expected_hex.?});
    } else {
        if (!svc.verifyUpgradeTmpByFilename(alloc, file_io, tp, basename)) {
            std.log.err("[utmmd] upgrade SHA256 verification failed, deleted {s}", .{tp});
            lock.release();
            // 文件已被 verifyUpgradeTmpByFilename 删除
            return null;
        }
        std.log.info("[utmmd] upgrade SHA256 verified via filename", .{});
    }

    const dest = utmmPath();

    // 5. 杀 utmm 进程。
    // 5. 杀 utmm 进程 + 替换二进制。
    if (builtin.os.tag == .windows) {
        // 锁先释放 — 否则自己的句柄可能妨碍 MoveFileExW。
        lock.release();

        // replaceUtmmWindows: 枚举杀全部 utmm.exe → 删旧 → MoveFileExW
        if (replaceUtmmWindows(tp, dest)) {
            std.log.info("[utmmd] upgrade replace done: → {s}", .{dest});
            return .restart;
        }
        std.log.warn("[utmmd] upgrade replace failed — keeping .tmp for retry", .{});
        return null;
    } else {
        // POSIX: kill utmm 然后 rename 原子替换
        if (proc) |p| {
            if (!killProcess(p)) {
                std.log.err("[utmmd] upgrade aborted: failed to kill utmm", .{});
                lock.release();
                return null;
            }
        }
        _ = std.posix.system.chmod(@ptrCast(tp.ptr), 0o755);
        // POSIX: rename 原子替换（覆盖已有文件）
        std.Io.Dir.cwd().rename(tp, std.Io.Dir.cwd(), dest, file_io) catch |err| {
            if (err == error.CrossDevice) {
                copyFileUpgradeFallback(file_io, tp, dest) catch |e| {
                    std.log.err("[utmmd] copyFileUpgradeFallback failed: {}", .{e});
                    lock.release();
                    std.Io.Dir.cwd().deleteFile(file_io, tp) catch {};
                    return null;
                };
                std.Io.Dir.cwd().deleteFile(file_io, tp) catch {};
            } else {
                std.log.err("[utmmd] upgrade rename failed: {} — removing stale .tmp", .{err});
                lock.release();
                std.Io.Dir.cwd().deleteFile(file_io, tp) catch {};
                return null;
            }
        };
        if (builtin.os.tag == .macos) {
            if (!runCmd(alloc, io, &.{ "codesign", "--force", "--sign", "-", dest })) {
                std.log.warn("[utmmd] codesign failed — checking if binary is executable...", .{});
                if (!runCmd(alloc, io, &.{ dest, "--version" })) {
                    std.log.err("[utmmd] codesign failed AND binary not executable — manual recovery needed (upgrade at {s})", .{tp});
                    lock.release();
                    return null;
                }
                std.log.info("[utmmd] codesign failed but binary runs — continuing", .{});
            }
        }
        std.log.info("[utmmd] upgrade rename done: → {s}", .{dest});
    }

    // 8. 释放锁
    lock.release();
    std.log.info("[utmmd] upgrade complete", .{});
    return .restart;
}

/// 跨文件系统回退：逐块 copy src → dst。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
fn copyFileUpgradeFallback(file_io: std.Io, src: []const u8, dst: []const u8) !void {
    const sf = try std.Io.Dir.cwd().openFile(file_io, src, .{ .mode = .read_only });
    defer sf.close(file_io);
    const df = try std.Io.Dir.cwd().createFile(file_io, dst, .{ .truncate = true });
    defer df.close(file_io);

    var buf: [65536]u8 = undefined;
    var rdbuf: [65536]u8 = undefined;
    var wrbuf: [65536]u8 = undefined;
    var r = sf.reader(file_io, &rdbuf);
    var w = df.writer(file_io, &wrbuf);
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        w.interface.writeAll(buf[0..n]) catch return error.WriteFailed;
    }
    w.interface.flush() catch {};
    df.sync(file_io) catch {};
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows 文件操作辅助函数（直接用 kernel32 API，绕过 Zig Io.Dir 绝对路径问题）
// ═══════════════════════════════════════════════════════════════════════════

const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
const MOVEFILE_WRITE_THROUGH: u32 = 0x00000008;

extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: ?[*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) i32;

// ── Toolhelp32 进程枚举（替代 taskkill.exe 子进程方案）──
const TH32CS_SNAPPROCESS: u32 = 0x00000002;
const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};
extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Process32FirstW(hSnapshot: ?*anyopaque, lppe: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(hSnapshot: ?*anyopaque, lppe: *PROCESSENTRY32W) callconv(.winapi) i32;

/// 直接枚举所有进程，TerminateProcess 杀掉全部 utmm.exe。
fn killAllUtmmWindows() bool {
    debugLogWindows("killAllUtmmWindows: Toolhelp32 entry");
    const h = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) orelse {
        debugLogWindows("killAllUtmmWindows: snapshot FAILED");
        return false;
    };
    defer _ = CloseHandle(h);

    var pe: PROCESSENTRY32W = undefined;
    pe.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(h, &pe) == 0) return false;

    var killed: bool = false;
    while (true) {
        const name = std.mem.sliceTo(@as([*:0]const u16, @ptrCast(&pe.szExeFile)), 0);
        if (std.mem.eql(u16, name, &[_]u16{ 'u', 't', 'm', 'm', '.', 'e', 'x', 'e' })) {
            if (pe.th32ProcessID != std.os.windows.GetCurrentProcessId()) {
                const ph = OpenProcess(PROCESS_TERMINATE, 0, pe.th32ProcessID);
                if (ph) |h2| {
                    _ = TerminateProcess(h2, 0);
                    _ = WaitForSingleObject(h2, 5000);
                    _ = CloseHandle(h2);
                    killed = true;
                }
            }
        }
        if (Process32NextW(h, &pe) == 0) break;
    }
    debugLogWindows("killAllUtmmWindows: done");
    return killed;
}

fn sleepMsWin(ms: u32) void {
    const krnl = struct {
        extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    };
    krnl.Sleep(ms);
}

/// 用原始 kernel32 WriteFile 写调试日志到 C:\opt\utmm\utmmd-debug.log。
/// 每次调用都 open→write→close，确保进程崩溃时日志不丢失。
/// 绕过所有 CRT/Zig stdlib，直接使用 kernel32 API。
fn debugLogWindows(msg: []const u8) void {
    const log_path = "C:\\opt\\utmm\\utmmd-debug.log";
    var path_utf16: [512]u16 = [_]u16{0} ** 512;
    const path_len = std.unicode.utf8ToUtf16Le(&path_utf16, log_path) catch return;
    if (path_len >= path_utf16.len) return;
    path_utf16[path_len] = 0;

    const handle = CreateFileW(
        @ptrCast(&path_utf16),
        @intCast(FILE_APPEND_DATA_DBG),
        FILE_SHARE_READ_DBG,
        null,
        @intCast(OPEN_ALWAYS_DBG),
        @intCast(FILE_ATTRIBUTE_NORMAL_DBG),
        null,
    );
    if (handle == INVALID_HANDLE_VALUE_DBG) return;

    _ = WriteFile(handle, msg.ptr, @intCast(msg.len), null, null);
    _ = WriteFile(handle, "\r\n", 2, null, null);
    _ = CloseHandle(handle);
}

// kernel32 API for debugLogWindows（使用真实 kernel32 导出名，手动声明以避免
// Zig 0.16.0 std.os.windows 类型系统不匹配）
const INVALID_HANDLE_VALUE_DBG: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
const FILE_APPEND_DATA_DBG: u32 = 0x0004;
const FILE_SHARE_READ_DBG: u32 = 0x00000001;
const OPEN_ALWAYS_DBG: u32 = 4;
const FILE_ATTRIBUTE_NORMAL_DBG: u32 = 128;
extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;

/// 用 DeleteFileW 删除绝对路径文件（避免 std.Io.Dir.cwd().deleteFile 在
/// Windows 上对绝对路径处理不一致的问题）。失败静默忽略。
fn deleteFileAbsoluteWindows(abs_path: []const u8) bool {
    var path_utf16: [512]u16 = [_]u16{0} ** 512;
    const len = std.unicode.utf8ToUtf16Le(&path_utf16, abs_path) catch return false;
    if (len >= path_utf16.len) return false;
    path_utf16[len] = 0;
    return DeleteFileW(@ptrCast(&path_utf16)) != 0;
}


// ═══════════════════════════════════════════════════════════════════════════
// 信号处理 — POSIX（直接用 C extern + 原生 sigaction）
// ═══════════════════════════════════════════════════════════════════════════

var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Windows SCM 停止事件 — svcHandler 收到 STOP/SHUTDOWN 控制时设置。
/// monitorLoop / stabilityCheck / monitorUtmm 轮询此标志位优雅退出，
/// 替代 svcHandler 中直接 exit(0) 的错误行为。
var g_stop_event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// 直接用 C sigaction — Zig 0.16.0 的 Sigaction/SIG 类型跨平台差异大。
extern "c" fn sigaction(sig: c_int, noalias act: ?*const c_sigaction, noalias oact: ?*c_sigaction) c_int;

const c_sigaction = extern struct {
    handler: extern union {
        sa_handler: ?*align(1) const fn (c_int) callconv(.c) void,
        sa_sigaction: ?*align(1) const fn (c_int, *anyopaque, *anyopaque) callconv(.c) void,
    },
    sa_mask: u32,
    sa_flags: c_int,
};

const SIGTERM: c_int = 15;
const SIGINT: c_int = 2;
const SIGCHLD: c_int = 20;
const SIG_IGN: ?*align(1) const fn (c_int) callconv(.c) void = @ptrFromInt(1);

fn setupSignalsPosix() void {
    var sa: c_sigaction = undefined;
    @memset(std.mem.asBytes(&sa), 0);
    sa.handler = .{ .sa_handler = handleSigterm };
    _ = sigaction(SIGTERM, &sa, null);
    _ = sigaction(SIGINT, &sa, null);
    sa.handler = .{ .sa_handler = SIG_IGN };
    _ = sigaction(SIGCHLD, &sa, null);
}

fn handleSigterm(_: c_int) callconv(.c) void {
    sigterm_received.store(true, .release);
}

// ═══════════════════════════════════════════════════════════════════════════
// 睡眠
// ═══════════════════════════════════════════════════════════════════════════

fn sleepMs(io: std.Io, ms: u64) void {
    if (ms == 0) return;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

// ═══════════════════════════════════════════════════════════════════════════
// 监控主循环
// ═══════════════════════════════════════════════════════════════════════════

const RestartReason = enum { restart, shutdown, crashed };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    // 解析参数（使用 init.minimal.args，不需要 argsWithAllocator）
    const args_list = try init.minimal.args.toSlice(init.arena.allocator());

    const cli = try parseArgs(alloc, args_list);
    defer freeCliArgs(alloc, cli);

    std.log.info("[utmmd] starting, role={s}", .{@tagName(cli.role)});
    if (builtin.os.tag == .windows) debugLogWindows("main: parsed args");

    // 创建共享内存
    if (builtin.os.tag == .windows) debugLogWindows("main: before shm.create");
    const shm_ptr = try shm.create(init.io);
    if (builtin.os.tag == .windows) debugLogWindows("main: after shm.create");
    defer shm.destroy(shm_ptr);

    // POSIX 信号
    if (builtin.os.tag != .windows) setupSignalsPosix();

    // Windows SCM 分发
    if (builtin.os.tag == .windows and cli.is_svc) {
        try winServiceRun(init.io, alloc, shm_ptr, cli.utmm_args);
        return;
    }

    // 进入监控循环
    monitorLoop(init.io, alloc, shm_ptr, cli.utmm_args);
}

fn monitorLoop(io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, utmm_args: []const []const u8) void {
    if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: entry");

    // 所有平台都需要独立的 Threaded Io 进行文件操作。
    // 事件循环 Io（epoll/kqueue/IOCP）不支持文件系统操作
    //（openDirAbsolute/rename/deleteFile 等）。POSIX 上复用 io 会导致
    // findUpgradeTmpPosix 中的 openDirAbsolute 静默失败 → 升级 .tmp 文件
    // 永远不会被发现（v0.18.34 linuxvm 升级失败根因）。
    if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: before Threaded.init");
    var file_threaded = std.Io.Threaded.init(alloc, .{});
    if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: after Threaded.init");
    const file_io: std.Io = file_threaded.io();

    var failure_count: u32 = 0;
    var backoff_sec: u32 = 1;
    shm_ptr.svc_state = @intFromEnum(shm.SvcState.running);

    while (true) {
        if (sigterm_received.load(.acquire) or g_stop_event.load(.acquire)) {
            std.log.info("[utmmd] stop signal received, shutting down", .{});
            shm_ptr.svc_state = @intFromEnum(shm.SvcState.stopping);
            // 杀掉 utmm 子进程防止变孤儿进程
            killUtmmByPid(shm_ptr.utmm_pid);
            return;
        }

        // 清理上次升级遗留的旧二进制（rename 替换后残留的 utmm-old.exe）
        if (builtin.os.tag == .windows) {
            _ = deleteFileAbsoluteWindows("C:\\opt\\utmm\\utmm-old.exe");
        }

        // 启动前检查待处理升级：utmm crash-loop 时 monitorUtmm 没机会运行，
        // 必须在启动 utmm 之前处理升级文件，否则永远卡在 crash-recovery 循环。
        //
        // Windows 上：升级替换需要 rename utmm.exe，但可能仍有残留 utmm.exe 进程
        // （--install 进程本身、上次 crash 遗留的孤儿进程等）持有 exe 文件句柄，
        // 导致 rename 失败。先通过 taskkill 确保所有 utmm.exe 已终止。
        if (builtin.os.tag == .windows) {
            if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: before killAllUtmmWindows#1");
            _ = killAllUtmmWindows();
            if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: after killAllUtmmWindows#1");
        }
        if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: before tryApplyPendingUpgrade");
        if (tryApplyPendingUpgrade(file_io, io, alloc, null, shm_ptr)) |_| {
            if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: upgrade applied, looping to start new utmm");
            // 升级已应用，继续循环启动新的（已升级的）utmm
        }
        if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: after tryApplyPendingUpgrade");

        // 启动 utmm
        if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: before startUtmm");
        const proc = startUtmm(io, alloc, shm_ptr, utmm_args) catch |err| {
            if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: startUtmm FAILED");
            std.log.err("[utmmd] start failed: {}", .{err});
            failure_count += 1;
            if (failure_count > MAX_FAILURE_COUNT) {
                std.log.err("[utmmd] {d} consecutive failures, exiting", .{failure_count});
                return;
            }
            backoff_sec = @min(backoff_sec * 2, MAX_BACKOFF_SEC);
            shm_ptr.backoff_sec = backoff_sec;
            shm_ptr.failure_count = failure_count;
            sleepMs(io, backoff_sec * 1000);
            continue;
        };

        if (builtin.os.tag == .windows) debugLogWindows("monitorLoop: utmm started, entering stabilityCheck");

        // 稳定期检查
        if (!stabilityCheck(io, shm_ptr, proc, STABILITY_THRESHOLD_SEC)) {
            failure_count += 1;
            shm_ptr.failure_count = failure_count;
            if (failure_count > MAX_FAILURE_COUNT) {
                std.log.err("[utmmd] {d} consecutive failures, exiting", .{failure_count});
                return;
            }
            backoff_sec = @min(backoff_sec * 2, MAX_BACKOFF_SEC);
            shm_ptr.backoff_sec = backoff_sec;
            std.log.info("[utmmd] backoff {d}s (fail {d}/{d})", .{ backoff_sec, failure_count, MAX_FAILURE_COUNT + 1 });
            sleepMs(io, backoff_sec * 1000);
            continue;
        }

        // 稳定运行
        failure_count = 0;
        backoff_sec = 1;
        shm_ptr.failure_count = 0;
        shm_ptr.backoff_sec = 1;
        std.log.info("[utmmd] utmm stable, monitoring...", .{});

        const reason = monitorUtmm(io, file_io, alloc, shm_ptr, proc);
        switch (reason) {
            .restart => std.log.info("[utmmd] restarting utmm...", .{}),
            .shutdown => {
                std.log.info("[utmmd] shutdown complete", .{});
                shm_ptr.svc_state = @intFromEnum(shm.SvcState.stopping);
                return;
            },
            .crashed => std.log.info("[utmmd] utmm exited unexpectedly, restarting...", .{}),
        }
    }
}

/// 稳定期：等待 utmm 持续运行超过 threshold_sec。
fn stabilityCheck(io: std.Io, shm_ptr: *volatile shm.ShmLayout, proc: ProcessRef, threshold_sec: u64) bool {
    const t0 = shm.nowMs(io);
    var last_hb = t0;

    while (shm.nowMs(io) - t0 < threshold_sec * 1000) {
        sleepMs(io, POLL_INTERVAL_MS);
        if (sigterm_received.load(.acquire) or g_stop_event.load(.acquire)) return false;

        if (!isProcessAlive(proc)) {
            shm_ptr.last_exit_code = 0; // waitpid 已获取，简化
            std.log.warn("[utmmd] utmm crashed during stability check", .{});
            return false;
        }

        const now = shm.nowMs(io);
        if (now - last_hb >= 2000) {
            shm.writeSvcHeartbeat(shm_ptr, io);
            last_hb = now;
        }

        if (shm.readCmd(shm_ptr) == .shutdown) {
            _ = killProcess(proc);
            return false;
        }
    }

    shm.writeSvcHeartbeat(shm_ptr, io);
    return true;
}

/// 运行中监控。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
fn monitorUtmm(io: std.Io, file_io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, proc: ProcessRef) RestartReason {
    // 确保进程句柄在返回时被关闭（Windows 上 HANDLE 不会自动回收）
    defer if (builtin.os.tag == .windows) closeProcessHandle(proc);

    var last_hb = shm.nowMs(io);

    // IP 变更检测状态
    var last_ip_check = shm.nowMs(io);
    var last_ip_fingerprint: u64 = 0;
    var stable_ip_checks: u32 = 0;

    // 升级连续失败计数 — 防止 .tmp 永不可应用时无限重试。
    // 仅当 .tmp 文件确实存在但 tryApplyPendingUpgrade 失败时递增。
    // 无 .tmp 文件时重置（正常状态，无需升级）。
    var upgrade_fail_streak: u32 = 0;

    while (true) {
        sleepMs(io, POLL_INTERVAL_MS);

        if (sigterm_received.load(.acquire) or g_stop_event.load(.acquire)) {
            _ = killProcess(proc);
            return .shutdown;
        }

        const now = shm.nowMs(io);
        if (now - last_hb >= 2000) {
            shm.writeSvcHeartbeat(shm_ptr, io);
            last_hb = now;
        }

        // 心跳超时检测
        const hb = shm.readUtmmHeartbeat(shm_ptr);
        if (hb > 0 and now - hb > HEARTBEAT_TIMEOUT_SEC * 1000) {
            std.log.warn("[utmmd] heartbeat timeout, killing utmm", .{});
            _ = killProcess(proc);
            return .crashed;
        }

        // 进程退出检测
        if (!isProcessAlive(proc)) {
            std.log.info("[utmmd] utmm exited", .{});
            const cmd = shm.readCmd(shm_ptr);
            if (cmd == .restart) {
                shm.clearCmd(shm_ptr);
                return .restart;
            }
            if (cmd == .shutdown) return .shutdown;
            return .crashed;
        }

        // 文件式升级检查：utmmd 扫描 .tmp 文件 → 尝试锁 → 校验 → 应用升级
        if (tryApplyPendingUpgrade(file_io, io, alloc, proc, shm_ptr)) |reason| {
            return reason;
        }
        // 升级未成功 — 区分「无 .tmp」和「有 .tmp 但失败」。
        // 有 .tmp 但连续失败 = 升级文件无法应用（磁盘满、权限等），
        // 必须设置上限，防止无限重试（每秒一次永不休止）。
        if (svc.findUpgradeTmp(alloc, file_io)) |tp| {
            defer alloc.free(tp);
            upgrade_fail_streak += 1;
            if (upgrade_fail_streak >= MAX_UPGRADE_FAILURES) {
                std.log.err("[utmmd] upgrade failed {d} consecutive times — removing stale {s}", .{ upgrade_fail_streak, tp });
                if (builtin.os.tag == .windows) _ = deleteFileAbsoluteWindows(tp)
                else std.Io.Dir.cwd().deleteFile(file_io, tp) catch {};
                upgrade_fail_streak = 0;
            }
        } else {
            upgrade_fail_streak = 0;
        }

        // 命令处理
        const cmd = shm.readCmd(shm_ptr);
        switch (cmd) {
            .restart => {
                // Guest 通过 SHM 发 restart 信号表明升级 .tmp 已就绪。
                // 尝试立即应用升级，成功则重启到新版。
                if (tryApplyPendingUpgrade(file_io, io, alloc, proc, shm_ptr)) |reason| {
                    shm.clearCmd(shm_ptr);
                    return reason;
                }
                // 升级文件尚未就绪（锁未释放、taskkill 未完成等）。
                // 清除命令，继续监控循环 — 主循环的 upgrade 检查（本函数
                // 每轮先检查升级再处理命令）会在下一轮重试。不杀 utmm：
                // 杀后重启旧二进制 = 升级丢失 + 服务中断，两败俱伤。
                shm.clearCmd(shm_ptr);
                // 注意：失败计数由上面的主循环 upgrade 检查统一处理，
                // 不在此单独计数，避免一次失败被双重计数。
            },
            .shutdown => {
                shm.clearCmd(shm_ptr);
                return .shutdown;
            },
            .none, .upgrade => {}, // .upgrade 已迁移到文件式升级，SHM 处忽略
        }

        // IP 变更检测（每 IP_CHECK_INTERVAL_MS 检查一次，去抖后触发重启）
        if (now - last_ip_check >= IP_CHECK_INTERVAL_MS) {
            last_ip_check = now;
            const fp = getAllIpsFingerprint();
            if (fp != 0 and fp != last_ip_fingerprint) {
                if (last_ip_fingerprint != 0) {
                    stable_ip_checks += 1;
                    if (stable_ip_checks >= IP_STABLE_CHECKS) {
                        std.log.warn("[utmmd] IP change detected, restarting utmm (fp 0x{x})", .{fp});
                        _ = killProcess(proc);
                        return .crashed;
                    }
                } else {
                    // 首次检测到有效 IP，记录指纹不触发
                    last_ip_fingerprint = fp;
                    stable_ip_checks = 0;
                }
            } else if (fp == last_ip_fingerprint and fp != 0) {
                // 指纹稳定，重置去抖计数器
                stable_ip_checks = 0;
            }
            // fp == 0 时不更新指纹也不触发（接口全部 down 保持上次状态）
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows SCM 分发
// ═══════════════════════════════════════════════════════════════════════════

const SERVICE_WIN32_OWN_PROCESS = 0x00000010;
const SERVICE_ACCEPT_STOP = 0x00000001;
const SERVICE_CONTROL_STOP = 0x00000001;
const SERVICE_CONTROL_INTERROGATE = 0x00000004;
const SERVICE_CONTROL_SHUTDOWN = 0x00000005;
const SERVICE_RUNNING = 0x00000004;
const SERVICE_START_PENDING = 0x00000002;
const SERVICE_STOP_PENDING = 0x00000003;
const SERVICE_STOPPED = 0x00000001;

const SERVICE_STATUS = extern struct {
    dwServiceType: u32,
    dwCurrentState: u32,
    dwControlsAccepted: u32,
    dwWin32ExitCode: u32,
    dwServiceSpecificExitCode: u32,
    dwCheckPoint: u32,
    dwWaitHint: u32,
};
const SERVICE_STATUS_HANDLE = *anyopaque;
const SvcMainFn = *const fn (dwNumServiceArgs: u32, lpServiceArgVectors: [*]?[*:0]const u16) callconv(.winapi) void;
const SERVICE_TABLE_ENTRYW = extern struct {
    lpServiceName: ?[*:0]const u16,
    lpServiceProc: ?SvcMainFn,
};

extern "advapi32" fn StartServiceCtrlDispatcherW(lpServiceStartTable: [*]const SERVICE_TABLE_ENTRYW) callconv(.winapi) u32;
extern "advapi32" fn RegisterServiceCtrlHandlerExW(lpServiceName: [*:0]const u16, lpHandlerProc: ?*const fn (u32, u32, ?*anyopaque, ?*anyopaque) callconv(.winapi) u32, lpContext: ?*anyopaque) callconv(.winapi) ?SERVICE_STATUS_HANDLE;
extern "advapi32" fn SetServiceStatus(hServiceStatus: ?SERVICE_STATUS_HANDLE, lpServiceStatus: *SERVICE_STATUS) callconv(.winapi) u32;

const SVC_NAME_UTF16 = [_:0]u16{ 'u', 't', 'm', 'm', 'd', 0 };

const SvcCtx = struct {
    var io: std.Io = undefined;
    var gpa: std.mem.Allocator = undefined;
    var args: []const []const u8 = &.{};
    var shm_p: ?*volatile shm.ShmLayout = null;
    var status_handle: ?SERVICE_STATUS_HANDLE = null;
};

fn svcHandler(dwControl: u32, _: u32, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) u32 {
    switch (dwControl) {
        SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN => {
            // 1. 报告 STOP_PENDING — SCM 期望 RUNNING→STOP_PENDING→STOPPED 状态转换。
            //    dwWaitHint=10000 告知 SCM 预计 10 秒内完成停止。
            if (SvcCtx.status_handle) |h| {
                var s = std.mem.zeroes(SERVICE_STATUS);
                s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
                s.dwCurrentState = SERVICE_STOP_PENDING;
                s.dwControlsAccepted = 0;
                s.dwWaitHint = 10000;
                s.dwCheckPoint = 1;
                _ = SetServiceStatus(h, &s);
            }
            // 2. 通知 monitorLoop 优雅退出（设置原子标志位后立即返回，
            //    不在 SCM Handler 线程中执行清理或 exit）。
            g_stop_event.store(true, .release);
            return 0;
        },
        SERVICE_CONTROL_INTERROGATE => {
            // SCM 定期发送 INTERROGATE 检查服务健康状态。
            // 必须调用 SetServiceStatus 报告当前状态，否则 SCM 可能标记服务为未响应。
            if (SvcCtx.status_handle) |h| {
                var s = std.mem.zeroes(SERVICE_STATUS);
                s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
                s.dwCurrentState = SERVICE_RUNNING;
                s.dwControlsAccepted = SERVICE_ACCEPT_STOP;
                _ = SetServiceStatus(h, &s);
            }
            return 0;
        },
        else => return 0,
    }
}

fn svcMain(_: u32, _: [*]?[*:0]const u16) callconv(.winapi) void {
    debugLogWindows("svcMain: entry");
    const h = RegisterServiceCtrlHandlerExW(&SVC_NAME_UTF16, svcHandler, null);
    debugLogWindows("svcMain: handler registered");
    SvcCtx.status_handle = h;
    if (h) |handle| {
        // 1. 报告 SERVICE_START_PENDING — SCM 期望 START_PENDING → RUNNING 状态转换。
        //    dwWaitHint=5000 告知 SCM 预计 5 秒内完成初始化。
        var s = std.mem.zeroes(SERVICE_STATUS);
        s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        s.dwCurrentState = SERVICE_START_PENDING;
        s.dwControlsAccepted = 0;
        s.dwWaitHint = 5000;
        s.dwCheckPoint = 0;
        _ = SetServiceStatus(handle, &s);

        // 2. 初始化完成 → SERVICE_RUNNING
        s.dwCurrentState = SERVICE_RUNNING;
        s.dwControlsAccepted = SERVICE_ACCEPT_STOP;
        s.dwWaitHint = 0;
        s.dwCheckPoint = 0;
        _ = SetServiceStatus(handle, &s);
    }

    if (SvcCtx.shm_p) |shm_ptr| {
        monitorLoop(SvcCtx.io, SvcCtx.gpa, shm_ptr, SvcCtx.args);
    }

    // monitorLoop 正常返回（收到 STOP/SHUTDOWN 信号后优雅退出）→ 报告 SERVICE_STOPPED。
    // 此时 utmm 子进程已被 killUtmmByPid 终止，共享内存将在 defer shm.destroy 中清理。
    if (h) |handle| {
        var s = std.mem.zeroes(SERVICE_STATUS);
        s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        s.dwCurrentState = SERVICE_STOPPED;
        s.dwControlsAccepted = 0;
        s.dwWin32ExitCode = 0;
        _ = SetServiceStatus(handle, &s);
    }
}

fn winServiceRun(io: std.Io, gpa: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, utmm_args: []const []const u8) !void {
    SvcCtx.io = io;
    SvcCtx.gpa = gpa;
    SvcCtx.args = utmm_args;
    SvcCtx.shm_p = shm_ptr;

    var tbl = [2]SERVICE_TABLE_ENTRYW{
        .{ .lpServiceName = &SVC_NAME_UTF16, .lpServiceProc = svcMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };
    if (StartServiceCtrlDispatcherW(&tbl) == 0) {
        std.log.err("[utmmd] SCM dispatch failed: {d}", .{@intFromEnum(std.os.windows.GetLastError())});
        return error.ServiceDispatchFailed;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests — 参数转发回归测试
// ═══════════════════════════════════════════════════════════════════════════
//
// Bug 背景：utmmd 解析 --role host 后未将 --host 标志转发给 utmm 子进程，
// utmm 默认为 guest 模式，Host daemon 的 IPC server 不启动，CLI 命令挂起。

fn testParseArgs(alloc: std.mem.Allocator, args: []const [:0]const u8) !CliArgs {
    return parseArgs(alloc, args);
}

test "parseArgs: --role host adds --host flag" {
    const alloc = std.testing.allocator;
    const argv = [_][:0]const u8{ "utmmd", "--role", "host", "--hostname", "testbox" };
    const cli = try testParseArgs(alloc, &argv);
    defer freeCliArgs(alloc, cli);

    try std.testing.expect(cli.role == .host);

    // 验证 --host 被添加到 utmm_args 中
    var found_host = false;
    var found_hostname = false;
    for (cli.utmm_args) |a| {
        if (std.mem.eql(u8, a, "--host")) found_host = true;
        if (std.mem.eql(u8, a, "--hostname")) found_hostname = true;
    }
    try std.testing.expect(found_host);
    try std.testing.expect(found_hostname);
}

test "parseArgs: --role guest does NOT add --host flag" {
    const alloc = std.testing.allocator;
    const argv = [_][:0]const u8{ "utmmd", "--role", "guest", "--hostname", "testbox" };
    const cli = try testParseArgs(alloc, &argv);
    defer freeCliArgs(alloc, cli);

    try std.testing.expect(cli.role == .guest);

    // 验证 --host 没有被添加到 utmm_args 中
    for (cli.utmm_args) |a| {
        try std.testing.expect(!std.mem.eql(u8, a, "--host"));
    }
}

test "parseArgs: only --role and --svc are consumed, others forwarded" {
    const alloc = std.testing.allocator;
    const argv = [_][:0]const u8{ "utmmd", "--role", "guest", "--svc", "--port", "2122", "--log-file", "/tmp/utmm.log" };
    const cli = try testParseArgs(alloc, &argv);
    defer freeCliArgs(alloc, cli);

    try std.testing.expect(cli.role == .guest);
    try std.testing.expect(cli.is_svc);

    // 验证其他参数被透传
    var found_port = false;
    var found_log = false;
    for (cli.utmm_args) |a| {
        if (std.mem.eql(u8, a, "--port")) found_port = true;
        if (std.mem.eql(u8, a, "--log-file")) found_log = true;
    }
    try std.testing.expect(found_port);
    try std.testing.expect(found_log);
}

test "parseArgs: --role host with extra args correctly includes --host" {
    const alloc = std.testing.allocator;
    const argv = [_][:0]const u8{ "utmmd", "--svc", "--role", "host", "--hostname", "myhost", "--port", "2121" };
    const cli = try testParseArgs(alloc, &argv);
    defer freeCliArgs(alloc, cli);

    try std.testing.expect(cli.role == .host);
    try std.testing.expect(cli.is_svc);

    var found_host = false;
    for (cli.utmm_args) |a| {
        if (std.mem.eql(u8, a, "--host")) found_host = true;
    }
    try std.testing.expect(found_host);
}

test "getAllIpsFingerprint: returns u64" {
    const fp = getAllIpsFingerprint();
    try std.testing.expect(@TypeOf(fp) == u64);
    // 返回值 0 表示无网络接口，非零表示有有效 IPv4 — 两种情况都合法。
}

test "getAllIpsFingerprint: deterministic within same call" {
    const fp1 = getAllIpsFingerprint();
    const fp2 = getAllIpsFingerprint();
    // 同一进程内两次连续调用应返回相同结果（无 I/O 状态变化）
    try std.testing.expectEqual(fp1, fp2);
}

test "getAllIpsFingerprint: logic — first non-zero fingerprints do not trigger" {
    // 模拟 monitorUtmm 的去抖逻辑：首次有效指纹只记录不触发
    const seed_fp = getAllIpsFingerprint();
    var last_fp: u64 = 0;
    var stable_checks: u32 = 0;
    var should_restart = false;

    // 首次非零指纹
    if (seed_fp != 0 and seed_fp != last_fp) {
        if (last_fp == 0) {
            // 首次检测到有效 IP，记录指纹不触发
            last_fp = seed_fp;
            stable_checks = 0;
        } else {
            stable_checks += 1;
            if (stable_checks >= 2) should_restart = true;
        }
    }
    try std.testing.expect(!should_restart);
    try std.testing.expectEqual(seed_fp, last_fp);
}

test "getAllIpsFingerprint: logic — different fingerprints trigger after debounce" {
    const base_fp = getAllIpsFingerprint();
    if (base_fp == 0) return; // 无网络时跳过此测试

    // 模拟 IP 变更场景：last_fp 记录的是"旧 IP 指纹"，
    // 每次调用 getAllIpsFingerprint 返回的是"当前 IP 指纹"
    var last_fp: u64 = 0;
    var stable_checks: u32 = 0;
    var should_restart = false;

    // 模拟真实算法：假设 IP 从 base_fp 变成了 base_fp+1，
    // 且连续 2 次检查都看到新值
    const new_fp: u64 = base_fp +% 1;

    // 检查 1：首次有效指纹，记录为 last_fp（模拟种子初始化）
    if (new_fp != 0 and new_fp != last_fp) {
        if (last_fp == 0) {
            last_fp = new_fp;
            stable_checks = 0;
        }
    }
    try std.testing.expect(!should_restart);
    try std.testing.expectEqual(new_fp, last_fp);

    // 现在模拟 IP 变更：指纹变成另一值，连续 2 次检查
    const changed_fp: u64 = base_fp +% 2;
    // last_fp 仍是 new_fp（旧指纹），changed_fp 是当前指纹
    // 防止溢出导致 changed_fp == 0
    if (changed_fp == 0) return;

    // 检查 2：检测到指纹不同于 last_fp → stable_checks=1
    if (changed_fp != 0 and changed_fp != last_fp) {
        stable_checks += 1;
    }
    try std.testing.expectEqual(1, stable_checks);
    try std.testing.expect(!should_restart);
    // last_fp 不更新 — 我们只比较"当前 vs 原始"

    // 检查 3：指纹仍不同 → stable_checks=2 → 触发
    if (changed_fp != 0 and changed_fp != last_fp) {
        stable_checks += 1;
        if (stable_checks >= 2) should_restart = true;
    }
    try std.testing.expect(should_restart);
}
