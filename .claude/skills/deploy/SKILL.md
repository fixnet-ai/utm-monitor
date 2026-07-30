# Deploy Skill — UTM Monitor 一键部署

本 skill 封装了 UTM Monitor 的完整部署流程：编译 → 测试 → 部署 Host → 部署 Guest → 验证。

## 触发条件

当用户要求以下操作时，使用本 skill：
- "部署" / "deploy"
- "上线" / "发布"
- "更新所有 VM"
- "升级到 vX.Y.Z"
- "交叉编译并部署"

## VM 配置表

| VM | Hostname | Target | IP | User | Password | Remote Dir |
|----|----------|--------|----|------|--------|------------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root | 111 | /opt/utmm |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root | 111 | /opt/utmm |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator | 111 | C:\opt\utmm |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator | 111 | C:\opt\utmm |

## 部署流程

### 1. 编译 + 测试（必须先通过）

```bash
# 单元测试
zig build test                    # 必须 0 失败

# 集成测试（本机架构）
zig build test-integration         # 必须 0 失败

# 本机编译 (macOS Host, Debug 用于开发)
zig build                          # → zig-out/bin/utmm (Mach-O aarch64)
```

> **重要**：集成测试二进制 `zig-out/bin/integration_test` 的架构取决于最后编译的 target。
> 交叉编译后会被覆盖为 ELF 格式（无法在 macOS 运行）。部署到 VM 前如需重跑集成测试，
> 先执行 `zig build test-integration` 恢复 Mach-O 格式。

### 2. 交叉编译 Guest 二进制

```bash
# ReleaseSafe — 所有部署必须使用
# 注意：产物含版本号后缀，如 utmm-aarch64-linux-0.14.2
#       用 `cat src/ver.txt` 获取当前版本号
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl    # → zig-out/bin/utmm-aarch64-linux-<ver>
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos         # → zig-out/bin/utmm-aarch64-macos-<ver>
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-windows       # → zig-out/bin/utmm-aarch64-windows-<ver>.exe
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows        # → zig-out/bin/utmm-x86_64-windows-<ver>.exe
```

> **仅需 `utmm` 二进制**：`utmm` 内嵌了 `utmmd.bin`（监督进程），`--install` 会自动
> 提取 `utmmd` 到 `/opt/utmm/utmmd`。部署只需复制一个文件。

### 3. 部署 Host（本机 macOS）

服务名为 `com.utmmd`（单一 utmmd 监督进程，角色通过 `--role host|guest` 区分）。

```bash
# 停止旧服务
sudo launchctl bootout system/com.utmmd 2>/dev/null || true

# 覆盖二进制
sudo cp zig-out/bin/utmm /opt/utmm/utmm

# 启动服务（kickstart 优先，失败则 bootstrap）
sudo launchctl kickstart -k system/com.utmmd 2>/dev/null || \
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmmd.plist

# 等待 LSA 稳定（Guest 需要 10-15s 重新注册）
sleep 5
sudo ./zig-out/bin/utmm --status
```

> **注意**：首次安装（无 plist 文件）需用 `sudo utmm --host --install` 生成 plist。

### 4. 部署 Guest

**Linux Guest:**
```bash
sshpass -p 111 scp zig-out/bin/utmm-aarch64-linux-0.14.2 root@192.168.64.2:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.2 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname linuxvm'
```

**macOS Guest:**
```bash
sshpass -p 111 scp zig-out/bin/utmm-aarch64-macos-0.14.2 root@192.168.64.4:/opt/utmm/utmm-new
sshpass -p 111 ssh root@192.168.64.4 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname macvm'
```

**Windows Guest:**
```bash
# windowsvm (aarch64)
sshpass -p 111 scp zig-out/bin/utmm-aarch64-windows-0.14.2.exe Administrator@192.168.65.2:C:/opt/utmm/utmm-new.exe
sshpass -p 111 ssh Administrator@192.168.65.2 'C:\opt\utmm\utmm-new.exe --install --hostname windowsvm'

# winx64 (x86_64)
sshpass -p 111 scp zig-out/bin/utmm-x86_64-windows-0.14.2.exe Administrator@192.168.3.108:C:/opt/utmm/utmm-new.exe
sshpass -p 111 ssh Administrator@192.168.3.108 'C:\opt\utmm\utmm-new.exe --install --hostname winx64'
```

> **前提**：Windows VM 需启用 OpenSSH Server（`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`）。

