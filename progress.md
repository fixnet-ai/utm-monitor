# Progress: v0.11.23

## 当前状态

- **分支**: `main`
- **版本**: v0.11.23（唯一来源 `src/ver.txt`，`@embedFile` 编译期嵌入；`build.zig.zon` 永为 `0.0.0`）
- **测试**: 166/166 通过
- **部署**: macOS Host v0.11.23 ✅ | macvm v0.11.23 ✅ | linuxvm v0.11.23 ✅ | windowsvm v0.11.22 | winx64 v0.11.22
- **健康检查**: 4/4 全部通过（`--verify` 全绿 ✓）
- **自动升级 rollback 修复**: `forceInstallInternal()` 步骤 5 不再回滚删除二进制+配置 ✅
- **KCP Tunnel 稳定性修复**: session_gen 唯一 conv + epoch 范围验证 + 日志降级 ✅
- **自动升级 forceInstall 修复**: killAllUtmm PID 感知 + waitForProcessExit + start() 重试 ✅

## Phase 75: utmmd 监督进程架构重构 ✅ (2026-07-28 已完成)

### 背景

Phase 72-74 修复了自动升级的具体 bug，但根本架构问题（系统保活与自升级启动权冲突）未解决。
Phase 75 引入 utmmd 监督进程，将生命周期管理从系统服务管理器中完全剥离。

### 决议

| R1 | utmmd 不需要系统保活 | R2 | IPC 用共享内存 | R3 | 检测到升级立即执行 |
| R4 | 服务名称简化为 "utmmd" | R5 | 命名 `utmmd` | R6 | 不考虑向后兼容 |

### 任务状态

| # | 任务 | 状态 |
|---|------|------|
| 355 | 创建 `src/shm.zig` — 跨平台共享内存协议 | ✅ |
| 356 | 创建 `src/utmmd.zig` — 监督进程完整实现 | ✅ |
| 357 | 修改 `src/svc.zig` — 简化为纯 OS 服务管理 | ✅ |
| 358 | 修改 `src/main.zig` — shm 连接 + 新 install/uninstall | ✅ |
| 359 | 修改 `src/broadcast.zig` — shm 驱动升级流程 | ✅ |
| 360 | 修改 `build.zig` — 两步构建 + utmmd 嵌入 | ✅ |
| 361 | 编译 + 测试 — 166/166 通过 | ✅ |
| 362 | 部署验证 — Host + linuxvm + macvm | 📋 待部署 |

### 实现详情

**shm.zig** (~400行, Task 355):
- `ShmLayout`: 4096 字节 extern struct（magic, version, svc_state, utmm_state, utmm_pid, svc_pid, svc_heartbeat, utmm_heartbeat, cmd, cmd_status, restart_count, last_exit_code, backoff_sec, failure_count, cmd_data[1024], _reserved[3008]）
- `create(io)` / `open()` / `destroy(shm)` / `detach(shm)` / `nowMs(io)` 公共 API
- POSIX: 原始 `extern "c" fn shm_open/mmap/munmap/shm_unlink` + 原始常量（O_CREAT, PROT_READ, MAP_SHARED 等）
- Windows: `CreateFileMappingW` / `OpenFileMappingW` / `MapViewOfFile` / `UnmapViewOfFile`
- 10 测试（size=4096, 默认值, enum 值验证）

**utmmd.zig** (~600行, Task 356):
- `parseArgs()` — `--role guest|host` + `--svc` 解析
- `monitorLoop(io, alloc, shm, role)` — 主循环：startUtmm → stabilityCheck(10s) → monitorUtmm
- `startUtmm()` — fork+exec (POSIX) / CreateProcessW (Windows) 启动 utmm --svc
- `stabilityCheck(10s)` — 每秒检查 shm 心跳，10s 稳定算启动成功
- `monitorUtmm()` — 每 1s 检查心跳（10s 超时触发重启）+ 处理 shm 命令（UPGRADE/RESTART/SHUTDOWN）
- `upgradeUtmm()` — 重命名临时文件 → 规范路径，macOS codesign 重签，失败回退
- `winServiceRun()` — Windows SCM 分发，SERVICE_CONTROL_STOP 处理
- 退避算法：1s→2s→4s→8s→16s→32s→超过5次退出

