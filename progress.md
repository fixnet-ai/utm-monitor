# Progress: v0.13.0 分层架构重构

## 当前状态

- **分支**: `refac/layered-arch`
- **版本**: v0.13.0-pre（尚未发布）
- **测试**: 150 执行 / 141 唯一测试，全部通过
- **源文件**: 16 个（20 → 16）
- **全部任务完成** ✅

## 会话记录

### 2026-07-29 (最新) — Phase 4 清理收尾 + 代码扫描

**成果**: CLAUDE.md 更新 + dpipe_file 测试修复 + build.zig 去重 + 代码库遗留问题扫描

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 11 | 更新 CLAUDE.md：KCP→TCP 架构、16 文件清单、新协议描述 | ✅ |
| Task 12 | 修复 dpipe_file hash mismatch 测试（warn→debug）| ✅ |
| Task 13 | 清理 build.zig standalone_test_modules（去重 tcp/lsa，新增 shm）| ✅ |
| Task 14 | 代码库遗留问题扫描（TODO、日志、refac.md）| ✅ |

**代码扫描发现**:
- 3 个 TODO 注释：config.zig:107（功能缺口）、guest.zig:780（TCP 自动升级未闭环）、lsa.zig:496（Zig stdlib 问题）
- refac.md §3.7 残留过时描述（"install.zig 可独立构建"），已修正
- 无编译警告、无未使用导入、warn 日志均在生产代码路径中非测试路径
- 结论：重构阶段可彻底收工，分支可合并 main

**CLAUDE.md 更新详情**:
- 协议栈图 → 7 层分层模型（应用/拓扑/传输/数据管道/协议/系统服务/基础）
- 删除 KCP 协议栈、KCP 可靠传输、HostState、KCP Patterns 等全部过时章节
- 新增 TCP per-command 模型、DuplexPipe vtable、TCP 帧协议、LSA 自洽模式
- 文件清单：18 文件（含已删除）→ 正确的 16 文件

**dpipe_file hash 测试修复详情**:
- 根因：Zig 0.16.0 测试运行器对 stderr `warn` 级别日志敏感，导致 `--listen=-` 协议通信异常
- 修复：`std.log.warn` → `std.log.debug`（hash 不匹配是预期的可恢复诊断事件）
- `zig build test` 完全干净通过，无 "failed command"

**build.zig 清理详情**:
- 移除 `tcp.zig`、`lsa.zig`（已在主二进制中通过 host.zig import 链覆盖，消除重复）
- 新增 `shm.zig`（发现其 10 个测试之前从未被执行！）
- 重命名 `refac_modules` → `standalone_test_modules`
- 测试二进制：7 → 6，总执行 150 次（141 唯一 + 9 不可避免的 dpipe 重复）

### 2026-07-29 — Phase 3 完成

**成果**: lock.zig 删除 + Platform/genInit 迁移 → svc.zig

| 任务 | 描述 | 状态 |
|------|------|------|
| lock.zig 删除 | svc.zig 内联 flock/LockFileEx (120行), 删除 365行 | ✅ commit `06adede` |
| Platform/genInit | host.zig → svc.zig 迁移 (~140行+4测试) | ✅ |
| refac.md 更新 | 反映所有已完成任务、最终文件清单 | ✅ |
| task_plan.md 更新 | 全部任务标记完成 | ✅ |

**lock.zig → svc.zig 详情**:
- POSIX: `open(O_CREAT|O_RDWR)` + `flock(LOCK_EX)` — OS 级别劝告锁，进程崩溃自动释放
- Windows: `CreateFileW(OPEN_ALWAYS)` + `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)`
- 锁文件: `/var/run/utmm-install.lock` (POSIX) / `C:\opt\utmm\utmm-install.lock` (Windows)
- API 简化: `acquire(io, alloc)` → `acquire()`

**Platform/genInit 迁移详情**:
- host.zig 调用改为 `svc.Platform` + `svc.genInit`
- 不独立构建 install.zig（收益低，发布目标翻倍，与单二进制模型冲突）

### 2026-07-29 — Phase 2 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 5 | 新建 dpipe.zig + dpipe_shell.zig + dpipe_file.zig | ✅ |
| Task 6 | broadcast.zig → guest.zig，移植到 dpipe | ✅ |
| Task 7 | 删除 file_chunk/file_eof | ✅ |
| Task 8 | 消灭 state.zig + cmdchan.zig | ✅ |

### 2026-07-29 — Phase 1 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 1 | tcpf.zig + socks4.zig + netconn.zig → tcp.zig | ✅ |
| Task 2 | tunproto.zig → protocol.zig | ✅ |
| Task 3 | mesh.zig + hosts_file.zig → lsa.zig | ✅ |
| Task 4 | 修复 /etc/hosts 空行累积 bug (range replacement) | ✅ |

## 最终文件清单（16 个）

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
├── svc.zig           服务管理（install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
└── shm.zig           共享内存（utmmd↔utmm）
```

### 删除文件（10 个）
state.zig, broadcast.zig, mesh.zig, hosts_file.zig, tunproto.zig,
tcpf.zig, socks4.zig, netconn.zig, cmdchan.zig, lock.zig

---

## 历史摘要

### v0.12.2 及之前
- KCP 隧道稳定性修复、自动升级完善
- utmmd 监督进程架构重构、MCP stdio JSON-RPC
- 8 交叉编译目标全通过，166 测试通过

### v0.13.0-pre (commit `036f40f`)
- 删除 KCP ARQ 协议 (~1300行)，新增 TCP+SOCKS4 传输层
- mesh.zig 简化为纯 LSA 广播
- 20 源文件，124 测试通过
