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
- **Per-command pty**: Each exec opens a fresh pty session via `posix_openpt` (POSIX)
  / `CreatePipe` (Windows). `MDELIM:$?\n` exit-code markers embedded in pty output.
- **sshpass subcommand**: Built-in non-interactive SSH password authentication
  (`utmm sshpass -p PASS ssh user@host cmd`). 100% CLI compatible with standalone
  sshpass. POSIX uses PTY, Windows uses ConPTY (dynamic load) with pipe fallback
  for older Windows builds (< 17763). ConPTY support is reported in `--status`
  output — critical for MCP SSH operations.
- **MCP stdio**: AI agents control machines via `utmm --mcp` (stdio JSON-RPC).
  `status` / `exec` / `ping` / `upload` / `download` tools. Benefits from
  auto-ensure — if Host service is down, `--mcp` auto-starts it, so the recovery
  flow is never broken.
- **utmmd supervisor**: Lightweight supervisor daemon manages utmm lifecycle
  via shared memory (heartbeat, crash recovery with exponential backoff).
  System service managers just keep utmmd alive; all restart/upgrade logic
  lives in utmmd.
- **Single port 2121** (TCP+UDP) — UDP for LSA mesh networking, TCP for SOCKS5
  accept + utmm frame protocol + chained forwarding. Every node is a SOCKS5
  proxy endpoint, enabling third-party tools to reach any mesh node via
  `curl --socks5 <any-node>:2121 <target>`. CLI and MCP use local IPC socket.
  MCP uses stdio — see `mcp.json.example`.
- **8 cross-compilation targets**: aarch64/x86_64/x86 × linux-musl/macos/windows.
- **Zero dependencies**: no Node.js, Python, SSH, curl at runtime.

Current configuration — four VM targets tracked:
| VM | Hostname | OS | IP | Credentials | App Path |
|----|----------|-----|----|-------------|----------|
| macOS | macvm | aarch64-macos | 192.168.65.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.6 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.64.3 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.x | Administrator / 111 | C:\opt\utmm\ |

## Architecture

### Layered Model (v0.13.0+)

```
┌──────────────────────────────────────────────────────────────────┐
│  Application Layer                                                │
│  guest.zig           Guest daemon: TCP listen + SOCKS5 dispatch  │
│  host.zig            Host daemon: LSA + IPC + TCP listen + SOCKS5│
│  ipc.zig             IPC socket server (CLI/MCP entry)            │
│  mcp.zig             MCP stdio JSON-RPC                           │
│  sshpass.zig         Built-in SSH password auth (PTY/ConPTY)      │
├──────────────────────────────────────────────────────────────────┤
│  Topology Layer                                                   │
│  arp.zig             ARP MAC→IP reverse discovery                 │
│  lsa.zig             LSA broadcast + node table + /etc/hosts      │
├──────────────────────────────────────────────────────────────────┤
│  Transport Layer                                                  │
│  tcp.zig             Frame protocol + SOCKS5 + forwarding + conn  │
├──────────────────────────────────────────────────────────────────┤
│  Data Pipe Layer                                                  │
│  dpipe.zig           DuplexPipe interface + relay engine          │
│  dpipe_shell.zig     pty ↔ DuplexPipe                            │
│  dpipe_file.zig      file ↔ DuplexPipe + SHA256                  │
├──────────────────────────────────────────────────────────────────┤
│  Protocol Layer                                                   │
│  protocol.zig        All protocol definitions (constants, types, │
│                       serialization, VERSION, buildCmdWithMarker) │
├──────────────────────────────────────────────────────────────────┤
│  System Service Layer                                             │
│  svc.zig             Service mgmt (install/uninstall/start +      │
│                       Platform/genInit + InstallLock)             │
│  utmmd.zig           Supervisor daemon                            │
│  shm.zig             Shared memory (utmmd↔utmm)                   │
├──────────────────────────────────────────────────────────────────┤
│  Foundation Layer                                                 │
│  main.zig            Entry point, CLI parsing, mode dispatch      │
│  fail.zig            Fast-fail helpers                            │
│  config.zig          Service config + file logger                 │
└──────────────────────────────────────────────────────────────────┘
```

### Dependency Graph

