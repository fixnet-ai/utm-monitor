# UTM Monitor Skill — VM Management via MCP

## Available VMs

| VM | Hostname | OS/Arch | IP | Shell |
|----|----------|---------|----|-------|
| macOS VM | macvm | aarch64-macos | 192.168.64.4 | zsh |
| Linux VM | linuxvm | aarch64-linux-musl | 192.168.64.2 | bash |
| Windows VM (ARM) | windowsvm | aarch64-windows | 192.168.65.2 | cmd.exe |
| Windows (x64) | winx64 | x86_64-windows | 192.168.3.108 | cmd.exe |

Credentials: root/111 (POSIX), Administrator/111 (Windows). App path: `/opt/utmm/` (POSIX), `C:\opt\utmm\` (Windows).

## Architecture

UTM Monitor is a single binary with two modes. The Host manages Guests through a
**mesh network over UDP port 2121** — LSA (Link State Advertisement) for topology
discovery, KCP (reliable ARQ) tunnels for command execution and file transfer.
CLI and MCP talk to the Host through a local **IPC socket** (`/var/run/utmm.sock`
on POSIX, named pipe on Windows) — no HTTP involved.

MCP is the complete CLI command set exposed through the MCP protocol over stdio.
All five management commands have corresponding MCP tools.

## MCP Tools

### `vm_status` — List all machines

Returns all nodes including the Host: hostname, role (host/guest), target (OS/arch),
IP, MAC, version, shell, and status (serving/upgrading). No arguments required.

### `vm_exec` — Execute command on target VM

- `vm`: hostname (linuxvm, macvm, windowsvm, winx64)
- `command`: shell command to execute
- **Shell persists**: `cd`, `export`, venv activation survive across calls. Each KCP
  tunnel connection = one shell session.
- Output is streaming; returns when command completes.

### `vm_ping` — Ping a Guest over mesh

- `vm`: hostname
- Returns hostname, MAC address, and RTT in milliseconds.
- Direct ping (Host→Guest) and relayed ping (Guest→Guest via Host) both supported.

### `vm_upload` — Upload file to Guest

- `vm`: hostname
- `local_path`: path to file on Host filesystem
- `remote_path` (optional): destination path on Guest. Defaults to `/opt/utmm/<basename>`.
- Transfer via KCP tunnel with SHA256 verification, 1200B MSS-aligned chunks.

### `vm_download` — Download file from Guest

- `vm`: hostname
- `remote_path`: path to file on Guest
- `local_path` (optional): local path on Host to save. Defaults to `./<basename>`.
- Transfer via KCP tunnel with SHA256 verification.

## CLI Commands

All management commands communicate with the Host daemon via IPC socket
(`/var/run/utmm.sock`). The CLI auto-ensures the Host service if not running.

```bash
# Status and health
sudo utmm --status                              # List Host + all guests (role, status, version, last seen)
sudo utmm --verify                              # Health check matrix: status + ping + exec echo per guest
sudo utmm --ping <vm>                           # Ping a guest via mesh
# Remote execution
sudo utmm --exec <vm> "<command>"               # Execute on target VM
sudo utmm --upload <local-file> <vm>            # Upload file (remote defaults to /opt/utmm/<basename>)
sudo utmm --download <vm> <remote-path> <local> # Download file
# Deploy
sudo utmm --deploy [<vm>]                       # Build + SCP + SSH install to all guests (or single)
# Maintenance
sudo utmm --gen-init linux                      # Generate systemd service template
utmm --version                                  # Print version (no root needed)
```

Build from source:

```bash
zig build                                      # Native build
zig build -Dtarget=aarch64-linux-musl          # Cross-compile for target
zig build test                                 # Run all tests
```

## Shell Syntax by Platform

### Linux (bash)
```bash
# Standard bash — POSIX utilities available
ps aux | grep myapp
export VAR=value && echo $VAR
cd /opt/myapp && ls
```

### macOS (zsh)
```bash
# Standard zsh — BSD utilities
ps aux | grep myapp
export VAR=value && echo $VAR
cd /opt/myapp && ls
```

### Windows (cmd.exe, UTF-8 forced)
```cmd
tasklist | findstr myapp
set VAR=value && echo %VAR%
cd C:\opt\myapp && dir
type file.txt
```

## Core Workflows

### Health Check

**Quick check (all-in-one):**
```bash
sudo utmm --verify
# Prints pass/fail matrix: status + ping + exec echo for each guest
# Exit 0 = all healthy, exit 1 = any check failed
```

**Detailed inspection:**
```
vm_status → check all nodes (Host+Guest) online + role + status + version match
If any guest missing → check Host service: sudo utmm --host
```

### Network Connectivity Test
```
vm_ping vm=linuxvm    → hostname, MAC, rtt_ms
vm_ping vm=windowsvm  → hostname, MAC, rtt_ms
```
Direct ping (Host→Guest) and relayed ping (Guest→Guest via Host) both supported.

### Cross-Platform Testing
```
vm_exec vm=linuxvm command="uname -a; cat /etc/os-release"
vm_exec vm=macvm command="uname -a; sw_vers"
vm_exec vm=windowsvm command="ver; systeminfo | findstr /B /C:"OS Name""
```

### Debugging Workflow
```
1. vm_exec vm=<vm> command="ps aux | grep myapp"       → find PID
2. vm_exec vm=<vm> command="gdb -p <pid> -batch -ex 'bt full'"  → backtrace
3. vm_exec vm=<vm> command="tail -100 /var/log/myapp.log"       → recent logs
```

### File Transfer
```
vm_upload vm=linuxvm local_path=./build.zip remote_path=/opt/utmm/build.zip
vm_download vm=linuxvm remote_path=/opt/utmm/core.dump local_path=./core.dump
```

### Deploy / Upgrade

**One-shot deploy (build + SCP + SSH install, v0.11.18+):**
```bash
sudo utmm --deploy                    # Cross-compile + deploy to all guests
sudo utmm --deploy linuxvm            # Deploy single guest
```
Requires `sshpass` on the Host. Windows targets print manual steps (SCP/SSH not
available on Windows by default). Automatically validates binary type (ELF/Mach-O/PE)
before cross-compiling to prevent wrong-platform deployment errors.

**Manual deploy:**
```bash
# One-line install (POSIX)
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sudo sh
# Windows (Administrator terminal)
curl -fsSLo %TEMP%\install.bat https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.bat && %TEMP%\install.bat
```

For offline/manual install, see the comments in [install.sh](install.sh).

### Auto-Upgrade (v0.11.14+)
Guests automatically upgrade when Host version changes:
1. Guest detects version mismatch via LSA (every 2s)
2. Guest sends `upgrade_req` via KCP tunnel, Host responds with chunked binary
3. Guest saves binary to temp, runs `--install --hostname <name>` to complete
4. Host never pushes upgrades — fully Guest-initiated

**Bootstrap note**: v0.11.13 and earlier Guests cannot auto-upgrade. Deploy once
manually to v0.11.14+ before auto-upgrade works.

**Verification**: `sudo utmm --status` shows each node's version — all should match Host
version after auto-upgrade completes (typically within seconds of Host restart).

### Multi-VM Network Test
```
vm_exec vm=linuxvm command="ping -c 2 macvm"
vm_exec vm=macvm command="ping -c 2 windowsvm"
```

## Service Management

```bash
# Check service status (via vm_exec or SSH)
sudo launchctl list | grep utmm          # macOS
sudo systemctl status utmm-guest         # Linux
sc query UTM-Monitor-Guest               # Windows

