# utmm Reference Manual

utmm is a remote machine management tool — single binary, dual mode (Host +
Guest). It provides command execution, file transfer, mesh networking, and
SOCKS5 forwarding to any machine (VM, cloud instance, or bare metal) running
the Guest daemon. AI agents interact with utmm via HTTP MCP JSON-RPC
on the Host's TCP :2121 port (`utmm --mcp` prints the endpoint URL).

## For AI Agents — Quick Start

If you are an AI agent reading this via the `manual` MCP tool, here is what you
need to know:

**Available tools**: `status`, `exec`, `ping`, `upload`, `download`, `sshpass`,
`manual` — all accessible through MCP JSON-RPC.

**Typical workflow**:
1. Call `status` to see which machines are online and their shell types.
2. Call `exec` to run commands on a machine (check shell type first —
   Linux/macOS use POSIX sh, Windows uses cmd.exe syntax with `&&` chaining).
3. Use `upload`/`download` for file transfer with SHA256 integrity verification.
4. Use `sshpass` for direct SSH to machines without utmm installed (bootstrap,
   recovery, or one-off access).
5. Call `ping` to test mesh network connectivity and measure RTT to a machine.

**Key rules**:
- Hostnames are case-insensitive — `LinuxVM`, `linuxvm`, `LINUXVM` are identical.
- Each `exec` runs in a fresh shell — no `cd` or `export` persistence across calls.
- **Connection lifetime = command lifetime**: aborting an `exec` call (agent
  timeout, HTTP disconnect, CLI Ctrl-C) kills the command on the target
  machine — the process group is SIGKILLed within ~2s. No zombie commands.
- Windows `exec` commands: use `&&` for chaining, NOT `;`.
- LSA mesh sync takes ~10–15s after Guest restart before it appears in `status`.

## Table of Contents

