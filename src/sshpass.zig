// sshpass.zig — Non-interactive SSH authentication via PTY/ConPTY.
//
// 100% CLI-compatible with the original sshpass(1) C utility.
// POSIX: posix_openpt → fork → pselect → prompt-matching → password injection.
// Windows: 交互式桌面会话 → CreatePseudoConsole (ConPTY, requires Windows 10 1809+)；
// Session 0 服务链（无控制台）与老 Windows → SSH_ASKPASS + NUL stdin：
// Win32 OpenSSH read_passphrase 检测到 SSH_ASKPASS 即走 askpass 程序获取密码，
// 完全绕过 TTY/ConPTY（ConPTY 在 Session 0 不可用，Phase 41/45D 实证）。
//
// Usage: utmm sshpass [-p password | -f file | -d fd | -e] [-hV] command [args...]
//
// Examples:
//   utmm sshpass -p '123456' ssh root@192.168.1.1 'ls -la'
//   utmm sshpass -f ~/.ssh/pass ssh user@server 'uptime'
//   utmm sshpass -e ssh admin@host 'cat /proc/cpuinfo'   # reads SSHPASS env var
//
// Windows password auth uses SSH_ASKPASS (no TTY/ConPTY dependency) — works in
// all Windows versions and Session 0 service contexts. conptyAvailable() only
// gates non-ssh interactive commands (ConPTY pty); reported in LSA node_info
// and visible in utmm --status output.

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════
// 退出码（与 C 版 sshpass 完全一致）
// ═══════════════════════════════════════════════════════════════════════════

pub const ExitCode = enum(u8) {
    no_error = 0,
    invalid_args = 1,
    conflicting_args = 2,
    runtime_error = 3,
    parse_error = 4,
    incorrect_password = 5,
    host_key_unknown = 6,
    host_key_changed = 7, // 预留，C 版定义但未使用
    _,
};

// ═══════════════════════════════════════════════════════════════════════════
// 密码源类型
// ═══════════════════════════════════════════════════════════════════════════

const PwType = enum {
    stdin_source,
    file,
    fd,
    pass,
};

