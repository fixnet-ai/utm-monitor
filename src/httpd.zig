//! Minimal HTTP server on top of std.http.Server.
//!
//! Provides:
//!   - TCP accept loop with detached threads
//!   - URL router dispatching on method + path
//!   - HostState: mutex-protected guest table + pending command queue
//!   - JSON helpers for reading POST bodies and building responses
//!
//! std.http.Server handles HTTP/1.1 parsing, keep-alive, and response formatting.
//! We add routing, concurrency, and application-level state.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const protocol = @import("protocol.zig");
const hosts_file = @import("hosts_file.zig");
const tunnel_mod = @import("tunnel.zig");
const tunproto = @import("tunproto.zig");
const mesh_mod = @import("mesh.zig");

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
            // Control characters and DEL: escape as \uXXXX
            // JSON requires escaping all control chars (0x00-0x1F)
            // except the ones handled above. 0x7F (DEL) should also
            // be escaped for safety.
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try buf.print(allocator, "\\u{d:0>4}", .{c}),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Get a nested object field from a JSON object. Returns null if missing or wrong type.
pub fn jsonGetNestedObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |inner| inner,
        else => null,
    };
}

/// Append a JSON-RPC id value to a buffer (handles all id types).
pub fn jsonAppendId(list: *std.ArrayList(u8), allocator: std.mem.Allocator, id: std.json.Value) !void {
    switch (id) {
        .null => try list.appendSlice(allocator, "null"),
        .integer => |n| try list.print(allocator, "{d}", .{n}),
        .string => |s| try list.print(allocator, "\"{s}\"", .{s}),
        .float => |f| try list.print(allocator, "{d}", .{f}),
        .number_string => |s| try list.appendSlice(allocator, s),
        .bool => |b| try list.appendSlice(allocator, if (b) "true" else "false"),
        else => try list.appendSlice(allocator, "null"),
    }
}

