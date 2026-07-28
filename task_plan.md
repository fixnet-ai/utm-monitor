# Task Plan: v0.13.0 — 分层架构重构

## 状态：全部完成 ✅

- **分支**: `refac/layered-arch`
- **源文件**: 20 → 16
- **测试**: 150 执行 / 141 唯一测试，全部通过
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

### Phase 4: 清理收尾 ✅

| # | 任务 | 状态 |
|---|------|------|
| 11 | 更新 CLAUDE.md（KCP→TCP 架构，16 文件清单）| ✅ |
| 12 | 修复 dpipe_file hash mismatch 测试（warn→debug）| ✅ |
| 13 | 清理 build.zig standalone_test_modules（去重 tcp/lsa，新增 shm）| ✅ |
| 14 | 代码库扫描（TODO、日志、refac.md 修正）| ✅ |
| 15 | 新增 config.auto_upgrade 开关（默认 false）| ✅ |


### Phase 5: 集成测试 📋

| # | 任务 | 状态 |
|---|------|------|
| 16 | 测试基础设施 `tests/common.zig` | 📋 |
| 17 | `tcp_frame` TCP 帧协议 + SOCKS4a 集成测试 | 📋 |
| 18 | `lsa_routing` LSA 编解码 + Dijkstra 路由集成测试 | 📋 |
| 19 | `dpipe_relay` DuplexPipe relay 集成测试 | 📋 |
| 20 | `svc_install` 安装/卸载集成测试 | 📋 |
| 21 | `auto_upgrade` 自动升级集成测试 | 📋 |
| 22 | build.zig 集成 `test-integration` 构建步骤 | 📋 |

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
| 10 | dpipe_file hash mismatch: warn→debug | Zig 0.16.0 测试运行器对 stderr warn 日志敏感 |
| 11 | build.zig 去重 tcp/lsa，新增 shm | tcp/lsa 已在主二进制中；shm 10 个测试之前从未运行 |
| 12 | auto_upgrade 默认 false | 避免自动升级在测试中干扰；部署时 --auto-upgrade 显式启用 |
