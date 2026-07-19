//! MCP (Model Context Protocol) JSON-RPC server over stdio.
//!
//! Two modes:
//!   run()       — Adapter: direct UDP+TCP for each tool call (no Host daemon needed)
//!   runDirect() — Integrated: Host + MCP in one process
//!
//! Framing: LSP-style Content-Length: N\r\n\r\n<JSON>\n on stdin/stdout.
//! Methods: initialize, notifications/initialized, ping, tools/list, tools/call.
//! Tools:   vm_status, vm_exec.

const std = @import("std");
const zio = @import("zio");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// Unified port for UDP broadcast + TCP (was IPC_PORT in old ipc.zig)
pub const CMD_PORT: u16 = protocol.DEFAULT_PORT;

/// Handler function type for integrated mode (Host daemon passes its handler).
pub const Handler = *const fn (*anyopaque, []const u8) anyerror![]const u8;

// ── MCP protocol constants ─────────────────────────────────────────────────

const SERVER_INFO =
    \\{"protocolVersion":"2024-11-05",
    \\"serverInfo":{"name":"utmm","version":"__VERSION__"},
    \\"capabilities":{"tools":{}}}
;

const TOOLS_JSON =
    \\[{"name":"vm_status","description":"Get status of all UTM virtual machines. Returns hostname, IP, OS/arch, MAC, version, shell (cmd.exe or /bin/sh — use this to write compatible commands), and whether an upgrade is available for each VM.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"vm_exec","description":"Execute a shell command on a UTM virtual machine. The command runs in the VM's native shell: /bin/sh on Linux/macOS, cmd.exe on Windows. Check vm_status first to see each VM's shell type, then write compatible commands.","inputSchema":{"type":"object","properties":{"vm":{"type":"string","description":"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')"},"command":{"type":"string","description":"Shell command (use POSIX sh for Linux/macOS, cmd.exe syntax for Windows)"}},"required":["vm","command"]}}]
;

// ── JSON value helpers ─────────────────────────────────────────────────────

/// Get a string field from a JSON object, or null if missing/wrong type.
fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get a nested string from obj.key1.key2, or null.
fn getNestedString(obj: std.json.ObjectMap, key1: []const u8, key2: []const u8) ?[]const u8 {
    const outer = obj.get(key1) orelse return null;
    return switch (outer) {
        .object => |inner| getString(inner, key2),
        else => null,
    };
}

/// Get a nested object map.
fn getNestedObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |inner| inner,
        else => null,
    };
}

/// Append a JSON value's id field to a buffer (for echo-back in responses).
fn appendId(list: *std.ArrayList(u8), allocator: std.mem.Allocator, id: std.json.Value) !void {
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

/// Escape a string for JSON (minimal: only handles " and \ and newlines).
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

// ── MCP response builders ──────────────────────────────────────────────────

fn sendResponse(io: std.Io, id: std.json.Value, result_json: []const u8) !void {
    const gpa = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendId(&buf, gpa, id);
    try buf.appendSlice(gpa, ",\"result\":");
    try buf.appendSlice(gpa, result_json);
    try buf.appendSlice(gpa, "}");

    try writeMessage(io, buf.items);
}

fn sendError(io: std.Io, id: std.json.Value, code: i64, message: []const u8) !void {
    const gpa = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendId(&buf, gpa, id);
    try buf.print(gpa, ",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}", .{ code, message });
    try buf.appendSlice(gpa, "}");

    try writeMessage(io, buf.items);
}

/// Send a response for a notification (no id field).
fn sendNotificationResponse(io: std.Io, result_json: []const u8) !void {
    const gpa = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"result\":");
    try buf.appendSlice(gpa, result_json);
    try buf.appendSlice(gpa, "}");

    try writeMessage(io, buf.items);
}

fn writeMessage(io: std.Io, json: []const u8) !void {
    var wb: [65536]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &wb);
    writer.interface.print("Content-Length: {d}\r\n\r\n{s}\n", .{ json.len, json }) catch {};
    writer.interface.flush() catch {};
}

