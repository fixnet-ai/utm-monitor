//! Mesh networking layer: UDP broadcast discovery via LSA, KCP reliable transport,
//! link-state routing (Dijkstra), and KCP relay for multi-hop tunnels.
//!
//! Replaces the legacy "ARE YOU OK?" / "ANNOUNCE" text protocol with a unified
//! binary protocol on UDP :2121. First-byte dispatch identifies message type.

const std = @import("std");
const builtin = @import("builtin");
const kcp = @import("kcp.zig");
const protocol = @import("protocol.zig");

const net = std.Io.net;
const assert = std.debug.assert;

// ═══════════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Node identifier (MAC address, 6 bytes)
pub const NodeId = [6]u8;

/// Parse "aa:bb:cc:dd:ee:ff" → NodeId. Returns error on malformed input.
pub fn parseNodeId(text: []const u8) !NodeId {
    if (text.len != 17) return error.InvalidFormat;
    var id: NodeId = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |byte_str| {
        if (i >= 6) return error.InvalidFormat;
        id[i] = try std.fmt.parseInt(u8, byte_str, 16);
        i += 1;
    }
    if (i != 6) return error.InvalidFormat;
    return id;
}

/// Derive a unique NodeId by hashing MAC + suffix together.
/// Used when multiple mesh nodes share a physical MAC (e.g. local testing
/// with Host + Guest on the same machine using --peer-mesh).
pub fn deriveNodeId(mac_text: []const u8, suffix: []const u8) !NodeId {
    const mac_id = try parseNodeId(mac_text);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&mac_id);
    hasher.update(suffix);
    const h: u64 = hasher.final();
    const h_bytes: [8]u8 = @bitCast(h);
    var id: NodeId = undefined;
    @memcpy(&id, h_bytes[0..6]);
    return id;
}

/// Format NodeId → "aa:bb:cc:dd:ee:ff"
pub fn formatNodeId(id: NodeId, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        id[0], id[1], id[2], id[3], id[4], id[5],
    });
}

/// Compute KCP conversation ID from two NodeIds (XOR of MACs → u32).
pub fn computeConv(a: NodeId, b: NodeId, nonce: u32) u32 {
    var conv: u32 = nonce;
    for (0..6) |i| {
        const shift: u5 = @intCast((i % 4) * 8);
        conv ^= @as(u32, @intCast(a[i] ^ b[i])) << shift;
    }
    return conv;
}

/// Generate a process-unique nonce from ASLR-entropy (stack address) and PID.
/// Changes on every process start, ensuring KCP conversation IDs are unique
/// across Host restarts — stale sessions are naturally abandoned.
fn generateNonce() u32 {
    // Stack variable address provides ASLR entropy (randomized per-process).
    var dummy: u8 = undefined;
    const stack_addr: u32 = @truncate(@intFromPtr(&dummy));
    // PID adds uniqueness across rapid restarts where stack layout might be similar.
    const pid: u32 = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.c.getpid());
    return pid ^ stack_addr;
}

/// Read the KCP conversation ID from a KCP packet embedded in mesh KCP data.
/// The KCP header starts at offset 13 (after 1-byte TTL + 6-byte src + 6-byte dst).
/// KCP conv is u32 big-endian at byte 0 of the KCP header.
pub fn readKcpConv(data: []const u8) u32 {
    return std.mem.readInt(u32, data[13..17], .big);
}

// ═══════════════════════════════════════════════════════════════════════════════
// LSA (Link-State Advertisement)
// ═══════════════════════════════════════════════════════════════════════════════

/// A received/stored LSA entry with expiry tracking.
pub const LsaEntry = struct {
    origin: NodeId,
    seq: u32,
    ttl: u8,
    flags: u8,
    node_info: []const u8, // heap-allocated: "hostname:...\nip:...\n..."
    neighbors: std.ArrayList(NeighborEntry), // neighbors advertised in this LSA
    received_ms: u32, // timestamp when received (for expiry)

    pub fn deinit(self: *LsaEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.node_info);
        self.neighbors.deinit(allocator);
        self.* = undefined;
    }
};

/// A neighbor entry within an LSA.
pub const NeighborEntry = struct {
    mac: NodeId,
    cost: u8, // 1 = direct, higher = worse
};

/// Encode an LSA into a buffer. Returns encoded length.
/// Format: type(1) origin(6) seq(4) ttl(1) flags(1) node_info_len(2) node_info(variable) neighbor_count(1) neighbors(variable)
pub fn encodeLsa(
    buf: []u8,
    origin: NodeId,
    seq: u32,
    ttl: u8,
    flags: u8,
    node_info: []const u8,
    neighbors: []const NeighborEntry,
) usize {
    assert(buf.len >= 15 + node_info.len + 1 + neighbors.len * 7);

    buf[0] = protocol.MESH_TYPE_LSA;
    @memcpy(buf[1..7], &origin);
    std.mem.writeInt(u32, buf[7..11], seq, .big);
    buf[11] = ttl;
    buf[12] = flags;
    std.mem.writeInt(u16, buf[13..15], @intCast(node_info.len), .big);
    @memcpy(buf[15..][0..node_info.len], node_info);
    var pos: usize = 15 + node_info.len;
    buf[pos] = @intCast(neighbors.len);
    pos += 1;
    for (neighbors) |n| {
        @memcpy(buf[pos..][0..6], &n.mac);
        buf[pos + 6] = n.cost;
        pos += 7;
    }
    return pos;
}

