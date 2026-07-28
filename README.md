# UTM Monitor

![UTM Monitor](WHATIAM.png)

**Remote debugging sidekick — VMs and physical machines, one command away.**

Check processes, read logs, attach debuggers, profile performance on any machine
running the Guest agent. Virtual or bare-metal — Linux, macOS, Windows. No SSH,
no IP tracking, no context switching. Just `utmm --exec linuxvm "..."` and you're in.

**MCP integration** (`utmm --mcp`) lets AI coding agents do the same — debug across
platforms through natural language. No daemon required — auto-ensure boots the Host
if needed.

**Mesh network & Zero config** ties everything together under the hood. Guests
auto-discover the Host over the local network — no fixed IPs, no DNS, no manual
wiring. A Linux VM on a bridge, a Windows laptop on Wi-Fi, a Raspberry Pi on
Ethernet — they all show up alongside the Host in `utmm --status` with role, version,
status, and last-seen time.

## AI Agent Experience

Same capabilities, natural language. `utmm --mcp` provides five MCP tools over stdio
for Claude Code and other agents — the complete CLI command set exposed through the
MCP protocol:

| Tool | Description |
|------|-------------|
| `vm_status` | List all nodes (Host + Guests): hostname, role, IP, OS/arch, version, status, shell type |
| `vm_exec` | Execute commands via TCP per-command connection. Each exec opens a fresh pty session |
| `vm_ping` | Ping a guest over the mesh — test connectivity and measure RTT |
| `vm_upload` | Upload a file from Host to Guest via TCP/SOCKS4 (SHA256 verified) |
| `vm_download` | Download a file from Guest to Host via TCP/SOCKS4 (SHA256 verified) |

Example prompts your AI agent can handle:
- "Check the status of all my machines"
- "linuxvm is slow — check CPU, memory, and disk IO"
- "Attach lldb to my program on macvm, set a breakpoint at main, and show the backtrace"
- "Upload the new build to all machines and restart the service"
- "Download the core dump from linuxvm and analyze the crash"

## CLI Quick Start

```bash
# Ping any machine over the mesh — test connectivity
utmm --ping linuxvm     # {"hostname":"linuxvm","mac":"16:a0:6c:...","rtt_ms":10}

# Peek inside any machine — instantly
utmm --exec linuxvm "ps aux | grep myapp"
utmm --exec macvm "tail -50 /var/log/system.log"
utmm --exec windowsvm "tasklist | findstr myapp"

# Debug crashes — attach debugger, set breakpoints, get backtraces
utmm --exec linuxvm "gdb -batch -ex 'bt full' -p $(pgrep myapp)"
utmm --exec macvm "lldb -o 'bt all' -o quit -p $(pgrep myapp)"

# Each exec opens a fresh pty — no state persists across calls
utmm --exec linuxvm "cd /opt/myapp && source ./venv/bin/activate && pip list"

# Check health across all machines with one command
utmm --status      # Host + all guests: role, version, status, last seen
utmm --verify      # Health matrix: status + ping + exec echo per guest

# One-shot deploy to all machines
utmm --deploy      # Build + SCP + SSH install to all guests
utmm --deploy linuxvm  # Deploy single guest

# File transfer
utmm --upload build.zip linuxvm
utmm --download linuxvm core ./core.dump
```

## One-Time Setup

The install script detects your OS and architecture, downloads the latest
release, and installs `utmm` as a system service (auto-start on boot). It
prompts for hostname and mode (Host or Guest) — no manual steps needed.

Root / Administrator privileges are required.