// ── Tool handlers ──────────────────────────────────────────────────────────

/// Execute a command via direct UDP+TCP (adapter mode — no Host daemon needed).
/// Supports: "STATUS_JSON" → discover all guests, "EXEC\\n<vm>\\n<cmd>" → exec on vm.
fn sendCommandRaw(block_io: std.Io, gpa: std.mem.Allocator, command: []const u8) ![]const u8 {
    if (std.mem.eql(u8, command, "STATUS_JSON")) {
        return discoverAndStatus(block_io, gpa);
    }
    if (std.mem.startsWith(u8, command, "EXEC\n")) {
        const rest = command["EXEC\n".len..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.InvalidCommand;
        const vm = rest[0..nl];
        const cmd = rest[nl + 1 ..];
        return execOnGuest(block_io, gpa, vm, cmd);
    }
    return error.UnknownCommand;
}

/// JSON-builder helper: append a JSON key-value string pair.
fn appendJsonKv(list: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8, comma: bool) !void {
    try list.appendSlice(alloc, "\"");
    try list.appendSlice(alloc, key);
    try list.appendSlice(alloc, "\":\"");
    const escaped = try jsonEscape(alloc, value);
    defer alloc.free(escaped);
    try list.appendSlice(alloc, escaped);
    try list.appendSlice(alloc, "\"");
    if (comma) try list.appendSlice(alloc, ",");
}

/// Derive the shell from the guest's target triple.
fn shellFromTarget(target: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target, "windows") != null) return "cmd.exe";
    return "/bin/sh";
}

/// Discover all guests via UDP broadcast → build JSON status.
/// Falls back to state file if UDP port is in use (Host daemon running).
fn discoverAndStatus(block_io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const port = CMD_PORT;
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var socket = listen_addr.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
        std.debug.print("[mcp] UDP bind failed: {}\n", .{err});
        // Fallback: read state file
        return buildStatusFromStateFile(block_io, gpa) catch
            gpa.dupe(u8, "{\"guests\":[]}");
    };
    defer socket.close(block_io);

    // Send PING to provoke immediate ANNOUNCE responses
    {
        const bc_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);
        const bind_ip = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
        var bc_socket = try bind_ip.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true });
        defer bc_socket.close(block_io);
        var ping_buf: [64]u8 = undefined;
        var ping_writer: std.Io.Writer = .fixed(&ping_buf);
        try protocol.buildPing(&ping_writer);
        bc_socket.send(block_io, &bc_addr, ping_writer.buffered()) catch {};
    }

    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(gpa, "{\"guests\":[");
    var recv_buf: [2048]u8 = undefined;
    const deadline_ns = std.Io.Timestamp.now(block_io, .real).nanoseconds + 3_000_000_000;
    var first: bool = true;

    while (std.Io.Timestamp.now(block_io, .real).nanoseconds < deadline_ns) {
        const msg_result = socket.receive(block_io, &recv_buf) catch break;
        const msg = msg_result.data;

        if (std.mem.indexOf(u8, msg, "ANNOUNCE") == null) continue;

        const info = protocol.GuestInfo.parse(gpa, msg) catch continue;
        defer {
            gpa.free(info.hostname);
            gpa.free(info.ip);
            gpa.free(info.target);
            gpa.free(info.mac);
            gpa.free(info.version);
            gpa.free(info.shell);
        }

        const src_ip = switch (msg_result.from) {
            .ip4 => |a| try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
            .ip6 => |a| try std.fmt.allocPrint(gpa, "{any}", .{a}),
        };
        defer gpa.free(src_ip);

        const use_src = std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.");
        const actual_ip = if (use_src) src_ip else info.ip;

        if (!first) try json.appendSlice(gpa, ",");
        first = false;
        try json.appendSlice(gpa, "{");
        try appendJsonKv(&json, gpa, "hostname", info.hostname, true);
        try appendJsonKv(&json, gpa, "ip", actual_ip, true);
        try appendJsonKv(&json, gpa, "target", info.target, true);
        try appendJsonKv(&json, gpa, "mac", info.mac, true);
        try appendJsonKv(&json, gpa, "version", info.version, true);
        try appendJsonKv(&json, gpa, "shell", if (info.shell.len > 0) info.shell else shellFromTarget(info.target), false);
        try json.appendSlice(gpa, "}");
    }
    try json.appendSlice(gpa, "]}");
    return json.toOwnedSlice(gpa);
}

