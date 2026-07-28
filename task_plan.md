# Task Plan: v0.12.1

## 架构概述

UTM Monitor (`utmm`) — 单二进制双模式（Guest/Host），Mesh LSA + KCP 隧道为唯一 Guest-Host 传输层。
自复制安装模型：二进制从任意路径运行，强制覆盖安装到 `/opt/utmm/utmm`（POSIX）/ `C:\opt\utmm\utmm.exe`（Windows）。

**关键设计决策：**
- KCP Tunnel 为唯一 Guest-Host 传输层（v0.11.0 删除 WebSocket）
- Host 和 Guest 均为系统自动启动服务
- 自复制模型：升级 = 新版本 `--install`（v0.12.0）
- **Guest 自主升级**（v0.11.14）：Guest 检测 LSA 版本不匹配 → KCP 下载 → `--install`。Host 永不推送
- **一键安装脚本**（v0.11.16）：`install.sh`/`install.bat` 交互式跨平台安装/升级
- 端口 2121 UDP only（mesh LSA + KCP tunnel），CLI/MCP 走本地 IPC socket
- Fast-fail 错误处理，所有操作要求 root/Administrator

## 活跃 VM

| VM | Hostname | OS | IP | 凭据 | 路径 |
|----|----------|-----|----|------|------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## 当前状态

- **版本**: v0.12.1（唯一来源 `src/ver.txt`，`@embedFile` 编译期嵌入）
- **`build.zig.zon`**: `0.0.0`（永不再改）
- **源文件**: 18 个（`src/*.zig`）+ 1 版本文件（`src/ver.txt`）+ 2 skills（`zig`、`deploy`）
- **测试**: 166/166 通过
- **部署**: macOS Host v0.12.1 ✅ | linuxvm v0.12.1 ✅ | macvm v0.12.1 ✅ | windowsvm v0.12.1 ✅ | winx64 v0.12.1 ✅
- **健康检查**: 4/4 Guest 在线，全部 v0.12.1，exec/ping 正常
- **8 交叉编译目标**: aarch64/x86_64/x86 × linux-musl/macos/windows

## 已完成阶段

| Phase | 日期 | 内容 |
|-------|------|------|
| 50 | 2026-07-26 | 加固优化全面审计（20 个修复） |
| 51 | 2026-07-26 | 19→13 文件合并，127→193 测试 (+52%) |
| 52 | 2026-07-26 | CLI auto-ensure + 管理命令行为矩阵 |
| 53 | 2026-07-26 | MCP stdio + utmm.lock 进程单例锁 |
| 54 | 2026-07-26 | Host 重启 exec 空输出修复（6 协同 bug：0xFF keepalive 污染等） |
| 55 | 2026-07-27 | Windows 服务停止卡死修复（3 断裂点） |
| 56 | 2026-07-27 | 回归测试 + Windows 硬停止（放弃优雅退出，Finding 103 永久延迟） |
| 57 | 2026-07-27 | `--ping` 命令 + ping/pong mesh 协议（11B direct / 18B relayed） |
| 58 | 2026-07-27 | file_chunk MSS 对齐（8KB→1200B），消除 KCP 二次分片 |
| 59 | 2026-07-27 | macOS plist StandardErrorPath 回归修复 |
| 60 | 2026-07-27 | 清理 HTTP POST 端点死代码 |
| 61 | 2026-07-27 | **彻底删除 HTTP 协议**，全面转向 KCP+IPC |
| 62 | 2026-07-27 | Windows IPC 编译修复 + 全量部署测试（8 目标全通过） |
| 63 | 2026-07-27 | Guest 自主升级（v0.11.12→v0.11.14，修复命令循环死锁） |
| 64 | 2026-07-27 | 文档重写（SKILL.md + MANUAL.md）+ v0.11.15 发布 |
| 65 | 2026-07-27 | install.sh + install.bat + v0.11.16 发布 + IP gating bug 修复 |
| 66 | 2026-07-27 | RTT 真实毫秒 (`nowMs()`)、macOS codesign 重签、多网卡广播刷新 |
| 67 | 2026-07-27 | v0.11.17：修复 `serveUpgradeFile` `@memcpy alias` crash + 自动升级全流程测试 |
| 68 | 2026-07-27 | v0.11.18：修复 LSA restart 误判 — nonce 比较替代全 node_info 字符串比较 |
| 69 | 2026-07-27 | ✅ 开发效率提升：二进制类型校验 + 一键部署 + 健康检查 + deploy skill |
| 70 | 2026-07-27 | `--status` 增强：全部字段 + Host 显示 + role 字段区分 host/guest |
| 71 | 2026-07-28 | 版本号单文件管理 + GitHub 新版本检测（OS线程 fire-and-forget） |
| 72 | 2026-07-28 | 自动升级 rollback 修复 + 全流程部署测试 |
| 73 | 2026-07-28 | KCP Tunnel 稳定性 + 下载性能修复（Finding 129 + 138） |
| 74 | 2026-07-28 | 自动升级 forceInstall 修复（Finding 123 + 135 + 139） |
| 75 | 2026-07-28 | utmmd 监督进程架构重构（shm + utmmd + svc 简化 + 安装优化） |
| 76 | 2026-07-28 | macOS launchctl 遗留修复 + 文档全面更新（Task 382-385） |
| 77 | 2026-07-28 | 安装脚本测试 + install.bat 双 bug 修复 + install.sh 同步修复（Task 386-391） |
| 78 | 2026-07-28 | **紧急修复**: serve-dir 版本不匹配自动 uninstall 自毁 + 全节点升级 v0.12.1 |

