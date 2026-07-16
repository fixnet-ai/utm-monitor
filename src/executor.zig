//! --exec remote command execution (Host side)

const std = @import("std");
const protocol = @import("protocol.zig");
const listener = @import("listener.zig");
const http_client = @import("http_client.zig");

/// Execute a command on a remote Guest via HTTP POST /exec
pub fn execRemote(
    io: std.Io,
    allocator: std.mem.Allocator,
    target_ip: []const u8,
    http_port: u16,
    cmd: []const u8,
) ![]const u8 {
    const resp = try http_client.execRemote(io, allocator, target_ip, http_port, cmd);
    defer allocator.free(resp);

    // Parse HTTP response: "OK\n<output>\n" or "ERR\n<message>\n"
    const trimmed = std.mem.trim(u8, resp, " \n\r");
    if (std.mem.startsWith(u8, trimmed, "OK")) {
        const output = if (trimmed.len > 3 and trimmed[2] == '\n')
            std.mem.trim(u8, trimmed[3..], "\n")
        else
            trimmed;
        return try allocator.dupe(u8, output);
    } else if (std.mem.startsWith(u8, trimmed, "ERR")) {
        std.debug.print("[exec] Remote error: {s}\n", .{trimmed});
        return error.RemoteExecFailed;
    }

    // If no OK/ERR prefix, return the raw response
    return try allocator.dupe(u8, trimmed);
}

/// Set SO_REUSEADDR on UDP socket to share port with Host listener
fn setReuseAddr(socket: std.Io.net.Socket) !void {
    if (@import("builtin").os.tag == .windows) return; // Windows not supported
    const sol_socket = std.posix.SOL.SOCKET;
    const so_reuseaddr = std.posix.SO.REUSEADDR;
    const one = [_]u8{1, 0, 0, 0}; // int 1 as bytes (little-endian)
    try std.posix.setsockopt(socket.handle, sol_socket, so_reuseaddr, &one);
}

/// Resolve Guest info via UDP broadcast (send PING, wait for ANNOUNCE reply)
/// target_name can be hostname or FQDN
pub fn resolveGuest(
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    target_name: []const u8,
) !protocol.GuestInfo {
    const broadcast_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);
    const bind_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const socket = try bind_addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer socket.close(io);
    try setReuseAddr(socket);

    // Send PING
    var msg_buf: [64]u8 = undefined;
    var msg_writer: std.Io.Writer = .fixed(&msg_buf);
    try protocol.buildPing(&msg_writer);
    try socket.send(io, &broadcast_addr, msg_writer.buffered());

    // Wait for reply (max 3 seconds)
    var recv_buf: [2048]u8 = undefined;
    const deadline = std.Io.Timestamp.now(io, .real).addDuration(std.Io.Duration.fromSeconds(3));

    while (std.Io.Timestamp.now(io, .real).nanoseconds < deadline.nanoseconds) {
        const msg_result = socket.receive(io, &recv_buf) catch break;
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") != null) {
            var info = protocol.GuestInfo.parse(allocator, msg) catch continue;

            // Match: exact hostname match, or exact FQDN match
            const fqdn = info.fqdn(allocator) catch "unknown";
            defer allocator.free(fqdn);

            const matched = std.mem.eql(u8, info.hostname, target_name) or
                std.mem.eql(u8, fqdn, target_name);

            if (!matched) {
                allocator.free(info.hostname);
                allocator.free(info.ip);
                allocator.free(info.target);
                allocator.free(info.mac);
                allocator.free(info.version);
                continue;
            }

            // If guest self-reported IP is unreliable, extract source IP from UDP packet
            if (std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.")) {
                allocator.free(info.ip);
                info.ip = switch (msg_result.from) {
                    .ip4 => |a| try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
                    .ip6 => |a| try std.fmt.allocPrint(allocator, "{any}", .{a}),
                };
            }
            return info;
        }
    }

    std.debug.print("[exec] Guest not found: {s}\n", .{target_name});
    return error.GuestNotFound;
}

test "resolveGuest" { _ = resolveGuest; }
test "execRemote" { _ = execRemote; }
test "findGuest" { _ = findGuest; }

/// Find by hostname or FQDN from GuestState list (for IPC reuse, no UDP PING needed)
pub fn findGuest(guests: []const listener.GuestState, target_name: []const u8) ?listener.GuestState {
    for (guests) |g| {
        if (std.mem.eql(u8, g.hostname, target_name)) return g;
        // Try FQDN match, using stack buffer to avoid heap allocation
        var fqdn_buf: [256]u8 = undefined;
        const fqdn = std.fmt.bufPrint(&fqdn_buf, "{s}.{s}.utm", .{ g.hostname, g.target }) catch continue;
        if (std.mem.eql(u8, fqdn, target_name)) return g;
    }
    return null;
}
