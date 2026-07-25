# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep communication and documentation in English**

## Project Overview

UTM Monitor (`utmm`) — remote debugging sidekick for VMs and physical machines.
Single Zig binary, dual mode (Guest default, Host with `--host`). Key capabilities:

- **Streaming exec**: HTTP chunked response with `x-exit-code` trailer — real-time
  output, no JSON wrapping, no timeout. Upload/download use raw binary body with
  custom headers (`x-vm`, `x-path`).
- **Auto-upgrade**: Host broadcasts version via UDP every 60s. Guest detects
  mismatch, spawns `utmm-old` to stop→download→replace→restart. Zero shell commands.
- **Persistent pty per connection**: `posix_openpt` (POSIX) / `CreatePipe` (Windows).
  Commands share one shell session — `cd`, `export`, shell history survive across calls.
  `MDELIM:$?\n` exit-code markers embedded in pty output.
- **MCP JSON-RPC**: AI agents control machines through `vm_status` / `vm_exec` tools.
- **Single port**: HTTP + WebSocket + MCP + static file serving all on 2121.
- **8 cross-compilation targets**: aarch64/x86_64/x86 × linux-musl/macos/windows.
- **Zero dependencies**: no Node.js, Python, SSH, curl at runtime.

Current configuration — four VM targets tracked:
| VM | Hostname | OS | IP | Credentials | App Path |
|----|----------|-----|----|-------------|----------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.x | Administrator / 111 | C:\opt\utmm\ |

## Architecture Design

### Two Run Modes (Same Binary)

- **Guest mode (default)**: Foreground mode — stops background service, runs in
  terminal, restarts service on exit. `--svc`: daemon mode (WebSocket + pty shell).
  `--install --user`: desktop shortcut (UTMM.command / UTMM.bat / utmm.desktop).
  `--version`: print version. `--update-url`: upgrade mode (internal, launched by `utmm-old`).
- **Host mode (`--host`)**: Unified HTTP server on port 2121 — guest registration
  (WebSocket + HTTP announce), management commands (exec/upload/download),
  MCP JSON-RPC, static file serving (/bin/), /etc/hosts sync, auto-upgrade
  binary serving, and periodic UDP version broadcast. All on one port.

### Complete Data Flow

```
                         ┌── MCP HTTP /mcp (JSON-RPC) ← AI Agent
Guest (macvm)    ──KCP/Mesh──┐
Guest (linuxvm)  ──KCP/Mesh──┤──→ Host HTTP :2121 ──┼── GET /bin/ (static files + auto-upgrade)
Guest (windows)  ──KCP/Mesh──┘                      ├── POST /exec, /upload, /download
                         │   (LSA discovery)         ├── GET /mcp (MCP JSON-RPC)
                         │                            └── /etc/hosts sync
                         │
Guest ←── LSA broadcast (UDP) ──┘  (topology discovery + version check → auto-upgrade trigger)
```

### How a Command Flows (KCP tunnel model)

```
1. CLI: utmm --exec linuxvm "ls -la"
2. Host HTTP /exec handler → looks up guest tunnel → builds pty_input frame
   with "ls -la; echo MDELIM:$?\n" appended
3. Host sends pty_input via KCP tunnel (tunproto message)
4. Guest meshSessionLoop: reads pty_input from KCP → writes to pty master fd
5. Shell executes command → output flows through pty → ptyReadLoop sends
   pty_output frames back to Host via KCP
6. Host handleMeshGuest: appendOpOutput + scanForMarker
7. Host HTTP handler: respondStreaming() sends output as it arrives (chunked)
8. When MDELIM:N\n found: strip marker, set exit_code=N, send x-exit-code trailer
```

### How Upload/Download Flows

```
Upload (Host→Guest):
1. CLI: utmm --upload file.txt linuxvm
2. HTTP POST /upload with headers: x-vm: linuxvm, x-path: file.txt
   Body: raw file bytes (application/octet-stream)
3. handleUpload: stream-read body 8KB chunks → tunproto file_chunk × N → file_eof
4. Guest receiveChunkedFile: temp file → sha256 per chunk → verify → rename
5. HTTP response: plain text "OK" or error

Download (Guest→Host):
1. CLI: utmm --download linuxvm file.txt ./local.txt
2. HTTP POST /download with headers: x-vm: linuxvm, x-path: file.txt
3. handleDownload: tunproto download_cmd → Guest sendChunkedFile
4. Guest: read file 8KB chunks → file_chunk × N → file_eof (sha256)
5. Host: appendOpOutput per chunk → file_eof marks completion
6. HTTP response: respondStreaming() chunked file bytes + x-exit-code trailer
7. CLI: body_reader.stream(file_iface) → write to local file
```