## Phase 78: serve-dir 版本不匹配自动 uninstall 修复 + 全节点部署 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 392 | 排查 Host 二进制 SIGKILL | 旧 utmmd 被杀后新二进制立即被 SIGKILL，1 秒内三文件全部消失 | ✅ |
| 393 | 定位根因 | `verifyServeDirBinaries` 版本不匹配 → `svc.uninstall()` 自毁 | ✅ |
| 394 | 代码修复 | `src/host.zig`: 移除 `svc.uninstall()`+`exit(1)`，改为 warn + continue | ✅ |
| 395 | 次要发现 | `copySiblingBinariesToServeDir` 在 src==dest 时跳过，平台文件永不更新 | ✅ |
| 396 | linuxvm 升级 | SSH 手动 `--install` → v0.12.1，exec 恢复正常 | ✅ |
| 397 | winx64 升级 | SSH PowerShell kill + reinstall → v0.12.1，exec 恢复正常 | ✅ |
| 398 | macvm 升级 | SSH `--install`（killAllUtmm 杀僵死进程）→ v0.12.1，exec 恢复正常 | ✅ |
| 399 | windowsvm 升级 | SCP 新二进制 + reinstall → v0.12.1，exec 恢复正常 | ✅ |
| 400 | serve-dir 平台文件 | 8 个 v0.12.1 平台二进制文件复制到 `/opt/utmm/` | ✅ |
| 401 | 文档更新 | task_plan.md + findings.md + progress.md + CLAUDE.md | ✅ |

### 变更摘要

- **`src/host.zig:776-783`**: `verifyServeDirBinaries` 失败时不再调用 `svc.uninstall()` → `exit(1)`。改为 `_ = verifyServeDirBinaries(block_io, sd)` — 警告但继续运行
- **根因**: 从 canonical path 执行 `--install` 时，`selfCopy` 和 `copySiblingBinariesToServeDir` 都检测到 src==dest 并跳过，平台二进制文件永远停留在旧版本。Host 启动时发现版本不匹配 → 自毁
- **Guest pty 丢失**: Host 重启后旧 Guest 进程保留但 pty 已失效，需重新 `--install` 来重建 KCP 隧道 + pty

## Phase 72: 自动升级 rollback 修复 + 全流程部署测试 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 339 | rollback 修复 | `forceInstallInternal()` 步骤 5 删除回滚逻辑，启动失败保留二进制+配置 | ✅ |
| 340 | v0.11.21→v0.11.23 构建 | 三次 bump 版本，构建 8 目标，部署 Host | ✅ |
| 341 | macvm 自动升级测试 | 下载成功，launchctl bootstrap errno=2，二进制+配置保留（新代码），手动恢复 | ✅ |
| 342 | linuxvm 自动升级测试 | 下载成功但 selfCopy 未更新规范路径二进制（已有 bug），手动修复 | ✅ |
| 343 | windowsvm 自动升级测试 | 下载完成 install 失败，优雅回退到旧版本 | ✅ |
| 344 | winx64 自动升级测试 | 未检测到升级信号，仍运行旧版本 | ✅ |

### 变更摘要

**`src/svc.zig` — forceInstallInternal() 步骤 5**:
- 删除 start 失败时的回滚逻辑（uninstallServiceConfig + deleteFile）
- 改为保留二进制和配置，仅日志 err + fail.err 退出
- 理由: 自动升级时旧进程已被 kill，删除一切 = VM 彻底失联

### 测试结论

**rollback 修复验证成功** — macvm 场景是最好证明：
- launchctl bootstrap 失败后，旧代码会删除二进制+plist → VM 失联
- 新代码保留二进制+配置 → 系统级恢复机制（重启、手动启动）仍可用

**发现 5 个已有/新问题**（见 findings.md Finding 135-139），均非本次修改引入。

