# UTM Monitor

**AI-powered UTM virtual machine management** — auto IP discovery, remote execution, remote debug..., and one-click deploy. Claude Code MCP + Skill integration lets your AI manage VMs through natural language.

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

### 1. Download & Install (macOS / Linux)

```bash
# One-command install: downloads utmm.zip, extracts to /opt/utmm/, creates symlinks
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

The install script:
- Downloads `utmm.zip` from GitHub Releases (contains all 8 platform binaries)
- Extracts to `/opt/utmm/` (configurable via `INSTALL_DIR`)
- Creates `/opt/utmm/utmm` → `utmm-{arch}-{os}` symlink for the Host
- Creates `/usr/local/bin/utmm` → `/opt/utmm/utmm` convenience symlink

### 2. Download Skill

```bash
cd ~/utmm

# Download Skill files (SKILL.md + MANUAL.md reference)
mkdir -p utm-vm
curl -o utm-vm/SKILL.md \
  https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/utm-vm/SKILL.md
curl -o utm-vm/MANUAL.md \
  https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/utm-vm/MANUAL.md

# Create symlink so Claude can find it
mkdir -p .claude/skills
ln -sf ../../utm-vm .claude/skills/utm-vm
```

> No extra files needed — the MCP server is built into the `utmm` binary via `--mcp`. Zero external dependencies.

### 3. Register MCP server with Claude Code

```bash
claude mcp add utmm -- utmm --mcp
```

Then restart Claude Code (or run `/mcp` to reload).

> **Integrated mode (all-in-one):** `claude mcp add utmm -- utmm --host --mcp`
> This runs the full Host + MCP in a single process — no separate Host daemon needed.

### 4. Start the Host

```bash
sudo utmm --host
```

Keep this running. The Host serves binaries from `/opt/utmm/` by default (all 8 platform binaries are already there from install). To auto-start on boot:

```bash
sudo utmm --install
```

### 5. Verify

```bash
# CLI test
utmm --host --status

# MCP is built in — test with a ping
printf 'Content-Length: 50\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n' | utmm --mcp
# → Content-Length: 47
# → {"jsonrpc":"2.0","id":1,"result":{}}
```

Done! Now talk to Claude: "Check the status of all VMs".

> **Alternative: source build** — if you prefer building from source, see [MANUAL.md §2](./utm-vm/MANUAL.md#2-installation) for Zig build instructions.


## Quick Start (CLI only)

```bash
# ─── Host (your Mac) — always deploy Host first ───

# One-command install (downloads utmm.zip, extracts to /opt/utmm/, creates symlinks)
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh

# Start the Host (needs sudo for /etc/hosts sync)
sudo utmm --host --install    # auto-start on boot
sudo utmm --host              # or run immediately

# ─── Guest (inside each VM) — one command per Guest ───
# No internet needed — everything comes from Host HTTP at gateway IP

# Linux / macOS Guest (find gateway first, then curl from Host HTTP)
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl "http://$GATEWAY:2121/bin/install.sh" | sh -s -- --guest --hostname linuxvm

# Windows Guest (PowerShell as Administrator)
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").NextHop | Select -First 1
iwr "http://${gw}:2121/bin/install.ps1" -OutFile install.ps1
.\install.ps1 -Guest -Hostname windowsvm

# ─── Verify ───
utmm --host --status                 # check all VM status
utmm --host --exec linuxvm "uname -a" # run command on VM
utmm --host --deploy                 # build + deploy to all VMs
utmm --host --upload ./f.txt linuxvm  # upload file to VM (no curl)
utmm --host --download linuxvm f.txt ./f.txt  # download file from VM (no curl)
```

## Documentation

| Document | For |
|----------|-----|
| **[MANUAL.md](./utm-vm/MANUAL.md)** | Full manual: install, deploy, daily usage, troubleshooting, MCP setup |
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
