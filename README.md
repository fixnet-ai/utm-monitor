# UTM Monitor

**AI-powered UTM virtual machine management** — auto IP discovery, remote execution, and one-click deploy. Claude Code MCP + Skill integration lets your AI manage VMs through natural language.

Written in Zig 0.16.0. Single binary, dual mode. Zero external dependencies.

## AI agents Integration (MCP + Skill)

The headline feature. After a quick one-time setup, you talk to Claude and it manages your VMs:
| Tool | What Claude can do |
|------|-------------------|
| `vm_status` | Discover all VMs: hostname, IP, OS/arch, version, upgradable? |
| `vm_exec` | Run any shell command on Linux/macOS/Windows VMs |
| `vm_deploy` | Cross-compile + HTTP deploy to VMs, then restart |

## Daily Usage Examples

```
"Check the status of all VMs"
"Run the test suite on linuxvm"
"Deploy the latest build to all VMs"
"Show me the last 50 lines of the log on windowsvm"
"Is macvm running the latest version?"
"What's using CPU on linuxvm?"
"Can linuxvm reach windowsvm over the network?"
"Create a test script on linuxvm and run it"
"Upload a config file to linuxvm"
"Download the app log from windowsvm"
```

## Features

- **Claude Code MCP + Skill** — AI-driven VM management: discover, execute, deploy — all via natural language
- **Auto IP Discovery** — Guest UDP broadcasts hostname+IP every second; Host auto-listens, ignoring VPN/tunnel interfaces
- **Automatic /etc/hosts Sync** — Host updates the hosts file marker block on IP change, so `linuxvm` always resolves
- **Remote Command Execution** — `--exec` sends commands to any VM, auto-adapts macOS/Linux/Windows shell
- **One-Click Build & Deploy** — `--deploy` cross-compiles + deploys via built-in HTTP, zero SSH dependency
- **Auto Version Upgrade** — Host detects Guest version mismatch via UDP broadcast, auto-pushes new binary via HTTP — no Guest polling needed
- **HTTP File Service** — Guest built-in HTTP server (thread-per-connection); file upload/download/exec all via HTTP
- **File Upload/Download** — `--upload` and `--download` commands replace curl for manual file transfers
- **Auto-Start on Boot** — Supports launchd / systemd / Task Scheduler
- **Single Binary, Dual Mode** — Default Guest mode; `--host` switches to Host mode



## One-Time Setup

### 1. Download Host binary (macOS)

```bash
# Download the Host binary from GitHub Releases
sudo curl -fsSL https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.macos \
  -o /usr/local/bin/utm-monitor
sudo chmod +x /usr/local/bin/utm-monitor

# Or use the install script (auto-detects architecture):
# curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

### 2. Download Guest binaries (for auto-deploy)

```bash
sudo mkdir -p /opt/utmm
# 5 binaries cover all scenarios (see MANUAL.md §6.4)
for bin in utmm utmm_arm64 utmm.macos utmm_arm64.macos utmm.exe; do
  sudo curl -fsSL \
    "https://github.com/fixnet-ai/utm-monitor/releases/latest/download/$bin" \
    -o "/opt/utmm/$bin"
done
sudo chmod +x /opt/utmm/*
```

### 3. Download Skill

```bash
cd ~/utm-monitor

# Download Skill (canonical location: utm-vm/SKILL.md)
curl -o utm-vm/SKILL.md \
  https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/utm-vm/SKILL.md

# Create symlink so Claude can find it
mkdir -p .claude/skills
ln -sf ../../utm-vm .claude/skills/utm-vm
```

> No extra files needed — the MCP server is built into the `utm-monitor` binary via `--mcp`. Zero external dependencies.

### 4. Register MCP server with Claude Code

```bash
claude mcp add utm-monitor -- utm-monitor --mcp
```

Then restart Claude Code (or run `/mcp` to reload).

> **Integrated mode (all-in-one):** `claude mcp add utm-monitor -- utm-monitor --host --mcp`
> This runs the full Host + MCP in a single process — no separate Host daemon needed.

### 5. Start the Host

```bash
sudo utm-monitor --host --serve-dir /opt/utmm
```

Keep this running. To auto-start on boot:

```bash
sudo utm-monitor --install
```

### 6. Verify

```bash
# CLI test
utm-monitor --host --status

# MCP is built in — test with a ping
printf 'Content-Length: 50\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n' | utm-monitor --mcp
# → Content-Length: 47
# → {"jsonrpc":"2.0","id":1,"result":{}}
```

Done! Now talk to Claude: "Check the status of all VMs".

> **Alternative: source build** — if you prefer building from source, see [MANUAL.md §2](./MANUAL.md#2-installation) for Zig build instructions.


## Quick Start (CLI only)

```bash
# Download binary
sudo curl -fsSL https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.macos \
  -o /usr/local/bin/utm-monitor && sudo chmod +x /usr/local/bin/utm-monitor

# Guest: run inside a VM
utm-monitor --hostname linuxvm --install    # auto-start on boot
utm-monitor --hostname linuxvm &            # or run immediately

# Host: run on your Mac
sudo utm-monitor --host                     # start listener (auto-upgrades Guests on version mismatch)
utm-monitor --host --status                 # check all VM status
utm-monitor --host --exec linuxvm "uname -a" # run command on VM
utm-monitor --host --deploy                 # build + deploy to all VMs
utm-monitor --host --upload ./f.txt linuxvm  # upload file to VM (no curl)
utm-monitor --host --download linuxvm f.txt ./f.txt  # download file from VM (no curl)
```

## Documentation

| Document | For |
|----------|-----|
| **[MANUAL.md](./MANUAL.md)** | Full manual: install, deploy, daily usage, troubleshooting, MCP setup |
| **[CLAUDE.md](./CLAUDE.md)** | Development guide (build commands, architecture, code style) |
| **[zig-codegen.md](./zig-codegen.md)** | Zig 0.16.0 coding knowledge base |

## Dependencies

- **Precompiled binary**: Zero dependencies — download and run
- **MCP**: Built into the binary via `--mcp` flag. Zero external dependencies.
- **Source build**: [Zig](https://ziglang.org) 0.16.0

## Architecture

```
Guest (linuxvm)  ──UDP broadcast──┐
Guest (macvm)    ──UDP broadcast──┤──→ Host listener (12345)
Guest (windows)  ──UDP broadcast──┘         │
                                            ├─ /etc/hosts sync
                                            ├─ HTTP server (2121)
                                            ├─ IPC (127.0.0.1:12347)
                                            │       ↑
                                            └─ MCP JSON-RPC (stdio)
                                                    ↑
                                            Claude Code
```

## License

MIT