/// Discover a specific guest by hostname via UDP, then TCP exec on it.
/// Falls back to state file if UDP port is in use (Host daemon running).
fn execOnGuest(block_io: std.Io, gpa: std.mem.Allocator, target: []const u8, cmd: []const u8) ![]const u8 {
    const port = CMD_PORT;

    // UDP discover guest IP (with state file fallback)
    const ip = blk: {
        const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
        var socket = listen_addr.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
            std.debug.print("[mcp] UDP bind failed: {}\n", .{err});
            // Fallback: lookup in state file
            break :blk lookupGuestIpInStateFile(block_io, gpa, target) catch null;
        };
        defer socket.close(block_io);

        // Send PING
        {
            const bc_addr = try std.Io.net.IpAddress.parse("255.255.255.255", port);
            const bind_ip = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
            var bc_socket = try bind_ip.bind(block_io, .{ .mode = .dgram, .allow_broadcast = true });
            defer bc_socket.close(block_io);
            var ping_buf: [64]u8 = undefined;
            var ping_writer: std.Io.Writer = .fixed(&ping_buf);
            try protocol.buildPing(&ping_writer);
            bc_socket.send(block_io, &bc_addr, ping_writer.buffered()) catch {};
        }

        var recv_buf: [2048]u8 = undefined;
        const deadline_ns = std.Io.Timestamp.now(block_io, .real).nanoseconds + 3_000_000_000;
        var result: ?[]const u8 = null;

        while (std.Io.Timestamp.now(block_io, .real).nanoseconds < deadline_ns) {
            const msg_result = socket.receive(block_io, &recv_buf) catch break;
            const msg = msg_result.data;

            if (std.mem.indexOf(u8, msg, "ANNOUNCE") == null) continue;

            const info = protocol.GuestInfo.parse(gpa, msg) catch continue;
            defer {
                gpa.free(info.hostname);
                gpa.free(info.ip);
                gpa.free(info.target);
                gpa.free(info.mac);
                gpa.free(info.version);
                gpa.free(info.shell);
            }

            if (std.mem.eql(u8, info.hostname, target)) {
                const fqdn = try info.fqdn(gpa);
                defer gpa.free(fqdn);
                if (std.mem.eql(u8, fqdn, target) or std.mem.eql(u8, info.hostname, target)) {
                    const src_ip = switch (msg_result.from) {
                        .ip4 => |a| try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
                        .ip6 => |a| try std.fmt.allocPrint(gpa, "{any}", .{a}),
                    };
                    const use_src = std.mem.eql(u8, info.ip, "0.0.0.0") or std.mem.startsWith(u8, info.ip, "127.");
                    result = if (use_src) src_ip else try gpa.dupe(u8, info.ip);
                    break;
                }
            }
        }
        break :blk result;
    } orelse return error.GuestNotFound;
    defer gpa.free(ip);

    // TCP connect + exec
    var rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const addr = try std.Io.net.IpAddress.parse(ip, port);
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[mcp] Connect to {s}:{d} failed: {}\n", .{ ip, port, err });
        return err;
    };
    defer stream.close(io);

    var wbuf: [65536]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    var reader = stream.reader(io, &rbuf);

    try transport.sendMessage(&writer, transport.MsgType.EXEC_REQ, cmd);
    writer.interface.flush() catch {};

    var output: std.ArrayList(u8) = .empty;
    while (true) {
        const msg = (transport.recvMessage(&reader, gpa) catch break) orelse break;
        defer gpa.free(msg.payload);

        switch (msg.msg_type) {
            transport.MsgType.EXEC_STDOUT => try output.appendSlice(gpa, msg.payload),
            transport.MsgType.EXEC_STDERR => try output.appendSlice(gpa, msg.payload),
            transport.MsgType.ERROR => {
                try output.appendSlice(gpa, "ERROR: ");
                try output.appendSlice(gpa, msg.payload);
            },
            transport.MsgType.EXEC_EXIT => break,
            else => {},
        }
    }
    return output.toOwnedSlice(gpa);
}

