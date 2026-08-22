//! 共享内存协议 — utmmd 监督进程与 utmm 之间的 IPC。
//!
//! 一块 4096 字节（一页）的共享内存区域，包含状态字段、心跳、命令通道。
//! utmmd 创建共享内存，utmm 通过约定名称打开。
//!
//! 平台：
//!   POSIX:   shm_open() + ftruncate() + mmap(MAP_SHARED)
//!   Windows: CreateFileMappingW() + MapViewOfFile()
//!
//! 命名约定：
//!   POSIX:   "/utmmd-shm"  (shm_open 抽象命名空间)
//!   Windows: L"Global\\utmmd-shm" (session 0 跨会话可见)

const builtin = @import("builtin");
const std = @import("std");

/// 共享内存名称 — utmmd 和 utmm 必须一致。
pub const SHM_NAME = "/utmmd-shm";

/// 魔数，标识共享内存区域有效性。
pub const MAGIC: u32 = 0x55544D44; // "UTMD"

/// 协议版本。
pub const VERSION: u32 = 1;

/// utmmd 状态。
pub const SvcState = enum(u32) {
    init = 0, // 初始化中
    running = 1, // 正常运行，监控 utmm
    stopping = 2, // 正在停止
};

/// utmm 状态。
pub const UtmmState = enum(u32) {
    starting = 0, // 启动中
    running = 1, // 正常运行
    stopping = 2, // 正在停止
    upgrading = 3, // 升级中（等待 utmmd 操作）
};

/// utmm → utmmd 命令。
pub const Cmd = enum(u32) {
    none = 0,
    restart = 1, // 重启 utmm（用于升级或配置变更）
    upgrade = 2, // 升级 utmm：cmd_data 含新二进制路径
    shutdown = 3, // 关闭 utmm，utmmd 也退出
};

/// utmmd → utmm 命令响应状态。
pub const CmdStatus = enum(u32) {
    pending = 0, // 待处理
    accepted = 1, // 已接受，正在执行
    done = 2, // 已完成
    failed = 3, // 执行失败
};

/// 共享内存布局 — 4096 字节，extern struct 确保字段顺序和填充可预测。
pub const ShmLayout = extern struct {
    magic: u32 = MAGIC, // 魔数 "UTMD"
    version: u32 = VERSION, // 协议版本

    svc_state: u32 = @intFromEnum(SvcState.init), // utmmd 写入
    utmm_state: u32 = @intFromEnum(UtmmState.starting), // utmm 写入

    utmm_pid: u32 = 0, // utmm 进程 PID（utmmd 写入）
    svc_pid: u32 = 0, // utmmd 自身 PID（utmmd 写入）

    svc_heartbeat: u32 = 0, // utmmd 心跳（单调时钟 ms）
    utmm_heartbeat: u32 = 0, // utmm 心跳（单调时钟 ms）

    cmd: u32 = @intFromEnum(Cmd.none), // utmm 写入命令
    cmd_status: u32 = @intFromEnum(CmdStatus.pending), // utmmd 响应

    restart_count: u32 = 0, // utmm 累计重启次数
    last_exit_code: u32 = 0, // utmm 上一次退出码
    backoff_sec: u32 = 0, // 当前重试延迟（秒）
    failure_count: u32 = 0, // 连续启动失败次数

    cmd_data: [1024]u8 = [_]u8{0} ** 1024, // 命令附加数据（如升级路径）

    _reserved: [3016]u8 = [_]u8{0} ** 3016,
};

comptime {
    if (@sizeOf(ShmLayout) != 4096) {
        @compileError("ShmLayout 必须是 4096 字节（恰好一页），实际大小：" ++
            @TypeOf(@sizeOf(ShmLayout)));
    }
}

/// 获取当前单调时钟时间（毫秒）。
pub fn nowMs(io: std.Io) u32 {
    const ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));
    return @truncate(ms);
}

// ═══════════════════════════════════════════════════════════════════════════
// POSIX 实现（shm_open + mmap）
// ═══════════════════════════════════════════════════════════════════════════

// Zig 0.16.0 posix 包装跨平台差异大，直接 @extern C 函数 + 原始常量。
extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) c_int;
extern "c" fn ftruncate(fd: c_int, length: isize) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getpid() c_int;
extern "c" fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: isize) *anyopaque;
extern "c" fn munmap(addr: ?*anyopaque, length: usize) c_int;

