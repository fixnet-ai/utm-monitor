# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep communication and documentation in English**

## Project Overview

UTM Monitor (`utmm`) — remote debugging sidekick for VMs and physical machines.
Single Zig binary, dual mode (Guest default, Host with `--host`). Key capabilities:

- **Streaming exec**: IPC socket streaming with binary framing — real-time output,
  no JSON wrapping, no timeout. Exit code sent as binary trailer after command
  completes. Upload/download use IPC binary protocol with vm+path fields.
- **Self-copy install**: Binary copies itself to canonical path `/opt/utmm/utmm`
  (POSIX) / `C:\opt\utmm\utmm.exe` (Windows). `--install` = unconditional force
  overwrite. Upgrade = scp new binary + `--install`. Zero shell commands.
- **Persistent pty per connection**: `posix_openpt` (POSIX) / `CreatePipe` (Windows).
  Commands share one shell session — `cd`, `export`, shell history survive across calls.
  `MDELIM:$?\n` exit-code markers embedded in pty output.
- **MCP stdio**: AI agents control machines via `utmm --mcp` (stdio JSON-RPC).
  `vm_status` / `vm_exec` tools. Benefits from auto-ensure — if Host service is
  down, `--mcp` auto-starts it, so the recovery flow is never broken.
- **utmmd supervisor**: Lightweight supervisor daemon manages utmm lifecycle
  via shared memory (heartbeat, crash recovery with exponential backoff).
  System service managers just keep utmmd alive; all restart/upgrade logic
  lives in utmmd.
- **Single port**: 2121 for mesh networking (UDP only — LSA + KCP tunnel).
  CLI and MCP use local IPC socket — no TCP or HTTP on any port.
  MCP uses stdio — see `mcp.json.example`.
- **8 cross-compilation targets**: aarch64/x86_64/x86 × linux-musl/macos/windows.
- **Zero dependencies**: no Node.js, Python, SSH, curl at runtime.

Current configuration — four VM targets tracked:
| VM | Hostname | OS | IP | Credentials | App Path |
|----|----------|-----|----|-------------|----------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.x | Administrator / 111 | C:\opt\utmm\ |

## Architecture

### Protocol Stack

```
┌──────────────────────────────────────┐
│     Application Layer                 │
│  tunproto.zig: pty_exec, upload,     │
│  download, file_chunk, file_eof      │
│  (1-byte type + null-term + BE ints) │
├──────────────────────────────────────┤
│     Transport Layer                   │
│  tunnel.zig: send/recv (阻塞流)       │
│  kcp.zig: reliable UDP ARQ           │
├──────────────────────────────────────┤
│     Network Layer                     │
│  mesh.zig: LSA routing, KCP relay    │
├──────────────────────────────────────┤
│     Physical                          │
│  UDP :2121 (first-byte dispatch)     │
└──────────────────────────────────────┘
```

UDP port 2121 first-byte dispatch:
- `0x01` LSA (Link State Advertisement)
- `0x02` KCP_DATA (KCP tunnel data)
- `0x03` MESH_PING / `0x04` MESH_PONG (reachability probe)

### Two Run Modes (Same Binary)

- **Guest mode (default)**: `utmmd --role guest` spawns `utmm --svc` (mesh LSA
  broadcast + KCP tunnel + pty shell). utmmd monitors utmm via shared memory
  (`/utmmd-shm`), handles crash recovery (exponential backoff 2s→60s, 5 retries),
  and coordinates auto-upgrade. `--install --hostname <name>`: force install as
  system auto-start service (single `utmmd` service per machine).
  `--version`: print version. No foreground mode — service model only.
- **Host mode (`--host`)**: `utmmd --role host` spawns `utmm --host --svc`.
  Mesh networking on UDP port 2121 — guest registration via LSA broadcast,
  KCP tunnel management, /etc/hosts sync, and IPC socket for CLI/MCP communication.
  Guest auto-upgrade binary serving via KCP (`serveUpgradeFile`). All on one port.
- **MCP mode (`--mcp`)**: stdio JSON-RPC server for AI agents. Talks to Host
  daemon via IPC socket (`/var/run/utmm.sock`); auto-ensures Host on first use.

