# UTM Monitor Skill — build, deploy, daily ops

UTM Monitor (`utmm`) remote debugging sidekick. Single Zig binary, dual mode.
This skill covers the full cycle: build → deploy → verify → daily use.

## VM Table

| VM | Hostname | Target | IP | User | Password |
|----|----------|--------|----|------|----------|
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root | 111 |
| macOS | macvm | aarch64-macos | 192.168.64.4 | root | 111 |
| Windows ARM | windowsvm | aarch64-windows | 192.168.65.2 | Administrator | 111 |
| Windows x64 | winx64 | x86_64-windows | 192.168.3.108 | Administrator | 111 |

## Architecture (v0.14.x)

```
Host (local macOS) ──UDP :2121 LSA──→ Guests (linuxvm, macvm, windowsvm, winx64)
                  ──TCP :2121 exec/upload/download──→ Guests
CLI/MCP ──IPC socket /var/run/utmm.sock──→ Host daemon
```

- **Single binary**: `utmm` embeds `utmmd` supervisor
- **Guest**: TCP listener + LSA broadcast, per-command pty shell
- **Host**: UDP LSA mesh + IPC socket + TCP SOCKS4a to guests
- **Single service per machine**: `com.utmmd` (macOS), `utmmd` (Linux), `UTM-MonitorD` (Windows)
- **Canonical path**: `/opt/utmm/utmm` (POSIX), `C:\opt\utmm\utmm.exe` (Windows)

## 1. Build

```bash
# Read current version
cat src/ver.txt

# Native build (for local Host)
zig build -Doptimize=ReleaseSafe
# → zig-out/bin/utmm (Mach-O arm64 on Apple Silicon)

# Cross-compile for targets (guest deployment)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl    # linuxvm
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos         # macvm
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows       # windowsvm
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows        # winx64

# Output naming: utmm-{target}-{version}
# e.g. zig-out/bin/utmm-aarch64-linux-0.14.2

# Run tests
zig build test
zig build test-integration
```

## 2. Deploy

### 2.1 Host (local macOS)

```bash
zig build -Doptimize=ReleaseSafe
sudo zig-out/bin/utmm --host --install
# Verify: sudo zig-out/bin/utmm --status
```

`--host --install` auto-starts utmmd. If Host was previously running, it stops old processes, self-copies, and restarts — one command.

### 2.2 Linux Guest (linuxvm)

```bash
V=$(cat src/ver.txt)
BIN="zig-out/bin/utmm-aarch64-linux-${V}"

# Copy + install (one SSH, --install handles stop→kill→copy→start)
scp "$BIN" root@192.168.64.2:/opt/utmm/utmm-new
ssh root@192.168.64.2 "/opt/utmm/utmm-new --install --hostname linuxvm"
```

`--install` auto-kills old processes (may wait up to 5s), self-copies to `/opt/utmm/utmm`, and restarts utmmd. If the old process won't die, pre-kill manually:

```bash
ssh root@192.168.64.2 "systemctl stop utmmd; pkill -9 utmm utmmd; sleep 1"
# then run --install
```

**Clean uninstall** (bare metal reset):
```bash
ssh root@192.168.64.2 "systemctl stop utmmd; pkill -9 utmm utmmd; sleep 1; rm -f /opt/utmm/utmm /opt/utmm/utmmd /etc/systemd/system/utmmd.service; systemctl daemon-reload"
```

### 2.3 macOS Guest (macvm)

```bash
V=$(cat src/ver.txt)
BIN="zig-out/bin/utmm-aarch64-macos-${V}"

# macOS --install may fail if launchctl is throttled.
# Safest: kill all first, then install.
scp "$BIN" root@192.168.64.4:/opt/utmm/utmm-new
ssh root@192.168.64.4 "killall -9 utmm utmmd 2>/dev/null; sleep 1; cp /opt/utmm/utmm-new /opt/utmm/utmm; /opt/utmm/utmm --install --hostname macvm"
```

**Why this order**: macOS launchctl throttles repeated bootout/bootstrap within a short window — returns "Input/output error" and refuses to load. Killing processes first avoids the bootout step in --install from hanging 5s. If install still fails, manually start utmmd:
```bash
ssh root@192.168.64.4 "nohup /opt/utmm/utmmd --role guest &>/dev/null &"
```

**Clean uninstall** (bare metal reset):
```bash
ssh root@192.168.64.4 "launchctl bootout system/com.utmmd 2>/dev/null; killall -9 utmm utmmd 2>/dev/null; sleep 1; rm -f /opt/utmm/utmm /opt/utmm/utmmd /Library/LaunchDaemons/com.utmmd.plist /var/run/utmm.sock"
```

### 2.4 Windows Guest (windowsvm / winx64)

Windows SSH (OpenSSH) does NOT handle `;` command chaining. Run commands one at a time.

