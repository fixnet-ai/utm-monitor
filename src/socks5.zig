//! SOCKS5 Protocol (RFC 1928) — parse, reply, connect, forward, relay.
//!
//! Imports tcp.zig for raw socket I/O and protocol.zig for Connection.
//! All SOCKS5 logic lives here; TCP transport lives in tcp.zig.

const std = @import("std");
const builtin = @import("builtin");
const tcp = @import("tcp.zig");
const protocol = @import("protocol.zig");

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Constants
// ═══════════════════════════════════════════════════════════════════════════

pub const SOCKS_VER: u8 = 0x05;
pub const SOCKS_CMD_CONNECT: u8 = 0x01;
pub const SOCKS_AUTH_NOAUTH: u8 = 0x00;
pub const SOCKS_AUTH_NONE_ACCEPTABLE: u8 = 0xff;
pub const SOCKS_ATYP_IPV4: u8 = 0x01;
pub const SOCKS_ATYP_DOMAIN: u8 = 0x03;
pub const SOCKS_REP_OK: u8 = 0x00;
pub const SOCKS_REP_GENERAL_FAILURE: u8 = 0x01;

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Request Types
// ═══════════════════════════════════════════════════════════════════════════

pub const Socks5Request = struct {
    hostname: []const u8,
    port: u16,
};

/// Stack-allocated SOCKS5 request parse result. hostname points into caller buffer.
pub const Socks5RequestBuf = struct {
    hostname: []const u8,
    port: u16,
};

// ═══════════════════════════════════════════════════════════════════════════
// Auth Negotiation (server side)
// ═══════════════════════════════════════════════════════════════════════════

/// SOCKS5 auth negotiation (server): read client method list, select NO AUTH.
fn authAccept(fd: tcp.socket_t) !void {
    // Read VER(1) + NMETHODS(1)
    var auth_hdr: [2]u8 = undefined;
    var off: usize = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, auth_hdr[off..].ptr, auth_hdr.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5AuthFailed;
        off += @intCast(n);
    }
    if (auth_hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    const nmethods = auth_hdr[1];

    // Read method list
    var methods: [256]u8 = undefined;
    if (nmethods > 0) {
        off = 0;
        while (off < nmethods) {
            const n = tcp.sockRead(fd, methods[off..].ptr, nmethods - off);
            if (tcp.sockIsError(n) or n == 0) return error.Socks5AuthFailed;
            off += @intCast(n);
        }
    }

    // Check if NO AUTH is offered
    const found_noauth = for (methods[0..nmethods]) |m| {
        if (m == SOCKS_AUTH_NOAUTH) break true;
    } else false;

    if (!found_noauth) {
        const resp = [_]u8{ SOCKS_VER, SOCKS_AUTH_NONE_ACCEPTABLE };
        _ = tcp.sockWrite(fd, &resp, resp.len);
        return error.Socks5AuthNoMethod;
    }

    // Accept NO AUTH
    const resp = [_]u8{ SOCKS_VER, SOCKS_AUTH_NOAUTH };
    const n = tcp.sockWrite(fd, &resp, resp.len);
    if (n != resp.len) return error.Socks5AuthFailed;
}

// ═══════════════════════════════════════════════════════════════════════════
// Request Parsing
// ═══════════════════════════════════════════════════════════════════════════

