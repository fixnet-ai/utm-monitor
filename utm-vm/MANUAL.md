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

UTM virtual machines obtain IP addresses via DHCP, and the IP may change after every reboot or network change. Manually maintaining IP mappings in the Host `/etc/hosts` is tedious. This tool implements **fully automatic IP discovery and synchronization**: Guests automatically announce their IP to the Host upon startup, and the Host automatically updates `/etc/hosts` -- no manual intervention required.

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
| Responsibility | UDP broadcast of its own info | Listen for broadcasts + sync /etc/hosts |
| Ancillary Services | HTTP server (2121): file upload/download + exec | IPC service (12347) + management commands (--status/--exec/--deploy) |
| Required Privileges | Regular user | `sudo` (to write /etc/hosts) |

### 1.3 Data Flow Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Host (Host Machine)                          │
│                                                                      │
│  ┌─────────────┐    ┌──────────────────┐    ┌──────────────────┐     │
│  │ /etc/hosts   │◄───│ hosts_file module │◄───│ listener         │     │
│  │              │    │ (marker block     │    │ (12345 UDP)      │     │
│  └─────────────┘    │  update)           │    └────────┬─────────┘     │
│                     └──────────────────┘             ▲               │
│                                          UDP broadcast (255.255.255.255:12345)
│                                          One ANNOUNCE message per second
│                                    ┌──────┼──────┐                   │
│                                    ▼      ▼      ▼                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                      │
│  │  macvm     │  │  linuxvm   │  │ windowsvm  │   ← Guest side       │
│  │            │  │            │  │            │                      │
│  │ broadcast  │  │ broadcast  │  │ broadcast  │   UDP broadcast       │
│  │ HTTP(2121) │  │ HTTP(2121) │  │ HTTP(2121) │   File transfer + exec │
│  └────────────┘  └────────────┘  └────────────┘                      │
│                                                                      │
│  ┌──────────────────────────────────────────┐                        │
│  │ IPC Service (127.0.0.1:12347 TCP)         │  ← Host internal       │
│  │ --status / --exec / --deploy forwarding   │   CLI → persistent     │
│  └──────────────────────────────────────────┘                        │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.4 Communication Protocols

#### UDP Broadcast Messages (Guest → Host, Port 12345)

The Guest sends one ANNOUNCE message per second to `255.255.255.255:12345`:

```
ANNOUNCE
hostname: ubuntu
target: aarch64-linux-musl
mac: 16:a0:6c:ba:ae:fa
ip: 192.168.64.2
http: 2121
version: 0.1.0
<blank line>
```

| Field | Description | Example Value |
|-------|-------------|---------------|
| `hostname` | OS hostname | `ubuntu`, `my-dev-box` |
| `target` | Zig cross-compilation target triple | `aarch64-linux-musl`, `x86_64-windows` |
| `mac` | Physical NIC MAC address | `1a:97:6d:38:0c:6c` |
| `ip` | Physical NIC IPv4 | `192.168.64.2` |
| `http` | HTTP service port | `2121` |
| `version` | Program version | `0.1.0` |

**AI Agent Integration**: `--status` output directly shows each VM's `target`, allowing AI agents to use `zig build -Dtarget=<target>` for cross-compilation.

In addition to parsing the `ip` field from the message, the Host also extracts the real IP from the **UDP packet source address**. When a Guest self-reports its IP as `0.0.0.0` or `127.x.x.x` (e.g., a Windows Guest cannot detect its own IP), the Host automatically uses the packet source address as the IP.

#### HTTP Service (Port 2121)

The Guest runs an HTTP server on port 2121 with these endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check |
| `/version` | GET | Return current version |
| `/update` | GET | Return bootstrap update script |
| `/bin/:filename` | GET | Download a file |
| `/upload?filename=X` | POST | Upload a file (multipart/form-data) |
| `/exec` | POST | Execute a shell command (JSON: `{"cmd":"..."}`) |

**Thread model**: one thread per connection, using `std.http.Server` from the Zig standard library. The shell is automatically selected based on the operating system:
- **macOS / Linux**: `/bin/sh -c <cmd>`
- **Windows**: `cmd /c <cmd>`

The Host also runs an HTTP server on port 2121, but read-only — serving `/version`, `/update`, and `/bin/:filename` for Guest auto-updates.

#### /etc/hosts Marker Block

The Host maintains a marker block in `/etc/hosts`, using FQDN format `{hostname}.{target}.utm` for naming:

```
# Normal hosts entries...
127.0.0.1  localhost

# UTM-MONITOR-BEGIN
192.168.64.2  ubuntu.aarch64-linux-musl.utm
192.168.64.4  macvm.aarch64-macos.utm
192.168.65.2  WIN-PC.aarch64-windows.utm
# UTM-MONITOR-END
```

The `target` in the FQDN is the Zig cross-compilation target triple, directly usable for `zig build -Dtarget=` and the `--deploy` command.

#### IPC Command Forwarding (Host Internal, Port 12347)

The persistent Host process starts a TCP IPC service on `127.0.0.1:12347`, accepting local management command forwarding. When executing management commands such as `--status`/`--exec`/`--deploy`, the CLI process does not directly bind a UDP port; instead, it connects to the IPC port and forwards the command to the persistent Host for execution.

```
CLI Process                     Persistent Host Process
────────                        ──────────────────────
1. Parse --status
2. Connect 127.0.0.1:12347 ──→ 3. Accept connection
                                4. Read "STATUS\n\n"
                                5. Lock → snapshot Guest list → format
                                6. Send "OK\n<output>" + close
7. Read byte by byte until EOF
8. Print output
9. exit(0)
```

**Key Design Decisions**:
- IPC binds only to `127.0.0.1` (localhost loopback), not accessible from external networks
- Connection closed after response, providing a simple and reliable EOF marker
- When the Host is not running, CLI automatically falls back to direct UDP mode (behavior unchanged)
- IPC thread only performs read-only access to the shared Guest list (locked); formatting and deploy compilation execute outside the lock

### 1.5 Physical NIC Detection

When the Guest starts, it needs to obtain the IPv4 address of the local physical NIC. The common "connect to 8.8.8.8 to get local IP" approach is easily disrupted by VPN tunnel interfaces (tun/utun/wintun), returning an incorrect IP (e.g., `198.18.0.1`).

This tool uses the `getifaddrs()` system call on **macOS / Linux** to enumerate all network interfaces and **automatically excludes** the following virtual interfaces:

