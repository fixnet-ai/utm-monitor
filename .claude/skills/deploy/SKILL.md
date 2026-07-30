# Deploy Skill — UTM Monitor 一键部署

Build → test → deploy Host → deploy Guests → verify. For VM table and prerequisites
see `SKILL.md` (project root). For full manual see `MANUAL.md`.

## Trigger Conditions

Use when user requests: "deploy" / "部署" / "上线" / "update all VMs" / "升级到 vX.Y.Z" /
"cross-compile and deploy".

## Flow

### 1. Build + Test (must pass)

```bash
cat src/ver.txt
zig build test                    # 0 failures required
zig build test-integration         # 0 failures required
zig build -Doptimize=ReleaseSafe   # native (Host)
```

### 2. Cross-Compile Guests

```bash
V=$(cat src/ver.txt)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl   # linuxvm
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos        # macvm
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows      # windowsvm
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows       # winx64
```

### 3. Deploy Host (local macOS)

```bash
sudo zig-out/bin/utmm --host --install
sleep 5
sudo zig-out/bin/utmm --status
```

### 4. Deploy Guests (can run in parallel)

```bash
V=$(cat src/ver.txt)

# linuxvm
scp zig-out/bin/utmm-aarch64-linux-$V root@192.168.64.6:/opt/utmm/utmm-new
ssh root@192.168.64.6 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname linuxvm'

# macvm — kill first to avoid launchctl throttle
ssh root@192.168.65.4 'killall -9 utmm utmmd 2>/dev/null; sleep 1'
scp zig-out/bin/utmm-aarch64-macos-$V root@192.168.65.4:/opt/utmm/utmm-new
ssh root@192.168.65.4 'cp /opt/utmm/utmm-new /opt/utmm/utmm && /opt/utmm/utmm --install --hostname macvm'

# windowsvm — kill utmmd first (locks exe)
ssh Administrator@192.168.64.3 'taskkill /F /IM utmmd.exe 2>nul'
scp zig-out/bin/utmm-aarch64-windows-$V.exe Administrator@192.168.64.3:C:/opt/utmm/utmm-new.exe
ssh Administrator@192.168.64.3 'C:\opt\utmm\utmm-new.exe --install --hostname windowsvm'

# winx64
ssh Administrator@192.168.3.108 'taskkill /F /IM utmmd.exe 2>nul'
scp zig-out/bin/utmm-x86_64-windows-$V.exe Administrator@192.168.3.108:C:/opt/utmm/utmm-new.exe
ssh Administrator@192.168.3.108 'C:\opt\utmm\utmm-new.exe --install --hostname winx64'
```

### 5. Verify

```bash
sleep 15   # wait for LSA sync
sudo zig-out/bin/utmm --status
sudo zig-out/bin/utmm --exec linuxvm "echo OK"
sudo zig-out/bin/utmm --exec macvm "echo OK"
sudo zig-out/bin/utmm --exec windowsvm "echo OK"
sudo zig-out/bin/utmm --exec winx64 "echo OK"
```

### 6. Wrap Up

Update `progress.md` and `task_plan.md` with deploy results. Commit + push.

## Key Notes

- **macOS Guest**: kill processes before `--install` (launchctl throttles repeated bootout)
- **Windows Guest**: kill utmmd.exe before install (AccessDenied if locked)
- **Windows SSH**: no `;` chaining — use separate calls
- **LSA sync**: need ~15s after Guest restart before appearing in `--status`
- **Binary naming**: cross-compiled output has version suffix (`utmm-aarch64-linux-0.14.7`)
- **Password all VMs**: 111
