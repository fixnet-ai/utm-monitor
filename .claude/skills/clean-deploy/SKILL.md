# Clean Deploy Skill — UTM Monitor 裸机部署测试

Complete "build → wipe → deploy → test" cycle. Simulates bare-metal deployment from
scratch. For VM table and prerequisites, see `SKILL.md` (project root). For deploy
flow, see `.claude/skills/deploy/SKILL.md`.

## Trigger Conditions

"裸机部署测试" / "clean deploy" / "从零开始部署并测试" / "全清空重建".

---

## Phase 0: Build Native utmm (required for sshpass)

External `sshpass` was removed in v0.14.7 — all remote SSH commands in Phase 1
use `./zig-out/bin/utmm sshpass`. Must build native binary first:

```bash
zig build -Doptimize=ReleaseSafe   # native → zig-out/bin/utmm
```

**Testing** (Zig 0.16.0 `--listen=-` may hang — use direct binary workaround):
```bash
# Unit tests (must pass, 0 failures)
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/test 2>&1 | tail -3
# Integration tests (must pass, 0 failures)
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/integration_test 2>&1 | tail -3
```

---

## Phase 1: Full Wipe

Stop all services, kill processes, delete binaries, configs, logs. Return all machines
to pre-installation state.

**`UTMM=./zig-out/bin/utmm` — all sshpass calls use utmm's built-in sshpass.**

### Host (local macOS)

```bash
sudo launchctl bootout system/com.utmmd 2>/dev/null || true
# Clean legacy service names too:
sudo launchctl bootout system/com.utmm.host 2>/dev/null || true
sudo launchctl bootout system/com.utmm.guest 2>/dev/null || true
sleep 2
sudo pkill -9 utmm 2>/dev/null || true
sudo pkill -9 utmmd 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.utmm*.plist
sudo rm -rf /opt/utmm
sudo rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log /var/log/utmm*.bak /var/log/utmm*.old
sudo rm -f /var/run/utmm.sock /var/run/utmm-install.lock
```

### macvm (macOS Guest)

```bash
./zig-out/bin/utmm sshpass -p 111 ssh root@macvm '
launchctl enable system/com.utmmd 2>/dev/null
launchctl bootout system/com.utmmd 2>/dev/null || true
launchctl bootout system/com.utmm.guest 2>/dev/null || true
sleep 2
pkill -9 utmm 2>/dev/null || true
pkill -9 utmmd 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.utmm*.plist
rm -rf /opt/utmm
rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log
rm -f /var/run/utmm.sock /var/run/utmm-install.lock
echo "macvm cleaned"
'
```

### linuxvm (Linux Guest)

```bash
./zig-out/bin/utmm sshpass -p 111 ssh root@linuxvm '
systemctl stop utmmd 2>/dev/null || true
systemctl stop utmm-guest 2>/dev/null || true
systemctl disable utmmd 2>/dev/null || true
systemctl disable utmm-guest 2>/dev/null || true
sleep 2
pkill -9 utmm 2>/dev/null || true
pkill -9 utmmd 2>/dev/null || true
rm -f /etc/systemd/system/utmm*.service
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/utmm
rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log
rm -f /var/run/utmm.sock /var/run/utmm-install.lock
echo "linuxvm cleaned"
'
```

### Windows Guests

```bash
# windowsvm
./zig-out/bin/utmm sshpass -p 111 ssh Administrator@windowsvm 'powershell -Command "
sc.exe stop UTM-MonitorD 2>$null; sc.exe delete UTM-MonitorD 2>$null;
Get-Process -Name utmm -ErrorAction SilentlyContinue | Stop-Process -Force;
Get-Process -Name utmmd -ErrorAction SilentlyContinue | Stop-Process -Force;
Start-Sleep -Seconds 3;
Remove-Item -Recurse -Force C:\opt\utmm -ErrorAction SilentlyContinue
"'
echo "windowsvm cleaned"

# winx64
./zig-out/bin/utmm sshpass -p 111 ssh Administrator@winx64 'powershell -Command "
sc.exe stop UTM-MonitorD 2>$null; sc.exe delete UTM-MonitorD 2>$null;
Get-Process -Name utmm -ErrorAction SilentlyContinue | Stop-Process -Force;
Get-Process -Name utmmd -ErrorAction SilentlyContinue | Stop-Process -Force;
Start-Sleep -Seconds 3;
Remove-Item -Recurse -Force C:\opt\utmm -ErrorAction SilentlyContinue
"'
echo "winx64 cleaned"
```

