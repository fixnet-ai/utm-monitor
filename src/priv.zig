//! Cross-platform admin privilege check + auto self-elevation.
//!
//! POSIX (Linux/macOS): checks geteuid() == 0, re-executes via sudo + execve.
//! Windows: checks token membership in Administrators group,
//! re-launches via ShellExecuteW "runas".
//!
//! Call ensureAdmin() early in main(), after --help/--version checks.
//! If not admin, tries to elevate; on success the new process takes
//! over, on failure prints a clear error message and exits.

const std = @import("std");
const builtin = @import("builtin");

/// Check whether the current process has admin/root privileges.
fn isAdmin() bool {
    if (builtin.os.tag == .windows) {
        return isWindowsAdmin();
    }
    return std.c.geteuid() == 0;
}

/// Windows: check token membership in the Administrators group (S-1-5-32-544).
fn isWindowsAdmin() bool {
    const w = std.os.windows;
    const BOOL = w.BOOL;
    const HANDLE = w.HANDLE;

    const NtAuthority: [6]u8 = [_]u8{ 0, 0, 0, 0, 0, 5 };
    const SECURITY_BUILTIN_DOMAIN_RID: u32 = 32;
    const DOMAIN_ALIAS_RID_ADMINS: u32 = 544;

    const AllocateAndInitializeSid = @extern(
        *const fn (pIdentifierAuthority: *const [6]u8, nSubAuthorityCount: u8, nSubAuthority0: u32, nSubAuthority1: u32, nSubAuthority2: u32, nSubAuthority3: u32, nSubAuthority4: u32, nSubAuthority5: u32, nSubAuthority6: u32, nSubAuthority7: u32, ppSid: *?*anyopaque) callconv(.winapi) BOOL,
        .{ .name = "AllocateAndInitializeSid", .library_name = "advapi32" },
    );
    const FreeSid = @extern(
        *const fn (pSid: ?*anyopaque) callconv(.winapi) ?*anyopaque,
        .{ .name = "FreeSid", .library_name = "advapi32" },
    );
    const CheckTokenMembership = @extern(
        *const fn (TokenHandle: ?HANDLE, SidToCheck: ?*anyopaque, IsMember: *BOOL) callconv(.winapi) BOOL,
        .{ .name = "CheckTokenMembership", .library_name = "advapi32" },
    );

    var admin_sid: ?*anyopaque = null;
    if (@intFromEnum(AllocateAndInitializeSid(
        @ptrCast(&NtAuthority),
        2,
        SECURITY_BUILTIN_DOMAIN_RID,
        DOMAIN_ALIAS_RID_ADMINS,
        0, 0, 0, 0, 0, 0,
        &admin_sid,
    )) == 0) return false;
    defer _ = FreeSid(admin_sid);

    var is_member: BOOL = .FALSE;
    _ = CheckTokenMembership(null, admin_sid, &is_member);
    return is_member != .FALSE;
}

/// POSIX: re-execute via sudo + execve. Never returns on success.
fn elevatePosix(
    exe_path: []const u8,
    args: []const [:0]const u8,
    gpa: std.mem.Allocator,
) !void {
    const total = 3 + (args.len - 1); // sudo + exe_path + (rest args skip argv[0]) + null
    const argv = try gpa.alloc(?[*:0]const u8, total);
    defer gpa.free(argv);

    argv[0] = @ptrCast(@constCast("/usr/bin/sudo".ptr));
    argv[1] = @ptrCast(@constCast(exe_path.ptr));
    for (args[1..], 0..) |arg, i| {
        argv[2 + i] = @ptrCast(arg.ptr);
    }
    argv[total - 1] = null;

    _ = std.c.execve("/usr/bin/sudo", @ptrCast(argv.ptr), std.c.environ);
    // execve only returns on error
}