```
utun*, tun*, tap*, llw*, awdl*, bridge*, vmnet*, docker*, gif*, stf*, veth*, vboxnet*, virbr*, lo*
```

On **Windows**, the Guest self-reports its IP as `0.0.0.0` (fallback value), and the Host extracts the real IP from the UDP packet source address.

---

## 2. Network Requirements

### 2.1 Port Checklist

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 12345 | UDP | Guest → Host | Broadcast ANNOUNCE |
| 12347 | TCP | Local (127.0.0.1) | IPC command forwarding (--status/--exec/--deploy) |
| 2121 | TCP | Bidirectional | HTTP: Guest file upload + exec / Host file serving (serve directory) |

### 2.2 Network Topology Requirements

**Guest and Host must be on the same broadcast domain**. Specifically:

- Guest sends UDP broadcast to `255.255.255.255:<port>`
- Host listens on `0.0.0.0:<port>`
- No router/NAT between them must block broadcast packets

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

### 2.3 Host One-Click Installation (First-time Deployment on New Mac)

Install on the Host side (the Mac running UTM) with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
```

The script downloads `utmm.zip` from GitHub Releases, extracts all 8 platform binaries to `/opt/utmm/`, auto-detects the Host architecture, and creates symlinks:

- `/opt/utmm/utmm` → `/opt/utmm/utmm-{arch}-{os}` (Host binary)
- `/usr/local/bin/utmm` → `/opt/utmm/utmm` (convenience)

All Guest binaries are already in `/opt/utmm/` after extraction — the Host's `serve_dir` defaults to this directory, so auto-upgrade works for all Guest architectures immediately.

Start the Host:

```bash
sudo utmm --host --install   # Install as Host system service, auto-start on boot
sudo utmm --host             # Start immediately
```

> **Note**: Use `--host --install` to generate a Host-mode service config (with `--host` flag included). Use just `--install` (without `--host`) on Guest VMs to self-install as a Guest-mode service. The same binary auto-detects the correct mode based on the presence of `--host`.

### 2.4 Bare-Metal Bootstrapping (First-time Guest VM Deployment)

A brand-new VM has no utmm running. After the Host starts `utmm --host`, it automatically provides a read-only HTTP server on port 2121 (serving the cross-compiled binaries from `/opt/utmm/`). The unified `install.sh` handles both Host and Guest deployment.

**Deployment order is always: Host first, then Guests.**

**Linux / macOS Guest** — one command (no internet needed, everything from Host HTTP):

```bash
# Find the gateway IP (Host's bridge address), then:
curl "http://<gateway>:2121/bin/install.sh" | sh -s -- --guest --hostname myvm

# Or detect gateway automatically:
GATEWAY=$(ip route | grep default | awk '{print $3}')
curl "http://$GATEWAY:2121/bin/install.sh" | sh -s -- --guest --hostname linuxvm
```

**Windows Guest** (PowerShell as Administrator):

```powershell
# Find the gateway IP (Host's bridge address), then:
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").NextHop | Select -First 1
iwr "http://${gw}:2121/bin/install.ps1" -OutFile install.ps1
.\install.ps1 -Guest -Hostname windowsvm
```

**What the script does automatically:**
1. Detects CPU architecture (`aarch64` / `x86_64` / `x86`) — no manual `uname -m` needed
2. Detects OS and finds the default gateway (the Host's bridge IP)
3. Downloads the correct binary from `http://<gateway>:2121/bin/utmm-{arch}-{os}[.exe]`
4. Creates `/opt/utmm/` (or `C:\opt\utmm\` on Windows) and installs the binary
5. Creates convenience symlinks (`/usr/local/bin/utmm` on Unix)
6. Installs auto-start service via `utmm --install`
7. Starts the Guest immediately with the given `--hostname`

> **Prerequisite**: The Host must be running `sudo utmm --host` and the gateway must be reachable from the Guest. If the gateway detection fails, the script probes common UTM bridge IPs (192.168.64.1, 192.168.65.1, 192.168.66.1).

**Other Alternative Methods** (if Host HTTP is unreachable):

- UTM shared folder mount `zig-out/bin/` → manual copy
- One-time SCP: `scp utmm-{target} root@<vm>:/opt/utmm/utmm`
- Direct `/update` endpoint: `curl -s "http://<gateway>:2121/update?name=myvm" | sh` (returns a generated shell script)

After the Guest starts, it begins UDP broadcast + HTTP server (2121). **From then on, Host-side `--deploy` is fully automatic.**

---

## 3. Quick Deployment

### 3.1 Environment Preparation

**Host Side (your Mac):**
- Method 1 (Recommended): Use install.sh for one-click installation (see §2.3), no Zig installation required
- Method 2 (Development Mode): Zig 0.16.0 (`brew install zig`) + sudo privileges

**Guest Side (VM):**
- Target path must exist: `/opt/` (`C:\opt\` on Windows)
- Bare-metal bootstrapping: Host HTTP `/update` endpoint (see §2.4), or UTM shared folder
- After initial bootstrapping, fully managed by Host-side `--deploy` or automatic upgrade (Host auto-pushes new binary on version mismatch)

### 3.2 Confirm VM Architecture

The target architecture depends on your VM's actual architecture. How to query:

```bash
# After Guest is online, query with --exec
utmm --host --exec ubuntu "uname -m"      # aarch64 → aarch64-linux-musl
utmm --host --exec macvm "uname -m"        # arm64  → aarch64-macos

# Or check the target field in --status output
utmm --host --status
```

### 3.3 Obtain the Binary

**Method 1: GitHub Releases (Recommended, no local compilation needed)**

Each release automatically builds 8 binaries for all VM scenarios, packaged as `utmm.zip`:

| File | Covers | Zig Target |
|------|--------|------------|
| `utmm-x86-linux` | 32-bit x86 Linux VMs | x86-linux-musl |
| `utmm-x86_64-linux` | 64-bit x86 Linux VMs | x86_64-linux-musl |
| `utmm-aarch64-linux` | ARM64 Linux VMs | aarch64-linux-musl |
| `utmm-x86_64-macos` | Intel Mac + Apple Silicon Mac (physical) | x86_64-macos |
| `utmm-aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) | aarch64-macos |
| `utmm-x86-windows.exe` | 32-bit x86 Windows VMs | x86-windows |
| `utmm-x86_64-windows.exe` | 64-bit x86 Windows VMs | x86_64-windows |
| `utmm-aarch64-windows.exe` | ARM64 Windows VMs | aarch64-windows |

