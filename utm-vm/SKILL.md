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
- Whether the utmm version on the VM is current or upgradable

If `vm_status` returns "No VMs currently online", the other tools cannot work.
Ask the user whether the VMs are booted and the Host is running.

### 2. `vm_exec(vm, command)` — Execute a shell command on a VM

The command runs in the VM's native shell:
- **Linux/macOS**: `/bin/sh -c "<command>"`
- **Windows**: `cmd.exe /c "<command>"`

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

> **Auto-upgrade**: The Host uploads `utmm.new` to any Guest whose version doesn't match. The Guest detects it in its 1-second broadcast loop and self-upgrades (atomic rename + detached restart). Bump `src/ver.zig` and rebuild — all online Guests upgrade within seconds.

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
3. For each Guest VM, run ONE command (no internet needed — from Host HTTP):
   - Linux/macOS: curl http://<gateway>:2121/bin/install.sh | sh -s -- --guest --hostname <name>
   - Windows: find gateway, download install.ps1 from http://<gateway>:2121/bin/install.ps1, run with -Guest
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

**The Host must be running before any MCP tool works:**
```bash
sudo utmm --host
```

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| "Host is not running" | Host process died or never started | `sudo utmm --host` |
| "GuestNotFound" for a VM | VM is offline or name mismatch | Run `vm_status` to see which VMs are actually online |
| "No VMs currently online" | VMs not booted, or guest utmm not running | Check VMs are booted; verify `utmm` is running inside each |
| VM marked "upgradable" | Guest binary is older than Host | Host will auto-upgrade within seconds — bump ver.zig and rebuild |
| vm_status returns empty but CLI --status shows VMs | MCP IPC issue | Use `utmm --host --mcp` for integrated mode (bypasses IPC) |

**Fallback:** If MCP tools are unavailable, you can use the CLI directly:
```bash
utmm --host --status
utmm --host --exec linuxvm "uname -a"
```

## Host Paths

| Item | Path |
|------|------|
| Host binary (symlink) | `/usr/local/bin/utmm` → `/opt/utmm/utmm` |
| Host binary (actual) | `/opt/utmm/utmm` → `/opt/utmm/utmm-aarch64-macos` |
| All platform binaries | `/opt/utmm/utmm-*` (8 binaries from utmm.zip) |
| Host service plist | `/Library/LaunchDaemons/com.utmm.plist` |
| Host log | `/var/log/utmm-host.log` |
| Serve directory (HTTP) | `/opt/utmm/` by default (configurable via `--serve-dir`) |

## Bootstrap Troubleshooting

### Guest can't download from Host HTTP (curl error 28/timeout)

**Symptom**: The `/update` script fetches successfully but the download within the script fails with a connection timeout.

**Cause**: The `/update` script uses the Host IP from the HTTP `Host` header. If the Guest is on a UTM bridge network that can't route to the Host's physical NIC IP, the download fails. Example: macvm on bridge100 (192.168.64.0/24) cannot reach the Host's en0 IP (192.168.3.130).

**Solution**: The `/update` endpoint now auto-detects the correct IP from the HTTP Host header. Ensure you're using the latest version. If the issue persists, download the binary directly:
```bash
# Use the bridge gateway IP (192.168.64.1, 192.168.65.1, etc.) directly:
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl -fsSL "http://$GATEWAY:2121/bin/utmm-aarch64-linux" -o /opt/utmm/utmm
chmod +x /opt/utmm/utmm
/opt/utmm/utmm --hostname linuxvm &
```

### `--status` shows stale/duplicate entries after Guest restarts

**Symptom**: After restarting a Guest with a new hostname, both the old and new names appear in `--status`.

**Cause**: The Host's UDP listener caches Guest entries. Old entries remain until they expire. There's currently no active cleanup for renamed guests.

**Workaround**: Restart the Host process (`sudo pkill utmm && sudo utmm --host`). The stale entry will be gone after restart.

### `/update` script fails: directory not found

**Symptom**: `curl: (23) client returned ERROR on write` when executing `/update`.

**Cause**: Older versions of the `/update` script did not create `/opt/utmm/` before downloading.

**Solution**: The latest `/update` script includes `mkdir -p`. If you're using an older Host, create the directory manually first: `sudo mkdir -p /opt/utmm`.

## Limitations

- `vm_exec` is non-interactive — you cannot run commands that require TTY input (nano, top, etc.)
- VM IPs can change on reboot — always check `vm_status` first, don't cache IPs
- Windows cmd.exe has different escaping rules than bash — test simple commands first

## Reference Manual

See [MANUAL.md](MANUAL.md) for the complete reference: build & install, architecture design, protocol specification, CLI reference, auto-upgrade workflow, MCP integration, platform-specific notes, and troubleshooting.