const STATE_FILE = "/tmp/utmm-guests.tsv";

/// Build JSON status from state file (fallback when UDP port is in use).
fn buildStatusFromStateFile(block_io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(block_io, STATE_FILE, gpa, @enumFromInt(64 * 1024));
    defer gpa.free(data);

    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(gpa, "{\"guests\":[");
    var first: bool = true;

    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitSequence(u8, line, "\t");
        const hostname = fields.next() orelse continue;
        const target = fields.next() orelse continue;
        const ip = fields.next() orelse continue;
        const mac = fields.next() orelse continue;
        const version = fields.next() orelse continue;
        const shell = fields.next() orelse shellFromTarget(target); // 6th column added in v0.2.2

        if (!first) try json.appendSlice(gpa, ",");
        first = false;
        try json.appendSlice(gpa, "{");
        try appendJsonKv(&json, gpa, "hostname", hostname, true);
        try appendJsonKv(&json, gpa, "ip", ip, true);
        try appendJsonKv(&json, gpa, "target", target, true);
        try appendJsonKv(&json, gpa, "mac", mac, true);
        try appendJsonKv(&json, gpa, "version", version, true);
        try appendJsonKv(&json, gpa, "shell", shell, false);
        try json.appendSlice(gpa, "}");
    }
    try json.appendSlice(gpa, "]}");
    return json.toOwnedSlice(gpa);
}

/// Look up a guest's IP in the state file (fallback when UDP port is in use).
/// State file format: hostname\ttarget\tip\tmac\tversion
fn lookupGuestIpInStateFile(block_io: std.Io, gpa: std.mem.Allocator, target: []const u8) ![]const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(block_io, STATE_FILE, gpa, @enumFromInt(64 * 1024));
    defer gpa.free(data);

    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitSequence(u8, line, "\t");
        const hostname = fields.next() orelse continue;
        _ = fields.next() orelse continue; // skip target
        const ip = fields.next() orelse continue;

        if (std.mem.eql(u8, hostname, target)) {
            return gpa.dupe(u8, ip);
        }
    }
    return error.GuestNotFound;
}

/// Handle vm_status: STATUS_JSON → markdown + JSON.
fn handleVmStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: ?*anyopaque,
    handler: ?Handler,
) ![]const u8 {
    const raw = if (ctx) |c| try handler.?(c, "STATUS_JSON")
        else try sendCommandRaw(io, allocator, "STATUS_JSON");
    defer allocator.free(raw);

    // Try parsing as JSON; fall back to raw output
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch {
        // Return raw output if JSON parse fails
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(allocator, "{\"text\":\"Raw status output:\\n");
        const escaped = try jsonEscape(allocator, raw);
        defer allocator.free(escaped);
        try buf.appendSlice(allocator, escaped);
        try buf.appendSlice(allocator, "\"}");
        return buf.toOwnedSlice(allocator);
    };
    defer parsed.deinit();

    const root = parsed.value;
    const guests: []const std.json.Value = if (root.object.get("guests")) |g| blk: {
        if (g == .array) break :blk g.array.items;
        break :blk @as([]const std.json.Value, &.{});
    } else @as([]const std.json.Value, &.{});

    if (guests.len == 0) {
        return try allocator.dupe(u8, "{\"text\":\"No VMs currently online.\"}");
    }

    // Build markdown table + JSON block
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(allocator, "**UTM Virtual Machines:**\\n");

    for (guests) |g| {
        const obj = switch (g) {
            .object => |o| o,
            else => continue,
        };
        const hostname = getString(obj, "hostname") orelse "?";
        const target = getString(obj, "target") orelse "?";
        const ip = getString(obj, "ip") orelse "?";
        const mac = getString(obj, "mac") orelse "?";
        const version = getString(obj, "version") orelse "?";
        const shell = getString(obj, "shell") orelse "?";
        const upgradable = switch (obj.get("upgradable") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        const status_str = if (upgradable) "⚠ upgradeable" else "✓";

        try text.print(allocator,
            "- **{s}** — {s} | IP: {s} | MAC: {s} | v{s} | shell: {s} | {s}\\n",
            .{ hostname, target, ip, mac, version, shell, status_str },
        );
    }

    // Append raw JSON for LLM consumption
    try text.appendSlice(allocator, "\\n```json\\n");
    const escaped = try jsonEscape(allocator, raw);
    defer allocator.free(escaped);
    try text.appendSlice(allocator, escaped);
    try text.appendSlice(allocator, "\\n```");

    // Build content result
    const text_json = try jsonEscape(allocator, text.items);
    defer allocator.free(text_json);
    defer text.deinit(allocator);

    var result: std.ArrayList(u8) = .empty;
    try result.print(allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text_json});
    return result.toOwnedSlice(allocator);
}

