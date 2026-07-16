//! Guest HTTP server — handles file uploads, exec commands, health/version checks
//! Uses std.http.Server with thread-per-connection model (std.Thread.spawn)
//! Port: 2121

const std = @import("std");
const protocol = @import("protocol.zig");
const http = std.http;

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

/// Get a header value by name (case-insensitive), or null if not found.
fn getHeaderValue(req: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            return h.value;
        }
    }
    return null;
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

/// Start the Guest HTTP server accept loop (runs in a dedicated thread)
pub fn startServer(io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("[http-guest] Listening on port {d}\n", .{port});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.debug.print("[http-guest] Accept error: {}\n", .{err});
            continue;
        };

        const t = std.Thread.spawn(.{}, handleClient, .{ stream, io, gpa }) catch |err| {
            std.debug.print("[http-guest] Thread spawn error: {}\n", .{err});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// Per-connection HTTP handler (runs in its own thread)
fn handleClient(stream: std.Io.net.Stream, io: std.Io, gpa: std.mem.Allocator) void {
    defer stream.close(io);

    var read_buf: [65536]u8 = undefined; // 64KB minimum for HTTP headers
    var write_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // CRITICAL: pass pointers to interface fields, do NOT copy
    var server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => {
                std.debug.print("[http-guest] receiveHead error: {}\n", .{err});
                break;
            },
        };

        dispatch(&request, io, gpa) catch |err| {
            std.debug.print("[http-guest] dispatch error: {}\n", .{err});
            break;
        };

        if (!request.head.keep_alive) break;
    }
}

