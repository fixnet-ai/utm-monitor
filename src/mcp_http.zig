//! Minimal HTTP/1.1 handler for MCP JSON-RPC transport.
//!
//! Single-request-per-connection model (no keep-alive) for POST: reads the HTTP
//! request, extracts the JSON-RPC body, calls mcp.processRequest(), writes the
//! HTTP response, and closes the socket. Runs on the thread pool via
//! spawnBlocking.
//!
//! GET is answered with an SSE (Server-Sent Events) stream held open — the
//! streamable-HTTP client's GET probe (Claude Code ≥ v2.1.84) requires
//! `Content-Type: text/event-stream` and rejects 405 with "Failed to connect".
//!
//! First byte of the request line is consumed by the caller (host.zig peek)
//! for protocol dispatch. This module reads the remainder.

const std = @import("std");
const tcp = @import("tcp.zig");
const host_mod = @import("host.zig");
const protocol = @import("protocol.zig");
const mcp = @import("mcp.zig");
const mcp_handler = @import("mcp_handler.zig");

/// Max HTTP request body size (matches mcp.zig's stdin buffer).
const MAX_BODY_SIZE: usize = 65536;

/// Max combined request line + headers size.
const MAX_HEADERS_SIZE: usize = 8192;

/// MCP 长任务 progress 心跳间隔（秒级保活，避免客户端 per-request 超时）。
const HEARTBEAT_MS: u32 = 5000;

/// 心跳线程 sleep 分片——done 置位后 join 延迟 ≤ 此值，不给命令响应加尾延迟。
const HEARTBEAT_SLICE_MS: u32 = 50;

/// HTTP 客户端断连检测器（exec 取消传播，mcp_handler.ClientWatch 实现）。
/// 等响应的 HTTP 客户端不会半关闭（无 SHUT_WR），单请求连接也不会多发 —
/// 可读事件（EOF/错误/垃圾字节）即客户端已断开。poll 按 50ms 分片，
/// done 置位后快速返回（join 延迟 ≤50ms，不给命令响应加尾延迟）。
const HttpProbe = struct {
    fd: tcp.socket_t,

    fn check(ctx: *anyopaque, done: *const std.atomic.Value(bool)) bool {
        const self: *HttpProbe = @ptrCast(@alignCast(ctx));
        while (!done.load(.acquire)) {
            if (!tcp.sockPollReadable(self.fd, 50)) continue;
            var b: [1]u8 = undefined;
            _ = tcp.sockRead(self.fd, @as([*]u8, @ptrCast(&b)), 1);
            return true; // EOF(0)/错误/意外数据 — 均判客户端断开
        }
        return false;
    }
};

