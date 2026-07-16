# HTTP Migration Plan: FTP → HTTP (v2.0.0)

**Branch**: `http-migration`
**Stack**: Pure Zig std lib — `std.http.Server` + `std.http.Client`, zero external dependencies
**Thread model**: Thread-per-connection (`std.Thread.spawn`), same as current FTP server — NO async I/O
**Compatibility**: None. Clean break. v1.x FTP code deleted entirely — code, comments, docs, MCP, skill.

---

## 1. Why HTTP + Pure std lib?

| Current FTP Problem | HTTP Solution (std.http) |
|---------------------|--------------------------|
| PASV data channel → separate TCP connection, dynamic ports | HTTP single-connection, same port |
| `readv()`/`writev()` tail data loss on TCP half-close | `Content-Length` tells exact byte count — no guessing |
| `std.posix.read` raw calls with no timeout | `std.http.Client` / `Server.Request.reader()` handle I/O properly |
| cmd_server self-kill on restart command | HTTP response completes before restart triggers |
| No upload verification | Content-Length enables exact size comparison |
| Two ports (2121 FTP + 12346 TCP) | One port (2121 HTTP) |
| Custom text protocol parsing | Standard HTTP methods + JSON / multipart |
| External library dependency risk | **Zero deps** — `std.http` is part of Zig std lib, always works |

**Issues from backlog solved**: H1, H2, H3, H4, M1, M2, M4.

---

## 2. Architecture

### Before (FTP v1.x)
```
┌─────────────────────────────────────────────┐
│ GUEST                                        │
│  UDP broadcast ──────────────┐               │
│  FTP Server (2121) ◄─ STOR/RETR/PASV        │
│  cmd_server (12346) ◄─ EXEC\n...\n          │
│  version check ──► Host FTP RETR /update     │
└─────────────────────────────────────────────┘
                        │
┌─────────────────────────────────────────────┐
│ HOST                                         │
│  UDP listener ◄──────────────┘               │
│  ftp_client ──► STOR (deploy upload)         │
│  executor ────► TCP EXEC (remote commands)    │
│  ftp_server (2121) ◄─ RETR /update (Guest)   │
│  IPC (12347) ◄─ CLI                           │
│  hosts_file sync                              │
└─────────────────────────────────────────────┘
```

### After (HTTP v2.0.0)
```
┌─────────────────────────────────────────────┐
│ GUEST                                        │
│  UDP broadcast ──────────────┐               │
│  HTTP Server (2121)           │               │
│   GET  /version               │               │
│   GET  /bin/:file             │               │
│   POST /upload  (multipart)   │               │
│   POST /exec    (JSON)        │               │
│   GET  /update  (shell script)│               │
│  version check ──► Host HTTP GET /version     │
└─────────────────────────────────────────────┘
                        │
┌─────────────────────────────────────────────┐
│ HOST                                         │
│  UDP listener ◄──────────────┘               │
│  http_client ──► POST /upload + POST /exec   │
│  HTTP Server (2121) ◄─ GET /bin/* (Guest)    │
│  IPC (12347) ◄─ CLI                           │
│  hosts_file sync                              │
└─────────────────────────────────────────────┘
```

Key simplifications:
- **3 threads** on Guest (UDP broadcast, HTTP server accept loop, version check)
- **Single port** on Guest (2121, was 2121 + 12346)
- **No data channels** — no PASV, no dynamic port negotiation
- **Real Content-Length** — upload verification becomes trivial
- **Zero external dependencies** — build.zig.zon unchanged

---

## 3. API Design

### 3.1 Guest HTTP Server (port 2121)

Built with `std.http.Server.init(&reader.interface, &writer.interface)`.
Each connection runs in its own thread (`std.Thread.spawn`).

| Method | Path | Request | Response | Replaces |
|--------|------|---------|----------|----------|
| `GET` | `/version` | — | `200 text/plain` version string | FTP RETR VERSION |
| `GET` | `/bin/:filename` | — | `200 application/octet-stream` binary | FTP RETR |
| `POST` | `/upload` | `multipart/form-data` with `file` field, `?filename=` query param | `200 text/plain` `OK\n<bytes>` | FTP STOR |
| `POST` | `/exec` | `application/json` `{"cmd":"..."}` | `200 text/plain` stdout output | TCP cmd_server |
| `GET` | `/update` | — | `200 text/plain` bootstrap shell script | FTP /update |
| `GET` | `/health` | — | `200 text/plain` `OK` | (new) |

### 3.2 Host HTTP Server (port 2121)

Same `std.http.Server` pattern, serves binaries from `serve_dir`.

| Method | Path | Request | Response | Replaces |
|--------|------|---------|----------|----------|
| `GET` | `/version` | — | `200 text/plain` version string | Host FTP RETR VERSION |
| `GET` | `/bin/:filename` | — | `200 application/octet-stream` binary | Host FTP RETR |

### 3.3 Host HTTP Client

Built with `std.http.Client{ .allocator, .io }`. Functions in `src/http_client.zig`:

