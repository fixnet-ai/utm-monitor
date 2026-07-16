//! HTTP client — used by Guest (version check, update download) and Host (deploy upload, exec)
//! Uses std.http.Client from the Zig standard library.
//! Zero external dependencies.

const std = @import("std");
const http = std.http;

/// GET a text resource from an HTTP server (returns heap-allocated string, caller frees)
pub fn getText(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}{s}", .{ host, port, path });
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("[http-client] GET {s} returned {d}\n", .{ path, @intFromEnum(response.head.status) });
        return error.HttpStatusNotOk;
    }

    var transfer_buf: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);
    const body = try body_reader.allocRemaining(gpa, .unlimited);
    return body;
}

/// GET /version — convenience wrapper
pub fn getVersion(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    return getText(io, gpa, host, port, "/version");
}

/// GET /update — convenience wrapper (returns the update script as text)
pub fn downloadText(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, filename: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, "/{s}", .{filename});
    defer gpa.free(path);
    return getText(io, gpa, host, port, path);
}

/// GET /bin/:filename → write to file on disk (for downloading binaries)
pub fn downloadFile(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, filename: []const u8, dest_path: []const u8) !usize {
    const path = try std.fmt.allocPrint(gpa, "/bin/{s}", .{filename});
    defer gpa.free(path);

    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}{s}", .{ host, port, path });
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("[http-client] GET {s} returned {d}\n", .{ path, @intFromEnum(response.head.status) });
        return error.HttpStatusNotOk;
    }

    // Read body and write to file
    var transfer_buf: [65536]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);

    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{ .permissions = @enumFromInt(0o755) });
    defer file.close(io);

    var wb: [4096]u8 = undefined;
    var fw = file.writer(io, &wb);
    var total: usize = 0;

    while (true) {
        const chunk = body_reader.take(transfer_buf.len) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        _ = try fw.interface.write(chunk);
        total += chunk.len;
    }
    try fw.interface.flush();

    return total;
}

/// POST /exec with JSON body → returns response text (heap-allocated, caller frees)
pub fn execRemote(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, command: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"cmd\":\"{s}\"}}", .{command});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/exec", .{ host, port });
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(body);

    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);
    const resp_body = try body_reader.allocRemaining(gpa, .unlimited);
    return resp_body;
}

/// POST /upload with multipart/form-data body → returns response text (heap-allocated, caller frees)
/// Returns the server response which includes "OK\n<bytes>\n" on success
pub fn uploadFile(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, local_path: []const u8, remote_filename: []const u8) !usize {
    // Read local file
    const file = try std.Io.Dir.cwd().openFile(io, local_path, .{});
    defer file.close(io);

    const file_len: usize = @intCast(file.length(io) catch |err| {
        std.debug.print("[http-client] Cannot get file size for {s}: {}\n", .{ local_path, err });
        return err;
    });

    const file_data = try gpa.alloc(u8, file_len);
    defer gpa.free(file_data);

    _ = try file.readPositional(io, &.{file_data}, 0);

    // Build multipart body
    const boundary = "utmBOUNDARY12345678901234567890abcdef";
    const part_header = try std.fmt.allocPrint(gpa,
        \\--{s}
        \\Content-Disposition: form-data; name="file"; filename="{s}"
        \\Content-Type: application/octet-stream
        \\
        \\
    , .{ boundary, remote_filename });
    defer gpa.free(part_header);

    const part_footer = try std.fmt.allocPrint(gpa, "\r\n--{s}--\r\n", .{boundary});
    defer gpa.free(part_footer);

    const total_body_len = part_header.len + file_data.len + part_footer.len;
    var full_body = try gpa.alloc(u8, total_body_len);
    defer gpa.free(full_body);

    @memcpy(full_body[0..part_header.len], part_header);
    @memcpy(full_body[part_header.len .. part_header.len + file_data.len], file_data);
    @memcpy(full_body[part_header.len + file_data.len ..], part_footer);

    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/upload?filename={s}", .{ host, port, remote_filename });
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "multipart/form-data; boundary=" ++ boundary },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(full_body);

    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);
    const resp_body = try body_reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(resp_body);

    // Parse "OK\n<bytes>" response
    const trimmed = std.mem.trim(u8, resp_body, " \n\r\t");
    if (std.mem.startsWith(u8, trimmed, "OK")) {
        // Extract byte count if present
        const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return file_len;
        if (nl + 1 < trimmed.len) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, trimmed[nl + 1 ..], " \n\r"), 10) catch file_len;
        }
        return file_len;
    }

    std.debug.print("[http-client] Upload response: {s}\n", .{resp_body});
    return error.UploadFailed;
}
