//! Unified cross-platform service management.
//!
//! Canonical install path:
//!   POSIX:   /opt/utmm/utmm
//!   Windows: C:\opt\utmm\utmm.exe
//!
//! Self-copy model: the running binary copies itself to the canonical path.
//! forceInstall() is always a full overwrite — stop → kill → copy → install → start.
//! No symlinks, no utmm.next staging files, no in-place rename of running binaries.

const builtin = @import("builtin");
const std = @import("std");
const fail = @import("fail.zig");
/// Install-time singleton lock to serialize install/uninstall operations.
/// Uses OS-level advisory locks automatically released on process exit.
const InstallLock = struct {
    const path_posix = "/var/run/utmm-install.lock";
    const path_win = "C:\\opt\\utmm\\utmm-install.lock";

    var _locked: bool = false;

    pub fn acquire() !void {
        if (builtin.os.tag == .windows) {
            return acquireWindows();
        }
        return acquirePosix();
    }

    pub fn release() void {
        if (!_locked) return;
        if (builtin.os.tag == .windows) {
            releaseWindows();
        } else {
            releasePosix();
        }
        _locked = false;
    }

    // ──────────── POSIX: flock ────────────
    const O_CREAT: c_int = if (builtin.os.tag == .macos) 0x0200 else 0o100;
    const O_RDWR: c_int = if (builtin.os.tag == .macos) 0x0002 else 0o2;
    const LOCK_EX: c_int = 2;
    const LOCK_UN: c_int = 8;

    extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
    extern "c" fn flock(fd: c_int, operation: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;

    var posix_fd: c_int = -1;

    fn acquirePosix() !void {
        const fd = open(path_posix, O_CREAT | O_RDWR, 0o644);
        if (fd < 0) {
            std.log.err("[svc] install-lock: open failed", .{});
            return error.LockFailed;
        }
        if (flock(fd, LOCK_EX) != 0) {
            _ = close(fd);
            std.log.err("[svc] install-lock: flock failed", .{});
            return error.LockFailed;
        }
        posix_fd = fd;
        _locked = true;
    }

    fn releasePosix() void {
        _ = flock(posix_fd, LOCK_UN);
        _ = close(posix_fd);
        posix_fd = -1;
    }

    // ──────────── Windows: LockFileEx ────────────
    const w = std.os.windows;
    const DWORD = w.DWORD;
    const BOOL = w.BOOL;
    const HANDLE = w.HANDLE;
    const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 128;
    const OPEN_ALWAYS: DWORD = 4;
    const LOCKFILE_EXCLUSIVE_LOCK: DWORD = 0x00000002;

    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: DWORD,
        OffsetHigh: DWORD,
        hEvent: ?HANDLE,
    };

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn LockFileEx(
        hFile: HANDLE,
        dwFlags: DWORD,
        dwReserved: DWORD,
        nNumberOfBytesToLockLow: DWORD,
        nNumberOfBytesToLockHigh: DWORD,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn UnlockFileEx(
        hFile: HANDLE,
        dwReserved: DWORD,
        nNumberOfBytesToUnlockLow: DWORD,
        nNumberOfBytesToUnlockHigh: DWORD,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    var win_handle: HANDLE = undefined;

    fn acquireWindows() !void {
        // Convert path to UTF-16 (stack-allocated, path is short)
        var path_utf16: [128]u16 = [_]u16{0} ** 128;
        var i: usize = 0;
        for (path_win) |c| {
            path_utf16[i] = @intCast(c);
            i += 1;
        }
        path_utf16[i] = 0;

        const h = CreateFileW(
            @ptrCast(&path_utf16),
            GENERIC_READ | GENERIC_WRITE,
            0, // exclusive access
            null,
            OPEN_ALWAYS, // create if not exists
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == INVALID_HANDLE_VALUE) {
            std.log.err("[svc] install-lock: CreateFileW failed", .{});
            return error.LockFailed;
        }

        var overlapped: OVERLAPPED = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Offset = 0,
            .OffsetHigh = 0,
            .hEvent = null,
        };
        const result = LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped);
        if (@intFromEnum(result) == @as(c_int, 0)) {
            _ = CloseHandle(h);
            std.log.err("[svc] install-lock: LockFileEx failed", .{});
            return error.LockFailed;
        }

        win_handle = h;
        _locked = true;
    }

    fn releaseWindows() void {
        var overlapped: OVERLAPPED = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Offset = 0,
            .OffsetHigh = 0,
            .hEvent = null,
        };
        _ = UnlockFileEx(win_handle, 0, 1, 0, &overlapped);
        _ = CloseHandle(win_handle);
    }
};
// ─── Windows: Toolhelp process enumeration API (replace tasklist/taskkill) ───

const w32 = struct {
    const DWORD = std.os.windows.DWORD;
    const BOOL = std.os.windows.BOOL;
    const HANDLE = std.os.windows.HANDLE;

    const TH32CS_SNAPPROCESS: DWORD = 0x00000002;
    const PROCESS_TERMINATE: DWORD = 0x0001;

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD,
        th32ProcessID: DWORD,
        th32DefaultHeapID: usize,
        th32ModuleID: DWORD,
        cntThreads: DWORD,
        th32ParentProcessID: DWORD,
        pcPriClassBase: i32,
        dwFlags: DWORD,
        szExeFile: [260]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    /// Case-insensitive match against "utmm.exe" in UTF-16LE.
    fn isUtmmExe(name: [*]const u16) bool {
        const target = [_]u16{ 'u', 't', 'm', 'm', '.', 'e', 'x', 'e' };
        var i: usize = 0;
        while (name[i] != 0 and i < target.len) : (i += 1) {
            const c = name[i];
            const lower: u16 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
            if (lower != target[i]) return false;
        }
        return i == target.len and name[i] == 0;
    }

    /// Case-insensitive match against "utmmd.exe" in UTF-16LE.
    fn isUtmmdExe(name: [*]const u16) bool {
        const target = [_]u16{ 'u', 't', 'm', 'm', 'd', '.', 'e', 'x', 'e' };
        var i: usize = 0;
        while (name[i] != 0 and i < target.len) : (i += 1) {
            const c = name[i];
            const lower: u16 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
            if (lower != target[i]) return false;
        }
        return i == target.len and name[i] == 0;
    }
};

const protocol = @import("protocol.zig");

/// Canonical install path for utmm (the managed process).
pub const CANONICAL_PATH_POSIX = "/opt/utmm/utmm";
pub const CANONICAL_PATH_WIN = "C:\\opt\\utmm\\utmm.exe";

/// Canonical install path for utmmd (the supervisor daemon / system service).
pub const CANONICAL_SVC_PATH_POSIX = "/opt/utmm/utmmd";
pub const CANONICAL_SVC_PATH_WIN = "C:\\opt\\utmm\\utmmd.exe";

/// Single service name — utmmd is the system service (v0.12.0+).
/// Guest and Host are mutually exclusive on one machine.
const SVC_NAME_MACOS = "com.utmmd";
const SVC_NAME_LINUX = "utmmd";
const SVC_NAME_WINDOWS = "UTM-MonitorD";

fn svcName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => SVC_NAME_MACOS,
        .linux => SVC_NAME_LINUX,
        .windows => SVC_NAME_WINDOWS,
        else => "utmmd",
    };
}

pub const ServiceRole = enum { guest, host };

/// Return the canonical install path for the current platform.
pub fn canonicalPath() []const u8 {
    if (builtin.os.tag == .windows) return CANONICAL_PATH_WIN;
    return CANONICAL_PATH_POSIX;
}

/// Return the directory portion of the canonical path.
pub fn canonicalDir() []const u8 {
    if (builtin.os.tag == .windows) return "C:\\opt\\utmm";
    return "/opt/utmm";
}

/// Return the system temporary directory.
/// On POSIX: $TMPDIR or /tmp.
/// On Windows: %TEMP%, %TMP%, or C:\Windows\Temp.
pub fn tempDir() [:0]const u8 {
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("TEMP")) |td| return std.mem.span(td);
        if (std.c.getenv("TMP")) |td| return std.mem.span(td);
        return "C:\\Windows\\Temp";
    }
    if (std.c.getenv("TMPDIR")) |td| return std.mem.span(td);
    return "/tmp";
}

