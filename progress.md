# Progress: v0.11.18

## 当前状态

- **分支**: `main`
- **版本**: v0.11.18（唯一来源 `src/ver.txt`，`@embedFile` 编译期嵌入；`build.zig.zon` 永为 `0.0.0`）
- **测试**: 166/166 通过
- **部署**: macOS Host v0.11.18 ✅ | linuxvm v0.11.18 ✅ | macvm v0.11.18 ✅ | windowsvm v0.11.18 ✅ | winx64 v0.11.18 ✅
- **健康检查**: 4/4 全部通过（`--verify` 全绿 ✓）
- **状态增强**: Host + 4 Guest 全部显示，role/status/last_seen 正确
- **GitHub 检查**: Host 启动时 fire-and-forget 线程，支持重定向+格式校验

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
