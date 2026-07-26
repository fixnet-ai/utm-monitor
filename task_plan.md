# Task Plan: v0.11.10

## 架构概述

UTM Monitor (`utmm`) — 单二进制双模式（Guest/Host），Mesh LSA + KCP 隧道为唯一 Guest-Host 传输层。自复制安装模型：二进制从任意路径运行，强制覆盖安装到固定路径。

**关键设计决策：**
- 删除 WebSocket，KCP Tunnel 为唯一传输层（v0.11.0）
- 统一服务模型：Host 和 Guest 均为系统自动启动服务（v0.12.0）
- 自复制模型：升级 = 新版本 `--install`，取消 utmm-old + agent.zig（v0.12.0）
- Fast-fail：不继续执行出错操作，打印错误退出
- 所有操作要求 root/Administrator（除 `--version`/`--help`）

## 活跃 VM

| VM | Hostname | OS | IP | 凭据 | 路径 |
|----|----------|-----|----|------|------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## 近期完成

### Phase 50: 加固优化全面审计 ✅ (2026-07-26)

对 13 个源文件全面审计，识别并修复 20 个安全/可靠性问题，分 5 个阶段实施：

- **Phase 0（清理）**: 删除 `src/host_http.zig`（1190 行死代码，零引用）
- **Phase 1（MTU + 11 项自包含修复）**: KCP MTU 1300→1266，UDP 包 ≤1280 字节强制门禁，缓冲区缩小，TOCTOU 临时文件名随机化，下载速度修复（~8KB/s→正常），encodeLsa 递归守卫，sessions.put OOM 回滚
- **Phase 2（mesh.zig 线程安全）**: 3 个 `std.Io.Mutex`（neighbors/routes/lsas），~30 处锁包裹，锁序 `sessions→neighbors→lsas→routes`，避免自死锁
- **Phase 3（线程生命周期）**: `tunnelManager` + `ptyReadLoop` 从 detach→join，defer 块 5 步有序销毁
- **Phase 4（错误处理 7 项）**: ptyWrite 返回值检查，poll EINTR→continue，catch 块 try 消除，pty_exec_done 消息，cleanupStaleOps 周期调用，forceInstall 失败回滚，CLI 边界检查，svc.zig runCmdQuiet 替换 24 处静默吞错

**验证**: `zig build test` 128/128 通过，8 目标交叉编译零错误，x86_64-macos Rosetta 测试通过。

### Phase 49: 文档合并与整理 ✅ (2026-07-26)

- DESIGN.md 内容合并到 CLAUDE.md（协议栈图、UDP 分发码、服务名表、设计决策理由）
- release-skill/SKILL.md 发布流程合并到 CLAUDE.md
- `build.sh` 改名 `release.sh`，增加 `gh release create` 调用，移到项目根目录
- 删除 `release-skill/` 目录、`DESIGN.md`
- `utm-vm` 改名 `utmm`：`.claude/skills/utmm/` + `skills/utmm` 软链
- 规划文档精简：task_plan（1042→53 行）、progress（1311→53 行）、findings（998→90 行）
- SKILL.md 重写（WebSocket→KCP 隧道）、MANUAL.md 整份重写（1245→632 行）
- README.md 更新安装/升级描述

### Phase 48: 自复制安装模型重构 ✅ (2026-07-26)

- 新建 `src/svc.zig`（统一跨平台服务管理）、`src/fail.zig`（fast-fail 工具）
- 删除 `src/agent.zig`、`src/upgrade.zig`
- 精简 `src/priv.zig`（仅 isAdmin）、`src/install.zig`（仅 genInit/Platform）
- 重写 `src/main.zig` 调度树
- 8 目标交叉编译全过，4 VM + Host 全部署验证通过

### Phase 47: KCP 可靠性第二轮深度审计 ✅ (2026-07-26)

- 7 个问题修复（2 Critical、2 High），20 个新测试，131/131 通过

### Phase 46: KCP 可靠性全面加固 ✅ (2026-07-26)

- 13 个问题修复（2 Critical），18 个新测试，111/111 通过

### Phase 50 部署测试 ✅ (2026-07-26)

全 VM 重新部署和 exec 功能验证，发现并修复 4 个部署期 bug（Findings #76-79）：

- **F76**: `wake_event.reset()` 信号线程调用 → `unreachable` panic — 移除 4 处 `reset()`
- **F77**: `cleanupOpState` 自死锁 — 移除 handleExec 外层锁
- **F78**: 交叉编译覆盖 `zig-out/bin/utmm` — 流程规范
- **F79**: tunnelManager use-after-free segfault — 新增 `isTunnelDead()` 方法

**修复范围**: `src/httpd.zig`（+15/-7 行），`src/host.zig`（+15/-10 行）

**部署验证**:

| VM | 状态 | 测试命令 |
|----|------|---------|
| linuxvm | ✅ | `hostname`、`uptime`、`uname -a` |
| macvm | ✅ | `uname -a`、`hostname` |
| windowsvm | ✅ | `echo W1` |
| winx64 | ✅ | `echo X1` |

`zig build test` 全量通过，Host 持续稳定无崩溃。

### Phase 51: 文件合并与测试扩充 ✅ (2026-07-26)

19 个源文件合并为 13 个，消除薄包装文件，每个文件有清晰职责：

**合并操作**：

