# Task Plan: v0.11.11

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

### Phase 50-56（历史）

Phase 50（加固审计）、Phase 51（文件合并）、Phase 52（auto-ensure）、Phase 53（MCP stdio + lock）、Phase 54（Host 重启 exec 空输出）、Phase 55（Windows 服务停止）、Phase 56（回归测试 + 硬停止）— 详见 [progress.md](progress.md)。

## 待办

- [ ] F91: `selfCopy()` copy+delete 回退路径添加 macOS codesign 重新签名
- [ ] Windows 优雅退出方案延后（Finding 103）：ARM64 AFD 不中断 ReadFile + 多线程协调竞态
- [ ] RTT 改为真实毫秒：`clock_ms` 事件计数器不适合测量时间，需用 `std.Io.Timestamp.awake`
