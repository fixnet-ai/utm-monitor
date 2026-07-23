# UTM Monitor

**Let AI agents manage your VMs.** Auto IP discovery, remote execution with shell
persistence, file transfer, auto-upgrade — all through natural language via MCP.
One zero-dependency Zig binary.

**v0.7.0: Zero-shell auto-upgrade** — Guests detect new Host versions via UDP broadcast
and self-upgrade through a separate `utmm-old` process. No external shell commands:
`fork()+execve()` on POSIX, `std.process.spawn` on Windows. Service stop/kill/download/
replace/start — all in pure Zig.

## AI Agent Experience

Two MCP tools for AI coding agents (Claude Code, etc.):

| Tool | Description |
|------|-------------|
| `vm_status` | List all VMs: hostname, IP, OS/arch, version, shell type |
| `vm_exec` | Execute commands on a VM. Shell session persists — cd, export survive |

Example prompts:
- "Check the status of all my VMs"
- "Run `ls /opt/utmm` on linuxvm"
- "Check disk space on all VMs"
- "Is the macvm service running?"
- "Deploy v0.7.0 to all VMs and verify auto-upgrade"

## VM Access Reference

| VM | Hostname | IP | SSH | utmm |
|----|----------|-----|-----|------|
| macOS | macvm | 192.168.64.4 | root@192.168.64.4 (pass: 111) | utmm --exec macvm |
| Linux | linuxvm | 192.168.64.2 | root@192.168.64.2 (pass: 111) | utmm --exec linuxvm |
| Windows ARM | windowsvm | 192.168.65.2 | Administrator@192.168.65.2 (pass: 111) | utmm --exec windowsvm |
| Windows x64 | winx64 | 192.168.3.x | Administrator@192.168.3.x (key auth) | utmm --exec winx64 |

## One-Time Setup

### 1. Install on Host (macOS where UTM runs)

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

This installs to `/opt/utmm/` and starts the Host HTTP server on port 2121.

### 2. Register with AI Agent

Add to your MCP config (`~/.claude/mcp.json` or `.mcp.json` in project):

```json
{
  "mcpServers": {
    "utm-monitor": {
      "type": "streamableHttp",
      "url": "http://127.0.0.1:2121/mcp"
    }
  }
}
```

### 3. Start Host

```bash
sudo utmm --host
# Or auto-start on boot:
sudo utmm --host --install
```

### 4. Install on Each VM Guest

On each VM, copy the binary to `/opt/utmm/` (or `C:\opt\utmm\` on Windows)
and run:

```bash
utmm --install
```

The Guest auto-discovers the Host via the default gateway.

## CLI Quick Reference

```bash
utmm --status                  # All VM status (UDP broadcast discovery)
utmm --exec linuxvm "uname -a" # Run command (pty shell, cd/export persist)
utmm --exec windowsvm "dir"    # Windows commands auto-use cmd.exe
utmm --upload file.txt linuxvm # Upload file
utmm --download linuxvm path ./local  # Download file
utmm --kick linuxvm            # Kill shell, force reconnect
utmm --gen-init linux          # Generate auto-start script
utmm --version                 # Print version
```

## How It Works

```
                         ┌── UDP broadcast discovery (--status, any LAN machine)
                         │   + periodic version broadcast (auto-upgrade trigger)
                         │
Guest (linuxvm)  ──WebSocket──┐
Guest (macvm)    ──WebSocket──┤──→ Host HTTP :2121 ── MCP /mcp (AI agents)
Guest (windows)  ──WebSocket──┘                      ── CLI (--status, --exec)
Guest (winx64)──WebSocket──┘                      ── Static files (/bin/ auto-upgrade)
```

**v0.7.0 auto-upgrade**: Host broadcasts version via UDP every 60s. Guest UDP listener
detects version mismatch, spawns `utmm-old` process which: stops service → kills old
processes → HTTP downloads new binary → replaces on disk → starts service → exits.
Zero external shell commands, pure Zig throughout.

**v0.6.0 UDP broadcast discovery**: `utmm --status` sends subnet-directed UDP
broadcasts to :2121. Each Guest runs a UDP listener that responds with its
hostname, IP, OS, version, and shell type. Works from any machine on the LAN.

**v0.5.0 pty model**: Each guest WebSocket connection gets a persistent shell
session. Commands run in the same shell — `cd /tmp` then `pwd` shows `/tmp`.
`export FOO=bar` then `echo $FOO` shows `bar`.

- **Zero dependencies**: pure Zig, no Node.js/Python/SSH/curl
- **Single port**: HTTP + WebSocket + MCP + binary serving all on 2121
- **Auto IP tracking**: /etc/hosts kept up to date
- **Cross-platform**: macOS, Linux, Windows guests (aarch64 + x86_64)
- **Auto-upgrade**: Host serves new binaries, guests self-upgrade via UDP version detection

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](utm-vm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](utm-vm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [CLAUDE.md](CLAUDE.md) | Developer guide (build, architecture, Zig patterns) |

## License

MIT
