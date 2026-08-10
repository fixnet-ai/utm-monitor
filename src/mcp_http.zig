//! Minimal HTTP/1.1 POST parser for MCP JSON-RPC transport.
//!
//! Single-request-per-connection model (no keep-alive). Reads the HTTP request,
//! extracts the JSON-RPC body, calls mcp.processRequest(), writes the HTTP
//! response, and closes the socket. Runs on the thread pool via spawnBlocking.
//!
//! First byte of the request line is consumed by the caller (host.zig peek)
//! for protocol dispatch. This module reads the remainder.

const std = @import("std");
const tcp = @import("tcp.zig");
const host_mod = @import("host.zig");
const protocol = @import("protocol.zig");
const mcp = @import("mcp.zig");

/// Max HTTP request body size (matches mcp.zig's stdin buffer).
const MAX_BODY_SIZE: usize = 65536;

/// Max combined request line + headers size.
const MAX_HEADERS_SIZE: usize = 8192;

/// Handle an HTTP MCP request on a raw TCP socket.
/// `first_byte` is the already-peeked first character of the HTTP method
/// (e.g., 'P' for POST, 'G' for GET). Reads the rest of the request,
/// dispatches to mcp.processRequest(), and writes the HTTP response.
/// Called from spawnBlocking (thread pool) — should not block the main loop.
pub fn handleHttpMcp(
    io: std.Io,
    gpa: std.mem.Allocator,
    fd: tcp.socket_t,
    first_byte: u8,
    state: *host_mod.GuestTable,
    mesh_ptr: ?*anyopaque,
    hostname: []const u8,
) void {
    defer tcp.sockClose(fd);

    // Read the rest of the request line + headers + body
    const body = readHttpRequestBody(gpa, fd, first_byte) catch |err| {
        switch (err) {
            error.MethodNotAllowed => writeHttpResponse(fd, 405, "Method Not Allowed", "Only POST is supported"),
            error.LengthRequired => writeHttpResponse(fd, 411, "Length Required", "Content-Length header required"),
            error.PayloadTooLarge => writeHttpResponse(fd, 413, "Payload Too Large", "Request body exceeds 64KB limit"),
            error.BadRequest => writeHttpResponse(fd, 400, "Bad Request", "Malformed HTTP request"),
            else => writeHttpResponse(fd, 500, "Internal Server Error", "Failed to read request"),
        }
        return;
    };
    defer gpa.free(body);

    // Build McpContext with the Host daemon's state
    const ctx = mcp.McpContext{
        .io = io,
        .gpa = gpa,
        .port = protocol.DEFAULT_PORT,
        .state = state,
        .mesh_ptr = mesh_ptr,
        .hostname = hostname,
    };

    // Call MCP JSON-RPC processor directly (no IPC, no serialization)
    const response_json = mcp.processRequest(ctx, body) catch |err| {
        std.log.err("[mcp-http] processRequest failed: {}", .{err});
        writeHttpResponse(fd, 500, "Internal Server Error", "JSON-RPC processing failed");
        return;
    };
    defer gpa.free(response_json);

    // Write HTTP 200 response with JSON body
    writeHttpResponse(fd, 200, "OK", response_json);
}

// ═══════════════════════════════════════════════════════════════════════════
// Socket byte I/O
// ═══════════════════════════════════════════════════════════════════════════

