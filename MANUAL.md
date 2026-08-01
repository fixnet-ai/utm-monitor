# utmm Reference Manual

utmm is a remote machine management tool — single binary, dual mode (Host +
Guest). It provides command execution, file transfer, mesh networking, and
SOCKS5 forwarding to any machine (VM, cloud instance, or bare metal) running
the Guest daemon. AI agents interact with utmm via the MCP stdio JSON-RPC
interface (`utmm --mcp`).

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
- Windows `exec` commands: use `&&` for chaining, NOT `;`.
- LSA mesh sync takes ~10–15s after Guest restart before it appears in `status`.
- The `--marker` / hosts-file tag is `UTM-MONITOR` (historical, not significant).

## Table of Contents

- [For AI Agents — Quick Start](#for-ai-agents--quick-start)
- [CLI Reference](#cli-reference)
- [MCP Protocol](#mcp-protocol)
- [Architecture](#architecture)
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
| `utmm` (no args) | Ensure Guest service is running (auto-installs utmmd if needed) |
| `utmm --host` | Ensure Host service is running |
| `utmm --svc` | Internal: run as daemon (set by service manager) |
| `utmm --mcp` | Start MCP stdio JSON-RPC server (auto-ensures Host on first use) |

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
| `--marker TAG` | hosts-file marker comment (default "UTM-MONITOR") |
| `--log-file PATH` | Log file path |

### Management Commands

All require Host service running. Auto-start Host if not running.

```bash
utmm --status                    # Query all online guest status
utmm --ping <vm>                 # Ping a guest via LSA mesh
utmm --exec <vm> "<cmd>"         # Execute command via per-command pty
utmm --upload <file> <vm>[:path] # Upload file (SHA256 verified)
utmm --download <vm> <rp> [lp]   # Download file (SHA256 verified)
utmm --upgrade <vm>              # Push upgrade binary to Guest
utmm --deploy [vm]               # Cross-compile, SCP, install & verify
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

**ConPTY support**: On Windows, sshpass dynamically loads `CreatePseudoConsole`
API at runtime. If unavailable (Windows < 10.0.17763), it falls back to pipe
mode. Check `--status` for `conpty:yes/no` on each node.

---

## MCP Protocol

`utmm --mcp` implements a stdio JSON-RPC 2.0 server. One JSON object per line,
newline-delimited. Log traffic goes to stderr, JSON-RPC to stdout.

### Initialization

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",...}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"utmm","version":"0.14.7"},"capabilities":{"tools":{}}}}

→ {"jsonrpc":"2.0","method":"notifications/initialized"}
← (empty response — notification, no id)

→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{...tool1...},{...tool2...}]}}
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
  Windows. On Windows, dynamically loads ConPTY (Windows 10 1809+) or falls back
  to pipe mode. No external sshpass binary needed.
- **Bootstrap and recovery** — SSH into a VM before utmm is installed, during
  upgrades, or when the Guest daemon is down.
- **Unified AI agent interface** — calling sshpass through MCP means AI agents
  get structured request/response handling, error codes, and output capture —
  no shell escape needed.

See [sshpass Subcommand](#sshpass-subcommand) for the full CLI reference.

### tools/call Examples

**status** — list all nodes:
```
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"**Connected Machines:**\n- **linuxvm** (guest) — aarch64-linux-musl | IP: 192.168.64.6 | MAC: 16:a0:6c:... | v0.14.7 | shell: bash | status: online\n..."}]}}
```

**exec** — execute a command:
```
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"exec","arguments":{"vm":"linuxvm","command":"uname -a"}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"Linux linuxvm 6.1.0-... aarch64 GNU/Linux\n"}]}}
```

**ping** — mesh connectivity test:
```
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ping","arguments":{"vm":"linuxvm"}}}
← {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"hostname\":\"linuxvm\",\"mac\":\"16:a0:6c:...\",\"rtt_ms\":3}"}]}}
```

**upload** — file transfer to Guest:
```
→ {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"upload","arguments":{"vm":"linuxvm","local_path":"/tmp/test.txt","remote_path":"/opt/utmm/test.txt"}}}
← {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"Upload OK: /opt/utmm/test.txt (1048576 bytes, SHA256: abc123...)"}]}}
```

**download** — file transfer from Guest:
```
→ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"download","arguments":{"vm":"linuxvm","remote_path":"/var/log/app.log","local_path":"./app.log"}}}
← {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"Download OK: ./app.log (4096 bytes)"}]}}
```

**sshpass** — direct SSH to any machine:
```
→ {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"sshpass","arguments":{"host":"linuxvm","user":"root","password":"111","command":"uname -a"}}}
← {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"**ssh root@linuxvm** `uname -a`\\nexit: 0\\n```\\nLinux linuxvm 6.1.0-... aarch64 GNU/Linux\\n```"}]}}
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

