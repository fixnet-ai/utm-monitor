# Clean Deploy Skill — UTM Monitor 裸机部署测试

本 skill 执行完整的"清空—构建—部署—测试"循环，模拟从零开始在裸机上部署
UTM Monitor 的完整流程。每次执行后总结问题点和可改进之处。

## 触发条件

当用户要求以下操作时，使用本 skill：
- "裸机部署测试" / "clean deploy"
- "从零开始部署并测试"
- "全清空重建"

## VM 配置表

| VM | Hostname | Target | IP | User | Password | Remote Dir | OS |
|----|----------|--------|----|------|--------|------------|-----|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root | 111 | /opt/utmm | macOS |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root | 111 | /opt/utmm | Linux |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator | 111 | C:\opt\utmm | Windows |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator | 111 | C:\opt\utmm | Windows |

## 实战踩坑记录

| # | 问题 | 根因 | 解决 |
|---|------|------|------|
| 1 | **scp 失败** | `/opt/utmm` 目录在清空时被删除 | scp 前先 `mkdir -p /opt/utmm` |
| 2 | **SSH 复合命令失败** | 含特殊字符的长命令 exit 255 | 拆成多个短 SSH 调用 |
| 3 | **macOS `timeout` 不可用** | macOS 无此命令 | 用后台进程 + `kill -0` 轮询模式 |
| 4 | **macOS bootstrap errno=5** | `launchctl bootout` 重设 disabled flag | `enable → bootout → enable → bootstrap` |
| 5 | **Windows 路径反斜杠被吞** | bash 把 `\` 当转义符 | 用单引号包裹：`'C:\opt\utmm\file.txt'` |
| 6 | **二进制名含版本号** | `zig build -Dtarget=...` 产物带版本后缀 | 实际文件名 `utmm-aarch64-macos-0.14.1` |

## 执行流程

### 阶段 1：全量清空

**目标**：停止所有 utmm 进程、服务，删除二进制、配置、日志，
使各机器恢复到未安装状态。

#### 1.1 清空本机 macOS Host

```bash
# 停止并移除服务
sudo launchctl bootout system/com.utmmd 2>/dev/null || true

# 清理旧服务名（legacy）
sudo launchctl bootout system/com.utmm.host 2>/dev/null || true
sudo launchctl bootout system/com.utmm.guest 2>/dev/null || true
sudo launchctl bootout system/com.utmm 2>/dev/null || true

# 等待进程退出
sleep 2

# 强制杀残留
sudo pkill -9 -f utmm 2>/dev/null || true
sudo pkill -9 -f utmmd 2>/dev/null || true

# 删除 plist
sudo rm -f /Library/LaunchDaemons/com.utmmd.plist
sudo rm -f /Library/LaunchDaemons/com.utmm.host.plist
sudo rm -f /Library/LaunchDaemons/com.utmm.guest.plist
sudo rm -f /Library/LaunchDaemons/com.utmm.plist

# 删除二进制
sudo rm -rf /opt/utmm

# 删除日志
sudo rm -f /var/log/utmm*.log /var/log/utm*.log
sudo rm -f /var/log/utmm*.bak /var/log/utm*.bak
sudo rm -f /var/log/utmm*.old /var/log/utm*.old
sudo rm -f /var/log/utmmd*.log

# 删除 IPC socket
sudo rm -f /var/run/utmm.sock
```

#### 1.2 清空 macvm (macOS Guest)

```bash
# 注意：bootout 会重设 disabled flag，之后需要重新 enable
sshpass -p 111 ssh root@192.168.64.4 '
launchctl enable system/com.utmmd 2>/dev/null
launchctl bootout system/com.utmmd 2>/dev/null || true
launchctl enable system/com.utmmd 2>/dev/null
launchctl bootout system/com.utmm.guest 2>/dev/null || true
launchctl disable system/com.utmm.guest 2>/dev/null || true
launchctl bootout system/com.utmm.host 2>/dev/null || true
launchctl disable system/com.utmm.host 2>/dev/null || true
sleep 2
pkill -9 -f utmm 2>/dev/null || true
pkill -9 -f utmmd 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.utmmd.plist
rm -f /Library/LaunchDaemons/com.utmm.guest.plist
rm -f /Library/LaunchDaemons/com.utmm.host.plist
rm -rf /opt/utmm
rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log
rm -f /var/run/utmm.sock /var/run/utmm-install.lock
echo "macvm cleaned"
'
```

#### 1.3 清空 linuxvm (Linux Guest)

```bash
sshpass -p 111 ssh root@192.168.64.2 '
systemctl stop utmmd 2>/dev/null || true
systemctl stop utmm-guest 2>/dev/null || true
systemctl disable utmmd 2>/dev/null || true
systemctl disable utmm-guest 2>/dev/null || true
sleep 2
pkill -9 -f utmm 2>/dev/null || true
pkill -9 -f utmmd 2>/dev/null || true
rm -f /etc/systemd/system/utmmd.service
rm -f /etc/systemd/system/utmm-guest.service
rm -f /etc/systemd/system/utmm-host.service
rm -f /etc/init.d/utmm*
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/utmm
rm -f /var/log/utmm*.log /var/log/utm*.log /var/log/utmmd*.log
rm -f /var/run/utmm.sock /var/run/utmm-install.lock
echo "linuxvm cleaned"
'
```

#### 1.4 清空 Windows VM（前提：需先启用 OpenSSH Server）

```bash
# windowsvm
sshpass -p 111 ssh Administrator@192.168.65.2 'powershell -Command "
sc.exe stop UTM-MonitorD 2>$null; sc.exe delete UTM-MonitorD 2>$null;
Start-Sleep -Seconds 3;
taskkill /F /IM utmm.exe 2>$null; taskkill /F /IM utmmd.exe 2>$null;
Remove-Item -Recurse -Force C:\opt\utmm -ErrorAction SilentlyContinue
"'
echo "windowsvm cleaned"

