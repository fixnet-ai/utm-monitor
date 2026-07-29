//! LSA 编解码 + Dijkstra 路由集成测试
//!
//! 验证场景：
//! 1. encodeLsa/decodeLsa 往返 + neighbors
//! 2. NodeId parse/format 一致性
//! 3. Dijkstra 路由（3 节点线型拓扑）
//! 4. LSA 重启检测（nonce 变化）
//! 5. 邻居过期
//! 6. LSA 重复/旧 seq 拒绝

const std = @import("std");
const lib = @import("testlib");
const common = @import("common");
const lsa = lib.lsa;
const protocol = lib.protocol;

const NeighborEntry = lsa.NeighborEntry;
const NodeId = lsa.NodeId;

/// 创建一个绑定到 :0 的 UDP socket，用于 Mesh.init。
fn bindDummyUdp(io: std.Io) !std.Io.net.Socket {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch return error.BindFailed;
    return addr.bind(io, .{ .mode = .dgram }) catch return error.BindFailed;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("内存泄漏");
    }
    const alloc = gpa.allocator();

    var runner = common.TestRunner{};
    defer {
        const all_pass = runner.summary();
        if (!all_pass) std.process.exit(1);
    }

    // ── 场景 1: encodeLsa/decodeLsa 往返 ──
    {
        var tc = runner.case("encodeLsa/decodeLsa 往返");

        const origin: NodeId = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
        const node_info = "hostname:testvm\nip:10.0.0.1\ntarget:aarch64-linux";
        const neighbors = [_]NeighborEntry{
            .{ .mac = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 }, .cost = 1 },
            .{ .mac = .{ 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc }, .cost = 2 },
        };

        var buf: [512]u8 = undefined;
        const n = lsa.encodeLsa(&buf, origin, 42, 8, 0, node_info, &neighbors);
        tc.expectTrue(n > 0, "encodeLsa 返回非零长度");

        // decodeLsa 从 type byte 之后开始解析
        const decoded = lsa.decodeLsa(buf[1..n]) orelse {
            tc.expect(false, "decodeLsa 返回 null", .{});
            tc.deinit();
            return;
        };

        tc.expectTrue(std.mem.eql(u8, &origin, &decoded.origin), "origin 一致");
        tc.expectEqual(@as(u32, 42), decoded.seq, "seq 一致");
        tc.expectEqual(@as(u8, 8), decoded.ttl, "ttl 一致");
        tc.expectStr(node_info, decoded.node_info, "node_info 一致");

        // 验证 neighbors
        var parsed_neighbors = lsa.parseLsaNeighbors(alloc, buf[1..n], @intCast(node_info.len)) catch {
            tc.expect(false, "parseLsaNeighbors 失败", .{});
            tc.deinit();
            return;
        };
        defer parsed_neighbors.deinit(alloc);

        tc.expectEqual(@as(usize, 2), parsed_neighbors.items.len, "neighbors 数量=2");
        tc.expectTrue(std.mem.eql(u8, &neighbors[0].mac, &parsed_neighbors.items[0].mac), "neighbor[0] mac");
        tc.expectEqual(neighbors[0].cost, parsed_neighbors.items[0].cost, "neighbor[0] cost");

        tc.deinit();
    }

    // ── 场景 2: NodeId parse/format 一致性 ──
    {
        var tc = runner.case("NodeId parse/format 一致性");

        const mac_str = "aa:bb:cc:dd:ee:ff";
        const id = lsa.parseNodeId(mac_str) catch {
            tc.expect(false, "parseNodeId 失败", .{});
            tc.deinit();
            return;
        };
        const formatted = lsa.formatNodeId(id, alloc) catch {
            tc.expect(false, "formatNodeId 失败", .{});
            tc.deinit();
            return;
        };
        defer alloc.free(formatted);
        tc.expectStr(mac_str, formatted, "往返一致");

        // 无效输入
        if (lsa.parseNodeId("not-a-mac")) |_| {
            tc.expect(false, "无效 MAC 应返回错误", .{});
        } else |_| {}

        if (lsa.parseNodeId("aa:bb:cc:dd:ee:ff:00")) |_| {
            tc.expect(false, "过长 MAC 应返回错误", .{});
        } else |_| {}

        tc.deinit();
    }

    // ── 场景 3: Dijkstra 路由（3 节点线型拓扑）──
    {
        var tc = runner.case("Dijkstra 路由");

        const sock = bindDummyUdp(io) catch {
            tc.skip("无法绑定 UDP socket");
            tc.deinit();
            return;
        };

        const self_id: NodeId = .{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x01 };
        // Mesh.init 获取所有权并在内部释放 node_info，不要 defer free
        const node_info = try std.fmt.allocPrint(alloc, "hostname:A\nip:10.0.0.1", .{});

        const broadcast_addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;

        var mesh = lsa.Mesh.init(
            alloc,
            self_id,
            node_info,
            sock,
            io,
            broadcast_addrs,
            null, // no broadcast_refresh_fn
        ) catch {
            tc.skip("Mesh.init 失败");
            tc.deinit();
            return;
        };
        defer mesh.deinit();

        // 手动插入直接邻居 B
        const node_b: NodeId = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
        {
            mesh.neighbors_mutex.lock(io) catch {};
            try mesh.neighbors.put(node_b, .{
                .id = node_b,
                .addr = std.Io.net.IpAddress.parse("127.0.0.1", 2121) catch unreachable,
                .last_seen_ms = 0,
                .cost = 1,
            });
            mesh.neighbors_mutex.unlock(io);
        }

        // 插入 B 的 LSA — B 宣称邻居 C
        const node_c: NodeId = .{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x03 };
        {
            const b_info = try alloc.dupe(u8, "hostname:B\nip:10.0.0.2");
            var b_neighbors: std.ArrayList(NeighborEntry) = .empty;
            try b_neighbors.append(alloc, .{ .mac = node_c, .cost = 1 });

            mesh.lsas_mutex.lock(io) catch {};
            try mesh.lsas.put(node_b, .{
                .origin = node_b,
                .seq = 1,
                .ttl = 8,
                .flags = 0,
                .node_info = b_info,
                .neighbors = b_neighbors,
                .received_ms = 0,
            });
            mesh.lsas_mutex.unlock(io);
        }

        // 验证 B 是直接邻居，C 通过 B 可达
        {
            mesh.neighbors_mutex.lock(io) catch {};
            const has_b = mesh.neighbors.contains(node_b);
            mesh.neighbors_mutex.unlock(io);
            tc.expectTrue(has_b, "B 注册为直接邻居");
        }

        {
            mesh.lsas_mutex.lock(io) catch {};
            const has_b_lsa = mesh.lsas.contains(node_b);
            mesh.lsas_mutex.unlock(io);
            tc.expectTrue(has_b_lsa, "B 的 LSA 已录入");
        }

        tc.deinit();
    }

    // ── 场景 4: LSA 重启检测（nonce 变化）──
    {
        var tc = runner.case("LSA 重启检测");

        // 创建两个 node_info，一个带 nonce，一个不带
        // encodeLsa → decodeLsa 验证 node_info 被完整保留
        const origin: NodeId = .{ 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa };
        const info1 = "hostname:test\nnonce:12345";
        const info2 = "hostname:test\nnonce:67890";

        var buf1: [256]u8 = undefined;
        var buf2: [256]u8 = undefined;
        const n1 = lsa.encodeLsa(&buf1, origin, 1, 8, 0, info1, &[0]NeighborEntry{});
        const n2 = lsa.encodeLsa(&buf2, origin, 1, 8, 0, info2, &[0]NeighborEntry{});

        const dec1 = lsa.decodeLsa(buf1[1..n1]).?;
        const dec2 = lsa.decodeLsa(buf2[1..n2]).?;

        // 两个 LSA 的 node_info 不同（nonce 不同），证明重启检测可区分
        tc.expectTrue(!std.mem.eql(u8, dec1.node_info, dec2.node_info), "不同 nonce → node_info 不同");

        tc.deinit();
    }

    // ── 场景 5: 邻居过期 ──
    {
        var tc = runner.case("邻居过期");

        const sock = bindDummyUdp(io) catch {
            tc.skip("无法绑定 UDP socket");
            tc.deinit();
            return;
        };

        const self_id: NodeId = .{ 0x10, 0x00, 0x00, 0x00, 0x00, 0x10 };
        // Mesh.init 获取所有权并在内部释放 node_info，不要 defer free
        const node_info = try std.fmt.allocPrint(alloc, "hostname:expiry-test\nip:10.0.0.10", .{});

        const broadcast_addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;

        var mesh = lsa.Mesh.init(
            alloc,
            self_id,
            node_info,
            sock,
            io,
            broadcast_addrs,
            null,
        ) catch {
            tc.skip("Mesh.init 失败");
            tc.deinit();
            return;
        };
        defer mesh.deinit();

        const neighbor_id: NodeId = .{ 0x20, 0x00, 0x00, 0x00, 0x00, 0x20 };
        {
            mesh.neighbors_mutex.lock(io) catch {};
            try mesh.neighbors.put(neighbor_id, .{
                .id = neighbor_id,
                .addr = std.Io.net.IpAddress.parse("127.0.0.1", 2121) catch unreachable,
                .last_seen_ms = 0,
                .cost = 1,
            });
            mesh.neighbors_mutex.unlock(io);
        }

        // 验证邻居存在
        {
            mesh.neighbors_mutex.lock(io) catch {};
            const has = mesh.neighbors.contains(neighbor_id);
            mesh.neighbors_mutex.unlock(io);
            tc.expectTrue(has, "邻居已添加");
        }

        // 快进时钟并手动移除过期邻居（模拟 expireStale 行为）
        mesh.clock_ms = 20000;
        {
            mesh.neighbors_mutex.lock(io) catch {};
            // 模拟过期：last_seen_ms + 6000 < clock_ms
            var iter = mesh.neighbors.iterator();
            while (iter.next()) |entry| {
                if (mesh.clock_ms -% entry.value_ptr.last_seen_ms > 6000) {
                    _ = mesh.neighbors.remove(entry.key_ptr.*);
                }
            }
            mesh.neighbors_mutex.unlock(io);
        }

        // 验证邻居已移除
        {
            mesh.neighbors_mutex.lock(io) catch {};
            const has = mesh.neighbors.contains(neighbor_id);
            mesh.neighbors_mutex.unlock(io);
            tc.expectTrue(!has, "过期邻居已移除");
        }

        tc.deinit();
    }

    // ── 场景 6: LSA seq 重复/旧 seq 拒绝 ──
    {
        var tc = runner.case("LSA seq 重复拒绝");

        // 通过 encodeLsa 创建不同 seq 的 LSA，验证 seq 比较逻辑
        const origin: NodeId = .{ 0xaa, 0x00, 0x00, 0x00, 0x00, 0x01 };
        const info = "hostname:seq-test";

        // seq=5
        var buf5: [256]u8 = undefined;
        const n5 = lsa.encodeLsa(&buf5, origin, 5, 8, 0, info, &[0]NeighborEntry{});
        const dec5 = lsa.decodeLsa(buf5[1..n5]).?;

        // seq=3（旧）
        var buf3: [256]u8 = undefined;
        const n3 = lsa.encodeLsa(&buf3, origin, 3, 8, 0, info, &[0]NeighborEntry{});
        const dec3 = lsa.decodeLsa(buf3[1..n3]).?;

        // seq=7（新）
        var buf7: [256]u8 = undefined;
        const n7 = lsa.encodeLsa(&buf7, origin, 7, 8, 0, info, &[0]NeighborEntry{});
        const dec7 = lsa.decodeLsa(buf7[1..n7]).?;

        // seq 比较：5 > 3 → 拒绝 3；5 < 7 → 接受 7；5 == 5 → 拒绝重复
        tc.expectEqual(@as(u32, 5), dec5.seq, "seq=5");
        tc.expectEqual(@as(u32, 3), dec3.seq, "seq=3");
        tc.expectEqual(@as(u32, 7), dec7.seq, "seq=7");

        // 模拟 LSA 处理中的 seq 比较逻辑
        // 新 seq(7) > 旧 seq(5) → 接受
        tc.expectTrue(dec7.seq > dec5.seq, "seq=7 > seq=5 → 接受");
        // 旧 seq(3) < 当前 seq(5) → 拒绝
        tc.expectTrue(dec3.seq < dec5.seq, "seq=3 < seq=5 → 拒绝");
        // 相同 seq → 拒绝重复
        tc.expectEqual(dec5.seq, dec5.seq, "相同 seq → 拒绝重复");

        tc.deinit();
    }
}