### Layered Model

```
┌─────────────────────────────────────────┐
│  Application Layer                       │
│  guest.zig / host.zig / ipc.zig / mcp.zig│
├─────────────────────────────────────────┤
│  Topology Layer                          │
│  lsa.zig (LSA broadcast + node table)    │
├─────────────────────────────────────────┤
│  Transport Layer                         │
│  tcp.zig (Frame protocol + SOCKS5 +     │
│           forwarding + relay)            │
├─────────────────────────────────────────┤
│  Data Pipe Layer                         │
│  dpipe.zig (DuplexPipe + relay engine)   │
│  dpipe_shell.zig (pty ↔ DuplexPipe)     │
│  dpipe_file.zig (file ↔ DuplexPipe)     │
├─────────────────────────────────────────┤
│  Protocol Layer                          │
│  protocol.zig (types, serialization)     │
├─────────────────────────────────────────┤
│  System Service Layer                    │
│  svc.zig / utmmd.zig / shm.zig           │
├─────────────────────────────────────────┤
│  Foundation Layer                        │
│  main.zig / fail.zig / config.zig        │
└─────────────────────────────────────────┘
```

### Run Modes

**Guest mode** (default): utmmd spawns utmm as Guest — UDP LSA broadcast,
TCP listener on port 2121 (SOCKS5 accept from Host + utmm frame protocol +
localhost relay), per-command pty shell. Guest accepts SOCKS5 connections only
from the Host — no CLI entry point for Guest commands.

**Host mode** (`--host`): utmmd spawns utmm as Host — UDP LSA mesh, IPC socket
(`/var/run/utmm.sock` on POSIX, `\\.\pipe\utmm` on Windows), TCP listener on
port 2121 (SOCKS5 accept from Guests + chain-forward to other Guests).
The Host is the only node that relays SOCKS5 between Guests.
CLI/MCP commands talk to Host daemon via IPC.

**MCP mode** (`--mcp`): stdio JSON-RPC server for AI agents. Auto-ensures Host
on first use — no daemon awareness needed.

### How a Command Flows

```
1. CLI: utmm --exec linuxvm "ls -la"
2. CLI → IPC socket (/var/run/utmm.sock) → Host daemon
3. Host → SOCKS5 → Guest TCP :2121
4. Host sends pty_exec_input frame with "ls -la; echo MDELIM:$?\n"
5. Guest: recv frame → dpipe_shell (pty) → fork/exec → pty output
6. Guest → Host: pty_exec_output frames (streaming) + pty_exec_done (exit code)
7. Host → CLI: binary frames via IPC socket → stdout
```

### SOCKS5 Forwarding (Hub-Spoke)

The Host is the central SOCKS5 proxy. Guests accept SOCKS5 from the Host only.
Every Guest's `/etc/hosts` has the Host's IP mapped as `gateway` — from any
Guest, target the Host with `gateway:2121`.

**Dispatch model (Host TCP :2121):**

```
SOCKS5 request arrives:
  target_hostname == self ?
    ├─ target_port == 2121 → OK, utmm internal frame protocol (exec/upload/download)
    └─ target_port != 2121 → OK, connect 127.0.0.1:target_port, relay
  target_hostname != self ?
    └─ lookup hostname→IP in node table
        ├─ found → OK, chain-forward SOCKS5 to target_ip:2121, relay
        └─ not found → REJECT
```

**Examples:**

```bash
# From Host — reach any Guest service
curl --socks5 localhost:2121 http://linuxvm:8080       # web server on linuxvm
curl --socks5 localhost:2121 http://macvm:22            # SSH on macvm

# From a Guest — route through the Host (gateway)
curl --socks5 gateway:2121 http://linuxvm:8080          # Guest → Host → linuxvm
curl --socks5 gateway:2121 http://windowsvm:3389        # Guest → Host → windowsvm

# Local service on the Host itself
curl --socks5 localhost:2121 http://localhost:3000
```

