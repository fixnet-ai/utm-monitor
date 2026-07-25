//! Host HTTP endpoint handlers.
//!
//! Plugs into httpd.Router to provide:
//!   POST /exec       — Send command to guest via KCP tunnel (pty, wait for MDELIM)
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
    // Flush immediately so the command reaches the Guest promptly.
    // tun.flush() handles its own locking and returns safely on failure.
    // If skipped, the mesh thread will flush via periodicTasks.
    tun.flush(tun.session.mesh.clock_ms);

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
    const file_hash = getRequestHeader(request, "x-file-hash") orelse "";

    // Validate content length
    const content_length = request.head.content_length orelse {
        try respondError(request, .bad_request, "Missing Content-Length");
        return;
    };
    if (content_length == 0) {
        try respondError(request, .bad_request, "Empty body");
        return;
    }
    if (content_length > 2 * 1024 * 1024 * 1024) { // 2GB max
        try respondError(request, .payload_too_large, "File too large");
        return;
    }

    std.log.info("[upload] {s} -> {s} ({d} bytes, hash={s})", .{ vm, path, content_length, file_hash });

    // Singleton dedup: keyed by destination (vm:path) only —
    // other clients may upload the same file, strict keys defeat the purpose.
    const transfer_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ vm, path });
    defer allocator.free(transfer_key);
    {
        state.mutex.lock(state.io.?) catch {};
        defer state.mutex.unlock(state.io.?);
        if (state.findTransfer(transfer_key)) |existing| {
            const msg = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"transfer_in_progress\",\"cmd_id\":\"{s}\",\"bytes\":{d},\"size\":{d}}}",
                .{ existing.cmd_id, existing.bytes_transferred, existing.file_size },
            );
            defer allocator.free(msg);
            try respondJson(request, msg);
            return;
        }
    }

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

    try state.createOpState(cmd_id);

    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };

    // Send upload_cmd (metadata, no file data)
    const cmd_frame = try tunproto.buildUploadCmd(allocator, cmd_id, path, @intCast(content_length), file_hash);
    defer allocator.free(cmd_frame);
    _ = tun.send(cmd_frame) catch |err| {
        std.log.err("[upload] upload_cmd send failed for {s}: {}", .{ vm, err });
        state.removeTransfer(transfer_key);
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Stream body as file_chunk messages (8KB each, incremental SHA256)
    var http_buf: [4096]u8 = undefined;
    var body_reader = request.readerExpectNone(&http_buf);
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_buf: [8192]u8 = undefined;
    var remaining: usize = @intCast(content_length);
    while (remaining > 0) {
        const to_read: usize = if (remaining > chunk_buf.len) chunk_buf.len else remaining;
        var chunk_writer: std.Io.Writer = .fixed(&chunk_buf);
        const n = body_reader.stream(&chunk_writer, std.Io.Limit.limited(to_read)) catch |err| {
            std.log.err("[upload] body read failed for {s}: {}", .{ cmd_id, err });
            state.removeTransfer(transfer_key);
            try respondError(request, .internal_server_error, "BodyReadFailed");
            return;
        };
        if (n == 0) break;
        remaining -= n;

        const chunk_data = chunk_writer.buffered();
        sha256.update(chunk_data);

        const chunk_frame = try tunproto.buildFileChunk(allocator, cmd_id, chunk_data);
        defer allocator.free(chunk_frame);
        _ = tun.send(chunk_frame) catch |err| {
            std.log.err("[upload] file_chunk send failed for {s}: {}", .{ cmd_id, err });
            state.removeTransfer(transfer_key);
            try respondError(request, .service_unavailable, "TunnelSendFailed");
            return;
        };
    }

    // Send file_eof with incremental SHA256 hash
    var hash_bin: [32]u8 = undefined;
    sha256.final(&hash_bin);
    var hash_hex: [64]u8 = undefined;
    for (hash_bin, 0..) |b, j| {
        hash_hex[j * 2] = "0123456789abcdef"[b >> 4];
        hash_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    const eof_frame = try tunproto.buildFileEof(allocator, cmd_id, 0, @intCast(content_length), &hash_hex);
    defer allocator.free(eof_frame);
    _ = tun.send(eof_frame) catch |err| {
        std.log.err("[upload] file_eof send failed for {s}: {}", .{ cmd_id, err });
        state.removeTransfer(transfer_key);
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Register transfer for singleton tracking
    state.registerTransfer(transfer_key, cmd_id, @intCast(content_length)) catch {};

    // Wait for result — woken by mesh handler thread via wake_event.
    // Reset-then-double-check avoids TOCTOU race between concurrent waiters
    // sharing the same wake_event.
    while (true) {
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);
            state.removeTransfer(transfer_key);
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
            state.removeTransfer(transfer_key);
            if (result.exit == 0) {
                try respondJson(request, "{\"ok\":true}");
            } else {
                try respondError(request, .internal_server_error, "UploadFailed");
            }
            return;
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } }) catch |err| {
            std.log.err("[upload] wait timeout for {s}: {}", .{ cmd_id, err });
            state.removeTransfer(transfer_key);
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

    // Singleton dedup: keyed by source (vm:path) — same as upload,
    // other clients may download the same file, strict keys defeat the purpose.
    const transfer_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ vm, path });
    defer allocator.free(transfer_key);
    {
        state.mutex.lock(state.io.?) catch {};
        defer state.mutex.unlock(state.io.?);
        if (state.findTransfer(transfer_key)) |existing| {
            const msg = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"transfer_in_progress\",\"cmd_id\":\"{s}\",\"bytes\":{d},\"size\":{d}}}",
                .{ existing.cmd_id, existing.bytes_transferred, existing.file_size },
            );
            defer allocator.free(msg);
            try respondJson(request, msg);
            return;
        }
    }

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

    // Register transfer for singleton tracking (size unknown until file_eof arrives)
    state.registerTransfer(transfer_key, cmd_id, 0) catch {};

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

            // Read file metadata from op state for response trailers
            const meta_hash: []const u8, const meta_size: u32 = blk: {
                state.mutex.lock(state.io.?) catch break :blk .{ "", 0 };
                defer state.mutex.unlock(state.io.?);
                const opm = state.op_states.getPtr(cmd_id) orelse break :blk .{ "", 0 };
                const h = if (opm.file_hash.len > 0) allocator.dupe(u8, opm.file_hash) catch "" else "";
                break :blk .{ h, opm.file_size_meta };
            };
            defer if (meta_hash.len > 0) allocator.free(meta_hash);

            var exit_buf: [32]u8 = undefined;
            const exit_str = std.fmt.bufPrint(&exit_buf, "{d}", .{exit_code}) catch "1";

            var size_buf: [32]u8 = undefined;
            const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{meta_size}) catch "0";

            var trailers_buf: [4]http.Header = undefined;
            var trailer_count: usize = 1;
            trailers_buf[0] = .{ .name = "x-exit-code", .value = exit_str };
            if (meta_hash.len > 0) {
                trailers_buf[trailer_count] = .{ .name = "x-file-hash", .value = meta_hash };
                trailer_count += 1;
            }
            if (meta_size > 0) {
                trailers_buf[trailer_count] = .{ .name = "x-file-size", .value = size_str };
                trailer_count += 1;
            }

            chunked_ended = true;
            body_writer.endChunked(.{ .trailers = trailers_buf[0..trailer_count] }) catch |err| {
                std.log.err("[download] endChunked failed for {s}: {}", .{ cmd_id, err });
            };
            state.removeTransfer(transfer_key);
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
            "{{\"hostname\":\"{s}\",\"target\":\"{s}\",\"ip\":\"{s}\",\"mac\":\"{s}\",\"version\":\"{s}\",\"shell\":\"{s}\",\"status\":\"{s}\"}}",
            .{ g.hostname, g.target, g.ip, g.mac, g.version, g.shell, g.status },
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
        "a{color:#06c}</style></head><body><h1>UTM Monitor</h1>" ++
        "<h2>Guests</h2><table>" ++
        "<tr><th>Hostname</th><th>IP</th><th>Target</th><th>MAC</th><th>Version</th><th>Shell</th><th>Status</th></tr>",
    );

    state.mutex.lock(state.io.?) catch {};
    defer state.mutex.unlock(state.io.?);

    for (state.guests.items) |g| {
        try html.print(allocator,
            "<tr><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td><td>{s}</td></tr>",
            .{ g.hostname, g.ip, g.target, g.mac, g.version, g.shell, g.status },
        );
    }
    try html.appendSlice(allocator, "</table>");

    // Directory listing — serve_dir contents
    try html.appendSlice(allocator, "<h2>Files</h2>");
    const io = state.io orelse {
        try html.appendSlice(allocator, "<p>IO not available</p></body></html>");
        try request.respond(html.items, .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
        });
        return;
    };

    const dir = std.Io.Dir.cwd().openDir(io, state.serve_dir, .{ .iterate = true }) catch |err| {
        try html.print(allocator, "<p>Cannot open serve dir: {}</p></body></html>", .{err});
        try request.respond(html.items, .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
        });
        return;
    };
    defer dir.close(io);

    try html.appendSlice(allocator, "<table><tr><th>Name</th><th>Size</th></tr>");

    // Use Dir iteration for directory listing
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file) {
            try html.print(allocator,
                "<tr><td><a href=\"/bin/{s}\">{s}</a></td><td>-</td></tr>",
                .{ entry.name, entry.name },
            );
        }
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
/// Runs until tunnel disconnects.
pub fn handleMeshGuest(
    allocator: std.mem.Allocator,
    state: *httpd.HostState,
    hostname: []const u8,
    tun: *tunnel_mod.Tunnel,
) void {
    defer {
        // Cleanup on disconnect.
        // Only remove guest/tunnel if our tunnel is still the registered one.
        // During upgrade replacement, the tunnel manager creates a new tunnel
        // and registers it under the same hostname before our defer runs.
        // Pointer comparison prevents the old thread from removing the new tunnel.
        const current_tun = state.getGuestTunnel(hostname);
        const we_are_registered = current_tun != null and current_tun.? == tun;

        state.failAllPendingOps();
        if (we_are_registered) {
            state.removeGuestTunnel(hostname);
            state.removeGuest(hostname);
            syncHostsFromState(state, allocator);
            if (state.on_guest_changed) |cb| cb(state);
        }

        std.log.info("[mesh-guest] {s} disconnected, cleanup done (registered={})", .{ hostname, we_are_registered });

        // Only close the session if we were the registered handler.
        // If the tunnel was replaced (e.g. by tunnel manager during upgrade),
        // the new handler owns the session and we must not destroy it.
        if (we_are_registered) {
            tun.session.mesh.closeSession(tun.session);
        }
        tun.deinit();
        allocator.destroy(tun);
        allocator.free(hostname);
    }

    // Send pty_spawn to guest — triggers ptySpawn + ptyReadLoop on guest side
    {
        const spawn_frame = tunproto.buildPtySpawn(allocator) catch |err| {
            std.log.err("[mesh-guest] buildPtySpawn failed for {s}: {}", .{ hostname, err });
            return;
        };
        defer allocator.free(spawn_frame);
        // Send and flush immediately — send() and flush() each handle their
        // own locking. If flush() skips due to contention, the mesh thread
        // will flush via periodicTasks.
        _ = tun.send(spawn_frame) catch |err| {
            std.log.err("[mesh-guest] pty_spawn send failed for {s}: {}", .{ hostname, err });
            return;
        };
        tun.flush(tun.session.mesh.clock_ms);
        std.log.info("[mesh-guest] Sent pty_spawn to {s}", .{hostname});
    }

    // Main loop: read guest responses from tunnel.
    // Uses 256KB fixed buffer — file transfers use chunked protocol
    // (file_chunk + file_eof), so no message exceeds 8KB + overhead.
    var rbuf: [262144]u8 = undefined;
    var empty_count: u32 = 0;
    while (true) {
        if (!tun.isAlive()) {
            std.log.info("[mesh-guest] {s} tunnel dead", .{hostname});
            return;
        }

        const n = tun.recv(&rbuf) catch |err| {
            std.log.err("[mesh-guest] tunnel recv failed for {s}: {}", .{ hostname, err });
            return;
        };
        if (n == 0 or rbuf[0] == 0) {
            empty_count += 1;
            if (empty_count == 1 or empty_count % 100 == 0) {
                std.log.info("[mesh-guest] {s} recv empty x{d} (n={d} peek={d})", .{ hostname, empty_count, n, tun.peekSize() });
            }
            std.Io.sleep(state.io.?, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
            continue;
        }
        empty_count = 0;
        std.log.info("[mesh-guest] {s} recv {d}B type={d}", .{ hostname, n, rbuf[0] });
        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        switch (msg_type) {
            @intFromEnum(tunproto.MsgType.pty_exec_output) => {
                if (tunproto.parsePtyExecOutput(payload)) |out| {
                    std.log.info("[mesh-guest] pty_output: cmd_id={s} len={d}", .{ out.cmd_id, out.data.len });
                    state.appendOpOutput(out.cmd_id, out.data);
                    state.scanForMarker(out.cmd_id);
                    state.wake_event.set(state.io.?);
                }
            },
            @intFromEnum(tunproto.MsgType.pty_exec_done) => {
                if (tunproto.parsePtyExecDone(payload)) |done| {
                    std.log.info("[mesh-guest] pty_done: cmd_id={s} exit={d}", .{ done.cmd_id, done.exit_code });
                    state.completeOpState(done.cmd_id, done.exit_code);
                }
            },
            @intFromEnum(tunproto.MsgType.upload_result) => {
                if (tunproto.parseUploadResult(payload)) |resp| {
                    state.completeOpState(resp.cmd_id, resp.exit_code);
                }
            },
            @intFromEnum(tunproto.MsgType.file_chunk) => {
                if (tunproto.parseFileChunk(payload)) |chunk| {
                    // Stream chunk data to download handler via op output
                    state.appendOpOutput(chunk.cmd_id, chunk.data);
                    state.updateTransferProgress(chunk.cmd_id, @intCast(chunk.data.len));
                    state.wake_event.set(state.io.?);
                }
            },
            @intFromEnum(tunproto.MsgType.file_eof) => {
                if (tunproto.parseFileEof(payload)) |eof| {
                    // Update transfer tracking with actual file metadata
                    state.updateTransferProgress(eof.cmd_id, eof.file_size);
                    state.setOpFileMeta(eof.cmd_id, eof.file_hash, eof.file_size);
                    state.completeOpState(eof.cmd_id, eof.exit_code);
                    state.wake_event.set(state.io.?);
                }
            },
            @intFromEnum(tunproto.MsgType.upgrade_req) => {
                handleUpgradeReq(allocator, state, tun, payload) catch |err| {
                    std.log.err("[mesh-guest] handleUpgradeReq for {s} failed: {}", .{ hostname, err });
                };
            },
            else => {
                std.log.debug("[mesh-guest] Unknown msg type {d} from {s}", .{ msg_type, hostname });
            },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Upgrade handler — Guest requests new binary via KCP tunnel
// ═══════════════════════════════════════════════════════════════════════════

fn handleUpgradeReq(
    allocator: std.mem.Allocator,
    state: *httpd.HostState,
    tun: *tunnel_mod.Tunnel,
    payload: []const u8,
) !void {
    const req = tunproto.parseUpgradeReq(payload) orelse {
        std.log.err("[upgrade] Failed to parse upgrade_req", .{});
        return;
    };

    const filename = protocol.deploymentFilename(req.target) orelse {
        std.log.err("[upgrade] Unknown target {s} from cmd {s}", .{ req.target, req.cmd_id });
        const err_frame = try tunproto.buildFileEof(allocator, req.cmd_id, -1, 0, "");
        defer allocator.free(err_frame);
        _ = tun.send(err_frame) catch {};
        return;
    };

    const io = state.io orelse {
        std.log.err("[upgrade] No I/O available for upgrade request", .{});
        return;
    };

    // Open binary from serve_dir for streaming read
    const dir = std.Io.Dir.cwd().openDir(io, state.serve_dir, .{}) catch |err| {
        std.log.err("[upgrade] Cannot open serve_dir {s}: {}", .{ state.serve_dir, err });
        const err_frame = try tunproto.buildFileEof(allocator, req.cmd_id, -2, 0, "");
        defer allocator.free(err_frame);
        _ = tun.send(err_frame) catch {};
        return;
    };
    defer dir.close(io);

    const file = dir.openFile(io, filename, .{}) catch |err| {
        std.log.err("[upgrade] Cannot open {s}/{s}: {}", .{ state.serve_dir, filename, err });
        const err_frame = try tunproto.buildFileEof(allocator, req.cmd_id, -3, 0, "");
        defer allocator.free(err_frame);
        _ = tun.send(err_frame) catch {};
        return;
    };
    defer file.close(io);

    // Stream binary as file_chunk messages via KCP (message mode).
    //
    // CRITICAL: chunk_size = 1200 bytes. KCP MSS = MTU - IKCP_OVERHEAD =
    // 1300 - 24 = 1276. Each chunk fits in ONE KCP segment (frg=0 in
    // message mode), so peekSize() returns the size immediately — no
    // waiting for fragment assembly. Each recv() returns exactly one
    // complete message. Batch size = 32 (fills IKCP_WND_SND window).
    //
    // Enable fast mode (nocwnd=true) for maximum throughput. No stream
    // mode — message mode with single-segment chunks avoids fragmentation
    // while keeping one-message-per-recv semantics.
    tun.enableFastMode();

    // KCP send window = 32 segments with nocwnd=true. Each file_chunk is one
    // segment (~1213 bytes frame). Send in quarter-window batches (8 chunks)
    // and wait for ACKs to drain snd_buf before sending more. waiting() returns
    // bytes (sum of segment lengths), so compare to batch_byte_cap ≈ 10KB.
    const BATCH_CHUNKS = 8;
    const BATCH_BYTE_CAP = BATCH_CHUNKS * 1300; // ~10KB upper bound

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u32 = 0;
    var chunk_buf: [1200]u8 = undefined;
    var file_read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_read_buf);
    var file_done = false;
    while (!file_done) {
        // ── Send one batch under a single lock window ──
        {
            tun.lock() catch return;
            defer tun.unlock();

            var batch: u32 = 0;
            while (batch < BATCH_CHUNKS) : (batch += 1) {
                const n = file_reader.interface.readSliceShort(&chunk_buf) catch |err| {
                    std.log.err("[upgrade] Read error {s}/{s}: {}", .{ state.serve_dir, filename, err });
                    const err_frame = try tunproto.buildFileEof(allocator, req.cmd_id, -4, 0, "");
                    defer allocator.free(err_frame);
                    _ = tun.sendLocked(err_frame) catch {};
                    return;
                };
                if (n == 0) { file_done = true; break; }
                sha256.update(chunk_buf[0..n]);
                const frame = try tunproto.buildFileChunk(allocator, req.cmd_id, chunk_buf[0..n]);
                defer allocator.free(frame);
                _ = tun.sendLocked(frame) catch |err| {
                    std.log.err("[upgrade] Failed to send file_chunk: {}", .{err});
                    return;
                };
                total += @intCast(n);
            }
            if (batch == 0) break; // EOF on first read

            // Flush: move from snd_queue → snd_buf → network
            tun.flushLocked(tun.session.mesh.clock_ms);
        }
        // ── Lock released — mesh thread can process ACKs ──

        // Adaptive pacing: wait for KCP to drain snd_queue + snd_buf below
        // BATCH_BYTE_CAP, or 200ms (one RTO cycle), whichever comes first.
        {
            var pace_wait: u32 = 0;
            while (pace_wait < 20) : (pace_wait += 1) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                if (tun.waiting() <= BATCH_BYTE_CAP) break;
            }
            if (total <= 50000) {
                std.log.info("[upgrade] batch complete: total={d} waiting={d} sndQ={d} sndB={d}", .{
                    total, tun.waiting(),
                    tun.session.kcp_inst.sendQueueSize(),
                    tun.session.kcp_inst.sndBufLen(),
                });
            }
        }
    }

    // Build hash and send file_eof
    var hash_bin: [32]u8 = undefined;
    sha256.final(&hash_bin);
    var hash_hex: [64]u8 = undefined;
    for (hash_bin, 0..) |b, j| {
        hash_hex[j * 2] = "0123456789abcdef"[b >> 4];
        hash_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }

    const eof_frame = try tunproto.buildFileEof(allocator, req.cmd_id, 0, total, &hash_hex);
    defer allocator.free(eof_frame);

    // Send EOF + flush under single lock window (same pattern as batches)
    {
        tun.lock() catch return;
        defer tun.unlock();
        _ = tun.sendLocked(eof_frame) catch |err| {
            std.log.err("[upgrade] Failed to send file_eof: {}", .{err});
            return;
        };
        tun.flushLocked(tun.session.mesh.clock_ms);
    }
    // Release lock before sleeping — mesh thread gets 500ms to deliver EOF
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    std.log.info("[upgrade] Sent {s} ({d} bytes, sha256={s}) to {s}", .{
        filename, total, &hash_hex, req.cmd_id,
    });
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
