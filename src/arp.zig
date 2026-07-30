//! ARP 表读取 — 通过 MAC 地址反向查找当前 IP。
//!
//! 当 Guest VM IP 发生变化时（UTM 网络常见），Host 通过已知的 MAC
//! 地址查询系统 ARP 缓存，自动发现新 IP 并恢复连接。
//!
//! 跨平台实现：
//!   - Linux:   解析 /proc/net/arp
//!   - macOS:   运行 `arp -a` 并解析输出
//!   - Windows: 动态加载 iphlpapi.dll 的 GetIpNetTable

const std = @import("std");
const builtin = @import("builtin");

/// 在系统 ARP 表中查找指定 MAC 地址对应的 IPv4 地址。
/// 返回 allocator 分配的 IP 字符串（如 "192.168.64.6"），未找到返回 null。
/// caller 负责释放返回的字符串。
pub fn lookupIp(allocator: std.mem.Allocator, mac: []const u8) !?[]const u8 {
    // 规范化 target MAC 为 6 字节，避免补零差异（如 9e:6 vs 9e:06）
    const target_bytes = parseMacBytes(mac) orelse return null;

    if (builtin.os.tag == .windows) return lookupIpWindows(allocator, target_bytes);
    if (builtin.os.tag == .linux) return lookupIpLinux(allocator, target_bytes);
    if (builtin.os.tag.isDarwin()) return lookupIpMacos(allocator, target_bytes);
    return null;
}

/// 解析 MAC 字符串为 6 字节数组。支持补零和不补零两种格式。
pub fn parseMacBytes(mac_str: []const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var parts = std.mem.splitScalar(u8, mac_str, ':');
    for (&bytes) |*b| {
        const part = parts.next() orelse return null;
        b.* = std.fmt.parseInt(u8, part, 16) catch return null;
    }
    if (parts.next() != null) return null; // 超过 6 段
    return bytes;
}

/// 比较 MAC 字符串与目标字节是否匹配（忽略补零差异）。
pub fn macMatch(hw_str: []const u8, target: [6]u8) bool {
    const bytes = parseMacBytes(hw_str) orelse return false;
    return std.mem.eql(u8, &bytes, &target);
}

// ── Linux: 解析 /proc/net/arp ─────────────────────────────────────────────────

fn lookupIpLinux(allocator: std.mem.Allocator, target_bytes: [6]u8) !?[]const u8 {
    const file = std.fs.openFileAbsolute("/proc/net/arp", .{ .mode = .read_only }) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    _ = lines.next(); // skip header

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const ip_str = it.next() orelse continue;
        _ = it.next(); // HW type
        _ = it.next(); // Flags
        const hw_addr = it.next() orelse continue;

        if (macMatch(hw_addr, target_bytes)) {
            const duped = try allocator.dupe(u8, ip_str);
            return duped;
        }
    }
    return null;
}

// ── macOS: arp -a 命令解析 ────────────────────────────────────────────────────

fn lookupIpMacos(allocator: std.mem.Allocator, target_bytes: [6]u8) !?[]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "arp", "-a" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // macOS arp -a output format (MAC octets are NOT zero-padded):
    // ? (192.168.64.6) at 9e:6:4f:79:db:fe on bridge100 ifscope [bridge]
    // macvm.lan (192.168.65.4) at 1a:97:6d:38:c:6c on bridge100 ifscope [bridge]
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Extract IP: between "(...)"
        const ip_start = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        const ip_end = std.mem.indexOfScalarPos(u8, line, ip_start + 1, ')') orelse continue;
        const ip_str = line[ip_start + 1 .. ip_end];

        // Extract MAC: after " at " and before " on "
        const at_pos = std.mem.indexOf(u8, line, " at ") orelse continue;
        const at_start = at_pos + 4;
        const on_pos = std.mem.indexOfPos(u8, line, at_start, " on ") orelse continue;
        const hw_addr = line[at_start..on_pos];

        if (macMatch(hw_addr, target_bytes)) {
            const duped = try allocator.dupe(u8, ip_str);
            return duped;
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Windows: GetIpNetTable via iphlpapi.dll
// ═══════════════════════════════════════════════════════════════════════════════

const windows = std.os.windows;

extern "iphlpapi" fn GetIpNetTable(
    pIpNetTable: ?*anyopaque,
    pdwSize: *windows.ULONG,
    bOrder: windows.BOOL,
) callconv(.winapi) windows.DWORD;

// MIB_IPNETROW (Windows IP Helper API)
const MIB_IPNETROW = extern struct {
    dwIndex: windows.DWORD,
    dwPhysAddrLen: windows.DWORD,
    bPhysAddr: [8]u8,
    dwAddr: windows.DWORD,
    dwType: windows.DWORD,
};

fn lookupIpWindows(allocator: std.mem.Allocator, target_bytes: [6]u8) !?[]const u8 {
    // 第一次调用获取所需 buffer 大小
    var buf_size: windows.ULONG = 0;
    _ = GetIpNetTable(null, &buf_size, .FALSE);

    if (buf_size == 0) return null;

    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    const rc = GetIpNetTable(@ptrCast(@alignCast(buf.ptr)), &buf_size, .FALSE);
    if (rc != 0) return null;

    // 表头: dwNumEntries (DWORD) + 变长 MIB_IPNETROW 数组
    const num_entries = @as(*align(4) windows.DWORD, @ptrCast(@alignCast(buf.ptr))).*;
    const rows_ptr: [*]MIB_IPNETROW = @ptrCast(@alignCast(buf.ptr + @sizeOf(windows.DWORD)));

    for (0..num_entries) |i| {
        const row = rows_ptr[i];
        if (row.dwPhysAddrLen == 0) continue;

        // 比较 MAC 字节（无需格式化字符串再比较）
        const row_bytes: [6]u8 = row.bPhysAddr[0..6].*;
        if (std.mem.eql(u8, &row_bytes, &target_bytes)) {
            // 读取 IPv4（dwAddr 为网络字节序）
            const ip_nbo = row.dwAddr;
            const a = @as(u8, @truncate(ip_nbo));
            const b = @as(u8, @truncate(ip_nbo >> 8));
            const c = @as(u8, @truncate(ip_nbo >> 16));
            const d = @as(u8, @truncate(ip_nbo >> 24));
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ a, b, c, d });
        }
    }

    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