### Tunnel Protocol (tunproto.zig)

Messages over KCP tunnel. All frames: 1-byte type + type-specific payload.
Strings null-terminated, blobs 4-byte BE length prefix, integers 4-byte BE.
File transfers use chunked protocol: command → file_chunk × N → file_eof.

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| pty_spawn | 0x0c | host→guest | Trigger shell spawn |
| pty_input | 0x0d | host→guest | Command for shell stdin (cmd_id + data) |
| pty_output | 0x0e | guest→host | Shell stdout (cmd_id + data) |
| pty_signal | 0x0f | host→guest | Signal to foreground process |
| pty_resize | 0x10 | host→guest | Terminal resize (rows+cols) |
| upload_cmd | 0x1b | host→guest | Upload request (cmd_id + path + file_size + hash) |
| file_chunk | 0x1c | bidirectional | 8KB file chunk (cmd_id + data) |
| file_eof | 0x1d | bidirectional | End of file (cmd_id + exit_code + size + hash) |
| download_cmd | 0x17 | host→guest | Download request (cmd_id + path) |
| ping | 0x1e | host→guest | Keepalive probe |
| upgrade_req | 0x19 | guest→host | Request upgrade binary |

### KCP Reliable Transport (kcp.zig)

Full ARQ protocol matching C reference (skywind3000/kcp):
- Sliding window with SN-based bounds: `snd_nxt < snd_una + cwnd`
- Congestion control: slow start + congestion avoidance
- Fast retransmit: triggered on `fastack >= fastresend`
- RTO with jitter: `resendts = current + rto + rtomin` (nodelay=0)
- Window probe: `rmt_wnd == 0` triggers IKCP_ASK_SEND
- Stream mode: segment merging in snd_queue
- Rate-limited flush: `ts_flush + interval` in update()

Key constants: `IKCP_MTU_DEFAULT=1300`, `IKCP_WND_SND=32`, `IKCP_WND_RCV=128`
### HostState — Central Shared State (httpd.zig)

All handlers share one `HostState` instance, mutex-protected:
- `guests`: ArrayList of `GuestEntry` (hostname, IP, target, MAC, version, shell)
- `outgoing_frames`: StringHashMap of per-guest FIFO frame queues
- `op_states`: StringHashMap of `OpState` by cmd_id (output buffer, exit_code, done flag)
- `wake_event`: Io.Event signaled on op completion (wakes polling HTTP handlers)

### Key Design Decisions

- Single binary, dual mode — reduced maintenance
- **Mesh + KCP tunnel** replaces WebSocket — LSA (Link State Advertisement) for
  topology discovery, KCP for reliable ordered delivery over UDP
- Single port 2121 for HTTP, MCP JSON-RPC, static file serving — mesh runs on
  separate UDP port (2121 default, configurable via `--mesh-port`)
- **Persistent pty per mesh session**: POSIX `posix_openpt` + fork + setsid + execve,
  Windows `CreatePipe` + `CreateProcessW("cmd.exe /k chcp 65001 ...")` + `SetConsoleOutputCP(65001)` — UTF-8 forced
- **MDELIM markers**: `; echo MDELIM:$?\n` appended to each command. Host-side
  `scanForMarker` uses `lastIndexOf` — handles echoed command text on macOS/BSD
  (where pty master doesn't support tcsetattr ECHO disable)
- Connection = Shell Session: mesh disconnect → pty killed → guest reconnects
  with fresh shell
- **Auto-upgrade via LSA version broadcast**: Host broadcasts version in LSA every 2s.
  Guest mesh LSA handler detects mismatch, spawns `utmm-old` process which
  stops service, kills old processes, downloads new binary via KCP file_chunk
  streaming (8KB chunks, SHA256 verification), replaces, restarts.
  Zero external shell commands — `fork()+execve()` (POSIX) / `std.process.spawn` (Windows).
- **Chunked file transfer**: upload/download/upgrade use `cmd → file_chunk × N → file_eof`
  protocol instead of blob-in-message. 8KB chunks, incremental SHA256, 256KB fixed buffer.
  Supports >1GB files with constant memory.
- `std.http.Server` with `std.Thread` per-connection concurrency
- Zero external dependencies: no Node.js, Python, SSH, curl
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)

## Build & Run