### Complete Data Flow

```
                         ┌── MCP stdio ← AI Agent (utmm --mcp → auto-ensure → IPC socket)
Guest (macvm)    ──KCP/Mesh──┐
Guest (linuxvm)  ──KCP/Mesh──┤──→ Host UDP :2121 ──┼── IPC socket (CLI/MCP)
Guest (windows)  ──KCP/Mesh──┘                      ├── KCP upgrade_req (binary serve)
                         │   (LSA discovery)         └── /etc/hosts sync
                         │
Guest ←── LSA broadcast (UDP) ──┘  (topology discovery + version detection)

Each side:
  utmmd ──shm── utmm    (utmmd spawns & monitors utmm, crash recovery, upgrade coord)
```

### How a Command Flows

```
1. CLI: utmm --exec linuxvm "ls -la"
2. Host IPC /exec → looks up guest tunnel → builds pty_exec_input frame
   with "ls -la; echo MDELIM:$?\n" appended
3. Host sends pty_exec_input via KCP tunnel (tunproto message)
4. Guest meshSessionLoop: reads pty_exec_input from KCP → writes to pty master fd
5. Shell executes → output flows through pty → ptyReadLoop sends
   pty_output frames back to Host via KCP
6. Host handleMeshGuest: appendOpOutput + scanForMarker
7. Host IPC: streams output to CLI via binary frame protocol (exec_data → exec_done with exit_code)
8. When MDELIM:N\n found: strip marker, set exit_code=N, send exec_done frame
```

### How Upload/Download Flows

```
Upload (Host→Guest):
1. CLI: utmm --upload file.txt linuxvm
2. IPC /upload: binary header (vm + dest_path + hash + file_size) followed by raw file bytes
3. handleUpload: parse header → tunproto file_chunk × N → file_eof
4. Guest receiveChunkedFile: temp file → sha256 per chunk → verify → rename
5. IPC response: binary status frame (OK or error with exit_code)

Download (Guest→Host):
1. CLI: utmm --download linuxvm file.txt ./local.txt
2. IPC /download: binary header (vm + remote_path)
3. handleDownload: tunproto download_cmd → Guest sendChunkedFile
4. Guest: read file → file_chunk × N → file_eof (sha256)
5. Host: appendOpOutput per chunk → file_eof marks completion
6. IPC response: streamed file data frames + exec_done frame with exit_code
7. CLI: write streamed bytes to local file
```

### Tunnel Protocol (tunproto.zig)

Messages over KCP tunnel. All frames: 1-byte type + type-specific payload.
Strings null-terminated, blobs 4-byte BE length prefix, integers 4-byte BE.
File transfers use chunked protocol: command → file_chunk × N → file_eof.

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| pty_spawn | 0x10 | host→guest | Trigger shell spawn |
| pty_exec_input | 0x11 | host→guest | Command for shell stdin (cmd_id + data) |
| pty_exec_output | 0x15 | guest→host | Shell stdout (cmd_id + data) |
| pty_exec_done | 0x16 | guest→host | Command exit (cmd_id + exit_code) |
| download_cmd | 0x14 | host→guest | Download request (cmd_id + path) |
| upload_cmd | 0x1b | host→guest | Upload request (cmd_id + path + file_size + hash) |
| upload_result | 0x17 | guest→host | Upload result (cmd_id + exit_code) |
| file_chunk | 0x1c | bidirectional | 1200B file chunk (cmd_id + data, MSS-aligned) |
| file_eof | 0x1d | bidirectional | End of file (cmd_id + exit_code + size + hash) |
| upgrade_req | 0x19 | guest→host | Request upgrade binary (cmd_id + target) |

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

**Thread safety**: `kcp.update()` only called by `mesh.run()` thread. `tunnel.send()`
only appends to snd_queue, `tunnel.recv()` only consumes rcv_queue — neither calls
update. KCP internal queues designed as single-producer/single-consumer.
**Keepalive**: 5s idle → probe → 3 failures → dead.

### HostState — Central Shared State (state.zig)

