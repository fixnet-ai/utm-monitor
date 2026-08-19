// dpipe_shell.zig — PTY shell 封装为 DuplexPipe
//
// 提供 create() 工厂函数：创建一个后台 shell 进程，将其 stdin/stdout
// 作为 DuplexPipe 暴露。每条命令使用独立的 shell 实例 — 不支持跨命令
// 共享 shell 状态（cd、export 等不持久）。
//
// POSIX: posix_openpt → fork → setsid → dup2 → exec $SHELL
// Windows: CreatePipe + cmd.exe /k（会话保持系统本地 OEM 代码页）+ Guest 侧
//   OEM↔UTF-8 双向转码 — 模拟真实控制台的转码职责：
//   - 输出：cmd/系统命令按本地 OEM（GetOEMCP：中日韩 936/932/949 自动匹配）
//     输出字节 → 转成 UTF-8 再发给 Host → 多语言通解，无需知道目标内码。
//     老命令（ipconfig 等 ANSI API）无视 chcp 始终按 OEM 输出，chcp 65001
//     既救不了输出又会破坏 cmd 管道 stdin 的多字节输入 — 因此不设 chcp。
//   - 输入：Host 发来的 UTF-8 命令 → 转成本地 OEM 写给 cmd stdin。
//   注意：ConPTY（CreatePseudoConsole）实测在本环境（Session 0 服务链）不可用
//   ——所有 API 成功但 cmd 拿不到伪控制台（零输出），见 findings 2026-08-19。

const std = @import("std");
const builtin = @import("builtin");
const dpipe = @import("dpipe.zig");

// ── C 外部函数声明 ────────────────────────────────────────────

// POSIX
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

// ── Shell 上下文结构 ───────────────────────────────────────────

/// PTY shell 状态：master fd + 子进程 pid + shell 描述。
const ShellCtx = struct {
    allocator: std.mem.Allocator,
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    shell: []const u8,
    stdin_fd: std.posix.fd_t, // Windows: stdin_write pipe handle
    /// Windows: Job Object 句柄（KILL_ON_JOB_CLOSE）— 取消时整树击杀
    /// cmd.exe 的子进程（ping/python/make 等）。INVALID_HANDLE_VALUE = 未启用
    ///（降级为仅杀 cmd）。POSIX 侧不使用。
    job_handle: std.posix.fd_t = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0,
    // Windows OEM↔UTF-8 跨块转码暂存（详见 readFn/writeFn）
    out_pending: [4]u8 = undefined, // 尾部 DBCS 前导字节（OEM 侧）
    out_pending_len: usize = 0,
    in_pending: [4]u8 = undefined, // 尾部不完整 UTF-8 序列
    in_pending_len: usize = 0,
};

// ── 工厂函数 ──────────────────────────────────────────────────

/// 创建后台 shell 进程并返回其 DuplexPipe 接口。
///
/// shell_path: 壳路径（如 "/bin/zsh" 或 "cmd.exe"）。在 POSIX 上，
/// 实际 shell 由 $SHELL 环境变量决定；Windows 上固定使用 cmd.exe。
///
/// 返回的 DuplexPipe 拥有 shell 进程的所有权 — close() 会
/// kill 子进程、关闭 fd、释放内存。
pub fn create(allocator: std.mem.Allocator, shell_path: []const u8) !dpipe.DuplexPipe {
    const session = try spawn(allocator, shell_path);

    // 在堆上分配 ShellCtx — 生命周期由 close() 管理
    const ctx = try allocator.create(ShellCtx);
    ctx.* = session;

    return dpipe.DuplexPipe{
        .ctx = ctx,
        .vtable = &shell_vtable,
    };
}

fn spawn(allocator: std.mem.Allocator, shell: []const u8) !ShellCtx {
    if (builtin.os.tag == .windows) {
        return spawnWindows(allocator);
    }
    return spawnPosix(allocator, shell);
}

// ── Windows 派生 ──────────────────────────────────────────────

fn spawnWindows(allocator: std.mem.Allocator) !ShellCtx {
    return spawnWindowsPipe(allocator);
}

// ── POSIX PTY 派生 ────────────────────────────────────────────