**Key properties:**
- Host TCP :2121 must be reachable from all Guests
- Each forwarded connection runs in its own thread, exits when either side closes
- Works with any SOCKS5-compatible client: `curl`, `wget`, browsers, `git`
- Host name `gateway` is auto-synced to every Guest's `/etc/hosts`

### TCP Wire Protocol (protocol.zig)

All frames: 4-byte BE length prefix (tcp.zig sendFrame/recvFrame), then inner
payload = 1-byte MsgType + type-specific payload.

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| `pty_spawn` | 0x10 | host→guest | Trigger shell spawn |
| `pty_exec_input` | 0x11 | host→guest | Command for shell stdin |
| `pty_exec_output` | 0x15 | guest→host | Shell stdout |
| `pty_exec_done` | 0x16 | guest→host | Command exit code |
| `download_cmd` | 0x14 | host→guest | Download request |
| `upload_cmd` | 0x1b | host→guest | Upload request |
| `upload_result` | 0x17 | guest→host | Upload verification |
| `upgrade_cmd` | 0x1a | host→guest | Push upgrade binary |

Strings: null-terminated. Blobs: 4-byte BE length prefix. Integers: 4-byte BE.
File data: raw TCP streaming (no chunking — TCP provides reliable delivery).

### LSA Mesh Protocol (UDP :2121)

First-byte dispatch: `0x01` = LSA broadcast, `0x03` = MESH_PING, `0x04` = MESH_PONG.

Host broadcasts LSA every 2 seconds. Nodes timeout after 6s (3 missed broadcasts).
LSA node_info is key:value\\n text with fields: hostname, ip, target, version, shell,
conpty, role, status, epoch.

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
| Windows | `cmd.exe` (UTF-8) | `&&` only (SSH does NOT handle `;`) |

### ConPTY Support Matrix

| Platform | PTY/ConPTY | sshpass Mode |
|----------|-----------|--------------|
| Linux | PTY (posix_openpt) | native |
| macOS | PTY (posix_openpt) | native |
| Windows 10 1809+ | ConPTY (CreatePseudoConsole) | full |
| Windows < 17763 | pipe fallback | degraded (stdin-based password input) |

---

## Deployment Guide

### Quick Deploy (all machines)

```bash
utmm --deploy
```

Cross-compiles for all targets, SCPs binaries to each Guest, runs `--install`,
verifies reachability.

### Host (local macOS)

```bash
zig build -Doptimize=ReleaseSafe
sudo zig-out/bin/utmm --host --install
sudo utmm --status    # verify
```

### Linux Guest

```bash
V=$(cat src/ver.txt)
scp zig-out/bin/utmm-aarch64-linux-$V root@linuxvm:/opt/utmm/utmm-new
ssh root@linuxvm '/opt/utmm/utmm-new --install --hostname linuxvm'
```

### macOS Guest

```bash
V=$(cat src/ver.txt)
# If launchctl throttles: kill processes first, then cp + --install
ssh root@macvm 'killall -9 utmm utmmd 2>/dev/null; sleep 1'
scp zig-out/bin/utmm-aarch64-macos-$V root@macvm:/opt/utmm/utmm-new
ssh root@macvm 'cp /opt/utmm/utmm-new /opt/utmm/utmm && /opt/utmm/utmm --install --hostname macvm'
```

### Windows Guest

```bash
V=$(cat src/ver.txt)
# Must kill utmmd before install (AccessDenied if utmmd locks the exe)
ssh Administrator@windowsvm 'taskkill /F /IM utmmd.exe 2>nul'
scp zig-out/bin/utmm-aarch64-windows-$V.exe Administrator@windowsvm:C:/opt/utmm/utmm-new.exe
ssh Administrator@windowsvm 'C:\opt\utmm\utmm-new.exe --install --hostname windowsvm'
```

### Upgrade via Host Push Model

```bash
# 1. Build + copy to serve-dir
utmm --deploy linuxvm

# 2. Push upgrade (Host → Guest via SOCKS5, no SSH needed)
utmm --upgrade linuxvm

# 3. Verify
utmm --status
```