/// 升级临时文件排他锁 — 跨平台，进程崩溃时 OS 自动释放。
/// Guest 端创建并持有锁写入；utmmd 端尝试获取锁来判断文件是否写入完成。
/// 使用 OS 级排他锁（POSIX flock + LOCK_EX；Windows CreateFileW dwShareMode=0），
/// 无需单独的标记文件 — 文件本身即自描述（SHA256 嵌入文件名）。
pub const UpgradeLock = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else c_int,

    /// 构建文件接收临时路径：{canonicalDir}/{prefix}.{sha256hex}.tmp
    pub fn tmpPath(allocator: std.mem.Allocator, comptime prefix: []const u8, sha256_hex: []const u8) ![]const u8 {
        if (builtin.os.tag == .windows) {
            return std.fmt.allocPrint(allocator, "C:\\opt\\utmm\\" ++ prefix ++ ".{s}.tmp", .{sha256_hex});
        }
        return std.fmt.allocPrint(allocator, "/opt/utmm/" ++ prefix ++ ".{s}.tmp", .{sha256_hex});
    }

    /// 从文件名提取 SHA256 hex（64 字符）。文件名格式：{prefix}.<64hex>.tmp
    pub fn extractSha256(basename: []const u8, comptime prefix: []const u8) ?[]const u8 {
        const full_prefix = prefix ++ ".";
        const suffix = ".tmp";
        if (!std.mem.startsWith(u8, basename, full_prefix)) return null;
        if (!std.mem.endsWith(u8, basename, suffix)) return null;
        const hex = basename[full_prefix.len .. basename.len - suffix.len];
        if (hex.len != 64) return null;
        return hex;
    }

    /// 创建文件并获取排他锁（阻塞等待）。调用者负责释放 allocator 分配的 path。
    pub fn create(path: []const u8) !UpgradeLock {
        if (builtin.os.tag == .windows) return createWindows(path);
        return createPosix(path);
    }

    /// 尝试获取排他锁（非阻塞）。成功返回 UpgradeLock，文件正在被写入返回 null。
    pub fn tryAcquire(path: []const u8) ?UpgradeLock {
        if (builtin.os.tag == .windows) return tryAcquireWindows(path);
        return tryAcquirePosix(path);
    }

    /// 向锁定文件写入数据（原始 OS write，绕过 Zig Io 层）。
    pub fn writeAll(self: *const UpgradeLock, data: []const u8) !void {
        if (builtin.os.tag == .windows) return writeAllWindows(self, data);
        return writeAllPosix(self, data);
    }

    /// 释放锁并关闭文件（保留磁盘文件 — utmmd 接管后 rename）。
    pub fn release(self: *const UpgradeLock) void {
        if (builtin.os.tag == .windows) {
            _ = windows.CloseHandle(self.fd);
        } else {
            _ = posixClose(self.fd);
        }
    }

    /// 释放锁、关闭文件并删除磁盘文件（写入失败或 SHA256 不匹配时调用）。
    pub fn releaseAndDelete(self: *const UpgradeLock, path: []const u8) void {
        if (builtin.os.tag == .windows) {
            _ = windows.CloseHandle(self.fd);
            deletePathWindows(path);
        } else {
            _ = posixClose(self.fd);
            deletePathPosix(path);
        }
    }

    // ════════════ POSIX 实现: open + flock ════════════

    const O_CREAT: c_int = if (builtin.os.tag == .macos) 0x0200 else 0o100;
    const O_RDWR: c_int = if (builtin.os.tag == .macos) 0x0002 else 0o2;
    const O_TRUNC: c_int = if (builtin.os.tag == .macos) 0x0400 else 0o1000;
    const LOCK_EX: c_int = 2;
    const LOCK_UN: c_int = 8;
    const LOCK_NB: c_int = 4;

    extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
    extern "c" fn flock(fd: c_int, operation: c_int) c_int;
    fn posixClose(fd: c_int) void { _ = close(fd); }
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn unlink(path: [*:0]const u8) c_int;

    /// 栈上将路径复制为 null 结尾字符串（内部使用）。
    fn copyPathZ(path: []const u8, buf: []u8) [:0]const u8 {
        if (path.len >= buf.len) @panic("UpgradeLock path too long");
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return buf[0..path.len :0];
    }

    fn createPosix(path: []const u8) !UpgradeLock {
        var zbuf: [512]u8 = undefined;
        const pz = copyPathZ(path, &zbuf);
        const fd = open(pz.ptr, O_CREAT | O_RDWR | O_TRUNC, 0o644);
        if (fd < 0) return error.OpenFailed;
        if (flock(fd, LOCK_EX) != 0) {
            _ = close(fd);
            return error.LockFailed;
        }
        return UpgradeLock{ .fd = fd };
    }

    fn tryAcquirePosix(path: []const u8) ?UpgradeLock {
        var zbuf: [512]u8 = undefined;
        const pz = copyPathZ(path, &zbuf);
        const fd = open(pz.ptr, O_RDWR, 0);
        if (fd < 0) return null;
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            _ = close(fd);
            return null;
        }
        return UpgradeLock{ .fd = fd };
    }

    fn deletePathPosix(path: []const u8) void {
        var zbuf: [512]u8 = undefined;
        const pz = copyPathZ(path, &zbuf);
        _ = unlink(pz.ptr);
    }

    fn writeAllPosix(self: *const UpgradeLock, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const n = write(self.fd, data.ptr + off, data.len - off);
            if (n < 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    // ════════════ Windows 实现: CreateFileW dwShareMode=0 ════════════
    // 使用 dwShareMode=0（排他访问）而非 LockFileEx — 进程崩溃时 OS
    // 自动关闭 HANDLE → 排他访问解除，比 LockFileEx 更可靠。

    const windows = struct {
        const w = std.os.windows;
        const DWORD = w.DWORD;
        const BOOL = w.BOOL;
        const HANDLE = w.HANDLE;
        const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
        const GENERIC_WRITE: DWORD = 0x40000000;
        const GENERIC_READ: DWORD = 0x80000000;
        const FILE_SHARE_READ: DWORD = 0x00000001;
        const CREATE_ALWAYS: DWORD = 2;
        const OPEN_EXISTING: DWORD = 3;
        const FILE_ATTRIBUTE_NORMAL: DWORD = 128;

        extern "kernel32" fn CreateFileW(
            lpFileName: [*:0]const u16,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*anyopaque,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;

        extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: [*]const u8,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*anyopaque,
        ) callconv(.winapi) BOOL;

        extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
        extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
    };

    /// UTF-8 路径（非 null 结尾）→ 栈上 UTF-16 null 结尾缓冲。
    fn utf8ToUtf16Stack(utf8: []const u8, utf16: []u16) ![]u16 {
        const len = std.unicode.utf8ToUtf16Le(utf16, utf8) catch return error.NameTooLong;
        if (len >= utf16.len) return error.NameTooLong;
        utf16[len] = 0;
        return utf16[0 .. len + 1];
    }

    fn createWindows(path: []const u8) !UpgradeLock {
        var path_utf16: [256]u16 = [_]u16{0} ** 256;
        const wpath = try utf8ToUtf16Stack(path, &path_utf16);

        const h = windows.CreateFileW(
            @ptrCast(wpath.ptr),
            windows.GENERIC_WRITE,
            0, // dwShareMode=0 — 排他访问，其他进程无法打开
            null,
            windows.CREATE_ALWAYS,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return UpgradeLock{ .fd = h };
    }

    fn tryAcquireWindows(path: []const u8) ?UpgradeLock {
        var path_utf16: [256]u16 = [_]u16{0} ** 256;
        const wpath = utf8ToUtf16Stack(path, &path_utf16) catch return null;

        const h = windows.CreateFileW(
            @ptrCast(wpath.ptr),
            windows.GENERIC_READ,
            windows.FILE_SHARE_READ, // Guest 用 dwShareMode=0 所以 Guest 持有文件时此调用失败
            null,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == windows.INVALID_HANDLE_VALUE) return null; // 文件不存在或 Guest 持有排他锁
        return UpgradeLock{ .fd = h };
    }

    fn deletePathWindows(path: []const u8) void {
        var path_utf16: [256]u16 = [_]u16{0} ** 256;
        const wpath = utf8ToUtf16Stack(path, &path_utf16) catch return;
        _ = windows.DeleteFileW(@ptrCast(wpath.ptr));
    }

    fn writeAllWindows(self: *const UpgradeLock, data: []const u8) !void {
        var written: windows.DWORD = 0;
        const rc = windows.WriteFile(self.fd, data.ptr, @intCast(data.len), &written, null);
        if (@intFromEnum(rc) == 0) return error.WriteFailed;
        if (written != data.len) return error.WriteFailed;
    }
};

/// 从 .tmp 文件名提取 SHA256 hex 后验证文件内容完整性。
/// 成功返回 true（内容匹配文件名），失败返回 false（文件损坏/不完整，已删除）。
/// file_io: 文件 I/O 用 Io（Windows 上需为 Threaded，IOCP 不支持文件操作）。
pub fn verifyUpgradeTmpByFilename(allocator: std.mem.Allocator, file_io: std.Io, path: []const u8, basename: []const u8) bool {
    const expected_hex = UpgradeLock.extractSha256(basename, "utmm-upgrade") orelse return false;
    const actual_hex = computeSha256Hex(allocator, file_io, path) catch return false;
    defer allocator.free(actual_hex);
    if (!std.mem.eql(u8, expected_hex, actual_hex)) {
        std.Io.Dir.cwd().deleteFile(file_io, path) catch {};
        return false;
    }
    return true;
}

/// 计算文件的 SHA256 hex 字符串（64 字符，allocator 分配）。
fn computeSha256Hex(allocator: std.mem.Allocator, file_io: std.Io, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.cwd().openFile(file_io, path, .{ .mode = .read_only });
    defer f.close(file_io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var rbuf: [65536]u8 = undefined;
    var rdr = f.reader(file_io, &rbuf);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = rdr.interface.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);
    const hex = try allocator.alloc(u8, 64);
    for (hash, 0..) |byte, i| {
        const h = "0123456789abcdef";
        hex[i * 2] = h[byte >> 4];
        hex[i * 2 + 1] = h[byte & 0x0f];
    }
    return hex;
}

/// 扫描升级临时文件：在 canonicalDir 中查找第一个 utmm-upgrade.*.tmp 文件。
/// 成功返回完整路径名（allocator 分配，调用者释放），未找到返回 null。
pub fn findUpgradeTmp(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const dir = std.Io.Dir.cwd().openDir(io, canonicalDir(), .{}) catch return null;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (UpgradeLock.extractSha256(entry.basename, "utmm-upgrade")) |_| {
            if (builtin.os.tag == .windows) {
                return std.fmt.allocPrint(allocator, "C:\\opt\\utmm\\{s}", .{entry.basename}) catch return null;
            }
            return std.fmt.allocPrint(allocator, "/opt/utmm/{s}", .{entry.basename}) catch return null;
        }
    }
    return null;
}

/// 清理由崩溃 Guest 遗留的升级临时文件。
/// 启动时（Host/Guest 模式均调用）扫描 canonicalDir，删除旧的 utmm-upgrade.*.tmp 文件。
/// 调用者需确保没有并发的升级操作（utmm 启动时 Guest 尚未 listen TCP，安全）。
pub fn cleanupStaleUpgradeTmp(io: std.Io, allocator: std.mem.Allocator) void {
    // 清理旧的 .sha256 标记机制残留（v0.17.19 之前）— 过渡期代码，后续版本可移除。
    {
        const old_tmp = if (builtin.os.tag == .windows)
            "C:\\opt\\utmm\\utmm-upgrade.sha256.tmp"
        else
            "/opt/utmm/utmm-upgrade.sha256.tmp";
        std.Io.Dir.cwd().deleteFile(io, old_tmp) catch {};

        const old_marker = if (builtin.os.tag == .windows)
            "C:\\opt\\utmm\\utmm-upgrade.sha256"
        else
            "/opt/utmm/utmm-upgrade.sha256";
        std.Io.Dir.cwd().deleteFile(io, old_marker) catch {};

        const old_bin = if (builtin.os.tag == .windows)
            "C:\\opt\\utmm\\utmm-upgrade.exe"
        else
            "/opt/utmm/utmm-upgrade";
        std.Io.Dir.cwd().deleteFile(io, old_bin) catch {};
    }

    // 清理新的 .tmp 机制残留（崩溃遗留的半写文件）。
    const dir = std.Io.Dir.cwd().openDir(io, canonicalDir(), .{}) catch return;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        // 检查 upload.*.tmp 或 utmm-upgrade.*.tmp 前缀
        const is_upload = UpgradeLock.extractSha256(entry.basename, "upload") != null;
        const is_upgrade = UpgradeLock.extractSha256(entry.basename, "utmm-upgrade") != null;
        if (is_upload or is_upgrade) {
            // 尝试获取排他锁 — 如果成功，说明没有人在写入，可以安全删除。
            const full_path = if (builtin.os.tag == .windows)
                std.fmt.allocPrint(allocator, "C:\\opt\\utmm\\{s}", .{entry.basename}) catch continue
            else
                std.fmt.allocPrint(allocator, "/opt/utmm/{s}", .{entry.basename}) catch continue;
            defer allocator.free(full_path);

            if (UpgradeLock.tryAcquire(full_path)) |lock| {
                lock.releaseAndDelete(full_path);
                std.log.info("[svc] cleanup: removed stale tmp {s}", .{entry.basename});
            }
            // 锁获取失败 = 正在被写入，跳过
        }
    }
}

