# UTM Monitor

**Remote debugging sidekick — VMs and physical machines, one command away.**

Check processes, read logs, attach debuggers, profile performance on any machine
running the Guest agent. Virtual or bare-metal — Linux, macOS, Windows. No SSH,
no IP tracking, no context switching. Just `utmm --exec linuxvm "..."` and you're in.

**MCP integration** - lets AI coding agents do the same — debug across platforms through
natural language.

**Mesh network & Zero config** - ties everything together Under the hood. Guests auto-discover the
Host over the local network — no fixed IPs, no DNS, no manual wiring. A Linux VM on a
bridge, a Windows laptop on Wi-Fi, a Raspberry Pi on Ethernet — they all show up in one
flat `utmm --status`. From there, `utmm --exec <hostname> "..."` reaches any machine
instantly. When a bug surfaces on a specific device, you don't SSH around hunting for IPs
or reconnecting to different networks — you just type the hostname and attach a debugger.

## AI Agent Experience

Same capabilities, natural language. Two MCP tools for Claude Code and other agents:

| Tool | Description |
|------|-------------|
| `vm_status` | List all machines: hostname, IP, OS/arch, version, shell type |
| `vm_exec` | Execute commands. Shell session persists — cd, export survive across calls |

Example prompts your AI agent can handle:
- "Check the status of all my machines"
- "linuxvm is slow — check CPU, memory, and disk IO"
- "Attach lldb to my program on macvm, set a breakpoint at main, and show the backtrace"
- "Is the utmm service running on all machines?"
- "My app crashed on windowsvm — find the crash dump and analyze it"
- "Upload the new build to all machines and restart the service"
- "Profile my app on linux with perf, show me the hot functions"

## CLI Quick Start

```bash
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

## VM or Physical Machine — Same Workflow

Unlike tools that only work inside hypervisors, utmm monitors anything that runs
the Guest agent. A Raspberry Pi on your desk, a Linux server in the rack, a
Windows laptop on Wi-Fi, and three UTM VMs on your Mac — all appear in
`utmm --status`, all respond to `utmm --exec`.

| Machine | Hostname | OS | Connection |
|---------|----------|-----|------------|
| macOS VM | macvm | aarch64-macos | UTM bridge |
| Linux VM | linuxvm | aarch64-linux | UTM bridge |
| Windows VM | windowsvm | aarch64-windows | UTM bridge |
| Windows laptop | winx64 | x86_64-windows | LAN Wi-Fi |
| Raspberry Pi | raspigw | aarch64-linux | LAN Ethernet |

Guest auto-discovers Host via default gateway. LAN machines just need the binary
and `utmm --install`. UTM VMs get the binary from the Host directly:
`curl http://<gateway>:2121/bin/install.sh | sh -s -- --guest --hostname myvm`.

## One-Time Setup

### 1. Install on Host

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

This installs to `/opt/utmm/` and creates `/usr/local/bin/utmm`.

### 2. Start Host

```bash
# macOS / Linux
sudo utmm --host
sudo utmm --host --install   # Auto-start on boot

# Windows (Administrator terminal)
utmm --host
utmm --host --install        # Auto-start on boot (Windows Service)
```

> **Linux note:** Port 2121 < 1024 requires root or `sudo setcap cap_net_bind_service=+ep $(which utmm)`.
> **Windows note:** The installer adds a firewall rule automatically. On first run, confirm the UAC prompt.

### 3. Register with AI Agent

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

### 4. Install on Each Guest

**UTM VM** (no internet needed — downloads from Host at gateway IP):
```bash
curl http://<gateway>:2121/bin/install.sh | sh -s -- --guest --hostname myvm
```

**Physical machine** (needs internet or pre-copied binary):
```bash
# Option A: copy binary + install manually
scp utmm-aarch64-linux pi@raspigw:/opt/utmm/
ssh pi@raspigw "sudo chmod +x /opt/utmm/utmm && sudo utmm --install --hostname raspigw"

# Option B: if the machine can reach GitHub
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh -s -- --guest --hostname raspigw
```

The Guest auto-discovers the Host via the default gateway. After setup, all
debugging happens through `utmm --exec` — no more SSH into individual machines.

## CLI Reference

```bash
utmm --status                      # All machines at a glance
utmm --exec linuxvm "uname -a"     # Command (streaming output, no timeout)
utmm --exec linuxvm "gdb ..."      # Attach debugger
utmm --exec macvm "lldb ..."       # Same on macOS
utmm --exec windowsvm "dir"        # Windows commands too
utmm --upload build.zip linuxvm    # Push a build (raw binary)
utmm --download linuxvm core ./    # Pull a core dump (streaming binary)
utmm --version                     # Print version
```

## How It Works

The Host runs an HTTP server on port 2121. Each Guest maintains a persistent
Mesh + KCP tunnel to the Host via UDP. LSA (Link State Advertisement) broadcasts
handle topology discovery. The Host distributes commands to Guests and streams
results back — HTTP handlers send frames through KCP tunnels, pty sessions execute.

```
Guest (linuxvm)      ──KCP/Mesh──┐
Guest (macvm)        ──KCP/Mesh──┤──→ Host HTTP :2121 ── MCP /mcp (AI agents)
Guest (windowsvm)    ──KCP/Mesh──┤                      ── CLI (--status, --exec)
Guest (raspigw, LAN) ──KCP/Mesh──┘                      ── Static files (/bin/)
                         ┌── LSA broadcast discovery ───┘   (topology + auto-upgrade trigger)
```

- **Streaming exec**: output flows in real time via HTTP chunked encoding with
  `x-exit-code` trailer. No JSON wrapping, no timeout. Upload/download use chunked
  stream (8KB blocks) over KCP tunnel.
- **Auto-upgrade**: Host broadcasts version in LSA every 2s. Guest detects
  mismatch, spawns `utmm-old` process to stop→download 8KB chunks via KCP→SHA256
  verify→replace→restart. Zero shell commands.
- **Single binary, zero dependencies**: no Node.js, Python, SSH, or curl at runtime
- **Single port number**: 2121 for MCP + CLI + static file serving (TCP) and mesh networking (UDP)
- **Auto IP tracking**: Host syncs Guest IPs to `/etc/hosts` — hostnames always resolve
- **Cross-platform**: macOS, Linux, Windows — both Host and Guest (aarch64, x86_64, x86 32-bit)
- **Persistent shell session**: shell state survives across `--exec` calls (pty model)
- **Reliable transport**: KCP ARQ protocol matching C reference — sliding window,
  congestion control, fast retransmit, window probing

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](utm-vm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](utm-vm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [mcp.json.example](mcp.json.example) | MCP configuration with Claude Code install guide |

## License

MIT