All handlers share one `HostState` instance, mutex-protected:
- `guests`: ArrayList of `GuestEntry` (hostname, IP, target, MAC, version, shell)
- `guest_tunnels`: StringHashMap of per-guest `*Tunnel` (KCP tunnel for exec/upload/download)
- `op_states`: StringHashMap of `OpState` by cmd_id (output buffer, exit_code, done flag)
- `transfers`: StringHashMap of `TransferState` (file transfer progress tracking)
- `wake_event`: Io.Event signaled on op completion (wakes polling IPC handlers)
- `serve_dir`: binary serve directory for Guest auto-upgrade (default: `/opt/utmm`)
- `mesh`: opaque pointer to `*mesh.Mesh` instance

### Self-Copy Install Model

**Canonical paths**: `/opt/utmm/utmm` (POSIX), `C:\opt\utmm\utmm.exe` (Windows)

```
forceInstall():
  1. stop  → stop existing service (ignore errors)
  1.5. wait → wait up to 5s for old processes to exit (prevents "Text file busy")
  2. kill  → kill leftover processes (PID-aware, skips self)
  3. copy  → self-copy to canonical path (tmp + rename, EXDEV → copy+delete fallback)
  3.5. copy-platform → Host mode only: copy cross-platform binaries to serve-dir
  4. install → overwrite system service config (best-effort bootstrap on macOS)
  5. start → start service (full retry + fallback chain on macOS: kickstart → bootstrap × 3 → startDirect)

ensure():
  service running → skip
  service not running → forceInstall()
```

**Service names** (single utmmd service per machine, role via `--role guest|host`):

| Platform | Service Name | Notes |
|----------|-------------|-------|
| macOS | `com.utmmd` | Legacy per-role names (`com.utmm.guest`/`com.utmm.host`) auto-cleaned |
| Linux | `utmmd` | Legacy per-role names (`utmm-guest`/`utmm-host`) auto-cleaned |
| Windows | `UTM-MonitorD` | Legacy per-role names (`UTM-Monitor-Guest`/`UTM-Monitor-Host`) auto-cleaned |

**utmmd crash recovery**: utmmd handles all retry logic internally — `MAX_FAILURE_COUNT=5`,
exponential backoff 2s→4s→8s→16s→32s→60s(max). After 5 consecutive failures, utmmd exits.
System service managers are configured to restart utmmd on exit (macOS `RunAtLoad`,
Linux `Restart=on-failure`, Windows `start=auto`).
**All paths require root** (except `--version` and `--help`). No privilege elevation code.
**Fast-fail**: errors print function name + system error code + message, then exit(1).

**Upgrade (manual)**: scp new binary to VM + `sudo ./utmm-new --install`. forceInstall handles
stop→kill→copy→install→start.

**Upgrade (automatic, v0.12.0+)**: Guest-initiated atomic operation:
1. Guest detects Host version mismatch via mesh LSA
2. Guest exits command loop, signals upgrade intent to utmmd via shared memory
3. Guest sends `upgrade_req` (0x19) via KCP tunnel
4. Host responds with `file_chunk × N + file_eof` (binary download)
5. Guest saves to temp dir, `chmod +x`, signals utmmd to restart with new binary
6. utmmd stops old utmm, replaces binary, spawns new utmm — zero-downtime handoff
Host never pushes upgrades — the Guest is fully self-upgrading.

### Key Design Decisions

- Single binary, dual mode — reduced maintenance
- **Mesh + KCP tunnel** replaces WebSocket (v0.11.0) — LSA for topology discovery,
  KCP for reliable ordered delivery. WebSocket and KCP were both reliable bidirectional
  streams (functional overlap); WebSocket 64KB frame limit blocked large file uploads;
  wsproto.zig + wsclient.zig ~1000 lines of maintenance burden; TCP+UDP dual
  connection increased network complexity.
- **Self-copy install model** (v0.12.0) — replaces utmm-old 10+ step KCP download
  upgrade (fork→mesh→connect→download→verify→replace→restart) with 4 steps
  (stop→kill→copy→start). Network-independent. No bat scripts for Windows.
