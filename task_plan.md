# Task Plan — UTM Monitor

**版本**: v0.18.1 | **分支**: `main` | **更新**: 2026-08-11

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **测试**: 216 单元 + 59 集成 + 2 Python (CLI 31/31 + MCP 14/14)，0 泄漏
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点全部 v0.18.1 serving
- **GitHub Release**: v0.18.1 published

## 已完成: Phase 31 — HTTP MCP 嵌入 Host Daemon

将 MCP 从独立 stdio 进程嵌入 Host daemon，消除 IPC 桥接。

| 任务 | 状态 |
|------|------|
| mcp_handler.zig — 提取核心业务逻辑（无 IPC 依赖） | ✅ |
| mcp_http.zig — HTTP/1.1 POST 解析器 + 传输层 | ✅ |
| socks5.zig — 新增 peek 变体（authAcceptWithVersion / readRequestBufWithVersion） | ✅ |
| host.zig — 首字节协议分发（0x05→SOCKS5, ASCII→HTTP MCP） | ✅ |
| mcp.zig — McpContext 结构体 + processRequest 重构 | ✅ |
| ipc.zig — handler 委托 mcp_handler（消除 ~160 行重复） | ✅ |
| main.zig — --mcp 打印 HTTP 端点 URL | ✅ |
| test_mcp_tools.py — stdio → HTTP POST | ✅ |
| mcp.zig 删除 SIGALRM / idle timeout / _exit(0) | ✅ |
| mcp.zig handleVmSshpass — 修复 zio IO + sshpass memset bug | ✅ |
| main.zig --help — 修复过期 --mcp 描述 | ✅ |
| README/refac.md — 修复过期数字 | ✅ |

**收益**:
- 消除 IPC 序列化开销（JSON 不走 socket）
- 消除 SIGALRM 空闲超时（`_exit(0)` 硬杀）
- 消除 EINTR 竞态（`SA_RESTART=0` 读中断即退出）
- 消除 64KB exec 缓冲区截断
- 单端口 2121 承载 SOCKS5 + HTTP MCP（首字节分发）

**验证**:
- `zig build` — 编译通过 ✅
- `zig build test` — 210+ 通过 ✅
- `zig build test-integration` — 59 通过，0 泄漏 ✅

## 已完成: Phase 32 — MCP 双格式响应 (structuredContent)

参考 zigtester 的 MCP 双格式模式，为全部 6 个 MCP 工具响应添加 `structuredContent` 字段。

| 任务 | 状态 |
|------|------|
| formatStatusMCP — guests[] + counts{total,serving,offline} | ✅ |
| formatExecMCP — {vm, command, exit_code} | ✅ |
| formatPingMCP — {vm, reachable, mac, rtt_ms} | ✅ |
| handleVmUpload — {vm, local_path, remote_path, success} | ✅ |
| handleVmDownload — {vm, remote_path, local_path, bytes, success} | ✅ |
| handleVmSshpass — {host, user, exit_code} | ✅ |
| 6 测试新增（status×2, exec×2, ping×2）| ✅ |

**收益**:
- AI agent 可程序化解析 `structuredContent` 做决策，无需从 markdown 提取
- 保持人类可读 markdown 在 `content[0].text` 中展示
- ~50 行增量，集中在 `src/mcp.zig` 的 `format*` / `handle*` 函数
- 所有 216 单元测试通过

## 下一阶段: Phase 30 — 部署体验改进

审计 `docs/deploy-ux-audit.md` 发现 8 个障碍，已完成 7/8：

| 障碍 | 优先级 | 状态 |
|------|--------|------|
| VM 凭据硬编码 → deploy.json | P0 | ✅ |
| Windows --deploy 空操作 → 自动化 | P0 | ✅ |
| zio 依赖不可解析 → README + 注释 | P1 | ✅ |
| deploy 要求 Zig 工具链 → serve-dir 缓存 | P1 | ✅ |
| --upgrade 错误信息差 → 可操作指引 | P3 | ✅ |
| Guest bootstrap（从零部署到裸 VM） | P2 | 待讨论 |
| zip 无文档 + 版本号不一致 | P2/P3 | 不做 |
| MANUAL.md 更新 deploy.json/serve-dir/sshpass | P2 | ✅ |
| cmdDeploy 用 utmm sshpass 去外部依赖 | P2 | ✅ |

### 待跟进

- **zio PR #646**: 等待 lalinsky re-review 后合并，之后 build.zig.zon 切回 URL

## 关键设计决策（持续有效）

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接 | 无跨线程共享状态 |
| 2 | DuplexPipe vtable 抽象 | 可扩展、可测试 |
| 3 | 单二进制双模式（Guest/Host） | 减少维护 |
| 4 | 自复制安装模型（stop→kill→copy→start） | 网络无关，零脚本 |
| 5 | SOCKS5 Hub-Spoke（Host 唯一中转） | 简单拓扑，无环路 |
| 6 | MDELIM 退出码标记 | 跨 shell 兼容 |
| 7 | deploy.json 配置文件 | 外部用户无需改源码 |
| 8 | serve-dir 缓存跳过编译 | --deploy 首次编译后零开销 |
| 9 | HTTP MCP 嵌入 Host Daemon | 消除 IPC 桥接、空闲超时、缓冲区截断 |
| 10 | 首字节协议分发（0x05/ASCII→HTTP） | 单端口承载 SOCKS5 + HTTP MCP |
| 11 | mcp_handler 共享业务逻辑 | HTTP MCP 和 IPC handler 零重复 |

## 架构（v0.18.0+）

```
Application:  guest.zig / host.zig / ipc.zig / mcp.zig / mcp_handler.zig / mcp_http.zig / sshpass.zig
Topology:     lsa.zig / arp.zig
Transport:    tcp.zig / socks5.zig
Data Pipe:    dpipe.zig / dpipe_shell.zig / dpipe_file.zig
Protocol:     protocol.zig
System:       svc.zig / utmmd.zig / shm.zig
Foundation:   main.zig / fail.zig / config.zig
```
