# UTM Monitor Manual — v0.15.x

Complete reference for CLI commands, MCP protocol, architecture, platform
differences, and deployment.

## Table of Contents

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

### Host Options

| Option | Description |
|--------|-------------|
| `--port PORT` | Service port (default 2121) |
| `--hosts-file PATH` | hosts file path (default /etc/hosts) |
| `--serve-dir PATH` | Binary serve directory for upgrade push |
| `--marker TAG` | Marker comment text (default "UTM-MONITOR") |
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

Returns 6 tools: `status`, `exec`, `ping`, `upload`, `download`, `sshpass`.
Each tool has `name`, `description`, and `inputSchema` (JSON Schema).

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
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"**UTM Virtual Machines:**\n- **linuxvm** (guest) — aarch64-linux-musl | IP: 192.168.64.6 | MAC: 16:a0:6c:... | v0.14.7 | shell: /bin/bash | status: serving\n..."}]}}
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
TCP listener on port 2121 (SOCKS5 accept + utmm frame protocol + chained
forwarding), per-command pty shell. No CLI entry point for guest commands
— all interaction goes through Host.

**Host mode** (`--host`): utmmd spawns utmm as Host — UDP LSA mesh, IPC socket
(`/var/run/utmm.sock` on POSIX, `\\.\pipe\utmm` on Windows), TCP listener on
port 2121 (SOCKS5 accept + forwarding, same dispatch logic as Guest),
TCP SOCKS5 connections to Guests. CLI/MCP commands talk to Host daemon via IPC.

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

### SOCKS5 Mesh Forwarding

Every utmm node (Host and Guest) is a peer SOCKS5 proxy endpoint on TCP :2121.
Third-party tools connect through **any** node to reach **any other** node in the
mesh — no SSH tunnels, no port mapping, no manual routing.

**Chained forwarding model:**

```
SOCKS5 request arrives on TCP :2121:
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
# Host → linuxvm:8080 web server (chained: Host → linuxvm:2121 → localhost:8080)
curl --socks5 localhost:2121 http://linuxvm:8080

# linuxvm → macvm:22 SSH (chained: linuxvm → Host → macvm:2121 → localhost:22)
# (from linuxvm) curl --socks5 localhost:2121 http://macvm:22

# Direct local service access on the same node
curl --socks5 localhost:2121 http://localhost:3000   # local dev server

# Git clone through mesh to a VM-hosted repo
git clone --config http.proxy=socks5://localhost:2121 \
    http://linuxvm:8080/repo.git
```

**Key properties:**
- Only port 2121 needs to be reachable between mesh nodes
- Each forwarded connection runs in its own thread, exits when either side closes
- Works with any SOCKS5-compatible client: `curl`, `wget`, browsers, `git`
- Zero configuration — hostname→IP lookup uses the existing LSA node table
- No new CLI flags, no new ports, no new files

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

### Quick Deploy (all VMs)

```bash
utmm --deploy
```

This cross-compiles for all targets, SCPs binaries to each Guest, runs `--install`,
and verifies.

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

**Cause**: Zig 0.16.0 的 `--listen=-` 测试协议在 macOS (Darwin 25) 存在 hang bug。

Zig 构建系统通过 `b.addRunArtifact()` 运行测试时，自动给测试进程注入 `--listen=-` 参数。
该参数让测试进程通过 stdio 管道与构建系统通信上报结果。构建系统会阻塞等待管道 EOF，
但某些情况下（尤其 macOS kqueue 后端）测试进程已退出而管道未正确关闭，导致死锁。

同样的原因，`zig build test --summary all` 在 CI 的 macOS runner 上也可能 hang。

**解决方案** — 本项目 `build.zig` 已绕过此问题：

`build.zig` 使用 `std.Build.Step.Run.create()` 手动运行测试二进制，
以 argv 参数形式传入而非通过 `addRunArtifact`，从而绕过 `--listen=-` 协议注入。
裸 `zig build test`（不加 `--summary all`）直接输出到终端，不走协议层。

**如果仍遇到 hang**，直接运行缓存的测试二进制：
```bash
# 单元测试（带 30s 超时防护）
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/test 2>&1 | tail -5
# 集成测试
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/integration_test 2>&1
```

**CI 注意事项**：GitHub Actions macOS runner 上应使用 `zig build test` 而非
`zig build test --summary all`，后者可能触发相同 hang。

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

### pkill -f自杀 (Linux only)

**Symptom**: Remote SSH command `pkill -9 -f utmm` kills the SSH session itself.

**Cause**: `-f` matches the full command line. `bash -c 'pkill -9 -f utmm'`
contains "utmm" so the parent bash is killed before the command completes.

**Fix**: Always use `pkill -9 utmm` (match process name only, no `-f` flag).
