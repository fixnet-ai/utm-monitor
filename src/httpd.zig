//! Minimal HTTP server on top of std.http.Server.
//!
//! Provides:
//!   - TCP accept loop with detached threads (same pattern as mcp.zig runHttp)
//!   - URL router dispatching on method + path
//!   - HostState: mutex-protected guest table + pending command queue
//!   - JSON helpers for reading POST bodies and building responses
//!
//! std.http.Server handles HTTP/1.1 parsing, keep-alive, and response formatting.
//! We add routing, concurrency, and application-level state.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

pub const DEFAULT_PORT: u16 = 2121;

// ═══════════════════════════════════════════════════════════════════════════
// JSON helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Parse a JSON string into a Value tree. Caller must call `defer parsed.deinit()`.
/// Returns Parsed(Value) which holds the arena that owns all string allocations.
pub fn parseJson(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{ .allocate = .alloc_always });
}

/// Get a string field from a JSON object. Returns null if missing or wrong type.
pub fn jsonGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get an integer field from a JSON object.
pub fn jsonGetInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Build a simple JSON object string. Caller owns returned memory.
pub fn buildJson(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, fmt, args);
}

/// Escape a string for JSON (minimal — only handles the common cases).
pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, s.len);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...7, 11, 14...31 => try buf.print(allocator, "\\u{d:0>4}", .{c}),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Application state (shared across all HTTP connection threads)
// ═══════════════════════════════════════════════════════════════════════════

pub const GuestEntry = struct {
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,
    mac: []const u8,
    version: []const u8,
    shell: []const u8,
    last_seen: i64, // monotonic milliseconds timestamp
};

/// Tracks the state of an in-flight operation (exec/upload/download).
pub const OpState = struct {
    output: std.ArrayList(u8),
    exit_code: i32 = -1,
    done: bool = false,
    /// Bytes already sent to streaming HTTP response.
    sent_pos: usize = 0,
};