/// Return the canonical install path for utmmd (the supervisor daemon).
pub fn canonicalSvcPath() []const u8 {
    if (builtin.os.tag == .windows) return CANONICAL_SVC_PATH_WIN;
    return CANONICAL_SVC_PATH_POSIX;
}

/// Check if the current process is running from the canonical path.
pub fn isAtCanonicalPath(io: std.Io) bool {
    var buf: [4096]u8 = undefined;
    const len = std.process.executablePath(io, &buf) catch return false;
    return std.mem.eql(u8, buf[0..len], canonicalPath());
}

// ═══════════════════════════════════════════════════════════════════════════
// Command helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Run `launchctl bootout system/<name>` with the correct slash-separated
/// service target syntax. The space-separated form (`bootout system <name>`)
/// is not valid on macOS and always returns exit code 5 (EIO).
fn bootoutMacOS(alloc: std.mem.Allocator, io: std.Io, name: []const u8) void {
    const target = std.fmt.allocPrint(alloc, "system/{s}", .{name}) catch return;
    defer alloc.free(target);
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", target });
}

/// Run a command using std.process.run. Returns true on success (exit code 0).
fn runCmd(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
        std.log.debug("[svc] cmd spawn failed: {s}: {}", .{ argv[0], err });
        return false;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.debug("[svc] cmd non-zero exit: {s} {s} (term={})", .{ argv[0], argv[1], result.term });
        return false;
    }
    return true;
}

/// Run a command for best-effort cleanup — failure is expected and logged
/// at debug level (not warn, since many of these intentionally target
/// services/files that may not exist).
/// macOS: clear Gatekeeper quarantine attribute so the binary can run.
/// Best-effort — failures are silently ignored (attribute may not exist).
pub fn clearQuarantine(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    if (builtin.os.tag != .macos) return;
    runCmdQuiet(alloc, io, &[_][]const u8{ "xattr", "-d", "com.apple.quarantine", path });
}

fn runCmdQuiet(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
        std.log.debug("[svc] cmd failed: {s} {s}: {}", .{ argv[0], argv[1], err });
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.debug("[svc] cmd non-zero exit: {s} {s}", .{ argv[0], argv[1] });
    }
}

/// Run a command and return its stdout (caller owns), or null on failure.
fn runCmdStdout(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    alloc.free(result.stderr);
    return result.stdout;
}

/// Run a command and check its exit code. Returns true if exit code is 0.
fn runCmdCheckExit(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Service status queries
// ═══════════════════════════════════════════════════════════════════════════

/// Check if the service is currently running.
pub fn isRunning(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) bool {
    _ = _role;
    const name = svcName();
    return switch (builtin.os.tag) {
        .macos => blk: {
            const result = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
            if (result) |stdout| {
                defer alloc.free(stdout);
                var lines = std.mem.splitScalar(u8, stdout, '\n');
                while (lines.next()) |line| {
                    if (std.mem.indexOf(u8, line, name)) |_| {
                        const trimmed = std.mem.trimStart(u8, line, " \t");
                        if (trimmed.len > 0 and std.ascii.isDigit(trimmed[0])) {
                            break :blk true;
                        }
                        break;
                    }
                }
            }
            // Fallback: check if utmmd process is actually running.
            // launchctl load (legacy) may have started it without launchd
            // tracking the PID properly. pgrep catches this case.
            if (runCmdCheckExit(alloc, io, &[_][]const u8{
                "pgrep", "-f", CANONICAL_SVC_PATH_POSIX,
            })) {
                break :blk true;
            }
            break :blk false;
        },
        .linux => blk: {
            break :blk runCmdCheckExit(alloc, io, &[_][]const u8{
                "systemctl", "is-active", "--quiet", name,
            });
        },
        .windows => blk: {
            const result = runCmdStdout(alloc, io, &[_][]const u8{
                "sc", "query", name,
            });
            if (result) |stdout| {
                defer alloc.free(stdout);
                break :blk std.mem.indexOf(u8, stdout, "RUNNING") != null;
            }
            break :blk false;
        },
        else => false,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Service lifecycle: install / uninstall / start / stop
// ═══════════════════════════════════════════════════════════════════════════

/// Install service configuration pointing to the canonical binary path.
/// Always overwrites existing config — no checks, no comparison.
pub fn install(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    // Clean up legacy service names first
    switch (builtin.os.tag) {
        .macos => {
            const legacy_labels = [_][]const u8{ "com.utmm", "com.utmmd-guest" };
            for (legacy_labels) |legacy| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{legacy});
                defer alloc.free(plist_path);
                bootoutMacOS(alloc, io, legacy);
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const legacy_names = [_][]const u8{"utmm"};
            for (legacy_names) |legacy| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", legacy });
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", legacy });
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{legacy});
                defer alloc.free(unit_path);
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
        },
        .windows => {
            const legacy_names = [_][]const u8{"UTM-Monitor"};
            for (legacy_names) |legacy| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", legacy });
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", legacy });
            }
        },
        else => {},
    }

    switch (builtin.os.tag) {
        .macos => try installMacOS(io, alloc, role, extra_args),
        .linux => try installLinux(io, alloc, role, extra_args),
        .windows => try installWindows(io, alloc, role, extra_args),
        else => fail.msg("install", "unsupported platform: {s}", .{@tagName(builtin.os.tag)}),
    }
}

fn installMacOS(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName();
    const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
    defer alloc.free(plist_path);

    const svc_path = canonicalSvcPath();
    const env = .{ .shell = "/bin/zsh", .home = "/var/root" };

    // Build ProgramArguments string: utmmd --role guest|host [extra_args...]
    var args_list: std.ArrayListAligned(u8, null) = .empty;
    defer args_list.deinit(alloc);
    try args_list.appendSlice(alloc, "        <string>");
    try args_list.appendSlice(alloc, svc_path);
    try args_list.appendSlice(alloc, "</string>\n");
    try args_list.appendSlice(alloc, "        <string>--role</string>\n");
    try args_list.appendSlice(alloc, if (role == .host)
        "        <string>host</string>\n"
    else
        "        <string>guest</string>\n");
    for (extra_args) |arg| {
        try args_list.appendSlice(alloc, "        <string>");
        try args_list.appendSlice(alloc, arg);
        try args_list.appendSlice(alloc, "</string>\n");
    }

    const log_path = "/var/log/utmmd.log";
    const err_log_path = "/var/log/utmmd-err.log";

    const plist = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\{s}
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>SHELL</key>
        \\        <string>{s}</string>
        \\        <key>HOME</key>
        \\        <string>{s}</string>
        \\    </dict>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\{s}
        \\    <key>StandardOutPath</key>
        \\    <string>{s}</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
    , .{ name, args_list.items, env.shell, env.home, MACOS_KEEPALIVE_CONFIG, log_path, err_log_path });
    defer alloc.free(plist);

    // Write plist file
    {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(io, plist_path, .{ .truncate = true }) catch |err| {
            fail.err("install/write-plist", err);
        };
        defer f.close(io);
        f.writeStreamingAll(io, plist) catch |err| {
            fail.err("install/write-plist-content", err);
        };
    }

    // Enable first to clear any persisted disabled flag from a previous
    // uninstall/disable cycle — must be done while the label still exists
    // in launchd's persistent state (before bootout removes it).
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
    // Bootout stale registration, then bootstrap fresh.
    // Without bootout, bootstrap fails with errno=5/17 when the service
    // label is already registered — even if not running.
    bootoutMacOS(alloc, io, name);
    // Enable again after bootout — bootout re-sets the disabled flag on
    // the label, causing subsequent bootstrap to fail with errno=5
    // (Input/output error). This is the root cause of the recurring
    // "bootstrap errno=5" issue on macOS, especially after repeated
    // install/upgrade cycles.
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
    _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path });

    std.log.info("[svc] macOS service {s} installed", .{name});
}

/// Shared systemd service restart configuration — single source of truth
/// for both installLinux() and genInit(.linux).
const SYSTEMD_RESTART_CONFIG =
    \\Restart=on-failure
    \\RestartSec=5
    \\StartLimitBurst=3
    \\StartLimitIntervalSec=30
;

/// Shared launchd KeepAlive + ThrottleInterval configuration — single source
/// of truth for both installMacOS() and genInit(.macos).
/// SuccessfulExit=false ensures launchd restarts utmmd when it exits
/// (regardless of exit code). ThrottleInterval=5 prevents respawn storms.
const MACOS_KEEPALIVE_CONFIG =
    \\    <key>KeepAlive</key>
    \\    <dict>
    \\        <key>SuccessfulExit</key>
    \\        <false/>
    \\    </dict>
    \\    <key>ThrottleInterval</key>
    \\    <integer>5</integer>
;

