# Task Plan: v0.11.18

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

- **版本**: v0.11.18（唯一来源 `src/ver.txt`，`@embedFile` 编译期嵌入）
- **`build.zig.zon`**: `0.0.0`（永不再改）
- **源文件**: 16 个（`src/*.zig`）+ 1 版本文件（`src/ver.txt`）+ 2 skills（`zig`、`deploy`）
- **测试**: 166/166 通过
- **部署**: macOS Host v0.11.18 ✅ | linuxvm v0.11.18 ✅ | macvm v0.11.18 ✅ | windowsvm v0.11.18 ✅ | winx64 v0.11.18 ✅
- **健康检查**: 4/4 全部通过（status ✓ ping ✓ exec ✓）
- **8 交叉编译目标**: aarch64/x86_64/x86 × linux-musl/macos/windows
- **GitHub 版本检查**: Host 启动时 fire-and-forget OS 线程，支持 302 重定向，格式校验防污染

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

## 待修复

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 123 | 🔴 CRITICAL | macOS 自动升级后 `exit(0)` + `KeepAlive SuccessfulExit=false` → 服务永久停止 |
| 124 | ✅ 已修复 | LSA restart 用全 node_info 比较 → 动态字段(status:)触发误判 → nonce 比较 |
| 129 | 🔴 | 非 Linux Guest 隧道不稳定：KCP 并发 connect() 导致会话状态不一致 |

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

## 待修复

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 123 | 🔴 CRITICAL | macOS 自动升级后 `exit(0)` + `KeepAlive SuccessfulExit=false` → 服务永久停止 |
| 129 | 🔴 | 非 Linux Guest 隧道不稳定：KCP 并发 connect() 导致会话状态不一致 |
| 125 | 📋 | `nowMs()` RTT 直连正确、中继异常（uptime 级别数值） |
| 127 | 📋 | linuxvm Journal 停止 + 升级下载无声失败 |
| 128 | 📋 | macOS `launchctl bootstrap` errno=5 在 bootout 后 |