/// Build a JSON-RPC success response.
pub fn jsonBuildResponse(allocator: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC error response.
pub fn jsonBuildError(allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id);
    try buf.print(allocator, ",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    const escaped_msg = try jsonEscape(allocator, message);
    defer allocator.free(escaped_msg);
    try buf.appendSlice(allocator, escaped_msg);
    try buf.appendSlice(allocator, "\"}}");
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
    status: []const u8, // "serving" | "upgrading" | "" (from LSA, for upgrade tracking)
    last_seen: i64, // monotonic milliseconds timestamp
    mesh_mac: ?[6]u8 = null, // parsed MAC for mesh routing (v0.10.0+)
};

/// Tracks the state of an in-flight operation (exec/upload/download).
pub const OpState = struct {
    output: std.ArrayList(u8),
    exit_code: i32 = -1,
    done: bool = false,
    /// Bytes already sent to streaming HTTP response.
    sent_pos: usize = 0,
    /// File metadata from file_eof (for x-file-hash/x-file-size trailers).
    file_hash: []const u8 = "",
    file_size_meta: u32 = 0,
    /// Monotonic ms timestamp when this op was created.
    /// Used for automatic cleanup of orphaned operations
    /// (client disconnected before receiving the result).
    created_ms: u64 = 0,
};

/// Maximum number of concurrent file transfers (upload + download).
/// Prevents unbounded transfers HashMap growth.
pub const MAX_CONCURRENT_TRANSFERS: usize = 16;

/// Stale OpState older than this is eligible for automatic cleanup
/// (client disconnected before receiving the result).
const OP_STATE_TIMEOUT_MS: u64 = 5 * 60 * 1000; // 5 minutes

/// Tracks an in-flight file transfer for singleton deduplication.
/// Key format: "<vm>:<path>" — destination path determines uniqueness,
/// not who initiated the transfer. Upload and download to the same
/// (vm, path) also share a key (they can't sensibly run concurrently).
pub const TransferState = struct {
    cmd_id: []const u8,
    file_size: u32,
    bytes_transferred: u32 = 0,
};

pub const HostState = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Guest table — ArrayList with linear search (only ~3 VMs, no HashMap needed).
    guests: std.ArrayList(GuestEntry),
    /// Guest tunnel mapping: hostname → KCP Tunnel pointer.
    /// HTTP handlers send frames via tunnel.send(), handler threads recv responses.
    guest_tunnels: std.StringHashMap(*tunnel_mod.Tunnel),
    /// Operation state tracking: cmd_id → OpState.
    /// Used by exec/upload/download to track completion.
    op_states: std.StringHashMap(OpState),
    /// Transfer state tracking: transfer_key → TransferState.
    /// Used for upload/download singleton deduplication.
    transfers: std.StringHashMap(TransferState),
    /// Wake event: set when any OpState completes (marker found or completeOpState called).
    /// HTTP handlers wait on this instead of busy-polling takeOpResult.
    wake_event: std.Io.Event = .unset,
    allocator: std.mem.Allocator,
    /// I/O instance for network operations (shared across threads).
    io: ?std.Io = null,
    /// Directory to serve binary files from (for /bin/<file> and auto-upgrade).
    serve_dir: []const u8 = "/opt/utmm",
    /// Called when guest table changes (for /etc/hosts sync)
    on_guest_changed: ?*const fn (*HostState) void = null,
    /// Mesh networking instance (v0.10.0+, *mesh.Mesh). Set by host.zig when mesh is active.
    /// Type-erased to avoid circular dependency. Cast with @ptrCast(@alignCast(...)).
    mesh: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) HostState {
        return .{
            .guests = .empty,
            .guest_tunnels = std.StringHashMap(*tunnel_mod.Tunnel).init(allocator),
            .op_states = std.StringHashMap(OpState).init(allocator),
            .transfers = std.StringHashMap(TransferState).init(allocator),
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

        // Free guest tunnels (just deinit the map — tunnels are owned by handler threads)
        {
            var it = self.guest_tunnels.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.guest_tunnels.deinit();
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

        // Free transfers
        {
            var it = self.transfers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.cmd_id);
                self.allocator.free(entry.key_ptr.*);
            }
            self.transfers.deinit();
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
    pub fn upsertGuest(self: *HostState, hostname: []const u8, ip: []const u8, target: []const u8, mac: []const u8, version: []const u8, shell: []const u8, status: []const u8) bool {
        self.mutex.lock(self.io.?) catch return false;
        defer self.mutex.unlock(self.io.?);

        const now_ms = @as(i64, @intCast(@divFloor(std.Io.Timestamp.now(self.io.?, .real).nanoseconds, std.time.ns_per_ms)));

        if (self.guestIndex(hostname)) |idx| {
            var changed = false;
            const existing = &self.guests.items[idx];
            if (!std.mem.eql(u8, existing.ip, ip)) changed = true;
            if (!std.mem.eql(u8, existing.target, target)) changed = true;
            if (!std.mem.eql(u8, existing.version, version)) changed = true;
            if (!std.mem.eql(u8, existing.shell, shell)) changed = true;
            if (!std.mem.eql(u8, existing.status, status)) changed = true;

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
            if (!std.mem.eql(u8, existing.status, status)) {
                if (existing.status.len > 0) self.allocator.free(existing.status);
                existing.status = self.allocator.dupe(u8, status) catch existing.status;
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
            .status = if (status.len > 0) self.allocator.dupe(u8, status) catch status else "",
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
        if (entry.status.len > 0) self.allocator.free(entry.status);
    }

    /// Set the parsed mesh MAC for a guest (v0.10.0+ mesh support).
    pub fn setGuestMeshMac(self: *HostState, hostname: []const u8, mac_bytes: [6]u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const idx = self.guestIndex(hostname) orelse return;
        self.guests.items[idx].mesh_mac = mac_bytes;
    }

    // ══════════════════════════════════════════════════════════
    // Guest tunnel registry (Host threads push, handler threads drain)
    // ══════════════════════════════════════════════════════════

    /// Register a KCP tunnel for a guest. Called by the LSA callback when
    /// Host establishes a tunnel to a discovered guest.
    pub fn registerGuestTunnel(self: *HostState, hostname: []const u8, tun: *tunnel_mod.Tunnel) !void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const gop = try self.guest_tunnels.getOrPut(hostname);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, hostname);
        }
        gop.value_ptr.* = tun;
    }

    /// Look up a guest's KCP tunnel. Returns null if no tunnel registered.
    pub fn getGuestTunnel(self: *HostState, hostname: []const u8) ?*tunnel_mod.Tunnel {
        self.mutex.lock(self.io.?) catch return null;
        defer self.mutex.unlock(self.io.?);

        return self.guest_tunnels.get(hostname);
    }

    /// Check if a guest's tunnel is dead. Returns true if:
    /// - no tunnel is registered for this guest
    /// - the tunnel's isAlive() returns false
    /// Safe to call from tunnelManager — holds state.mutex across the
    /// lookup + isAlive check, preventing use-after-free when the mesh
    /// handler thread concurrently frees the tunnel.
    pub fn isTunnelDead(self: *HostState, hostname: []const u8) bool {
        self.mutex.lock(self.io.?) catch return true;
        defer self.mutex.unlock(self.io.?);

        const tun = self.guest_tunnels.get(hostname) orelse return true;
        return !tun.isAlive();
    }

    /// Remove a guest's tunnel registration. Called when tunnel disconnects.
    pub fn removeGuestTunnel(self: *HostState, hostname: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        if (self.guest_tunnels.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    // ══════════════════════════════════════════════════════════
    // Operation state (tracks exec/upload/download completion)
    // ══════════════════════════════════════════════════════════

    /// Initialize an OpState for a new command. cmd_id must be unique.
    pub fn createOpState(self: *HostState, cmd_id: []const u8) !void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const gop = try self.op_states.getOrPut(cmd_id);
        if (gop.found_existing) {
            gop.value_ptr.output.deinit(self.allocator);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, cmd_id);
        }
        gop.value_ptr.* = .{
            .output = .empty,
            .created_ms = @intCast(@divFloor(std.Io.Timestamp.now(self.io.?, .awake).nanoseconds, std.time.ns_per_ms)),
        };
    }

    /// Append data to an operation's accumulated output.
    pub fn appendOpOutput(self: *HostState, cmd_id: []const u8, data: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        op.output.appendSlice(self.allocator, data) catch {};
    }

    /// Scan accumulated output for MDELIM:N\n marker.
    /// If found, strips the marker, sets exit_code and marks done.
    pub fn scanForMarker(self: *HostState, cmd_id: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
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
        // Wake HTTP handlers waiting on takeOpResult
        self.wake_event.set(self.io.?);
    }

    /// Mark an operation as complete with explicit exit code.
    /// Used for upload/download responses.
    pub fn completeOpState(self: *HostState, cmd_id: []const u8, exit_code: i32) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        op.exit_code = exit_code;
        op.done = true;
        self.wake_event.set(self.io.?);
    }

    /// Check if an operation is already marked done (thread-safe).
    /// Used to avoid redundant completions (e.g. MDELIM + pty_exec_done).
    pub fn isOpDone(self: *HostState, cmd_id: []const u8) bool {
        self.mutex.lock(self.io.?) catch return false;
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return false;
        return op.done;
    }

    /// Set file metadata on an op state (for download x-file-hash/x-file-size trailers).
    pub fn setOpFileMeta(self: *HostState, cmd_id: []const u8, file_hash: []const u8, file_size_meta: u32) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const op = self.op_states.getPtr(cmd_id) orelse return;
        if (op.file_hash.len > 0) self.allocator.free(op.file_hash);
        op.file_hash = if (file_hash.len > 0) self.allocator.dupe(u8, file_hash) catch "" else "";
        op.file_size_meta = file_size_meta;
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

    // ══════════════════════════════════════════════════════════
    // Transfer state tracking (upload/download singleton dedup)
    // ══════════════════════════════════════════════════════════

    /// Look up an in-progress transfer by key. Returns null if not found.
    /// Caller MUST hold mutex.
    pub fn findTransfer(self: *HostState, key: []const u8) ?TransferState {
        return self.transfers.get(key);
    }

    /// Clean up op states that have been idle for too long (5 min).
    /// These are operations where the client disconnected before completion.
    /// Safe to call periodically — only removes stale, non-done ops.
    pub fn cleanupStaleOps(self: *HostState) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        const now_ms = @divFloor(std.Io.Timestamp.now(self.io.?, .awake).nanoseconds, std.time.ns_per_ms);
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.op_states.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.done) continue; // don't clean done ops (takeOpResult handles those)
            const age = now_ms -| entry.value_ptr.created_ms;
            if (age > OP_STATE_TIMEOUT_MS) {
                stale.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (stale.items) |cmd_id| {
            std.log.info("[httpd] cleaning up stale OpState: {s}", .{cmd_id});
            if (self.op_states.fetchRemove(cmd_id)) |kv| {
                var output = kv.value.output;
                output.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
        }
    }

    /// Register a new transfer. Caller MUST hold mutex.
    pub fn registerTransfer(self: *HostState, key: []const u8, cmd_id: []const u8, file_size: u32) !void {
        // Reject new transfers if at capacity
        if (self.transfers.count() >= MAX_CONCURRENT_TRANSFERS) {
            return error.TransferLimitExceeded;
        }
        const gop = try self.transfers.getOrPut(key);
        if (gop.found_existing) {
            // Replace existing — free old cmd_id
            self.allocator.free(gop.value_ptr.cmd_id);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = .{
            .cmd_id = try self.allocator.dupe(u8, cmd_id),
            .file_size = file_size,
            .bytes_transferred = 0,
        };
    }

    /// Update bytes_transferred for a transfer by cmd_id.
    pub fn updateTransferProgress(self: *HostState, cmd_id: []const u8, bytes: u32) void {
        var it = self.transfers.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.cmd_id, cmd_id)) {
                entry.value_ptr.bytes_transferred = bytes;
                if (entry.value_ptr.file_size == 0 and bytes > 0) {
                    entry.value_ptr.file_size = bytes;
                }
                return;
            }
        }
    }

    /// Remove a transfer by key. Safe to call on non-existent key.
    pub fn removeTransfer(self: *HostState, key: []const u8) void {
        self.mutex.lock(self.io.?) catch return;
        defer self.mutex.unlock(self.io.?);

        if (self.transfers.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.cmd_id);
            self.allocator.free(kv.key);
        }
    }

    /// Fail all pending operations (called on guest disconnect).
    /// Wakes all HTTP handlers waiting on wake_event so they
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
    /// Path prefix match (e.g. "/exec", "/bin/", "/api/guests")
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
    shutdown: ?*std.atomic.Value(bool),
) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("[httpd] HTTP server on 0.0.0.0:{d}", .{port});

    while (true) {
        // Check for Windows service shutdown before blocking on accept
        if (shutdown) |s| {
            if (s.load(.acquire)) {
                std.log.info("[httpd] Shutdown requested, stopping accept loop", .{});
                break;
            }
        }

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

// ═══════════════════════════════════════════════════════════════════════════
// HTTP endpoint handlers
// ═══════════════════════════════════════════════════════════════════════════

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
/// Safely handles both pre-body-read (reader in .received_head) and post-body-read
/// states. In the pre-body-read case, uses a direct write to avoid discardBody's
/// assert on missing Content-Length for POST requests.
fn respondError(request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    // If the reader is still in .received_head state and this is a POST request
    // without transfer-encoding or content-length, request.respond() would call
    // discardBody() which asserts → unreachable panic. Use the direct path instead.
    if (request.server.reader.state == .received_head and
        request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and
        request.head.content_length == null)
    {
        return respondErrorDirect(request, status, message);
    }
    try request.respond(message, .{
        .status = status,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
    });
}

/// Respond with an HTTP error bypassing request.respond()'s discardBody assert.
/// Use this ONLY when the request body could not be read (e.g. missing Content-Length),
/// because calling request.respond() would trigger discardBody() → assert → unreachable panic.
/// Writes directly to the server output and sets reader state to .closing to prevent
/// subsequent response attempts.
fn respondErrorDirect(request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    const phrase = status.phrase() orelse "";
    const out = request.server.out;
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), phrase });
    try out.writeAll("connection: close\r\n");
    try out.print("content-length: {d}\r\n", .{message.len});
    try out.writeAll("Content-Type: text/plain\r\n\r\n");
    try out.writeAll(message);
    try out.flush();
    // Prevent further response attempts on this connection.
    request.server.reader.state = .closing;
}