## Phase 73: KCP Tunnel 稳定性 + 下载性能修复 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 345 | Finding 138 修复 | 3 条 KCP 数据包日志 info→debug，消除 ~15KB/s 性能瓶颈 | ✅ |
| 346 | Finding 129 修复 | 生成计数器唯一 conv + 移除旧 session 销毁 + epoch 范围验证 + 死 session 清理 | ✅ |
| 347 | waitForHostTunnel 修复 | sessions_mutex 移到 Tunnel.init() 之后，消除 UAF 窗口 | ✅ |
| 348 | tunnel.deinit 修复 | 加 closeSession() 调用，消除 session 泄露 | ✅ |
| 349 | 测试 + 部署验证 | 166/166 测试通过，Host + macvm + linuxvm 部署，exec 验证 | ✅ |

### 变更摘要

**`src/mesh.zig`**:
- 3 条日志 `std.log.info` → `std.log.debug`：`[mesh-kcp] recv`、`[mesh-kcp] peek`、`[mesh] kcp_output`
- 新增 `session_gen: u32` 字段，`connect()` 使用 `base_conv + session_gen` 产生唯一 conv
- 移除 `connect()` 中对同一 dest 旧 session 的销毁（UAF 根因）
- epoch 检查改为范围验证 `diff < 256`（两处：`handleKcpData` + `handleLsa`）
- `periodicTasks()` 增加孤立死 session 清理（60s 保险机制）

**`src/broadcast.zig`**:
- `waitForHostTunnel()`: sessions_mutex 解锁移到 `Tunnel.init()` 之后

**`src/tunnel.zig`**:
- `deinit()` 调用 `mesh.closeSession()` 正确释放 session

### 验证结果

| 测试 | 修复前 | 修复后 |
|------|--------|--------|
| macvm exec | exit=-1（几乎每次） | **4/4 成功** |
| linuxvm exec | 正常 | 正常（无回归） |
| macvm 文件上传 | 不稳定 | 成功 |
| Host 日志增长 | ~96MB/数分钟 | ~3.5KB/10 秒 |

## Phase 74: 自动升级 forceInstall 修复 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 350 | Fix A: killAllUtmm PID 感知 | pgrep/tasklist 枚举 PID → 过滤自身 → kill -9 每个（Finding 139） | ✅ |
| 351 | Fix B: waitForProcessExit | stop 后轮询等待进程退出（5s 超时/100ms 间隔），防 Text file busy（Finding 135） | ✅ |
| 352 | Fix C: macOS start() 重试 | kickstart 失败后 500ms 延迟 + bootstrap 3 次重试（间隔 1s）（Finding 123） | ✅ |
| 353 | Fix D: exit(0) → exit(42) | applyUpgradeAndRestart 非零退出码触发 launchd/systemd 可靠重启 | ✅ |
| 354 | 编译 + 测试 | zig build ✅，166/166 测试通过 ✅ | ✅ |

### 变更摘要

**`src/svc.zig`**:
- `getOwnPid()` — 跨平台获取自身 PID
- `killAllUtmm()` 重写 — pgrep/tasklist PID 枚举替代 pkill/taskkill /im，排除自身 PID
- `countOtherUtmmProcesses()` + `waitForProcessExit()` — stop 后轮询等待，防 Linux Text file busy
- `forceInstallInternal()` — 步骤 1.5 插入 waitForProcessExit
- `start()` macOS — kickstart 失败后 500ms 延迟 + bootstrap 3 次重试（1s 间隔）+ verify 前 500ms 延迟

**`src/broadcast.zig`**:
- `applyUpgradeAndRestart()` — `exit(0)` → `exit(42)`，非零退出码触发服务管理器可靠重启

### 未包含

- **Finding 136** (winx64 LSA 信号): 网络隔离问题（192.168.3.x vs 64.x/65.x），非代码 bug
- **Finding 137** (windowsvm install): Windows .exe 文件锁定机制，需单独设计

## Phase 75: utmmd 监督进程架构重构 ✅ (2026-07-28)

### 背景

Phase 72-74 修复了自动升级的 5 个 bug，但这些都是治标。根本问题在于**架构设计错误**：

```
当前模型：系统服务管理器（launchd/systemd/SCM）→ 保活 → utmm（直接作为服务）
                              ↑_____ 启动权冲突 _____↑
升级时：utmm-new → stop → kill → copy → start
        系统服务管理器在 stop 和 start 之间可能自行重启服务
```

**核心矛盾**：应用生命周期管理权分散在两个地方——系统服务管理器（保活）和 utmm 自身（升级时 stop→start），导致启动权冲突。

### 解决方案

引入 `utmmd` 监督进程层，将生命周期管理从系统服务管理器中完全剥离：

```
新模型：launchd/systemd/SCM →（仅开机启动，不保活）→ utmmd →（完全控制）→ utmm
```

### 决议