```
               ┌─────────────┐
               │ protocol.zig │  ← zero dependencies
               └──────┬──────┘
      ┌───────────────┼───────────────┐
      ↓               ↓               ↓
 ┌─────────┐    ┌─────────┐    ┌──────────┐    ┌─────────┐
 │ fail.zig │    │ tcp.zig │    │ lsa.zig  │    │ arp.zig │
 └─────────┘    └────┬─────┘    └──────────┘    └────┬────┘
                     ↓                               │
                ┌─────────┐                          │
                │ dpipe   │ ← dpipe_shell/dpipe_file │
                └────┬────┘                          │
       ┌─────────────┼─────────────┐                │
       ↓             ↓             ↓                │
  ┌────────┐   ┌────────┐   ┌────────┐              │
  │ guest  │   │ host   │───│  ipc   │──────────────┘
  └────────┘   └───┬────┘   └───┬────┘  (ARP lookup)
                   │             │
                   └──────┬──────┘
                          ↓
                     ┌────────┐    ┌──────────┐
                     │  main  │────│ sshpass  │
                     └────────┘    └──────────┘
```

### TCP Per-Command Model (v0.13.0+)

Each exec/upload/download opens a fresh TCP connection. No persistent tunnels,
no cross-thread shared state.

```
exec:     cli → ipc → tcp.connect(vm) → send(pty_exec_input) → stream recv → close
upload:   cli → ipc → tcp.connect(vm) → send(upload_cmd) → stream file bytes → recv result → close
download: cli → ipc → tcp.connect(vm) → send(download_cmd) → stream recv file bytes → close

Guest side:
accept → recv first frame → switch type:
  exec     → dpipe.relay(conn, dpipe_shell.create())
  upload   → dpipe.relay(conn, dpipe_file.writeFile())
  download → dpipe.relay(conn, dpipe_file.readFile())
```

Per-command independent connection = no cross-thread shared state = no state.zig needed.

### UDP Port 2121 First-Byte Dispatch

- `0x01` LSA (Link State Advertisement)
- `0x03` MESH_PING / `0x04` MESH_PONG (reachability probe)

### Two Run Modes (Same Binary)

- **Guest mode (default)**: `utmmd --role guest` spawns `utmm --svc` (LSA broadcast
  + TCP listener on :2121 + dpipe shell). TCP :2121 accepts SOCKS5 connections:
  target==self+port==2121 → utmm frame protocol; target==self+port!=2121 → localhost
  relay; target!=self → chained SOCKS5 forward via node table. utmmd monitors utmm
  via shared memory (`/utmmd-shm`), handles crash recovery (exponential backoff
  2s→60s, 5 retries), and coordinates binary upgrade.
  `--install --hostname <name>`: force install as system auto-start service
  (single `utmmd` service per machine).
  `--version`: print version. No foreground mode — service model only.
- **Host mode (`--host`)**: `utmmd --role host` spawns `utmm --host --svc`.
  UDP port 2121 mesh networking — guest registration via LSA broadcast,
  /etc/hosts sync, TCP listener on :2121 (SOCKS5 accept + forwarding, same
  dispatch logic as Guest), and IPC socket for CLI/MCP communication.
  Host-initiated binary upgrade via `--upgrade <vm>` (push model). All on one port.
- **MCP mode (`--mcp`)**: stdio JSON-RPC server for AI agents. Talks to Host
  daemon via IPC socket (`/var/run/utmm.sock`); auto-ensures Host on first use.

### Complete Data Flow

```
                         ┌── MCP stdio ← AI Agent (utmm --mcp → auto-ensure → IPC socket)
Guest (macvm)    ──TCP──┐
Guest (linuxvm)  ──TCP──┤──→ Host TCP :2121 ──┼── CLI/MCP (IPC socket)
Guest (windows)  ──TCP──┘   (SOCKS5 accept +    │   /etc/hosts sync
                         │    forwarding)        │
                         │                       │
Guest ←── LSA broadcast (UDP) ──┘  (topology discovery)

Every node TCP :2121 = SOCKS5 endpoint. Guest forwards to Host; Host forwards
to Guest. Third-party tools use any node as SOCKS5 proxy to reach any other node.
```

### How a Command Flows

