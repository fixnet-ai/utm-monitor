//! MCP stdio server — AI agent interface via stdin/stdout JSON-RPC 2.0.
//!
//! The utmm --mcp command starts a stdio MCP server. Tool calls (status,
//! exec, ping, upload, download, sshpass) are translated to IPC commands
//! against the local Host service via /var/run/utmm.sock, benefiting from
//! auto-ensure — auto-starts Host if not running. sshpass spawns utmm as
//! direct SSH access to machines without utmm installed.
//!
//! Protocol: newline-delimited JSON, one JSON-RPC object per line.
//! Logging goes to stderr; JSON-RPC traffic goes to stdout.

const std = @import("std");
const protocol = @import("protocol.zig");
const ipc_mod = @import("ipc.zig");
const sshpass = @import("sshpass.zig");

/// Guest default upload directory — platform-aware default for remote_path.
fn guestDefaultDir(vm: []const u8) []const u8 {
    if (std.mem.indexOf(u8, vm, "win") != null) return "C:\\opt\\utmm";
    return "/opt/utmm";
}

/// Maximum JSON-RPC request size (64KB).
const MAX_REQUEST_SIZE = 65536;

/// MCP server info (JSON, with __VERSION__ placeholder). Single-line for MCP stdio transport.
const SERVER_INFO = "{\"protocolVersion\":\"2024-11-05\",\"serverInfo\":{\"name\":\"utmm\",\"version\":\"__VERSION__\"},\"capabilities\":{\"tools\":{}}}";

/// MCP tool definitions (JSON). Single-line for MCP stdio transport.
const TOOLS_JSON = "[{\"name\":\"status\",\"description\":\"Get status of all UTM virtual machines. Returns hostname, IP, OS/arch, MAC, version, and shell (bash, zsh, or cmd.exe) for each connected Guest.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},{\"name\":\"exec\",\"description\":\"Execute a shell command on a UTM virtual machine. The command runs in the VM's native shell. Check status first to see each VM's shell type, then write compatible commands.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"vm\":{\"type\":\"string\",\"description\":\"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')\"},\"command\":{\"type\":\"string\",\"description\":\"Shell command (use POSIX sh for Linux/macOS, cmd.exe syntax for Windows)\"}},\"required\":[\"vm\",\"command\"]}},{\"name\":\"ping\",\"description\":\"Ping a Guest over the mesh network to test connectivity and measure RTT. Returns JSON with hostname, MAC address, and rtt_ms.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"vm\":{\"type\":\"string\",\"description\":\"Target VM hostname (e.g. 'linuxvm', 'macvm', 'windowsvm')\"}},\"required\":[\"vm\"]}},{\"name\":\"upload\",\"description\":\"Upload a file from the Host to a Guest VM. The file is transferred through a TCP/SOCKS5 connection with SHA256 verification.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"vm\":{\"type\":\"string\",\"description\":\"Target VM hostname\"},\"local_path\":{\"type\":\"string\",\"description\":\"Path to the file on the Host filesystem\"},\"remote_path\":{\"type\":\"string\",\"description\":\"Destination path on the Guest (e.g. /opt/utmm/file.txt). Defaults to /opt/utmm/<basename> (POSIX) or C:\\\\opt\\\\utmm\\\\<basename> (Windows) if omitted.\"}},\"required\":[\"vm\",\"local_path\"]}},{\"name\":\"download\",\"description\":\"Download a file from a Guest VM to the Host. The file is transferred through a TCP/SOCKS5 connection with SHA256 verification.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"vm\":{\"type\":\"string\",\"description\":\"Target VM hostname\"},\"remote_path\":{\"type\":\"string\",\"description\":\"Path to the file on the Guest (e.g. /opt/utmm/core.dump)\"},\"local_path\":{\"type\":\"string\",\"description\":\"Local path on the Host to save the file. Defaults to ./<basename> if omitted.\"}},\"required\":[\"vm\",\"remote_path\"]}},{\"name\":\"sshpass\",\"description\":\"Execute a shell command on any machine via non-interactive SSH password authentication. Works on Linux, macOS, and Windows (ConPTY dynamic loading). Use this for direct SSH access to machines that may not have utmm installed — bootstrap, recovery, and pre-install scenarios. For machines already running utmm Guest daemon, prefer the exec tool for mesh-based command execution.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"host\":{\"type\":\"string\",\"description\":\"Target hostname or IP address (e.g. 'linuxvm', '192.168.64.6')\"},\"user\":{\"type\":\"string\",\"description\":\"SSH username (e.g. 'root', 'Administrator')\"},\"password\":{\"type\":\"string\",\"description\":\"SSH password\"},\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute on the remote machine\"}},\"required\":[\"host\",\"user\",\"password\",\"command\"]}}]";