/// Handle vm_exec: EXEC → code-fenced output.
fn handleVmExec(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: ?*anyopaque,
    handler: ?Handler,
    vm: []const u8,
    command: []const u8,
) ![]const u8 {
    const ipc_cmd = try std.fmt.allocPrint(allocator, "EXEC\n{s}\n{s}", .{ vm, command });
    defer allocator.free(ipc_cmd);

    const raw = if (ctx) |c| try handler.?(c, ipc_cmd)
        else try sendCommandRaw(io, allocator, ipc_cmd);
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \n\r");
    const esc_vm = try jsonEscape(allocator, vm);
    defer allocator.free(esc_vm);
    const esc_cmd = try jsonEscape(allocator, command);
    defer allocator.free(esc_cmd);
    const esc_out = try jsonEscape(allocator, trimmed);
    defer allocator.free(esc_out);

    var result: std.ArrayList(u8) = .empty;
    try result.print(allocator, 
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"**{s}** `$ {s}`:\\n```\\n{s}\\n```\"}}]}}",
        .{ esc_vm, esc_cmd, esc_out },
    );
    return result.toOwnedSlice(allocator);
}

// ── MCP request parser ─────────────────────────────────────────────────────

const MCPRequest = struct {
    method: []const u8,
    id: std.json.Value,
    params: ?std.json.ObjectMap,
};

