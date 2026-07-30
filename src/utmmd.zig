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
        _ = std.os.windows.CloseHandle(h);
        std.log.info("[utmmd] utmm killed by pid, pid={d}", .{pid});
    } else {
        std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
        std.log.info("[utmmd] utmm killed by pid, pid={d}", .{pid});
    }
}

/// 强杀 utmm 进程。
fn killProcess(proc: ProcessRef) void {
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(proc.handle, 1);
        _ = std.os.windows.CloseHandle(proc.handle);
        std.log.info("[utmmd] utmm killed, pid={d}", .{proc.pid});
    } else {
        if (proc == 0) return;
        std.posix.kill(@intCast(proc), std.posix.SIG.KILL) catch {};
        std.log.info("[utmmd] utmm killed, pid={d}", .{proc});
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

// ═══════════════════════════════════════════════════════════════════════════
// 升级
// ═══════════════════════════════════════════════════════════════════════════

fn upgradeUtmm(io: std.Io, alloc: std.mem.Allocator, upgrade_path: []const u8) !void {
    const dest = utmmPath();
    std.log.info("[utmmd] upgrading: {s} → {s}", .{ upgrade_path, dest });

    _ = std.Io.Dir.cwd().statFile(io, upgrade_path, .{}) catch return error.UpgradeFileNotFound;

    // POSIX: 设置可执行权限
    if (builtin.os.tag != .windows) {
        _ = std.posix.system.chmod(@ptrCast(upgrade_path.ptr), 0o755);
    }

    // 原子替换
    std.Io.Dir.cwd().rename(upgrade_path, std.Io.Dir.cwd(), dest, io) catch |err| {
        if (err == error.CrossDevice) {
            // 跨文件系统回退
            try copyFileUpgrade(io, alloc, upgrade_path, dest);
            if (builtin.os.tag == .macos) {
                _ = runCmd(alloc, io, &.{ "codesign", "--force", "--sign", "-", dest });
            }
            std.Io.Dir.cwd().deleteFile(io, upgrade_path) catch {};
        } else return err;
    };

    std.log.info("[utmmd] upgrade complete", .{});
}

fn copyFileUpgrade(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    _ = alloc;
    const sf = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer sf.close(io);
    const df = try std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer df.close(io);

    var buf: [65536]u8 = undefined;
    var rdbuf: [65536]u8 = undefined;
    var wrbuf: [65536]u8 = undefined;
    var r = sf.reader(io, &rdbuf);
    var w = df.writer(io, &wrbuf);
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        w.interface.writeAll(buf[0..n]) catch return error.WriteFailed;
    }
    w.interface.flush() catch {};
    df.sync(io) catch {};
}

fn runCmd(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

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

fn getCmdDataStr(alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout) ![]const u8 {
    // Volatile 数组 → 需要 @volatileCast 后转为 []const u8
    const raw: [*]const u8 = @ptrCast(@volatileCast(&shm_ptr.cmd_data));
    const slice: []const u8 = raw[0..1024];
    const len = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    if (len == 0) return error.EmptyCmdData;
    return try alloc.dupe(u8, slice[0..len]);
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

        const reason = monitorUtmm(io, alloc, shm_ptr, proc);
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
fn monitorUtmm(io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, proc: ProcessRef) RestartReason {
    var last_hb = shm.nowMs(io);

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
            if (cmd == .upgrade) {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.accepted);
                const up = getCmdDataStr(alloc, shm_ptr) catch |err| {
                    std.log.err("[utmmd] bad upgrade path: {}", .{err});
                    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.failed);
                    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                    return .crashed;
                };
                defer alloc.free(up);
                upgradeUtmm(io, alloc, up) catch |err| {
                    std.log.err("[utmmd] upgrade failed: {}", .{err});
                    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.failed);
                    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                    return .crashed;
                };
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.done);
                shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                return .restart;
            }
            if (cmd == .restart) {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.done);
                shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                return .restart;
            }
            if (cmd == .shutdown) return .shutdown;
            return .crashed;
        }

        // 命令处理
        const cmd: shm.Cmd = @enumFromInt(shm_ptr.cmd);
        switch (cmd) {
            .upgrade => {
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.accepted);
                // 在 kill 之前读取升级路径（shm 数据仍有效）
                const up = getCmdDataStr(alloc, shm_ptr) catch |err| {
                    std.log.err("[utmmd] bad upgrade path: {}", .{err});
                    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.failed);
                    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                    return .crashed;
                };
                defer alloc.free(up);
                upgradeUtmm(io, alloc, up) catch |err| {
                    std.log.err("[utmmd] upgrade failed: {}", .{err});
                    shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.failed);
                    shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                    return .crashed;
                };
                shm_ptr.cmd_status = @intFromEnum(shm.CmdStatus.done);
                shm_ptr.cmd = @intFromEnum(shm.Cmd.none);
                killProcess(proc);
                return .restart;
            },
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
            .none => {},
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