- `uploadFile(io, allocator, host, port, local_path, remote_filename)` → POST /upload (multipart)
- `execRemote(io, allocator, host, port, command)` → POST /exec (JSON body)
- `getVersion(io, allocator, host, port)` → GET /version → `[]const u8`
- `downloadFile(io, allocator, host, port, filename, dest_path)` → GET /bin/:filename

### 3.4 Multipart Upload Format

Manual multipart encoding (simple boundary, no dependency needed):
```
POST /upload?filename=utm-monitor-aarch64-linux HTTP/1.1
Content-Type: multipart/form-data; boundary=----utmBOUNDARY1234567890
Content-Length: <size>

------utmBOUNDARY1234567890
Content-Disposition: form-data; name="file"; filename="utm-monitor-aarch64-linux"
Content-Type: application/octet-stream

<binary data>
------utmBOUNDARY1234567890--
```

Guest parses boundary-delimited parts via simple string scanning — no external parser.

### 3.5 Exec Format

```
POST /exec HTTP/1.1
Content-Type: application/json
Content-Length: <size>

{"cmd":"uname -a"}
```

Guest parses JSON with `std.json.parseFromSlice` → `std.json.Value` tree.

---

## 4. Key std.http API Patterns (Zig 0.16.0)

### Server (thread-per-connection)

```zig
fn handleClient(stream: std.Io.net.Stream, io: std.Io, allocator: std.mem.Allocator) !void {
    defer stream.close(io);

    var read_buf: [65536]u8 = undefined;   // 64KB minimum for HTTP headers
    var write_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // CRITICAL: pass pointers to .interface fields — do NOT copy
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => |e| return e,
        };

        // Route: request.head.method (.GET, .POST), request.head.target (path)
        // Read body: request.reader()
        // Respond:  request.respond(body, .{ .status = .ok, .extra_headers = ... })

        if (!request.head.keep_alive) break;
    }
}
```

- `server.receiveHead()` reads HTTP method, target, headers → returns `Request`
- `request.respond(body, options)` — one-shot response (headers + body in single call)
- `request.respondStreaming(options)` — returns `Response` with `.writer()` + `.end()` for large files
- `request.reader()` — reads request body (reuses read buffer, no extra alloc)
- Read buffer MUST be ≥ 64KB (standard HTTP header limit)

### Client

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();

// GET
const uri = try std.Uri.parse("http://192.168.64.5:2121/version");
var req = try client.request(.GET, uri, .{});
defer req.deinit();
try req.sendBodiless();
var redirect_buf: [1024]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);
var transfer_buf: [4096]u8 = undefined;
var body = response.reader(&transfer_buf);
const data = try body.allocRemaining(gpa, .unlimited);

// POST with body
var req = try client.request(.POST, uri, .{
    .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
    },
});
defer req.deinit();
try req.send(content_length);       // sends headers
try req.writer().writeAll(body);    // writes body
try req.finish();                   // finalizes
var response = try req.receiveHead(&redirect_buf);
```

- `client.request(method, uri, options)` — no manual connection management
- `req.sendBodiless()` → GET/HEAD
- `req.send(len)` → `req.writer().writeAll()` → `req.finish()` → POST/PUT
- `req.receiveHead(&redirect_buf)` → response status + headers

---

## 5. File Changes

| File | Action | Description |
|------|--------|-------------|
| `src/http_server.zig` | **NEW** (~300 lines) | Guest HTTP server: accept loop, route dispatch, 6 handlers |
| `src/http_client.zig` | **NEW** (~200 lines) | Host HTTP client: uploadFile, execRemote, getVersion, downloadFile |
| `src/host_http.zig` | **NEW** (~100 lines) | Host HTTP server: accept loop, GET /version, GET /bin/:file |
| `src/guest.zig` | Modify | Replace FTP+cmd_server threads with HTTP server thread |
| `src/host.zig` | Modify | Replace Host FTP server with HTTP server; deploy/exec use http_client |
| `src/deploy.zig` | Modify | Use `http_client.uploadFile` instead of `ftp_client.uploadFile` |
| `src/executor.zig` | Modify | Use `http_client.execRemote` instead of TCP EXEC |
| `src/main.zig` | Modify | Rename `--ftp-port` → `--http-port`, update help text |
| `src/protocol.zig` | Modify | Bump VERSION to `"2.0.0"`, remove FTP constants |
| `src/install.zig` | Modify | Remove cmd_server port from service files |
| `src/ftp_server.zig` | **DELETE** | Replaced by http_server.zig + host_http.zig |
| `src/ftp_client.zig` | **DELETE** | Replaced by http_client.zig |
| `src/cmd_server.zig` | **DELETE** | Absorbed into http_server.zig POST /exec |
| `src/file_locker.zig` | **DELETE** | HTTP uploads use Content-Length — no temp file locking needed |
| `build.zig.zon` | Modify | Bump version only (no new deps) |
| `README.md` | Modify | Architecture diagram, HTTP API docs, remove FTP |
| `MANUAL.md` | Modify | Remove all FTP/port references |
| `CLAUDE.md` | Modify | Architecture, protocol, port numbers |
| `findings.md` | Modify | Close FTP-related issues, note HTTP migration complete |
| `mcp.json.example` | Modify | Update command |
| `.claude/skills/utm-vm/SKILL.md` | Modify | Remove FTP references, update ports |

---

## 6. Implementation Phases

### Phase 1: HTTP Server Scaffold
- Create `src/http_server.zig` — accept loop + `handleClient` + route dispatch skeleton
- Implement `GET /health` (simplest route — validates end-to-end HTTP)
- Implement `GET /version` handler
- Wire into `guest.zig`: replace FTP server thread with HTTP server thread
- **Verify**: `zig build` compiles; `curl http://VM_IP:2121/health` returns "OK"

