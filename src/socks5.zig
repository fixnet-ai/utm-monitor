//! SOCKS5 Protocol (RFC 1928) — parse, reply, connect, forward, relay.
//!
//! Imports tcp.zig for raw socket I/O and protocol.zig for Connection.
//! All SOCKS5 logic lives here; TCP transport lives in tcp.zig.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const tcp = @import("tcp.zig");
const protocol = @import("protocol.zig");

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Constants
// ═══════════════════════════════════════════════════════════════════════════

pub const SOCKS_VER: u8 = 0x05;
pub const SOCKS_CMD_CONNECT: u8 = 0x01;
pub const SOCKS_CMD_BIND: u8 = 0x02;
pub const SOCKS_CMD_UDP_ASSOCIATE: u8 = 0x03;
pub const SOCKS_AUTH_NOAUTH: u8 = 0x00;
pub const SOCKS_AUTH_NONE_ACCEPTABLE: u8 = 0xff;
pub const SOCKS_ATYP_IPV4: u8 = 0x01;
pub const SOCKS_ATYP_DOMAIN: u8 = 0x03;
pub const SOCKS_ATYP_IPV6: u8 = 0x04;
pub const SOCKS_REP_OK: u8 = 0x00;
pub const SOCKS_REP_GENERAL_FAILURE: u8 = 0x01;
pub const SOCKS_REP_COMMAND_NOT_SUPPORTED: u8 = 0x07;
pub const SOCKS_REP_ADDRESS_TYPE_NOT_SUPPORTED: u8 = 0x08;

// ═══════════════════════════════════════════════════════════════════════════
// SOCKS5 Request Types
// ═══════════════════════════════════════════════════════════════════════════

pub const Socks5Request = struct {
    cmd: u8,
    atyp: u8,
    hostname: []const u8,
    port: u16,
};

