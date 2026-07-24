---
name: utm-vm
description: >
  Use this skill whenever the user needs to interact with UTM virtual machines —
  checking VM status, running commands on VMs, testing code cross-platform,
  deploying binaries to VMs, debugging issues inside a VM, or any cross-VM
  coordination. This skill gives you structured access via the utmm MCP
  server. Trigger on ANY mention of: VM names (linuxvm, macvm, windowsvm, ubuntu),
  "VM", "UTM", "virtual machine", "guest", "cross-platform", "deploy to", "test on
  Linux/Windows", "run on the VM", "check the VM", "/etc/hosts", IP changes,
  or remote execution on a local VM.
---

# UTM VM Management via utmm

You have structured access to three UTM virtual machines through the `utmm`
MCP server. This lets you run commands, deploy code, and check status on Linux,
macOS, and Windows VMs — without needing to know their IP addresses. The Host
auto-syncs VM IPs to `/etc/hosts`, so hostnames like `linuxvm` always resolve.

## Available VMs

| Hostname | OS | Arch | Credentials | App Path |
|----------|-----|------|-------------|----------|
| `linuxvm` | Linux | aarch64 | root / 111 | `/opt/utmm/` |
| `macvm` | macOS | aarch64 | root / 111 | `/opt/utmm/` |
| `windowsvm` | Windows | aarch64 | Administrator / 111 | `C:\opt\utmm\` |
| `winx64` | Windows | x86_64 | Administrator / 111 | `C:\opt\utmm\` |

> **SSH access**: `Administrator@192.168.3.x` (winx64, key auth).

## Two MCP Tools

### 1. `vm_status` — List all VMs and their state

**Always call this FIRST** in any VM workflow. It tells you:
- Which VMs are online, their IP, OS/arch, MAC address
- **Which shell to use** (`shell` field — detected at Guest startup from `$SHELL`):
  - macOS/Linux: the user's configured `$SHELL` (e.g. `/bin/zsh`, `/bin/bash`). Falls back to `/bin/sh`.
  - Windows: `cmd.exe`
- The utmm version running on each VM

> **Persistent shell session**: Each Guest runs a persistent shell via pty.
> Commands execute in the same shell session — `cd /tmp` then `pwd` shows `/tmp`.
> `export FOO=bar` then `echo $FOO` shows `bar`. The shell lives for the WebSocket
> connection lifetime.

If `vm_status` returns "No VMs currently online", the other tools cannot work.
Ask the user whether the VMs are booted and the Host is running.

### 2. `vm_exec(vm, command)` — Execute a shell command on a VM

**Always check `vm_status` first** to see the `shell` field for each VM, then use the correct syntax:

| Shell | OS | Syntax Rules |
|-------|-----|-------------|
| `/bin/zsh` | macOS | zsh syntax: `&&`, `\|`, `$VAR`, single quotes preferred |
| `/bin/bash` | Linux | bash syntax: `&&`, `\|`, `$VAR`, single quotes preferred |
| `/bin/sh` | Linux (fallback) | POSIX sh: `&&`, `\|`, `$VAR`, single quotes preferred |
| `cmd.exe` | Windows | `cmd /c` syntax: `&` not `&&`, `%VAR%`, no `grep`/`awk` |

**Key patterns:**

| Task | Example |
|------|---------|
| OS info | `vm_exec("linuxvm", "uname -a")` |
| List files | `vm_exec("linuxvm", "ls -la /opt/")` |
| Check process | `vm_exec("linuxvm", "ps aux \| grep utm")` |
| Read logs | `vm_exec("linuxvm", "tail -50 /var/log/utmm.log")` |
| Install packages | `vm_exec("linuxvm", "apt-get install -y htop")` |
| Restart service | `vm_exec("linuxvm", "systemctl restart utmm-guest")` |
| Run a script | `vm_exec("linuxvm", "cd /opt && bash -c '...'")` |
| Write a file | `vm_exec("linuxvm", "cat > /opt/test.sh << 'EOF'\n...\nEOF")` |
| Check connectivity | `vm_exec("linuxvm", "ping -c 2 macvm")` |
| Windows dir | `vm_exec("windowsvm", "dir C:\\opt\\")` |
| Windows tasklist | `vm_exec("windowsvm", "tasklist \| findstr utm")` |
| macOS version | `vm_exec("macvm", "sw_vers")` |

**Shell persistence — cd and export work across calls:**

| Task | Example |
|------|---------|
| Navigate and verify | `vm_exec("linuxvm", "cd /tmp; pwd")` shows `/tmp` |
| Set env and use | `vm_exec("linuxvm", "export FOO=bar; echo $FOO")` shows `bar` |
| Multi-step workflow | `cd /opt/utmm` then `ls` then `./utmm --version` — all in same shell |

**Shell escaping notes:**
- Pipe characters `|` may need escaping depending on context — prefer single-line commands
- For multi-line scripts, use heredoc: `cat > /tmp/s.sh << 'EOF'\n...\nEOF\nsh /tmp/s.sh`
- Windows: backslashes in paths work, forward slashes also work in cmd.exe
- Single quotes are safer than double quotes for shell commands

## Core Workflows

### Workflow A: Quick health check
```
vm_status → see which VMs are online, their versions, IPs
```

### Workflow B: Cross-platform testing
```
1. vm_status                         → confirm targets online, check versions
2. vm_exec("linuxvm", "./test.sh")   → run tests
3. Repeat 2 for macvm, windowsvm
```

### Workflow C: Debugging a VM problem
```
1. vm_status                            → confirm online, note version
2. vm_exec("linuxvm", "ps aux")         → check running processes
3. vm_exec("linuxvm", "cat /var/log/...") → read relevant logs
4. vm_exec("linuxvm", "...")            → verify the fix
```

### Workflow D: Initial setup (first time or after VM rebuild)

**Deploy Host first, then Guests.**

```
1. Host: curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
2. Host: sudo utmm --host --install  (installs + starts as LaunchDaemon automatically)
3. For each Guest VM, run ONE command (no internet needed — from Host HTTP):
   - Linux/macOS: curl http://<gateway>:2121/bin/install.sh | sh -s -- --guest --hostname <name>
   - Windows: find gateway, download install.bat from http://<gateway>:2121/bin/install.bat, run with --guest