// ── POST /exec ────────────────────────────────────────────────────────────

pub fn handleExec(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const body_str = readBody(allocator, request) catch |err| {
        std.log.err("[exec] readBody failed: {}", .{err});
        try respondErrorDirect(request, .bad_request, "Missing body");
        return;
    };
    defer allocator.free(body_str);

    const parsed = parseJson(allocator, body_str) catch {
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

    const vm = jsonGetString(obj, "vm") orelse {
        try respondError(request, .bad_request, "Missing 'vm' field");
        return;
    };
    const command = jsonGetString(obj, "command") orelse {
        try respondError(request, .bad_request, "Missing 'command' field");
        return;
    };

    std.log.info("[exec] cmd for {s}: {s}", .{ vm, command });

    // Check guest exists and get shell type (block-scoped lock to avoid
    // self-deadlock with internal locking in createOpState/getGuestTunnel).
    const guest_shell = blk: {
        state.mutex.lock(state.io.?) catch return;
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
    const cmd_with_marker = try buildCmdWithMarker(allocator, guest_shell, command);
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
    body_writer.flush() catch |err| {
        std.log.err("[exec] header flush failed for {s}: {}", .{ cmd_id, err });
        return;
    };
    var chunked_ended = false;
    defer if (!chunked_ended) {
        body_writer.endChunked(.{}) catch {};
    };

    // Loop: write new output chunks as they arrive
    while (true) {
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
                break :blk op.output.items[start..];
            }
            break :blk @as(?[]const u8, null);
        };

        if (new_chunk) |chunk| {
            body_writer.writer.writeAll(chunk) catch |err| {
                std.log.err("[exec] write chunk failed: {}", .{err});
                break;
            };
            body_writer.writer.flush() catch |err| {
                std.log.err("[exec] flush chunk failed: {}", .{err});
                break;
            };
            body_writer.flush() catch |err| {
                std.log.err("[exec] body flush failed: {}", .{err});
                break;
            };
            continue;
        }

        // Done?
        const done = blk: {
            state.mutex.lock(state.io.?) catch break :blk false;
            defer state.mutex.unlock(state.io.?);
            const op = state.op_states.getPtr(cmd_id) orelse break :blk true;
            break :blk op.done;
        };

        if (done) break;

        // Wait for more data
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(10), .clock = .awake } }) catch break;
        state.wake_event.reset();
    }

    // Get exit code
    const exit_code = blk: {
        state.mutex.lock(state.io.?) catch break :blk @as(i32, -1);
        defer state.mutex.unlock(state.io.?);
        const op = state.op_states.getPtr(cmd_id) orelse break :blk @as(i32, -1);
        break :blk op.exit_code;
    };

    // End chunked with x-exit-code trailer
    var trailers: [1]http.Header = undefined;
    var buf: [32]u8 = undefined;
    const exit_str = std.fmt.bufPrint(&buf, "{}", .{exit_code}) catch "0";
    trailers[0] = .{ .name = "x-exit-code", .value = exit_str };
    body_writer.endChunked(.{ .trailers = &trailers }) catch {};
    chunked_ended = true;

    // Clean up op state (cleanupOpState locks internally — do NOT pre-lock state.mutex)
    state.cleanupOpState(cmd_id);
    std.log.info("[exec] done {s} exit={d}", .{ cmd_id, exit_code });
}

