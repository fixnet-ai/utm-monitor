//! --status query module (Host side)

const std = @import("std");
const protocol = @import("protocol.zig");
const listener = @import("listener.zig");

fn setReuseAddr(socket: std.Io.net.Socket) !void {
    if (@import("builtin").os.tag == .windows) return;
    const sol_socket = std.posix.SOL.SOCKET;
    const so_reuseaddr = std.posix.SO.REUSEADDR;
    const one = [_]u8{1, 0, 0, 0};
    try std.posix.setsockopt(socket.handle, sol_socket, so_reuseaddr, &one);
}

pub fn queryStatus(io: std.Io, allocator: std.mem.Allocator, port: u16) !void {
    // Listen on broadcast port for guest ANNOUNCE messages
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const socket = try listen_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer socket.close(io);
    setReuseAddr(socket) catch {};

    var guests: std.ArrayList(listener.GuestState) = .empty;
    defer {
        for (guests.items) |g| {
            allocator.free(g.hostname);
            allocator.free(g.ip);
            allocator.free(g.target);
            allocator.free(g.mac);
            allocator.free(g.version);
        }
        guests.deinit(allocator);
    }

    var recv_buf: [2048]u8 = undefined;
    const deadline = std.Io.Timestamp.now(io, .real).addDuration(std.Io.Duration.fromSeconds(3));

    // Collect broadcast messages until timeout (guests broadcast every second)
    while (std.Io.Timestamp.now(io, .real).nanoseconds < deadline.nanoseconds) {
        const msg_result = socket.receive(io, &recv_buf) catch break;
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") != null) {
            const info = protocol.GuestInfo.parse(allocator, msg) catch continue;

            // Extract real IP (prefer UDP source address)
            const real_ip = if (std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127."))
                switch (msg_result.from) {
                    .ip4 => |a| try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
                    .ip6 => |a| try std.fmt.allocPrint(allocator, "{any}", .{a}),
                }
            else
                info.ip;

            // Check if already in list (deduplicate by hostname)
            var found = false;
            for (guests.items) |*g| {
                if (std.mem.eql(u8, g.hostname, info.hostname)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try guests.append(allocator, .{
                    .hostname = info.hostname,
                    .ip = real_ip,
                    .target = info.target,
                    .mac = info.mac,
                    .http_port = info.http_port,
                    .version = info.version,
                    .last_seen = std.Io.Timestamp.now(io, .real).nanoseconds,
                });
            } else {
                // Free temp fields for duplicates
                allocator.free(info.hostname);
                allocator.free(info.target);
                allocator.free(info.mac);
                allocator.free(info.version);
            }
        }
    }

    if (guests.items.len == 0) {
        std.debug.print("No online Guests\n", .{});
        return;
    }

    // Output: hostname, target, ip, mac, version, status
    std.debug.print("\n{s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s}\n", .{ "Hostname", "Target", "IP", "MAC", "Version", "Status" });
    std.debug.print("{s:-<85}\n", .{""});
    for (guests.items) |g| {
        const ok = std.mem.eql(u8, g.version, protocol.VERSION);
        std.debug.print("{s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s}\n", .{
            g.hostname, g.target, g.ip, g.mac, g.version,
            if (ok) "✓" else "⚠ upgradeable",
        });
    }
    std.debug.print("\n", .{});
}

/// Generate --status table from GuestState list (for IPC reuse)
pub fn formatStatusTable(allocator: std.mem.Allocator, guests: []const listener.GuestState) ![]const u8 {
    if (guests.len == 0) {
        return try allocator.dupe(u8, "No online Guests\n");
    }

    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(allocator, "\n");
    try buf.print(allocator, "{s: <16} {s: <18} {s: <16} {s: <18} {s: <10} {s}\n", .{ "Hostname", "Target", "IP", "MAC", "Version", "Status" });
    try buf.print(allocator, "{s:-<85}\n", .{""});
    for (guests) |g| {
        const ok = std.mem.eql(u8, g.version, protocol.VERSION);
        try buf.print(allocator, "{s: <16} {s: <18} {s: <16} {s: <18} v{s: <9} {s}\n", .{
            g.hostname, g.target, g.ip, g.mac, g.version,
            if (ok) "✓" else "⚠ upgradeable",
        });
    }
    try buf.appendSlice(allocator, "\n");

    return buf.toOwnedSlice(allocator);
}

test "queryStatus" { _ = queryStatus; }
test "formatStatusTable" { _ = formatStatusTable; }
