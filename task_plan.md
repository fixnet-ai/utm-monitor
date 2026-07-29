# Task Plan: v0.13.0 — 分层架构重构

## 状态：全部完成 ✅

**最新版本**: v0.13.1 — SOCKS4a 栈悬垂指针修复 + 跨平台 socket I/O 完善

- **分支**: `refac/layered-arch`
- **源文件**: 20 → 17（10 删除 + 1 新增 testlib.zig）
- **测试**: 155 执行 / 146 唯一测试（新增 5 个 tcp.zig 测试）+ 45 集成测试场景（9 套件），全部通过
- **真机验证**: linuxvm + windowsvm + macvm exec/upload/download 全通过
- **设计文档**: `refac.md`

## 架构概述

UTM Monitor (`utmm`) 分层架构重构：20 → 17 文件，TCP per-command 连接模型，
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


### Phase 5: 集成测试 ✅

| # | 任务 | 状态 |
|---|------|------|
| 16 | 测试基础设施 `tests/common.zig` | ✅ |
| 17 | `tcp_frame` TCP 帧协议 + SOCKS4a 集成测试（6 场景）| ✅ |
| 18 | `lsa_routing` LSA 编解码 + Dijkstra 路由集成测试（6 场景）| ✅ |
| 19 | `dpipe_relay` DuplexPipe relay 集成测试（5 场景）| ✅ |
| 20 | `svc_install` 安装/卸载集成测试（7 场景）| ✅ |
| 21 | `auto_upgrade` 自动升级集成测试（5 场景）| ✅ |
| 22 | `exec_e2e` exec 端到端 TCP loopback 全协议流程（4 场景）| ✅ |
| 23 | `upload_e2e` upload 端到端 TCP loopback 全流程（4 场景）| ✅ |
| 24 | `download_e2e` download 端到端 TCP loopback 全流程（4 场景）| ✅ |
| 25 | `upgrade_e2e` upgrade 端到端 TCP loopback 全流程（4 场景）| ✅ |

### Phase 6: 代码审查修复 ✅

| # | 任务 | 来源 | 状态 |
|---|------|------|------|
| 26 | C1 双重 MDELIM 标记 fix | REVIEW_FINDINGS.md | ✅ |
| 27 | C2 GuestTable Mutex 并发保护 | REVIEW_FINDINGS.md | ✅ |
| 28 | I1 自动升级 TCP 完整流程实现 | REVIEW_FINDINGS.md | ✅ |
| 29 | I2 genInit 模板服务名修正 | REVIEW_FINDINGS.md | ✅ |
| 30 | I3/I4 buildCmdWithMarker/scanForMarker 统一 | REVIEW_FINDINGS.md | ✅ |
| 31 | M1 saveConfig 重复 port 行删除 | REVIEW_FINDINGS.md | ✅ |
| 32 | M2 loadConfig 改为返回 error.Unimplemented | REVIEW_FINDINGS.md | ✅ |
| 33 | M3 heartbeatThread 日志 | REVIEW_FINDINGS.md | ✅ |
| 34 | M4 tunnelManager 锁分两阶段 | REVIEW_FINDINGS.md | ✅ |
| 35 | M5 svc.zig remove 内存泄漏修复 | REVIEW_FINDINGS.md | ✅ |
| 36 | M6 死代码标记 | REVIEW_FINDINGS.md | ✅ |

### Phase 7: CLAUDE.md 部署门禁 ✅

| # | 任务 | 状态 |
|---|------|------|
| 37 | 添加 Deployment Gating Rule（改代码→集成测试→真机）| ✅ |

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
| 13 | Integration tests 新增 4 个 e2e | exec/upload/download/upgrade 端到端 TCP loopback 协议验证，补全 REVIEW 指出的测试缺口 |
| 14 | system.read/write 返回 isize 非 error union | Zig 0.16.0 POSIX 系统调用返回 C 风格返回值，需 @intCast 且不能 try/catch |
| 15 | 部署前必须通过集成测试 | 协议回归（如双 MDELIM）在真机调测前先被集成测试捕获，低修复成本 |

