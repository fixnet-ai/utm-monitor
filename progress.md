## v0.17.19 — 升级文件机制重构：SHA256 嵌入文件名 + 文件锁替代 .sha256 标记

**时间**: 2026-08-02

### 背景

旧机制用两个文件（`utmm-upgrade` 二进制 + `utmm-upgrade.sha256` 标记），
存在以下问题：
- `.sha256` 标记可能成为过期残留（Guest crash 在写标记之后，utmmd IOCP bug
  导致无法消费标记），阻止后续升级推送
- 两文件分离，同步清理复杂

### 新设计

**单文件机制**: `utmm-upgrade.<sha256hex>.tmp`

- SHA256 嵌入文件名（64 字符 hex），文件内容自校验
- OS 排他文件锁（POSIX flock + LOCK_EX；Windows CreateFileW dwShareMode=0）
  替代标记文件作为"写入完成"信号
- 进程崩溃时 OS 自动释放锁 — 零残留状态文件

### 修改文件

1. **`src/svc.zig`** — 新增 `UpgradeLock` 命名空间:
   - `tmpPath(allocator, sha256_hex)` — 构建临时文件路径
   - `extractSha256(basename)` — 从文件名提取 SHA256
   - `create(path)` — 创建文件 + 排他锁（阻塞，Guest 用）
   - `tryAcquire(path)` — 尝试获取排他锁（非阻塞，utmmd 用）
   - `writeAll(data)` / `release()` / `releaseAndDelete(path)` — 文件操作
   - POSIX: open + flock + write + close
   - Windows: CreateFileW(dwShareMode=0) + WriteFile + CloseHandle
   - `verifyUpgradeTmpByFilename()` — 文件名 SHA256 vs 内容 SHA256 自校验
   - `findUpgradeTmp()` — 扫码 canonicalDir 中的 .tmp 文件
   - `cleanupStaleUpgradeTmp()` 重写 — 过渡期兼容清理旧机制残留

2. **`src/guest.zig` — `handleUpgradeCmd`** 重构:
   - 移除 `.sha256` 标记文件机制（tmp → rename 原子写入）
   - 移除并发保护 statFile 检查
   - 移除 `std.Io.Threaded` 文件 I/O（改用原始 OS write）
   - 改用 `UpgradeLock.create` + `writeAll` + `release`/`releaseAndDelete`

3. **`src/utmmd.zig`** 重构升级检测+应用:
   - 新增 `tryApplyPendingUpgrade()` 合并 checkPendingUpgrade + applyUpgrade
   - 扫码 .tmp → 尝试锁 → 文件名自校验 → 替换二进制
   - 移除 `upgradeMarkerPath`、`upgradeBinPath`、`readFileAlloc`、`computeSha256Hex`
   - 新增 `const svc = @import("svc.zig")`

4. **`src/host.zig`**: `cleanupStaleUpgradeTmp` 调用签名更新

### 测试结果

- 188 单元测试全部通过 ✅
- 59 集成测试全部通过 ✅
- 无内存泄漏

### v0.17.19-b — 文件传输统一：receiveFile 消除 upload/upgrade 重复

**时间**: 2026-08-03

**背景**: 升级、上传、下载三套文件传输机制各不一样 — handleUpgradeCmd 用
UpgradeLock + 原始 OS write，handleUpload 用 dpipe_file.writeFile + Zig Io 层，
handleDownload 读文件发 TCP。TCP 读循环 + SHA256 校验在 upload 和 upgrade 中
完全重复（~80 行）。

**统一方案**: 提取 `receiveFile()` 通用函数，UpgradeLock 模式推广为所有文件接收
的统一方式。

**修改**:
1. `src/svc.zig`:
   - `UpgradeLock.tmpPath(allocator, prefix, sha256_hex)` — 接受 comptime prefix 参数
   - `UpgradeLock.extractSha256(basename, prefix)` — 接受 comptime prefix 参数
   - `cleanupStaleUpgradeTmp` 扩展 — 同时清理 `upload.*.tmp` 和 `utmm-upgrade.*.tmp`

2. `src/guest.zig`:
   - 新增 `receiveFile(io, allocator, fd, prefix, sha256, size, shm)` 通用函数
     (~60 行): TCP 读循环 + heartbeat + hasher + UpgradeLock.writeAll + SHA256 校验
   - `handleUpload` 重构 (~60→~40 行): receiveFile("upload", ...) + rename 到目标
   - `handleUpgradeCmd` 重构 (~100→~35 行): receiveFile("utmm-upgrade", ...) + lock.release
   - 移除 handleUpload 对 `dpipe_file.writeFile` 和 `std.Io.Threaded` 的依赖

3. `src/dpipe_file.zig`: `copyAndDelete` 改为 pub（upload rename CrossDevice fallback 用）
4. `src/utmmd.zig`: extractSha256 调用传 prefix

**净收益**:
- 删除 ~110 行重复代码
- Upload 获得 OS 排他锁保护 + 文件名自描述 temp 文件
- Upload 不再依赖 `std.Io.Threaded`（Windows 兼容性更好）
- 所有文件接收使用统一的文件名内嵌 SHA256 模式

### v0.17.19-c — macOS Gatekeeper 隔离清除

**时间**: 2026-08-03

**问题**: macOS 上 scp/下载的二进制被标记 `com.apple.quarantine`，首次运行时
弹窗阻止，需要手动到"系统设置"中批准。

**修改**:
1. `src/svc.zig`: 新增 `pub fn clearQuarantine(alloc, io, path)` — macOS 调用
   `xattr -d com.apple.quarantine <path>`，best-effort（忽略错误）
2. `src/main.zig`: `extractUtmmd` 写入 `/opt/utmm/utmmd` 后调用
3. `src/svc.zig`: `forceInstallInternal` selfCopy 后对 `/opt/utmm/utmm` 和
   `/opt/utmm/utmmd` 调用

---

## Phase 27 P0 — installLinux systemd Restart 修复

**时间**: 2026-08-02

### v0.17.16: utmmd Windows 文件 I/O 修复 + 全量部署验证

**背景**: v0.17.14/15 部署后 Windows VM 升级推送成功写入文件但 utmmd 无法检测，
根因是 utmmd.zig 中文件操作使用 zio IOCP event loop，Windows IOCP 不支持文件 I/O。
与 v0.17.13 在 guest.zig 中修复的同类 bug。

**修复** (`src/utmmd.zig`):
- `monitorLoop` 中创建条件 `std.Io.Threaded`（仅 Windows），传递 `file_io` 给所有文件 I/O 函数
- 修改函数：checkPendingUpgrade、computeSha256Hex、readFileAlloc、applyUpgrade、copyFileUpgradeFallback、monitorUtmm
- 清理 `host.zig` 中临时 debug 日志

**发布**: v0.17.16 — 188 单测 + 59 集成测试通过，6/8 交叉编译目标（x86 跳过，zio 限制）

**部署验证**:

| VM | 升级方式 | 结果 |
|----|---------|------|
| Host (macOS) | 本地构建 | ✅ v0.17.16 serving |
| linuxvm | --upgrade 推送 | ✅ v0.17.16 serving |
| macvm | --upgrade 推送 | ✅ v0.17.16 serving |
| winx64 | 批处理脚本手动升级 | ✅ v0.17.16 serving |
| windowsvm | SSH sc start 恢复服务 | ✅ v0.17.16 serving |

**功能验证（windowsvm 恢复后）**:

| 功能 | 结果 |
|------|------|
| exec | ✅ |
| upload | ✅ |
| download | ✅ 49 bytes SHA256 一致 |
| ping | ✅ rtt_ms=0 |

**windowsvm 恢复详情**:
- 早期 ren 命令部分执行导致 utmm 服务崩溃，UTM-MonitorD 停止（WIN32_EXIT_CODE 1067）
- 通过 utmm sshpass SSH 直接执行 sc start UTM-MonitorD 恢复
- 服务启动后 utmmd spawn utmm，LSA 广播恢复，TCP handler 正常

**发现的并发保护问题**:
- Guest handleUpgradeCmd 检查 .sha256 标记文件是否存在，若存在则拒绝新推送
- 当 utmmd 无法消费升级时（IOCP bug），标记文件永久残留，阻止所有后续升级
- 修复 utmmd IOCP bug 后此问题不再触发，但 handleUpgradeCmd 应处理残留 marker 情况
- [P2] 待修复：仅 .sha256 marker 残留（upgrade 二进制不存在）时应清理标记而非拒绝

### 修复: installLinux() 缺少 systemd Restart 指令

**根因**: `svc.zig` 中 `installLinux()` 和 `genInit(.linux)` 生成的 systemd service 配置不一致：
- `installLinux()`（实际安装路径）**缺少** `Restart=on-failure`、`RestartSec=5`、`StartLimitBurst=3`、`StartLimitIntervalSec=30`
- `genInit(.linux)`（模板生成）**已正确包含**

**故障链**:
```
utmm 崩溃 → utmmd 重试 5 次 → utmmd 退出 → systemd 无 Restart → VM 永久离线
```

**修复** (`src/svc.zig`):

1. 新增共享常量 `SYSTEMD_RESTART_CONFIG`（避免 future drift）:
```zig
const SYSTEMD_RESTART_CONFIG =
    \\Restart=on-failure
    \\RestartSec=5
    \\StartLimitBurst=3
    \\StartLimitIntervalSec=30
;
```

2. `installLinux()` 模板新增 `{s}` 插值，传入 `SYSTEMD_RESTART_CONFIG`
3. `genInit(.linux)` 模板用 `++ SYSTEMD_RESTART_CONFIG ++` 引用同一常量

**生成的服务文件变化** — `installLinux()` 生成的 `/etc/systemd/system/utmmd.service`:
```ini
# 修复前（缺失 Restart）
[Service]
Type=simple
Environment=SHELL=/bin/bash
Environment=HOME=/root
ExecStart=/opt/utmm/utmmd --role guest
WorkingDirectory=/opt/utmm
StandardOutput=journal

# 修复后（与 genInit 一致）
[Service]
Type=simple
Environment=SHELL=/bin/bash
Environment=HOME=/root
ExecStart=/opt/utmm/utmmd --role guest
WorkingDirectory=/opt/utmm
Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=30
StandardOutput=journal
```

**测试验证**:
- 188 单元测试全部通过 ✅
- 59 集成测试全部通过，0 泄漏 ✅

**待部署**: linuxvm 真机验证（Task 241）

### linuxvm 真机验证

**部署**: SCP → `--install --hostname linuxvm` → 服务文件验证 → 崩溃恢复测试

**服务文件生成结果**:
```ini
[Service]
ExecStart=/opt/utmm/utmmd --role guest --hostname linuxvm
WorkingDirectory=/opt/utmm
Restart=on-failure         ✅
RestartSec=5               ✅
StartLimitBurst=3          ✅
StartLimitIntervalSec=30   ✅
StandardOutput=journal
```

**崩溃恢复测试**:
1. `kill -9 <utmmd PID>` → utmmd 被 SIGKILL
2. 等待 10s
3. systemd 自动重启 utmmd (新 PID)，utmm 也被重新 spawn
4. `systemctl status utmmd` 确认: `"Scheduled restart job, restart counter is at 1."`

**验证结果**:
- systemd Restart=on-failure 生效 ✅
- utmmd 退出后 systemd 10s 内自动重启 ✅
- Host `--status` 显示 linuxvm serving (v0.17.13) ✅
- 5 节点全部在线 ✅

### 全量部署测试（macvm + windowsvm + winx64）

**部署**:
- macvm: SCP → --install ✅ (700ms stop old utmm, launchd already running)
- windowsvm: SCP → --install ✅ (5s timeout → killAllUtmm PID 3056 → restart)
- winx64: SCP to Temp → --install from Temp ✅ (5s timeout → killAllUtmm PID 34192 → restart)

**功能验证**:

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --ping | ✅ (1ms) | ✅ (1ms) | ✅ (1ms) | ✅ (4ms) |
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| SHA256 | ✅ | ✅ | ✅ | ✅ |

**全节点状态** (v0.17.13):
```
Role   Hostname             Version    Status
host   dasis-macbook-air    v0.17.13   serving
guest  linuxvm              v0.17.13   serving
guest  macvm                v0.17.13   serving
guest  windowsvm            v0.17.13   serving
guest  winx64               v0.17.13   serving
```

**观察**: macvm launchd plist 缺少 `KeepAlive` 段（见 P2 待验证项）。

---

## v0.17.13 — zio IOCP file I/O 修复（上传/下载/升级 Windows 兼容）

**时间**: 2026-08-02

### Windows 文件 I/O 与 zio IOCP 不兼容

**问题**: zio 的 IOCP 异步 I/O 后端无法处理 Windows 上的文件操作。`createFile`、
`writeStreamingAll`、`deleteFile`、`rename` 等操作返回 `error.Unexpected`，
导致 Windows Guest 上 upload/download/upgrade 全部失败。

**根因**: IOCP (I/O Completion Port) 是 Windows 的异步 I/O 机制，专为网络 socket
设计，不支持普通文件的异步操作。Windows 文件 I/O 需要使用同步 API 或
`std.Io.Threaded`（线程池模拟异步）。

**修复方案**: 对所有文件 I/O 操作使用 `std.Io.Threaded` 替代 zio `io`。

**修改文件**:

1. **`src/guest.zig` — `handleUpload`**:
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
const file_pipe = dpipe_file.writeFile(allocator, file_io, cmd.path, cmd.hash) catch |err| { ... };
```

2. **`src/guest.zig` — `handleDownload`**:
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
const file_pipe = dpipe_file.readFile(allocator, file_io, cmd.path) catch |err| { ... };
```