fn spawnPosix(allocator: std.mem.Allocator, shell: []const u8) !ShellCtx {
    const master = posix_openpt(O_RDWR);
    if (master < 0) {
        std.log.err("[dpipe-shell] posix_openpt failed", .{});
        return error.PtyOpenFailed;
    }
    errdefer _ = close(master);

    if (grantpt(master) != 0) {
        std.log.err("[dpipe-shell] grantpt failed", .{});
        return error.PtyGrantFailed;
    }
    if (unlockpt(master) != 0) {
        std.log.err("[dpipe-shell] unlockpt failed", .{});
        return error.PtyUnlockFailed;
    }

    const slave_name = ptsname(master) orelse {
        std.log.err("[dpipe-shell] ptsname returned null", .{});
        return error.PtyPtsnameFailed;
    };

    const pid = fork();
    if (pid < 0) {
        std.log.err("[dpipe-shell] fork failed", .{});
        return error.PtyForkFailed;
    }

    if (pid == 0) {
        // 子进程：设置控制终端并 exec shell
        _ = setsid();

        const slave = open(slave_name, O_RDWR, 0);
        if (slave < 0) {
            std.log.err("[dpipe-shell] open slave failed", .{});
            std.process.exit(1);
        }

        const TIOCSCTTY: usize = if (builtin.os.tag == .macos) 0x20007461 else 0x540E;
        _ = std.c.ioctl(slave, TIOCSCTTY, @as(usize, 0));

        _ = dup2(slave, 0);
        _ = dup2(slave, 1);
        _ = dup2(slave, 2);
        _ = close(slave);
        _ = close(master);

        // 禁用 pty 回显（子进程侧）
        if (std.posix.tcgetattr(0)) |t| {
            var t2 = t;
            t2.lflag.ECHO = false;
            std.posix.tcsetattr(0, .NOW, t2) catch {};
        } else |_| {}

        // 使用 $SHELL 或回退到 /bin/sh
        const shell_path: [:0]const u8 = if (std.c.getenv("SHELL")) |sh| blk: {
            const s = std.mem.sliceTo(sh, 0);
            if (s.len > 0) break :blk @as([:0]const u8, @ptrCast(s[0..s.len :0]));
            break :blk "/bin/sh";
        } else "/bin/sh";

        // 数组字面量初始化（哨兵槽自动就位）— 不可用 `= undefined`：哨兵
        // 槽保持垃圾值，execve 的 argv 终止符未定义（Debug 下 sentinel 切片
        // 断言 panic，实测子进程秒退）。作业控制关闭（set +m）在
        // buildCmdWithMarker 的命令前缀完成 — argv +m 会被交互式 shell
        // 初始化强制覆盖（实测 linuxvm 无效）。
        const argv = [_:null]?[*:0]const u8{ shell_path.ptr, "-l" };
        _ = std.c.execve(shell_path.ptr, &argv, std.c.environ);
        std.log.err("[dpipe-shell] execve failed", .{});
        std.process.exit(1);
    }

    // 父进程：禁用 pty 回显（master 侧，Linux 支持）
    if (std.posix.tcgetattr(master)) |t| {
        var t2 = t;
        t2.lflag.ECHO = false;
        std.posix.tcsetattr(master, .NOW, t2) catch {};
    } else |_| {}

    std.log.info("[dpipe-shell] pty spawned: master={d} shell={s} pid={d}", .{ master, shell, pid });
    return ShellCtx{
        .allocator = allocator,
        .master_fd = master,
        .child_pid = pid,
        .shell = try allocator.dupe(u8, shell),
        .stdin_fd = 0,
    };
}

// ── Windows 管道派生 ──────────────────────────────────────────