> **macOS Rosetta 2 note**: Apple Silicon **physical** Macs can run `utmm-x86_64-macos` (x86_64) via Rosetta 2. However, UTM ARM macOS **VMs** lack Rosetta 2, so they need `utmm-aarch64-macos` (native aarch64). If you need Rosetta 2 on a physical Mac: `softwareupdate --install-rosetta`.

Download URL: `https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.zip`

For the Host side, using `install.sh` (§2.3) is recommended; for the Guest side, using the `/update` virtual endpoint (§2.4) is recommended.

**Method 2: Local Compilation**

```bash
git clone https://github.com/fixnet-ai/utm-monitor.git
cd utmm

# Native build
zig build -Doptimize=ReleaseSafe

# Cross-compile for each platform (8 targets cover all scenarios)
zig build -Dtarget=x86-linux-musl       -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-linux-musl   -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl  -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-macos        -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos       -Doptimize=ReleaseSafe
zig build -Dtarget=x86-windows         -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows      -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-windows     -Doptimize=ReleaseSafe
```

Build artifacts:
- `zig-out/bin/utmm` — native binary (current platform)
- `zig-out/bin/utmm-x86-linux` — Linux 32-bit x86 musl static
- `zig-out/bin/utmm-x86_64-linux` — Linux 64-bit x86 musl static
- `zig-out/bin/utmm-aarch64-linux` — Linux aarch64 musl static
- `zig-out/bin/utmm-x86_64-macos` — macOS x86_64 (Intel + Apple Silicon via Rosetta 2)
- `zig-out/bin/utmm-aarch64-macos` — macOS aarch64 (ARM VMs without Rosetta 2)
- `zig-out/bin/utmm-x86-windows.exe` — Windows 32-bit x86
- `zig-out/bin/utmm-x86_64-windows.exe` — Windows 64-bit x86
- `zig-out/bin/utmm-aarch64-windows.exe` — Windows ARM64
- `zig-out/bin/utmm` — Linux x86_64 musl (also covers x86 Linux)
- `zig-out/bin/utmm-aarch64-linux` — Linux aarch64 musl
- `zig-out/bin/utmm-x86_64-macos` — macOS x86_64 (Intel + Apple Silicon via Rosetta 2)
- `zig-out/bin/utmm-aarch64-macos` — macOS aarch64 (ARM VMs without Rosetta 2)
- `zig-out/bin/utmm.exe` — Windows 32-bit x86 (covers all Windows via emulation)

> **Note**: The build system (`build.zig`) automatically produces deployment filenames alongside the main binary.

Run tests to confirm correctness:

```bash
zig build test --summary all
```

### 3.4 Bare-Metal Bootstrapping (First Time)