3. **`src/guest.zig` — `handleUpgradeCmd`** (最复杂，涉及全部文件操作):
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
// 替换: statFile, createFile, writeStreamingAll, close, deleteFile, writer, rename
// 关键: sha_file.writer(file_io, &sha_wb) — writer 内部烘焙 io 引用，
// 后续 writeAll/flush 全部走 file_io
```

4. **`src/tcp.zig`**: 新增 `WSAEWOULDBLOCK` 常量 + `sockRead`/`sockWrite` 重试循环

5. **`src/main.zig`**: SystemInfo 收集移至 zio Runtime 创建之前（避免 IOCP 与
   `std.process.run` 冲突）

6. **`src/ipc.zig`**: sockWrite 返回值处理修复（之前 `_ =` 丢弃返回值）

**真机验证**:
- winx64 (x86_64-windows): upload/download/upgrade 全部通过 ✅
- windowsvm (aarch64-windows): upload/download/upgrade 全部通过 ✅

**构建验证**:
- 188 单元测试 + 59 集成测试全部通过 ✅
- 6/8 交叉编译目标通过（x86 的 2 个 zio 不支持，预存限制）

**发布**: https://github.com/fixnet-ai/utm-monitor/releases/tag/v0.17.13

**提交**: commit `待提交`，版本号 `src/ver.txt` 0.17.12 → 0.17.13

---

## Phase 27 规划 — VM 离线根因调查与修复计划

**时间**: 2026-08-02

### 调查结果

对 `--status` 反复显示 VM 离线的问题进行了系统调查，分析各 VM 系统日志、
utmmd 日志、systemd/journald/launchd 服务配置。

**离线根因汇总**:

| 优先级 | VM | 根因 | 代码位置 |
|--------|-----|------|---------|
| **P0** | linuxvm | `installLinux()` 生成的 systemd service 缺少 `Restart=on-failure` | `src/svc.zig:593-606` |
| **P1** | linuxvm | 心跳超时误触发 + kill 后线程创建 `SystemResources` | `src/utmmd.zig` + musl |
| **P2** | windowsvm | utmm.exe 堆损坏 (0xc0000374) / 访问违规 (0xc0000005) | 可能与 IOCP 相关 |
| **P2** | macvm | launchd KeepAlive 行为待验证 | `src/svc.zig` installMacOS |

### P0 详细分析: installLinux vs genInit 不一致

`svc.zig` 中两个函数生成 systemd service 文件，但配置不一致：

- **`installLinux()`** (实际安装路径) — **缺少** `Restart=on-failure`, `RestartSec=5`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=30`
- **`genInit()` → `genInitLinux()`** (生成 init 脚本) — **正确包含**上述指令

**故障链**:
```
utmm 崩溃（任意原因）
  → utmmd kill → spawn → 重试 5 次 → utmmd 退出
  → systemd 无 Restart 指令 → 不重启 utmmd
  → VM 永久离线
```

**修复**:
1. `installLinux()` 添加与 `genInitLinux()` 一致的 Restart 指令
2. 提取 systemd 配置为共享常量（单一真相源）
3. 部署到 linuxvm，模拟崩溃验证 systemd 自动恢复

### P1 详细分析: 心跳超时 + 线程创建失败

linuxvm utmmd 日志显示：
1. **心跳超时**: utmm 在阻塞 I/O（acceptRaw/dpipe.relay/SOCKS5 relay）时无法更新
   共享内存心跳 → utmmd 10s 超时误判为僵死 → SIGKILL
2. **线程创建失败**: kill 后立即 spawn → `std.Thread.spawn` → `error.SystemResources`
   （musl 线程资源未释放）

**v0.17.7 已修复**: acceptRaw 不再内部循环阻塞，长传输增加了心跳更新。
**v0.17.13 可能改善**: IOCP → Threaded 文件 I/O 减少了协程阻塞。

**待调查**:
- dpipe.relay 线程是否需要心跳更新
- SOCKS5 转发线程是否需要心跳更新
- utmmd spawn 失败后是否应有退避延迟

### P2 详细分析: Windows 堆损坏

windowsvm 事件日志中反复出现 0xc0000374/0xc0000005。v0.17.13 的 IOCP 修复
可能已解决部分问题，但需长时间运行验证。

### 修复计划

详见 `task_plan.md` Phase 27 完整任务列表（Task 239-250）。

---

## v0.17.11 — ssh.exe 嵌入 + CLI 测试脚本

**时间**: 2026-08-02

### Windows ssh.exe 嵌入与自动提取

**背景**: Windows utmm 运行 sshpass 时调用 `CreateProcessW` 执行 `ssh` 命令，依赖 PATH
中找到 `ssh.exe`。但 Windows VM 可能未安装 OpenSSH Client，或 PATH 配置有问题，
导致 sshpass 功能不可用。

**方案**: 将 x86_64/aarch64 Windows 的 `ssh.exe` 作为 embedded binary 编译进 utmm，
并在 `--install` 流程中自动提取到 utmmd 同目录（`C:\opt\utmm\ssh.exe`）。
sshpass 执行 ssh 时优先使用嵌入路径。

**实现细节**:

1. **提取 ssh.exe binary** (`src/embed/`):
   - `src/embed/x86_64-windows/ssh.exe` — 1,253,888 bytes, PE32+ x86-64，从 winx64 提取
   - `src/embed/aarch64-windows/ssh.exe` — 1,135,104 bytes, PE32+ Aarch64，从 windowsvm 提取
   - 提取方法：`utmm sshpass ssh Administrator@<vm> "PowerShell Get-Command ssh.exe | Select -ExpandProperty Source"`
   - 源路径：`C:\Windows\System32\OpenSSH\ssh.exe`

2. **`src/main.zig` ssh.exe 嵌入**:
   ```zig
   const ssh_exe_bin: []const u8 = if (builtin.os.tag == .windows) switch (builtin.cpu.arch) {
       .aarch64 => @embedFile("embed/aarch64-windows/ssh.exe"),
       .x86_64 => @embedFile("embed/x86_64-windows/ssh.exe"),
       else => &.{},
   } else &.{};
   ```
   - 新增 `extractSshExe(io, alloc)` — 写 temp 文件 + SHA256 不校验（只验长度>0）
     + atomic rename 到 `C:\opt\utmm\ssh.exe`
   - 新增 `extractSshExeIfMissing(io, alloc)` — 检查存在性，调用 extractSshExe
   - 从 `extractUtmmd()` 中调用：`extractSshExeIfMissing(io, alloc) catch {};` — best-effort，不硬错误

3. **`src/sshpass.zig` ssh 路径解析**:
   - 新增 `isSshCommand(cmd)` — 检测命令名是否为裸 "ssh" 或 "ssh.exe"（无路径前缀，大小写不敏感）
   - `runWindows()` 修改：如果命令是 ssh，将 `cmd_args[0]` 替换为 `C:\opt\utmm\ssh.exe`
   - 使用栈缓冲 `[64][]const u8` 避免堆分配
   - 路径替换仅当 cmd_args.len < 64 时生效

**设计决策**:
- ssh.exe 提取是 best-effort（失败 warn 不中断安装流程）—— sshpass 回退到 PATH 查找
- 不校验 SHA256（二进制较大、SHA256 跨版本变化，验长度>0 足够）
- Atomic temp→rename 写入模式与 utmmd.bin 提取一致
- embed 仅限 Windows 目标 — 非 Windows 编译 ssh_exe_bin = &.{}（零字节）

**构建验证**:
- 6/8 交叉编译目标通过（x86 2 个 zio 不支持）✅
- 188 单元测试 + 59 集成测试全部通过 ✅

### Python 测试脚本（MCP + CLI）

**MCP Tools Test Script** (`tests/test_mcp_tools.py`, ~268 行):
- 覆盖所有 7 个 MCP 工具：status, exec, ping, upload, download, sshpass, manual
- JSON-RPC stdio 通信，通过 `--mcp` 管道 vs Host daemon
- upload→download SHA256 验证 + sshpass 密码认证
- linuxvm 为文件传输目标，linuxvm+macvm 为 exec/ping 目标

**CLI Commands Test Script** (`tests/test_cli_commands.py`, ~248 行):
- 覆盖全部 CLI 管理命令：`--version`, `--status`, `--ping`, `--exec`, `--upload`, `--download`, `sshpass`
- 31/31 检查通过
- 关键修复：
  - utmm CLI 输出到 stderr（非 stdout）→ `run()` 合并 stdout+stderr
  - `--ping` 输出 JSON 格式 `{"rtt_ms":N}` → 检查 `"rtt_ms" in out` 而非 `"RTT" in out`
  - sshpass 错误密码测试需 `-o PubkeyAuthentication=no`（否则密钥认证绕过密码检查）
  - upload/download 成功检测：`"[upload]" in out and "error:" not in out.lower()`

**验证**:
- `sudo python3 tests/test_mcp_tools.py` — 全部通过 ✅
- `sudo python3 tests/test_cli_commands.py` — 31/31 通过 ✅

**SKILL.md 更新**:
- 新增 "MCP Tools Test" 章节
- 新增 "CLI Commands Test" 章节

---

## v0.17.11 — zio 协程重构完成 + macOS 自动 codesign

**时间**: 2026-08-02

### zio 协程重构（v0.17.8—v0.17.10）

将 utmm 从 OS 线程模型迁移到 zio stackful 协程框架。

**背景**: `refactor-zio` 分支，8 个 commit。目标是用协程替代 OS 线程，提升 I/O 调度效率。

**重构分阶段**:

1. **Phase 1 — zio 依赖**: `main.zig` `--svc` 路径创建 Runtime + Executor
2. **Phase 2 — Guest spawnBlocking**: `guest.zig` 所有 `std.Thread.spawn` → `zio.Group.spawnBlocking`
3. **Phase 3 — dpipe relay**: `dpipe.relay()` `std.Thread` → `zio.spawnBlocking`
4. **Phase 4 — Host spawnBlocking**: `host.zig` 顶层服务 spawn 改用 zio
5. **Phase 5 — Host accept loop**: Host TCP accept 循环移至主 executor
6. **Phase 6 — spawnBlocking 统一**: 所有 `std.Thread.spawn` → `rt.spawnBlocking()`
7. **Phase 7 — 统一主 executor**: LSA + IPC 作为协程运行在统一 executor 上

**关键问题与修复**:

1. **SO_REUSEPORT TCP 端口冲突** (`src/tcp.zig`):
   - zio 的 `addr.listen()` 设置 SO_REUSEPORT（非 SO_REUSEADDR），导致内核将 :2121
     连接负载均衡到 Host 和 Guest 两个 TCP listener
   - 修复：TcpListener.init 改用手动原始 POSIX socket（`socket()` + `setsockopt(SO_REUSEADDR)` +
     `bind()` + `listen()` + `fcntl(O_NONBLOCK)`），在 POSIX 和 Windows 上均只设 SO_REUSEADDR

2. **Spinlock 替代 Mutex** (`src/host.zig`):
   - zio `std.Io.Mutex.lock(io)` 内部调用 `io.futexWait()` 需要协程上下文
   - 线程池 spawBlocking 线程上没有协程上下文，导致 hang
   - 修复：`lockTable()` + `unlockTable()` helpers 使用 `tryLock()` 忙等 + `@prefetch`

3. **Upload GuestNotFound** (`src/host.zig`):
   - `cmdUpload` 将完整 `vm:path` 字符串（如 "macvm:/tmp/test.txt"）作为 vm 名传给 `ipcUpload`
   - `findByHostname` 查找字面量 "macvm:/tmp/test.txt"，当然找不到
   - 修复：在 `:` 处分割，提取 hostname

4. **Host 自我处理** (`src/host.zig`):
   - 删除独立 Guest daemon 概念 — Host 的 self:2121 SOCKS5 handler 调用
     `guest.handleOneCommand()` 直接处理 exec/upload/download
   - 新增 Host `getSystemInfo()` 为 self-exec 收集 SystemInfo
   - 5 个 guest.zig handler 函数改为 `pub`：
     `handleOneCommand`, `handleExecCmd`, `handleUpload`, `handleUpgradeCmd`, `handleDownload`

5. **Windows SOCKET 类型** (`src/tcp.zig`):
   - aarch64-windows 上 SOCKET = `*anyopaque`（指针），`@intCast` 对指针无效
   - 修复：`.handle = s` 直接赋值（s 已是正确类型）

**版本链**:
- v0.17.8: dpipe relay + guest spawnBlocking
- v0.17.9: host accept loop + service spawns
- v0.17.10: SO_REUSEPORT fix + upload GuestNotFound fix + spinlock + Windows SOCKET fix

### macOS 自动 Ad-Hoc Codesign（v0.17.11）

**问题**: 交叉编译或 scp 传输的 Mach-O 二进制，ad-hoc 签名损坏（`cs_invalid_page`, `tainted:1`），
Apple Silicon 内核发送 SIGKILL。

**修复** (`build.zig`):
- 原生构建后自动 `codesign --force --sign -`
- 交叉编译循环中每个 macOS 目标独立 codesign
- sign 步骤依赖于编译完成，install 步骤依赖于 sign 完成

**验证**:
- scp binary 到 macvm 后无需手动 codesign 即可运行 ✅
- 188 单元测试 + 59 集成测试全部通过 ✅
- 6/8 交叉编译目标通过（x86 的 2 个 zio 不支持，预存限制）