| # | 决议 | 理由 |
|---|------|------|
| R1 | utmmd 自身不需要系统保活 | 生命周期管理必须在唯一一处，否则等于没改 |
| R2 | IPC 用共享内存（mmap/CreateFileMapping） | Guest OS 兼容性最好，零拷贝、无序列化开销 |
| R3 | 检测到升级可用时**立即**升级 | 版本不一致会带来不可预期的行为 |
| R4 | 服务名称简化为单一 "utmmd" | 同一台机器 Guest/Host 互斥，后安装覆盖前者 |
| R5 | 监督进程命名为 `utmmd` | 简短、Unix 守护进程命名传统 |
| R6 | **不考虑向后兼容** | 软件在快速迭代阶段 |

### 架构设计

```
┌──────────────────────────────────────────────────┐
│ 系统服务管理器 (launchd/systemd/SCM)               │
│ - 开机启动 only，NO keep-alive/auto-restart       │
│ - 服务名: "utmmd" (单一名称)                      │
│ - 二进制: /opt/utmmd/utmmd                       │
└──────────────────┬───────────────────────────────┘
                   │ start/stop
                   ▼
┌──────────────────────────────────────────────────┐
│ utmmd (监督守护进程)                              │
│ - 创建共享内存区域                                │
│ - 启动/停止/监控 utmm 子进程                      │
│ - 按退避算法重启（1s→2s→4s→8s→16s→32s→退出）     │
│ - 处理升级命令（kill→替换二进制→重启）            │
│ - 信号处理（SIGTERM→kill utmm→cleanup→exit）      │
│ - Windows SCM 分发                               │
└──────────────────┬───────────────────────────────┘
                   │ mmap 共享内存 IPC
                   │ 启动/杀掉/监控
                   ▼
┌──────────────────────────────────────────────────┐
│ utmm (应用程序二进制)                             │
│ - /opt/utmm/utmm                                 │
│ - Guest 或 Host 模式                             │
│ - 连接共享内存、更新心跳                          │
│ - 发送升级/重启/关闭命令                          │
└──────────────────────────────────────────────────┘
```

### 共享内存协议 (shm.zig)

```
Layout: 4096 字节（一页）

偏移    大小   字段            方向        说明
0       4      magic           -          0x55544D44 ("UTMD")
4       4      version         -          协议版本=1
8       4      svc_state       utmmd 写   0=init 1=running 2=stopping
12      4      utmm_state      utmm 写    0=starting 1=running 2=stopping 3=upgrading
16      4      utmm_pid        utmmd 写   utmm 进程 PID
20      4      svc_pid         utmmd 写   utmmd 自身 PID
24      8      svc_heartbeat   utmmd 写   单调时钟 ms
32      8      utmm_heartbeat  utmm 写    单调时钟 ms
40      4      cmd             utmm 写    0=none 1=restart 2=upgrade 3=shutdown
44      4      cmd_status      utmmd 写   0=pending 1=accepted 2=done 3=failed
48      4      restart_count   utmmd 写   utmm 累计重启次数
52      4      last_exit_code  utmmd 写   utmm 上一次退出码
56      4      backoff_sec     utmmd 写   当前重试延迟（秒）
60      4      failure_count   utmmd 写   连续启动失败次数
64      1024   cmd_data        utmm 写    命令附加数据（升级二进制路径）
1088    3008   _reserved       -          保留
```

### 保活退避算法

```
failure_count = 0, backoff = 1s
loop:
  start utmm
  wait STABILITY_THRESHOLD=10s（utmm 持续运行算稳定）
  
  if stable:
    failure_count = 0, backoff = 1s
    monitor: 检查心跳 + 处理命令 + 检测进程退出
  
  else (启动失败/快速崩溃):
    failure_count += 1
    if failure_count > 5: exit(1)  // 放弃
    backoff = min(backoff * 2, 60)
    sleep(backoff)
    goto loop
```

重试序列：1s → 2s → 4s → 8s → 16s → 32s → 超过5次→退出

### 升级流程

```
1. utmm 检测版本不匹配 (LSA)
2. utmm 通过 KCP 下载新二进制到 /opt/utmm/.utmm-upgrade-XXXXX
3. utmm 写 cmd_data = 升级路径
4. utmm 写 cmd = CMD_UPGRADE(2), utmm_state = UPGRADING
5. utmmd 检测 cmd == CMD_UPGRADE
6. utmmd 写 cmd_status = ACCEPTED
7. utmmd kill utmm (SIGKILL / TerminateProcess)
8. utmmd 等待进程退出确认
9. utmmd rename 新二进制 → /opt/utmm/utmm
10. utmmd chmod +x (POSIX)
11. utmmd 启动新 utmm
12. 新 utmm 挂载共享内存 → utmm_state = RUNNING
13. utmmd 写 cmd = NONE, cmd_status = DONE
```