**svc.zig** (重构, Task 357):
- 服务名统一：SVC_NAME_MACOS=`com.utmmd`, SVC_NAME_LINUX=`utmmd`, SVC_NAME_WINDOWS=`UTM-MonitorD`
- `svcName()` 无参数（Guest/Host 互斥，单名称）
- 新增 `canonicalSvcPath()` — `/opt/utmm/utmmd` 或 `C:\opt\utmm\utmmd.exe`
- macOS plist: 移除 `KeepAlive` dict + `ThrottleInterval`
- Linux systemd: 移除 `Restart=on-failure` + `RestartSec=5` + `StartLimitBurst=3`
- Windows: 移除 `sc failure` 配置
- 移除 SCM 集成（SvcGlobals, svcMain, svcCtrlHandler）→ 移入 utmmd.zig
- 存根函数在 Task 373 完成后清理
- `getOwnPid()` → `pub`（供 main.zig 使用）

**main.zig** (修改, Task 358):
- 新增 `@embedFile("embed/utmmd.bin")` + `extractUtmmd()` + `extractUtmmdIfMissing()`
- `--install`: 调用 extractUtmmd 强制提取，然后 svc.forceInstall
- `ensure`: 调用 extractUtmmdIfMissing（仅缺失时提取）
- `--svc`: 打开 shm → 设置 PID/状态 → 心跳线程(1s) → 运行主循环 → 清理（设置 stopping 状态 + detach）
- 新增 `heartbeatThread()` — 每秒更新 shm.utmm_heartbeat
- 新增 `copyFile()` — 用于 extractUtmmd 的 EXDEV 回退路径

**broadcast.zig** (修改, Task 359):
- `doAutoUpgrade` 签名改为返回 `!bool`（是否成功通知 utmmd）
- 下载后写 shm（cmd=UPGRADE, cmd_data=临时路径）替代执行 `--install`
- 调用方（meshSessionLoop）检查返回值：成功 → break 退出；失败 → 恢复 serving 状态继续
- 移除 `applyUpgradeAndRestart` 函数（~48 行）
- 移除 `svc.resetRetryCounter` 和 `svc.checkPendingUpgradeWindows` 调用

**host.zig** (清理, Task 359):
- 移除 `svc.resetRetryCounter` 调用

**build.zig** (修改, Task 360):
- 新增 utmmd 编译步骤 + `addSystemCommand("cp -f")` 复制到 `src/embed/utmmd.bin`
- utmm 构建步骤依赖 copy 步骤
- `src/embed/` 加入 .gitignore

### 验证

- `zig build`: 编译成功（utmmd + utmm 两步构建）
- `zig build test`: 166/166 全部通过
- macOS aarch64 原生构建验证通过

## Task 376: 安装优化 — hash 比对 + config 持久化 + 3b 仅重启路径 ✅ (2026-07-28)

### 背景

完成 Phase 75 核心实现后，识别出安装流程可进一步优化：每次 `ensure` 都走完整 forceInstall
（stop→kill→selfCopy→installService→start），即使 utmmd 未变化。引入 hash 比对和 3b 路径跳过
不必要的重装步骤。

### 变更摘要

**build.zig**:
- 新增 `hash_utmmd` 构建步骤：`shasum -a 256 utmmd.bin → src/embed/utmmd.sha256`
- utmm 编译依赖 hash 步骤（替代直接依赖 copy 步骤）
- 避免 comptime SHA256（2MB 二进制需要 >20M eval branch quota）