### Phase 8: Windows 跨平台 Socket 抽象层修复 ✅

| # | 任务 | 状态 |
|---|------|------|
| 38 | tcp.zig 新增跨平台 socket I/O 抽象层（sockRead/sockWrite/sockClose/sockShutdown/sockAccept/sockListen/makePair）| ✅ |
| 39 | tests/common.zig 新增相同跨平台 socket 辅助函数（6 个 extern + 7 个 wrapper）| ✅ |
| 40 | 所有 6 个测试文件迁移至 common.zig 统一辅助函数 | ✅ |
| 41 | Winsock2 extern 添加 `callconv(.winapi)` — 修复 x86-windows-gnu 链接 | ✅ |
| 42 | svc.zig LockFileEx Bool 比较修复（`@intFromEnum`）| ✅ |
| 43 | 8 交叉编译目标全部通过 | ✅ |
| 44 | 部署 linuxvm + macvm + windowsvm 真机验证通过 | ✅ |

### Phase 9: E2E 真机 Bug 修复 ✅

| # | 任务 | 状态 |
|---|------|------|
| 45 | 修复 AddressInUse 崩溃循环（TCP listener 缺 SO_REUSEADDR + FD_CLOEXEC）| ✅ |
| 46 | 修复 upload 后 panic（handleUpload 双 close → use-after-free）| ✅ |
| 47 | 修复 utmmd.bin 嵌入构建流程（按目标分目录 + comptime switch）| ✅ |
| 48 | linuxvm E2E 真机验证（5 轮 exec/upload/download 全通过）| ✅ |
| 49 | 修复 Windows SOCKS4a 拒绝（socks4Accept 悬垂栈指针 → socks4CheckAndReply）| ✅ |
| 50 | 修复 Windows upload/download socket I/O（system.read/write → sockRead/sockWrite）| ✅ |
| 51 | windowsvm E2E 全验证（exec + upload + download SHA256 一致）| ✅ |
| 52 | 修复 macOS aarch64 SOCKS4a 拒绝（readUntilNull 栈悬垂指针 → readUntilNullBuf）| ✅ |
| 53 | socks4Accept 悬垂指针修复（改为接受 allocator，堆分配 hostname）| ✅ |
| 54 | 新增 socks4CheckAndReply × 2 + readUntilNullBuf × 3 单元测试 | ✅ |
| 55 | 更新 tcp_frame 集成测试适配新 API | ✅ |

## 关键决策记录（续）

| # | 决策 | 理由 |
|---|------|------|
| 16 | 跨平台 socket I/O 抽象层放在 tcp.zig（非独立文件）| 所有网络 I/O 的统一入口，避免分散 |
| 17 | `callconv(.winapi)` 解决 x86 stdcall 名称修饰 | 32 位 Windows: `.winapi` = `.Stdcall`（`@n` 后缀），64 位: = `.C`（无修饰）|
| 18 | tests/common.zig 复制 tcp.zig 的 socket 抽象 | 测试可执行文件独立编译，不依赖主二进制 |
| 19 | `addr.listen()` 替代 `addr.bind()` + 手动 `fcntl(FD_CLOEXEC)` | `listen()` 原生支持 `reuse_address`；`fcntl` 防止 fork 子进程继承 listener socket |
| 20 | handleUpload 移除 `defer file_pipe.close()` | 显式 close 已覆盖所有退出路径，defer 导致双 close → use-after-free panic |
| 21 | `readUntilNull` → `readUntilNullBuf(fd, buf)` | 缓冲区由调用者提供，消除栈悬垂指针。macOS aarch64 ABI 导致 `std.mem.eql` 覆盖旧栈帧 |
| 22 | `socks4Accept` 改为接受 allocator | 返回的 hostname 堆分配，调用者负责释放。消除 socks4Accept 自身的悬垂指针 |
| 23 | 新增 `socks4CheckAndReply` + `readUntilNullBuf` 测试 | 之前关键路径零测试覆盖；两个函数都是 bug 高发区 |