### Verify Wipe

```bash
ps aux | grep -i utmm | grep -v grep || echo "Host clean"
./zig-out/bin/utmm sshpass -p 111 ssh root@macvm 'ps aux | grep -i utmm | grep -v grep || echo "macvm clean"'
./zig-out/bin/utmm sshpass -p 111 ssh root@linuxvm 'ps aux | grep -i utmm | grep -v grep || echo "linuxvm clean"'
./zig-out/bin/utmm sshpass -p 111 ssh Administrator@windowsvm 'cmd /c "tasklist | findstr utmm || echo windowsvm clean"'
./zig-out/bin/utmm sshpass -p 111 ssh Administrator@192.168.3.108 'cmd /c "tasklist | findstr utmm || echo winx64 clean"'
```

---

## Phase 2: Cross-Compile

Build for all Guest targets:

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

---

## Phase 3: Deploy

Follow `.claude/skills/deploy/SKILL.md` flow. Key extra steps for clean deploy:

- **mkdir first**: wipe deletes `/opt/utmm` — run `mkdir -p /opt/utmm` on each Guest before scp.
  On Windows use: `./zig-out/bin/utmm sshpass -p 111 ssh Administrator@windowsvm 'powershell -Command "New-Item -ItemType Directory -Force -Path C:\opt\utmm"'`
- **Wait 15s**: after all deployments, wait for LSA sync before testing

---

## Phase 4: Full Test

```bash
sleep 15
sudo zig-out/bin/utmm --status
sudo zig-out/bin/utmm --exec linuxvm "echo OK"
sudo zig-out/bin/utmm --exec macvm "echo OK"
sudo zig-out/bin/utmm --exec windowsvm "echo OK"
sudo zig-out/bin/utmm --exec winx64 "echo OK"

# Upload
echo "upload-test-$(date +%s)" > /tmp/clean_deploy_test.txt
sudo zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt linuxvm
sudo zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt macvm
sudo zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt windowsvm
sudo zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt winx64

# Download
sudo zig-out/bin/utmm --download linuxvm /opt/utmm/clean_deploy_test.txt /tmp/dl_linux.txt
sudo zig-out/bin/utmm --download macvm /opt/utmm/clean_deploy_test.txt /tmp/dl_mac.txt
sudo zig-out/bin/utmm --download windowsvm 'C:\opt\utmm\clean_deploy_test.txt' /tmp/dl_win.txt
sudo zig-out/bin/utmm --download winx64 'C:\opt\utmm\clean_deploy_test.txt' /tmp/dl_win64.txt

# Verify contents match
sha256sum /tmp/clean_deploy_test.txt /tmp/dl_*.txt

# Ping
sudo zig-out/bin/utmm --ping linuxvm
sudo zig-out/bin/utmm --ping macvm
sudo zig-out/bin/utmm --ping windowsvm
sudo zig-out/bin/utmm --ping winx64
```

---

## Phase 5: Summary

Record results in `progress.md`:

```
## Clean Deploy Test Summary

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --upload | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --download | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --ping | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
```

## Caveats

- **Phase 0 required**: v0.14.7 removed external sshpass — build native utmm first for `utmm sshpass`
- **Hostname resolution**: all commands use hostnames (linuxvm/macvm/windowsvm/winx64) — the Host's
  LSA `/etc/hosts` sync provides DNS-free name resolution. If a hostname doesn't resolve during
  wipe (e.g. first-time setup), use the IP from the VM table in `SKILL.md`.
  **Known issue**: `winx64` (192.168.3.x subnet) may not resolve via LSA sync — use IP `192.168.3.108` if `ssh: Could not resolve hostname winx64`.
- **Irreversible** — wipes all configs, logs, history. Dev/test only.
- **Windows OpenSSH** must be pre-enabled on Guests
- **mkdir after wipe** — `/opt/utmm` is deleted during wipe; use `New-Item` on Windows
- **Windows download paths**: single-quote in bash (`'C:\opt\utmm\file.txt'`)
- **Cross-compile output has version suffix** — `utmm-aarch64-macos-0.14.7`
- SSH compound commands: avoid very long ones with `&&` + pipes — split into separate calls
- **`pkill -9 utmm`** (no `-f`): `-f` matches full command line and kills the ssh/bash parent process on Linux