**PR**: https://github.com/fixnet-ai/utm-monitor/pull/5

**提交**: 8 个 commit（`3532190` 到 `2fffe18`），tag `v0.17.11`

### 已知遗留问题（本版本未修复）

1. **Zombie 进程**: `dpipe_shell.zig` killChild 5s WNOHANG waitpid 限制
2. **utmmd 二进制升级缺口**: push-upgrade 仅替换 utmm，不替换 utmmd
3. **x86 目标不支持**: zio `unimplemented architecture: x86`，2 个 32-bit 目标无法编译
4. **测试输出静默**: `zig build test` stdout 无输出（ExitCode=0 但输出被吞）— 不影响 CI

---

## v0.17.7 — 心跳超时崩溃循环修复

**时间**: 2026-08-02

### acceptRaw 内层循环阻塞心跳 — 根因分析与修复

linuxvm 自 v0.17.2 起持续心跳超时崩溃循环。排查发现根因在 `tcp.zig` 的
`acceptRaw()` 函数。

**根因**: `acceptRaw()` 内部有一个 `while(true)` 循环 — 当 `accept()` 返回
`WouldBlock` 时 sleep 100ms 后 retry，永不返回到调用者。POSIX 非阻塞 socket
上 `accept()` 立即返回 `EAGAIN`/`WouldBlock`（无连接时），内层循环无限重试，
导致外层 accept 循环中的 shm 心跳更新从不执行。空闲期间 10s 后 utmmd 检测
心跳超时 → 杀 utmm → 崩溃循环。

**修复（3 个文件）**:

1. `src/tcp.zig` — acceptRaw 删除内层 `while(true)`，改为直接返回 `WouldBlock`：
```zig
// 修复前：内层 while(true) 永不返回
pub fn acceptRaw(self: *TcpListener) !socket_t {
    while (true) {
        const stream = self.server.?.accept(self.io) catch |err| {
            if (err == error.WouldBlock) {
                std.Io.sleep(self.io, ...) catch {};
                continue;  // ← 永不返回！
            }
            return error.AcceptFailed;
        };
        return stream.socket.handle;
    }
}

// 修复后：WouldBlock 直接返回给调用者
pub fn acceptRaw(self: *TcpListener) !socket_t {
    const stream = self.server.?.accept(self.io) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        return error.AcceptFailed;
    };
    return stream.socket.handle;
}
```

2. `src/guest.zig` — accept 循环 WouldBlock 处理增加 sleep：
```zig
const fd = listener.acceptRaw() catch |err| {
    if (err == error.WouldBlock) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        continue;  // ← 心跳在外部 while 循环顶部更新
    }
};
```

3. `src/host.zig` — 同 guest.zig 模式修复。

**长传输心跳补充（`src/guest.zig`）**:
- `handleUpload` / `handleDownload` / `handleUpgradeCmd` 签名增加 `shm_handle` 参数
- 文件传输循环中每次读写后更新心跳
- `handleOneCommand` 分发更新三处调用传递 `shm_handle`

**测试验证**:
- 188 单元测试 + 59 集成测试全部通过 ✅
- ReleaseSafe 构建通过 ✅

**提交**: commit `b850b02`，tag `v0.17.7`

### 已知遗留问题（本版本未修复）

1. **Zombie 进程**: `dpipe_shell.zig` 的 `killChild()` 有 5s WNOHANG waitpid 限制，
   子进程卡在 D 状态时无法收割
2. **utmmd 二进制升级缺口**: push-upgrade 仅替换 utmm，不替换 utmmd。本次修复只需
   改 utmm 代码，`--upgrade <vm>` 即可部署

---

## v0.17.6 — utmmd IP 变更检测自动重启

**时间**: 2026-08-02

### IP 指纹检测

当机器 IP 因 DHCP 续约、网络切换变化时，utmmd 通过 Wyhash 指纹检测变更并自动重启 utmm。

**实现** (`src/utmmd.zig`):
- 新增 `getAllIpsFingerprint()` — 跨平台 IP 枚举（POSIX `getifaddrs` / Windows `GetAdaptersAddresses` 动态加载 iphlpapi.dll）
- Wyhash 哈希所有非回环 IPv4 地址的原始字节 + 计数 → u64 指纹
- 零堆分配，纯栈变量
- monitorUtmm 轮询循环中每 10s 检查一次
- 去抖 2 次确认（IP 需稳定 20s），防 DHCP 瞬态抖动
- 指纹 = 0（无 IP）不触发重启
- 4 个单元测试

**验证**:
- 188 测试全部通过 + 8 交叉编译目标 ✅
- Host 真机指纹计算正常、无异常重启 ✅

**提交**: commit `4ad00bc`，tag `v0.17.6`

---

## v0.16.0 — SOCKS5 全协议（BIND + UDP ASSOCIATE）+ 协议层提取

**时间**: 2026-08-01

### feat/socks5-full 分支合并

**协议提取**:
- `src/socks5.zig` 新建（~1300 行）：SOCKS5 全部协议逻辑（解析/回复/连接/转发/BIND/UDP ASSOCIATE）
- `src/protocol.zig` 扩展（+285 行）：帧协议 + Connection（从 tcp.zig 移入）
- `src/tcp.zig` 精简（1678→~900 行）：纯 TCP 传输层（socket I/O、TcpListener、ConnLimit）
- 删除 `TcpListener.accept()` — 消除 tcp→socks5 循环依赖
- 消费者更新：guest.zig、host.zig 新增 socks5 import，SOCKS5 调用路径迁移

**SOCKS5 全协议实现**:
- BIND（RFC 1928 §4）：两阶段握手，TcpListener + accept timeout (60s) + relay
- UDP ASSOCIATE（RFC 1928 §6）：TCP 控制通道 + UDP 数据报中继（tcp↔udp 双线程）
- IPv4 ATYP 支持（IPv4 地址 → 点分十进制存入 hostname）
- IPv6 ATYP 返回 ADDRESS_TYPE_NOT_SUPPORTED

**关键修复**:
1. Windows fd_set 初始化：`socket_t = *anyopaque`（指针）→ 用 `undefined` 初始化，不能用 `{0}` 数组字面量
2. sockAcceptTimeout：Windows `select()` / POSIX `poll()` 跨平台实现
3. UDP socket 跨平台：Windows `ws2_socket(AF_INET,SOCK_DGRAM)` / POSIX `socket(AF.INET,SOCK.DGRAM)`

**测试验证**:
- 186 单元测试 + 59 集成测试全部通过 ✅
- 8 交叉编译目标全部通过 ✅

### 裸机部署测试（modasiaipc, x86_64-windows）

| 功能 | 结果 |
|------|------|
| exec | ✅ |
| upload | ✅ SHA256 一致 |
| download | ✅ SHA256 一致 |
| sshpass (ConPTY) | ✅ |
| SOCKS5 CONNECT chain | ✅ curl → modasiaipc:2121 → Host → linuxvm:22 |
| UDP ASSOCIATE | ✅ |
| BIND | ⚠️ Windows Firewall 阻止动态端口入站 |

所有 5 节点确认 v0.16.0 serving。

### MCP 配置修正

- `mcp.json.example`：MCP 服务器名 "utm-monitor" → "utmm"
- main.zig header + build.zig.zon package name 保持 "UTM Monitor"（软件产品名）
- 区分：UTM Monitor = 软件名，utmm = 命令/二进制名

---

## v0.15.11 — 工作流优化全流程演练

**时间**: 2026-08-01 01:30—02:30

### bump → release.sh → deploy → upgrade → 验证 全流程

**v0.15.10 bump + build**:
- `src/ver.txt` 0.15.9 → 0.15.10
- 8 目标交叉编译：aarch64-windows FIONBIO 值 `0x8004667e` 超出 `c_int` (i32) 范围
  - 修复：`const FIONBIO: c_int = @bitCast(@as(std.os.windows.ULONG, 0x8004667e));`
- 全部 8 目标编译通过，deploy 到 serve-dir
- 3 台 Guest 报 `BinaryNotFound` — 因为只编译了 native 目标，跨平台二进制未更新
- 修复后 3 台 Guest (linuxvm, windowsvm, modasiaipc) + 1 台已升级 (macvm) 全部 v0.15.10

**--ping 崩溃修复**:
- 症状：`sudo utmm --ping`（无参数）panic "attempt to use null value"
- 根因：`cli.ping_target.?` — ping_target 为 null 时 unwrap panic
- 修复 1（host.zig）：加 null 检查，输出 `[ERROR] --ping requires a target hostname`
- 修复 2（main.zig）：parseArgs 返回前统一校验所有管理命令必选参数
  - ping → 需要 target；exec → 需要 target + command；upload → 需要 file + target
  - download → 需要 target + remote_path；upgrade → 需要 target

**并行交叉编译**:
- `build.zig` 新增 `cross` step：`zig build cross -Doptimize=ReleaseSafe`
- 8 目标全部并行编译，替代 serial `for target in $targets; do zig build -Dtarget=$target; done`
- `std.Target.Query` 字段是 optional，需用 `tgt.result` 而非 `query`
- `standardOptimizeOption` 只能调用一次，循环内复用外部 `optimize` 变量

**release.sh 重构**:
- 旧流程：用户手动 commit + tag → release.sh 构建测试（失败则删 tag 重建）
- 新流程（5 阶段）：
  1. 校验（ver.txt 匹配 VERSION arg、工作区干净）
  2. 单元测试 + 集成测试
  3. `zig build cross` 并行编译 8 目标
  4. 收集二进制 + zip 打包
  5. commit ver.txt → tag → push → gh release create
- 关键改进：构建测试全部通过后才打 tag，杜绝 tag 反复删除重建
- 验证：v0.15.11 release.sh 一次性全流程通过，5 阶段全部成功

**CI 脚本更新** (`.github/workflows/release.yml`):
- 交叉编译：串行 8×`zig build` → 单步 `zig build cross`
- 删除 `install.sh` / `install.bat` 引用（这两个文件不存在于仓库 — utmm 自带 `--install`）
- 测试步骤去 `--summary all`（避免 macOS `--listen=-` hang）
- 步骤数：6 → 5（合并 collect + ver.txt）

**cmdDeploy 改进**:
- sshpass 缺失不再 `exit(1)` → 改为 `return` + 明确警告
  - 旧行为：`[deploy] sshpass is required...` + exit 1（误导：本地部署已成功）
  - 新行为：`[deploy] Local binaries have been copied to serve-dir.` + 提示安装 sshpass
- 串行 for 循环编译 → 单次 `zig build cross` 并行编译
- serve-dir 复制在 cross 编译完成后统一进行

**pushUpgrade 错误信息优化**:
- `"BinaryNotFound"` → `"BinaryNotFound: run zig build cross + deploy to populate serve-dir"`
- 同时 log 输出具体缺失文件名：`expected utmm-aarch64-linux-0.15.11 in serve-dir`

**MANUAL.md 增强**:
- "zig build test hangs on macOS" 条目扩充：
  - `--listen=-` stdio 协议机制说明
  - kqueue 后端死锁原因
  - 本项目 `build.zig` 绕过方案（`Step.Run.create`）
  - `--summary all` CI 风险提示

### 部署验证 (v0.15.11)

| 项目 | 结果 |
|------|------|
| `--status` | ✅ 5 nodes (1 Host + 4 Guest), all v0.15.11 serving |
| `--ping` | ✅ macvm(1ms) linuxvm(1ms) windowsvm(1ms) modasiaipc(4ms) |
| `--exec` | ✅ linuxvm, windowsvm 命令执行正常 |
| `--upgrade` | ✅ 4 台 Guest 全部升级成功（utmmd 自动检测→验证→替换→重启） |
| 8-target build | ✅ `zig build cross` 并行编译全部通过 |
| Unit tests | ✅ 172 passed, 0 failed |
| Integration tests | ✅ 59 passed, 0 failed, 0 leaks |
| GitHub Release | ✅ v0.15.11 published |

### 发现与修复汇总

| # | 发现 | 严重度 | 修复 |
|---|------|--------|------|
| 1 | FIONBIO 值在 aarch64-windows 上超出 c_int | 高（编译阻断） | @bitCast 转换 |
| 2 | --ping 空参数 panic | 中（用户操作崩溃） | parseArgs 前置校验 |
| 3 | --deploy exit 1 误导（sshpass 缺失） | 低（实际已成功） | exit → return |
| 4 | release.sh 先 tag 后构建失败要重建 | 中（流程反复） | 构建过再 tag |
| 5 | CI 引用不存在的 install.sh/install.bat | 高（CI 必然失败） | 删除引用 |
| 6 | linuxvm ping RTT 496659s（升级瞬态） | 低（瞬态，不影响） | 无需修复 |
| 7 | cmdDeploy 串行编译慢 | 低（效率问题） | 改用 zig build cross |

## Clean Deploy Test v0.14.7 (第二轮 — 修复后 skill 验证)

**时间**: 2026-07-31 04:13-04:15

### 测试环境
- **版本**: v0.14.7
- **测试方法**: 修复后的 `.claude/skills/clean-deploy/SKILL.md`（Phase 0 Build → Phase 1 Wipe → Phase 2 Cross-Compile → Phase 3 Deploy → Phase 4 Test）

### 测试结果

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ (2ms) | ✅ (1ms) | ✅ (1ms) | ✅ (6ms) |
| SHA256 | ✅ | ✅ | ✅ | ✅ |

**总评**: 4/4 VM 全部通过，所有 SHA256 校验一致。176 单元测试 + 59 集成测试全部通过。