For the first deployment on a brand-new VM, you need to manually transfer the binary into it. See [2.4 Bare-Metal Bootstrapping](#24-bare-metal-bootstrapping-first-time-guest-vm-deployment), choose any method to place the build artifact under `/opt/` on the VM and start it.

### 3.5 --deploy One-Click Deployment (Subsequent Updates)

Once the Guest is running, use `--deploy` for subsequent updates -- **no SSH required**:

```bash
# One-click compile + deploy to all online Guests
utmm --host --deploy

# Deploy only to a specific VM
utmm --host --deploy ubuntu
```

Internal flow: compile → create directory via HTTP exec → HTTP upload → HTTP exec restart command. Entirely uses built-in channels with zero external dependencies.

### 3.6 Start Guest Service

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
utmm --host --exec ubuntu "nohup /opt/utmm/utmm &"

# Install auto-start on boot via --exec
utmm --host --exec ubuntu "/opt/utmm/utmm --install"
```

#### Auto-Start on Boot Reference

**macOS — launchd**:

```bash
# Execute in VM or via --exec
utmm --host --gen-init macos
# Generates plist content; place it in the VM's /Library/LaunchDaemons/com.utmm.plist
# Then launchctl load /Library/LaunchDaemons/com.utmm.plist
```

**Linux — systemd**:

```bash
# Execute in VM or via --exec
utmm --host --gen-init linux
# Generates unit file; place it in the VM's /etc/systemd/system/utmm.service
# Then systemctl daemon-reload && systemctl enable --now utmm
```

**Windows — Task Scheduler**:

```bash
# Execute in VM or via --exec
utmm --host --gen-init windows
# Generates script; use with schtasks to create a scheduled task:
# schtasks /create /tn utmm /tr "C:\opt\utmm\utmm.exe" /sc ONSTART /ru SYSTEM /f
# schtasks /run /tn utmm
```

### 3.7 Start Host Service

The Host HTTP server serves cross-compiled binaries from a configurable directory (defaults to `/opt/utmm/`, or `C:\opt\utmm\` on Windows). This directory must contain the deployment binaries (e.g., `utmm-aarch64-linux`, `utmm-x86_64-macos`, `utmm-x86-windows.exe`) produced by `zig build -Dtarget=...` or extracted from `utmm.zip`.

```bash
# Foreground (observe logs)
sudo utmm --host

# Custom serve directory (if binaries are not next to the executable)
sudo utmm --host --serve-dir /opt/utm-binaries

# Background
sudo nohup utmm --host > /var/log/utmm-host.log 2>&1 & disown
```

After starting, the following output indicates normal operation:

```
[host] Starting to listen for Guest broadcasts...
[listener] Listening on port 12345
[listener] 🆕 Discovered new guest: macvm (192.168.64.4)
[listener] 🆕 Discovered new guest: linuxvm (192.168.64.2)
[listener] 🆕 Discovered new guest: windowsvm (192.168.65.2)
```

Verify `/etc/hosts` has been updated:

```bash
grep -A 10 "UTM-MONITOR" /etc/hosts
```

### 3.8 Deployment Verification Checklist

| # | Check Item | Command | Expected Result |
|---|------------|---------|-----------------|
| 1 | Guest process running | `utmm --host --exec ubuntu "ps aux \| grep utmm"` | Shows `/opt/utmm/utmm` process |
| 2 | Host receiving broadcasts | `utmm --host --status` | Shows all Guests |
| 3 | /etc/hosts synced | `grep "UTM-MONITOR" /etc/hosts` | Contains entries for 3 VMs |
| 4 | Remote command channel | `utmm --host --exec ubuntu "uptime"` | Returns uptime |
| 5 | HTTP service | `utmm --host --status` (shows all VMs online) | Returns guest list with versions |

---

## 4. Daily Usage

### 4.1 CLI Parameter Quick Reference

```
Usage: utmm [options]

Mode Selection:
  (no arguments)         Guest mode (default)
  --host                 Host mode

Guest Options:
  --port PORT            UDP broadcast port         (default 12345)
  --http-port PORT       HTTP server port           (default 2121)
  --hostname NAME        Local hostname (auto-detect by default)
  --log-file PATH        Log output path

Host Options:
  --port PORT            UDP listen port            (default 12345)
  --hosts-file PATH      Hosts file path            (default /etc/hosts)
  --serve-dir PATH       HTTP serve directory       (default: exe directory)
  --marker TAG           Hosts marker text          (default UTM-MONITOR)
  --config PATH          Config file path
  --log-file PATH        Log output path

Host Management Commands:
  --status               Query online status of all Guests
  --exec TARGET CMD      Execute command on target Guest
  --deploy [TARGET]      Compile and deploy to VM
  --upload FILE VM       Upload a file to Guest (via HTTP, no curl)
  --download VM R L      Download file from Guest (via HTTP GET /bin/...)
  --gen-init PLATFORM    Generate auto-start boot script (linux/macos/windows)
  --install              Install as system service (Guest mode auto-start; add --host for Host mode)
  --uninstall            Remove system service and stop running processes
  --watch [PATH]         Watch directory for automatic deployment
  --save-config          Save current configuration
  --version              Display version
```

### 4.2 Daily Operation Scenarios

#### View All VM Status

```bash
utmm --host --status
```

Example output:

```
Hostname         Target             IP               MAC                 Version   Status
-------------------------------------------------------------------------------------
ubuntu           aarch64-linux-musl 192.168.64.2     16:a0:6c:ba:ae:fa  v0.1.0     ✓
macvm            aarch64-macos      192.168.64.4     1a:97:6d:38:0c:6c  v0.1.0     ✓
WIN-PC           aarch64-windows    192.168.65.2     66:DC:DA:EC:A1:59  v0.1.0     ✓
```

If versions differ, it displays `⚠ Upgradable`, prompting you to redeploy.

#### Execute Commands on a Specific VM

```bash
# View system info
utmm --host --exec linuxvm "uname -a"
utmm --host --exec macvm "sw_vers"
utmm --host --exec windowsvm "ver"

# View load
utmm --host --exec linuxvm "uptime"

# View processes
utmm --host --exec macvm "ps aux | head -5"

# Execute complex commands
utmm --host --exec linuxvm "df -h && free -m"
```

#### Transfer Files via HTTP

```bash
# Upload a file to Guest (built-in, no curl required)
utmm --host --upload ./local_file linuxvm

# Download a file from Guest
utmm --host --download linuxvm remote_file ./local_file
```

> **Under the hood**: `--upload` uses HTTP POST `/upload` with multipart/form-data; `--download` uses HTTP GET `/bin/:filename`. Both use `std.http.Client` — zero external dependencies.

#### Update the Binary

```bash
# One-click compile + deploy (recommended, zero SSH dependencies)
utmm --host --deploy

# Update only a specific VM
utmm --host --deploy ubuntu
```

#### Automatic Upgrade (Host-Push)

The Host automatically upgrades any Guest whose version doesn't match. No Guest polling, no curl scripts.

**How it works:**
1. Guest broadcasts ANNOUNCE with its version every second
2. Host compares Guest version with its own (`src/ver.zig`)
3. If mismatch → Host HTTP-uploads the correct binary (from serve-dir) + remote-restarts the Guest
4. Guest restarts with new version, broadcasts again → version matches, done

**To trigger**: bump `src/ver.zig`, `zig build`, restart Host. All online Guests upgrade within seconds.

**Debounce**: upgrades only trigger once per Guest per session. After restart, the new ANNOUNCE carries the updated version, so no repeat.

#### Check Guest Logs

```bash
utmm --host --exec ubuntu "tail -20 /opt/utmm/utmm.log"
```

#### Force Sync /etc/hosts

If you suspect the hosts file is out of sync:

```bash
# Restart Host listener
sudo pkill utmm
sudo utmm --host

# Check after a few seconds
grep -A 10 "UTM-MONITOR" /etc/hosts
```

### 4.3 Configuration File

`--save-config` persists current parameters to a file, automatically loaded on next startup:

```bash
utmm --host --port 12345 --save-config
# Saves to ./utmm.conf

cat utmm.conf
# port=12345
```

### 4.4 Version Upgrade Process

#### Fully Automatic Upgrade (Host-Push)

The **Host** drives all upgrades. When a Guest broadcasts ANNOUNCE with a version that doesn't match the Host's (`src/ver.zig`), the Host immediately:
1. Finds the correct binary in the serve directory by mapping the Guest's target triple to the deployment filename (e.g., `utmm-x86_64-linux` for x86_64-linux-musl, `utmm-aarch64-windows.exe` for aarch64-windows)
2. HTTP-uploads it to Guest `/upload` as `.new`
3. HTTP-executes a background restart command on Guest

No Guest polling, no shell scripts with curl, no `/update` endpoint needed. The Guest just broadcasts — the Host does the rest.

**To release a new version:**
1. Bump `src/ver.zig`
2. `zig build -Doptimize=ReleaseSafe` (and cross-compile for all targets)
3. Restart Host: `sudo pkill utmm && sudo utmm --host`
4. All online Guests auto-upgrade within seconds

#### Manual Upgrade

**Host Side**:
```bash
# Method 1: Re-run install.sh (recommended — downloads from GitHub Releases)
curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
sudo pkill utmm
sudo utmm --host &

# Method 2: Build from source
cd utmm && git pull && zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/utmm /usr/local/bin/utmm
```

**Guest Side** (manual intervention — Host auto-push is preferred):
```bash
# Host-side one-click deployment (builds + uploads + restarts)
utmm --host --deploy

# Or bootstrap: download from Host HTTP and pipe to shell (one-time, needs curl)
curl -s "http://<host-ip>:2121/update" | sh
```

#### CI Release Process (Developers)

```bash
# 1. Bump version in src/ver.zig
# 2. Tag and push
git tag v0.1.0
git push origin v0.1.0

# 3. GitHub Actions auto: test → 5-target cross-compile → publish Release
# 4. Host auto-pushes upgrade to all Guests on version mismatch
```

---

## 5. Troubleshooting

### 5.1 Host Not Receiving Broadcasts

**Symptom**: `--status` shows empty or missing a VM

**Diagnosis Steps**:

```bash
# 1. Check if Guest process is running
utmm --host --exec ubuntu "ps aux | grep utmm"

# 2. Check Guest logs to confirm broadcasts are being sent
utmm --host --exec ubuntu "tail -5 /opt/utmm/utmm.log"
# Normal log line: [broadcast] Broadcast: linuxvm → 192.168.64.2

# 3. Check if the Guest's displayed IP is the correct physical NIC IP
# First log line shows: [broadcast] Physical NIC enp0s1: 192.168.64.2
# If it shows a tun/utun interface, tunnel filtering is not working

# 4. Use tcpdump on Host to verify packets are received
sudo tcpdump -i any port 12345 -n
# Should see UDP packets from each VM

# 5. Check if port is occupied
lsof -i :12345
```

### 5.2 Wrong IP Detected (Tunnel/VPN Interference)

**Symptom**: `--status` shows IP as `198.18.x.x` or other non-LAN IP instead of `192.168.x.x`

**Cause**: `utun`/`tun` virtual interfaces created by VPN programs are incorrectly identified as physical NICs.

**Solution**:
1. Confirm that the `isPhysicalInterface()` function in the code has excluded that interface prefix
2. View all interfaces on the Guest VM: `ifconfig -a` or `ip addr show`
3. If a new tunnel interface prefix appears, add it to `exclude_prefixes` in `src/broadcast.zig`
4. Recompile and redeploy

### 5.3 --exec Command Execution Failed

**Common Errors**:

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `GuestNotFound` | Host has not received broadcast from this Guest | Wait a few seconds and retry; check if Guest is running |
| `ConnectionRefused` | Guest HTTP service (2121) not listening | Check if Guest process started normally |
| `Timeout` | TCP connected but no response | Guest shell may be stuck; pkill and restart |
| `FileNotFound` (Windows) | Incorrect command or shell path | Use `cmd /c` compatible commands |
| `RemoteExecFailed` | Command execution returned error | Check if command is correct (use Windows `ver` instead of `uname`) |

### 5.4 Windows Guest Process Cannot Run in Background

**Symptom**: Process disappears when the window is closed after direct launch

**Solution**: Use Task Scheduler instead of direct launch, or auto-install the service via `--install`. Execute in the VM:

```cmd
C:\opt\utmm\utmm.exe --install
```

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

### 5.7 HTTP Upload Failed: File Locked

**Symptom**: When updating a running executable via HTTP upload, the upload succeeds but the file cannot be replaced because it's locked by a running process.

**Cause**: The target file is being locked by a running process (mmap or already opened). Linux/Windows prohibit overwriting a running executable.

**Solution**:
```bash
# 1. Use --exec to terminate the locking process
utmm --host --exec linuxvm "pkill utmm"

# 2. Re-upload and restart
utmm --host --upload ./new_binary linuxvm
utmm --host --exec linuxvm "/opt/utmm/utmm &"
```

**Advanced**: Using `--deploy` is recommended. It uploads via HTTP as a `.new` temporary file, then performs an atomic replacement + restart via HTTP exec, automatically handling file locking issues:
```bash
utmm --host --deploy ubuntu
```

### 5.8 Port Conflict

**Management commands (--status/--exec/--deploy) no longer conflict with the Host UDP port**. Since Phase 9, management commands are forwarded to the persistent Host process via IPC (127.0.0.1:12347 TCP), and the CLI process no longer directly binds the UDP port.

If ports 12345/2121 are occupied by other programs, they can be changed via parameters:

```bash
# Guest side
utmm --port 12348 --http-port 2122

# Host side (ports must match Guest)
utmm --host --port 12348
```

---

## 6. Reference Appendix

### 6.1 Project File Structure

```
utmm/
├── build.zig              # Build script (includes link_libc)
├── build.zig.zon          # Package manifest
├── install.sh             # Host one-click installation script
├── manual.md              # This manual
├── README.md              # Project overview
├── CLAUDE.md              # Development guide
├── zig-codegen.md         # Zig 0.16.0 coding experience notes
├── task_plan.md           # Task plan
├── progress.md            # Progress log
├── findings.md            # Research findings
├── mcp.json.example          # MCP config reference (use `claude mcp add` instead)
├── .github/
│   └── workflows/
│       └── release.yml    # CI: auto build and publish 5-target binaries on tag
├── utm-vm/
│   └── SKILL.md           # Claude Code skill (symlinked into .claude/skills/)
├── .claude/               # Local config: mcp.json + skills/ symlinks (gitignored)
├── src/
│   ├── main.zig           # Entry point + CLI parsing (22 arguments)
│   ├── protocol.zig       # Message protocol (ANNOUNCE/PING/EXEC)
│   ├── ver.zig            # Single version source (bump to trigger auto-upgrade)
│   ├── guest.zig          # Guest mode orchestration (broadcast + HTTP server)
│   ├── host.zig           # Host mode orchestration
│   ├── broadcast.zig      # UDP broadcast + gateway detection (getifaddrs)
│   ├── listener.zig       # UDP listener (includes source IP extraction)
│   ├── hosts_file.zig     # /etc/hosts marker block read/write
│   ├── http_server.zig    # Guest HTTP server (upload/download/exec/update endpoints)
│   ├── http_client.zig    # HTTP client (GET/POST file transfer + exec)
│   ├── host_http.zig      # Host HTTP file server (read-only, serve directory)
│   ├── status.zig         # --status query
│   ├── executor.zig       # --exec remote execution
│   ├── deploy.zig         # --deploy / --watch compilation and deployment (HTTP)
│   ├── ipc.zig            # IPC module (127.0.0.1:12347 TCP command forwarding)
│   ├── mcp.zig            # MCP JSON-RPC server (--mcp flag)
│   ├── install.zig        # --install / --gen-init service installation
│   └── config.zig         # Configuration persistence + logging
└── zig-out/
    └── bin/
        └── utmm    # Build artifact
```

### 6.2 Technology Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Zig | 0.16.0 | Programming language |
| libc | System | `getifaddrs` / `gethostname` / `getenv` |
| launchd | macOS system | macOS auto-start on boot |
| systemd | Linux system | Linux auto-start on boot |
| Task Scheduler | Windows system | Windows auto-start on boot |
| HTTP+IPC | Built-in | Binary deployment + file transfer + remote execution + command forwarding |

### 6.3 Binary Packaging (8 Binaries → All VMs)

Each release builds 8 binaries covering all architecture+OS combinations, packaged as `utmm.zip`:

| # | Binary | Build Target | Covers |
|---|--------|-------------|--------|
| 1 | `utmm-x86-linux` | `x86-linux-musl` | 32-bit x86 Linux VMs |
| 2 | `utmm-x86_64-linux` | `x86_64-linux-musl` | 64-bit x86 Linux VMs |
| 3 | `utmm-aarch64-linux` | `aarch64-linux-musl` | ARM64 Linux VMs |
| 4 | `utmm-x86_64-macos` | `x86_64-macos` | Intel Mac, Apple Silicon (physical, via Rosetta 2) |
| 5 | `utmm-aarch64-macos` | `aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) |
| 6 | `utmm-x86-windows.exe` | `x86-windows` | 32-bit x86 Windows VMs |
| 7 | `utmm-x86_64-windows.exe` | `x86_64-windows` | 64-bit x86 Windows VMs |
| 8 | `utmm-aarch64-windows.exe` | `aarch64-windows` | ARM64 Windows VMs |

