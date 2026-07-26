//! MCP (Model Context Protocol) JSON-RPC server.
//!
//! Host-integrated mode: tool handlers read HostState HashMap directly.
//! No UDP discovery, no TCP transport — all through the shared guest table.
//!
//! Methods: initialize, notifications/initialized, ping, tools/list, tools/call.
//! Tools:   vm_status, vm_exec.

const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("protocol.zig");
const httpd = @import("httpd.zig");
const tunproto = @import("tunproto.zig");

// ── MCP protocol constants ─────────────────────────────────────────────────

const SERVER_INFO =
    \\{"protocolVersion":"2024-11-05",
    \\"serverInfo":{"name":"utmm","version":"__VERSION__"},
    \\"capabilities":{"tools":{}}}
;

const TOOLS_JSON =
    \\[{"name":"vm_status","description":"Get status of all UTM virtual machines. Returns hostname, IP, OS/arch, MAC, version, and shell (bash, zsh, or cmd.exe) for each connected Guest.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"vm_exec","description":"Execute a shell command on a UTM virtual machine. The command runs in the VM's native shell. Check vm_status first to see each VM's shell type, then write compatible commands.","inputSchema":{"type":"object","properties":{"vm":{"type":"string","description":"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')"},"command":{"type":"string","description":"Shell command (use POSIX sh for Linux/macOS, cmd.exe syntax for Windows)"}},"required":["vm","command"]}}]
;

// ── JSON value helpers ─────────────────────────────────────────────────────

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getNestedObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |inner| inner,
        else => null,
    };
}

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