const PwSource = union {
    filename: []const u8,
    fd: std.posix.fd_t,
    password: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// 参数
// ═══════════════════════════════════════════════════════════════════════════

const SshpassArgs = struct {
    pwtype: PwType = .stdin_source,
    pwsrc: PwSource = .{ .fd = undefined }, // overwritten by parseArgs before use
};

// ═══════════════════════════════════════════════════════════════════════════
// 跨平台 stdout/stderr 写入
// ═══════════════════════════════════════════════════════════════════════════

fn writeStdout(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const stdout_handle = std.os.windows.peb().ProcessParameters.hStdOutput;
        var written: windows.DWORD = 0;
        _ = windows.WriteFile(stdout_handle, msg.ptr, @intCast(msg.len), &written, null);
    } else {
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

fn writeStderr(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const stderr_handle = std.os.windows.peb().ProcessParameters.hStdError;
        var written: windows.DWORD = 0;
        _ = windows.WriteFile(stderr_handle, msg.ptr, @intCast(msg.len), &written, null);
    } else {
        _ = std.c.write(2, msg.ptr, msg.len);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// 帮助
// ═══════════════════════════════════════════════════════════════════════════

fn showHelp() void {
    writeStdout(
        \\Usage: utmm sshpass [-f|-d|-p|-e] [-hV] command parameters
        \\   -f filename   Take password to use from file
        \\   -d number     Use number as file descriptor for getting password
        \\   -p password   Provide password as argument (security unwise)
        \\   -e            Password is passed as env-var "SSHPASS"
        \\   With no parameters - password will be taken from stdin
        \\
        \\   -h            Show help (this screen)
        \\   -V            Print version information
        \\At most one of -f, -d, -p or -e should be used
        \\
    );
}

fn showVersion() void {
    const version = @import("protocol.zig").VERSION;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "utmm-sshpass v{s}\n", .{version}) catch return;
    writeStdout(msg);
}

// ═══════════════════════════════════════════════════════════════════════════
// 参数解析 — 模拟 getopt("+f:d:p:heV")，100% 复刻 C 版 parse_options()
// ═══════════════════════════════════════════════════════════════════════════

fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) !struct { args: SshpassArgs, cmd_offset: usize } {
    var result = SshpassArgs{};
    // 函数级 errdefer：跟踪 -p dupe 的内存，任何后续错误返回（NoCommand 等）
    // 都释放它。块内 errdefer 在 case 块结束时即失效，无法覆盖块外错误返回。
    var duped_pass: ?[]u8 = null;
    errdefer if (duped_pass) |d| gpa.free(d);
    var i: usize = 0;

    while (i < argv.len) {
        const arg = argv[i];

        // 第一个不以 '-' 开头的参数 = 命令开始（getopt '+' 模式）
        if (arg.len == 0 or arg[0] != '-') break;

        if (arg.len == 1) break; // 裸 '-' 不作为选项

        const opt = arg[1]; // 跳过 '-'，仅处理单字符选项

        switch (opt) {
            'f' => {
                if (result.pwtype != .stdin_source) {
                    writeStderr("Conflicting password source\n");
                    return error.ConflictingArgs;
                }
                if (i + 1 >= argv.len) return error.MissingArg;
                i += 1;
                result.pwtype = .file;
                result.pwsrc = .{ .filename = try gpa.dupe(u8, argv[i]) };
            },
            'd' => {
                if (result.pwtype != .stdin_source) {
                    writeStderr("Conflicting password source\n");
                    return error.ConflictingArgs;
                }
                if (i + 1 >= argv.len) return error.MissingArg;
                i += 1;
                const fd_num = if (builtin.os.tag == .windows)
                    @as(std.posix.fd_t, @ptrFromInt(std.fmt.parseInt(std.os.windows.DWORD, argv[i], 10) catch {
                        writeStderr("sshpass: invalid file descriptor number\n");
                        return error.InvalidArgs;
                    }))
                else std.fmt.parseInt(std.posix.fd_t, argv[i], 10) catch {
                    writeStderr("sshpass: invalid file descriptor number\n");
                    return error.InvalidArgs;
                };
                result.pwtype = .fd;
                result.pwsrc = .{ .fd = fd_num };
            },
            'p' => {
                if (result.pwtype != .stdin_source) {
                    writeStderr("Conflicting password source\n");
                    return error.ConflictingArgs;
                }
                if (i + 1 >= argv.len) return error.MissingArg;
                i += 1;
                result.pwtype = .pass;
                // 必须 dupe：main() 里密码隐藏会 @memset(argv[密码], 'z') 覆写原
                // argv 内存，若 password 直接引用 argv，提取时读到的是被覆写的 "zzz"。
                // C 版先 strdup 再覆写 argv，此处同理。
                duped_pass = try gpa.dupe(u8, argv[i]);
                result.pwsrc = .{ .password = duped_pass.? };
            },
            'e' => {
                if (result.pwtype != .stdin_source) {
                    writeStderr("Conflicting password source\n");
                    return error.ConflictingArgs;
                }
                const env_pw = std.c.getenv("SSHPASS");
                if (env_pw == null) {
                    writeStderr("sshpass: -e option given but SSHPASS environment variable not set\n");
                    return error.InvalidArgs;
                }
                result.pwtype = .pass;
                result.pwsrc = .{ .password = try gpa.dupe(u8, std.mem.sliceTo(env_pw.?, 0)) };
            },
            'h' => {
                showHelp();
                return error.HelpShown;
            },
            'V' => {
                showVersion();
                return error.VersionShown;
            },
            '-' => {
                // 长选项 "--"，跳过并停止解析
                return .{ .args = result, .cmd_offset = i + 1 };
            },
            else => {
                // 未知选项 → 错误，但不退出（让调用者决定）
                return error.InvalidArgs;
            },
        }
        i += 1;
    }

    if (i >= argv.len) {
        return error.NoCommand;
    }

    return .{ .args = result, .cmd_offset = i };
}

// ═══════════════════════════════════════════════════════════════════════════
// 提示匹配状态机（与 C 版算法完全一致）
// ═══════════════════════════════════════════════════════════════════════════

/// 逐字符状态机：在 buffer 中的字符与 reference 之间进行匹配。
/// 返回新的匹配状态（在 reference 中匹配到的位置）。
fn patternMatch(reference: []const u8, buffer: []const u8, state: usize) usize {
    var s = state;
    for (buffer) |byte| {
        if (reference[s] == byte) {
            s += 1;
            if (s >= reference.len) break;
        } else {
            s = 0;
            if (reference[s] == byte) s += 1;
        }
    }
    return s;
}

const PromptPatterns = struct {
    const compare1 = "assword:"; // 经典 SSH 密码提示 "Password:" / "password:"
    const compare2 = "The authenticity of host "; // 未知主机密钥
    const compare3 = "assword for "; // OpenPAM 风格 "password for user@host:"
    const compare4 = "Verification code:"; // Google Authenticator TOTP
};

// ═══════════════════════════════════════════════════════════════════════════
// 密码写入
// ═══════════════════════════════════════════════════════════════════════════

/// 从 srcfd 逐字节复制到 dstfd，遇到 '\n' 停止，然后在 dstfd 写入 '\n'。
fn writePassFd(dstfd: anytype, srcfd: anytype, readFn: anytype, writeFn: anytype) void {
    var done = false;
    var buf: [40]u8 = undefined;

    while (!done) {
        const numread = readFn(srcfd, &buf);
        if (numread < 1) done = true;
        var j: usize = 0;
        while (j < @as(usize, @intCast(numread)) and !done) : (j += 1) {
            if (buf[j] != '\n') {
                _ = writeFn(dstfd, buf[j .. j + 1]);
            } else {
                done = true;
            }
        }
    }
    _ = writeFn(dstfd, "\n");
}

// ═══════════════════════════════════════════════════════════════════════════
// POSIX 实现
// ═══════════════════════════════════════════════════════════════════════════

const is_posix = builtin.os.tag != .windows;

const posix = if (is_posix) struct {
    // ── C externs ──
    extern "c" fn posix_openpt(flags: u32) std.posix.fd_t;
    extern "c" fn grantpt(fd: std.posix.fd_t) c_int;
    extern "c" fn unlockpt(fd: std.posix.fd_t) c_int;
    extern "c" fn ptsname(fd: std.posix.fd_t) ?[*:0]u8;
    extern "c" fn fork() std.posix.pid_t;
    extern "c" fn setsid() std.posix.pid_t;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: u32, mode: u32) std.posix.fd_t;
    extern "c" fn close(fd: std.posix.fd_t) c_int;
    extern "c" fn dup2(old: std.posix.fd_t, new: std.posix.fd_t) std.posix.fd_t;
    extern "c" fn read(fd: std.posix.fd_t, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, count: usize) isize;
    extern "c" fn kill(pid: std.posix.pid_t, sig: c_int) c_int;
    extern "c" fn waitpid(pid: std.posix.pid_t, stat_loc: *c_int, options: c_int) std.posix.pid_t;
    extern "c" fn pselect(
        nfds: c_int,
        readfds: ?*FdSet,
        writefds: ?*FdSet,
        errorfds: ?*FdSet,
        timeout: ?*Timespec,
        sigmask: ?*Sigset,
    ) c_int;

    extern "c" fn fcntl(fd: std.posix.fd_t, cmd: c_int, flags: c_int) c_int;
    extern "c" fn ioctl(fd: std.posix.fd_t, request: c_ulong, argp: *anyopaque) c_int;
    extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
    extern "c" fn sigemptyset(set: *Sigset) c_int;
    extern "c" fn sigaddset(set: *Sigset, sig: c_int) c_int;
    extern "c" fn sigprocmask(how: c_int, set: ?*const Sigset, oset: ?*Sigset) c_int;
    extern "c" fn perror(s: [*:0]const u8) void;

    // ── 类型 ──
    const FdSet = extern struct {
        fds_bits: [32]c_int, // 1024 bits / 32 bits
    };

    const Timespec = extern struct {
        tv_sec: isize,
        tv_nsec: isize,
    };

    const Sigset = extern struct {
        __val: [16]c_uint,
    };

    // ── 常量（使用 Zig 内置 c_int / c_ulong 类型）──
    const O_RDWR: u32 = 2;
    const O_NOCTTY: u32 = if (builtin.os.tag == .macos) 0x20000 else 0x100;
    const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 4 else 2048;
    const F_SETFL: c_int = 4;
    const SIGCHLD: c_int = if (builtin.os.tag == .macos) 20 else 17;
    const SIGWINCH: c_int = if (builtin.os.tag == .macos) 28 else 28;
    const WNOHANG: c_int = 1;
    const SIG_SETMASK: c_int = 3;

    const TIOCGWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x40087468 else 0x5413;
    const TIOCSWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else 0x5414;

    const Winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    const c = @This();

    // ── 全局变量（信号处理器共享）──
    var global_masterpt: std.posix.fd_t = -1;
    var global_ourtty: std.posix.fd_t = -1;

    fn FD_ZERO(set: *FdSet) void {
        @memset(std.mem.asBytes(set), 0);
    }

    fn FD_SET(fd: std.posix.fd_t, set: *FdSet) void {
        const byte_idx = @as(usize, @intCast(fd)) / (@bitSizeOf(c_int));
        const bit_idx = @as(u5, @intCast(@as(usize, @intCast(fd)) % @bitSizeOf(c_int)));
        set.fds_bits[byte_idx] |= @as(c_int, 1) << bit_idx;
    }

    fn FD_ISSET(fd: std.posix.fd_t, set: *FdSet) bool {
        const byte_idx = @as(usize, @intCast(fd)) / (@bitSizeOf(c_int));
        const bit_idx = @as(u5, @intCast(@as(usize, @intCast(fd)) % @bitSizeOf(c_int)));
        return (set.fds_bits[byte_idx] & (@as(c_int, 1) << bit_idx)) != 0;
    }

    // ── 信号处理器 ──
    fn windowResizeHandler(signum: c_int) callconv(.c) void {
        _ = signum;
        var ttysize: Winsize = undefined;
        if (ioctl(global_ourtty, TIOCGWINSZ, @ptrCast(&ttysize)) == 0) {
            _ = ioctl(global_masterpt, TIOCSWINSZ, @ptrCast(&ttysize));
        }
    }

    fn sigchldHandler(signum: c_int) callconv(.c) void {
        _ = signum;
        // 空处理器 — 仅用于中断 pselect
    }

    // ── runPosix — 复刻 C 版 runprogram() ──

    fn runPosix(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        // 注册 SIGCHLD 处理器（用于中断 pselect）
        _ = signal(SIGCHLD, sigchldHandler);

        // 打开 PTY 主端
        const masterpt = posix_openpt(O_RDWR);
        if (masterpt == -1) {
            perror("Failed to get a pseudo terminal");
            return .runtime_error;
        }
        global_masterpt = masterpt;

        // 设置非阻塞
        _ = fcntl(masterpt, F_SETFL, O_NONBLOCK);

        if (grantpt(masterpt) != 0) {
            perror("Failed to change pseudo terminal's permission");
            return .runtime_error;
        }
        if (unlockpt(masterpt) != 0) {
            perror("Failed to unlock pseudo terminal");
            return .runtime_error;
        }

        // 获取当前 TTY 大小并转发到 PTY
        const ourtty = open("/dev/tty", 0, 0);
        global_ourtty = ourtty;
        if (ourtty != -1) {
            var ttysize: Winsize = undefined;
            if (ioctl(ourtty, TIOCGWINSZ, @ptrCast(&ttysize)) == 0) {
                _ = signal(SIGWINCH, windowResizeHandler);
                _ = ioctl(masterpt, TIOCSWINSZ, @ptrCast(&ttysize));
            }
        }

        const slave_name_raw = ptsname(masterpt);
        if (slave_name_raw == null) {
            perror("Failed to get slave pty name");
            return .runtime_error;
        }
        const slave_name = std.mem.span(slave_name_raw.?);

        // Fork
        const childpid = fork();
        if (childpid == 0) {
            // ── 子进程 ──
            _ = setsid();

            const slavept = open(slave_name, O_RDWR, 0);
            _ = close(slavept); // close slave — PTY 仍作为控制终端工作
            _ = close(masterpt);

            // 构建 argv（需要 null 终止的指针数组）
            const new_argv = allocator.allocSentinel(?[*:0]const u8, cmd_args.len, null) catch {
                _ = perror("sshpass: out of memory");
                std.process.exit(@intFromEnum(ExitCode.runtime_error));
            };
            defer allocator.free(new_argv);

            for (cmd_args, 0..) |carg, idx| {
                new_argv[idx] = @ptrCast(carg.ptr);
            }

            _ = execvp(@ptrCast(cmd_args[0].ptr), @ptrCast(new_argv.ptr));

            perror("sshpass: Failed to run command");
            std.process.exit(@intFromEnum(ExitCode.runtime_error));
        } else if (childpid < 0) {
            perror("sshpass: Failed to create child process");
            return .runtime_error;
        }

        // ── 父进程 ──
        // 打开 slave 端（保持到握手完成 — Linux 内核 bug workaround）
        const slavept = open(slave_name, O_RDWR | O_NOCTTY, 0);

        var sigmask: Sigset = undefined;
        var sigmask_select: Sigset = undefined;

        _ = sigemptyset(&sigmask_select);
        _ = sigemptyset(&sigmask);
        _ = sigaddset(&sigmask, SIGCHLD);
        _ = sigprocmask(SIG_SETMASK, &sigmask, null);

        // handleoutput 使用的状态
        var prevmatch: bool = false;
        var state1: usize = 0; // "assword:"
        var state2: usize = 0; // "The authenticity of host "
        var state3: usize = 0; // "assword for "
        var state4: usize = 0; // "Verification code:"
        var terminate: i32 = 0;

        var status: c_int = 0;
        var wait_ret: std.posix.pid_t = undefined;

        while (true) {
            if (terminate == 0) {
                var readfd: FdSet = undefined;
                FD_ZERO(&readfd);
                FD_SET(masterpt, &readfd);

                const selret = pselect(
                    @intCast(masterpt + 1),
                    &readfd,
                    null,
                    null,
                    null,
                    &sigmask_select,
                );

                if (selret > 0) {
                    if (FD_ISSET(masterpt, &readfd)) {
                        const ret = handleoutputPosix(
                            masterpt,
                            sp_args,
                            &prevmatch,
                            &state1,
                            &state2,
                            &state3,
                            &state4,
                        );
                        if (ret != 0) {
                            if (ret > 0) {
                                _ = posix.c.close(masterpt); // 向 ssh 通知控制终端已关闭
                                _ = posix.c.close(slavept);
                            }
                            terminate = ret;
                            if (terminate != 0) {
                                _ = posix.c.close(slavept);
                            }
                        }
                    }
                }
                wait_ret = waitpid(childpid, &status, WNOHANG);
            } else {
                wait_ret = waitpid(childpid, &status, 0);
            }

            if (wait_ret == 0 or wait_ret == childpid) {
                // 检查子进程是否已退出
                if (wait_ret == childpid) {
                    if (WIFEXITED(status) or WIFSIGNALED(status)) break;
                }
            } else {
                break;
            }
        }

        if (terminate > 0) {
            return @enumFromInt(@as(u8, @intCast(terminate)));
        } else if (WIFEXITED(status)) {
            return @enumFromInt(WEXITSTATUS(status));
        } else {
            return @enumFromInt(@as(u8, 255));
        }
    }

    fn WIFEXITED(status: c_int) bool {
        return ((status) & 0x7f) == 0;
    }

    fn WIFSIGNALED(status: c_int) bool {
        return (@as(c_int, @intCast((@as(c_uint, @bitCast(status)) & 0x7f) + 1)) >> 1) > 0;
    }

    fn WEXITSTATUS(status: c_int) u8 {
        return @intCast((status >> 8) & 0xff);
    }

    // ── handleoutput — 复刻 C 版 handleoutput() ──

    fn handleoutputPosix(
        fd: std.posix.fd_t,
        sp_args: SshpassArgs,
        prevmatch: *bool,
        state1: *usize,
        state2: *usize,
        state3: *usize,
        state4: *usize,
    ) i32 {
        var buf: [40]u8 = undefined;
        const numread = read(fd, &buf, buf.len);
        const data = buf[0..@intCast(if (numread > 0) numread else 0)];

        var ret: i32 = 0;

        // 匹配 "assword:"
        state1.* = patternMatch(PromptPatterns.compare1, data, state1.*);
        if (PromptPatterns.compare1.len > 0 and state1.* >= PromptPatterns.compare1.len) {
            if (!prevmatch.*) {
                writePassPosix(fd, sp_args);
                state1.* = 0;
                prevmatch.* = true;
            } else {
                ret = @intFromEnum(ExitCode.incorrect_password);
            }
        }

        // 匹配 "assword for "（OpenPAM）
        if (ret == 0) {
            state3.* = patternMatch(PromptPatterns.compare3, data, state3.*);
            if (state3.* >= PromptPatterns.compare3.len) {
                if (!prevmatch.*) {
                    writePassPosix(fd, sp_args);
                    state3.* = 0;
                    prevmatch.* = true;
                } else {
                    ret = @intFromEnum(ExitCode.incorrect_password);
                }
            }
        }

        // 匹配 "Verification code:"（TOTP）
        if (ret == 0) {
            state4.* = patternMatch(PromptPatterns.compare4, data, state4.*);
            if (state4.* >= PromptPatterns.compare4.len) {
                if (!prevmatch.*) {
                    writePassPosix(fd, sp_args);
                    state4.* = 0;
                    prevmatch.* = true;
                } else {
                    ret = @intFromEnum(ExitCode.incorrect_password);
                }
            }
        }

        // 匹配 "The authenticity of host "（未知主机密钥）
        if (ret == 0) {
            state2.* = patternMatch(PromptPatterns.compare2, data, state2.*);
            if (state2.* >= PromptPatterns.compare2.len) {
                ret = @intFromEnum(ExitCode.host_key_unknown);
            }
        }

        return ret;
    }

    fn writePassPosix(dst_fd: std.posix.fd_t, sp_args: SshpassArgs) void {
        switch (sp_args.pwtype) {
            .stdin_source => writePassFd(dst_fd, 0, struct {
                fn readFn(f: std.posix.fd_t, b: []u8) isize {
                    return read(f, b.ptr, b.len);
                }
            }.readFn, struct {
                fn writeFn(f: std.posix.fd_t, b: []const u8) isize {
                    return write(f, b.ptr, b.len);
                }
            }.writeFn),
            .fd => writePassFd(dst_fd, sp_args.pwsrc.fd, struct {
                fn readFn(f: std.posix.fd_t, b: []u8) isize {
                    return read(f, b.ptr, b.len);
                }
            }.readFn, struct {
                fn writeFn(f: std.posix.fd_t, b: []const u8) isize {
                    return write(f, b.ptr, b.len);
                }
            }.writeFn),
            .file => {
                const srcfd = open(@ptrCast(sp_args.pwsrc.filename.ptr), 0, 0);
                if (srcfd != -1) {
                    writePassFd(dst_fd, srcfd, struct {
                        fn readFn(f: std.posix.fd_t, b: []u8) isize {
                            return read(f, b.ptr, b.len);
                        }
                    }.readFn, struct {
                        fn writeFn(f: std.posix.fd_t, b: []const u8) isize {
                            return write(f, b.ptr, b.len);
                        }
                    }.writeFn);
                    _ = close(srcfd);
                }
            },
            .pass => {
                _ = write(dst_fd, sp_args.pwsrc.password.ptr, sp_args.pwsrc.password.len);
                _ = write(dst_fd, "\n", 1);
            },
        }
    }
} else struct {}; // Windows: no posix namespace