**Compatibility matrix** — which binary to use for each VM scenario:

| VM Scenario | Binary to Use | Notes |
|-------------|---------------|-------|
| Windows VM (x86) | `utmm-x86-windows.exe` | 32-bit x86 |
| Windows VM (x86_64) | `utmm-x86_64-windows.exe` | 64-bit x86 |
| Windows VM (ARM64) | `utmm-aarch64-windows.exe` | Native ARM64 |
| macOS VM on Intel Mac (UTM) | `utmm-x86_64-macos` | Native x86_64 |
| macOS VM on Apple Silicon (UTM) | `utmm-aarch64-macos` | UTM ARM VMs lack Rosetta 2; need native aarch64 |
| Physical Apple Silicon Mac (Host) | `utmm-x86_64-macos` | Rosetta 2 handles x86_64 → aarch64 translation |
| Physical Intel Mac (Host) | `utmm-x86_64-macos` | Native x86_64 |
| Linux VM (x86 / 32-bit) | `utmm-x86-linux` | 32-bit musl static |
| Linux VM (x86_64) | `utmm-x86_64-linux` | 64-bit musl static, no glibc dependency |
| Linux VM (aarch64) | `utmm-aarch64-linux` | aarch64 musl static |

> **Install flow**: `install.sh` downloads `utmm.zip`, extracts all 8 binaries to `/opt/utmm/`, then creates a symlink `/opt/utmm/utmm` → the correct binary for the Host platform. The Host's `serve_dir` now contains all platform binaries, enabling auto-upgrade for any Guest architecture.