// ── POST /upload ───────────────────────────────────────────────────────────

pub fn handleUpload(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const vm = getRequestHeader(request, "x-vm") orelse {
        try respondError(request, .bad_request, "Missing x-vm header");
        return;
    };
    const remote_path = getRequestHeader(request, "x-path") orelse {
        try respondError(request, .bad_request, "Missing x-path header");
        return;
    };

    std.log.info("[upload] {s} → {s}:{s}", .{ vm, vm, remote_path });

    // Get guest tunnel (getGuestTunnel has its own internal locking)
    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };

    const content_length = request.head.content_length orelse 0;

    // Transfer key for singleton dedup
    const transfer_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ vm, remote_path });
    defer allocator.free(transfer_key);

    // Build upload command
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "up_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    // Register transfer
    state.registerTransfer(transfer_key, cmd_id, @intCast(content_length)) catch |err| {
        std.log.err("[upload] transfer limit: {}", .{err});
        try respondError(request, .service_unavailable, "Too many concurrent transfers");
        return;
    };

    // Send upload_cmd
    const up_cmd = try tunproto.buildUploadCmd(allocator, cmd_id, remote_path, @intCast(content_length), "");
    defer allocator.free(up_cmd);
    _ = tun.send(up_cmd) catch |err| {
        std.log.err("[upload] tunnel send failed: {}", .{err});
        state.removeTransfer(transfer_key);
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Stream body chunks → KCP tunnel
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var chunk_buf: [8192]u8 = undefined;
    var body_reader = request.readerExpectNone(&chunk_buf);

    while (true) {
        const chunk_size = @min(content_length - total, chunk_buf.len);
        if (chunk_size == 0) break;

        var chunk_writer: std.Io.Writer = .fixed(chunk_buf[0..chunk_size]);
        body_reader.streamExact(&chunk_writer, chunk_size) catch |err| {
            std.log.err("[upload] body read failed: {}", .{err});
            state.removeTransfer(transfer_key);
            return;
        };

        sha256.update(chunk_buf[0..chunk_size]);

        const fchunk = try tunproto.buildFileChunk(allocator, cmd_id, chunk_buf[0..chunk_size]);
        defer allocator.free(fchunk);

        // Lock once per chunk — mesh thread flush competition is rare
        tun.lock() catch |err| {
            std.log.err("[upload] lock failed: {}", .{err});
            state.removeTransfer(transfer_key);
            return;
        };
        defer tun.unlock();
        _ = tun.sendLocked(fchunk) catch |err| {
            std.log.err("[upload] chunk send failed: {}", .{err});
            state.removeTransfer(transfer_key);
            return;
        };
        tun.flushLocked(tun.session.mesh.clock_ms);

        total += chunk_size;
    }

    // Send EOF
    var hash_bin: [32]u8 = undefined;
    sha256.final(&hash_bin);
    var hash_hex: [64]u8 = undefined;
    for (hash_bin, 0..) |b, j| {
        hash_hex[j * 2] = "0123456789abcdef"[b >> 4];
        hash_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }

    const eof_frame = try tunproto.buildFileEof(allocator, cmd_id, 0, @intCast(total), &hash_hex);
    defer allocator.free(eof_frame);

    {
        tun.lock() catch return;
        defer tun.unlock();
        _ = tun.sendLocked(eof_frame) catch |err| {
            std.log.err("[upload] EOF send failed: {}", .{err});
            state.removeTransfer(transfer_key);
            return;
        };
        tun.flushLocked(tun.session.mesh.clock_ms);
    }
    // Release lock — mesh thread gets time to deliver EOF
    std.Io.sleep(state.io.?, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    state.removeTransfer(transfer_key);
    try request.respond("OK", .{ .status = .ok });
}

// ── POST /download ─────────────────────────────────────────────────────────

pub fn handleDownload(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const vm = getRequestHeader(request, "x-vm") orelse {
        try respondError(request, .bad_request, "Missing x-vm header");
        return;
    };
    const remote_path = getRequestHeader(request, "x-path") orelse {
        try respondError(request, .bad_request, "Missing x-path header");
        return;
    };

    std.log.info("[download] {s}:{s}", .{ vm, remote_path });

    const tun = state.getGuestTunnel(vm) orelse {
        try respondError(request, .service_unavailable, "GuestNotConnected");
        return;
    };

    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "dl_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    // Create op state (cleanupOpState has its own internal locking)
    try state.createOpState(cmd_id);
    defer state.cleanupOpState(cmd_id);

    // Send download command
    const dl_cmd = try tunproto.buildDownloadCmd(allocator, cmd_id, remote_path);
    defer allocator.free(dl_cmd);

    _ = tun.send(dl_cmd) catch |err| {
        std.log.err("[download] tunnel send failed: {}", .{err});
        try respondError(request, .service_unavailable, "TunnelSendFailed");
        return;
    };

    // Wait for EOF marker — Guest sends chunks as file_chunk → file_eof.
    // appendOpOutput accumulates, scanForMarker detects file_eof arrival.
    var got_eof = false;
    while (!got_eof) {
        const op = blk: {
            state.mutex.lock(state.io.?) catch break :blk null;
            defer state.mutex.unlock(state.io.?);
            break :blk state.op_states.getPtr(cmd_id);
        };
        const done = if (op) |o| o.done else false;
        if (done) {
            got_eof = true;
            break;
        }
        // Wait for more data
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(5), .clock = .awake } }) catch |err| {
            std.log.err("[download] wait failed: {}", .{err});
            break;
        };
        state.wake_event.reset();
    }

    // Collect all chunk data
    const file_data = blk: {
        state.mutex.lock(state.io.?) catch return;
        defer state.mutex.unlock(state.io.?);
        const op = state.op_states.getPtr(cmd_id) orelse return;
        break :blk try allocator.dupe(u8, op.output.items);
    };
    defer allocator.free(file_data);

    if (!got_eof) {
        try respondError(request, .gateway_timeout, "Download timeout");
        return;
    }

    // Respond with raw file bytes
    try request.respond(file_data, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }},
    });
}