4. vm_status → verify all VMs appear online
```

The Guest script auto-detects arch/OS, downloads the correct binary from the Host, creates
symlinks, installs the auto-start service, and starts the Guest — all in one command.
No internet access needed on Guest VMs.

### Workflow E: Multi-VM network test
```
1. vm_exec("linuxvm", "ping -c 2 macvm")    → can linux reach mac?
2. vm_exec("windowsvm", "ping -n 2 linuxvm") → can windows reach linux?
```

## Prerequisites & Troubleshooting

**The Host must be running for everything:**
```bash
sudo utmm --host          # macOS / Linux
utmm --host               # Windows (Administrator)
```

**MCP connects via HTTP** — The Host daemon serves MCP JSON-RPC over HTTP (streamableHttp) on `127.0.0.1:2121/mcp`. This is the same port as the HTTP server — everything on 2121. Configure your agent's `mcp.json`:

```json
{"mcpServers": {"utm-monitor": {"type": "streamableHttp", "url": "http://127.0.0.1:2121/mcp"}}}
# Or use claude mcp add: claude mcp add utm-monitor --transport streamableHttp http://127.0.0.1:2121/mcp
```

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| "No VMs online" | VMs not booted, or guest utmm not running | Check VMs are booted; verify `utmm` is running inside each |
| "GuestNotFound" for a VM | VM is offline or name mismatch | Run `vm_status` to see which VMs are actually online |
| WebSocket connection failed | Guest can't reach Host gateway | Guest auto-detects Host via default gateway; override with `--host-ip` |
| MCP connection refused | Host daemon not running or old version | `sudo utmm --host` |
| Command hangs or produces no output | Guest disconnected mid-command or shell dead | Check `vm_status`; use `--kick` then retry |

**Fallback:** If MCP tools are unavailable, you can use the CLI directly:
```bash
utmm --status
utmm --exec linuxvm "uname -a"
```

## Host Paths

| Item | macOS | Linux | Windows |
|------|-------|-------|---------|
| Host binary (symlink) | `/usr/local/bin/utmm` → `/opt/utmm/utmm` | `/usr/local/bin/utmm` → `/opt/utmm/utmm` | `C:\opt\utmm\utmm.exe` |
| Host binary (actual) | `/opt/utmm/utmm` → `/opt/utmm/utmm-aarch64-macos` | `/opt/utmm/utmm` → `/opt/utmm/utmm-x86_64-linux` | `C:\opt\utmm\utmm.exe` |
| Guest binary | `/opt/utmm/utmm` | `/opt/utmm/utmm` | `C:\opt\utmm\utmm.exe` |
| All platform binaries | `/opt/utmm/utmm-*` (8 binaries) | `/opt/utmm/utmm-*` (8 binaries) | `C:\opt\utmm\utmm-*.exe` |
| Host service config | `/Library/LaunchDaemons/com.utmm.host.plist` | `/etc/systemd/system/utmm-host.service` | Windows Service: `UTM-Monitor-Host` |
| Guest service config | `/Library/LaunchDaemons/com.utmm.guest.plist` | `/etc/systemd/system/utmm-guest.service` | Windows Service: `UTM-Monitor-Guest` |
| Host log | `/var/log/utmm-host.log` | journald (`journalctl -u utmm-host`) | `C:\opt\utmm\utmm-host.log` |
| Guest log | `/var/log/utmm-guest.log` | journald (`journalctl -u utmm-guest`) | `C:\opt\utmm\utmm-guest.log` |
| Serve directory (HTTP) | `/opt/utmm/` | `/opt/utmm/` | `C:\opt\utmm\` | |

## Bootstrap Troubleshooting

### Guest can't download from Host (connection timeout)

**Symptom**: The install script fetches successfully but the download within the script fails with a connection timeout.

**Cause**: The Guest is on a UTM bridge network that can't route to the Host's physical NIC IP. Example: macvm on bridge100 (192.168.64.0/24) cannot reach the Host's en0 IP (192.168.3.130).

**Solution**: Use the bridge gateway IP directly:
```bash
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl -fsSL "http://$GATEWAY:2121/bin/utmm-aarch64-linux" -o /opt/utmm/utmm
chmod +x /opt/utmm/utmm
/opt/utmm/utmm --hostname linuxvm &
```

## Limitations

- `vm_exec` is non-interactive — you cannot run commands that require TTY input (nano, top, etc.)
- VM IPs can change on reboot — always check `vm_status` first, don't cache IPs
- Windows cmd.exe has different escaping rules than bash — test simple commands first
- Commands stream output in real time — no fixed timeout, but if a command hangs, use `--kick` to force shell restart

### Q: `--download` fails with "Guest not found" but the Guest is online
**A**: This happens when you use a full path like `/opt/utmm/file.txt` instead of just the filename `file.txt`. Use just the basename:
```
# Wrong:
utmm --download linuxvm /opt/utmm/app.log ./app.log
# Correct:
utmm --download linuxvm app.log ./app.log
```
To download files from other directories, use `--exec` to copy them to `/opt/utmm/` first.

> Upload/download use raw binary HTTP with `x-vm`/`x-path` headers —
> no JSON wrapping. Verify integrity with MD5 after transfer.

## Deployment FAQs (from bare-metal validation)

### Q: `zig-out/bin/utmm` is the wrong architecture after cross-compilation
**A**: `zig build` always overwrites `zig-out/bin/utmm` with the LAST target built. After cross-compiling all targets, rebuild native last: `zig build -Doptimize=ReleaseSafe`. Or use the specifically-named output file (e.g., `zig-out/bin/utmm-aarch64-macos`) for the correct architecture.

### Q: macOS Guest: `ip route` command not found
**A**: macOS uses `route -n get default`, not `ip route`. The install.sh auto-detects the correct command per OS.

### Q: Windows: SSH+PowerShell quoting is complex
**A**: Use the batch installer (`install.bat`) instead — no PowerShell dependency, no quoting issues. Example:
```batch
curl -o install.bat "http://<gateway>:2121/bin/install.bat" && install.bat --guest --hostname windowsvm
```

### Q: Does utmm support 32-bit x86?
**A**: Yes, since v0.2.5, 32-bit x86-linux-musl builds and passes tests. x86-windows has a pre-existing linker issue unrelated to utmm code. All modern UTM VMs are aarch64 or x86_64, so 32-bit is a bonus, not a requirement.

## Reference Manual

See [MANUAL.md](MANUAL.md) for the complete reference: build & install, architecture design, protocol specification, CLI reference, auto-upgrade workflow, MCP integration, platform-specific notes, and troubleshooting.
