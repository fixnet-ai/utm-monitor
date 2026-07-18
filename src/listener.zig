//! UDP listen module (Host side)
//! Listen for Guest broadcasts, detect IP changes, trigger hosts update and notification

const std = @import("std");
const protocol = @import("protocol.zig");

/// Known Guest state
pub const GuestState = struct {
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    http_port: u16,
    version: []const u8,
    last_seen: i96,

    /// Build /etc/hosts FQDN: <hostname>.<target>.utm
    pub fn fqdn(self: GuestState, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}.{s}.utm", .{ self.hostname, self.target });
    }
};

/// IP change callback (with context pointer)
pub const OnIpChanged = struct {
    context: ?*anyopaque,
    callFn: *const fn (?*anyopaque, ?GuestState, GuestState) void,

    pub fn call(self: OnIpChanged, old: ?GuestState, new: GuestState) void {
        self.callFn(self.context, old, new);
    }
};

/// Start UDP listen loop.
/// Retries bind on transient port conflicts up to 30 seconds.
pub fn listenLoop(io: std.Io, allocator: std.mem.Allocator, port: u16, on_ip_changed: OnIpChanged) !void {
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);

    // Retry bind with backoff — port may be in TIME_WAIT from a previous instance.
    // Without this, launchd fast-restart cycles cause the host process to crash-loop.
    var socket: std.Io.net.Socket = undefined;
    var bind_ok = false;
    for (0..30) |attempt| {
        socket = listen_addr.bind(io, .{ .mode = .dgram }) catch |err| {
            std.debug.print("[listener] bind port {d} failed (attempt {d}/30): {}\n", .{ port, attempt + 1, err });
            std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real) catch {};
            continue;
        };
        bind_ok = true;
        break;
    }
    if (!bind_ok) {
        std.debug.print("[listener] FATAL: could not bind port {d} after 30 attempts\n", .{port});
        return error.PortUnavailable;
    }
    defer socket.close(io);

    var guests = std.StringHashMap(GuestState).init(allocator);
    defer {
        var it = guests.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.hostname);
            allocator.free(entry.value_ptr.ip);
            allocator.free(entry.value_ptr.target);
            allocator.free(entry.value_ptr.mac);
            allocator.free(entry.value_ptr.version);
        }
        guests.deinit();
    }

    var recv_buf: [2048]u8 = undefined;
    std.debug.print("[listener] Listening on port {d}\n", .{port});

    while (true) {
        const msg_result = try socket.receive(io, &recv_buf);
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") == null) continue;

        const info = protocol.GuestInfo.parse(allocator, msg) catch |err| {
            std.debug.print("[listener] Failed to parse message: {}\n", .{err});
            continue;
        };
        defer allocator.free(info.hostname);
        defer allocator.free(info.version);
        defer allocator.free(info.target);
        defer allocator.free(info.mac);

        // Extract source IP from the UDP packet (more reliable than guest self-reported IP)
        const src_ip = switch (msg_result.from) {
            .ip4 => |a| try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
            .ip6 => |a| try std.fmt.allocPrint(allocator, "{any}", .{a}),
        };
        errdefer allocator.free(src_ip);

        // Prefer the packet's source IP if the guest self-reported IP is unreliable
        const use_src = std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.");
        const actual_ip: []const u8 = if (use_src) src_ip else blk: {
            allocator.free(src_ip);
            break :blk info.ip;
        };
        defer if (use_src) allocator.free(info.ip);

        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        const state = GuestState{
            .hostname = info.hostname,
            .ip = actual_ip,
            .target = info.target,
            .mac = info.mac,
            .http_port = info.http_port,
            .version = info.version,
            .last_seen = now,
        };

        // ── IP reuse detection ─────────────────────────────────────────
        // If a DIFFERENT guest previously used this IP, evict it.
        // IPs are unique at any moment; when a new guest picks up an IP
        // that belonged to a different guest, the old entry is stale.
        {
            var it = guests.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, info.hostname) and
                    std.mem.eql(u8, entry.value_ptr.ip, actual_ip))
                {
                    const old_key = entry.key_ptr.*;
                    if (guests.fetchRemove(old_key)) |kv| {
                        std.debug.print("[listener] 🗑 IP {s} reused: {s} → {s}\n", .{ actual_ip, old_key, info.hostname });
                        allocator.free(kv.value.hostname);
                        allocator.free(kv.value.ip);
                        allocator.free(kv.value.target);
                        allocator.free(kv.value.mac);
                        allocator.free(kv.value.version);
                    }
                    break;
                }
            }
        }

        if (guests.getPtr(info.hostname)) |existing| {
            if (!std.mem.eql(u8, existing.ip, actual_ip)) {
                const old_state = GuestState{
                    .hostname = existing.hostname,
                    .ip = existing.ip,
                    .target = existing.target,
                    .mac = existing.mac,
                    .http_port = existing.http_port,
                    .version = existing.version,
                    .last_seen = existing.last_seen,
                };
                std.debug.print("\n[listener] ⚡ IP changed: {s} ({s})  {s} → {s}\n", .{ info.hostname, info.target, existing.ip, actual_ip });

                // Copy state data into owned memory (persist in guests map)
                const owned = GuestState{
                    .hostname = try allocator.dupe(u8, info.hostname),
                    .ip = try allocator.dupe(u8, actual_ip),
                    .target = try allocator.dupe(u8, info.target),
                    .mac = try allocator.dupe(u8, info.mac),
                    .http_port = info.http_port,
                    .version = try allocator.dupe(u8, info.version),
                    .last_seen = now,
                };
                allocator.free(existing.hostname);
                allocator.free(existing.ip);
                allocator.free(existing.target);
                allocator.free(existing.mac);
                allocator.free(existing.version);
                existing.* = owned;
                on_ip_changed.call(old_state, state);
            } else {
                // Same IP — update mutable fields that may have changed
                // (version after auto-upgrade, target after reinstall, etc.)
                var changed = false;
                const old_state = GuestState{
                    .hostname = existing.hostname,
                    .ip = existing.ip,
                    .target = existing.target,
                    .mac = existing.mac,
                    .http_port = existing.http_port,
                    .version = existing.version,
                    .last_seen = existing.last_seen,
                };
                if (!std.mem.eql(u8, existing.version, info.version)) {
                    allocator.free(existing.version);
                    existing.version = try allocator.dupe(u8, info.version);
                    changed = true;
                }
                if (!std.mem.eql(u8, existing.target, info.target)) {
                    allocator.free(existing.target);
                    existing.target = try allocator.dupe(u8, info.target);
                    changed = true;
                }
                if (!std.mem.eql(u8, existing.mac, info.mac)) {
                    allocator.free(existing.mac);
                    existing.mac = try allocator.dupe(u8, info.mac);
                    changed = true;
                }
                if (existing.http_port != info.http_port) {
                    existing.http_port = info.http_port;
                    changed = true;
                }
                existing.last_seen = now;
                if (changed) {
                    on_ip_changed.call(old_state, state);
                }
            }
        } else {
            std.debug.print("[listener] 🆕 New guest discovered: {s} ({s}) → {s}\n", .{ info.hostname, info.target, actual_ip });
            const owned = GuestState{
                .hostname = try allocator.dupe(u8, info.hostname),
                .ip = try allocator.dupe(u8, actual_ip),
                .target = try allocator.dupe(u8, info.target),
                .mac = try allocator.dupe(u8, info.mac),
                .http_port = info.http_port,
                .version = try allocator.dupe(u8, info.version),
                .last_seen = now,
            };
            try guests.put(owned.hostname, owned);
            on_ip_changed.call(null, state);
        }
    }
}

test "GuestState" {
    _ = GuestState;
}
