# Task Plan: v0.13.0 — 分层架构重构

## 架构概述

UTM Monitor (`utmm`) 分层架构重构：20 文件 → 15 文件，TCP per-command 连接模型，
DuplexPipe vtable 抽象，消灭 `state.zig`（不再需要跨线程共享状态）。

**已完成 (v0.13.0-pre, commit `036f40f`):**
- 删除 KCP ARQ 协议 (~1300 行) + tunnel/ringbuf/completion
- 删除未使用的重构模块: channel/sess*/disco/router/upgrade/json
- 新增 TCP 传输层: tcpf.zig (帧协议) + socks4.zig (SOCKS4a) + netconn.zig (连接抽象)
- mesh.zig 简化为纯 LSA 广播 + Dijkstra + ping/pong
- broadcast.zig 迁移到 guestTcpLoop
- state.zig/host.zig/ipc.zig 迁移到 TCP 连接

**设计文档:** `refac.md` — 完整的分层架构设计、模块接口、实施计划

## 当前状态

- **分支**: `refac/layered-arch`
- **版本**: v0.13.0-pre（尚未发布）
- **源文件**: 20 个
- **测试**: 124/124 通过（需验证）
- **目标**: 15 文件，所有测试通过

## 实施阶段

### Phase 1: 低风险合并（文件合并，逻辑不变）

| # | 任务 | 产出 | 测试 | 状态 |
|---|------|------|------|------|
| 1 | `tcpf.zig` + `socks4.zig` + `netconn.zig` → `tcp.zig` | ~530行，统一对外接口 | 12 测试迁移 | pending |
| 2 | `tunproto.zig` → `protocol.zig` | 协议定义合一 | 合并测试 | pending |
| 3 | `mesh.zig` + `hosts_file.zig` → `lsa.zig` | 自洽 LSA 闭环 | 合并测试 | pending |
| 4 | 修复 `/etc/hosts` 空行累积 bug | range replacement | 新增测试 | pending |

### Phase 2: 核心重构

| # | 任务 | 产出 | 测试 | 状态 |
|---|------|------|------|------|
| 5 | 新建 `dpipe.zig` + `dpipe_shell.zig` + `dpipe_file.zig` | DuplexPipe vtable 体系 | 边界测试 | pending |
| 6 | `broadcast.zig` → `guest.zig`，移植到 dpipe | TCP accept + dpipe.relay | 功能测试 | pending |
| 7 | 删除 `file_chunk`/`file_eof`，简化 tunproto | TCP 流式传输替代分块 | 更新测试 | pending |
| 8 | 重构 `host.zig` + `ipc.zig`，消灭 `state.zig` | IPC 直接操作 tcp.Connection | 功能测试 | pending |

### Phase 3: 系统服务

| # | 任务 | 产出 | 测试 | 状态 |
|---|------|------|------|------|
| 9 | `install.zig` 独立构建 + 代码整合 | 可独立测试的安装程序 | 边界测试 | pending |
| 10 | 更新 `build.zig` 适配新模块 | 编译+测试全绿 | CI | pending |

## 删除文件清单

| # | 文件 | 原因 |
|---|------|------|
| 1 | `state.zig` | Phase 2: TCP per-command 无需共享状态 |
| 2 | `broadcast.zig` | Phase 2: → `guest.zig` |
| 3 | `mesh.zig` | Phase 1: → `lsa.zig` |
| 4 | `hosts_file.zig` | Phase 1: → `lsa.zig` |
| 5 | `tunproto.zig` | Phase 1: → `protocol.zig` |
| 6 | `tcpf.zig` | Phase 1: → `tcp.zig` |
| 7 | `socks4.zig` | Phase 1: → `tcp.zig` |
| 8 | `netconn.zig` | Phase 1: → `tcp.zig` |
| 9 | `cmdchan.zig` | Phase 2: TCP per-command 无需跨线程命令队列 |

## 最终文件清单（15 文件）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── lock.zig          进程互斥
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
└── svc.zig           服务管理（含 install）
    utmmd.zig         监督进程（嵌入 main）
    shm.zig           共享内存（utmmd 用）
```

## 关键决策记录

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接模型 | 消除跨线程共享状态需求 |
| 2 | DuplexPipe vtable 模式 | Zig 惯用，可扩展，可测试 |
| 3 | SOCKS4a 内嵌在 tcp.zig | 代码量小(120行)，无需独立文件 |
| 4 | 删除 file_chunk/file_eof | TCP 可靠传输无需分块校验 |
| 5 | lsa.zig 自洽 | LSA + 节点表 + hosts 三者合一，消除数据冗余 |
| 6 | state/cmdchan 删除 | TCP per-command 无共享状态 |
| 7 | per-command shell（不保留 cd/export） | 简单，匹配独立连接模型 |

## 遇到的错误

| 错误 | 尝试次数 | 解决方案 |
|------|---------|---------|
| — | — | — |