/// Stack-allocated SOCKS5 request parse result. hostname points into caller buffer.
pub const Socks5RequestBuf = struct {
    cmd: u8,
    atyp: u8,
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

/// SOCKS5 auth negotiation variant: VER byte already consumed by caller (peek).
/// Skips VER read — only reads NMETHODS + method list, sends NO AUTH reply.
fn authAcceptWithVersion(fd: tcp.socket_t, version_byte: u8) !void {
    _ = version_byte; // caller must ensure version_byte == SOCKS_VER (0x05)

    // Read NMETHODS(1) — VER was already consumed by the caller's peek
    var nmethods_byte: u8 = undefined;
    var off: usize = 0;
    while (off < 1) {
        const n = tcp.sockRead(fd, @as([*]u8, @ptrCast(&nmethods_byte)), 1);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5AuthFailed;
        off += @intCast(n);
    }
    const nmethods = nmethods_byte;

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
/// Supports CMD: CONNECT, BIND, UDP_ASSOCIATE. ATYP: IPv4, DOMAIN.
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

    const cmd = hdr[1];
    switch (cmd) {
        SOCKS_CMD_CONNECT, SOCKS_CMD_BIND, SOCKS_CMD_UDP_ASSOCIATE => {},
        else => return error.Socks5BadCommand,
    }

    const atyp = hdr[3];
    var hostname: []const u8 = undefined;

    switch (atyp) {
        SOCKS_ATYP_IPV4 => {
            // Read 4-byte IPv4 address
            var ip: [4]u8 = undefined;
            off = 0;
            while (off < 4) {
                const n = tcp.sockRead(fd, ip[off..].ptr, ip.len - off);
                if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
                off += @intCast(n);
            }
            // Format as dotted decimal into buf
            hostname = try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        },
        SOCKS_ATYP_DOMAIN => {
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
            hostname = buf[0..len_byte];
        },
        SOCKS_ATYP_IPV6 => return error.Socks5AddressTypeNotSupported,
        else => return error.Socks5AddressTypeNotSupported,
    }

    // Phase 4: Read port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5RequestBuf{ .cmd = cmd, .atyp = atyp, .hostname = hostname, .port = dst_port };
}

/// Read SOCKS5 request into caller-provided buffer, skipping VER byte.
/// `version_byte` is the already-peeked first byte (must be SOCKS_VER).
/// Completes auth negotiation (without re-reading VER) + request parsing.
pub fn readRequestBufWithVersion(fd: tcp.socket_t, buf: []u8, version_byte: u8) !Socks5RequestBuf {
    // Phase 1: SOCKS5 auth negotiation — VER byte already consumed by caller's peek
    try authAcceptWithVersion(fd, version_byte);

    // Phase 2: Read remaining header: CMD(1) RSV(1) ATYP(1) = 3 bytes (VER already consumed)
    var hdr: [3]u8 = undefined;
    var off: usize = 0;
    while (off < 3) {
        const n = tcp.sockRead(fd, hdr[off..].ptr, hdr.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }

    const cmd = hdr[0];
    switch (cmd) {
        SOCKS_CMD_CONNECT, SOCKS_CMD_BIND, SOCKS_CMD_UDP_ASSOCIATE => {},
        else => return error.Socks5BadCommand,
    }

    const atyp = hdr[2];
    var hostname: []const u8 = undefined;

    switch (atyp) {
        SOCKS_ATYP_IPV4 => {
            // Read 4-byte IPv4 address
            var ip: [4]u8 = undefined;
            off = 0;
            while (off < 4) {
                const n = tcp.sockRead(fd, ip[off..].ptr, ip.len - off);
                if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
                off += @intCast(n);
            }
            // Format as dotted decimal into buf
            hostname = try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        },
        SOCKS_ATYP_DOMAIN => {
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
            hostname = buf[0..len_byte];
        },
        SOCKS_ATYP_IPV6 => return error.Socks5AddressTypeNotSupported,
        else => return error.Socks5AddressTypeNotSupported,
    }

    // Phase 4: Read port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5RequestBuf{ .cmd = cmd, .atyp = atyp, .hostname = hostname, .port = dst_port };
}

/// Read SOCKS5 request (with auth negotiation, for tests).
/// Returned Socks5Request.hostname is allocator-owned; caller must free.
/// Production code should use checkAndReply or readRequestBuf.
/// Supports CMD: CONNECT, BIND, UDP_ASSOCIATE. ATYP: IPv4, DOMAIN.
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

    const cmd = hdr[1];
    switch (cmd) {
        SOCKS_CMD_CONNECT, SOCKS_CMD_BIND, SOCKS_CMD_UDP_ASSOCIATE => {},
        else => return error.Socks5BadCommand,
    }

    const atyp = hdr[3];
    var hn_buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const hn: []const u8 = switch (atyp) {
        SOCKS_ATYP_IPV4 => blk: {
            // Read 4-byte IPv4 address
            var ip: [4]u8 = undefined;
            off = 0;
            while (off < 4) {
                const n = tcp.sockRead(fd, ip[off..].ptr, ip.len - off);
                if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
                off += @intCast(n);
            }
            break :blk try std.fmt.bufPrint(&hn_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        },
        SOCKS_ATYP_DOMAIN => blk: {
            // Read hostname length (1 byte) + hostname
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
                const n = tcp.sockRead(fd, hn_buf[off..].ptr, len_byte - off);
                if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
                off += @intCast(n);
            }
            break :blk hn_buf[0..len_byte];
        },
        SOCKS_ATYP_IPV6 => return error.Socks5AddressTypeNotSupported,
        else => return error.Socks5AddressTypeNotSupported,
    };

    // Phase 4: Read port (2 bytes BE)
    var port_buf: [2]u8 = undefined;
    off = 0;
    while (off < 2) {
        const n = tcp.sockRead(fd, port_buf[off..].ptr, port_buf.len - off);
        if (tcp.sockIsError(n) or n == 0) return error.Socks5HeaderTooShort;
        off += @intCast(n);
    }
    const dst_port = std.mem.readInt(u16, &port_buf, .big);

    return Socks5Request{
        .cmd = cmd,
        .atyp = atyp,
        .hostname = try allocator.dupe(u8, hn),
        .port = dst_port,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Reply Helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Send parameterized SOCKS5 reply (10 bytes).
pub fn reply(fd: tcp.socket_t, rep: u8, bnd_addr: [4]u8, bnd_port: u16) void {
    const resp = [_]u8{
        SOCKS_VER, rep,
        0x00, // RSV
        SOCKS_ATYP_IPV4, // ATYP=IPv4
        bnd_addr[0], bnd_addr[1], bnd_addr[2], bnd_addr[3],
        @truncate(bnd_port >> 8), @truncate(bnd_port & 0xff),
    };
    _ = tcp.sockWrite(fd, &resp, resp.len);
}

/// Send SOCKS5 success response (10 bytes).
pub fn replyOk(fd: tcp.socket_t) void {
    reply(fd, SOCKS_REP_OK, [_]u8{ 0, 0, 0, 0 }, 0);
}

/// Send SOCKS5 rejection response (10 bytes).
pub fn replyRejected(fd: tcp.socket_t) void {
    reply(fd, SOCKS_REP_GENERAL_FAILURE, [_]u8{ 0, 0, 0, 0 }, 0);
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

/// Send SOCKS5 auth negotiation + request (internal, via raw fd).
/// Parameterized: cmd (CONNECT/BIND/UDP_ASSOCIATE), atyp (IPv4/DOMAIN).
fn sendRequest(fd: tcp.socket_t, cmd: u8, atyp: u8, hostname: []const u8, port: u16) !void {
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
    req[pos] = cmd;
    pos += 1;
    req[pos] = 0x00;
    pos += 1; // RSV
    req[pos] = atyp;
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

/// SOCKS5 reply parsed from server response.
pub const Socks5Reply = struct {
    rep: u8,
    bnd_addr: [4]u8,
    bnd_port: u16,
};

/// Read SOCKS5 reply (10 bytes, IPv4 ATYP only) from fd.
pub fn readReply(fd: tcp.socket_t) !Socks5Reply {
    var resp: [10]u8 = undefined;
    var off: usize = 0;
    while (off < 10) {
        const n = tcp.sockRead(fd, resp[off..].ptr, resp.len - off);
        if (n == 0) return error.Socks5ResponseTooShort;
        if (tcp.sockIsError(n)) return error.Socks5ReadFailed;
        off += @intCast(n);
    }
    if (resp[0] != SOCKS_VER) return error.Socks5BadVersion;
    return Socks5Reply{
        .rep = resp[1],
        .bnd_addr = resp[4..8].*,
        .bnd_port = std.mem.readInt(u16, resp[8..10], .big),
    };
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
    try sendRequest(fd, SOCKS_CMD_CONNECT, SOCKS_ATYP_DOMAIN, target_hostname, target_port);

    const rep = try readReply(fd);
    if (rep.rep != SOCKS_REP_OK) {
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
    const local_fd = tcp.sockConnectLocalhost(target_port) catch {
        replyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };

    replyOk(client_fd);
    relay(io, client_fd, local_fd);
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
    relay(io, client_fd, next_fd);
    tcp.sockClose(client_fd);
    tcp.sockClose(next_fd);
}

// ═══════════════════════════════════════════════════════════════════════════
// Bidirectional Relay
// ═══════════════════════════════════════════════════════════════════════════

/// Bidirectional relay: A ↔ B. Uses zio spawnBlocking for managed thread pool.
/// When one side closes, shuts down write on the other side.
pub fn relay(io: std.Io, a_fd: tcp.socket_t, b_fd: tcp.socket_t) void {
    const rt = zio.Runtime.fromIo(io);
    var a_to_b_done = std.atomic.Value(bool).init(false);

    var relay_handle = rt.spawnBlocking(relayDir, .{ b_fd, a_fd, &a_to_b_done }) catch return;
    defer _ = relay_handle.join();

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
// UDP ASSOCIATE Relay (RFC 1928 Section 6)
// ═══════════════════════════════════════════════════════════════════════════

/// SOCKS5 UDP ASSOCIATE relay. Binds a UDP socket, replies with BND.ADDR:BND.PORT,
/// then relays UDP datagrams bidirectionally over the TCP connection.
/// Does not return — runs until TCP closes or error.
/// Only IPv4 ATYP is supported for relayed datagrams.
pub fn udpAssociate(io: std.Io, tcp_fd: tcp.socket_t) void {
    const udp_fd = tcp.createUdpSocket() catch {
        replyRejected(tcp_fd);
        tcp.sockClose(tcp_fd);
        return;
    };
    const udp_port = tcp.getBoundPort(udp_fd) catch {
        replyRejected(tcp_fd);
        tcp.sockClose(udp_fd);
        tcp.sockClose(tcp_fd);
        return;
    };

    // Reply with BND.ADDR=0.0.0.0, BND.PORT=assigned UDP port
    reply(tcp_fd, SOCKS_REP_OK, [_]u8{ 0, 0, 0, 0 }, udp_port);

    const rt = zio.Runtime.fromIo(io);
    var shutdown = std.atomic.Value(bool).init(false);

    // TCP→UDP on managed thread pool
    var tcp_to_udp = rt.spawnBlocking(udpTcpToUdp, .{ tcp_fd, udp_fd, &shutdown }) catch {
        tcp.sockClose(tcp_fd);
        tcp.sockClose(udp_fd);
        return;
    };
    // UDP→TCP thread (runs in current thread)
    udpUdpToTcp(tcp_fd, udp_fd, &shutdown);
    _ = tcp_to_udp.join();

    tcp.sockClose(tcp_fd);
    tcp.sockClose(udp_fd);
}

/// Read SOCKS5 UDP datagrams from TCP, extract DATA, forward via UDP.
fn udpTcpToUdp(tcp_fd: tcp.socket_t, udp_fd: tcp.socket_t, shutdown: *std.atomic.Value(bool)) void {
    var buf: [65536]u8 = undefined;
    while (!shutdown.load(.acquire)) {
        // Read 2-byte BE length prefix
        var len_buf: [2]u8 = undefined;
        var off: usize = 0;
        while (off < 2) {
            const n = tcp.sockRead(tcp_fd, len_buf[off..].ptr, len_buf.len - off);
            if (n == 0) {
                shutdown.store(true, .release);
                return;
            }
            if (tcp.sockIsError(n)) {
                shutdown.store(true, .release);
                return;
            }
            off += @intCast(n);
        }
        const dgram_len = std.mem.readInt(u16, &len_buf, .big);
        if (dgram_len == 0 or dgram_len > buf.len) {
            shutdown.store(true, .release);
            return;
        }

        // Read UDP datagram body
        off = 0;
        while (off < dgram_len) {
            const n = tcp.sockRead(tcp_fd, buf[off..].ptr, dgram_len - off);
            if (n == 0) {
                shutdown.store(true, .release);
                return;
            }
            if (tcp.sockIsError(n)) {
                shutdown.store(true, .release);
                return;
            }
            off += @intCast(n);
        }

        const dgram = buf[0..dgram_len];
        // Format: RSV(2) FRAG(1) ATYP(1) DST.ADDR(var) DST.PORT(2) DATA(rest)
        if (dgram.len < 10) continue; // minimum: RSV+FRAG+ATYP+IPv4(4)+PORT(2) = 10

        const frag = dgram[2];
        if (frag != 0) continue; // fragmentation not supported

        const atyp = dgram[3];
        if (atyp != SOCKS_ATYP_IPV4) continue; // only IPv4 supported

        const dst_ip: [4]u8 = dgram[4..8].*;
        const dst_port = std.mem.readInt(u16, dgram[8..10], .big);
        const data = dgram[10..];

        const addr = tcp.UdpAddr{ .ip = dst_ip, .port = dst_port };
        tcp.sendUdpTo(udp_fd, data, addr) catch continue;
    }
}

/// Receive raw UDP datagrams, wrap in SOCKS5 UDP format, send via TCP.
fn udpUdpToTcp(tcp_fd: tcp.socket_t, udp_fd: tcp.socket_t, shutdown: *std.atomic.Value(bool)) void {
    var buf: [65536]u8 = undefined;
    while (!shutdown.load(.acquire)) {
        const result = tcp.recvUdpFrom(udp_fd, buf[10..]) catch {
            // UDP socket error — shutdown
            shutdown.store(true, .release);
            return;
        };

        // Build SOCKS5 UDP datagram header
        // RSV(2) + FRAG(1) + ATYP(1) + IPv4(4) + PORT(2) = 10 bytes
        buf[0] = 0x00; // RSV high byte
        buf[1] = 0x00; // RSV low byte
        buf[2] = 0x00; // FRAG = no fragmentation
        buf[3] = SOCKS_ATYP_IPV4;
        @memcpy(buf[4..8], &result.from.ip);
        std.mem.writeInt(u16, buf[8..10], result.from.port, .big);

        const dgram = buf[0 .. 10 + result.n];

        // Write 2-byte BE length prefix
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @truncate(dgram.len), .big);

        // Write to TCP (best-effort; if TCP is closed, shutdown)
        const w1 = tcp.sockWrite(tcp_fd, &len_buf, len_buf.len);
        if (tcp.sockIsError(w1)) {
            shutdown.store(true, .release);
            return;
        }
        const w2 = tcp.sockWrite(tcp_fd, dgram.ptr, dgram.len);
        if (tcp.sockIsError(w2)) {
            shutdown.store(true, .release);
            return;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// BIND Handler (RFC 1928 Section 5)
// ═══════════════════════════════════════════════════════════════════════════

/// SOCKS5 BIND handler. Creates a TCP listener, replies with BND.ADDR:BND.PORT,
/// waits for inbound connection (60s timeout), relays client↔accepted.
/// Does not return.
pub fn socks5Bind(io: std.Io, client_fd: tcp.socket_t) void {
    // Create TCP listener on random port
    var listener = tcp.TcpListener.init(io, 0) catch {
        replyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };
    defer listener.deinit();

    // First reply: BND.ADDR=0.0.0.0, BND.PORT=listener's port
    reply(client_fd, SOCKS_REP_OK, [_]u8{ 0, 0, 0, 0 }, listener.port);

    // Wait for inbound connection with 60s timeout
    const accepted = tcp.sockAcceptTimeout(listener.listener_fd, 60_000) catch {
        // Timeout or error — send rejection as second reply
        replyRejected(client_fd);
        tcp.sockClose(client_fd);
        return;
    };

    // Second reply: BND.ADDR=peer IP, BND.PORT=peer port
    reply(client_fd, SOCKS_REP_OK, accepted.addr.ip, accepted.addr.port);

    // Relay between client and accepted connection
    relay(io, client_fd, accepted.fd);
    tcp.sockClose(client_fd);
    tcp.sockClose(accepted.fd);
}

/// Thread wrapper: socks5Bind with connection limit release.
pub fn socks5BindWithLimit(io: std.Io, fd: tcp.socket_t, limit: *tcp.ConnLimit) void {
    defer limit.release();
    socks5Bind(io, fd);
}

/// Thread wrapper: udpAssociate with connection limit release.
pub fn udpAssociateWithLimit(io: std.Io, fd: tcp.socket_t, limit: *tcp.ConnLimit) void {
    defer limit.release();
    udpAssociate(io, fd);
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
    try sendRequest(fd, SOCKS_CMD_CONNECT, SOCKS_ATYP_DOMAIN, guest_hostname, port);

    const rep = try readReply(fd);
    if (rep.rep != SOCKS_REP_OK) {
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

test "readRequestBuf parses BIND command" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=BIND, ATYP=DOMAIN, hostname="0.0.0.0", port=0
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_BIND,
                0x00, SOCKS_ATYP_DOMAIN,
                7, '0', '.', '0', '.', '0', '.', '0',
                0x00, 0x00,
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const req = try readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectEqual(SOCKS_CMD_BIND, req.cmd);
    try std.testing.expectEqual(SOCKS_ATYP_DOMAIN, req.atyp);
    try std.testing.expectEqualStrings("0.0.0.0", req.hostname);
}

test "readRequestBuf parses UDP_ASSOCIATE command" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=UDP_ASSOCIATE, ATYP=DOMAIN, hostname="client", port=0
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_UDP_ASSOCIATE,
                0x00, SOCKS_ATYP_DOMAIN,
                6, 'c', 'l', 'i', 'e', 'n', 't',
                0x00, 0x00,
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const req = try readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectEqual(SOCKS_CMD_UDP_ASSOCIATE, req.cmd);
    try std.testing.expectEqualStrings("client", req.hostname);
}

test "readRequestBuf parses IPv4 ATYP" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=CONNECT, ATYP=IPv4, addr=192.168.1.100, port=8080
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_IPV4,
                192, 168, 1, 100, // IPv4 = 192.168.1.100
                0x1F, 0x90, // PORT = 8080
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const req = try readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectEqual(SOCKS_ATYP_IPV4, req.atyp);
    try std.testing.expectEqualStrings("192.168.1.100", req.hostname);
    try std.testing.expectEqual(@as(u16, 8080), req.port);
}

test "readRequestBuf rejects unknown command" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Send bad CMD=0xFF (unknown command)
            const bad_hdr = [_]u8{ SOCKS_VER, 0xFF, 0x00, SOCKS_ATYP_DOMAIN };
            _ = tcp.sockWrite(fd, &bad_hdr, bad_hdr.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const result = readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectError(error.Socks5BadCommand, result);
}

test "readRequestBuf rejects IPv6 ATYP" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=CONNECT, ATYP=IPv6 (unsupported)
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_IPV6,
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const result = readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectError(error.Socks5AddressTypeNotSupported, result);
}

test "readRequestBuf rejects unknown ATYP" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=CONNECT, ATYP=0xFF (unknown)
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, 0xFF,
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
    const result = readRequestBuf(pair.a, buf[0..]);
    try std.testing.expectError(error.Socks5AddressTypeNotSupported, result);
}

test "parameterized reply with bind address" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Send reply with specific BND.ADDR=192.168.1.1 BND.PORT=9090
    reply(pair.a, SOCKS_REP_OK, [_]u8{ 192, 168, 1, 1 }, 9090);

    var resp: [10]u8 = [_]u8{0} ** 10;
    var off: usize = 0;
    while (off < 10) {
        const n = tcp.sockRead(pair.b, resp[off..].ptr, resp.len - off);
        if (n == 0) break;
        off += @intCast(n);
    }
    try std.testing.expectEqual(SOCKS_VER, resp[0]);
    try std.testing.expectEqual(SOCKS_REP_OK, resp[1]);
    try std.testing.expectEqual(@as(u8, 0x00), resp[2]); // RSV
    try std.testing.expectEqual(SOCKS_ATYP_IPV4, resp[3]);
    try std.testing.expectEqual(@as(u8, 192), resp[4]);
    try std.testing.expectEqual(@as(u8, 168), resp[5]);
    try std.testing.expectEqual(@as(u8, 1), resp[6]);
    try std.testing.expectEqual(@as(u8, 1), resp[7]);

    const bnd_port = std.mem.readInt(u16, resp[8..10], .big);
    try std.testing.expectEqual(@as(u16, 9090), bnd_port);
}

test "accept returns cmd and atyp fields" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

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

            // Request: CMD=CONNECT, ATYP=DOMAIN, hostname="test", port=2121
            const req = [_]u8{
                SOCKS_VER, SOCKS_CMD_CONNECT,
                0x00, SOCKS_ATYP_DOMAIN,
                4, 't', 'e', 's', 't',
                0x08, 0x49,
            };
            _ = tcp.sockWrite(fd, &req, req.len);
        }
    }.run, .{pair.b});
    defer client_thread.join();

    const request = try accept(pair.a, std.testing.allocator);
    defer std.testing.allocator.free(request.hostname);
    try std.testing.expectEqual(SOCKS_CMD_CONNECT, request.cmd);
    try std.testing.expectEqual(SOCKS_ATYP_DOMAIN, request.atyp);
    try std.testing.expectEqualStrings("test", request.hostname);
    try std.testing.expectEqual(@as(u16, 2121), request.port);
}

test "readReply round-trip" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Send a reply with specific BND.ADDR and BND.PORT
    reply(pair.a, SOCKS_REP_OK, [_]u8{ 10, 0, 0, 1 }, 5353);

    const rep = try readReply(pair.b);
    try std.testing.expectEqual(SOCKS_REP_OK, rep.rep);
    try std.testing.expectEqual(@as(u8, 10), rep.bnd_addr[0]);
    try std.testing.expectEqual(@as(u8, 1), rep.bnd_addr[3]);
    try std.testing.expectEqual(@as(u16, 5353), rep.bnd_port);
}

