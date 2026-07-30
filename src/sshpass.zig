// sshpass.zig — Non-interactive SSH authentication via PTY/ConPTY.
//
// 100% CLI-compatible with the original sshpass(1) C utility.
// POSIX: posix_openpt → fork → pselect → prompt-matching → password injection.
// Windows: CreatePseudoConsole (ConPTY, requires Windows 10 1809+).
//
// Usage: utmm sshpass [-p password | -f file | -d fd | -e] [-hV] command [args...]

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
                // 不 dupe — argv 在进程生命周期内有效，避免错误路径中的内存泄漏
                result.pwsrc = .{ .password = argv[i] };
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
// Windows 实现（ConPTY: CreatePseudoConsole / 管道降级 fallback）
// ═══════════════════════════════════════════════════════════════════════════
//
// ConPTY API (CreatePseudoConsole) 仅在 Windows 10 1809 (build 17763) 及之后可用。
// 老版本 Windows 不支持 ConPTY，sshpass 降级为纯管道模式：
//   - ConPTY 路径：子进程（ssh.exe）认为自己连着一个真正的控制台 → 交互式提示 → 密码注入
//   - 管道降级：直接用 CreatePipe 连接 stdin/stdout → 仍可匹配提示 → 注入密码
//     （Windows OpenSSH 客户端在非 TTY 模式下会从 stdin 读取密码）
//
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

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: DWORD,
        dwThreadId: DWORD,
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

    /// 管道降级模式（老版本 Windows，无 ConPTY）。
    /// 直接用 CreatePipe 连接子进程 stdin/stdout，仍可匹配 SSH 提示并注入密码。
    /// Windows OpenSSH 客户端在非 TTY 模式下会从 stdin 读取密码。
    fn runWindowsPipe(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        const cmd_utf16 = buildCmdLine(allocator, cmd_args) catch return .runtime_error;
        defer allocator.free(cmd_utf16);

        var sa: w.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
            .bInheritHandle = @enumFromInt(1),
            .lpSecurityDescriptor = null,
        };

        // 子进程 stdin 管道（父进程写入密码）
        var stdin_read: HANDLE = undefined;
        var stdin_write: HANDLE = undefined;
        if (@intFromEnum(CreatePipe(&stdin_read, &stdin_write, &sa, 0)) == 0) return .runtime_error;
        defer _ = CloseHandle(stdin_read);
        _ = SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);

        // 子进程 stdout 管道（父进程读取输出）
        var stdout_read: HANDLE = undefined;
        var stdout_write: HANDLE = undefined;
        if (@intFromEnum(CreatePipe(&stdout_read, &stdout_write, &sa, 0)) == 0) return .runtime_error;
        defer _ = CloseHandle(stdout_write);
        _ = SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

        // 使用标准 STARTUPINFO（非 ConPTY 的 EXTENDED_STARTUPINFO）
        var startup_info: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup_info.cb = @sizeOf(w.STARTUPINFOW);
        startup_info.hStdInput = stdin_read;
        startup_info.hStdOutput = stdout_write;
        startup_info.hStdError = stdout_write;
        startup_info.dwFlags = @as(DWORD, @bitCast(@as(c_ulong, 0x100))); // STARTF_USESTDHANDLES

        var pi: PROCESS_INFORMATION = undefined;
        const create_result = CreateProcessW(
            null,
            @as([*:0]u16, @ptrCast(cmd_utf16.ptr)),
            null,
            null,
            @enumFromInt(1), // inherit handles
            0, // 无特殊 flag
            null,
            null,
            &startup_info,
            &pi,
        );
        if (@intFromEnum(create_result) == 0) return .runtime_error;
        defer _ = CloseHandle(pi.hThread);
        defer _ = CloseHandle(pi.hProcess);

        // 关闭子进程端的句柄
        _ = CloseHandle(stdin_read);
        _ = CloseHandle(stdout_write);

        // 读取/写入循环（与 ConPTY 路径相同的 prompt 匹配逻辑）
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
            if (exit_code != 259) break; // 259 = STILL_ACTIVE

            var bytes_read: DWORD = 0;
            const read_ok = ReadFile(stdout_read, &tmp_buf, @intCast(tmp_buf.len), &bytes_read, null);
            if (@intFromEnum(read_ok) != 0 and bytes_read > 0) {
                const data = tmp_buf[0..@intCast(bytes_read)];

                // 透传到父进程 stdout
                var written: DWORD = 0;
                const stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return .runtime_error;
                _ = WriteFile(stdout_handle, data.ptr, @intCast(data.len), &written, null);

                const ret = handleoutputWindows(
                    &sp_args, &prevmatch, &state1, &state2, &state3, &state4,
                    data, stdin_write,
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

        var startup_info: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup_info.cb = @sizeOf(w.STARTUPINFOW);

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

        startup_info.cb = @sizeOf(w.STARTUPINFOW);

        const create_result = CreateProcessW(
            null,
            @as([*:0]u16, @ptrCast(cmd_utf16.ptr)),
            null, null,
            @enumFromInt(1),
            EXTENDED_STARTUPINFO_PRESENT,
            null, null,
            &startup_info,
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

    /// runWindows 调度器：检测 ConPTY 可用性，选择最优路径。
    fn runWindows(allocator: std.mem.Allocator, sp_args: SshpassArgs, cmd_args: []const []const u8) ExitCode {
        resolveConpty();
        if (conpty_create != null and conpty_close != null) {
            return runWindowsConpty(allocator, sp_args, cmd_args);
        } else {
            return runWindowsPipe(allocator, sp_args, cmd_args);
        }
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
                // 使用 CreateFileW 打开文件
                const CreateFileW = @extern(
                    *const fn (lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*w.SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE,
                    .{ .name = "CreateFileW", .library_name = "kernel32" },
                );

                // UTF-8 文件名 → UTF-16
                const filename_u16 = std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, sp_args.pwsrc.filename) catch return;
                defer std.heap.page_allocator.free(filename_u16);

                const fname_z = std.heap.page_allocator.allocSentinel(u16, filename_u16.len, 0) catch return;
                defer std.heap.page_allocator.free(fname_z);
                @memcpy(fname_z[0..filename_u16.len], filename_u16);
                fname_z[filename_u16.len] = 0;

                const src_handle = CreateFileW(fname_z.ptr, 0x80000000, 1, null, 3, 0x80, null);
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

    const cmd_args = actual_args[parsed.cmd_offset..];
    if (cmd_args.len == 0) {
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
    const argv = [_][]const u8{ "-p", "mypass", "ssh", "host" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
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
    const argv = [_][]const u8{ "-p", "pass", "--", "ssh", "-o", "opt" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expect(parsed.args.pwtype == .pass);
    try std.testing.expectEqual(@as(usize, 3), parsed.cmd_offset);
}