### 安装流程

```
utmm --install --hostname myvm [--host]

1. selfCopy utmm → /opt/utmm/utmm（总是执行，utmm 版本必然变化）

2. 判断 utmmd 是否需要更新（三条件任一满足即需要）：
   a. /opt/utmmd/utmmd 不存在（首次安装）
   b. SHA256(已安装 utmmd) ≠ SHA256(内嵌 utmmd)（utmmd 版本变化）
   c. 已安装的服务配置 ≠ 将写入的配置（参数变化）

3a. 如需更新 utmmd：
    3a.1 stop utmmd 服务（忽略未运行的错误）
    3a.2 kill utmm 进程（防止旧 utmm 与新 utmmd 状态不一致）
    3a.3 提取内嵌 utmmd → /opt/utmmd/utmmd
    3a.4 chmod +x（POSIX）
    3a.5 写入服务配置（无保活，仅开机启动）
    3a.6 start utmmd 服务
    3a.7 utmmd 启动 utmm

3b. 如无需更新 utmmd（仅 utmm 版本变化）：
    3b.1 检查 utmmd 是否在运行
    3b.2 如未运行 → start utmmd 服务
    3b.3 如已运行 → 打开共享内存，写 cmd=CMD_RESTART
    3b.4 utmmd kill 旧 utmm + 启动新 utmm
```

**优化效果**：utmmd 稳定后，绝大多数 `--install` 只走 3b 路径——不触发系统服务管理器操作，无权限弹窗、无启停竞态。

**比对数据存储**：复用现有 `/opt/utmm/utmm.conf` 配置文件，新增两个字段：
```
utmmd_sha256=<hex>    # 上次安装的 utmmd 二进制 SHA256
utmmd_args=<params>   # 上次安装的 utmmd 服务参数
```
`loadConfig()` 当前是桩函数（返回默认值），Phase 75 中实现基本的 key=value 解析。`saveConfig()` 追加 utmmd 字段。安装时读取比对，全量更新后回写新值。

### 卸载流程

```
utmm --uninstall
1. stop utmmd 服务
2. killAllUtmm + killAllUtmmd
3. remove utmmd 服务配置（plist/systemd/sc）
4. delete /opt/utmmd/ 目录
5. delete /opt/utmm/ 目录
```

### 服务配置（无保活，仅开机启动）

| 平台 | 关键配置 |
|------|---------|
| macOS | `RunAtLoad=true`, 无 `KeepAlive` |
| Linux | `Type=simple`, 无 `Restart=` |
| Windows | `start=auto`, `sc failure` actions 为空 |

### 文件结构变更

```
src/
├── shm.zig        ← 新增：共享内存协议（utmmd 与 utmm 共用）
├── utmmd.zig      ← 新增：监督进程入口 (~350行)
├── svc.zig        ← 修改：简化为纯 OS 服务配置管理（无保活，单名称 "utmmd"）
├── main.zig       ← 修改：shm 连接 + 新 install/uninstall 流程
├── broadcast.zig  ← 修改：升级流程改为 shm 驱动（替代自执行 --install）
├── build.zig      ← 修改：两步构建（utmmd 先编译，@embedFile 嵌入 utmm）
其他文件不变
```

### 任务列表

| # | 任务 | 描述 | 依赖 | 状态 |
|---|------|------|------|------|
| 355 | 创建 `src/shm.zig` | 跨平台共享内存协议：ShmLayout(4096B) + create/open/close + 平台适配（POSIX shm_open/mmap, Windows CreateFileMapping/MapViewOfFile） | - | ✅ |
| 356 | 创建 `src/utmmd.zig` | utmmd 监督进程完整实现：monitorLoop + backoff 退避 + 信号处理 + Windows SCM 分发 | 355 | ✅ |
| 357 | 修改 `src/svc.zig` | 简化为纯 OS 服务管理：删保活配置、删 retry counter、删 winServiceRun、删 checkPendingUpgradeWindows、服务名 → "utmmd"、新增 canonicalSvcPath/extractUtmmd/shouldUpdateUtmmd（hash比对 + utmm.conf 配置比对） | 355 | ✅ |
| 358 | 修改 `src/main.zig` | 启动时挂载 shm + 心跳协程 + install 流程（3a 全量/3b 仅重启两条路径）+ uninstall 清理 utmmd | 355, 357 | ✅ |
| 359 | 修改 `src/broadcast.zig` | 升级流程改为 shm 驱动：写 cmd_data(路径) + cmd=UPGRADE → exit(0)，移除 applyUpgradeAndRestart | 355 | ✅ |
| 360 | 修改 `build.zig` | 两步构建：utmmd 先编译 → 复制到 src/embed/utmmd.bin → utmm @embedFile + .gitignore embed/ | 356 | ✅ |
| 361 | 编译 + 测试 | zig build + zig build test 全部通过 | 355-360 | ✅ |
| 376 | 安装优化 3b 路径 + config 持久化 | hash 比对 + utmm.conf 读写 + 3a/3b 双路径 + SHA256 构建期预计算 | 361 | ✅ |
| 362 | 部署验证 | Host + linuxvm + macvm 部署测试，验证 3a/3b 两条安装路径 | 376 | 📋 待部署 |