| 删除文件 | 合并目标 | 内容 |
|----------|---------|------|
| `ver.zig` (30 行) | `protocol.zig` | VERSION 常量 |
| `priv.zig` (72 行) | `main.zig` | isAdmin 检查 |
| `install.zig` (186 行) | `svc.zig` + `host.zig` | detectServiceEnv→svc, Platform/genInit→host |
| `guest.zig` (65 行) | `broadcast.zig` | 系统信息 + meshSessionLoop 入口 |
| `mcp.zig` (397 行) | `httpd.zig` | JSON-RPC 处理 |
| `host_http.zig` (1280 行新增) | `httpd.zig` | HTTP 端点处理器 |

**合并后结构** (13 文件，12,641 行)：

| 文件 | 行数 | 职责 |
|------|------|------|
| `kcp.zig` | 3039 | KCP 可靠 ARQ 协议 |
| `httpd.zig` | 2472 | HTTP 服务器 + 端点处理 + MCP JSON-RPC |
| `broadcast.zig` | 1677 | Guest 核心 + 系统信息 + pty |
| `mesh.zig` | 1367 | LSA mesh 网络 + UDP 广播 + KCP 会话 |
| `host.zig` | 975 | Host 编排 + Platform 检测 + genInit |
| `svc.zig` | 950 | 跨平台服务管理 + detectServiceEnv |
| `tunproto.zig` | 645 | 隧道协议：构建/解析/分块传输 |
| `main.zig` | 511 | 入口 + CLI 解析 + isAdmin |
| `protocol.zig` | 322 | 协议常量 + VERSION + 部署文件名 |
| `tunnel.zig` | 272 | KCP 上的 TCP 流包装 |
| `hosts_file.zig` | 191 | /etc/hosts 标记块读写 |
| `config.zig` | 159 | 配置持久化 + 文件日志 |
| `fail.zig` | 61 | Fast-fail 工具 |

**Zig 0.16.0 API 兼容修复**：
- `waitpid` → `process.WaitPidResult` 新 API
- `BodyWriter` → `Response.Writer` 新类型
- `executablePath()` → 返回 `[]const u8`（不再需要 `fs.selfExePath`）
- `Event.set()` 签名：`.set(io)` 而非 `.set(io, .unset)`
- `readSliceAll` → `ReadBuffer` + `readUntilDelimiterAll`

**测试扩充** (+66 测试，+52%)：
- `httpd.zig`: 0→44 测试（jsonEscape, json helpers, buildCmdWithMarker, scanForMarker, HostState, OpState）
- `svc.zig` (原 install.zig): 4→10 测试
- `config.zig`: 3→9 测试
- `broadcast.zig`: 2→6 测试
- `hosts_file.zig`: 3→5 测试

**验证**: `zig build test` 128/128 通过，原生构建成功。

### Phase 52: CLI 管理命令自动确保 Host 服务 ✅ (2026-07-26)

管理命令（`--status`/`--exec`/`--upload`/`--download`）之前需要用户先手动 `utmm --host` 启动服务再执行，两步操作繁琐且对 AI Agent 不友好。服务未运行时管理命令仅打印 `ConnectionRefused` 后 crash。

**改造**: `main.zig` 合并 `--host` 和 management commands 的 `svc.ensure()` 逻辑。

- `needs_host`：`--host`、`--status`、`--exec`、`--upload`、`--download` 中任一触发 → `svc.ensure(.host)`
- `--host` 单独使用：ensure 后 return（行为不变）
- 管理命令（含 `--host` 组合）：ensure 后 fall through → HTTP 执行
- `--gen-init` / `--save-config`：不触发 Host ensure
- 失败路径不变：`forceInstall` 失败 → `fail.err()` → exit(1)

**影响**: 用户和 AI Agent 可从 `utmm --exec vm "cmd"` 一步完成，无需先 `utmm --host`。

**修改**: `src/main.zig` +6/-5 行。

### Phase 52 部署测试与 Bug 修复 ✅ (2026-07-26)

**目标**: 部署到 Host + 4 VM，验证 auto-ensure 端到端行为。

**部署过程中发现并修复**:

| # | 问题 | 文件 | 严重度 | 状态 |
|---|------|------|--------|------|
| F89 | `runCmd()` 永远返回 true 不检查退出码 | `svc.zig` | Critical | ✅ |
| F90 | macOS `cp` 破坏签名 → SIGKILL | 部署流程 | Critical | ✅ 规避 |
| F91 | `selfCopy` copy+delete 破坏签名 | `svc.zig` | High | 📋 待修 |
| F92 | `launchctl enable` 不足清除 disabled | `svc.zig` | Medium | ✅ 规避 |
| F93 | `installMacOS` + `start()` 双重 bootstrap | `svc.zig` | High | ✅ |

**start() macOS 重构**: isRunning 早返 → kickstart 优先 → enable+bootstrap 回退 → verify

**部署状态**: Host ✅ | linuxvm ✅ | macvm ✅ | windowsvm ✅ | winx64 ✅

**已知遗留**: KCP 隧道 Host 重启后 exec 空输出（F93，预存在）、selfCopy 未重新签名（F91）、DebugAllocator CLI 短生命周期泄漏（4 处）

## 待办

- [ ] F91: `selfCopy()` copy+delete 回退路径添加 macOS codesign 重新签名
- [ ] F93: KCP 隧道 Host 重启后 exec 空输出（dual-session mismatch）