// ═══════════════════════════════════════════════════════════════════════════
// Windows 实现（SSH_ASKPASS 主路径 / ConPTY 交互辅助）
// ═══════════════════════════════════════════════════════════════════════════
//
// ssh 命令（sshpass 核心场景）永远走 SSH_ASKPASS：设 SSH_ASKPASS/SSHPASS 环境
// 变量指向固定 askpass.bat，spawn ssh.exe 时 stdin 重定向 NUL（立即 EOF）。
// Win32 OpenSSH read_passphrase 检测到 SSH_ASKPASS 即走 askpass 程序读密码，
// 完全绕过 TTY/ConPTY——在 Session 0 服务链与所有 Windows 版本都可用。
// （管道注入对 ssh 无效：ssh 非 TTY 时用 _getch() 读控制台而非 stdin，Phase 45D 实证。）
//
// 非 ssh 交互命令：有控制台 + ConPTY 可用 → runWindowsConpty（CreatePseudoConsole，
// 交互式提示）；否则 → runWindowsAskpass（通用管道透传）。
// ConPTY 可用性通过 LoadLibraryA/GetProcAddress 运行时检测，避免 @extern 在
// 老版本 Windows 上导致 DLL 加载失败。

const windows = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;

    const HANDLE = w.HANDLE;
    const BOOL = w.BOOL;
    const DWORD = w.DWORD;
    const LPVOID = w.LPVOID;
    const LPWSTR = w.LPWSTR;
    const HRESULT = i32; // std.os.windows.HRESULT removed in Zig 0.16.0
    const COORD = extern struct { X: i16, Y: i16 };

    // kernel32 externs
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
    const ReadFile = @extern(
        *const fn (hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL,
        .{ .name = "ReadFile", .library_name = "kernel32" },
    );
    const WriteFile = @extern(
        *const fn (hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL,
        .{ .name = "WriteFile", .library_name = "kernel32" },
    );
    const CreateProcessW = @extern(
        *const fn (lpApplicationName: ?[*:0]const u16, lpCommandLine: [*:0]u16, lpProcessAttributes: ?*w.SECURITY_ATTRIBUTES, lpThreadAttributes: ?*w.SECURITY_ATTRIBUTES, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?LPVOID, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *w.STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) BOOL,
        .{ .name = "CreateProcessW", .library_name = "kernel32" },
    );

    // ── ConPTY 函数指针类型（运行时动态解析，老版本 Windows 不可用）──
    const ConptyCreateFn = *const fn (size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HANDLE) callconv(.winapi) HRESULT;
    const ConptyCloseFn = *const fn (hPC: HANDLE) callconv(.winapi) void;

    // ── kernel32 动态加载支持 ──
    const LoadLibraryA = @extern(
        *const fn (lpLibFileName: [*:0]const u8) callconv(.winapi) ?std.os.windows.HMODULE,
        .{ .name = "LoadLibraryA", .library_name = "kernel32" },
    );
    const GetProcAddress = @extern(
        *const fn (hModule: std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque,
        .{ .name = "GetProcAddress", .library_name = "kernel32" },
    );

    /// 运行时检测 ConPTY 是否可用。
    /// Windows 10 1809 (build 17763) 之前 CreatePseudoConsole 不存在于 kernel32.dll。
    var conpty_checked: bool = false;
    var conpty_create: ?ConptyCreateFn = null;
    var conpty_close: ?ConptyCloseFn = null;

    fn resolveConpty() void {
        if (conpty_checked) return;
        conpty_checked = true;
        const h = LoadLibraryA("kernel32.dll") orelse return;
        conpty_create = @ptrCast(@alignCast(GetProcAddress(h, "CreatePseudoConsole")));
        conpty_close = @ptrCast(@alignCast(GetProcAddress(h, "ClosePseudoConsole")));
    }

    /// Guest 检测：ConPTY 是否可用（供 LSA node_info 上报）。
    pub fn conptyAvailable() bool {
        resolveConpty();
        return conpty_create != null and conpty_close != null;
    }

    /// dpipe_shell 复用：创建 ConPTY。返回 false = ConPTY 不可用（< Win10 1809）
    /// 或创建失败。hInput/hOutput 为喂给 ConPTY 的管道读/写端（所有权移交 ConPTY）。
    pub fn pseudoConsoleCreate(size_x: i16, size_y: i16, hInput: HANDLE, hOutput: HANDLE, phPC: *HANDLE) bool {
        resolveConpty();
        const create = conpty_create orelse return false;
        return create(.{ .X = size_x, .Y = size_y }, hInput, hOutput, 0, phPC) == 0;
    }

    /// dpipe_shell 复用：关闭 ConPTY。
    pub fn pseudoConsoleClose(hPC: HANDLE) void {
        resolveConpty();
        if (conpty_close) |f| f(hPC);
    }
    const GetExitCodeProcess = @extern(
        *const fn (hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL,
        .{ .name = "GetExitCodeProcess", .library_name = "kernel32" },
    );
    const WaitForSingleObject = @extern(
        *const fn (hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD,
        .{ .name = "WaitForSingleObject", .library_name = "kernel32" },
    );
    const GetLastError = @extern(
        *const fn () callconv(.winapi) DWORD,
        .{ .name = "GetLastError", .library_name = "kernel32" },
    );
    const TerminateProcess = @extern(
        *const fn (hProcess: HANDLE, uExitCode: w.UINT) callconv(.winapi) BOOL,
        .{ .name = "TerminateProcess", .library_name = "kernel32" },
    );
    const GetStdHandle = @extern(
        *const fn (nStdHandle: DWORD) callconv(.winapi) ?HANDLE,
        .{ .name = "GetStdHandle", .library_name = "kernel32" },
    );

    // ── SSH_ASKPASS 模式所需（Session 0 服务链 / 老 Windows）──
    const GetConsoleWindow = @extern(
        *const fn () callconv(.winapi) ?HANDLE,
        .{ .name = "GetConsoleWindow", .library_name = "kernel32" },
    );
    const SetEnvironmentVariableW = @extern(
        *const fn (lpName: [*:0]const u16, lpValue: [*:0]const u16) callconv(.winapi) BOOL,
        .{ .name = "SetEnvironmentVariableW", .library_name = "kernel32" },
    );
    const CreateFileW = @extern(
        *const fn (lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*w.SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE,
        .{ .name = "CreateFileW", .library_name = "kernel32" },
    );

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_SHARE_READ: DWORD = 1;
    const OPEN_EXISTING: DWORD = 3;
    const CREATE_ALWAYS: DWORD = 2;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: DWORD,
        dwThreadId: DWORD,
    };

    /// ConPTY 附加需要扩展 STARTUPINFO：cb 必须 = sizeof(STARTUPINFOEXW)，
    /// lpAttributeList 指向已初始化的 proc-thread attribute list。
    /// Zig 0.16 std.os.windows 无此类型，自定义（StartupInfo 104B + 8B 指针 = 112B，
    /// 64 位下对齐 8；Phase 41 实测布局 104/112 正确）。
    const STARTUPINFOEXW = extern struct {
        StartupInfo: w.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };

    const HANDLE_FLAG_INHERIT: DWORD = 1;
    const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
    const STD_INPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(c_long, -10)));
    const STD_OUTPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(c_long, -11)));
    const INFINITE: DWORD = 0xFFFFFFFF;
    const WAIT_OBJECT_0: DWORD = 0;
    const PSEUDOCONSOLE_INHERIT_CURSOR: DWORD = 1;

    const c = @This();

    /// 构建 Windows 命令行 UTF-16 字符串（所有参数空格连接，含引号处理）。
    /// 调用者拥有返回的 cmd_utf16（需 defer allocator.free）。
    fn buildCmdLine(allocator: std.mem.Allocator, cmd_args: []const []const u8) ![]u16 {
        var cmdline_buf: std.ArrayList(u8) = .empty;
        defer cmdline_buf.deinit(allocator);
        for (cmd_args, 0..) |carg, idx| {
            if (idx > 0) try cmdline_buf.append(allocator, ' ');
            const needs_quote = std.mem.indexOfAny(u8, carg, " \t") != null;
            if (needs_quote) try cmdline_buf.append(allocator, '"');
            try cmdline_buf.appendSlice(allocator, carg);
            if (needs_quote) try cmdline_buf.append(allocator, '"');
        }
        try cmdline_buf.append(allocator, 0);

        const cmd_u8 = cmdline_buf.items;
        const cmd_utf16 = try allocator.alloc(u16, cmd_u8.len);
        errdefer allocator.free(cmd_utf16);
        const utf16_len = try std.unicode.utf8ToUtf16Le(cmd_utf16, cmd_u8[0 .. cmd_u8.len - 1]);
        cmd_utf16[utf16_len] = 0;
        return cmd_utf16;
    }

    /// 当前进程是否有交互控制台。
    /// Session 0 服务进程（utmmd / utmm 服务）无控制台 → GetConsoleWindow() == null。
    /// ConPTY 在 Session 0 不可用（Phase 41/45D 实证：CreatePseudoConsole 成功但
    /// 零输出/阻塞），必须走 SSH_ASKPASS。
    fn hasConsole() bool {
        return GetConsoleWindow() != null;
    }

    /// UTF-8 → UTF-16LE 以 null 结尾（返回 len+1 的 slice，调用者 free）。
    fn toUtf16Z(gpa: std.mem.Allocator, s: []const u8) ![]u16 {
        const buf = try gpa.alloc(u16, s.len + 1);
        errdefer gpa.free(buf);
        const len = try std.unicode.utf8ToUtf16Le(buf[0..s.len], s);
        buf[len] = 0;
        return buf;
    }

    /// 从 SshpassArgs 提取单行密码（UTF-8，去掉尾部 CR/LF）。
    /// -p → 直接截断；-f/-d/stdin → 读内容后截断到首个换行。
    fn extractPasswordWindows(sp_args: *const SshpassArgs, buf: []u8) ?[]const u8 {
        switch (sp_args.pwtype) {
            .pass => {
                return std.mem.trimEnd(u8, std.mem.sliceTo(sp_args.pwsrc.password, '\n'), "\r\n");
            },
            .file => {
                const fname_u16 = toUtf16Z(std.heap.page_allocator, sp_args.pwsrc.filename) catch return null;
                defer std.heap.page_allocator.free(fname_u16);
                const fh = CreateFileW(
                    @ptrCast(fname_u16.ptr),
                    GENERIC_READ,
                    FILE_SHARE_READ,
                    null,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (fh == w.INVALID_HANDLE_VALUE) return null;
                defer _ = CloseHandle(fh);
                return readPasswordHandle(fh, buf);
            },
            .stdin_source => {
                const sh = GetStdHandle(STD_INPUT_HANDLE) orelse return null;
                return readPasswordHandle(sh, buf);
            },
            .fd => {
                const sh = GetStdHandle(@intCast(@intFromPtr(sp_args.pwsrc.fd))) orelse return null;
                return readPasswordHandle(sh, buf);
            },
        }
    }

    fn readPasswordHandle(handle: HANDLE, buf: []u8) ?[]const u8 {
        var n: DWORD = 0;
        if (@intFromEnum(ReadFile(handle, buf.ptr, @intCast(buf.len), &n, null)) == 0) return null;
        return std.mem.trimEnd(u8, buf[0..@intCast(n)], "\r\n");
    }

    /// 确保 C:\opt\utmm\askpass.bat 存在（@echo off + echo %SSHPASS%）。
    /// SSH_ASKPASS 指向它：ssh.exe spawn 它时输出密码（密码经 SSHPASS 环境变量传入）。
    /// 输出 "111\r\n"，Win32 OpenSSH ssh_askpass 去 CRLF 后作为密码。
    /// 注意：密码不得含 cmd 元字符（& | < > ^），否则 echo %SSHPASS% 展开出错。
    fn ensureAskpassBat() bool {
        const path_u16 = toUtf16Z(std.heap.page_allocator, "C:\\opt\\utmm\\askpass.bat") catch return false;
        defer std.heap.page_allocator.free(path_u16);
        const handle = CreateFileW(
            @ptrCast(path_u16.ptr),
            GENERIC_WRITE,
            FILE_SHARE_READ,
            null,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == w.INVALID_HANDLE_VALUE) return false;
        defer _ = CloseHandle(handle);

        const content = "@echo off\r\necho %SSHPASS%\r\n";
        var written: DWORD = 0;
        return @intFromEnum(WriteFile(handle, content.ptr, @intCast(content.len), &written, null)) != 0;
    }

    /// SSH_ASKPASS 模式（Session 0 服务链 / 老 Windows，所有 Windows 版本可用）。
    /// 原理：Win32 OpenSSH read_passphrase 检测到 SSH_ASKPASS 即走 ssh_askpass 程序
    /// （CreatePipe + CreateProcess + ReadFile 读密码），完全绕过 TTY/ConPTY。
    /// 密码经 SSHPASS 环境变量传入；ssh.exe stdin 用 NUL（立即 EOF）根治
    /// Win32-OpenSSH "认证成功 + 命令完成后退出挂起"（issue #1769/#1427）。
    fn runWindowsAskpass(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        const cmd_utf16 = buildCmdLine(allocator, cmd_args) catch return .runtime_error;
        defer allocator.free(cmd_utf16);

        // 提取密码（UTF-8 单行）
        var pass_buf: [8192]u8 = undefined;
        const password = extractPasswordWindows(&sp_args, &pass_buf) orelse return .runtime_error;
        if (password.len == 0) return .runtime_error;

        // ensure askpass.bat 存在
        if (!ensureAskpassBat()) return .runtime_error;

        // 密码 → UTF-16，设置环境变量（本进程即 utmm sshpass 子进程，spawn ssh.exe 后即退出）
        const gpa = std.heap.page_allocator;
        const pass_u16 = toUtf16Z(gpa, password) catch return .runtime_error;
        defer gpa.free(pass_u16);
        const key_sshpass = toUtf16Z(gpa, "SSHPASS") catch return .runtime_error;
        defer gpa.free(key_sshpass);
        const key_askpass = toUtf16Z(gpa, "SSH_ASKPASS") catch return .runtime_error;
        defer gpa.free(key_askpass);
        const key_require = toUtf16Z(gpa, "SSH_ASKPASS_REQUIRE") catch return .runtime_error;
        defer gpa.free(key_require);
        const val_askpass = toUtf16Z(gpa, "C:\\opt\\utmm\\askpass.bat") catch return .runtime_error;
        defer gpa.free(val_askpass);
        const val_force = toUtf16Z(gpa, "force") catch return .runtime_error;
        defer gpa.free(val_force);
        const nul_name = toUtf16Z(gpa, "NUL") catch return .runtime_error;
        defer gpa.free(nul_name);

        _ = SetEnvironmentVariableW(@ptrCast(key_sshpass.ptr), @ptrCast(pass_u16.ptr));
        _ = SetEnvironmentVariableW(@ptrCast(key_askpass.ptr), @ptrCast(val_askpass.ptr));
        _ = SetEnvironmentVariableW(@ptrCast(key_require.ptr), @ptrCast(val_force.ptr));

        // NUL 作为子进程 stdin（立即 EOF → 根治退出挂起）。需设为可继承供 STARTF_USESTDHANDLES。
        const nul_handle = CreateFileW(@ptrCast(nul_name.ptr), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
        if (nul_handle == w.INVALID_HANDLE_VALUE) return .runtime_error;
        defer _ = CloseHandle(nul_handle);
        _ = SetHandleInformation(nul_handle, HANDLE_FLAG_INHERIT, 1);

        // 子进程 stdout/stderr 管道（合并，父进程读取透传）
        var stdout_read: HANDLE = undefined;
        var stdout_write: HANDLE = undefined;
        var sa: w.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
            .bInheritHandle = @enumFromInt(1),
            .lpSecurityDescriptor = null,
        };
        if (@intFromEnum(CreatePipe(&stdout_read, &stdout_write, &sa, 0)) == 0) return .runtime_error;
        defer _ = CloseHandle(stdout_write);
        _ = SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

        var startup_info: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup_info.cb = @sizeOf(w.STARTUPINFOW);
        startup_info.hStdInput = nul_handle;
        startup_info.hStdOutput = stdout_write;
        startup_info.hStdError = stdout_write;
        startup_info.dwFlags = @as(DWORD, @bitCast(@as(c_ulong, 0x100))); // STARTF_USESTDHANDLES

        var pi: PROCESS_INFORMATION = undefined;
        const create_result = CreateProcessW(
            null,
            @as([*:0]u16, @ptrCast(cmd_utf16.ptr)),
            null,
            null,
            @enumFromInt(1), // inherit handles（NUL + stdout_write）
            0,
            null, // lpEnvironment=null → 继承当前环境（含已设置的 SSH_ASKPASS/SSHPASS）
            null,
            &startup_info,
            &pi,
        );
        if (@intFromEnum(create_result) == 0) return .runtime_error;
        defer _ = CloseHandle(pi.hThread);
        defer _ = CloseHandle(pi.hProcess);

        _ = CloseHandle(stdout_write);

        // 读循环：透传子进程输出到父进程 stdout。密码由 askpass 一次性提供，无
        // 交互提示匹配；但需检测 stderr 中的 "Permission denied"（合并管道）→
        // 密码被拒 → sshpass 约定 exit 5（incorrect password）。
        var password_rejected = false;
        var tmp_buf: [4096]u8 = undefined;
        const Sleep = @extern(*const fn (dwMilliseconds: DWORD) callconv(.winapi) void, .{ .name = "Sleep", .library_name = "kernel32" });

        while (true) {
            var exit_code: DWORD = 0;
            _ = GetExitCodeProcess(pi.hProcess, &exit_code);
            if (exit_code != 259) break; // 259 = STILL_ACTIVE

            var bytes_read: DWORD = 0;
            const read_ok = ReadFile(stdout_read, &tmp_buf, @intCast(tmp_buf.len), &bytes_read, null);
            if (@intFromEnum(read_ok) != 0 and bytes_read > 0) {
                const data = tmp_buf[0..@intCast(bytes_read)];
                if (!password_rejected and std.mem.indexOf(u8, data, "Permission denied") != null) {
                    password_rejected = true;
                }
                var written: DWORD = 0;
                const stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return .runtime_error;
                _ = WriteFile(stdout_handle, data.ptr, @intCast(data.len), &written, null);
            } else {
                Sleep(50);
            }
        }

        var final_exit: DWORD = 0;
        _ = GetExitCodeProcess(pi.hProcess, &final_exit);
        if (password_rejected) return .incorrect_password;
        return @enumFromInt(@as(u8, @truncate(final_exit)));
    }

    /// ConPTY 模式（Windows 10 1809+）。
    /// CreatePseudoConsole → child process thinks it's connected to a real console
    /// → interactive password prompts work naturally.
    fn runWindowsConpty(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        const cmd_utf16 = buildCmdLine(allocator, cmd_args) catch return .runtime_error;
        defer allocator.free(cmd_utf16);

        var sa: w.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
            .bInheritHandle = @enumFromInt(1),
            .lpSecurityDescriptor = null,
        };

        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        if (@intFromEnum(CreatePipe(&in_read, &in_write, &sa, 0)) == 0) return .runtime_error;
        defer _ = CloseHandle(in_read);
        _ = SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);

        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (@intFromEnum(CreatePipe(&out_read, &out_write, &sa, 0)) == 0) return .runtime_error;
        defer _ = CloseHandle(out_write);
        _ = SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);

        // 动态解析的 ConPTY 函数指针（resolveConpty 已在调度前调用）
        const conpty_size = COORD{ .X = 80, .Y = 25 };
        var hpc: HANDLE = undefined;
        const hr = conpty_create.?(conpty_size, in_read, out_write, PSEUDOCONSOLE_INHERIT_CURSOR, &hpc);
        if (hr != 0) return .runtime_error;
        defer conpty_close.?(hpc);

        var startup_info_ex: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        startup_info_ex.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);

        var pi: PROCESS_INFORMATION = undefined;

        var attr_list_buf: [1024]u8 align(@alignOf(u64)) = [_]u8{0} ** 1024;

        const InitializeProcThreadAttributeList = @extern(
            *const fn (lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL,
            .{ .name = "InitializeProcThreadAttributeList", .library_name = "kernel32" },
        );
        const UpdateProcThreadAttribute = @extern(
            *const fn (lpAttributeList: *anyopaque, dwFlags: DWORD, attribute: usize, lpValue: ?*anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL,
            .{ .name = "UpdateProcThreadAttribute", .library_name = "kernel32" },
        );
        const DeleteProcThreadAttributeList = @extern(
            *const fn (lpAttributeList: *anyopaque) callconv(.winapi) void,
            .{ .name = "DeleteProcThreadAttributeList", .library_name = "kernel32" },
        );

        const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

        var attr_size: usize = @sizeOf(@TypeOf(attr_list_buf));
        if (@intFromEnum(InitializeProcThreadAttributeList(@ptrCast(&attr_list_buf), 1, 0, &attr_size)) == 0) {
            return .runtime_error;
        }
        defer DeleteProcThreadAttributeList(@ptrCast(&attr_list_buf));

        if (@intFromEnum(UpdateProcThreadAttribute(
            @ptrCast(&attr_list_buf), 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(&hpc), @sizeOf(HANDLE), null, null,
        )) == 0) {
            return .runtime_error;
        }

        // ConPTY 附加：lpAttributeList 必须挂进 STARTUPINFOEXW。此前漏挂（cb 只声明
        // STARTUPINFOW 大小）→ CreateProcessW 带 EXTENDED_STARTUPINFO_PRESENT + cb 不符
        // 直接 ERROR_INVALID_PARAMETER → sshpass 恒 exit 3（Windows 10/11 完全不可用）。
        startup_info_ex.lpAttributeList = @ptrCast(&attr_list_buf);

        const create_result = CreateProcessW(
            null,
            @as([*:0]u16, @ptrCast(cmd_utf16.ptr)),
            null, null,
            @enumFromInt(1),
            EXTENDED_STARTUPINFO_PRESENT,
            null, null,
            @ptrCast(&startup_info_ex.StartupInfo),
            &pi,
        );
        if (@intFromEnum(create_result) == 0) return .runtime_error;
        defer _ = CloseHandle(pi.hThread);
        defer _ = CloseHandle(pi.hProcess);

        _ = CloseHandle(in_read);
        _ = CloseHandle(out_write);

        var prevmatch: bool = false;
        var state1: usize = 0;
        var state2: usize = 0;
        var state3: usize = 0;
        var state4: usize = 0;
        var terminate: i32 = 0;

        var tmp_buf: [40]u8 = undefined;
        const Sleep = @extern(*const fn (dwMilliseconds: DWORD) callconv(.winapi) void, .{ .name = "Sleep", .library_name = "kernel32" });

        while (true) {
            var exit_code: DWORD = 0;
            _ = GetExitCodeProcess(pi.hProcess, &exit_code);
            if (exit_code != 259) break;

            var bytes_read: DWORD = 0;
            const read_ok = ReadFile(out_read, &tmp_buf, @intCast(tmp_buf.len), &bytes_read, null);
            if (@intFromEnum(read_ok) != 0 and bytes_read > 0) {
                const data = tmp_buf[0..@intCast(bytes_read)];

                var written: DWORD = 0;
                const stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return .runtime_error;
                _ = WriteFile(stdout_handle, data.ptr, @intCast(data.len), &written, null);

                const ret = handleoutputWindows(
                    &sp_args, &prevmatch, &state1, &state2, &state3, &state4,
                    data, in_write,
                );
                if (ret != 0) { terminate = ret; break; }
            } else {
                Sleep(50);
            }
        }

        if (terminate > 0) {
            _ = TerminateProcess(pi.hProcess, @as(w.UINT, @intCast(terminate)));
            return @enumFromInt(@as(u8, @intCast(terminate)));
        }

        var final_exit: DWORD = 0;
        _ = GetExitCodeProcess(pi.hProcess, &final_exit);
        return @enumFromInt(@as(u8, @truncate(final_exit)));
    }

    /// runWindows 调度器：按"命令类型"而非"有无控制台"选择路径。
    ///   - ssh 命令（自动密码认证）→ 永远 runWindowsAskpass。ConPTY 下 Win32 OpenSSH
    ///     用 _getch() 从键盘读密码（readpass.c WIN32_FIXME），不读管道 → 密码无法注入
    ///     → 双向死锁（实测 SSH 会话 / exec 通道 / SYSTEM schtask 全复现，GetConsoleWindow
    ///     在三者下均非空，"Session 0 无控制台"假设错误）。SSH_ASKPASS 不依赖 TTY。
    ///   - 非 ssh 交互命令 + 有控制台 + ConPTY → runWindowsConpty（交互式桌面会话）
    ///   - 非 ssh 命令 + 无控制台 / 老 Windows（无 ConPTY）→ runWindowsAskpass
    /// Check if the command is "ssh" or "ssh.exe" (no path prefix).
    fn isSshCommand(cmd: []const u8) bool {
        // Only match bare "ssh" / "ssh.exe" — don't override explicit paths
        if (std.mem.indexOfScalar(u8, cmd, '\\') != null) return false;
        if (std.mem.indexOfScalar(u8, cmd, '/') != null) return false;
        return std.ascii.eqlIgnoreCase(cmd, "ssh") or
            std.ascii.eqlIgnoreCase(cmd, "ssh.exe");
    }

    fn runWindows(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        // If command is "ssh"/"ssh.exe" (bare name, no path), use the embedded
        // ssh.exe at C:\opt\utmm\ssh.exe. This guarantees sshpass works even when
        // OpenSSH is not in PATH. The binary is extracted during --install / ensure.
        const SSH_EXE_PATH = "C:\\opt\\utmm\\ssh.exe";
        var ssh_args_buf: [64][]const u8 = undefined;
        const is_ssh = cmd_args.len > 0 and isSshCommand(cmd_args[0]);
        const effective_args = if (is_ssh and
            cmd_args.len < ssh_args_buf.len)
        blk: {
            @memcpy(ssh_args_buf[0..cmd_args.len], cmd_args);
            ssh_args_buf[0] = SSH_EXE_PATH;
            break :blk ssh_args_buf[0..cmd_args.len];
        } else cmd_args;

        // ssh 命令（sshpass 的核心场景：自动密码认证）永远走 SSH_ASKPASS，
        // 无论有无控制台。ConPTY 下 ssh 会 _getch() 读键盘 → 死锁（见函数注释）。
        if (is_ssh) {
            return runWindowsAskpass(allocator, sp_args, effective_args);
        }

        // 非 ssh 交互命令：有控制台 + ConPTY → ConPTY；否则 askpass（通用管道透传）。
        resolveConpty();
        const conpty_ok = conpty_create != null and conpty_close != null;
        if (conpty_ok and hasConsole()) {
            return runWindowsConpty(allocator, sp_args, effective_args);
        }
        return runWindowsAskpass(allocator, sp_args, effective_args);
    }

    fn handleoutputWindows(
        sp_args: *const SshpassArgs,
        prevmatch: *bool,
        state1: *usize,
        state2: *usize,
        state3: *usize,
        state4: *usize,
        data: []const u8,
        stdin_write: HANDLE,
    ) i32 {
        var ret: i32 = 0;

        state1.* = patternMatch(PromptPatterns.compare1, data, state1.*);
        if (state1.* >= PromptPatterns.compare1.len) {
            if (!prevmatch.*) {
                writePassWindows(stdin_write, sp_args);
                state1.* = 0;
                prevmatch.* = true;
            } else {
                ret = @intFromEnum(ExitCode.incorrect_password);
            }
        }

        if (ret == 0) {
            state3.* = patternMatch(PromptPatterns.compare3, data, state3.*);
            if (state3.* >= PromptPatterns.compare3.len) {
                if (!prevmatch.*) {
                    writePassWindows(stdin_write, sp_args);
                    state3.* = 0;
                    prevmatch.* = true;
                } else {
                    ret = @intFromEnum(ExitCode.incorrect_password);
                }
            }
        }

        if (ret == 0) {
            state4.* = patternMatch(PromptPatterns.compare4, data, state4.*);
            if (state4.* >= PromptPatterns.compare4.len) {
                if (!prevmatch.*) {
                    writePassWindows(stdin_write, sp_args);
                    state4.* = 0;
                    prevmatch.* = true;
                } else {
                    ret = @intFromEnum(ExitCode.incorrect_password);
                }
            }
        }

        if (ret == 0) {
            state2.* = patternMatch(PromptPatterns.compare2, data, state2.*);
            if (state2.* >= PromptPatterns.compare2.len) {
                ret = @intFromEnum(ExitCode.host_key_unknown);
            }
        }

        return ret;
    }

    fn writePassWindows(dst_handle: HANDLE, sp_args: *const SshpassArgs) void {
        switch (sp_args.pwtype) {
            .stdin_source => {
                const stdin_handle = GetStdHandle(STD_INPUT_HANDLE) orelse return;
                writePassFd(dst_handle, stdin_handle, struct {
                    fn readFn(h: HANDLE, b: []u8) isize {
                        var n: DWORD = 0;
                        _ = ReadFile(h, b.ptr, @intCast(b.len), &n, null);
                        return @intCast(n);
                    }
                }.readFn, struct {
                    fn writeFn(h: HANDLE, b: []const u8) isize {
                        var n: DWORD = 0;
                        _ = WriteFile(h, b.ptr, @intCast(b.len), &n, null);
                        return @intCast(n);
                    }
                }.writeFn);
            },
            .file => {
                // UTF-8 文件名 → UTF-16
                const filename_u16 = toUtf16Z(std.heap.page_allocator, sp_args.pwsrc.filename) catch return;
                defer std.heap.page_allocator.free(filename_u16);

                const src_handle = CreateFileW(
                    @ptrCast(filename_u16.ptr),
                    GENERIC_READ,
                    FILE_SHARE_READ,
                    null,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (src_handle != w.INVALID_HANDLE_VALUE) {
                    defer _ = CloseHandle(src_handle);
                    writePassFd(dst_handle, src_handle, struct {
                        fn readFn(h: HANDLE, b: []u8) isize {
                            var n: DWORD = 0;
                            _ = ReadFile(h, b.ptr, @intCast(b.len), &n, null);
                            return @intCast(n);
                        }
                    }.readFn, struct {
                        fn writeFn(h: HANDLE, b: []const u8) isize {
                            var n: DWORD = 0;
                            _ = WriteFile(h, b.ptr, @intCast(b.len), &n, null);
                            return @intCast(n);
                        }
                    }.writeFn);
                }
            },
            .fd => {
                // Windows 文件描述符 → HANDLE
                const fd_handle = GetStdHandle(@intCast(@intFromPtr(sp_args.pwsrc.fd))) orelse return;
                writePassFd(dst_handle, fd_handle, struct {
                    fn readFn(h: HANDLE, b: []u8) isize {
                        var n: DWORD = 0;
                        _ = ReadFile(h, b.ptr, @intCast(b.len), &n, null);
                        return @intCast(n);
                    }
                }.readFn, struct {
                    fn writeFn(h: HANDLE, b: []const u8) isize {
                        var n: DWORD = 0;
                        _ = WriteFile(h, b.ptr, @intCast(b.len), &n, null);
                        return @intCast(n);
                    }
                }.writeFn);
            },
            .pass => {
                var written: DWORD = 0;
                _ = WriteFile(dst_handle, sp_args.pwsrc.password.ptr, @intCast(sp_args.pwsrc.password.len), &written, null);
                _ = WriteFile(dst_handle, "\n", 1, &written, null);
            },
        }
    }
} else struct {};

/// 检查 SSH 命令行参数中是否已包含 StrictHostKeyChecking 选项。
/// 匹配 "-o StrictHostKeyChecking=..." 和 "-oStrictHostKeyChecking=..." 两种形式。
pub fn hasStrictHostKeyChecking(args: []const []const u8) bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 < args.len and std.mem.startsWith(u8, args[i + 1], "StrictHostKeyChecking")) {
                return true;
            }
        }
        if (std.mem.startsWith(u8, args[i], "-oStrictHostKeyChecking")) {
            return true;
        }
    }
    return false;
}