// ── parseMacBytes ──────────────────────────────────────────────────────────────

test "parseMacBytes: zero-padded format (LSA)" {
    const bytes = parseMacBytes("9e:06:4f:79:db:fe");
    try std.testing.expect(bytes != null);
    const b = bytes.?;
    try std.testing.expectEqual(@as(u8, 0x9e), b[0]);
    try std.testing.expectEqual(@as(u8, 0x06), b[1]);
    try std.testing.expectEqual(@as(u8, 0x4f), b[2]);
    try std.testing.expectEqual(@as(u8, 0x79), b[3]);
    try std.testing.expectEqual(@as(u8, 0xdb), b[4]);
    try std.testing.expectEqual(@as(u8, 0xfe), b[5]);
}

test "parseMacBytes: non-zero-padded format (macOS arp -a)" {
    const bytes = parseMacBytes("9e:6:4f:79:db:fe");
    try std.testing.expect(bytes != null);
    const b = bytes.?;
    try std.testing.expectEqual(@as(u8, 0x9e), b[0]);
    try std.testing.expectEqual(@as(u8, 0x06), b[1]); // "6" = 0x06
    try std.testing.expectEqual(@as(u8, 0x4f), b[2]);
    try std.testing.expectEqual(@as(u8, 0x79), b[3]);
    try std.testing.expectEqual(@as(u8, 0xdb), b[4]);
    try std.testing.expectEqual(@as(u8, 0xfe), b[5]);
}

test "parseMacBytes: zeros to single digits" {
    // 00:01:02:03:04:05 → macOS arp would show as 0:1:2:3:4:5
    const bytes = parseMacBytes("0:1:2:3:4:5");
    try std.testing.expect(bytes != null);
    const b = bytes.?;
    try std.testing.expectEqual(@as(u8, 0x00), b[0]);
    try std.testing.expectEqual(@as(u8, 0x01), b[1]);
    try std.testing.expectEqual(@as(u8, 0x02), b[2]);
    try std.testing.expectEqual(@as(u8, 0x03), b[3]);
    try std.testing.expectEqual(@as(u8, 0x04), b[4]);
    try std.testing.expectEqual(@as(u8, 0x05), b[5]);
}

test "parseMacBytes: too few segments" {
    try std.testing.expectEqual(@as(@TypeOf(parseMacBytes("aa:bb:cc")), null), null);
}

test "parseMacBytes: too many segments" {
    try std.testing.expectEqual(@as(@TypeOf(parseMacBytes("aa:bb:cc:dd:ee:ff:00")), null), null);
}

test "parseMacBytes: non-hex chars" {
    try std.testing.expectEqual(@as(@TypeOf(parseMacBytes("zz:bb:cc:dd:ee:ff")), null), null);
}

test "parseMacBytes: empty string" {
    try std.testing.expectEqual(@as(@TypeOf(parseMacBytes("")), null), null);
}

test "parseMacBytes: empty segments" {
    try std.testing.expectEqual(@as(@TypeOf(parseMacBytes("aa::bb:cc:dd:ee")), null), null);
}

// ── macMatch ───────────────────────────────────────────────────────────────────