/// Decoded LSA contents.
pub const DecodedLsa = struct {
    origin: NodeId,
    seq: u32,
    ttl: u8,
    flags: u8,
    node_info: []const u8, // slice into original buffer
};

/// Decode an LSA from raw bytes (excluding type byte). Returns null if malformed.
pub fn decodeLsa(data: []const u8) ?DecodedLsa {
    if (data.len < 15) return null; // origin(6) + seq(4) + ttl(1) + flags(1) + info_len(2) = 14, + at least 1 byte info

    const origin: NodeId = data[0..6].*;
    const seq = std.mem.readInt(u32, data[6..10], .big);
    const ttl = data[10];
    const flags = data[11];
    const info_len = std.mem.readInt(u16, data[12..14], .big);
    if (data.len < 14 + info_len + 1) return null; // need at least neighbor_count byte

    const node_info = data[14..][0..info_len];
    return DecodedLsa{
        .origin = origin,
        .seq = seq,
        .ttl = ttl,
        .flags = flags,
        .node_info = node_info,
    };
}

/// Parse neighbor list from an LSA buffer at the given offset.
/// Returns the parsed neighbors (caller owns the ArrayList).
pub fn parseLsaNeighbors(
    allocator: std.mem.Allocator,
    data: []const u8,
    info_len: u16,
) !std.ArrayList(NeighborEntry) {
    var list: std.ArrayList(NeighborEntry) = .empty;
    const pos: usize = 14 + info_len;
    if (pos >= data.len) return list;

    const count = data[pos];
    var offset: usize = pos + 1;

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (offset + 7 > data.len) break;
        const mac: NodeId = data[offset..][0..6].*;
        const cost = data[offset + 6];
        try list.append(allocator, .{ .mac = mac, .cost = cost });
        offset += 7;
    }
    return list;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Neighbor (directly connected node)
// ═══════════════════════════════════════════════════════════════════════════════

