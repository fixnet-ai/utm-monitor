# SKILL.md — 部署与运维实战手册

本文档记录开发、部署、测试过程中的实战经验和注意事项，
避免重复踩坑。

---

## 部署

### 全量部署流程

目标：本机 Host + 4 台 Guest VM（macvm / linuxvm / windowsvm / winx64）。

**推荐方式：`scp` + `ssh`，不要用 `--exec` 做部署。**

原因：`--exec` 执行 `pkill utmm` 会导致 KCP 隧道断开，
后续 `--exec` 全部报 `GuestNotConnected`。用 `scp` 传二进制 +
`ssh` 远程执行 install 一条命令完成，干净可靠。

```bash
# 通用模板
scp <platform-binary> <user>@<ip>:/tmp/utmm-new
ssh <user>@<ip> "<cleanup> && cp /tmp/utmm-new /opt/utmm/utmm && /opt/utmm/utmm --install --hostname <name>"
```

#### macOS Guest

```bash
sshpass -p 111 scp -o StrictHostKeyChecking=no ./zig-out/bin/utmm-aarch64-macos-0.11.23 root@192.168.64.4:/tmp/utmm-new
sshpass -p 111 ssh -o StrictHostKeyChecking=no root@192.168.64.4 \
  "launchctl bootout system/com.utmmd 2>/dev/null; pkill -9 utmm 2>/dev/null; pkill -9 utmmd 2>/dev/null; sleep 1; rm -f /opt/utmm/utmm /opt/utmm/utmmd /opt/utmm/utmm.conf /Library/LaunchDaemons/com.utmmd.plist /var/run/utmm.sock /var/log/utmmd.log; mkdir -p /opt/utmm; cp /tmp/utmm-new /opt/utmm/utmm; chmod +x /opt/utmm/utmm; /opt/utmm/utmm --install --hostname macvm"
```

#### Linux Guest

```bash
sshpass -p 111 scp -o StrictHostKeyChecking=no ./zig-out/bin/utmm-aarch64-linux-0.11.23 root@192.168.64.2:/tmp/utmm-new
sshpass -p 111 ssh -o StrictHostKeyChecking=no root@192.168.64.2 \
  "systemctl stop utmmd 2>/dev/null; pkill -9 utmm 2>/dev/null; pkill -9 utmmd 2>/dev/null; sleep 1; rm -f /opt/utmm/utmm /opt/utmm/utmmd /opt/utmm/utmm.conf /etc/systemd/system/utmmd.service /var/run/utmm.sock; mkdir -p /opt/utmm; cp /tmp/utmm-new /opt/utmm/utmm; chmod +x /opt/utmm/utmm; /opt/utmm/utmm --install --hostname linuxvm"
```

#### Windows Guest

**关键问题**：Windows SSH 的默认 `cmd.exe` 环境 PATH 不完整 —
`sc`、`taskkill`、`del` 等命令找不到。**必须用 PowerShell**。

```bash
# 传二进制
sshpass -p 111 scp -o StrictHostKeyChecking=no ./zig-out/bin/utmm-aarch64-windows-0.11.23.exe Administrator@192.168.65.2:"C:/temp/utmm-new.exe"

# 清理 + 安装（用 PowerShell）
sshpass -p 111 ssh -o StrictHostKeyChecking=no Administrator@192.168.65.2 \
  "powershell -Command \"Stop-Process -Name utmmd -Force -ErrorAction SilentlyContinue; Stop-Process -Name utmm -Force -ErrorAction SilentlyContinue; Start-Sleep 2; Remove-Item -Force C:\opt\utmm\utmm.exe -ErrorAction SilentlyContinue; Remove-Item -Force C:\opt\utmm\utmmd.exe -ErrorAction SilentlyContinue; Copy-Item -Force C:\temp\utmm-new.exe C:\opt\utmm\utmm.exe; & C:\opt\utmm\utmm.exe --install --hostname windowsvm\""
```

**Windows 平台二进制对应表：**

| 目标 VM | 二进制文件 |
|---------|-----------|
| windowsvm (aarch64) | `utmm-aarch64-windows-0.11.23.exe` |
| winx64 (x86_64) | `utmm-x86_64-windows-0.11.23.exe` |

### 本机 Host 安装

```bash
# 清理
sudo launchctl bootout system/com.utmmd 2>/dev/null
sudo pkill -9 utmm; sudo pkill -9 utmmd
sudo rm -f /opt/utmm/utmm /opt/utmm/utmmd /opt/utmm/utmm.conf
sudo rm -f /Library/LaunchDaemons/com.utmmd.plist /var/run/utmm.sock /dev/shm/utmmd-shm /var/log/utmmd.log

# 构建 + 安装
zig build
sudo ./zig-out/bin/utmm --host --install
```

---

## 验证

### 逐个执行，不要并发

`--exec` 基于 PTY 异步流式输出。多个 `--exec` 并发时，
远程输出到达时间不确定 → 本地输出会交错混乱。

```bash
# ❌ 错误：输出会交错
sudo ./zig-out/bin/utmm --exec linuxvm "uname -a" &
sudo ./zig-out/bin/utmm --exec macvm "uname -a" &

# ✅ 正确：逐个执行
sudo ./zig-out/bin/utmm --exec linuxvm "uname -a"
sudo ./zig-out/bin/utmm --exec macvm "uname -a"
```

### `--status` 是即时验证的最好方式

```bash
sudo ./zig-out/bin/utmm --status
# 0.024s 响应，确认所有 Guest 在线且版本一致
```

---

## 构建

```bash
zig build                        # 本机构建 → zig-out/bin/utmm
zig build test                   # 全量测试
```

交叉编译在 release 时通过 `release.sh` 完成，日常开发只需本机构建。

---

## macOS launchctl 注意事项

### bootstrap 失败（exit 5: Input/output error）

可能原因及处理：

1. **launchd throttle（限流）**：同一 service label 短时间反复 bootout/bootstrap
   超过阈值，launchd 拒绝加载返回 EIO。通常持续 5-10 分钟自动解除。
   **触发场景**：频繁测试重装。生产环境几乎不会触发。

2. **disabled flag**：`launchctl disable` 或异常卸载后，服务被持久标记为 disabled。
   检查：`launchctl print-disabled system | grep utmm`
   修复：`enable` 必须在 `bootout` 之前调用（因为 enable 需要服务 label
   存在于 launchd 中，bootout 之后找不到服务返回 exit 64）。

3. **代码处理**：`installMacOS` 中 bootstrap 是 best-effort（不验证结果），
   真正的启动验证在 `start()` 中：`kickstart → enable → bootout → bootstrap × 3
   → startDirect`。`startDirect` 是终极回退，直接后台运行 utmmd 绕过 launchd。
   注意：`startDirect` 不传 `--hostname`，Guest 会用系统 hostname。

### launchctl load（legacy）的陷阱

`launchctl load` 在 bootstrap 失败时同样失败，但**返回 exit 0**（只打印错误到
stderr）。不能仅靠 exit code 判断成功 — 必须验证服务是否出现在 `launchctl list` 中。
当前代码已移除 legacy load 回退，改为 `startDirect`。

### enable 的 exit 64

`enable system/<name>` 在以下情况返回 exit 64（EX_USAGE）：
- 服务从未被 launchd 注册（首次安装）
- 服务被 bootout 后且 throttle 期间

这是无害的 — `enable` 仅清除 disabled flag，如果 flag 不存在，无需清除。
代码中 `_ = runCmd(...)` 忽略此错误。