### Build
```bash
zig build                    # Native build → zig-out/bin/utmm
zig build -Dtarget=aarch64-linux-musl    # → zig-out/bin/utmm-aarch64-linux
zig build -Dtarget=x86_64-linux-musl     # → zig-out/bin/utmm-x86_64-linux
zig build -Dtarget=x86-linux-musl        # → zig-out/bin/utmm-x86-linux
zig build -Dtarget=aarch64-macos         # → zig-out/bin/utmm-aarch64-macos
zig build -Dtarget=x86_64-macos          # → zig-out/bin/utmm-x86_64-macos
zig build -Dtarget=aarch64-windows       # → zig-out/bin/utmm-aarch64-windows.exe
zig build -Dtarget=x86_64-windows        # → zig-out/bin/utmm-x86_64-windows.exe
zig build -Dtarget=x86-windows-gnu       # → zig-out/bin/utmm-x86-windows.exe
```

> 32-bit x86-linux-musl builds and passes tests. 32-bit x86-windows uses
> `x86-windows-gnu` to avoid MinGW `_system@4` linker warning that Zig
> promotes to error.

### Tests
```bash
zig build test
```

### Guest Runtime
```bash
utmm                                # Foreground (stop service, run, restart on exit)
utmm --hostname myvm --port 2121   # Custom parameters
utmm --svc                          # Daemon mode (for systemd/launchd/sc)
utmm --host-ip IP                   # Override Host IP (default: auto-detect via gateway)
utmm --log-file PATH                # Log file path
utmm --version                      # Print version and exit
utmm --install                      # Install as system service (Guest: --svc + auto-start)
utmm --install --user               # Create desktop shortcut for foreground launcher
utmm --uninstall                    # Remove system service
utmm --uninstall --user             # Remove desktop shortcut
```

### Host Runtime
```bash
sudo utmm --host                    # Start HTTP server :2121 (foreground)
utmm --host --port 2122             # Custom port
utmm --host --serve-dir PATH        # Static file serve directory (default: exe dir)
utmm --host --hosts-file PATH       # hosts file path (default /etc/hosts)
utmm --host --marker TAG            # hosts marker comment text
utmm --host --config PATH           # Config file path
utmm --host --log-file PATH         # Log file path
utmm --host --install               # Install as system service (Host mode)
utmm --host --uninstall             # Remove system service
utmm --host --save-config           # Save current parameters to config file

# Management Commands (HTTP to 127.0.0.1:2121)
utmm --status                       # All guest status (UDP broadcast discovery)
utmm --exec linuxvm "uname -a"      # Remote exec (pty, env/cd persist)
utmm --upload file.txt linuxvm      # Upload file
utmm --download linuxvm f.txt ./f.txt  # Download file
utmm --gen-init linux               # Generate auto-start script (linux/macos/windows)
utmm --version                      # Print version and exit
```

## Project File Structure

```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch, Windows service
├── ver.zig            # Single source of truth for version (bump to trigger auto-upgrade)
├── protocol.zig       # Protocol constants, deployment filename mapping
├── tunproto.zig       # Tunnel protocol over KCP: 10+ msg types, build/parse, chunked file transfer
├── kcp.zig            # KCP reliable ARQ protocol (matches C reference skywind3000/kcp)
├── mesh.zig           # LSA mesh networking: UDP broadcast, KCP session mgmt, relay
├── tunnel.zig         # TCP-like stream wrapper over KCP sessions (send/recv/flush)
├── httpd.zig          # HTTP server core: accept loop + Router + HostState
├── host_http.zig      # HTTP endpoint handlers: /exec, /upload, /download, /mcp, /bin/
├── host.zig           # Host orchestration: cmd dispatch + HTTP server + mesh start
├── guest.zig          # Guest entry: system info + UpgradeSignal + meshSessionLoop start
├── broadcast.zig      # Guest core: system info, ptySpawn, ptyReadLoop, meshSessionLoop
├── upgrade.zig        # Auto-upgrade: utmm-old (stop→kill→mesh→download→replace→start)
├── hosts_file.zig     # /etc/hosts marked block read/write
├── mcp.zig            # MCP JSON-RPC: processJsonRpcWithState — reads HostState
├── install.zig        # Service install/uninstall + desktop shortcuts + --gen-init
├── agent.zig          # Foreground guest: stop service, run TTY, restart on exit
├── priv.zig           # Admin privilege elevation (macOS/Linux/Windows)
└── config.zig         # Config persistence + file logger
```

## Code of Conduct / Guidelines

Before starting any work, read (if they exist): `./CLAUDE.md`, `./README.md`,
`./zig-codegen.md`.

### Zig 0.16.0 Key Changes
- `std.posix.socket` removed → use `std.Io.net`
- `std.net` removed → use `std.Io.net.IpAddress.parse()`
- Container init: `.{}` → `.empty` / `.init`
- `usingnamespace` / `async`/`await` / `@Type` / `@cImport` — removed
- `std.process.Child.Term` fields lowercase: `.exited`, `.signal`, `.stopped`, `.unknown`
- `std.Io.Threaded.global_single_threaded` uses `Allocator.failing` — never for
  `std.process.run` in daemon contexts