/// MCP server entry point. Reads JSON-RPC from stdin, writes responses to stdout.
pub fn run(io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    return runWithPipe(io, gpa, port, &stdin_reader.interface, &stdout_writer.interface);
}

/// Core MCP loop — reads JSON-RPC from `reader`, writes responses to `writer`.
/// Testable with Reader.fixed / Writer.fixed for protocol verification.
pub fn runWithPipe(
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    // Read JSON-RPC requests line by line until EOF.
    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(gpa);

    while (true) {
        req_buf.clearRetainingCapacity();

        // Read until newline (MCP stdio transport: one JSON object per line).
        const line = reader.takeDelimiter('\n') catch |err| {
            std.log.err("[mcp] read error: {}", .{err});
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
            _ = writer.print("{s}\n", .{err_resp}) catch break;
            _ = writer.flush() catch |err_flush| {
                std.log.err("[mcp] flush error: {}", .{err_flush});
                break;
            };
            continue;
        };
        defer gpa.free(response);

        // Write response (skip empty responses for notifications)
        if (response.len > 0) {
            _ = writer.print("{s}\n", .{response}) catch break;
            _ = writer.flush() catch |err_flush| {
                std.log.err("[mcp] flush error: {}", .{err_flush});
                break;
            };
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

        if (std.mem.eql(u8, tool_name, "status")) {
            const result = handleVmStatus(gpa, io, port) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "exec")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: vm, command");
            }
            const vm_raw = jsonGetString(args.?, "vm") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: vm");
            };
            const vm = std.ascii.allocLowerString(gpa, vm_raw) catch {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Out of memory");
            };
            defer gpa.free(vm);
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

        if (std.mem.eql(u8, tool_name, "ping")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: vm");
            }
            const vm_raw = jsonGetString(args.?, "vm") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: vm");
            };
            const vm = std.ascii.allocLowerString(gpa, vm_raw) catch {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Out of memory");
            };
            defer gpa.free(vm);
            const result = handleVmPing(gpa, io, port, vm) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "upload")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: vm, local_path");
            }
            const vm_raw = jsonGetString(args.?, "vm") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: vm");
            };
            const vm = std.ascii.allocLowerString(gpa, vm_raw) catch {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Out of memory");
            };
            defer gpa.free(vm);
            const local_path = jsonGetString(args.?, "local_path") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: local_path");
            };
            // remote_path defaults to <canonical_dir>/<basename> (platform-aware)
            const remote_path = jsonGetString(args.?, "remote_path") orelse blk: {
                const basename = if (std.mem.lastIndexOfScalar(u8, local_path, '/')) |pos|
                    local_path[pos + 1 ..]
                else
                    local_path;
                break :blk try std.fmt.allocPrint(gpa, "{s}/{s}", .{ guestDefaultDir(vm), basename });
            };
            const result = handleVmUpload(gpa, io, port, vm, local_path, remote_path) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "download")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: vm, remote_path");
            }
            const vm_raw = jsonGetString(args.?, "vm") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: vm");
            };
            const vm = std.ascii.allocLowerString(gpa, vm_raw) catch {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Out of memory");
            };
            defer gpa.free(vm);
            const remote_path = jsonGetString(args.?, "remote_path") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: remote_path");
            };
            // local_path defaults to ./<basename>
            const local_path = jsonGetString(args.?, "local_path") orelse blk: {
                const basename = if (std.mem.lastIndexOfScalar(u8, remote_path, '/')) |pos|
                    remote_path[pos + 1 ..]
                else
                    remote_path;
                break :blk try std.fmt.allocPrint(gpa, "./{s}", .{basename});
            };
            const result = handleVmDownload(gpa, io, port, vm, remote_path, local_path) catch |err| {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32603, @errorName(err));
            };
            defer gpa.free(result);
            return jsonBuildResponse(gpa, id_val, result);
        }

        if (std.mem.eql(u8, tool_name, "sshpass")) {
            if (args == null) {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing arguments: host, user, password, command");
            }
            const host_raw = jsonGetString(args.?, "host") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: host");
            };
            const user = jsonGetString(args.?, "user") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: user");
            };
            const password = jsonGetString(args.?, "password") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: password");
            };
            const command = jsonGetString(args.?, "command") orelse {
                if (is_notification) return gpa.dupe(u8, "");
                return jsonBuildError(gpa, id_val, -32602, "Missing argument: command");
            };
            const result = handleVmSshpass(gpa, io, host_raw, user, password, command) catch |err| {
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

/// Handle status via IPC.
fn handleVmStatus(gpa: std.mem.Allocator, io: std.Io, port: u16) ![]const u8 {
    _ = port; // IPC handler — port reserved for future use
    const json = try ipc_mod.ipcStatus(io, gpa);
    defer gpa.free(json);
    return formatStatusMCP(gpa, json);
}

/// Format a JSON guest list string into MCP content markdown.
fn formatStatusMCP(gpa: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        std.log.err("[mcp] status JSON parse: {}", .{err});
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
        const role = jsonGetString(g, "role") orelse "?";
        const target = jsonGetString(g, "target") orelse "?";
        const ip = jsonGetString(g, "ip") orelse "?";
        const mac = jsonGetString(g, "mac") orelse "?";
        const version = jsonGetString(g, "version") orelse "?";
        const shell = jsonGetString(g, "shell") orelse "?";
        const status = jsonGetString(g, "status") orelse "?";
        try text.print(gpa,
            "- **{s}** ({s}) — {s} | IP: {s} | MAC: {s} | v{s} | shell: {s} | status: {s}\\n",
            .{ hostname, role, target, ip, mac, version, if (shell.len > 0) shell else "unknown", if (status.len > 0) status else "?" },
        );
    }

    const text_json = try jsonEscape(gpa, text.items);
    defer gpa.free(text_json);

    return std.fmt.allocPrint(gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text_json});
}