```
1. CLI: utmm --exec linuxvm "ls -la"
2. Host IPC /exec → tcp.connect(linuxvm) → sends pty_exec_input frame
   with "ls -la; echo MDELIM:$?\n" appended
3. Guest accept → recv pty_exec_input → dpipe_shell.create()
4. dpipe.relay(conn, shell): write command to pty → read output → send back via TCP
5. Host: stream recv pty_exec_output → forward to CLI via IPC binary frames
   (exec_data → exec_done with exit_code)
6. When MDELIM:N\n found: strip marker, set exit_code=N, send exec_done frame
```

### How Upload/Download Flows

```
Upload (Host→Guest):
1. CLI: utmm --upload file.txt linuxvm
2. IPC /upload: binary header (vm + dest_path + hash + file_size) → tcp.connect(vm)
3. Host streams: send upload_cmd + raw file bytes via TCP
4. Guest: dpipe_file.writeFile → temp file → SHA256 per write → verify → atomic rename
5. IPC response: binary status frame (OK or error with exit_code)

Download (Guest→Host):
1. CLI: utmm --download linuxvm file.txt ./local.txt
2. IPC /download: binary header (vm + remote_path) → tcp.connect(vm)
3. Host sends download_cmd → Guest: dpipe_file.readFile → streams raw bytes via TCP
4. Host: forwards streamed bytes to CLI via IPC binary frames
5. IPC response: streamed file data frames + exec_done frame with exit_code
```

### How SOCKS5 Forwarding Flows (v0.15.0+)

Every node (Guest + Host) is a peer SOCKS5 proxy endpoint. When a TCP connection
arrives on :2121, the node reads the SOCKS5 request and dispatches:

```
accept → socks5ReadRequestBuf → read target_hostname, target_port
  ├─ target==self, port==2121 → OK, utmm frame protocol (exec/upload/download)
  ├─ target==self, port!=2121 → OK, connect 127.0.0.1:target_port, bidirectional relay
  └─ target!=self → lookup hostname→IP from node table
       ├─ found → OK, SOCKS5 chain-forward to target_ip:2121, relay
       └─ not found → REJECT
```

**Chained forwarding example** — curl on Host reaches a web server on winx64
across a network boundary:

```
curl --socks5 localhost:2121 http://winx64:8080
  → Host reads SOCKS5: target=winx64, port=8080
  → Host node table: winx64 → 192.168.3.108
  → Host sends SOCKS5 to 192.168.3.108:2121 (target=winx64, port=8080)
    → winx64 Guest reads SOCKS5: target==self, port!=2121
    → winx64 connects 127.0.0.1:8080, relays bidirectionally
```

**Direct local service access:**

```
curl --socks5 localhost:2121 http://linuxvm:22
  → Host reads SOCKS5: target=linuxvm, port=22
  → Host node table: linuxvm → 192.168.64.6
  → Host sends SOCKS5 to 192.168.64.6:2121 (target=linuxvm, port=22)
    → linuxvm Guest: target==self, port!=2121 → connect 127.0.0.1:22 → relay
```

Each forwarded connection spawns a detached thread for bidirectional relay.
Threads exit when either side closes the connection.

### Wire Protocol (protocol.zig)

TCP frames: 4-byte BE length prefix (tcp.zig sendFrame/recvFrame),
then inner payload = 1-byte MsgType + type-specific payload.
Strings null-terminated, blobs 4-byte BE length prefix, integers 4-byte BE.
File transfers use raw TCP streaming (no chunking — TCP provides reliable delivery).

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| pty_spawn | 0x10 | host→guest | Trigger shell spawn |
| pty_exec_input | 0x11 | host→guest | Command for shell stdin (cmd_id + data) |
| pty_exec_output | 0x15 | guest→host | Shell stdout (cmd_id + data) |
| pty_exec_done | 0x16 | guest→host | Command exit (cmd_id + exit_code) |
| download_cmd | 0x14 | host→guest | Download request (cmd_id + path) |
| upload_cmd | 0x1b | host→guest | Upload request (cmd_id + path + file_size + hash) |
| upload_result | 0x17 | guest→host | Upload result (cmd_id + exit_code) |
| upgrade_cmd | 0x1a | host→guest | Push upgrade binary (cmd_id + target + file_size + sha256 + version) |

> `file_chunk` (0x1c) and `file_eof` (0x1d) removed in v0.13.0 — TCP reliable
> streaming eliminates the need for chunk-level verification.