// fcntl.h 原始常量 — macOS 与 Linux 值不同，按平台区分
const O_CREAT: c_int = if (builtin.os.tag == .macos) 0x0200 else 0o100;
const O_EXCL: c_int = if (builtin.os.tag == .macos) 0x0800 else 0o200;
const O_RDWR: c_int = 0o2;

const MAP_FAILED: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const MAP_SHARED: c_int = 0x0001;

/// POSIX: 创建共享内存区域（由 utmmd 调用）。
/// 在 launchd bootstrap 环境中首次 shm_open 可能失败，添加重试逻辑。
fn createPosix(io: std.Io, name: [:0]const u8) !*volatile ShmLayout {
    const fd: c_int = fd: {
        const f = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0o600);
        if (f >= 0) break :fd f;
        // shm 已存在（上次未清理）→ unlink 后重新创建
        _ = shm_unlink(name);
        const f2 = shm_open(name, O_CREAT | O_RDWR, 0o600);
        if (f2 >= 0) break :fd f2;
        // 首次失败（常见于 launchd bootstrap 环境），等待后重试
        std.log.warn("[shm] first create attempt failed, retrying...", .{});
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2000), .awake) catch {};
        _ = shm_unlink(name);
        const f3 = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0o600);
        if (f3 >= 0) break :fd f3;
        _ = shm_unlink(name);
        const f4 = shm_open(name, O_CREAT | O_RDWR, 0o600);
        if (f4 < 0) return error.ShmCreateFailed;
        break :fd f4;
    };

    if (ftruncate(fd, @intCast(@sizeOf(ShmLayout))) != 0) {
        _ = close(fd);
        return error.ShmCreateFailed;
    }

    const ptr = mmap(null, @sizeOf(ShmLayout), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        _ = close(fd);
        return error.ShmMapFailed;
    }
    _ = close(fd);

    const shm: *volatile ShmLayout = @ptrCast(@alignCast(ptr));
    @memset(@as([*]u8, @ptrCast(@constCast(ptr)))[0..@sizeOf(ShmLayout)], 0);
    shm.magic = MAGIC;
    shm.version = VERSION;
    shm.svc_pid = @intCast(getpid());
    shm.svc_heartbeat = nowMs(io);

    return shm;
}

/// POSIX: 打开已有共享内存区域（由 utmm 调用）。
fn openPosix(name: [:0]const u8) !*volatile ShmLayout {
    const fd = shm_open(name, O_RDWR, 0o600);
    if (fd < 0) return error.ShmOpenFailed;

    const ptr = mmap(null, @sizeOf(ShmLayout), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        _ = close(fd);
        return error.ShmMapFailed;
    }
    _ = close(fd);

    const shm: *volatile ShmLayout = @ptrCast(@alignCast(ptr));
    if (shm.magic != MAGIC) {
        _ = munmap(ptr, @sizeOf(ShmLayout));
        return error.ShmInvalidMagic;
    }
    return shm;
}

/// POSIX: 关闭共享内存，由 utmmd 在退出时调用（unlink 清理命名对象）。
fn closePosix(shm_ptr: *volatile ShmLayout, name: [:0]const u8) void {
    _ = munmap(@ptrCast(@volatileCast(@alignCast(shm_ptr))), @sizeOf(ShmLayout));
    _ = shm_unlink(name);
}