/// 管道模式：cmd.exe /k（会话保持系统本地 OEM 代码页），
/// OEM↔UTF-8 转码在 readFn/writeFn（见文件头注释）。
fn spawnWindowsPipe(allocator: std.mem.Allocator) !ShellCtx {
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

    // 不设 chcp/SetConsoleCP：会话保持系统本地 OEM 代码页。cmd/系统命令
    // 按 OEM 输出与解读输入，转码统一在 readFn/writeFn（见文件头注释）。
    const cmd_u8 = "cmd.exe /k";
    const cmd_utf16 = try allocator.alloc(u16, cmd_u8.len + 1);
    defer allocator.free(cmd_utf16);
    const end_idx = try std.unicode.utf8ToUtf16Le(cmd_utf16, cmd_u8);
    cmd_utf16[end_idx] = 0;

    if (@intFromEnum(CreateProcessW(null, @as([*:0]u16, @ptrCast(cmd_utf16.ptr)), null, null, @enumFromInt(1), 0, null, null, &si, &pi)) == 0) {
        return error.ProcessCreateFailed;
    }

    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(stdin_read);
    _ = CloseHandle(stdout_write);

    // Job Object（KILL_ON_JOB_CLOSE）：Windows 无进程组，TerminateProcess 只杀
    // cmd.exe 直系，孙进程（ping/python/make）残留 — 断连取消的核心漏洞。
    // Job 内所有后代（cmd 默认不 breakaway）随 TerminateJobObject 整树终止；
    // 句柄关闭（含 utmm 自身崩溃）亦触发全灭。分配失败降级为仅杀 cmd。
    const CreateJobObjectW = @extern(
        *const fn (lpJobAttributes: ?*w.SECURITY_ATTRIBUTES, lpName: ?[*:0]const u16) callconv(.winapi) HANDLE,
        .{ .name = "CreateJobObjectW", .library_name = "kernel32" },
    );
    const SetInformationJobObject = @extern(
        *const fn (hJob: HANDLE, JobObjectInformationClass: DWORD, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL,
        .{ .name = "SetInformationJobObject", .library_name = "kernel32" },
    );
    const AssignProcessToJobObject = @extern(
        *const fn (hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL,
        .{ .name = "AssignProcessToJobObject", .library_name = "kernel32" },
    );
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: DWORD,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: DWORD,
        Affinity: usize,
        PriorityClass: DWORD,
        SchedulingClass: DWORD,
    };
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;
    const JobObjectExtendedLimitInformation: DWORD = 9;

    const INVALID_HANDLE: HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
    var job: HANDLE = INVALID_HANDLE;
    {
        const h = CreateJobObjectW(null, null);
        if (h != INVALID_HANDLE) {
            var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (@intFromEnum(SetInformationJobObject(h, JobObjectExtendedLimitInformation, &info, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))) != 0 and
                @intFromEnum(AssignProcessToJobObject(h, pi.hProcess)) != 0)
            {
                job = h;
            } else {
                _ = CloseHandle(h); // 设置/分配失败 — 降级
            }
        }
    }

    std.log.info("[dpipe-shell] Windows pipe pty: cmd.exe /k (OEM xcode) pid={d} job={}", .{ pi.dwProcessId, job != INVALID_HANDLE });

    return ShellCtx{
        .allocator = allocator,
        .master_fd = stdout_read,
        .child_pid = pi.hProcess,
        .shell = try allocator.dupe(u8, "cmd.exe /k"),
        .stdin_fd = stdin_write,
        .job_handle = job,
    };
}

// ── VTable 实现 ───────────────────────────────────────────────

fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    if (builtin.os.tag == .windows) {
        return xcodeRead(self, buf);
    }
    return ptyRead(self.master_fd, buf);
}

/// Windows 读：拼接上一块遗留的 DBCS 前导字节 → ReadFile → OEM→UTF-8。
/// cmd/系统命令按本地 OEM（GetOEMCP）输出，转成 UTF-8 后 Host 侧 JSON
/// 始终有效（中日韩多语言自动匹配，无需硬编码内码）。
fn xcodeRead(self: *ShellCtx, buf: []u8) !usize {
    // OEM→UTF-8 最大膨胀 1.5×（GBK 2B→3B）：限制原始读取量防 dst 溢出
    const max_raw = @min(buf.len / 3 * 2, buf.len);
    if (max_raw == 0) return 0;

    var raw: [4096]u8 = undefined;
    var prefix: usize = 0;
    if (self.out_pending_len > 0) {
        prefix = @min(self.out_pending_len, @min(raw.len, max_raw));
        @memcpy(raw[0..prefix], self.out_pending[0..prefix]);
        self.out_pending_len = 0;
    }
    const n = try ptyRead(self.master_fd, raw[prefix .. @min(raw.len, prefix + max_raw)]);
    const total = prefix + n;
    if (total == 0) return 0;

    // 尾部 DBCS 前导字节（可能缺尾字节）→ 暂存拼入下一块。
    // 误报无害：完整双字节字符的尾字节被暂存也只是延迟一块转码。
    const consume = total - dbcsPendingLen(raw[0..total]);
    const pending = total - consume;
    if (pending > 0 and pending <= self.out_pending.len) {
        @memcpy(self.out_pending[0..pending], raw[consume..total]);
        self.out_pending_len = pending;
    }
    if (consume == 0) {
        // 单块全是疑似前导字节（4KB 块下实际不可能）。丢弃 pending 防
        // EOF 误判（返回 0 会被调用方当 EOF），下块重新对齐。
        self.out_pending_len = 0;
        std.log.warn("[dpipe-shell] xcode consume=0, dropped {d}B lead bytes", .{pending});
        return ptyReadToUtf8(self, buf);
    }

    return oemToUtf8(buf, raw[0..consume]);
}

