# UTM Monitor

![UTM Monitor](WHATIAM.png)

**Remote debugging sidekick — VMs and physical machines, one command away.**

Single Zig binary, dual mode (Guest agent + Host controller). Check processes,
read logs, transfer files on any machine — Linux, macOS, Windows. No SSH daemon
required at runtime. AI agents get the same capabilities through MCP stdio.

## MCP Integration

`utmm --mcp` provides six tools over stdio JSON-RPC 2.0 for AI coding agents.

| Tool | Description |
|------|-------------|
| `status` | List all nodes: hostname, role, IP, OS/arch, MAC, version, status, shell, ConPTY |
| `exec` | Execute a shell command on any Guest via per-command pty |
| `ping` | Ping a Guest over the mesh network and measure RTT |
| `upload` | Upload file from Host to Guest (TCP/SOCKS4, SHA256 verified) |
| `download` | Download file from Guest to Host (TCP/SOCKS4, SHA256 verified) |
| `sshpass` | Non-interactive SSH password auth — direct shell access to any machine. Works on **Linux, macOS, and Windows** (ConPTY dynamic loading + pipe fallback). Bootstrap, recovery, and pre-install scenarios when the Guest daemon is down or not yet installed. |

Example prompts your AI agent can handle:
- "Check the status of all my machines"
- "linuxvm is slow — check CPU, memory, and disk IO"
- "Upload the new build to all Guests and restart the service"
- "Download the core dump from linuxvm and analyze the crash"