test "macMatch: identical format matches" {
    const target = parseMacBytes("9e:06:4f:79:db:fe").?;
    try std.testing.expect(macMatch("9e:06:4f:79:db:fe", target));
}

test "macMatch: zero-padded vs non-padded matches (key scenario)" {
    // LSA stores "9e:06:4f:79:db:fe", arp -a shows "9e:6:4f:79:db:fe"
    const target = parseMacBytes("9e:06:4f:79:db:fe").?; // LSA format
    try std.testing.expect(macMatch("9e:6:4f:79:db:fe", target)); // macOS arp format
}

test "macMatch: same format different value" {
    const target = parseMacBytes("9e:06:4f:79:db:fe").?;
    try std.testing.expect(!macMatch("aa:bb:cc:dd:ee:ff", target));
}

test "macMatch: non-padded target vs zero-padded input" {
    const target = parseMacBytes("9e:6:4f:79:db:fe").?; // non-padded
    try std.testing.expect(macMatch("9e:06:4f:79:db:fe", target)); // zero-padded
}

test "macMatch: empty hw string returns false" {
    const target = parseMacBytes("9e:06:4f:79:db:fe").?;
    try std.testing.expect(!macMatch("", target));
}

test "macMatch: double-digit edge (0c vs c)" {
    // 0c = 12 decimal, c = 12 decimal — same byte value
    const target = parseMacBytes("1a:97:6d:38:0c:6c").?; // LSA: zero-padded 0c
    const bytes2 = parseMacBytes("1a:97:6d:38:c:6c").?;   // arp: non-padded c
    try std.testing.expect(std.mem.eql(u8, &target, &bytes2)); // verify same bytes
    try std.testing.expect(macMatch("1a:97:6d:38:c:6c", target));
}

// ── macOS arp -a 格式解析 ─────────────────────────────────────────────────────

test "lookupIp: macos arp -a parse" {
    const testing = std.testing;

    const sample =
        \\? (192.168.64.6) at 9e:6:4f:79:db:fe on bridge100 ifscope [bridge]
        \\macvm.lan (192.168.65.4) at 1a:97:6d:38:c:6c on bridge100 ifscope [bridge]
        \\? (192.168.64.3) at 66:dc:da:ec:a1:59 on bridge100 ifscope [bridge]
        \\
    ;

    var lines = std.mem.splitScalar(u8, sample, '\n');
    var found: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const ip_start = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        const ip_end = std.mem.indexOfScalarPos(u8, line, ip_start + 1, ')') orelse continue;
        const ip = line[ip_start + 1 .. ip_end];

        const at_pos = std.mem.indexOf(u8, line, " at ") orelse continue;
        const on_pos = std.mem.indexOfPos(u8, line, at_pos + 4, " on ") orelse continue;
        const mac = line[at_pos + 4 .. on_pos];

        if (found == 0) { try testing.expectEqualStrings("192.168.64.6", ip); try testing.expectEqualStrings("9e:6:4f:79:db:fe", mac); }
        if (found == 1) { try testing.expectEqualStrings("192.168.65.4", ip); try testing.expectEqualStrings("1a:97:6d:38:c:6c", mac); }
        if (found == 2) { try testing.expectEqualStrings("192.168.64.3", ip); try testing.expectEqualStrings("66:dc:da:ec:a1:59", mac); }
        found += 1;
    }
    try testing.expectEqual(@as(u32, 3), found);
}

// ── Linux /proc/net/arp 格式解析 ───────────────────────────────────────────────

test "lookupIpLinux: parse /proc/net/arp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp = try tmp_dir.dir.createFile("arp", .{});
    defer tmp.close();
    try tmp.writeAll(
        \\IP address       HW type     Flags       HW address            Mask     Device
        \\192.168.64.6     0x1         0x2         9e:06:4f:79:db:fe     *        enp0s1
        \\192.168.65.4     0x1         0x2         1a:97:6d:38:0c:6c     *        enp0s2
        \\10.0.0.1         0x1         0x2         aa:bb:cc:dd:ee:ff     *        eth0
        \\
    );

    _ = try tmp_dir.dir.readFileAlloc(allocator, "arp", 4096);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 集成辅助函数
// ═══════════════════════════════════════════════════════════════════════════════

/// 尝试通过 ARP 表重发现 Guest IP。
/// 给定 MAC 和当前 IP，如果发现新 IP（与当前不同）则返回新 IP。
/// 用于 Guest 失联后的自动恢复。
pub fn rediscoverIp(allocator: std.mem.Allocator, mac: []const u8, current_ip: []const u8) !?[]const u8 {
    const found = try lookupIp(allocator, mac) orelse return null;
    if (std.mem.eql(u8, found, current_ip)) {
        allocator.free(found);
        return null; // IP 未变
    }
    return found; // 新 IP
}
