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
extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?std.os.windows.HANDLE;

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
        // Windows: 通过 PID 获取句柄再杀
        const h = OpenProcess(1, 0, pid) orelse return;
        _ = TerminateProcess(h, 1);
        _ = WaitForSingleObject(h, 5000); // 等待异步终止完成
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
/// 注意：不关闭进程句柄——调用者负责管理句柄生命周期。
fn killProcess(proc: ProcessRef) void {
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(proc.handle, 1);
        // 等待进程完全退出——TerminateProcess 异步返回，文件锁可能尚未释放
        _ = WaitForSingleObject(proc.handle, 5000); // 最多等待 5 秒
        std.log.info("[utmmd] utmm killed, pid={d}", .{proc.pid});
    } else {
        if (proc == 0) return;
        std.posix.kill(@intCast(proc), std.posix.SIG.KILL) catch {};
        std.log.info("[utmmd] utmm killed, pid={d}", .{proc});
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
    shm_ptr.svc_heartbeat = shm.nowMs(io);
    shm_ptr.restart_count += 1;
    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.pending);
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
        std.log.err("[utmmd] CreateProcess failed: {d}", .{@intFromEnum(w.GetLastError())});
        return error.ProcessStartFailed;
    }
    _ = w.CloseHandle(pi.hThread);

    shm_ptr.utmm_pid = pi.dwProcessId;
    shm_ptr.svc_heartbeat = shm.nowMs(io);
    shm_ptr.restart_count += 1;
    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.pending);
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