/// Windows: re-launch via ShellExecuteW "runas". Exits the current process
/// (code 0) on success; returns on failure (UAC denied or error).
fn elevateWindows(
    exe_path: []const u8,
    args: []const [:0]const u8,
    gpa: std.mem.Allocator,
) !void {
    const LPCWSTR = [*:0]const u16;
    const INT = i32;

    const shell32 = struct {
        const ShellExecuteW = @extern(
            *const fn (
                hwnd: ?*anyopaque,
                lpOperation: ?LPCWSTR,
                lpFile: ?LPCWSTR,
                lpParameters: ?LPCWSTR,
                lpDirectory: ?LPCWSTR,
                nShowCmd: INT,
            ) callconv(.winapi) *anyopaque,
            .{ .name = "ShellExecuteW", .library_name = "shell32" },
        );
    }.ShellExecuteW;

    // Convert exe path to null-terminated UTF-16
    const exe_utf16 = try toUtf16LeWithNull(gpa, exe_path);
    defer gpa.free(exe_utf16);

    // Rebuild command line from args (skip argv[0]).
    // Windows command-line quoting: args with spaces/quotes/tabs are wrapped
    // in double quotes and any internal double quotes are escaped as "".
    var cmd_line: std.ArrayListAligned(u16, null) = .empty;
    defer cmd_line.deinit(gpa);

    for (args[1..], 0..) |arg, i| {
        if (i > 0) try cmd_line.append(gpa, ' ');
        const needs_quote = std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (needs_quote) try cmd_line.append(gpa, '"');
        for (arg) |byte| {
            try cmd_line.append(gpa, @intCast(byte));
            if (byte == '"') try cmd_line.append(gpa, '"');
        }
        if (needs_quote) try cmd_line.append(gpa, '"');
    }
    try cmd_line.append(gpa, 0);

    const SW_SHOW: INT = 5;
    const h: usize = @intFromPtr(shell32(
        null,
        @ptrCast(@alignCast(@constCast("runas".ptr))),
        @ptrCast(@alignCast(@constCast(exe_utf16.ptr))),
        @ptrCast(@alignCast(@constCast(cmd_line.items.ptr))),
        null,
        SW_SHOW,
    ));

    // ShellExecuteW returns a value > 32 on success (new process handle).
    // Values <= 32 are error codes (e.g. ERROR_CANCELLED = 1223 when user
    // clicks No on the UAC dialog).
    if (h > 32) {
        std.process.exit(0); // elevated process launched — exit non-elevated one
    }
    // Failed — return to caller, which prints the error message.
}

/// Convert a UTF-8 string to null-terminated UTF-16LE.
fn toUtf16LeWithNull(allocator: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    const buf = try allocator.alloc(u16, utf8.len + 1);
    errdefer allocator.free(buf);
    const end = try std.unicode.utf8ToUtf16Le(buf, utf8);
    buf[end] = 0;
    return buf[0..end :0];
}

/// Ensure the process has admin/root privileges.
///
/// If already admin, returns immediately. If not, attempts to re-launch
/// the same executable with elevated privileges:
///   POSIX: sudo <exe> <original-args...>
///   Windows: ShellExecuteW runas
///
/// On successful elevation the current process exits (the new elevated one
/// takes over). On failure, prints an error message and exits with code 1.
///
/// Call this early in main(), after --help/--version checks
/// but before any privileged operations. The executable path is obtained
/// via std.process.executablePath(io).
pub fn ensureAdmin(
    io: std.Io,
    args: []const [:0]const u8,
    gpa: std.mem.Allocator,
) !void {
    if (isAdmin()) return;

    // Get the executable path (needed for re-exec)
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    exe_buf[exe_len] = 0; // null-terminate for execve / ShellExecuteW
    const exe_path = exe_buf[0..exe_len];

    std.debug.print("[priv] not running as admin, attempting self-elevation...\n", .{});

    if (builtin.os.tag == .windows) {
        try elevateWindows(exe_path, args, gpa);
    } else {
        try elevatePosix(exe_path, args, gpa);
    }

    // If we get here, elevation failed
    std.debug.print(
        \\
        \\error: Administrator / root privileges are required.
        \\
        \\To run with admin privileges:
        \\  POSIX (Linux/macOS): sudo utmm ...
        \\  Windows: Right-click → "Run as Administrator" or use an Administrator terminal
        \\
        \\
    , .{});
    std.process.exit(1);
}