/// 确保 SSH 命令行参数中包含 "-o StrictHostKeyChecking=no"。
/// 如果已存在（任意值），则不添加。否则在 args[0]（"ssh" 命令）之后插入。
/// 调用者需确保 args 至少有一个元素。
pub fn ensureStrictHostKeyChecking(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8)) !void {
    if (hasStrictHostKeyChecking(list.items)) return;
    try list.insert(gpa, 1, "StrictHostKeyChecking=no");
    try list.insert(gpa, 1, "-o");
}

/// Guest 检测：平台是否支持 PTY 密码注入。
/// - POSIX：始终返回 true（posix_openpt 在所有现代系统上可用）。
/// - Windows：动态检测 CreatePseudoConsole API 是否存在（需 Win10 1809+）。
/// 供 Guest/Host 在 LSA node_info 中上报 conpty 标记。
pub fn conptyAvailable() bool {
    if (builtin.os.tag == .windows) {
        windows.resolveConpty();
        return windows.conpty_create != null and windows.conpty_close != null;
    }
    return true; // POSIX always has PTY
}

/// dpipe_shell 复用：创建 ConPTY（Windows only，非 Windows 返回 false）。
/// input_read/output_write 为喂给 ConPTY 的管道端（所有权移交 ConPTY），
/// out_hpc 接收 ConPTY 句柄。返回 false = ConPTY 不可用或创建失败。
/// fd_t 在 Windows 上即 HANDLE。
pub fn conptyCreate(size_x: i16, size_y: i16, input_read: std.posix.fd_t, output_write: std.posix.fd_t, out_hpc: *std.posix.fd_t) bool {
    if (builtin.os.tag != .windows) return false;
    return windows.pseudoConsoleCreate(size_x, size_y, input_read, output_write, out_hpc);
}