See [MANUAL.md](MANUAL.md#mcp-protocol) for the full MCP protocol reference
(message format, request/response examples).

## Core Capabilities

- **Streaming exec** — per-command pty shell on any Guest. Real-time output,
  exit code, no timeout. `MDELIM` markers handled transparently.
- **File transfer** — upload/download with SHA256 verification and atomic writes.
- **sshpass built-in** — non-interactive SSH password auth, 100% CLI-compatible
  with the standalone `sshpass` tool. POSIX PTY + Windows ConPTY (dynamic load
  with pipe fallback on older Windows).
- **MCP stdio** — AI agents control machines via `utmm --mcp`. Six tools:
  `status`, `exec`, `ping`, `upload`, `download`, `sshpass`. Auto-ensures Host on first use.
- **LSA mesh zero-config** — Guests auto-discover Host over the local network.
  No fixed IPs, no DNS. `/etc/hosts` kept in sync automatically.
- **Self-copy install** — single `--install` handles stop→kill→copy→start.
  Upgrade = scp + `--install`. No shell scripts, no package managers.
- **utmmd supervisor** — lightweight daemon manages utmm lifecycle via shared
  memory: heartbeat, crash recovery (exponential backoff), binary upgrade coordination.
- **8 cross-compilation targets** — aarch64/x86_64/x86 × linux-musl/macos/windows.
  Zero runtime dependencies.
- **Connectivity Fabric** — `/etc/hosts` sync + SOCKS4a proxy turn the Host into a
  universal gateway. All system tools (ssh, scp, curl, browser, IDE) automatically
  resolve Guest hostnames and reach any target — VM mesh, LAN, internet — through
  the Host proxy.

## Connectivity Fabric

utmm 在底层创建了一个通用互联层，让**你所有的工具**都能无缝访问整个网络：

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

Host 守护进程在 LSA 状态变化时自动将 Guest hostname→IP 映射写入 `/etc/hosts`。
Guest 端也有 30 秒周期同步。标记块（`# UTM-MONITOR-BEGIN` / `# UTM-MONITOR-END`）
原子替换，不影响文件中其他内容。

**效果**：所有系统工具（ssh、scp、curl、ping、浏览器、IDE）都能直接用 hostname
访问 VM，无需手动配置 DNS 或记住 IP。

```bash
# /etc/hosts 中的条目（Host 自动维护）：
# === UTM-MONITOR-BEGIN (auto-managed by utmm) ===
192.168.64.6	linuxvm.target.utm linuxvm
192.168.65.4	macvm.target.utm macvm
192.168.64.3	windowsvm.target.utm windowsvm
# === UTM-MONITOR-END ===

# 然后你可以：
ssh root@linuxvm           # 直接用 hostname
curl http://macvm:8080     # 无需知道 IP
```

### SOCKS4a 代理

`utmm --host --socks-proxy 1080` 启动 SOCKS4a 代理，将 Host 变成通用网络网关。
外部工具配置代理后，可通过 Host 到达任何目标。

**主机名解析优先级**：GuestTable（mesh VM 实时 IP）→ `/etc/hosts` → 系统 DNS

```bash
# 启动 Host 并开启 SOCKS4a 代理
sudo utmm --host --socks-proxy 1080

# 通过代理访问 VM（hostname 自动解析为 Guest IP）
curl --socks4a localhost:1080 http://linuxvm:8080/metrics

# 通过代理访问局域网机器
curl --socks4a localhost:1080 http://db-server.local:5432

# 通过代理访问互联网
curl --socks4a localhost:1080 https://example.com

# SSH 通过代理（~/.ssh/config）：
# Host *.target.utm
#     ProxyCommand nc -X 4 -x localhost:1080 %h %p
ssh root@linuxvm.target.utm
```

**安全性**：代理仅绑定 127.0.0.1，不可从网络访问。

## Architecture

```
                         ┌── MCP stdio ← AI Agent
Guest (macvm)    ──TCP──┐
Guest (linuxvm)  ──TCP──┤──→ Host IPC socket ──┼── CLI
Guest (windows)  ──TCP──┘
                         │   (LSA auto-discovery)
Guest ←── LSA broadcast (UDP :2121) ──┘

Each machine: utmmd ──shm── utmm    (supervisor + worker)
```

## CLI Quick Start

```bash
# Check health across all machines
utmm --status      # Host + all Guests: hostname, role, IP, target, version, status, shell, ConPTY

# Execute commands on any Guest (pty shell, streaming output)
utmm --exec linuxvm "ps aux | grep myapp"
utmm --exec macvm "tail -50 /var/log/system.log"
utmm --exec windowsvm "tasklist | findstr myapp"

# File transfer
utmm --upload build.zip linuxvm
utmm --download linuxvm /var/log/app.log ./app.log

# Non-interactive SSH (built-in sshpass)
utmm sshpass -p '111' ssh root@linuxvm 'uname -a'
utmm sshpass -f ~/.ssh/pass ssh user@server 'uptime'      # password from file
utmm sshpass -e ssh admin@host 'cmd'                        # password from SSHPASS env

# Push upgrade to Guest
utmm --upgrade linuxvm

# One-shot deploy to all machines
utmm --deploy
utmm --deploy linuxvm

# Mesh ping
utmm --ping linuxvm
```

> **ConPTY**: On Windows, `--status` shows `conpty:yes/no` for each node.
> Windows < 10.0.17763 lacks the ConPTY API — sshpass falls back to pipe mode.
> POSIX always reports `conpty:yes`. This is critical for MCP SSH operations.


## Install

Download the latest `utmm.zip` from [GitHub Releases](https://github.com/fixnet-ai/utm-monitor/releases),
unzip, and run `--install`:

```bash
# POSIX (Linux/macOS)
unzip utmm.zip
sudo ./utmm-<target>-<version> --install --hostname <name>

# Windows (PowerShell as Administrator)
Expand-Archive utmm.zip
C:\opt\utmm\utmm-<target>-<version>.exe --install --hostname <name>
```

Install is a single atomic operation: stop → kill → copy to canonical path →
install system service → start. No shell scripts, no package managers.

## Build

```bash
zig build                          # Native debug build → zig-out/bin/utmm
zig build -Doptimize=ReleaseSafe   # ReleaseSafe
zig build test                     # Unit tests
zig build test-integration         # Integration tests

# Cross-compile (ReleaseSafe required for deployment)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows
# ... plus x86_64 and x86 variants for all three platforms (8 targets total)
```

**Requirements**: Zig 0.16.0, macOS build host (other hosts may work, untested).

## Full Reference

See [MANUAL.md](MANUAL.md) for the complete CLI reference, MCP protocol
messages, architecture deep-dive, platform differences, and deployment guide.
