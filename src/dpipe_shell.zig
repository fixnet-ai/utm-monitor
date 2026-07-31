// dpipe_shell.zig — PTY shell 封装为 DuplexPipe
//
// 提供 create() 工厂函数：创建一个后台 shell 进程，将其 stdin/stdout
// 作为 DuplexPipe 暴露。每条命令使用独立的 shell 实例 — 不支持跨命令
// 共享 shell 状态（cd、export 等不持久）。
//
// POSIX: posix_openpt → fork → setsid → dup2 → exec $SHELL
// Windows: CreatePipe + CreateProcessW("cmd.exe /k chcp 65001 ...")

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

        const argv = [_:null]?[*:0]const u8{ shell_path.ptr, @as(?[*:0]const u8, @ptrFromInt(@intFromPtr("-l"))), null };
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

fn spawnWindows(allocator: std.mem.Allocator) !ShellCtx {
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

    _ = SetConsoleOutputCP(65001);
    _ = SetConsoleCP_ext(65001);

    const cmd_u8 = "cmd.exe /k chcp 65001 >nul & set LANG=en_US.UTF-8";
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

    std.log.info("[dpipe-shell] Windows pipe pty: cmd.exe /k pid={d}", .{pi.dwProcessId});

    return ShellCtx{
        .allocator = allocator,
        .master_fd = stdout_read,
        .child_pid = pi.hProcess,
        .shell = try allocator.dupe(u8, "cmd.exe /k chcp 65001 >nul & set LANG=en_US.UTF-8"),
        .stdin_fd = stdin_write,
    };
}

// ── VTable 实现 ───────────────────────────────────────────────

fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    return ptyRead(self.master_fd, buf);
}

fn writeFn(ctx: *anyopaque, data: []const u8) anyerror!void {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    return ptyWrite(self, data);
}

fn closeFn(ctx: *anyopaque) void {
    const self: *ShellCtx = @ptrCast(@alignCast(ctx));
    killChild(self.child_pid);
    closePtyFd(self.master_fd);
    if (builtin.os.tag == .windows) {
        closePtyFd(self.stdin_fd);
    }
    self.allocator.free(self.shell);
    self.allocator.destroy(self);
}

const shell_vtable = dpipe.VTable{
    .readFn = readFn,
    .writeFn = writeFn,
    .closeFn = closeFn,
};

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
            _ = std.posix.system.waitpid(pid, null, 0);
        },
        else => @compileError("unsupported OS for killChild"),
    }
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
