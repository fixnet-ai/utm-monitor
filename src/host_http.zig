//! Host HTTP endpoint handlers.
//!
//! Plugs into httpd.Router to provide:
//!   POST /announce   — Guest heartbeat, returns pending commands
//!   POST /exec       — Send command to guest (enqueue, wait for result)
//!   POST /exec-result — Guest posts command execution result
//!   GET  /bin/<file> — Serve static binaries
//!   GET  /           — Simple HTML status page
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

// serve_dir is stored in httpd.HostState.serve_dir

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
// POST /announce — Guest heartbeat
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleAnnounce(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    // Read body (expected: JSON with hostname, ip, target, mac, version, shell)
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

    // Upsert guest
    const changed = state.upsertGuest(hostname, ip, target, mac, version, shell);

    // Sync /etc/hosts if changed
    if (changed) {
        syncHostsFromState(state, allocator);
    }

    // Build pending commands response
    const pending = state.drainPending(hostname) catch &.{};
    defer {
        for (pending) |*cmd| {
            allocator.free(cmd.id);
            allocator.free(cmd.payload);
        }
        allocator.free(pending);
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);

    try resp.appendSlice(allocator,"{\"pending\":[");
    for (pending, 0..) |cmd, i| {
        if (i > 0) try resp.appendSlice(allocator,",");
        try resp.print(allocator,"{{\"id\":\"{s}\",\"type\":\"", .{cmd.id});
        try resp.appendSlice(allocator,@tagName(cmd.cmd_type));
        try resp.appendSlice(allocator,"\",\"payload\":\"");
        // JSON-escape the payload
        const escaped = httpd.jsonEscape(allocator, cmd.payload) catch cmd.payload;
        defer if (escaped.ptr != cmd.payload.ptr) allocator.free(escaped);
        try resp.appendSlice(allocator,escaped);
        try resp.appendSlice(allocator,"\"}");
    }
    try resp.appendSlice(allocator,"]}");

    try respondJson(request, resp.items);
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /exec — Send command to guest
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleExec(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    std.log.info("[exec] handleExec called", .{});
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

    // Check guest exists
    {
        state.mutex.lock(state.io.?) catch {};
        const guest_exists = state.containsGuest(vm);
        if (!guest_exists) {
            std.log.err("[exec] GuestNotFound: vm='{s}' len={d}, table entries:", .{ vm, vm.len });
            for (state.guests.items) |g| {
                std.log.err("[exec]   hostname='{s}' ip='{s}'", .{ g.hostname, g.ip });
            }
            state.mutex.unlock(state.io.?);
            try respondJson(request, "{\"error\":\"GuestNotFound\"}");
            return;
        }
        state.mutex.unlock(state.io.?);
    }

    // Enqueue command — returns command id
    const cmd_id = try state.enqueueCmd(vm, .exec, command);
    defer allocator.free(cmd_id);
    std.log.info("[exec] Enqueued cmd {s} for {s}", .{ cmd_id, vm });

    // Poll for result — no timeout (streaming exec may run indefinitely)
    while (true) {
        if (state.tryTakeResult(cmd_id)) |result| {
            std.log.info("[exec] Result received for {s}", .{cmd_id});
            const escaped_stdout = try httpd.jsonEscape(allocator, result.stdout);
            defer allocator.free(escaped_stdout);
            const escaped_stderr = try httpd.jsonEscape(allocator, result.stderr);
            defer allocator.free(escaped_stderr);
            const resp_json = try std.fmt.allocPrint(allocator,
                "{{\"stdout\":\"{s}\",\"stderr\":\"{s}\",\"exit\":{d}}}",
                .{ escaped_stdout, escaped_stderr, result.exit },
            );
            defer allocator.free(resp_json);
            if (result.stdout.len > 0) allocator.free(result.stdout);
            if (result.stderr.len > 0) allocator.free(result.stderr);
            try respondJson(request, resp_json);
            return;
        }
        std.Io.sleep(state.io.?, std.Io.Duration{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /exec-result — Guest posts command result
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleExecResult(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
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

    const cmd_id = httpd.jsonGetString(obj, "id") orelse {
        try respondError(request, .bad_request, "Missing 'id'");
        return;
    };
    const stdout = httpd.jsonGetString(obj, "stdout") orelse "";
    const stderr = httpd.jsonGetString(obj, "stderr") orelse "";
    const exit: i32 = @intCast(httpd.jsonGetInt(obj, "exit") orelse -1);

    const found = state.deliverResult(cmd_id, stdout, stderr, exit);
    if (found) {
        try respondJson(request, "{\"ok\":true}");
    } else {
        try respondError(request, .not_found, "Command id not found");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /exec-signal — Send signal (Ctrl+C) to a running command on guest
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleExecSignal(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
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
    const cmd_id = httpd.jsonGetString(obj, "cmd_id") orelse {
        try respondError(request, .bad_request, "Missing 'cmd_id' field");
        return;
    };

    std.log.info("[exec-signal] Sending SIGINT to {s} cmd={s}", .{ vm, cmd_id });
    try state.enqueueSignal(vm, cmd_id, 0); // 0 = SIGINT
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

    // Payload: path\0data
    const payload = try allocator.alloc(u8, path.len + 1 + data.len);
    defer allocator.free(payload);
    @memcpy(payload[0..path.len], path);
    payload[path.len] = 0;
    @memcpy(payload[path.len + 1 ..], data);

    const cmd_id = try state.enqueueCmd(vm, .upload, payload);
    defer allocator.free(cmd_id);

    // Poll for result — no timeout
    while (true) {
        if (state.tryTakeResult(cmd_id)) |result| {
            if (result.stdout.len > 0) allocator.free(result.stdout);
            if (result.stderr.len > 0) allocator.free(result.stderr);
            if (result.exit == 0) {
                try respondJson(request, "{\"ok\":true}");
            } else {
                try respondJson(request, "{\"error\":\"UploadFailed\",\"exit\":0}");
            }
            return;
        }
        std.Io.sleep(state.io.?, std.Io.Duration{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
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

    const cmd_id = try state.enqueueCmd(vm, .download, path);
    defer allocator.free(cmd_id);

    // Poll for result
    // Poll for result — no timeout
    while (true) {
        if (state.tryTakeResult(cmd_id)) |result| {
            defer {
                if (result.stdout.len > 0) allocator.free(result.stdout);
                if (result.stderr.len > 0) allocator.free(result.stderr);
            }
            if (result.exit == 0) {
                // Return file content as JSON (escape for safety)
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
        std.Io.sleep(state.io.?, std.Io.Duration{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// GET /bin/<file> — Serve static binaries
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleBin(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    // Extract filename from path: /bin/utmm-aarch64-linux
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

    // Read and serve file
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
        if (!first) try json.appendSlice(allocator,",");
        first = false;
        try json.print(allocator,
            "{{\"hostname\":\"{s}\",\"target\":\"{s}\",\"ip\":\"{s}\",\"mac\":\"{s}\",\"version\":\"{s}\",\"shell\":\"{s}\"}}",
            .{ g.hostname, g.target, g.ip, g.mac, g.version, g.shell },
        );
    }
    try json.appendSlice(allocator,"]");

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
    try html.appendSlice(allocator,"</table></body></html>");

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
        // Notification — no response needed
        try request.respond("", .{ .status = .ok });
    } else {
        try respondJson(request, result);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// GET /ws — WebSocket upgrade (Guest persistent connection)
// ═══════════════════════════════════════════════════════════════════════════

pub fn handleWebSocket(allocator: std.mem.Allocator, state: *httpd.HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;

    const upgrade = request.upgradeRequested();
    const ws_key = upgrade.websocket orelse {
        try respondError(request, .bad_request, "Not a WebSocket upgrade request");
        return;
    };

    var ws = try request.respondWebSocket(.{ .key = ws_key });

    // respondWebSocket writes the 101 response to the output buffer but does
    // NOT flush — data stays buffered. The Guest is waiting for the 101 before
    // sending its announce. Without the flush, both sides deadlock.
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

    // Update guest table — cleaned up on exit
    const changed = state.upsertGuest(info.hostname, info.ip, info.target, info.mac, info.version, info.shell);
    if (changed) syncHostsFromState(state, allocator);
    const ws_hostname = try allocator.dupe(u8, info.hostname);
    defer {
        state.removeGuest(ws_hostname);
        syncHostsFromState(state, allocator);
        if (state.on_guest_changed) |cb| cb(state);
        allocator.free(ws_hostname);
    }
    if (state.on_guest_changed) |cb| cb(state);

    // Main loop: poll for pending commands, send to guest, receive results.
    // Guest re-announces at least once per second (WouldBlock timeout in
    // readFrame triggers re-announce), so readSmallMessage never blocks
    // indefinitely — it always returns with an announce or command response.

    while (true) {
        // 1. Drain pending commands and send to guest
        const pending = state.drainPending(info.hostname) catch &.{};
        if (pending.len > 0) {
            std.log.info("[ws] Drained {d} pending commands for {s}", .{ pending.len, info.hostname });
        }
        for (pending) |cmd| {
            const frame = try blk: {
                switch (cmd.cmd_type) {
                    .exec => break :blk wsproto.buildExecStart(allocator, cmd.id, cmd.payload),
                    .upload => {
                        const null_pos = std.mem.indexOfScalar(u8, cmd.payload, 0) orelse {
                            allocator.free(cmd.id);
                            allocator.free(cmd.payload);
                            continue;
                        };
                        const path = cmd.payload[0..null_pos];
                        const data = cmd.payload[null_pos + 1 ..];
                        break :blk wsproto.buildUploadReq(allocator, cmd.id, path, data);
                    },
                    .download => break :blk wsproto.buildDownloadReq(allocator, cmd.id, cmd.payload),
                    .upgrade => {
                        allocator.free(cmd.id);
                        allocator.free(cmd.payload);
                        continue;
                    },
                }
            };
            defer allocator.free(frame);
            ws.writeMessage(frame, .binary) catch |err| {
                std.log.err("[ws] Write failed for {s}: {}", .{ info.hostname, err });
                // Free cmd copies from drainPending
                allocator.free(cmd.id);
                allocator.free(cmd.payload);
                return;
            };
            // Free drainPending copies
            allocator.free(cmd.id);
            allocator.free(cmd.payload);
        }

        // Drain and send pending signals (exec_signal)
        {
            const signals = state.drainSignals(info.hostname) catch &.{};
            if (signals.len > 0) {
                std.log.info("[ws] Drained {d} signals for {s}", .{ signals.len, info.hostname });
            }
            for (signals) |sig| {
                std.log.info("[ws] Sending signal {d} for cmd={s}", .{ sig.signal, sig.cmd_id });
                const sig_frame = try wsproto.buildExecSignal(allocator, sig.cmd_id, sig.signal);
                defer allocator.free(sig_frame);
                ws.writeMessage(sig_frame, .binary) catch |err| {
                    std.log.err("[ws] Signal write failed for {s}: {}", .{ info.hostname, err });
                };
                // flush to ensure signal is sent immediately
                ws.output.flush() catch |err| {
                    std.log.err("[ws] Signal flush failed: {}", .{err});
                };
                allocator.free(sig.cmd_id);
            }
            if (signals.len > 0) allocator.free(signals);
        }

        // 2. Read response from guest (blocks until Guest re-announces or
        //    sends a command response — Guest guarantees at least 1 msg/sec).
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
                        std.log.info("[ws] Re-announce from {s}", .{a.hostname});
                        _ = state.upsertGuest(a.hostname, a.ip, a.target, a.mac, a.version, a.shell);
                        if (state.on_guest_changed) |cb| cb(state);
                    }
                },
                @intFromEnum(wsproto.MsgType.exec_resp) => {
                    if (wsproto.parseExecResp(payload)) |resp| {
                        _ = state.deliverResult(resp.cmd_id, resp.stdout_data, resp.stderr_data, resp.exit_code);
                    }
                },
                @intFromEnum(wsproto.MsgType.exec_stdout) => {
                    if (wsproto.parseExecStdout(payload)) |chunk| {
                        state.deliverStdoutChunk(chunk.cmd_id, chunk.chunk);
                    }
                },
                @intFromEnum(wsproto.MsgType.exec_exit) => {
                    if (wsproto.parseExecExit(payload)) |exit_msg| {
                        _ = state.deliverExecExit(exit_msg.cmd_id, exit_msg.exit_code);
                    }
                },
                @intFromEnum(wsproto.MsgType.upload_resp) => {
                    if (wsproto.parseUploadResp(payload)) |resp| {
                        _ = state.deliverResult(resp.cmd_id, "", "", resp.exit_code);
                    }
                },
                @intFromEnum(wsproto.MsgType.download_resp) => {
                    if (wsproto.parseDownloadResp(payload)) |resp| {
                        _ = state.deliverResult(resp.cmd_id, resp.file_data, "", resp.exit_code);
                    }
                },
                else => {
                    std.log.debug("[ws] Unknown message type: {d}", .{resp_type});
                },
            }
        } else if (msg.opcode == .connection_close) {
            std.log.info("[ws] Guest {s} disconnected", .{info.hostname});
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

    // Build hosts entries from guest table
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