fn installLinux(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName();
    const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
    defer alloc.free(unit_path);

    const svc_path = canonicalSvcPath();
    const env = .{ .shell = "/bin/bash", .home = "/root" };

    // Build ExecStart args: utmmd --role guest|host [extra_args...]
    var exec_args: std.ArrayListAligned(u8, null) = .empty;
    defer exec_args.deinit(alloc);
    try exec_args.appendSlice(alloc, svc_path);
    try exec_args.appendSlice(alloc, " --role ");
    try exec_args.appendSlice(alloc, if (role == .host) "host" else "guest");
    for (extra_args) |arg| {
        try exec_args.append(alloc, ' ');
        try exec_args.appendSlice(alloc, arg);
    }

    const unit = try std.fmt.allocPrint(alloc,
        \\[Unit]
        \\Description=UTM Monitor Daemon ({s})
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL={s}
        \\Environment=HOME={s}
        \\ExecStart={s}
        \\WorkingDirectory=/opt/utmm
        \\{s}
        \\StandardOutput=journal
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{
        if (role == .host) "host" else "guest",
        env.shell,
        env.home,
        exec_args.items,
        SYSTEMD_RESTART_CONFIG,
    });
    defer alloc.free(unit);

    // Write unit file
    {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(io, unit_path, .{ .truncate = true }) catch |err| {
            fail.err("install/write-unit", err);
        };
        defer f.close(io);
        f.writeStreamingAll(io, unit) catch |err| {
            fail.err("install/write-unit-content", err);
        };
    }

    // Reload and enable
    if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" })) {
        fail.msg("install/systemctl-daemon-reload", "daemon-reload failed", .{});
    }
    if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "enable", name })) {
        fail.msg("install/systemctl-enable", "enable {s} failed", .{name});
    }

    std.log.info("[svc] Linux service {s} installed", .{name});
}

fn installWindows(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName();
    const svc_path = canonicalSvcPath();

    // Build binPath: utmmd --svc --role guest|host [extra_args...]
    var bin_path: std.ArrayListAligned(u8, null) = .empty;
    defer bin_path.deinit(alloc);
    try bin_path.appendSlice(alloc, "\"");
    try bin_path.appendSlice(alloc, svc_path);
    try bin_path.appendSlice(alloc, "\" --svc --role ");
    try bin_path.appendSlice(alloc, if (role == .host) "host" else "guest");
    for (extra_args) |arg| {
        try bin_path.append(alloc, ' ');
        try bin_path.appendSlice(alloc, arg);
    }

    // Delete old service if exists
    runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name }); // best-effort: may not exist
    if (!runCmd(alloc, io, &[_][]const u8{ "sc", "delete", name })) {
        std.log.warn("[svc] sc delete {s} failed (may not be installed)", .{name});
    }

    // Create service
    if (!runCmd(alloc, io, &[_][]const u8{
        "sc", "create", name,
        "binPath=", bin_path.items,
        "start=", "auto",
    })) {
        fail.msg("install/sc-create", "failed to create service {s}", .{name});
    }

    // Configure failure actions — SCM restarts utmmd on crash.
    // After 3 consecutive restarts (<30s apart), SCM stops restarting
    // and utmmd's internal crash recovery (5 retries, exponential backoff)
    // takes over. reset=30 clears the failure count after 30s of uptime.
    _ = runCmd(alloc, io, &[_][]const u8{
        "sc", "failure", name,
        "reset=", "30",
        "actions=", "restart/5000/restart/5000/restart/5000/none/5000",
    });

    // Add firewall rule (delete any previous rule first, ignore error if not found)
    const rule_name = "UTM Monitor";
    runCmdQuiet(alloc, io, &[_][]const u8{
        "netsh", "advfirewall", "firewall", "delete", "rule",
        "name=" ++ rule_name,
    }); // best-effort: may not exist
    if (!runCmd(alloc, io, &[_][]const u8{
        "netsh", "advfirewall", "firewall", "add", "rule",
        "name=" ++ rule_name,
        "dir=", "in",
        "action=", "allow",
        "program=", svc_path,
        "enable=", "yes",
    })) {
        fail.msg("install/firewall", "failed to add firewall rule", .{});
    }

    std.log.info("[svc] Windows service {s} installed", .{name});
}

/// Remove service configuration only (no binary deletion, no process killing).
/// Used as rollback when forceInstall's start step fails.
fn uninstallServiceConfig(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) void {
    _ = _role;
    const name = svcName();
    switch (builtin.os.tag) {
        .macos => {
            const plist_path = std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name}) catch return;
            defer alloc.free(plist_path);
            bootoutMacOS(alloc, io, name);
            std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
        },
        .linux => {
            const unit_path = std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name}) catch return;
            defer alloc.free(unit_path);
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", name });
            std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" });
        },
        .windows => {
            runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name });
            runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", name });
            runCmdQuiet(alloc, io, &[_][]const u8{
                "netsh", "advfirewall", "firewall", "delete", "rule",
                "name=UTM Monitor",
            });
        },
        else => {},
    }
}

/// Uninstall service: acquire lock, stop, remove config, delete binary.
pub fn uninstall(io: std.Io, alloc: std.mem.Allocator) !void {
    InstallLock.acquire() catch |err| {
        fail.err("uninstall/lock", err);
    };
    defer InstallLock.release();

    // Stop and remove all service names (current + legacy)
    switch (builtin.os.tag) {
        .macos => {
            const all_names = [_][]const u8{ SVC_NAME_MACOS, "com.utmm.guest", "com.utmm.host", "com.utmm" };
            for (all_names) |name| {
                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);
                bootoutMacOS(alloc, io, name);
                std.Io.Dir.cwd().deleteFile(io, plist_path) catch {};
            }
        },
        .linux => {
            const all_names = [_][]const u8{ SVC_NAME_LINUX, "utmm-guest", "utmm-host", "utmm" };
            for (all_names) |name| {
                const unit_path = try std.fmt.allocPrint(alloc, "/etc/systemd/system/{s}.service", .{name});
                defer alloc.free(unit_path);
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "stop", name });
                runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "disable", name });
                std.Io.Dir.cwd().deleteFile(io, unit_path) catch {};
            }
            runCmdQuiet(alloc, io, &[_][]const u8{ "systemctl", "daemon-reload" });
        },
        .windows => {
            const all_names = [_][]const u8{ SVC_NAME_WINDOWS, "UTM-Monitor-Guest", "UTM-Monitor-Host", "UTM-Monitor" };
            for (all_names) |name| {
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "stop", name });
                runCmdQuiet(alloc, io, &[_][]const u8{ "sc", "delete", name });
            }
            // Remove firewall rules
            runCmdQuiet(alloc, io, &[_][]const u8{
                "netsh", "advfirewall", "firewall", "delete", "rule",
                "name=UTM Monitor",
            });
        },
        else => {},
    }

    // Delete binaries (both utmm and utmmd)
    const exe_path = canonicalPath();
    std.Io.Dir.cwd().deleteFile(io, exe_path) catch |err| {
        std.log.warn("[svc] could not delete binary at {s}: {}", .{ exe_path, err });
    };
    const svc_path = canonicalSvcPath();
    if (!std.mem.eql(u8, svc_path, exe_path)) {
        std.Io.Dir.cwd().deleteFile(io, svc_path) catch |err| {
            std.log.warn("[svc] could not delete utmmd binary at {s}: {}", .{ svc_path, err });
        };
    }

    // Kill any remaining utmm processes
    killAllUtmm(io, alloc) catch |err| {
        std.log.warn("[svc] uninstall killAllUtmm failed: {}", .{err});
    };

    std.log.info("[svc] uninstall complete", .{});
}

/// Start utmmd directly as a background process (no launchd/systemd/SCM).
/// Fallback for environments where the service manager is unavailable or
/// restricted (e.g. UTM macOS VMs with SIP-enforced launchd limits).
fn startDirect(alloc: std.mem.Allocator, io: std.Io, role: ServiceRole, extra_args: []const []const u8) !void {
    const svc_path = canonicalSvcPath();
    const role_str = if (role == .host) "host" else "guest";

    // Build command with role + all extra args (--hostname, --port, etc.).
    // These are the same args embedded in the service config; startDirect
    // bypasses the service manager so we must pass them explicitly.
    var cmd_buf: std.ArrayListAligned(u8, null) = .empty;
    defer cmd_buf.deinit(alloc);
    try cmd_buf.appendSlice(alloc, svc_path);
    try cmd_buf.appendSlice(alloc, " --role ");
    try cmd_buf.appendSlice(alloc, role_str);
    for (extra_args) |a| {
        try cmd_buf.append(alloc, ' ');
        try cmd_buf.appendSlice(alloc, a);
    }
    try cmd_buf.appendSlice(alloc, " > /var/log/utmmd.log 2>&1 &");
    const cmd = try cmd_buf.toOwnedSlice(alloc);
    defer alloc.free(cmd);
    std.log.info("[svc] starting utmmd directly: {s}", .{cmd});

    if (builtin.os.tag == .windows) {
        // Windows: cmd /c start /b <path> --role <role> <extra_args...>
        var win_args = std.ArrayListAligned([]const u8, null).init(alloc);
        defer win_args.deinit();
        try win_args.append(alloc, "cmd");
        try win_args.append(alloc, "/c");
        try win_args.append(alloc, "start");
        try win_args.append(alloc, "/b");
        try win_args.append(alloc, svc_path);
        try win_args.append(alloc, "--role");
        try win_args.append(alloc, role_str);
        for (extra_args) |a| try win_args.append(alloc, a);
        _ = runCmd(alloc, io, win_args.items);
    } else {
        _ = runCmd(alloc, io, &[_][]const u8{ "sh", "-c", cmd });
    }
    // Don't fail — best-effort background start. Give it a moment.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
}