- **Guest-initiated auto-upgrade** (v0.12.0) — Guest detects version mismatch via
  LSA, downloads new binary via KCP tunnel (`upgrade_req` → `file_chunk` × N →
  `file_eof`), saves to temp, signals utmmd via shared memory to restart with new
  binary. utmmd handles the atomic stop→replace→spawn handoff. Host never pushes
  upgrades — fully atomic on Guest side. Upgrade check runs in both the outer
  mesh session loop and the inner command loop to ensure idle Guests detect the
  signal promptly.
- Single port 2121 for mesh UDP (LSA + KCP tunnel)
- **Persistent pty per mesh session**: POSIX `posix_openpt` + fork + setsid + execve,
  Windows `CreatePipe` + `CreateProcessW("cmd.exe /k chcp 65001 ...")` + `SetConsoleOutputCP(65001)` — UTF-8 forced
- **MDELIM markers**: `; echo MDELIM:$?\n` appended to each command. Host-side
  `scanForMarker` uses `lastIndexOf` — handles echoed command text on macOS/BSD
  (where pty master doesn't support tcsetattr ECHO disable)
- Connection = Shell Session: mesh disconnect → pty killed → guest reconnects
  with fresh shell
- **Chunked file transfer**: upload/download use `cmd → file_chunk × N → file_eof`
  protocol instead of blob-in-message. 1200B MSS-aligned chunks (one per KCP segment),
  incremental SHA256, 256KB fixed buffer. Supports >1GB files with constant memory.
- **LSA version broadcast**: Host broadcasts version in LSA every 2s. Guest compares
  against `protocol.VERSION`, sets `upgrade.needed` on mismatch, triggering
  Guest-initiated auto-upgrade (see above).
  The upgrade check runs both between command sessions and inside the command loop
  (v0.12.0+), ensuring idle Guests detect the signal promptly.
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)
- **No auto-uninstall on version mismatch** (v0.12.1+) — `verifyServeDirBinaries`
  only warns when platform binaries don't match the Host version. Auto-uninstalling
  (v0.12.0 behavior) leaves the machine unreachable with zero recovery path — far
  worse than degraded Guest auto-upgrade (which is self-limiting anyway). Host
  continues serving exec/upload/download commands. Guest auto-upgrade is temporarily
  unavailable until matching platform binaries are provided.

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
utmm --hostname myvm --port 2121    # Ensure Guest service (auto-installs utmmd if needed)
utmm --svc                           # Daemon mode (internal, spawned by utmmd supervisor)
utmm --host-ip IP                    # Override Host IP (default: auto-detect via gateway)
utmm --log-file PATH                 # Log file path
utmm --version                       # Print version and exit (no root needed)
utmm --install --hostname myvm       # Force install utmmd as system service
utmm --uninstall                     # Remove system service and binary
```

### Host Runtime
```bash
sudo utmm --host                     # Ensure Host service (auto-installs utmmd if needed)
utmm --host --port 2122              # Custom mesh port
utmm --host --serve-dir PATH         # Binary serve directory for Guest upgrade (default: exe dir)
utmm --host --hosts-file PATH        # hosts file path (default /etc/hosts)
utmm --host --marker TAG             # hosts marker comment text
utmm --host --config PATH            # Config file path
utmm --host --log-file PATH          # Log file path
utmm --host --install                # Force install utmmd as system service (Host mode)
utmm --host --uninstall              # Remove system service
utmm --host --save-config            # Save current parameters to config file

