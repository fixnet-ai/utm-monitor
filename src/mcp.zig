//! MCP stdio server — AI agent interface via stdin/stdout JSON-RPC 2.0.
//!
//! The utmm --mcp command starts a stdio MCP server. Tool calls (vm_status,
//! vm_exec) are translated to HTTP management commands against the local Host
//! service (127.0.0.1:2121), benefiting from auto-ensure (Phase 52).
//!
//! Protocol: newline-delimited JSON, one JSON-RPC object per line.
//! Logging goes to stderr; JSON-RPC traffic goes to stdout.

const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("protocol.zig");
const ipc_mod = @import("ipc.zig");

/// Maximum JSON-RPC request size (64KB).
const MAX_REQUEST_SIZE = 65536;

/// MCP server info (JSON, with __VERSION__ placeholder).
const SERVER_INFO =
    \\{"protocolVersion":"2024-11-05",
    \\"serverInfo":{"name":"utmm","version":"__VERSION__"},
    \\"capabilities":{"tools":{}}}
;

/// MCP tool definitions (JSON).
const TOOLS_JSON =
    \\[{"name":"vm_status","description":"Get status of all UTM virtual machines. Returns hostname, IP, OS/arch, MAC, version, and shell (bash, zsh, or cmd.exe) for each connected Guest.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"vm_exec","description":"Execute a shell command on a UTM virtual machine. The command runs in the VM's native shell. Check vm_status first to see each VM's shell type, then write compatible commands.","inputSchema":{"type":"object","properties":{"vm":{"type":"string","description":"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')"},"command":{"type":"string","description":"Shell command (use POSIX sh for Linux/macOS, cmd.exe syntax for Windows)"}},"required":["vm","command"]}}]
;

/// MCP server entry point. Reads JSON-RPC from stdin, writes responses to stdout.
pub fn run(io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin_r = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout_w = &stdout_writer.interface;

    // Read JSON-RPC requests line by line until EOF.
    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(gpa);

    while (true) {
        req_buf.clearRetainingCapacity();

        // Read until newline (MCP stdio transport: one JSON object per line).
        const line = stdin_r.takeDelimiter('\n') catch |err| {
            std.log.err("[mcp] stdin read error: {}", .{err});
            break;
        };
        if (line == null) break; // EOF

        const json_str = line.?;

        // Process the request
        const response = processRequest(gpa, io, port, json_str) catch |err| {
            std.log.err("[mcp] processRequest error: {}", .{err});
            // Try to send an error response
            const err_resp = jsonBuildError(gpa, .{ .null = {} }, -32603, @errorName(err)) catch continue;
            defer gpa.free(err_resp);
            stdout_w.print("{s}\n", .{err_resp}) catch break;
            try stdout_w.flush();
            continue;
        };
        defer gpa.free(response);

        // Write response (skip empty responses for notifications)
        if (response.len > 0) {
            stdout_w.print("{s}\n", .{response}) catch break;
            try stdout_w.flush();
        }
    }
}

/// Process a single JSON-RPC request string, return the response JSON string.
/// Caller owns the returned buffer.
fn processRequest(gpa: std.mem.Allocator, io: std.Io, port: u16, json_str: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        return jsonBuildError(gpa, .{ .null = {} }, -32700, @errorName(err));
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return jsonBuildError(gpa, .{ .null = {} }, -32600, "Invalid Request"),
    };

    const method_raw = jsonGetString(obj, "method") orelse
        return jsonBuildError(gpa, .{ .null = {} }, -32600, "Missing method");

    const id_val = if (obj.get("id")) |v| v else std.json.Value{ .null = {} };
    const is_notification = switch (id_val) {
        .null => true,
        else => false,
    };

    const method = try gpa.dupe(u8, method_raw);
    defer gpa.free(method);

    if (std.mem.eql(u8, method, "initialize")) {
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(gpa);
        var iter = std.mem.splitSequence(u8, SERVER_INFO, "__VERSION__");
        var first = true;
        while (iter.next()) |part| {
            if (!first) try info.appendSlice(gpa, protocol.VERSION);
            try info.appendSlice(gpa, part);
            first = false;
        }
        return jsonBuildResponse(gpa, id_val, info.items);
    }

    if (std.mem.eql(u8, method, "notifications/initialized")) {
        if (is_notification) return gpa.dupe(u8, "");
        return jsonBuildResponse(gpa, id_val, "{}");
    }

    if (std.mem.eql(u8, method, "ping")) {
        return jsonBuildResponse(gpa, id_val, "{}");
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        var tools: std.ArrayList(u8) = .empty;
        defer tools.deinit(gpa);
        try tools.appendSlice(gpa, "{\"tools\":");
        var iter = std.mem.splitSequence(u8, TOOLS_JSON, "__VERSION__");
        var first = true;
        while (iter.next()) |part| {
            if (!first) try tools.appendSlice(gpa, protocol.VERSION);
            try tools.appendSlice(gpa, part);
            first = false;
        }
        try tools.appendSlice(gpa, "}");
        return jsonBuildResponse(gpa, id_val, tools.items);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = jsonGetNestedObject(obj, "params") orelse {
            if (is_notification) return gpa.dupe(u8, "");
            return jsonBuildError(gpa, id_val, -32602, "Missing params");
        };

        const tool_name = jsonGetString(params, "name") orelse {
            if (is_notification) return gpa.dupe(u8, "");
            return jsonBuildError(gpa, id_val, -32602, "Missing tool name");
        };

        const args = jsonGetNestedObject(params, "arguments");

        if (std.mem.eql(u8, tool_name, "vm_status")) {
            const result = handleVmStatus(gpa, io, port) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "vm_exec")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: vm, command");
            }
            const vm = jsonGetString(args.?, "vm") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: vm");
            };
            const command = jsonGetString(args.?, "command") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: command");
            };
            const result = handleVmExec(gpa, io, port, vm, command) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (is_notification) return gpa.dupe(u8, "");
        return jsonBuildError(gpa, id_val, -32601, "Unknown tool");
    }

    if (is_notification) return gpa.dupe(u8, "");
    return jsonBuildError(gpa, id_val, -32601, "Method not found");
}

