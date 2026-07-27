# Task Plan: v0.11.14

## 架构概述

UTM Monitor (`utmm`) — 单二进制双模式（Guest/Host），Mesh LSA + KCP 隧道为唯一 Guest-Host 传输层。自复制安装模型：二进制从任意路径运行，强制覆盖安装到固定路径。

**关键设计决策：**
- 删除 WebSocket，KCP Tunnel 为唯一传输层（v0.11.0）
- 统一服务模型：Host 和 Guest 均为系统自动启动服务（v0.12.0）
- 自复制模型：升级 = 新版本 `--install`，取消 utmm-old + agent.zig（v0.12.0）
- **Guest 自主升级**（v0.11.14）：Guest 检测 LSA 版本不匹配 → KCP 下载新二进制 → `--install --hostname <name>` 自安装。Host 永不推送升级。
- Fast-fail：不继续执行出错操作，打印错误退出
- 所有操作要求 root/Administrator（除 `--version`/`--help`）

## 活跃 VM

| VM | Hostname | OS | IP | 凭据 | 路径 |
|----|----------|-----|----|------|------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## 已完成阶段

### Phase 57: `--ping` 命令实现与自动升级测试 ✅ (2026-07-27)

**目标**: 实现 `utmm --ping <hostname>` CLI 命令，通过 mesh 对指定 Guest 发起 ping，并验证自动升级端到端流程。

**核心实现**:

| 组件 | 文件 | 说明 |
|------|------|------|
| CLI 参数 + 调度 + 帮助 | `src/main.zig` | `--ping <hostname>` 解析、`needs_host` 集成、dispatch |
| `cmdPing()` HTTP 客户端 | `src/host.zig` | POST `/ping` + `x-vm` header，显示 JSON 响应 |
| `/ping` 路由注册 | `src/host.zig:524` | `router.add(gpa, .POST, "/ping", httpd.handlePing)` |
| `handlePing()` HTTP 处理器 | `src/httpd.zig:1369` | 查找 Guest MAC → mesh.pingAndWait → 返回 JSON |
| `pingAndWait()` + `sendPing()` | `src/mesh.zig` | 发送 MESH_TYPE_PING，200×50ms=10s 真实时间轮询等 pong |
| `handlePing()` mesh 层 | `src/mesh.zig:1119` | 直接 ping（10 字节）/ 中继 ping（17 字节含 dst_mac+TTL） |
| `handlePong()` mesh 层 | `src/mesh.zig:1181` | 更新 `last_pong_*` 跟踪字段供 `pingAndWait` 检测 |
| `setGuestMeshMac()` 调用 | `src/host.zig:873` | 在 tunnelManager 注册 tunnel 后设置 mesh_mac |

**修复的 Bug**:

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | `/ping` 返回 "guest not found" | `setGuestMeshMac()` 定义但从未调用 → `mesh_mac` 永远为 null | 在 tunnelManager `registerGuestTunnel` 后调用 |
| 2 | `pingAndWait` 超时不准确 | 使用 `clock_ms`（事件计数器，~1000-2000/秒）做 5s 超时，实际周期 ping 每 ~60s 一次 | 改为 200×50ms=10s 真实时间轮询 |
| 3 | `fromMillis` / `readHeader` 编译错误 | Zig 0.16.0 API 变更 | `fromMilliseconds` / `getRequestHeader` |
| 4 | `Writer.Discarding.init()` 需要 buffer 参数 | Zig 0.16.0 API | 改用 `Writer.fixed()` |

**Ping 协议**:
- **直接 ping** (Host→Guest 或同一子网): `[0x03][src_mac:6][timestamp:4]` = 11 字节
- **中继 ping** (跨跳，如 Guest→Guest 经 Host): `[0x03][src_mac:6][dst_mac:6][ttl:1][timestamp:4]` = 18 字节
- **Pong 响应**（统一格式）: `[0x04][responder_mac:6][timestamp:4]` = 11 字节
- **RTT 单位**: mesh `clock_ms` 事件计数（非真实毫秒），~10 表示 sub-ms 实际延迟

**自动升级验证** (v0.11.10→v0.11.11):