/// Handle exec via IPC.
fn handleVmExec(gpa: std.mem.Allocator, io: std.Io, port: u16, vm: []const u8, command: []const u8) ![]const u8 {
    _ = port; // IPC handler — port reserved for future use
    // Captures output in a fixed buffer
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

/// Handle ping via IPC.
fn handleVmPing(gpa: std.mem.Allocator, io: std.Io, port: u16, vm: []const u8) ![]const u8 {
    _ = port;
    const json = try ipc_mod.ipcPing(io, gpa, vm);
    defer gpa.free(json);
    return formatPingMCP(gpa, vm, json);
}

/// Format ping JSON result into MCP content markdown.
fn formatPingMCP(gpa: std.mem.Allocator, vm: []const u8, json_str: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch |err| {
        std.log.err("[mcp] ping JSON parse: {}", .{err});
        return error.PingFailed;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.PingFailed,
    };

    const mac = jsonGetString(obj, "mac") orelse "?";
    const rtt = if (obj.get("rtt_ms")) |v| switch (v) {
        .integer => |n| n,
        else => @as(i64, 0),
    } else @as(i64, 0);

    const esc_vm = try jsonEscape(gpa, vm);
    defer gpa.free(esc_vm);

    return std.fmt.allocPrint(gpa,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"**{s}** ping: MAC={s}, RTT={d}ms\"}}]}}",
        .{ esc_vm, mac, rtt },
    );
}

/// Handle upload via IPC.
fn handleVmUpload(gpa: std.mem.Allocator, io: std.Io, port: u16, vm: []const u8, local_path: []const u8, remote_path: []const u8) ![]const u8 {
    _ = port;
    try ipc_mod.ipcUpload(io, gpa, vm, local_path, remote_path);

    const esc_vm = try jsonEscape(gpa, vm);
    defer gpa.free(esc_vm);
    const esc_local = try jsonEscape(gpa, local_path);
    defer gpa.free(esc_local);
    const esc_remote = try jsonEscape(gpa, remote_path);
    defer gpa.free(esc_remote);

    return std.fmt.allocPrint(gpa,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"Uploaded `{s}` → **{s}**:`{s}`\"}}]}}",
        .{ esc_local, esc_vm, esc_remote },
    );
}

/// Handle download via IPC.
fn handleVmDownload(gpa: std.mem.Allocator, io: std.Io, port: u16, vm: []const u8, remote_path: []const u8, local_path: []const u8) ![]const u8 {
    _ = port;

    // Create local file for writing (createFile = open or create, truncate)
    const file = std.Io.Dir.cwd().createFile(io, local_path, .{}) catch |err| {
        std.log.err("[mcp] Cannot create {s} for write: {}", .{ local_path, err });
        return error.DownloadFailed;
    };
    defer file.close(io);

    var fbuf: [65536]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    const total_bytes = try ipc_mod.ipcDownload(io, gpa, vm, remote_path, &fw.interface);

    const esc_vm = try jsonEscape(gpa, vm);
    defer gpa.free(esc_vm);
    const esc_remote = try jsonEscape(gpa, remote_path);
    defer gpa.free(esc_remote);
    const esc_local = try jsonEscape(gpa, local_path);
    defer gpa.free(esc_local);

    return std.fmt.allocPrint(gpa,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"Downloaded **{s}**:`{s}` → `{s}` ({d} bytes)\"}}]}}",
        .{ esc_vm, esc_remote, esc_local, total_bytes },
    );
}

/// Handle sshpass via child process — spawns `utmm sshpass -p <pass> ssh <user>@<host> <command>`.
fn handleVmSshpass(gpa: std.mem.Allocator, io: std.Io, host: []const u8, user: []const u8, password: []const u8, command: []const u8) ![]const u8 {
    // Build destination string: user@host
    const dest = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ user, host });
    defer gpa.free(dest);

    // Get path to current executable
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);

    // Build SSH command-line args (ssh <dest> <command>), ensure StrictHostKeyChecking
    var ssh_args: std.ArrayList([]const u8) = .empty;
    defer ssh_args.deinit(gpa);
    try ssh_args.append(gpa, "ssh");
    try ssh_args.append(gpa, dest);
    var cmd_iter = std.mem.splitScalar(u8, command, ' ');
    while (cmd_iter.next()) |arg| {
        if (arg.len > 0) try ssh_args.append(gpa, arg);
    }
    try sshpass.ensureStrictHostKeyChecking(gpa, &ssh_args);

    // Build argv: utmm sshpass -p <password> <ssh_args...>
    var argv = try std.ArrayList([]const u8).initCapacity(gpa, 0);
    defer argv.deinit(gpa);
    try argv.append(gpa, exe_path);
    try argv.append(gpa, "sshpass");
    try argv.append(gpa, "-p");
    try argv.append(gpa, password);
    try argv.appendSlice(gpa, ssh_args.items);

    // Spawn child process, collect output, wait
    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .exited => |code| @as(i32, code),
        .signal => |sig| @intCast(@intFromEnum(sig)),
        .stopped => |sig| @intCast(@intFromEnum(sig)),
        .unknown => -1,
    };

    // Build result
    const esc_host = try jsonEscape(gpa, host);
    defer gpa.free(esc_host);
    const esc_user = try jsonEscape(gpa, user);
    defer gpa.free(esc_user);
    const esc_command = try jsonEscape(gpa, command);
    defer gpa.free(esc_command);
    const esc_stdout = try jsonEscape(gpa, result.stdout);
    defer gpa.free(esc_stdout);

    if (exit_code == 0) {
        return std.fmt.allocPrint(gpa,
            "{{\"content\":[{{\"type\":\"text\",\"text\":\"**ssh {s}@{s}** `{s}`\\nexit: {d}\\n```\\n{s}\\n```\"}}]}}",
            .{ esc_user, esc_host, esc_command, exit_code, esc_stdout },
        );
    }

    const esc_stderr = try jsonEscape(gpa, result.stderr);
    defer gpa.free(esc_stderr);
    return std.fmt.allocPrint(gpa,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"**ssh {s}@{s}** `{s}`\\nexit: {d}\\n```\\n{s}\\n```\\nstderr:\\n```\\n{s}\\n```\"}}]}}",
        .{ esc_user, esc_host, esc_command, exit_code, esc_stdout, esc_stderr },
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

// ═══════════════════════════════════════════════════════════════════════════
// processRequest tests — non-IPC methods (no Host service needed)
// ═══════════════════════════════════════════════════════════════════════════

test "processRequest: initialize" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;

    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
    );
    defer alloc.free(result);

    // Must be valid JSON-RPC response with server info
    try std.testing.expect(std.mem.indexOf(u8, result, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "serverInfo") != null);
    // Version placeholder should be replaced with actual version
    try std.testing.expect(std.mem.indexOf(u8, result, "__VERSION__") == null);
}

