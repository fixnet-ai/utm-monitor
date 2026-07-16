//! Host HTTP file server — serves VERSION, /update scripts, and /bin/:filename
//! to Guest VMs. Replaces the old FTP server. Read-only, no upload/exec routes.
//! Uses std.http.Server from the Zig standard library. Thread-per-connection.

const std = @import("std");
const http = std.http;
const protocol = @import("protocol.zig");

const Md5 = std.crypto.hash.Md5;

/// Compute MD5 hex digest of a file. Returns hex string (caller owns).
fn computeFileMd5Hex(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const file_len = file.length(io) catch 0;

    var md5 = Md5.init(.{});
    var fbuf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_len) {
        const to_read = @min(fbuf.len, file_len - offset);
        const n = file.readPositional(io, &.{fbuf[0..to_read]}, offset) catch break;
        if (n == 0) break;
        md5.update(fbuf[0..n]);
        offset += n;
    }

    var hash: [Md5.digest_length]u8 = undefined;
    md5.final(&hash);
    const hex_bytes = std.fmt.bytesToHex(&hash, .lower);
    return gpa.dupe(u8, &hex_bytes);
}

/// Resolve a filename relative to base_dir, rejecting path traversal attempts.
/// `filename` may contain `/` for subdirectories (e.g., "subdir/file.txt").
/// Rejects: "..", ".", empty components, leading "/" or "\".
/// Returns: allocated full path like "/opt/utmm/subdir/file.txt" (caller owns).
fn resolveSafePath(gpa: std.mem.Allocator, base_dir: []const u8, filename: []const u8) ![]const u8 {
    if (filename.len == 0) return error.InvalidPath;

    // Reject absolute paths
    if (filename[0] == '/' or filename[0] == '\\') return error.InvalidPath;

    // Split by / or \ — reject traversal components
    var it = std.mem.tokenizeAny(u8, filename, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
        if (std.mem.eql(u8, component, ".")) return error.InvalidPath;
    }

    // Build full path: base_dir/filename
    // Strip trailing slash from base_dir for clean join
    const base = if (base_dir[base_dir.len - 1] == '/') base_dir[0 .. base_dir.len - 1] else base_dir;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, filename });
}

/// Configuration for the Host HTTP file server
pub const Config = struct {
    port: u16 = protocol.DEFAULT_HTTP_PORT,
    serve_dir: []const u8,
    host_ip: ?[]const u8 = null, // For /update script generation
};

/// Start the HTTP server — runs in a loop, never returns
pub fn startServer(io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", config.port);
    var listener = try addr.listen(io, .{});
    defer listener.close(io);

    std.debug.print("[host-http] Serving files from {s}/ on port {d}\n", .{ config.serve_dir, config.port });

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.debug.print("[host-http] Accept error: {}\n", .{err});
            continue;
        };

        // Spawn thread per connection
        const handle_thread = std.Thread.spawn(.{}, handleClient, .{ io, gpa, stream, config }) catch {
            std.debug.print("[host-http] Failed to spawn thread\n", .{});
            stream.close(io);
            continue;
        };
        handle_thread.detach();
    }
}

fn handleClient(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, config: Config) void {
    defer stream.close(io);

    var read_buf: [65536]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var server = http.Server.init(&reader.interface, &writer.interface);

    // Keep-alive loop
    while (true) {
        var request = server.receiveHead() catch |err| {
            if (err != error.HttpHeadersExceededSizeLimit) {
                // Client disconnected or invalid request
            }
            return;
        };

        dispatch(&request, io, gpa, config) catch |err| {
            std.debug.print("[host-http] Error handling request: {}\n", .{err});
        };

        if (!request.head.keep_alive) return;
    }
}

fn dispatch(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    const raw_path = request.head.target;
    // Strip query string for routing (e.g., "/update?name=foo" → "/update")
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |qpos|
        raw_path[0..qpos]
    else
        raw_path;

    // GET /version
    if (request.head.method == .GET and std.mem.eql(u8, path, "/version")) {
        return handleVersion(request, io, gpa, config);
    }

    // GET /update
    if (request.head.method == .GET and std.mem.eql(u8, path, "/update")) {
        return handleUpdate(request, io, gpa, config);
    }

    // GET /bin/:filename
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/bin/")) {
        const filename = path["/bin/".len..];
        if (filename.len == 0) {
            try request.respond("Not Found\n", .{ .status = .not_found });
            return;
        }
        return handleBinDownload(request, io, gpa, config, filename);
    }

    // 404 for everything else
    try request.respond("Not Found\n", .{ .status = .not_found });
}

