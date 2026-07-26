# UTM Monitor

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

Same capabilities, natural language. `utmm --mcp` provides two MCP tools over stdio
for Claude Code and other agents:

| Tool | Description |
|------|-------------|
| `vm_status` | List all machines: hostname, IP, OS/arch, version, shell type |
| `vm_exec` | Execute commands. Shell session persists — cd, export survive across calls |

Example prompts your AI agent can handle:
- "Check the status of all my machines"
- "linuxvm is slow — check CPU, memory, and disk IO"
- "Attach lldb to my program on macvm, set a breakpoint at main, and show the backtrace"
- "Upload the new build to all machines and restart the service"

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

## One-Time Setup

### 1. Install Host Service

```bash
# Build for host platform, SCP to host machine
zig build
scp zig-out/bin/utmm root@<host>:/tmp/utmm

# Force install as system auto-start service
ssh root@<host> "chmod +x /tmp/utmm && /tmp/utmm --host --install"
```

Service auto-starts on boot. Binary self-copies to `/opt/utmm/utmm` (POSIX) or
`C:\opt\utmm\utmm.exe` (Windows).

### 2. Install Guest Service

```bash
# Build for target, SCP to guest
zig build -Dtarget=aarch64-linux-musl
scp zig-out/bin/utmm-aarch64-linux root@<guest>:/tmp/utmm

# Force install with hostname
ssh root@<guest> "chmod +x /tmp/utmm && /tmp/utmm --install --hostname myvm"
```

Guest auto-discovers Host via default gateway (UTM VMs) or `--host-ip` (physical machines).

### 3. Register with AI Agent

Add to your MCP config (`~/.claude/mcp.json` or `.mcp.json` in project):

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
Guest (macvm)        ──KCP/Mesh──┤──→ Host HTTP :2121 ── CLI (--status, --exec)
Guest (windowsvm)    ──KCP/Mesh──┤                      ── Static files (/bin/)
Guest (raspigw, LAN) ──KCP/Mesh──┘
                         ┌── LSA broadcast discovery ───┘   (topology + version detection)
                         │
AI Agent ── utmm --mcp (stdio) ──→ auto-ensure → HTTP 127.0.0.1:2121
```

- **Streaming exec**: output flows in real time via HTTP chunked encoding with
  `x-exit-code` trailer. No JSON wrapping, no timeout. Upload/download use chunked
  stream (8KB blocks) over KCP tunnel.
- **Self-copy install**: binary copies itself to `/opt/utmm/utmm` (POSIX) or
  `C:\opt\utmm\utmm.exe` (Windows). `--install` = unconditional force overwrite.
  Upgrade = scp new binary + `--install`. Zero shell commands.
- **Single binary, zero dependencies**: no Node.js, Python, SSH, or curl at runtime
- **Single port**: 2121 for CLI + static file serving (TCP) and mesh networking (UDP)
  MCP uses stdio (utmm --mcp), not HTTP — no port needed
- **Auto IP tracking**: Host syncs Guest IPs to `/etc/hosts` — hostnames always resolve
- **Cross-platform**: macOS, Linux, Windows — both Host and Guest (aarch64, x86_64, x86)
- **Persistent shell session**: shell state survives across `--exec` calls (pty model)
- **Reliable transport**: KCP ARQ protocol matching C reference — sliding window,
  congestion control, fast retransmit, window probing

## Upgrade

```bash
# Build new binary → SCP to VM → force reinstall
scp zig-out/bin/utmm-aarch64-linux root@<vm>:/tmp/utmm-new
ssh root@<vm> "chmod +x /tmp/utmm-new && /tmp/utmm-new --install --hostname <name>"
```

The force install flow: stop service → kill processes → self-copy to canonical
path → overwrite service config → start. No KCP download, no utmm-old process.

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](skills/utmm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](skills/utmm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [mcp.json.example](mcp.json.example) | MCP configuration with Claude Code install guide |

## License

MIT