/// Read SOCKS5 request into caller-provided buffer, without sending reply.
/// Completes auth negotiation + request parsing internally.
/// hostname is written into buf; returns Socks5RequestBuf pointing into buf.
pub fn readRequestBuf(fd: tcp.socket_t, buf: []u8) !Socks5RequestBuf {
    // Phase 1: SOCKS5 auth negotiation
    try authAccept(fd);

    // Phase 2: Read request header: VER(1) CMD(1) RSV(1) ATYP(1) = 4 bytes
    var hdr: [4]u8 = undefined;
    var off: usize = 0;
    while (off < 4) {
        const n = tcp.sockRead(fd, hdr[off..].ptr, hdr.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    if (hdr[1] != SOCKS_CMD_CONNECT) return error.Socks5BadCommand;
    if (hdr[3] != SOCKS_ATYP_DOMAIN) return error.Socks5DomainRequired;

    // Phase 3: Read hostname length (1 byte) + hostname
    var len_byte: u8 = undefined;
    off = 0;
    while (off < 1) {
        const n = tcp.sockRead(fd, @as([*]u8, @ptrCast(&len_byte)), 1);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (len_byte == 0 or len_byte > tcp.MAX_HOSTNAME) return error.Socks5BadHostname;

    off = 0;
    while (off < len_byte) {
        const n = tcp.sockRead(fd, buf[off..].ptr, len_byte - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const hostname = buf[0..len_byte];

    // Phase 4: Read port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5RequestBuf{ .hostname = hostname, .port = dst_port };
}

/// Read SOCKS5 request (with auth negotiation, for tests).
/// Returned Socks5Request.hostname is allocator-owned; caller must free.
/// Production code should use checkAndReply or readRequestBuf.
pub fn accept(fd: tcp.socket_t, allocator: std.mem.Allocator) !Socks5Request {
    // Phase 1: SOCKS5 auth negotiation
    try authAccept(fd);

    // Phase 2: Read request header: VER(1) CMD(1) RSV(1) ATYP(1) = 4 bytes
    var hdr: [4]u8 = undefined;
    var off: usize = 0;
    while (off < 4) {
        const n = tcp.sockRead(fd, hdr[off..].ptr, hdr.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (hdr[0] != SOCKS_VER) return error.Socks5BadVersion;
    if (hdr[1] != SOCKS_CMD_CONNECT) return error.Socks5BadCommand;
    if (hdr[3] != SOCKS_ATYP_DOMAIN) return error.Socks5DomainRequired;

    // Phase 3: Read hostname length (1 byte) + hostname
    var len_byte: u8 = undefined;
    off = 0;
    while (off < 1) {
        const n = tcp.sockRead(fd, @as([*]u8, @ptrCast(&len_byte)), 1);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    if (len_byte == 0 or len_byte > tcp.MAX_HOSTNAME) return error.Socks5BadHostname;

    var hn_buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    off = 0;
    while (off < len_byte) {
        const n = tcp.sockRead(fd, hn_buf[off..].ptr, len_byte - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const hn = hn_buf[0..len_byte];

    // Phase 4: Read port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5Request{ .hostname = try allocator.dupe(u8, hn), .port = dst_port };
}

// ═══════════════════════════════════════════════════════════════════════════
// Reply Helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Send SOCKS5 success response (10 bytes).
pub fn replyOk(fd: tcp.socket_t) void {
    const resp = [_]u8{
        SOCKS_VER, SOCKS_REP_OK, // VER, REP=success
        0x00, // RSV
        SOCKS_ATYP_IPV4, // ATYP=IPv4
        0x00, 0x00, 0x00, 0x00, // BND.ADDR = 0.0.0.0
        0x00, 0x00, // BND.PORT = 0
    };
    _ = tcp.sockWrite(fd, &resp, resp.len);
}

/// Send SOCKS5 rejection response (10 bytes).
pub fn replyRejected(fd: tcp.socket_t) void {
    const resp = [_]u8{
        SOCKS_VER, SOCKS_REP_GENERAL_FAILURE, // VER, REP=failure
        0x00, // RSV
        SOCKS_ATYP_IPV4, // ATYP=IPv4
        0x00, 0x00, 0x00, 0x00, // BND.ADDR = 0.0.0.0
        0x00, 0x00, // BND.PORT = 0
    };
    _ = tcp.sockWrite(fd, &resp, resp.len);
}

// ═══════════════════════════════════════════════════════════════════════════
// Server-Side Dispatch
// ═══════════════════════════════════════════════════════════════════════════

/// Read SOCKS5 request from accepted TCP socket (with auth negotiation),
/// check if hostname matches. If matched, send OK and return true;
/// otherwise send rejection and return false.
pub fn checkAndReply(fd: tcp.socket_t, self_hostname: []const u8) !bool {
    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const req = try readRequestBuf(fd, buf[0..]);
    if (std.mem.eql(u8, req.hostname, self_hostname)) {
        replyOk(fd);
        return true;
    }
    replyRejected(fd);
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Connect (Client Side)
// ═══════════════════════════════════════════════════════════════════════════

/// Send SOCKS5 auth negotiation + connect request (internal, via raw fd).
fn sendRequest(fd: tcp.socket_t, hostname: []const u8, port: u16) !void {
    // Step 1: Send auth negotiation [0x05, 0x01, 0x00] (VER, 1 method, NO AUTH)
    const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
    const n1 = tcp.sockWrite(fd, &auth, auth.len);
    if (n1 != auth.len) return error.Socks5SendFailed;

    // Step 2: Read auth response [0x05, 0x00]
    var auth_resp: [2]u8 = undefined;
    var off: usize = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, auth_resp[off..].ptr, auth_resp.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5AuthFailed;
        off += @intCast(n);
    }
    if (auth_resp[0] != SOCKS_VER or auth_resp[1] != SOCKS_AUTH_NOAUTH) {
        return error.Socks5AuthFailed;
    }

    // Step 3: Build and send SOCKS5 request
    // VER(1) CMD(1) RSV(1) ATYP(1) LEN(1) HOSTNAME(N) PORT(2)
    var req: [270]u8 = undefined;
    var pos: usize = 0;
    req[pos] = SOCKS_VER;
    pos += 1;
    req[pos] = SOCKS_CMD_CONNECT;
    pos += 1;
    req[pos] = 0x00;
    pos += 1; // RSV
    req[pos] = SOCKS_ATYP_DOMAIN;
    pos += 1;
    req[pos] = @truncate(hostname.len);
    pos += 1; // 1-byte hostname length
    @memcpy(req[pos..][0..hostname.len], hostname);
    pos += hostname.len;
    std.mem.writeInt(u16, req[pos..][0..2], port, .big);
    pos += 2;

    const n2 = tcp.sockWrite(fd, &req, pos);
    if (n2 != pos) return error.Socks5SendFailed;
}

/// Send SOCKS5 connect request to target address (with auth negotiation).
/// Returns connected TCP stream; caller is responsible for closing.
pub fn connect(
    io: std.Io,
    target_ip: std.Io.net.IpAddress,
    target_hostname: []const u8,
    target_port: u16,
) !std.Io.net.Stream {
    const stream = tcp.connectTcp(io, &target_ip, tcp.TCP_CONNECT_TIMEOUT_MS) catch |err| {
        return err;
    };
    errdefer stream.close(io);

    const fd = stream.socket.handle;
    try sendRequest(fd, target_hostname, target_port);

    // Read SOCKS5 response: VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(var) BND.PORT(2)
    // Minimum 10 bytes (when ATYP=IPv4)
    var resp: [10]u8 = undefined;
    var off: usize = 0;
    while (off < 10) {
        const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) {
            stream.close(io);
            return error.Socks5ResponseTooShort;
        }
        off += @intCast(n);
    }
    if (resp[0] != SOCKS_VER) {
        stream.close(io);
        return error.Socks5BadVersion;
    }
    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        return error.Socks5Rejected;
    }

    return stream;
}

// ═══════════════════════════════════════════════════════════════════════════
// Local Relay
// ═══════════════════════════════════════════════════════════════════════════

/// Local relay: connect 127.0.0.1:target_port, then relay.
/// Sends rejection to client on failure. Does not return — runs relay.
/// Uses raw socket API (not Zig Io.net) to ensure fd type compatibility.
/// Windows: Winsock2 SOCKET vs AFD handles are incompatible.
pub fn localRelay(io: std.Io, client_fd: tcp.socket_t, target_port: u16) void {
    _ = io; // unused — raw sockets don't need Zig Io
    const local_fd = tcp.sockConnectLocalhost(target_port) catch {
        replyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };

    replyOk(client_fd);
    relay(client_fd, local_fd);
    tcp.sockClose(client_fd);
    tcp.sockClose(local_fd);
}

/// Local relay thread wrapper — releases connection limit slot on completion.
pub fn localRelayWithLimit(io: std.Io, fd: tcp.socket_t, port: u16, limit: *tcp.ConnLimit) !void {
    defer limit.release();
    localRelay(io, fd, port);
}

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Chain Forwarding
// ═══════════════════════════════════════════════════════════════════════════

/// SOCKS5 chain-forward: connect to next-hop node, send SOCKS5 request, relay.
/// Sends rejection to original client on failure. Does not return.
pub fn forward(
    io: std.Io,
    client_fd: tcp.socket_t,
    next_hop_ip: std.Io.net.IpAddress,
    target_hostname: []const u8,
    target_port: u16,
) void {
    const stream = connect(io, next_hop_ip, target_hostname, target_port) catch {
        replyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };
    const next_fd = stream.socket.handle;
    // Don't close stream — fd ownership transferred to relay

    replyOk(client_fd);
    relay(client_fd, next_fd);
    tcp.sockClose(client_fd);
    tcp.sockClose(next_fd);
}

// ═══════════════════════════════════════════════════════════════════════════
// Bidirectional Relay
// ═══════════════════════════════════════════════════════════════════════════

/// Bidirectional relay: A ↔ B. Two threads, one per direction.
/// When one side closes, shuts down write on the other side.
pub fn relay(a_fd: tcp.socket_t, b_fd: tcp.socket_t) void {
    var a_to_b_done = std.atomic.Value(bool).init(false);

    const relay_thread = std.Thread.spawn(.{}, relayDir, .{ b_fd, a_fd, &a_to_b_done }) catch return;
    defer relay_thread.join();

    relayDir(a_fd, b_fd, &a_to_b_done);
}

fn relayDir(src: tcp.socket_t, dst: tcp.socket_t, done: *std.atomic.Value(bool)) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = tcp.sockRead(src, &buf, buf.len);
        if (n == 0) {
            tcp.sockShutdown(dst, 1); // SHUT_WR — notify peer no more data
            done.store(true, .release);
            return;
        }
        if (tcp.sockIsError(n)) {
            done.store(true, .release);
            return;
        }
        const w = tcp.sockWrite(dst, &buf, @intCast(n));
        if (tcp.sockIsError(w)) {
            done.store(true, .release);
            return;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Host Connect
// ═══════════════════════════════════════════════════════════════════════════

/// Connect to a Guest and complete SOCKS5 handshake, returning a Connection.
pub fn hostConnect(io: std.Io, guest_ip: []const u8, guest_hostname: []const u8, port: u16) !protocol.Connection {
    const addr = std.Io.net.IpAddress.parse(guest_ip, port) catch |err| {
        std.log.err("[socks5] parse guest IP '{s}' failed: {}", .{ guest_ip, err });
        return error.ConnectFailed;
    };

    const stream = tcp.connectTcp(io, &addr, tcp.TCP_CONNECT_TIMEOUT_MS) catch |err| {
        std.log.err("[socks5] connect to {s}:{d} failed: {}", .{ guest_ip, port, err });
        return error.ConnectFailed;
    };

    const fd = stream.socket.handle;
    errdefer {
        stream.close(io);
    }

    // Send SOCKS5 auth + request
    try sendRequest(fd, guest_hostname, port);

    // Read SOCKS5 response (10 bytes)
    var resp: [10]u8 = undefined;
    var off: usize = 0;
    while (off < 10) {
        const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) {
            stream.close(io);
            return error.Socks5ResponseTooShort;
        }
        off += @intCast(n);
    }

    if (resp[1] != SOCKS_REP_OK) {
        stream.close(io);
        std.log.err("[socks5] SOCKS5 rejected by {s}", .{guest_hostname});
        return error.Socks5Rejected;
    }

    // Don't close stream — fd ownership transferred to Connection
    return protocol.Connection{ .fd = fd, .alive = true };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "socks5 handshake round-trip" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Client thread: send SOCKS5 auth + request → verify response
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            // Auth: [0x05, 0x01, 0x00]
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = tcp.sockWrite(fd, &auth, auth.len);
            // Read auth response
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = tcp.sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }
            std.debug.assert(auth_resp[0] == SOCKS_VER);
            std.debug.assert(auth_resp[1] == SOCKS_AUTH_NOAUTH);

            // Request: VER CMD RSV ATYP=0x03 LEN=4 "test" PORT=2121
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT, // VER, CMD
                0x00, // RSV
                SOCKS_ATYP_DOMAIN, // ATYP=domain
                4, // hostname len
                't',  'e',  's',  't', // HOSTNAME
                0x08, 0x49, // PORT = 2121
            };
            _ = tcp.sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            if (off >= 2) {
                std.debug.assert(resp[0] == SOCKS_VER);
                std.debug.assert(resp[1] == SOCKS_REP_OK);
            }
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // Server: accept → read SOCKS5 request → send reply
    const request = try accept(pair.a, std.testing.allocator);
    defer std.testing.allocator.free(request.hostname);
    try std.testing.expectEqualStrings("test", request.hostname);
    try std.testing.expectEqual(@as(u16, 2121), request.port);

    replyOk(pair.a);
}

test "socks5ReplyRejected" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    replyRejected(pair.a);

    var resp: [10]u8 = [_]u8{0} ** 10;
    var off: usize = 0;
    while (off < 10) {
        const n = tcp.sockRead(pair.b, resp[off..].ptr, resp.len - off);
        if (n == 0) break;
        off += @intCast(n);
    }
    try std.testing.expect(resp[1] == SOCKS_REP_GENERAL_FAILURE);
}

test "socks5CheckAndReply matching hostname" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Client thread: send SOCKS5 request with correct hostname
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = tcp.sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = tcp.sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="self"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                4, 's', 'e', 'l', 'f',
                0x08, 0x49, // PORT = 2121
            };
            _ = tcp.sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_OK);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // Server: checkAndReply should match "self" → return true + send OK
    const accepted = try checkAndReply(pair.a, "self");
    try std.testing.expect(accepted);
}

test "socks5CheckAndReply mismatched hostname" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Client thread: send "intruder" hostname
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = tcp.sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = tcp.sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="intruder"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                8, 'i', 'n', 't', 'r', 'u', 'd', 'e', 'r',
                0x08, 0x49,
            };
            _ = tcp.sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_GENERAL_FAILURE);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // Server: checkAndReply should not match → return false + send rejection
    const accepted = try checkAndReply(pair.a, "self");
    try std.testing.expect(!accepted);
}

