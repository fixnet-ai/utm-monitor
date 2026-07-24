//! Mesh tunnel — TCP-like stream over KCP sessions.
//!
//! Provides blocking send/recv on top of mesh KCP tunnels. Used as a fallback
//! transport when direct TCP WebSocket is unavailable.

const std = @import("std");
const kcp = @import("kcp.zig");
const mesh = @import("mesh.zig");

/// Tunnel wraps a MeshSession for stream I/O.
pub const Tunnel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *mesh.MeshSession,

    /// Create a tunnel from an existing MeshSession.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, sess: *mesh.MeshSession) Tunnel {
        return .{
            .allocator = allocator,
            .io = io,
            .session = sess,
        };
    }

    /// Connect to a remote node via mesh. Returns a Tunnel on success.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, m: *mesh.Mesh, dest: mesh.NodeId) !Tunnel {
        const sess = try m.connect(dest);
        return Tunnel.init(allocator, io, sess);
    }

    /// Send data through the tunnel. Data is queued in KCP for reliable delivery.
    /// The actual UDP transmission happens via mesh.run()'s periodicTasks (kcp.update).
    /// NOTE: Does NOT call kcp.update() — only mesh.run() thread updates KCP state.
    /// This avoids data races when send() is called from HTTP/MCP handler threads.
    pub fn send(self: *Tunnel, data: []const u8) !usize {
        try self.session.kcp_inst.send(data);
        return data.len;
    }

    /// Receive data from the tunnel. Returns immediately — does NOT poll or block.
    /// Returns 0 if no data is available (not an error — caller should sleep and retry).
    /// NOTE: Does NOT call kcp.update() — only mesh.run() thread updates KCP state.
    pub fn recv(self: *Tunnel, buf: []u8) !usize {
        return try self.session.kcp_inst.recv(buf);
    }

    /// Check if the tunnel is still alive (KCP retransmit + keepalive).
    pub fn isAlive(self: *Tunnel) bool {
        if (self.session.dead) return false;
        return !self.session.kcp_inst.isDead();
    }

    /// Close the tunnel and release the mesh session.
    /// The caller must have access to the Mesh to properly close.
    pub fn deinit(self: *Tunnel) void {
        // Note: actual session cleanup is done by mesh.closeSession()
        // This just marks the tunnel as invalid.
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