**Clean install from bare metal:**
```bash
# 1. Copy binary
scp "zig-out/bin/utmm-aarch64-windows-${V}.exe" Administrator@192.168.65.2:C:/opt/utmm/utmm-new.exe

# 2. Kill old processes (if any — harmless on first install)
ssh Administrator@192.168.65.2 "taskkill /F /IM utmm.exe"
ssh Administrator@192.168.65.2 "taskkill /F /IM utmmd.exe"

# 3. Install
ssh Administrator@192.168.65.2 "C:/opt/utmm/utmm-new.exe --install --hostname windowsvm"
```

**If `--install` fails with AccessDenied**: utmmd.exe is locking the file. Kill utmmd.exe first, then retry.

**winx64** — same pattern, different binary:
```bash
scp "zig-out/bin/utmm-x86_64-windows-${V}.exe" Administrator@192.168.3.108:C:/opt/utmm/utmm-new.exe
ssh Administrator@192.168.3.108 "taskkill /F /IM utmm.exe"
ssh Administrator@192.168.3.108 "taskkill /F /IM utmmd.exe"
ssh Administrator@192.168.3.108 "C:/opt/utmm/utmm-new.exe --install --hostname winx64"
```

**Clean uninstall** (bare metal reset):
```bash
ssh Administrator@192.168.65.2 "taskkill /F /IM utmm.exe"
ssh Administrator@192.168.65.2 "taskkill /F /IM utmmd.exe"
ssh Administrator@192.168.65.2 "sc delete UTM-MonitorD"
ssh Administrator@192.168.65.2 "del /F C:\opt\utmm\utmm.exe C:\opt\utmm\utmmd.exe"
```

## 3. Verify

```bash
# Status — instant snapshot of all nodes
sudo zig-out/bin/utmm --status

# Per-VM exec smoke test
sudo zig-out/bin/utmm --exec linuxvm "uname -a"
sudo zig-out/bin/utmm --exec macvm "uname -a"
sudo zig-out/bin/utmm --exec windowsvm "ver"
sudo zig-out/bin/utmm --exec winx64 "ver"
```

Healthy output shows: version match across all guests, `serving` status, Last seen `now`.

## 4. Daily Ops

All commands connect to Host daemon via IPC socket (`/var/run/utmm.sock`). If Host is not running, they auto-start it.

```bash
# Status
sudo utmm --status

# Execute command on guest (pty shell, streaming output)
sudo utmm --exec <vm> "<command>"
# Examples:
sudo utmm --exec linuxvm "ps aux | grep myapp"
sudo utmm --exec windowsvm "tasklist | findstr myapp"
sudo utmm --exec macvm "tail -50 /var/log/system.log"

# Upload file (Host → Guest, SHA256 verified)
sudo utmm --upload <local-file> <vm>
# Example: sudo utmm --upload ./build.zip linuxvm
# Defaults to /opt/utmm/<basename> on guest.
# For custom path: sudo utmm --upload ./build.zip linuxvm:/tmp/build.zip

# Download file (Guest → Host, SHA256 verified)
sudo utmm --download <vm> <remote-path> <local-path>
# Example: sudo utmm --download linuxvm /var/log/app.log ./app.log

# Version (no root needed)
utmm --version
```

### Shell syntax by platform

| Guest | Shell | Example |
|-------|-------|---------|
| linuxvm | `/bin/bash` | `export FOO=bar && echo $FOO` |
| macvm | `/bin/zsh` | `cd /tmp && pwd` |
| windowsvm / winx64 | `cmd.exe` (UTF-8) | `set VAR=value && echo %VAR%` |

### Key behaviors

- **Per-command shell**: each exec opens a fresh pty. No `cd`/`export` persistence across execs.
- **Streaming output**: output flows in real time, no timeout. Exit code returned as binary trailer.
- **No concurrent exec**: multiple `--exec` calls from one terminal will interleave output. Run sequentially.

## 5. Upgrade Flow

```bash
# 1. Build new version
zig build -Doptimize=ReleaseSafe
# bump src/ver.txt if needed

# 2. Reinstall Host (local)
sudo zig-out/bin/utmm --host --install

# 3. Deploy to guests (see §2 per platform)
# scp + --install is the reliable path.

# 4. Verify all guests show new version
sudo zig-out/bin/utmm --status
```

## 6. Troubleshooting

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| Guest not in `--status` | Service not running on guest | SSH to guest, verify utmmd is running, reinstall |
| `--exec` returns `GuestNotFound` | Hostname mismatch | Check `--status` for actual guest hostname; use that name in CLI commands. |
| macOS `--install` bootstrap fails (exit 5) | launchctl throttle | `killall -9 utmm utmmd` first, then `--install` |
| Windows `--install` AccessDenied | utmmd.exe locking file | `taskkill /F /IM utmmd.exe` first, then `--install` |
| `--status` returns `IpcNotRunning` | Host daemon just started, IPC not yet ready | Wait 2-3s and retry |
| Linux `--install` waits 5s | old process not responding to SIGTERM | Pre-kill with `pkill -9 utmm utmmd` before install |
| Exec output shows `MDELIM:N` | Exit code marker in output | Normal — Host strips this internally, should not be visible |