/// Start the service.
pub fn start(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) !void {
    const name = svcName();
    switch (builtin.os.tag) {
        .macos => {
            // If already running, do nothing. Otherwise kickstart (restarts
            // a loaded-but-dead service) or bootstrap (loads from scratch).
            // installMacOS already bootstraps the service, so start is
            // normally a no-op; kickstart handles the edge case where the
            // service was installed but later stopped.
            if (isRunning(io, alloc, role)) {
                std.log.info("[svc] {s} already running in start()", .{name});
                return;
            }
            var launched_via_launchd = true;
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "kickstart", "-k", "system", name })) {
                // kickstart failed — service may not be loaded or already
                // in a broken state. Enable first to clear any persisted
                // disabled flag (must be done while label is still registered),
                // then bootout stale registration, then bootstrap fresh.
                std.log.info("[svc] kickstart failed, re-registering service...", .{});
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
                bootoutMacOS(alloc, io, name);
                // Enable after bootout — bootout re-sets the disabled flag.
                _ = runCmd(alloc, io, &[_][]const u8{ "launchctl", "enable", "system", name });
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

                const plist_path = try std.fmt.allocPrint(alloc, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer alloc.free(plist_path);

                // Retry bootstrap up to 3 times with 1-second delays.
                // launchd may still be processing a prior bootout; retries
                // resolve transient failures.
                // Note: bootstrap may return exit 0 even when it prints
                // "Bootstrap failed: 5" to stderr, so we verify in
                // launchctl list below — don't trust exit code alone.
                var bootstrapped = false;
                for (0..3) |attempt| {
                    if (runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootstrap", "system", plist_path })) {
                        // Verify bootstrap actually worked (not just exit 0)
                        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                        if (runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" })) |list| {
                            defer alloc.free(list);
                            if (std.mem.indexOf(u8, list, name) != null) {
                                bootstrapped = true;
                                std.log.info("[svc] bootstrap succeeded on attempt {d}", .{attempt + 1});
                                break;
                            }
                        }
                        std.log.warn("[svc] bootstrap attempt {d}: exit 0 but service not in launchctl list", .{attempt + 1});
                    } else {
                        std.log.warn("[svc] bootstrap attempt {d}/3 failed (non-zero exit), retrying in 1s...", .{attempt + 1});
                    }
                    std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch break;
                }
                if (!bootstrapped) {
                    // launchd bootstrap unavailable — start utmmd directly.
                    // Most commonly caused by the service being in "disabled"
                    // state in launchd (errno=5 Input/output error). The
                    // startDirect fallback bypasses launchd entirely.
                    std.log.warn("[svc] bootstrap failed, starting utmmd directly...", .{});
                    try startDirect(alloc, io, role, extra_args);
                    launched_via_launchd = false;
                }
            }
            // Verify launchd registration (skip if we fell back to startDirect).
            if (launched_via_launchd) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                const list_out = runCmdStdout(alloc, io, &[_][]const u8{ "launchctl", "list" });
                if (list_out) |stdout| {
                    defer alloc.free(stdout);
                    if (std.mem.indexOf(u8, stdout, name) == null) {
                        fail.msg("start/verify", "service {s} not found in launchctl list after start", .{name});
                    }
                }
            }
        },
        .linux => {
            if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "start", name })) {
                fail.msg("start/systemctl-start", "failed to start {s}", .{name});
            }
        },
        .windows => {
            if (!runCmd(alloc, io, &[_][]const u8{ "sc", "start", name })) {
                fail.msg("start/sc-start", "failed to start {s}", .{name});
            }
        },
        else => fail.msg("start", "unsupported platform", .{}),
    }
    std.log.info("[svc] {s} started", .{name});
}

/// Stop the service.
pub fn stop(io: std.Io, alloc: std.mem.Allocator, _role: ServiceRole) !void {
    _ = _role;
    const name = svcName();
    switch (builtin.os.tag) {
        .macos => {
            const target = std.fmt.allocPrint(alloc, "system/{s}", .{name}) catch return;
            defer alloc.free(target);
            if (!runCmd(alloc, io, &[_][]const u8{ "launchctl", "bootout", target })) {
                std.log.warn("[svc] stop {s}: bootout returned non-zero (may not be running)", .{name});
            }
        },
        .linux => {
            if (!runCmd(alloc, io, &[_][]const u8{ "systemctl", "stop", name })) {
                std.log.warn("[svc] stop {s}: systemctl stop returned non-zero (may not be running)", .{name});
            }
        },
        .windows => {
            if (!runCmd(alloc, io, &[_][]const u8{ "sc", "stop", name })) {
                std.log.warn("[svc] stop {s}: sc stop returned non-zero (may not be running)", .{name});
                // sc.exe stop can fail if the service was already deleted.
                // Fall back to terminating utmmd.exe directly via Toolhelp API.
                killUtmmd();
            }
        },
        else => {},
    }
}

/// Kill utmmd.exe on Windows using Toolhelp + TerminateProcess.
/// Public so that extractUtmmd in main.zig can call it when rename
/// fails with AccessDenied (old utmmd.exe locks the file).
pub fn killUtmmd() void {
    if (builtin.os.tag != .windows) return;

    const snap = w32.CreateToolhelp32Snapshot(w32.TH32CS_SNAPPROCESS, 0);
    if (snap == std.os.windows.INVALID_HANDLE_VALUE) {
        std.log.err("[svc] killUtmmd: CreateToolhelp32Snapshot failed", .{});
        return;
    }
    defer _ = w32.CloseHandle(snap);

    var pe = std.mem.zeroInit(w32.PROCESSENTRY32W, .{});
    pe.dwSize = @intCast(@sizeOf(w32.PROCESSENTRY32W));

    if (@intFromEnum(w32.Process32FirstW(snap, &pe)) == 0) return;

    var killed: usize = 0;
    while (true) {
        if (w32.isUtmmdExe(&pe.szExeFile)) {
            std.log.info("[svc] killUtmmd: killing PID {d}", .{pe.th32ProcessID});
            const h = w32.OpenProcess(w32.PROCESS_TERMINATE, .FALSE, pe.th32ProcessID) orelse {
                std.log.warn("[svc] killUtmmd: OpenProcess(PID {d}) failed", .{pe.th32ProcessID});
                if (@intFromEnum(w32.Process32NextW(snap, &pe)) == 0) break;
                continue;
            };
            _ = w32.TerminateProcess(h, 1);
            _ = w32.CloseHandle(h);
            killed += 1;
        }
        if (@intFromEnum(w32.Process32NextW(snap, &pe)) == 0) break;
    }
    if (killed > 0) {
        std.log.info("[svc] killUtmmd: killed {d} utmmd process(es)", .{killed});
    }
}

extern "c" fn getpid() c_int;

/// Get our own process ID, cross-platform.
pub fn getOwnPid() u32 {
    if (builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    return @intCast(getpid());
}

/// Kill all utmm processes (except self) — best-effort, never fails.
/// Uses pgrep/tasklist to enumerate PIDs, filtering out our own PID
/// so the installer doesn't kill itself.
fn killAllUtmm(io: std.Io, alloc: std.mem.Allocator) !void {
    const my_pid = getOwnPid();
    switch (builtin.os.tag) {
        .macos, .linux => {
            // Enumerate PIDs with pgrep; fall back to pkill if unavailable.
            const out = runCmdStdout(alloc, io, &[_][]const u8{ "pgrep", "-x", "utmm" }) orelse {
                std.log.warn("[svc] pgrep -x utmm failed, falling back to pkill", .{});
                runCmdQuiet(alloc, io, &[_][]const u8{ "pkill", "-9", "-x", "utmm" });
                return;
            };
            defer alloc.free(out);
            var killed: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |pid_str| {
                const pid = std.fmt.parseInt(u32, std.mem.trim(u8, pid_str, " \r"), 10) catch continue;
                if (pid == my_pid) {
                    std.log.debug("[svc] killAllUtmm: skipping own PID {d}", .{pid});
                    continue;
                }
                std.log.info("[svc] killAllUtmm: killing PID {d}", .{pid});
                _ = runCmdQuiet(alloc, io, &[_][]const u8{ "kill", "-9", pid_str });
                killed += 1;
            }
            if (killed > 0) {
                std.log.info("[svc] killAllUtmm: killed {d} process(es)", .{killed});
            }
        },
        .windows => {
            // Enumerate utmm.exe via Toolhelp snapshot → OpenProcess+TerminateProcess.
            // Native API works even on SYSTEM-privileged processes where taskkill /F fails.
            const snap = w32.CreateToolhelp32Snapshot(w32.TH32CS_SNAPPROCESS, 0);
            if (snap == std.os.windows.INVALID_HANDLE_VALUE) {
                std.log.err("[svc] killAllUtmm: CreateToolhelp32Snapshot failed", .{});
                return;
            }
            defer _ = w32.CloseHandle(snap);

            var pe = std.mem.zeroInit(w32.PROCESSENTRY32W, .{});
            pe.dwSize = @intCast(@sizeOf(w32.PROCESSENTRY32W));

            if (@intFromEnum(w32.Process32FirstW(snap, &pe)) == 0) return;

            var killed: usize = 0;
            while (true) {
                if (w32.isUtmmExe(&pe.szExeFile) and pe.th32ProcessID != my_pid) {
                    std.log.info("[svc] killAllUtmm: killing PID {d}", .{pe.th32ProcessID});
                    const h = w32.OpenProcess(w32.PROCESS_TERMINATE, .FALSE, pe.th32ProcessID) orelse {
                        std.log.warn("[svc] killAllUtmm: OpenProcess(PID {d}) failed", .{pe.th32ProcessID});
                        if (@intFromEnum(w32.Process32NextW(snap, &pe)) == 0) break;
                        continue;
                    };
                    _ = w32.TerminateProcess(h, 1);
                    _ = w32.CloseHandle(h);
                    killed += 1;
                }
                if (@intFromEnum(w32.Process32NextW(snap, &pe)) == 0) break;
            }
            if (killed > 0) {
                std.log.info("[svc] killAllUtmm: killed {d} process(es)", .{killed});
            }
        },
        else => {},
    }
}

/// Count utmm processes other than our own PID.
/// Returns 0 if no other utmm processes are running.
fn countOtherUtmmProcesses(alloc: std.mem.Allocator, io: std.Io, my_pid: u32) !usize {
    switch (builtin.os.tag) {
        .macos, .linux => {
            const out = runCmdStdout(alloc, io, &[_][]const u8{ "pgrep", "-x", "utmm" }) orelse return 0;
            defer alloc.free(out);
            var count: usize = 0;
            var iter = std.mem.tokenizeScalar(u8, out, '\n');
            while (iter.next()) |pid_str| {
                const pid = std.fmt.parseInt(u32, std.mem.trim(u8, pid_str, " \r"), 10) catch continue;
                if (pid != my_pid) count += 1;
            }
            return count;
        },
        .windows => {
            const snap = w32.CreateToolhelp32Snapshot(w32.TH32CS_SNAPPROCESS, 0);
            if (snap == std.os.windows.INVALID_HANDLE_VALUE) return 0;
            defer _ = w32.CloseHandle(snap);

            var pe = std.mem.zeroInit(w32.PROCESSENTRY32W, .{});
            pe.dwSize = @intCast(@sizeOf(w32.PROCESSENTRY32W));

            if (@intFromEnum(w32.Process32FirstW(snap, &pe)) == 0) return 0;

            var count: usize = 0;
            while (true) {
                if (w32.isUtmmExe(&pe.szExeFile) and pe.th32ProcessID != my_pid) {
                    count += 1;
                }
                if (@intFromEnum(w32.Process32NextW(snap, &pe)) == 0) break;
            }
            return count;
        },
        else => return 0,
    }
}

/// Wait up to `timeout_ms` for all other utmm processes to exit.
/// Returns true if no other utmm processes remain, false on timeout.
/// Placed between stop() and killAllUtmm() so selfCopy has a clean
/// filesystem — prevents "Text file busy" on Linux.
fn waitForProcessExit(io: std.Io, alloc: std.mem.Allocator, timeout_ms: u64) bool {
    const my_pid = getOwnPid();
    const poll_interval_ms: u64 = 100;
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        const remaining = countOtherUtmmProcesses(alloc, io, my_pid) catch |err| {
            std.log.debug("[svc] countOtherUtmmProcesses error: {} (continuing wait)", .{err});
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch return false;
            elapsed += poll_interval_ms;
            continue;
        };

        if (remaining == 0) {
            std.log.info("[svc] all other utmm processes exited after {d}ms", .{elapsed});
            return true;
        }

        std.log.info("[svc] waiting for {d} other utmm process(es) to exit... ({d}ms elapsed)", .{ remaining, elapsed });
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch return false;
        elapsed += poll_interval_ms;
    }

    std.log.warn("[svc] timeout after {d}ms — proceeding with killAllUtmm", .{elapsed});
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// Binary type validation — prevent cross-platform binary overwrite
// ═══════════════════════════════════════════════════════════════════════════

/// Binary magic numbers for platform detection.
const MAGIC_ELF = [4]u8{ 0x7f, 'E', 'L', 'F' };
const MAGIC_MACHO64 = [4]u8{ 0xcf, 0xfa, 0xed, 0xfe }; // 64-bit LE
const MAGIC_MACHO32 = [4]u8{ 0xce, 0xfa, 0xed, 0xfe }; // 32-bit LE
const MAGIC_PE = [2]u8{ 'M', 'Z' };

/// Return a human-readable description of the binary format detected in `head`.
fn describeBinary(head: []const u8) []const u8 {
    if (head.len >= 2 and std.mem.eql(u8, head[0..2], &MAGIC_PE)) return "PE (Windows)";
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], &MAGIC_ELF)) return "ELF (Linux)";
    if (head.len >= 4 and (std.mem.eql(u8, head[0..4], &MAGIC_MACHO64) or
        std.mem.eql(u8, head[0..4], &MAGIC_MACHO32))) return "Mach-O (macOS)";
    return "unknown format";
}