**`src/main.zig`**:
- `utmmd_sha256_hex`: `@embedFile("embed/utmmd.sha256")` — 构建期预计算，64 字符 hex
- `--install`: forceInstall 后调用 `svc.saveUtmmdMeta()` 持久化 hash + args
- Host ensure: 新增 `shouldUpdateUtmmd` 分支
  - 3a 路径: utmmd 需更新 → extractUtmmd + forceInstall + saveMeta
  - 3b 路径: utmmd 未变但服务未运行 → `svc.start()`（跳过重装）
  - 均未命中: 服务已在运行，无需操作
- Guest ensure: 同 Host ensure 优化逻辑

**`src/svc.zig`** (~140 行新增):
- `configFilePath()` — utmm.conf 路径
- `readConfigValue(io, alloc, key)` — 读取 key=value
- `writeConfigValue(io, alloc, key, value)` — 写入 key=value（tmp+rename 原子写）
- `readFullFile(io, alloc, path)` — 读取完整文件内容
- `fileSha256Hex(io, alloc, path)` — 运行时计算文件 SHA256 hex
- `buildArgsString(alloc, role, extra_args)` — 序列化参数用于比对
- `shouldUpdateUtmmd(io, alloc, role, extra_args, comptime hex) bool` — 三检查点:
  1. utmmd 二进制是否存在
  2. SHA256 hash 是否匹配嵌入值
  3. 存储的 args 是否匹配当前参数
- `saveUtmmdMeta(io, alloc, role, extra_args, comptime hex)` — 保存 hash+args 到 utmm.conf

### 设计决策

- SHA256 在构建期预计算（`build.zig` shasum 步骤），避免 comptime 哈希的 eval branch quota 问题
- utmm.conf 使用 key=value 纯文本格式，简单可靠
- 文件写入使用 tmp+rename 原子模式
- `shouldUpdateUtmmd` 三检查点中任一项不匹配即触发全量重装

### 验证

- `zig build`: 编译成功（utmmd + hash + utmm 三步构建）
- `zig build test`: 166/166 全部通过

## Phase 74: 自动升级 forceInstall 修复 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 350 | killAllUtmm PID 感知 — pgrep/tasklist 枚举 + 排除自身（Finding 139） | ✅ |
| 351 | waitForProcessExit — stop 后轮询等待进程退出（Finding 135） | ✅ |
| 352 | macOS start() 重试 — 500ms 延迟 + bootstrap 3 次重试（Finding 123） | ✅ |
| 353 | exit(0) → exit(42) — applyUpgradeAndRestart 非零退出码 | ✅ |
| 354 | zig build + 166/166 测试通过 | ✅ |

### 变更摘要

- **`src/svc.zig`**: `getOwnPid()` + `killAllUtmm()` 重写（PID 感知）+ `countOtherUtmmProcesses()` + `waitForProcessExit()` + `forceInstallInternal()` 步骤 1.5 等待 + `start()` macOS bootstrap 重试
- **`src/broadcast.zig`**: `applyUpgradeAndRestart()` — `exit(0)` → `exit(42)`

### 验证结果

- 166/166 测试通过
- zig build 编译成功
- 待部署验证: macvm (Finding 123), linuxvm (Finding 135), Host (Finding 139)

## Phase 73: KCP Tunnel 稳定性 + 下载性能修复 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 345 | 3 条 KCP 日志 info→debug（Finding 138） | ✅ |
| 346 | session_gen 计数 + 移除旧 session 销毁 + epoch 范围（Finding 129） | ✅ |
| 347 | waitForHostTunnel mutex 解锁顺序修复 | ✅ |
| 348 | tunnel.deinit 加 closeSession() | ✅ |
| 349 | 部署验证（Host + macvm + linuxvm） | ✅ |

### 变更摘要

- **`src/mesh.zig`**: session_gen 字段、connect() 重写、2 处 epoch 检查改为范围验证、3 条日志降级、死 session 清理
- **`src/broadcast.zig`**: waitForHostTunnel() mutex 移到 Tunnel.init() 之后
- **`src/tunnel.zig`**: deinit() 调用 closeSession()