/// MCP progress 心跳线程：长任务（exec/download/upload/sshpass）期间周期发
/// `notifications/progress` SSE 事件保活。progress 值单调递增（MCP 要求 MUST
/// increase），total 省略（长任务总时长未知）。分片 sleep 保证 done 置位后
/// join 快速返回（≤HEARTBEAT_SLICE_MS），不给最终响应加尾延迟。
const Heartbeat = struct {
    fd: tcp.socket_t,
    token: []const u8,
    done: *const std.atomic.Value(bool),

    fn run(self: *Heartbeat) void {
        var elapsed_ms: u32 = 0;
        var counter: u32 = 0;
        while (!self.done.load(.acquire)) {
            tcp.threadSleepMs(HEARTBEAT_SLICE_MS);
            elapsed_ms += HEARTBEAT_SLICE_MS;
            if (elapsed_ms >= HEARTBEAT_MS) {
                elapsed_ms = 0;
                counter += 1;
                writeProgressEvent(self.fd, self.token, counter, counter * HEARTBEAT_MS / 1000);
            }
        }
    }
};

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
            error.GetRequest => writeSseStream(fd),
            error.MethodNotAllowed => writeHttpResponse(fd, 405, "Method Not Allowed", "Only POST is supported"),
            error.LengthRequired => writeHttpResponse(fd, 411, "Length Required", "Content-Length header required"),
            error.PayloadTooLarge => writeHttpResponse(fd, 413, "Payload Too Large", "Request body exceeds 64KB limit"),
            error.BadRequest => writeHttpResponse(fd, 400, "Bad Request", "Malformed HTTP request"),
            else => writeHttpResponse(fd, 500, "Internal Server Error", "Failed to read request"),
        }
        return;
    };
    defer gpa.free(body);

    // Build McpContext with the Host daemon's state + client disconnect
    // watcher (exec cancellation: agent abort → kill command on guest)
    var probe = HttpProbe{ .fd = fd };
    const ctx = mcp.McpContext{
        .io = io,
        .gpa = gpa,
        .port = protocol.DEFAULT_PORT,
        .state = state,
        .mesh_ptr = mesh_ptr,
        .hostname = hostname,
        .client_watch = mcp_handler.ClientWatch{ .ctx = &probe, .checkFn = HttpProbe.check },
    };

    // 提取 progressToken（客户端 opt-in 的 progress 能力；无则 null）
    const token = extractProgressToken(gpa, body);
    defer if (token) |t| gpa.free(t);

    // 写 SSE 响应头 + priming 注释——首字节立即到达让客户端进入流式模式，
    // 长任务期间不再因"无字节"撞 per-request 超时（zigtester json_response=False 同款）
    writeSsePostHead(fd);

    // spawn 心跳线程（有 token 才发 progress 通知；无 token 仅靠 SSE 流保活）
    var done = std.atomic.Value(bool).init(false);
    var hb = Heartbeat{ .fd = fd, .token = token orelse "", .done = &done };
    var hb_thread: ?std.Thread = null;
    if (token != null) {
        hb_thread = std.Thread.spawn(.{}, Heartbeat.run, .{&hb}) catch null;
    }

    // Call MCP JSON-RPC processor directly (no IPC, no serialization)
    const response_json = mcp.processRequest(ctx, body) catch |err| {
        std.log.err("[mcp-http] processRequest failed: {}", .{err});
        done.store(true, .release);
        if (hb_thread) |t| t.join();
        var err_buf: [512]u8 = undefined;
        const err_json = std.fmt.bufPrint(&err_buf,
            "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-32603,\"message\":\"{s}\"}},\"id\":null}}",
            .{@errorName(err)}) catch "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}";
        writeSseMessageEvent(fd, err_json);
        return;
    };
    defer gpa.free(response_json);

    // 停止心跳，写最终 JSON-RPC 响应事件（通知类空响应只发 SSE 头，连接随后关闭）
    done.store(true, .release);
    if (hb_thread) |t| t.join();
    if (response_json.len > 0) {
        writeSseMessageEvent(fd, response_json);
    }
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

    // Parse method — POST carries the JSON-RPC body; GET opens an SSE stream
    // (streamable-HTTP client probe); any other method is rejected.
    const first_space = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadRequest;
    const method = request_line[0..first_space];
    if (std.ascii.eqlIgnoreCase(method, "GET")) {
        return error.GetRequest;
    }
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
            // Trim surrounding whitespace (RFC 7230 OWS)
            while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
                value = value[1..];
            }
            while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) {
                value = value[0 .. value.len - 1];
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

/// Write the SSE response head (status line + headers + initial `endpoint`
/// event) for a GET probe. The `endpoint` event is optional per the MCP
/// streamable-HTTP spec but flushes the response so the client sees the stream
/// is alive immediately.
fn writeSseHead(fd: tcp.socket_t) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nevent: endpoint\ndata: http://127.0.0.1:{d}/\n\n",
        .{protocol.DEFAULT_PORT},
    ) catch "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n";
    var written: usize = 0;
    while (written < head.len) {
        const n = tcp.sockWrite(fd, head[written..].ptr, head.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

/// Answer a GET with an SSE stream and hold it open until the client
/// disconnects (EOF/error). This GET is the server→client notification channel
/// in streamable-HTTP MCP; closing early would make the client retry/flag it.
fn writeSseStream(fd: tcp.socket_t) void {
    writeSseHead(fd);

    while (true) {
        if (!tcp.sockPollReadable(fd, 1000)) continue;
        var b: [1]u8 = undefined;
        const n = tcp.sockRead(fd, @as([*]u8, @ptrCast(&b)), 1);
        if (tcp.sockIsError(n) or n == 0) return;
    }
}

/// 写 POST 的 SSE 响应头 + priming 注释。priming 注释（`: connected`）是合法
/// SSE 字节，立即 flush 让客户端首字节秒到、进入流式模式——这是避免 per-request
/// 超时的关键（zigtester `json_response=False` 同款）。
fn writeSsePostHead(fd: tcp.socket_t) void {
    const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n";
    _ = tcp.sockWrite(fd, head.ptr, head.len);
}

/// 写一个 SSE `message` 事件（JSON-RPC 响应单行，无多行 data 问题）。
fn writeSseMessageEvent(fd: tcp.socket_t, data: []const u8) void {
    const head = "event: message\ndata: ";
    var written: usize = 0;
    while (written < head.len) {
        const n = tcp.sockWrite(fd, head[written..].ptr, head.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < data.len) {
        const n = tcp.sockWrite(fd, data[written..].ptr, data.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    const tail = "\n\n";
    _ = tcp.sockWrite(fd, tail.ptr, tail.len);
}

/// 写一个 `notifications/progress` SSE 事件。progress 单调递增，total 省略。
fn writeProgressEvent(fd: tcp.socket_t, token: []const u8, progress: u32, elapsed_s: u32) void {
    var buf: [512]u8 = undefined;
    const data = std.fmt.bufPrint(&buf,
        "event: message\ndata: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{{\"progressToken\":\"{s}\",\"progress\":{d},\"message\":\"long-running task ({d}s elapsed)\"}}}}\n\n",
        .{ token, progress, elapsed_s },
    ) catch return;
    _ = tcp.sockWrite(fd, data.ptr, data.len);
}

/// 从 JSON-RPC 请求提取 progressToken（客户端 opt-in 的 progress 能力）。
/// 标准位置 `params._meta.progressToken`，fallback 顶层 `_meta.progressToken`。
/// 返回 gpa 分配的副本（parsed.deinit 会释放原串）；无则 null。
fn extractProgressToken(gpa: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (protocol.jsonGetNestedObject(obj, "params")) |params| {
        if (protocol.jsonGetNestedObject(params, "_meta")) |meta| {
            if (protocol.jsonGetString(meta, "progressToken")) |tok| {
                return gpa.dupe(u8, tok) catch null;
            }
        }
    }
    if (protocol.jsonGetNestedObject(obj, "_meta")) |meta| {
        if (protocol.jsonGetString(meta, "progressToken")) |tok| {
            return gpa.dupe(u8, tok) catch null;
        }
    }
    return null;
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

test "HttpProbe detects peer close and honors done" {
    const pair = try tcp.makePair();
    defer tcp.sockClose(pair.a);
    var done = std.atomic.Value(bool).init(false);

    // 对端关闭 → poll readable(EOF) → 判断开
    tcp.sockShutdown(pair.b, 2);
    tcp.sockClose(pair.b);
    var probe = HttpProbe{ .fd = pair.a };
    try std.testing.expect(HttpProbe.check(&probe, &done));

    // done 已置位 → 不进入长等待，快速返回 false
    const pair2 = try tcp.makePair();
    defer tcp.sockClose(pair2.a);
    defer tcp.sockClose(pair2.b);
    done.store(true, .release);
    var probe2 = HttpProbe{ .fd = pair2.a };
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const t0 = std.Io.Timestamp.now(io, .awake);
    try std.testing.expect(!HttpProbe.check(&probe2, &done));
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - t0.nanoseconds;
    try std.testing.expect(elapsed < 500_000_000); // <500ms（join 快速返回的保证）
}

test "writeSseHead emits SSE stream response for GET" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            writeSseHead(fd);
        }
    }.run, .{pair.b});
    defer writer.join();

    // Read the SSE head (status line + headers + endpoint event, ends in \n\n).
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = tcp.sockRead(pair.a, buf[len..].ptr, buf.len - len);
        try std.testing.expect(n > 0);
        len += @intCast(n);
        if (len >= 2 and buf[len - 2] == '\n' and buf[len - 1] == '\n') break;
    }
    try std.testing.expect(len >= 2);

    var expected_buf: [256]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nevent: endpoint\ndata: http://127.0.0.1:{d}/\n\n",
        .{protocol.DEFAULT_PORT},
    ) catch unreachable;
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "extractProgressToken: params._meta" {
    const gpa = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"exec\",\"arguments\":{},\"_meta\":{\"progressToken\":\"tok-123\"}}}";
    const token = extractProgressToken(gpa, body);
    defer if (token) |t| gpa.free(t);
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("tok-123", token.?);
}

test "extractProgressToken: top-level _meta fallback" {
    const gpa = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"exec\",\"arguments\":{}},\"_meta\":{\"progressToken\":\"top-456\"}}";
    const token = extractProgressToken(gpa, body);
    defer if (token) |t| gpa.free(t);
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("top-456", token.?);
}

test "extractProgressToken: absent returns null" {
    const gpa = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"exec\",\"arguments\":{}}}";
    const token = extractProgressToken(gpa, body);
    try std.testing.expect(token == null);
}

test "extractProgressToken: invalid json returns null" {
    const gpa = std.testing.allocator;
    const token = extractProgressToken(gpa, "not-json");
    try std.testing.expect(token == null);
}

test "writeSseMessageEvent emits message event" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            writeSseMessageEvent(fd, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
        }
    }.run, .{pair.b});
    defer writer.join();
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = tcp.sockRead(pair.a, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        if (len >= 2 and buf[len - 2] == '\n' and buf[len - 1] == '\n') break;
    }
    const expected = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n";
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "writeProgressEvent emits progress notification" {
    const pair = try tcp.makePair();
    defer {
        tcp.sockClose(pair.a);
        tcp.sockClose(pair.b);
    }
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: tcp.socket_t) void {
            writeProgressEvent(fd, "tok-1", 3, 15);
        }
    }.run, .{pair.b});
    defer writer.join();
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = tcp.sockRead(pair.a, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        if (len >= 2 and buf[len - 2] == '\n' and buf[len - 1] == '\n') break;
    }
    const expected = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"tok-1\",\"progress\":3,\"message\":\"long-running task (15s elapsed)\"}}\n\n";
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}
