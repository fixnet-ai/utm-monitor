//! Host HTTP endpoint handlers.
//!
//! Plugs into httpd.Router to provide:
//!   POST /exec       — Send command to guest via KCP tunnel (pty, wait for MDELIM)
//!   POST /kick       — Request guest tunnel close
//!   POST /upload     — Upload file to guest via KCP tunnel
//!   POST /download   — Download file from guest via KCP tunnel
//!   GET  /bin/<file> — Serve static binaries
//!   GET  /           — Simple HTML status page
//!   POST /mcp        — MCP JSON-RPC (delegates to mcp.zig)
//!
//! Guest discovery is now via mesh LSA — /announce and /ws are removed.
//! All guest communication goes through KCP tunnel (tunproto.zig).
//!
//! All handlers receive (allocator, HostState, Request, body).

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const httpd = @import("httpd.zig");
const protocol = @import("protocol.zig");
const hosts_file = @import("hosts_file.zig");
const mcp = @import("mcp.zig");
const tunproto = @import("tunproto.zig");
const tunnel_mod = @import("tunnel.zig");

/// Read the request body as raw bytes. Caller owns the returned buffer.
fn readBody(allocator: std.mem.Allocator, request: *http.Server.Request) ![]const u8 {
    const content_length = request.head.content_length orelse return error.MissingContentLength;
    if (content_length == 0) return error.EmptyBody;
    if (content_length > 10 * 1024 * 1024) return error.BodyTooLarge;

    const buf = try allocator.alloc(u8, @intCast(content_length));
    errdefer allocator.free(buf);

    var body_reader = request.readerExpectNone(buf);
    var writer: std.Io.Writer = .fixed(buf);
    try body_reader.streamExact(&writer, @intCast(content_length));
    return buf;
}

/// Read the request body as raw bytes with custom size limit.
fn readRawBody(allocator: std.mem.Allocator, request: *http.Server.Request, max_size: usize) ![]const u8 {
    const content_length = request.head.content_length orelse return error.MissingContentLength;
    if (content_length == 0) return error.EmptyBody;
    if (content_length > max_size) return error.BodyTooLarge;

    const buf = try allocator.alloc(u8, @intCast(content_length));
    errdefer allocator.free(buf);

    var body_reader = request.readerExpectNone(buf);
    var writer: std.Io.Writer = .fixed(buf);
    try body_reader.streamExact(&writer, @intCast(content_length));
    return buf;
}

/// Get a request header value by name (case-insensitive). Returns null if not found.
fn getRequestHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            return h.value;
        }
    }
    return null;
}