test "processRequest: ping" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer alloc.free(result);

    // Should return {"jsonrpc":"2.0","id":1,"result":{}}
    try std.testing.expect(std.mem.indexOf(u8, result, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":{}") != null);
}

test "processRequest: tools/list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    // Should contain all 6 tools
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"download\"") != null);
}

test "processRequest: notifications/initialized (notification, no id)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer alloc.free(result);

    // Notification without id returns empty string
    try std.testing.expectEqualStrings("", result);
}

test "processRequest: notifications/initialized with id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":2,"method":"notifications/initialized"}
    );
    defer alloc.free(result);

    // With id present, should return a JSON response with empty object result
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":{}") != null);
}

test "processRequest: unknown method" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"nonexistent"}
    );
    defer alloc.free(result);

    // Should be an error response with code -32601
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32601") != null);
}

test "processRequest: invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121, "not json at all");
    defer alloc.free(result);

    // Should be a parse error -32700
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32700") != null);
}

test "processRequest: missing method" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1}
    );
    defer alloc.free(result);

    // Should be error -32600 Invalid Request
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32600") != null);
}

test "processRequest: non-object root (array)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121, "[1,2,3]");
    defer alloc.free(result);

    // Array instead of object should be Invalid Request -32600
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32600") != null);
}

test "processRequest: string id preserved" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":"req-abc","method":"ping"}
    );
    defer alloc.free(result);

    // String id should be preserved in response
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"req-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":{}") != null);
}

