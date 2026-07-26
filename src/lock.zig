//! Process singleton lock via utmm.lock file.
//!
//! Prevents concurrent install/upgrade/reinstall/stop/start operations from
//! corrupting each other. Uses a PID-based lock file with crash-residue
//! detection: if the lock file is older than 20 seconds, it's considered
//! a crash residue and may be stolen.
//!
//! Lock lifecycle:
//!   acquire() — create utmm.lock with own PID, retry up to 3×5s on conflict
//!   release() — delete utmm.lock
//!
//! The lock file lives in the current working directory.

const builtin = @import("builtin");
const std = @import("std");

/// Lock file name in the current working directory.
const LOCK_FILE = "utmm.lock";

/// Maximum age (ms) before a lock file is considered crash residue.
const STALE_AGE_MS = 20_000;

/// Retry interval (ms) when lock is held by another live process.
const RETRY_INTERVAL_MS = 5000;

/// Maximum retry attempts.
const MAX_RETRIES = 3;

/// PID type used across platforms.
const Pid = if (builtin.os.tag == .windows) std.os.windows.DWORD else std.posix.system.pid_t;

/// Human-readable error messages for acquire failures.
pub const LockError = error{
    /// Another process holds the lock and is still alive after all retries.
    LockHeld,
    /// The lock file could not be created or read (I/O error).
    LockIo,
};

/// Get the current process ID.
fn getMyPid() Pid {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentProcessId();
    }
    return std.posix.system.getpid();
}

/// Try to acquire the singleton lock.
///
/// On success the caller owns the lock and must call release().
/// On failure the lock is NOT held and the caller should abort.
pub fn acquire(io: std.Io, alloc: std.mem.Allocator) LockError!void {
    const cwd = std.Io.Dir.cwd();
    const my_pid = getMyPid();

    var retries: u32 = 0;
    while (true) {
        // Try to create the lock file atomically.
        if (try createLockFile(io, alloc, cwd, my_pid)) {
            return; // acquired successfully
        }

        // Lock exists — check if we can steal it.
        if (try stealStaleLock(io, alloc, cwd, my_pid)) {
            return; // stole successfully
        }

        // Lock is held by another live process.
        retries += 1;
        if (retries > MAX_RETRIES) {
            std.log.warn("[lock] lock held by another process after {d} retries, giving up", .{MAX_RETRIES});
            return error.LockHeld;
        }

        std.log.info("[lock] lock held by another process, retry {d}/{d} in {d}s...", .{ retries, MAX_RETRIES, @divTrunc(RETRY_INTERVAL_MS, 1000) });
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(RETRY_INTERVAL_MS), .awake) catch {
            return error.LockIo;
        };
    }
}

/// Release the singleton lock by deleting the lock file.
pub fn release(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, LOCK_FILE) catch |err| {
        std.log.warn("[lock] failed to delete lock file: {}", .{err});
    };
}