/// dpipe_shell 复用：关闭 ConPTY（非 Windows 无操作）。
pub fn conptyClose(hpc: std.posix.fd_t) void {
    if (builtin.os.tag != .windows) return;
    windows.pseudoConsoleClose(hpc);
}

const is_windows = builtin.os.tag == .windows;

// ═══════════════════════════════════════════════════════════════════════════
// 公共入口
// ═══════════════════════════════════════════════════════════════════════════

/// sshpass 模块入口。args[0] = 二进制路径，args[1] = "sshpass"，args[2..] = sshpass 参数和命令。
pub fn main(gpa: std.mem.Allocator, args: []const []const u8) noreturn {
    const actual_args = args[2..]; // 跳过二进制路径和 "sshpass" 子命令名

    const parsed = parseArgs(gpa, actual_args) catch |err| switch (err) {
        error.HelpShown => std.process.exit(0),
        error.VersionShown => std.process.exit(0),
        error.NoCommand => {
            showHelp();
            std.process.exit(0);
        },
        error.ConflictingArgs => {
            showHelp();
            std.process.exit(@intFromEnum(ExitCode.conflicting_args));
        },
        error.InvalidArgs, error.MissingArg => {
            showHelp();
            std.process.exit(@intFromEnum(ExitCode.invalid_args));
        },
        else => {
            std.log.err("[sshpass] parse error: {}", .{err});
            std.process.exit(@intFromEnum(ExitCode.invalid_args));
        },
    };

    const cmd_args_raw = actual_args[parsed.cmd_offset..];
    if (cmd_args_raw.len == 0) {
        showHelp();
        std.process.exit(0);
    }

    // 隐藏命令行中的密码（复刻 C 版安全措施）
    // 注意：仅在真正的命令行参数上执行（argv 内存可写）
    if (parsed.args.pwtype == .pass) {
        // 从 actual_args 中找到 -p 选项后的密码参数并覆盖
        for (actual_args[0 .. parsed.cmd_offset - 1], 0..) |arg, idx| {
            if (std.mem.eql(u8, arg, "-p") and idx + 1 < parsed.cmd_offset) {
                @memset(@constCast(actual_args[idx + 1]), 'z');
                break;
            }
        }
    }

    // 确保 SSH 命令包含 -o StrictHostKeyChecking=no（避免 host_key_unknown）
    var cmd_args_buf: std.ArrayList([]const u8) = .empty;
    defer cmd_args_buf.deinit(gpa);
    const cmd_args = if (hasStrictHostKeyChecking(cmd_args_raw))
        cmd_args_raw
    else blk: {
        cmd_args_buf.appendSlice(gpa, cmd_args_raw) catch {
            std.process.exit(@intFromEnum(ExitCode.runtime_error));
        };
        ensureStrictHostKeyChecking(gpa, &cmd_args_buf) catch {
            std.process.exit(@intFromEnum(ExitCode.runtime_error));
        };
        break :blk cmd_args_buf.items;
    };

    const exit_code: ExitCode = if (is_windows)
        windows.c.runWindows(gpa, parsed.args, cmd_args)
    else
        posix.c.runPosix(gpa, parsed.args, cmd_args);

    std.process.exit(@intFromEnum(exit_code));
}

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "sshpass: patternMatch — assword:" {
    const input = "Password:";
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare1, input, state);
    try std.testing.expect(state == PromptPatterns.compare1.len);
}