### Verify Deployment

```bash
utmm --status                              # all Guests online + version match
utmm --exec linuxvm "echo OK"             # exec smoke test
utmm --exec macvm "echo OK"
utmm --exec windowsvm "echo OK"
utmm --exec winx64 "echo OK"
utmm --upload /tmp/test.txt linuxvm        # upload test
utmm --download linuxvm /opt/utmm/test.txt /tmp/dl.txt  # download test
```

---

## Troubleshooting

### zig build test hangs on macOS

**Symptom**: `zig build test` never completes, no error output — stuck indefinitely.

**Cause**: Zig 0.16.0 `--listen=-` test protocol has a hang bug on macOS (Darwin 25).

When the build system runs tests via `b.addRunArtifact()`, it injects `--listen=-`
into the test process. This flag makes the test process report results to the build
system over a stdio pipe. The build system blocks waiting for pipe EOF, but on
macOS (kqueue backend) the pipe sometimes fails to close after the test process
exits, causing a deadlock.

For the same reason, `zig build test --summary all` can also hang on macOS CI runners.

**Solution** — this project's `build.zig` already works around the issue:

`build.zig` uses `std.Build.Step.Run.create()` to run test binaries manually,
passing the binary as an argv argument rather than via `addRunArtifact`, thus
avoiding `--listen=-` injection entirely. Bare `zig build test` (without
`--summary all`) outputs directly to the terminal, bypassing the protocol layer.

**If it still hangs**, run the cached test binary directly:
```bash
# Unit tests (with 30s timeout guard)
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/test 2>&1 | tail -5
# Integration tests
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/integration_test 2>&1
```

**CI note**: On GitHub Actions macOS runners, use `zig build test` rather than
`zig build test --summary all` — the latter can trigger the same hang.

### Hostname not resolving for winx64

**Symptom**: `ssh: Could not resolve hostname winx64`.

**Cause**: winx64 is on 192.168.3.x subnet, LSA UDP broadcast may not traverse
subnets. `/etc/hosts` sync only covers VMs on the same broadcast domain.

**Workaround**: Use the IP directly for SSH/scp operations targeting winx64:
```bash
ssh Administrator@192.168.3.108 '<command>'
scp file.exe Administrator@192.168.3.108:C:/opt/utmm/
```
The `--status` / `--exec` / `--upload` / `--download` commands through the Host
work correctly with hostname `winx64` — only direct SSH/scp is affected.

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

### Windows Firewall blocks SOCKS5 BIND / UDP ASSOCIATE

**Symptom**: SOCKS5 BIND second-stage accept times out (60s), external connector
cannot reach the dynamically-assigned TCP port. UDP ASSOCIATE datagrams not
received from remote peers.

**Cause**: Windows Firewall blocks inbound connections to ports not explicitly
allowed. BIND creates a TCP listener on a random port — the firewall drops
inbound SYN packets. UDP ASSOCIATE uses a random UDP port with the same issue.

**Solution — disable Windows Firewall** (recommended for VM/isolated environments):

```
# PowerShell (Administrator)
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Or via Control Panel:
#   Control Panel → Windows Defender Firewall → Turn Windows Defender Firewall on or off
#   → Turn off Windows Defender Firewall (all profiles)
```

**Verification**:
```
netsh advfirewall show allprofiles | findstr State
# Should show: State    OFF
```

**Alternative — add a program rule** (if disabling entirely is not acceptable):
```
netsh advfirewall firewall add rule name="utmm" dir=in action=allow program="C:\opt\utmm\utmm.exe" enable=yes
```

> This is a Windows OS-level restriction, not a code defect. Linux and macOS
> have no equivalent issue — BIND and UDP ASSOCIATE work without firewall
> configuration on those platforms.
>
> SOCKS5 CONNECT (the most common operation: exec, upload, download, forwarding)
> is NOT affected — it uses outbound connections which Windows Firewall allows
> by default.

### pkill -f self-kill (Linux only)

**Symptom**: Remote SSH command `pkill -9 -f utmm` kills the SSH session itself.

**Cause**: `-f` matches the full command line. `bash -c 'pkill -9 -f utmm'`
contains "utmm" so the parent bash is killed before the command completes.

**Fix**: Always use `pkill -9 utmm` (match process name only, no `-f` flag).