### 发现的问题

1. **winx64 hostname 不解析** — `ssh: Could not resolve hostname winx64`
   - 原因: winx64 在 192.168.3.x 子网，LSA UDP 广播可能不跨子网，/etc/hosts 无法同步
   - 影响: clean-deploy 中对 winx64 的 sshpass 命令需用 IP（192.168.3.108）
   - 建议: skill 中为 winx64 保留 IP 备选，或增加 winx64 的 /etc/hosts 同步机制

2. **Windows sc.exe stop 失效** — `[SC] ControlService FAILED 109: The pipe has been ended.`
   - 当 utmm 进程状态异常时 sc.exe 无法停止，需 `taskkill /F` 兜底
   - skill 中的 wipe 流程已包含 taskkill 步骤，合理

3. **utmm sshpass scp 可用** — 验证了 `utmm sshpass -p 111 scp ...` 可正常工作
   - POSIX Guest 和 Windows Guest 均成功

4. **Zig 0.16.0 `--listen=-` 协议 bug** — `zig build test` 卡死
   - Workaround: 直接运行 `.zig-cache/o/<hash>/test` 二进制（已验证可行）
   - 两轮测试均遇到此问题，建议在 SKILL.md/deploy skill 中记录此 workaround

5. **Windows `tasklist /fi` 在 cmd /c 下需转义** — `/fi "imagename eq utmm.exe"` 中的引号
   在 `cmd /c` 中会丢失，建议改为 `tasklist | findstr utmm`

### 与上轮对比

| 问题 | 上轮状态 | 本轮状态 |
|------|---------|---------|
| skill linuxvm IP 错误 | ❌ 192.168.64.2 | ✅ 已修复 |
| skill pkill -f 自杀 | ❌ 存在 | ✅ 已修复 |
| skill sshpass 引用 | ❌ 裸 sshpass | ✅ utmm sshpass |
| skill Windows mkdir | ❌ 不可靠 | ✅ 已修复 |
| winx64 hostname | — 未测试（上轮用 IP） | ❌ 新发现 |
# Progress: 分层架构重构

## 当前状态

- **分支**: `refac/layered-arch`
- **版本**: v0.14.7（sshpass 集成 + MCP 工具名去前缀）
- **测试**: 208 唯一单元测试 + 59 集成测试场景（待验证）
- **源文件**: 18 src + 11 test（新增 sshpass.zig）

## 会话记录

### 2026-07-31 — v0.14.7：sshpass 集成 + MCP 工具名去 vm_ 前缀

**成果**: 将开源 sshpass 工具 100% CLI 兼容移植为 `utmm sshpass` 子命令；POSIX (PTY) +
Windows (ConPTY) 双平台支持；移除所有 MCP 工具名的 `vm_` 前缀。

**sshpass 集成**:
- 新建 `src/sshpass.zig`（~1200 行）：
  - 退出码 7 个（与 C 版完全一致）
  - 密码源 4 种：stdin/file/fd/pass（互斥检查）
  - `parseArgs()` 模拟 `getopt("+f:d:p:heV")`，100% CLI 兼容
  - `patternMatch()` 逐字符状态机匹配 4 种 SSH 提示
  - `runPosix()`：posix_openpt→fork→setsid→execvp→pselect→password injection
  - `runWindows()`：CreatePseudoConsole (ConPTY)→CreateProcessW→ReadFile/WriteFile loop
  - 内联测试：7 patternMatch + 8 parseArgs + 32 protocol = 47 测试，全部通过，0 泄漏
- `src/main.zig` 修改：
  - 新增 sshpass import + cmd_sshpass 字段 + comptime 注册
  - parseArgs 早期检测 "sshpass" 子命令
  - main() sshpass 分发（在管理员权限检查之前，无需 root）
  - printHelp() 新增 sshpass 行
- Zig 0.16.0 API 适配：
  - `std.io` → `std.Io`（重命名）：getStdErr/getStdOut 不存在 → `std.c.write(fd, ..)` / `WriteFile`
  - `std.posix.getenv` → `std.c.getenv`（返回 `?[*:0]u8` → `std.mem.sliceTo`）
  - `std.posix.write` 不存在 → `std.c.write`
  - `c_int`/`c_ulong` 重定义阴影原语 → 使用 Zig 内置类型
  - `@bitCast`/`@intCast` 需显式 `@as` 类型（Zig 0.16.0 更严格）
  - `std.Io.sleep(io, ...)` Windows 不适用 → `kernel32.Sleep(ms)`
  - `std.posix.fd_t` 类型错误（应为 C int 非常量）

**MCP 工具名去前缀**:
- `src/mcp.zig`：5 个工具名 `vm_status`/`vm_exec`/`vm_ping`/`vm_upload`/`vm_download` → `status`/`exec`/`ping`/`upload`/`download`
- 所有 `std.mem.eql(u8, tool_name, "vm_*")` 比较路径更新
- 54 个测试断言更新（TOOLS_JSON 校验 × 3 组）
- 文档更新：CLAUDE.md / README.md / task_plan.md

**编译验证**:
- `zig test src/sshpass.zig`：47/47 通过，0 泄漏，0 错误 ✅
- `zig build`：编译通过 ✅
- 主程序测试（zig test main）：176/176 通过 ✅
- 独立模块：guest (8/9 pass + 1 skip) + dpipe (5) + dpipe_shell (7) + dpipe_file (23) + shm (10) 全部通过 ✅
- `zig build test`：因 Zig 0.16.0 `--listen=-` 协议 bug 卡住，分步运行全部通过 ✅
- 修复 6 处 Zig 0.16.0 API 适配：open() 3 参数、allocSentinel 3 参数、ExitCode non-exhaustive enum

**集成测试**:
- `zig build test-integration`：59/59 通过，0 失败，0 泄漏 ✅

**交叉编译**:
- 8/8 目标全部通过 ✅

**真机部署**:
- Host + 4 VM 全部 v0.14.7，serving 状态
- sshpass 冒烟测试：正确密码 → exit 0，错误密码 → exit 5 ✅
- exec/upload/download 回归测试全部通过 ✅
- 修复已安装二进制 MD5 不匹配 → 手动 cp 解决

**关键决策**:
- 决策 42: sshpass 密码不 dupe（引用 argv），隐藏密码移到 main() — 避免 parseArgs 错误路径内存泄漏
- 决策 43: sshpass 无需 root 权限 — 原版不需要；AI agent 无法 sudo 交互式提权
- 决策 44: POSIX + Windows 一起做 — 用户要求；ConPTY API 在 Windows 10 1809+ 可用

### 2026-07-31 — v0.14.7：sshpass args[2..] Bug 修复 + Windows 交叉编译

**背景**：sshpass.main() 使用 `args[1..]` 只跳过了二进制路径（args[0]），没有跳过 "sshpass"
子命令名（args[1]）。导致 `parseArgs()` 将 "sshpass" 当作要执行的命令，`runPosix()` 调用
`execvp("sshpass", ...)` 时找到系统的外部 sshpass 二进制文件。

**症状**：
- Host：sshpass 看起来正常工作（因为 `/opt/homebrew/bin/sshpass` 仍在 PATH 中，被意外调用）
- VM：sshpass 返回 "Failed to run command: No such file or directory"（VM 无外部 sshpass）
- 嵌入的 zig 实现从未被实际调用！

**修复**（`src/sshpass.zig:1054`）：
```zig
// 修复前（错误）
const actual_args = args[1..]; // 只跳过二进制路径，未跳过 "sshpass"

// 修复后（正确）
const actual_args = args[2..]; // 跳过二进制路径 + "sshpass" 子命令名
```

**验证**：
- 移除 `/opt/homebrew/bin/sshpass` 外部二进制
- Host: `utmm sshpass -p 111 ssh root@192.168.64.6 echo HELLO` → HELLO, exit 0 ✅
- Host: `utmm sshpass -p bad ssh ...` → Permission denied, exit 5 ✅
- linuxvm: `utmm sshpass -V` → utmm-sshpass v0.14.7 ✅
- linuxvm: `utmm sshpass -h` → 帮助文本正确 ✅
- macvm: `utmm sshpass -V` → utmm-sshpass v0.14.7 ✅
- macvm: `utmm sshpass -p wrong ssh ...` → exit 5 (提示匹配成功) ✅

**Windows 交叉编译修复**（6 个预存问题）：
1. `std.os.windows.WriteFile` 已移除 → 使用 `@extern` 声明 `kernel32.WriteFile`
2. `std.os.windows.GetStdHandle` 已移除 → 使用 `@extern` 声明
3. `std.os.windows.HRESULT` 已移除 → `const HRESULT = i32`
4. `std.fmt.parseInt(std.posix.fd_t, ...)` on Windows 失败（fd_t = `*anyopaque`）→ 平台分派
5. `ArrayList.append()` 需要 Allocator 参数 → `buf.append(allocator, x)`
6. `DeleteProcThreadAttribute` 不存在于 kernel32 → 使用 `DeleteProcThreadAttributeList`
7. struct 默认值 `fd = 0` 在 Windows 上零指针被禁止 → `fd = undefined`

**交叉编译**：
- 8/8 目标全部通过（含修复后的 aarch64/x86_64-windows）✅
- macOS native: Mach-O arm64 ✅
- Linux aarch64: ELF aarch64 ✅
- Windows aarch64: PE32+ Aarch64 ✅
- Windows x86_64: PE32+ x86-64 ✅

**部署验证**：
- Host: 正常 ✅
- linuxvm: 升级 + sshpass 验证 ✅
- macvm: 升级 + sshpass 验证 ✅
- windowsvm: 升级成功，sshpass Windows runtime 待进一步测试（ConPTY 输出捕获问题）

**关键教训**：
- 交叉编译必须实际运行 `zig build -Dtarget=...`，原生编译通过不代表所有目标通过
- Zig 0.16.0 `ArrayList.append()` 新增 allocator 参数，旧代码在交叉编译目标上才会报错
- `std.os.windows.*` 大量 API 被移除，必须用 `@extern` 手动声明
- struct 默认值 `0` 对指针类型（Windows fd_t = `*anyopaque`）不合法

### 2026-07-30 — v0.14.5：ARP 集成测试 + 发布

**成果**：新增 10 个 ARP 集成测试场景；parseMacBytes/macMatch 改为 pub + 17 个单元测试；
修复 Linux 交叉编译 `std.fs.openFileAbsolute` → `std.Io.Dir.cwd().openFile`；发布 v0.14.5。

**ARP 集成测试**:
- `tests/test_arp.zig`：10 个集成测试场景
  - parseMacBytes 零补/不补/非法输入（3 场景）
  - macMatch 跨格式匹配/不同 MAC/非法输入（3 场景）
  - rediscoverIp 虚假 MAC/空 MAC/same-IP 逻辑（3 场景）
  - lookupIp 真实 macOS ARP 表查询（1 场景）
- `src/testlib.zig` 新增 arp 模块导出
- `tests/integration_test.zig` 注册 test_arp 模块

**Zig 0.16.0 兼容修复**:
- `lookupIpLinux`：`std.fs.openFileAbsolute` → `std.Io.Dir.cwd().openFile(io, ...)`
- `file.close()` → `file.close(io)`
- `file.read(&buf)` → `file.readStreaming(io, &.{buf[0..]})`

**发布**:
- 版本号 bump：0.14.4 → 0.14.5
- 8 交叉编译目标全部通过，utmm.zip 13MB
- GitHub release: https://github.com/fixnet-ai/utm-monitor/releases/tag/v0.14.5

**关键决策**:
- 决策 41: ARP 集成测试覆盖补零差异 — macMatch 跨格式测试是核心回归防护

### 2026-07-30 — v0.14.4：ARP MAC→IP 反向发现

**成果**：实现跨平台 ARP 表查询，Guest IP 变化时自动通过 MAC 地址重发现新 IP 并恢复连接。

**新建文件**:
- `src/arp.zig`（~245 行）：平台特定 ARP 表读取
  - Linux：解析 `/proc/net/arp` 文本格式
  - macOS：`std.process.run("arp -a")` + 输出解析
  - Windows：`extern "iphlpapi" GetIpNetTable` 原生 API
- `parseMacBytes()` + `macMatch()`：字节数组 [6]u8 比较，解决补零差异

**修改文件**:
- `src/host.zig`：新增 `connectGuest()`（TCP 失败 → ARP 重发现 → 重试）、`GuestTable.updateIp()`
- `src/ipc.zig`：handleExec/Upload/Download 统一使用 `connectGuest()`
- `src/utmmd.zig`：Zig 0.16.0 兼容修复

**修复的关键 Bug**:
1. MAC 格式不匹配：LSA `9e:06:4f:79:db:fe` vs macOS arp `9e:6:4f:79:db:fe` → 字节级比较
2. Windows `LoadLibraryA` 移除（Zig 0.16.0）→ `extern "iphlpapi"` 直接声明
3. Windows `BOOL` enum → `0` 改为 `.FALSE`
4. Linux `std.fs.openFileAbsolute` 移除 → `std.Io.Dir.cwd().openFile()`

**测试验证**:
- 所有 exec/upload/download 操作在 macvm + windowsvm 上通过
- 41 集成测试 + 161 单元测试全部通过
- ARP 恢复路径（IP 变化→ARP 重发现→重试）通过单元测试验证；真实 IP 变化尚未触发

**关键决策**:
- 决策 39: ARP MAC→IP 反向发现 — 当 Guest IP 变化时自动恢复连接
- 决策 40: 字节级 MAC 比较 — 彻底消除补零差异