/// Try to create the lock file atomically with our PID. Returns true on success.
fn createLockFile(io: std.Io, alloc: std.mem.Allocator, cwd: std.Io.Dir, my_pid: Pid) LockError!bool {
    const pid_u32: u32 = @intCast(my_pid);
    const pid_str = std.fmt.allocPrint(alloc, "{d}", .{pid_u32}) catch |e| {
        std.log.err("[lock] allocPrint failed: {}", .{e});
        return error.LockIo;
    };
    defer alloc.free(pid_str);

    if (builtin.os.tag == .windows) {
        // Windows: CreateFileW with CREATE_NEW is atomic.
        const w = std.os.windows;
        const BOOL = w.BOOL;
        const HANDLE = w.HANDLE;
        const DWORD = w.DWORD;

        const GENERIC_WRITE: DWORD = 0x40000000;
        const CREATE_NEW: DWORD = 1;
        const FILE_ATTRIBUTE_NORMAL: DWORD = 128;
        const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

        const CreateFileW = @extern(
            *const fn (lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE,
            .{ .name = "CreateFileW", .library_name = "kernel32" },
        );
        const CloseHandle = @extern(
            *const fn (hObject: HANDLE) callconv(.winapi) BOOL,
            .{ .name = "CloseHandle", .library_name = "kernel32" },
        );
        const WriteFile = @extern(
            *const fn (hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL,
            .{ .name = "WriteFile", .library_name = "kernel32" },
        );

        // utf8ToUtf16LeWithNull removed in 0.16.0, use utf8ToUtf16LeAllocZ
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, LOCK_FILE) catch |e| {
            std.log.err("[lock] utf8ToUtf16LeAllocZ failed: {}", .{e});
            return error.LockIo;
        };
        defer alloc.free(path_w);

        const handle = CreateFileW(
            path_w.ptr,
            GENERIC_WRITE,
            0, // exclusive access
            null, // no security attributes
            CREATE_NEW, // fail if exists — atomic
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) {
            const err = w.GetLastError();
            if (err == .FILE_EXISTS) return false;
            std.log.err("[lock] CreateFileW failed: {s}", .{@tagName(err)});
            return error.LockIo;
        }
        defer _ = CloseHandle(handle);

        // Write PID
        var written: DWORD = 0;
        if (@intFromEnum(WriteFile(handle, pid_str.ptr, @intCast(pid_str.len), &written, null)) == 0) {
            std.log.err("[lock] WriteFile failed", .{});
            return error.LockIo;
        }
        return true;
    }

    // POSIX: open with O_CREAT|O_EXCL is atomic.
    _ = io;
    _ = cwd;
    const posix = std.posix.system;
    const flags: posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
    };
    const fd = posix.open(LOCK_FILE, flags, @as(posix.mode_t, 0o644));
    if (fd < 0) {
        const err: posix.E = posix.errno(fd);
        if (err == .EXIST) return false;
        std.log.err("[lock] open failed: {s}", .{@tagName(err)});
        return error.LockIo;
    }
    defer _ = posix.close(fd);

    const written = posix.write(fd, @ptrCast(pid_str.ptr), pid_str.len);
    if (written < 0) {
        std.log.err("[lock] write failed", .{});
        return error.LockIo;
    }
    return true;
}

/// Try to steal a stale lock (dead PID or crash residue >20s). Returns true if acquired.
fn stealStaleLock(io: std.Io, alloc: std.mem.Allocator, cwd: std.Io.Dir, my_pid: Pid) LockError!bool {
    // Read lock file contents (PID + file age).
    const lock_info = readLockFile(io, alloc, cwd) catch |err| {
        // Can't read — try to remove and recreate.
        std.log.warn("[lock] cannot read lock file, attempting forced removal: {}", .{err});
        cwd.deleteFile(io, LOCK_FILE) catch {};
        return createLockFile(io, alloc, cwd, my_pid);
    };

    const pid = lock_info.pid;
    const age_ms = lock_info.age_ms;

    // Check if the holding process is still alive.
    const alive = isProcessAlive(pid);

    if (!alive) {
        std.log.info("[lock] lock holder PID {d} is dead, stealing lock", .{@as(u32, @intCast(pid))});
        cwd.deleteFile(io, LOCK_FILE) catch {};
        return createLockFile(io, alloc, cwd, my_pid);
    }

    if (age_ms > STALE_AGE_MS) {
        std.log.warn("[lock] lock file age {d}ms > {d}ms, stealing (possible crash residue)", .{ age_ms, STALE_AGE_MS });
        cwd.deleteFile(io, LOCK_FILE) catch {};
        return createLockFile(io, alloc, cwd, my_pid);
    }

    // Lock is held by a live process that created it recently — can't steal.
    return false;
}

const LockFileInfo = struct {
    pid: Pid,
    age_ms: i96,
};