test "socks5CheckAndReply on non-blocking socket" {
    const pair = try tcp.makeNonBlockingPair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Client thread sends SOCKS5 auth+request (hostname="nbself")
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            // Auth
            const auth = [_]u8{ SOCKS_VER, 1, SOCKS_AUTH_NOAUTH };
            _ = tcp.sockWrite(fd, &auth, auth.len);
            var auth_resp: [2]u8 = [_]u8{0} ** 2;
            var aoff: usize = 0;
            while (aoff < 2) {
                const n = tcp.sockRead(fd, auth_resp[aoff..].ptr, auth_resp.len - aoff);
                if (n == 0) break;
                aoff += @intCast(n);
            }

            // Request: hostname="nbself"
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                6, 'n', 'b', 's', 'e', 'l', 'f',
                0x08, 0x49, // PORT = 2121
            };
            _ = tcp.sockWrite(fd, &req, req.len);

            var resp: [10]u8 = [_]u8{0} ** 10;
            var off: usize = 0;
            while (off < 10) {
                const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
                if (n == 0) break;
                off += @intCast(n);
            }
            std.debug.assert(resp[0] == SOCKS_VER);
            std.debug.assert(resp[1] == SOCKS_REP_OK);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    // Server completes SOCKS5 handshake on non-blocking socket
    const accepted = try checkAndReply(pair.a, "nbself");
    try std.testing.expect(accepted);
}