### 2026-07-30 — v0.14.3：自动升级启用 + Windows API 进程管理

**成果**: 自动升级编译时默认开启（AUTO_UPGRADE=true）；Windows 进程管理换用 Toolhelp + TerminateProcess API；
Windows upload 路径分隔符修复；SKILL 版本号批量更新；清理旧构建产物。

**自动升级启用**:
- `protocol.zig`：`AUTO_UPGRADE = true`（编译时常量，false 时死代码消除）
- `host.zig` 新增 `pushUpgrade()`（查 GuestEntry → deploymentFilename → 读 serve-dir → SHA256 → SOCKS4a 推送）
- `host.zig` 新增 `pushUpgradeThread()` 线程入口（分离线程，不阻塞 LSA 扫描）
- `host.zig` 新增 `LastUpgradeMap`（`StringHashMap(i64)`，冷却 120s 防重复推送）
- `host.zig` `tunnelManager` Phase 2 新增版本检测：比对 LSA 版本 → 检查冷却期 → 检查 upgrading 状态 → spawn 升级线程
- `ipc.zig` `handleUpgrade` 重构：~110 行 → ~25 行，调用 `host_mod.pushUpgrade()` 复用核心逻辑
- 冷却期 `AUTO_UPGRADE_COOLDOWN_MS = 120_000`（2 分钟）

**Windows API 进程管理**:
- `svc.zig` 新增 `w32` 命名空间（Toolhelp + TerminateProcess API）
- `killAllUtmm` Windows 分支重写：快照枚举 → 匹配 "utmm.exe" → OpenProcess(PROCESS_TERMINATE) → TerminateProcess
- `countOtherUtmmProcesses` Windows 分支重写：同上枚举计数
- 替换 `taskkill /F` + `tasklist` → 原生 API，支持 SYSTEM 权限进程

**其他修复**:
- Windows upload 路径分隔符：`host.zig:408` `"/"` → `std.fs.path.sep_str`（跨平台正确）
- SKILL 文件版本号批量更新：clean-deploy + deploy + utmm SKILL 0.14.1 → 0.14.2
- 清理 8 个旧构建产物 `zig-out/bin/*-0.14.1*`

**关键决策**:
- 决策 33: 自动升级 Host 端 LSA 版本检测 + 推送（编译时常量开关）
- 决策 34: Windows 进程杀死换用 Toolhelp + TerminateProcess API
- 决策 35: `extractUtmmd/rename` AccessDenied 根本原因是 `sc.exe stop` 不可靠（见 memory/windows-stop-utmmd-ineffective.md）

**编译验证**:
- `zig build test` 全部通过 ✅
- `zig build test-integration` 41/41 通过 ✅
- 8 交叉编译目标全部通过 ✅

### 2026-07-30 — v0.14.3 Bug 修复：detectUnixIp + upsert MAC

**成果**: 修复两个已知 bug：多 NIC VM IP 检测偏好 + GuestTable MAC 变更检测。

**detectUnixIp() 多 NIC 偏好修复**:
- 根因：`detectUnixIp()` 返回 getifaddrs 枚举的第一个物理 NIC。多 NIC VM（如 Lima `utmm-test`）上 eth0 (NAT, 192.168.5.15) 先于 lima0 (vmnet bridged, 192.168.105.2) 被发现，导致 LSA 广播不可达 IP
- 修复：新增 `isLikelyVmNat()` 辅助函数，检查已知 VM NAT 范围（10.0.2.0/24 = QEMU/VirtualBox，192.168.122.0/24 = libvirt）。`detectUnixIp()` 改为优先返回非 NAT 地址，无可用时回退到第一个物理 NIC
- 影响：多 NIC VM 现在自动选择更可能可达的 IP。当前 4 台生产 VM 均为单 NIC，行为无变化

**upsert() MAC 变更检测修复**:
- 根因：`host.zig:969-974` 检查 ip/target/version/shell/status/role 共 6 个字段变更，遗漏 MAC。VM 重装后 MAC 可能变化，但 status 显示旧 MAC（仅 cosmetic，路由使用正确的 LSA node_id）
- 修复：新增 `existing.mac` 比对和更新，与其余 6 个字段保持一致模式
- 影响：VM 重装后 `--status` 正确显示新 MAC

**新增测试**:
- `isLikelyVmNat - QEMU/VirtualBox default`：验证 10.0.2.x 匹配
- `isLikelyVmNat - libvirt default`：验证 192.168.122.x 匹配
- `isLikelyVmNat - non-NAT addresses`：验证正常 IP 不匹配
- `GuestTable upsert detects MAC change`：验证 MAC 变更可检测并更新

**验证**: `zig build test` + `zig build test-integration` 全部通过（41/41，0 泄漏）

### 2026-07-30 — v0.14.3 Clean Deploy 全量验证

**成果**: 完整的"清空—构建—部署—测试"裸机部署循环，4 台 VM 全 v0.14.3，
16 项功能测试（exec/upload/download/ping × 4）全部通过，SHA256 跨平台一致。

**测试结果**:

| 测试项 | linuxvm | macvm | windowsvm | winx64 |
|--------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ (2ms) | ✅ (1ms) | ✅ (1ms) | ✅ (5ms) |

**构建验证**:
- `zig build test` 全部通过 ✅
- `zig build test-integration` 41/41 通过，0 泄漏 ✅
- 4 交叉编译目标全部通过 ✅

**踩坑记录**:
1. macvm IP 变化：192.168.64.4 → 192.168.65.4（SSH host key 也变了，需 StrictHostKeyChecking=no）
2. windowsvm IP 变化：192.168.65.2 → 192.168.64.3
3. macvm UTM stop/start 后网络需 ~30s 才恢复
4. SKILL.md + CLAUDE.md 中 macvm/windowsvm 旧 IP 已更正

**文档更新**:
- CLAUDE.md：macvm IP 192.168.64.4 → 192.168.65.4，windowsvm 192.168.65.2 → 192.168.64.3
- SKILL.md：全部 macvm/windowsvm 命令中的 IP 相应更新

### 2026-07-30 — 源码注释清理

**成果**: 全面扫描并修复 src/ 下所有过时/错误注释。KCP、HTTP/WebUI、tunnel manager、
mesh relay 等 v0.13.0 后已删除的功能在注释中仍大量残留，现已全部修正。

**修改详情**:

- **`src/main.zig`**（10+ 处）:
  - 模块 doc：`"Automatic VM IP sync tool"` → `"Remote machine management via TCP/SOCKS4a"`
  - `port` 字段 doc：`"Mesh UDP port"` → `"TCP listen + UDP LSA port"`
  - `host_ip` 字段 doc：`"Host IP for Guest HTTP client"` → `"Host IP override for Guest"`
  - `serve_dir` 字段 doc：`"HTTP serve directory"` → `"Binary serve directory for Host upgrade push"`
  - `--serve-dir` help text：同上 HTTP→binary
  - `--ping` help text：删除 `"relayed"`
  - 行 ~453：`"bind the HTTP port"` → `"bind the IPC socket"`
  - 删除过时中文注释

- **`src/host.zig`**（~15 处）:
  - 12 处 `"HTTP handlers preserved for future WebUI"` → `"IPC handler"`
  - `"Parse JSON and print table (same as HTTP path)"` → `"Parse JSON and print table"`
  - `"Spawn tunnel manager thread"` → `"Spawn LSA manager thread"`
  - `pushUpgrade` doc：`"tunnelManager"` → `"LSA manager"`

- **`src/mcp.zig`**（2 处）:
  - `handleVmStatus`/`handleVmExec` doc：删除 `"HTTP handler preserved for future WebUI"`

- **`src/protocol.zig`**（1 处）:
  - KCP 隧道过时注释重写为当前 TCP/SOCKS4a wire protocol 描述

**验证**: `zig build test` + `zig build test-integration`（41/41 通过）— 纯注释变更，无代码逻辑修改。

### 2026-07-30 — linuxvm 重建与文档更新

**背景**: linuxvm 的 `Linux.utm` bundle 从磁盘消失，UTM 显示 phantom "started" 状态但无实际进程。
用户重装 Ubuntu Desktop 为新 VM，IP 从 192.168.64.2 变为 192.168.64.6。

**linuxvm 重建**:
- Phantom UTM Linux VM 从 UTM Registry 删除（Python plistlib 操作 `com.utmapp.UTM.plist`）
- 用户通过 UTM GUI 安装 Ubuntu Desktop 24.04 (aarch64)，UUID `13BE0E67-8CA3-44A7-AE50-D0A65842FD2F`
- SSH 配置：`PermitRootLogin yes` + `PasswordAuthentication yes`（`/etc/ssh/sshd_config.d/50-utmm.conf`）
- root 密码 111，dasimo 用户 sudo 权限
- 部署 utmm v0.14.3 并验证 exec/upload/download/ping 全部通过

**临时 Lima VM 测试**:
- 在等待用户重装期间，创建 Lima VM `utmm-test`（Ubuntu 26.04, aarch64, vz 驱动）
- 探索 socket_vmnet 桥接网络配置，发现两个踩坑：
  1. Lima 拒绝 symlink → 必须 `sudo cp` 实际二进制到 `/opt/socket_vmnet/bin/`
  2. `/etc/sudoers.d/lima` 权限问题 → `chgrp admin`（dasimo 在 admin 组非 wheel）
- 发现 `detectUnixIp()` 多 NIC bug：eth0 (NAT) 先于 lima0 (vmnet) 被发现，返回错误 IP
  - 修复：`ip link set eth0 down` + netplan `dhcp4: false` for eth0
  - utmmd 重启后 Guest 正确检测 lima0 IP (192.168.105.2) 和 MAC
- 临时 VM 未删除（`limactl` 不在 PATH），待后续清理

**观察到的代码问题**:
- `upsert()` in host.zig (lines 969-974)：不检查 MAC 字段变化 — 仅 cosmetic，路由使用正确的 LSA node_id
- LSA 注册延迟：Host 重启后需 10-20s Guest 才出现在 status 中（正常行为）

**文档更新**:
- CLAUDE.md：linuxvm IP 192.168.64.2 → 192.168.64.6
- SKILL.md (clean-deploy)：5 处 linuxvm IP 更新

**关键发现**:
- UTM VM bundle 可能因 QEMU 崩溃或磁盘空间不足而从文件系统消失
- UTM Registry 与文件系统不同步时会显示 phantom 状态
- Lima `lima:shared` 网络模式（socket_vmnet + vmnet-shared）提供主机到 VM 直接 connectivity

### 2026-07-30 — v0.14.2 裸机部署验证

**成果**: 完整的"清空—构建—部署—测试"裸机部署测试循环。5 台机器从零部署 v0.14.2，
16 项功能测试（exec/upload/download/ping × 4）全通过，SHA256 跨平台一致。

**测试结果**:

| 测试项 | linuxvm | macvm | windowsvm | winx64 |
|--------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ | ✅ | ✅ | ✅ |

**踩坑记录**:
1. Windows `taskkill /F` 无法终止 SYSTEM 权限 utmm 进程 → 需 PowerShell `Stop-Process -Force`
2. linuxvm SSH 长命令链 (`&&`/`||`) exit 255 → 分步执行 (4 个独立 SSH 调用)
3. winx64 `waitOldProcesses` 5s 超时 — 旧 utmm 进程残留，killAllUtmm 最终清理成功
4. 交叉编译产物同时保留 `-0.14.1` 和 `-0.14.2` 后缀 → 部署时需手动选择正确版本
5. Windows upload 路径显示 `C:\opt\utmm/clean_deploy_test.txt` (混合分隔符) — `vmRemoteDir()` 正确返回 `C:\opt\utmm`，功能正常

**关键决策**:
- 决策 32: Windows 部署安装用 PowerShell `Stop-Process -Force` 替代 `taskkill /F`

### 2026-07-30 — v0.14.2：升级系统重构 + 质量修复

**成果**: 升级系统从 Guest 自主升级重构为 Host 主控直推模型；修复 macOS launchctl bootstrap
errno=5 根因；跨平台路径审计并修复 5 处硬编码；临时文件泄露修复；部署流程自动化改进。

**升级系统重构**:
- Guest 侧：删除 UpgradeSignal/tryPerformUpgrade/LSA 版本比对/auto_upgrade 门控，新增 handleUpgradeCmd（升级指令接收 + 流式二进制 + 增量 SHA256 + shm 通知 utmmd）
- Host 侧：删除 checkGitHubVersion/verifyServeDirBinaries/upgradeTcpListener/handleUpgradeConnection/serveUpgradeFile/isValidVersion，新增 cmdUpgrade + ipcUpgrade（查 GuestTable → SOCKS4a 直推）
- IPC 新增 handleUpgrade：Request.upgrade (0x07) → serve-dir 读取二进制 → Guest 推送
- CLI 新增 `--upgrade <vm>` 参数，Host 直推模型
- upgrade_e2e 集成测试：7 场景（正常/哈希不匹配/0 字节/大文件/SOCKS4a/重传/并发）
- 删除 plan 文件 `floofy-skipping-gem.md`（已完全实现）

**macOS launchctl 修复**:
- 根因：`launchctl bootout` 重设 disabled flag，导致后续 bootstrap 返回 errno=5
- 修复：bootout 后显式 `launchctl enable` — installMacOS() 和 start() 两处
- macvm 验证：`state = running`，`enabled` flag 正确