### 验证结果

- macvm exec 4/4 成功（修复前 exit=-1）
- linuxvm exec 无回归
- 日志 10 秒 3.5KB（修复前 96MB/数分钟）
- Windows VM 仍 v0.11.22，显示旧行为（符合预期）

## Phase 72: 自动升级 rollback 修复 + 全流程部署测试 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 339 | `forceInstallInternal()` 步骤 5 删除回滚逻辑 | ✅ |
| 340 | v0.11.21→v0.11.22→v0.11.23 构建 + Host 部署 | ✅ |
| 341 | macvm 自动升级观察 | ✅ 下载成功，bootstrap errno=2，二进制+配置保留 |
| 342 | linuxvm 自动升级观察 | ✅ 下载成功，selfCopy 未更新（Text file busy），手动修复 |
| 343 | windowsvm 自动升级观察 | ✅ 下载成功，install 失败，优雅回退 |
| 344 | winx64 自动升级观察 | ✅ 未检测到升级信号 |

### 变更摘要

**`src/svc.zig` — forceInstallInternal() 步骤 5**:
- 删除 start 失败时的回滚逻辑（uninstallServiceConfig + deleteFile）
- 改为保留二进制和配置，仅日志 err + fail.err 退出
- 理由: 自动升级时旧进程已被 kill，删除一切 = VM 彻底失联

### 自动升级结果矩阵

| Guest | 下载 | install | 最终版本 | 根因 | Finding |
|-------|------|---------|---------|------|---------|
| macvm | ✅ 12.6MB | ⚠️ bootstrap errno=2 | v0.11.23 | launchctl bootstrap 间歇失败 | 92, 128 |
| linuxvm | ✅ 12.6MB | ❌ selfCopy 未更新 | v0.11.23 (手动) | Text file busy — 服务未完全停止 | 135 |
| windowsvm | ✅ 6MB | ❌ install 失败 | v0.11.22 | 待调查（优雅回退） | 137 |
| winx64 | ❌ 未触发 | — | v0.11.22 | LSA 升级信号未检测到 | 136 |

### 关键发现

1. **rollback 修复验证成功** — macvm 场景是最佳证明：bootstrap 失败后二进制+配置保留，旧代码会删除一切
2. **linuxvm selfCopy** — `systemctl stop` 异步，进程未完全退出前 selfCopy 遇到 "Text file busy"
3. **KCP 下载性能** — info 级别 mesh 数据包日志导致 96MB 日志文件，有效吞吐 ~15KB/s
4. **Host 自 kill** — `pkill -9 -x utmm` 匹配安装器自身进程
5. **winx64 子网隔离** — 192.168.3.x 与 64.x/65.x 之间的 LSA 可达性待验证

## Phase 71: 版本号单文件管理 + GitHub 新版本检测 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 334 | `src/ver.txt`（0.11.18 无换行）+ `build.zig.zon` → `0.0.0` | ✅ |
| 335 | `protocol.zig`: `@embedFile("ver.txt")` + comptime strip 换行 | ✅ |
| 336 | `release.sh` 打包 ver.txt；`install.sh`/`install.bat` 动态读版本 | ✅ |
| 337 | `checkGitHubVersion()` — OS 线程 fire-and-forget，5 redirect，格式校验 | ✅ |
| 338 | 构建+测试 166/166 通过 | ✅ |

### 变更摘要

**版本号单文件管理**:
- `src/ver.txt` — 版本号唯一来源，内容 `0.11.18`（无末尾换行）
- `build.zig.zon` — 永为 `0.0.0`，不再改动
- `protocol.zig` — `@embedFile("ver.txt")` 编译期嵌入，comptime strip 末尾换行
- `release.sh` — `cp src/ver.txt release/`
- `install.sh`/`install.bat` — 从 `ver.txt` 动态读版本，curl 流程回退 `"latest"`

