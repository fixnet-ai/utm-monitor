# UTM Monitor

**Let AI agents manage your VMs.** Auto IP discovery, remote execution with shell
persistence, file transfer — all through natural language via MCP. One zero-dependency
Zig binary.

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
      "type": "http",
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
utmm --status                  # All VM status
utmm --exec linuxvm "uname -a" # Run command (pty shell, cd/export persist)
utmm --exec windowsvm "dir"    # Windows commands auto-use cmd.exe
utmm --upload file.txt linuxvm # Upload file
utmm --download linuxvm /path ./local  # Download file
utmm --kick linuxvm            # Kill shell, force reconnect
```

## How It Works

```
Guest (linuxvm)  ──WebSocket──┐
Guest (macvm)    ──WebSocket──┤──→ Host HTTP :2121 ── MCP /mcp (AI agents)
Guest (windows)  ──WebSocket──┘                      ── CLI (--status, --exec)
```

**v0.5.0 pty model**: Each guest gets a persistent shell session. Commands run
in the same shell — `cd /tmp` then `pwd` shows `/tmp`. `export FOO=bar` then
`echo $FOO` shows `bar`.

- **Zero dependencies**: pure Zig, no Node.js/Python/SSH/curl
- **Single port**: HTTP + WebSocket + MCP all on 2121
- **Auto IP tracking**: /etc/hosts kept up to date
- **Cross-platform**: macOS, Linux, Windows guests
- **Auto-upgrade**: Host serves new binaries, guests self-upgrade

## Docs

| Document | For |
|----------|-----|
| [SKILL.md](utm-vm/SKILL.md) | AI agent instructions (MCP tool details, workflows) |
| [MANUAL.md](utm-vm/MANUAL.md) | Full user manual (architecture, deployment, troubleshooting) |
| [CLAUDE.md](CLAUDE.md) | Developer guide (build, architecture, Zig patterns) |

## License

MIT
