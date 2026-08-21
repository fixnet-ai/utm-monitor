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
  sshpass. POSIX uses PTY prompt injection; Windows uses Win32 OpenSSH's
  `SSH_ASKPASS` mechanism (no TTY/ConPTY dependency) — works on all Windows
  versions including Session 0 service contexts. ConPTY availability is
  reported in `--status` output for non-ssh interactive commands.
- **MCP HTTP**: AI agents control machines via HTTP POST to Host's TCP :2121
  (JSON-RPC over HTTP). `status` / `exec` / `ping` / `upload` / `download` /
  `sshpass` / `manual` tools. First-byte protocol dispatch: 0x05→SOCKS5,
  ASCII letter→HTTP MCP — single port for all protocols. `utmm --mcp` prints
  the HTTP endpoint URL and auto-ensures Host — no separate MCP process, no
  IPC bridge, no idle timeout, no 64KB buffer truncation.
- **utmmd supervisor**: Lightweight supervisor daemon manages utmm lifecycle
  via shared memory (heartbeat, crash recovery with exponential backoff).
  System service managers just keep utmmd alive; all restart/upgrade logic
  lives in utmmd.
- **Single port 2121** (TCP+UDP) — UDP for LSA mesh networking, TCP for SOCKS5
  accept + utmm frame protocol + HTTP MCP (first-byte dispatch). Host is the
  central SOCKS5 proxy; Guests route through the Host via `gateway:2121`
  (auto-synced to every Guest's `/etc/hosts`). CLI management commands use
  local IPC socket. MCP uses HTTP POST to :2121 — see `mcp.json.example`.
- **8 cross-compilation targets**: aarch64/x86_64/x86 × linux-musl/macos/windows
  (x86 32-bit Linux + Windows — macOS dropped 32-bit).
- **Zero dependencies**: no Node.js, Python, SSH, curl at runtime.

Current configuration — four VM targets tracked:
| VM | Hostname | OS | IP | Credentials | App Path |
|----|----------|-----|----|-------------|----------|
| macOS | macvm | aarch64-macos | 192.168.65.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.6 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.64.3 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## Architecture

### Layered Model (v0.13.0+)

```
┌──────────────────────────────────────────────────────────────────┐
│  Application Layer                                                │
│  guest.zig           Guest daemon: TCP listen + SOCKS5 dispatch  │
│  host.zig            Host daemon: LSA + IPC + TCP listen + SOCKS5│
│                      + first-byte dispatch (SOCKS5 / HTTP MCP)   │
│  ipc.zig             IPC socket server (CLI entry)                │
│  mcp.zig             MCP JSON-RPC processor                      │
│  mcp_handler.zig     MCP core business logic (shared by          │
│                       HTTP MCP + IPC handlers)                    │
│  mcp_http.zig        HTTP/1.1 POST parser + transport            │
│  sshpass.zig         Built-in SSH password auth (PTY/ConPTY)      │
├──────────────────────────────────────────────────────────────────┤
│  Topology Layer                                                   │
│  arp.zig             ARP MAC→IP reverse discovery                 │
│  lsa.zig             LSA broadcast + node table + /etc/hosts      │
├──────────────────────────────────────────────────────────────────┤
│  Transport / Protocol Layer                                       │
│  tcp.zig             TCP socket I/O + connection primitives       │
│  socks5.zig          SOCKS5 protocol (RFC 1928, full)             │
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
               │ protocol.zig │  ← imports tcp.zig for socket_t
               └──────┬──────┘
       ┌──────────────┼───────────────┐
       ↓              ↓               ↓
  ┌─────────┐   ┌─────────┐   ┌──────────┐   ┌─────────┐
  │ fail.zig │   │ tcp.zig │   │ lsa.zig  │   │ arp.zig │
  └─────────┘   └────┬─────┘   └──────────┘   └────┬────┘
                     ↓                              │
                ┌─────────┐                          │
                │ dpipe   │ ← dpipe_shell/dpipe_file │
                └────┬────┘                          │
       ┌─────────────┼─────────────┐                │
       ↓             ↓             ↓                │
  ┌────────┐   ┌────────┐   ┌────────┐              │
  │ guest  │   │ host   │───│  ipc   │──────────────┘
  └────────┘   └───┬────┘   └───┬────┘  (ARP lookup)
                   │             │
         ┌─────────┼──────┐      │
         ↓         ↓      ↓      ↓
    ┌─────────┐ ┌──────┐ ┌──────────────┐
    │ mcp_http│→│ mcp  │→│ mcp_handler  │
    └─────────┘ └──────┘ └──────────────┘
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

HTTP MCP side (Host only):
accept → peek first byte → ASCII letter → mcp_http.handleHttpMcp:
  read HTTP request → mcp.processRequest → mcp_handler (direct Host fn calls)
  → write HTTP response → close
```

Per-command independent connection = no cross-thread shared state = no state.zig needed.

### TCP Port 2121 First-Byte Dispatch (v0.18.0+)

- `0x05` — SOCKS5 protocol (existing Guest-Host communication)
- `'A'..'Z'` — HTTP MCP JSON-RPC (HTTP method starts with uppercase ASCII)
- Any other byte — close connection

### UDP Port 2121 First-Byte Dispatch

- `0x01` LSA (Link State Advertisement)
- `0x03` MESH_PING / `0x04` MESH_PONG (reachability probe)

### Two Run Modes (Same Binary)

- **Guest mode (default)**: `utmmd --role guest` spawns `utmm --svc` (LSA broadcast
  + TCP listener on :2121 + dpipe shell). TCP :2121 accepts SOCKS5 connections from
  Host: target==self+port==2121 → utmm frame protocol; target==self+port!=2121 →
  localhost relay. utmmd monitors utmm via shared memory (`/utmmd-shm`), handles
  crash recovery (exponential backoff 2s→60s, 5 retries), and coordinates binary
  upgrade.
  `--install --hostname <name>`: force install as system auto-start service
  (single `utmmd` service per machine).
  `--version`: print version. No foreground mode — service model only.
- **Host mode (`--host`)**: `utmmd --role host` spawns `utmm --host --svc`.
  UDP port 2121 mesh networking — guest registration via LSA broadcast,
  /etc/hosts sync, TCP listener on :2121 (SOCKS5 accept from Guests + chain-forward
  to other Guests — Host is the only relay node), and IPC socket for CLI/MCP
  communication. Host-initiated binary upgrade via `--upgrade <vm>` (push model).
  All on one port.
- **MCP mode (`--mcp`)**: Prints HTTP endpoint URL (`http://127.0.0.1:{port}/`)
  and ensures Host daemon is running. MCP is served directly by the Host daemon
  via TCP :2121 first-byte dispatch — no separate MCP process, no IPC bridge.

### Complete Data Flow

```
                         ┌── HTTP MCP ← AI Agent (POST to :2121)
Guest (macvm)    ──TCP──┐
Guest (linuxvm)  ──TCP──┤──→ Host TCP :2121 ──┼── CLI (IPC socket)
Guest (windows)  ──TCP──┘   (SOCKS5 + HTTP MCP │   /etc/hosts sync
                         │    via first-byte)   │
                         │                      │
Guest ←── LSA broadcast (UDP) ──┘  (topology discovery)

Every node TCP :2121 = SOCKS5 endpoint. Guest forwards to Host; Host forwards
to Guest. Third-party tools use any node as SOCKS5 proxy to reach any other node.
AI agents use HTTP POST to Host :2121 for MCP JSON-RPC.
```

### How a Command Flows

**CLI management commands** (via IPC socket):
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

**HTTP MCP commands** (directly in Host daemon, no IPC):
```
1. AI Agent: HTTP POST :2121 → Host peek first byte ('P' for POST)
2. mcp_http.readHttpRequestBody → extract JSON-RPC body
3. mcp.processRequest(McpContext, json) → dispatch to mcp_handler
4. mcp_handler.execOnGuest: tcp.connect(vm) → send command frame → stream recv → return result
5. mcp_http.writeHttpResponse(fd, 200, response_json) → close
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

The Host is the central SOCKS5 relay — only the Host chain-forwards between
Guests. Guests accept SOCKS5 from the Host only. Every Guest's `/etc/hosts`
maps the Host IP as `gateway`.

Host SOCKS5 dispatch on TCP :2121:

```
accept → socks5ReadRequestBuf → read target_hostname, target_port
  ├─ target==self, port==2121 → OK, utmm frame protocol (exec/upload/download)
  ├─ target==self, port!=2121 → OK, connect 127.0.0.1:target_port, bidirectional relay
  └─ target!=self → lookup hostname→IP from node table
       ├─ found → OK, SOCKS5 chain-forward to target_ip:2121, relay
       └─ not found → REJECT
```

**Chained forwarding example** — curl on Host reaches a web server on winx64:

```
curl --socks5 localhost:2121 http://winx64:8080
  → Host reads SOCKS5: target=winx64, port=8080
  → Host node table: winx64 → 192.168.3.108
  → Host sends SOCKS5 to 192.168.3.108:2121 (target=winx64, port=8080)
    → winx64 Guest reads SOCKS5: target==self, port!=2121
    → winx64 connects 127.0.0.1:8080, relays bidirectionally
```

**Guest → Guest via Host** — from a Guest, use `gateway:2121`:

```
curl --socks5 gateway:2121 http://linuxvm:22
  → Guest sends SOCKS5 to Host (gateway:2121): target=linuxvm, port=22
  → Host node table: linuxvm → 192.168.64.6
  → Host chain-forwards SOCKS5 to 192.168.64.6:2121
    → linuxvm Guest: target==self, port!=2121 → connect 127.0.0.1:22 → relay
```

Each forwarded connection spawns a detached thread for bidirectional relay.
Threads exit when either side closes the connection.

### Wire Protocol (protocol.zig)

TCP frames: 4-byte BE length prefix (protocol.zig sendFrame/recvFrame),
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
| download_result | 0x1c | guest→host | Download verify header (cmd_id + file_size + sha256_hex), sent before raw bytes |
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
pub fn relay(a: DuplexPipe, b: DuplexPipe) !void;
```

Implementations:
- `dpipe_shell.zig`: pty master ↔ DuplexPipe (posix_openpt/fork/execve or CreatePipe/CreateProcessW; Windows pipe mode does bidirectional OEM↔UTF-8 codec in readFn/writeFn — GetOEMCP() auto-matches CJK locales, session stays OEM, never chcp)
- `dpipe_file.zig`: file read/write ↔ DuplexPipe with incremental SHA256
- `tcp.duplexPipe(fd, allocator)`: TCP connection ↔ DuplexPipe (adapter)

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
  tcp.duplexPipe (network). dpipe.relay() bridges any two DuplexPipes — dual-threaded
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
- **MDELIM markers**: POSIX `; echo MDELIM:$?\n`; Windows `\r\necho MDELIM:%errorlevel%\r\n`
  — the marker MUST be on its own line: interactive cmd expands `%errorlevel%` at whole-line
  parse time, so appending it to the same line (`& echo ...`) reports the pre-execution value.
  Host-side `scanForMarker` uses `lastIndexOf` — handles echoed command text on macOS/BSD
  (where pty master doesn't support tcsetattr ECHO disable)
- **Chunked file transfer → direct TCP streaming** (v0.13.0): TCP provides reliable
  ordered delivery — application-level chunking and SHA256-per-chunk are unnecessary.
  dpipe_file handles incremental SHA256 for end-to-end integrity verification.
- **LSA version broadcast**: Host broadcasts version in LSA every 2s for informational
  purposes. Guest no longer takes autonomous action on version mismatch. The Host's
  opt-in auto-upgrade (build-time `protocol.AUTO_UPGRADE`, default **false**) can push
  to mismatched Guests — off by default so upgrades stay on-demand (`--upgrade`/`--deploy`).
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)
- **Hub-spoke SOCKS5 forwarding** (v0.15.0) — Host is the central SOCKS5 proxy.
  TCP :2121 accepts SOCKS5, dispatches by target hostname: self+2121 → utmm
  frame protocol, self+other-port → localhost relay, other-host → chained
  SOCKS5 forward. Guests route through Host via `gateway:2121` (auto-synced
  to every Guest's `/etc/hosts`). Third-party tools reach any Guest from the Host
  without SSH tunnels or port mapping.
- **HTTP MCP embedding** (v0.18.0) — MCP JSON-RPC served directly by Host daemon
  via TCP :2121 first-byte dispatch (0x05→SOCKS5, ASCII→HTTP). Eliminates the
  stdio MCP process and IPC bridge: no SIGALRM idle timeout, no EINTR races,
  no 64KB exec buffer truncation, no IPC serialization overhead. Core business
  logic extracted to `mcp_handler.zig` — shared by HTTP MCP and IPC handlers
  with zero duplication. `utmm --mcp` prints the HTTP endpoint and auto-ensures
  Host daemon.
- **MCP dual-format responses** (v0.18.1) — Every tool result includes both
  `content[0].text` (human-readable markdown) and `structuredContent`
  (machine-readable JSON). AI agents parse `structuredContent` for programmatic
  decisions without regex/markdown extraction. Fields: status→guests[]+counts,
  exec→{vm,command,exit_code}, ping→{vm,reachable,mac,rtt_ms}, upload→{vm,
  local_path,remote_path,success}, download→{vm,remote_path,local_path,bytes,
  success}, sshpass→{host,user,exit_code}. All format helpers in `src/mcp.zig`.
- **Exec output streaming** (v0.18.69) — Guest streams pty output as 4KB
  chunks (only a ≤6-byte tail is held for partial MDELIM prefix detection),
  eliminating the 64KB single-frame loss bug. Host forwards chunks in real
  time: CLI via per-chunk `exec_data` IPC frames (terminal shows output as it
  arrives), MCP via synchronous full response (single-call semantics — a
  two-phase session/read model was rejected as unusable for AI agents).
- **Download end-to-end hash verification** (v0.18.69) — `download_result`
  frame (cmd_id + file_size + sha256_hex) precedes the raw byte stream,
  symmetric with upload. Host reads exactly file_size bytes and verifies
  incremental SHA256. Parse results must be copied out of the recv buffer
  before reuse (dangling-slice bug found in live verification).
- **Windows exec OEM↔UTF-8 codec** (v0.18.79) — cmd.exe /k session keeps the system
  local OEM codepage; dpipe_shell converts output OEM→UTF-8 and input UTF-8→OEM
  (GetOEMCP() auto-matches GBK/Shift-JIS/EUC-KR — multilingual without knowing the
  target's codepage). Legacy commands (ipconfig etc.) ignore `chcp` and always emit
  local ANSI/OEM — `chcp 65001` never fixed output and corrupts cmd's piped stdin
  (byte-at-a-time decode → U+FFFD). ConPTY was attempted and **rejected**: in the
  Session 0 service chain every API succeeds but cmd never attaches (zero output,
  5 implementation variants incl. exact EchoCon replica all fail) — see findings
  2026-08-19. Never deploy an unverified implementation fleet-wide.
- **macOS utmmd hash check disabled** (v0.18.72) — adhoc codesign is
  non-deterministic and remove-signature is not byte-reversible, so the
  installed utmmd hash can never match the embedded unsigned hash.
  `shouldUpdateUtmmd` returns false on macOS (utmmd updates come from
  explicit `--install`); Linux/Windows keep hash comparison.
- **Exec cancellation propagation** (v0.18.80) — connection lifetime =
  command lifetime. Client disconnect (agent abort / CLI Ctrl-C) → Host
  detects (HTTP: poll+recv EOF; IPC: zero-length exec_data write probe every
  2s — EPIPE/BROKEN_PIPE = dead; write probing because macOS poll reports
  POLLHUP for half-closes too, findings 2026-08-19) → shutdown Guest TCP →
  Guest watcher (per-exec thread, 250ms poll) → `dpipe_shell.requestKill` →
  process-group SIGKILL (`kill(-pid)`). Zero protocol changes; mixed-version
  fleets degrade to the old behavior. Guest frame commands now run on
  per-connection threads (`std.Thread.spawn` detached) instead of inline in
  the accept loop — a long exec no longer blocks the Guest's other commands.
- **macOS pty closeFn order** (v0.18.80) — POSIX closeFn closes the pty
  master BEFORE killing: a shell blocked in slave-read that receives SIGKILL
  lingers in E-state ~5s on macOS until the master closes; master-close-first
  gives EOF → clean exit → reap in ~100ms (previously every exec burned a
  hidden 5s in teardown).

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
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos         # → zig-out/bin/utmm-aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos          # → zig-out/bin/utmm-x86_64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows       # → zig-out/bin/utmm-aarch64-windows.exe
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows        # → zig-out/bin/utmm-x86_64-windows.exe
```

> **重要**：Debug 构建仅用于开发调试。部署、发布、CI 必须使用 `-Doptimize=ReleaseSafe`。
> x86_64-linux-musl Debug 模式 `.data.rel.ro` 段膨胀至 20MB+，整体 80MB+；ReleaseSafe 后降至 11MB。
>
> 32-bit x86 (x86-linux-musl, x86-windows-gnu) 不支持 — zio 不支持 32-bit x86。

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

## Release Process (CI-owned since v0.18.80)

Local side only bumps the version and pushes a tag; **tests, 8-target build,
SignPath signing, and GitHub Release all run in CI** (`.github/workflows/release.yml`).
Push/PR test gating lives in `.github/workflows/ci.yml`.

> **CI sibling dependency**: `build.zig.zon` declares `.zio = .{ .path = "../zio" }`
> (fixnet-ai/zio fork, branch feat/x86-32 — x86-32 support pending upstream PR #646).
> Both workflows clone it to `../zio` after checkout — without this step
> `zig build test` fails with `unable to open '../zio': FileNotFound`
> (root cause of 15+ consecutive CI failures before v0.18.80).
> Local dev requires: `git clone -b feat/x86-32 https://github.com/fixnet-ai/zio.git ../zio`

### Prerequisites
- Clean working tree (no uncommitted changes)
- (gh CLI / Zig only needed for local `--deploy`, not for releasing)

### Step 1: Determine version
Read `src/ver.txt` for the current version. Ask the user what the next version
should be (suggest patch bump, e.g. `0.17.16` → `0.17.17`).
If already bumped and not yet tagged, use that.

### Step 2: Bump version (if needed)
Update one file:
- `src/ver.txt`: change version number (e.g., `0.17.16` → `0.17.17`)

`build.zig.zon` version is permanently `0.0.0` (never changes). Runtime version
comes from `src/ver.txt` via `@embedFile` at compile time — single source of truth.
`--install` is a single self-contained operation — no external scripts needed.

### Step 3: Tag & push (CI does the rest)
```bash
./release.sh vX.Y.Z "Release notes"
```
Thin script: verifies `src/ver.txt` + clean tree → commits the bump →
annotated tag (notes) → push. The tag triggers the CI pipeline:
unit + integration tests → `zig build cross` 8 targets ReleaseSafe →
SignPath Windows signing (if enabled) → GitHub Release with `utmm.zip`
(auto-generated release notes).

**utmmd mode decision is retired**: CI always builds with `-Dutmmd=true`
(default) — the supervisor is rebuilt from source every release, so published
binaries can never carry a stale embedded utmmd. The old
`--utmmd/--no-utmmd` per-release decision (and the
`src/embed/UTMMD-BUILT-FROM` drift guard) no longer applies to releases.
Repo-tracked `src/embed/*/utmmd.bin` still serves the local `--deploy` path.

**CI failure handling**: fix the issue, then re-run the failed run from the
Actions page, or delete and re-create the tag:
`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z && ./release.sh ...`

**Manual build-chain verification** (no release): Actions → Release workflow →
"Run workflow" (workflow_dispatch). The release job only publishes on tag refs.
Cross-compilation targets:

| # | Target | Output Binary |
|---|--------|---------------|
| 1 | `x86_64-windows` | `utmm-x86_64-windows.exe` |
| 2 | `aarch64-windows` | `utmm-aarch64-windows.exe` |
| 3 | `x86-windows` | `utmm-x86-windows.exe` |
| 4 | `x86_64-macos` | `utmm-x86_64-macos` |
| 5 | `aarch64-macos` | `utmm-aarch64-macos` |
| 6 | `x86_64-linux-musl` | `utmm-x86_64-linux` |
| 7 | `aarch64-linux-musl` | `utmm-aarch64-linux` |
| 8 | `x86-linux-musl` | `utmm-x86-linux` |

> 8 targets total. x86 32-bit macOS excluded (macOS dropped 32-bit support).
> x86 32-bit Linux + Windows added in v0.18.0 (zio feat/x86-32 branch).

### Step 5: Verify
Watch the CI run (Actions → Release workflow) turn green, then confirm on the
release page:
- `utmm.zip` is attached
- Release notes are correct
- Tag points to the right commit
- (Once SignPath is enabled) downloaded `utmm-*-windows.exe` show a valid
  Authenticode signature on Windows (file Properties → Digital Signatures)

### SignPath enablement (one-time, after OSS application is approved)

1. Apply at signpath.org (open source program, MIT license, public repo) —
   manual approval, ~1 week
2. SignPath portal: add Trusted Build System "GitHub.com" + install the
   SignPath GitHub App authorized for this repo; create project
   `utm-monitor`, signing policy `release-signing`, Artifact Configuration
   with a `<zip-file>` root element signing `utmm-*.exe`
3. GitHub repo settings → Secrets and variables → Actions:
   - Secrets: `SIGNPATH_API_TOKEN`, `SIGNPATH_ORGANIZATION_ID`
   - Variables: `SIGNPATH_ENABLED=true`

The sign job stays skipped (green neutral) until step 3 flips it on — releases
are unsigned but never blocked.

### Post-release
Use `utmm --deploy` — it scp's each VM and runs the full installer
(`--install --hostname <vm>`), which updates **both** utmm and utmmd
(utmmd only when its embedded hash differs).

**升级通道约定（2026-08-18 裁定）**: 版本升级一律走 `--deploy`。
`--upgrade <vm>`（mesh 推送）**只更新 utmm、永远不更新 utmmd**——单独使用
会造成 utmm/utmmd 版本漂移（Windows VM 曾因此 supervisor 落后 6 天未察觉，
见 findings 2026-08-18）。`--upgrade` 仅适用于紧急单机 utmm 热修。

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

### HTTP MCP Server Patterns (v0.18.0+)

- **First-byte dispatch**: `hostTcpListen` reads 1 byte on accept: `0x05`→SOCKS5,
  uppercase ASCII→HTTP MCP. Single-threaded peek, dispatched to thread pool.
- **HTTP/1.1 POST only**: `mcp_http.zig` handles one request per connection (no
  keep-alive). Reads request line → headers (Content-Length) → body → dispatches
  to `mcp.processRequest()` → writes HTTP response → closes socket.
- **Max body 64KB**: matches old stdio buffer size. Content-Length required.
  Non-POST returns 405, missing Content-Length returns 411, oversized returns 413.
- **Thread pool execution**: `spawnBlocking(mcpHttpHandler, ...)` runs HTTP handler
  on zio thread pool. ConnLimit prevents overload. Heartbeat updated before spawnBlocking.
- **McpContext struct**: `{ io, gpa, port, state: ?*GuestTable, mesh_ptr: ?*anyopaque, hostname }`
  — carries Host daemon state into MCP processor. Eliminates IPC serialization.

### TCP Frame Protocol Patterns

- **Frame format**: 1-byte type + 4-byte BE length + payload. Length = payload bytes only.
  `protocol.zig` handles frame serialization via `sendFrame`/`recvFrame`.
- **First-byte protocol dispatch** (v0.18.0): `hostTcpListen` reads 1 byte on accept
  before any further processing. `0x05` → SOCKS5 (skip VER byte, use
  `socks5.readRequestBufWithVersion`). Uppercase ASCII → HTTP MCP
  (`mcpHttpHandler` on thread pool). Everything else → close. This enables
  SOCKS5, utmm frame protocol, and HTTP MCP on a single TCP port.
- **SOCKS5**: In `socks5.zig` (extracted from tcp.zig at v0.16.0). Host accepts SOCKS5 on
  TCP :2121 and dispatches by target hostname: self+2121 → utmm frame protocol,
  self+other → localhost relay, other → chained SOCKS5 forward via node table.
  Guests accept SOCKS5 from Host only (self+2121 → frame protocol, self+other →
  localhost relay). Key API: `socks5.checkAndReply` (accept side), `socks5.connect`
  (connect side), `socks5.forward` (chain-forward), `socks5.localRelay` (localhost
  forward), `socks5.relay` (bidirectional relay), `socks5.hostConnect` (Host→Guest
  via SOCKS5 proxy). Guest→Guest goes through Host via `gateway:2121`.
  `socks5.authAcceptWithVersion` / `socks5.readRequestBufWithVersion` accept
  pre-peeked VER byte for first-byte dispatch compatibility.
- **Windows socket handle compatibility**: On Windows, Zig 0.16.0's `IpAddress.connect()`
  returns AFD kernel handles which are NOT compatible with Winsock2 `recv`/`send`.
  `sockAccept` returns raw Winsock2 SOCKET handles. These two handle types cannot
  be mixed in `sockRead`/`sockWrite`/`socks5Relay`. Use `sockConnectLocalhost()`
  (raw Winsock2 `ws2_socket` + `ws2_connect`) for localhost connections that need
  to relay with accept-fd handles. Same rule applies to any new outbound TCP
  connect that will be relayed with an accept-fd — use raw Winsock2 on Windows.
- **Per-command connections**: Every exec/upload/download opens `tcp.connect()`,
  completes one operation, and closes. No connection pooling or keep-alive.
  HTTP MCP connections are also single-request-per-connection.

### LSA Patterns

- **LSA carries version**: Host node_info includes version string for informational
  purposes (visible in `--status`). Auto-upgrade triggering is opt-in via
  `protocol.AUTO_UPGRADE` (default **false**) — see the LSA scan loop in host.zig.
- **Self-contained closed loop**: LSA rx → update node table → trigger hosts sync
  via range replacement (not splitScalar). No external state dependency.
- **2s broadcast interval**: Host broadcasts LSA every 2 seconds. Nodes timeout
  after 6 seconds (3 missed broadcasts).

### DuplexPipe Patterns

- **Vtable not generics**: `DuplexPipe` uses a vtable pointer — no comptime generics,
  fast compilation. Each implementation (shell, file, tcp) has its own vtable instance.
- **relay() threading**: `dpipe.relay()` spawns two zio `spawnBlocking` tasks (a→b and
  b→a). Either side closing sets a shared `std.atomic.Value(bool)` done flag to
  trigger the other side to close.
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