// ── GET /bin/<file> ────────────────────────────────────────────────────────

pub fn handleBin(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    const path = request.head.target;
    // Strip "/bin/" prefix (5 chars)
    if (path.len <= 5) {
        try respondError(request, .not_found, "No filename");
        return;
    }
    const filename = path[5..];

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

// ── GET /version ────────────────────────────────────────────────────────────

pub fn handleVersion(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    _ = state;
    const buf = try std.fmt.allocPrint(allocator, "{s}\n", .{protocol.VERSION});
    defer allocator.free(buf);
    try respondJson(request, buf);
}

// ── POST /ping ──────────────────────────────────────────────────────────────

pub fn handlePing(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    // Read target hostname from x-vm header
    const vm = getRequestHeader(request, "x-vm") orelse {
        try respondJson(request, "{\"error\":\"missing x-vm header\"}");
        return;
    };

    // Find guest and get mesh MAC
    const mesh_ptr = state.mesh orelse {
        try respondJson(request, "{\"error\":\"mesh not available\"}");
        return;
    };
    const mesh: *mesh_mod.Mesh = @ptrCast(@alignCast(mesh_ptr));

    const node_id = blk: {
        state.mutex.lock(state.io.?) catch return error.InternalError;
        defer state.mutex.unlock(state.io.?);
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, vm)) {
                if (g.mesh_mac) |mac| break :blk mac;
                break :blk null;
            }
        }
        break :blk null;
    } orelse {
        try respondJson(request, "{\"error\":\"guest not found or no mesh MAC\"}");
        return;
    };

    // Send ping and wait for pong
    const rtt = mesh.pingAndWait(node_id) orelse {
        try respondJson(request, "{\"error\":\"ping timeout\"}");
        return;
    };

    var mac_buf: [18]u8 = undefined;
    const mac_str = mesh_mod.formatNodeIdBuf(node_id, &mac_buf);
    const buf = try std.fmt.allocPrint(allocator,
        "{{\"hostname\":\"{s}\",\"mac\":\"{s}\",\"rtt_ms\":{d}}}",
        .{ vm, mac_str, rtt },
    );
    defer allocator.free(buf);
    try respondJson(request, buf);
}

// ── GET /api/guests ────────────────────────────────────────────────────────

pub fn handleApiGuests(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    state.mutex.lock(state.io.?) catch return;
    defer state.mutex.unlock(state.io.?);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '[');

    for (state.guests.items, 0..) |g, i| {
        if (i > 0) try json.append(allocator, ',');
        try json.print(allocator,
            \\{{"hostname":"{s}","target":"{s}","ip":"{s}","mac":"{s}","version":"{s}","shell":"{s}"}}
        , .{ g.hostname, g.target, g.ip, g.mac, g.version, g.shell });
    }

    try json.append(allocator, ']');
    try respondJson(request, json.items);
}

// ── GET / ──────────────────────────────────────────────────────────────────

