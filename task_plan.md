# Task Plan: v0.13.0 — 分层架构重构

## 状态：全部完成 ✅

- **分支**: `refac/layered-arch`
- **提交**: `036f40f` (KCP→TCP) → `3ca7239` (refac.md 更新) → `06adede` (lock.zig 删除) → 待 commit (Platform/genInit 迁移)
- **源文件**: 20 → 16
- **测试**: 通过（1 个预存 dpipe_file hash 失败，非本次引入）
- **设计文档**: `refac.md`

## 架构概述

UTM Monitor (`utmm`) 分层架构重构：20 → 16 文件，TCP per-command 连接模型，
DuplexPipe vtable 抽象，消灭 state.zig + cmdchan.zig + lock.zig。

## 实施阶段

### Phase 1: 低风险合并 ✅

| # | 任务 | 状态 |
|---|------|------|
| 1 | `tcpf.zig` + `socks4.zig` + `netconn.zig` → `tcp.zig` | ✅ |
| 2 | `tunproto.zig` → `protocol.zig` | ✅ |
| 3 | `mesh.zig` + `hosts_file.zig` → `lsa.zig` | ✅ |
| 4 | 修复 `/etc/hosts` 空行累积 bug（range replacement）| ✅ |

### Phase 2: 核心重构 ✅

| # | 任务 | 状态 |
|---|------|------|
| 5 | 新建 `dpipe.zig` + `dpipe_shell.zig` + `dpipe_file.zig` | ✅ |
| 6 | `broadcast.zig` → `guest.zig`，移植到 dpipe | ✅ |
| 7 | 删除 `file_chunk`/`file_eof`，简化 wire 协议 | ✅ |
| 8 | 重构 `host.zig` + `ipc.zig`，消灭 `state.zig` + `cmdchan.zig` | ✅ |

### Phase 3: 系统服务 ✅

| # | 任务 | 状态 |
|---|------|------|
| 9 | Platform/genInit → svc.zig（不独立构建 install）| ✅ |
| 10 | `lock.zig` → svc.zig 内联 flock/LockFileEx | ✅ |

## 删除文件清单（10 个）

| # | 文件 | 原因 |
|---|------|------|
| 1 | `state.zig` | TCP per-command 无需共享状态 |
| 2 | `broadcast.zig` | → `guest.zig` |
| 3 | `mesh.zig` | → `lsa.zig` |
| 4 | `hosts_file.zig` | → `lsa.zig` |
| 5 | `tunproto.zig` | → `protocol.zig` |
| 6 | `tcpf.zig` | → `tcp.zig` |
| 7 | `socks4.zig` | → `tcp.zig` |
| 8 | `netconn.zig` | → `tcp.zig` |
| 9 | `cmdchan.zig` | TCP per-command 无需跨线程命令队列 |
| 10 | `lock.zig` | → svc.zig 内联 flock/LockFileEx |

## 最终文件清单（16 文件）

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
├── svc.zig           服务管理（install/uninstall + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
└── shm.zig           共享内存（utmmd↔utmm）
```

## 关键决策记录

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接模型 | 消除跨线程共享状态需求 |
| 2 | DuplexPipe vtable 模式 | Zig 惯用，可扩展，可测试 |
| 3 | SOCKS4a 内嵌在 tcp.zig | 代码量小，无需独立文件 |
| 4 | 删除 file_chunk/file_eof | TCP 可靠传输无需分块校验 |
| 5 | lsa.zig 自洽 | LSA + 节点表 + hosts 三者合一，消除数据冗余 |
| 6 | state/cmdchan 删除 | TCP per-command 无共享状态 |
| 7 | per-command shell | 匹配独立连接模型 |
| 8 | lock.zig → svc.zig 内联 flock/LockFileEx | OS 级别锁自动释放，无 stale lock；固定路径替代 CWD |
| 9 | Platform/genInit → svc.zig（不独立构建）| 独立构建收益低，聚合到服务管理层即可 |

## 预存问题

| # | 问题 | 状态 |
|---|------|------|
| 1 | dpipe_file hash mismatch 测试 | 预存，非本次引入 |