**POSIX (Linux / macOS):**

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sudo sh
```

**Windows (Administrator terminal):**

```batch
curl -fsSLo %TEMP%\install.bat https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.bat && %TEMP%\install.bat
```

**Offline install:** download `utmm.zip` from the
[latest release](https://github.com/fixnet-ai/utm-monitor/releases/latest),
extract to the target machine, then run the bundled `install.sh` or `install.bat`.

**Manual install** (no automation): see the comments at the top of
[install.sh](install.sh) for the few manual commands needed.

**Register with AI Agent** — use the Claude Code CLI (recommended):

```bash
claude mcp add --scope user utm-monitor -- sudo -n /opt/utmm/utmm --mcp
```

> **Note:** `--scope user` registers at user level in `~/.claude.json`, available
> across all projects. Default `--scope local` is project-only.
> Use `claude mcp list` to verify.
> See [mcp.json.example](mcp.json.example) for manual config and troubleshooting.

## CLI Reference

```bash
utmm --status                      # All nodes at a glance (Host + guests, role/status/version/last seen)
utmm --verify                      # Health check matrix: status + ping + exec per guest
utmm --ping linuxvm                # Ping a guest (Host→Guest mesh ping, returns JSON)
utmm --exec linuxvm "uname -a"     # Command (streaming output, no timeout)
utmm --exec linuxvm "gdb ..."      # Attach debugger
utmm --exec macvm "lldb ..."       # Same on macOS
utmm --exec windowsvm "dir"        # Windows commands too
utmm --upload build.zip linuxvm    # Push a build (raw binary)
utmm --download linuxvm core ./    # Pull a core dump (streaming binary)
utmm --deploy [<vm>]              # Build + SCP + SSH deploy to all guests (or single)
utmm --version                     # Print version
```

## How It Works

The Host manages Guests through **TCP per-command connections** via SOCKS4a proxy
(UTM network). Each exec, upload, or download opens a fresh TCP connection,
completes the operation, and closes — no persistent tunnels. LSA (Link State
Advertisement) broadcasts over UDP port 2121 handle topology discovery and
version detection. CLI commands and MCP talk to the Host through a local IPC
socket (`/var/run/utmm.sock` on POSIX, named pipe on Windows) — no HTTP.

```
Guest (linuxvm)      ──TCP/SOCKS4──┐
Guest (macvm)        ──TCP/SOCKS4──┤──→ Host ── IPC socket ── CLI (--status, --exec, --ping)
Guest (windowsvm)    ──TCP/SOCKS4──┤          ── Binary serve (TCP upgrade_req)
                         ┌── LSA broadcast (UDP:2121) ──┘  (topology + version detection)
                         │
AI Agent ── utmm --mcp (stdio) ──→ auto-ensure → IPC socket
```

- **Streaming exec**: output flows in real time through TCP connection via IPC socket,
  with exit code sent as binary trailer. No JSON wrapping, no timeout.
  Upload/download use direct TCP streaming (no chunking needed — TCP provides
  reliable ordered delivery).
- **Self-copy install**: binary copies itself to canonical path `/opt/utmm/utmm` (POSIX)
  or `C:\opt\utmm\utmm.exe` (Windows). utmmd supervisor manages utmm's lifecycle
  (spawn, monitor, crash recovery) via shared memory heartbeat.
  `--install` = unconditional force overwrite. Upgrade = scp new binary + `--install`.
  Zero shell commands.
- **Guest-initiated auto-upgrade** (v0.12.0+): Guest detects Host version change via
  LSA broadcast, downloads new binary through TCP connection, and signals utmmd
  via shared memory to restart with the new binary. Host never pushes upgrades.
- **Single binary, zero dependencies**: no Node.js, Python, SSH, or curl at runtime
- **Single UDP port 2121** for LSA mesh networking.
  MCP and CLI use local IPC socket (stdio for MCP, Unix domain socket for CLI) — no TCP/HTTP ports needed.
- **Auto IP tracking**: Host syncs Guest IPs to `/etc/hosts` — hostnames always resolve
- **Cross-platform**: macOS, Linux, Windows — both Host and Guest (aarch64, x86_64, x86)
- **Per-command fresh shell**: each exec opens a new pty session — no cd/export
  persistence across commands. Simpler model matching independent TCP connections.
- **TCP reliable transport**: frame protocol with 1-byte type + payload over TCP/SOCKS4a.
  Per-command connections — no persistent tunnels, no cross-thread shared state.

## Upgrade

**`--deploy` (fastest, v0.11.18+):** cross-compile, SCP, and SSH install in one command.
```bash
sudo utmm --deploy                # All guests
sudo utmm --deploy linuxvm        # Single guest
```
Requires `sshpass` on the Host. Validates binary type (ELF/Mach-O/PE) before copying.

**Online machines:** re-run the install script — it upgrades in place.

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sudo sh
```

**Guest auto-upgrade (hands-free):** Guests detect a Host version change via
LSA broadcast, download the new binary through TCP, and signal
utmmd to restart with the new binary. No human intervention needed.

**Offline/manual:** download `utmm.zip` from the
[latest release](https://github.com/fixnet-ai/utm-monitor/releases/latest),
extract, and run `./utmm --install --hostname <name>`.

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](.claude/skills/utmm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](.claude/skills/utmm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [mcp.json.example](mcp.json.example) | MCP configuration with Claude Code install guide |

## License

MIT