/// POSIX: 探测命名对象是否仍存在（只 open + close，不 mmap）。
/// 命名对象可能被外部 unlink（/dev/shm 清理、误删、其他实例竞争等），
/// 此时 utmmd 的已有 mmap 仍有效，但新进程 shm_open 会失败——utmmd 用它
/// 检测是否需要自愈重建。
fn existsPosix(name: [:0]const u8) bool {
    const fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

/// POSIX: 取消映射但不 unlink（由 utmm 退出时调用，不删除命名对象）。
fn detachPosix(shm_ptr: *volatile ShmLayout) void {
    _ = munmap(@ptrCast(@volatileCast(@alignCast(shm_ptr))), @sizeOf(ShmLayout));
}

// ═══════════════════════════════════════════════════════════════════════════
// Windows 实现（CreateFileMapping + MapViewOfFile）
// ═══════════════════════════════════════════════════════════════════════════

const windows = std.os.windows;
const WINAPI: std.builtin.CallingConvention = .winapi;

const PAGE_READWRITE: u32 = 0x04;
const FILE_MAP_ALL_ACCESS: u32 = 0x000F001F;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern "kernel32" fn CreateFileMappingW(
    hFile: ?windows.HANDLE,
    lpFileMappingAttributes: ?*anyopaque,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?[*:0]const u16,
) callconv(WINAPI) ?windows.HANDLE;

extern "kernel32" fn OpenFileMappingW(
    dwDesiredAccess: u32,
    bInheritHandle: i32,
    lpName: [*:0]const u16,
) callconv(WINAPI) ?windows.HANDLE;

extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: windows.HANDLE,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) callconv(WINAPI) ?*anyopaque;

extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: ?*const anyopaque) callconv(WINAPI) windows.BOOL;

/// 将 UTF-8 名称转为 UTF-16（Windows API 需要），栈分配。
fn winShmNameUtf16() [64]u16 {
    var buf: [64]u16 = [_]u16{0} ** 64;
    const prefix = "Global\\";
    var idx: usize = 0;
    for (prefix) |c| {
        if (idx >= 63) break;
        buf[idx] = @intCast(c);
        idx += 1;
    }
    const name = "utmmd-shm";
    for (name) |c| {
        if (idx >= 63) break;
        buf[idx] = @intCast(c);
        idx += 1;
    }
    buf[idx] = 0;
    return buf;
}

/// Windows: 创建共享内存区域（由 utmmd 调用）。
fn createWindows(io: std.Io) !*volatile ShmLayout {
    const name_utf16 = winShmNameUtf16();

    const h = CreateFileMappingW(
        INVALID_HANDLE_VALUE,
        null,
        PAGE_READWRITE,
        0,
        @sizeOf(ShmLayout),
        @ptrCast(&name_utf16),
    ) orelse return error.ShmCreateFailed;

    const ptr = MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, @sizeOf(ShmLayout)) orelse {
        _ = windows.CloseHandle(h);
        return error.ShmMapFailed;
    };
    // 不关闭句柄 h —— Windows 上关闭 CreateFileMappingW 句柄会移除命名对象的名字，
    // 即使 MapViewOfFile 的视图还映射着。名字移除后，utmm 的 OpenFileMappingW
    // 找不到映射（ERROR_FILE_NOT_FOUND）。句柄随 utmmd 进程退出自动释放。
    // 泄漏一个句柄换取命名对象在整个 utmmd 生命周期内可见，代价可忽略。

    const shm: *volatile ShmLayout = @ptrCast(@alignCast(ptr));
    @memset(@as([*]u8, @ptrCast(@alignCast(ptr)))[0..@sizeOf(ShmLayout)], 0);
    shm.magic = MAGIC;
    shm.version = VERSION;
    shm.svc_pid = windows.GetCurrentProcessId();
    shm.svc_heartbeat = nowMs(io);

    return shm;
}

/// Windows: 打开已有共享内存区域（由 utmm 调用）。
fn openWindows() !*volatile ShmLayout {
    const name_utf16 = winShmNameUtf16();

    const h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, 0, @ptrCast(&name_utf16)) orelse
        return error.ShmOpenFailed;

    const ptr = MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, @sizeOf(ShmLayout)) orelse {
        _ = windows.CloseHandle(h);
        return error.ShmMapFailed;
    };
    _ = windows.CloseHandle(h);

    const shm: *volatile ShmLayout = @ptrCast(@alignCast(ptr));
    if (shm.magic != MAGIC) {
        _ = UnmapViewOfFile(ptr);
        return error.ShmInvalidMagic;
    }
    return shm;
}

/// Windows: 关闭共享内存（utmmd 退出时调用）。
fn closeWindows(shm: *volatile ShmLayout) void {
    _ = UnmapViewOfFile(@ptrCast(@constCast(@volatileCast(shm))));
}