**macOS Rosetta 2**: Available on physical Apple Silicon Macs by default; install manually if missing: `softwareupdate --install-rosetta`. NOT available inside UTM ARM macOS VMs — those must use `utmm-aarch64-macos`.

### 6.4 Zig Cross-Compilation Target Reference

| Zig Target | Output Binary | Guest Platform |
|------------|---------------|----------------|
| `x86-linux-musl` | `utmm-x86-linux` | Linux 32-bit x86 (musl static) |
| `x86_64-linux-musl` | `utmm-x86_64-linux` | Linux 64-bit x86 (musl static) |
| `aarch64-linux-musl` | `utmm-aarch64-linux` | Linux aarch64 (musl static) |
| `x86_64-macos` | `utmm-x86_64-macos` | Intel Mac + Apple Silicon Mac (via Rosetta 2) |
| `aarch64-macos` | `utmm-aarch64-macos` | ARM macOS VMs (UTM guests, no Rosetta 2) |
| `x86-windows` | `utmm-x86-windows.exe` | Windows 32-bit x86 |
| `x86_64-windows` | `utmm-x86_64-windows.exe` | Windows 64-bit x86 |
| `aarch64-windows` | `utmm-aarch64-windows.exe` | Windows ARM64 |

All Linux binaries are statically linked against musl — no glibc version dependency, runs on any Linux distribution.

### 6.5 Common Troubleshooting Commands Summary

```bash
# View VM architecture
utmm --host --exec ubuntu "uname -m"

# View all network interfaces on VM
utmm --host --exec ubuntu "ip addr show"

# View Guest broadcast logs
utmm --host --exec ubuntu "head -5 /opt/utmm/utmm.log"

# Capture packets to verify broadcasts
sudo tcpdump -i any port 12345 -n -c 10

# Verify Guest is online (via Host status)
utmm --host --status

# View Host listener
ps aux | grep "utmm --host"

# Reload /etc/hosts (macOS)
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

### 6.6 Guest VM Information (Example)

| VM | User | Password | Binary Path | Initial Bootstrap Method |
|----|------|----------|-------------|--------------------------|
| macvm | root | 111 | `/opt/utmm/utmm` | UTM shared folder / one-time SCP |
| linuxvm | root | 111 | `/opt/utmm/utmm` | UTM shared folder / one-time SCP |
| windowsvm | Administrator | 111 | `C:\opt\utmm\utmm.exe` | UTM shared folder / one-time SCP |

> After the Guest starts, it is fully auto-updated via `--deploy`; no further manual transfer is needed.

### 6.7 Troubleshooting Quick Reference

| Problem | Cause | Command |
|---------|-------|---------|
| `error.Unexpected` | Guest cannot obtain local IP | Check if VM has a valid network interface |
| `error.AccessDenied` | Host not running with sudo | `sudo utmm --host` |
| `error.ConnectionRefused` | Guest cmd_server not started | Check if Guest process is running |
| `GuestNotFound` | UDP broadcast not reaching | Check if network is on same broadcast domain |
| Tunnel IP detected | VPN interface interference | utun/tun added to exclusion list |
| Windows process disappears | Direct launch without background daemon | Use --install to install as service |
| HTTP upload file locked | Target file mmap'd by process | Kill process and retry |

---

## 7. Claude Code Integration (MCP Server)

utmm can be used as a Claude Code plugin via the Model Context Protocol (MCP). This lets Claude automatically discover, execute commands on, and deploy to your UTM VMs — without you typing CLI commands.

### 7.1 Architecture

```
Claude Code
  │ MCP (JSON-RPC over stdio)
  ▼