/// Route dispatch based on HTTP method + path
fn dispatch(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator) !void {
    const target = request.head.target;

    if (std.mem.startsWith(u8, target, "/health")) {
        try request.respond("OK", .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    }

    if (std.mem.startsWith(u8, target, "/version")) {
        try request.respond(protocol.VERSION, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    }

    if (std.mem.startsWith(u8, target, "/update")) {
        return handleUpdate(request, gpa);
    }

    if (std.mem.startsWith(u8, target, "/bin/")) {
        const filename = target["/bin/".len..];
        return handleBinDownload(request, io, gpa, filename);
    }

    if (std.mem.startsWith(u8, target, "/upload")) {
        return handleUpload(request, io, gpa);
    }

    if (std.mem.startsWith(u8, target, "/exec")) {
        return handleExec(request, io, gpa);
    }

    // 404
    try request.respond("Not Found\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

// ═══════════════════════════════════════════════════════════════════
// GET /update — bootstrap shell script for auto-upgrade
// ═══════════════════════════════════════════════════════════════════

fn handleUpdate(request: *http.Server.Request, gpa: std.mem.Allocator) !void {
    _ = gpa; // not used — update script is static

    // Embed the update script — same logic as old FTP /update endpoint
    // The script is generated with the Host's IP baked in by the Host
    // For Guest-side, we return a template that auto-detects the gateway
    const script = "#!" ++ "/bin/sh\n" ++
        "# Auto-update script — Guest downloads new binary from Host via HTTP\n" ++
        "set -e\n" ++
        "GW=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}' || " ++
        "  awk '$2 == \"00000000\" { ip=sprintf(\"%d.%d.%d.%d\", " ++
        "  strtonum(\"0x\"substr($3,7,2)), strtonum(\"0x\"substr($3,5,2)), " ++
        "  strtonum(\"0x\"substr($3,3,2)), strtonum(\"0x\"substr($3,1,2))); print ip }' /proc/net/route 2>/dev/null || " ++
        "  echo \"192.168.64.1\")\n" ++
        "HOST=\"http://${GW}:2121\"\n" ++
        "ARCH=$(uname -m)\n" ++
        "case \"$ARCH\" in\n" ++
        "  arm64|aarch64) ARCH=\"aarch64\" ;;\n" ++
        "  x86_64|amd64)  ARCH=\"x86_64\" ;;\n" ++
        "  i386|i486|i586|i686) ARCH=\"x86\" ;;\n" ++
        "esac\n" ++
        "OS=$(uname -s | tr '[:upper:]' '[:lower:]')\n" ++
        "case \"$OS\" in darwin) OS=\"macos\" ;; mingw*|msys*|cygwin*) OS=\"windows\" ;; esac\n" ++
        "BIN=\"utmm-${ARCH}-${OS}\"\n" ++
        "case \"$OS\" in windows) BIN=\"${BIN}.exe\" ;; esac\n" ++
        "DEST=\"/opt/utmm/utmm\"\n" ++
        "case \"$OS\" in windows) DEST=\"C:\\\\opt\\\\utmm\\\\utmm.exe\" ;; esac\n" ++
        "REMOTE_VER=$(curl -s \"${HOST}/version\" 2>/dev/null || echo \"\")\n" ++
        "if [ -x \"$DEST\" ]; then\n" ++
        "  LOCAL_VER=$(\"$DEST\" --version 2>&1 | awk '{print $2}' | tr -d 'v\\n')\n" ++
        "  if [ \"$LOCAL_VER\" = \"$REMOTE_VER\" ]; then echo \"Already latest: $LOCAL_VER\"; exit 0; fi\n" ++
        "fi\n" ++
        "echo \"Updating $LOCAL_VER → $REMOTE_VER\"\n" ++
        "TMP=$(mktemp) && curl -s \"${HOST}/bin/${BIN}\" -o \"$TMP\" && " ++
        "  mv \"$TMP\" \"$DEST\" && chmod +x \"$DEST\" && echo \"Updated to $REMOTE_VER\"\n";

    try request.respond(script, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

// ═══════════════════════════════════════════════════════════════════
// GET /bin/:filename — file download (streaming for large binaries)
// ═══════════════════════════════════════════════════════════════════

fn handleBinDownload(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator, filename: []const u8) !void {
    // Security: resolve path relative to /opt/utmm, reject traversal
    const file_path = resolveSafePath(gpa, "/opt/utmm", filename) catch {
        try request.respond("Forbidden\n", .{
            .status = .forbidden,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer gpa.free(file_path);

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch {
        try request.respond("Not Found\n", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer file.close(io);

    const file_len = file.length(io) catch 0;

    // Compute MD5 for ETag (must be done before respondStreaming since headers are sent first)
    const etag_hex = computeFileMd5Hex(gpa, io, file_path) catch null;
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

    // Use respondStreaming for large files — avoids buffering entire file in memory
    var resp_buf: [4096]u8 = undefined;
    var response = try request.respondStreaming(&resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = extra_headers[0..header_count],
        },
    });

    var fbuf: [65536]u8 = undefined;
    var total: usize = 0;
    var offset: u64 = 0;
    while (offset < file_len) {
        const to_read = @min(fbuf.len, file_len - offset);
        const n = file.readPositional(io, &.{fbuf[0..to_read]}, offset) catch break;
        if (n == 0) break;
        _ = try response.writer.writeVec(&.{fbuf[0..n]});
        total += n;
        offset += n;
    }
    try response.end();
    std.debug.print("[http-guest] Served {s}: {} bytes (etag={s})\n", .{ filename, total, if (etag_hex) |h| @as([]const u8, h) else @as([]const u8, "none") });
}

// ═══════════════════════════════════════════════════════════════════
// POST /upload — multipart file upload
// ═══════════════════════════════════════════════════════════════════

fn handleUpload(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator) !void {
    if (request.head.method != .POST) {
        try request.respond("Method Not Allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    }

    // Extract filename from query string: /upload?filename=utmm-aarch64-linux
    const target = request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const filename: []const u8 = if (query_start) |qs| blk: {
        const query = target[qs + 1 ..];
        if (std.mem.startsWith(u8, query, "filename=")) {
            break :blk query["filename=".len..];
        }
        break :blk "uploaded.bin";
    } else "uploaded.bin";

    // Security: resolve path relative to /opt/utmm, reject traversal
    const file_path = resolveSafePath(gpa, "/opt/utmm", filename) catch {
        try request.respond("Invalid filename\n", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer gpa.free(file_path);

    // Extract expected MD5 from ETag header (before reading body)
    const expected_md5 = getHeaderValue(request, "etag");

    // IMPORTANT: Both `filename` and `expected_md5` are slices into the request's
    // internal buffer (`read_buf` in handleClient). The Zig stdlib Stream.Reader's
    // writableVector() adds the entire `read_buf` as a fallback iovec, so netRead()
    // may write excess body data into it, corrupting these slices. Copy them to
    // heap NOW before allocRemaining() triggers any reads.
    const filename_owned = try gpa.dupe(u8, filename);
    defer gpa.free(filename_owned);
    const expected_md5_owned: ?[]const u8 = if (expected_md5) |e| try gpa.dupe(u8, e) else null;
    defer if (expected_md5_owned) |e| gpa.free(e);

    // Create parent directories if needed (e.g., filename = "subdir/file.txt")
    if (std.fs.path.dirname(file_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    // Read the request body
    var body_buf: [65536]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_buf);
    const body = body_reader.allocRemaining(gpa, @enumFromInt(50 * 1024 * 1024)) catch |err| {
        std.debug.print("[http-guest] Failed to read upload body: {}\n", .{err});
        try request.respond("Body too large or read error\n", .{
            .status = .payload_too_large,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer gpa.free(body);

    var written_bytes: usize = 0;

    // Parse multipart: find boundary, extract file content
    const boundary = extractBoundary(request.head.target, body);

    if (boundary == null) {
        // No multipart boundary found — treat entire body as file content
        var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = @enumFromInt(0o755) });
        defer file.close(io);

        var wb: [4096]u8 = undefined;
        var fw = file.writer(io, &wb);
        _ = try fw.interface.write(body);
        try fw.interface.flush();

        written_bytes = @intCast(file.length(io) catch body.len);
        std.debug.print("[http-guest] Uploaded {s}: {} bytes (raw body)\n", .{ filename_owned, written_bytes });
    } else {
        // Extract file portion from multipart body
        const file_data = extractMultipartFile(gpa, body, boundary.?) catch |err| {
            std.debug.print("[http-guest] Multipart parse error: {}\n", .{err});
            try request.respond("Bad multipart format\n", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
            return;
        };

        var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = @enumFromInt(0o755) });
        defer file.close(io);

        var wb: [4096]u8 = undefined;
        var fw = file.writer(io, &wb);
        _ = try fw.interface.write(file_data);
        try fw.interface.flush();

        written_bytes = @intCast(file.length(io) catch file_data.len);
        std.debug.print("[http-guest] Uploaded {s}: {} bytes\n", .{ filename_owned, written_bytes });
    }

    // Verify MD5 checksum if ETag was provided
    if (expected_md5_owned) |expected| {
        const actual = computeFileMd5Hex(gpa, io, file_path) catch null;
        if (actual) |a| {
            defer gpa.free(a);
            if (!std.mem.eql(u8, a, expected)) {
                std.debug.print("[http-guest] Upload checksum mismatch for {s}: expected={s}, got={s}\n", .{ filename_owned, expected, a });
                std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
                try request.respond("Checksum mismatch\n", .{
                    .status = .bad_request,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/plain" },
                    },
                });
                return;
            }
            std.debug.print("[http-guest] Upload checksum verified for {s}: {s}\n", .{ filename_owned, a });
        }
    }

    var resp_buf: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "OK\n{d}\n", .{written_bytes});
    try request.respond(resp, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

/// Extract boundary string from Content-Type header
fn extractBoundary(target: []const u8, body: []const u8) ?[]const u8 {
    _ = target;
    // The boundary is in the Content-Type header, but std.http.Server
    // parses headers internally. We detect it from the body itself:
    // multipart body starts with "--<boundary>\r\n"
    if (body.len < 4 or body[0] != '-' or body[1] != '-') return null;

    const crlf = std.mem.indexOf(u8, body, "\r\n") orelse return null;
    if (crlf < 4) return null; // at least "--xx\r\n"

    return body[2..crlf];
}

/// Extract file content from multipart/form-data body
fn extractMultipartFile(gpa: std.mem.Allocator, body: []const u8, boundary: []const u8) ![]const u8 {
    const full_boundary = try std.fmt.allocPrint(gpa, "--{s}", .{boundary});
    defer gpa.free(full_boundary);
    const end_boundary = try std.fmt.allocPrint(gpa, "--{s}--", .{boundary});
    defer gpa.free(end_boundary);

    // Find the first boundary → skip to after headers (\r\n\r\n)
    const first_boundary = std.mem.indexOf(u8, body, full_boundary) orelse return error.BadMultipart;
    const after_boundary = body[first_boundary + full_boundary.len ..];

    // Skip \r\n after boundary, then skip headers until \r\n\r\n
    var pos: usize = 0;
    if (after_boundary.len >= 2 and std.mem.eql(u8, after_boundary[0..2], "\r\n")) {
        pos = 2;
    }
    const headers_end = std.mem.indexOf(u8, after_boundary[pos..], "\r\n\r\n") orelse return error.BadMultipart;
    pos += headers_end + 4; // skip past \r\n\r\n

    // Find the ending boundary (search for \r\n--<boundary>, not just \r\n-- to avoid false matches in binary file content)
    const boundary_sep = try std.fmt.allocPrint(gpa, "\r\n--{s}", .{boundary});
    defer gpa.free(boundary_sep);
    const next_boundary = std.mem.indexOf(u8, after_boundary[pos..], boundary_sep) orelse return error.BadMultipart;
    const file_data = after_boundary[pos .. pos + next_boundary];

    // Handle trailing \r\n before boundary
    const trimmed = if (file_data.len >= 2 and std.mem.eql(u8, file_data[file_data.len - 2 ..], "\r\n"))
        file_data[0 .. file_data.len - 2]
    else
        file_data;

    return gpa.dupe(u8, trimmed);
}

// ═══════════════════════════════════════════════════════════════════
// POST /exec — JSON command execution
// ═══════════════════════════════════════════════════════════════════

fn handleExec(request: *http.Server.Request, io: std.Io, gpa: std.mem.Allocator) !void {
    if (request.head.method != .POST) {
        try request.respond("Method Not Allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    }

    // Read body
    var body_buf: [65536]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_buf);
    const body = body_reader.allocRemaining(gpa, @enumFromInt(1024 * 1024)) catch |err| {
        std.debug.print("[http-guest] Failed to read exec body: {}\n", .{err});
        try request.respond("ERR\nBody read error\n\n", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer gpa.free(body);

    // Parse JSON: {"cmd":"..."}
    const trimmed = std.mem.trim(u8, body, " \n\r\t");
    const cmd = extractJsonCmd(trimmed) orelse {
        try request.respond("ERR\nInvalid JSON: missing cmd field\n\n", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };

    std.debug.print("[http-guest] EXEC: {s}\n", .{cmd});

    // Execute
    const shell: []const u8 = if (@import("builtin").os.tag == .windows) "cmd.exe" else "/bin/sh";
    const shell_arg: []const u8 = if (@import("builtin").os.tag == .windows) "/c" else "-c";

    const result = std.process.run(gpa, io, .{
        .argv = &[_][]const u8{ shell, shell_arg, cmd },
    }) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "ERR\nExecution failed: {}\n\n", .{err}) catch "ERR\nExecution failed\n\n";
        try request.respond(err_msg, .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }

    if (result.term == .exited and result.term.exited == 0) {
        var resp_buf: std.ArrayList(u8) = .empty;
        defer resp_buf.deinit(gpa);
        try resp_buf.appendSlice(gpa, "OK\n");
        if (result.stdout.len > 0) {
            try resp_buf.appendSlice(gpa, result.stdout);
            if (result.stdout[result.stdout.len - 1] != '\n') {
                try resp_buf.append(gpa, '\n');
            }
        }
        try resp_buf.append(gpa, '\n');

        try request.respond(resp_buf.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    } else {
        var resp_buf: std.ArrayList(u8) = .empty;
        defer resp_buf.deinit(gpa);
        try resp_buf.appendSlice(gpa, "ERR\n");
        if (result.stderr.len > 0) {
            try resp_buf.appendSlice(gpa, result.stderr);
        }
        if (result.term != .exited) {
            try resp_buf.appendSlice(gpa, "Process terminated abnormally\n");
        }
        try resp_buf.append(gpa, '\n');

        try request.respond(resp_buf.items, .{
            .status = .ok, // Still 200 — client checks OK/ERR prefix
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    }
}

/// Extract "cmd" string from {"cmd":"..."} JSON — simple string scan
fn extractJsonCmd(json: []const u8) ?[]const u8 {
    // Find "cmd" key
    const key_pos = std.mem.indexOf(u8, json, "\"cmd\"") orelse return null;
    const after_key = json[key_pos + "\"cmd\"".len ..];

    // Find ':' after key
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const after_colon = std.mem.trim(u8, after_key[colon + 1 ..], " \t");

    // Find opening '"'
    if (after_colon.len == 0 or after_colon[0] != '"') return null;
    const after_open = after_colon[1..];

    // Find closing '"' (handle escaping simply — no escaped quotes for exec commands)
    const close = std.mem.indexOfScalar(u8, after_open, '"') orelse return null;

    return after_open[0..close];
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

test "extractJsonCmd - valid" {
    const cmd = extractJsonCmd("{\"cmd\":\"uname -a\"}");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("uname -a", cmd.?);
}

test "extractJsonCmd - with whitespace" {
    const cmd = extractJsonCmd("{ \"cmd\" : \"ls -la\" }");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("ls -la", cmd.?);
}

test "extractJsonCmd - missing" {
    const cmd = extractJsonCmd("{\"foo\":\"bar\"}");
    try std.testing.expectEqual(@as(@TypeOf(cmd), null), cmd);
}

test "extractBoundary" {
    const body = "----utmBOUNDARY\r\nContent-Disposition: form-data...";
    const b = extractBoundary("", body);
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("--utmBOUNDARY", b.?);
}

test "extractMultipartFile" {
    const allocator = std.testing.allocator;
    const body = "--utmbound\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.exe\"\r\nContent-Type: application/octet-stream\r\n\r\nbinary data here\r\n--utmbound--\r\n";
    const file_data = try extractMultipartFile(allocator, body, "utmbound");
    defer allocator.free(file_data);
    try std.testing.expectEqualStrings("binary data here", file_data);
}