/// Windows: 探测命名对象是否仍存在（只 open + close，不 map）。
fn existsWindows() bool {
    const name_utf16 = winShmNameUtf16();
    const h = OpenFileMappingW(FILE_MAP_ALL_ACCESS, 0, @ptrCast(&name_utf16)) orelse
        return false;
    _ = windows.CloseHandle(h);
    return true;
}

/// Windows: 取消映射（utmm 退出时调用）。
const detachWindows = closeWindows;

// ═══════════════════════════════════════════════════════════════════════════
// 公共 API
// ═══════════════════════════════════════════════════════════════════════════

/// utmmd 调用：创建共享内存区域并初始化。
/// 返回指向已初始化 ShmLayout 的 volatile 指针。
pub fn create(io: std.Io) !*volatile ShmLayout {
    const name: [:0]const u8 = if (builtin.os.tag != .windows) SHM_NAME else undefined;
    return switch (builtin.os.tag) {
        .macos, .linux => createPosix(io, name),
        .windows => createWindows(io),
        else => @compileError("shm: 不支持的平台"),
    };
}

/// utmm 调用：打开 utmmd 已创建的共享内存区域。
/// 验证魔数。返回 null 表示共享内存不存在（utmmd 未运行）。
pub fn open() !*volatile ShmLayout {
    const name: [:0]const u8 = if (builtin.os.tag != .windows) SHM_NAME else undefined;
    return switch (builtin.os.tag) {
        .macos, .linux => openPosix(name),
        .windows => openWindows(),
        else => @compileError("shm: 不支持的平台"),
    };
}

/// utmmd 调用：探测共享内存命名对象是否仍存在。
/// 命名对象可能被外部 unlink（/dev/shm 清理、误删、其他实例竞争等），
/// 此时 utmmd 的已有 mmap 仍有效（可继续与旧 utmm 通信），但新启动的
/// utmm 无法 shm_open 加入 → 心跳死 → 升级/重启链路断裂。
/// utmmd 用它定期检测，丢失则重建。
pub fn exists() bool {
    const name: [:0]const u8 = if (builtin.os.tag != .windows) SHM_NAME else undefined;
    return switch (builtin.os.tag) {
        .macos, .linux => existsPosix(name),
        .windows => existsWindows(),
        else => @compileError("shm: 不支持的平台"),
    };
}

/// utmmd 调用：关闭并清理共享内存（unmap + unlink 命名对象）。
pub fn destroy(shm: *volatile ShmLayout) void {
    switch (builtin.os.tag) {
        .macos, .linux => closePosix(shm, SHM_NAME),
        .windows => closeWindows(shm),
        else => {},
    }
}

