# Deploy Skill — UTM Monitor 一键部署

本 skill 封装了 UTM Monitor 的完整部署流程：编译 → 部署 Host → 部署 Guest → 验证。

## 触发条件

当用户要求以下操作时，使用本 skill：
- "部署" / "deploy"
- "上线" / "发布"
- "更新所有 VM"
- "升级到 vX.Y.Z"

## VM 配置表

| VM | Hostname | Target | IP | User | Password | Remote Dir |
|----|----------|--------|----|------|--------|------------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root | 111 | /opt/utmm |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root | 111 | /opt/utmm |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator | 111 | C:\opt\utmm |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator | 111 | C:\opt\utmm |

## 部署流程

### 1. 版本准备

```bash
# 读取当前版本
grep "pub const VERSION" src/protocol.zig

# 如果尚未 bump，询问用户目标版本号
# 更新 src/protocol.zig 和 build.zig.zon
```

### 2. 编译 + 测试

```bash
# 1. 运行全部测试
zig build test

# 2. 本地编译 (macOS Host)
zig build

# 3. 验证二进制类型
file zig-out/bin/utmm
# 必须输出: Mach-O 64-bit executable arm64
```

### 3. 部署 Host (本机 macOS)

```bash
# 停止旧服务 → 覆盖二进制 → 启动
sudo launchctl bootout system/com.utmm.host 2>/dev/null || true
sudo cp zig-out/bin/utmm /opt/utmm/utmm
# 如果 bootstrap 失败 (errno=5)，用 kickstart：
sudo launchctl kickstart -k system/com.utmm.host 2>/dev/null || \
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmm.host.plist

# 等待 Host 启动
sleep 3
sudo ./zig-out/bin/utmm --status
```

### 4. 部署 Guest

**推荐方式 — 使用 `--deploy` 命令（需要 sshpass）：**

```bash
# 部署所有 Guest (交叉编译 + SCP + SSH install)
sudo ./zig-out/bin/utmm --deploy

# 部署单个 Guest
sudo ./zig-out/bin/utmm --deploy linuxvm
```

`--deploy` 命令自动完成：交叉编译 → SCP 上传 → SSH 安装 → 输出成功/失败摘要。

**手动方式（不支持 `--deploy` 时使用）：**

Linux Guest:
```bash
zig build -Dtarget=aarch64-linux-musl
sshpass -p 111 scp zig-out/bin/utmm-aarch64-linux root@192.168.64.2:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.2 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname linuxvm'
```

macOS Guest:
```bash
zig build -Dtarget=aarch64-macos
sshpass -p 111 scp zig-out/bin/utmm-aarch64-macos root@192.168.64.4:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.4 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname macvm'
```

Windows Guest (手动):
```bash
zig build -Dtarget=aarch64-windows
# 复制 utmm-aarch64-windows.exe → C:\opt\utmm\utmm-new.exe（通过 SMB 共享或其他方式）
# 然后运行: C:\opt\utmm\utmm-new.exe --install --hostname windowsvm
```

### 5. 验证

```bash
# 健康检查全部 Guest
sudo ./zig-out/bin/utmm --verify
# 期望输出: 全部 ✓ (status, ping, exec)
```

### 6. 清理 + 更新规划文件

部署确认后：
- 更新 `task_plan.md` — 标记当前阶段完成
- 更新 `progress.md` — 记录部署结果
- 更新 `findings.md` — 记录任何新发现
- Git commit + push

## macOS 常见问题处理

| 问题 | 症状 | 解决 |
|------|------|------|
| **bootstrap errno=5** | `launchctl bootstrap` 返回错误 5 | `sudo launchctl kickstart -k system/com.utmm.host` |
| **bootstrap errno=2** | 服务未加载 | `sudo launchctl enable system/com.utmm.host && sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmm.host.plist` |
| **codesign 失效** | `kill -9` 后进程被系统终止 | `sudo codesign --force --sign - /opt/utmm/utmm` |
| **Guest 不响应** | `GuestNotConnected` | 等待 10-15s 让 KCP 隧道重建，KCP 5s keepalive × 3 = 15s 死亡检测 |

## 并行部署策略

`--deploy` 命令自动处理并行部署，一次命令部署全部 Guest。如需手动控制，按以下顺序：

1. **先部署 Host**（版本 bump → 本地 `--install`）— Guest 通过 LSA 检测新版本
2. **然后部署 Guest**（`--deploy` 或手动 scp + ssh）— 交叉编译可并行
3. **最后验证**（`--verify`）— 确认全部通过

## 安全注意事项

- 密码硬编码在代码中仅用于本地 UTM 测试环境
- `sshpass` 会暴露密码在进程列表中，仅在受信网络中使用
- 生产环境应使用 SSH key 认证
- 部署后验证 `--verify` 确保所有 Guest 在线且响应正常