utmm --mcp      ← built into the binary (adapter mode)
  │ STATUS_JSON / EXEC / DEPLOY (127.0.0.1:12347 TCP)
  ▼
utmm --host     ← persistent Host process
  │
  ├─ UDP ──→ linuxvm
  ├─ UDP ──→ macvm
  └─ UDP ──→ windowsvm
```

The `--mcp` flag translates between MCP's JSON-RPC protocol and utmm's text IPC. All real work happens in the Host process (which must be running). No Node.js or any external dependencies needed.

For a simpler all-in-one setup, use `--host --mcp` together: the Host services (UDP/HTTP/IPC) run in background threads while the main thread serves MCP on stdio.

### 7.2 Full Setup Walkthrough (from zero to working)

**Prerequisites:**
- UTM VMs must be booted with `utmm` running inside each guest
- The Host binary must be running: `sudo utmm --host`
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

**Step 2: Download Guest binaries (for VM auto-deploy)**

```bash
sudo mkdir -p /opt/utmm
# 5 binaries cover all scenarios (see §6.4)
for bin in utmm utmm-aarch64-linux utmm-x86_64-macos utmm-aarch64-macos utmm.exe; do
  sudo curl -fsSL \
    "https://github.com/fixnet-ai/utm-monitor/releases/latest/download/$bin" \
    -o "/opt/utmm/$bin"