/// utmm 调用：取消映射但不删除命名对象（utmm 退出时调用）。
pub fn detach(shm: *volatile ShmLayout) void {
    switch (builtin.os.tag) {
        .macos, .linux => detachPosix(shm),
        .windows => detachWindows(shm),
        else => {},
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// 跨进程同步辅助函数（原子操作 + 内存序）
//
// ShmLayout 字段是普通整数类型，*volatile 指针仅防止编译器重排，
// 不插入 CPU 内存屏障。ARM64 弱内存序可能导致写入方连续 store 被
// 读取方以乱序观察到，必须使用 @atomicStore/@atomicLoad 确保跨进程
// Happens-Before 语义。
// ═══════════════════════════════════════════════════════════════════════════

/// utmm → utmmd: 写入命令及状态。
/// cmd_status 先写入，cmd 后写入——utmmd 轮询 cmd 字段触发分发，
/// cmd 的 release 存储确保 cmd_status 对 acquire 读取方可见。
pub fn writeCmd(shm_ptr: *volatile ShmLayout, cmd_val: Cmd, status: CmdStatus) void {
    @atomicStore(u32, &shm_ptr.cmd_status, @intFromEnum(status), .release);
    @atomicStore(u32, &shm_ptr.cmd, @intFromEnum(cmd_val), .release);
}

/// utmm → utmmd: 清除命令（utmmd 处理完后重置）。
pub fn clearCmd(shm_ptr: *volatile ShmLayout) void {
    @atomicStore(u32, &shm_ptr.cmd_status, @intFromEnum(CmdStatus.pending), .release);
    @atomicStore(u32, &shm_ptr.cmd, @intFromEnum(Cmd.none), .release);
}

/// utmmd ← utmm: 读取命令，acquire 确保 cmd_status 写入已可见。
pub fn readCmd(shm_ptr: *volatile ShmLayout) Cmd {
    return @enumFromInt(@atomicLoad(u32, &shm_ptr.cmd, .acquire));
}

/// utmmd ← utmm: 读取命令状态（紧接 readCmd 之后调用）。
pub fn readCmdStatus(shm_ptr: *volatile ShmLayout) CmdStatus {
    return @enumFromInt(@atomicLoad(u32, &shm_ptr.cmd_status, .acquire));
}

/// utmm → utmmd: 写入 utmm 心跳（release 存储确保 utmmd 看到最新值）。
pub fn writeUtmmHeartbeat(shm_ptr: *volatile ShmLayout, io: std.Io) void {
    @atomicStore(u32, &shm_ptr.utmm_heartbeat, nowMs(io), .release);
}

/// utmmd → utmm: 写入 utmmd 心跳。
pub fn writeSvcHeartbeat(shm_ptr: *volatile ShmLayout, io: std.Io) void {
    @atomicStore(u32, &shm_ptr.svc_heartbeat, nowMs(io), .release);
}

/// utmmd ← utmm: 读取 utmm 心跳（acquire 加载）。
pub fn readUtmmHeartbeat(shm_ptr: *volatile ShmLayout) u32 {
    return @atomicLoad(u32, &shm_ptr.utmm_heartbeat, .acquire);
}

/// utmm → utmmd: 将升级文件路径写入 cmd_data（null 结尾）。
/// utmmd 可直接使用此路径，无需扫描目录。
/// 逐字节写 — @memcpy 对 *volatile 共享内存可能被优化掉，跨进程不可见。
pub fn writeCmdPath(shm_ptr: *volatile ShmLayout, path: []const u8) void {
    const len = @min(path.len, shm_ptr.cmd_data.len - 1);
    for (path[0..len], 0..) |c, i| {
        @atomicStore(u8, &shm_ptr.cmd_data[i], c, .monotonic);
    }
    @atomicStore(u8, &shm_ptr.cmd_data[len], 0, .release);
}

/// utmmd ← utmm: 读取 cmd_data 中的路径（若有效）。acquire 确保写入可见。
pub fn readCmdPath(shm_ptr: *volatile ShmLayout, buf: []u8) ?[]const u8 {
    const first_byte = @atomicLoad(u8, &shm_ptr.cmd_data[0], .acquire);
    if (first_byte == 0) return null; // 空
    const max_len = @min(buf.len, shm_ptr.cmd_data.len);
    var len: usize = 0;
    while (len < max_len) : (len += 1) {
        const c = @atomicLoad(u8, &shm_ptr.cmd_data[len], .acquire);
        if (c == 0) break;
        buf[len] = c;
    }
    if (len == 0 or len >= max_len) return null;
    buf[len] = 0;
    return buf[0..len];
}

// ========== Tests ==========

test "ShmLayout size is 4096" {
    try std.testing.expectEqual(@as(usize, 4096), @sizeOf(ShmLayout));
}

test "ShmLayout default magic" {
    const layout = ShmLayout{};
    try std.testing.expectEqual(MAGIC, layout.magic);
}

test "ShmLayout default version" {
    const layout = ShmLayout{};
    try std.testing.expectEqual(VERSION, layout.version);
}

test "ShmLayout default cmd is none" {
    const layout = ShmLayout{};
    try std.testing.expectEqual(@intFromEnum(Cmd.none), layout.cmd);
}

test "Cmd enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Cmd.none));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Cmd.restart));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Cmd.upgrade));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Cmd.shutdown));
}

test "SvcState enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(SvcState.init));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(SvcState.running));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(SvcState.stopping));
}

test "UtmmState enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(UtmmState.starting));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(UtmmState.running));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(UtmmState.stopping));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(UtmmState.upgrading));
}

test "CmdStatus enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(CmdStatus.pending));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(CmdStatus.accepted));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(CmdStatus.done));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(CmdStatus.failed));
}

test "MAGIC constant" {
    try std.testing.expectEqual(@as(u32, 0x55544D44), MAGIC);
}

test "SHM_NAME" {
    try std.testing.expectEqualStrings("/utmmd-shm", SHM_NAME);
}
