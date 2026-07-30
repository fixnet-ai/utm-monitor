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
- **SOCKS4a mesh forwarding** — every node is a SOCKS4a proxy endpoint on TCP :2121.
  Third-party tools (`curl`, `wget`, browsers) reach any mesh node through any other
  node. No SSH tunnels, no port mapping. `curl --socks4a localhost:2121 http://linuxvm:8080`
  just works.
- **Self-copy install** — single `--install` handles stop→kill→copy→start.
  Upgrade = scp + `--install`. No shell scripts, no package managers.
- **utmmd supervisor** — lightweight daemon manages utmm lifecycle via shared
  memory: heartbeat, crash recovery (exponential backoff), binary upgrade coordination.
- **8 cross-compilation targets** — aarch64/x86_64/x86 × linux-musl/macos/windows.
  Zero runtime dependencies.

## Architecture

```
                         ┌── MCP stdio ← AI Agent
Guest (macvm)    ──TCP──┐
Guest (linuxvm)  ──TCP──┤──→ Host TCP :2121  ──┼── CLI (IPC)
Guest (windows)  ──TCP──┘   (SOCKS4a endpoint)
                         │
Guest ←── LSA broadcast (UDP :2121) ──┘  (auto-discovery + topology)

Every node TCP :2121 = SOCKS4a proxy. Third-party tools connect through any node.
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

# SOCKS4a mesh forwarding — any third-party tool reaches any node
curl --socks4a localhost:2121 http://linuxvm:8080       # web server on linuxvm
curl --socks4a localhost:2121 http://windowsvm:3389     # RDP on windowsvm
git clone --config http.proxy=socks4a://localhost:2121   # clone through mesh
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
