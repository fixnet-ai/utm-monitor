# Clean Deploy Skill — UTM Monitor 裸机部署测试

Complete "wipe → build → deploy → test" cycle. Simulates bare-metal deployment from
scratch. For VM table and prerequisites, see `SKILL.md` (project root). For deploy
flow, see `.claude/skills/deploy/SKILL.md`.

## Trigger Conditions

"裸机部署测试" / "clean deploy" / "从零开始部署并测试" / "全清空重建".

---

## Phase 1: Full Wipe

Stop all services, kill processes, delete binaries, configs, logs. Return all machines
to pre-installation state.

### Host (local macOS)

```bash
sudo launchctl bootout system/com.utmmd 2>/dev/null || true
# Clean legacy service names too:
sudo launchctl bootout system/com.utmm.host 2>/dev/null || true
sudo launchctl bootout system/com.utmm.guest 2>/dev/null || true
sleep 2
sudo pkill -9 -f utmm 2>/dev/null || true
sudo pkill -9 -f utmmd 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.utmm*.plist
sudo rm -rf /opt/utmm
sudo rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log /var/log/utmm*.bak /var/log/utmm*.old
sudo rm -f /var/run/utmm.sock /var/run/utmm-install.lock
```

### macvm (macOS Guest)

```bash
sshpass -p 111 ssh root@192.168.65.4 '
launchctl enable system/com.utmmd 2>/dev/null
launchctl bootout system/com.utmmd 2>/dev/null || true
launchctl bootout system/com.utmm.guest 2>/dev/null || true
sleep 2
pkill -9 -f utmm 2>/dev/null || true
pkill -9 -f utmmd 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.utmm*.plist
rm -rf /opt/utmm
rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log
rm -f /var/run/utmm.sock /var/run/utmm-install.lock
echo "macvm cleaned"
'
```

### linuxvm (Linux Guest)

```bash
sshpass -p 111 ssh root@192.168.64.2 '
systemctl stop utmmd 2>/dev/null || true
systemctl stop utmm-guest 2>/dev/null || true
systemctl disable utmmd 2>/dev/null || true
systemctl disable utmm-guest 2>/dev/null || true
sleep 2
pkill -9 -f utmm 2>/dev/null || true
pkill -9 -f utmmd 2>/dev/null || true
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
sshpass -p 111 ssh Administrator@192.168.64.3 'powershell -Command "
sc.exe stop UTM-MonitorD 2>$null; sc.exe delete UTM-MonitorD 2>$null;
Get-Process -Name utmm -ErrorAction SilentlyContinue | Stop-Process -Force;
Get-Process -Name utmmd -ErrorAction SilentlyContinue | Stop-Process -Force;
Start-Sleep -Seconds 3;
Remove-Item -Recurse -Force C:\opt\utmm -ErrorAction SilentlyContinue
"'
echo "windowsvm cleaned"

# winx64
sshpass -p 111 ssh Administrator@192.168.3.108 'powershell -Command "
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
sshpass -p 111 ssh root@192.168.65.4 'ps aux | grep -i utmm | grep -v grep || echo "macvm clean"'
sshpass -p 111 ssh root@192.168.64.2 'ps aux | grep -i utmm | grep -v grep || echo "linuxvm clean"'
sshpass -p 111 ssh Administrator@192.168.64.3 'tasklist /fi "imagename eq utmm.exe" 2>nul'
sshpass -p 111 ssh Administrator@192.168.3.108 'tasklist /fi "imagename eq utmm.exe" 2>nul'
```

---

## Phase 2: Build

```bash
zig build test            # must pass, 0 failures
zig build test-integration # must pass, 0 failures
zig build -Doptimize=ReleaseSafe                     # native
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

---

## Phase 3: Deploy

Follow `.claude/skills/deploy/SKILL.md` flow. Key extra steps for clean deploy:

- **mkdir first**: wipe deletes `/opt/utmm` — run `mkdir -p /opt/utmm` on each Guest before scp
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

- **Irreversible** — wipes all configs, logs, history. Dev/test only.
- **Windows OpenSSH** must be pre-enabled on Guests
- **mkdir after wipe** — `/opt/utmm` is deleted during wipe
- **Windows download paths**: single-quote in bash (`'C:\opt\utmm\file.txt'`)
- **Cross-compile output has version suffix** — `utmm-aarch64-macos-0.14.7`
- SSH compound commands: avoid very long ones with `&&` + pipes — split into separate calls