/// Read first 4 bytes of a binary and verify the magic matches the current platform.
/// Call before selfCopy to prevent accidental cross-platform binary overwrite
/// (e.g. deploying an ELF binary to a macOS host).
fn validateBinaryType(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(io, path, .{ .mode = .read_only }) catch |err| {
        fail.err("validateBinary/open", err);
    };
    defer f.close(io);

    var head: [4]u8 = [_]u8{0} ** 4;
    var read_buf: [256]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    const n = reader.interface.readSliceShort(&head) catch |err| {
        fail.err("validateBinary/read", err);
    };

    if (n < 4) {
        fail.msg("validateBinary", "file too small ({d} bytes) to be a valid binary", .{n});
    }

    switch (builtin.os.tag) {
        .linux => {
            if (!std.mem.eql(u8, &head, &MAGIC_ELF)) {
                fail.msg("validateBinary", "expected ELF (Linux) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        .macos => {
            if (!std.mem.eql(u8, &head, &MAGIC_MACHO64) and
                !std.mem.eql(u8, &head, &MAGIC_MACHO32))
            {
                fail.msg("validateBinary", "expected Mach-O (macOS) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        .windows => {
            if (!std.mem.eql(u8, head[0..2], &MAGIC_PE)) {
                fail.msg("validateBinary", "expected PE (Windows) binary but detected {s} — wrong platform binary?", .{describeBinary(&head)});
            }
        },
        else => {}, // Unknown platform — skip check
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Self-copy: copy current binary to canonical path
// ═══════════════════════════════════════════════════════════════════════════

/// Copy the current process binary to the canonical install path.
/// Uses tmp file + rename for atomic replacement.
/// Validates binary magic before copying to prevent cross-platform mistakes.
pub fn selfCopy(io: std.Io, alloc: std.mem.Allocator) !void {
    const dest = canonicalPath();

    // Get current executable path
    var self_buf: [4096]u8 = undefined;
    const self_len = std.process.executablePath(io, &self_buf) catch |err| {
        fail.err("selfCopy/executablePath", err);
    };
    const self_path = self_buf[0..self_len];

    // Already at canonical path — nothing to do
    if (std.mem.eql(u8, self_path, dest)) {
        std.log.info("[svc] already at canonical path", .{});
        return;
    }

    // Validate binary matches current platform before copying
    validateBinaryType(io, self_path) catch |err| {
        fail.err("selfCopy/binary-check", err);
    };

    // Ensure canonical directory exists
    const dest_dir = canonicalDir();
    std.Io.Dir.cwd().createDirPath(io, dest_dir) catch |err| {
        fail.err("selfCopy/mkdir", err);
    };

    // Copy to temp file first, then rename (atomic on same filesystem)
    const tmp_path = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}\\utmm.tmp.exe", .{dest_dir})
    else
        try std.fmt.allocPrint(alloc, "{s}/utmm.tmp", .{dest_dir});
    defer alloc.free(tmp_path);

    // Remove stale tmp file
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Copy with executable permissions on POSIX (chmod removed in Zig 0.16.0)
    copyFile(io, alloc, self_path, tmp_path, builtin.os.tag != .windows) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail.err("selfCopy/copy", err);
    };

    // Atomic rename tmp → dest
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dest, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        // On EXDEV (cross-filesystem), try copy+delete fallback
        if (err == error.CrossDevice) {
            copyFile(io, alloc, tmp_path, dest, builtin.os.tag != .windows) catch |err2| {
                fail.err("selfCopy/copy-fallback", err2);
            };
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        } else {
            fail.err("selfCopy/rename", err);
        }
    };

    // macOS: copyFile + rename strips the ad-hoc code signature applied by
    // the Zig compiler.  Re-sign so the kernel doesn't SIGKILL the process.
    if (builtin.os.tag == .macos) {
        if (!runCmd(alloc, io, &[_][]const u8{ "codesign", "--force", "--sign", "-", dest })) {
            std.log.warn("[svc] selfCopy: codesign re-sign failed — ad-hoc signature may be missing", .{});
        }
    }

    std.log.info("[svc] self-copied to canonical path {s}", .{dest});
}

/// Copy src to dst. Uses 64KB chunks. If make_executable is true,
/// sets 755 permissions on the destination file (POSIX only).
fn copyFile(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, make_executable: bool) !void {
    _ = alloc;
    const cwd = std.Io.Dir.cwd();
    const src = cwd.openFile(io, src_path, .{ .mode = .read_only }) catch |err| {
        fail.err("selfCopy/open-src", err);
    };
    defer src.close(io);

    const dst_file = if (make_executable and builtin.os.tag != .windows)
        cwd.createFile(io, dst_path, .{ .truncate = true, .permissions = @enumFromInt(0o755) })
    else
        cwd.createFile(io, dst_path, .{ .truncate = true });
    const dst = dst_file catch |err| {
        fail.err("selfCopy/create-dst", err);
    };
    defer dst.close(io);

    var buf: [65536]u8 = undefined;
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = src.reader(io, &read_buf);
    var writer = dst.writer(io, &write_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch |err| {
            fail.err("selfCopy/read", err);
        };
        if (n == 0) break;
        writer.interface.writeAll(buf[0..n]) catch |err| {
            fail.err("selfCopy/write", err);
        };
    }
    writer.interface.flush() catch |err| {
        std.log.warn("[svc] copyFile flush failed: {}", .{err});
    };

    // fsync to ensure data is on disk before rename
    dst.sync(io) catch |err| {
        std.log.warn("[svc] copyFile sync failed: {}", .{err});
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Core operations: forceInstall / ensure
// ═══════════════════════════════════════════════════════════════════════════

/// Copy platform-specific deployment binaries from the source exe directory
/// to the canonical install directory (serve-dir). Only called for Host mode —
/// these binaries are served to Guests for auto-upgrade.
///
/// Best-effort: missing source files are skipped with a warning.
/// Skips the source binary itself (the one we just selfCopy'd).
fn copySiblingBinariesToServeDir(io: std.Io, alloc: std.mem.Allocator, src_dir: []const u8) void {
    const dst_dir = canonicalDir();

    // If source and destination are the same directory, nothing to do.
    if (std.mem.eql(u8, src_dir, dst_dir)) {
        std.log.info("[svc] Platform binaries already in serve-dir, skipping copy.", .{});
        return;
    }

    var src_dir_handle = std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch |err| {
        std.log.warn("[svc] Cannot open source dir {s}: {} — skipping platform binary copy", .{ src_dir, err });
        return;
    };
    defer src_dir_handle.close(io);

    var iter = src_dir_handle.iterate();
    var copied: usize = 0;

    while (true) {
        const entry = iter.next(io) catch {
            std.log.warn("[svc] Failed to iterate source dir", .{});
            break;
        } orelse break;
        const name = entry.name;
        // Match platform binary files: utmm-* or utmm*.exe
        if (!std.mem.startsWith(u8, name, "utmm-") and !(std.mem.startsWith(u8, name, "utmm") and std.mem.endsWith(u8, name, ".exe"))) {
            continue;
        }
        // Skip the main binary (utmm or utmm.exe)
        if (std.mem.eql(u8, name, "utmm") or std.mem.eql(u8, name, "utmm.exe")) continue;

        const src_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, name }) catch continue;
        defer alloc.free(src_path);
        const dst_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, name }) catch continue;
        defer alloc.free(dst_path);

        copyFile(io, alloc, src_path, dst_path, builtin.os.tag != .windows) catch |err| {
            std.log.warn("[svc] Failed to copy {s}: {}", .{name, err});
            continue;
        };
        std.log.info("[svc] Copied {s} to serve-dir", .{name});
        copied += 1;
    }

    if (copied > 0) {
        std.log.info("[svc] Copied {d} platform binaries to serve-dir", .{copied});
    } else {
        std.log.warn("[svc] No platform binaries found in source directory {s} — Host will not serve upgrades.", .{src_dir});
    }
}

/// Force install — unconditional overwrite.
/// Stops any running service, kills all utmm processes, copies self to
/// canonical path, registers service config, and starts the service.
/// Fail-fast: any unexpected error calls fail() and does not return.
/// Force-install the service (public entry point, acquires singleton lock).
/// Called from main.zig --install path.
pub fn forceInstall(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    InstallLock.acquire() catch |err| {
        fail.err("forceInstall/lock", err);
    };
    defer InstallLock.release();
    forceInstallInternal(io, alloc, role, extra_args);
}

/// Force-install without acquiring the lock (caller must hold it).
fn forceInstallInternal(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName();
    const dest_path = canonicalPath();
    std.log.info("[svc] force installing {s}...", .{name});

    // 1. Stop any running service (ignore errors — may not be installed)
    stop(io, alloc, role) catch |err| {
        std.log.warn("[svc] stop before install: {} (continuing)", .{err});
    };

    // 1.5. Wait for old processes to fully exit before touching the binary.
    // On Linux, systemctl stop may return before the process has released
    // its file descriptors, causing selfCopy to fail with "Text file busy".
    // 5-second timeout covers the typical case; killAllUtmm handles stragglers.
    _ = waitForProcessExit(io, alloc, 5000);

    // 2. Kill any lingering utmm processes (now PID-aware; excludes self)
    killAllUtmm(io, alloc) catch |err| {
        std.log.warn("[svc] forceInstall killAllUtmm failed: {}", .{err});
    };

    // 3. Copy self to canonical path
    selfCopy(io, alloc) catch |err| {
        fail.err("forceInstall/selfCopy", err);
    };

    // macOS: clear Gatekeeper quarantine on installed binaries
    clearQuarantine(alloc, io, dest_path);
    clearQuarantine(alloc, io, canonicalSvcPath());

    // 3.1. Create/refresh symlink in system PATH so any user can
    // run `utmm` without specifying the full /opt/utmm/utmm path.
    ensurePathSymlink(io, alloc);

    // 3.5. Host mode: copy platform binaries + ver.txt to serve-dir
    // so Guests can auto-upgrade to the correct version.
    if (role == .host) {
        var src_buf: [4096]u8 = undefined;
        if (std.process.executablePath(io, &src_buf)) |src_len| {
            const src_dir = std.fs.path.dirname(src_buf[0..src_len]) orelse ".";
            copySiblingBinariesToServeDir(io, alloc, src_dir);
        } else |_| {
            std.log.warn("[svc] Cannot get exe path — platform binary copy skipped.", .{});
        }
    }

    // 4. Install/overwrite service configuration.
    // If this fails, remove the binary we just copied so the system isn't
    // left in a state with a binary but no service.
    install(io, alloc, role, extra_args) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, dest_path) catch |rm_err| {
            std.log.warn("[svc] cleanup binary after install failure: {}", .{rm_err});
        };
        fail.err("forceInstall/install", err);
    };

    // 5. Start service.
    // Don't rollback on failure — binary and service config are already in
    // place. System-level recovery (Restart=on-failure, KeepAlive, reboot,
    // or manual intervention) can bring the service back. Deleting everything
    // leaves the VM unreachable with no recovery path — especially critical
    // for auto-upgrade where the old Guest process was already killed.
    start(io, alloc, role, extra_args) catch |err| {
        std.log.err("[svc] start failed for {s}: {} — binary and config preserved, not rolling back", .{ name, err });
        fail.err("forceInstall/start", err);
    };

    std.log.info("[svc] {s} installed and running", .{name});
}

