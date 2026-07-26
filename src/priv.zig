//! Cross-platform admin privilege check.
//!
//! POSIX (Linux/macOS): checks geteuid() == 0.
//! Windows: checks token membership in Administrators group (S-1-5-32-544).
//!
//! Call isAdmin() early in main(), after --help/--version checks.
//! If not admin, print a clear error message and exit.

const std = @import("std");
const builtin = @import("builtin");

/// Check whether the current process has admin/root privileges.
pub fn isAdmin() bool {
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

// ── Tests ──────────────────────────────────────────────────────────────────

test "isAdmin does not crash" {
    // isAdmin should at minimum return a bool without panicking
    _ = isAdmin();
}

test "isAdmin returns bool" {
    const result = isAdmin();
    _ = switch (result) {
        true => "admin",
        false => "not admin",
    };
}