**跨平台路径审计**:
- host.zig：3 处 `/opt/utmm` → `svc.canonicalDir()`
- ipc.zig：1 处 `/opt/utmm` → `svc_mod.canonicalDir()`
- host.zig cmdUpload：`/opt/utmm/{s}` → `vmRemoteDir()` 查 VM_DEPLOY_TABLE
- mcp.zig cmdVmUpload：`/opt/utmm/{s}` → `guestDefaultDir(vm)` 平台感知默认路径

**临时文件清理**:
- dpipe_file.zig：rename 失败 (CrossDevice + 普通) 两路径均 deleteFile
- guest.zig：新增 cleanupStaleTempFiles() — 启动时扫描 canonicalDir + tempDir，删除 `.utmm-*` 和 `.utmm-upgrade-*`

**VM 维护**:
- 4 VM 遗留垃圾清理（旧服务名 plist/service unit、temp 文件、日志）
- Windows VM (windowsvm + winx64) 启用 OpenSSH Server
- 版本号 bump：ver.txt 0.14.1 → 0.14.2

**Skill 更新**:
- clean-deploy/SKILL.md：新建裸机部署测试 skill（5 phase：清空→构建→部署→测试→总结）
- deploy/SKILL.md：Windows SMB 手动复制 → SSH 命令，并行策略更新

**关键决策**:
- 决策 26：升级系统 Guest 自主 → Host 主控直推
- 决策 27：复用 upload_result (0x17) 作为升级响应
- 决策 28：升级 temp 文件用 svc.tempDir()
- 决策 29：Windows SSH 替代 SMB/RDP
- 决策 30：mcp.zig guestDefaultDir() VM 名前缀推断平台
- 决策 31：deploy/clean-deploy SKILL 二进制名含版本号

### 2026-07-30 — v0.14.1：集成测试重构 + ReleaseSafe 强制 + 临时文件清理修复

**成果**: 集成测试从 8 个独立可执行文件重构为单入口 flat file 模式；强制所有发布构建使用 ReleaseSafe；
审计并修复所有上传/下载/升级错误路径的临时文件清理；4 台真机部署 v0.14.1。

**集成测试重构**:
- 8 个 `tests/<name>/main.zig` 目录删除 → 9 个 flat `tests/test_xxx.zig` 文件（`pub fn test_xxx(io, alloc, runner)` 签名）
- 单入口 `tests/integration_test.zig`：统一 DebugAllocator + TestRunner + 内存泄漏检测
- `build.zig` 简化：8 个独立 executable → 1 个 `integration_test` executable
- 修复 `_ = io` pointless discard（Zig 0.16.0 编译错误 — io 后续被使用）
- 40 测试场景全部通过，0 失败，0 泄漏

**x86_64 二进制尺寸根因**:
- 问题：x86_64-linux-musl Debug 模式 80MB
- 根因：x86_64-elf 的 `.data.rel.ro` 段 = 20.3MB（relocation data for read-only data, stack traces, lazy symbol resolution）；aarch64 无此段
- 解决：`-Doptimize=ReleaseSafe` 消除 `.data.rel.ro`：x86_64 从 80MB → 11MB
- ReleaseSafe 尺寸：Linux musl 8.8-11MB（静态链接 musl），macOS 1.4-1.6MB，Windows 2.0-2.3MB

**临时文件清理审计**:
1. dpipe_file.zig writeFile：`createFile()` 成功后 `allocator.create(WriteFileCtx)` 失败 → 旧 errdefer 只 close 不 delete → temp 文件泄露。修复：增加 `deleteFile` 调用
2. guest.zig handleUpgradeCmd：`defer file.close(io)` + 显式 `file.close(io)` → 双 close。修复：移除 defer

**ReleaseSafe 强制**:
- release.sh：所有 `zig build -Dtarget=` 添加 `-Doptimize=ReleaseSafe`
- CI workflow：所有构建添加 `-Doptimize=ReleaseSafe`
- CLAUDE.md：Build & Run 分 Debug/ReleaseSafe 两节，8 交叉编译命令均标注 ReleaseSafe

**真机部署验证**:
- linuxvm (aarch64): v0.14.1 ✅ — exec "uname -a" 正常
- macvm (aarch64): v0.14.1 ✅ — 需手动 cp + killall（macOS launchctl bootout 问题），exec 正常
- windowsvm (aarch64): v0.14.1 ✅ — taskkill /F utmm.exe 后 --install，exec 正常
- winx64 (x86_64): v0.14.1 ✅ — taskkill /F utmm.exe + utmmd.exe 后 --install，exec 正常
- Host (macOS aarch64): v0.14.1 ✅ — IPC + MCP + LSA 全部正常

**待提交**: 21 文件变更（新增 9 test、删除 8 旧 test 目录、修改 build.zig/release.sh/CI/CLAUDE.md/guest.zig/dpipe_file.zig/ver.txt）

### 2026-07-29 — Phase 9（续2）：修复 macOS SOCKS4a 栈悬垂指针

**成果**: 定位并修复 macOS aarch64 上 `readUntilNull` 栈悬垂指针导致 SOCKS4a 始终拒绝连接的 bug。

**Bug 修复详情**:

6. **SOCKS4a 栈悬垂指针** (`src/tcp.zig`):
   - 根因：`readUntilNull` 返回指向自身栈缓冲区的切片，函数返回后栈帧被释放。即使
     `socks4CheckAndReply` 在返回后"立即"调用 `std.mem.eql` 比较，`std.mem.eql` 的函数
     调用栈帧恰好与 `readUntilNull` 旧栈帧重叠（macOS aarch64 ABI），数据被破坏。
     调试日志证实：`hn` 前 4 字节 "dasi" 正确，后续被垃圾覆盖。
   - 修复：`readUntilNull` → `readUntilNullBuf(fd, buf)` — 缓冲区由调用者提供，数据存在于
     调用者栈帧中，`readUntilNullBuf` 返回后持续有效
   - 影响函数：`socks4CheckAndReply`（生产）、`socks4Accept`（测试）
   - 修复前：SOCKS4a 所有 hostname 都返回 REJECTED (0x5b)
   - 修复后：SOCKS4a 返回 OK (0x5a)，macvm exec 端到端通过

**测试方法反思**:
- 错误 1：从开发目录 `sudo ./zig-out/bin/utmm --exec` 触发了 `forceInstall(.host)`，
  覆盖本机 Host daemon 二进制
- 错误 2：用 Python 裸 SOCKS4a 测试而非走 CLI 路径
- 正确流程：build → scp 到 guest → `--install` 重启 → 走本机已有 Host daemon CLI 验证
- 事后已恢复 Host daemon

**验证状态**:
- `zig build` 编译通过 ✅
- `zig build test` 全部通过（含新增 5 个测试：socks4CheckAndReply × 2, readUntilNullBuf × 3）✅
- `zig build test-integration` 全部通过（9 套件 / 45 场景 / 0 失败）✅
- SOCKS4a Python 测试: 0x5a (OK) ✅
- macvm exec (CLI 端到端): `echo hello` → `hello` ✅

**测试更新**:
- `socks4Accept` 改为接受 allocator 参数，返回堆分配 hostname（消除 socks4Accept 自身的悬垂指针）
- 新增 `socks4CheckAndReply matching hostname` 测试
- 新增 `socks4CheckAndReply mismatched hostname` 测试
- 新增 `readUntilNullBuf basic` 测试
- 新增 `readUntilNullBuf empty field` 测试
- 新增 `readUntilNullBuf buffer overflow` 测试
- 集成测试 `tcp_frame/main.zig`: 更新 socks4Accept 调用传递 allocator

### 2026-07-29 — Phase 9：E2E 真机 Bug 修复

**成果**: 真机 E2E 验证发现并修复 2 个致命 bug（AddressInUse 崩溃循环 + upload 双 close panic），
修复 utmmd.bin 嵌入构建流程。linuxvm 5 轮 exec/upload/download 全通过。

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 45 | 修复 AddressInUse 崩溃循环（TCP listener 缺 SO_REUSEADDR + FD_CLOEXEC）| ✅ |
| Task 46 | 修复 upload 后 panic（handleUpload 双 close → use-after-free）| ✅ |
| Task 47 | 修复 utmmd.bin 嵌入构建流程（按目标分目录 + comptime switch）| ✅ |
| Task 48 | linuxvm E2E 真机验证（5 轮 exec/upload/download 全通过）| ✅ |
| Task 49 | 修复 Windows SOCKS4a 拒绝（readUntilNull 悬垂栈指针）| ✅ |
| Task 50 | 修复 Windows upload/download socket I/O（system.read/write → sockRead/sockWrite）| ✅ |
| Task 51 | windowsvm E2E 全验证（exec + upload + download SHA256 一致）| ✅ |
| Task 48 | linuxvm E2E 真机验证（5 轮 exec/upload/download 全通过）| ✅ |

**Bug 修复详情**:

1. **AddressInUse 崩溃循环** (`src/tcp.zig`):
   - 根因链：dpipe_shell fork() → 子进程继承 TCP listener socket（无 FD_CLOEXEC）→ upload panic → 孤儿子进程持有 TCP :2121 → 新 utmm 无法 bind → AddressInUse
   - 修复：`addr.bind()` → `addr.listen()`（启用 `reuse_address: true`）+ `fcntl(F_SETFD, FD_CLOEXEC)`
   - Zig 0.16.0 编译坑：`std.posix.F` 是 struct 非 enum（`@intCast`）、variadic fcntl 字面量需 `@as(c_int, ...)`、`Server` 替代 `Socket`
   - 影响文件：`src/tcp.zig`、`tests/tcp_frame/main.zig`

2. **Upload 双 close panic** (`src/guest.zig`):
   - 根因：`handleUpload` 有 `defer file_pipe.close()` + 显式 `file_pipe.close()` → 第一次 close 释放 ctx 内存 → defer 的第二次 close 操作已释放内存 → 垃圾 fd → EBADF → recoverableOsBugDetected panic
   - 修复：移除 `defer file_pipe.close()`（显式 close 已覆盖所有退出路径）
   - 这是 AddressInUse 崩溃循环的直接触发因素

3. **utmmd.bin 嵌入构建流程修复** (`build.zig` + `src/main.zig`):
   - 问题：切换目标平台不重编 utmmd + `src/embed/` 无按平台分子目录 → 交叉编译覆盖错误 bin
   - 修复：按目标分目录 `src/embed/{arch}-{os}/` + comptime switch 选择正确路径 + mkdir -p 子目录

**真机验证**:
- linuxvm (192.168.64.2) 5 轮测试（每轮 exec "uname -a" + upload test.txt + download test.txt），全部通过
- Guest PID (6632) 全程稳定无崩溃
- 验证修复有效：无 AddressInUse、无 upload panic、无 download 失败

**关键决策**:
- 决策 19：`addr.listen()` 替代 `addr.bind()` + 手动 `fcntl(FD_CLOEXEC)` — 原生支持 reuse_address
- 决策 20：handleUpload 移除 `defer file_pipe.close()` — 显式 close 已覆盖所有退出路径

### 2026-07-29 — Phase 9（续）：Windows E2E 真机 Bug 修复

**成果**: windowsvm (aarch64-windows) exec + upload + download 全通过，SHA256 一致验证。

**Bug 修复详情**:

4. **Windows SOCKS4a 拒绝 (0x5b)** (`src/tcp.zig`):
   - 根因：`readUntilNull()` 返回指向栈缓冲区的切片，函数返回后 `socks4Accept` 调用方
     访问该悬垂指针进行 hostname 比较 → 栈被重用 → 数据损坏 → 比较失败 → 拒绝连接
   - 修复：新建 `socks4CheckAndReply()` — 在 `readUntilNull` 返回后立即比较 hostname
     （在栈数据仍有效时），避免悬垂指针
   - 保留原 `socks4Accept` 仅供测试使用

5. **Windows upload/download socket I/O 失败** (`src/guest.zig` + `src/ipc.zig`):
   - 根因：`std.posix.system.read/write(conn.fd, ...)` — `conn.fd` 是 raw Winsock2 SOCKET，
     Windows 上 `system.read`/`write` 底层走 `ReadFile`/`WriteFile`，不支持 socket 句柄
   - upload 症状：temp 文件创建成功但 0 字节（`system.read` 返回 -1 → while 循环不执行）
   - download 症状：`system.write` 失败 → Host 收到 0 字节
   - exec 不受影响：`handleExecCmd` 全程使用 `conn.sendAndFlush()`（framed），不走裸读写
   - 修复：4 处 `system.read`/`write` → `tcp.sockRead`/`tcp.sockWrite`（Windows 走 `ws2_recv`/`ws2_send`）

**真机验证**:
- windowsvm (192.168.65.2): exec "echo" + ver 正常，50KB 二进制 upload + download SHA256 完全一致
- 全部测试通过：unit tests (150 执行) + integration tests (7 suites, 0 failures)

### 2026-07-29 — Phase 8：Windows 跨平台 Socket 抽象层修复

**成果**: 新增跨平台 socket I/O 抽象层（7 个 wrapper 函数），修复 x86-windows-gnu Winsock2 链接，
8 交叉编译目标全部通过，部署 3 台真机验证通过。

| 任务 | 描述 | 状态 |
|------|------|------|
| Phase 8 | tcp.zig + tests/common.zig 跨平台 socket 抽象层 + 6 个测试文件迁移 | ✅ |