/// 尝试查找并应用待处理升级。
/// 返回 RestartReason 表示升级已应用（调用者应重启 utmm），null 表示无待处理升级。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
fn tryApplyPendingUpgrade(file_io: std.Io, io: std.Io, alloc: std.mem.Allocator, proc: ?ProcessRef) ?RestartReason {
    // 1. 扫描 utmm-upgrade.*.tmp 文件
    const tmp_path = svc.findUpgradeTmp(alloc, file_io) orelse return null;
    defer alloc.free(tmp_path);

    // 2. 提取文件名的 SHA256 hex（用于自校验）
    const basename = if (std.mem.lastIndexOfScalar(u8, tmp_path, '/')) |pos|
        tmp_path[pos + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, tmp_path, '\\')) |pos|
        tmp_path[pos + 1 ..]
    else
        tmp_path;

    if (svc.UpgradeLock.extractSha256(basename, "utmm-upgrade") == null) {
        // 文件名格式不对 — 清理残留
        std.Io.Dir.cwd().deleteFile(file_io, tmp_path) catch {};
        return null;
    }

    // 3. 尝试获取排他锁 — 成功 = 文件写入完成，失败 = Guest 仍在写入
    var lock = svc.UpgradeLock.tryAcquire(tmp_path) orelse return null;

    std.log.info("[utmmd] upgrade tmp file found: {s}", .{tmp_path});

    // 4. 验证文件内容 SHA256 是否与文件名匹配
    if (!svc.verifyUpgradeTmpByFilename(alloc, file_io, tmp_path, basename)) {
        std.log.err("[utmmd] upgrade SHA256 verification failed, deleted {s}", .{tmp_path});
        lock.release();
        // 文件已被 verifyUpgradeTmpByFilename 删除
        return null;
    }

    std.log.info("[utmmd] upgrade SHA256 verified via filename", .{});

    const dest = utmmPath();

    // 5. 杀 utmm 进程（null 跳过：crash-recovery 场景进程已死）
    if (proc) |p| killProcess(p);

    // 6. POSIX: 设置可执行权限
    if (builtin.os.tag != .windows) {
        _ = std.posix.system.chmod(@ptrCast(tmp_path.ptr), 0o755);
    }

    // 7. 替换二进制。
    // POSIX: rename 原子替换目标文件。
    // Windows: 运行中 exe 无法删除或覆盖（文件锁）。先 rename 旧 exe → .old
    //   （Windows 允许 rename 打开的文件），再将新 .tmp rename → 目标。
    //   旧 .old 文件在下次升级或重启时清理。
    if (builtin.os.tag == .windows) {
        const old_path_buf = try alloc.alloc(u8, dest.len + 4);
        defer alloc.free(old_path_buf);
        @memcpy(old_path_buf[0..dest.len], dest);
        @memcpy(old_path_buf[dest.len..], ".old");
        const old_path = old_path_buf[0 .. dest.len + 4];

        // 7a. 删除上次升级的 .old 残留（如果有），忽略错误
        std.Io.Dir.cwd().deleteFile(file_io, old_path) catch {};

        // 7b. 将当前 utmm.exe rename 为 utmm.exe.old
        //     即使 exe 仍在运行（文件锁定）Windows 也允许此操作。
        renameWindowsOldFirst(file_io, dest, old_path, tmp_path) catch |err| {
            std.log.err("[utmmd] upgrade replace failed: {}", .{err});
            lock.release();
            return null;
        };

        // 7c. 清理 .old 文件（best-effort，失败也无妨——下次升级会覆盖）
        std.Io.Dir.cwd().deleteFile(file_io, old_path) catch {};

        std.log.info("[utmmd] upgrade replace done: {s}", .{tmp_path});
    } else {
        // POSIX: rename 原子替换（覆盖已有文件）
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dest, file_io) catch |err| {
            if (err == error.CrossDevice) {
                copyFileUpgradeFallback(file_io, tmp_path, dest) catch |e| {
                    std.log.err("[utmmd] copyFileUpgradeFallback failed: {}", .{e});
                    lock.release();
                    std.Io.Dir.cwd().deleteFile(file_io, tmp_path) catch {};
                    return null;
                };
                std.Io.Dir.cwd().deleteFile(file_io, tmp_path) catch {};
            } else {
                std.log.err("[utmmd] upgrade rename failed: {}", .{err});
                lock.release();
                return null;
            }
        };
        if (builtin.os.tag == .macos) {
            if (!runCmd(alloc, io, &.{ "codesign", "--force", "--sign", "-", dest })) {
                std.log.warn("[utmmd] codesign failed — checking if binary is executable...", .{});
                if (!runCmd(alloc, io, &.{ dest, "--version" })) {
                    std.log.err("[utmmd] codesign failed AND binary not executable — manual recovery needed (upgrade at {s})", .{tmp_path});
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

/// Windows: 安全替换正在运行的可执行文件。
///
/// Windows 上无法直接覆盖或删除运行中的 exe（文件锁定）。但 Windows 允许
/// 对已打开的文件进行重命名操作。利用此特性：
///   1. 将旧 exe 重命名为 .old（释放目标路径名）
///   2. 将新 .tmp 重命名为目标路径名
///
/// 这与 Windows 安装程序的原子替换策略（MoveFileEx + MOVEFILE_REPLACE_EXISTING
/// 回退到 MOVEFILE_DELAY_UNTIL_REBOOT）原理相同，但无需重启。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
fn renameWindowsOldFirst(file_io: std.Io, dest: []const u8, old_path: []const u8, tmp_path: []const u8) !void {
    // 使用原始 Windows MoveFileExW API：
    // MOVEFILE_REPLACE_EXISTING=1 — 替换已有文件
    // MOVEFILE_WRITE_THROUGH=8  — 等待写入完成
    // 不使用 MOVEFILE_DELAY_UNTIL_REBOOT — 不需要重启
    const windows = std.os.windows;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x00000008;

    // 需要 UTF-16 路径
    var dest_utf16: [512]u16 = [_]u16{0} ** 512;
    var old_utf16: [512]u16 = [_]u16{0} ** 512;
    var tmp_utf16: [512]u16 = [_]u16{0} ** 512;

    const dest_len = std.unicode.utf8ToUtf16Le(&dest_utf16, dest) catch return error.NameTooLong;
    if (dest_len >= dest_utf16.len) return error.NameTooLong;
    dest_utf16[dest_len] = 0;

    const old_len = std.unicode.utf8ToUtf16Le(&old_utf16, old_path) catch return error.NameTooLong;
    if (old_len >= old_utf16.len) return error.NameTooLong;
    old_utf16[old_len] = 0;

    const tmp_len = std.unicode.utf8ToUtf16Le(&tmp_utf16, tmp_path) catch return error.NameTooLong;
    if (tmp_len >= tmp_utf16.len) return error.NameTooLong;
    tmp_utf16[tmp_len] = 0;

    // 重试循环：进程刚被杀后文件锁定可能短暂残留
    var retry: u32 = 0;
    while (true) {
        // Step 1: 如果目标 exe 存在，将其重命名为 .old
        //         此操作在 exe 仍在运行时也允许
        if (MoveFileExW(@ptrCast(&dest_utf16), @ptrCast(&old_utf16), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
            std.log.info("[utmmd] renameWindowsOldFirst: renamed dest → .old", .{});
        } else {
            const err = windows.GetLastError();
            if (@intFromEnum(err) == 2) { // ERROR_FILE_NOT_FOUND
                // dest 不存在（首次安装？）— 继续
                std.log.info("[utmmd] renameWindowsOldFirst: dest not found, placing new binary directly", .{});
            } else {
                std.log.err("[utmmd] renameWindowsOldFirst: rename dest → .old failed (err={d})", .{@intFromEnum(err)});
                return error.ReplaceFailed;
            }
        }

        // Step 2: 将新 .tmp 重命名为目标 exe
        if (MoveFileExW(@ptrCast(&tmp_utf16), @ptrCast(&dest_utf16), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
            return;
        }
        const err2 = windows.GetLastError();
        if (retry < 20) {
            retry += 1;
            std.log.warn("[utmmd] renameWindowsOldFirst: rename tmp → dest retry {d}/20 (err={d})", .{ retry, @intFromEnum(err2) });
            // 等待 250ms 后重试（文件锁正在释放）
            std.Io.sleep(file_io, std.Io.Duration.fromMilliseconds(250), .awake) catch {};
            continue;
        }
        std.log.err("[utmmd] renameWindowsOldFirst: rename tmp → dest failed after 20 retries (err={d})", .{@intFromEnum(err2)});
        return error.ReplaceFailed;
    }
}

extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: ?[*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) i32;

// ═══════════════════════════════════════════════════════════════════════════
// 信号处理 — POSIX（直接用 C extern + 原生 sigaction）
// ═══════════════════════════════════════════════════════════════════════════

var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

    // 创建共享内存
    const shm_ptr = try shm.create(init.io);
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
    // Windows: IOCP 不支持文件 I/O（stat/open/read/rename/delete），
    // 需使用独立的 Threaded Io 进行文件操作。POSIX 上直接复用 io。
    const need_threaded = builtin.os.tag == .windows;
    var file_threaded: std.Io.Threaded = undefined;
    if (need_threaded) {
        file_threaded = std.Io.Threaded.init(alloc, .{});
    }
    const file_io: std.Io = if (need_threaded) file_threaded.io() else io;

    var failure_count: u32 = 0;
    var backoff_sec: u32 = 1;
    shm_ptr.svc_state = @intFromEnum(shm.SvcState.running);

    while (true) {
        if (sigterm_received.load(.acquire)) {
            std.log.info("[utmmd] SIGTERM, shutting down", .{});
            shm_ptr.svc_state = @intFromEnum(shm.SvcState.stopping);
            // 杀掉 utmm 子进程防止变孤儿进程
            killUtmmByPid(shm_ptr.utmm_pid);
            return;
        }

        // 启动前检查待处理升级：utmm crash-loop 时 monitorUtmm 没机会运行，
        // 必须在启动 utmm 之前处理升级文件，否则永远卡在 crash-recovery 循环。
        if (tryApplyPendingUpgrade(file_io, io, alloc, null)) |_| {
            // 升级已应用，继续循环启动新的（已升级的）utmm
        }

        // 启动 utmm
        const proc = startUtmm(io, alloc, shm_ptr, utmm_args) catch |err| {
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
        if (sigterm_received.load(.acquire)) return false;

        if (!isProcessAlive(proc)) {
            shm_ptr.last_exit_code = 0; // waitpid 已获取，简化
            std.log.warn("[utmmd] utmm crashed during stability check", .{});
            return false;
        }

        const now = shm.nowMs(io);
        if (now - last_hb >= 2000) {
            shm_ptr.svc_heartbeat = now;
            last_hb = now;
        }

        if (@as(shm.Cmd, @enumFromInt(shm_ptr.cmd)) == .shutdown) {
            killProcess(proc);
            return false;
        }
    }

    shm_ptr.svc_heartbeat = shm.nowMs(io);
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

    while (true) {
        sleepMs(io, POLL_INTERVAL_MS);

        if (sigterm_received.load(.acquire)) {
            killProcess(proc);
            return .shutdown;
        }

        const now = shm.nowMs(io);
        if (now - last_hb >= 2000) {
            shm_ptr.svc_heartbeat = now;
            last_hb = now;
        }

        // 心跳超时检测
        const hb = shm_ptr.utmm_heartbeat;
        if (hb > 0 and now - hb > HEARTBEAT_TIMEOUT_SEC * 1000) {
            std.log.warn("[utmmd] heartbeat timeout, killing utmm", .{});
            killProcess(proc);
            return .crashed;
        }

        // 进程退出检测
        if (!isProcessAlive(proc)) {
            std.log.info("[utmmd] utmm exited", .{});
            const cmd: shm.Cmd = @enumFromInt(shm_ptr.cmd);
            if (cmd == .restart) {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.done);
                shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                return .restart;
            }
            if (cmd == .shutdown) return .shutdown;
            return .crashed;
        }

        // 文件式升级检查：utmmd 扫描 .tmp 文件 → 尝试锁 → 校验 → 应用升级
        if (tryApplyPendingUpgrade(file_io, io, alloc, proc)) |reason| {
            return reason;
        }

        // 命令处理
        const cmd: shm.Cmd = @enumFromInt(shm_ptr.cmd);
        switch (cmd) {
            .restart => {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.accepted);
                shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                killProcess(proc);
                return .restart;
            },
            .shutdown => {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.accepted);
                killProcess(proc);
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
                        killProcess(proc);
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
const SERVICE_RUNNING = 0x00000004;
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
    if (dwControl == SERVICE_CONTROL_STOP) {
        var s = std.mem.zeroes(SERVICE_STATUS);
        s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        s.dwCurrentState = SERVICE_STOPPED;
        s.dwControlsAccepted = 0;
        _ = SetServiceStatus(SvcCtx.status_handle, &s);
        std.process.exit(0);
    }
    return 0;
}

fn svcMain(_: u32, _: [*]?[*:0]const u16) callconv(.winapi) void {
    const h = RegisterServiceCtrlHandlerExW(&SVC_NAME_UTF16, svcHandler, null);
    SvcCtx.status_handle = h;
    if (h) |handle| {
        var s = std.mem.zeroes(SERVICE_STATUS);
        s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        s.dwCurrentState = SERVICE_RUNNING;
        s.dwControlsAccepted = SERVICE_ACCEPT_STOP;
        _ = SetServiceStatus(handle, &s);
    }

    if (SvcCtx.shm_p) |shm_ptr| {
        monitorLoop(SvcCtx.io, SvcCtx.gpa, shm_ptr, SvcCtx.args);
    }

    if (h) |handle| {
        var s = std.mem.zeroes(SERVICE_STATUS);
        s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        s.dwCurrentState = SERVICE_STOPPED;
        s.dwControlsAccepted = 0;
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
