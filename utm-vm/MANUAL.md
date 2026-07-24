# UTM Monitor User Manual

## Table of Contents

1. [Architecture Principles](#1-architecture-principles)
2. [Network Requirements](#2-network-requirements)
3. [Quick Deployment](#3-quick-deployment)
4. [Daily Usage](#4-daily-usage)
5. [Troubleshooting](#5-troubleshooting)
6. [Reference Appendix](#6-reference-appendix)
7. [Claude Code Integration (MCP Server)](#7-claude-code-integration-mcp-server)

---

## 1. Architecture Principles

### 1.1 Why This Tool Is Needed

UTM virtual machines obtain IP addresses via DHCP, and the IP may change after every reboot or network change. Manually maintaining IP mappings in the Host `/etc/hosts` is tedious. This tool implements **fully automatic IP discovery and synchronization**: Guests automatically announce their IP to the Host upon startup, and the Host automatically updates `/etc/hosts` — no manual intervention required.

Guests also **auto-upgrade** themselves: the Host broadcasts its version via UDP every 60s; Guests detect a mismatch, spawn a separate `utmm-old` process, and self-upgrade without any external shell commands or dependencies.

### 1.2 Operating Modes

A single binary supports two modes, distinguished by startup arguments:

```
utmm              # Guest mode (default)
utmm --host       # Host mode
```

| Dimension | Guest Mode | Host Mode |
|-----------|------------|-----------|
| Runs on | Inside each VM | Host machine |
| Count | One per VM | Only one |
| Responsibility | WebSocket connect to Host, announce info, run persistent pty shell, auto-upgrade | Unified HTTP server: guest registration, exec via pty, upload, download, MCP, static files, /etc/hosts sync, periodic UDP version broadcast |
| Required Privileges | Regular user (Windows: Administrator for service install) | `sudo` (to write /etc/hosts, bind privileged port) |

**Guest sub-modes**:

| Mode | How to invoke | Behavior |
|------|--------------|----------|
| Foreground | `utmm` (default, no args) | Stop background service, run Guest in terminal, restart service on exit (Ctrl+C / close window). Auto-detects TTY; falls back to daemon if no terminal. |
| Daemon | `utmm --svc` | Run guest directly — no service management. Used by service managers (launchd/systemd/sc). |
| Upgrade | `utmm --update-url URL` | Upgrade mode — stops service, kills old processes, downloads new binary, replaces, starts service. Invoked internally by `utmm-old` process. |
| Install | `utmm --install` / `--install --user` | Install as system service (daemon) or create desktop shortcut (foreground launcher). |
| Version | `utmm --version` | Print version and exit. |

### 1.3 Data Flow Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Host (Host Machine)                          │
│                                                                      │
│  ┌─────────────┐    ┌──────────────────┐    ┌──────────────────┐     │
│  │ /etc/hosts   │◄───│ hosts_file module │◄───│ Host HTTP :2121  │     │
│  │              │    │ (marker block     │    │                  │     │
│  └─────────────┘    │  update)           │    │ /ws    ← WebSocket│     │
│                     └──────────────────┘    │ /mcp   ← AI Agent  │     │
│                                             │ /exec  ← CLI       │     │
│                              WebSocket (persistent, binary frames)    │
│                              One connection per Guest                 │
│                                    ┌────┼──────┬──────┐              │
│                                    ▼    ▼      ▼      ▼              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│  │  macvm     │  │  linuxvm   │  │ windowsvm  │  │ winx64     │     │
│  │            │  │            │  │            │  │            │     │
│  │ WS client  │  │ WS client  │  │ WS client  │  │ WS client  │     │
│  │ + pty shell│  │ + pty shell│  │ + cmd.exe  │  │ + cmd.exe  │     │
│  └────────────┘  └────────────┘  └────────────┘  └────────────┘     │
│                                                                      │
│  ┌──────────────────────────────────────────┐                        │
│  │ CLI Management Commands                   │  ← Host CLI            │
│  │ --status / --exec via HTTP to Host :2121  │                        │
│  │ --upload / --download via HTTP            │                        │
│  │ --gen-init / --version                    │                        │
│  └──────────────────────────────────────────┘                        │
│                                                                      │
│  UDP Broadcast (periodic, :2121)                                     │
│  "ARE YOU OK?\r\n0.7.0\r\n" → Guest version check → auto-upgrade    │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.4 Communication Protocols

#### WebSocket (Guest ↔ Host, Port 2121, Path /ws)

Guest opens a persistent WebSocket connection to Host. All communication uses **binary frames**:

**Frame format**: `[1-byte message type][type-specific payload]`

| Message Type | Wire Value | Direction | Purpose |
|-------------|-----------|-----------|---------|
| `announce` | 1 | Guest → Host | Advertise hostname, IP, target, MAC, version, shell |
| `upload_req` | 4 | Host → Guest | Upload file: path + binary data |
| `upload_resp` | 5 | Guest → Host | Upload result: exit code |
| `download_req` | 6 | Host → Guest | Download file: path |
| `download_resp` | 7 | Guest → Host | File content: exit code + binary data |
| `pty_spawn` | 12 | Host → Guest | Spawn persistent shell on WS connect (no payload) |
| `pty_input` | 13 | Host → Guest | Feed command stdin: cmd_id + data (with MDELIM marker) |
| `pty_output` | 14 | Guest → Host | Shell stdout/stderr: cmd_id + output data |
| `pty_signal` | 15 | Host → Guest | Send signal to shell: 1-byte (0=SIGINT/CtrlC, 1=SIGTERM, 2=SIGHUP) |
| `pty_resize` | 16 | Host → Guest | Terminal resize: rows(u16 BE) + cols(u16 BE) |

> **Wire values 2,3,8,9,10,11 are reserved/deprecated** — removed in v0.5.0 when pty session model replaced per-command exec model. Current wire values: announce=1, upload=4-7, pty=12-16.

**pty Session Model**: On WebSocket connect, Guest spawns a persistent shell
via `posix_openpt` (POSIX) or `CreatePipe` (Windows). Commands are fed via pty_input
and output arrives via pty_output. A `MDELIM:$?\n` (POSIX) or `MDELIM:%errorlevel%\r\n`
(Windows) exit-code marker is appended to each command for completion detection.
The shell session lives for the entire WebSocket connection lifetime — `cd`, `export`,
and other stateful commands persist across `vm_exec` calls.

**Payload encoding:**
- String fields: null-terminated (`\0` delimiter)
- Binary fields: 4-byte big-endian length prefix + raw bytes
- No base64, no JSON encoding — raw binary for file data

**Periodic re-announce**: Guest re-sends announce periodically so Host always has current info.

Guest auto-discovers Host IP via default gateway (UTM Host is the gateway for bridged networks). Override with `--host-ip`.

#### HTTP REST (CLI → Host, Port 2121)

CLI management commands use standard HTTP:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/guests` | GET | List all guests (JSON) |
| `/exec` | POST | Send command via pty, wait for result |
| `/upload` | POST | Upload file to guest |
| `/download` | POST | Download file from guest |
| `/mcp` | POST | MCP JSON-RPC (AI agent entry) |
| `/bin/<file>` | GET | Static file serving (bootstrap scripts, binaries for auto-upgrade) |
| `/` | GET | HTML status page |

CLI commands send HTTP to `127.0.0.1:2121`. Host communicates with Guest via WebSocket
for actual command execution.

**Streaming exec**: `POST /exec` returns chunked streaming plain text —
output arrives in real time as the command runs. Exit code is delivered via
`x-exit-code` HTTP trailer. No timeout — commands run as long as needed.

**Binary upload/download**: `POST /upload` and `POST /download` use
custom HTTP headers `x-vm` (target VM hostname) and `x-path` (file path on guest).
Body is raw binary (`application/octet-stream`) — no JSON wrapping.
Download response is chunked streaming with `x-exit-code` trailer.

#### UDP Broadcast Discovery (Port 2121)

Host broadcasts a versioned discovery query via UDP to all LAN subnets every 60s:

```
"ARE YOU OK?\r\n0.7.0\r\n"
```

`utmm --status` also sends this broadcast. Each Guest listens on UDP :2121 and
responds with its ANNOUNCE info. The version line enables **auto-upgrade**:
Guest compares Host version with its own; if different, triggers self-upgrade.

Old-format broadcasts ("ARE YOU OK?\r\n" without a version line) are backward-compatible:
Guests still respond but won't trigger auto-upgrade.

#### Auto-Upgrade Flow

```
1. Host periodicBroadcastLoop: UDP "ARE YOU OK?\r\n0.8.2\r\n" to all subnets (every 60s)
2. Guest udpDiscoveryListener: parseDiscoveryVersion → "0.8.2" != "0.8.1" → set upgrade.needed
3. Guest wsAnnounceLoop: detect upgrade.needed flag
4. Guest triggerSelfUpgrade:
   - Copy current exe → utmm-old[.exe] (same directory)
   - chmod +x (POSIX, direct syscall)
   - POSIX: fork()+setsid()+execve(utmm-old, --update-url, URL)
   - Windows: std.process.spawn(utmm-old.exe, --update-url, URL)
   - std.process.exit(0)
5. utmm-old process (upgrade.zig):
   a. stopService: launchctl bootout / systemctl stop / sc stop
   b. killUtmmProcesses: pkill -9 -x utmm / taskkill /im utmm.exe
   c. downloadBinary: std.http.Client GET http://host:2121/bin/utmm-<target>
   d. replaceBinary: write utmm.next → chmod +x → rename over utmm[.exe]
   e. startService: launchctl bootstrap / systemctl start / sc start
   f. exit(0)
6. Service manager restarts Guest → new version connects via WebSocket
```

All steps use **zero external shell commands**: `fork()`+`execve()` on POSIX,
`std.process.spawn` on Windows, `std.c.chmod` for permissions, `std.http.Client` for download.

#### /etc/hosts Marker Block

The Host maintains a marker block in `/etc/hosts`, using FQDN format `{hostname}.{target}.utm` for naming:

```
# Normal hosts entries...
127.0.0.1  localhost

# UTM-MONITOR-BEGIN
192.168.64.2  linuxvm.aarch64-linux-musl.utm
192.168.64.4  macvm.aarch64-macos.utm
192.168.65.2  windowsvm.aarch64-windows.utm
192.168.3.x  winx64.x86_64-windows.utm
# UTM-MONITOR-END
```

The `target` in the FQDN is the Zig cross-compilation target triple, directly usable for `zig build -Dtarget=` for cross-compilation.

### 1.5 Physical NIC Detection

When the Guest starts, it needs to obtain the IPv4 address of the local physical NIC. The common "connect to 8.8.8.8 to get local IP" approach is easily disrupted by VPN tunnel interfaces (tun/utun/wintun), returning an incorrect IP (e.g., `198.18.0.1`).

This tool uses the `getifaddrs()` system call on **macOS / Linux** to enumerate all network interfaces and **automatically excludes** the following virtual interfaces:

```
utun*, tun*, tap*, llw*, awdl*, bridge*, vmnet*, docker*, gif*, stf*, veth*, vboxnet*, virbr*, lo*
```

On **Windows**, the Guest self-reports its IP as `0.0.0.0` (fallback value), and the Host extracts the real IP from the TCP connection source address.

---

## 2. Network Requirements

### 2.1 Port Checklist

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 2121 | TCP | Bidirectional | HTTP server: WebSocket (guest connection) + REST (CLI) + MCP (AI agent) + static files (auto-upgrade binaries) |
| 2121 | UDP | Host→Guests | Broadcast discovery + version announcement (auto-upgrade trigger) |

### 2.2 Network Topology Requirements

**Guest and Host must be on the same network**. Specifically:

- Guest connects via TCP to Host on port 2121
- Host listens on `0.0.0.0:2121`
- Guest discovers Host IP by detecting default gateway (UTM Host is the gateway)

**UTM's default network modes satisfy this requirement** (both Shared Network and Bridged Network work).

Verification method:
```bash
# Confirm IP on Guest
ip addr show        # Linux
ifconfig en0        # macOS
ipconfig            # Windows

# Confirm reachable from Host
ping 192.168.64.2
```

### 2.3 Host One-Click Installation (macOS / Linux / Windows)

Install on the Host machine with a single command:

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

The script downloads `utmm.zip` from GitHub Releases, extracts all 8 platform binaries to `/opt/utmm/`, auto-detects the Host architecture, and creates symlinks:

- `/opt/utmm/utmm` → `/opt/utmm/utmm-{arch}-{os}` (Host binary)
- `/usr/local/bin/utmm` → `/opt/utmm/utmm` (convenience)

All Guest binaries are already in `/opt/utmm/` after extraction — the Host's `serve_dir` defaults to this directory, so auto-upgrade works for all Guest architectures immediately.

**Windows:**
Download `utmm.zip` from [GitHub Releases](https://github.com/fixnet-ai/utm-monitor/releases), extract to `C:\opt\utmm\`, and run:
```batch
C:\opt\utmm\utmm.exe --host
```

Start the Host:

```bash
# macOS / Linux
sudo utmm --host --install   # Install as system service, auto-start on boot (starts immediately)

# Windows (Administrator terminal)
C:\opt\utmm\utmm.exe --host --install   # Install as Windows Service, auto-start on boot
```

> **Linux note:** Port 2121 < 1024 requires root or `sudo setcap cap_net_bind_service=+ep /opt/utmm/utmm`.
> **Windows note:** The installer adds a firewall rule for the binary automatically. On first run, confirm any UAC prompt.

> **Service mode note**: Use `--host --install` to generate a Host-mode service config (service name: `com.utmm.host` / `utmm-host` / `UTM-Monitor-Host`). Use just `--install` (without `--host`) on Guest VMs to self-install as a Guest-mode service (`com.utmm.guest` / `utmm-guest` / `UTM-Monitor-Guest`).

### 2.4 Bare-Metal Bootstrapping (First-time Guest VM Deployment)

A brand-new VM has no utmm running. After the Host starts `utmm --host`, it automatically provides an HTTP server on port 2121 (serving the cross-compiled binaries from `/opt/utmm/`). The unified `install.sh` handles both Host and Guest deployment.

**Deployment order is always: Host first, then Guests.**

**Linux / macOS Guest** — one command (no internet needed, everything from Host HTTP):

```bash
# Find the gateway IP (Host's bridge address), then:
curl "http://<gateway>:2121/bin/install.sh" | sh -s -- --guest --hostname myvm

# Linux: detect gateway automatically:
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl "http://$GATEWAY:2121/bin/install.sh" | sh -s -- --guest --hostname linuxvm

# macOS: detect gateway automatically:
GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
curl "http://$GATEWAY:2121/bin/install.sh" | sh -s -- --guest --hostname macvm
```

**Windows Guest** (as Administrator):

```batch
curl -o install.bat "http://<gateway>:2121/bin/install.bat" && install.bat --guest --hostname windowsvm
```

> **Note**: The batch installer (`install.bat`) has zero dependencies — no PowerShell, no execution policy issues, no SSH quoting problems.

**What the script does automatically:**
1. Detects CPU architecture (`aarch64` / `x86_64`) — no manual `uname -m` needed
2. Detects OS and finds the default gateway (the Host's bridge IP)
3. Downloads the correct binary from `http://<gateway>:2121/bin/utmm-{arch}-{os}[.exe]`
4. Creates `/opt/utmm/` (or `C:\opt\utmm\` on Windows) and installs the binary
5. Creates convenience symlinks (`/usr/local/bin/utmm` on Unix)
6. Installs auto-start service via `utmm --install` (with SHELL and HOME environment variables)
7. Starts the Guest immediately with the given `--hostname`

> **Prerequisite**: The Host must be running `sudo utmm --host` and the gateway must be reachable from the Guest. If the gateway detection fails, the script probes common UTM bridge IPs (192.168.64.1, 192.168.65.1, 192.168.66.1).

After the Guest starts, it establishes a WebSocket connection to the Host. **From then on, auto-upgrade is fully automatic.**

---

## 3. Quick Deployment

### 3.1 Environment Preparation

**Host Side (your Mac):**
- Method 1 (Recommended): Use install.sh for one-click installation (see §2.3), no Zig installation required
- Method 2 (Development Mode): Zig 0.16.0 (`brew install zig`) + sudo privileges

**Guest Side (VM):**
- Target path must exist: `/opt/` (`C:\opt\` on Windows)
- Bare-metal bootstrapping: Host HTTP `/bin/install.sh` endpoint (see §2.4), or UTM shared folder
- After initial bootstrapping, fully managed by automatic upgrade

### 3.2 Confirm VM Architecture

```bash
# After Guest is online, query with --exec
utmm --exec linuxvm "uname -m"      # aarch64 → aarch64-linux-musl
utmm --exec macvm "uname -m"        # arm64  → aarch64-macos

# Or check the target field in --status output
utmm --status
```

### 3.3 Obtain the Binary

**Method 1: GitHub Releases (Recommended, no local compilation needed)**

Each release automatically builds 8 binaries for all VM scenarios, packaged as `utmm.zip`:

| File | Covers | Zig Target |
|------|--------|------------|
| `utmm-x86_64-linux` | 64-bit x86 Linux VMs | x86_64-linux-musl |
| `utmm-aarch64-linux` | ARM64 Linux VMs | aarch64-linux-musl |
| `utmm-x86-linux` | 32-bit x86 Linux VMs | x86-linux-musl |
| `utmm-x86_64-macos` | Intel Mac + Apple Silicon Mac (physical) | x86_64-macos |
| `utmm-aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) | aarch64-macos |
| `utmm-x86_64-windows.exe` | 64-bit x86 Windows VMs | x86_64-windows |
| `utmm-aarch64-windows.exe` | ARM64 Windows VMs | aarch64-windows |
| `utmm-x86-windows.exe` | 32-bit x86 Windows | x86-windows-gnu |

> **32-bit x86 support**: x86-linux-musl builds since v0.2.5. x86-windows uses `x86-windows-gnu` since v0.8.0 to avoid MinGW `_system@4` linker warning.

> **macOS Rosetta 2 note**: Apple Silicon **physical** Macs can run `utmm-x86_64-macos` (x86_64) via Rosetta 2. However, UTM ARM macOS **VMs** lack Rosetta 2, so they need `utmm-aarch64-macos` (native aarch64). If you need Rosetta 2 on a physical Mac: `softwareupdate --install-rosetta`.

Download URL: `https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.zip`

**Method 2: Local Compilation**

```bash
git clone https://github.com/fixnet-ai/utm-monitor.git
cd utm-monitor

# Cross-compile for each platform (8 targets cover all scenarios)
zig build -Dtarget=x86_64-linux-musl   -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl  -Doptimize=ReleaseSafe
zig build -Dtarget=x86-linux-musl      -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-macos        -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos       -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows      -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-windows     -Doptimize=ReleaseSafe
zig build -Dtarget=x86-windows-gnu     -Doptimize=ReleaseSafe

# Rebuild native LAST — each cross-compile overwrites zig-out/bin/utmm,
# so the final native build ensures utmm is the correct host architecture.
zig build -Doptimize=ReleaseSafe
```

Build artifacts:
- `zig-out/bin/utmm` — native binary (current platform, built last)
- `zig-out/bin/utmm-x86_64-linux` — Linux 64-bit x86 musl static
- `zig-out/bin/utmm-aarch64-linux` — Linux aarch64 musl static
- `zig-out/bin/utmm-x86-linux` — Linux 32-bit x86 musl static
- `zig-out/bin/utmm-x86_64-macos` — macOS x86_64 (Intel + Apple Silicon via Rosetta 2)
- `zig-out/bin/utmm-aarch64-macos` — macOS aarch64 (ARM VMs without Rosetta 2)
- `zig-out/bin/utmm-x86_64-windows.exe` — Windows 64-bit x86
- `zig-out/bin/utmm-aarch64-windows.exe` — Windows ARM64
- `zig-out/bin/utmm-x86-windows.exe` — Windows 32-bit x86 (x86-windows-gnu)

Run tests to confirm correctness:

```bash
zig build test --summary all
```

**After building from source, code-sign and set up the Host serve directory:**

When building from source (Method 2), the `install.sh` and `install.bat` files are **not** automatically copied to the serve directory. Copy them manually:

```bash
# From the project root:
sudo mkdir -p /opt/utmm
sudo cp install.sh install.bat zig-out/bin/utmm-* /opt/utmm/
sudo chmod +x /opt/utmm/*
# macOS: code-sign to prevent AMFI from killing the binary when run with sudo
sudo codesign --force --sign - /opt/utmm/utmm-aarch64-macos 2>/dev/null || true
# Create symlinks
sudo ln -sf /opt/utmm/utmm-aarch64-macos /opt/utmm/utmm   # Apple Silicon
# Or: sudo ln -sf /opt/utmm/utmm-x86_64-macos /opt/utmm/utmm  # Intel Mac
sudo mkdir -p /usr/local/bin
sudo ln -sf /opt/utmm/utmm /usr/local/bin/utmm
```

> **Important**: After cross-compilation, `zig-out/bin/utmm` is the LAST target built (not native). Always rebuild native last to ensure the generic `utmm` binary matches your host architecture. The platform-specific named binaries (`utmm-aarch64-macos`, etc.) are correct from their respective cross-compile steps. The `sudo cp zig-out/bin/utmm-* /opt/utmm/` copies all named binaries including the correct host one — no need to copy `utmm` separately.

> **macOS code signing**: On macOS, binaries run with `sudo` are subject to AMFI (Apple Mobile File Integrity). Unsigned binaries get SIGKILL. Sign in `/tmp` then `mv` to `/opt/utmm/` — signing directly in `/opt/utmm/` may fail with "internal error in Code Signing subsystem" due to SIP restrictions.

### 3.4 Start Guest Service

#### During Bare-Metal Bootstrapping (Execute Directly in VM)

After the binary has been placed under `/opt/` via shared folder or other means, execute in the VM console or via one-time SSH:

```bash
# Temporary run (for debugging)
/opt/utmm/utmm &

# Install as system service (recommended, auto-start on boot)
/opt/utmm/utmm --install
```

#### After Guest Is Online (Remote Operation from Host)

Once the Guest starts, the Host can manage it remotely:

```bash
# Background start via --exec
utmm --exec linuxvm "nohup /opt/utmm/utmm &"

# Install auto-start on boot via --exec
utmm --exec linuxvm "/opt/utmm/utmm --install"
```

#### Auto-Start on Boot Reference

**macOS — launchd**:

```bash
# Install via --install (recommended)
utmm --install
# Creates /Library/LaunchDaemons/com.utmm.guest.plist and bootstraps

# Manual approach:
utmm --gen-init macos
# Generates plist content; place it in the VM's /Library/LaunchDaemons/com.utmm.guest.plist
# Then: sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmm.guest.plist
```

**Linux — systemd**:

```bash
# Install via --install (recommended)
utmm --install
# Creates /etc/systemd/system/utmm-guest.service, enables and starts

# Manual approach:
utmm --gen-init linux
# Generates unit file; place it in the VM's /etc/systemd/system/utmm-guest.service
# Then: systemctl daemon-reload && systemctl enable --now utmm-guest
```

**Windows — sc (Windows Service)**:

```bash
# Install via --install (recommended)
utmm --install
# Creates UTM-Monitor-Guest service with sc, starts immediately, adds firewall rule

# Manual approach:
utmm --gen-init windows
# Shows sc create command for manual setup
```

> On Windows, --install creates a proper Windows service (`UTM-Monitor-Guest`) via `sc create`, not a scheduled task. The service runs in its own session, survives SSH disconnect, and starts automatically on boot.

### 3.5 Start Host Service

The Host HTTP server serves cross-compiled binaries from a configurable directory (defaults to `/opt/utmm/`). This directory must contain the platform binaries produced by `zig build -Dtarget=...` or extracted from `utmm.zip`.

```bash
# Foreground (observe logs)
sudo utmm --host

# Custom serve directory (if binaries are not next to the executable)
sudo utmm --host --serve-dir /opt/utmm

# Background (note: redirect must be inside sudo, else Permission denied)
sudo sh -c 'nohup utmm --host > /var/log/utmm-host.log 2>&1 & disown'
```

After starting, the following output indicates normal operation:

```
[host] HTTP server on 0.0.0.0:2121
[host] Serve dir: /opt/utmm
[ws] Guest linuxvm connected (192.168.64.2 v0.8.2)
[host-http] /etc/hosts synced (1 guests)
```

Verify `/etc/hosts` has been updated:

```bash
grep -A 10 "UTM-MONITOR" /etc/hosts
```

### 3.6 Verification Checklist

| # | Check Item | Command | Expected Result |
|---|------------|---------|-----------------|
| 1 | Guest process running | `utmm --exec linuxvm "ps aux | grep utmm"` | Shows `/opt/utmm/utmm` process |
| 2 | Host receiving guests | `utmm --status` | Shows all Guests |
| 3 | /etc/hosts synced | `grep "UTM-MONITOR" /etc/hosts` | Contains entries for all VMs |
| 4 | Remote command channel | `utmm --exec linuxvm "uptime"` | Returns uptime |
| 5 | Shell persistence | `utmm --exec linuxvm "cd /tmp; pwd"` | Shows `/tmp` |
| 6 | WebSocket connected | Guest logs show `[guest-ws] Connected and announced` | Guest is online |
| 7 | Auto-upgrade | Bump ver.zig → build → deploy Host → wait 60s | Guest upgrades to new version |

---

## 4. Daily Usage

### 4.1 CLI Parameter Quick Reference

```
Usage: utmm [options]

Mode Selection:
  (no arguments)         Guest mode (default: foreground, stop service, run, restart on exit)
  --host                 Host mode
  --svc                  Run as daemon (launched by service mgr; non-TTY auto-detection also enables daemon mode)

Guest Options:
  --port PORT            Host port to connect to     (default 2121)
  --hostname NAME        Local hostname (auto-detect by default)
  --host-ip IP           Host IP (default: auto-detect via default gateway)
  --log-file PATH        Log output path

Host Options:
  --port PORT            HTTP listen port            (default 2121)
  --hosts-file PATH      Hosts file path            (default /etc/hosts)
  --serve-dir PATH       Static file serve directory (default: exe directory)
  --marker TAG           Hosts marker text          (default "UTM-MONITOR")
  --config PATH          Config file path
  --log-file PATH        Log output path
  --save-config          Save current configuration

Management Commands (HTTP to Host on 127.0.0.1:2121):
  --status               Query online status of all Guests (UDP broadcast discovery)
  --exec TARGET CMD      Execute command on target Guest (pty shell, streaming output, no timeout)
  --upload FILE VM       Upload a file to Guest
  --download VM R L      Download file from Guest
  --gen-init PLATFORM    Generate auto-start boot script (linux/macos/windows)
  --install              Install as system service (Guest mode; add --host for Host)
  --install --user       Create desktop shortcut (UTMM) for foreground guest launcher
  --uninstall            Remove system service and stop running processes
  --uninstall --user     Remove desktop shortcut
  --version              Display version and exit
  --mcp                  Deprecated; MCP now available automatically on --host :2121/mcp

Internal (set by utmm-old during auto-upgrade, not for manual use):
  --update-url URL       Download URL for new binary (upgrade mode)
```

### 4.2 Daily Operation Scenarios

#### View All VM Status

```bash
utmm --status
```

Example output:

```
Hostname         Target             IP               MAC                Version    Shell
-------------------------------------------------------------------------------------
linuxvm          aarch64-linux-musl 192.168.64.2     16:a0:6c:ba:ae:fa  v0.8.2     /bin/bash
macvm            aarch64-macos      192.168.64.4     1a:97:6d:38:0c:6c  v0.8.2     /bin/zsh
windowsvm        aarch64-windows    192.168.65.2     66:DC:DA:EC:A1:59  v0.8.2     cmd.exe
winx64           x86_64-windows     192.168.3.x      00:FF:4D:91:87:0B  v0.8.2     cmd.exe
```

#### Execute Commands on a Specific VM

```bash
# View system info
utmm --exec linuxvm "uname -a"
utmm --exec macvm "sw_vers"
utmm --exec windowsvm "ver"

# View load
utmm --exec linuxvm "uptime"

# View processes
utmm --exec macvm "ps aux | head -5"

# Shell persistence — cd and export work across commands
utmm --exec linuxvm "cd /tmp && pwd"     # Shows /tmp
utmm --exec linuxvm "export FOO=bar"     # Set env var
utmm --exec linuxvm "echo $FOO"          # Shows bar (persists in same shell)
```

#### Transfer Files

```bash
# Upload a local file to Guest (raw binary HTTP, no JSON wrapping)
utmm --upload ./local_file linuxvm

# Download a file from Guest (streaming chunked response)
utmm --download linuxvm remote_file ./local_file
```

> **Binary protocol**: Upload/download use raw binary HTTP body with
> `x-vm` and `x-path` custom headers — no JSON encoding overhead. Download
> streams via chunked transfer encoding with `x-exit-code` trailer for error
> reporting. Verify with MD5: `utmm --exec linuxvm "md5sum file.txt"`.

> **Important**: Both `--upload` and `--download` are limited to the Guest's `/opt/utmm/` directory (`C:\opt\utmm\` on Windows). The filename must be a **simple name without path separators** (`/` or `\`). For example:
> - ✅ `utmm --download linuxvm app.log ./app.log`
> - ❌ `utmm --download linuxvm /var/log/app.log ./app.log` (full path — returns error)
>
> To get files from outside `/opt/utmm/`, use `--exec` to copy them first:
> ```bash
> utmm --exec linuxvm "cp /var/log/syslog /opt/utmm/syslog.log"
> utmm --download linuxvm syslog.log ./syslog.log
> ```

#### Verify Transfer Integrity

```bash
# Check file size and MD5 after upload/download
utmm --exec linuxvm "ls -la /opt/utmm/file.txt && md5sum /opt/utmm/file.txt"
md5 -q ./local_file  # macOS; use md5sum on Linux
```

#### Trigger Auto-Upgrade

To release a new version:

```bash
# 1. Bump ver.zig
echo 'pub const VERSION = "0.8.2";' > src/ver.zig

# 2. Build all 8 targets (or use release-skill/build.sh)
zig build -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
# ... (all 8 targets)

# 3. Copy all binaries to Host serve dir
sudo cp zig-out/bin/utmm* /opt/utmm/

# 4. Restart Host (broadcasts new version, triggers auto-upgrade on all Guests)
sudo pkill utmm && sudo utmm --host &
```

Guests will auto-detect the new version within 60s (next periodic UDP broadcast) and self-upgrade. Notifications appear in Host logs.

#### Check Guest Logs

```bash
utmm --exec linuxvm "tail -20 /var/log/utmm.log"
```

#### Force Sync /etc/hosts

If you suspect the hosts file is out of sync:

```bash
# Restart Host
sudo pkill utmm
sudo utmm --host

# Check after a few seconds
grep -A 10 "UTM-MONITOR" /etc/hosts
```

### 4.3 Configuration File

`--save-config` writes a default configuration file for future use:

```bash
utmm --host --save-config
# Saves to ./utmm.conf (or custom path via --config)
```

---

## 5. Troubleshooting

### 5.1 Host Not Receiving Guest Connections

**Symptom**: `--status` shows empty or missing a VM

**Diagnosis Steps**:

```bash
# 1. Check if Guest process is running
utmm --exec linuxvm "ps aux | grep utmm"

# 2. Check Guest logs to confirm WebSocket connection
utmm --exec linuxvm "tail -5 /var/log/utmm.log"
# Normal log line: [guest-ws] Connected and announced

# 3. Check if the Guest's displayed IP is the correct physical NIC IP
# First log line shows: [broadcast] Physical NIC enp0s1: 192.168.64.2

# 4. Use tcpdump on Host to verify connections
sudo tcpdump -i any port 2121 -n
# Should see TCP connections from each VM

# 5. Check if port is occupied
sudo lsof -i :2121
```

### 5.2 Wrong IP Detected (Tunnel/VPN Interference)

**Symptom**: `--status` shows IP as `198.18.x.x` or other non-LAN IP instead of `192.168.x.x`

**Cause**: `utun`/`tun` virtual interfaces created by VPN programs are incorrectly identified as physical NICs.

**Solution**:
1. Confirm that the `isPhysicalInterface()` function in the code has excluded that interface prefix
2. View all interfaces on the Guest VM: `ifconfig -a` or `ip addr show`
3. If a new tunnel interface prefix appears, add it to `exclude_prefixes` in `src/broadcast.zig`
4. Bump ver.zig and rebuild

### 5.3 --exec Command Execution Failed

**Common Errors**:

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `GuestNotFound` | Guest not connected to Host | Wait a few seconds and retry; check if Guest is running |
| `ConnectionRefused` | Host HTTP server not running | `sudo utmm --host` |
| `disconnected` | Guest WebSocket closed during execution | Guest may have crashed; check `vm_status` |

### 5.4 Windows Guest Process Cannot Run in Background

**Symptom**: Process disappears when the window is closed after direct launch

**Solution**: Install as a Windows service via `--install` (creates `UTM-Monitor-Guest` service that auto-starts on boot):

```cmd
C:\opt\utmm\utmm.exe --install
```

The service runs in its own session and survives logout/disconnect. Firewall rule is automatically added. Or create a desktop shortcut for foreground mode: `C:\opt\utmm\utmm.exe --install --user` (creates `UTMM.bat` on the desktop).

### 5.5 /etc/hosts Not Updated

```bash
# 1. Confirm Host is running as sudo
ps aux | grep "utmm --host" | grep root

# 2. Check file permissions
ls -la /etc/hosts

# 3. Manually test write
sudo utmm --host &
sleep 5
grep "UTM-MONITOR" /etc/hosts
```

### 5.6 Compilation Failed

```bash
# Confirm Zig version
zig version
# Requires 0.16.0

# Clean cache and retry
rm -rf .zig-cache zig-out
zig build

# Check if link_libc is enabled
grep link_libc build.zig
# Output: .link_libc = true,
```

### 5.7 Port Conflict

If port 2121 is occupied by another program, it can be changed via the `--port` parameter:

```bash
# Guest side
utmm --port 12348

# Host side (ports must match Guest)
utmm --host --port 12348
```

### 5.8 WebSocket Connection Issues

**Symptom**: Guest logs show `[guest-ws] Connect failed` or `[guest-ws] Read error`

**Diagnosis**:

```bash
# 1. Is Host running?
utmm --status

# 2. Can Guest reach Host?
utmm --exec linuxvm "curl -s http://<gateway>:2121/"

# 3. Check Guest default gateway detection
# Guest should auto-detect the Host as the default gateway
# Override with: utmm --host-ip 192.168.64.1
```

### 5.9 Stale WebSocket After VM Suspend/Resume

**Symptom**: VM was suspended and resumed, but `--status` shows it as offline or exec commands time out.

**Cause**: VM suspend/resume can leave the WebSocket connection in a stale state — TCP connection appears open but the remote end is unreachable.

**Solution**: Restart the utmm guest service on the affected VM:
```bash
# Linux
utmm --exec linuxvm "systemctl restart utmm-guest"

# macOS
utmm --exec macvm "launchctl bootout system /Library/LaunchDaemons/com.utmm.guest.plist; launchctl bootstrap system /Library/LaunchDaemons/com.utmm.guest.plist"

# Windows
utmm --exec windowsvm "sc stop UTM-Monitor-Guest & sc start UTM-Monitor-Guest"
```

---

## 6. Reference Appendix

### 6.1 Project File Structure

```
utmm/
├── build.zig              # Build script (zero external dependencies)
├── build.zig.zon          # Package manifest
├── install.sh             # Host/guest one-click installation script
├── install.bat            # Windows batch installer (zero dependencies)
├── README.md              # Project overview
├── CLAUDE.md              # Development guide
├── zig-codegen.md         # Zig 0.16.0 coding experience notes
├── findings.md            # Architecture decisions and bug fixes
├── progress.md            # Development session log
├── task_plan.md           # Feature implementation plan
├── .github/
│   └── workflows/
│       └── release.yml    # CI: auto build and publish 6-target binaries on tag
├── release-skill/
│   └── SKILL.md           # Release workflow skill
├── utm-vm/
│   ├── SKILL.md           # Claude Code skill for VM management
│   └── MANUAL.md          # This manual
├── src/
│   ├── main.zig           # Entry point + CLI parsing + Windows service
│   ├── protocol.zig       # Protocol constants, UDP discovery, deployment filenames
│   ├── ver.zig            # Single version source (bump to trigger auto-upgrade)
│   ├── wsproto.zig        # Binary WebSocket protocol (1B type + payload)
│   ├── wsclient.zig       # Guest WebSocket client (TCP + HTTP upgrade + frame I/O)
│   ├── httpd.zig          # HTTP server core (accept loop, Router, HostState)
│   ├── host_http.zig      # HTTP endpoint handlers (/ws, /exec, /mcp, /bin/, etc.)
│   ├── guest.zig          # Guest mode: UpgradeSignal + WebSocket announce loop
│   ├── host.zig           # Host mode: management commands + HTTP server + periodic UDP broadcast
│   ├── broadcast.zig      # Guest core: ptySpawn, ptyReadLoop, wsAnnounceLoop, triggerSelfUpgrade
│   ├── upgrade.zig        # Auto-upgrade: utmm-old process (stop→kill→download→replace→start)
│   ├── hosts_file.zig     # /etc/hosts marker block read/write
│   ├── mcp.zig            # MCP JSON-RPC handler (reads HostState directly)
│   ├── install.zig        # --install/--uninstall + desktop shortcuts + --gen-init
│   ├── agent.zig          # Guest foreground mode (stop service, TTY, restart on exit)
│   └── config.zig         # Configuration persistence + logging
└── zig-out/
    └── bin/
        └── utmm*    # Build artifacts (6 platform binaries)
```

### 6.2 Technology Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Zig | 0.16.0 | Programming language |
| std.http.Server | Built-in | HTTP server + WebSocket upgrade |
| std.http.Client | Built-in | HTTP download (auto-upgrade) |
| libc | System | `getifaddrs` / `gethostname` / `getenv` / `posix_openpt` / `fork` / `execve` |
| launchd | macOS system | macOS auto-start on boot |
| systemd | Linux system | Linux auto-start on boot |
| sc | Windows system | Windows auto-start on boot (Windows Service, `--svc` flag) |

### 6.3 Binary Packaging (8 Binaries → All VMs)

Each release builds 8 binaries covering all architecture+OS combinations, packaged as `utmm.zip`:

| # | Binary | Build Target | Covers |
|---|--------|-------------|--------|
| 1 | `utmm-x86_64-linux` | `x86_64-linux-musl` | 64-bit x86 Linux VMs |
| 2 | `utmm-aarch64-linux` | `aarch64-linux-musl` | ARM64 Linux VMs |
| 3 | `utmm-x86-linux` | `x86-linux-musl` | 32-bit x86 Linux VMs |
| 4 | `utmm-x86_64-macos` | `x86_64-macos` | Intel Mac, Apple Silicon (physical, via Rosetta 2) |
| 5 | `utmm-aarch64-macos` | `aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) |
| 6 | `utmm-x86_64-windows.exe` | `x86_64-windows` | 64-bit x86 Windows VMs |
| 7 | `utmm-aarch64-windows.exe` | `aarch64-windows` | ARM64 Windows VMs |
| 8 | `utmm-x86-windows.exe` | `x86-windows-gnu` | 32-bit x86 Windows |

> **8 release targets** since v0.8.0. `x86-windows-gnu` used for 32-bit Windows to avoid MinGW `_system@4` linker warning that Zig promotes to error.

**Compatibility matrix** — which binary to use for each VM scenario:

| VM Scenario | Binary to Use | Notes |
|-------------|---------------|-------|
| Windows VM (x86_64) | `utmm-x86_64-windows.exe` | 64-bit x86 |
| Windows VM (ARM64) | `utmm-aarch64-windows.exe` | Native ARM64 |
| Windows VM (32-bit x86) | `utmm-x86-windows.exe` | x86-windows-gnu target |
| macOS VM on Intel Mac (UTM) | `utmm-x86_64-macos` | Native x86_64 |
| macOS VM on Apple Silicon (UTM) | `utmm-aarch64-macos` | UTM ARM VMs lack Rosetta 2; need native aarch64 |
| Physical Apple Silicon Mac (Host) | `utmm-x86_64-macos` | Rosetta 2 handles x86_64 → aarch64 translation |
| Physical Intel Mac (Host) | `utmm-x86_64-macos` | Native x86_64 |
| Linux VM (x86_64) | `utmm-x86_64-linux` | 64-bit musl static, no glibc dependency |
| Linux VM (x86 32-bit) | `utmm-x86-linux` | 32-bit musl static |
| Linux VM (aarch64) | `utmm-aarch64-linux` | aarch64 musl static |

### 6.4 Zig Cross-Compilation Target Reference

| Zig Target | Output Binary | Guest Platform |
|------------|---------------|----------------|
| `x86_64-linux-musl` | `utmm-x86_64-linux` | Linux 64-bit x86 (musl static) |
| `aarch64-linux-musl` | `utmm-aarch64-linux` | Linux aarch64 (musl static) |
| `x86-linux-musl` | `utmm-x86-linux` | Linux 32-bit x86 (musl static) |
| `x86_64-macos` | `utmm-x86_64-macos` | Intel Mac + Apple Silicon Mac (via Rosetta 2) |
| `aarch64-macos` | `utmm-aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) |
| `x86_64-windows` | `utmm-x86_64-windows.exe` | Windows 64-bit x86 |
| `aarch64-windows` | `utmm-aarch64-windows.exe` | Windows ARM64 |
| `x86-windows-gnu` | `utmm-x86-windows.exe` | Windows 32-bit x86 |

All Linux binaries are statically linked against musl — no glibc version dependency, runs on any Linux distribution.

### 6.5 Common Troubleshooting Commands Summary

```bash
# View VM architecture
utmm --exec linuxvm "uname -m"

# View all network interfaces on VM
utmm --exec linuxvm "ip addr show"

# View Guest logs
utmm --exec linuxvm "head -5 /var/log/utmm.log"

# Capture packets to verify connections
sudo tcpdump -i any port 2121 -n -c 10

# Verify Guest is online (via Host status)
utmm --status

# View Host process
ps aux | grep "utmm --host"

# Reload /etc/hosts (macOS)
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

### 6.6 Guest VM Information (Example)

| VM | Hostname | User | Password | Binary Path | SSH |
|----|----------|------|----------|-------------|-----|
| macvm | macvm | root | 111 | `/opt/utmm/utmm` | root@192.168.64.4 |
| linuxvm | linuxvm | root | 111 | `/opt/utmm/utmm` | root@192.168.64.2 |
| windowsvm | windowsvm | Administrator | 111 | `C:\opt\utmm\utmm.exe` | Administrator@192.168.65.2 |
| winx64 | winx64 | Administrator | 111 | `C:\opt\utmm\utmm.exe` | Administrator@192.168.3.x (key auth) |

> After the Guest starts, it is fully auto-updated; no further manual transfer is needed.

### 6.7 Troubleshooting Quick Reference

| Problem | Cause | Command |
|---------|-------|---------|
| `error.Unexpected` | Guest cannot obtain local IP | Check if VM has a valid network interface |
| `error.AccessDenied` | Host not running with sudo | `sudo utmm --host` |
| `error.ConnectionRefused` | Host HTTP server not started | `sudo utmm --host` |
| `GuestNotFound` | Guest not connected via WebSocket | Check if Guest process is running |
| Tunnel IP detected | VPN interface interference | utun/tun added to exclusion list |
| Windows process disappears | Direct launch without service | Use --install to install as Windows service |
| `zig-out/bin/utmm` is wrong arch | `zig build` overwrites with last target | Use named file e.g. `utmm-aarch64-macos` |
| Auto-upgrade not triggering | Guest UDP listener not receiving broadcasts | Check firewall; verify host and guest on same subnet |

---

## 7. Claude Code Integration (MCP Server)

utmm can be used as a Claude Code plugin via the Model Context Protocol (MCP). This lets Claude automatically discover and execute commands on your UTM VMs — without you typing CLI commands.

### 7.1 Architecture

```
Claude Code
  │ MCP (JSON-RPC over HTTP, streamableHttp transport)
  ▼
utmm --host     ← Host daemon (unified HTTP server on :2121)
  │ WebSocket (binary frames) + HTTP REST + UDP broadcast
  ▼
Guest VMs (linuxvm, macvm, windowsvm, winx64)
  │
  └─ WebSocket (2121): pty shell session (announce, pty_input, pty_output)
  └─ UDP (2121): version check → auto-upgrade trigger
```

The Host daemon (`utmm --host`) serves MCP JSON-RPC over HTTP on `127.0.0.1:2121/mcp` using the streamableHttp transport — the same port and process as everything else. Claude Code connects directly via TCP. The Host's in-memory guest cache provides instant responses without discovery per request.

### 7.2 Full Setup Walkthrough (from zero to working)

**Prerequisites:**
- UTM VMs must be booted with `utmm` running inside each guest
- No extra dependencies — the MCP server is built into the `utmm` binary
- No Zig toolchain needed — binaries are precompiled

**Step 1: Download Host binary**

```bash
sudo curl -fsSL https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm-x86_64-macos \
  -o /usr/local/bin/utmm
sudo chmod +x /usr/local/bin/utmm
```

> Alternative: use the install script which auto-detects your architecture:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
> ```

**Step 2: Download Guest binaries (for Guest auto-upgrade)**

```bash
sudo mkdir -p /opt/utmm
sudo curl -fsSL \
  "https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.zip" \
  -o "/opt/utmm/utmm.zip"
cd /opt/utmm && sudo unzip -o utmm.zip && sudo rm utmm.zip
sudo chmod +x /opt/utmm/*
```

**Step 3: Register MCP server with Claude Code**

```bash
claude mcp add utm-monitor --transport streamableHttp http://127.0.0.1:2121/mcp
```

Or manually edit `~/.claude/mcp.json`:

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

> The Host must be running (`sudo utmm --host`) for the MCP server to be available.
> Run `/mcp` in Claude Code to reload the MCP configuration.

**Step 4: Start the Host**

```bash
sudo utmm --host --serve-dir /opt/utmm
```

Expected output:

```
[host] HTTP server on 0.0.0.0:2121
[host] Serve dir: /opt/utmm
```

To auto-start on boot (LaunchDaemon):

```bash
sudo utmm --host --install
```

**Step 5: Verify the MCP connection**

```bash
curl -s -X POST http://127.0.0.1:2121/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
# → {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"utmm","version":"0.7.0"},"capabilities":{"tools":{}}}}
```

### 7.3 Available Tools

| Tool | What it does | Example |
|------|-------------|---------|
| `vm_status` | List all VMs: hostname, IP, OS/arch, MAC, version, shell | `vm_status()` |
| `vm_exec` | Execute a shell command on a VM (pty session, cd/export persist) | `vm_exec("linuxvm", "uname -a")` |

### 7.4 Daily Usage Examples

#### Checking VM health

```
👤 "How are the VMs doing?"
🤖 → vm_status()
    linuxvm:     aarch64-linux-musl 192.168.64.2   ✓
    macvm:       aarch64-macos    192.168.64.4   ✓
    windowsvm:   aarch64-windows  192.168.65.2   ✓
    winx64:      x86_64-windows   192.168.3.x   ✓
```

#### Cross-platform testing

```
👤 "I just changed the broadcast module. Test it on all platforms."
🤖 → vm_exec("linuxvm", "cd /opt && ./utmm --version")
    → vm_exec("macvm", "cd /opt && ./utmm --version")
    → vm_exec("windowsvm", "C:\\opt\\utmm.exe --version")
    → vm_exec("winx64", "C:\\opt\\utmm.exe --version")
    All four return v0.8.2 ✓
```

#### Debugging a specific VM

```
👤 "linuxvm seems slow, what's going on?"
🤖 → vm_exec("linuxvm", "top -b -n 1 | head -10")     # CPU usage
    → vm_exec("linuxvm", "free -h")                    # memory
    → vm_exec("linuxvm", "df -h")                      # disk
    → vm_exec("linuxvm", "dmesg | tail -20")           # kernel messages
```

### 7.5 CLI vs MCP — When to Use Which

| Scenario | Use |
|----------|-----|
| Quick status check | `utmm --status` |
| One-shot command | `utmm --exec linuxvm "..."` |
| Interactive debugging | Claude Code with MCP tools |
| Multi-step testing across VMs | Claude Code with MCP tools |
| Deploy-test-verify loop | Claude Code with MCP tools |
| Setting up a new VM | Claude Code with MCP tools |
| CI / bash scripts | CLI commands |

### 7.6 Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| MCP tools don't appear in Claude | MCP server not registered or Host not running | Verify Host daemon running (`ps aux | grep utmm`); check port 2121 (`curl http://127.0.0.1:2121/mcp`); run `/mcp` to reload |
| "No VMs online" | VMs not booted, guest not running | Boot VMs, verify `utmm` running inside each |
| "GuestNotFound" for a VM | VM offline or hostname typo | `vm_status` to see online VMs |
| MCP connection refused | Host daemon not running | `sudo utmm --host` |
| Port 2121 AddressInUse at Host start | Old `utmm` process still running | `sudo pkill -f utmm && sudo utmm --host` |
| WebSocket connection failed | Guest can't reach Host gateway | Check guest gateway detection; use `--host-ip` to override |
| Command hangs or produces no output | Guest disconnected mid-command or shell dead | Check `vm_status`; wait for auto-reconnect or restart guest |

### 7.7 Complete Uninstall / Cleanup

**Host side**:
```bash
# Stop all processes
sudo pkill -f utmm 2>/dev/null

# Remove auto-start service
sudo launchctl bootout system /Library/LaunchDaemons/com.utmm.host.plist 2>/dev/null
sudo launchctl bootout system /Library/LaunchDaemons/com.utmm.plist 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.utmm.host.plist /Library/LaunchDaemons/com.utmm.plist

# Remove binaries
sudo rm -rf /opt/utmm
sudo rm -f /usr/local/bin/utmm

# Clean /etc/hosts
sudo sed -i '' '/# UTM-MONITOR-BEGIN/,/# UTM-MONITOR-END/d' /etc/hosts
```

**Linux Guest**:
```bash
systemctl stop utmm-guest 2>/dev/null; systemctl disable utmm-guest 2>/dev/null
systemctl stop utmm 2>/dev/null; systemctl disable utmm 2>/dev/null
rm -f /etc/systemd/system/utmm-guest.service /etc/systemd/system/utmm.service
rm -rf /opt/utmm /opt/utm-monitor /opt/utmm_*
rm -f /var/log/utmm*.log /opt/utmm*.log
pkill -f utmm 2>/dev/null
```

**macOS Guest**:
```bash
pkill -f utmm 2>/dev/null
launchctl bootout system /Library/LaunchDaemons/com.utmm.guest.plist 2>/dev/null
launchctl bootout system /Library/LaunchDaemons/com.utmm.plist 2>/dev/null
rm -f /Library/LaunchDaemons/com.utmm.guest.plist /Library/LaunchDaemons/com.utmm.plist
rm -rf /opt/utmm /opt/utm-monitor /opt/utmm_*
rm -f /var/log/utmm*.log /opt/utmm*.log
```

**Windows Guest**:
```cmd
taskkill /f /im utmm.exe
sc stop UTM-Monitor-Guest 2>nul & sc delete UTM-Monitor-Guest 2>nul
sc stop UTM-Monitor 2>nul & sc delete UTM-Monitor 2>nul
rmdir /s /q C:\opt\utmm
del C:\opt\utmm*.log 2>nul
```

### 7.8 Skill (Bundled)

The `utm-vm/SKILL.md` file provides Claude with detailed knowledge about:
- When to use each tool in different debugging scenarios
- Shell escaping patterns per platform (bash vs cmd.exe)
- Shell persistence behavior (cd, export work across vm_exec calls)
- Common workflows: health checks, cross-platform testing, debugging, setup
- Auto-upgrade process and how to trigger new version deployment
- Error recovery procedures

The skill activates automatically when you mention VM names, cross-platform testing, or UTM.