/// Ensure the service is installed and running.
/// If already running: log and return.
/// If not running: acquire singleton lock, then call forceInstallInternal.
pub fn ensure(io: std.Io, alloc: std.mem.Allocator, role: ServiceRole, extra_args: []const []const u8) void {
    const name = svcName();
    if (isRunning(io, alloc, role)) {
        std.log.info("[svc] {s} service already running", .{name});
        std.debug.print("utmm {s} service is running.\n", .{if (role == .host) "host" else "guest"});
        return;
    }
    std.log.info("[svc] {s} service not running — acquiring lock...", .{name});
    InstallLock.acquire() catch |err| {
        fail.err("ensure/lock", err);
    };
    defer InstallLock.release();
    forceInstallInternal(io, alloc, role, extra_args);
}


// ═══════════════════════════════════════════════════════════════════════════
/// Compute SHA256 of a file at the given path. Returns hex string or null on error.
fn fileSha256Hex(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var read_buf: [65536]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return null;
        if (n == 0) break;
        sha.update(buf[0..n]);
    }

    var hash: [32]u8 = undefined;
    sha.final(&hash);

    var hex: [64]u8 = undefined;
    for (hash, 0..) |b, j| {
        hex[j * 2] = "0123456789abcdef"[b >> 4];
        hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return alloc.dupe(u8, &hex) catch null;
}

/// Check whether the installed utmmd needs updating.
/// Returns true if utmmd binary is missing or its SHA256 differs from the
/// comptime-embedded value.  No config file needed — just compare against
/// the hash baked into the current binary at compile time.
pub fn shouldUpdateUtmmd(io: std.Io, alloc: std.mem.Allocator, comptime embedded_sha256_hex: []const u8) bool {
    const svc_path = canonicalSvcPath();

    const installed_hash = fileSha256Hex(io, alloc, svc_path) orelse {
        std.log.debug("[svc] utmmd binary missing at {s}, needs install", .{svc_path});
        return true;
    };
    defer alloc.free(installed_hash);

    if (!std.mem.eql(u8, installed_hash, embedded_sha256_hex)) {
        std.log.debug("[svc] utmmd hash differs (installed={s}, embedded={s}), needs update", .{ installed_hash[0..@min(installed_hash.len, 16)], embedded_sha256_hex[0..@min(embedded_sha256_hex.len, 16)] });
        return true;
    }

    return false;
}

/// No-op stub — previously persisted metadata to /opt/utmm/utmm.conf.
/// Kept so callers in main.zig don't need to change.
pub fn saveUtmmdMeta(
    _: std.Io,
    _: std.mem.Allocator,
    _: ServiceRole,
    _: []const []const u8,
    comptime _: []const u8,
) void {}

// Platform detection + init script generation (moved from host.zig, Task 9)
// ═══════════════════════════════════════════════════════════════════════════

/// Supported operating system platforms for init script generation.
pub const Platform = enum {
    linux,
    macos,
    windows,

    pub fn detect() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .linux,
        };
    }

    pub fn asStr(self: Platform) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
        };
    }
};