# winx64
sshpass -p 111 ssh Administrator@192.168.3.108 'powershell -Command "
sc.exe stop UTM-MonitorD 2>$null; sc.exe delete UTM-MonitorD 2>$null;
Start-Sleep -Seconds 3;
taskkill /F /IM utmm.exe 2>$null; taskkill /F /IM utmmd.exe 2>$null;
Remove-Item -Recurse -Force C:\opt\utmm -ErrorAction SilentlyContinue
"'
echo "winx64 cleaned"
```

#### 1.5 验证清空

```bash
# 确认 Host 无 utmm 进程
ps aux | grep -i utmm | grep -v grep || echo "Host clean"

# 确认各 Guest 无 utmm 进程
sshpass -p 111 ssh root@192.168.64.4 'ps aux | grep -i utmm | grep -v grep || echo "macvm clean"'
sshpass -p 111 ssh root@192.168.64.2 'ps aux | grep -i utmm | grep -v grep || echo "linuxvm clean"'
sshpass -p 111 ssh Administrator@192.168.65.2 'tasklist /fi "imagename eq utmm.exe" 2>nul & tasklist /fi "imagename eq utmmd.exe" 2>nul || echo "windowsvm clean"'
sshpass -p 111 ssh Administrator@192.168.3.108 'tasklist /fi "imagename eq utmm.exe" 2>nul & tasklist /fi "imagename eq utmmd.exe" 2>nul || echo "winx64 clean"'
```

### 阶段 2：构建

```bash
# 2.1 单元测试
zig build test
# 必须 0 失败

# 2.2 集成测试
zig build test-integration
# 必须 0 失败

# 2.3 本机构建 (Debug)
zig build

# 2.4 交叉编译（ReleaseSafe）
# 产物含版本号后缀（如 utmm-aarch64-linux-0.14.1），部署时注意
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

### 阶段 3：部署

#### 3.1 部署本机 Host

```bash
# 安装 Host
sudo ./zig-out/bin/utmm --host --install

# 等待启动
sleep 5

# 初始状态检查（此时应该只有 Host 自己）
sudo ./zig-out/bin/utmm --status
```

#### 3.2 部署 linuxvm

```bash
# 创建目标目录（清空后 /opt/utmm 已删除）
sshpass -p 111 ssh root@192.168.64.2 'mkdir -p /opt/utmm'

# scp 二进制（注意：文件名含版本号后缀）
sshpass -p 111 scp zig-out/bin/utmm-aarch64-linux-0.14.1 root@192.168.64.2:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.2 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname linuxvm'
```

#### 3.3 部署 macvm

```bash
# 创建目标目录
sshpass -p 111 ssh root@192.168.64.4 'mkdir -p /opt/utmm'

# scp 二进制
sshpass -p 111 scp zig-out/bin/utmm-aarch64-macos-0.14.1 root@192.168.64.4:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.4 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname macvm'
```

#### 3.4 部署 Windows VM

```bash
# windowsvm — mkdir + scp + ssh install
sshpass -p 111 ssh Administrator@192.168.65.2 'mkdir C:\opt\utmm 2>nul'
sshpass -p 111 scp zig-out/bin/utmm-aarch64-windows-0.14.1.exe Administrator@192.168.65.2:C:/opt/utmm/utmm-new.exe
sshpass -p 111 ssh Administrator@192.168.65.2 'C:\opt\utmm\utmm-new.exe --install --hostname windowsvm'

# winx64
sshpass -p 111 ssh Administrator@192.168.3.108 'mkdir C:\opt\utmm 2>nul'
sshpass -p 111 scp zig-out/bin/utmm-x86_64-windows-0.14.1.exe Administrator@192.168.3.108:C:/opt/utmm/utmm-new.exe
sshpass -p 111 ssh Administrator@192.168.3.108 'C:\opt\utmm\utmm-new.exe --install --hostname winx64'
```