pub const HostState = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Guest table — ArrayList with linear search (only ~3 VMs, no HashMap needed).
    guests: std.ArrayList(GuestEntry),
    /// Outgoing frame queue: hostname → FIFO of pre-built binary frames.
    /// HTTP handlers push frames, WebSocket handler drains them.
    outgoing_frames: std.StringHashMap(std.ArrayList([]const u8)),
    /// Operation state tracking: cmd_id → OpState.
    /// Used by exec/upload/download to track completion.
    op_states: std.StringHashMap(OpState),
    /// Close requests: hostname → present (flag set).
    /// HTTP --kick handler sets, WebSocket handler checks and consumes.
    close_requests: std.StringHashMap(void),
    /// Wake event: set when any OpState completes (marker found or completeOpState called).
    /// HTTP/MCP handlers wait on this instead of busy-polling takeOpResult.
    wake_event: std.Io.Event = .unset,
    allocator: std.mem.Allocator,
    /// I/O instance for network operations (shared across threads).
    io: ?std.Io = null,
    /// Directory to serve binary files from (for /bin/<file> and auto-upgrade).
    serve_dir: []const u8 = "/opt/utmm",
    /// Called when guest table changes (for /etc/hosts sync)
    on_guest_changed: ?*const fn (*HostState) void = null,

    pub fn init(allocator: std.mem.Allocator) HostState {
        return .{
            .guests = .empty,
            .outgoing_frames = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .op_states = std.StringHashMap(OpState).init(allocator),
            .close_requests = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HostState) void {
        // Free guest entries
        for (self.guests.items) |*entry| {
            self.allocator.free(entry.hostname);
            self.allocator.free(entry.ip);
            self.allocator.free(entry.target);
            self.allocator.free(entry.mac);
            self.allocator.free(entry.version);
            if (entry.shell.len > 0) self.allocator.free(entry.shell);
        }
        self.guests.deinit(self.allocator);

        // Free outgoing frames
        {
            var it = self.outgoing_frames.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |frame| {
                    self.allocator.free(frame);
                }
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            self.outgoing_frames.deinit();
        }

        // Free op states
        {
            var it = self.op_states.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.output.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            self.op_states.deinit();
        }

        // Free close requests
        {
            var it = self.close_requests.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.close_requests.deinit();
        }
    }

    /// Find a guest by hostname. Returns index into guests.items or null.
    fn guestIndex(self: *HostState, hostname: []const u8) ?usize {
        for (self.guests.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.hostname, hostname)) return i;
        }
        return null;
    }

    /// Check if a guest is in the table (caller MUST hold mutex).
    pub fn containsGuest(self: *HostState, hostname: []const u8) bool {
        return self.guestIndex(hostname) != null;
    }

    /// Upsert a guest from announce data (caller must own the strings — they are duplicated).
    /// Returns true if this is a new guest or IP/target/version/shell changed.
    pub fn upsertGuest(self: *HostState, hostname: []const u8, ip: []const u8, target: []const u8, mac: []const u8, version: []const u8, shell: []const u8) bool {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const now_ms = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(self.io.?, .real).nanoseconds, std.time.ns_per_ms)));

        if (self.guestIndex(hostname)) |idx| {
            var changed = false;
            const existing = &self.guests.items[idx];
            if (!std.mem.eql(u8, existing.ip, ip)) changed = true;
            if (!std.mem.eql(u8, existing.target, target)) changed = true;
            if (!std.mem.eql(u8, existing.version, version)) changed = true;
            if (!std.mem.eql(u8, existing.shell, shell)) changed = true;

            // Update fields (free old strings)
            if (!std.mem.eql(u8, existing.ip, ip)) {
                self.allocator.free(existing.ip);
                existing.ip = self.allocator.dupe(u8, ip) catch existing.ip;
            }
            if (!std.mem.eql(u8, existing.target, target)) {
                self.allocator.free(existing.target);
                existing.target = self.allocator.dupe(u8, target) catch existing.target;
            }
            if (!std.mem.eql(u8, existing.version, version)) {
                self.allocator.free(existing.version);
                existing.version = self.allocator.dupe(u8, version) catch existing.version;
            }
            if (!std.mem.eql(u8, existing.shell, shell)) {
                if (existing.shell.len > 0) self.allocator.free(existing.shell);
                existing.shell = self.allocator.dupe(u8, shell) catch existing.shell;
            }
            existing.last_seen = now_ms;
            return changed;
        }

        // New guest
        self.guests.append(self.allocator, .{
            .hostname = self.allocator.dupe(u8, hostname) catch hostname,
            .ip = self.allocator.dupe(u8, ip) catch ip,
            .target = self.allocator.dupe(u8, target) catch target,
            .mac = self.allocator.dupe(u8, mac) catch mac,
            .version = self.allocator.dupe(u8, version) catch version,
            .shell = if (shell.len > 0) self.allocator.dupe(u8, shell) catch shell else "",
            .last_seen = now_ms,
        }) catch return false;
        return true;
    }

    /// Remove a guest and free its strings. Safe to call even if guest doesn't exist.
    pub fn removeGuest(self: *HostState, hostname: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const idx = self.guestIndex(hostname) orelse return;
        const entry = self.guests.swapRemove(idx);
        self.allocator.free(entry.hostname);
        self.allocator.free(entry.ip);
        self.allocator.free(entry.target);
        self.allocator.free(entry.mac);
        self.allocator.free(entry.version);
        if (entry.shell.len > 0) self.allocator.free(entry.shell);
    }

    // ══════════════════════════════════════════════════════════
    // Outgoing frame queue (HTTP handlers push, WS handler drains)
    // ══════════════════════════════════════════════════════════

    /// Push a pre-built binary frame to a guest's outgoing queue.
    pub fn enqueueOutgoingFrame(self: *HostState, hostname: []const u8, frame: []const u8) !void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const gop = try self.outgoing_frames.getOrPut(hostname);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, hostname);
            gop.value_ptr.* = .empty;
        }
        const frame_owned = try self.allocator.dupe(u8, frame);
        try gop.value_ptr.append(self.allocator, frame_owned);
    }

    /// Pop the next frame from a guest's outgoing queue (FIFO).
    /// Returns null if no frames queued. Caller owns the returned frame data.
    pub fn dequeueOutgoingFrame(self: *HostState, hostname: []const u8) ?[]const u8 {
        self.mutex.lock(self.io.?) catch return null;
        defer self.mutex.unlock(self.io.?);

        const list = self.outgoing_frames.getPtr(hostname) orelse return null;
        if (list.items.len == 0) return null;
        return list.orderedRemove(0);
    }

    // ══════════════════════════════════════════════════════════
    // Operation state (tracks exec/upload/download completion)
    // ══════════════════════════════════════════════════════════

    /// Initialize an OpState for a new command. cmd_id must be unique.
    pub fn createOpState(self: *HostState, cmd_id: []const u8) !void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const gop = try self.op_states.getOrPut(cmd_id);
        if (gop.found_existing) {
            gop.value_ptr.output.deinit(self.allocator);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, cmd_id);
        }
        gop.value_ptr.* = .{ .output = .empty };
    }

    /// Append data to an operation's accumulated output.
    pub fn appendOpOutput(self: *HostState, cmd_id: []const u8, data: []const u8) void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        op.output.appendSlice(self.allocator, data) catch {};
    }

    /// Scan accumulated output for MDELIM:N\n marker.
    /// If found, strips the marker, sets exit_code and marks done.
    pub fn scanForMarker(self: *HostState, cmd_id: []const u8) void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        if (op.done) return;

        const haystack = op.output.items;
        const marker = "MDELIM:";

        // Use lastIndexOf: the real marker is always LAST in the output stream.
        // When pty ECHO is ON, echoed command text also contains "MDELIM:" but
        // appears before actual command output. We validate the exit code region
        // so echoed "$?" (non-digit) fails to match.
        const pos = std.mem.lastIndexOf(u8, haystack, marker) orelse return;

        // Validate exit code: region between MDELIM: and \n must contain
        // only digits and optional leading '-'. Echoed text like "MDELIM:$?\n"
        // fails this check.
        const after = pos + marker.len;
        if (after >= haystack.len) return;

        var ec: i32 = 0;
        var neg = false;
        var i: usize = after;
        var has_digit = false;
        while (i < haystack.len and haystack[i] != '\n') : (i += 1) {
            if (haystack[i] == '\r') {
                // CR before LF — skip, part of CRLF line ending
            } else if (haystack[i] == '-') {
                if (has_digit) return; // '-' not at start — invalid
                neg = true;
            } else if (haystack[i] >= '0' and haystack[i] <= '9') {
                has_digit = true;
                ec = ec * 10 + @as(i32, @intCast(haystack[i] - '0'));
            } else {
                // Non-digit, non-CR, non-dash character (e.g. '$', '?' from echoed text).
                // This is not the real marker — wait for more data.
                return;
            }
        }
        if (i >= haystack.len) return; // No newline yet, wait for more data
        if (!has_digit) return;        // No digits found — invalid marker
        if (neg) ec = -ec;

        // Strip marker + exit code + newline.
        // Marker is always at the end (appended via "; echo MDELIM:$?\n"),
        // so truncating at the marker position is safe.
        op.output.shrinkRetainingCapacity(pos);

        // After shrinking, sent_pos might point past the new end.
        // Clamp it so the streaming handler doesn't miss the remaining data.
        if (op.sent_pos > op.output.items.len) {
            op.sent_pos = op.output.items.len;
        }

        op.exit_code = ec;
        op.done = true;
        // Wake HTTP/MCP handlers waiting on takeOpResult
        self.wake_event.set(self.io.?);
    }

    /// Mark an operation as complete with explicit exit code.
    /// Used for upload/download responses.
    pub fn completeOpState(self: *HostState, cmd_id: []const u8, exit_code: i32) void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        op.exit_code = exit_code;
        op.done = true;
        self.wake_event.set(self.io.?);
    }

    /// Take the result of a completed operation. Returns null if not yet done.
    /// On success, removes the operation state. Caller owns stdout string.
    pub fn takeOpResult(self: *HostState, cmd_id: []const u8) ?struct { stdout: []const u8, exit: i32 } {
        self.mutex.lock(self.io.?) catch return null;
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return null;
        if (!op.done) return null;

        const stdout_owned = op.output.toOwnedSlice(self.allocator) catch "";
        const exit = op.exit_code;

        // Remove from map
        if (self.op_states.fetchRemove(cmd_id)) |kv| {
            var out = kv.value.output;
            out.deinit(self.allocator);
            self.allocator.free(kv.key);
        }

        return .{ .stdout = stdout_owned, .exit = exit };
    }

    /// Remove an operation state entry, freeing all memory.
    /// Safe to call on non-existent cmd_id (no-op).
    pub fn cleanupOpState(self: *HostState, cmd_id: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        if (self.op_states.fetchRemove(cmd_id)) |kv| {
            var output = kv.value.output;
            output.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    /// Fail all pending operations (called on guest disconnect).
    /// Wakes all HTTP/MCP handlers waiting on wake_event so they
    /// can return errors instead of blocking forever.
    pub fn failAllPendingOps(self: *HostState) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        var it = self.op_states.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.done) {
                entry.value_ptr.output.clearRetainingCapacity();
                entry.value_ptr.output.appendSlice(self.allocator, "guest disconnected") catch {};
                entry.value_ptr.exit_code = -1;
                entry.value_ptr.done = true;
            }
        }
        self.wake_event.set(self.io.?);
    }

    // ══════════════════════════════════════════════════════════
    // Close requests (--kick)
    // ══════════════════════════════════════════════════════════

    /// Mark a guest for WebSocket close (--kick).
    pub fn requestClose(self: *HostState, hostname: []const u8) !void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);
        const gop = try self.close_requests.getOrPut(hostname);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, hostname);
        }
        // Wake any HTTP handlers waiting on commands for this guest
        self.wake_event.set(self.io.?);
    }

    /// Check if a guest is marked for kick, and consume the flag.
    pub fn checkCloseRequested(self: *HostState, hostname: []const u8) bool {
        self.mutex.lock(self.io.?) catch return false;
        defer self.mutex.unlock(self.io.?);
        if (self.close_requests.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// HTTP router
// ═══════════════════════════════════════════════════════════════════════════

pub const HandlerFn = *const fn (
    allocator: std.mem.Allocator,
    state: *HostState,
    request: *http.Server.Request,
    body: ?[]const u8,
) anyerror!void;

const Route = struct {
    method: http.Method,
    /// Path prefix match (e.g. "/mcp", "/announce", "/bin/")
    path: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    routes: std.ArrayListUnmanaged(Route) = .empty,

    pub fn deinit(self: *Router, allocator: std.mem.Allocator) void {
        self.routes.deinit(allocator);
    }

    pub fn add(self: *Router, allocator: std.mem.Allocator, method: http.Method, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{
            .method = method,
            .path = path,
            .handler = handler,
        });
    }

    /// Find matching route and call handler, or return 404.
    pub fn dispatch(
        self: *Router,
        allocator: std.mem.Allocator,
        state: *HostState,
        request: *http.Server.Request,
        body: ?[]const u8,
    ) void {
        const target = request.head.target;
        const method = request.head.method;

        for (self.routes.items) |route| {
            if (route.method == method and std.mem.startsWith(u8, target, route.path)) {
                route.handler(allocator, state, request, body) catch |err| {
                    std.log.err("[httpd] Handler error for {s} {s}: {}", .{ @tagName(method), target, err });
                };
                return;
            }
        }

        // 404
        const not_found = "{\"error\":\"not found\"}";
        request.respond(not_found, .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        }) catch {};
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// HTTP server — TCP accept loop
// ═══════════════════════════════════════════════════════════════════════════

/// Context passed to each connection handler thread.
const ConnCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: *std.Io.net.Stream,
    router: *Router,
    state: *HostState,
};

/// Start the HTTP server. Blocks forever (accept loop).
/// Caller must provide its own I/O instance with worker threads (Threaded.init).
/// Build command with appropriate marker for the guest's shell.
/// POSIX (/bin/sh, /bin/bash, ...): uses "; echo MDELIM:$?\n"
/// Windows (cmd.exe): uses "& echo MDELIM:%errorlevel%\r\n"
pub fn buildCmdWithMarker(allocator: std.mem.Allocator, shell: []const u8, command: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, shell, "cmd.exe") != null) {
        return try std.fmt.allocPrint(allocator, "{s} & echo MDELIM:%errorlevel%\r\n", .{command});
    }
    return try std.fmt.allocPrint(allocator, "{s}; echo MDELIM:$?\n", .{command});
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    router: *Router,
    state: *HostState,
    port: u16,
) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("[httpd] HTTP server on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("[httpd] Accept error: {}", .{err});
            continue;
        };

        const conn = allocator.create(std.Io.net.Stream) catch |err| {
            std.log.err("[httpd] Alloc error: {}", .{err});
            stream.close(io);
            continue;
        };
        conn.* = stream;

        const ctx = allocator.create(ConnCtx) catch |err| {
            std.log.err("[httpd] Alloc ctx error: {}", .{err});
            conn.close(io);
            allocator.destroy(conn);
            continue;
        };
        ctx.* = .{
            .io = io,
            .allocator = allocator,
            .stream = conn,
            .router = router,
            .state = state,
        };

        const t = std.Thread.spawn(.{}, handleConnection, .{ctx}) catch |err| {
            std.log.err("[httpd] Thread spawn error: {}", .{err});
            conn.close(io);
            allocator.destroy(conn);
            allocator.destroy(ctx);
            continue;
        };
        t.detach();
    }
}

/// Per-connection thread: parse HTTP request, dispatch to router, handle keep-alive.
/// Each handler is responsible for reading the body via request.readerExpectNone() if needed
/// and sending the response via request.respond().
fn handleConnection(ctx: *ConnCtx) void {
    defer {
        ctx.stream.close(ctx.io);
        ctx.allocator.destroy(ctx.stream);
        ctx.allocator.destroy(ctx);
    }

    var rbuf: [65536]u8 = undefined;
    var reader = ctx.stream.reader(ctx.io, &rbuf);
    var wbuf: [65536]u8 = undefined;
    var writer = ctx.stream.writer(ctx.io, &wbuf);

    var http_srv = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = http_srv.receiveHead() catch |err| {
            if (err != error.HttpHeadersInvalid) break;
            const resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = writer.interface.write(resp) catch {};
            writer.interface.flush() catch {};
            break;
        };

        ctx.router.dispatch(ctx.allocator, ctx.state, &request, null);

        if (!request.head.keep_alive) break;
    }
}