### 实现总结

**完成时间**: 2026-07-28，Tasks 355-361 + 376 全部完成。

**代码变更量**:
| 文件 | 变更类型 | 行数 |
|------|---------|------|
| `src/shm.zig` | 新建 | ~400 行 |
| `src/utmmd.zig` | 新建 | ~600 行 |
| `src/svc.zig` | 重构 | -440/+340 行（净减 ~100） |
| `src/main.zig` | 修改 | +210/-50 行 |
| `src/broadcast.zig` | 修改 | +50/-90 行 |
| `src/host.zig` | 清理 | -1 行 |
| `build.zig` | 修改 | +30 行 |

**关键实现细节**:
- **shm.zig**: Zig 0.16.0 移除了 `posix.O`/`posix.mmap`/`posix.munmap` 的跨平台封装，改用原始 `extern "c"` 函数 + POSIX 常量绕过平台差异。`shm.open()` 返回 `*volatile ShmLayout`（mmap 映射的内存）。
- **utmmd.zig**: macOS 信号处理用自定义 `c_sigaction` extern struct（`SIG_IGN` sentinel 需 `*align(1)` 类型）。`init.gpa` 替代已移除的 `GeneralPurposeAllocator`。Windows SCM `SERVICE_TABLE_ENTRYW` 手动声明。
- **svc.zig**: 服务名统一为 `utmmd`（`com.utmmd`/`utmmd`/`UTM-MonitorD`），plist 移除 `KeepAlive`，systemd 移除 `Restart=`，Windows 移除 `sc failure`。存根函数（`checkRetryLimit` 等）在 Task 373 完成后已清理。Task 376 新增：`shouldUpdateUtmmd`、`saveUtmmdMeta`、`readConfigValue`、`writeConfigValue`、`fileSha256Hex`、`buildArgsString`。
- **main.zig**: `@embedFile("embed/utmmd.bin")` + `@embedFile("embed/utmmd.sha256")` 编译期嵌入 ~2.1MB utmmd 二进制及其 SHA256 哈希。`extractUtmmd` 在 `--install` 时强制写入，`extractUtmmdIfMissing` 在 `ensure` 时按需写入。`--svc` 路径：打开 shm → 设置 PID/状态 → 心跳线程(1s) → 运行主循环 → 清理。Task 376 优化：3a（全量 forceInstall + saveMeta）/ 3b（仅 start() 跳过重装）双路径。
- **broadcast.zig**: `doAutoUpgrade` 下载新二进制后不再执行 `--install`，改为写 shm（`cmd=UPGRADE, cmd_data=临时路径`）后返回 `true`，外层循环检测后 `break` 退出。utmmd 接管重命名+重启。
- **build.zig**: `addSystemCommand("cp -f")` 替代 `addInstallBinFile`（后者写入 zig-out/ 而非源码树）。Task 376 新增 `shasum -a 256` 构建步骤预计算 utmmd SHA256，避免 comptime 哈希 >20M eval branch quota 问题。

**测试**: 全部 166 个测试通过，构建无警告。

## 待修复

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 136 | 🔴 | winx64 自动升级信号未检测到（网络隔离，待调查） |
| 137 | 🟡 | windowsvm 自动升级 install 失败，优雅回退 |
| 123 | ✅ 已修复 (Phase 74) | macOS 自动升级：killAllUtmm PID 感知 + start() 重试 + exit(42) |
| 128 | ✅ 已修复 (Phase 76) | macOS bootstrap errno=5：识别为 launchd throttle → startDirect 回退 |
| 135 | ✅ 已修复 (Phase 74) | linuxvm selfCopy：waitForProcessExit 等进程退出后再覆盖 |
| 139 | ✅ 已修复 (Phase 74) | Host 自 kill：killAllUtmm 排除自身 PID |
| 129 | ✅ 已修复 (Phase 73) | 非 Linux Guest 隧道不稳定：KCP 并发 connect() 导致会话状态不一致 |
| 138 | ✅ 已修复 (Phase 73) | KCP 自动升级下载性能瓶颈（~15KB/s，mesh 日志刷屏） |