### Phase 2: Guest HTTP Server — Full Routes
- `GET /bin/:filename` — `request.respondStreaming()` for file download
- `POST /upload` — manual multipart boundary scan + file write
- `POST /exec` — JSON body → `std.process.run()` → return output
- `GET /update` — embedded shell script, respond as text/plain
- **Verify**: `curl` each endpoint on a test VM

### Phase 3: Host HTTP Client
- Create `src/http_client.zig`:
  - `getVersion()` → GET /version
  - `downloadFile()` → GET /bin/:file → write to disk
  - `uploadFile()` → multipart POST /upload
  - `execRemote()` → JSON POST /exec
- **Verify**: compile + test each function

### Phase 4: Host Integration
- Wire `deploy.zig` → `http_client.uploadFile()`
- Wire `executor.zig` → `http_client.execRemote()`
- Create `src/host_http.zig` — Host HTTP server
- Wire `host.zig` — replace Host FTP server with HTTP server
- Update `guest.zig` version check to use `http_client`
- **Verify**: `--host --deploy`, `--host --exec`, `--host --status`, auto-upgrade

### Phase 5: Cleanup — No Remnants
- Delete: `ftp_server.zig`, `ftp_client.zig`, `cmd_server.zig`, `file_locker.zig`
- `protocol.zig`: VERSION=`"2.0.0"`, remove FTP constants
- `main.zig`: rename `--ftp-port` → `--http-port`, update help
- `install.zig`: remove cmd_server port
- Docs: README, MANUAL, CLAUDE, findings, SKILL.md, mcp.json.example
- **Verify**: `grep -r "ftp" src/` returns zero results; `grep -r "cmd_server" src/` returns zero

### Phase 6: Cross-Compile + Deploy
- Build: aarch64-linux, aarch64-macos, aarch64-windows
- Bootstrap deploy via SSH to all 3 VMs
- Final verification: all VMs online, deploy works, exec works, auto-upgrade works

---

## 7. Risk Assessment

| Risk | Mitigation |
|------|-----------|
| `std.http.Server` 64KB header buffer | Standard HTTP limit. Our headers are minimal (< 1KB). |
| Multipart parsing edge cases | 32-char random boundary; boundary-in-data is astronomically unlikely |
| `std.http.Client` API stability | std lib is stable within 0.16.x; pin Zig version |
| Chicken-and-egg bootstrap | SSH/curl — same pattern used when FTP was broken |
| Windows `std.Thread.spawn` | Already proven in current FTP server code |
| Binary size | `std.http` in std lib already — no new dep; may shrink after deleting FTP PASV |
| JSON parsing for /exec | Only extract `"cmd"` field — `std.json.Value` tree or simple scan |

---

## 8. Deploy Strategy

**Bootstrap** (one-time): Build all 3 binaries → scp to each VM → restart → done. Same pattern already used when FTP was broken.

**Ongoing**: `--host --deploy` → cross-compile → HTTP POST /upload → Content-Length verification.

---

## 9. Success Criteria

- [x] `zig build` compiles — zero warnings
- [x] `zig build test` — all tests pass
- [x] Cross-compile: aarch64-linux, aarch64-macos, aarch64-windows — all succeed
- [x] Guest HTTP server: all 6 routes respond correctly (curl-tested)
- [x] Host HTTP client: upload, exec, version check, download all work
- [x] `--host --deploy` → binary size matches via Content-Length
- [x] `--host --exec <vm> "uname -a"` → correct output
- [x] `--host --status` → all VMs with correct versions
- [x] Auto-upgrade: Guest detects + updates via HTTP
- [x] All 3 VMs deployed and operational
- [x] Old files deleted: ftp_server.zig, ftp_client.zig, cmd_server.zig, file_locker.zig
- [x] `grep -ri "ftp\|cmd_server\|file_locker" src/` → zero results
- [x] Docs/skill/MCP all reference HTTP, not FTP

---
## Status: ✅ COMPLETE (2026-07-16)

All 6 phases implemented. All 13 success criteria met. Zero FTP/tcp_cmd/file_locker references remain in `src/`. All 58 tests pass. Cross-compilation for all 3 targets succeeds. All documentation updated (CLAUDE.md, README.md, MANUAL.md, SKILL.md, zig-codegen.md, findings.md, progress.md, task_plan.md).