pub fn handleRoot(allocator: std.mem.Allocator, state: *HostState, request: *http.Server.Request, body: ?[]const u8) !void {
    _ = body;
    state.mutex.lock(state.io.?) catch return;
    defer state.mutex.unlock(state.io.?);

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>UTM Monitor</title>
        \\<style>
        \\  body { font-family: system-ui, sans-serif; background: #0d1117; color: #c9d1d9; margin: 2em; }
        \\  h1 { color: #58a6ff; }
        \\  table { border-collapse: collapse; width: 100%%; }
        \\  th, td { border: 1px solid #30363d; padding: 8px; text-align: left; }
        \\  th { background: #161b22; color: #8b949e; }
        \\  tr:hover { background: #1c2129; }
        \\  .online { color: #3fb950; }
        \\  .version { color: #d2a8ff; }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>🖥️ UTM Monitor</h1>
    );

    if (state.guests.items.len == 0) {
        try html.appendSlice(allocator, "<p>No VMs currently online.</p>");
    } else {
        try html.appendSlice(allocator,
            \\<table>
            \\<tr><th>Status</th><th>Hostname</th><th>Target</th><th>IP</th><th>MAC</th><th>Version</th><th>Shell</th></tr>
        );
        for (state.guests.items) |g| {
            try html.print(allocator,
                \\<tr>
                \\  <td class="online">● ONLINE</td>
                \\  <td>{s}</td>
                \\  <td>{s}</td>
                \\  <td>{s}</td>
                \\  <td>{s}</td>
                \\  <td class="version">{s}</td>
                \\  <td>{s}</td>
                \\</tr>
            , .{ g.hostname, g.target, g.ip, g.mac, g.version, g.shell });
        }
        try html.appendSlice(allocator, "</table>");
    }

    try html.appendSlice(allocator,
        \\<p style="margin-top:2em;color:#8b949e;">UTM Monitor v
    );
    try html.appendSlice(allocator, protocol.VERSION);
    try html.appendSlice(allocator, "</p></body></html>");

    try request.respond(html.items, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
    });
}

// ── Mesh guest handler (tunnel per guest) ───────────────────────────────────

/// Per-guest mesh session handler spawned as a new thread.
/// Reads pty_output + file_chunk + file_eof messages from the KCP tunnel
/// and updates the shared HostState.
pub fn handleMeshGuest(
    allocator: std.mem.Allocator,
    state: *HostState,
    hostname: []const u8,
    tun: *tunnel_mod.Tunnel,
) void {
    defer {
        // Remove from guest table BEFORE freeing hostname — removeGuestTunnel
        // does a HashMap lookup by hostname. If we free hostname first, the
        // allocator could reuse the memory, corrupting the lookup and leaving
        // a stale tunnel pointer in the map (use-after-free crash, Finding 79).
        state.removeGuestTunnel(hostname);
        allocator.free(hostname);
        tun.deinit();
        allocator.destroy(tun);
    }

    var rbuf: [262144]u8 = undefined;
    std.log.info("[tun-hdl] mesh handler started for {s}", .{hostname});

    while (tun.isAlive()) {
        // Peek message size first (message mode, each recv = one complete message)
        const peek_size = tun.peekSize();
        if (peek_size <= 0) {
            // No complete message yet — sleep briefly to avoid busy-wait
            std.Io.sleep(state.io.?, std.Io.Duration.fromMilliseconds(100), .awake) catch break;
            continue;
        }
        if (peek_size > rbuf.len) {
            std.log.err("[tun-hdl] Message too large for {s}: {d} bytes", .{ hostname, peek_size });
            break;
        }

        const n = tun.recv(rbuf[0..@intCast(peek_size)]) catch |err| {
            std.log.err("[tun-hdl] recv error for {s}: {}", .{ hostname, err });
            break;
        };
        if (n == 0) {
            std.Io.sleep(state.io.?, std.Io.Duration.fromMilliseconds(100), .awake) catch break;
            continue;
        }

        const data = rbuf[0..n];
        if (data.len == 0) continue;

        const msg_type = data[0];
        switch (msg_type) {
            @intFromEnum(tunproto.MsgType.pty_exec_output) => {
                // Use dedicated parser — buildPtyExecOutput writes raw data
                // (not a length-prefixed blob). The payload is every byte
                // after the null-terminated cmd_id.
                const out = tunproto.parsePtyExecOutput(data[1..]) orelse {
                    std.log.err("[tun-hdl] pty_output parse failed for {s}", .{hostname});
                    continue;
                };
                state.appendOpOutput(out.cmd_id, out.data);
                // Scan for MDELIM marker in accumulated output
                state.scanForMarker(out.cmd_id);
                // Wake the waiting HTTP handler.
                // Do NOT call reset() here — the waiting thread resets
                // after returning from waitTimeout(). Calling reset() from
                // this thread while waitTimeout() is still in-flight causes
                // unreachable panic in std.Io.Event.waitTimeout.
                state.wake_event.set(state.io.?);
            },
            @intFromEnum(tunproto.MsgType.pty_exec_done) => {
                const done = tunproto.parsePtyExecDone(data[1..]) orelse {
                    std.log.err("[tun-hdl] pty_exec_done parse failed for {s}", .{hostname});
                    continue;
                };
                std.log.debug("[tun-hdl] pty_exec_done for {s}: cmd={s} exit={d}", .{ hostname, done.cmd_id, done.exit_code });
                // Scan for any remaining MDELIM marker (arrived in last pty_output).
                // If the op is already done (MDELIM detected), this is a no-op.
                state.scanForMarker(done.cmd_id);
                // If still not done, complete with the received exit code.
                if (!state.isOpDone(done.cmd_id)) {
                    state.completeOpState(done.cmd_id, done.exit_code);
                    state.wake_event.set(state.io.?);
                }
            },
            @intFromEnum(tunproto.MsgType.file_chunk) => {
                var pos: usize = 1;
                const cmd_id_opt = tunproto.readString(data, &pos);
                const payload_opt = tunproto.readBlob(data, &pos);
                if (cmd_id_opt == null or payload_opt == null) {
                    std.log.err("[tun-hdl] file_chunk parse failed for {s}", .{hostname});
                    continue;
                }
                state.appendOpOutput(cmd_id_opt.?, payload_opt.?);
            },
            @intFromEnum(tunproto.MsgType.file_eof) => {
                const eof = tunproto.parseFileEof(data) orelse {
                    std.log.err("[tun-hdl] file_eof parse failed for {s}", .{hostname});
                    // Mark the op done anyway so the handler doesn't hang.
                    // Extract cmd_id before falling through to manual extraction.
                    var pos2: usize = 1;
                    const cmd_id_str = tunproto.readString(data, &pos2) orelse {
                        std.log.err("[tun-hdl] file_eof missing cmd_id for {s}", .{hostname});
                        continue;
                    };
                    if (!std.mem.eql(u8, cmd_id_str, "dl_") and !std.mem.eql(u8, cmd_id_str, "up_")) {
                        state.completeOpState(cmd_id_str, -1);
                    } else {
                        state.completeOpState(cmd_id_str, 0);
                    }
                    state.wake_event.set(state.io.?);
                    continue;
                };
                std.log.info("[tun-hdl] file_eof for {s}: {d} bytes, sha256={s}", .{ eof.cmd_id, eof.file_size, eof.file_hash });
                state.completeOpState(eof.cmd_id, eof.exit_code);
                if (eof.file_hash.len > 0) {
                    state.setOpFileMeta(eof.cmd_id, eof.file_hash, eof.file_size);
                }
                state.wake_event.set(state.io.?);
            },
            @intFromEnum(tunproto.MsgType.upgrade_req) => {
                var pos: usize = 1;
                const cmd_id_opt = tunproto.readString(data, &pos);
                const target_opt = tunproto.readString(data, &pos);
                if (cmd_id_opt == null or target_opt == null) {
                    std.log.err("[tun-hdl] upgrade_req parse failed for {s}", .{hostname});
                    continue;
                }
                std.log.info("[tun-hdl] upgrade request from {s} target={s}", .{ hostname, target_opt.? });
                serveUpgradeFile(state.io.?, allocator, tun, cmd_id_opt.?, target_opt.?) catch |err| {
                    std.log.err("[tun-hdl] serveUpgradeFile failed: {}", .{err});
                };
            },
            else => {
                std.log.err("[tun-hdl] unknown msg type 0x{x:0>2} for {s}", .{ msg_type, hostname });
            },
        }
    }

    std.log.info("[tun-hdl] mesh handler exiting for {s}", .{hostname});
}

/// Serve upgrade binary to Guest via file_chunk + file_eof over KCP tunnel.
fn serveUpgradeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    tun: *tunnel_mod.Tunnel,
    cmd_id: []const u8,
    target: []const u8,
) !void {
    const filename = protocol.deploymentFilename(target) orelse {
        std.log.err("[upgrade] Unknown target: {s}", .{target});
        const eof_frame = try tunproto.buildFileEof(allocator, cmd_id, 1, 0, &[_]u8{0} ** 64);
        defer allocator.free(eof_frame);
        _ = tun.sendLocked(eof_frame) catch {};
        return;
    };

    // Use exe_dir to find the binary (same directory as running utmm)
    var exe_path_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_len];
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    var path_buf: [1024]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ exe_dir, filename });

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        std.log.err("[upgrade] Cannot open {s}: {}", .{ file_path, err });
        const eof_frame = try tunproto.buildFileEof(allocator, cmd_id, 1, 0, &[_]u8{0} ** 64);
        defer allocator.free(eof_frame);
        _ = tun.send(eof_frame) catch {};
        return;
    };
    defer file.close(io);

    const file_size = try file.length(io);
    std.log.info("[upgrade] Serving {s} ({d} bytes) to {s}", .{ filename, file_size, cmd_id });

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    while (true) {
        const remaining = file_size - total;
        const chunk_size = @min(remaining, file_buf.len);
        if (chunk_size == 0) break;

        try file_reader.interface.readSliceAll(file_buf[0..chunk_size]);

        sha256.update(file_buf[0..chunk_size]);

        const fchunk = try tunproto.buildFileChunk(allocator, cmd_id, file_buf[0..chunk_size]);
        defer allocator.free(fchunk);

        // Lock once per chunk — mesh thread runs in same Io, competition is rare
        tun.lock() catch return;
        defer tun.unlock();
        _ = tun.sendLocked(fchunk) catch |err| {
            std.log.err("[upgrade] Failed to send chunk: {}", .{err});
            return;
        };
        tun.flushLocked(tun.session.mesh.clock_ms);

        total += chunk_size;
    }

    var hash_bin: [32]u8 = undefined;
    sha256.final(&hash_bin);
    var hash_hex: [64]u8 = undefined;
    for (hash_bin, 0..) |b, j| {
        hash_hex[j * 2] = "0123456789abcdef"[b >> 4];
        hash_hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }

    const eof_frame = try tunproto.buildFileEof(allocator, cmd_id, 0, @intCast(total), &hash_hex);
    defer allocator.free(eof_frame);

    {
        tun.lock() catch return;
        defer tun.unlock();
        _ = tun.sendLocked(eof_frame) catch |err| {
            std.log.err("[upgrade] Failed to send file_eof: {}", .{err});
            return;
        };
        tun.flushLocked(tun.session.mesh.clock_ms);
    }
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    std.log.info("[upgrade] Sent {s} ({d} bytes, sha256={s}) to {s}", .{
        filename, total, &hash_hex, cmd_id,
    });
}

