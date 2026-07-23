//! Host HTTP endpoint handlers.
//!
//! Plugs into httpd.Router to provide:
//!   POST /announce   — Guest heartbeat (backward compat, empty pending)
//!   POST /exec       — Send command to guest via pty (enqueue pty_input, wait for MDELIM)
//!   POST /kick       — Request guest WebSocket close
//!   POST /upload     — Upload file to guest
//!   POST /download   — Download file from guest
//!   GET  /bin/<file> — Serve static binaries
//!   GET  /           — Simple HTML status page
//!   GET  /ws         — WebSocket upgrade (Guest persistent pty connection)
//!   POST /mcp        — MCP JSON-RPC (delegates to mcp.zig)
//!
//! All handlers receive (allocator, HostState, Request, body).

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const httpd = @import("httpd.zig");
const protocol = @import("protocol.zig");
const hosts_file = @import("hosts_file.zig");
const mcp = @import("mcp.zig");
const wsproto = @import("wsproto.zig");

/// Read the request body as JSON. Caller owns the returned string.
fn readBody(allocator: std.mem.Allocator, request: *http.Server.Request) ![]const u8 {
    const content_length = request.head.content_length orelse return error.MissingContentLength;
    if (content_length == 0) return error.EmptyBody;
    if (content_length > 10 * 1024 * 1024) return error.BodyTooLarge;

    const buf = try allocator.alloc(u8, @intCast(content_length));
    errdefer allocator.free(buf);

    var body_reader = request.readerExpectNone(buf);
    // Read the full body into buf using the body reader
    var writer: std.Io.Writer = .fixed(buf);
    try body_reader.streamExact(&writer, @intCast(content_length));
    return buf;
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
// POST /announce — Guest heartbeat (backward compat)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleAnnounce(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const body_str = readBody(allocator, request) catch {
        try respondError(request, .bad_request, "Missing or invalid body");
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

    const hostname = httpd.jsonGetString(obj, "hostname") orelse "unknown";
    const ip = httpd.jsonGetString(obj, "ip") orelse "0.0.0.0";
    const target = httpd.jsonGetString(obj, "target") orelse "unknown";
    const mac = httpd.jsonGetString(obj, "mac") orelse "00:00:00:00:00:00";
    const version = httpd.jsonGetString(obj, "version") orelse protocol.VERSION;
    const shell = httpd.jsonGetString(obj, "shell") orelse "";

    const changed = state.upsertGuest(hostname, ip, target, mac, version, shell);
    if (changed) {
        syncHostsFromState(state, allocator);
    }

    // No pending commands in pty model — commands go via outgoing_frames through WebSocket
    try respondJson(request, "{\"pending\":[]}");
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

    const frame = try wsproto.buildPtyInput(allocator, cmd_id, cmd_with_marker);
    defer allocator.free(frame);

    // Create operation state and enqueue frame
    try state.createOpState(cmd_id);
    try state.enqueueOutgoingFrame(vm, frame);

    std.log.info("[exec] Enqueued pty cmd {s} for {s}", .{ cmd_id, vm });

    // Stream response using chunked transfer encoding
    var stream_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
        },
    });
    // Track whether we called endChunked — defer fires end() only as fallback
    var chunked_ended = false;

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

        const done_and_exit = blk: {
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

        // Wait for next chunk (woken by WebSocket handler on each pty_output)
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(3600), .clock = .awake } }) catch {};
        state.wake_event.reset();
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
// POST /upload — Upload file to guest
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleUpload(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
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
        try respondError(request, .bad_request, "Missing 'vm'");
        return;
    };
    const path = httpd.jsonGetString(obj, "path") orelse {
        try respondError(request, .bad_request, "Missing 'path'");
        return;
    };
    const data = httpd.jsonGetString(obj, "data") orelse {
        try respondError(request, .bad_request, "Missing 'data'");
        return;
    };

    // Check guest exists
    {
        state.mutex.lock(state.io.?) catch {};
        const guest_exists = state.containsGuest(vm);
        state.mutex.unlock(state.io.?);
        if (!guest_exists) {
            try respondJson(request, "{\"error\":\"GuestNotFound\"}");
            return;
        }
    }

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "upload_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    const frame = try wsproto.buildUploadReq(allocator, cmd_id, path, data);
    defer allocator.free(frame);

    try state.createOpState(cmd_id);
    try state.enqueueOutgoingFrame(vm, frame);

    // Wait for result — woken by WebSocket handler via wake_event
    while (true) {
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);
            if (result.exit == 0) {
                try respondJson(request, "{\"ok\":true}");
            } else {
                try respondJson(request, "{\"error\":\"UploadFailed\"}");
            }
            return;
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } }) catch |err| {
            std.log.err("[upload] wait timeout for {s}: {}", .{ cmd_id, err });
            try respondJson(request, "{\"error\":\"UploadTimeout\"}");
            return;
        };
        state.wake_event.reset();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /download — Download file from guest
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleDownload(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
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
        try respondError(request, .bad_request, "Missing 'vm'");
        return;
    };
    const path = httpd.jsonGetString(obj, "path") orelse {
        try respondError(request, .bad_request, "Missing 'path'");
        return;
    };

    // Check guest exists
    {
        state.mutex.lock(state.io.?) catch {};
        const guest_exists = state.containsGuest(vm);
        state.mutex.unlock(state.io.?);
        if (!guest_exists) {
            try respondJson(request, "{\"error\":\"GuestNotFound\"}");
            return;
        }
    }

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "download_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    const frame = try wsproto.buildDownloadReq(allocator, cmd_id, path);
    defer allocator.free(frame);

    try state.createOpState(cmd_id);
    try state.enqueueOutgoingFrame(vm, frame);

    // Poll for result — no timeout
    while (true) {
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);
            if (result.exit == 0) {
                const escaped = try httpd.jsonEscape(allocator, result.stdout);
                defer allocator.free(escaped);
                const resp_json = try std.fmt.allocPrint(allocator,
                    "{{\"ok\":true,\"data\":\"{s}\",\"size\":{d}}}",
                    .{ escaped, result.stdout.len },
                );
                defer allocator.free(resp_json);
                try respondJson(request, resp_json);
            } else {
                try respondJson(request, "{\"error\":\"DownloadFailed\"}");
            }
            return;
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } }) catch |err| {
            std.log.err("[download] wait timeout for {s}: {}", .{ cmd_id, err });
            try respondJson(request, "{\"error\":\"DownloadTimeout\"}");
            return;
        };
        state.wake_event.reset();
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
// GET /ws — WebSocket upgrade (Guest persistent pty connection)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleWebSocket(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;

    const upgrade = request.upgradeRequested();
    const ws_key = upgrade.websocket orelse {
        try respondError(request, .bad_request, "Not a WebSocket upgrade request");
        return;
    };

    var ws = try request.respondWebSocket(.{ .key = ws_key });

    // Flush 101 response so Guest can proceed with announce
    try ws.output.flush();

    // Read announce frame from guest (first message)
    const announce = ws.readSmallMessage() catch |err| {
        std.log.err("[ws] Announce read failed: {}", .{err});
        return;
    };
    if (announce.opcode != .binary or announce.data.len == 0) {
        std.log.err("[ws] Expected binary announce, got opcode={s}", .{@tagName(announce.opcode)});
        return;
    }
    const msg_type: u8 = announce.data[0];
    if (msg_type != @intFromEnum(wsproto.MsgType.announce)) {
        std.log.err("[ws] Expected announce (1), got type={d}", .{msg_type});
        return;
    }
    const info = wsproto.parseAnnounce(announce.data[1..]) orelse {
        std.log.err("[ws] Failed to parse announce", .{});
        return;
    };

    std.log.info("[ws] Guest {s} connected ({s} v{s})", .{ info.hostname, info.ip, info.version });

    // Update guest table
    const changed = state.upsertGuest(info.hostname, info.ip, info.target, info.mac, info.version, info.shell);
    if (changed) syncHostsFromState(state, allocator);
    const ws_hostname = try allocator.dupe(u8, info.hostname);
    defer {
        state.failAllPendingOps();
        state.removeGuest(ws_hostname);
        syncHostsFromState(state, allocator);
        if (state.on_guest_changed) |cb| cb(state);
        allocator.free(ws_hostname);
    }
    if (state.on_guest_changed) |cb| cb(state);

    // Send pty_spawn to guest — triggers ptySpawn + ptyReadLoop on guest side
    {
        const spawn_frame = try wsproto.buildPtySpawn(allocator);
        defer allocator.free(spawn_frame);
        ws.writeMessage(spawn_frame, .binary) catch |err| {
            std.log.err("[ws] pty_spawn write failed for {s}: {}", .{ info.hostname, err });
            return;
        };
        std.log.info("[ws] Sent pty_spawn to {s}", .{info.hostname});
    }

    // Main loop: drain outgoing frames, read guest messages, check close
    while (true) {
        // 1. Drain outgoing frames queue → send to guest
        while (state.dequeueOutgoingFrame(ws_hostname)) |frame| {
            defer allocator.free(frame);
            ws.writeMessage(frame, .binary) catch |err| {
                std.log.err("[ws] Frame write failed for {s}: {}", .{ info.hostname, err });
                return;
            };
        }

        // 2. Read message from guest (blocks)
        const msg = ws.readSmallMessage() catch |err| {
            std.log.err("[ws] Read failed for {s}: {}", .{ info.hostname, err });
            return;
        };

        if (msg.opcode == .binary and msg.data.len > 0) {
            const resp_type: u8 = msg.data[0];
            const payload = msg.data[1..];
            switch (resp_type) {
                @intFromEnum(wsproto.MsgType.announce) => {
                    if (wsproto.parseAnnounce(payload)) |a| {
                        std.log.debug("[ws] Re-announce from {s}", .{a.hostname});
                        _ = state.upsertGuest(a.hostname, a.ip, a.target, a.mac, a.version, a.shell);
                        if (state.on_guest_changed) |cb| cb(state);
                    }
                },
                @intFromEnum(wsproto.MsgType.pty_output) => {
                    if (wsproto.parsePtyOutput(payload)) |out| {
                        state.appendOpOutput(out.cmd_id, out.data);
                        state.scanForMarker(out.cmd_id);
                        // Wake streaming HTTP handlers even if marker not yet found
                        state.wake_event.set(state.io.?);
                    }
                },
                @intFromEnum(wsproto.MsgType.upload_resp) => {
                    if (wsproto.parseUploadResp(payload)) |resp| {
                        state.completeOpState(resp.cmd_id, resp.exit_code);
                    }
                },
                @intFromEnum(wsproto.MsgType.download_resp) => {
                    if (wsproto.parseDownloadResp(payload)) |resp| {
                        state.appendOpOutput(resp.cmd_id, resp.file_data);
                        state.completeOpState(resp.cmd_id, resp.exit_code);
                    }
                },
                else => {
                    std.log.debug("[ws] Unknown message type: {d}", .{resp_type});
                },
            }
        } else if (msg.opcode == .ping) {
            // RFC 6455: respond to ping with pong
            ws.writeMessage(&.{}, .pong) catch {};
        } else if (msg.opcode == .connection_close) {
            std.log.info("[ws] Guest {s} disconnected", .{info.hostname});
            return;
        }

        // 3. Check kick request
        if (state.checkCloseRequested(ws_hostname)) {
            std.log.info("[ws] Guest {s} kicked, closing connection", .{info.hostname});
            return;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

fn syncHostsFromState(state: *httpd.HostState, allocator: std.mem.Allocator) void {
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