**GitHub 新版本检测** (`src/host.zig`):
- `checkGitHubVersion()` — 独立 OS 线程，spawn+detach，fire-and-forget
- 支持 302 重定向（`redirect_behavior = .init(5)`）
- `isValidVersion()` 格式校验 — 纯数字 `X.Y.Z`，拒绝人机校验页面
- 日志：`[host] New version X.Y.Z available on github`（仅新版本时）

**附带修复**:
- `src/main.zig` comptime 块加 `@import("host.zig")` → 7 个遗漏测试生效

## Phase 70: `--status` 增强 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 330 | GuestEntry 加 role 字段：struct + upsertGuest + deinit + removeGuest | ✅ |
| 331 | handleStatus JSON 输出全部 9 字段（+role/+status/+last_seen） | ✅ |
| 332 | host.zig：tunnelManager 移除 role:host 过滤 + Host 自注册 + cmdStatus 表格 + cmdVerify 跳过 Host | ✅ |
| 333 | formatStatusMCP markdown 加 role/status | ✅ |

### 变更摘要

**GuestEntry 加 role 字段** (`src/httpd.zig`):
- `role: []const u8` — "host" | "guest" 标识节点类型
- `upsertGuest()` 签名加 `role` 参数，update/insert 路径均处理
- `deinit()` / `removeGuest()` 释放 role 内存

**handleStatus 完整字段** (`src/ipc.zig`):
- JSON 从 6 字段扩展到 9 字段：hostname, role, target, ip, mac, version, shell, status, last_seen

**Host 自注册 + 过滤移除** (`src/host.zig`):
- `startHost()`：mesh 初始化后 upsertGuest 写入 Host 自身（role=host, MAC=全零）
- `tunnelManager`：移除 `role == "host" continue` 过滤
- `upsertGuest` 调用传递 role 参数

**cmdStatus 表格更新** (`src/host.zig`):
- 加 Role、Status、Last 三列（8 列紧凑单行）
- last_seen 使用相对时间格式化（now/Ns/Nm/Nh/Nd）

**cmdVerify 跳过 Host** (`src/host.zig`):
- Host 无自身 KCP 隧道，ping/exec 必然失败 → 跳过 role=host 的条目

**formatStatusMCP 更新** (`src/mcp.zig`):
- 每个节点显示 role 标签：`**hostname** (role) — ...`
- 加 status 字段：`| status: serving`

## Phase 69: 开发效率提升 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 326 | 二进制类型校验 — selfCopy 前检查文件魔数 | ✅ |
| 327 | `--verify` 健康检查命令 | ✅ |
| 328 | `--deploy` 一键部署命令 | ✅ |
| 329 | `deploy` Claude Code skill | ✅ |

### 变更摘要

**Task 326 — 二进制类型校验** (`src/svc.zig`):
- 新增 `validateBinaryType()` 函数：读二进制前 4 字节，比较平台魔数
- 新增 `describeBinary()` 辅助函数：魔数 → 可读格式名称
- 在 `selfCopy()` 中调用，复制前验证平台匹配
- 魔数常量：ELF `\x7fELF`、Mach-O `\xcf\xfa\xed\xfe`、PE `MZ`
- 10 个新测试（describeBinary 7 + magic constants 3）
- 防止 ELF-on-macOS 类部署错误

**Task 327 — `--verify` 健康检查** (`src/main.zig`、`src/host.zig`):
- 新增 `--verify` CLI 命令
- 对全部在线 Guest 执行三重检查：Status（LSA 在线）+ Ping（mesh 可达）+ Exec echo（隧道+shell 正常）
- ANSI 彩色矩阵输出（绿✓/红✗/黄−）
- 任一检查失败 → exit(1)；全部通过 → exit(0)

