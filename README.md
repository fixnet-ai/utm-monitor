# UTM Monitor

**Your remote debugging sidekick.** One command to peek inside any VM — check
processes, read logs, attach debuggers, profile performance. No SSH, no IP
tracking, no context switching. Just `utmm --exec linuxvm "..."` and you're in.

MCP integration lets AI coding agents do the same — debug across Linux, macOS,
and Windows VMs through natural language.

**v0.7.0: Zero-shell auto-upgrade** — Guests detect new Host versions via UDP broadcast
and self-upgrade through a separate `utmm-old` process. No external shell commands:
`fork()+execve()` on POSIX, `std.process.spawn` on Windows. One binary, zero dependencies.


## AI Agent Experience

Same capabilities, natural language. Two MCP tools for Claude Code and other agents:

| Tool | Description |
|------|-------------|
| `vm_status` | List all VMs: hostname, IP, OS/arch, version, shell type |
| `vm_exec` | Execute commands on a VM. Shell session persists — cd, export survive |

Example prompts your AI agent can handle:
- "Check the status of all my VMs"
- "linuxvm is slow — check CPU, memory, and disk IO"
- "Attach lldb to my program on macvm, set a breakpoint at main, and show the backtrace"
- "Is the utmm service running on all VMs?"
- "My app crashed on windowsvm — find the crash dump and analyze it"
- "Upload the new build to all VMs and restart the service"
- "Profile my app on linuxvm with perf, show me the hot functions"

## What Can You Do With command line

```
# Peek inside any VM — instantly
utmm --exec linuxvm "ps aux | grep myapp"
utmm --exec macvm "tail -50 /var/log/system.log"
utmm --exec windowsvm "tasklist | findstr myapp"

# Debug crashes — attach debugger, set breakpoints, get backtraces
utmm --exec linuxvm "gdb -batch -ex 'bt full' -p $(pgrep myapp)"
utmm --exec macvm "lldb -o 'bt all' -o quit -p $(pgrep myapp)"

# Profile performance across platforms — one tool, same workflow
utmm --exec linuxvm "perf stat myapp"
utmm --exec macvm "sample myapp 1 -file /tmp/out.txt"
utmm --exec windowsvm "typeperf \"\\Process(myapp)\\%% Processor Time\" -sc 5"

# Shell state persists — cd, export, venv all survive across calls
utmm --exec linuxvm "cd /opt/myapp && source venv/bin/activate && pip list"
utmm --exec linuxvm "pwd"     # /opt/myapp — still there
utmm --exec linuxvm "env"     # venv still activated

# Check health across all VMs with one command
utmm --status
```


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

The Guest auto-discovers the Host via the default gateway. After that, all
debugging happens through `utmm --exec` — no more SSH into individual VMs.

## CLI Quick Reference

```bash
utmm --status                      # All VMs at a glance
utmm --exec linuxvm "uname -a"     # One-off command
utmm --exec linuxvm "gdb ..."      # Attach debugger
utmm --exec macvm "lldb ..."       # Same on macOS
utmm --exec windowsvm "dir"        # Windows commands work too
utmm --upload build.zip linuxvm    # Push a new build
utmm --download linuxvm core ./    # Pull a core dump
utmm --kick linuxvm                # Force shell restart
utmm --version                     # Print version
```

## How It Works

```
                         ┌── UDP broadcast discovery (--status, any LAN machine)
                         │   + periodic version broadcast (auto-upgrade trigger)
                         │
Guest (linuxvm)  ──WebSocket──┐
Guest (macvm)    ──WebSocket──┤──→ Host HTTP :2121 ── MCP /mcp (AI agents)
Guest (windows)  ──WebSocket──┘                      ── CLI (--status, --exec)
Guest (winx64)   ──WebSocket──┘                      ── Static files (/bin/ auto-upgrade)
```

**v0.7.0 auto-upgrade**: Host broadcasts version via UDP every 60s. Guest UDP listener
detects version mismatch, spawns `utmm-old` process which: stops service, kills old
processes, HTTP downloads new binary, replaces on disk, starts service, exits.
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