fn buildResponseJson(allocator: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendId(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn buildErrorJson(allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendId(&buf, allocator, id);
    try buf.print(allocator, ",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    const escaped_msg = try jsonEscape(allocator, message);
    defer allocator.free(escaped_msg);
    try buf.appendSlice(allocator, escaped_msg);
    try buf.appendSlice(allocator, "\"}}");
    return buf.toOwnedSlice(allocator);
}

// ── Tool handlers (HostState-based, no UDP/TCP) ─────────────────────────────

/// Build vm_status result from HostState guest table.
fn handleVmStatus(allocator: std.mem.Allocator, state: *httpd.HostState) ![]const u8 {
    state.mutex.lock(state.io.?) catch {};
    defer state.mutex.unlock(state.io.?);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    if (state.guests.items.len == 0) {
        return try allocator.dupe(u8, "{\"text\":\"No VMs currently online.\"}");
    }

    try text.appendSlice(allocator, "**UTM Virtual Machines:**\\n");

    for (state.guests.items) |g| {
        try text.print(allocator,
            "- **{s}** — {s} | IP: {s} | MAC: {s} | v{s} | shell: {s}\\n",
            .{ g.hostname, g.target, g.ip, g.mac, g.version, if (g.shell.len > 0) g.shell else "unknown" },
        );
    }

    const text_json = try jsonEscape(allocator, text.items);
    defer allocator.free(text_json);

    var result: std.ArrayList(u8) = .empty;
    try result.print(allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text_json});
    return result.toOwnedSlice(allocator);
}

/// Handle vm_exec via pty model: build pty_input, enqueue frame, poll for marker.
fn handleVmExec(allocator: std.mem.Allocator, state: *httpd.HostState, vm: []const u8, command: []const u8) ![]const u8 {
    // Check guest exists and get shell type
    const guest_shell = blk: {
        state.mutex.lock(state.io.?) catch {};
        defer state.mutex.unlock(state.io.?);
        for (state.guests.items) |g| {
            if (std.mem.eql(u8, g.hostname, vm)) {
                break :blk try allocator.dupe(u8, g.shell);
            }
        }
        return error.GuestNotFound;
    };
    defer allocator.free(guest_shell);

    // Generate unique cmd_id
    const cmd_id = blk: {
        const ts = std.Io.Timestamp.now(state.io.?, .real).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "mcp_{d}", .{ts});
    };
    defer allocator.free(cmd_id);

    // Build pty_input frame with shell-appropriate marker
    const cmd_with_marker = try httpd.buildCmdWithMarker(allocator, guest_shell, command);
    defer allocator.free(cmd_with_marker);

    const frame = try tunproto.buildPtyExecInput(allocator, cmd_id, cmd_with_marker);
    defer allocator.free(frame);

    try state.createOpState(cmd_id);

    const tun = state.getGuestTunnel(vm) orelse {
        return error.GuestNotConnected;
    };
    _ = tun.send(frame) catch {
        return error.TunnelSendFailed;
    };

    // Wait for result — woken by mesh handler thread via wake_event
    while (true) {
        if (state.takeOpResult(cmd_id)) |result| {
            defer allocator.free(result.stdout);

            const trimmed = std.mem.trim(u8, result.stdout, " \n\r");
            const esc_vm = try jsonEscape(allocator, vm);
            defer allocator.free(esc_vm);
            const esc_cmd = try jsonEscape(allocator, command);
            defer allocator.free(esc_cmd);
            const esc_out = try jsonEscape(allocator, trimmed);
            defer allocator.free(esc_out);

            var buf: std.ArrayList(u8) = .empty;
            try buf.print(allocator,
                "{{\"content\":[{{\"type\":\"text\",\"text\":\"**{s}** `$ {s}`:\\n```\\n{s}\\n```\"}}]}}",
                .{ esc_vm, esc_cmd, esc_out },
            );
            return buf.toOwnedSlice(allocator);
        }
        state.wake_event.waitTimeout(state.io.?, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } }) catch {
            return error.ExecTimeout;
        };
        state.wake_event.reset();
    }
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Process a raw JSON-RPC request string using HostState, return JSON-RPC response.
/// Called from the unified HTTP server's /mcp endpoint.
pub fn processJsonRpcWithState(
    allocator: std.mem.Allocator,
    state: *httpd.HostState,
    json_str: []const u8,
) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{ .allocate = .alloc_always }) catch |err| {
        return buildErrorJson(allocator, .{ .null = {} }, -32700, @errorName(err));
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return buildErrorJson(allocator, .{ .null = {} }, -32600, "Invalid Request"),
    };

    const method_raw = getString(obj, "method") orelse
        return buildErrorJson(allocator, .{ .null = {} }, -32600, "Missing method");

    const id_val = if (obj.get("id")) |v| v else std.json.Value{ .null = {} };
    const is_notification = switch (id_val) {
        .null => true,
        else => false,
    };

    const method = try allocator.dupe(u8, method_raw);
    defer allocator.free(method);

    if (std.mem.eql(u8, method, "initialize")) {
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(allocator);
        var iter = std.mem.splitSequence(u8, SERVER_INFO, "__VERSION__");
        var first = true;
        while (iter.next()) |part| {
            if (!first) try info.appendSlice(allocator, protocol.VERSION);
            try info.appendSlice(allocator, part);
            first = false;
        }
        return buildResponseJson(allocator, id_val, info.items);
    }

    if (std.mem.eql(u8, method, "notifications/initialized")) {
        if (is_notification) return allocator.dupe(u8, "");
        return buildResponseJson(allocator, id_val, "{}");
    }

    if (std.mem.eql(u8, method, "ping")) {
        return buildResponseJson(allocator, id_val, "{}");
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        var tools: std.ArrayList(u8) = .empty;
        defer tools.deinit(allocator);
        try tools.appendSlice(allocator, "{\"tools\":");
        var iter = std.mem.splitSequence(u8, TOOLS_JSON, "__VERSION__");
        var first = true;
        while (iter.next()) |part| {
            if (!first) try tools.appendSlice(allocator, protocol.VERSION);
            try tools.appendSlice(allocator, part);
            first = false;
        }
        try tools.appendSlice(allocator, "}");
        return buildResponseJson(allocator, id_val, tools.items);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = getNestedObject(obj, "params") orelse {
            if (is_notification) return allocator.dupe(u8, "");
            return buildErrorJson(allocator, id_val, -32602, "Missing params");
        };

        const tool_name = getString(params, "name") orelse {
            if (is_notification) return allocator.dupe(u8, "");
            return buildErrorJson(allocator, id_val, -32602, "Missing tool name");
        };

        const args = getNestedObject(params, "arguments");

        if (std.mem.eql(u8, tool_name, "vm_status")) {
            const result = handleVmStatus(allocator, state) catch |err| {
                if (is_notification) return allocator.dupe(u8, "");
                return buildErrorJson(allocator, id_val, -32603, @errorName(err));
            };
            defer allocator.free(result);
            return buildResponseJson(allocator, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "vm_exec")) {
            if (args == null) {
                if (is_notification) return allocator.dupe(u8, "");
                return buildErrorJson(allocator, id_val, -32602, "Missing arguments: vm, command");
            }
            const vm = getString(args.?, "vm") orelse {
                if (is_notification) return allocator.dupe(u8, "");
                return buildErrorJson(allocator, id_val, -32602, "Missing argument: vm");
            };
            const command = getString(args.?, "command") orelse {
                if (is_notification) return allocator.dupe(u8, "");
                return buildErrorJson(allocator, id_val, -32602, "Missing argument: command");
            };
            const result = handleVmExec(allocator, state, vm, command) catch |err| {
                if (is_notification) return allocator.dupe(u8, "");
                return buildErrorJson(allocator, id_val, -32603, @errorName(err));
            };
            defer allocator.free(result);
            return buildResponseJson(allocator, id_val, result);
        }

        if (is_notification) return allocator.dupe(u8, "");
        return buildErrorJson(allocator, id_val, -32601, "Unknown tool");
    }

    if (is_notification) return allocator.dupe(u8, "");
    return buildErrorJson(allocator, id_val, -32601, "Method not found");
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