done
sudo chmod +x /opt/utmm/*
```

**Step 3: Download Skill**

```bash
cd ~/utmm

# Download Skill (canonical location: utm-vm/SKILL.md)
curl -o utm-vm/SKILL.md \
  https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/utm-vm/SKILL.md

# Create symlink so Claude can find it
mkdir -p .claude/skills
ln -sf ../../utm-vm .claude/skills/utm-vm
```

> No extra files needed — the MCP server is built into the `utmm` binary via `--mcp`. Zero external dependencies.

**Step 4: Register MCP server with Claude Code**

```bash
claude mcp add utmm -- utmm --mcp
```

> This writes to `~/.claude.json`, which is the recognized MCP config file.
>
> Restart Claude Code (or run `/mcp` to reload). You should see `utmm` in the MCP servers list.
>
> **Integrated mode (all-in-one):** `claude mcp add utmm -- utmm --host --mcp`
> This runs the full Host + MCP in a single process — no separate Host daemon needed.

**Step 5: Start the Host**

```bash
sudo utmm --host --serve-dir /opt/utmm
```

Expected output:

```
[host] Listening for Guest broadcasts...
[broadcast] Physical NIC en0: 192.168.3.130
[host] HTTP server started on port 2121 (read-only, serving /opt/utmm/utmm/)
[ipc] IPC server started on 127.0.0.1:12347
[listener] Listening on port 12345
```

Keep this terminal open — the Host runs in the foreground. To auto-start on boot:

```bash
sudo utmm --install
```

**Step 6: Verify the MCP connection**

```bash
# Ping the MCP server via proper LSP-style framing
printf 'Content-Length: 50\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n' | utmm --mcp
# → Content-Length: 47
# → {"jsonrpc":"2.0","id":1,"result":{}}
```

**Step 7: First conversation** — see next section.

> **Alternative: build from source** — requires Zig 0.16.0. Clone the repo and run `zig build -Doptimize=ReleaseSafe`. The binary lands at `zig-out/bin/utmm`. Use that path in the steps above instead of `/usr/local/bin/utmm`.

**Step 7: First conversation**

Type this in Claude Code to verify everything works:

```
Check the status of all VMs
```

Claude will call `vm_status()` and return a summary of which VMs are online, their IPs, versions, and whether upgrades are needed.

### 7.3 Available Tools

| Tool | What it does | Example |
|------|-------------|---------|
| `vm_status` | List all VMs: hostname, IP, OS/arch, MAC, version, upgradable? | `vm_status()` |
| `vm_exec` | Execute a shell command on a VM | `vm_exec("linuxvm", "uname -a")` |
| `vm_deploy` | Cross-compile + HTTP deploy to VM(s), then restart | `vm_deploy("linuxvm")` |

### 7.4 Daily Usage Examples

#### Checking VM health

```
👤 "How are the VMs doing?"
🤖 → vm_status()
    linuxvm:    aarch64-linux-musl 192.168.64.2   ✓
    macvm:      aarch64-macos    192.168.64.4   ✓
    windowsvm:  aarch64-windows  192.168.65.2   ⚠ upgradable

👤 "Update windowsvm to the latest version"
🤖 → vm_deploy("windowsvm")
    Building aarch64-windows... done
    Uploading to windowsvm (192.168.65.2:2121)... OK
    Deploy complete

👤 "Verify all VMs are now on the latest version"
🤖 → vm_status()
    All three VMs: v0.1.0 ✓
```

#### Cross-platform testing

```
👤 "I just changed the broadcast module. Test it on all platforms."
🤖 → vm_deploy()                              # build + deploy to all 3 VMs
    → vm_exec("linuxvm", "cd /opt && ./utmm --version")
    → vm_exec("macvm", "cd /opt && ./utmm --version")
    → vm_exec("windowsvm", "C:\\opt\\utmm.exe --version")
    All three return v0.1.0 ✓
```

#### Debugging a specific VM

```
👤 "linuxvm seems slow, what's going on?"
🤖 → vm_exec("linuxvm", "top -b -n 1 | head -10")     # CPU usage
    → vm_exec("linuxvm", "free -h")                    # memory
    → vm_exec("linuxvm", "df -h")                      # disk
    → vm_exec("linuxvm", "dmesg | tail -20")           # kernel messages
    CPU idle 95%, memory 2.1G/4G, disk 60% — looks normal.
    But dmesg shows repeated DHCP renewals — network might be flapping.
```

#### Reading logs and restarting services

```
👤 "Check the utmm logs on all VMs for errors"
🤖 → vm_exec("linuxvm", "tail -30 /var/log/utmm.log")
    → vm_exec("macvm", "tail -30 /var/log/utmm.log")
    → vm_exec("windowsvm", "type C:\\opt\\utmm.log")
    All clean, no errors.

👤 "Restart the guest on linuxvm"
🤖 → vm_exec("linuxvm", "pkill utmm; sleep 1; /opt/utmm/utmm --hostname linuxvm &")
    Restarted. vm_status confirms it's back online.
```

#### Multi-VM coordination

```
👤 "Can linuxvm reach the internet and also ping windowsvm?"
🤖 → vm_exec("linuxvm", "ping -c 1 example.com")
    200 — internet works
    → vm_exec("linuxvm", "ping -c 2 windowsvm")
    2 packets transmitted, 2 received — VM-to-VM networking works
```

#### Setting up a new VM

```
👤 "I just created a new VM called 'debian'. Help me set it up."
🤖 To set up debian, you need to:
    1. Build for its architecture: zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
    2. Copy the binary to the VM via UTM shared folder:
       cp zig-out/bin/utmm /path/to/shared/folder/
    3. Inside the VM:
       mkdir -p /opt/utmm && cp /mnt/shared/utmm /opt/utmm/utmm
       chmod +x /opt/utmm/utmm
       /opt/utmm/utmm --hostname debian --install
       /opt/utmm/utmm --hostname debian &
    4. Wait 3 seconds, then vm_status should show debian online.

👤 (after following steps) "Check if debian is online"
🤖 → vm_status()
    debian:  x86_64-linux-musl  192.168.64.7  v0.1.0  ✓  — it's working!
```

#### File operations on VMs

```
👤 "Create a test script on linuxvm and run it"
🤖 → vm_exec("linuxvm", "cat > /tmp/test.sh << 'EOF'
#!/bin/sh
echo \"Hello from $(uname -a)\"
echo \"Date: $(date)\"
EOF
chmod +x /tmp/test.sh && /tmp/test.sh")
    Hello from Linux ubuntu 5.15.0 aarch64
    Date: Wed Jul 16 10:30:00 UTC 2026
```

#### Installing packages on VMs

```
👤 "Install jq on linuxvm and verify it works"
🤖 → vm_exec("linuxvm", "apt-get update -qq && apt-get install -y -qq jq")
    → vm_exec("linuxvm", "echo '{\"status\":\"ok\"}' | jq .status")
    "ok" — jq installed and working
```

### 7.5 CLI vs MCP — When to Use Which

| Scenario | Use |
|----------|-----|
| Quick status check | `utmm --host --status` |
| One-shot command | `utmm --host --exec linuxvm "..."` |
| Interactive debugging | Claude Code with MCP tools |
| Multi-step testing across VMs | Claude Code with MCP tools |
| Deploy-test-verify loop | Claude Code with MCP tools |
| Setting up a new VM | Claude Code with MCP tools |
| CI / bash scripts | CLI commands |

### 7.6 Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| MCP tools don't appear in Claude | MCP server not registered or wrong path | Run `claude mcp add utmm -- utmm --mcp`, then `/mcp` to reload |
| "Host is not running" | Host process died or not started | `sudo utmm --host` |
| "GuestNotFound" for a VM | VM offline or hostname typo | `vm_status` to see online VMs |
| "No VMs online" | VMs not booted, guest not running | Boot VMs, verify `utmm` running inside each |
| VM marked "upgradable" | Guest binary older than Host | `vm_deploy("that-vm")` |
| MCP tools can't reach Host | IPC port blocked or Host not running | Try `utmm --host --mcp` for integrated mode (bypasses IPC entirely) |
| Port 12345 AddressInUse at Host start | Old `utm-monitor` process still running | `sudo pkill -f utm-monitor && sudo utmm --host` |
| `/update` script fails: directory not found | Old `/update` script without `mkdir -p` | `sudo mkdir -p /opt/utmm` before running, or update Host binary |
| Guest shows wrong hostname (OS hostname) | `/update` ran without `?name=` parameter | Restart Guest: `/opt/utmm/utmm --hostname desired-name &` |
| `--status` shows stale/duplicate entries | Guest renamed but old entry cached | Restart Host: `sudo pkill utmm && sudo utmm --host` |
| Windows bootstrap: `Get-WmiObject` not found | `wmic` deprecated in modern Windows | Use `Get-CimInstance Win32_Processor` instead (see §2.4) |
| Guest can't download binary from Host (timeout) | Guest on isolated bridge can't reach Host physical NIC IP | Use bridge gateway IP directly; latest Host auto-detects via Host header |

### 7.7 Complete Uninstall / Cleanup

To remove utmm entirely and return to bare-metal state:

**Host side**:
```bash
# Stop all processes
sudo pkill -f utmm 2>/dev/null
sudo pkill -f utm-monitor 2>/dev/null

# Remove auto-start service
sudo launchctl bootout system /Library/LaunchDaemons/com.utmm.plist 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.utmm.plist

# Remove binaries
sudo rm -rf /opt/utmm
sudo rm -f /usr/local/bin/utmm

# Clean /etc/hosts
sudo sed -i '' '/# UTM-MONITOR-BEGIN/,/# UTM-MONITOR-END/d' /etc/hosts
```

**Linux Guest** (run inside VM or via SSH):
```bash
pkill -f utmm 2>/dev/null
systemctl stop utmm 2>/dev/null; systemctl disable utmm 2>/dev/null
rm -f /etc/systemd/system/utmm.service
rm -rf /opt/utmm /opt/utm-monitor /opt/utmm_*
rm -f /var/log/utmm*.log /opt/utmm*.log
```

**macOS Guest** (run inside VM or via SSH):
```bash
pkill -f utmm 2>/dev/null
launchctl bootout system /Library/LaunchDaemons/com.utmm.plist 2>/dev/null
rm -f /Library/LaunchDaemons/com.utmm.plist
rm -rf /opt/utmm /opt/utm-monitor /opt/utmm_*
rm -f /var/log/utmm*.log /opt/utmm*.log
```

**Windows Guest** (run inside VM or via SSH):
```cmd
taskkill /f /im utmm.exe
schtasks /delete /tn utmm /f
rmdir /s /q C:\opt\utmm C:\opt\utmm_win
del C:\opt\utmm*.log C:\opt\utm-monitor*
```

### 7.8 Skill (Bundled)

The `utm-vm/SKILL.md` file (at project root, symlinked into `.claude/skills/`) provides Claude with detailed knowledge about:
- When to use each tool in different debugging scenarios
- Shell escaping patterns per platform (bash vs cmd.exe)
- Common workflows: health checks, cross-platform testing, debugging, setup
- Error recovery procedures

The skill activates automatically when you mention VM names, cross-platform testing, or UTM.
