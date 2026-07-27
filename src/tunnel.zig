//! Mesh tunnel — TCP-like stream over KCP sessions.
//!
//! Provides blocking send/recv on top of mesh KCP tunnels.
//! This is the primary (and only) Guest-Host transport layer.

const std = @import("std");
const kcp = @import("kcp.zig");
const mesh = @import("mesh.zig");

/// Single-byte 0xFF keepalive probe sent by mesh.periodicTasks through KCP data
/// channel. Filtered at the tunnel layer so applications never see it.
const KEEPALIVE_PROBE: u8 = 0xFF;

/// Tunnel wraps a MeshSession for stream I/O.
pub const Tunnel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *mesh.MeshSession,
    /// Debug-mode sentinel to detect use-after-deinit.
    /// In ReleaseFast/ReleaseSmall the check is elided by the compiler.
    _alive: bool = true,

    /// Create a tunnel from an existing MeshSession.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, sess: *mesh.MeshSession) Tunnel {
        return .{
            .allocator = allocator,
            .io = io,
            .session = sess,
            ._alive = true,
        };
    }

    /// Assert the tunnel is still alive (debug-only, compile-time elided in ReleaseFast/ReleaseSmall).
    inline fn assertAlive(self: *const Tunnel) void {
        if (!self._alive) {
            @branchHint(.cold);
            std.debug.panic("use-after-deinit: Tunnel.deinit() was already called", .{});
        }
    }

    /// Connect to a remote node via mesh. Returns a Tunnel on success.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, m: *mesh.Mesh, dest: mesh.NodeId) !Tunnel {
        const sess = try m.connect(dest);
        return Tunnel.init(allocator, io, sess);
    }

    /// Send data through the tunnel. Data is queued in KCP for reliable delivery.
    /// The actual UDP transmission happens via mesh.run()'s periodicTasks (kcp.update).
    /// NOTE: Does NOT call kcp.update() — only mesh.run() thread updates KCP state.
    /// Locks sessions_mutex to synchronize with mesh thread's kcp.flush().
    /// For batch sends, prefer lock() + sendLocked() + unlock() to avoid
    /// mutex starvation of the mesh thread's ACK processing loop.
    pub fn send(self: *Tunnel, data: []const u8) !usize {
        self.assertAlive();
        try self.session.mesh.sessions_mutex.lock(self.io);
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        try self.session.kcp_inst.send(data);
        return data.len;
    }

    /// Send data and immediately flush KCP to trigger UDP transmission.
    /// Combines send + kcp.update in a single lock cycle.
    /// Use this when the mesh thread's periodicTasks might not run promptly
    /// (e.g., on Windows where the mesh loop uses blocking receive without
    /// timeout). Prefer send() for batch operations where multiple chunks
    /// should be flushed once; use sendAndFlush() for latency-sensitive
    /// single messages like pty output frames.
    ///
    /// Sets kcp_inst.current and calls flush() directly rather than going
    /// through update(), bypassing the interval rate limiter (ts_flush check).
    /// update() won't flush if called within the same interval since the last
    /// mesh thread periodicTasks, which would defeat this optimization.
    pub fn sendAndFlush(self: *Tunnel, data: []const u8, current_ms: u32) !usize {
        self.assertAlive();
        try self.session.mesh.sessions_mutex.lock(self.io);
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        try self.session.kcp_inst.send(data);
        self.session.kcp_inst.current = current_ms;
        self.session.kcp_inst.flush();
        return data.len;
    }

    /// Acquire sessions_mutex. Use with sendLocked()/flushLocked() for batch
    /// operations to prevent mesh thread starvation between per-chunk sends.
    /// Always pair with unlock() — prefer defer.
    /// Returns LockFailed if the Io context is canceled.
    pub fn lock(self: *Tunnel) !void {
        self.assertAlive();
        try self.session.mesh.sessions_mutex.lock(self.io);
    }

    /// Release sessions_mutex acquired by lock().
    pub fn unlock(self: *Tunnel) void {
        self.session.mesh.sessions_mutex.unlock(self.io);
    }

    /// Send data assuming sessions_mutex is already held (via lock()).
    /// Does NOT lock/unlock — caller is responsible for synchronization.
    pub fn sendLocked(self: *Tunnel, data: []const u8) !usize {
        self.assertAlive();
        try self.session.kcp_inst.send(data);
        return data.len;
    }

    /// Receive data from the tunnel. Returns immediately — does NOT poll or block.
    /// Returns 0 if no data is available (not an error — caller should sleep and retry).
    /// Filters out 0xFF keepalive probes — they are consumed silently and the next
    /// available real message is returned.
    /// NOTE: Does NOT call kcp.update() — only mesh.run() thread updates KCP state.
    /// Locks sessions_mutex to synchronize with mesh thread's kcp.input().
    pub fn recv(self: *Tunnel, buf: []u8) !usize {
        self.assertAlive();
        try self.session.mesh.sessions_mutex.lock(self.io);
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        while (true) {
            const n = try self.session.kcp_inst.recv(buf);
            // Filter out 0xFF keepalive probes — they are mesh-level control
            // messages that should not reach the application layer.
            if (n == 1 and buf[0] == KEEPALIVE_PROBE) continue;
            return n;
        }
    }

    /// Check if the tunnel is still alive (KCP retransmit + keepalive).
    /// Locks sessions_mutex to synchronize with mesh thread.
    /// On mutex lock failure, assumes alive — a transient lock failure
    /// does not mean the tunnel is dead, and returning false here
    /// causes the handleMeshGuest thread to exit prematurely.
    pub fn isAlive(self: *Tunnel) bool {
        self.session.mesh.sessions_mutex.lock(self.io) catch return true;
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        if (self.session.dead) return false;
        return !self.session.kcp_inst.isDead();
    }

    /// Returns the size of the next complete message in the receive queue,
    /// or -1 if no complete message is available. In message mode (non-stream),
    /// this is the exact size needed for the next recv() call. Callers can
    /// use this to allocate the correct buffer size before calling recv().
    /// Filters out 0xFF keepalive probes — consumes them silently and returns
    /// the size of the next real message. This is critical because callers
    /// size their receive buffer from peekSize; a 1-byte keepalive would
    /// cause a BufferTooSmall error on the subsequent recv() when the real
    /// tunproto message is larger.
    /// Locks sessions_mutex to synchronize with mesh thread.
    pub fn peekSize(self: *Tunnel) i32 {
        self.assertAlive();
        self.session.mesh.sessions_mutex.lock(self.io) catch return -1;
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        while (true) {
            const ps = self.session.kcp_inst.peekSize();
            // 1-byte messages are always 0xFF keepalive probes — consume
            // them silently so callers see the next real tunproto message.
            if (ps == 1) {
                var dummy: [1]u8 = undefined;
                const n = self.session.kcp_inst.recv(&dummy) catch return ps;
                if (n == 1 and dummy[0] == KEEPALIVE_PROBE) continue;
            }
            return ps;
        }
    }

    /// Force immediate KCP flush. Normally the mesh thread's periodic update
    /// drives KCP flushing, but during large file transfers we want to push
    /// data through without waiting for the next cycle (which can be 1 second).
    /// current_ms should come from the mesh's clock for consistency.
    /// Locks sessions_mutex to synchronize with mesh thread.
    pub fn flush(self: *Tunnel, current_ms: u32) void {
        self.assertAlive();
        self.session.mesh.sessions_mutex.lock(self.io) catch return;
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        self.session.kcp_inst.update(current_ms);
    }

    /// Flush assuming sessions_mutex is already held (via lock()).
    pub fn flushLocked(self: *Tunnel, current_ms: u32) void {
        self.assertAlive();
        self.session.kcp_inst.update(current_ms);
    }

    /// Enable fast transfer mode for the upgrade tunnel.
    /// - setNoDelay(nc=true): nocwnd disables congestion window limit.
    ///   Does NOT enable stream mode — message mode with single-segment
    ///   chunks (≤MSS) avoids fragmentation; peekSize returns immediately
    ///   and recv returns exactly one message per call.
    /// Locks sessions_mutex to synchronize with mesh thread.
    pub fn enableFastMode(self: *Tunnel) void {
        self.assertAlive();
        self.session.mesh.sessions_mutex.lock(self.io) catch return;
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        self.session.kcp_inst.setNoDelay(false, 10, 0, true);
    }

    /// Number of KCP segments waiting to be sent (snd_queue) + in flight (snd_buf).
    /// Returns 0 when all data has been acknowledged by the peer.
    pub fn waiting(self: *Tunnel) usize {
        self.assertAlive();
        self.session.mesh.sessions_mutex.lock(self.io) catch return 0;
        defer self.session.mesh.sessions_mutex.unlock(self.io);
        return self.session.kcp_inst.waiting();
    }

    /// Deinit the tunnel and release the mesh session.
    /// Calls mesh.closeSession() to remove the session from the sessions
    /// hashmap and free KCP resources. Must NOT be called while holding
    /// sessions_mutex (closeSession acquires it internally).
    pub fn deinit(self: *Tunnel) void {
        self._alive = false;
        self.session.mesh.closeSession(self.session);
        self.* = undefined;
    }

};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "tunnel init and isAlive" {
    const allocator = std.testing.allocator;

    // Create two KCP instances to simulate a mesh session
    var a = try kcp.Kcp.create(allocator, 10, null);
    defer a.release();
    var b = try kcp.Kcp.create(allocator, 10, null);
    defer b.release();

    // Cross-wire them
    const A2B = struct {
        var target: *kcp.Kcp = undefined;
        fn output(_: u32, data: []const u8, _: ?*anyopaque) void {
            target.input(data) catch {};
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    const B2A = struct {
        var target: *kcp.Kcp = undefined;
        fn output(_: u32, data: []const u8, _: ?*anyopaque) void {
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    // Send data from a → b
    try a.send("tunnel test");
    a.update(100);

    var rbuf: [64]u8 = undefined;
    const n = try b.recv(&rbuf);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualStrings("tunnel test", rbuf[0..n]);
}

test "tunnel send/recv large data" {
    const allocator = std.testing.allocator;

    var a = try kcp.Kcp.create(allocator, 11, null);
    defer a.release();
    a.setMtu(256);
    var b = try kcp.Kcp.create(allocator, 11, null);
    defer b.release();
    b.setMtu(256);

    const A2B = struct {
        var target: *kcp.Kcp = undefined;
        fn output(_: u32, data: []const u8, _: ?*anyopaque) void {
            target.input(data) catch {};
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    const B2A = struct {
        var target: *kcp.Kcp = undefined;
        fn output(_: u32, data: []const u8, _: ?*anyopaque) void {
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    const msg = "x" ** 500;
    try a.send(msg);

    var now: u32 = 0;
    for (0..100) |_| {
        now += 50;
        a.update(now);
        b.update(now);
    }

    var rbuf: [1024]u8 = undefined;
    const n = try b.recv(&rbuf);
    try std.testing.expectEqual(msg.len, n);
    try std.testing.expectEqualStrings(msg, rbuf[0..n]);
}