## Phase 77: 安装脚本测试 + Bug 修复 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 386 | GitHub install.sh macOS Host 测试 | curl 管道安装（通过代理 127.0.0.1:7890），下载→解压→安装→验证 | ✅ |
| 387 | GitHub install.bat Windows Guest 测试 | SSH 远程部署测试，发现 2 个阻断 bug | ✅ |
| 388 | install.bat Bug 1 修复 | `del install.bat` 在 `--install` 前自我删除 → Windows cmd 无法继续执行 | ✅ |
| 389 | install.bat Bug 2 修复 | LF 换行 → `:resolve_binary` 标签无法解析，转换为 CRLF | ✅ |
| 390 | install.sh 同步修复 | 同样 premature self-deletion，移至安装成功后 | ✅ |
| 391 | windowsvm 全流程验证 | 离线安装→Guest 注册→v0.12.0 升级确认 | ✅ |

### 变更摘要

**`install.bat` — 两个阻断 bug 修复**:
- Bug 1: 第 302 行 `del /q install.sh install.bat 2>nul` 在 Guest 模式 file placement 阶段执行，早于第 319 行的 `--install` 命令。Windows cmd 删除自身后无法读取后续行 → "The batch file cannot be found."，安装命令从未执行。修复：移动 self-deletion 到安装成功后的第 338 行
- Bug 2: 文件使用 LF (`\n`) 换行而非 CRLF (`\r\n`)。Windows cmd 用 LF 可以执行简单命令，但 `call :label` 和 `goto :label` 的标签解析不可靠 → "The system cannot find the batch label specified - resolve_binary"。修复：`git add --renormalize` 强制 CRLF（`.gitattributes` 已配置 `install.bat text eol=crlf`）

**`install.sh` — 一致性问题修复**:
- 第 267 行 `rm -f install.sh` 同样在 `--install` 前自我删除。bash 将脚本读入内存故不受影响，但为一致性和良好实践，移至安装成功后

### 测试结果

**macOS Host（install.sh）**:
| 步骤 | 结果 |
|------|------|
| curl 代理下载脚本 | ✅ 127.0.0.1:7890 |
| 平台检测 (aarch64-macos) | ✅ |
| 下载 utmm.zip (19MB) | ✅ |
| 解压 11 文件 | ✅ |
| utmmd 注入 + launchd 注册 | ✅ |
| `--status` 确认 | ✅ Host + 4 Guest 在线 |

**Windows Guest（install.bat）**:
| 步骤 | 修复前 | 修复后 |
|------|--------|--------|
| `:resolve_binary` 标签 | ❌ 找不到 | ✅ |
| 离线模式检测 | ⚠️ ZIP_BINARY 为空 | ✅ |
| 自我删除 | ❌ 安装前删除自身 | ✅ 安装后清理 |
| `utmmd.exe` 注入 | ❌ 未执行 | ✅ 797KB |
| `UTM-MonitorD` 服务 | ❌ 未注册 | ✅ 运行中 |
| Guest 注册到 Host | ❌ | ✅ WIN-Q0JNGDDBE28 v0.12.0 |

## Phase 76: macOS launchctl 遗留修复 + 文档更新 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 382 | 诊断 launchctl bootstrap 失败 | 识别 launchd throttle 为根因（Finding 153），非代码 bug | ✅ |
| 383 | 修复 macOS launchctl 两个遗留问题 | enable 前置（bootout 前清 disabled flag）+ bootstrap 验证改用 launchctl list（不信任 exit code）+ 移除 legacy load 回退 | ✅ |
| 384 | macvm 部署验证 | 确认 fallback 路径正确工作：bootstrap 失败 → startDirect | ✅ |
| 385 | 更新所有过时文件 | CLAUDE.md（10 处）、README.md（4 处）、MANUAL.md（4 处）、SKILL.md（launchctl 注意事项）、memory 文件（删除 1 个、更新 3 个） | ✅ |

### 变更摘要

**`src/svc.zig` — installMacOS() 重排序**:
- `enable → bootout → bootstrap`：enable 必须在 bootout 之前（需要服务 label 存在于 launchd）
- bootstrap 改为 best-effort（不验证结果），真正的启动验证交给 `start()`

**`src/svc.zig` — start() macOS 路径重写**:
- kickstart 失败后：enable → bootout → bootstrap × 3（每次验证 launchctl list）
- bootstrap 全部失败 → startDirect（绕过 launchd，直接后台运行 utmmd）
- `launched_via_launchd` 标志：startDirect 场景跳过 launchctl list 验证
- 移除 legacy `launchctl load` 回退（exit 0 误导性）

**`src/shm.zig` — createPosix 重试**:
- 新增 retry 逻辑：首次 shm_open 失败后等 2s 重试
- launchd bootstrap 环境中 shm_open 可能瞬时失败

### 关键发现