/// Handle vm_status via IPC. HTTP handler preserved for future WebUI.
fn handleVmStatus(gpa: std.mem.Allocator, io: std.Io, port: u16) ![]const u8 {
    _ = port; // HTTP handlers preserved for future WebUI
    const json = try ipc_mod.ipcStatus(io, gpa);
    defer gpa.free(json);
    return formatStatusMCP(gpa, json);
}

/// Format a JSON guest list string into MCP content markdown.
fn formatStatusMCP(gpa: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        std.log.err("[mcp] vm_status JSON parse: {}", .{err});
        return error.StatusFailed;
    };
    defer parsed.deinit();

    const guests = switch (parsed.value) {
        .array => |arr| arr,
        else => {
            const text = try gpa.dupe(u8, "{\"text\":\"No VMs currently online.\"}");
            return std.fmt.allocPrint(gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text});
        },
    };

    if (guests.items.len == 0) {
        return try gpa.dupe(u8, "{\"content\":[{\"type\":\"text\",\"text\":\"No VMs currently online.\"}]}");
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);

    try text.appendSlice(gpa, "**UTM Virtual Machines:**\\n");

    for (guests.items) |guest_val| {
        const g = switch (guest_val) {
            .object => |o| o,
            else => continue,
        };
        const hostname = jsonGetString(g, "hostname") orelse "?";
        const target = jsonGetString(g, "target") orelse "?";
        const ip = jsonGetString(g, "ip") orelse "?";
        const mac = jsonGetString(g, "mac") orelse "?";
        const version = jsonGetString(g, "version") orelse "?";
        const shell = jsonGetString(g, "shell") orelse "?";
        try text.print(gpa,
            "- **{s}** — {s} | IP: {s} | MAC: {s} | v{s} | shell: {s}\\n",
            .{ hostname, target, ip, mac, version, if (shell.len > 0) shell else "unknown" },
        );
    }

    const text_json = try jsonEscape(gpa, text.items);
    defer gpa.free(text_json);

    return std.fmt.allocPrint(gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text_json});
}

/// Handle vm_exec via IPC. HTTP handler preserved for future WebUI.
fn handleVmExec(gpa: std.mem.Allocator, io: std.Io, port: u16, vm: []const u8, command: []const u8) ![]const u8 {
    _ = port; // HTTP handlers preserved for future WebUI
    // IPC-only — capture output in a fixed buffer
    var output_buf: [65536]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output_buf);
    const exit_code = try ipc_mod.ipcExec(io, gpa, vm, command, &output_writer);
    return formatExecMCP(gpa, vm, command, output_writer.buffered(), exit_code);
}