> **`--deploy` 命令**（实验性）：理论上 `sudo utmm --deploy [vm]` 可自动完成交叉编译 +
> SCP + SSH 安装，但需要 sshpass 且实现不稳定，当前推荐手动方式。

### 5. 验证部署

```bash
# 1. 健康检查 — 确认所有 Guest 在线
sudo ./zig-out/bin/utmm --status
# 期望：所有 Guest 显示 online + 版本号

# 2. 执行测试 — 每个 VM 跑一条简单命令
sudo ./zig-out/bin/utmm --exec macvm "echo OK"
sudo ./zig-out/bin/utmm --exec linuxvm "echo OK"
sudo ./zig-out/bin/utmm --exec windowsvm "echo OK"
sudo ./zig-out/bin/utmm --exec winx64 "echo OK"
# 期望：全部返回 OK + exit_code=0

# 3. 上传测试（已知可能失败 — 见下方已知问题）
sudo ./zig-out/bin/utmm --upload /tmp/test.txt linuxvm
```

### 6. 收尾

部署确认后：
- 更新 `task_plan.md` — 标记当前阶段完成
- 更新 `progress.md` — 记录部署结果
- 更新 `findings.md` — 记录新发现的问题
- Git commit + push

## 跨平台路径注意事项

| 场景 | POSIX | Windows | 注意 |
|------|-------|---------|------|
| Guest 安装目录 | `/opt/utmm` | `C:\opt\utmm` | svc.canonicalDir() 自动适配 |
| IPC socket | `/var/run/utmm.sock` | `\\.\pipe\utmm` | ipc.zig 自动适配 |
| 服务配置 | `/Library/LaunchDaemons/com.utmmd.plist` | `sc.exe create` | svc.zig 按平台分支 |
| SSH 传 Windows 路径 | `C:\opt\utmm\file.txt` | 单引号包裹 | bash 吞噬反斜杠 |
| 交叉编译产物 | `utmm-aarch64-macos-0.14.2` | `utmm-aarch64-windows-0.14.2.exe` | 含版本号后缀 |

## macOS 常见问题处理

| 问题 | 症状 | 解决 |
|------|------|------|
| **bootstrap errno=5** | `launchctl bootstrap` 返回错误 5 | v0.14.2 已修复：bootout 重设 disabled flag → enable after bootout。旧版可手动 `launchctl enable system/com.utmmd` 后再 bootstrap |
| **bootstrap errno=2** | 服务未加载 | `sudo launchctl enable system/com.utmmd && sudo launchctl bootstrap system /Library/LaunchDaemons/com.utmmd.plist` |
| **codesign 失效** | `kill -9` 后进程被系统终止 | `sudo codesign --force --sign - /opt/utmm/utmm` |
| **Guest 不响应** | `GuestNotConnected` | 等待 10-15s 让 LSA 重新注册（LSA 2s 广播 × 3 次超时 = 6s + 连接建立时间） |
| **--install 卡 5 秒** | `waitOldProcesses` 等待超时 | 正常现象 — 固定 5s 超时等旧进程退出，不是 hang |

## 已知问题

| # | 问题 | 影响 | 状态 |
|---|------|------|------|
| 1 | **5s 安装超时** | 每次 `--install` 都会等满 5s（`waitOldProcesses` 超时） | 已知延迟，非阻塞问题 |
| 2 | **集成测试二进制覆盖** | `zig build -Dtarget=...` 交叉编译后 `integration_test` 变 ELF | 部署本地前重跑 `zig build test-integration` |
| 3 | **二进制 hash 不一致** | 自复制安装修改二进制（嵌入规范路径），hash 与编译产物不同 | 正常行为，勿用 hash 对比验证部署 |
| 4 | **`--deploy` 不可靠** | 依赖 sshpass 且实现不完整 | 使用手动 scp + ssh 方式 |

## 并行部署策略

部署顺序（Guest 部署可并行）：

1. **先部署 Host** — 停止服务 → 覆盖二进制 → 启动 → `--status` 确认
2. **然后并行部署 Guest** — linuxvm + macvm + windowsvm + winx64 的 scp+ssh 可同时进行
3. **最后验证** — `--status` + `--exec <vm> "echo OK"` 逐个确认

## 安全注意事项

- 密码硬编码在代码中仅用于本地 UTM 测试环境
- `sshpass` 会暴露密码在进程列表中，仅在受信网络中使用
- 生产环境应使用 SSH key 认证
- 部署后必须逐个验证 VM 可执行命令