/// consume=0 兜底：直接透传一块原始字节转码（不做 pending 处理）。
fn ptyReadToUtf8(self: *ShellCtx, buf: []u8) !usize {
    var raw: [4096]u8 = undefined;
    const max_raw = @min(buf.len / 3 * 2, @min(raw.len, buf.len));
    const n = try ptyRead(self.master_fd, raw[0..max_raw]);
    if (n == 0) return 0;
    return oemToUtf8(buf, raw[0..n]);
}

fn writeFn(ctx: *anyopaque, data: []const u8) anyerror!void {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    if (builtin.os.tag == .windows) {
        return xcodeWrite(self, data);
    }
    return ptyWrite(self, data);
}

/// Windows 写：Host 发来的 UTF-8 → 本地 OEM 后写给 cmd stdin。
/// cmd 管道 stdin 按 OEM 解读输入字节；不转码则 UTF-8 中文直接乱码。
/// 尾部不完整 UTF-8 序列暂存拼入下一块。
fn xcodeWrite(self: *ShellCtx, data: []const u8) !void {
    var pending_buf: [8]u8 = undefined;
    var pending_len: usize = 0;
    if (self.in_pending_len > 0) {
        pending_len = @min(self.in_pending_len, pending_buf.len - self.in_pending_len);
        @memcpy(pending_buf[0..self.in_pending_len], self.in_pending[0..self.in_pending_len]);
        pending_len = self.in_pending_len;
        self.in_pending_len = 0;
    }

    // 拼接 pending + data 后取完整 UTF-8 前缀
    var joined_buf: [8192]u8 = undefined;
    const joined_len = pending_len + @min(data.len, joined_buf.len - pending_len);
    @memcpy(joined_buf[0..pending_len], pending_buf[0..pending_len]);
    @memcpy(joined_buf[pending_len..joined_len], data[0 .. joined_len - pending_len]);

    const complete = completeUtf8Prefix(joined_buf[0..joined_len]);
    const leftover = joined_len - complete;
    if (leftover > 0 and leftover <= self.in_pending.len) {
        @memcpy(self.in_pending[0..leftover], joined_buf[complete..joined_len]);
        self.in_pending_len = leftover;
    }

    var oem_buf: [8192]u8 = undefined;
    const oem_len = utf8ToOem(&oem_buf, joined_buf[0..complete]);
    if (oem_len > 0) {
        try ptyWrite(self, oem_buf[0..oem_len]);
    }
    // data 超出 joined_buf 容量的部分（单次 write >8KB，实际不发生：
    // guest.zig 单次写入整条命令 <4KB）——直接透传 OEM 转码
    if (joined_len < data.len) {
        const rest = data[joined_len - pending_len ..];
        const rest_complete = completeUtf8Prefix(rest);
        var rest_oem: [8192]u8 = undefined;
        const rl = utf8ToOem(&rest_oem, rest[0..rest_complete]);
        if (rl > 0) try ptyWrite(self, rest_oem[0..rl]);
        const rleft = rest.len - rest_complete;
        if (rleft > 0 and rleft <= self.in_pending.len) {
            @memcpy(self.in_pending[0..rleft], rest[rest_complete..]);
            self.in_pending_len = rleft;
        }
    }
}

fn closeFn(ctx: *anyopaque) void {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    if (builtin.os.tag == .windows) {
        killChild(self); // TerminateJobObject 整树 → stdout pipe EOF
        closePtyFd(self.master_fd);
        closePtyFd(self.stdin_fd);
        if (self.job_handle != std.os.windows.INVALID_HANDLE_VALUE) {
            closePtyFd(self.job_handle); // 释放 Job（触发 kill-on-close 兜底）
        }
    } else {
        // 先关 master 再 kill：从属端 read 立即得到 EOF/HUP，shell 干净退出。
        // macOS 实测：SIGKILL 一个阻塞在 slave read 的 shell，进程卡 E 状态
        // ~5s 直到 master 关闭才真正退出（killChild waitpid 轮询白等满）—
        // findings 2026-08-19。先关 master 使收割在 ~100ms 内完成。
        closePtyFd(self.master_fd);
        killChild(self); // 清理残余进程组 + 收割
    }
    self.allocator.free(self.shell);
    self.allocator.destroy(self);
}