/// Read the lock file: parse PID and compute age.
fn readLockFile(io: std.Io, alloc: std.mem.Allocator, cwd: std.Io.Dir) !LockFileInfo {
    // Read content
    const content = try cwd.readFileAlloc(io, LOCK_FILE, alloc, std.Io.Limit.limited(64));
    defer alloc.free(content);

    const pid_str = std.mem.trim(u8, content, " \n\r\t");
    const pid_int = try std.fmt.parseInt(u32, pid_str, 10);
    const pid: Pid = @intCast(pid_int);

    // Get file modification time via statFile
    const stat = try cwd.statFile(io, LOCK_FILE, .{});
    const file_mtime_ns = stat.mtime.nanoseconds;
    const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const age_ns = now_ns - file_mtime_ns;
    const age_ms = @divTrunc(age_ns, 1_000_000);

    return .{ .pid = pid, .age_ms = age_ms };
}

/// Check whether a process with the given PID is still running.
fn isProcessAlive(pid: Pid) bool {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const BOOL = w.BOOL;
        const HANDLE = w.HANDLE;
        const DWORD = w.DWORD;

        const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
        const STILL_ACTIVE: DWORD = 259;

        const OpenProcess = @extern(
            *const fn (dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) HANDLE,
            .{ .name = "OpenProcess", .library_name = "kernel32" },
        );
        const CloseHandle = @extern(
            *const fn (hObject: HANDLE) callconv(.winapi) BOOL,
            .{ .name = "CloseHandle", .library_name = "kernel32" },
        );
        const GetExitCodeProcess = @extern(
            *const fn (hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL,
            .{ .name = "GetExitCodeProcess", .library_name = "kernel32" },
        );

        const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, @enumFromInt(0), pid);
        if (@intFromPtr(handle) == 0) return false;
        defer _ = CloseHandle(handle);

        var exit_code: DWORD = 0;
        if (@intFromEnum(GetExitCodeProcess(handle, &exit_code)) == 0) return false;
        return exit_code == STILL_ACTIVE;
    }

    // POSIX: kill(pid, 0) checks existence without sending a signal.
    const sig: std.c.SIG = @enumFromInt(@as(u32, 0));
    const result = std.posix.system.kill(@intCast(pid), sig);
    if (result != 0) {
        const err: std.posix.system.E = std.posix.system.errno(result);
        if (err == .SRCH) return false; // no such process
        if (err == .PERM) return true; // exists but we can't signal it
        return false; // other errors: assume dead
    }
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "lock acquire and release" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Clean up any leftover lock from previous test runs
    release(io);

    // Acquire should succeed
    try acquire(io, alloc);

    // Release should succeed
    release(io);

    // Verify lock file is gone
    const exists = std.Io.Dir.cwd().statFile(io, LOCK_FILE, .{}) catch null;
    try std.testing.expect(exists == null);
}

test "lock file contains valid PID" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    release(io);
    try acquire(io, alloc);
    defer release(io);

    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, LOCK_FILE, alloc, std.Io.Limit.limited(64));
    defer alloc.free(content);

    const pid_str = std.mem.trim(u8, content, " \n\r\t");
    const lock_pid = try std.fmt.parseInt(u32, pid_str, 10);
    try std.testing.expect(lock_pid > 0);
}

test "lock file matches our PID" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    release(io);
    try acquire(io, alloc);
    defer release(io);

    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, LOCK_FILE, alloc, std.Io.Limit.limited(64));
    defer alloc.free(content);

    const pid_str = std.mem.trim(u8, content, " \n\r\t");
    const lock_pid = try std.fmt.parseInt(u32, pid_str, 10);
    const my_pid: u32 = @intCast(getMyPid());
    try std.testing.expectEqual(my_pid, lock_pid);
}

test "isProcessAlive detects own process" {
    const my_pid = getMyPid();
    try std.testing.expect(isProcessAlive(my_pid));
}

test "isProcessAlive detects dead PID" {
    // Use a very high PID that almost certainly doesn't exist.
    if (builtin.os.tag == .windows) {
        const dead_pid: Pid = 0;
        try std.testing.expect(!isProcessAlive(dead_pid));
    } else {
        const dead_pid: Pid = @intCast(0x7FFFFFFF);
        try std.testing.expect(!isProcessAlive(dead_pid));
    }
}