/// Respond with a JSON body and status 200.
fn respondJson(request: *http.Server.Request, json: []const u8) !void {
    try request.respond(json, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
}

/// Respond with a simple text error.
fn respondError(request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    try request.respond(message, .{
        .status = status,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /exec — Send command to guest via pty, stream output back
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleExec(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const body_str = readBody(allocator, request) catch |err| {
        std.log.err("[exec] readBody failed: {}", .{err});
        try respondError(request, .bad_request, "Missing body");
        return;
    };
    defer allocator.free(body_str);

    const parsed = httpd.parseJson(allocator, body_str) catch {
        try respondError(request, .bad_request, "Invalid JSON");
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try respondError(request, .bad_request, "Expected JSON object");
            return;
        },
    };

    const vm = httpd.jsonGetString(obj, "vm") orelse {
        try respondError(request, .bad_request, "Missing 'vm' field");
        return;
    };
    const command = httpd.jsonGetString(obj, "command") orelse {
        try respondError(request, .bad_request, "Missing 'command' field");
        return;
    };

    std.log.info("[exec] cmd for {s}: {s}", .{ vm, command });

    // Check guest exists and get shell type
    const guest_shell = blk: {
        state.mutex.lock(state.io.?) catch {};
        defer state.mutex.unlock(state.io.?);
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, vm)) {
                break :blk try allocator.dupe(u8, g.shell);
            }
        }
        std.log.err("[exec] GuestNotFound: vm='{s}'", .{vm});
        try respondError(request, .not_found, "GuestNotFound");
        return;
    };
    defer allocator.free(guest_shell);

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "exec_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    // Build pty_input frame with shell-appropriate marker
    const cmd_with_marker = try httpd.buildCmdWithMarker(allocator, guest_shell, command);
    defer allocator.free(cmd_with_marker);

    const frame = try tunproto.buildPtyExecInput(allocator, cmd_id, cmd_with_marker);
    defer allocator.free(frame);

    // Create operation state and send via KCP tunnel
    try state.createOpState(cmd_id);

    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };
    _ = tun.send(frame) catch |err| {
        std.log.err("[exec] tunnel send failed for {s}: {}", .{ vm, err });
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    std.log.info("[exec] Sent pty cmd {s} for {s}", .{ cmd_id, vm });

    // Stream response using chunked transfer encoding
    var stream_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
        },
    });
    // Must flush immediately — BodyWriter docs: "The header is not guaranteed
    // to be sent until BodyWriter.flush or BodyWriter.end is called."
    body_writer.flush() catch |err| {
        std.log.err("[exec] header flush failed for {s}: {}", .{ cmd_id, err });
        return;
    };
    // Track whether we called endChunked — defer fires end() only as fallback
    var chunked_ended = false;
    defer if (!chunked_ended) {
        body_writer.endChunked(.{}) catch {};
    };

    // Loop: write new output chunks as they arrive
    while (true) {
        // Check for new data under mutex
        const new_chunk = blk: {
            state.mutex.lock(state.io.?) catch {
                break :blk @as(?[]const u8, null);
            };
            defer state.mutex.unlock(state.io.?);

            const op = state.op_states.getPtr(cmd_id) orelse {
                break :blk @as(?[]const u8, null);
            };

            if (op.output.items.len > op.sent_pos) {
                const start = op.sent_pos;
                op.sent_pos = op.output.items.len;
                const data = allocator.dupe(u8, op.output.items[start..]) catch {
                    break :blk @as(?[]const u8, null);
                };
                break :blk data;
            }
            break :blk @as(?[]const u8, null);
        };

        if (new_chunk) |chunk| {
            defer allocator.free(chunk);
            body_writer.writer.writeAll(chunk) catch |err| {
                std.log.err("[exec] body write failed for {s}: {}", .{ cmd_id, err });
                return;
            };
            // writer.flush() encodes the chunk → http_protocol_output
            body_writer.writer.flush() catch |err| {
                std.log.err("[exec] writer flush failed for {s}: {}", .{ cmd_id, err });
                return;
            };
            // body_writer.flush() sends http_protocol_output → network
            body_writer.flush() catch |err| {
                std.log.err("[exec] body flush failed for {s}: {}", .{ cmd_id, err });
                return;
            };
        }

        var done_and_exit: ?i32 = blk: {
            state.mutex.lock(state.io.?) catch {
                break :blk @as(?i32, null);
            };
            defer state.mutex.unlock(state.io.?);

            const op = state.op_states.getPtr(cmd_id) orelse {
                break :blk @as(?i32, null);
            };
            if (op.done) {
                break :blk op.exit_code;
            }
            break :blk @as(?i32, null);
        };

        if (done_and_exit) |exit_code| {
            // One last check: scanForMarker may have stripped the marker
            // after we last checked for data, leaving unsent data behind.
            const final_chunk = blk: {
                state.mutex.lock(state.io.?) catch break :blk @as(?[]const u8, null);
                defer state.mutex.unlock(state.io.?);

                const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?[]const u8, null);
                if (op.output.items.len > op.sent_pos) {
                    const start = op.sent_pos;
                    op.sent_pos = op.output.items.len;
                    const data = allocator.dupe(u8, op.output.items[start..]) catch break :blk @as(?[]const u8, null);
                    break :blk data;
                }
                break :blk @as(?[]const u8, null);
            };

            if (final_chunk) |chunk| {
                defer allocator.free(chunk);
                body_writer.writer.writeAll(chunk) catch |err| {
                    std.log.err("[exec] final write failed for {s}: {}", .{ cmd_id, err });
                    return;
                };
                body_writer.writer.flush() catch {};
                body_writer.flush() catch {};
            }

            // Write exit code as HTTP trailer
            var exit_buf: [32]u8 = undefined;
            const exit_str = std.fmt.bufPrint(&exit_buf, "{d}", .{exit_code}) catch "1";
            chunked_ended = true;
            body_writer.endChunked(.{ .trailers = &.{
                .{ .name = "x-exit-code", .value = exit_str },
            } }) catch |err| {
                std.log.err("[exec] endChunked failed for {s}: {}", .{ cmd_id, err });
            };
            // Clean up op_state
            state.cleanupOpState(cmd_id);
            return;
        }

        // Wait for next chunk (woken by WebSocket handler on each pty_output).
        // Reset-then-double-check avoids a TOCTOU race: if wake_event.set()
        // was called between our done-check above and reset(), the re-check
        // catches it so we don't block for the full timeout waiting for a
        // signal that already fired.
        state.wake_event.reset();
        const done2 = blk: {
            state.mutex.lock(state.io.?) catch break :blk @as(?i32, null);
            defer state.mutex.unlock(state.io.?);
            const op2 = state.op_states.getPtr(cmd_id) orelse break :blk @as(?i32, null);
            if (op2.done) break :blk op2.exit_code;
            break :blk @as(?i32, null);
        };
        if (done2) |ec| {
            done_and_exit = ec;
            continue; // will be handled at top of loop
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(3600), .clock = .awake } }) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /kick — Close a guest's WebSocket connection
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleKick(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const body_str = readBody(allocator, request) catch {
        try respondError(request, .bad_request, "Missing body");
        return;
    };
    defer allocator.free(body_str);

    const parsed = httpd.parseJson(allocator, body_str) catch {
        try respondError(request, .bad_request, "Invalid JSON");
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try respondError(request, .bad_request, "Expected JSON object");
            return;
        },
    };

    const vm = httpd.jsonGetString(obj, "vm") orelse {
        try respondError(request, .bad_request, "Missing 'vm' field");
        return;
    };

    std.log.info("[kick] Kicking guest {s}", .{vm});
    try state.requestClose(vm);
    try respondJson(request, "{\"ok\":true}");
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /upload — Upload file to guest (binary body, x-vm + x-path headers)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleUpload(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;

    const vm = getRequestHeader(request, "x-vm") orelse {
        try respondError(request, .bad_request, "Missing x-vm header");
        return;
    };
    const path = getRequestHeader(request, "x-path") orelse {
        try respondError(request, .bad_request, "Missing x-path header");
        return;
    };

    // Read raw binary body (50 MB max for file upload)
    const file_data = readRawBody(allocator, request, 50 * 1024 * 1024) catch {
        try respondError(request, .bad_request, "Missing body");
        return;
    };
    defer allocator.free(file_data);

    std.log.info("[upload] {s} -> {s} ({d} bytes)", .{ vm, path, file_data.len });

    // Check guest exists
    {
        state.mutex.lock(state.io.?) catch {};
        const guest_exists = state.containsGuest(vm);
        state.mutex.unlock(state.io.?);
        if (!guest_exists) {
            try respondError(request, .not_found, "GuestNotFound");
            return;
        }
    }

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "upload_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    const frame = try tunproto.buildUploadData(allocator, cmd_id, path, file_data);
    defer allocator.free(frame);

    try state.createOpState(cmd_id);

    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };
    _ = tun.send(frame) catch |err| {
        std.log.err("[upload] tunnel send failed for {s}: {}", .{ vm, err });
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Wait for result — woken by mesh handler thread via wake_event.
    // Reset-then-double-check avoids TOCTOU race between concurrent waiters
    // sharing the same wake_event.
    while (true) {
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);
            if (result.exit == 0) {
                try respondJson(request, "{\"ok\":true}");
            } else {
                try respondError(request, .internal_server_error, "UploadFailed");
            }
            return;
        }
        state.wake_event.reset();
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);
            if (result.exit == 0) {
                try respondJson(request, "{\"ok\":true}");
            } else {
                try respondError(request, .internal_server_error, "UploadFailed");
            }
            return;
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } }) catch |err| {
            std.log.err("[upload] wait timeout for {s}: {}", .{ cmd_id, err });
            try respondError(request, .gateway_timeout, "UploadTimeout");
            return;
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /download — Download file from guest (x-vm + x-path headers, streaming binary response)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleDownload(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;

    const vm = getRequestHeader(request, "x-vm") orelse {
        try respondError(request, .bad_request, "Missing x-vm header");
        return;
    };
    const path = getRequestHeader(request, "x-path") orelse {
        try respondError(request, .bad_request, "Missing x-path header");
        return;
    };

    std.log.info("[download] {s} from {s}", .{ path, vm });

    // Check guest exists
    {
        state.mutex.lock(state.io.?) catch {};
        const guest_exists = state.containsGuest(vm);
        state.mutex.unlock(state.io.?);
        if (!guest_exists) {
            try respondError(request, .not_found, "GuestNotFound");
            return;
        }
    }

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "download_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    const frame = try tunproto.buildDownloadCmd(allocator, cmd_id, path);
    defer allocator.free(frame);

    try state.createOpState(cmd_id);

    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };
    _ = tun.send(frame) catch |err| {
        std.log.err("[download] tunnel send failed for {s}: {}", .{ vm, err });
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Stream response via chunked encoding (same pattern as handleExec)
    var stream_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }},
        },
    });
    body_writer.flush() catch |err| {
        std.log.err("[download] header flush failed for {s}: {}", .{ cmd_id, err });
        return;
    };
    var chunked_ended = false;
    defer if (!chunked_ended) {
        body_writer.endChunked(.{}) catch {};
    };

    // Loop: write new output chunks as they arrive from guest
    while (true) {
        const new_chunk = blk: {
            state.mutex.lock(state.io.?) catch break :blk @as(?[]const u8, null);
            defer state.mutex.unlock(state.io.?);

            const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?[]const u8, null);

            if (op.output.items.len > op.sent_pos) {
                const start = op.sent_pos;
                op.sent_pos = op.output.items.len;
                const data = allocator.dupe(u8, op.output.items[start..]) catch break :blk @as(?[]const u8, null);
                break :blk data;
            }
            break :blk @as(?[]const u8, null);
        };

        if (new_chunk) |chunk| {
            defer allocator.free(chunk);
            body_writer.writer.writeAll(chunk) catch |err| {
                std.log.err("[download] write failed for {s}: {}", .{ cmd_id, err });
                return;
            };
            body_writer.writer.flush() catch |err| {
                std.log.err("[download] writer flush failed for {s}: {}", .{ cmd_id, err });
                return;
            };
            body_writer.flush() catch |err| {
                std.log.err("[download] body flush failed for {s}: {}", .{ cmd_id, err });
                return;
            };
        }

        var done_and_exit: ?i32 = blk: {
            state.mutex.lock(state.io.?) catch break :blk @as(?i32, null);
            defer state.mutex.unlock(state.io.?);

            const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?i32, null);
            if (op.done) break :blk op.exit_code;
            break :blk @as(?i32, null);
        };

        if (done_and_exit) |exit_code| {
            // Final check for remaining data
            const final_chunk = blk: {
                state.mutex.lock(state.io.?) catch break :blk @as(?[]const u8, null);
                defer state.mutex.unlock(state.io.?);

                const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(?[]const u8, null);
                if (op.output.items.len > op.sent_pos) {
                    const start = op.sent_pos;
                    op.sent_pos = op.output.items.len;
                    const data = allocator.dupe(u8, op.output.items[start..]) catch break :blk @as(?[]const u8, null);
                    break :blk data;
                }
                break :blk @as(?[]const u8, null);
            };

            if (final_chunk) |chunk| {
                defer allocator.free(chunk);
                body_writer.writer.writeAll(chunk) catch {};
                body_writer.writer.flush() catch {};
                body_writer.flush() catch {};
            }

            var exit_buf: [32]u8 = undefined;
            const exit_str = std.fmt.bufPrint(&exit_buf, "{d}", .{exit_code}) catch "1";
            chunked_ended = true;
            body_writer.endChunked(.{ .trailers = &.{
                .{ .name = "x-exit-code", .value = exit_str },
            } }) catch |err| {
                std.log.err("[download] endChunked failed for {s}: {}", .{ cmd_id, err });
            };
            state.cleanupOpState(cmd_id);
            return;
        }

        // Wait for next chunk — same reset-then-double-check pattern as exec.
        state.wake_event.reset();
        const done2 = blk: {
            state.mutex.lock(state.io.?) catch break :blk @as(?i32, null);
            defer state.mutex.unlock(state.io.?);
            const op2 = state.op_states.getPtr(cmd_id) orelse break :blk @as(?i32, null);
            if (op2.done) break :blk op2.exit_code;
            break :blk @as(?i32, null);
        };
        if (done2) |ec| {
            done_and_exit = ec;
            continue; // will be handled at top of loop
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(3600), .clock = .awake } }) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// GET /bin/<file> — Serve static binaries
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleBin(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const target = request.head.target;
    if (target.len <= "/bin/".len) {
        try respondError(request, .not_found, "No filename");
        return;
    }
    const filename = target["/bin/".len..];

    // Security: only allow simple filenames (no directory traversal)
    for (filename) |c| {
        if (c == '/' or c == '\\') {
            try respondError(request, .forbidden, "Invalid filename");
            return;
        }
    }

    const io = state.io orelse {
        try respondError(request, .internal_server_error, "No I/O");
        return;
    };
    const dir = std.Io.Dir.cwd().openDir(io, state.serve_dir, .{}) catch {
        try respondError(request, .not_found, "Serve dir not found");
        return;
    };
    defer dir.close(io);

    const content = dir.readFileAlloc(io, filename, allocator, @enumFromInt(50 * 1024 * 1024)) catch {
        try respondError(request, .not_found, "File not found");
        return;
    };
    defer allocator.free(content);

    try request.respond(content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/octet-stream" },
            .{ .name = "Content-Disposition", .value = "attachment" },
        },
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// GET /version — Host version check (Guest auto-upgrade trigger)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleVersion(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = allocator;
    _ = state;
    _ = body;
    try request.respond(protocol.VERSION, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// GET /api/guests — JSON status (for CLI --status)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleApiGuests(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "[");

    state.mutex.lock(state.io.?) catch {};
    defer state.mutex.unlock(state.io.?);

    var first = true;
    for (state.guests.items) |g| {
        if (!first) try json.appendSlice(allocator, ",");
        first = false;
        try json.print(allocator,
            "{{\"hostname\":\"{s}\",\"target\":\"{s}\",\"ip\":\"{s}\",\"mac\":\"{s}\",\"version\":\"{s}\",\"shell\":\"{s}\"}}",
            .{ g.hostname, g.target, g.ip, g.mac, g.version, g.shell },
        );
    }
    try json.appendSlice(allocator, "]");

    try respondJson(request, json.items);
}

// ═══════════════════════════════════════════════════════════════════════════
// GET / — Simple HTML status page
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleRoot(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);

    try html.appendSlice(allocator,
        "<!DOCTYPE html><html><head><title>UTM Monitor</title>" ++
        "<meta charset='utf-8'><style>body{font-family:monospace;margin:20px}" ++
        "table{border-collapse:collapse}th,td{padding:6px 12px;text-align:left;border-bottom:1px solid #ccc}" ++
        "</style></head><body><h1>UTM Monitor</h1><table>" ++
        "<tr><th>Hostname</th><th>IP</th><th>Target</th><th>MAC</th><th>Version</th><th>Shell</th></tr>",
    );

    state.mutex.lock(state.io.?) catch {};
    defer state.mutex.unlock(state.io.?);

    for (state.guests.items) |g| {
        try html.print(allocator,
            "<tr><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td></tr>",
            .{ g.hostname, g.ip, g.target, g.mac, g.version, g.shell },
        );
    }
    try html.appendSlice(allocator, "</table></body></html>");

    try request.respond(html.items, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /mcp — MCP JSON-RPC
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleMcp(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const body_str = readBody(allocator, request) catch {
        try respondError(request, .bad_request, "Missing body");
        return;
    };
    defer allocator.free(body_str);

    const result = try mcp.processJsonRpcWithState(allocator, state, body_str);
    defer allocator.free(result);

    if (result.len == 0) {
        try request.respond("", .{ .status = .ok });
    } else {
        try respondJson(request, result);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mesh guest handler — per-Guest KCP tunnel thread
// ═══════════════════════════════════════════════════════════════════════════

/// Background thread: reads tunproto frames from a Guest's KCP tunnel,
/// dispatches to HostState (appendOpOutput, completeOpState, etc.).
/// Runs until tunnel disconnects or kick is requested.
pub fn handleMeshGuest(
    allocator: std.mem.Allocator,
    state: *httpd.HostState,
    hostname: []const u8,
    tun: *tunnel_mod.Tunnel,
) void {
    defer {
        // Cleanup on disconnect
        state.failAllPendingOps();
        state.removeGuestTunnel(hostname);
        state.removeGuest(hostname);
        syncHostsFromState(state, allocator);
        if (state.on_guest_changed) |cb| cb(state);
        std.log.info("[mesh-guest] {s} disconnected, cleanup done", .{hostname});
    }

    // Send pty_spawn to guest — triggers ptySpawn + ptyReadLoop on guest side
    {
        const spawn_frame = tunproto.buildPtySpawn(allocator) catch |err| {
            std.log.err("[mesh-guest] buildPtySpawn failed for {s}: {}", .{ hostname, err });
            return;
        };
        defer allocator.free(spawn_frame);
        _ = tun.send(spawn_frame) catch |err| {
            std.log.err("[mesh-guest] pty_spawn send failed for {s}: {}", .{ hostname, err });
            return;
        };
        std.log.info("[mesh-guest] Sent pty_spawn to {s}", .{hostname});
    }

    // Main loop: read guest responses from tunnel
    var rbuf: [65536]u8 = undefined;
    while (true) {
        // Check kick request
        if (state.checkCloseRequested(hostname)) {
            std.log.info("[mesh-guest] {s} kicked, closing tunnel", .{hostname});
            return;
        }

        const n = tun.recv(&rbuf) catch |err| {
            std.log.err("[mesh-guest] tunnel recv failed for {s}: {}", .{ hostname, err });
            return;
        };
        if (n == 0) {
            // Tunnel dead — reconnect handled by caller (tunnelManager)
            if (tun.isAlive()) {
                std.Io.sleep(state.io.?, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                continue;
            }
            std.log.info("[mesh-guest] {s} tunnel dead", .{hostname});
            return;
        }

        if (n == 0 or rbuf[0] == 0) continue;
        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        switch (msg_type) {
            @intFromEnum(tunproto.MsgType.pty_exec_output) => {
                if (tunproto.parsePtyExecOutput(payload)) |out| {
                    state.appendOpOutput(out.cmd_id, out.data);
                    state.scanForMarker(out.cmd_id);
                    state.wake_event.set(state.io.?);
                }
            },
            @intFromEnum(tunproto.MsgType.pty_exec_done) => {
                if (tunproto.parsePtyExecDone(payload)) |done| {
                    state.completeOpState(done.cmd_id, done.exit_code);
                }
            },
            @intFromEnum(tunproto.MsgType.upload_result) => {
                if (tunproto.parseUploadResult(payload)) |resp| {
                    state.completeOpState(resp.cmd_id, resp.exit_code);
                }
            },
            @intFromEnum(tunproto.MsgType.download_result) => {
                if (tunproto.parseDownloadResult(payload)) |resp| {
                    state.appendOpOutput(resp.cmd_id, resp.file_data);
                    state.completeOpState(resp.cmd_id, resp.exit_code);
                }
            },
            else => {
                std.log.debug("[mesh-guest] Unknown msg type {d} from {s}", .{ msg_type, hostname });
            },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

pub fn syncHostsFromState(state: *httpd.HostState, allocator: std.mem.Allocator) void {
    state.mutex.lock(state.io.?) catch {};
    defer state.mutex.unlock(state.io.?);

    var entries: std.ArrayList(hosts_file.HostEntry) = .empty;
    defer entries.deinit(allocator);
    var allocated_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_names.items) |n| allocator.free(n);
        allocated_names.deinit(allocator);
    }

    for (state.guests.items) |g| {
        const name_str = std.fmt.allocPrint(allocator, "{s}.{s}.utm", .{ g.hostname, g.target }) catch continue;
        allocated_names.append(allocator, name_str) catch {
            allocator.free(name_str);
            continue;
        };
        entries.append(allocator, .{
            .ip = g.ip,
            .name = name_str,
        }) catch continue;
    }

    hosts_file.updateHosts(state.io.?, allocator, "/etc/hosts", entries.items) catch |err| {
        std.log.err("[host-http] Failed to sync /etc/hosts: {}", .{err});
    };
}