/// Format exec output into MCP content markdown.
fn formatExecMCP(gpa: std.mem.Allocator, vm: []const u8, command: []const u8, output: []const u8, exit_code: i32) ![]const u8 {
    const trimmed = std.mem.trim(u8, output, " \n\r");
    const esc_vm = try jsonEscape(gpa, vm);
    defer gpa.free(esc_vm);
    const esc_cmd = try jsonEscape(gpa, command);
    defer gpa.free(esc_cmd);
    const esc_out = try jsonEscape(gpa, trimmed);
    defer gpa.free(esc_out);

    if (exit_code != 0) {
        return std.fmt.allocPrint(gpa,
            "{{\"content\":[{{\"type\":\"text\",\"text\":\"**{s}** `$ {s}` (exit {d}):\\n```\\n{s}\\n```\"}}]}}",
            .{ esc_vm, esc_cmd, exit_code, esc_out },
        );
    }

    return std.fmt.allocPrint(gpa,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"**{s}** `$ {s}`:\\n```\\n{s}\\n```\"}}]}}",
        .{ esc_vm, esc_cmd, esc_out },
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// JSON helper utilities
// ═══════════════════════════════════════════════════════════════════════════

/// Escape a string for JSON (backslash-escapes quotes, backslash, newlines, etc.).
fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (text) |ch| {
        switch (ch) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try result.print(allocator, "\\u{d:0>4}", .{ch});
                } else {
                    try result.append(allocator, ch);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Build a JSON-RPC 2.0 success response.
fn jsonBuildResponse(allocator: std.mem.Allocator, id_val: std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC 2.0 error response.
fn jsonBuildError(allocator: std.mem.Allocator, id_val: std.json.Value, code: i32, message: []const u8) ![]const u8 {
    const esc_msg = try jsonEscape(allocator, message);
    defer allocator.free(esc_msg);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try jsonAppendId(&buf, allocator, id_val);
    try buf.print(allocator, ",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, esc_msg });
    return buf.toOwnedSlice(allocator);
}

/// Append a JSON-RPC id value to a list. Handles null, integer, string, float, bool.
fn jsonAppendId(list: *std.ArrayList(u8), allocator: std.mem.Allocator, id_val: std.json.Value) !void {
    switch (id_val) {
        .null => try list.appendSlice(allocator, "null"),
        .integer => |n| try list.print(allocator, "{d}", .{n}),
        .string => |s| try list.print(allocator, "\"{s}\"", .{s}),
        .float => |f| try list.print(allocator, "{d}", .{f}),
        .bool => |b| try list.appendSlice(allocator, if (b) "true" else "false"),
        else => try list.appendSlice(allocator, "null"),
    }
}

/// Get a string value from a JSON object by key.
fn jsonGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get a nested object value from a JSON object by key.
fn jsonGetNestedObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "jsonEscape basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonEscape(alloc, "hello");
    try std.testing.expectEqualStrings("hello", result);
}

test "jsonEscape with quotes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonEscape(alloc, "say \"hi\"");
    try std.testing.expectEqualStrings("say \\\"hi\\\"", result);
}

test "jsonEscape with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonEscape(alloc, "line1\nline2");
    try std.testing.expectEqualStrings("line1\\nline2", result);
}

test "jsonBuildResponse null id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonBuildResponse(alloc, .{ .null = {} }, "{}");
    try std.testing.expect(std.mem.indexOf(u8, result, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":null") != null);
}

test "jsonBuildResponse integer id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonBuildResponse(alloc, .{ .integer = 42 }, "{}");
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":42") != null);
}

test "jsonBuildError" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try jsonBuildError(alloc, .{ .null = {} }, -32601, "Method not found");
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32601") != null);
}

test "jsonGetString found" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"key": "value"}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const result = jsonGetString(obj, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value", result.?);
}

test "jsonGetString missing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"other": "value"}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const result = jsonGetString(obj, "key");
    try std.testing.expect(result == null);
}

test "jsonAppendId null" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);

    try jsonAppendId(&list, alloc, .{ .null = {} });
    try std.testing.expectEqualStrings("null", list.items);
}

test "jsonAppendId integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);

    try jsonAppendId(&list, alloc, .{ .integer = 42 });
    try std.testing.expectEqualStrings("42", list.items);
}

test "jsonAppendId string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);

    try jsonAppendId(&list, alloc, .{ .string = "req-1" });
    try std.testing.expectEqualStrings("\"req-1\"", list.items);
}

test "jsonAppendId true" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);

    try jsonAppendId(&list, alloc, .{ .bool = true });
    try std.testing.expectEqualStrings("true", list.items);
}

test "jsonGetNestedObject found" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"params": {"name": "test"}}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const nested = jsonGetNestedObject(obj, "params");
    try std.testing.expect(nested != null);
}

test "jsonGetNestedObject missing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"other": {}}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const nested = jsonGetNestedObject(obj, "params");
    try std.testing.expect(nested == null);
}
