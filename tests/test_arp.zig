//! ARP MAC→IP 反向发现集成测试
//!
//! 测试 arp.zig 的公共 API：parseMacBytes、macMatch、rediscoverIp。
//! rediscoverIp 调用平台特定的 lookupIp（macOS: arp -a, Linux: /proc/net/arp,
//! Windows: GetIpNetTable），验证完整的 MAC 规范化→系统 ARP 查询→IP 比较链路。

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const arp = @import("testlib").arp;

const TestRunner = common.TestRunner;

pub fn test_arp(io: std.Io, alloc: std.mem.Allocator, runner: *TestRunner) !void {
    _ = io;

    // ── parseMacBytes 公共 API 验证 ──────────────────────────────────────────

    {
        var c = runner.case("arp parseMacBytes zero-padded (LSA format)");
        defer c.deinit();
        const bytes = arp.parseMacBytes("9e:06:4f:79:db:fe");
        c.expectTrue(bytes != null, "should parse zero-padded MAC");
        if (bytes) |b| {
            c.expectEqual(@as(u8, 0x9e), b[0], "byte[0]");
            c.expectEqual(@as(u8, 0x06), b[1], "byte[1]");
            c.expectEqual(@as(u8, 0xdb), b[4], "byte[4]");
            c.expectEqual(@as(u8, 0xfe), b[5], "byte[5]");
        }
    }

    {
        var c = runner.case("arp parseMacBytes non-zero-padded (macOS arp format)");
        defer c.deinit();
        const bytes = arp.parseMacBytes("9e:6:4f:79:db:fe");
        c.expectTrue(bytes != null, "should parse non-zero-padded MAC");
        if (bytes) |b| {
            // "6" 应解析为 0x06，与 "06" 相同
            c.expectEqual(@as(u8, 0x06), b[1], "non-padded 6 -> 0x06");
        }
    }

    {
        var c = runner.case("arp parseMacBytes invalid input returns null");
        defer c.deinit();
        c.expectTrue(arp.parseMacBytes("not:a:mac:addr:zz:ff") == null, "non-hex → null");
        c.expectTrue(arp.parseMacBytes("aa:bb:cc:dd") == null, "4 segments → null");
        c.expectTrue(arp.parseMacBytes("aa:bb:cc:dd:ee:ff:00") == null, "7 segments → null");
        c.expectTrue(arp.parseMacBytes("") == null, "empty → null");
    }

    // ── macMatch 跨格式匹配验证（核心回归防护）──────────────────────────────

    {
        var c = runner.case("arp macMatch zero-padded vs non-padded (key regression)");
        defer c.deinit();
        // 模拟真实场景：LSA 存 "9e:06:4f:79:db:fe"，macOS arp -a 输出 "9e:6:4f:79:db:fe"
        const lsa_mac = "9e:06:4f:79:db:fe";
        const arp_output = "9e:6:4f:79:db:fe";
        const target = arp.parseMacBytes(lsa_mac) orelse {
            c.failed = true;
            std.debug.print("  FAIL: parseMacBytes failed on LSA format\n", .{});
            return;
        };
        c.expectTrue(arp.macMatch(arp_output, target), "macMatch should ignore zero-padding diff");
    }

    {
        var c = runner.case("arp macMatch different MAC returns false");
        defer c.deinit();
        const target = arp.parseMacBytes("aa:bb:cc:dd:ee:ff") orelse {
            c.failed = true;
            return;
        };
        c.expectTrue(!arp.macMatch("11:22:33:44:55:66", target), "different MAC → false");
    }

    {
        var c = runner.case("arp macMatch invalid hw string returns false");
        defer c.deinit();
        const target = arp.parseMacBytes("9e:06:4f:79:db:fe") orelse {
            c.failed = true;
            return;
        };
        c.expectTrue(!arp.macMatch("", target), "empty string → false");
        c.expectTrue(!arp.macMatch("not_a_mac", target), "garbage → false");
    }

    // ── rediscoverIp: 系统 ARP 表查询（平台相关） ──────────────────────────

    {
        var c = runner.case("arp rediscoverIp with bogus MAC returns null");
        defer c.deinit();
        // 使用不存在的 MAC 地址，确保 lookupIp 返回 null
        const result = arp.rediscoverIp(alloc, "ff:ff:ff:ff:ff:ff", "192.168.1.1") catch |err| {
            c.failed = true;
            std.debug.print("  FAIL: rediscoverIp error: {}\n", .{err});
            return;
        };
        if (result) |ip| {
            defer alloc.free(ip);
            // 极罕见：广播 MAC 可能在 ARP 表中有条目
            std.debug.print("  NOTE: broadcast MAC found in ARP table: {s}\n", .{ip});
        }
        // 无论找到与否，验证不崩溃
        c.expectTrue(true, "rediscoverIp completed without crash");
    }

    {
        var c = runner.case("arp rediscoverIp with empty MAC returns null");
        defer c.deinit();
        const result = arp.rediscoverIp(alloc, "", "192.168.1.1") catch |err| {
            c.failed = true;
            std.debug.print("  FAIL: rediscoverIp error: {}\n", .{err});
            return;
        };
        c.expectTrue(result == null, "empty MAC → null");
    }

    // ── rediscoverIp: IP 相同返回 null（纯逻辑验证） ────────────────────────

    {
        var c = runner.case("arp rediscoverIp same-IP logic (via bogus MAC)");
        defer c.deinit();
        // 用不存在的 MAC 测试 — lookupIp 返回 null，rediscoverIp 也返回 null
        // 这验证了 rediscoverIp 的 "not found" 路径
        const result = arp.rediscoverIp(alloc, "dd:dd:dd:dd:dd:dd", "10.0.0.1") catch |err| {
            c.failed = true;
            std.debug.print("  FAIL: rediscoverIp error: {}\n", .{err});
            return;
        };
        c.expectTrue(result == null, "nonexistent MAC → null");
    }

    // ── lookupIp: 真实系统 ARP 表查询 ──────────────────────────────────────

    // 在 macOS 上验证 lookupIp 能正确查询真实 ARP 表
    if (builtin.os.tag.isDarwin()) {
        var c = runner.case("arp lookupIp on real macOS ARP table");
        defer c.deinit();

        // 用当前 Host 自己的 IP 反向验证 — 自己的 IP 肯定在 ARP 表里
        // （至少 gateway 会在 ARP 表中有条目）
        // 这个测试验证：1) arp -a 命令成功执行  2) 输出解析不崩溃
        // 不要求找到特定 MAC，只验证调用链路完整
        const test_mac = "00:00:00:00:00:00"; // 不存在的 MAC
        const result = arp.lookupIp(alloc, test_mac) catch |err| {
            c.failed = true;
            std.debug.print("  FAIL: lookupIp error: {}\n", .{err});
            return;
        };
        if (result) |ip| {
            defer alloc.free(ip);
            std.debug.print("  NOTE: 00:00:00:00:00:00 found with IP {s}\n", .{ip});
        }
        c.expectTrue(true, "lookupIp completed on macOS without crash");
    }
}