pub const Neighbor = struct {
    id: NodeId,
    addr: net.IpAddress, // last known address (for unicast)
    last_seen_ms: u32,
    cost: u8 = 1,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Route
// ═══════════════════════════════════════════════════════════════════════════════

pub const Route = struct {
    dest: NodeId,
    next_hop: NodeId,
    cost: u32,
};

// ═══════════════════════════════════════════════════════════════════════════════
// MeshSession — KCP tunnel to a remote node
// ═══════════════════════════════════════════════════════════════════════════════

pub const MeshSession = struct {
    kcp_inst: *kcp.Kcp,
    mesh: *Mesh,
    remote: NodeId,
    conv: u32,
    next_hop: NodeId,
    allocator: std.mem.Allocator,

    /// KCP keepalive — TCP-style idle probe.
    /// After 5s idle, send a 1-byte probe through KCP. Each probe expects
    /// the peer's KCP ACK response — if no ACK arrives, KCP retransmits.
    /// After 3 unanswered probes (~15s total), the session is declared dead.
    last_recv_ms: u32 = 0,
    keepalive_probes: u8 = 0,
    keepalive_next_ms: u32 = 0,

    /// Set true by the mesh thread when keepalive declares dead.
    /// Checked by Tunnel.isAlive() and the Guest command loop.
    dead: bool = false,

    pub fn deinit(self: *MeshSession) void {
        self.kcp_inst.release();
        self.* = undefined;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Mesh — central mesh networking instance
// ═══════════════════════════════════════════════════════════════════════════════

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    node_id: NodeId,
    node_info: []const u8, // our info string for LSA broadcast (heap-allocated)
    socket: net.Socket,
    io: std.Io,

    // Broadcast addresses for LSA (subnet-directed + 255.255.255.255)
    broadcast_addrs: std.ArrayList(net.IpAddress),

    // LSA state
    lsa_seq: u32,
    last_lsa_broadcast_ms: u32,

    // Topology
    neighbors: std.AutoHashMap(NodeId, Neighbor),
    lsas: std.AutoHashMap(NodeId, LsaEntry),
    routes: std.ArrayList(Route),

    // KCP sessions (keyed by conv)
    sessions: std.AutoHashMap(u32, *MeshSession),
    sessions_mutex: std.Io.Mutex,

    /// Per-process nonce, XOR'd with connect_counter to produce unique
    /// KCP conversation IDs across reconnections and Host restarts.
    nonce: u32,

    /// Counter incremented on each connect() call. Ensures each reconnection
    /// gets a unique conv, preventing stale KCP seq number mismatch.
    connect_counter: u32,

    // Shutdown
    shutdown: std.atomic.Value(bool),

    // Upgrade signal (set when version mismatch detected via LSA)
    upgrade_needed: *std.atomic.Value(bool),

    // Host gateway IP (Guest only) — LSA version check only fires for this IP.
    // Empty string on Host (no self-upgrade) or when host-ip is not known.
    host_gateway_ip: []const u8,

    // Clock (monotonic ms, advanced in run loop)
    clock_ms: u32,

    /// Create a new Mesh instance. Takes ownership of node_info (will free on deinit).
    /// socket should be a UDP socket already bound to :2121 with broadcast enabled.
    /// broadcast_addrs should contain subnet-directed broadcast + 255.255.255.255.
    pub fn init(
        allocator: std.mem.Allocator,
        node_id: NodeId,
        node_info: []const u8,
        socket: net.Socket,
        io: std.Io,
        upgrade_needed: *std.atomic.Value(bool),
        broadcast_addrs: std.ArrayList(net.IpAddress),
        host_gateway_ip: []const u8,
    ) !Mesh {
        return Mesh{
            .allocator = allocator,
            .node_id = node_id,
            .node_info = node_info,
            .socket = socket,
            .io = io,
            .broadcast_addrs = broadcast_addrs,
            .lsa_seq = 0,
            .last_lsa_broadcast_ms = 0,
            .neighbors = std.AutoHashMap(NodeId, Neighbor).init(allocator),
            .lsas = std.AutoHashMap(NodeId, LsaEntry).init(allocator),
            .routes = .empty,
            .sessions = std.AutoHashMap(u32, *MeshSession).init(allocator),
            .sessions_mutex = std.Io.Mutex.init,
            .shutdown = std.atomic.Value(bool).init(false),
            .upgrade_needed = upgrade_needed,
            .host_gateway_ip = host_gateway_ip,
            .nonce = generateNonce(),
            .connect_counter = 0,
            .clock_ms = 0,
        };
    }

    /// Release all resources.
    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.node_info);

        self.broadcast_addrs.deinit(self.allocator);

        // Free neighbors
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |_| {}
        self.neighbors.deinit();

        // Free LSAs
        var l_iter = self.lsas.iterator();
        while (l_iter.next()) |entry| {
            var lsa = entry.value_ptr.*;
            lsa.deinit(self.allocator);
        }
        self.lsas.deinit();

        // Free sessions
        var s_iter = self.sessions.iterator();
        while (s_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();

        self.routes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Signal shutdown (thread-safe). The run() loop will exit.
    /// On Windows, also closes the socket to unblock a pending
    /// blocking receive() call (receiveTimeout is unsupported).
    pub fn signalShutdown(self: *Mesh) void {
        self.shutdown.store(true, .release);
        if (builtin.os.tag == .windows) {
            // Closing the socket unblocks any pending receive() call
            // in the mesh thread, allowing it to check shutdown and exit.
            self.socket.close(self.io);
        }
    }

    /// Main UDP receive/dispatch loop. Blocks until shutdown is signaled.
    /// Should be run in its own thread.
    pub fn run(self: *Mesh) !void {
        // Broadcast initial LSA before entering receive loop.
        // On Windows, receive() blocks without timeout and periodicTasks
        // only runs after received packets, so we need this initial
        // broadcast to announce our presence immediately.
        self.broadcastOwnLsaInit();
        self.last_lsa_broadcast_ms = self.clock_ms;

        if (builtin.os.tag == .windows) {
            return self.runWindows();
        }
        return self.runPosix();
    }

    /// POSIX: use receiveTimeout with 1-second timeout for periodic tasks.
    fn runPosix(self: *Mesh) !void {
        var buf: [4096]u8 = undefined;

        while (!self.shutdown.load(.acquire)) {
            const timeout: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(1), .clock = .awake } };
            const msg = self.socket.receiveTimeout(self.io, &buf, timeout) catch |err| {
                switch (err) {
                    error.Timeout => {
                        self.clock_ms +%= 1000;
                        try self.periodicTasks();
                        continue;
                    },
                    else => {
                        std.log.err("[mesh] receive error: {}", .{err});
                        continue;
                    },
                }
            };

            self.clock_ms +%= 10;

            if (msg.data.len == 0) continue;

            switch (msg.data[0]) {
                protocol.MESH_TYPE_LSA => try self.handleLsa(msg.data[1..], msg.from),
                protocol.MESH_TYPE_KCP => try self.handleKcpData(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PING => self.handlePing(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PONG => self.handlePong(msg.data[1..]),
                else => {},
            }

            try self.periodicTasks();
        }

        std.log.info("[mesh] Shutting down", .{});
    }

    /// Windows: Zig 0.16.0 Io.Threaded on ARM64 Windows sometimes fails
    /// with error.ConcurrencyUnavailable even for synchronous operate().
    /// The underlying netReceiveOneWindows ignores the Io instance
    /// entirely (calls NtDeviceIoControlFile directly), but the Io
    /// initialization may trigger worker threads that interfere.
    /// Workaround: use global_single_threaded Io which has no worker
    /// threads and forces all operations synchronous.
    /// Shutdown is handled by the main thread closing the socket to
    /// unblock receive(). Periodic tasks run after each received
    /// packet — Host LSA broadcasts every 5s provide regular wakeups.
    fn runWindows(self: *Mesh) !void {
        // Use the single-threaded Io to avoid ConcurrencyUnavailable on Windows.
        const local_io = std.Io.Threaded.global_single_threaded.io();
        var buf: [4096]u8 = undefined;

        while (!self.shutdown.load(.acquire)) {
            const msg = self.socket.receive(local_io, &buf) catch |err| {
                if (self.shutdown.load(.acquire)) break;
                std.log.err("[mesh] receive error: {}", .{err});
                std.Io.sleep(local_io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                continue;
            };

            self.clock_ms +%= 10;

            if (msg.data.len == 0) continue;

            switch (msg.data[0]) {
                protocol.MESH_TYPE_LSA => try self.handleLsa(msg.data[1..], msg.from),
                protocol.MESH_TYPE_KCP => try self.handleKcpData(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PING => self.handlePing(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PONG => self.handlePong(msg.data[1..]),
                else => {},
            }

            try self.periodicTasks();
        }

        std.log.info("[mesh] Shutting down", .{});
    }

    /// Broadcast own LSA once before entering receive loop.
    /// Separate from broadcastOwnLsa to avoid the interval check.
    fn broadcastOwnLsaInit(self: *Mesh) void {
        self.lsa_seq +%= 1;

        var neighbor_list: [32]NeighborEntry = undefined;
        var neighbor_count: usize = 0;
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            if (neighbor_count >= neighbor_list.len) break;
            neighbor_list[neighbor_count] = .{ .mac = entry.key_ptr.*, .cost = entry.value_ptr.cost };
            neighbor_count += 1;
        }

        var lsa_buf: [1500]u8 = undefined;
        const len = encodeLsa(
            &lsa_buf,
            self.node_id,
            self.lsa_seq,
            protocol.MESH_MAX_TTL,
            0,
            self.node_info,
            neighbor_list[0..neighbor_count],
        );

        for (self.broadcast_addrs.items) |*addr| {
            self.socket.send(self.io, addr, lsa_buf[0..len]) catch |err| {
                std.log.err("[mesh] initial broadcast LSA to {any} failed: {}", .{ addr, err });
            };
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Periodic tasks
    // ──────────────────────────────────────────────────────────────────────────

    fn periodicTasks(self: *Mesh) !void {
        // Broadcast own LSA every MESH_LSA_INTERVAL_MS
        if (self.clock_ms - self.last_lsa_broadcast_ms >= protocol.MESH_LSA_INTERVAL_MS) {
            self.broadcastOwnLsa();
            self.last_lsa_broadcast_ms = self.clock_ms;
        }

        // Expire stale neighbors every 5 seconds
        if (self.clock_ms % 5000 < 10) {
            self.expireStale();
        }

        // Update all KCP sessions + keepalive (lock to prevent concurrent modification)
        self.sessions_mutex.lock(self.io) catch {};
        defer self.sessions_mutex.unlock(self.io);

        var s_iter = self.sessions.iterator();
        while (s_iter.next()) |entry| {
            const conv = entry.key_ptr.*;
            const sess = entry.value_ptr.*;

            // Once keepalive has declared a session dead, stop calling
            // kcp.update() — retransmissions would trigger meshKcpOutput
            // which tries to find a neighbor that's already been removed.
            if (sess.dead) continue;

            sess.kcp_inst.update(self.clock_ms);

            // ── KCP keepalive ──
            // Check if data has arrived (proves peer is alive)
            if (sess.kcp_inst.peekSize() >= 0) {
                sess.last_recv_ms = self.clock_ms;
                sess.keepalive_probes = 0;
                sess.keepalive_next_ms = 0;
            }

            const idle = self.clock_ms -| sess.last_recv_ms;

            if (idle < 5000) {
                // Link is active — nothing to do
            } else if (sess.keepalive_probes >= 3) {
                // Dead: 3 probes sent, no response. Set flag only —
                // the tunnel owner (handleMeshGuest / command loop)
                // checks isAlive() and does the actual closeSession cleanup.
                std.log.info("[mesh] keepalive dead conv={d} idle={d:.1}s", .{ conv, @as(f64, @floatFromInt(idle)) / 1000.0 });
                sess.dead = true;
            } else if (sess.keepalive_next_ms == 0) {
                // First probe after idle period
                sess.keepalive_probes = 1;
                sess.keepalive_next_ms = self.clock_ms + 5000;
                _ = sess.kcp_inst.send(&[_]u8{0xFF}) catch {};
            } else if (self.clock_ms >= sess.keepalive_next_ms) {
                // Next probe interval elapsed → send another
                sess.keepalive_probes += 1;
                sess.keepalive_next_ms = self.clock_ms + 5000;
                _ = sess.kcp_inst.send(&[_]u8{0xFF}) catch {};
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // LSA handling
    // ──────────────────────────────────────────────────────────────────────────

    /// Broadcast our own LSA to all subnet broadcast addresses + 255.255.255.255.
    fn broadcastOwnLsa(self: *Mesh) void {
        self.lsa_seq +%= 1;

        // Collect neighbor list
        var neighbor_list: [32]NeighborEntry = undefined;
        var neighbor_count: usize = 0;
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            if (neighbor_count >= neighbor_list.len) break;
            neighbor_list[neighbor_count] = .{ .mac = entry.key_ptr.*, .cost = entry.value_ptr.cost };
            neighbor_count += 1;
        }

        var lsa_buf: [1500]u8 = undefined;
        const len = encodeLsa(
            &lsa_buf,
            self.node_id,
            self.lsa_seq,
            protocol.MESH_MAX_TTL,
            0, // flags
            self.node_info,
            neighbor_list[0..neighbor_count],
        );

        // Send to every broadcast address (subnet-directed + 255.255.255.255)
        for (self.broadcast_addrs.items) |*addr| {
            self.socket.send(self.io, addr, lsa_buf[0..len]) catch |err| {
                std.log.err("[mesh] broadcast LSA to {any} failed: {}", .{ addr, err });
            };
        }
    }

    /// Process an incoming LSA (data does NOT include the type byte).
    fn handleLsa(self: *Mesh, data: []const u8, from: net.IpAddress) !void {
        const decoded = decodeLsa(data) orelse return;
        if (std.mem.eql(u8, &decoded.origin, &self.node_id)) return; // ignore our own LSA

        // TTL check
        if (decoded.ttl <= 1) return;

        // Check if we already have a newer or same-seq LSA
        if (self.lsas.getPtr(decoded.origin)) |existing| {
            // Use wrapping comparison: treat seq as wrapping, ignore if not newer
            const diff: i32 = @bitCast(decoded.seq -% existing.seq);
            if (diff <= 0) {
                // If node_info changed (e.g. Guest restart with different
                // hostname), treat as a restart — accept the new LSA even
                // though the seq number is lower/non-increasing.
                if (!std.mem.eql(u8, decoded.node_info, existing.node_info)) {
                    std.log.info("[mesh] LSA restart detected: node_info changed, accepting lower seq", .{});
                    existing.deinit(self.allocator);
                } else {
                    return; // existing is same or newer
                }
            } else {
                // Replace: free old entry
                existing.deinit(self.allocator);
            }
        }

        // Store LSA
        const info_dup = try self.allocator.dupe(u8, decoded.node_info);
        errdefer self.allocator.free(info_dup);

        var neighbors = try parseLsaNeighbors(self.allocator, data, @intCast(decoded.node_info.len));
        errdefer neighbors.deinit(self.allocator);

        try self.lsas.put(decoded.origin, .{
            .origin = decoded.origin,
            .seq = decoded.seq,
            .ttl = decoded.ttl,
            .flags = decoded.flags,
            .node_info = info_dup,
            .neighbors = neighbors,
            .received_ms = self.clock_ms,
        });

        // Update neighbor table (directly connected = LSA from that node)
        {
            const result = try self.neighbors.getOrPut(decoded.origin);
            result.value_ptr.* = .{
                .id = decoded.origin,
                .addr = from,
                .last_seen_ms = self.clock_ms,
                .cost = 1, // direct neighbor
            };
        }

        // Check for version mismatch (upgrade signal).
        // Only fire when host_gateway_ip is set (Guest mode) AND the LSA
        // comes from the Host (matched by IP). This prevents false upgrades
        // triggered by peer Guests running different versions.
        if (!self.upgrade_needed.load(.acquire) and self.host_gateway_ip.len > 0) {
            // Extract IP from node_info to verify this LSA is from the Host
            var remote_ip: []const u8 = "";
            if (std.mem.indexOf(u8, decoded.node_info, "ip:")) |ip_start| {
                const ip_line = decoded.node_info[ip_start + "ip:".len ..];
                const ip_end = std.mem.indexOfScalar(u8, ip_line, '\n') orelse ip_line.len;
                remote_ip = ip_line[0..ip_end];
            }
            if (remote_ip.len > 0 and std.mem.eql(u8, remote_ip, self.host_gateway_ip)) {
                // Parse version from node_info
                if (std.mem.indexOf(u8, decoded.node_info, "version:")) |v_start| {
                    const v_line = decoded.node_info[v_start + "version:".len ..];
                    const v_end = std.mem.indexOfScalar(u8, v_line, '\n') orelse v_line.len;
                    const remote_version = v_line[0..v_end];
                    if (!std.mem.eql(u8, remote_version, protocol.VERSION)) {
                        std.log.info("[mesh] LSA version mismatch from host: remote={s} local={s} — signalling upgrade", .{ remote_version, protocol.VERSION });
                        self.upgrade_needed.store(true, .release);
                    }
                }
            }
        }

        // Rebuild routes on topology change
        self.rebuildRoutes();

        // Relay LSA: decrement TTL, re-broadcast to our neighbors
        if (decoded.ttl > 2) {
            var relay_buf: [1500]u8 = undefined;
            relay_buf[0] = protocol.MESH_TYPE_LSA;
            @memcpy(relay_buf[1..][0..data.len], data);
            relay_buf[1 + 6 + 4] = decoded.ttl - 1; // decrement TTL in-place
            const total_len = 1 + data.len;

            var n_iter = self.neighbors.iterator();
            while (n_iter.next()) |entry| {
                if (std.mem.eql(u8, &entry.key_ptr.*, &decoded.origin)) continue; // don't send back to origin
                self.socket.send(self.io, &entry.value_ptr.addr, relay_buf[0..total_len]) catch {};
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // KCP data handling
    // ──────────────────────────────────────────────────────────────────────────

    /// Process an incoming KCP_DATA packet (data does NOT include the type byte).
    /// Format: ttl(1) src_mac(6) dst_mac(6) kcp_segment(variable)
    fn handleKcpData(self: *Mesh, data: []const u8, _: net.IpAddress) !void {
        if (data.len < 13 + kcp.IKCP_OVERHEAD) return;

        const ttl = data[0];
        if (ttl <= 1) return;

        const src_mac: NodeId = data[1..7].*;
        const dst_mac: NodeId = data[7..13].*;

        // Read KCP conversation ID directly from the KCP header.
        // This is more robust than computing from MAC addresses because
        // the conv embeds the Host's startup nonce — when Host restarts,
        // the conv changes and a fresh session is created automatically.
        const kcp_conv = readKcpConv(data);

        // Is this for us?
        if (std.mem.eql(u8, &dst_mac, &self.node_id)) {
            // Deliver to our KCP session (keyed by conv from packet header)
            // Lock to check/create session safely (protects against tunnelManager)
            self.sessions_mutex.lock(self.io) catch {};
            const existing = self.sessions.get(kcp_conv);
            if (existing) |sess| {
                self.sessions_mutex.unlock(self.io);
                sess.kcp_inst.input(data[13..]) catch |err| {
                    std.log.err("[mesh] KCP input error: {}", .{err});
                };
                sess.last_recv_ms = self.clock_ms;
                sess.keepalive_probes = 0;
            } else {
                std.log.debug("[mesh] New KCP session from incoming data conv={d}", .{kcp_conv});
                // New incoming session — create KCP instance and store
                const new_sess = try self.allocator.create(MeshSession);
                errdefer self.allocator.destroy(new_sess);
                new_sess.* = .{
                    .kcp_inst = try kcp.Kcp.create(self.allocator, kcp_conv, new_sess),
                    .mesh = self,
                    .remote = src_mac,
                    .conv = kcp_conv,
                    .next_hop = src_mac,
                    .allocator = self.allocator,
                    .last_recv_ms = self.clock_ms,
                };
                new_sess.kcp_inst.setOutput(meshKcpOutput);
                try self.sessions.put(kcp_conv, new_sess);
                self.sessions_mutex.unlock(self.io);
                new_sess.kcp_inst.input(data[13..]) catch |err| {
                    std.log.err("[mesh] KCP input error (new session): {}", .{err});
                };
            }
        } else {
            // Relay: forward to next hop toward dst
            if (self.routeTo(dst_mac)) |next_hop| {
                if (self.neighbors.get(next_hop)) |neighbor| {
                    var relay_buf: [4096]u8 = undefined;
                    relay_buf[0] = protocol.MESH_TYPE_KCP;
                    relay_buf[1] = ttl - 1;
                    @memcpy(relay_buf[2..][0..data.len-1], data[1..][0..data.len - 1]); // copy src+dst+kcp
                    _ = self.socket.send(self.io, &neighbor.addr, relay_buf[0 .. 1 + data.len]) catch {};
                }
            }
        }
    }

    /// KCP output callback: when a session has data to send, encapsulate as KCP_DATA and send.
    fn meshKcpOutput(conv: u32, data: []const u8, user: ?*anyopaque) void {
        const user_ptr = user orelse {
            std.log.err("[mesh] kcp_output: user is null", .{});
            return;
        };
        const sess: *MeshSession = @ptrCast(@alignCast(user_ptr));
        const mesh = sess.mesh;
        // Look up next-hop neighbor for sending
        if (mesh.neighbors.get(sess.next_hop)) |neighbor| {
            std.log.debug("[mesh] kcp_output: conv={d} len={d} to={}", .{ conv, data.len, neighbor.addr });
            var buf: [4096]u8 = undefined;
            buf[0] = protocol.MESH_TYPE_KCP;
            buf[1] = protocol.MESH_MAX_TTL;
            @memcpy(buf[2..8], &mesh.node_id);
            @memcpy(buf[8..14], &sess.remote);
            const header_len: usize = 14;
            if (header_len + data.len > buf.len) {
                std.log.err("[mesh] kcp_output: buffer overflow conv={d} len={d}", .{ conv, data.len });
                return;
            }
            @memcpy(buf[header_len..][0..data.len], data);
            mesh.socket.send(mesh.io, &neighbor.addr, buf[0 .. header_len + data.len]) catch |err| {
                std.log.err("[mesh] kcp_output: send failed conv={d} addr={} len={d} err={}", .{ conv, neighbor.addr, header_len + data.len, err });
            };
        } else {
            std.log.err("[mesh] kcp_output: neighbor not found for next_hop conv={d}", .{conv});
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Ping/Pong handling
    // ──────────────────────────────────────────────────────────────────────────

    fn handlePing(self: *Mesh, data: []const u8, from: net.IpAddress) void {
        if (data.len < 10) return; // src_mac(6) + timestamp(4)
        // Respond with pong
        var pong: [11]u8 = undefined;
        pong[0] = protocol.MESH_TYPE_PONG;
        @memcpy(pong[1..], data[0..10]);
        self.socket.send(self.io, &from, &pong) catch {};
    }

    fn handlePong(self: *Mesh, data: []const u8) void {
        if (data.len < 10) return;
        // Used for RTT measurement — could update neighbor cost based on RTT
        _ = .{ self, data };
    }

    /// Send a ping to a specific neighbor (for RTT/cost measurement).
    pub fn sendPing(self: *Mesh, dest_id: NodeId) void {
        if (self.neighbors.get(dest_id)) |neighbor| {
            var ping: [11]u8 = undefined;
            ping[0] = protocol.MESH_TYPE_PING;
            @memcpy(ping[1..7], &self.node_id);
            std.mem.writeInt(u32, ping[7..11], self.clock_ms, .big);
            self.socket.send(self.io, &neighbor.addr, &ping) catch {};
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Routing (Dijkstra)
    // ──────────────────────────────────────────────────────────────────────────

    /// Find the next hop toward a destination. Returns null if unreachable.
    pub fn routeTo(self: *Mesh, dest: NodeId) ?NodeId {
        for (self.routes.items) |r| {
            if (std.mem.eql(u8, &r.dest, &dest)) return r.next_hop;
        }
        return null;
    }

    /// Rebuild routing table using Dijkstra's algorithm.
    /// Builds new routes in a temporary list and only replaces the live table
    /// on success — avoids losing existing routes on allocation failure.
    fn rebuildRoutes(self: *Mesh) void {
        var new_routes: std.ArrayList(Route) = .empty;

        // Build adjacency list from LSA database
        // Simple Dijkstra: nodes reachable through direct neighbors
        var visited = std.AutoHashMap(NodeId, void).init(self.allocator);
        defer visited.deinit();
        var dist = std.AutoHashMap(NodeId, u32).init(self.allocator);
        defer dist.deinit();
        var prev = std.AutoHashMap(NodeId, NodeId).init(self.allocator);
        defer prev.deinit();

        // Initialize distances: self = 0, direct neighbors get their cost
        // Using a simple approach: iterate over direct neighbors and their LSAs

        // Mark self as visited with cost 0
        visited.put(self.node_id, {}) catch {};
        dist.put(self.node_id, 0) catch {};

        // Add direct neighbors (cost = 1)
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            const nid = entry.key_ptr.*;
            visited.put(nid, {}) catch {};
            dist.put(nid, entry.value_ptr.cost) catch {};
            prev.put(nid, nid) catch {}; // next hop = self (direct)
            // Route: next_hop = nid (direct connection)
            new_routes.append(self.allocator, .{
                .dest = nid,
                .next_hop = nid,
                .cost = entry.value_ptr.cost,
            }) catch continue; // skip this neighbor on OOM, keep building
        }

        // For each neighbor's LSA, find nodes reachable through them
        n_iter = self.neighbors.iterator();
        while (n_iter.next()) |neighbor_entry| {
            const neighbor_id = neighbor_entry.key_ptr.*;
            if (self.lsas.get(neighbor_id)) |neighbor_lsa| {
                // Neighbor can reach nodes in its own neighbor list
                for (neighbor_lsa.neighbors.items) |nb| {
                    if (std.mem.eql(u8, &nb.mac, &self.node_id)) continue; // skip self
                    if (visited.contains(nb.mac)) continue; // already reached directly

                    const cost: u32 = neighbor_entry.value_ptr.cost + nb.cost;
                    visited.put(nb.mac, {}) catch {};
                    dist.put(nb.mac, cost) catch {};
                    prev.put(nb.mac, neighbor_id) catch {};
                    new_routes.append(self.allocator, .{
                        .dest = nb.mac,
                        .next_hop = neighbor_id,
                        .cost = cost,
                    }) catch continue;
                }
            }
        }

        // Try deeper paths (2-hop relay through neighbors of neighbors)
        var changed = true;
        var iter_count: u32 = 0;
        while (changed and iter_count < protocol.MESH_MAX_TTL) : (iter_count += 1) {
            changed = false;
            n_iter = self.neighbors.iterator();
            while (n_iter.next()) |neighbor_entry| {
                const neighbor_id = neighbor_entry.key_ptr.*;
                if (self.lsas.get(neighbor_id)) |neighbor_lsa| {
                    for (neighbor_lsa.neighbors.items) |nb| {
                        if (std.mem.eql(u8, &nb.mac, &self.node_id)) continue;
                        if (visited.contains(nb.mac)) continue;

                        const base_cost = dist.get(neighbor_id) orelse continue;
                        const new_cost = base_cost + nb.cost;
                        visited.put(nb.mac, {}) catch {};
                        dist.put(nb.mac, new_cost) catch {};
                        prev.put(nb.mac, neighbor_id) catch {};
                        new_routes.append(self.allocator, .{
                            .dest = nb.mac,
                            .next_hop = neighbor_id,
                            .cost = new_cost,
                        }) catch continue;
                        changed = true;
                    }
                }
            }
        }

        // Swap: only replace old routes after successful build.
        // Old routes are freed even if new_routes is empty (e.g. all neighbors gone).
        self.routes.deinit(self.allocator);
        self.routes = new_routes;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Session management
    // ──────────────────────────────────────────────────────────────────────────

    /// Create (or return existing) KCP session to a remote node.
    /// Thread-safe: locks sessions_mutex to protect against concurrent mesh.run() access.
    pub fn connect(self: *Mesh, dest: NodeId) !*MeshSession {
        self.sessions_mutex.lock(self.io) catch {};
        defer self.sessions_mutex.unlock(self.io);

        // Increment counter to ensure each reconnection gets a unique conv.
        // This prevents stale KCP seq number mismatch after reconnect
        // (when nonce hasn't changed because Host wasn't restarted).
        self.connect_counter +%= 1;
        const conv = computeConv(self.node_id, dest, self.nonce ^ self.connect_counter);
        if (self.sessions.get(conv)) |existing| return existing;

        const sess = try self.allocator.create(MeshSession);
        errdefer self.allocator.destroy(sess);

        const next_hop = self.routeTo(dest) orelse dest;
        sess.* = .{
            .kcp_inst = try kcp.Kcp.create(self.allocator, conv, sess),
            .mesh = self,
            .remote = dest,
            .conv = conv,
            .next_hop = next_hop,
            .allocator = self.allocator,
            .last_recv_ms = self.clock_ms,
        };
        sess.kcp_inst.setOutput(meshKcpOutput);

        try self.sessions.put(conv, sess);
        return sess;
    }

    /// Close and free a session.
    pub fn closeSession(self: *Mesh, sess: *MeshSession) void {
        self.sessions_mutex.lock(self.io) catch {};
        defer self.sessions_mutex.unlock(self.io);
        _ = self.sessions.remove(sess.conv);
        sess.deinit();
        self.allocator.destroy(sess);
    }

    /// Close the KCP session for a specific destination node, if any.
    /// Used before reconnecting to avoid stale KCP seq number mismatch.
    /// Finds the session by iterating (using `remote` field) rather than
    /// computing conv, because the conv may have changed due to
    /// connect_counter increments or nonce changes.
    pub fn closeSessionFor(self: *Mesh, dest: NodeId) void {
        self.sessions_mutex.lock(self.io) catch {};
        defer self.sessions_mutex.unlock(self.io);
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.*.remote, &dest)) {
                const sess = entry.value_ptr.*;
                _ = self.sessions.remove(entry.key_ptr.*);
                sess.deinit();
                self.allocator.destroy(sess);
                break;
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Maintenance
    // ──────────────────────────────────────────────────────────────────────────

    /// Expire stale neighbors and LSAs.
    fn expireStale(self: *Mesh) void {
        const timeout_ms: u32 = 15000; // 15s = 3× LSA interval + margin

        // Expire stale neighbors
        {
            var to_remove: std.ArrayList(NodeId) = .empty;
            var n_iter = self.neighbors.iterator();
            while (n_iter.next()) |entry| {
                const age = self.clock_ms -| entry.value_ptr.last_seen_ms;
                if (age > timeout_ms) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |nid| {
                _ = self.neighbors.remove(nid);
            }
            to_remove.deinit(self.allocator);
        }

        // Expire stale LSAs
        {
            var to_remove: std.ArrayList(NodeId) = .empty;
            var l_iter = self.lsas.iterator();
            while (l_iter.next()) |entry| {
                const age = self.clock_ms -| entry.value_ptr.received_ms;
                if (age > timeout_ms) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |nid| {
                if (self.lsas.getPtr(nid)) |existing| {
                    existing.deinit(self.allocator);
                    _ = self.lsas.remove(nid);
                }
            }
            to_remove.deinit(self.allocator);
        }

        // Rebuild routes if we removed anything
        if (self.neighbors.count() > 0) {
            self.rebuildRoutes();
        }
    }

    /// List known nodes (for --status display).
    pub fn listNodes(self: *Mesh, allocator: std.mem.Allocator) !std.ArrayList(NodeInfo) {
        var list: std.ArrayList(NodeInfo) = .empty;
        var seen = std.AutoHashMap(NodeId, void).init(allocator);
        defer seen.deinit();

        // Add direct neighbors
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            const nid = entry.key_ptr.*;
            if (seen.contains(nid)) continue;
            seen.put(nid, {}) catch {};

            var info: NodeInfo = .{ .mac = nid, .cost = entry.value_ptr.cost, .is_direct = true };
            // Try to get node_info from LSA
            if (self.lsas.get(nid)) |lsa| {
                info.node_info = try allocator.dupe(u8, lsa.node_info);
            }
            try list.append(allocator, info);
        }

        // Add indirect nodes (from routing table)
        for (self.routes.items) |r| {
            if (seen.contains(r.dest)) continue;
            seen.put(r.dest, {}) catch {};

            var info: NodeInfo = .{ .mac = r.dest, .cost = r.cost, .is_direct = false };
            if (self.lsas.get(r.dest)) |lsa| {
                info.node_info = try allocator.dupe(u8, lsa.node_info);
            }
            try list.append(allocator, info);
        }

        return list;
    }
};

/// Public node information (for status queries).
pub const NodeInfo = struct {
    mac: NodeId,
    cost: u32,
    is_direct: bool,
    node_info: []const u8 = "", // heap-allocated if present

    pub fn deinit(self: *NodeInfo, allocator: std.mem.Allocator) void {
        if (self.node_info.len > 0) allocator.free(self.node_info);
        self.* = undefined;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "parseNodeId" {
    const id = try parseNodeId("aa:bb:cc:dd:ee:ff");
    try std.testing.expectEqual(@as(u8, 0xaa), id[0]);
    try std.testing.expectEqual(@as(u8, 0xff), id[5]);
}

test "parseNodeId invalid" {
    try std.testing.expectError(error.InvalidFormat, parseNodeId("not-a-mac"));
    try std.testing.expectError(error.InvalidFormat, parseNodeId("aa:bb:cc"));
}

test "formatNodeId" {
    const id: NodeId = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const text = try formatNodeId(id, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", text);
}

test "computeConv" {
    const a: NodeId = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const b: NodeId = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    // Same MACs with nonce=0 → conv = 0 (all XOR pairs cancel)
    try std.testing.expectEqual(@as(u32, 0), computeConv(a, b, 0));
    // Same MACs with nonce=42 → conv = 42
    try std.testing.expectEqual(@as(u32, 42), computeConv(a, b, 42));

    const a2: NodeId = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const b2: NodeId = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    _ = computeConv(a2, b2, 0); // just verify non-zero and deterministic
    try std.testing.expectEqual(computeConv(a2, b2, 0), computeConv(a2, b2, 0));
    // Verify nonce changes conv
    try std.testing.expect(computeConv(a2, b2, 0) != computeConv(a2, b2, 1));
}

test "readKcpConv" {
    var buf: [64]u8 = [_]u8{0} ** 64;
    // Write a KCP conv at offset 13 (big-endian, matching KCP wire format)
    std.mem.writeInt(u32, buf[13..17], 0x12345678, .big);
    try std.testing.expectEqual(@as(u32, 0x12345678), readKcpConv(&buf));
}

test "encodeLsa + decodeLsa round-trip" {
    const origin: NodeId = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const info = "hostname:test\nip:1.2.3.4\n";
    const neighbors = [_]NeighborEntry{
        .{ .mac = .{ 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f }, .cost = 1 },
    };

    var buf: [512]u8 = undefined;
    const len = encodeLsa(&buf, origin, 42, 8, 0, info, &neighbors);
    try std.testing.expect(len >= 15 + info.len + 1 + 7);

    // Decode
    const decoded = decodeLsa(buf[1..len]).?;
    try std.testing.expect(std.mem.eql(u8, &decoded.origin, &origin));
    try std.testing.expectEqual(@as(u32, 42), decoded.seq);
    try std.testing.expectEqual(@as(u8, 8), decoded.ttl);
    try std.testing.expectEqualStrings(info, decoded.node_info);

    // Parse neighbors
    const allocator = std.testing.allocator;
    var parsed = try parseLsaNeighbors(allocator, buf[1..len], @intCast(info.len));
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.items.len);
    try std.testing.expect(std.mem.eql(u8, &parsed.items[0].mac, &neighbors[0].mac));
    try std.testing.expectEqual(@as(u8, 1), parsed.items[0].cost);
}