// ── /etc/hosts sync ────────────────────────────────────────────────────────

pub fn syncHostsFromState(state: *HostState, allocator: std.mem.Allocator) void {
    state.mutex.lock(state.io.?) catch return;
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

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "jsonEscape - basic" {
    const result = try jsonEscape(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "jsonEscape - with quotes" {
    const result = try jsonEscape(std.testing.allocator, "say \"hi\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", result);
}

test "jsonEscape - with newlines" {
    const result = try jsonEscape(std.testing.allocator, "line1\nline2");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2", result);
}

test "jsonEscape - with backslash" {
    const result = try jsonEscape(std.testing.allocator, "path\\to\\file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "jsonEscape - with tab" {
    const result = try jsonEscape(std.testing.allocator, "col1\tcol2");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("col1\\tcol2", result);
}

test "jsonEscape - with CR" {
    const result = try jsonEscape(std.testing.allocator, "line\r");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line\\r", result);
}

test "jsonEscape - empty string" {
    const result = try jsonEscape(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "jsonEscape - control characters" {
    // Test \uXXXX escaping for control chars 0-7, 11, 14-31
    const result = try jsonEscape(std.testing.allocator, &.{ 0, 7, 11, 14, 31 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\\u0000\\u0007\\u000b\\u000e\\u001f", result);
}

test "jsonEscape - DEL and other edge control chars" {
    // Test BS (0x08), FF (0x0C), DEL (0x7F)
    {
        const result = try jsonEscape(std.testing.allocator, &.{0x08});
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("\\u0008", result);
    }
    {
        const result = try jsonEscape(std.testing.allocator, &.{0x0C});
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("\\u000c", result);
    }
    {
        const result = try jsonEscape(std.testing.allocator, &.{0x7F});
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("\\u007f", result);
    }
}

test "jsonEscape - all safe printable" {
    const result = try jsonEscape(std.testing.allocator, "abc123!@# ");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("abc123!@# ", result);
}

test "jsonGetString - present" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .string = "value" });
    const result = jsonGetString(map, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value", result.?);
}

test "jsonGetString - missing" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    const result = jsonGetString(map, "nope");
    try std.testing.expect(result == null);
}

test "jsonGetString - wrong type" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .integer = 42 });
    const result = jsonGetString(map, "key");
    try std.testing.expect(result == null);
}

test "jsonGetString - empty string value" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .string = "" });
    const result = jsonGetString(map, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "jsonGetInt - present" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .integer = 42 });
    const result = jsonGetInt(map, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 42), result.?);
}

test "jsonGetInt - negative" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .integer = -1 });
    const result = jsonGetInt(map, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, -1), result.?);
}

test "jsonGetInt - missing" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    const result = jsonGetInt(map, "nope");
    try std.testing.expect(result == null);
}

test "jsonGetInt - wrong type" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .string = "42" });
    const result = jsonGetInt(map, "key");
    try std.testing.expect(result == null);
}

test "parseJson - valid object" {
    const parsed = try parseJson(std.testing.allocator, "{\"a\":1}");
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "parseJson - invalid" {
    _ = parseJson(std.testing.allocator, "not json") catch |err| {
        try std.testing.expectEqual(error.UnexpectedToken, err);
        return;
    };
    try std.testing.expect(false); // should have errored
}

test "buildJson - simple" {
    const result = try buildJson(std.testing.allocator, "{{\"x\":{d}}}", .{42});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"x\":42}", result);
}

test "buildCmdWithMarker - bash" {
    const result = try buildCmdWithMarker(std.testing.allocator, "/bin/bash", "ls -la");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ls -la; echo MDELIM:$?\n", result);
}

test "buildCmdWithMarker - zsh" {
    const result = try buildCmdWithMarker(std.testing.allocator, "/bin/zsh", "uname -a");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("uname -a; echo MDELIM:$?\n", result);
}

test "buildCmdWithMarker - sh fallback" {
    const result = try buildCmdWithMarker(std.testing.allocator, "/bin/sh", "echo hi");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("echo hi; echo MDELIM:$?\n", result);
}

test "buildCmdWithMarker - cmd.exe" {
    const result = try buildCmdWithMarker(std.testing.allocator, "cmd.exe", "dir");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("dir & echo MDELIM:%errorlevel%\r\n", result);
}

test "buildCmdWithMarker - empty command POSIX" {
    const result = try buildCmdWithMarker(std.testing.allocator, "/bin/bash", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("; echo MDELIM:$?\n", result);
}

test "buildCmdWithMarker - empty command Windows" {
    const result = try buildCmdWithMarker(std.testing.allocator, "cmd.exe", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(" & echo MDELIM:%errorlevel%\r\n", result);
}

test "scanForMarker - normal exit 0" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test1");
    state.appendOpOutput("test1", "hello world");
    state.appendOpOutput("test1", "MDELIM:0\n");

    state.scanForMarker("test1");

    try std.testing.expectEqualStrings("hello world", state.op_states.get("test1").?.output.items);
    try std.testing.expectEqual(@as(i32, 0), state.op_states.get("test1").?.exit_code);
    try std.testing.expect(state.op_states.get("test1").?.done);
}

test "scanForMarker - exit code 127" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test2");
    state.appendOpOutput("test2", "command not found\n");
    state.appendOpOutput("test2", "MDELIM:127\n");

    state.scanForMarker("test2");

    try std.testing.expect(state.op_states.get("test2").?.done);
    try std.testing.expectEqual(@as(i32, 127), state.op_states.get("test2").?.exit_code);
    try std.testing.expectEqualStrings("command not found\n", state.op_states.get("test2").?.output.items);
}

