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
Ethernet — they all show up in one flat `utmm --status`.

## AI Agent Experience

Same capabilities, natural language. `utmm --mcp` provides five MCP tools over stdio
for Claude Code and other agents — the complete CLI command set exposed through the
MCP protocol:

| Tool | Description |
|------|-------------|
| `vm_status` | List all machines: hostname, IP, OS/arch, version, shell type |
| `vm_exec` | Execute commands. Shell session persists — cd, export survive across calls |
| `vm_ping` | Ping a guest over the mesh — test connectivity and measure RTT |
| `vm_upload` | Upload a file from Host to Guest via KCP tunnel (SHA256 verified) |
| `vm_download` | Download a file from Guest to Host via KCP tunnel (SHA256 verified) |

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

# Shell state persists — cd, export, venv survive across calls
utmm --exec linuxvm "cd /opt/myapp && source venv/bin/activate && pip list"
utmm --exec linuxvm "pwd"     # /opt/myapp — still there

# Check health across all machines with one command
utmm --status

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

**Register with AI Agent** — add to your MCP config (`~/.claude/mcp.json` or `.mcp.json`):

```json
{
  "mcpServers": {
    "utmm": {
      "command": "sudo",
      "args": ["/opt/utmm/utmm", "--mcp"]
    }
  }
}
```

Or use the CLI: `claude mcp add utmm -- sudo /opt/utmm/utmm --mcp`

## CLI Reference

```bash
utmm --status                      # All machines at a glance
utmm --ping linuxvm                # Ping a guest (Host→Guest mesh ping, returns JSON)
utmm --exec linuxvm "uname -a"     # Command (streaming output, no timeout)
utmm --exec linuxvm "gdb ..."      # Attach debugger
utmm --exec macvm "lldb ..."       # Same on macOS
utmm --exec windowsvm "dir"        # Windows commands too
utmm --upload build.zip linuxvm    # Push a build (raw binary)
utmm --download linuxvm core ./    # Pull a core dump (streaming binary)
utmm --version                     # Print version
```

## How It Works

The Host manages Guests through a **mesh network over UDP port 2121**. Each Guest
maintains a persistent KCP tunnel to the Host. LSA (Link State Advertisement)
broadcasts handle topology discovery and version detection. CLI commands and MCP
talk to the Host through a local IPC socket (`/var/run/utmm.sock` on POSIX,
named pipe on Windows) — no HTTP.

```
Guest (linuxvm)      ──KCP/Mesh──┐
Guest (macvm)        ──KCP/Mesh──┤──→ Host ── IPC socket ── CLI (--status, --exec, --ping)
Guest (windowsvm)    ──KCP/Mesh──┤          ── Static files (/bin/ via KCP upgrade_req)
Guest (raspigw, LAN) ──KCP/Mesh──┘
                         ┌── LSA broadcast discovery ───┘   (topology + version detection)
                         │
AI Agent ── utmm --mcp (stdio) ──→ auto-ensure → IPC socket
```

- **Streaming exec**: output flows in real time through KCP tunnel with `x-exit-code`
  trailer. No JSON wrapping, no timeout. Upload/download use chunked stream
  (1200B MSS-aligned blocks, one per KCP segment — no fragmentation).
- **Self-copy install**: binary copies itself to `/opt/utmm/utmm` (POSIX) or
  `C:\opt\utmm\utmm.exe` (Windows). `--install` = unconditional force overwrite.
  Upgrade = scp new binary + `--install`. Zero shell commands.
- **Guest-initiated auto-upgrade** (v0.11.14+): Guest detects Host version change via
  LSA broadcast, downloads new binary through KCP tunnel, and runs `--install
  --hostname <name>` to complete deployment. Host never pushes upgrades.
- **Single binary, zero dependencies**: no Node.js, Python, SSH, or curl at runtime
- **Single port**: 2121 for mesh networking (UDP only — LSA + KCP tunnel).
  MCP and CLI use local IPC socket (stdio/stdin for MCP, Unix domain socket for CLI) — no port needed.
- **Auto IP tracking**: Host syncs Guest IPs to `/etc/hosts` — hostnames always resolve
- **Cross-platform**: macOS, Linux, Windows — both Host and Guest (aarch64, x86_64, x86)
- **Persistent shell session**: shell state survives across `--exec` calls (pty model)
- **Reliable transport**: KCP ARQ protocol matching C reference — sliding window,
  congestion control, fast retransmit, window probing

## Upgrade

**Online machines:** re-run the install script — it upgrades in place.

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sudo sh
```

**Guest auto-upgrade (hands-free):** Guests detect a Host version change via
LSA broadcast, download the new binary through the KCP tunnel, and run
`--install --hostname <name>` automatically. No human intervention needed.

**Offline/manual:** download `utmm.zip` from the
[latest release](https://github.com/fixnet-ai/utm-monitor/releases/latest),
extract, and run `./utmm --install --hostname <name>`.

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](skills/utmm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](skills/utmm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [mcp.json.example](mcp.json.example) | MCP configuration with Claude Code install guide |

## License

MIT