# Reinstall (new binary already on disk)
sudo /opt/utmm/utmm --install --hostname <name>    # Guest
sudo /opt/utmm/utmm --host --install               # Host

# Uninstall
sudo utmm --uninstall
```

## Host Paths

| Path | Purpose |
|------|---------|
| `/opt/utmm/utmm` (POSIX) / `C:\opt\utmm\utmm.exe` (Windows) | Binary |
| `/opt/utmm/` | Serve directory (binaries, logs) |
| `/var/run/utmm.sock` (POSIX) / `\\.\pipe\utmm` (Windows) | IPC socket |
| `/etc/hosts` | Host-synced guest hostnames |

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Guest not in `--status` | Host service running? KCP tunnel established? LSA visible? |
| `vm_exec` timeout | Guest KCP tunnel alive? Check keepalive dead_link |
| All exec checks failing | Run `sudo utmm --verify` to isolate: status (LSA), ping (mesh reachability), exec (tunnel+shell) |
| Service won't start | Re-run install script or `--install` to force reinstall; check retry limit (3 count) |
| Binary at wrong path | Run from any path — `--install` auto-copies to canonical path |
| Wrong binary type deployed | `--deploy` and `selfCopy` now validate ELF/Mach-O/PE magic numbers before execution |
| Guest not auto-upgrading | Check `sudo utmm --status` for version mismatch. Verify Guest can reach Host via mesh LSA. Older Guests (pre v0.11.14) need one manual upgrade via install script. |
| Auto-upgrade stuck | Guest idle? v0.11.14+ checks every 1s in command loop. Restart Guest if stuck. |
| macOS launchctl bootstrap errno=2 | Known intermittent issue. Use `sudo launchctl kickstart -k system/com.utmm.host` or bootout+bootstrap sequence. |

## Limitations

- Windows cmd.exe: no `grep`/`tail` built-in. Use `findstr`, PowerShell, or install busybox.
- Shell session lives for KCP tunnel lifetime. Tunnel disconnect → fresh shell on reconnect.
- No file editing — upload/download for file transfer.
- Exec output is streaming; `vm_exec` returns when command completes (no timeout).
