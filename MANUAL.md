# UTM Monitor Manual — v0.14.x

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
| `--socks-proxy PORT` | SOCKS4a proxy port (0=disabled, e.g. 1080) |
| `--marker TAG` | Marker comment text (default "UTM-MONITOR") |
| `--config PATH` | Config file path |
| `--log-file PATH` | Log file path |
| `--save-config` | Save current parameters to config file |

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

## Connectivity Fabric

utmm 在底层创建了一个通用互联层，将所有系统工具接入 utmm 通信体系：

```
你的工具（ssh, curl, scp, 浏览器, IDE...）
│
├─ 名字解析：/etc/hosts（LSA 自动同步）
│   linuxvm → 192.168.64.6
│   macvm   → 192.168.65.4
│
└─ 连通：SOCKS4a 代理（localhost:1080）
    ├─ VM 网格（linuxvm, macvm, windowsvm）
    ├─ 局域网（internal-server.local）
    └─ 互联网（example.com）
```

### /etc/hosts 同步

**工作机制**：
- **Host 端**：LSA 状态变化时触发 `/etc/hosts` 同步。通过标记块（marker block）范围
  替换实现原子更新，不影响文件中其他内容。写入流程：tmp file → rename（POSIX 原子操作）。
- **Guest 端**：30 秒周期同步（自身 + gateway），同时接收 LSA 状态变化事件触发即时更新。
- **标记格式**：`# UTM-MONITOR-BEGIN` / `# UTM-MONITOR-END`
- **条目格式**：`<IP> <fqdn> <hostname>`，其中 FQDN 为 `<hostname>.target.utm`

**设计目的**：让所有系统工具（ssh、scp、curl、ping、浏览器、IDE）都能直接用 hostname
访问 VM，无需手动配置 DNS 或记住 IP 地址。这是将 utmm 从单一 CLI 工具扩展为通用
通信基础设施的关键设计。

```bash
# /etc/hosts 中的实际条目（Host 自动维护）：
# === UTM-MONITOR-BEGIN (auto-managed by utmm) ===
192.168.64.6	linuxvm.target.utm linuxvm
192.168.65.4	macvm.target.utm macvm
192.168.64.3	windowsvm.target.utm windowsvm
# === UTM-MONITOR-END ===
```

### SOCKS4a 代理

`--socks-proxy PORT` 启动 SOCKS4a 代理监听器，将 Host 变成通用网络网关。
SOCKS4a 协议的核心优势：目标地址是 **hostname**（不是 IP），让 Host 代理能覆盖
VM 网格 + 局域网 + 互联网的全部目标。

**命令行**：
```bash
sudo utmm --host --socks-proxy 1080     # 启动 Host + SOCKS4a 代理
```

**主机名解析优先级**：GuestTable（mesh VM 实时 IP）→ `/etc/hosts` → 系统 DNS

**连接策略**：
- GuestTable 命中 → Host 直接 TCP 连接 Guest IP:port
- 非 Guest 目标 → Host 直接 TCP 连接目标（/etc/hosts 或 DNS 解析后）

**安全性**：代理仅绑定 127.0.0.1，不可从网络访问。外部机器无法连接到代理端口。

**工具配置**：

```bash
# curl：通过代理访问任何目标
curl --socks4a localhost:1080 http://linuxvm:8080/metrics
curl --socks4a localhost:1080 https://example.com

# SSH：通过 ProxyCommand（~/.ssh/config）
# Host *.target.utm
#     ProxyCommand nc -X 4 -x localhost:1080 %h %p
ssh root@linuxvm.target.utm

# 浏览器：配置 SOCKS4 代理为 localhost:1080
# Firefox: Settings → Network Settings → SOCKS Host: localhost, Port: 1080, SOCKS v4
# 然后直接在地址栏输入 http://linuxvm:8080/

# git：通过代理 clone
git -c http.proxy=socks4a://localhost:1080 clone http://git-server.local/repo.git
```

### 跨子网支持

对于不在同一子网的机器（如 winx64），`/etc/hosts` 条目仍然会被写入（LSA 通过
`--peer-mesh` 转发），curl/浏览器等工具通过 SOCKS4a 代理访问：

```bash
# 在 Host 代理可达的情况下，跨子网访问透明：
curl --socks4a localhost:1080 http://winx64:8080/
```

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
│  tcp.zig (Frame protocol + SOCKS4)       │
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
TCP listener on port 2121, per-command pty shell. No CLI entry point for guest
commands — all interaction goes through Host.

**Host mode** (`--host`): utmmd spawns utmm as Host — UDP LSA mesh, IPC socket
(`/var/run/utmm.sock` on POSIX, `\\.\pipe\utmm` on Windows), TCP SOCKS4a
connections to Guests. CLI/MCP commands talk to Host daemon via IPC.

**MCP mode** (`--mcp`): stdio JSON-RPC server for AI agents. Auto-ensures Host
on first use — no daemon awareness needed.

### How a Command Flows

```
1. CLI: utmm --exec linuxvm "ls -la"
2. CLI → IPC socket (/var/run/utmm.sock) → Host daemon
3. Host → SOCKS4a → Guest TCP :2121
4. Host sends pty_exec_input frame with "ls -la; echo MDELIM:$?\n"
5. Guest: recv frame → dpipe_shell (pty) → fork/exec → pty output
6. Guest → Host: pty_exec_output frames (streaming) + pty_exec_done (exit code)
7. Host → CLI: binary frames via IPC socket → stdout
```

### TCP Wire Protocol (protocol.zig)

All frames: 1-byte type + type-specific payload.

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

# 2. Push upgrade (Host → Guest via SOCKS4a, no SSH needed)
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

**Symptom**: `zig build test` never completes, no error output.

**Cause**: Zig 0.16.0 `--listen=-` test runner protocol bug on macOS.

**Workaround** — run the compiled test binary directly:
```bash
# Unit tests
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/test 2>&1 | tail -5
# Integration tests
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/integration_test 2>&1
```

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
