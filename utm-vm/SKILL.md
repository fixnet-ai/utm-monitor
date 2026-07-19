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
| `linuxvm` | Linux | aarch64 | root / 111 | `/opt/` |
| `macvm` | macOS | aarch64 | root / 111 | `/opt/` |
| `windowsvm` | Windows | aarch64 | Administrator / 111 | `C:\opt\` |

## Two MCP Tools

### 1. `vm_status` — List all VMs and their state

**Always call this FIRST** in any VM workflow. It tells you:
- Which VMs are online, their IP, OS/arch, MAC address
- **Which shell to use** (`shell` field — read from `$SHELL` at Guest startup):
  - macOS/Linux: the user's configured `$SHELL` (e.g. `/bin/zsh`, `/bin/bash`), falls back to `/bin/sh`
  - Windows: `cmd.exe`
- Whether the utmm version on the VM is current or upgradable

> **Login shell**: Commands on Linux/macOS run with `shell -l -c` (login mode),
> so `$PATH`, `$HOME`, and other profile environment variables are loaded.
> On Windows, commands run with `cmd.exe /c`.

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
| Restart service | `vm_exec("linuxvm", "systemctl restart utmm")` |
| Run a script | `vm_exec("linuxvm", "cd /opt && bash -c '...'")` |
| Write a file | `vm_exec("linuxvm", "cat > /opt/test.sh << 'EOF'\n...\nEOF")` |
| Check connectivity | `vm_exec("linuxvm", "ping -c 2 macvm")` |
| Windows dir | `vm_exec("windowsvm", "dir C:\\opt\\")` |
| Windows tasklist | `vm_exec("windowsvm", "tasklist \| findstr utm")` |
| macOS version | `vm_exec("macvm", "sw_vers")` |

**Shell escaping notes:**
- Pipe characters `|` may need escaping depending on context — prefer single-line commands
- For multi-line scripts, use heredoc: `cat > /tmp/s.sh << 'EOF'\n...\nEOF\nsh /tmp/s.sh`
- Windows: backslashes in paths work, forward slashes also work in cmd.exe
- Single quotes are safer than double quotes for shell commands

> **Auto-upgrade**: The Host uploads `utmm.next` (or `utmm.next.exe` on Windows) via TCP transport to any Guest whose version doesn't match. The Guest detects it in its 1-second broadcast loop and self-upgrades (atomic rename + detached restart). Bump `src/ver.zig` and rebuild — all online Guests upgrade within seconds.

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
> Bump `src/ver.zig` and rebuild before testing — Host auto-upgrades all Guests.

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
2. Host: sudo utmm --host --install && sudo utmm --host
3. For each Guest VM, run ONE command (no internet needed — from Host TCP):
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

**The Host must be running for auto-upgrade and /etc/hosts sync:**
```bash
sudo utmm --host
```

**MCP adapter mode works independently** — `utmm --mcp` discovers Guests via UDP broadcast (with `/tmp/utmm-guests.tsv` state file fallback) and connects directly via TCP transport.

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| "No VMs online" | VMs not booted, or guest utmm not running | Check VMs are booted; verify `utmm` is running inside each |
| "GuestNotFound" for a VM | VM is offline or name mismatch | Run `vm_status` to see which VMs are actually online |
| VM marked "upgradable" | Guest binary is older than Host | Host will auto-upgrade within seconds — bump ver.zig and rebuild |
| vm_status returns empty but CLI --status shows VMs | UDP port not available, no state file | Start Host (`sudo utmm --host`) to write state file; or use `--host --mcp` for integrated mode |

**Fallback:** If MCP tools are unavailable, you can use the CLI directly:
```bash
utmm --status
utmm --exec linuxvm "uname -a"
```

## Host Paths

| Item | Path |
|------|------|
| Host binary (symlink) | `/usr/local/bin/utmm` → `/opt/utmm/utmm` |
| Host binary (actual) | `/opt/utmm/utmm` → `/opt/utmm/utmm-aarch64-macos` |
| All platform binaries | `/opt/utmm/utmm-*` (6 binaries from utmm.zip) |
| Host service plist | `/Library/LaunchDaemons/com.utmm.plist` |
| Host log | `/var/log/utmm-host.log` |
| Serve directory (TCP) | `/opt/utmm/` by default (configurable via `--serve-dir`) |
| State file | `/tmp/utmm-guests.tsv` (TSV: hostname, target, ip, mac, version, shell) |

## Bootstrap Troubleshooting

### Guest can't download from Host (connection timeout)

**Symptom**: The install script fetches successfully but the download within the script fails with a connection timeout.

**Cause**: The Guest is on a UTM bridge network that can't route to the Host's physical NIC IP. Example: macvm on bridge100 (192.168.64.0/24) cannot reach the Host's en0 IP (192.168.3.130).

**Solution**: Use the bridge gateway IP directly:
```bash
# Use the bridge gateway IP (192.168.64.1, 192.168.65.1, etc.) directly:
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl -fsSL "http://$GATEWAY:2121/bin/utmm-aarch64-linux" -o /opt/utmm/utmm
chmod +x /opt/utmm/utmm
/opt/utmm/utmm --hostname linuxvm &
```

### `--status` shows stale/duplicate entries after Guest restarts

**Symptom**: After restarting a Guest with a new hostname, both the old and new names appear in `--status`.

**Cause**: The Host's UDP listener caches Guest entries. Old entries remain until they expire.

**Workaround**: Restart the Host process (`sudo pkill utmm && sudo utmm --host`). The stale entry will be gone after restart.

### Guest broadcasts with wrong hostname (OS default instead of specified name)

**A**: This was a bug in install.sh — `--install` was called without `--hostname`. Fixed in v0.1.5. If affected, restart the Guest: `pkill utmm && /opt/utmm/utmm --hostname <name> &`

## Limitations

- `vm_exec` is non-interactive — you cannot run commands that require TTY input (nano, top, etc.)
- VM IPs can change on reboot — always check `vm_status` first, don't cache IPs
- Windows cmd.exe has different escaping rules than bash — test simple commands first

### Q: `--download` fails with "Guest not found" but the Guest is online
**A**: This happens when you use a full path like `/opt/utmm/file.txt` instead of just the filename `file.txt`. The FILE_REQ endpoint only accepts simple filenames (no `/` or `\`) and only reads from `/opt/utmm/` on the Guest. Use just the basename:
```
# Wrong:
utmm --download linuxvm /opt/utmm/app.log ./app.log
# Correct:
utmm --download linuxvm app.log ./app.log
```
To download files from other directories, use `--exec` to copy them to `/opt/utmm/` first.

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

### Q: 32-bit x86 build fails with "unimplemented architecture: x86"
**A**: zio's coroutine context switching explicitly excludes 32-bit x86 (`coroutines.zig:108`). zio supports 8 other architectures (x86_64, aarch64, arm, riscv64/32, loongarch64, powerpc64, sparc64), but our 6 release targets only cover aarch64 + x86_64 × linux/macos/windows — the architectures relevant to UTM VMs. 32-bit x86 is not planned for support.

## Reference Manual

See [MANUAL.md](MANUAL.md) for the complete reference: build & install, architecture design, protocol specification, CLI reference, auto-upgrade workflow, MCP integration, platform-specific notes, and troubleshooting.