### Io API (0.16.0)
- `Io.Reader` no `.read()` — use `.stream(writer, limit)` or `.streamExact(writer, n)`
- `Io.Writer.write()` returns `usize` — discard with `_ =`
- `Stream.Writer.interface.flush()` to drain buffered data

### PTY Patterns (v0.5.0)
- POSIX: `posix_openpt` → fork → child: `setsid`, `dup2(slave→0,1,2)`,
  `execve(shell, argv, std.c.environ)` — pass `std.c.environ` NOT `{null}`
- macOS/BSD: pty master doesn't support `tcsetattr` ECHO disable.
  Use `lastIndexOf` in host-side marker scanning.
- `Io.Timeout` union: `{ none, duration: Clock.Duration, deadline: Clock.Timestamp }`
  Use `.awake` clock: `.{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } }`

### HTTP Patterns (v0.8.0)

- **Custom request headers**: `request.iterateHeaders()` returns `HeaderIterator`,
  call `.next()` to get `http.Header{ .name, .value }`. Use `std.ascii.eqlIgnoreCase`
  for case-insensitive name matching.
- **Raw body read**: `request.head.content_length` + `readerExpectNone(buf)` +
  `body_reader.streamExact(&writer, content_length)`. Use `std.Io.Limit.limited(n)`
  for streaming reads.
- **Chunked streaming response**: `respondStreaming()` + `x-exit-code` trailer.
  Must call `response.writer.flush()` before `response.flush()` for chunked data
  to be sent.
- **sendBodyComplete("")** not `sendBodiless()` for empty POST body — the latter
  panics with chunked encoding (`unreachable` at Client.zig:914).

### KCP Patterns (v0.11.8)

KCP matches the C reference implementation (skywind3000/kcp). Key behaviors:

- **cwnd starts at 0**: flush() ensures `cwnd >= 1` for the send window calculation
  so the first send doesn't deadlock. Set congestion control minimum at 1 segment.
- **rmt_wnd tracked from every segment**: input() reads `seg.wnd` from every header
  and stores in `self.rmt_wnd` — used in flush() send window and window probe.
- **shrinkBuf after parseUna/parseAck**: snd_una is updated from snd_buf[0].sn
  (or snd_nxt if empty). Must be called after every UNA or ACK processing.
- **fastack aggregated per packet**: input() tracks maxack/latest_ts across all
  segments in one datagram, calls parseFastack once. Don't call per-segment.
- **flush rate-limited by interval**: update() checks `ts_flush + interval` —
  won't flush on every call. Use `tunnel.flush(ms)` for urgent data.
- **acklist format**: `ArrayList([2]u32)` stores (sn, ts) pairs. ackPush
  deduplicates by sn. flush() sends all ACKs unconditionally (no guard).
- **xmit starts at 0**: segments created in send() have xmit=0. First send in
  flush() increments to 1. This matches C behavior for RTO calculation.
- **batch encoding**: flush() uses `encodeSeg()` + `outputData()` to pack
  multiple segments into MTU-sized UDP datagrams via the `buffer` scratch space.

### Mesh LSA Patterns (v0.11.0+)

- **LSA carries version**: Host node_info includes `version:0.11.x`. Guest's
  LSA handler compares against `protocol.VERSION`. Mismatch → `upgrade_needed.store(true)`.
- **conv based on MAC+nonce**: KCP conversation ID includes host nonce to prevent
  stale session reuse after Host restart.
- **DeriveNodeId for local testing**: when `peer_mesh` is set, use
  `deriveNodeId(MAC, hostname)` instead of `parseNodeId(MAC)` to get unique node IDs.

### Chunked File Transfer Patterns (v0.11.7+)

- **8KB chunks**: each `file_chunk` fits in one KCP segment (frg=0 in message mode).
  `peekSize()` returns immediately; each `recv()` returns exactly one message.
- **Incremental SHA256**: `Sha256.init({})` → `.update(chunk)` per chunk →
  `.final(&hash)`. No full-file buffering needed.
- **256KB fixed buffer**: `var rbuf: [262144]u8 = undefined` — large enough for
  any single message, small enough to stack-allocate.

### Development Principles
1. **Think before coding** — state assumptions, present trade-offs
2. **Simplicity first** — minimum code, no speculative features
3. **Precise changes** — only change what's necessary, match existing style
4. **Goal-driven** — define criteria, verify with `zig build test`