test "sshpass: patternMatch — assword for " {
    const input = "user@host's password for some-realm: ";
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare3, input, state);
    try std.testing.expect(state >= PromptPatterns.compare3.len);
}

test "sshpass: patternMatch — partial across reads" {
    // 模拟跨多次 read 的匹配
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare1, "Pass", state);
    try std.testing.expect(state > 0);
    try std.testing.expect(state < PromptPatterns.compare1.len);
    state = patternMatch(PromptPatterns.compare1, "word:", state);
    try std.testing.expect(state == PromptPatterns.compare1.len);
}

test "sshpass: patternMatch — host key" {
    const input = "The authenticity of host 'example.com (1.2.3.4)' can't be established.";
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare2, input, state);
    try std.testing.expect(state >= PromptPatterns.compare2.len);
}

test "sshpass: patternMatch — verification code" {
    const input = "Verification code: 123456";
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare4, input, state);
    try std.testing.expect(state >= PromptPatterns.compare4.len);
}

test "sshpass: patternMatch — no false positive" {
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare1, "Hello World!", state);
    try std.testing.expect(state == 0);
    try std.testing.expect(state < PromptPatterns.compare1.len);
}

test "sshpass: patternMatch — reset on mismatch" {
    var state: usize = 0;
    state = patternMatch(PromptPatterns.compare1, "PassX", state);
    try std.testing.expect(state == 0); // 'X' 破坏了匹配
}