**Task 328 — `--deploy` 一键部署** (`src/main.zig`、`src/host.zig`):
- 新增 `--deploy [TARGET]` CLI 命令
- 硬编码 4 VM 配置表（linuxvm/macvm/windowsvm/winx64）
- 自动交叉编译 → sshpass+scp 上传 → sshpass+ssh 安装
- Windows 目标跳过 SCP/SSH（提示手动步骤）
- 成功/失败计数摘要输出
- 依赖 `sshpass`（检查并提示安装）

**Task 329 — deploy skill** (`.claude/skills/deploy/SKILL.md`):
- VM 配置表 + 部署流程文档
- macOS bootstrap 常见问题处理（errno=5/2、codesign）
- 手动/自动部署两种方式
- 安全注意事项

### 性能影响
- 无运行时开销（所有新增代码仅在 CLI 管理命令中执行）
- `validateBinaryType` 仅在 `selfCopy` 时调用，读 4 字节
- `--verify` 串行检查每台 Guest（ping + exec echo），~5s/台

## Phase 68: 修复 LSA restart 误判 (Finding 124) (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 325 | 实现 nonce 比较替代全 node_info 字符串比较 | ✅ |

### 修复摘要

**根因**: LSA restart 检测用全 node_info 字符串比较，但 `status:serving↔upgrading` 变化被误判为进程重启 → KCP 会话被杀 → 隧道循环断开。这是自毁循环：升级第一步（改 status）就断了升级需要的隧道。

**fix**: `nonceChanged()` 用 nonce 比较替代全字符串比较；`updateNodeInfo()` 自动重新附加 nonce 保身份不丢失；`parseEpoch()` 兼容 `nonce:` 和 `epoch:` 键名。

**测试**: 149/149 通过

## Phase 67: v0.11.17 部署 + 自动升级测试 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 320 | Bump 版本 v0.11.16→v0.11.17 | ✅ |
| 321 | 构建 8 目标 + 149/149 tests | ✅ |
| 322 | Host v0.11.17 部署 | ✅ `launchctl bootstrap` errno=2，kickstart 恢复 |
| 323 | 自动升级观察 | ❌ 全部失败 — 4 台 Guest 下载成功，但 `--install` 均未生效 |
| 324 | 手动升级 + 功能验证 | ✅ linuxvm (SCP+--install)、macvm (kickstart)、Windows (SCP+--install) |

### 自动升级问题汇总

| Guest | 下载 | --install | 最终状态 | 根因 |
|-------|------|-----------|---------|------|
| linuxvm | ✅ (8MB) | ❌ 无声失败，无日志 | 手动 SCP 恢复 | receiveUpgradeFile 未完成；Journal 停止 |
| macvm | ✅ (4MB, 第3次) | ⚠️ 成功但服务停止 | 手动 kickstart | Finding 123: exit(0)+KeepAlive |
| windowsvm | ✅ (3.5MB) | ❌ --install 未生效 | 手动 SCP 恢复 | 待调查 |
| winx64 | ✅ (3.6MB) | ❌ --install 未生效 | 手动 SCP 恢复 | 待调查 |

### 关键 Bug 发现

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 123 | 🔴 CRITICAL | macOS 自动升级后服务永久停止 |
| 124 | 🔴 | 非 Linux Guest 隧道不稳定，exec 失败 |
| 125 | 📋 | `nowMs()` RTT 中继路径异常 |
| 126 | 📋 | DebugAllocator 泄漏（仅 debug 构建） |
| 127 | 📋 | linuxvm 日志停止 + 升级无声失败 |
| 128 | 📋 | macOS bootstrap errno=5 在 bootout 后 |

### 功能验证 (手动升级后)

| Guest | exec | upload | download |
|-------|------|--------|----------|
| linuxvm | ✅ | ✅ | ✅ |
| macvm | ❌ exit=-1 | — | — |
| windowsvm | ✅ | — | — |
| winx64 | ❌ exit=-1 | — | — |

## Phase 66: 小修复收尾 ✅ (2026-07-27)