/// Read one MCP request from stdin. Returns null on EndOfStream.
/// Uses the same persistent reader for all calls (to avoid losing buffered data between requests).
fn readRequest(allocator: std.mem.Allocator, reader: anytype) !?MCPRequest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Read until we have a complete Content-Length header + body
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (buf.items.len == 0) return null;
                break;
            },
            else => return err,
        };
        try buf.append(allocator, byte);

        // Check for \r\n\r\n (header terminator)
        if (buf.items.len >= 4 and
            buf.items[buf.items.len - 4] == '\r' and
            buf.items[buf.items.len - 3] == '\n' and
            buf.items[buf.items.len - 2] == '\r' and
            buf.items[buf.items.len - 1] == '\n')
        {
            break;
        }
    }

    if (buf.items.len == 0) return null;

    // Parse Content-Length header
    const header_end = blk: {
        for (0..buf.items.len - 3) |i| {
            if (buf.items[i] == '\r' and buf.items[i + 1] == '\n' and
                buf.items[i + 2] == '\r' and buf.items[i + 3] == '\n')
            {
                break :blk i + 4;
            }
        }
        return error.InvalidHeader;
    };

    const header = buf.items[0 .. header_end - 4]; // strip \r\n\r\n
    const cl_prefix = "Content-Length:";
    if (!std.mem.startsWith(u8, header, cl_prefix)) return error.InvalidHeader;

    const cl_value = std.mem.trim(u8, header[cl_prefix.len..], " \r\n");
    const content_length = try std.fmt.parseInt(usize, cl_value, 10);

    // Read body bytes
    var body: std.ArrayList(u8) = .empty;
    errdefer if (body.capacity > 0) body.deinit(allocator);

    const already_read = buf.items.len - header_end;
    if (already_read > 0) {
        try body.appendSlice(allocator, buf.items[header_end..@min(header_end + content_length, buf.items.len)]);
    }

    while (body.items.len < content_length) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try body.append(allocator, byte);
    }

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body.items, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("[mcp] JSON parse error: {}\n", .{err});
        body.deinit(allocator);
        return error.InvalidJson;
    };
    // Note: parsed.deinit() must be called by caller — we transfer ownership
    // via the MCPRequest. Cleanup happens in the dispatch loop.
    body.deinit(allocator);

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => {
            parsed.deinit();
            return error.InvalidJson;
        },
    };

    const method = getString(obj, "method") orelse {
        parsed.deinit();
        return error.MissingMethod;
    };

    // Clone id and params out of the parsed tree (they point into parsed's arena)
    // We must clone them before parsed.deinit() is called later.
    // Actually, parsed.deinit() frees all Value trees. We need to copy what we need.
    // Strategy: return the method as a dupe, and keep parsed alive until after dispatch.
    // But we can't return parsed through the function boundary easily.
    // Better: clone method string, id value, and params map contents into allocator.

    const method_owned = try allocator.dupe(u8, method);
    const id_val = if (obj.get("id")) |v| v else std.json.Value{ .null = {} };
    const id_owned = cloneValue(allocator, id_val) catch std.json.Value{ .null = {} };

    // Deep-clone params before deinit — ObjectMap keys and Value strings point into parsed arena.
    const params_cloned: ?std.json.ObjectMap = if (getNestedObject(obj, "params")) |p| blk: {
        break :blk try cloneObjectMapDeep(allocator, p);
    } else null;

    // We're done with parsed — deinit it. method_owned, id_owned, and params_cloned are independent copies.
    parsed.deinit();

    return MCPRequest{
        .method = method_owned,
        .id = id_owned,
        .params = params_cloned,
    };
}

/// Clone a JSON Value into a separately-allocated copy (shallow for strings, deep for objects).
fn cloneValue(allocator: std.mem.Allocator, val: std.json.Value) !std.json.Value {
    return switch (val) {
        .null => .{ .null = {} },
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        else => .{ .null = {} },
    };
}

/// Deep-clone a JSON Value including nested objects and arrays.
fn cloneValueDeep(allocator: std.mem.Allocator, val: std.json.Value) !std.json.Value {
    return switch (val) {
        .null => .{ .null = {} },
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .object => |o| .{ .object = try cloneObjectMapDeep(allocator, o) },
        .array => |a| blk: {
            var arr = try allocator.alloc(std.json.Value, a.items.len);
            errdefer {
                for (arr) |*item| freeValueDeep(allocator, item);
                allocator.free(arr);
            }
            for (a.items, 0..) |item, i| {
                arr[i] = try cloneValueDeep(allocator, item);
            }
            break :blk .{ .array = .{ .items = arr, .capacity = arr.len, .allocator = allocator } };
        },
    };
}

/// Deep-clone an ObjectMap, duplicating all keys and recursively cloning all values.
fn cloneObjectMapDeep(allocator: std.mem.Allocator, src: std.json.ObjectMap) anyerror!std.json.ObjectMap {
    var dst: std.json.ObjectMap = .empty;
    errdefer freeObjectMapDeep(allocator, &dst);

    var it = src.iterator();
    while (it.next()) |entry| {
        const key_dupe = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_dupe);
        var val_clone = try cloneValueDeep(allocator, entry.value_ptr.*);
        errdefer freeValueDeep(allocator, &val_clone);
        try dst.put(allocator, key_dupe, val_clone);
    }
    return dst;
}

