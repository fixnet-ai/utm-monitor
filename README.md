# UTM Monitor

**Let AI agents manage your VMs.** Auto IP discovery, remote execution, file transfer, and seamless version upgrades — all through natural language via MCP. Built into one zero-dependency Zig binary.

## AI Agent Experience

Once installed, your AI agent gets two tools:

| Tool | What it does |
|------|-------------|
| `vm_status` | Discover all VMs — hostname, IP, OS, arch, version, online status |
| `vm_exec` | Run any shell command on any VM (Linux/macOS/Windows) |

```
"Check the status of all VMs"
"Run the test suite on linuxvm"
"Show me the last 50 lines of the log on windowsvm"
"Deploy the latest build to all VMs"
"Upload the config file to macvm"
"What's the network latency between linuxvm and windowsvm?"
```

Works with any MCP-compatible agent: Claude Code, Codex, Gemini CLI, and others.

## One-Time Setup

### 1. Install on Host (your Mac)

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

This downloads all platform binaries to `/opt/utmm/` and creates the `utmm` command.

### 2. Register with your AI agent

Host daemon serves MCP over HTTP on port 2121. Configure your agent to connect via `streamableHttp`:

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

> CLI: `claude mcp add utm-monitor --transport streamableHttp http://127.0.0.1:2121/mcp`

### 3. Start the Host

```bash
sudo utmm --host --install   # auto-start on boot
sudo utmm --host             # or run immediately
```

### 4. Install on each VM (Guest)

No internet needed — Guests fetch everything from the Host over the network:

```bash
# Linux VM (as root)
curl http://$(ip route | grep default | awk '{print $3}'):2121/bin/install.sh | sh -s -- --guest --hostname linuxvm

# macOS VM (as root)
GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
curl "http://$GW:2121/bin/install.sh" | sh -s -- --guest --hostname macvm

# Windows VM (as Administrator)
curl -o install.bat "http://<gateway>:2121/bin/install.bat" && install.bat --guest --hostname windowsvm
```

Done. Ask your AI agent: "Check the status of all VMs".

## CLI Quick Reference

For when you're in a terminal without an agent:

```bash
utmm --status                          # all VM status
utmm --exec linuxvm "uname -a"         # run a command
utmm --upload ./file.txt linuxvm       # upload a file
utmm --download linuxvm file.txt ./    # download a file
```

## How It Works

```
Guest VMs ──WebSocket (binary frames)──→ Host HTTP :2121 ──→ /etc/hosts sync
                ↑                                        ├──→ MCP /mcp (JSON-RPC) ← AI Agent
                └── HTTP POST /announce (backward compat) ├──→ GET /bin/ (static files)
                                                          └──→ /exec, /upload, /download (CLI)
```

- **Single port**: Everything on 2121 — WebSocket, HTTP REST, MCP, static files. No UDP broadcast, no separate MCP port.
- **WebSocket push**: Guest maintains persistent WS connection; Host pushes commands in real-time via binary frames. No polling.
- **Binary protocol**: exec, upload, download use raw binary WebSocket frames — zero encoding overhead, no base64.
- **Auto-discovery**: Guest connects to default gateway (UTM Host = gateway); Host always knows Guest IP from WS connection.
- **Zero deps**: No Python, Node.js, SSH, or external libraries — one binary, everywhere.

## Docs

| For | Read |
|-----|------|
| Using with AI agents, troubleshooting | **[SKILL.md](./utm-vm/SKILL.md)** |
| Full reference manual | **[MANUAL.md](./utm-vm/MANUAL.md)** |
| Building from source, development | **[CLAUDE.md](./CLAUDE.md)** |

## License

MIT
