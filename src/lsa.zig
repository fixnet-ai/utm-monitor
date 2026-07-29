//! LSA (Link-State Advertisement) mesh networking and /etc/hosts management.
//!
//! LSA broadcast + node table + /etc/hosts sync (self-contained)
//!
//! Binary protocol on UDP :2121 with first-byte dispatch for message type
//! identification. LSA carries topology and version info for display in --status.
//!
//! /etc/hosts marker block:
//!   # UTM-MONITOR-BEGIN
//!   192.168.64.5  macvm
//!   192.168.64.8  linuxvm
//!   # UTM-MONITOR-END

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

const net = std.Io.net;
const assert = std.debug.assert;

// ═══════════════════════════════════════════════════════════════════════════════
// NodeId — types & helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Node identifier (MAC address, 6 bytes)
pub const NodeId = [6]u8;

/// Parse a colon-separated MAC address string (aa:bb:cc:dd:ee:ff).
pub fn parseNodeId(text: []const u8) !NodeId {
    if (text.len != 17) return error.InvalidFormat;
    var id: NodeId = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const pos = i * 3;
        if (i < 5 and text[pos + 2] != ':') return error.InvalidFormat;
        id[i] = try std.fmt.parseInt(u8, text[pos .. pos + 2], 16);
    }
    return id;
}

/// Derive a NodeId for a registered MAC that may be longer than 6 bytes
/// (virtual MAC from UTM). Uses first 4 bytes of hostname hash with last
/// 2 bytes of MAC.
pub fn deriveNodeId(mac: []const u8, hostname: []const u8) !NodeId {
    if (mac.len < 6) return error.InvalidFormat;
    var id: NodeId = undefined;
    // Use a rolling hash over the hostname
    var h: u32 = 5381;
    for (hostname) |c| {
        h = ((h << 5) + h) + c;
    }
    id[0] = @truncate(h >> 24);
    id[1] = @truncate(h >> 16);
    id[2] = @truncate(h >> 8);
    id[3] = @truncate(h);
    // Last 2 bytes from MAC to reduce collision probability
    id[4] = mac[mac.len - 2];
    id[5] = mac[mac.len - 1];
    return id;
}

/// Format a NodeId to an allocator-allocated string (aa:bb:cc:dd:ee:ff).
pub fn formatNodeId(id: NodeId, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        id[0], id[1], id[2], id[3], id[4], id[5],
    });
}

/// Format a NodeId into a pre-allocated buffer (18 bytes recommended).
/// Returns the formatted slice, or "??:??:??:??:??:??" on overflow.
pub fn formatNodeIdBuf(id: NodeId, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        id[0], id[1], id[2], id[3], id[4], id[5],
    }) catch "??:??:??:??:??:??";
}



/// Generate a process-unique nonce from ASLR-entropy (stack address) and PID.
/// Changes on every process start, ensuring LSA restart detection works
/// across process restarts.
fn generateNonce() u32 {
    var dummy: u8 = undefined;
    const stack_addr: u32 = @truncate(@intFromPtr(&dummy));
    const pid: u32 = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.c.getpid());
    return pid ^ stack_addr;
}

/// Extract the Host epoch (per-process nonce) from an LSA node_info string.
/// Format: "epoch:{nonce}" or "nonce:{nonce}" on its own line. Returns null if not found or malformed.
fn parseEpoch(node_info: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, node_info, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "epoch:") or std.mem.startsWith(u8, line, "nonce:")) {
            const colon = std.mem.indexOfScalar(u8, line, ':').?;
            return std.fmt.parseInt(u32, line[colon + 1 ..], 10) catch null;
        }
    }
    return null;
}

