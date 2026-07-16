---
name: utm-vm
description: >
  Use this skill whenever the user needs to interact with UTM virtual machines —
  checking VM status, running commands on VMs, testing code cross-platform,
  deploying binaries to VMs, debugging issues inside a VM, or any cross-VM
  coordination. This skill gives you structured access via the utm-monitor MCP
  server. Trigger on ANY mention of: VM names (linuxvm, macvm, windowsvm, ubuntu),
  "VM", "UTM", "virtual machine", "guest", "cross-platform", "deploy to", "test on
  Linux/Windows", "run on the VM", "check the VM", "/etc/hosts", IP changes,
  or remote execution on a local VM.
---

# UTM VM Management via utm-monitor

You have structured access to three UTM virtual machines through the `utm-monitor`
MCP server. This lets you run commands, deploy code, and check status on Linux,
macOS, and Windows VMs — without needing to know their IP addresses. The Host
auto-syncs VM IPs to `/etc/hosts`, so hostnames like `linuxvm` always resolve.

## Available VMs

| Hostname | OS | Arch | Credentials | App Path |
|----------|-----|------|-------------|----------|
| `linuxvm` | Linux | aarch64 | root / 111 | `/opt/` |
| `macvm` | macOS | aarch64 | root / 111 | `/opt/` |
| `windowsvm` | Windows | aarch64 | Administrator / 111 | `C:\opt\` |

## Three MCP Tools

### 1. `vm_status` — List all VMs and their state

**Always call this FIRST** in any VM workflow. It tells you:
- Which VMs are online, their IP, OS/arch, MAC address
- Whether the utm-monitor version on the VM is current or upgradable

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
| Read logs | `vm_exec("linuxvm", "tail -50 /var/log/utm-monitor.log")` |
| Install packages | `vm_exec("linuxvm", "apt-get install -y htop")` |
| Restart service | `vm_exec("linuxvm", "systemctl restart utm-monitor")` |
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

### 3. `vm_deploy(vm?)` — Cross-compile and deploy to VMs

Compiles the current project from source and deploys via HTTP to the target VM(s).
Omit `vm` to deploy to all online VMs.

```
vm_deploy()              → deploy to ALL online VMs
vm_deploy("linuxvm")     → deploy only to linuxvm
```

The deploy workflow: `zig build -Dtarget=...` → HTTP upload → remote restart.

> **Auto-upgrade**: The Host automatically pushes new binaries to any Guest whose version doesn't match. Bump `src/ver.zig` and rebuild — all online Guests upgrade within seconds. No Guest polling, no curl scripts.

**When to deploy:**
- After making code changes that need testing
- When `vm_status` shows a VM as "upgradable"
- Before running tests on a VM with a fresh build

## Core Workflows

### Workflow A: Quick health check
```
vm_status → see which VMs are online, their versions, IPs
```

### Workflow B: Cross-platform testing
```
1. vm_status                         → confirm targets online
2. vm_deploy("linuxvm")              → push latest build
3. vm_exec("linuxvm", "./test.sh")   → run tests
4. Repeat 2-3 for macvm, windowsvm
```

### Workflow C: Debugging a VM problem
```
1. vm_status                            → confirm online, note version
2. vm_exec("linuxvm", "ps aux")         → check running processes
3. vm_exec("linuxvm", "cat /var/log/...") → read relevant logs
4. vm_deploy("linuxvm")                 → update to latest if needed
5. vm_exec("linuxvm", "...")            → verify the fix
```

### Workflow D: Initial setup (first time or after VM rebuild)
```
1. vm_status → see which VMs are missing
2. For each missing VM, tell user to:
   - Copy utm-monitor binary to /opt/ via UTM shared folder
   - Run: utm-monitor --install && utm-monitor --hostname <name> &
3. Once all VMs appear in vm_status, proceed
```

### Workflow E: Multi-VM network test
```
1. vm_exec("linuxvm", "ping -c 2 macvm")    → can linux reach mac?
2. vm_exec("windowsvm", "ping -n 2 linuxvm") → can windows reach linux?
```

## Prerequisites & Troubleshooting

**The Host must be running before any MCP tool works:**
```bash
sudo utm-monitor --host
```

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| "Host is not running" | Host process died or never started | `sudo utm-monitor --host` |
| "GuestNotFound" for a VM | VM is offline or name mismatch | Run `vm_status` to see which VMs are actually online |
| "No VMs currently online" | VMs not booted, or guest utm-monitor not running | Check VMs are booted; verify `utm-monitor` is running inside each |
| VM marked "upgradable" | Guest binary is older than Host | `vm_deploy("that-vm")` — or Host will auto-upgrade within seconds |
| vm_status returns empty but CLI --status shows VMs | MCP IPC issue | Use `utm-monitor --host --mcp` for integrated mode (bypasses IPC) |

**Fallback:** If MCP tools are unavailable, you can use the CLI directly:
```bash
utm-monitor --host --status
utm-monitor --host --exec linuxvm "uname -a"
utm-monitor --host --deploy linuxvm
```

## Host Paths

| Item | Path |
|------|------|
| Host binary | `/usr/local/bin/utm-monitor` |
| Host service plist | `/Library/LaunchDaemons/com.utm-monitor.plist` |
| Host log | `/var/log/utm-monitor-host.log` |
| Serve directory (HTTP) | Same directory as Host binary (or `--serve-dir`) |

## Limitations

- `vm_exec` is non-interactive — you cannot run commands that require TTY input (nano, top, etc.)
- `vm_deploy` builds from source — the Zig project must be at the MCP server's cwd
- VM IPs can change on reboot — always check `vm_status` first, don't cache IPs
- Windows cmd.exe has different escaping rules than bash — test simple commands first