const shell_vtable = dpipe.VTable{
    .readFn = readFn,
    .writeFn = writeFn,
    .closeFn = closeFn,
};

// ── Windows OEM↔UTF-8 转码 ────────────────────────────────────



/// DBCS 前导字节范围（GBK/Shift-JIS/EUC-KR 均为 0x81-0xFE）。
/// 块尾字节落在此范围时可能是缺尾字节的双字节字符前导 → 暂存 1 字节。
/// 误报无害：完整双字节字符的尾字节被暂存也只是延迟一块转码。
fn dbcsPendingLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const last = bytes[bytes.len - 1];
    if (last >= 0x81 and last <= 0xFE) return 1;
    return 0;
}

/// 返回 data 头部完整且合法的 UTF-8 序列前缀长度。
/// 尾部不完整/非法序列留给调用方暂存拼入下一块。
fn completeUtf8Prefix(data: []const u8) usize {
    var i: usize = 0;
    while (i < data.len) {
        const n = std.unicode.utf8ByteSequenceLength(data[i]) catch return i;
        if (i + n > data.len) return i;
        _ = std.unicode.utf8Decode(data[i .. i + n]) catch return i;
        i += n;
    }
    return i;
}

/// OEM → UTF-8（经 UTF-16 中转）。返回写入 dst 的字节数；失败时 best-effort
/// 拷贝（MultiByteToWideChar 对无效序列以默认字符替换，不报错）。
fn oemToUtf8(dst: []u8, src: []const u8) usize {
    const w = std.os.windows;
    const MultiByteToWideChar = @extern(
        *const fn (codepage: w.UINT, dwflags: w.DWORD, lpmultibytestr: [*]const u8, cbmultibyte: c_int, lpwidecharstr: [*]u16, cchwidechar: c_int) callconv(.winapi) c_int,
        .{ .name = "MultiByteToWideChar", .library_name = "kernel32" },
    );
    const WideCharToMultiByte = @extern(
        *const fn (codepage: w.UINT, dwflags: w.DWORD, lpwidecharstr: [*]const u16, cchwidechar: c_int, lpmultibytestr: [*]u8, cbmultibyte: c_int, lpdefaultchar: ?[*]const u8, lpuseddefaultchar: ?*w.BOOL) callconv(.winapi) c_int,
        .{ .name = "WideCharToMultiByte", .library_name = "kernel32" },
    );

    var wbuf: [8192]u16 = undefined;
    const wlen = MultiByteToWideChar(1, 0, src.ptr, @intCast(src.len), &wbuf, wbuf.len); // 1 = CP_OEMCP
    if (wlen <= 0) return 0;
    const ulen = WideCharToMultiByte(65001, 0, &wbuf, wlen, dst.ptr, @intCast(dst.len), null, null); // 65001 = CP_UTF8
    return if (ulen > 0) @intCast(ulen) else 0;
}

/// UTF-8 → OEM（经 UTF-16 中转）。返回写入 dst 的字节数。
/// 无法映射的字符（OEM 无对应字形）被默认字符替换。
fn utf8ToOem(dst: []u8, src: []const u8) usize {
    const w = std.os.windows;
    const MultiByteToWideChar = @extern(
        *const fn (codepage: w.UINT, dwflags: w.DWORD, lpmultibytestr: [*]const u8, cbmultibyte: c_int, lpwidecharstr: [*]u16, cchwidechar: c_int) callconv(.winapi) c_int,
        .{ .name = "MultiByteToWideChar", .library_name = "kernel32" },
    );
    const WideCharToMultiByte = @extern(
        *const fn (codepage: w.UINT, dwflags: w.DWORD, lpwidecharstr: [*]const u16, cchwidechar: c_int, lpmultibytestr: [*]u8, cbmultibyte: c_int, lpdefaultchar: ?[*]const u8, lpuseddefaultchar: ?*w.BOOL) callconv(.winapi) c_int,
        .{ .name = "WideCharToMultiByte", .library_name = "kernel32" },
    );

    var wbuf: [8192]u16 = undefined;
    const wlen = MultiByteToWideChar(65001, 0, src.ptr, @intCast(src.len), &wbuf, wbuf.len);
    if (wlen <= 0) return 0;
    const olen = WideCharToMultiByte(1, 0, &wbuf, wlen, dst.ptr, @intCast(dst.len), null, null); // 1 = CP_OEMCP
    return if (olen > 0) @intCast(olen) else 0;
}