### DuplexPipe Abstraction (dpipe.zig)

Vtable-based bidirectional I/O interface:

```zig
const VTable = struct {
    readFn:  *const fn (*anyopaque, []u8) anyerror!usize,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,
    closeFn: *const fn (*anyopaque) void,
};

pub const DuplexPipe = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub fn read(self, buf: []u8) !usize;
    pub fn write(self, data: []const u8) !void;
    pub fn close(self) void;
};

/// Bidirectional relay: a→b + b→a, dual-threaded, exits when either side closes.
pub fn relay(io: std.Io, a: DuplexPipe, b: DuplexPipe) !void;
```

Implementations:
- `dpipe_shell.zig`: pty master ↔ DuplexPipe (posix_openpt/fork/execve or CreatePipe/CreateProcessW)
- `dpipe_file.zig`: file read/write ↔ DuplexPipe with incremental SHA256
- `tcp.Connection.duplex()`: TCP connection ↔ DuplexPipe (adapter)

### Self-Copy Install Model

**Canonical paths**: `/opt/utmm/utmm` (POSIX), `C:\opt\utmm\utmm.exe` (Windows)

```
forceInstall():
  1. lock   → InstallLock.acquire() (flock/LockFileEx, fixed paths)
  2. stop   → stop existing service (ignore errors)
  3. wait   → wait up to 5s for old processes to exit (prevents "Text file busy")
  4. kill   → kill leftover processes (PID-aware, skips self)
  5. copy   → self-copy to canonical path (tmp + rename, EXDEV → copy+delete fallback)
  6. copy-platform → Host mode only: copy cross-platform binaries to serve-dir
  7. install → overwrite system service config (best-effort bootstrap on macOS)
  8. start  → start service (full retry + fallback chain on macOS: kickstart → bootstrap × 3 → startDirect)

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
lock→stop→kill→copy→install→start.

**Upgrade (Host-initiated push model, v0.14.0+)**: Host-controlled atomic operation:
1. CLI: `utmm --upgrade <vm>` or `utmm --deploy` (compile + copy to serve-dir)
2. Host reads target binary from serve-dir, computes SHA256
3. Host connects to Guest via SOCKS5 (tcp.hostConnect)
4. Host sends `upgrade_cmd` (0x1a) frame (target + file_size + sha256_hex) + raw binary bytes
5. Guest receives: verify SHA256 → send `upload_result` (0x17) → signal utmmd via shm
6. utmmd stops old utmm, replaces binary, spawns new utmm — zero-downtime handoff
Host pushes upgrades on demand — no autonomous Guest-side version polling.

### Key Design Decisions

- **TCP per-command model** (v0.13.0) — eliminates cross-thread shared state. Each
  exec/upload/download opens a fresh TCP connection, completes the operation, and closes.
  No persistent tunnels, no guest_tunnels HashMap, no op_states polling, no cmdchan.
  state.zig + cmdchan.zig deleted (~1750 lines removed).
- **DuplexPipe vtable abstraction** (v0.13.0) — dpipe.zig defines a common interface for
  bidirectional byte streams. Implementations: dpipe_shell (pty), dpipe_file (file I/O),
  tcp.Connection (network). dpipe.relay() bridges any two DuplexPipes — dual-threaded
  bidirectional forwarding. Zig-idiomatic, extensible, testable.
- **lsa.zig self-contained** (v0.13.0) — LSA broadcast + node table + /etc/hosts sync
  merged into one module. mesh.zig + hosts_file.zig → lsa.zig. Internal auto-sync:
  LSA rx → update node table → trigger hosts sync (range replacement, no splitScalar bug).
- **protocol.zig merged** (v0.13.0) — tunproto.zig merged into protocol.zig. Single source
  for all protocol definitions: MsgType, constants, serialization, VERSION, buildCmdWithMarker.
- **Single binary, dual mode** — reduced maintenance
- **Self-copy install model** (v0.12.0) — replaces KCP-era 10+ step download upgrade
  with 4 steps (stop→kill→copy→start). Network-independent. No bat scripts for Windows.
- **InstallLock in svc.zig** (v0.13.0) — flock (POSIX) / LockFileEx (Windows) with fixed
  paths (`/var/run/utmm-install.lock` / `C:\opt\utmm\utmm-install.lock`). Replaces
  lock.zig PID-file lock with CWD-relative path bug. OS-level advisory locks auto-release
  on process exit.
- **Per-command shell** (v0.13.0) — each exec spawns a fresh pty. No cd/export persistence
  across commands. Simpler model that matches independent TCP connections.
- Single UDP port 2121 for LSA mesh (LSA broadcast only — no KCP data)
- **MDELIM markers**: `; echo MDELIM:$?\n` appended to each command. Host-side
  `scanForMarker` uses `lastIndexOf` — handles echoed command text on macOS/BSD
  (where pty master doesn't support tcsetattr ECHO disable)
- **Chunked file transfer → direct TCP streaming** (v0.13.0): TCP provides reliable
  ordered delivery — application-level chunking and SHA256-per-chunk are unnecessary.
  dpipe_file handles incremental SHA256 for end-to-end integrity verification.
- **LSA version broadcast**: Host broadcasts version in LSA every 2s for informational
  purposes. Guest no longer takes autonomous action on version mismatch.
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)
- **Peer SOCKS5 forwarding** (v0.15.0) — every node is a SOCKS5 proxy endpoint.
  TCP :2121 accepts SOCKS5, dispatches by target hostname: self+2121 → utmm
  frame protocol, self+other-port → localhost relay, other-host → chained
  SOCKS5 forward to target node. Third-party tools (`curl`, `wget`, browsers)
  reach any mesh node through any other node without SSH tunnels or port mapping.
  No new files, no new CLI flags — all through existing tcp.zig primitives.

## Build & Run

### Build

**开发构建（Debug，快速编译，含调试符号）：**
```bash
zig build                    # Native build → zig-out/bin/utmm
```

**发布构建（ReleaseSafe — 所有部署、CI、release 必须使用）：**
```bash
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl    # → zig-out/bin/utmm-aarch64-linux
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl     # → zig-out/bin/utmm-x86_64-linux
zig build -Doptimize=ReleaseSafe -Dtarget=x86-linux-musl        # → zig-out/bin/utmm-x86-linux
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos         # → zig-out/bin/utmm-aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos          # → zig-out/bin/utmm-x86_64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows       # → zig-out/bin/utmm-aarch64-windows.exe
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows        # → zig-out/bin/utmm-x86_64-windows.exe
zig build -Doptimize=ReleaseSafe -Dtarget=x86-windows-gnu       # → zig-out/bin/utmm-x86-windows.exe
```

> **重要**：Debug 构建仅用于开发调试。部署、发布、CI 必须使用 `-Doptimize=ReleaseSafe`。
> x86_64-linux-musl Debug 模式 `.data.rel.ro` 段膨胀至 20MB+，整体 80MB+；ReleaseSafe 后降至 11MB。
>
> 32-bit x86-linux-musl builds and passes tests. 32-bit x86-windows uses
> `x86-windows-gnu` to avoid MinGW `_system@4` linker warning that Zig
> promotes to error.

### Tests
```bash
zig build test               # Unit tests (all src/*.zig)
zig build test-integration   # Integration tests (single binary, flat test files)
```

### Guest Runtime
```bash
utmm --hostname myvm --port 2121    # Ensure Guest service (auto-installs utmmd if needed)
utmm --svc                           # Daemon mode (internal, spawned by utmmd supervisor)
utmm --host-ip IP                    # Override Host IP (default: auto-detect via gateway)
utmm --mesh-port PORT                # LSA broadcast UDP port (default: 2121)
utmm --peer-mesh ADDR                # Peer mesh address for multi-host topologies
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
utmm --host --log-file PATH          # Log file path
utmm --host --install                # Force install utmmd as system service (Host mode)
utmm --host --uninstall              # Remove system service