test "processRequest: bool id preserved" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":true,"method":"ping"}
    );
    defer alloc.free(result);

    // Bool id should be preserved
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":true") != null);
}

test "processRequest: tools/call unknown tool" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nonexistent_tool","arguments":{}}}
    );
    defer alloc.free(result);

    // Unknown tool should be error -32601
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32601") != null);
}

test "processRequest: tools/call without params" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    );
    defer alloc.free(result);

    // Missing params should be error -32602
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32602") != null);
}

// ═══════════════════════════════════════════════════════════════════════════
// Format function tests — pure functions, no I/O needed
// ═══════════════════════════════════════════════════════════════════════════

test "formatStatusMCP: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatStatusMCP(alloc, "[]");
    defer alloc.free(result);

    // Empty list should show "No VMs"
    try std.testing.expect(std.mem.indexOf(u8, result, "No VMs currently online.") != null);
}

test "formatStatusMCP: with guests" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatStatusMCP(alloc,
        \\[{"hostname":"linuxvm","role":"guest","target":"aarch64-linux-musl","ip":"192.168.64.6","mac":"aa:bb:cc:dd:ee:ff","version":"0.14.5","shell":"bash","status":"online"}]
    );
    defer alloc.free(result);

    // Should contain guest info in markdown
    try std.testing.expect(std.mem.indexOf(u8, result, "linuxvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "192.168.64.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "aa:bb:cc:dd:ee:ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "0.14.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "online") != null);
    // Should have MCP content format
    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\"") != null);
}

test "formatStatusMCP: non-array input" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatStatusMCP(alloc, "{}");
    defer alloc.free(result);

    // Non-array JSON should fallback to "No VMs"
    try std.testing.expect(std.mem.indexOf(u8, result, "No VMs currently online.") != null);
}

test "formatExecMCP: success (exit 0)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatExecMCP(alloc, "linuxvm", "uname -a", "Linux linuxvm 6.1.0", 0);
    defer alloc.free(result);

    // Should show VM, command, output
    try std.testing.expect(std.mem.indexOf(u8, result, "linuxvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "uname -a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Linux linuxvm 6.1.0") != null);
    // Success (exit 0) should NOT show exit code
    try std.testing.expect(std.mem.indexOf(u8, result, "(exit") == null);
    // Should have MCP content format
    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\"") != null);
}

test "formatExecMCP: error exit (non-zero)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatExecMCP(alloc, "linuxvm", "cat /nonexistent", "cat: /nonexistent: No such file or directory", 1);
    defer alloc.free(result);

    // Error exit code should be shown
    try std.testing.expect(std.mem.indexOf(u8, result, "linuxvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "exit 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "No such file or directory") != null);
}