/// GET /version — return the VERSION file content
fn handleVersion(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    // Build path: serve_dir/VERSION
    var path_buf: [512]u8 = undefined;
    const ver_path = try std.fmt.bufPrint(&path_buf, "{s}/VERSION", .{config.serve_dir});

    const file = std.Io.Dir.cwd().openFile(io, ver_path, .{}) catch {
        try request.respond("utmm v" ++ protocol.VERSION ++ "\n", .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer file.close(io);

    const file_len = file.length(io) catch 0;
    const file_data = try gpa.alloc(u8, @intCast(file_len));
    defer gpa.free(file_data);
    _ = file.readPositional(io, &.{file_data}, 0) catch {};

    try request.respond(file_data, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

/// GET /update — return the bootstrap shell script
/// Query params:
///   ?name=HOSTNAME — set the Guest hostname (e.g., curl .../update?name=linuxvm | sh)
fn handleUpdate(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    _ = io;

    // Determine Host IP: parse the Host header from the raw request buffer
    // (the IP the Guest actually used to reach us). This ensures the download
    // URL is reachable even when the Guest is on a bridge network with a
    // different subnet than the Host's physical NIC.
    var host_ip_buf: [64]u8 = undefined;
    var host_ip: []const u8 = config.host_ip orelse "127.0.0.1";
    {
        // Parse "Host: <value>" from the raw head buffer (case-insensitive search)
        const buf = request.head_buffer;
        const host_start = std.mem.indexOf(u8, buf, "Host:") orelse
            std.mem.indexOf(u8, buf, "host:");
        if (host_start) |start| {
            const val_start = start + "host:".len; // same length as "Host:"
            const val_end = std.mem.indexOfScalarPos(u8, buf, val_start, '\r') orelse buf.len;
            var host_val = std.mem.trim(u8, buf[val_start..val_end], " \t");
            // Strip port suffix (e.g., "192.168.64.1:2121" → "192.168.64.1")
            if (std.mem.indexOfScalar(u8, host_val, ':')) |colon_pos| {
                host_val = host_val[0..colon_pos];
            }
            if (host_val.len > 0 and host_val.len <= host_ip_buf.len) {
                @memcpy(host_ip_buf[0..host_val.len], host_val);
                host_ip = host_ip_buf[0..host_val.len];
            }
        }
    }
    const port = config.port;

    // Parse ?name= query param for hostname
    var hostname_arg: []const u8 = "";
    if (std.mem.indexOfScalar(u8, request.head.target, '?')) |qpos| {
        const qs = request.head.target[qpos + 1 ..];
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "name=")) {
                hostname_arg = pair["name=".len..];
            }
        }
    }

    const script = try std.fmt.allocPrint(
        gpa,
        \\#!/bin/sh
        \\# utmm auto-update script (generated by Host HTTP server)
        \\set -e
        \\HOST="{s}"
        \\PORT="{d}"
        \\NAME="{s}"
        \\ARCH=$(uname -m)
        \\case "$ARCH" in
        \\  arm64|aarch64) ARCH="aarch64" ;;
        \\  x86_64|amd64)  ARCH="x86_64" ;;
        \\  i386|i486|i586|i686) ARCH="x86" ;;
        \\esac
        \\OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        \\case "$OS" in
        \\  darwin) OS="macos" ;;
        \\  mingw*|msys*|cygwin*) OS="windows" ;;
        \\esac
        \\BIN="utmm-$ARCH-$OS"
        \\case "$OS" in windows) BIN="$BIN.exe" ;; esac
        \\DEST_DIR="/opt/utmm"
        \\DEST="/opt/utmm/utmm"
        \\case "$OS" in
        \\  windows)
        \\    DEST_DIR="C:\\opt\\utmm"
        \\    DEST="C:\\opt\\utmm\\utmm.exe"
        \\    ;;
        \\esac
        \\echo "[update] Creating $DEST_DIR ..."
        \\mkdir -p "$DEST_DIR"
        \\echo "[update] Downloading http://$HOST:$PORT/bin/$BIN ..."
        \\if command -v curl >/dev/null 2>&1; then
        \\  curl -fsSL "http://$HOST:$PORT/bin/$BIN" -o "$DEST.new"
        \\elif command -v wget >/dev/null 2>&1; then
        \\  wget -q "http://$HOST:$PORT/bin/$BIN" -O "$DEST.new"
        \\else
        \\  echo "[update] No curl or wget, cannot download"
        \\  exit 1
        \\fi
        \\chmod +x "$DEST.new"
        \\mv "$DEST.new" "$DEST"
        \\echo "[update] Done. Restarting..."
        \\pkill utmm || true
        \\sleep 1
        \\if [ -n "$NAME" ]; then
        \\  "$DEST" --hostname "$NAME" &
        \\else
        \\  "$DEST" &
        \\fi
        \\
    , .{ host_ip, port, hostname_arg });
    defer gpa.free(script);

    try request.respond(script, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

/// GET /bin/:filename — serve a binary file from serve_dir
fn handleBinDownload(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator, config: Config, filename: []const u8) !void {
    // Security: resolve path relative to serve_dir, reject traversal
    const full_path = resolveSafePath(gpa, config.serve_dir, filename) catch {
        try request.respond("Forbidden\n", .{ .status = .forbidden });
        return;
    };
    defer gpa.free(full_path);

    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
        try request.respond("Not Found\n", .{ .status = .not_found });
        return;
    };
    defer file.close(io);

    const file_len = file.length(io) catch 0;

    // Compute MD5 for ETag (must be done before respondStreaming since headers are sent first)
    const etag_hex = computeFileMd5Hex(gpa, io, full_path) catch null;
    defer if (etag_hex) |h| gpa.free(h);

    // Build extra_headers with ETag if available
    var etag_header: http.Header = undefined;
    var extra_headers: [4]http.Header = undefined;
    var header_count: usize = 2; // content-type + cache-control
    extra_headers[0] = .{ .name = "content-type", .value = "application/octet-stream" };
    extra_headers[1] = .{ .name = "cache-control", .value = "no-cache" };
    if (etag_hex) |h| {
        etag_header = .{ .name = "etag", .value = h };
        extra_headers[2] = etag_header;
        header_count = 3;
    }

    var resp_buf: [4096]u8 = undefined;
    var response = try request.respondStreaming(&resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = extra_headers[0..header_count],
        },
    });

    var fbuf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_len) {
        const to_read = @min(fbuf.len, file_len - offset);
        const n = file.readPositional(io, &.{fbuf[0..to_read]}, offset) catch break;
        if (n == 0) break;
        _ = try response.writer.writeVec(&.{fbuf[0..n]});
        offset += n;
    }
    try response.end();
    std.debug.print("[host-http] Served {s}: {} bytes (etag={s})\n", .{ filename, offset, if (etag_hex) |h| @as([]const u8, h) else @as([]const u8, "none") });
}