# Management Commands (auto-start Host if not running)
utmm --status                        # All guest status
utmm --exec linuxvm "uname -a"       # Remote exec (pty)
utmm --upload file.txt linuxvm       # Upload file
utmm --download linuxvm f.txt ./f.txt  # Download file
utmm --ping linuxvm                  # Ping guest reachability
utmm --upgrade linuxvm               # Push upgrade to guest
utmm --deploy                        # Build + scp + install all guests
utmm --gen-init linux                # Generate auto-start script (linux/macos/windows)
utmm --version                       # Print version and exit
```

> Management commands (`--status`/`--exec`/`--upload`/`--download`) connect to
> the Host daemon via IPC socket (`/var/run/utmm.sock`). If the Host service is not
> running, they auto-start it via `svc.ensure(.host)` before executing.
> `utmm --host` also ensures the service and exits. `--host` combined with
> a management command ensures once then executes. `--gen-init`
> does not require the Host.

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
`--install` is a single self-contained operation — no external scripts needed.

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
After release, use `utmm --deploy` to compile and copy new binaries to the
serve-dir (`/opt/utmm/`). Then use `utmm --upgrade <vm>` to push upgrades
to individual Guest VMs via the Host-initiated push model.

## Project File Structure (19 src files + 13 test files)

```
src/
├── main.zig           Entry point, CLI parsing, mode dispatch
├── protocol.zig       All protocol definitions (types, serialization, VERSION, buildCmdWithMarker)
├── fail.zig           Fast-fail helpers (err, msg — noreturn)
├── config.zig         Service config + file logger
├── arp.zig            ARP MAC→IP reverse discovery (Linux/macOS/Windows)
├── lsa.zig            LSA broadcast + node table + /etc/hosts + hostname→IP lookup
├── tcp.zig            Frame protocol + SOCKS5 (accept/connect/forward/relay)
├── dpipe.zig          DuplexPipe interface + relay engine
├── dpipe_shell.zig    pty ↔ DuplexPipe (posix_openpt/CreatePipe)
├── dpipe_file.zig     file ↔ DuplexPipe + SHA256 verification
├── guest.zig          Guest daemon: TCP :2121 SOCKS5 dispatch + dpipe relay
├── host.zig           Host daemon: LSA + IPC + TCP :2121 SOCKS5 + command dispatch
├── ipc.zig            IPC socket server: CLI/MCP request handling
├── mcp.zig            MCP stdio server: JSON-RPC stdin/stdout, IPC client to Host
├── sshpass.zig        Built-in SSH password auth (PTY/ConPTY, 100% CLI compatible)
├── svc.zig            Service management (install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock)
├── utmmd.zig          Supervisor daemon: utmm lifecycle, crash recovery, shared memory IPC
├── shm.zig            Shared memory protocol: utmmd↔utmm IPC, heartbeat, commands
└── testlib.zig        Test re-export module (protocol + tcp + dpipe + lsa + host + svc + fail + config)