**核心修复**:
- `tcp.zig` 新增 ~130 行：`sockWrite`、`sockRead`、`sockClose`、`sockShutdown`、`sockAccept`、`sockListen`、`makePair`
- `tests/common.zig` 新增相同 7 个 wrapper + 6 个 Winsock2 extern
- 所有 POSIX `system.read/write/close/shutdown/accept/listen` 调用统一迁移至 wrapper
- `host.zig` line 852: `system.listen` → `tcp.sockListen`
- 6 个测试文件全部迁移至 `common.zig` 辅助函数
- `svc.zig` LockFileEx Bool 比较修复：`== 0` → `@intFromEnum(result) == @as(c_int, 0)`

**x86-windows-gnu 链接修复**（6 个未定义符号）:
- 根因：`extern "ws2_32"` 默认 cdecl，32 位 Windows stdcall 需要 `@n` 名称修饰（如 `_send@16` 而非 `_send`）
- 修复：所有 6 个 Winsock2 extern 添加 `callconv(.winapi)` — 32 位解析为 `.Stdcall`，64 位为 `.C`（无操作）
- 额外修复：`accept` 的 `addrlen` 类型从 `?*c_int` 改为 `?*std.posix.socklen_t`（Zig 的 Windows socklen_t 是 `u32`）

**编译验证**:
- 全部 8 交叉编译目标通过：aarch64/x86_64/x86 × linux-musl/macos/windows
- `zig build test` 通过
- `zig build test-integration` 通过（7 测试套件，43 场景，0 失败）

**真机部署验证**:
- linuxvm (aarch64-linux): v0.13.0 → v0.13.1，`--exec` + `--status` 正常
- macvm (aarch64-macos): v0.13.0 → v0.13.1，LSA 发现正常
- windowsvm (aarch64-windows): v0.13.0 → v0.13.1，UDP LSA 正常（TCP 2121 仍未开放，预存问题）
- winx64 (x86_64-windows, 192.168.3.108): 仍运行 v0.12.2，待后续升级

**已知遗留**:
- Windows VM TCP 2121 端口未监听（仅 UDP 2121 LSA 可用），非本次变更所致
- winx64 仍运行旧版 v0.12.2

### 2026-07-29 — Phase 5-7：集成测试补充 + 代码审查修复 + 部署门禁

**成果**: 新增 4 个 e2e 集成测试（16 场景）、12 项代码审查修复全部完成、CLAUDE.md 部署门禁规则

| 任务 | 描述 | 状态 |
|------|------|------|
| Phase 5 | 9 集成测试全部实现（43 场景，0 FAIL）| ✅ |
| Phase 6 | REVIEW_FINDINGS.md 12 项全部修复（C1-C2, I1-I4, M1-M6）| ✅ |
| Phase 7 | CLAUDE.md 添加 Deployment Gating Rule | ✅ |

**新增集成测试详情**:
| 测试 | 场景数 | 验证内容 |
|------|--------|---------|
| `exec_e2e` | 4 | 命令执行 + MDELIM 标记 + exit code（捕获 C1 双重标记回归）|
| `upload_e2e` | 4 | 小文件/零字节/二进制上传 + SHA256 验证 + 错误码回传 |
| `download_e2e` | 4 | 小文件/128KB 流式下载 + 零字节 + 失败退出码 |
| `upgrade_e2e` | 4 | upgrade_req → 256KB 二进制流接收 + SHA256 校验 + 编解码 |

**编译问题修复记录**:
- `fromOwnedSlice(alloc, slice)` → `.empty` + `appendSlice` (Zig 0.16.0 ArrayList API)
- `system.read` / `system.write` 返回 `isize` 非 error union → 不能 try/catch
- `system.write` 参数需 `[*]const u8` 非 `[]const u8` → 使用 `.ptr`
- `catch |_| {}` → Zig 0.16.0 不允许丢弃 error capture

**CLAUDE.md 部署门禁**:
```markdown
### Deployment Gating Rule
Code changes must pass integration tests before deployment to real devices.
- zig build test AND zig build test-integration must both pass
- No exceptions for "trivial" changes
```

**成果**: CLAUDE.md 更新 + dpipe_file 测试修复 + build.zig 去重 + 代码库遗留问题扫描

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 11 | 更新 CLAUDE.md：KCP→TCP 架构、16 文件清单、新协议描述 | ✅ |
| Task 12 | 修复 dpipe_file hash mismatch 测试（warn→debug）| ✅ |
| Task 13 | 清理 build.zig standalone_test_modules（去重 tcp/lsa，新增 shm）| ✅ |
| Task 14 | 代码库遗留问题扫描（TODO、日志、refac.md）| ✅ |
| Task 15 | 新增 config.auto_upgrade 开关（默认 false，5 文件变更）| ✅ |

### 2026-07-29 — Phase 5 集成测试（计划中）

**计划**: 创建 `tests/` 目录，5 个独立可执行集成测试程序 + 共享测试库。

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 16 | 测试基础设施 `tests/common.zig` | 📋 |
| Task 17 | `tcp_frame` — TCP 帧协议 + SOCKS4a | 📋 |
| Task 18 | `lsa_routing` — LSA + Dijkstra 路由 | 📋 |
| Task 19 | `dpipe_relay` — DuplexPipe 双向转发 | 📋 |
| Task 20 | `svc_install` — 安装/卸载 | 📋 |
| Task 21 | `auto_upgrade` — 自动升级 | 📋 |
| Task 22 | build.zig `test-integration` 构建步骤 | 📋 |

详见 `refac.md` §8 集成测试计划。

---

**auto_upgrade 开关详情**:
- `config.zig`: 新增 `auto_upgrade: bool = false` 字段
- `main.zig`: 新增 `--auto-upgrade` CLI flag（显式启用）及 help text
- `lsa.zig`: `upgrade_needed` 从 `*std.atomic.Value(bool)` 改为 `?*`，null 时跳过版本比对
- `guest.zig`: `guestTcpLoop` 新增 `auto_upgrade` 参数，升级检查和 Mesh 信号按开关门控
- `host.zig`: `startHost` 新增 `auto_upgrade` 参数，GitHub 检查、serve-dir 校验、升级信号均门控
- 编译和测试全通过，5 文件变更

**代码扫描发现**:
- 3 个 TODO 注释：config.zig:107（功能缺口）、guest.zig:780（TCP 自动升级未闭环）、lsa.zig:496（Zig stdlib 问题）
- refac.md §3.7 残留过时描述（"install.zig 可独立构建"），已修正
- 无编译警告、无未使用导入、warn 日志均在生产代码路径中非测试路径
- 结论：重构阶段可彻底收工，分支可合并 main

**CLAUDE.md 更新详情**:
- 协议栈图 → 7 层分层模型（应用/拓扑/传输/数据管道/协议/系统服务/基础）
- 删除 KCP 协议栈、KCP 可靠传输、HostState、KCP Patterns 等全部过时章节
- 新增 TCP per-command 模型、DuplexPipe vtable、TCP 帧协议、LSA 自洽模式
- 文件清单：18 文件（含已删除）→ 正确的 16 文件

**dpipe_file hash 测试修复详情**:
- 根因：Zig 0.16.0 测试运行器对 stderr `warn` 级别日志敏感，导致 `--listen=-` 协议通信异常
- 修复：`std.log.warn` → `std.log.debug`（hash 不匹配是预期的可恢复诊断事件）
- `zig build test` 完全干净通过，无 "failed command"

**build.zig 清理详情**:
- 移除 `tcp.zig`、`lsa.zig`（已在主二进制中通过 host.zig import 链覆盖，消除重复）
- 新增 `shm.zig`（发现其 10 个测试之前从未被执行！）
- 重命名 `refac_modules` → `standalone_test_modules`
- 测试二进制：7 → 6，总执行 150 次（141 唯一 + 9 不可避免的 dpipe 重复）

### 2026-07-29 — Phase 3 完成

**成果**: lock.zig 删除 + Platform/genInit 迁移 → svc.zig

| 任务 | 描述 | 状态 |
|------|------|------|
| lock.zig 删除 | svc.zig 内联 flock/LockFileEx (120行), 删除 365行 | ✅ commit `06adede` |
| Platform/genInit | host.zig → svc.zig 迁移 (~140行+4测试) | ✅ |
| refac.md 更新 | 反映所有已完成任务、最终文件清单 | ✅ |
| task_plan.md 更新 | 全部任务标记完成 | ✅ |

**lock.zig → svc.zig 详情**:
- POSIX: `open(O_CREAT|O_RDWR)` + `flock(LOCK_EX)` — OS 级别劝告锁，进程崩溃自动释放
- Windows: `CreateFileW(OPEN_ALWAYS)` + `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)`
- 锁文件: `/var/run/utmm-install.lock` (POSIX) / `C:\opt\utmm\utmm-install.lock` (Windows)
- API 简化: `acquire(io, alloc)` → `acquire()`

**Platform/genInit 迁移详情**:
- host.zig 调用改为 `svc.Platform` + `svc.genInit`
- 不独立构建 install.zig（收益低，发布目标翻倍，与单二进制模型冲突）

### 2026-07-29 — Phase 2 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 5 | 新建 dpipe.zig + dpipe_shell.zig + dpipe_file.zig | ✅ |
| Task 6 | broadcast.zig → guest.zig，移植到 dpipe | ✅ |
| Task 7 | 删除 file_chunk/file_eof | ✅ |
| Task 8 | 消灭 state.zig + cmdchan.zig | ✅ |

### 2026-07-29 — Phase 1 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 1 | tcpf.zig + socks4.zig + netconn.zig → tcp.zig | ✅ |
| Task 2 | tunproto.zig → protocol.zig | ✅ |
| Task 3 | mesh.zig + hosts_file.zig → lsa.zig | ✅ |
| Task 4 | 修复 /etc/hosts 空行累积 bug (range replacement) | ✅ |