test "scanForMarker - negative exit code" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test3");
    state.appendOpOutput("test3", "output");
    state.appendOpOutput("test3", "MDELIM:-1\n");

    state.scanForMarker("test3");

    try std.testing.expect(state.op_states.get("test3").?.done);
    try std.testing.expectEqual(@as(i32, -1), state.op_states.get("test3").?.exit_code);
}

test "scanForMarker - no marker yet" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test4");
    state.appendOpOutput("test4", "partial output...");

    state.scanForMarker("test4");

    try std.testing.expect(!state.op_states.get("test4").?.done);
    try std.testing.expectEqual(@as(i32, -1), state.op_states.get("test4").?.exit_code);
}

test "scanForMarker - partial marker (no newline)" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test5");
    state.appendOpOutput("test5", "data");
    state.appendOpOutput("test5", "MDELIM:0"); // no newline yet

    state.scanForMarker("test5");

    try std.testing.expect(!state.op_states.get("test5").?.done);
}

test "scanForMarker - echo with MDELIM reference (macOS pty)" {
    // macOS pty echoes the command which contains "MDELIM:$?".
    // scanForMarker must use lastIndexOf and not match the echo.
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test6");
    // Simulate macOS pty: echoed command then actual output then real marker
    state.appendOpOutput("test6", "echo MDELIM:$\n");
    state.appendOpOutput("test6", "actual command output\n");
    state.appendOpOutput("test6", "MDELIM:0\n");

    state.scanForMarker("test6");

    try std.testing.expect(state.op_states.get("test6").?.done);
    try std.testing.expectEqual(@as(i32, 0), state.op_states.get("test6").?.exit_code);
    // Should strip only the real marker, leaving echoed text + output
    try std.testing.expectEqualStrings("echo MDELIM:$\nactual command output\n", state.op_states.get("test6").?.output.items);
}

test "scanForMarker - no digits in marker (invalid echo text)" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test7");
    // Only echoed text with no valid exit code
    state.appendOpOutput("test7", "echo MDELIM:$\n");

    state.scanForMarker("test7");

    try std.testing.expect(!state.op_states.get("test7").?.done);
}

test "scanForMarker - CRLF line ending" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test8");
    state.appendOpOutput("test8", "output\r\n");
    state.appendOpOutput("test8", "MDELIM:0\r\n");

    state.scanForMarker("test8");

    try std.testing.expect(state.op_states.get("test8").?.done);
    try std.testing.expectEqual(@as(i32, 0), state.op_states.get("test8").?.exit_code);
}

test "scanForMarker - multiple markers, picks last valid" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("test9");
    // Two markers: first invalid (echo), second real
    state.appendOpOutput("test9", "MDELIM:$\n"); // invalid, skipped
    state.appendOpOutput("test9", "some output\n");
    state.appendOpOutput("test9", "MDELIM:42\n"); // real marker

    state.scanForMarker("test9");

    try std.testing.expect(state.op_states.get("test9").?.done);
    try std.testing.expectEqual(@as(i32, 42), state.op_states.get("test9").?.exit_code);
    // Should strip at the real marker position
    try std.testing.expectEqualStrings("MDELIM:$\nsome output\n", state.op_states.get("test9").?.output.items);
}

test "HostState init and deinit" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.guests.items.len);
}

test "HostState createOpState and takeOpResult" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("cmd1");
    state.appendOpOutput("cmd1", "hello");
    state.completeOpState("cmd1", 0);

    const result = state.takeOpResult("cmd1");
    try std.testing.expect(result != null);
    defer allocator.free(result.?.stdout);

    try std.testing.expectEqual(@as(i32, 0), result.?.exit);
    try std.testing.expectEqualStrings("hello", result.?.stdout);

    // Should be removed after takeOpResult
    try std.testing.expect(!state.op_states.contains("cmd1"));
}

test "HostState cleanupOpState" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("cmd2");
    state.cleanupOpState("cmd2");
    try std.testing.expect(!state.op_states.contains("cmd2"));

    // cleanupOpState on non-existent should be no-op
    state.cleanupOpState("non_existent");
}

test "HostState appendOpOutput" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("cmd3");
    state.appendOpOutput("cmd3", "part1");
    state.appendOpOutput("cmd3", "part2");

    const op = state.op_states.get("cmd3").?;
    try std.testing.expectEqualStrings("part1part2", op.output.items);
}

test "HostState completeOpState" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("cmd4");
    state.completeOpState("cmd4", 5);

    const op = state.op_states.get("cmd4").?;
    try std.testing.expect(op.done);
    try std.testing.expectEqual(@as(i32, 5), op.exit_code);
}

test "HostState failAllPendingOps" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("pending1");
    try state.createOpState("pending2");
    state.completeOpState("pending2", 0); // one already done

    state.failAllPendingOps();

    const op1 = state.op_states.get("pending1").?;
    try std.testing.expect(op1.done);
    try std.testing.expectEqual(@as(i32, -1), op1.exit_code);
}

test "HostState setOpFileMeta" {
    const allocator = std.testing.allocator;
    var state = HostState.init(allocator);
    defer state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    state.io = threaded.io();

    try state.createOpState("cmd5");
    state.setOpFileMeta("cmd5", "abcdef", 1024);

    const op = state.op_states.get("cmd5").?;
    try std.testing.expectEqualStrings("abcdef", op.file_hash);
    try std.testing.expectEqual(@as(u32, 1024), op.file_size_meta);
}

test "HostState router add and dispatch" {
    const allocator = std.testing.allocator;
    var router: Router = .{};
    defer router.deinit(allocator);

    // Just verify we can create and deinit a router without crashes
    try std.testing.expectEqual(@as(usize, 0), router.routes.items.len);
}

test "DEFAULT_PORT is 2121" {
    try std.testing.expectEqual(@as(u16, 2121), DEFAULT_PORT);
}