/// Generate auto-start script/config template for the given platform.
pub fn genInit(platform: Platform) []const u8 {
    return switch (platform) {
        .macos =>
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.utmmd</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/utmm/utmmd</string>
        \\        <string>--role</string>
        \\        <string>guest</string>
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>SHELL</key>
        \\        <string>/bin/zsh</string>
        \\        <key>HOME</key>
        \\        <string>/var/root</string>
        \\    </dict>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        ++ MACOS_KEEPALIVE_CONFIG ++
        \\    <key>StandardOutPath</key>
        \\    <string>/var/log/utmmd.log</string>
        \\</dict>
        \\</plist>
        \\
        \\<!-- Install: sudo cp this file to /Library/LaunchDaemons/com.utmmd.plist -->
        \\<!-- Load:    sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmmd.plist -->
        \\
        \\<!-- Host mode: change --role guest to --role host -->
        ,
        .linux =>
        \\[Unit]
        \\Description=UTM Monitor Service (utmmd)
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\Environment=SHELL=/bin/bash
        \\Environment=HOME=/root
        \\ExecStart=/opt/utmm/utmmd --role guest
        \\WorkingDirectory=/opt/utmm
        ++ SYSTEMD_RESTART_CONFIG ++
        \\StandardOutput=journal
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
        \\<!-- Install: sudo cp this file to /etc/systemd/system/utmmd.service -->
        \\<!-- Enable:  sudo systemctl daemon-reload && sudo systemctl enable utmmd -->
        \\
        \\<!-- Host mode: change --role guest to --role host in ExecStart -->
        ,
        .windows =>
        \\:: UTM Monitor auto-start service (utmmd)
        \\::
        \\:: Install: sc create "UTM-MonitorD" binPath= "\"C:\opt\utmm\utmmd.exe\" --role guest" start= auto
        \\::           sc failure "UTM-MonitorD" reset=30 actions=restart/5000/restart/5000/restart/5000/none/5000
        \\::           sc start "UTM-MonitorD"
        \\:: Remove:  sc stop "UTM-MonitorD" & sc delete "UTM-MonitorD"
        \\
        \\:: Host mode: change --role guest to --role host in binPath
        ,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// PATH symlink — make utmm globally accessible without full path
// ═══════════════════════════════════════════════════════════════════════════

/// Create/refresh a symlink in the system default executable search path
/// so any user (root, sshd login, etc.) can run `utmm` without specifying
/// the full /opt/utmm/utmm path.
///
/// POSIX: /usr/local/bin/utmm → /opt/utmm/utmm
/// Windows: Add C:\opt\utmm to system PATH via registry
fn ensurePathSymlink(io: std.Io, alloc: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        ensureWindowsPath(io, alloc);
    } else {
        ensurePosixSymlink(io);
    }
}

fn ensurePosixSymlink(io: std.Io) void {
    const link_path: [:0]const u8 = "/usr/local/bin/utmm";
    const target_path: [:0]const u8 = @ptrCast(canonicalPath());

    // 检查软连接是否已存在且指向正确位置
    var rlbuf: [4096]u8 = undefined;
    const nr = std.c.readlink(link_path, &rlbuf, rlbuf.len);
    if (nr > 0) {
        const existing = rlbuf[0..@intCast(nr)];
        if (std.mem.eql(u8, existing, target_path)) {
            std.log.info("[svc] symlink ok: {s} -> {s}", .{ link_path, target_path });
            return;
        }
        // 指向了错误位置 — 删除旧连接
        std.Io.Dir.cwd().deleteFile(io, link_path) catch |err| {
            std.log.warn("[svc] remove stale symlink {s}: {}", .{ link_path, err });
        };
    }

    // /usr/local/bin 在所有 macOS/Linux 系统上都存在，
    // 如果不存在则 symlink 会失败，下面会处理该错误。

    // 创建 Symlink
    if (std.c.symlink(target_path, link_path) != 0) {
        std.log.warn("[svc] symlink {s} -> {s} failed (continuing)", .{ link_path, target_path });
    } else {
        std.log.info("[svc] symlink created: {s} -> {s}", .{ link_path, target_path });
    }
}

fn ensureWindowsPath(io: std.Io, alloc: std.mem.Allocator) void {
    _ = io;
    const w = std.os.windows;

    const HKEY_LOCAL_MACHINE: w.HKEY = @ptrFromInt(0x80000002);
    // REGSAM 在 Zig 0.16.0 中是 ACCESS_MASK packed struct，需要用 @bitCast
    const KEY_READ_WRITE: w.REGSAM = @bitCast(@as(w.DWORD, 0x20019 | 0x20006));
    const REG_SZ: w.DWORD = 1;
    const REG_EXPAND_SZ: w.DWORD = 2;

    const RegOpenKeyExW = @extern(
        *const fn (w.HKEY, [*:0]const u16, w.DWORD, w.REGSAM, *w.HKEY) callconv(.winapi) w.LSTATUS,
        .{ .name = "RegOpenKeyExW", .library_name = "advapi32" },
    );
    const RegQueryValueExW = @extern(
        *const fn (w.HKEY, [*:0]const u16, ?*w.DWORD, ?*w.DWORD, ?[*]u8, *w.DWORD) callconv(.winapi) w.LSTATUS,
        .{ .name = "RegQueryValueExW", .library_name = "advapi32" },
    );
    const RegSetValueExW = @extern(
        *const fn (w.HKEY, [*:0]const u16, w.DWORD, w.DWORD, [*]const u8, w.DWORD) callconv(.winapi) w.LSTATUS,
        .{ .name = "RegSetValueExW", .library_name = "advapi32" },
    );
    const RegCloseKey = @extern(
        *const fn (w.HKEY) callconv(.winapi) w.LSTATUS,
        .{ .name = "RegCloseKey", .library_name = "advapi32" },
    );
    const SendMessageTimeoutW = @extern(
        *const fn (w.HWND, w.UINT, w.LPARAM, w.LPARAM, w.UINT, w.UINT, ?*w.DWORD_PTR) callconv(.winapi) w.LPARAM,
        .{ .name = "SendMessageTimeoutW", .library_name = "user32" },
    );

    const subkey_u8 = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";
    const subkey_u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, subkey_u8) catch {
        std.log.warn("[svc] PATH: utf8→utf16 failed", .{});
        return;
    };
    defer alloc.free(subkey_u16);

    var key: w.HKEY = undefined;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, @ptrCast(subkey_u16), 0, KEY_READ_WRITE, &key) != 0) {
        std.log.warn("[svc] PATH: open registry key failed", .{});
        return;
    }
    defer _ = RegCloseKey(key);

    // 读取当前 PATH 值
    const value_name_u8 = "Path";
    const value_name_u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, value_name_u8) catch {
        std.log.warn("[svc] PATH: value name utf8→utf16 failed", .{});
        return;
    };
    defer alloc.free(value_name_u16);

    var data_type: w.DWORD = 0;
    var data_size: w.DWORD = 0;
    // 先查询大小
    _ = RegQueryValueExW(key, @ptrCast(value_name_u16), null, &data_type, null, &data_size);

    if (data_size == 0) {
        std.log.warn("[svc] PATH: empty or missing Path value", .{});
        return;
    }

    const buf = alloc.alloc(u8, @intCast(data_size)) catch {
        std.log.warn("[svc] PATH: alloc {d} bytes failed", .{data_size});
        return;
    };
    defer alloc.free(buf);

    if (RegQueryValueExW(key, @ptrCast(value_name_u16), null, &data_type, buf.ptr, &data_size) != 0) {
        std.log.warn("[svc] PATH: query value failed", .{});
        return;
    }

    // 检查 C:\opt\utmm 是否已在 PATH 中
    const add_dir = "C:\\opt\\utmm";
    // PATH 条目以 ';' 分隔，使用大小写不敏感匹配 (Windows)
    // data_size 包含末尾 null — 去掉 null 得到实际字符串
    const existing = buf[0 .. @as(usize, @intCast(data_size)) -| 1];
    if (std.ascii.indexOfIgnoreCase(existing, add_dir)) |_| {
        std.log.info("[svc] PATH: already contains {s}", .{add_dir});
        return;
    }

    // 追加 C:\opt\utmm 到 PATH
    var new_path: std.ArrayList(u8) = .empty;
    defer new_path.deinit(alloc);
    new_path.appendSlice(alloc, existing) catch {
        std.log.warn("[svc] PATH: alloc for new path failed", .{});
        return;
    };
    // 确保末尾有分号分隔
    if (existing.len > 0 and existing[existing.len - 1] != ';') {
        new_path.append(alloc, ';') catch return;
    }
    new_path.appendSlice(alloc, add_dir) catch {
        std.log.warn("[svc] PATH: alloc for append failed", .{});
        return;
    };
    // 确保以 null 结尾（REG_SZ / REG_EXPAND_SZ）
    new_path.append(alloc, 0) catch return;

    const set_type: w.DWORD = if (data_type == REG_EXPAND_SZ) REG_EXPAND_SZ else REG_SZ;
    const set_size: w.DWORD = @intCast(new_path.items.len);
    if (RegSetValueExW(key, @ptrCast(value_name_u16), 0, set_type, new_path.items.ptr, set_size) != 0) {
        std.log.warn("[svc] PATH: set value failed", .{});
        return;
    }

    // 广播环境变量变更（通知所有窗口）
    const HWND_BROADCAST: w.HWND = @ptrFromInt(0xFFFF);
    const WM_SETTINGCHANGE: w.UINT = 0x001A;
    const SMTO_ABORTIFHUNG: w.UINT = 0x0002;
    const env_ptr: isize = @bitCast(@intFromPtr("Environment"));
    _ = SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, env_ptr, SMTO_ABORTIFHUNG, 5000, null);

    std.log.info("[svc] PATH: added {s} to system PATH", .{add_dir});
}

test "Platform.detect returns valid platform" {
    const p = Platform.detect();
    _ = switch (p) {
        .macos, .linux, .windows => true,
    };
}

test "genInit - linux has systemd service" {
    const script = genInit(.linux);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Unit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--role guest") != null);
}

test "genInit - macos has launchd plist" {
    const script = genInit(.macos);
    try std.testing.expect(std.mem.indexOf(u8, script, "com.utmmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "plist") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/opt/utmm/utmmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--role") != null);
}

test "genInit - windows has sc command" {
    const script = genInit(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "sc create") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "UTM-MonitorD") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "C:\\opt\\utmm\\utmmd.exe") != null);
}

// ========== Tests ==========

test "describeBinary - ELF" {
    const head = [_]u8{ 0x7f, 'E', 'L', 'F' };
    try std.testing.expectEqualStrings("ELF (Linux)", describeBinary(&head));
}

test "describeBinary - Mach-O 64-bit" {
    const head = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe };
    try std.testing.expectEqualStrings("Mach-O (macOS)", describeBinary(&head));
}

test "describeBinary - Mach-O 32-bit" {
    const head = [_]u8{ 0xce, 0xfa, 0xed, 0xfe };
    try std.testing.expectEqualStrings("Mach-O (macOS)", describeBinary(&head));
}

test "describeBinary - PE" {
    const head = [_]u8{ 'M', 'Z', 0, 0 };
    try std.testing.expectEqualStrings("PE (Windows)", describeBinary(&head));
}

test "describeBinary - unknown" {
    const head = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "describeBinary - short slice" {
    const head = [_]u8{'M'};
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "describeBinary - empty slice" {
    const head = [_]u8{};
    try std.testing.expectEqualStrings("unknown format", describeBinary(&head));
}

test "magic constants - ELF" {
    try std.testing.expectEqual(@as(u8, 0x7f), MAGIC_ELF[0]);
    try std.testing.expectEqual(@as(u8, 'E'), MAGIC_ELF[1]);
    try std.testing.expectEqual(@as(u8, 'L'), MAGIC_ELF[2]);
    try std.testing.expectEqual(@as(u8, 'F'), MAGIC_ELF[3]);
}

test "magic constants - Mach-O 64 LE" {
    // 0xFEEDFACF in little-endian
    try std.testing.expectEqual(@as(u8, 0xcf), MAGIC_MACHO64[0]);
    try std.testing.expectEqual(@as(u8, 0xfa), MAGIC_MACHO64[1]);
    try std.testing.expectEqual(@as(u8, 0xed), MAGIC_MACHO64[2]);
    try std.testing.expectEqual(@as(u8, 0xfe), MAGIC_MACHO64[3]);
}

test "magic constants - PE" {
    try std.testing.expectEqual(@as(u8, 'M'), MAGIC_PE[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), MAGIC_PE[1]);
}