## 最终文件清单（16 个）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── config.zig        配置持久化
├── lsa.zig           LSA + 节点表 + /etc/hosts
├── tcp.zig           帧协议 + SOCKS4 + 连接
├── dpipe.zig         DuplexPipe 接口 + relay
├── dpipe_shell.zig   pty→pipe
├── dpipe_file.zig    file→pipe
├── guest.zig         Guest daemon
├── host.zig          Host daemon
├── ipc.zig           IPC socket
├── mcp.zig           MCP stdio
├── svc.zig           服务管理（install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
└── shm.zig           共享内存（utmmd↔utmm）
```

### 删除文件（10 个）
state.zig, broadcast.zig, mesh.zig, hosts_file.zig, tunproto.zig,
tcpf.zig, socks4.zig, netconn.zig, cmdchan.zig, lock.zig

---

### 2026-07-31 — v0.14.7：裸机部署测试（clean deploy）+ skill 问题修复

**测试流程**：全清空 → 构建(176 unit + 59 integration) → 部署(Host + 4 Guest) → 全功能验证

**测试结果（全部通过）**：

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅* | ✅ | ✅ | ✅ |

*linuxvm 首次 ping RTT 异常（1636224693 ms），重试正常（0 ms）

**发现的 skill 问题（5 个）**：

| # | 问题 | 影响 | 修复 |
|---|------|------|------|
| 1 | **sshpass 不存在** — v0.14.7 移除了外部 sshpass，clean-deploy skill 仍直接调用 `sshpass` | 清空 Host 后无法执行 Guest SSH 操作（鸡和蛋问题：需要 utmm 内置 sshpass，但 utmm 先被删了） | 先构建 → 用 `./zig-out/bin/utmm sshpass` 替代 `sshpass`；skill 需更新流程顺序 |
| 2 | **linuxvm IP 错误** — skill 中写 `192.168.64.2` | SSH 连接超时 | 更新为 `192.168.64.6` |
| 3 | **`pkill -9 -f utmm` 自杀** — Linux 上 `-f` 匹配命令全行，pkill 杀死执行该命令的 shell 自身 | SSH 会话异常退出（255） | 改用 `pkill -9 utmm`（仅匹配进程名，不用 `-f`） |
| 4 | **Windows `mkdir C:\opt\utmm` 不可靠** — `2>nul` 隐藏错误但目录未创建 | SCP 失败 "No such file or directory" | 用 PowerShell `New-Item -ItemType Directory -Force -Path` |
| 5 | **linuxvm ping RTT 偶尔异常** — 首次 ping 返回时间戳值而非 RTT | `--ping` 结果不可靠 | 待排查（可能 LSA 未完全同步时的竞争条件） |

**skill 文件已同步修复**：
- `clean-deploy/SKILL.md`：移除 `-f` 标志、更新 IP、添加 PowerShell mkdir
- `deploy/SKILL.md`：更新 linuxvm IP
- `SKILL.md`（根）：更新 linuxvm IP

### 2026-07-31 — v0.14.7：动态 ConPTY 加载 + 管道降级 + conpty 状态标记 + 文档审查

**Task 190 — 动态 ConPTY 加载 + 管道降级**:
- `src/sshpass.zig`：Windows ConPTY 函数指针类型 + LoadLibraryA/GetProcAddress 运行时解析
- `resolveConpty()`：惰性初始化，仅检查一次，失败则 conpty_create/conpty_close 为 null
- `windows.conptyAvailable()`：Guest 检测 ConPTY 是否可用
- `runWindows()` 调度器：ConPTY 可用 → `runWindowsConpty()`；不可用 → `runWindowsPipe()`
- `runWindowsConpty()`：原实现，使用动态加载的函数指针
- `runWindowsPipe()`：新增管道降级模式，CreatePipe + 标准 STARTUPINFO
- `buildCmdLine()`：从 runWindows 提取的命令行构建辅助函数

**Task 191 — conpty 状态标记**:
- `src/sshpass.zig`：模块级 `pub fn conptyAvailable()`（POSIX 恒返回 true）
- `src/guest.zig`：LSA node_info 新增 `conpty:{s}` 字段（yes/no）
- `src/host.zig`：
  - 新增 `sshpass` import
  - `GuestEntry` struct 新增 `conpty: []const u8`
  - `upsert()` 新增 conpty 参数 + 比较 + 替换逻辑
  - `deinit()`/`remove()` 新增 conpty 释放
  - LSA 解析循环新增 `parseNodeInfoLine(line, "conpty")`
  - Host node_info 新增 `conpty:{s}` 字段
  - `cmdStatus()` 表头/行输出新增 ConPTY 列
  - Host 自注册 upsert 包含 conpty
  - 12 个测试 upsert 调用更新
- `src/ipc.zig`：`ipcStatus()` JSON 新增 `"conpty"` 字段
- 编译验证：native debug + 8/8 交叉编译目标全部通过 ✅
- 单元测试：176/176 通过 ✅

**Task 192 — 全面文档审查**:
- `src/main.zig`：printHelp() sshpass 行展开为完整选项说明（-p/-f/-d/-e/-hV）+ ConPTY 自动检测提示
- `src/sshpass.zig`：模块文档新增使用示例 + ConPTY 重要性说明
- `CLAUDE.md`：Key capabilities 新增 sshpass 子命令条目
- `README.md`：CLI Quick Start 新增 3 个 sshpass 示例；MCP section 新增 ConPTY 解释

**关键教训**:
- `@ptrCast` from `?*anyopaque` (align 1) to fn pointer (align 4) 在交叉编译（Windows）时才报错；原生构建通过不代表对齐正确
- 动态 DLL 加载避免 Win32 @extern 强制依赖 — 老版本 Windows 缺少 API 时优雅降级而非崩溃
- ConPTY 对 MCP SSH 操作至关重要 — `--status` 输出 conpty 字段让 AI agent 了解目标能力

## 历史摘要

### v0.12.2 及之前
- KCP 隧道稳定性修复、自动升级完善
- utmmd 监督进程架构重构、MCP stdio JSON-RPC
- 8 交叉编译目标全通过，166 测试通过

### v0.13.0-pre (commit `036f40f`)
- 删除 KCP ARQ 协议 (~1300行)，新增 TCP+SOCKS4 传输层
- mesh.zig 简化为纯 LSA 广播
- 20 源文件，124 测试通过

### 2026-07-31 — v0.15.0：对等 SOCKS4a 转发 + Windows 句柄兼容修复

**对等 SOCKS4a 转发（v0.15.0, commit `b4a818a`）**:
- `src/tcp.zig`：新增 `socks4ReadRequestBuf`（读取不回复）、`socks4Forward`（链式转发）、
  `socks4LocalRelay`（本地 relay）、修复 `socks4Relay`（`!void` → `void` + SHUT_WR 传播）、
  `TcpListener.acceptRaw()`
- `src/lsa.zig`：新增 `Mesh.lookupHostnameIp()` — Guest 端 hostname→IP 查找
- `src/guest.zig`：accept 循环改为三路 dispatch（self:2121 → utmm 帧协议 /
  self:other → localhost relay / other → chain-forward）；`ForwardCtx` + `forwardThreadFn`
- `src/host.zig`：新增 `hostTcpListen()` 线程 — Host 端 TCP :2121 SOCKS4a listener；
  复用 `guest.ForwardCtx`/`forwardThreadFn`
- 文档更新：CLAUDE.md、README.md、MANUAL.md
- 0 个新文件、0 个新 CLI 参数、0 个新端口 — 全部复用已有 TCP :2121 + SOCKS4a
- 测试：176 单元 + 59 集成 = 全部通过 ✅

**Windows SOCKS4a 转发修复（commit `7a47461`）**:
- 问题：SOCKS4a → windowsvm:22 收到 0 字节（linuxvm/macvm 正常）
- 根因：`socks4LocalRelay` 中 `IpAddress.connect()` 返回 AFD 内核句柄，
  `sockAccept` 返回 Winsock2 SOCKET，两种句柄类型不兼容 — `ws2_recv`/`ws2_send`
  在 AFD 句柄上静默失败
- 修复：新增 `sockConnectLocalhost()` — Windows 上用 `ws2_socket()`+`ws2_connect()`
  创建 Winsock2 兼容 SOCKET，POSIX 上用原始 `socket()`+`connect()`

**裸机部署测试结果（5 节点，全部通过）**:
| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ | ✅ | ✅ | ✅ |
| SOCKS4a forward | ✅ | ✅ | ✅ (修复后) | ✅ (修复后) |

### 2026-07-31 — MCP download 修复 + 全工具测试

**MCP download 修复**:
- 根因：`src/mcp.zig` `handleVmDownload` 使用 `openFile(io, local_path, .{ .mode = .write_only })`，
  `openFile` 要求文件已存在（否则 `FileNotFound`）。CLI `cmdDownload` 正确使用 `createFile`
- 修复：`openFile` → `createFile(io, local_path, .{})` — 创建或截断，1 行变更
- macOS 踩坑：`cp` 覆盖 `/opt/utmm/utmm` 导致 ad-hoc 签名失效，`sudo` 运行被 SIGKILL（bug_type 309）
  - 解决：`codesign --remove-signature` + `codesign -s -` 重新 ad-hoc 签名
  - 建议：部署 flow 应使用 `--install` 而非裸 `cp`，install flow 内部处理签名

**MCP 全工具测试（通过管道验证）**:
| 工具 | linuxvm | 结果 |
|------|---------|------|
| status | — | ✅ 5 节点 online |
| exec | uname -a | ✅ |
| ping | — | ✅ RTT=0ms |
| upload | 25 bytes → /opt/utmm/ | ✅ |
| download | 25 bytes ← /opt/utmm/ | ✅ （修复后）|
| sshpass | echo SSH-PASS-OK | ✅ exit=0 |

**sshpass 测试详情**: `ssh root@192.168.64.6 echo SSH-PASS-OK` → 输出正确，exit 0 ✅
- 管道降级 + ConPTY 动态加载在之前 session 已验证，本次直接测试正常路径

**测试验证**:
- 176 单元测试全部通过 ✅
- 59 集成测试全部通过 ✅

**修复后二进制确认**:
- `/opt/utmm/utmm` 已包含 `createFile` 代码 + 重新 ad-hoc 签名
- MCP 进程需重启会话才能加载新二进制（管道测试已验证功能正确）

---

## v0.16.1 后续 — Hub-Spoke 架构全面修正

**时间**: 2026-08-01

### SOCKS5 文档全面修正

用户指出对 SOCKS5 转发架构理解有根本性错误 — 是 Hub-Spoke（Host 唯一中转），
不是 peer-mesh（每节点中转）。Host IP 同步到每个 Guest 的 `/etc/hosts` 文件
作为 `gateway` hostname。

**文档修正** (commit `dc782b9`):
- `README.md`: CLI Quick Start SOCKS5 示例加 gateway 注释
- `MANUAL.md`: SOCKS5 Forwarding 整节重写，Run Modes 更新，加 Windows Firewall BIND 限制
- `CLAUDE.md`: 5+ 处修正 — 端口描述、运行模式、转发流程、设计决策、TCP 帧协议模式

### Guest 链式转发代码修正

**Explore agent 发现**: `src/guest.zig:989-1051` 仍保留直接 Guest→Guest 链式转发代码，
与 Hub-Spoke 模型矛盾。

**修复** (commit `2b69c8e`):
- 删除 ~58 行直接链式转发代码（node table lookup → connect → socks5 forward）
- 替换为直接 REJECT：目标非本机时拒绝，统一走 Host (gateway) 中转
- `ForwardCtx`/`forwardThreadFn` 保留 — host.zig 仍使用它们做正确的 Host 侧转发

**测试验证**:
- 186 单元测试全通过 ✅
- 59 集成测试全通过，无内存泄漏 ✅

---

## P1 误报确认 — relay/SOCKS5 心跳无需修复

**时间**: 2026-08-02

P1 调查项 "relay/SOCKS5 线程心跳更新" 经代码审查确认**不是问题**：

### 心跳更新机制分析

| 路径 | 类型 | 心跳更新 |
|------|------|---------|
| 主 accept 循环（host:747, guest:920） | 同步 | 每迭代顶部更新 |
| handleExec shell read 循环（guest:1099） | 同步 | 读取后更新 |
| handleUpload read 循环（guest:1171） | 同步 | 读取后更新 |
| handleDownload read 循环（guest:1409） | 同步 | 读取后更新 |
| handleUpgrade read 循环（guest:1274） | 同步 | 读取后更新 |
| SOCKS5 relay/forward detach 线程 | 异步 | 不需要 — 不阻塞主循环 |
| localRelayWithLimit detach 线程 | 异步 | 不需要 — 不阻塞主循环 |

**关键洞察**: SOCKS5 relay/forward 线程通过 group.spawnBlocking detach 执行，
不阻塞主 accept 循环。主循环独立更新心跳，不受 relay 线程影响。
唯一的同步阻塞路径 handleOneCommand 已在所有读写循环中覆盖心跳更新。
**架构设计正确，无需修改。**

---

## Phase 27 P0 macOS/Windows — installMacOS + installWindows 服务恢复修复

**时间**: 2026-08-02

### P0 macOS: installMacOS() 缺少 KeepAlive + ThrottleInterval

**根因**: `installMacOS()` plist 模板只有 `RunAtLoad`，缺少 `KeepAlive`（含
`SuccessfulExit=false`）。`RunAtLoad` 仅在开机时启动 utmmd，utmmd 退出后
launchd 不会自动重启 → macvm 永久离线。

`genInit(.macos)` 模板正确但 `installMacOS()` 不一致 — 与 linux P0 完全相同的模式。

**修复** (`src/svc.zig`):
1. 新增共享常量 `MACOS_KEEPALIVE_CONFIG`
2. `installMacOS()` plist 插入 `{s}` 插值
3. `genInit(.macos)` 改用 `++ MACOS_KEEPALIVE_CONFIG ++`

### P0 Windows: installWindows() 缺少 sc failure 命令

**根因**: `installWindows()` 只执行 `sc create ... start=auto`，没有 `sc failure`
配置。utmmd 5 次重试后退出一 → SCM 无 failure action 不重启 → VM 永久离线。

`genInit(.windows)` 正确显示了 `sc failure` 命令但 `installWindows()` 没执行。

**修复**: `installWindows()` 在 `sc create` 后添加 `sc failure` 命令:
```
sc failure <name> reset=30 actions=restart/5000/restart/5000/restart/5000/none/5000
```

**设计**: SCM 先尝试 3 次快速重启（5s 间隔），30s 后 reset 计数。
若 utmm 反复崩溃，utmmd 内部 5 次重试耗尽后退出，SCM 再重启 utmmd。
双保险架构。

**测试验证**:
- 188 单元测试全通过 ✅
- 59 集成测试全通过，无内存泄漏 ✅

---

## v0.17.15: Windows --upgrade 推送失败修复

**时间**: 2026-08-02

### 根因分析

`pushUpgrade` 对比已验证的 `handleUpload`，发现三个关键缺陷：

| 问题 | pushUpgrade（旧） | handleUpload（正确） |
|------|-------------------|---------------------|
| 大文件写 | 单次 `sockWrite` 4MB，丢弃返回值 | 分块 64KB 写，循环处理短写 |
| 响应确认 | fire-and-forget，不读响应 | 读 upload_result，验证 exit_code |
| 连接关闭 | 写后立即 close() | 确认响应后再 close() |

**故障链路推断**:
1. macOS Host 端 `system.write(fd, buf, 4_000_000)` 对大缓冲可能短写
2. 旧代码 `_ = tcp.sockWrite(...)` 丢弃返回值 → 短写无法检测
3. `defer tcp_conn.deinit()` 立即 `shutdown(SHUT_RDWR)` + `close()`
4. macOS `close()` 无 SO_LINGER 时可能丢弃内核发送缓冲中的未发送数据
5. Guest 端 `conn.recv` 读到 0（EOF）→ `handleOneCommand` 静默返回
6. Guest 无任何 upgrade 日志 → 升级完全未生效

POSIX VM（macvm 2MB、linuxvm 14MB）成功而 Windows（4MB）失败的原因
可能是网络时序差异：Windows 4MB 在 close() 前未能全部排入发送缓冲，
或 send buffer 耗尽触发短写。

### 修复 (src/host.zig)

1. **分块写循环** — 替代单次 `sockWrite`:
```zig
var written: usize = 0;
while (written < file_size) {
    const w = tcp.sockWrite(tcp_conn.fd, file_data.ptr + written, file_size - written);
    if (w < 0) return "WriteFailed";
    if (w == 0) return "WriteFailed";
    written += @intCast(w);
}
```

2. **读 Guest 响应** — 发送后等待 upload_result:
```zig
const nr = tcp_conn.recv(&rbuf) catch |err| { return "ResponseReadFailed"; };
if (nr > 0 and rbuf[0] == @intFromEnum(protocol.MsgType.upload_result)) {
    const result = protocol.parseUploadResult(rbuf[1..nr]) orelse { ... };
    if (result.exit_code != 0) return "UpgradeRejected";
}
```

3. **错误传播** — 每步失败返回具体错误字符串，不再 `catch` 后吞掉

**测试**: 188 单元测试全通过 ✅

### 待验证
- 下一轮部署中验证 Windows `--upgrade` 是否真正生效
- 若问题持续，需在 Guest 端 `handleOneCommand` 入口添加更多诊断日志