| Guest | 升级方式 | 结果 |
|-------|---------|------|
| linuxvm | SSH scp + `--install` | ✅ 服务重启，LSA 重连 |
| macvm | SSH scp + `--install` + 手动 bootstrap | ✅ (launchd bootstrap 间歇失败) |
| windowsvm | SSH scp + `--install` | ✅ |
| winx64 | SSH scp + `--install` | ✅ |

**部署期发现**:
- `--install` 通过 SSH 执行不可靠：`pkill`/`taskkill` 会杀掉 SSH 会话，导致服务配置未完成
- macOS `launchctl bootstrap` 间歇返回 errno=2，需手动重试
- 升级后 Guest 丢失 `--hostname` 参数 → 自动检测主机名 → 需手动重配服务

**验证**: `zig build test` 193/193 通过（EXIT=0），`--ping` 4/4 Guest 全部返回正确 MAC 和 RTT。

### Phase 58: 关键代码注释 + file_chunk MSS 对齐优化 ✅ (2026-07-27)

**目标**: 在关键位置添加技术细节注释，防止误读代码；将 file_chunk 数据大小从 8KB 改为与 KCP MSS 对齐，消除 KCP 层二次分片。

**注释添加**:

| 文件 | 位置 | 内容 |
|------|------|------|
| `src/tunproto.zig` | Parse functions 前 | **CRITICAL CONVENTION**: 所有 `parse*()` 从 `pos=0` 开始，调用者必须传 `data[1..]`（Finding 109 教训） |
| `src/kcp.zig` | 常量区后 | MTU/MSS/frg 关系、message vs stream 模式、MSS-aligned 设计意图 |
| `src/httpd.zig` | `handleMeshGuest` dispatch | `msg_type = data[0]` 被 switch 消费，分支必须传 `data[1..]` |
| `src/broadcast.zig` | `sendChunkedFile` + dispatch | MSS-aligned chunk 设计理由；`payload = rbuf[1..]` 注释 |

**file_chunk MSS 对齐重构**:

- `tunproto.zig`: 新增 `FILE_CHUNK_DATA_MAX = 1200`（MSS 1242 - 帧开销 ~42）
- `broadcast.zig`: `chunk_buf[1200]` + `file_read_buf[4096]`（分离磁盘读缓冲）
- `httpd.zig`/`ipc.zig`: 所有上传 chunk buffer 改用新常量

**设计理由**:
- 旧方案：8KB chunk → KCP 拆 7 segment (frg 6→0) → 无谓二次分片 → 丢一段阻塞整 chunk
- 新方案：1200B chunk → frame ≈ 1229B < MSS 1242 → **恰好 1 KCP segment** → 无 frg 重组
- 代价：~7x 的 `sendAndFlush()` 调用，但文件通常 < 100MB，可接受

### Phase 59: StandardErrorPath plist 回归修复 ✅ (2026-07-27)

**问题**: `--install` 重写 macOS plist 时未包含 `StandardErrorPath`（Finding 110 回归）。
每次 `--install` 都会丢失之前手动添加的 stderr 日志路径，所有 `std.log` 输出进入 ASL 而非文件。

**修复**: `svc.zig:installMacOS()` 的 plist 模板中新增 `StandardErrorPath` 键，生成同 stdout 的 `-err.log` 路径。

### Phase 50-56（历史）

Phase 50（加固审计）、Phase 51（文件合并）、Phase 52（auto-ensure）、Phase 53（MCP stdio + lock）、Phase 54（Host 重启 exec 空输出）、Phase 55（Windows 服务停止）、Phase 56（回归测试 + 硬停止）— 详见 [progress.md](progress.md)。

### Phase 60: HTTP 废弃端点清理 ✅ (2026-07-27)

**目标**: 移除 CLI→IPC 迁移后的 HTTP 死代码（POST 端点 + HTTP fallback 函数）。

**httpd.zig 移除**:
- `parseJson()` — 未使用，mcp.zig 有自己的 JSON 解析
- `readBody()` / `readRawBody()` — POST body 读取辅助
- `getRequestHeader()` — 自定义 header 读取
- `handlePing()` / `handleExec()` / `handleUpload()` / `handleDownload()` — POST 端点
- `parseJson` 测试 (2 个)

**httpd.zig 保留**: `respondError()` / `respondErrorDirect()` — `handleBin()` 仍在使用。