/// Read a single byte from the socket. Returns error on EOF or read failure.
fn sockReadByte(fd: tcp.socket_t) !u8 {
    var b: u8 = undefined;
    const n = tcp.sockRead(fd, @as([*]u8, @ptrCast(&b)), 1);
    if (tcp.sockIsError(n) or n == 0) return error.BadRequest;
    return b;
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP parsing
// ═══════════════════════════════════════════════════════════════════════════

/// Read the full HTTP request body from a POST request.
/// `first_byte` is the first character of the HTTP method (already peeked by caller).
fn readHttpRequestBody(gpa: std.mem.Allocator, fd: tcp.socket_t, first_byte: u8) ![]const u8 {
    // Read the rest of the request line: "<ethod_rest> SP PATH SP HTTP/1.1\r\n"
    var line_buf: [256]u8 = undefined;
    line_buf[0] = first_byte;
    var line_len: usize = 1;

    // Read until \r\n
    while (line_len < line_buf.len) {
        const b = try sockReadByte(fd);
        line_buf[line_len] = b;
        line_len += 1;
        if (line_len >= 2 and line_buf[line_len - 2] == '\r' and line_buf[line_len - 1] == '\n') {
            break;
        }
    }
    if (line_len >= line_buf.len) return error.BadRequest;

    const request_line = line_buf[0 .. line_len - 2]; // strip \r\n

    // Parse method — must be POST
    const first_space = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadRequest;
    const method = request_line[0..first_space];
    if (!std.ascii.eqlIgnoreCase(method, "POST")) {
        return error.MethodNotAllowed;
    }

    // Read headers until \r\n\r\n
    var headers_buf: [MAX_HEADERS_SIZE]u8 = undefined;
    var headers_len: usize = 0;
    while (headers_len + 4 <= headers_buf.len) {
        const b = try sockReadByte(fd);
        headers_buf[headers_len] = b;
        headers_len += 1;
        // Check for \r\n\r\n (end of headers)
        if (headers_len >= 4 and
            headers_buf[headers_len - 4] == '\r' and
            headers_buf[headers_len - 3] == '\n' and
            headers_buf[headers_len - 2] == '\r' and
            headers_buf[headers_len - 1] == '\n')
        {
            break;
        }
    }
    if (headers_len >= headers_buf.len) return error.BadRequest;

    const headers_str = headers_buf[0 .. headers_len - 2]; // strip trailing \r\n

    // Parse Content-Length
    const content_length = parseContentLength(headers_str) orelse return error.LengthRequired;
    if (content_length > MAX_BODY_SIZE) return error.PayloadTooLarge;
    if (content_length == 0) return &[0]u8{};

    // Read body (exactly content_length bytes)
    const body = try gpa.alloc(u8, content_length);
    errdefer gpa.free(body);
    var off: usize = 0;
    while (off < content_length) {
        const n = tcp.sockRead(fd, body[off..].ptr, content_length - off);
        if (tcp.sockIsError(n)) {
            gpa.free(body);
            return error.BadRequest;
        }
        if (n == 0) {
            gpa.free(body);
            return error.BadRequest;
        }
        off += @intCast(n);
    }

    return body;
}

/// Parse Content-Length value from HTTP headers. Returns null if not found or invalid.
fn parseContentLength(headers: []const u8) ?usize {
    var remaining = headers;
    while (remaining.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, remaining, '\r') orelse remaining.len;
        const line = remaining[0..line_end];

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            remaining = remaining[@min(line_end + 2, remaining.len)..];
            continue;
        };

        const key = line[0..colon];
        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            var value = line[colon + 1 ..];
            // Trim leading whitespace
            while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
                value = value[1..];
            }
            return std.fmt.parseUnsigned(usize, value, 10) catch null;
        }

        remaining = remaining[@min(line_end + 2, remaining.len)..];
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP response writing
// ═══════════════════════════════════════════════════════════════════════════

/// Write a simple HTTP response. On success (200), body is the JSON-RPC response.
/// On error, body is a human-readable message (wrapped as JSON-RPC error).
fn writeHttpResponse(fd: tcp.socket_t, status_code: u16, status_text: []const u8, body: []const u8) void {
    // Build response body: JSON-RPC error for non-200, raw JSON for 200
    var body_buf: [512]u8 = undefined;
    const response_body: []const u8 = if (status_code == 200)
        body
    else blk: {
        break :blk std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-32603,\"message\":\"HTTP {d} {s}: {s}\"}},\"id\":null}}",
            .{ status_code, status_text, body },
        ) catch {
            // Fallback: minimal error JSON
            break :blk "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}";
        };
    };

    // Build HTTP status line + headers
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status_code, status_text, response_body.len },
    ) catch {
        const fallback = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n";
        _ = tcp.sockWrite(fd, fallback.ptr, fallback.len);
        return;
    };

    // Write header
    var written: usize = 0;
    while (written < header.len) {
        const n = tcp.sockWrite(fd, header[written..].ptr, header.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }

    // Write body
    written = 0;
    while (written < response_body.len) {
        const n = tcp.sockWrite(fd, response_body[written..].ptr, response_body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parseContentLength: normal" {
    const headers = "Host: localhost\r\nContent-Length: 123\r\nContent-Type: application/json\r\n";
    const len = parseContentLength(headers);
    try std.testing.expectEqual(@as(usize, 123), len.?);
}

test "parseContentLength: with whitespace" {
    const headers = "Content-Length:  456 \r\n";
    const len = parseContentLength(headers);
    try std.testing.expectEqual(@as(usize, 456), len.?);
}

test "parseContentLength: case insensitive" {
    const headers = "content-length: 789\r\n";
    const len = parseContentLength(headers);
    try std.testing.expectEqual(@as(usize, 789), len.?);
}

test "parseContentLength: not found" {
    const headers = "Host: localhost\r\nContent-Type: application/json\r\n";
    const len = parseContentLength(headers);
    try std.testing.expectEqual(@as(?usize, null), len);
}

test "parseContentLength: empty" {
    const headers = "";
    const len = parseContentLength(headers);
    try std.testing.expectEqual(@as(?usize, null), len);
}