### 阶段 4：全功能测试

#### 4.1 等待 LSA 同步

```bash
# 等待 Guest 通过 LSA 注册到 Host（2s 广播 × 3 超时 = 6s + 连接）
sleep 15

# 检查状态
sudo ./zig-out/bin/utmm --status
# 期望：全部 Guest 显示 online
```

#### 4.2 Exec 测试

```bash
sudo ./zig-out/bin/utmm --exec linuxvm "echo OK"
sudo ./zig-out/bin/utmm --exec macvm "echo OK"
sudo ./zig-out/bin/utmm --exec windowsvm "echo OK"
sudo ./zig-out/bin/utmm --exec winx64 "echo OK"
# 期望：全部返回 OK + exit_code=0
```

#### 4.3 Upload 测试

```bash
echo "upload-test-$(date +%s)" > /tmp/clean_deploy_test.txt

sudo ./zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt linuxvm
sudo ./zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt macvm
# Windows upload 也 OK — utmm 内部处理路径格式
sudo ./zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt windowsvm
sudo ./zig-out/bin/utmm --upload /tmp/clean_deploy_test.txt winx64
# 期望：全部返回 OK
```

#### 4.4 Download 测试

```bash
sudo ./zig-out/bin/utmm --download linuxvm /opt/utmm/clean_deploy_test.txt /tmp/dl_linux.txt
sudo ./zig-out/bin/utmm --download macvm /opt/utmm/clean_deploy_test.txt /tmp/dl_mac.txt
# ⚠️  Windows 路径必须单引号包裹，否则 bash 吞反斜杠导致 0 字节
sudo ./zig-out/bin/utmm --download windowsvm 'C:\opt\utmm\clean_deploy_test.txt' /tmp/dl_win.txt
sudo ./zig-out/bin/utmm --download winx64 'C:\opt\utmm\clean_deploy_test.txt' /tmp/dl_win64.txt

# 验证内容一致
sha256sum /tmp/clean_deploy_test.txt /tmp/dl_*.txt
```

#### 4.5 Ping 测试

```bash
sudo ./zig-out/bin/utmm --ping linuxvm
sudo ./zig-out/bin/utmm --ping macvm
sudo ./zig-out/bin/utmm --ping windowsvm
sudo ./zig-out/bin/utmm --ping winx64
```

### 阶段 5：总结

测试结束后，记录：

```markdown
## 裸机部署测试总结

### 测试结果
| 测试项 | linuxvm | macvm | windowsvm | winx64 |
|--------|---------|-------|-----------|--------|
| --exec | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --upload | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --download | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| --ping | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |

### 遇到的问题
1. ...
2. ...

### 可改进之处
1. ...
2. ...
```

## 跨平台路径速查

| 路径 | POSIX | Windows |
|------|-------|---------|
| 安装目录 | `/opt/utmm/` | `C:\opt\utmm\` |
| 二进制 | `/opt/utmm/utmm` | `C:\opt\utmm\utmm.exe` |
| 监督进程 | `/opt/utmm/utmmd` | `C:\opt\utmm\utmmd.exe` |
| IPC socket | `/var/run/utmm.sock` | `\\.\pipe\utmm` |
| 安装锁 | `/var/run/utmm-install.lock` | `C:\opt\utmm\utmm-install.lock` |
| macOS 服务 | `/Library/LaunchDaemons/com.utmmd.plist` | — |
| Linux 服务 | `/etc/systemd/system/utmmd.service` | — |
| 日志 | `/var/log/utmmd.log` | 无（sc.exe 管理） |
| bash 中 Windows 路径 | — | 必须单引号包裹 `'C:\opt\utmm\file.txt'` |

## 注意事项

- 本 skill **不可逆** — 清空操作会删除所有配置、日志和历史数据
- 仅在开发/测试阶段使用，**不要**在生产环境执行
- Windows VM 需预先启用 OpenSSH Server（`Add-WindowsCapability -Online -Name OpenSSH.Server`）
- 清空后 `/opt/utmm` 目录被删除，部署前需 `mkdir -p /opt/utmm`
- LSA 同步需要等待 ~15s，不要在部署后立即测试
- **Windows download 路径必须单引号包裹**，否则 bash 吞反斜杠：`'C:\opt\utmm\file.txt'`
- **交叉编译产物含版本号后缀**（如 `utmm-aarch64-macos-0.14.1`），scp 时注意
- **macOS `launchctl bootout` 会重设 disabled flag**，bootstrap 前必须 `enable`
- SSH 复合命令避免过长（含 `&&`、管道、特殊字符多的），拆成多个短调用
- macOS 无 `timeout` 命令，超时场景用后台进程 + `kill -0` 轮询
- download 测试后记得 `sudo rm` 清理下载文件（sudo 创建的）
