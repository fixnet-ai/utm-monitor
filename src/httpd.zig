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

pub const CmdType = enum { exec, upgrade, upload, download };

pub const CmdStatus = enum { pending, dispatched, completed };

pub const PendingCmd = struct {
    id: []const u8,
    cmd_type: CmdType,
    /// exec: shell command; upgrade: download URL path; download: filename
    payload: []const u8,
    /// Set when guest posts result back
    result: ?CmdResult = null,
    /// Lifecycle: pending → dispatched (Guest fetched via /announce) → completed (result posted)
    status: CmdStatus = .pending,
    /// Accumulated stdout chunks from streaming exec (exec_stdout frames).
    /// Caller must deinit when freeing the cmd.
    partial_stdout: std.ArrayList(u8) = .empty,
};

pub const CmdResult = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit: i32 = 0,
};

pub const SignalEntry = struct {
    cmd_id: []const u8,
    signal: u8, // 0=SIGINT, 1=SIGTERM
};

pub const HostState = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Guest table — ArrayList with linear search (only ~3 VMs, no HashMap needed).
    guests: std.ArrayList(GuestEntry),
    pending: std.StringHashMap(std.ArrayList(PendingCmd)),
    /// Pending signals to be delivered via WebSocket. Keyed by hostname.
    pending_signals: std.StringHashMap(std.ArrayList(SignalEntry)),
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
            .pending = std.StringHashMap(std.ArrayList(PendingCmd)).init(allocator),
            .pending_signals = std.StringHashMap(std.ArrayList(SignalEntry)).init(allocator),
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

        // Free pending commands
        var pit = self.pending.iterator();
        while (pit.next()) |entry| {
            for (entry.value_ptr.items) |*cmd| {
                self.allocator.free(cmd.id);
                self.allocator.free(cmd.payload);
                cmd.partial_stdout.deinit(self.allocator);
                if (cmd.result) |*r| {
                    if (r.stdout.len > 0) self.allocator.free(r.stdout);
                    if (r.stderr.len > 0) self.allocator.free(r.stderr);
                }
            }
            entry.value_ptr.deinit(self.allocator);
        }
        // Free pending signals
        var sit = self.pending_signals.iterator();
        while (sit.next()) |entry| {
            for (entry.value_ptr.items) |*sig| {
                self.allocator.free(sig.cmd_id);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_signals.deinit();

        self.pending.deinit();
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

    /// Enqueue a pending command for a guest. Returns the command id (caller owns).
    pub fn enqueueCmd(self: *HostState, hostname: []const u8, cmd_type: CmdType, payload: []const u8) ![]const u8 {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const gop = try self.pending.getOrPut(hostname);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }

        var buf: [16]u8 = undefined;
        const ts: i64 = @intCast(@as(i64, @intCast(@divFloor(std.Io.Timestamp.now(self.io.?, .real).nanoseconds, std.time.ns_per_ms))));
        const id = try std.fmt.bufPrint(&buf, "{d}", .{ts});
        const cmd = PendingCmd{
            .id = try self.allocator.dupe(u8, id),
            .cmd_type = cmd_type,
            .payload = try self.allocator.dupe(u8, payload),
        };
        try gop.value_ptr.append(self.allocator, cmd);
        return try self.allocator.dupe(u8, id);
    }

    /// Return all undispatched (status=pending) commands for a guest.
    /// Marks returned commands as dispatched. Caller owns returned slice and items.
    pub fn drainPending(self: *HostState, hostname: []const u8) ![]PendingCmd {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const list = self.pending.getPtr(hostname) orelse return &.{};

        // Count pending commands
        var count: usize = 0;
        for (list.items) |*cmd| {
            if (cmd.status == .pending) count += 1;
        }
        if (count == 0) return &.{};

        // Collect copies, mark dispatched (use index for mutable access)
        var result = try self.allocator.alloc(PendingCmd, count);
        errdefer self.allocator.free(result);
        var i: usize = 0;
        const items_mut: []PendingCmd = @constCast(list.items);
        for (items_mut) |*cmd| {
            if (cmd.status == .pending) {
                cmd.status = .dispatched;
                result[i] = PendingCmd{
                    .id = try self.allocator.dupe(u8, cmd.id),
                    .cmd_type = cmd.cmd_type,
                    .payload = try self.allocator.dupe(u8, cmd.payload),
                    .status = .dispatched,
                };
                i += 1;
            }
        }
        return result;
    }

    /// Deliver a command result (from guest's /exec-result POST).
    pub fn deliverResult(self: *HostState, cmd_id: []const u8, stdout: []const u8, stderr: []const u8, exit: i32) bool {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        var pit = self.pending.iterator();
        while (pit.next()) |entry| {
            for (entry.value_ptr.items) |*cmd| {
                if (std.mem.eql(u8, cmd.id, cmd_id)) {
                    cmd.result = CmdResult{
                        .stdout = if (stdout.len > 0) self.allocator.dupe(u8, stdout) catch stdout else "",
                        .stderr = if (stderr.len > 0) self.allocator.dupe(u8, stderr) catch stderr else "",
                        .exit = exit,
                    };
                    cmd.status = .completed;
                    return true;
                }
            }
        }
        return false;
    }

    /// Deliver a stdout chunk from streaming exec (exec_stdout frame from Guest).
    pub fn deliverStdoutChunk(self: *HostState, cmd_id: []const u8, chunk: []const u8) void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        var pit = self.pending.iterator();
        while (pit.next()) |entry| {
            for (entry.value_ptr.items) |*cmd| {
                if (std.mem.eql(u8, cmd.id, cmd_id)) {
                    cmd.partial_stdout.appendSlice(self.allocator, chunk) catch {};
                    return;
                }
            }
        }
    }

    /// Deliver exec_exit from streaming exec: builds result from accumulated stdout
    /// chunks, marks command as completed. Returns false if cmd_id not found.
    pub fn deliverExecExit(self: *HostState, cmd_id: []const u8, exit_code: i32) bool {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        var pit = self.pending.iterator();
        while (pit.next()) |entry| {
            for (entry.value_ptr.items) |*cmd| {
                if (std.mem.eql(u8, cmd.id, cmd_id)) {
                    const stdout_owned = cmd.partial_stdout.toOwnedSlice(self.allocator) catch "";
                    cmd.result = CmdResult{
                        .stdout = stdout_owned,
                        .stderr = "",
                        .exit = exit_code,
                    };
                    cmd.status = .completed;
                    return true;
                }
            }
        }
        return false;
    }

    /// Try to take a completed command result. Returns null if not yet completed.
    /// On success, removes the command from pending and caller owns the CmdResult strings.
    pub fn tryTakeResult(self: *HostState, cmd_id: []const u8) ?CmdResult {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        var pit = self.pending.iterator();
        while (pit.next()) |entry| {
            for (entry.value_ptr.items, 0..) |cmd, j| {
                if (std.mem.eql(u8, cmd.id, cmd_id) and cmd.status == .completed) {
                    const result = cmd.result orelse return null;
                    // Free cmd metadata before removing
                    self.allocator.free(cmd.id);
                    self.allocator.free(cmd.payload);
                    // Remove this command from the list (swap-remove for O(1))
                    _ = entry.value_ptr.swapRemove(j);
                    return result;
                }
            }
        }
        return null;
    }

    /// Enqueue a signal to be sent to a guest via WebSocket.
    pub fn enqueueSignal(self: *HostState, hostname: []const u8, cmd_id: []const u8, signal: u8) !void {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const gop = try self.pending_signals.getOrPut(hostname);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, .{
            .cmd_id = try self.allocator.dupe(u8, cmd_id),
            .signal = signal,
        });
    }

    /// Drain all pending signals for a hostname. Caller owns returned slice and items.
    pub fn drainSignals(self: *HostState, hostname: []const u8) ![]SignalEntry {
        self.mutex.lock(self.io.?) catch {};
        defer self.mutex.unlock(self.io.?);

        const list = self.pending_signals.getPtr(hostname) orelse return &.{};
        if (list.items.len == 0) return &.{};

        const result = try list.toOwnedSlice(self.allocator);
        list.deinit(self.allocator);
        _ = self.pending_signals.remove(hostname);
        return result;
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