// ── 跨平台 PTY I/O ────────────────────────────────────────────

fn ptyWrite(self: *ShellCtx, data: []const u8) error{ WriteFailed, Interrupted }!void {
    if (builtin.os.tag == .windows) {
        const WriteFile = @extern(
            *const fn (std.os.windows.HANDLE, [*]const u8, std.os.windows.DWORD, *std.os.windows.DWORD, ?*anyopaque) callconv(.winapi) std.os.windows.BOOL,
            .{ .name = "WriteFile", .library_name = "kernel32" },
        );
        var written: std.os.windows.DWORD = 0;
        if (@intFromEnum(WriteFile(self.stdin_fd, data.ptr, @intCast(data.len), &written, null)) == 0) {
            return error.WriteFailed;
        }
        if (written < data.len) {
            return error.WriteFailed;
        }
    } else {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = write(self.master_fd, data.ptr + offset, data.len - offset);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }
}

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

fn killChild(self: *ShellCtx) void {
    switch (builtin.os.tag) {
        .windows => {
            // Job Object 整树击杀：cmd.exe + 其全部子进程（ping/python 等）
            const TerminateJobObject = @extern(
                *const fn (std.os.windows.HANDLE, std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL,
                .{ .name = "TerminateJobObject", .library_name = "kernel32" },
            );
            if (self.job_handle != std.os.windows.INVALID_HANDLE_VALUE) {
                _ = TerminateJobObject(self.job_handle, 1);
                return;
            }
            // 降级：Job 未启用（创建失败）— 仅杀 cmd.exe 直系，孙进程残留
            const TerminateProcess = @extern(
                *const fn (std.os.windows.HANDLE, std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
                .{ .name = "TerminateProcess", .library_name = "kernel32" },
            );
            _ = TerminateProcess(self.child_pid, 1);
        },
        .linux, .macos => {
            const pid = self.child_pid;
            // 杀整个进程组 — 子进程 setsid 后是组长（spawnPosix），覆盖命令
            // 派生的孙进程（make/cc/管道链/nohup 型守护）。组长已死或非组长
            // 时 kill(-pid) 失败，回退仅杀本进程。
            if (kill(-pid, SIGKILL) != 0) {
                _ = kill(pid, SIGKILL);
            }
            // 非阻塞等待（5s 超时）— 子进程可能卡在 E（正在退出）状态。
            // waitpid 阻塞 → 主 accept 循环停止 → SOCKS5 握手无响应。
            // 超时后不再等待：子进程已 SIGKILL，OS 最终会回收。
            const WNOHANG: c_int = 1;
            var waited_ms: u32 = 0;
            while (waited_ms < 5000) : (waited_ms += 100) {
                if (std.c.waitpid(pid, null, WNOHANG) != 0) break;
                // 使用原生 nanosleep — dpipe_shell closeFn 没有 Io 参数。
                var req = std.posix.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&req, null);
            }
        },
        else => @compileError("unsupported OS for killChild"),
    }
}

/// 请求异步终止 shell 进程组（exec 断连取消传播用，由 Guest watcher 线程调用）。
/// 线程安全：另一线程阻塞在 read() 时调用安全 —— SIGKILL/TerminateProcess
/// 使阻塞的 pty master / stdout pipe read 返回 EOF/BROKEN_PIPE。
/// 与后续 close() 的 killChild 双重调用无害（kill 对已回收 pid 返回 ESRCH）。
pub fn requestKill(pipe: dpipe.DuplexPipe) void {
    const self: *ShellCtx = @ptrCast(@alignCast(pipe.ctx));
    killChild(self);
}

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

// ── 测试 ──────────────────────────────────────────────────────

const testing = std.testing;

test "dpipe_shell create and close on POSIX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shell_path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";
    const sh = try create(testing.allocator, shell_path);
    defer sh.close();

    // 写入命令
    try sh.write("echo hello_from_test\n");

    // 读取输出（shell 可能输出 prompt + echoed command + actual output）
    // 只验证可以读取到数据，不验证具体内容
    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    var found: bool = false;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const deadline = std.Io.Timestamp.now(io, .awake);
    const timeout_ns: u64 = 2_000_000_000; // 2s

    while (true) {
        const n = sh.read(buf[total..]) catch break;
        if (n == 0) {
            // 短暂等待后重试
            const now = std.Io.Timestamp.now(io, .awake);
            if (now.nanoseconds - deadline.nanoseconds > timeout_ns) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            continue;
        }
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "hello_from_test")) |_| {
            found = true;
            break;
        }
        if (total > 1000) break; // safety limit
    }

    try testing.expect(found);
}