# Management Commands (auto-start Host if not running)
utmm --status                        # All guest status
utmm --exec linuxvm "uname -a"       # Remote exec (pty, env/cd persist)
utmm --upload file.txt linuxvm       # Upload file
utmm --download linuxvm f.txt ./f.txt  # Download file
utmm --gen-init linux                # Generate auto-start script (linux/macos/windows)
utmm --version                       # Print version and exit
```

> Management commands (`--status`/`--exec`/`--upload`/`--download`) connect to
> the Host daemon via IPC socket (`/var/run/utmm.sock`). If the Host service is not
> running, they auto-start it via `svc.ensure(.host)` before executing.
> `utmm --host` also ensures the service and exits. `--host` combined with
> a management command ensures once then executes. `--gen-init` and `--save-config`
> do not require the Host.

## Release Process

### Prerequisites
- `gh` CLI authenticated (`gh auth status`)
- Zig 0.16.0 in PATH
- Clean working tree (no uncommitted changes)

### Step 1: Determine version
Read `src/ver.txt` for the current version. Ask the user what the next version
should be (suggest patch bump, e.g. `0.11.10` → `0.11.11`).
If already bumped and not yet tagged, use that.

### Step 2: Bump version (if needed)
Update one file:
- `src/ver.txt`: change version number (e.g. `0.11.18` → `0.11.19`)

`build.zig.zon` version is permanently `0.0.0` (never changes). Runtime version
comes from `src/ver.txt` via `@embedFile` at compile time — single source of truth.
Install scripts (`install.sh`/`install.bat`) also read `ver.txt` at runtime.

### Step 3: Commit & tag
```bash
git add -A
git commit -m "vX.Y.Z: <brief summary>"
git tag -a vX.Y.Z -m "vX.Y.Z: <description>"
git push origin main --tags
```

### Step 4: Build, zip & publish
```bash
./release.sh vX.Y.Z "Release notes (markdown)"
```
This runs tests, cross-compiles 8 targets, creates `utmm.zip`, and calls
`gh release create` to publish the GitHub release — all in one shot.

Cross-compilation targets:

| # | Target | Output Binary |
|---|--------|---------------|
| 1 | `x86_64-windows` | `utmm-x86_64-windows.exe` |
| 2 | `aarch64-windows` | `utmm-aarch64-windows.exe` |
| 3 | `x86-windows-gnu` | `utmm-x86-windows.exe` |
| 4 | `x86_64-macos` | `utmm-x86_64-macos` |
| 5 | `aarch64-macos` | `utmm-aarch64-macos` |
| 6 | `x86-linux-musl` | `utmm-x86-linux` |
| 7 | `x86_64-linux-musl` | `utmm-x86_64-linux` |
| 8 | `aarch64-linux-musl` | `utmm-aarch64-linux` |

> `x86-windows` (32-bit) uses `x86-windows-gnu` target triple to work around
> a MinGW linker warning (`_system@4`) that Zig promotes to an error.

### Step 5: Verify
Open the release URL printed by the script and confirm:
- `utmm.zip` is attached
- Release notes are correct
- Tag points to the right commit

### Post-release
After release, the Host's serve-dir auto-serves new binaries. Guests detect
version mismatch via LSA broadcast and trigger Guest-initiated auto-upgrade
(v0.12.0+): download new binary via KCP tunnel → signal utmmd via shared memory
→ utmmd performs atomic stop→replace→spawn handoff.
Host never pushes upgrades — the Guest is fully self-upgrading.

## Project File Structure

```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch
├── protocol.zig       # Protocol constants, VERSION via @embedFile("ver.txt"), deployment filename mapping
├── tunproto.zig       # Tunnel protocol over KCP: 10+ msg types, build/parse, chunked file transfer
├── kcp.zig            # KCP reliable ARQ protocol (matches C reference skywind3000/kcp)
├── mesh.zig           # LSA mesh networking: UDP broadcast, KCP session mgmt, relay
├── tunnel.zig         # TCP-like stream wrapper over KCP sessions (send/recv/flush)
├── state.zig          # Host shared state: guest table, tunnels, ops, JSON helpers
├── mcp.zig            # MCP stdio server: JSON-RPC stdin/stdout, IPC client to Host
├── lock.zig           # Process singleton lock (utmm.lock PID file)
├── host.zig           # Host orchestration: cmd dispatch + mesh start + IPC socket
├── broadcast.zig      # Guest core: system info, ptySpawn, ptyReadLoop, meshSessionLoop
├── svc.zig            # Unified cross-platform service management (install/start/stop/uninstall)
├── utmmd.zig          # Supervisor daemon: utmm lifecycle, crash recovery, shared memory IPC
├── shm.zig            # Shared memory protocol: utmmd↔utmm IPC, heartbeat, commands
├── hosts_file.zig     # /etc/hosts marked block read/write
├── ipc.zig            # Host IPC socket server: CLI/MCP request handling
├── config.zig         # Config persistence + file logger
└── fail.zig           # Fast-fail helpers (err, msg — noreturn)
```

> v0.12.0: 18 source files — added shm.zig, utmmd.zig, ipc.zig.
> Legacy merges: ver.zig→protocol.zig, priv.zig→main.zig, install.zig→svc.zig,
> guest.zig→broadcast.zig, host_http.zig→state.zig.

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

### Zig 0.16.0 SCM / Windows
- `std.os.windows.SERVICE_TABLE_ENTRYW` removed — declare manually in `svc.zig`
- `GetLastError()` returns `Win32Error` enum — use `@intFromEnum()`
- `std.c.strerror` removed — use `@extern`
- `rename()` signature: `(old_path, new_dir, new_path, io)` — 4 params
- `++` string concat needs comptime-known left operand

### Io API (0.16.0)
- `Io.Reader` no `.read()` — use `.stream(writer, limit)` or `.streamExact(writer, n)`
- `Io.Writer.write()` returns `usize` — discard with `_ =`
- `Stream.Writer.interface.flush()` to drain buffered data

### PTY Patterns
- POSIX: `posix_openpt` → fork → child: `setsid`, `dup2(slave→0,1,2)`,
  `execve(shell, argv, std.c.environ)` — pass `std.c.environ` NOT `{null}`
- macOS/BSD: pty master doesn't support `tcsetattr` ECHO disable.
  Use `lastIndexOf` in host-side marker scanning.
- `Io.Timeout` union: `{ none, duration: Clock.Duration, deadline: Clock.Timestamp }`
  Use `.awake` clock: `.{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } }`

### HTTP Client Patterns (GitHub version check only)

The Host daemon uses `std.http.Client` for fire-and-forget GitHub version polling.
No HTTP server — Host daemon uses IPC socket for CLI/MCP, UDP mesh for Guest-Host.

- **Custom request headers**: `request.iterateHeaders()` returns `HeaderIterator`,
  call `.next()` to get `http.Header{ .name, .value }`. Use `std.ascii.eqlIgnoreCase`
  for case-insensitive name matching.
- **Raw body read**: `request.head.content_length` + `body_reader.streamExact(&writer, content_length)`.
  Use `std.Io.Limit.limited(n)` for streaming reads.

### KCP Patterns

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

### Mesh LSA Patterns

- **LSA carries version**: Host node_info includes `version:0.11.x`. Guest's
  LSA handler compares against `protocol.VERSION`. Mismatch logged as info.
- **conv based on MAC+nonce**: KCP conversation ID includes host nonce to prevent
  stale session reuse after Host restart.
- **DeriveNodeId for local testing**: when `peer_mesh` is set, use
  `deriveNodeId(MAC, hostname)` instead of `parseNodeId(MAC)` to get unique node IDs.

### Windows Mesh Patterns

- **Blocking receive + timer thread**: Always uses `global_single_threaded.io()` with
  blocking `socket.receive()` and a dedicated timer thread. Zig 0.16.0 `receiveTimeout`
  with service Io silently fails on ARM64 Windows — UDP packets arrive but KCP
  data never reaches the application layer. The timer thread uses raw Win32 `Sleep()`
  to avoid Io dependency.
- **No receiveTimeout**: The two-tier approach (try receiveTimeout, fall back to
  blocking) was removed. The service Io may succeed at `receiveTimeout` but KCP
  data is silently lost. Blocking receive on `global_single_threaded` is the only
  reliable approach.

### Chunked File Transfer Patterns

- **1200B MSS-aligned chunks**: each `file_chunk` fits in exactly one KCP segment
  (frg=0 in message mode, no KCP-layer fragmentation). `peekSize()` returns
  immediately; each `recv()` returns exactly one message.
- **Incremental SHA256**: `Sha256.init({})` → `.update(chunk)` per chunk →
  `.final(&hash)`. No full-file buffering needed.
- **256KB fixed buffer**: `var rbuf: [262144]u8 = undefined` — large enough for
  any single message, small enough to stack-allocate.

### Development Principles
1. **Think before coding** — state assumptions, present trade-offs
2. **Simplicity first** — minimum code, no speculative features
3. **Precise changes** — only change what's necessary, match existing style
4. **Goal-driven** — define criteria, verify with `zig build test`