/// Compare two node_info strings for LSA restart detection.
/// Returns true if the nonce differs (genuine process restart), false if same.
/// Falls back to full string comparison when nonce is missing (backward compat
/// with pre-nonce LSA entries).
fn nonceChanged(a: []const u8, b: []const u8) bool {
    const na = parseEpoch(a);
    const nb = parseEpoch(b);
    if (na != null and nb != null) return na.? != nb.?;
    // Fallback: at least one LSA entry has no nonce — compare full strings
    return !std.mem.eql(u8, a, b);
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

/// Encode an LSA into a buffer. Returns encoded length, or 0 if the buffer
/// is too small to hold all neighbors (neighbors are truncated silently by
/// callers; encodeLsa asserts in debug mode but returns 0 in release).
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
    const needed = 15 + node_info.len + 1 + neighbors.len * 7;
    if (buf.len < needed) {
        std.log.warn("[lsa] encodeLsa: buffer too small (need {d}, have {d})", .{ needed, buf.len });
        // Guard: if buffer can't even hold the header, encode with zero neighbors
        // to avoid infinite recursion (buf.len -| X saturating to 0 → 0 neighbors → try again).
        const min_header = 16 + node_info.len;
        if (buf.len < min_header) {
            std.log.err("[lsa] encodeLsa: buffer too small for header (need {d}, have {d})", .{ min_header, buf.len });
            return encodeLsa(buf, origin, seq, ttl, flags, node_info, &[0]NeighborEntry{});
        }
        // Try to fit as many neighbors as possible
        const max_neighbors = (buf.len -| (15 + node_info.len + 1)) / 7;
        return encodeLsa(buf, origin, seq, ttl, flags, node_info, neighbors[0..@min(neighbors.len, max_neighbors)]);
    }

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
    // Optional callback to refresh broadcast_addrs when interfaces change.
    // Called by periodicTasks every ~30s. Set by Host/Guest init code.
    // Takes allocator, returns new ArrayList (caller takes ownership).
    broadcast_refresh_fn: ?*const fn (std.mem.Allocator) anyerror!std.ArrayList(net.IpAddress) = null,

    // LSA state
    lsa_seq: u32,
    last_lsa_broadcast_ms: u32,
    periodic_tick: u32 = 0, // incremented each periodicTasks call

    // Topology
    neighbors: std.AutoHashMap(NodeId, Neighbor),
    neighbors_mutex: std.Io.Mutex,
    lsas: std.AutoHashMap(NodeId, LsaEntry),
    lsas_mutex: std.Io.Mutex,
    routes: std.ArrayList(Route),
    routes_mutex: std.Io.Mutex,

    /// Per-process nonce for LSA restart detection.
    /// Changes on every process start — remote nodes detect restart
    /// by comparing this value across LSA entries.
    nonce: u32,

    // Shutdown
    shutdown: std.atomic.Value(bool),

    // (was host_gateway_ip — removed. IP gating on version-mismatch check
    //  was unreliable on multihomed hosts where the Host's primary IP ≠
    //  guest-facing bridge/gateway IP. Version mismatch alone is sufficient:
    //  other Guests share our protocol.VERSION and won't trigger.)

    // Clock (monotonic ms, advanced in run loop)
    clock_ms: u32,

    // Broadcast address refresh counter (seconds since last refresh)
    broadcast_refresh_tick: u32 = 0,
    broadcast_refresh_next_ms: u32 = 30_000, // first refresh after ~30s

    // Last pong received (for --ping command). Set by handlePong.
    last_pong_src: NodeId = [_]u8{0} ** 6,
    last_pong_rtt: u32 = 0,
    last_pong_time: u64 = 0, // real monotonic ms from nowMs() when received
    last_pong_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Create a new Mesh instance. Takes ownership of node_info (will free on deinit).
    /// socket should be a UDP socket already bound to :2121 with broadcast enabled.
    /// broadcast_addrs should contain subnet-directed broadcast + 255.255.255.255.
    /// broadcast_refresh_fn is an optional callback for periodicTasks to refresh the
    /// broadcast address list (picks up new interfaces like bridge100 created after startup).
    pub fn init(
        allocator: std.mem.Allocator,
        node_id: NodeId,
        node_info: []const u8,
        socket: net.Socket,
        io: std.Io,
        broadcast_addrs: std.ArrayList(net.IpAddress),
        broadcast_refresh_fn: ?*const fn (std.mem.Allocator) anyerror!std.ArrayList(net.IpAddress),
    ) !Mesh {
        const nonce = generateNonce();

        // Append nonce to node_info so remote nodes can detect process restarts
        // via LSA nonce change (Finding 93). Build it here inside init() so
        // the first LSA broadcast already carries the nonce — no updateNodeInfo()
        // call window where a stale nonce-less LSA could leak out and cause a
        // double LSA restart detection on the remote side.
        // parseEpoch() accepts both "nonce:" and "epoch:" keys for backward compat.
        const node_info_with_epoch = std.fmt.allocPrint(allocator, "{s}\nnonce:{d}", .{ node_info, nonce }) catch {
            // If alloc fails, fall back to the original node_info without nonce.
            allocator.free(node_info);
            return error.OutOfMemory;
        };
        allocator.free(node_info);

        return Mesh{
            .allocator = allocator,
            .node_id = node_id,
            .node_info = node_info_with_epoch,
            .socket = socket,
            .io = io,
            .broadcast_addrs = broadcast_addrs,
            .broadcast_refresh_fn = broadcast_refresh_fn,
            .lsa_seq = 0,
            .last_lsa_broadcast_ms = 0,
            .neighbors = std.AutoHashMap(NodeId, Neighbor).init(allocator),
            .neighbors_mutex = std.Io.Mutex.init,
            .lsas = std.AutoHashMap(NodeId, LsaEntry).init(allocator),
            .lsas_mutex = std.Io.Mutex.init,
            .routes = .empty,
            .routes_mutex = std.Io.Mutex.init,
            .shutdown = std.atomic.Value(bool).init(false),
            .nonce = nonce,
            .clock_ms = 0,
        };
    }

    /// Real monotonic millisecond timestamp for ping/pong RTT measurement.
    /// Separate from clock_ms — clock_ms is a coarse event counter used by
    /// LSA expiry and periodic timers, where 10ms/1000ms granularity is
    /// acceptable.  Ping/pong RTT needs sub-ms precision, so we read the
    /// system monotonic clock directly.
    fn nowMs(self: *Mesh) u32 {
        return @truncate(@as(u64, @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds())));
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

        self.routes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Signal shutdown (thread-safe). The run() loop will exit.
    /// On Windows the caller MUST close the socket after join() to
    /// clean up — do NOT close it here. The timer thread needs the
    /// socket open to send the self-wake dummy packet that unblocks
    /// the mesh thread's blocking receive(). Closing the socket early
    /// prevents the self-wake and causes a permanent hang on ARM64
    /// where AFD close does not reliably cancel a pending receive.
    pub fn signalShutdown(self: *Mesh) void {
        self.shutdown.store(true, .release);
    }

    /// Replace the LSA node_info string dynamically (e.g. to signal
    /// status change from "serving" to "upgrading"). Next LSA broadcast
    /// will carry the new info. Takes ownership of new_info.
    /// The per-process nonce is re-appended so dynamic field changes
    /// (status:, ip:) don't trigger spurious LSA restart detection.
    pub fn updateNodeInfo(self: *Mesh, new_info: []const u8) void {
        self.allocator.free(self.node_info);
        // Append nonce so LSA restart detection can distinguish genuine
        // process restarts from dynamic field changes (Finding 124).
        const with_nonce = std.fmt.allocPrint(self.allocator, "{s}\nnonce:{d}", .{ new_info, self.nonce }) catch {
            self.node_info = new_info;
            return;
        };
        self.allocator.free(new_info);
        self.node_info = with_nonce;
    }

    /// Main UDP receive/dispatch loop. Blocks until shutdown is signaled.
    /// Should be run in its own thread.
    pub fn run(self: *Mesh) !void {
        // Broadcast initial LSA before entering receive loop.
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
                        self.periodicTasks();
                        continue;
                    },
                    else => {
                        std.log.err("[lsa] receive error: {}", .{err});
                        continue;
                    },
                }
            };

            self.clock_ms +%= 10;

            if (msg.data.len == 0) continue;

            switch (msg.data[0]) {
                protocol.MESH_TYPE_LSA => self.handleLsa(msg.data[1..], msg.from) catch |err| {
                    std.log.err("[lsa] handleLsa failed: {}", .{err});
                },
                protocol.MESH_TYPE_PING => self.handlePing(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PONG => self.handlePong(msg.data[1..]),
                else => {},
            }

            self.periodicTasks();
        }

        std.log.info("[lsa] Shutting down", .{});
    }

    /// Windows: blocking receive on mesh Io with a separate timer thread.
    /// Zig 0.16.0 Io.Threaded on Windows does NOT support receiveTimeout —
    /// net_receive with concurrency=true is an explicit TODO in the stdlib
    /// (Threaded.zig:3197-3199) and always returns ConcurrencyUnavailable.
    /// Workaround: blocking receive() + CloseHandle from service control
    /// handler to interrupt on shutdown. The timer thread uses raw Win32
    /// Sleep() to drive periodicTasks independently of the Io.
    fn runWindows(self: *Mesh) !void {
        var buf: [4096]u8 = undefined;

        // Periodic timer thread: wake every 1s to drive keepalive.
        const timer_thread = std.Thread.spawn(.{}, runWindowsTimer, .{self}) catch |err| {
            std.log.err("[lsa] Failed to spawn timer thread: {}", .{err});
            return err;
        };
        timer_thread.detach();

        while (!self.shutdown.load(.acquire)) {
            const msg = self.socket.receive(self.io, &buf) catch |err| {
                if (self.shutdown.load(.acquire)) break;
                std.log.err("[lsa] receive error: {}", .{err});
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                continue;
            };

            self.clock_ms +%= 10;

            if (msg.data.len == 0) continue;

            switch (msg.data[0]) {
                protocol.MESH_TYPE_LSA => self.handleLsa(msg.data[1..], msg.from) catch |err| {
                    std.log.err("[lsa] handleLsa failed: {}", .{err});
                },
                protocol.MESH_TYPE_PING => self.handlePing(msg.data[1..], msg.from),
                protocol.MESH_TYPE_PONG => self.handlePong(msg.data[1..]),
                else => {},
            }

            self.periodicTasks();
        }

        std.log.info("[lsa] Shutting down", .{});
    }

    /// Periodic timer for Windows blocking receive fallback.
    /// Drives LSA broadcasts and periodic maintenance every 1 second.
    /// Uses raw Windows Sleep() to avoid any Io dependency — timer must
    /// run regardless of Io.Threaded configuration.
    /// On shutdown, sends a dummy 1-byte UDP packet to the mesh socket
    /// (self-wake) to unblock the main thread's blocking receive().
    /// socket.close() from another thread does NOT reliably unblock AFD
    /// receive on ARM64, but a real incoming packet does.
    fn runWindowsTimer(self: *Mesh) void {
        const Sleep = @extern(
            *const fn (std.os.windows.DWORD) callconv(.winapi) void,
            .{ .name = "Sleep", .library_name = "kernel32" },
        );
        while (!self.shutdown.load(.acquire)) {
            Sleep(1000);
            if (self.shutdown.load(.acquire)) break;
            self.clock_ms +%= 1000;
            self.periodicTasks();
        }
        // Shutdown signaled — send a dummy packet to our own socket to
        // unblock the main thread's blocking receive(). AFD does not
        // reliably cancel pending receive on close (ARM64 kernel quirk),
        // but an actual incoming datagram always wakes it.
        const dummy: [1]u8 = .{0xFF};
        const loopback: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = protocol.DEFAULT_PORT } };
        self.socket.send(self.io, &loopback, &dummy) catch {};
    }

    /// Broadcast own LSA once before entering receive loop.
    /// Separate from broadcastOwnLsa to avoid the interval check.
    fn broadcastOwnLsaInit(self: *Mesh) void {
        self.lsa_seq +%= 1;

        self.neighbors_mutex.lock(self.io) catch return;
        defer self.neighbors_mutex.unlock(self.io);

        var neighbor_list: [32]NeighborEntry = undefined;
        var neighbor_count: usize = 0;
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            if (neighbor_count >= neighbor_list.len) break;
            neighbor_list[neighbor_count] = .{ .mac = entry.key_ptr.*, .cost = entry.value_ptr.cost };
            neighbor_count += 1;
        }

        var lsa_buf: [1280]u8 = undefined;
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
                std.log.err("[lsa] initial broadcast LSA to {any} failed: {}", .{ addr, err });
            };
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Periodic tasks
    // ──────────────────────────────────────────────────────────────────────────

    fn periodicTasks(self: *Mesh) void {
        // Broadcast own LSA every MESH_LSA_INTERVAL_MS
        if (self.clock_ms - self.last_lsa_broadcast_ms >= protocol.MESH_LSA_INTERVAL_MS) {
            self.broadcastOwnLsa();
            self.last_lsa_broadcast_ms = self.clock_ms;
        }

        // Refresh broadcast address list every ~30s to pick up new
        // interfaces (e.g. bridge100 created after Host startup by UTM).
        // Multi-NIC Hosts otherwise miss bridge subnet Guests in LSA.
        if (self.broadcast_refresh_fn) |refresh_fn| {
            if (self.clock_ms >= self.broadcast_refresh_next_ms) {
                self.broadcast_refresh_next_ms = self.clock_ms + 30_000;
                const new_addrs = refresh_fn(self.allocator) catch |err| {
                    std.log.err("[lsa] broadcast address refresh failed: {}", .{err});
                    self.broadcast_refresh_next_ms = self.clock_ms + 30_000;
                    return;
                };
                var old = self.broadcast_addrs;
                self.broadcast_addrs = new_addrs;
                old.deinit(self.allocator);
            }
        }

        // Periodic ping of all known nodes (every ~60 periodicTasks calls,
        // roughly 60s when idle) — measures RTT for both direct neighbors
        // and relayed paths.
        self.periodic_tick +%= 1;
        if (self.periodic_tick % 60 == 0) {
            // Collect known node IDs (release lsas_mutex before calling sendPing
            // to avoid holding lsas → neighbors/routes lock nesting)
            var ping_targets: [64]NodeId = undefined;
            var ping_count: usize = 0;
            {
                self.lsas_mutex.lock(self.io) catch return;
                defer self.lsas_mutex.unlock(self.io);
                var l_iter = self.lsas.iterator();
                while (l_iter.next()) |entry| {
                    const node = entry.key_ptr.*;
                    if (std.mem.eql(u8, &node, &self.node_id)) continue;
                    if (ping_count >= ping_targets.len) break;
                    ping_targets[ping_count] = node;
                    ping_count += 1;
                }
            }
            for (ping_targets[0..ping_count]) |node| {
                self.sendPing(node);
            }
        }

        // Expire stale neighbors every 5 seconds
        if (self.clock_ms % 5000 < 10) {
            self.expireStale();
        }

    }

    // ──────────────────────────────────────────────────────────────────────────
    // LSA handling
    // ──────────────────────────────────────────────────────────────────────────

    /// Broadcast our own LSA to all subnet broadcast addresses + 255.255.255.255.
    fn broadcastOwnLsa(self: *Mesh) void {
        self.lsa_seq +%= 1;

        self.neighbors_mutex.lock(self.io) catch return;
        defer self.neighbors_mutex.unlock(self.io);

        // Collect neighbor list
        var neighbor_list: [32]NeighborEntry = undefined;
        var neighbor_count: usize = 0;
        var n_iter = self.neighbors.iterator();
        while (n_iter.next()) |entry| {
            if (neighbor_count >= neighbor_list.len) break;
            neighbor_list[neighbor_count] = .{ .mac = entry.key_ptr.*, .cost = entry.value_ptr.cost };
            neighbor_count += 1;
        }

        var lsa_buf: [1280]u8 = undefined;
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
                std.log.err("[lsa] broadcast LSA to {any} failed: {}", .{ addr, err });
            };
        }
    }

    /// Process an incoming LSA (data does NOT include the type byte).
    fn handleLsa(self: *Mesh, data: []const u8, from: net.IpAddress) !void {
        const decoded = decodeLsa(data) orelse return;
        if (std.mem.eql(u8, &decoded.origin, &self.node_id)) return; // ignore our own LSA

        // TTL check
        if (decoded.ttl <= 1) return;

        // ── lsas section: lock, check + store, unlock ──
        var lsa_restart: bool = false;
        {
            self.lsas_mutex.lock(self.io) catch return;
            defer self.lsas_mutex.unlock(self.io);

            // Check if we already have a newer or same-seq LSA.
            // LSA restart detection: compare nonce (per-process identity) rather
            // than the full node_info string. Dynamic fields like status:/ip: must
            // not trigger restart detection — only a genuine process restart
            // changes the nonce (Finding 124 / Task #325).
            if (self.lsas.getPtr(decoded.origin)) |existing| {
                const diff: i32 = @bitCast(decoded.seq -% existing.seq);
                if (diff <= 0) {
                    if (nonceChanged(decoded.node_info, existing.node_info)) {
                        std.log.info("[lsa] LSA restart detected: nonce changed, accepting lower seq", .{});
                        existing.deinit(self.allocator);
                        lsa_restart = true;
                    } else {
                        return; // existing is same or newer
                    }
                } else if (nonceChanged(decoded.node_info, existing.node_info)) {
                    // Higher seq with different nonce: stale relayed LSA
                    // from an older process whose seq counter was ahead.
                    // Keep the current (lower-seq, newer-process) entry —
                    // replacing it would let the next genuine LSA trigger a
                    // spurious second restart (Finding 93 / Task #254).
                    std.log.info("[lsa] Ignoring stale high-seq LSA from {any} (nonce differs)", .{decoded.origin});
                    return;
                } else {
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
        }
        // ── lsas_mutex released here ──

        // ── neighbors section: only add as direct neighbor if received
        // directly from the origin (TTL == MESH_MAX_TTL, not relayed).
        // Relayed LSAs go into the LSA database but don't create direct
        // neighbor entries — Dijkstra will route through the relay source.
        if (decoded.ttl == protocol.MESH_MAX_TTL) {
            self.neighbors_mutex.lock(self.io) catch return;
            defer self.neighbors_mutex.unlock(self.io);

            const result = try self.neighbors.getOrPut(decoded.origin);
            result.value_ptr.* = .{
                .id = decoded.origin,
                .addr = switch (from) {
                    .ip4 => |v4| net.IpAddress{ .ip4 = .{ .bytes = v4.bytes, .port = protocol.DEFAULT_PORT } },
                    .ip6 => |v6| net.IpAddress{ .ip6 = .{ .bytes = v6.bytes, .port = protocol.DEFAULT_PORT, .flow = v6.flow, .interface = v6.interface } },
                },
                .last_seen_ms = self.clock_ms,
                .cost = 1, // direct neighbor
            };
        }
        // ── neighbors_mutex released here ──

        // Rebuild routes on topology change (no locks held)
        self.rebuildRoutes();

        // ── relay section: lock, iterate, send, unlock ──
        if (decoded.ttl > 2) {
            if (data.len > 1279) {
                std.log.warn("[lsa] LSA relay dropped: data too large ({d} bytes)", .{data.len});
                return;
            }
            var relay_buf: [1280]u8 = undefined;
            relay_buf[0] = protocol.MESH_TYPE_LSA;
            @memcpy(relay_buf[1..][0..data.len], data);
            relay_buf[1 + 6 + 4] = decoded.ttl - 1; // decrement TTL in-place
            const total_len = 1 + data.len;

            self.neighbors_mutex.lock(self.io) catch return;
            defer self.neighbors_mutex.unlock(self.io);
            var n_iter = self.neighbors.iterator();
            while (n_iter.next()) |entry| {
                if (std.mem.eql(u8, &entry.key_ptr.*, &decoded.origin)) continue;
                self.socket.send(self.io, &entry.value_ptr.addr, relay_buf[0..total_len]) catch {};
            }
        }
    }



    // ──────────────────────────────────────────────────────────────────────────
    // Ping/Pong handling (supports both direct and relayed ping)
    // ──────────────────────────────────────────────────────────────────────────
    //
    // Ping format: [src_mac:6][timestamp:4] (10 bytes, direct neighbor)
    //              [src_mac:6][dst_mac:6][ttl:1][timestamp:4] (17 bytes, relayed)
    // Pong format: [src_mac:6][timestamp:4] — always 10 bytes (direct reply to sender)

    fn handlePing(self: *Mesh, data: []const u8, from: net.IpAddress) void {
        if (data.len < 10) return;

        // Relayed ping format: src(6) + dst(6) + ttl(1) + ts(4) = 17 bytes
        if (data.len >= 17) {
            var src_mac: NodeId = undefined;
            @memcpy(&src_mac, data[0..6]);
            var dst_mac: NodeId = undefined;
            @memcpy(&dst_mac, data[6..12]);
            const ttl = data[12];

            // Is this node the target?
            if (std.mem.eql(u8, &dst_mac, &self.node_id)) {
                // Yes — respond with pong (direct reply to relay source)
                var src_buf: [18]u8 = undefined;
                std.log.info("[lsa] relayed ping reached target from {s}", .{formatNodeIdBuf(src_mac, &src_buf)});
                var pong: [11]u8 = undefined;
                pong[0] = protocol.MESH_TYPE_PONG;
                @memcpy(pong[1..7], &self.node_id);
                std.mem.writeInt(u32, pong[7..11], self.nowMs(), .big);
                self.socket.send(self.io, &from, &pong) catch {};
                return;
            }

            // Not the target — relay to next hop if TTL > 0
            if (ttl > 0) {
                if (self.routeTo(dst_mac)) |next_hop| {
                    // Rewrite the packet with decremented TTL and forward
                    var relayed: [18]u8 = undefined;
                    relayed[0] = protocol.MESH_TYPE_PING;
                    @memcpy(relayed[1..13], data[0..12]);  // src + dst
                    relayed[13] = ttl - 1;                  // decrement TTL
                    @memcpy(relayed[14..18], data[13..17]);  // timestamp

                    self.neighbors_mutex.lock(self.io) catch return;
                    defer self.neighbors_mutex.unlock(self.io);
                    if (self.neighbors.get(next_hop)) |nb| {
                        var src_buf: [18]u8 = undefined;
                        var dst_buf: [18]u8 = undefined;
                        var hop_buf: [18]u8 = undefined;
                        std.log.info("[lsa] ping relay fwd: {s} → {s} via {s} ttl={d}", .{
                            formatNodeIdBuf(src_mac, &src_buf),
                            formatNodeIdBuf(dst_mac, &dst_buf),
                            formatNodeIdBuf(next_hop, &hop_buf),
                            ttl - 1,
                        });
                        self.socket.send(self.io, &nb.addr, &relayed) catch {};
                    }
                }
            }
            return;
        }

        // Direct ping (10 bytes): always respond with pong.
        // Include responder's MAC so the sender knows who replied.
        var pong: [11]u8 = undefined;
        pong[0] = protocol.MESH_TYPE_PONG;
        @memcpy(pong[1..7], &self.node_id);                  // responder MAC
        std.mem.writeInt(u32, pong[7..11], std.mem.readInt(u32, data[6..10], .big), .big); // original timestamp
        self.socket.send(self.io, &from, &pong) catch {};
    }

    fn handlePong(self: *Mesh, data: []const u8) void {
        if (data.len < 10) return;
        var src_mac: NodeId = undefined;
        @memcpy(&src_mac, data[0..6]);
        const send_ts = std.mem.readInt(u32, data[6..10], .big);
        const rtt = self.nowMs() -% send_ts;
        var mac_buf: [18]u8 = undefined;
        std.log.info("[lsa] pong from {s} rtt={d}ms", .{ formatNodeIdBuf(src_mac, &mac_buf), rtt });

        // Store for --ping command (lock-free read: worst case is stale data)
        self.last_pong_mutex.lock(self.io) catch return;
        defer self.last_pong_mutex.unlock(self.io);
        self.last_pong_src = src_mac;
        self.last_pong_rtt = rtt;
        self.last_pong_time = self.nowMs();
    }

    /// Send a ping and wait for the pong from the specific target.
    /// Returns RTT in milliseconds, or null on timeout (10s real time).
    pub fn pingAndWait(self: *Mesh, dest_id: NodeId) ?u32 {
        // Record current pong state so we can detect a new one
        self.last_pong_mutex.lock(self.io) catch return null;
        const prev_time = self.last_pong_time;
        self.last_pong_mutex.unlock(self.io);

        // Send the ping
        self.sendPing(dest_id);

        // Wait for a fresh pong from the target (up to 10 seconds, real time).
        // We poll in 50ms increments — 200 iterations = 10 seconds.
        var iterations: u32 = 0;
        while (iterations < 200) : (iterations += 1) {
            self.last_pong_mutex.lock(self.io) catch return null;
            const fresh = self.last_pong_time != prev_time;
            const matches = std.mem.eql(u8, &self.last_pong_src, &dest_id);
            const rtt = self.last_pong_rtt;
            self.last_pong_mutex.unlock(self.io);

            if (fresh and matches) return rtt;

            // Yield before polling again (50ms sleep)
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(50), .awake) catch return null;
        }
        return null; // timeout after ~10 seconds
    }

    /// Send a ping to any node (direct neighbor or via relay).
    /// Uses the routing table to decide direct vs relayed format.
    pub fn sendPing(self: *Mesh, dest_id: NodeId) void {
        const next_hop = self.routeTo(dest_id) orelse {
            var mac_buf: [18]u8 = undefined;
            std.log.info("[lsa] ping: no route to {s}", .{formatNodeIdBuf(dest_id, &mac_buf)});
            return;
        };

        // Direct ping if next hop IS the destination itself
        if (std.mem.eql(u8, &next_hop, &dest_id)) {
            self.neighbors_mutex.lock(self.io) catch return;
            defer self.neighbors_mutex.unlock(self.io);
            if (self.neighbors.get(dest_id)) |neighbor| {
                var ping: [11]u8 = undefined;
                ping[0] = protocol.MESH_TYPE_PING;
                @memcpy(ping[1..7], &self.node_id);
                std.mem.writeInt(u32, ping[7..11], self.nowMs(), .big);
                self.socket.send(self.io, &neighbor.addr, &ping) catch {};
                var dst_buf: [18]u8 = undefined;
                std.log.info("[lsa] ping direct: → {s} addr={any}", .{ formatNodeIdBuf(dest_id, &dst_buf), neighbor.addr });
            }
            return;
        }

        // Relayed ping — send via next_hop with dst_mac + ttl
        self.neighbors_mutex.lock(self.io) catch return;
        defer self.neighbors_mutex.unlock(self.io);
        if (self.neighbors.get(next_hop)) |nb| {
            var ping: [18]u8 = undefined;
            ping[0] = protocol.MESH_TYPE_PING;
            @memcpy(ping[1..7], &self.node_id);     // src_mac
            @memcpy(ping[7..13], &dest_id);          // dst_mac
            ping[13] = protocol.MESH_MAX_TTL;        // ttl
            std.mem.writeInt(u32, ping[14..18], self.nowMs(), .big); // timestamp
            self.socket.send(self.io, &nb.addr, &ping) catch {};
            var src_buf: [18]u8 = undefined;
            var dst_buf: [18]u8 = undefined;
            var hop_buf: [18]u8 = undefined;
            std.log.info("[lsa] ping relay: {s} → {s} via {s}", .{
                formatNodeIdBuf(self.node_id, &src_buf),
                formatNodeIdBuf(dest_id, &dst_buf),
                formatNodeIdBuf(next_hop, &hop_buf),
            });
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Routing (Dijkstra)
    // ──────────────────────────────────────────────────────────────────────────

    /// Find the next hop toward a destination. Returns null if unreachable.
    pub fn routeTo(self: *Mesh, dest: NodeId) ?NodeId {
        self.routes_mutex.lock(self.io) catch return null;
        defer self.routes_mutex.unlock(self.io);
        for (self.routes.items) |r| {
            if (std.mem.eql(u8, &r.dest, &dest)) return r.next_hop;
        }
        return null;
    }

    /// Rebuild routing table using Dijkstra's algorithm.
    /// Builds new routes in a temporary list and only replaces the live table
    /// on success — avoids losing existing routes on allocation failure.
    /// Caller must NOT hold any topology locks (to avoid self-deadlock).
    fn rebuildRoutes(self: *Mesh) void {
        self.neighbors_mutex.lock(self.io) catch return;
        defer self.neighbors_mutex.unlock(self.io);
        self.lsas_mutex.lock(self.io) catch return;
        defer self.lsas_mutex.unlock(self.io);
        self.routes_mutex.lock(self.io) catch return;
        defer self.routes_mutex.unlock(self.io);

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
    // Maintenance
    // ──────────────────────────────────────────────────────────────────────────

    /// Expire stale neighbors and LSAs.
    fn expireStale(self: *Mesh) void {
        const timeout_ms: u32 = 15000; // 15s = 3× LSA interval + margin

        // Expire stale neighbors
        {
            self.neighbors_mutex.lock(self.io) catch return;
            defer self.neighbors_mutex.unlock(self.io);

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
            self.lsas_mutex.lock(self.io) catch return;
            defer self.lsas_mutex.unlock(self.io);

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

        // Rebuild routes if we removed anything (no locks held to avoid self-deadlock)
        {
            self.neighbors_mutex.lock(self.io) catch return;
            const has_neighbors = self.neighbors.count() > 0;
            self.neighbors_mutex.unlock(self.io);
            if (has_neighbors) {
                self.rebuildRoutes();
            }
        }
    }

    /// List known nodes (for --status display).
    pub fn listNodes(self: *Mesh, allocator: std.mem.Allocator) !std.ArrayList(NodeInfo) {
        self.neighbors_mutex.lock(self.io) catch return error.LockFailed;
        defer self.neighbors_mutex.unlock(self.io);
        self.lsas_mutex.lock(self.io) catch return error.LockFailed;
        defer self.lsas_mutex.unlock(self.io);
        self.routes_mutex.lock(self.io) catch return error.LockFailed;
        defer self.routes_mutex.unlock(self.io);

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
// /etc/hosts marker block management
// ═══════════════════════════════════════════════════════════════════════════════
//
// Maintain a block wrapped by marker comments in the hosts file:
//   # UTM-MONITOR-BEGIN
//   192.168.64.5  macvm
//   192.168.64.8  linuxvm
//   # UTM-MONITOR-END
//
// Update logic: read file → replace marker block → write back (write to temp file then rename)

/// A single hosts entry
pub const HostEntry = struct {
    ip: []const u8,
    name: []const u8,
};

/// Update the marker block in the hosts file.
/// Uses range-based replacement: finds marker boundaries in the original content
/// and only replaces the block itself — everything outside is preserved byte-for-byte.
/// This avoids the empty-line accumulation bug (Finding 169) caused by the old
/// splitScalar + rebuild method, which added a spurious trailing newline on every
/// write when the file ends with \n (as all well-formed text files do).
///
/// If the marker block does not exist, appends it to the end of the file.
/// Uses temp file + atomic rename for safety.
pub fn updateHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const HostEntry,
) !void {
    // Read existing file content
    const original = readFile(io, allocator, file_path) catch |err| switch (err) {
        error.FileNotFound => {
            return writeNewHosts(io, allocator, file_path, entries);
        },
        else => return err,
    };
    defer allocator.free(original);

    const begin_line = protocol.HOSTS_MARKER_BEGIN;
    const end_line = protocol.HOSTS_MARKER_END;

    // Build new content via range replacement
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);
    try new_content.ensureTotalCapacity(allocator, original.len + 512);

    // Find marker block boundaries in the original content.
    // We look for lines that match the begin/end markers (after trimming whitespace).
    const begin_pos = findMarkerLine(original, begin_line);
    const end_pos = if (begin_pos != null)
        findMarkerLine(original[begin_pos.? + begin_line.len ..], end_line)
    else
        null;

    if (begin_pos != null and end_pos != null) {
        const block_start = begin_pos.?;
        const block_end = block_start + begin_line.len + end_pos.? + end_line.len;

        // Find end of the END-marker line (skip past trailing \r\n)
        var actual_end = block_end;
        while (actual_end < original.len and (original[actual_end] == '\r' or original[actual_end] == '\n')) {
            actual_end += 1;
        }

        // Copy content before the marker block
        try new_content.appendSlice(allocator, original[0..block_start]);

        // Write new block
        try new_content.appendSlice(allocator, begin_line);
        try new_content.append(allocator, '\n');
        for (entries) |entry| {
            try new_content.print(allocator, "{s}  {s}\n", .{ entry.ip, entry.name });
        }
        try new_content.appendSlice(allocator, end_line);
        try new_content.append(allocator, '\n');

        // Copy content after the marker block
        if (actual_end < original.len) {
            try new_content.appendSlice(allocator, original[actual_end..]);
        }
    } else {
        // No marker block exists — copy original and append new block
        try new_content.appendSlice(allocator, original);

        // Ensure trailing newline before appending block
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.appendSlice(allocator, begin_line);
        try new_content.append(allocator, '\n');
        for (entries) |entry| {
            try new_content.print(allocator, "{s}  {s}\n", .{ entry.ip, entry.name });
        }
        try new_content.appendSlice(allocator, end_line);
        try new_content.append(allocator, '\n');
    }

    // Write to temp file
    const tmp_path = try std.mem.concat(allocator, u8, &.{ file_path, ".tmp" });
    defer allocator.free(tmp_path);

    try writeFile(io, tmp_path, new_content.items);

    // Atomic rename using the file's parent directory (not cwd, which may change).
    // For absolute paths like /etc/hosts, this opens /etc as the dir handle.
    const parent_dir_path = std.fs.path.dirname(file_path) orelse "/";
    const parent_dir = try std.Io.Dir.cwd().openDir(io, parent_dir_path, .{});
    defer parent_dir.close(io);
    const file_basename = std.fs.path.basename(file_path);
    try parent_dir.rename(tmp_path, parent_dir, file_basename, io);
}

/// Read entire file content
fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size = try file.length(io);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

/// Write entire file content
fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

/// Create a new hosts file (with marker block)
fn writeNewHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const HostEntry,
) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.print("{s}\n", .{protocol.HOSTS_MARKER_BEGIN});
    for (entries) |entry| {
        try writer.interface.print("{s}  {s}\n", .{ entry.ip, entry.name });
    }
    try writer.interface.print("{s}\n", .{protocol.HOSTS_MARKER_END});
    try writer.interface.flush();
}

/// Find the byte offset of a marker line within content.
/// The marker must appear at the start of a line (after optional leading whitespace).
/// Returns the byte position of the FIRST character of the marker, or null if not found.
fn findMarkerLine(content: []const u8, marker: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < content.len) {
        // Skip leading whitespace on this line
        var line_start = pos;
        while (line_start < content.len and (content[line_start] == ' ' or content[line_start] == '\t' or content[line_start] == '\r')) {
            line_start += 1;
        }
        // Check if this line starts with the marker
        if (line_start + marker.len <= content.len and std.mem.eql(u8, content[line_start..][0..marker.len], marker)) {
            // Verify it's at the start of a line or preceded by \n
            if (pos == 0 or content[pos - 1] == '\n') {
                return line_start;
            }
        }
        // Advance to next line
        while (pos < content.len and content[pos] != '\n') : (pos += 1) {}
        if (pos < content.len) pos += 1; // skip the \n
    }
    return null;
}


// ═══════════════════════════════════════════════════════════════════════════════
// Tests — mesh routing
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

test "parseEpoch" {
    try std.testing.expectEqual(@as(?u32, 42), parseEpoch("hostname:test\nip:1.2.3.4\nepoch:42\nstatus:serving"));
    try std.testing.expectEqual(@as(?u32, null), parseEpoch("hostname:test\nip:1.2.3.4\n"));
    try std.testing.expectEqual(@as(?u32, null), parseEpoch(""));
    try std.testing.expectEqual(@as(?u32, 0), parseEpoch("epoch:0"));
    try std.testing.expectEqual(@as(?u32, null), parseEpoch("epoch:notanumber"));
    try std.testing.expectEqual(@as(?u32, 1234567890), parseEpoch("epoch:1234567890\nother:data"));
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

test "nonceChanged" {
    const a = "hostname:test\nnonce:42";
    const b = "hostname:test\nnonce:99";
    const c = "hostname:test\nnonce:42";
    const d = "hostname:test\n"; // no nonce
    const e = ""; // no nonce

    // Same nonce → false
    try std.testing.expect(!nonceChanged(a, c));
    // Different nonce → true
    try std.testing.expect(nonceChanged(a, b));
    // Same string (no nonce) → false
    try std.testing.expect(!nonceChanged(a, a));
    // Different strings, both no nonce → fallback to full comparison
    try std.testing.expect(nonceChanged(d, e));
    // One with nonce, one without → fallback to full comparison (different strings)
    try std.testing.expect(nonceChanged(a, d));
    // One with nonce, one without but same non-nonce content → fallback (different strings)
    try std.testing.expect(nonceChanged(a, "hostname:test\n"));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests — /etc/hosts sync
// ═══════════════════════════════════════════════════════════════════════════════

test "HostEntry struct basics" {
    const e = HostEntry{ .ip = "10.0.0.1", .name = "testvm" };
    try std.testing.expectEqualStrings("10.0.0.1", e.ip);
    try std.testing.expectEqualStrings("testvm", e.name);
}

test "HostEntry with FQDN" {
    const e = HostEntry{ .ip = "192.168.1.100", .name = "linuxvm.aarch64-linux-musl.utm" };
    try std.testing.expectEqualStrings("192.168.1.100", e.ip);
    try std.testing.expectEqualStrings("linuxvm.aarch64-linux-musl.utm", e.name);
}

test "HostEntry with IPv6 address" {
    const e = HostEntry{ .ip = "fe80::1", .name = "ipv6host" };
    try std.testing.expectEqualStrings("fe80::1", e.ip);
    try std.testing.expectEqualStrings("ipv6host", e.name);
}

test "HostEntry with empty name" {
    const e = HostEntry{ .ip = "1.2.3.4", .name = "" };
    try std.testing.expectEqualStrings("1.2.3.4", e.ip);
    try std.testing.expectEqualStrings("", e.name);
}

test "multiple entries with different IPs" {
    const entries = [_]HostEntry{
        .{ .ip = "10.0.0.1", .name = "vm1" },
        .{ .ip = "10.0.0.2", .name = "vm2" },
        .{ .ip = "10.0.0.3", .name = "vm3" },
    };
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("10.0.0.1", entries[0].ip);
    try std.testing.expectEqualStrings("vm2", entries[1].name);
    try std.testing.expectEqualStrings("10.0.0.3", entries[2].ip);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests — hosts file range replacement (Finding 169 fix)
// ═══════════════════════════════════════════════════════════════════════════════

test "findMarkerLine - basic" {
    const content = "127.0.0.1 localhost\n# UTM-MONITOR-BEGIN\n1.2.3.4 vm\n# UTM-MONITOR-END\n";
    const pos = findMarkerLine(content, "# UTM-MONITOR-BEGIN").?;
    // "127.0.0.1 localhost\n" = 20 bytes, so '#' is at offset 20
    try std.testing.expectEqual(@as(usize, 20), pos);
}

test "findMarkerLine - not found" {
    const content = "127.0.0.1 localhost\nno markers here\n";
    try std.testing.expectEqual(@as(?usize, null), findMarkerLine(content, "# UTM-MONITOR-BEGIN"));
}

test "findMarkerLine - with leading whitespace" {
    const content = "127.0.0.1 localhost\n  # UTM-MONITOR-BEGIN\n1.2.3.4 vm\n# UTM-MONITOR-END\n";
    const pos = findMarkerLine(content, "# UTM-MONITOR-BEGIN");
    try std.testing.expect(pos != null);
}

test "findMarkerLine - end marker" {
    const content = "127.0.0.1 localhost\n# UTM-MONITOR-BEGIN\n1.2.3.4 vm\n# UTM-MONITOR-END\n";
    const begin = findMarkerLine(content, "# UTM-MONITOR-BEGIN").?;
    const after = content[begin + "# UTM-MONITOR-BEGIN".len ..];
    const end = findMarkerLine(after, "# UTM-MONITOR-END").?;
    // end offset is the position within `after`
    try std.testing.expect(end < after.len);
}

test "updateHosts range replacement - no empty line accumulation" {
    // Simulate the range replacement logic: write a file with marker block,
    // then "update" it twice and verify no trailing empty lines accumulate.

    const allocator = std.testing.allocator;
    const begin_line = "# UTM-MONITOR-BEGIN";
    const end_line = "# UTM-MONITOR-END";

    // Build a file that ends with newline (normal well-formed text file)
    const original = "127.0.0.1 localhost\n\n# UTM-MONITOR-BEGIN\n192.168.64.5 macvm\n# UTM-MONITOR-END\n";
    const entries = [_]HostEntry{
        .{ .ip = "10.0.0.1", .name = "vm1" },
        .{ .ip = "10.0.0.2", .name = "vm2" },
    };

    // Run the range-replacement logic 3 times, simulating repeated updateHosts calls
    var content = try allocator.dupe(u8, original);

    for (0..3) |_| {
        const begin_pos = findMarkerLine(content, begin_line);
        const end_pos = if (begin_pos != null)
            findMarkerLine(content[begin_pos.? + begin_line.len ..], end_line)
        else
            null;

        var new_content: std.ArrayList(u8) = .empty;
        try new_content.ensureTotalCapacity(allocator, content.len + 128);

        if (begin_pos != null and end_pos != null) {
            const block_start = begin_pos.?;
            const block_end = block_start + begin_line.len + end_pos.? + end_line.len;
            var actual_end = block_end;
            while (actual_end < content.len and (content[actual_end] == '\r' or content[actual_end] == '\n')) {
                actual_end += 1;
            }
            try new_content.appendSlice(allocator, content[0..block_start]);
            try new_content.appendSlice(allocator, begin_line);
            try new_content.append(allocator, '\n');
            for (entries) |entry| {
                try new_content.print(allocator, "{s}  {s}\n", .{ entry.ip, entry.name });
            }
            try new_content.appendSlice(allocator, end_line);
            try new_content.append(allocator, '\n');
            if (actual_end < content.len) {
                try new_content.appendSlice(allocator, content[actual_end..]);
            }
        }

        // Replace old content with new
        const new_slice = try new_content.toOwnedSlice(allocator);
        allocator.free(content);
        content = new_slice;
    }

    // After 3 iterations, verify:
    // 1. No duplicate empty lines
    // 2. The file doesn't grow unboundedly
    // 3. Content before the block is preserved
    try std.testing.expect(std.mem.startsWith(u8, content, "127.0.0.1 localhost\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "# UTM-MONITOR-BEGIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "10.0.0.1  vm1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "10.0.0.2  vm2") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# UTM-MONITOR-END") != null);

    // The content should end with the END marker + newline — no extra trailing empty lines
    try std.testing.expect(std.mem.endsWith(u8, content, "# UTM-MONITOR-END\n"));

    // Verify no trailing empty lines after the end marker (no \n\n at end)
    try std.testing.expect(!std.mem.endsWith(u8, content, "\n\n"));

    allocator.free(content);
}