test "formatExecMCP: special characters escaped" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatExecMCP(alloc, "vm", "echo \"hello\"", "output with\nnewline", 0);
    defer alloc.free(result);

    // Quotes and newlines should be JSON-escaped
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "newline") != null);
}

test "formatExecMCP: trims whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatExecMCP(alloc, "vm", "cmd", "  output with spaces  \n\r", 0);
    defer alloc.free(result);

    // Trimmed output should not have leading/trailing whitespace in the display
    try std.testing.expect(std.mem.indexOf(u8, result, "output with spaces") != null);
}

test "formatPingMCP: valid ping result" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simulate ping response from IPC
    const ping_json =
        \\{"mac":"11:22:33:44:55:66","rtt_ms":3}
    ;
    const result = try formatPingMCP(alloc, "linuxvm", ping_json);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "linuxvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "11:22:33:44:55:66") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\"") != null);
}

test "formatPingMCP: missing mac field" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatPingMCP(alloc, "testvm", "{}");
    defer alloc.free(result);

    // Missing mac should show "?"
    try std.testing.expect(std.mem.indexOf(u8, result, "MAC=?") != null);
}

test "guestDefaultDir: linux returns posix path" {
    try std.testing.expectEqualStrings("/opt/utmm", guestDefaultDir("linuxvm"));
}

test "guestDefaultDir: macos returns posix path" {
    try std.testing.expectEqualStrings("/opt/utmm", guestDefaultDir("macvm"));
}

test "guestDefaultDir: windows returns windows path" {
    try std.testing.expectEqualStrings("C:\\opt\\utmm", guestDefaultDir("windowsvm"));
    try std.testing.expectEqualStrings("C:\\opt\\utmm", guestDefaultDir("winx64"));
}

test "SERVER_INFO contains required fields" {
    try std.testing.expect(std.mem.indexOf(u8, SERVER_INFO, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, SERVER_INFO, "utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, SERVER_INFO, "capabilities") != null);
}

test "TOOLS_JSON lists all 6 tools" {
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"download\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TOOLS_JSON, "\"name\":\"sshpass\"") != null);
}

// ═══════════════════════════════════════════════════════════════════════════
// runWithPipe integration tests — full MCP protocol via pipe simulation
// ═══════════════════════════════════════════════════════════════════════════

/// Run a sequence of JSON-RPC requests through runWithPipe and return the output.
fn runMcpTest(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Reader.fixed accepts []const u8 — input is read-only
    var reader = std.Io.Reader.fixed(input);

    var out_buf: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);

    try runWithPipe(io, gpa, 2121, &reader, &writer);
    return gpa.dupe(u8, writer.buffered());
}

test "runWithPipe: initialize → ping → tools/list → notifications/initialized" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const requests =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
        \\
    ;
    const output = try runMcpTest(alloc, requests);
    defer alloc.free(output);

    // Each response should be valid JSON on its own line
    var lines = std.mem.splitScalar(u8, output, '\n');
    const line1 = lines.next().?; // initialize
    const line2 = lines.next().?; // ping
    const line3 = lines.next().?; // tools/list (notification between ping & tools/list skipped — no id)
    try std.testing.expect(lines.rest().len == 0);

    // Line 1: initialize response — contains serverInfo and version
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "serverInfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "utmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"error\"") == null);

    // Line 2: ping response — empty result
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"result\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"error\"") == null);

    // Line 3: tools/list response
    // (notifications/initialized between ping and tools/list is a no-id
    // notification → processRequest returns "" → skipped by runWithPipe)
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\":\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\":\"upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\":\"download\"") != null);

    // Verify the tools/list response is in MCP list_tools format
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line3, "inputSchema") != null);
}

test "runWithPipe: notification skipped (no output)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pure notification — no id field
    const output = try runMcpTest(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer alloc.free(output);

    // No id = notification → response is empty string → skipped
    try std.testing.expectEqualSlices(u8, "", output);
}

test "runWithPipe: unknown method error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const output = try runMcpTest(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"bad.method"}
    );
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
}

test "runWithPipe: invalid json returns parse error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const output = try runMcpTest(alloc, "this is not json\n");
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-32700") != null);
}