| Finding | 描述 |
|---------|------|
| 153 | **launchd throttle**：同一 label 短时间反复 bootout/bootstrap 超阈值后，launchd 拒绝加载返回 EIO（exit 5），持续 5-10 分钟。新鲜 labels 工作完美 |
| 154 | **launchctl load exit 0 误导性**：load 失败打印 "Load failed: 5" 但返回 exit 0，`runCmd` 误判成功。代码已移除 legacy load 回退，改为 startDirect |
| 155 | **enable exit 64 无害**：首次安装（service 从未存在）或 throttle 期间 bootout 后，`enable system/<name>` 返回 exit 64（EX_USAGE）。仅表示无 disabled flag 需清除 |

## Phase 71: 版本号单文件管理 + GitHub 新版本检测 ✅ (2026-07-28)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 334 | `ver.txt` + `build.zig.zon` | 新建 `src/ver.txt`（0.11.18 无换行），`build.zig.zon` → `0.0.0` 永不动 | ✅ |
| 335 | `protocol.zig` @embedFile | `VERSION = "0.11.18"` → `@embedFile("ver.txt")` + comptime strip 换行 | ✅ |
| 336 | release.sh + install 适配 | `cp src/ver.txt release/`，install.sh/bat 动态读版本 | ✅ |
| 337 | GitHub 新版本检测 | `checkGitHubVersion()` OS 线程 fire-and-forget，5 次重定向，`isValidVersion()` 格式校验 | ✅ |
| 338 | 编译测试验证 | zig build ✅，166/166 测试通过 ✅ | ✅ |

### 变更摘要

- **`src/ver.txt`** 为版本号唯一来源 — `@embedFile` 编译期嵌入，`build.zig.zon` 永为 `0.0.0`
- **`checkGitHubVersion()`** — Host 启动时 spawn OS 线程，`std.http.Client` GET GitHub API
  - `redirect_behavior = .init(5)` — 跟随最多 5 次重定向
  - `isValidVersion()` — 严格校验 `X.Y.Z` 格式（纯数字），拒绝人机校验页面/HTML
  - 完全 fire-and-forget：detach 后不 join，失败静默返回
  - 日志：`[host] New version X.Y.Z available on github`（仅新版本时 warn）
- **`src/main.zig` comptime 块加 `host.zig`** — 其 7 个测试（Platform/genInit/isValidVersion）之前从未编译进测试二进制

## Phase 69: 开发效率提升 ✅

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 326 | 二进制类型校验 | `selfCopy` 前检查文件魔数（Mach-O / ELF / PE），拒绝错误平台 + 10 tests | ✅ |
| 327 | `--verify` 健康检查 | 对所有 Guest 执行 status + ping + exec echo，ANSI 彩色矩阵输出 | ✅ |
| 328 | `--deploy` 一键部署 | 读取 VM 配置，自动交叉编译→SCP→install→验证全流程，使用 sshpass | ✅ |
| 329 | `deploy` skill | Claude Code skill 封装部署流程，含 VM 表、常见问题、安全注意事项 | ✅ |

## Phase 70: `--status` 增强 ✅ (2026-07-27)

| # | 任务 | 描述 | 状态 |
|---|------|------|------|
| 330 | GuestEntry 加 role 字段 | httpd.zig: struct + upsertGuest + deinit + removeGuest | ✅ |
| 331 | handleStatus 完整字段 | ipc.zig: JSON 输出 +role/+status/+last_seen（6→9 字段） | ✅ |
| 332 | host.zig 四改 | tunnelManager 移除 role:host 过滤 + 传递 role；Host 自注册；cmdStatus 表格；cmdVerify 跳过 Host | ✅ |
| 333 | formatStatusMCP 更新 | mcp.zig: markdown 加 role/status 字段 | ✅ |

### 变更摘要

- **`GuestEntry` 加 `role` 字段**：`"host"` | `"guest"`，标识节点类型
- **`handleStatus` JSON 输出全部 9 字段**：hostname, role, target, ip, mac, version, shell, status, last_seen
- **Host 自注册到 guest table**：`startHost()` 中 mesh 初始化成功后 `upsertGuest(..., "host")`，MAC 全零
- **tunnelManager 移除 `role:host` 过滤**：Host 和 Guest 平等出现在状态列表中
- **`cmdStatus` 表格加 3 列**：Role, Status, Last（相对时间：now/Ns/Nm/Nh/Nd）
- **`cmdVerify` 跳过 Host**：Host 无自身隧道，ping/exec 会失败
- **`formatStatusMCP` 更新**：每行显示 `(role)` + `status:` 字段

### 验证

- 149/149 测试通过
- `--status`：Host + 4 Guest 全部显示，role/status/last 正确
- `--verify`：4 Guest 全绿 ✓，Host 正确跳过
- MCP `vm_status`：role 标签 + status 字段正确

