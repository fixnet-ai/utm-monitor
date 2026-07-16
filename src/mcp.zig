//! MCP (Model Context Protocol) JSON-RPC server over stdio.
//!
//! Two modes:
//!   run()       — Adapter: connects to Host IPC (127.0.0.1:12347) for each tool call
//!   runDirect() — Integrated: calls ipcHandler directly (same process, no TCP overhead)
//!
//! Framing: LSP-style Content-Length: N\r\n\r\n<JSON>\n on stdin/stdout.
//! Methods: initialize, notifications/initialized, ping, tools/list, tools/call.
//! Tools:   vm_status, vm_exec.

const std = @import("std");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");

const IPC_PORT = ipc.IPC_PORT;

// ── MCP protocol constants ─────────────────────────────────────────────────

const SERVER_INFO =
    \\{"protocolVersion":"2024-11-05",
    \\"serverInfo":{"name":"utmm","version":"__VERSION__"},
    \\"capabilities":{"tools":{}}}
;

const TOOLS_JSON =
    \\[{"name":"vm_status","description":"Get status of all UTM virtual machines. Returns hostname, IP, OS/arch, MAC, version, and whether an upgrade is available for each VM.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"vm_exec","description":"Execute a shell command on a UTM virtual machine. Use this to run tests, check files, install packages, or debug on any VM (Linux/macOS/Windows). The VM name is the hostname (e.g. 'linuxvm', 'macvm', 'windowsvm').","inputSchema":{"type":"object","properties":{"vm":{"type":"string","description":"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')"},"command":{"type":"string","description":"Shell command to execute on the VM"}},"required":["vm","command"]}}]
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
    var wb: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &wb);
    writer.interface.print("Content-Length: {d}\r\n\r\n{s}\n", .{ json.len, json }) catch {};
    writer.interface.flush() catch {};
}

// ── Tool handlers ──────────────────────────────────────────────────────────

/// Execute a tool via IPC (adapter mode) or direct handler (integrated mode).
fn execToolViaIpc(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
) ![]const u8 {
    return ipc.sendCommandRaw(io, allocator, command);
}

fn execToolDirect(
    _: std.mem.Allocator,
    ctx: *anyopaque,
    handler: ipc.Handler,
    command: []const u8,
) ![]const u8 {
    return handler(ctx, command);
}

/// Handle vm_status: STATUS_JSON → markdown + JSON.
fn handleVmStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: ?*anyopaque,
    handler: ?ipc.Handler,
) ![]const u8 {
    const raw = if (ctx) |c| try execToolDirect(allocator, c, handler.?, "STATUS_JSON")
        else try execToolViaIpc(allocator, io, "STATUS_JSON");
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
        const upgradable = switch (obj.get("upgradable") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        const status_str = if (upgradable) "⚠ upgradeable" else "✓";

        try text.print(allocator, 
            "- **{s}** — {s} | IP: {s} | MAC: {s} | v{s} | {s}\\n",
            .{ hostname, target, ip, mac, version, status_str },
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
    handler: ?ipc.Handler,
    vm: []const u8,
    command: []const u8,
) ![]const u8 {
    const ipc_cmd = try std.fmt.allocPrint(allocator, "EXEC\n{s}\n{s}", .{ vm, command });
    defer allocator.free(ipc_cmd);

    const raw = if (ctx) |c| try execToolDirect(allocator, c, handler.?, ipc_cmd)
        else try execToolViaIpc(allocator, io, ipc_cmd);
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
fn readRequest(allocator: std.mem.Allocator, io: std.Io) !?MCPRequest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Read until we have a complete Content-Length header + body
    var rb: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &rb);

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

    const params_obj = getNestedObject(obj, "params");

    // We're done with parsed — deinit it. method_owned and id_owned are independent copies.
    parsed.deinit();

    return MCPRequest{
        .method = method_owned,
        .id = id_owned,
        .params = params_obj,
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
    handler: ?ipc.Handler,
    req: MCPRequest,
) !void {
    defer allocator.free(req.method);
    defer freeValue(allocator, req.id);

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

/// Adapter mode: each tool call forwards to Host IPC (127.0.0.1:12347).
/// Blocks until stdin closes (Claude Code exits).
pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    std.debug.print("[mcp] MCP server starting (adapter mode, IPC 127.0.0.1:{d})\n", .{IPC_PORT});
    try mcpLoop(io, allocator, null, null);
}

/// Integrated mode: tool calls dispatch directly to ipcHandler (no TCP roundtrip).
/// Blocks until stdin closes (Claude Code exits). Host services run in threads.
pub fn runDirect(io: std.Io, allocator: std.mem.Allocator, ctx: *anyopaque, handler: ipc.Handler) !void {
    std.debug.print("[mcp] MCP server starting (integrated mode, direct handler)\n", .{});
    try mcpLoop(io, allocator, ctx, handler);
}

fn mcpLoop(io: std.Io, allocator: std.mem.Allocator, ctx: ?*anyopaque, handler: ?ipc.Handler) !void {
    while (true) {
        const req = readRequest(allocator, io) catch |err| switch (err) {
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