/// Free a deep-cloned ObjectMap (keys + nested values).
fn freeObjectMapDeep(allocator: std.mem.Allocator, map: *std.json.ObjectMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var val = entry.value_ptr.*;
        freeValueDeep(allocator, &val);
    }
    map.deinit(allocator);
}

/// Free a deep-cloned Value (strings, nested objects, arrays).
fn freeValueDeep(allocator: std.mem.Allocator, val: *std.json.Value) void {
    switch (val.*) {
        .number_string => |s| {
            allocator.free(s);
            val.* = .{ .number_string = &.{} };
        },
        .string => |s| {
            allocator.free(s);
            val.* = .{ .string = &.{} };
        },
        .object => |*o| {
            var map = o.*;
            freeObjectMapDeep(allocator, &map);
            val.* = .{ .null = {} };
        },
        .array => |*a| {
            for (a.items) |*item| freeValueDeep(allocator, item);
            allocator.free(a.items);
            val.* = .{ .null = {} };
        },
        else => {},
    }
}

/// Free a cloned value.
fn freeValue(allocator: std.mem.Allocator, val: std.json.Value) void {
    switch (val) {
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        else => {},
    }
}

// ── Request dispatch ───────────────────────────────────────────────────────

fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: ?*anyopaque,
    handler: ?Handler,
    req: MCPRequest,
) !void {
    var params_mut = req.params;
    defer allocator.free(req.method);
    defer freeValue(allocator, req.id);
    defer if (params_mut) |*p| freeObjectMapDeep(allocator, p);

    const is_notification = switch (req.id) {
        .null => true,
        else => false,
    };

    if (std.mem.eql(u8, req.method, "initialize")) {
        // Build SERVER_INFO with actual version
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(allocator);
        // Split around __VERSION__ and insert actual version
        var iter = std.mem.splitSequence(u8, SERVER_INFO, "__VERSION__");
        var first = true;
        while (iter.next()) |part| {
            if (!first) try info.appendSlice(allocator, protocol.VERSION);
            try info.appendSlice(allocator, part);
            first = false;
        }
        try sendResponse(io, req.id, info.items);
    } else if (std.mem.eql(u8, req.method, "notifications/initialized")) {
        // Notification — no response
    } else if (std.mem.eql(u8, req.method, "ping")) {
        try sendResponse(io, req.id, "{}");
    } else if (std.mem.eql(u8, req.method, "tools/list")) {
        // Build tools list with actual version
        var tools: std.ArrayList(u8) = .empty;
        defer tools.deinit(allocator);
        try tools.appendSlice(allocator, "{\"tools\":");
        var iter2 = std.mem.splitSequence(u8, TOOLS_JSON, "__VERSION__");
        var first2 = true;
        while (iter2.next()) |part| {
            if (!first2) try tools.appendSlice(allocator, protocol.VERSION);
            try tools.appendSlice(allocator, part);
            first2 = false;
        }
        try tools.appendSlice(allocator, "}");
        try sendResponse(io, req.id, tools.items);
    } else if (std.mem.eql(u8, req.method, "tools/call")) {
        const params = req.params orelse {
            if (!is_notification) {
                try sendError(io, req.id, -32602, "Missing params");
            }
            return;
        };

        const tool_name = getString(params, "name") orelse {
            if (!is_notification) {
                try sendError(io, req.id, -32602, "Missing tool name");
            }
            return;
        };

        const args = getNestedObject(params, "arguments");

        const result = blk: {
            if (std.mem.eql(u8, tool_name, "vm_status")) {
                break :blk handleVmStatus(allocator, io, ctx, handler) catch |err| {
                    if (!is_notification) {
                        try sendError(io, req.id, -32603, @errorName(err));
                    }
                    return;
                };
            } else if (std.mem.eql(u8, tool_name, "vm_exec")) {
                if (args == null) {
                    if (!is_notification) {
                        try sendError(io, req.id, -32602, "Missing arguments: vm, command");
                    }
                    return;
                }
                const vm = getString(args.?, "vm") orelse {
                    if (!is_notification) {
                        try sendError(io, req.id, -32602, "Missing argument: vm");
                    }
                    return;
                };
                const command = getString(args.?, "command") orelse {
                    if (!is_notification) {
                        try sendError(io, req.id, -32602, "Missing argument: command");
                    }
                    return;
                };
                break :blk handleVmExec(allocator, io, ctx, handler, vm, command) catch |err| {
                    if (!is_notification) {
                        try sendError(io, req.id, -32603, @errorName(err));
                    }
                    return;
                };
            } else {
                if (!is_notification) {
                    try sendError(io, req.id, -32601, "Unknown tool");
                }
                return;
            }
        };
        defer allocator.free(result);

        if (!is_notification) {
            try sendResponse(io, req.id, result);
        }
    } else {
        if (!is_notification) {
            try sendError(io, req.id, -32601, "Method not found");
        }
    }
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Adapter mode: each tool call uses direct UDP+TCP (no Host daemon needed).
/// Blocks until stdin closes (Claude Code exits).
pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    std.debug.print("[mcp] MCP server starting (adapter mode, direct UDP+TCP)\n", .{});
    try mcpLoop(io, allocator, null, null);
}