tests/
├── common.zig              Test infrastructure (TestRunner, TestCase, socket I/O, TempDir)
├── integration_test.zig    Single entry point: setup → all tests → leak check → summary
├── test_tcp_frame.zig      TCP 帧协议 + SOCKS5 集成测试 (pub fn test_tcp_frame)
├── test_lsa_routing.zig    LSA + Dijkstra 集成测试 (pub fn test_lsa_routing)
├── test_dpipe_relay.zig    DuplexPipe relay 集成测试 (pub fn test_dpipe_relay)
├── test_svc_install.zig    安装/卸载集成测试 (pub fn test_svc_install)
├── test_exec_e2e.zig       Exec 端到端集成测试 (pub fn test_exec_e2e)
├── test_upload_e2e.zig     Upload 端到端集成测试 (pub fn test_upload_e2e)
├── test_download_e2e.zig   Download 端到端集成测试 (pub fn test_download_e2e)
├── test_upgrade_e2e.zig    Upgrade 端到端集成测试 (pub fn test_upgrade_e2e)
├── test_arp.zig            ARP MAC→IP 集成测试 (pub fn test_arp)
├── test_hosts.zig          /etc/hosts 同步集成测试 (pub fn test_hosts)
└── test_ipc_e2e.zig        IPC 端到端集成测试 (pub fn test_ipc_e2e)
```

> v0.13.0: 20 → 19 files (10 deleted, 3 added in later phases: arp.zig, sshpass.zig, testlib.zig). Deleted: state.zig, broadcast.zig, mesh.zig, hosts_file.zig,
> tunproto.zig, tcpf.zig, socks4.zig, netconn.zig, cmdchan.zig, lock.zig.
> v0.13.2: Integration tests restructured from 8 separate executables to single binary with flat `pub fn test_xxx()` modules.
> Run via `zig build test-integration`.

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

### HTTP Client Patterns (not currently used)

No HTTP client code currently — checkGitHubVersion was removed in v0.14.0.

### TCP Frame Protocol Patterns

- **Frame format**: 1-byte type + 4-byte BE length + payload. Length = payload bytes only.
  `tcp.zig` handles frame serialization via `sendFrame`/`recvFrame`.
- **SOCKS5**: Built into tcp.zig. Every node accepts SOCKS5 on TCP :2121 and
  dispatches by target hostname: self+2121 → utmm frame protocol, self+other →
  localhost relay, other → chained SOCKS5 forward via node table.
  `socks5CheckAndReply` (accept side), `socks5Connect` (connect side),
  `socks5Forward` (chain-forward), `socks5LocalRelay` (localhost forward),
  `socks5Relay` (bidirectional relay). Host connects to Guests via SOCKS5
  proxy (UTM network). Destination hostname embedded in SOCKS5 request after userid.
- **Windows socket handle compatibility**: On Windows, Zig 0.16.0's `IpAddress.connect()`
  returns AFD kernel handles which are NOT compatible with Winsock2 `recv`/`send`.
  `sockAccept` returns raw Winsock2 SOCKET handles. These two handle types cannot
  be mixed in `sockRead`/`sockWrite`/`socks5Relay`. Use `sockConnectLocalhost()`
  (raw Winsock2 `ws2_socket` + `ws2_connect`) for localhost connections that need
  to relay with accept-fd handles. Same rule applies to any new outbound TCP
  connect that will be relayed with an accept-fd — use raw Winsock2 on Windows.
- **Per-command connections**: Every exec/upload/download opens `tcp.connect()`,
  completes one operation, and closes. No connection pooling or keep-alive.

### LSA Patterns

- **LSA carries version**: Host node_info includes version string for informational
  purposes (visible in `--status`). Version is no longer used for auto-upgrade triggering.
- **Self-contained closed loop**: LSA rx → update node table → trigger hosts sync
  via range replacement (not splitScalar). No external state dependency.
- **2s broadcast interval**: Host broadcasts LSA every 2 seconds. Nodes timeout
  after 6 seconds (3 missed broadcasts).

### DuplexPipe Patterns

- **Vtable not generics**: `DuplexPipe` uses a vtable pointer — no comptime generics,
  fast compilation. Each implementation (shell, file, tcp) has its own vtable instance.
- **relay() threading**: `dpipe.relay()` spawns two threads (a→b and b→a). Either side
  closing triggers the other to close. Uses `std.Io.Event` for coordination.
- **guest.zig uses individual read/write, not relay()**: The guest command handler uses
  manual read/write loops with `scanForMarker` for protocol-aware processing — the
  relay() engine is used by higher-level orchestration.

### File Transfer Patterns (TCP Streaming)

- **Direct TCP streaming**: File data flows directly over TCP without chunking —
  TCP provides reliable ordered delivery, eliminating the need for application-level
  chunk/fragment management (file_chunk/file_eof removed in v0.13.0).
- **Incremental SHA256 in dpipe_file**: `Sha256.init({})` → `.update(data)` per write →
  `.final(&hash)` at close. Hash verified against expected value before atomic rename.
  No full-file buffering needed.
- **Atomic write**: dpipe_file.writeFile writes to temp file (`.utmm-<random>`), verifies
  SHA256, then `rename(temp, dest)`. Hash mismatch → temp deleted, dest not created.
- **256KB stack buffer**: `var rbuf: [262144]u8 = undefined` — large enough for
  any single frame, small enough to stack-allocate.

### Development Principles
1. **Think before coding** — state assumptions, present trade-offs
2. **Simplicity first** — minimum code, no speculative features
3. **Precise changes** — only change what's necessary, match existing style
4. **Goal-driven** — define criteria, verify with `zig build test`

### Deployment Gating Rule
**Code changes must pass integration tests before deployment to real devices.**
- `zig build test` and `zig build test-integration` must both pass (all scenarios, 0 failures)
- This catches protocol regressions (double MDELIM, frame format mismatches, etc.)
  before they reach physical VMs where debugging is slow and recovery difficult
- No exceptions for "trivial" changes — protocol bugs often come from one-line edits