test "sendRequest with BIND command" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    // Server thread: accept auth + read request
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            var buf: [tcp.MAX_HOSTNAME]u8 = undefined;
            const req = readRequestBuf(fd, buf[0..]) catch return;
            // Verify BIND command was received
            std.debug.assert(req.cmd == SOCKS_CMD_BIND);
            std.debug.assert(std.mem.eql(u8, req.hostname, "0.0.0.0"));
        }
    }.run, .{pair.a});
    defer server_thread.join();

    try sendRequest(pair.b, SOCKS_CMD_BIND, SOCKS_ATYP_DOMAIN, "0.0.0.0", 0);
}

test "createUdpSocket and getBoundPort" {
    const udp_fd = try tcp.createUdpSocket();
    defer tcp.sockClose(udp_fd);
    const port = try tcp.getBoundPort(udp_fd);
    // OS-assigned port should be non-zero
    try std.testing.expect(port > 0);
}

test "socks5Bind accept timeout returns error" {
    // Create a TCP listener that no one connects to
    var t: std.Io.Threaded = .init_single_threaded;
    var listener = try tcp.TcpListener.init(t.io(), 0);
    defer listener.deinit();

    // sockAcceptTimeout should timeout (50ms, short for testing)
    const result = tcp.sockAcceptTimeout(listener.listener_fd, 50);
    try std.testing.expectError(error.WouldBlock, result);
}

test "parameterized reply with SOCKS_REP_COMMAND_NOT_SUPPORTED" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    reply(pair.a, SOCKS_REP_COMMAND_NOT_SUPPORTED, [_]u8{ 0, 0, 0, 0 }, 0);

    const rep = try readReply(pair.b);
    try std.testing.expectEqual(SOCKS_REP_COMMAND_NOT_SUPPORTED, rep.rep);
}