test "runWithPipe: multiple requests batched" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 5 ping requests, verify each gets correct id in response
    const output = try runMcpTest(alloc,
        \\{"jsonrpc":"2.0","id":10,"method":"ping"}
        \\{"jsonrpc":"2.0","id":20,"method":"ping"}
        \\{"jsonrpc":"2.0","id":30,"method":"ping"}
        \\{"jsonrpc":"2.0","id":40,"method":"ping"}
        \\{"jsonrpc":"2.0","id":50,"method":"ping"}
        \\
    );
    defer alloc.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"id\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"id\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"id\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"id\":50") != null);
    try std.testing.expect(lines.rest().len == 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tool schema validation — parse tools/list JSON and verify each tool
// ═══════════════════════════════════════════════════════════════════════════

test "tools/list response: each tool has required MCP fields" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Get tools/list response via processRequest
    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    // Parse the response as JSON
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("PARSE ERROR: {}\nResponse: {s}\n", .{ err, result });
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const result_val = root.get("result").?;
    const tools_arr = result_val.object.get("tools").?.array;

    // Must have exactly 6 tools
    try std.testing.expectEqual(@as(usize, 6), tools_arr.items.len);

    const expected_tools = [_][]const u8{ "status", "exec", "ping", "upload", "download", "sshpass" };
    for (expected_tools) |expected_name| {
        var found = false;
        for (tools_arr.items) |tool_val| {
            const tool = tool_val.object;
            const name = tool.get("name").?.string;
            if (std.mem.eql(u8, name, expected_name)) {
                found = true;
                // Every tool must have name, description, inputSchema
                try std.testing.expect(tool.get("name") != null);
                try std.testing.expect(tool.get("description") != null);
                const schema = tool.get("inputSchema").?;
                try std.testing.expect(schema.object.get("type") != null);
                try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
                try std.testing.expect(schema.object.get("properties") != null);
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "tools/list: exec requires vm and command" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        if (std.mem.eql(u8, tool.get("name").?.string, "exec")) {
            const schema = tool.get("inputSchema").?.object;
            const required = schema.get("required").?.array;
            try std.testing.expectEqual(@as(usize, 2), required.items.len);
            try std.testing.expectEqualStrings("vm", required.items[0].string);
            try std.testing.expectEqualStrings("command", required.items[1].string);

            const props = schema.get("properties").?.object;
            try std.testing.expect(props.get("vm") != null);
            try std.testing.expect(props.get("command") != null);
            break;
        }
    }
}

test "tools/list: upload requires vm and local_path" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        if (std.mem.eql(u8, tool.get("name").?.string, "upload")) {
            const schema = tool.get("inputSchema").?.object;
            const required = schema.get("required").?.array;
            try std.testing.expectEqual(@as(usize, 2), required.items.len);
            try std.testing.expectEqualStrings("vm", required.items[0].string);
            try std.testing.expectEqualStrings("local_path", required.items[1].string);
            break;
        }
    }
}

test "tools/list: download requires vm and remote_path" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        if (std.mem.eql(u8, tool.get("name").?.string, "download")) {
            const schema = tool.get("inputSchema").?.object;
            const required = schema.get("required").?.array;
            try std.testing.expectEqual(@as(usize, 2), required.items.len);
            try std.testing.expectEqualStrings("vm", required.items[0].string);
            try std.testing.expectEqualStrings("remote_path", required.items[1].string);
            break;
        }
    }
}

test "tools/list: ping requires vm only" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        if (std.mem.eql(u8, tool.get("name").?.string, "ping")) {
            const schema = tool.get("inputSchema").?.object;
            const required = schema.get("required").?.array;
            try std.testing.expectEqual(@as(usize, 1), required.items.len);
            try std.testing.expectEqualStrings("vm", required.items[0].string);
            break;
        }
    }
}

test "tools/list: status requires no arguments" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        if (std.mem.eql(u8, tool.get("name").?.string, "status")) {
            const schema = tool.get("inputSchema").?.object;
            const required = schema.get("required").?.array;
            try std.testing.expectEqual(@as(usize, 0), required.items.len);
            break;
        }
    }
}

test "tools/list: each tool inputSchema has type=object" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        const schema = tool.get("inputSchema").?.object;
        const stype = schema.get("type").?.string;
        try std.testing.expectEqualStrings("object", stype);
    }
}

test "tools/list: each tool has a non-empty description" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const result = try processRequest(alloc, threaded.io(), 2121,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    for (tools.items) |tool_val| {
        const tool = tool_val.object;
        const desc = tool.get("description").?.string;
        try std.testing.expect(desc.len > 0);
    }
}