/// Integrated mode: tool calls dispatch directly to handler (no TCP roundtrip).
/// Blocks until stdin closes (Claude Code exits).
pub fn runDirect(io: std.Io, allocator: std.mem.Allocator, ctx: *anyopaque, handler: Handler) !void {
    std.debug.print("[mcp] MCP server starting (integrated mode, direct handler)\n", .{});
    try mcpLoop(io, allocator, ctx, handler);
}

fn mcpLoop(io: std.Io, allocator: std.mem.Allocator, ctx: ?*anyopaque, handler: ?Handler) !void {
    // Persistent buffered stdin reader — creating a new one per request causes
    // buffered data to be lost between requests.
    var rb: [65536]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &rb);

    while (true) {
        const req = readRequest(allocator, &reader) catch |err| switch (err) {
            error.EndOfStream => break,
            error.InvalidJson => {
                // Try to send a parse error (use null id since we can't parse the actual id)
                var wb: [4096]u8 = undefined;
                var writer = std.Io.File.stdout().writer(io, &wb);
                const err_msg = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";
                writer.interface.print("Content-Length: {d}\r\n\r\n{s}\n", .{ err_msg.len, err_msg }) catch {};
                writer.interface.flush() catch {};
                continue;
            },
            else => {
                std.debug.print("[mcp] Request read error: {}\n", .{err});
                continue;
            },
        };

        if (req == null) break; // EndOfStream

        handleRequest(allocator, io, ctx, handler, req.?) catch |err| {
            std.debug.print("[mcp] Request handling error: {}\n", .{err});
        };
    }

    std.debug.print("[mcp] MCP server stopped (stdin closed)\n", .{});
}

// ── Tests ──────────────────────────────────────────────────────────────────

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

test "appendId - null" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendId(&list, std.testing.allocator, .{ .null = {} });
    try std.testing.expectEqualStrings("null", list.items);
}

test "appendId - integer" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendId(&list, std.testing.allocator, .{ .integer = 42 });
    try std.testing.expectEqualStrings("42", list.items);
}

test "appendId - string" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendId(&list, std.testing.allocator, .{ .string = "abc" });
    try std.testing.expectEqualStrings("\"abc\"", list.items);
}

test "appendId - bool true" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendId(&list, std.testing.allocator, .{ .bool = true });
    try std.testing.expectEqualStrings("true", list.items);
}

test "appendId - bool false" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendId(&list, std.testing.allocator, .{ .bool = false });
    try std.testing.expectEqualStrings("false", list.items);
}

test "getString - present" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .string = "value" });
    const result = getString(map, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value", result.?);
}

test "getString - missing" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    const result = getString(map, "nope");
    try std.testing.expect(result == null);
}

test "getString - wrong type" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "key", .{ .integer = 42 });
    const result = getString(map, "key");
    try std.testing.expect(result == null);
}