| # | 任务 | 状态 | 提交 |
|---|------|------|------|
| 1 | `upload_result` (0x17) handler | ✅ 已存在（commit `98409c4`）| — |
| 2 | RTT → 真实毫秒 | ✅ `nowMs()` 替代 ping/pong 时钟 | `3c6d7d4` |
| 3 | macOS codesign 重签 | ✅ EXDEV 回退路径加 `codesign --force --sign -` | `3c6d7d4` |
| 4 | 多网卡 LSA 广播可达性 | ✅ 每 30s 回调刷新广播地址列表 | `3c6d7d4` |

**已取消**: httpd.zig 测试编译（httpd 已废弃）、Windows 优雅退出 Finding 103（永久延迟）

## Phase 61-65 摘要

### Phase 61: 删除 HTTP 协议 → KCP+IPC ✅
HTTP 服务器全面删除。端口 2121 仅保留 UDP（mesh LSA + KCP tunnel）。CLI/MCP 走 IPC socket（`/var/run/utmm.sock`）。httpd.zig 1750→680 行（-61%）。

### Phase 62: Windows IPC 编译修复 + 全量部署 ✅
修复 Zig 0.16.0 Windows Named Pipe API 移除（手动 `extern "kernel32"` + `callconv(.winapi)`）。8 目标全通过，4 Guest 全量功能验证通过（status/ping/exec/upload/download）。

### Phase 63: Guest 自主升级 ✅
v0.11.12: Guest 检测版本不匹配 → `upgrade_req` → KCP 下载 → `--install`。
v0.11.13: 移除 Host 推送升级代码（~223 行），Host 仅响应 `upgrade_req`。
v0.11.14: 修复命令循环死锁 — 升级检查需在内外两层循环都存在（Finding 120）。

### Phase 64: 文档重写 + v0.11.15 ✅
SKILL.md + MANUAL.md 全面更新至 v0.11.14 代码现状。发布 v0.11.15 后发现 IP gating bug 阻止自动升级。

### Phase 65: install.sh + install.bat + v0.11.16 ✅
跨平台一键安装脚本（POSIX 272 行 / Windows 332 行）。v0.11.16 附带 IP gating 修复（`mesh.zig` 移除 `host_gateway_ip` 依赖）。全部 Guest 手动升级至 v0.11.16。

## 历史阶段 (Phase 50-60)

| Phase | 关键成果 |
|-------|---------|
| 50 | 加固审计：20 修复（Finding 68-79） |
| 51 | 文件合并 19→13、API 适配 Zig 0.16.0、测试 +52% |
| 52 | CLI auto-ensure：管理命令自动启动 Host 服务 |
| 53 | MCP stdio JSON-RPC + `utmm.lock` PID 文件单例锁 |
| 54 | Host 重启 exec 空输出修复：6 协同 bug（0xFF keepalive 污染、peekSize/recv 不对称等） |
| 55 | Windows 服务停止：signalShutdown 不提前关 socket、pty 管道 CloseHandle |
| 56 | 回归测试 + Windows 硬停止（放弃优雅退出） |
| 57 | `--ping` 命令：mesh ping/pong（11B direct / 18B relayed） |
| 58 | file_chunk MSS 对齐 8KB→1200B + 关键代码注释 |
| 59 | macOS plist StandardErrorPath 回归修复 |
| 60 | 清理 HTTP POST 端点 + fallback 函数死代码 |

## 最近提交

```
14896a9 v0.11.17: fix serveUpgradeFile @memcpy alias crash, deployment test findings
54c3376 docs: fix outdated architecture references and clean up planning files
3c6d7d4 feat: RTT real ms, macOS codesign re-sign, multi-NIC broadcast refresh
b5bc849 docs: mark Phase 66 complete, update planning files
3006806 fix: replace host_gateway_ip with self-role check in epoch tracking
a94b6a7 v0.11.16: install.sh + install.bat, fix auto-upgrade IP gating bug
```