test "dpipe_shell close releases resources" {
    // 验证 create + close 不泄漏、不崩溃
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shell_path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";
    const sh = try create(testing.allocator, shell_path);

    // close 会 kill 子进程、关闭 fd、释放 shell 字符串、释放 ctx
    sh.close();
    // 如果到这里没有 crash/fail，说明资源已正确释放
}

test "requestKill kills process group and unblocks read" {
    // 断连取消传播核心：requestKill 后阻塞的 read 必须在 2s 内返回 EOF/error
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shell_path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";
    const sh = try create(testing.allocator, shell_path);
    defer sh.close();

    // 长命令 — read 将长时间无数据
    try sh.write("sleep 30\n");

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake) catch {};

    // 模拟 Guest watcher 判定断连：请求终止进程组
    requestKill(sh);

    // read 必须在 2s 内返回 EOF(0)/error（SIGKILL → pty master EOF）；
    // 可能先读到 echo/prompt 残留输出，继续读直到 EOF/error 或超时。
    var buf: [256]u8 = undefined;
    const deadline = std.Io.Timestamp.now(io, .awake);
    const timeout_ns: u64 = 2_000_000_000;
    var unblocked = false;
    while (true) {
        const n = sh.read(&buf) catch {
            unblocked = true; // read error 同样是被终止的表现
            break;
        };
        if (n == 0) {
            unblocked = true; // EOF
            break;
        }
        // 有输出（echo/prompt）— 未到 EOF，继续
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds - deadline.nanoseconds > timeout_ns) break; // 超时 → unblocked 保持 false
    }
    try testing.expect(unblocked);
}

// ── Windows 转码纯函数测试（跨平台可测）─────────────────────────

test "dbcsPendingLen: DBCS lead byte at tail" {
    // ASCII 结尾 → 0
    try std.testing.expectEqual(@as(usize, 0), dbcsPendingLen("hello"));
    try std.testing.expectEqual(@as(usize, 0), dbcsPendingLen(""));
    // GBK "以太网" 完整 6 字节 → 尾字节 0xF8 是合法尾字节（0x40-0xFE）→ 误报 1（无害延迟）
    try std.testing.expectEqual(@as(usize, 1), dbcsPendingLen("\xd2\xf4\xcc\xab\xcd\xf8"));
    // 孤立前导字节（真实待拼接场景）→ 1
    try std.testing.expectEqual(@as(usize, 1), dbcsPendingLen("abc\xd2"));
    // 0x80/0xFF 范围外 → 0
    try std.testing.expectEqual(@as(usize, 0), dbcsPendingLen("abc\x80"));
    try std.testing.expectEqual(@as(usize, 0), dbcsPendingLen("abc\xff"));
}

test "completeUtf8Prefix: complete sequences only" {
    // 全部合法
    try std.testing.expectEqual(@as(usize, 6), completeUtf8Prefix("ab\u{4e2d}c"));
    // 尾部不完整序列（"中" 的前 2 字节）→ 前缀停在 2
    try std.testing.expectEqual(@as(usize, 2), completeUtf8Prefix("ab\xe4\xb8"));
    // 非法起始字节 → 前缀停在 0
    try std.testing.expectEqual(@as(usize, 0), completeUtf8Prefix("\xff\xfe"));
    // 合法后接非法
    try std.testing.expectEqual(@as(usize, 2), completeUtf8Prefix("ab\xc3\x28"));
    // 空输入
    try std.testing.expectEqual(@as(usize, 0), completeUtf8Prefix(""));
}