test "sshpass: parseArgs — -p password" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "-p", "mypass", "ssh", "host" };
    const parsed = try parseArgs(alloc, &argv);
    defer alloc.free(parsed.args.pwsrc.password);
    try std.testing.expect(parsed.args.pwtype == .pass);
    try std.testing.expectEqualStrings("mypass", parsed.args.pwsrc.password);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd_offset);
}

test "sshpass: parseArgs — -f file" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "-f", "/tmp/pass.txt", "ssh", "host" };
    const parsed = try parseArgs(alloc, &argv);
    defer alloc.free(parsed.args.pwsrc.filename);
    try std.testing.expect(parsed.args.pwtype == .file);
    try std.testing.expectEqualStrings("/tmp/pass.txt", parsed.args.pwsrc.filename);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd_offset);
}

test "sshpass: parseArgs — default stdin" {
    const argv = [_][]const u8{ "ssh", "host" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expect(parsed.args.pwtype == .stdin_source);
    try std.testing.expectEqual(@as(usize, 0), parsed.cmd_offset);
}

test "sshpass: parseArgs — conflicting sources" {
    // 使用不触发内存分配的选项顺序，避免冲突前 dupe 导致的内存泄漏
    const argv = [_][]const u8{ "-d", "5", "-f", "/tmp/pass", "ssh", "host" };
    const result = parseArgs(std.testing.allocator, &argv);
    try std.testing.expectError(error.ConflictingArgs, result);
}

test "sshpass: parseArgs — no command" {
    const argv = [_][]const u8{"-p", "pass"};
    const result = parseArgs(std.testing.allocator, &argv);
    try std.testing.expectError(error.NoCommand, result);
}

test "sshpass: parseArgs — -h shows help" {
    const argv = [_][]const u8{"-h"};
    const result = parseArgs(std.testing.allocator, &argv);
    try std.testing.expectError(error.HelpShown, result);
}

test "sshpass: parseArgs — -V shows version" {
    const argv = [_][]const u8{"-V"};
    const result = parseArgs(std.testing.allocator, &argv);
    try std.testing.expectError(error.VersionShown, result);
}

test "sshpass: parseArgs — -- separator" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "-p", "pass", "--", "ssh", "-o", "opt" };
    const parsed = try parseArgs(alloc, &argv);
    defer alloc.free(parsed.args.pwsrc.password);
    try std.testing.expect(parsed.args.pwtype == .pass);
    try std.testing.expectEqual(@as(usize, 3), parsed.cmd_offset);
}