- [For AI Agents — Quick Start](#for-ai-agents--quick-start)
- [CLI Reference](#cli-reference)
- [MCP Protocol](#mcp-protocol)
- [Architecture](#architecture)
- [Common Usage Scenarios](#common-usage-scenarios)
- [Platform Differences](#platform-differences)
- [Deployment Guide](#deployment-guide)
- [Troubleshooting](#troubleshooting)

---

## CLI Reference

### Service Management

| Command | Description |
|---------|-------------|
| `utmm --install --hostname <name>` | Force install as system auto-start service (guest mode) |
| `utmm --host --install` | Force install as system auto-start service (host mode) |
| `utmm --uninstall` | Remove system service and binary |
| `utmm --version` | Print version and exit (no root needed) |

### Mode Selection

| Command | Description |
|---------|-------------|
| `utmm` (no args) | Ensure Guest service is running (auto-installs if needed) |
| `utmm --host` | Ensure Host service is running |
| `utmm --svc` | Internal: run as daemon (set by service manager) |
| `utmm --mcp` | Print MCP HTTP endpoint URL and ensure Host daemon is running |

### Guest Options

| Option | Description |
|--------|-------------|
| `--hostname NAME` | Local hostname (auto-detect by default) |
| `--host-ip IP` | Host IP to connect to (auto-detect via gateway by default) |
| `--port PORT` | Service port (default 2121) |
| `--mesh-port PORT` | Mesh UDP port (default 2121) |
| `--peer-mesh ADDR` | Direct peer mesh address for local testing |
| `--log-file PATH` | Log file path |

> **Hostname normalization**: All hostnames (`--hostname`, `--exec`, `--ping`,
> `--upload`, `--download`, `--upgrade`, `--deploy`, and MCP `vm` parameters) are
> automatically lowercased before processing. Guest OS hostnames from
> `gethostname()` / `COMPUTERNAME` are also lowercased at source. This ensures
> case-insensitive matching across all code paths — `LinuxVM`, `LINUXVM`, and
> `linuxvm` are treated identically.

### Host Options

| Option | Description |
|--------|-------------|
| `--port PORT` | Service port (default 2121) |
| `--hosts-file PATH` | hosts file path (default /etc/hosts) |
| `--serve-dir PATH` | Binary serve directory for upgrade push |
| `--marker TAG` | hosts-file marker comment |
| `--log-file PATH` | Log file path |

### Management Commands

All require Host service running. Auto-start Host if not running.

```bash
utmm --status                    # Query all online guest status
utmm --ping <vm>                 # Ping a guest via LSA mesh
utmm --exec <vm> "<cmd>"         # Execute command via per-command pty
utmm --upload <file> <vm>[:path] # Upload file (SHA256 verified)
utmm --download <vm> <rp> [lp]   # Download file (SHA256 verified)
utmm --upgrade <vm>              # Push upgrade binary to Guest via SOCKS5 mesh
utmm --deploy [vm]               # Build, SCP, install & verify (uses serve-dir cache)
utmm --gen-init <platform>       # Generate auto-start script
```

### sshpass Subcommand

Non-interactive SSH password authentication. 100% CLI-compatible with standalone
`sshpass(1)`. No root needed.

```
utmm sshpass [-p PASS | -f FILE | -d FD | -e] [-hV] command [args...]
```

| Option | Description |
|--------|-------------|
| `-p PASS` | Password from command line |
| `-f FILE` | Password from file (first line) |
| `-d FD` | Password from file descriptor |
| `-e` | Password from `SSHPASS` environment variable |
| (none) | Read password from stdin (first line) |
| `-h` | Show help and exit |
| `-V` | Print version and exit |

Password sources are mutually exclusive — conflicting sources return exit code 2.

**Exit codes** (identical to original sshpass):

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Invalid arguments |
| 2 | Conflicting password sources |
| 3 | Runtime error (PTY allocation failure, etc.) |
| 4 | Parse error |
| 5 | Incorrect password |
| 6 | Unknown host key |
| 7 | Host key changed (reserved) |

**Examples**:
```bash
utmm sshpass -p '111' ssh root@linuxvm 'ls -la'
utmm sshpass -f ~/.ssh/pass ssh user@server 'uptime'
utmm sshpass -e ssh admin@host 'cat /proc/cpuinfo'
```

**Windows password authentication (SSH_ASKPASS)**: On Windows, `utmm sshpass`
uses the Win32 OpenSSH `SSH_ASKPASS` mechanism — it sets the `SSH_ASKPASS`/
`SSHPASS` environment variables pointing to a fixed `askpass.bat` and spawns
`ssh.exe` with stdin redirected to `NUL` (immediate EOF). This bypasses TTY/
ConPTY entirely, so password auth works in every Windows version and in
Session 0 service contexts (no interactive console). Non-ssh interactive
commands may still use ConPTY (Windows 10 1809+); `--status` shows each node's
`conpty:yes/no` platform capability.

---

## MCP Protocol

MCP is served directly by the Host daemon via HTTP POST on TCP :2121 (first-byte
protocol dispatch: `0x05`→SOCKS5, ASCII→HTTP MCP). No separate MCP process,
no IPC bridge.

`utmm --mcp` prints the HTTP endpoint URL (`http://127.0.0.1:{port}/`) and
ensures the Host daemon is running. AI agents then send JSON-RPC 2.0 requests
as HTTP POST with `Content-Type: application/json`. Each request opens a fresh
TCP connection — single-request-per-connection model (no keep-alive).

**Dual-format responses** (v0.18.1+): Every tool result includes both
`content[0].text` (human-readable markdown for display) and `structuredContent`
(machine-readable JSON for programmatic use). AI agents should parse
`structuredContent` instead of extracting data from markdown text.

| Tool | structuredContent fields |
|------|-------------------------|
| `status` | `guests[]`, `counts{total,serving,offline}` |
| `exec` | `vm`, `command`, `exit_code` |
| `ping` | `vm`, `reachable`, `mac`, `rtt_ms` |
| `upload` | `vm`, `local_path`, `remote_path`, `success` |
| `download` | `vm`, `remote_path`, `local_path`, `bytes`, `success` |
| `sshpass` | `host`, `user`, `exit_code` |

### Initialization

```
→ POST http://127.0.0.1:2121/  Content-Type: application/json
  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",...}}
← HTTP/1.1 200 OK  Content-Type: application/json
  {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"utmm","version":"0.18.1"},"capabilities":{"tools":{}}}}

→ POST (notification — no response expected for "notifications/initialized")
  {"jsonrpc":"2.0","method":"notifications/initialized"}

→ POST
  {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← HTTP/1.1 200 OK  Content-Type: application/json
  {"jsonrpc":"2.0","id":2,"result":{"tools":[{...tool1...},{...tool2...}]}}
```

### tools/list Response

Returns 7 tools: `status`, `exec`, `ping`, `upload`, `download`, `sshpass`,
`manual`. Each tool has `name`, `description`, and `inputSchema` (JSON Schema).

### sshpass: Direct SSH from AI Agents

`sshpass` is a first-class MCP tool that spawns `utmm sshpass` as a child process
— AI agents call it through the standard MCP JSON-RPC channel, just like any other
tool. It is also available as a CLI command for shell-based automation.

**Why sshpass matters:**

- **Cross-platform SSH automation** — works identically on Linux, macOS, and
  Windows. On Windows it uses the `SSH_ASKPASS` mechanism (no TTY/ConPTY
  dependency), so it works in all Windows versions including Session 0 service
  contexts. No external sshpass binary needed.
- **Bootstrap and recovery** — SSH into a VM before utmm is installed, during
  upgrades, or when the Guest daemon is down.
- **Unified AI agent interface** — calling sshpass through MCP means AI agents
  get structured request/response handling, error codes, and output capture —
  no shell escape needed.

See [sshpass Subcommand](#sshpass-subcommand) for the full CLI reference.

### tools/call Examples

**status** — list all nodes (v0.18.1+ includes structuredContent):
```
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"**Connected Machines:**\n- **linuxvm** (guest) — aarch64-linux-musl | IP: 192.168.64.6 | MAC: 16:a0:6c:... | v0.18.1 | shell: bash | status: serving\n..."}],"structuredContent":{"guests":[{...}],"counts":{"total":1,"serving":1,"offline":0}}}}
```

**exec** — execute a command:
```
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"exec","arguments":{"vm":"linuxvm","command":"uname -a"}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"**linuxvm** `$ uname -a`:\n```\nLinux linuxvm 6.1.0-... aarch64 GNU/Linux\n```"}],"structuredContent":{"vm":"linuxvm","command":"uname -a","exit_code":0}}}
```

**ping** — mesh connectivity test:
```
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ping","arguments":{"vm":"linuxvm"}}}
← {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"**linuxvm** ping: MAC=16:a0:6c:..., RTT=3ms"}],"structuredContent":{"vm":"linuxvm","reachable":true,"mac":"16:a0:6c:...","rtt_ms":3}}}
```

**upload** — file transfer to Guest:
```
→ {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"upload","arguments":{"vm":"linuxvm","local_path":"/tmp/test.txt","remote_path":"/opt/utmm/test.txt"}}}
← {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"Upload OK: /opt/utmm/test.txt (1048576 bytes, SHA256: abc123...)"}],"structuredContent":{"vm":"linuxvm","local_path":"/tmp/test.txt","remote_path":"/opt/utmm/test.txt","success":true}}}
```

**download** — file transfer from Guest:
```
→ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"download","arguments":{"vm":"linuxvm","remote_path":"/var/log/app.log","local_path":"./app.log"}}}
← {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"Download OK: ./app.log (4096 bytes)"}],"structuredContent":{"vm":"linuxvm","remote_path":"/var/log/app.log","local_path":"./app.log","bytes":4096,"success":true}}}
```

**sshpass** — direct SSH to any machine:
```
→ {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"sshpass","arguments":{"host":"linuxvm","user":"root","password":"111","command":"uname -a"}}}
← {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"**ssh root@linuxvm** `uname -a`\\nexit: 0\\n```\\nLinux linuxvm 6.1.0-... aarch64 GNU/Linux\\n```"}],"structuredContent":{"host":"linuxvm","user":"root","exit_code":0}}}
```

**manual** — get the full reference manual (this document):
```
→ {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"manual","arguments":{}}}
← {"jsonrpc":"2.0","id":9,"result":{"content":[{"type":"text","text":"# utmm Reference Manual\n\n..."}]}}
```

The `manual` tool returns the entire MANUAL.md embedded at compile time — no
arguments needed. Use it whenever you need detailed information about utmm
usage, architecture, platform specifics, or troubleshooting.

### Error Response Format

```json
{"jsonrpc":"2.0","id":8,"error":{"code":-32603,"message":"GuestNotFound"}}
```

Standard JSON-RPC error codes: `-32600` (Invalid Request), `-32602` (Invalid
Params), `-32603` (Internal Error — tool-specific failure).

---

## Architecture

### Run Modes

**Guest mode** (default): The Guest daemon listens on TCP/UDP port 2121 for SOCKS5
connections and mesh broadcasts. It accepts SOCKS5 connections from the Host only —
no local CLI entry point for Guest commands. Each command (exec/upload/download)
spawns a fresh pty session, so there is no `cd` or `export` persistence.

**Host mode** (`--host`): The Host daemon is the central coordination node —
it runs the LSA mesh, maintains the node table, syncs `/etc/hosts` on Guests,
accepts SOCKS5 connections from Guests and chain-forwards them to other Guests,
and serves CLI/MCP requests via a local IPC socket. Only one Host per mesh.
The Host is the only node that relays SOCKS5 between Guests.

**MCP mode** (`--mcp`): Prints the HTTP endpoint URL and ensures the Host daemon
is running. MCP JSON-RPC is served directly by the Host daemon via TCP :2121
first-byte dispatch — no separate MCP process, no IPC bridge. AI agents POST
JSON-RPC requests to `http://127.0.0.1:2121/`.

### How a Command Flows

**CLI management commands** (via IPC socket):
```
1. User runs: utmm --exec linuxvm "ls -la"
2. CLI connects to Host daemon via local IPC socket
3. Host opens SOCKS5 connection to linuxvm:2121
4. Host sends the command frame (with "ls -la; echo MDELIM:$?\n" appended)
5. Guest spawns a fresh pty, runs the command, streams output back
6. Host forwards output to CLI, detects exit-code marker, reports exit code
```

**MCP commands** (via HTTP POST, handled directly by Host daemon):
```
1. AI Agent: HTTP POST :2121 {"method":"tools/call","params":{"name":"exec",...}}
2. Host first-byte dispatch: ASCII 'P' → mcp_http → mcp.processRequest
3. mcp_handler.execOnGuest → SOCKS5 connect → send command → stream recv → return result
4. Host: write HTTP 200 response with JSON-RPC result
```

Each exec/upload/download opens a fresh TCP connection, completes one operation,
and closes — no persistent tunnels between commands. Each MCP HTTP request is
also one connection.

### SOCKS5 Forwarding (Hub-Spoke)

The Host is the central SOCKS5 proxy. Guests accept SOCKS5 from the Host only.
Every Guest's `/etc/hosts` has the Host's IP mapped as `gateway` — from any
Guest, target the Host with `gateway:2121`.

**Dispatch model (Host TCP :2121):**

```
TCP connection arrives at Host :2121:
  peek 1 byte:
    'A'..'Z' → HTTP MCP JSON-RPC (read HTTP request, process, respond, close)
    0x05      → SOCKS5 dispatch:
      target_hostname == self ?
        ├─ target_port == 2121 → utmm internal frame protocol (exec/upload/download)
        └─ target_port != 2121 → connect 127.0.0.1:target_port, relay
      target_hostname != self ?
        └─ lookup hostname→IP in node table
            ├─ found → chain-forward SOCKS5 to target_ip:2121, relay
            └─ not found → REJECT
    other → close (unknown protocol)
```

**Guest SOCKS5 accept (TCP :2121):**

```
SOCKS5 request arrives from Host at Guest:
  target_hostname == self ?
    ├─ target_port == 2121 → utmm internal frame protocol (exec/upload/download)
    └─ target_port != 2121 → connect 127.0.0.1:target_port, relay
  target_hostname != self →
    REJECT — Guests only serve local services; use gateway for other Guests
```

**Examples:**

```bash
# From Host — reach any Guest service
curl --socks5 localhost:2121 http://linuxvm:8080       # web server on linuxvm
curl --socks5 localhost:2121 http://macvm:22            # SSH on macvm
curl --socks5 localhost:2121 http://windowsvm:3389      # RDP on windowsvm

# From a Guest — route through the Host (gateway)
curl --socks5 gateway:2121 http://linuxvm:8080          # Guest → Host → linuxvm
curl --socks5 gateway:2121 http://windowsvm:3389        # Guest → Host → windowsvm

# Local service on the Host itself
curl --socks5 localhost:2121 http://localhost:3000

# Git clone via SOCKS5
git -c http.proxy=socks5://localhost:2121 clone http://linuxvm:8080/repo.git
```

**Key properties:**
- Host TCP :2121 must be reachable from all Guests
- Each forwarded connection runs independently, exits when either side closes
- Works with any SOCKS5-compatible client: `curl`, `wget`, browsers, `git`, database tools
- Host name `gateway` is auto-synced to every Guest's `/etc/hosts`

### Mesh Networking (LSA)

The Host broadcasts Link State Advertisements (LSA) via UDP port 2121 every 2
seconds. Each Guest listens for LSA broadcasts and the Host maintains a node table
with all discovered machines. Nodes that miss 3 consecutive broadcasts (6 seconds)
are marked offline.

LSA also carries node metadata: hostname, IP address, OS/architecture, version,
shell type, ConPTY support, and role (host/guest). This is what powers the
`--status` and `--ping` commands.

**Mesh diagnostics:**

```bash
# Check which nodes the Host can see
utmm --status

# Test direct mesh reachability to a specific Guest
utmm --ping linuxvm

# Check if a Guest is receiving LSA broadcasts
utmm --exec linuxvm "cat /etc/hosts | grep UTM-MONITOR"
```

---

## Common Usage Scenarios

### Remote Command Execution

```bash
# Basic system info
utmm --exec linuxvm "uname -a"
utmm --exec windowsvm "ver"

# Process and resource inspection
utmm --exec linuxvm "ps aux | head -20"
utmm --exec linuxvm "free -h && df -h"
utmm --exec windowsvm "tasklist | findstr /i java"

# Service management on Guests
utmm --exec linuxvm "systemctl status nginx"
utmm --exec windowsvm "sc.exe query UTM-MonitorD"

# Network diagnostics from within a Guest
utmm --exec linuxvm "ip addr show && ping -c 3 8.8.8.8"
utmm --exec windowsvm "ipconfig /all && ping -n 3 8.8.8.8"

# Multi-step Windows commands (use && chaining)
utmm --exec windowsvm "cd C:\opt\utmm && dir && type config.ini"

# Long-running commands — output streams in real time
utmm --exec linuxvm "find /var/log -name '*.log' -mtime -1 -exec tail -5 {} \;"
```

> **Windows note**: Always use `&&` for command chaining on Windows — `;` is not
> recognized by `cmd.exe`. Use `findstr` instead of `grep`, `type` instead of `cat`.

### File Transfer

```bash
# Upload a config file to a specific path
utmm --upload nginx.conf linuxvm:/etc/nginx/nginx.conf

# Upload to default directory (/opt/utmm/ or C:\opt\utmm\)
utmm --upload myapp.exe windowsvm

# Download log files for analysis
utmm --download linuxvm /var/log/syslog ./syslog.txt

# Download Windows event logs
utmm --download windowsvm C:\Windows\System32\winevt\Logs\Application.evtx ./

# Upload and verify — SHA256 is computed during transfer
# The file is written to a temp location, verified, then atomically renamed
```

File transfers use direct TCP streaming with end-to-end SHA256 integrity
verification. Uploads are atomic (temp file → verify hash → rename) so a
failed transfer never leaves a partial file. Downloads stream directly from
the Guest's filesystem.

### SOCKS5 Tunneling

The Host TCP :2121 port is a full SOCKS5 proxy. Any SOCKS5-compatible tool
can reach any Guest through it.

```bash
# Browse a web app running on a Guest
curl --socks5 localhost:2121 http://linuxvm:8080/api/health

# SSH to a Guest through the SOCKS5 tunnel
ssh -o ProxyCommand='nc --proxy-type socks5 --proxy localhost:2121 %h %p' root@linuxvm

# Database client connecting to a database on a Guest
psql -h linuxvm -p 5432 -U postgres  # with SOCKS5 proxy in ~/.psqlrc or env

# From a Guest — use gateway:2121 (Host IP is auto-synced to /etc/hosts)
curl --socks5 gateway:2121 http://windowsvm:8080

# Browser setup: configure SOCKS5 proxy to localhost:2121, then browse
# http://linuxvm:3000 directly in the address bar
```

### Software Upgrade

**Standard path — `--deploy` (updates both utmm and utmmd):**

```bash
# 1. Release: thin script verifies ver.txt + tags + pushes; CI runs tests,
#    8-target build (utmmd always rebuilt from source) and publishes.
./release.sh vX.Y.Z "notes"

# 2. Deploy to every VM: scp + full installer (--install) per machine.
#    utmmd is replaced only when its embedded hash differs from disk.
utmm --deploy

# 3. Verify all Guests are on the new version
utmm --status
```

**Emergency hot-fix — `--upgrade` (utmm ONLY, never updates utmmd):**

```bash
# Push a single utmm binary Host → Guest over the SOCKS5 mesh channel
# (no SSH needed), SHA256-verified, zero-downtime restart via utmmd.
utmm --upgrade linuxvm
```

> **Channel convention**: version upgrades always go through `--deploy`.
> `--upgrade` pushes utmm only — using it alone causes utmm/utmmd version
> drift (the Windows VMs' supervisor once lagged 6 days unnoticed this way).
> On the deploy path `extractUtmmd` skips the rewrite when disk bytes already
> match the embedded binary, so unchanged supervisors stay byte-identical
> fleet-wide with no extra service churn.

`--deploy` SCPs each Guest's binary using built-in `utmm sshpass` (no external
sshpass needed), then runs the full installer over SSH. VM credentials are read
from `/opt/utmm/deploy.json` (falls back to compile-time defaults). Error
messages include actionable guidance for common failures.

### Bootstrap a New Machine

```bash
# 1. SSH in and create the install directory
utmm sshpass -p <pass> ssh root@newvm 'mkdir -p /opt/utmm'

# 2. Copy the binary (from Host serve-dir or zig-out/bin)
utmm sshpass -p <pass> scp /opt/utmm/utmm-aarch64-linux-0.18.1 root@newvm:/opt/utmm/utmm-new

# 3. Install as a system service
utmm sshpass -p <pass> ssh root@newvm '/opt/utmm/utmm-new --install --hostname newvm'

# 4. Wait for LSA sync (~10-15s), then verify
sleep 15 && utmm --status
```

For Windows VMs, use the `.exe` binary and Windows paths:
```bash
utmm sshpass -p <pass> scp /opt/utmm/utmm-x86_64-windows-0.18.1.exe Administrator@winvm:"C:\\opt\\utmm\\utmm-new.exe"
utmm sshpass -p <pass> ssh Administrator@winvm "C:\\opt\\utmm\\utmm-new.exe --install --hostname winvm"
```

> **Note**: All password-authenticated operations use `utmm sshpass` — no external
> sshpass binary needed. SSH agent and key-based auth are also supported directly.

---

## Platform Differences

### Paths

| Path | POSIX | Windows |
|------|-------|---------|
| Install dir | `/opt/utmm/` | `C:\opt\utmm\` |
| Binary | `/opt/utmm/utmm` | `C:\opt\utmm\utmm.exe` |
| Supervisor | `/opt/utmm/utmmd` | `C:\opt\utmm\utmmd.exe` |
| IPC socket | `/var/run/utmm.sock` | `\\.\pipe\utmm` |
| Install lock | `/var/run/utmm-install.lock` | `C:\opt\utmm\utmm-install.lock` |
| Service config | `/Library/LaunchDaemons/com.utmmd.plist` (macOS) | `sc.exe create` |
| Service config | `/etc/systemd/system/utmmd.service` (Linux) | — |

### Service Management

| Action | macOS | Linux | Windows |
|--------|-------|-------|---------|
| Service name | `com.utmmd` | `utmmd` | `UTM-MonitorD` |
| Start | `launchctl bootstrap system` | `systemctl start utmmd` | `sc.exe start UTM-MonitorD` |
| Stop | `launchctl bootout system/com.utmmd` | `systemctl stop utmmd` | `sc.exe stop UTM-MonitorD` |
| Uninstall | delete plist | delete unit file + daemon-reload | `sc.exe delete UTM-MonitorD` |

### Shell Types

| Platform | Default Shell | Command Chaining |
|----------|---------------|------------------|
| Linux | `/bin/bash` | `;` or `&&` |
| macOS | `/bin/zsh` | `;` or `&&` |
| Windows | `cmd.exe` (UTF-8) | `&&` only |

### Password Auth Matrix

| Platform | ssh password auth | Non-ssh interactive commands |
|----------|-------------------|------------------------------|
| Linux | PTY prompt injection | PTY (posix_openpt) |
| macOS | PTY prompt injection | PTY (posix_openpt) |
| Windows (all versions) | SSH_ASKPASS + NUL stdin (no TTY/ConPTY needed) | ConPTY (Win10 1809+) / askpass pipe |

> On Windows, `utmm sshpass` password auth is **not** tied to ConPTY — it uses
> Win32 OpenSSH's `SSH_ASKPASS` path, which works in Session 0 (service context)
> and on Windows < 1809. ConPTY remains the interactive path for non-ssh
> commands. See `--status` for each node's `conpty:yes/no` capability.

---

## Deployment Guide

### Initial Setup

**Host** (the control machine — typically your local workstation):

```bash
sudo utmm --host --install
sudo utmm --status    # verify the Host is running
```

**Guests** (managed machines) — create a deploy.json config file at
`/opt/utmm/deploy.json` (POSIX) or `C:\opt\utmm\deploy.json` (Windows Host):

```json
[
  {"hostname": "linuxvm",   "target": "aarch64-linux-musl",  "ip": "192.168.64.6", "user": "root",          "password": "111", "remote_dir": "/opt/utmm"},
  {"hostname": "macvm",     "target": "aarch64-macos",       "ip": "192.168.65.4", "user": "root",          "password": "111", "remote_dir": "/opt/utmm"},
  {"hostname": "windowsvm", "target": "aarch64-windows",     "ip": "192.168.64.3", "user": "Administrator", "password": "111", "remote_dir": "C:\\opt\\utmm"},
  {"hostname": "winx64",    "target": "x86_64-windows",      "ip": "192.168.3.108","user": "Administrator", "password": "111", "remote_dir": "C:\\opt\\utmm"}
]
```

All fields are required. If the file is missing or invalid, `--deploy` falls back
to compile-time defaults with a warning.

Then use the automated deploy pipeline:

```bash
# Deploy to all Guests (cross-compile + SCP + install + verify)
utmm --deploy

# Or deploy to a single Guest
utmm --deploy linuxvm
```

`--deploy` cross-compiles for all target platforms (skipped on subsequent runs
when cached binaries exist in serve-dir), transfers binaries via built-in
`utmm sshpass` (no external sshpass needed), and installs on each Guest. After
deployment, wait ~10–15 seconds for LSA mesh sync, then verify with `--status`.

### Manual Guest Deployment

If `--deploy` is not available (no build environment on the Host), deploy
binaries manually using `utmm sshpass`:

```bash
# POSIX (Linux/macOS)
utmm sshpass -p <pass> scp /opt/utmm/utmm-<target>-<version> root@<hostname>:/opt/utmm/utmm-new
utmm sshpass -p <pass> ssh root@<hostname> 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname <hostname>'

# Windows — kill utmmd first (it locks the exe → AccessDenied on rename)
utmm sshpass -p <pass> ssh Administrator@<hostname> 'taskkill /F /IM utmmd.exe 2>nul'
utmm sshpass -p <pass> scp /opt/utmm/utmm-<target>-<version>.exe Administrator@<hostname>:C:/opt/utmm/utmm-new.exe
utmm sshpass -p <pass> ssh Administrator@<hostname> 'C:\opt\utmm\utmm-new.exe --install --hostname <hostname>'
```

### Day-to-Day Upgrades

```bash
# Push upgrade to a Guest via SOCKS5 mesh (no SSH needed, zero-downtime)
utmm --deploy                # build & stage to serve-dir (cached on re-runs)
utmm --upgrade linuxvm       # push + restart via SOCKS5
utmm --status                # verify version

# Or deploy + upgrade in one line per Guest:
utmm --upgrade windowsvm     # if binary already in serve-dir
```

The upgrade is atomic: the new binary is SHA256-verified, the utmmd supervisor
stops the old process, renames the binary, and spawns the new one — zero-downtime
from the caller's perspective.

**Error messages are now actionable:**

| Error | What to do |
|-------|-----------|
| `GuestNotFound: ... — Use --deploy for initial setup` | VM not in mesh; run `--deploy` to bootstrap |
| `BinaryNotFound: ... — run 'utmm --deploy' first` | Missing binary in serve-dir; run `--deploy` |
| `UnknownTarget: ... — check deploy.json target field` | Architecture not recognized; fix config |
| `GuestConnectFailed` | TCP/SOCKS5 connect failed; check Guest is running |

### Verify Deployment

```bash
utmm --status                              # all Guests online + version match
utmm --exec linuxvm "echo OK"             # exec smoke test
utmm --exec macvm "echo OK"
utmm --exec windowsvm "echo OK"
utmm --upload /tmp/test.txt linuxvm        # upload test
utmm --download linuxvm /tmp/test.txt /tmp/dl.txt  # download test
```

---

## Troubleshooting

### Guest not appearing in status after install

**Symptom**: `utmm --status` doesn't show a newly installed Guest.

**Cause**: LSA mesh sync takes ~10–15 seconds after Guest service starts.
The Guest needs to receive at least one LSA broadcast and the Host needs to
register it in the node table.

**Check**:
```bash
# Check if Guest service is running
utmm --exec <vm> "echo OK"   # or use sshpass if Guest not in status yet

# Wait and retry
sleep 15 && utmm --status
```

### Hostname not resolving for direct SSH

**Symptom**: `ssh: Could not resolve hostname <name>`.

**Cause**: The machine is on a different IP subnet and LSA UDP broadcast may not
traverse subnet boundaries. `/etc/hosts` sync only covers machines on the same
broadcast domain.

**Workaround**: Use the IP directly for SSH/scp operations:
```bash
ssh Administrator@192.168.3.108 '<command>'
scp file.exe Administrator@192.168.3.108:C:/opt/utmm/
```
The `--status` / `--exec` / `--upload` / `--download` commands through the Host
work correctly with hostnames — only direct SSH/scp is affected.

### Windows service stop fails (sc.exe error 109)

**Symptom**: `[SC] ControlService FAILED 109: The pipe has been ended.`

**Cause**: The utmm process is in a bad state and the service control manager
cannot communicate with it.

**Workaround**: Kill the process directly before stopping the service:
```bash
ssh Administrator@windowsvm 'cmd /c "taskkill /F /IM utmm.exe & taskkill /F /IM utmmd.exe & sc.exe delete UTM-MonitorD"'
```

### Windows process verification

**Symptom**: `tasklist /fi "imagename eq utmm.exe"` doesn't work in `cmd /c`
remote commands.

**Workaround**: Use `tasklist | findstr` instead:
```bash
ssh Administrator@windowsvm 'cmd /c "tasklist | findstr utmm || echo clean"'
```

### macOS launchctl throttling

**Symptom**: `--install` fails with launchctl error after repeated bootout/bootstrap.

**Cause**: macOS throttles rapid service bootstrap cycles.

**Workaround**: Kill processes manually before running `--install`:
```bash
ssh root@macvm 'killall -9 utmm utmmd 2>/dev/null; sleep 1'
scp utmm-new root@macvm:/opt/utmm/utmm-new
ssh root@macvm 'cp /opt/utmm/utmm-new /opt/utmm/utmm && /opt/utmm/utmm --install --hostname macvm'
```

### Windows Firewall blocks inbound SOCKS5 connections

**Symptom**: SOCKS5 connections from Host to Windows Guest time out. Exec
commands targeting the Windows Guest fail with connection errors.

**Cause**: Windows Firewall blocks inbound connections to port 2121 (and other
ports used by SOCKS5 forwarding). Linux and macOS have no equivalent issue.

**Solution — add a firewall rule**:
```
netsh advfirewall firewall add rule name="utmm" dir=in action=allow program="C:\opt\utmm\utmm.exe" enable=yes
```

**Or disable Windows Firewall entirely** (appropriate for VM/isolated environments):
```
# PowerShell (Administrator)
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
```

**Verification**:
```
netsh advfirewall show allprofiles | findstr State
# Should show: State    OFF
```

> SOCKS5 CONNECT (the most common operation: exec, upload, download, forwarding)
> uses outbound connections which Windows Firewall allows by default. Only
> inbound connections are affected.

### pkill -f self-kill (Linux only)

**Symptom**: Remote SSH command `pkill -9 -f utmm` kills the SSH session itself.

**Cause**: `-f` matches the full command line. `bash -c 'pkill -9 -f utmm'`
contains "utmm" so the parent bash is killed before the command completes.

**Fix**: Always use `pkill -9 utmm` (match process name only, no `-f` flag).