**host.zig 移除**:
- 4 条 POST 路由注册 (`/download`, `/upload`, `/exec`, `/ping`)
- 5 个 HTTP fallback 函数: `cmdStatusHttp()`, `cmdPingHttp()`, `cmdExecHttp()`, `cmdUploadHttp()`, `cmdDownloadHttp()`

**验证**: `zig build test` 149/149 通过（与 git HEAD 一致）。

### Phase 61: 彻底删除 HTTP 协议，全面转向 KCP+IPC ✅ (2026-07-27)

**目标**: HTTP 服务器所有 GET 端点均无活跃消费者（升级走 scp，GUEST 列表走 IPC），删除整个 HTTP 服务栈。

**httpd.zig** (净保留 ~680 行):
- 删除: HTTP 路由器（`Router`、`HandlerFn`、`Route`）、`serve()` accept 循环、`respondJson/Error/Direct`、`handleBin/Version/ApiGuests/Root`
- 保留: `HostState` + 所有状态管理方法、`buildCmdWithMarker`、`handleMeshGuest`、`serveUpgradeFile`（KCP 文件分发，非 HTTP）、`syncHostsFromState`、JSON 辅助函数、测试

**host.zig** (净删除 ~170 行):
- 移除 HTTP 路由注册和 `httpd.serve()` 阻塞调用
- `startHttpHost` → `startHost`，端口 2121 不再用于 HTTP
- 替换阻塞机制：shutdown flag 轮询循环
- 清理 MCP HTTP fallback 函数: `handleVmStatusHttp` (72 行)、`handleVmExecHttp` (93 行)

**端口 2121 仅保留 UDP** (mesh LSA + KCP tunnel)

**验证**: `zig build test` 149/149 通过。HTTP 代码从 `httpd.zig` ~1750 行减至 ~680 行（-61%）。

### Phase 62: Windows IPC 编译修复 + 全量部署测试 ✅ (2026-07-27)

**目标**: 修复 Phase 61 HTTP 删除后 Windows 交叉编译问题，构建所有 8 目标并部署到全部 VM 验证。

**Windows IPC 编译修复** (`src/ipc.zig`):

Zig 0.16.0 移除了大量 `std.os.windows` API（CreateNamedPipeA、ConnectNamedPipe、CreateFileA、ReadFile、WriteFile、SetNamedPipeHandleState），需在 `ipc.zig` 中手动 `extern "kernel32"` 声明。

| 修复 | 问题 | 方案 |
|------|------|------|
| `callconv(.winapi)` | x86-windows-gnu (32-bit MinGW) 缺少此约定导致 `_CreateFileA` 等 6 个符号未定义 | 全部 extern 添加 `callconv(.winapi)` |
| `hTemplateFile: ?HANDLE` | Zig 0.16.0 中 `null` 无类型，不能隐式转换为 `*anyopaque` | 参数改为可空类型 `?HANDLE` |
| `socketPathZ()` 返回 `[*:0]const u8` | `@ptrCast([]const u8)` 无法转为 C API 所需的 null-terminated 指针 | 独立函数返回字符串字面量（直接强制转换） |

**构建验证**: 8 目标全部通过。

**全量部署测试** (2026-07-27):

| VM | --status | --ping | --exec | --upload | --download |
|----|----------|--------|--------|----------|------------|
| linuxvm | ✅ | ✅ RTT=10 | ✅ uname | ✅ 30B MATCH | ✅ 30B MATCH |
| macvm | ✅ | ✅ RTT=10 | ✅ uname | ✅ 30B MATCH | ✅ 30B MATCH |
| windowsvm | ✅ | ✅ RTT=10 | ✅ ver | ✅ 30B MATCH | ✅ 30B MATCH |
| winx64 | ✅ | ✅ RTT=10 | ✅ ver | ✅ 30B MATCH | ✅ 30B MATCH |

macOS `launchctl bootstrap` 间歇性 errno=2/5（已知问题，Phase 57）：`--install` 最后一步失败，但 launchd 自动重启服务（二进制已复制到位）。

### Phase 63: Guest 自主升级方案 ✅ (2026-07-27)

**目标**: 将升级从 Host 推送模式简化为 Guest 自主完成，实现原子化自升级。

**v0.11.12 — Guest 自动升级 (commit `6ee2155`)**:

初始实现 Guest 自主升级：LSA 检测版本不匹配 → `doAutoUpgrade()` → KCP `upgrade_req` → Host `serveUpgradeFile` → `receiveUpgradeFile()` → `applyUpgradeAndRestart()` → `--install --hostname <name>`。

**v0.11.13 — 简化 Host 侧 (commit `98409c4`)**:

彻底移除 Host 推送升级的所有代码：
- `host.zig`: 删除 `pushUpgradeToGuest()` 函数（~183 行）、`upgrade_cooldown` 状态、推送触发逻辑
- `host.zig`: tunnelManager "Phase 2" 简化 — 移除 upgrading 特殊逻辑，统一使用 `m.connect()`
- 升级完全由 Guest 发起，Host 仅响应 `upgrade_req`

**v0.11.14 — 修复命令循环死锁 (commit `7178fb2`)**:

**Critical Bug**: Guest `meshSessionLoop` 的升级检查只在**外层循环**（`waitForHostTunnel` 之前），但 Guest 在 `waitForHostTunnel` 之后进入**内层命令循环**（`while (!pty_dead.load(.acquire))`）永不退出。`upgrade.needed` 被设置后永远不会被检查 → 升级信号死锁。

**修复**: 在内层命令循环中添加升级检查：
```zig
if (upgrade.needed.load(.acquire)) {
    std.log.info("[guest-mesh] Upgrade signal detected, exiting command loop", .{});
    break;
}
```

**Bootstrap 部署**: v0.11.11/v0.11.12 Guest 由于上述 bug 无法自动升级。SSH 手动部署 v0.11.14 到 linuxvm/macvm/windowsvm（winx64 离线）。升级后所有 Guest 的 `--exec`、`--upload`、`--download` 验证通过。

**最终升级流程**:
```
1. Guest LSA handler 检测 Host version != protocol.VERSION → upgrade.needed = true
2. Guest 命令循环检测到 upgrade.needed → break 退出内层循环
3. 外层循环: doAutoUpgrade()
   a. waitForHostTunnel() 获取 KCP 隧道
   b. 发送 upgrade_req(0x19) → Host serveUpgradeFile()
   c. 接收 file_chunk × N + file_eof (SHA256 校验)
   d. 保存到临时目录 → chmod +x
   e. 运行 --install --hostname <name> → forceInstall 完整部署
4. Host 永不推送升级 — Guest 完全自主
```

**Host 侧保留**: `serveUpgradeFile()` 响应 Guest 的 `upgrade_req`，通过 `deploymentFilename()` 查找匹配目标平台的二进制。

### Phase 64: 文档重写 + v0.11.15 发布 ✅ (2026-07-27)

**目标**: 重写 `skills/utmm/SKILL.md` 和 `skills/utmm/MANUAL.md`，使其与 v0.11.14 代码现状一致；发布 v0.11.15 验证文档更新后的完整发布流程。

**文档修正**:

| 文件 | 关键修正 |
|------|---------|
| `SKILL.md` | 架构描述（UDP+IPC 替代 HTTP）、MCP 工具 2→5（新增 vm_ping/vm_upload/vm_download）、IPC socket 路径、文件传输工作流、Auto-Upgrade 节 |
| `MANUAL.md` | 版本号 0.11.10→0.11.14、端口 2121 TCP HTTP→UDP only、CLI 通信 HTTP→IPC socket、MCP 通信 HTTP→IPC socket、MCP 工具 2→5、升级"无自动升级"→Guest 自主升级、源文件 13→15（新增 ipc.zig） |

**v0.11.15 发布**: 构建 8 目标 → `./release.sh` → GitHub Release → 本机 Host 安装 → 观察 VM 自动升级。

## 待办

- [ ] F91: `selfCopy()` copy+delete 回退路径添加 macOS codesign 重新签名
- [ ] Windows 优雅退出方案延后（Finding 103）：ARM64 AFD 不中断 ReadFile + 多线程协调竞态
- [ ] RTT 改为真实毫秒：`clock_ms` 事件计数器不适合测量时间，需用 `std.Io.Timestamp.awake`
- [ ] `handleMeshGuest` 缺少 `upload_result` (0x17) 处理分支 — 虽不影响功能（当前 upload 走 fire-and-forget），但会在日志刷 `unknown msg type 0x17`
- [ ] httpd.zig 测试未被编译到测试套件中（~31 个测试遗漏）— 需排查
