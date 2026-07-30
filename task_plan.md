# Task Plan: v0.13.0+ — 分层架构重构

## 状态：持续迭代中 🔄

**最新版本**: v0.14.5 — ARP MAC→IP 反向发现 + 集成测试

- **分支**: `refac/layered-arch`
- **源文件**: 17 src + 11 test（10 集成测试 flat file + 1 common）
- **测试**: 161 唯一单元测试 + 51 集成测试场景，全部通过
- **真机验证**: linuxvm + windowsvm + macvm + winx64 — 4 台全 v0.14.4 ✅
- **ARP 恢复**: connectGuest 自动 ARP 重发现 + 10 集成测试覆盖 ✅

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

## 最终文件清单（17 文件）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── config.zig        配置持久化
├── arp.zig           ARP 表读取（MAC→IP 反向发现）
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

### Phase 10: v0.14.1 — 集成测试重构 + ReleaseSafe 强制 + 临时文件清理修复 ✅

| # | 任务 | 状态 |
|---|------|------|
| 56 | 集成测试重构：8 独立可执行文件 → 单入口 flat file（`tests/integration_test.zig`）| ✅ |
| 57 | 统一 DebugAllocator + TestRunner + 内存泄漏检测 | ✅ |
| 58 | 9 个集成测试文件从子目录迁移到 flat `pub fn test_xxx()` 签名 | ✅ |
| 59 | 修复 `_ = io` pointless discard（test_tcp_frame.zig Zig 0.16.0 编译错误）| ✅ |
| 60 | 修复 x86_64-linux-musl Debug 80MB 二进制（`.data.rel.ro` = 20MB → ReleaseSafe 11MB）| ✅ |
| 61 | ReleaseSafe 强制：release.sh + CI workflow + CLAUDE.md 全部使用 `-Doptimize=ReleaseSafe` | ✅ |
| 62 | 临时文件清理审计：dpipe_file.zig writeFile errdefer 清理 temp 文件 + guest.zig 双 close 修复 | ✅ |
| 63 | 8 交叉编译目标 ReleaseSafe 构建 + 二进制尺寸验证 | ✅ |
| 64 | 4 台真机部署：linuxvm/macvm/windowsvm/winx64 全 v0.14.1 + 烟雾测试 | ✅ |
| 65 | 更新 task_plan.md + progress.md + CLAUDE.md | ✅ |

**集成测试重构详情**：
- 8 个旧目录删除：`tests/tcp_frame/`, `tests/lsa_routing/`, `tests/dpipe_relay/`, `tests/svc_install/`, `tests/exec_e2e/`, `tests/upload_e2e/`, `tests/download_e2e/`, `tests/upgrade_e2e/`
- 9 个新 flat file 创建：`tests/common.zig`, `tests/integration_test.zig`, `tests/test_tcp_frame.zig`, `tests/test_lsa_routing.zig`, `tests/test_dpipe_relay.zig`, `tests/test_svc_install.zig`, `tests/test_exec_e2e.zig`, `tests/test_upload_e2e.zig`, `tests/test_download_e2e.zig`, `tests/test_upgrade_e2e.zig`
- `build.zig` 简化：8 个独立 executable → 1 个 `integration_test` executable + `test-integration` step
- 40 测试场景全部通过，0 失败，0 泄漏

**Bug 修复详情**：
1. dpipe_file.zig writeFile errdefer：`createFile()` 成功后 `allocator.create(WriteFileCtx)` 失败 → 只 close 不 delete → temp 文件泄露。修复：errdefer 增加 `deleteFile` 调用
2. guest.zig handleUpgradeCmd：`defer file.close(io)` + 显式 `file.close(io)` → 双 close。修复：移除 defer

**x86_64 二进制尺寸根因**：
- x86_64-elf Debug 模式 `.data.rel.ro` 段 = 20.3MB（relocation data for read-only data, stack traces, lazy symbol resolution）
- aarch64 无此段（Mach-O/ELF 均无）
- ReleaseSafe 消除此段：x86_64-linux-musl 从 80MB → 11MB

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
| 24 | 集成测试从独立可执行文件改为单入口 flat file | 统一 leak detection + 简化 build.zig + 零独立 main.zig 样板 |
| 25 | ReleaseSafe 强制所有发布构建 | Debug x86_64 80MB → ReleaseSafe 11MB；所有 release 路径统一使用 `-Doptimize=ReleaseSafe` |

### Phase 11: v0.14.2 — 升级系统重构 + 质量修复 ✅

| # | 任务 | 状态 |
|---|------|------|
| 66 | macOS launchctl bootstrap errno=5 根因修复（bootout 重设 disabled flag → enable after bootout）| ✅ |
| 67 | 跨平台路径审计：host.zig 3 处 + ipc.zig 1 处硬编码路径 → `svc.canonicalDir()` | ✅ |
| 68 | 临时文件泄露修复：dpipe_file.zig rename 失败时 deleteFile + guest.zig 启动扫描清理 | ✅ |
| 69 | 升级系统重构：Guest 自主升级 → Host 主控直推（`--upgrade <vm>`）| ✅ |
| 70 | 删除旧升级代码：upgrade_req、auto_upgrade、UpgradeSignal、checkGitHubVersion、verifyServeDirBinaries、upgradeTcpListener、handleUpgradeConnection、isValidVersion | ✅ |
| 71 | 新增 upgrade_cmd (0x1a) 协议 + guest.handleUpgradeCmd + host.cmdUpgrade + ipc.handleUpgrade | ✅ |
| 72 | 新增 upgrade_e2e 集成测试（7 场景：正常/哈希不匹配/0字节/大文件/SOCKS4a/重传/并发）| ✅ |
| 73 | 4 VM 遗留垃圾清理（旧服务名、temp 文件、日志、deploy 残留）| ✅ |
| 74 | Windows VM 启用 OpenSSH Server，替代 SMB/RDP 手动操作 | ✅ |
| 75 | 硬编码远程路径修复：host.zig cmdUpload + mcp.zig cmdVmUpload → 平台感知 remote_dir | ✅ |
| 76 | 4 处陈旧注释修正：auto-upgrade 描述 → Host 直推模型 | ✅ |
| 77 | deploy SKILL 更新：Windows SMB 手动 → SSH 命令；clean-deploy SKILL 新建 | ✅ |
| 78 | 版本号 bump: ver.txt 0.14.1 → 0.14.2 | ✅ |

**升级系统重构详情**：
- Guest 侧删除：`UpgradeSignal` struct、`tryPerformUpgrade` 函数（~120 行）、LSA 版本比对、`auto_upgrade` 门控
- Guest 侧新增：`handleUpgradeCmd`（~110 行）— 接收 upgrade_cmd 帧 + 流式二进制 → 增量 SHA256 → 通知 utmmd via shm
- Host 侧删除：`checkGitHubVersion`（~55 行）、`verifyServeDirBinaries`（~40 行）、`upgradeTcpListener`（~40 行）、`handleUpgradeConnection`/`serveUpgradeFile`（~70 行）、`isValidVersion`（~15 行）、`upgrade_signal` + `upgrade_shutdown` 原子变量
- Host 侧新增：`cmdUpgrade` → `ipcUpgrade`（查 GuestTable → SOCKS4a 连接 → 推送 upgrade_cmd + 二进制流）
- IPC 新增：Request.upgrade (0x07) → handleUpgrade（从 serve-dir 读取二进制 → SOCKS4a 连接 → 推送）
- CLI 新增：`--upgrade <vm>` 参数（`cmd_upgrade` + `upgrade_target`）
- 完全删除 Guest 自主升级路径 — Host 通过 SOCKS4a 直推，复用以 `upload_result` (0x17) 响应
- 升级后 utmmd 自动检测退出原因 (Cmd.upgrade) → rename temp → 重启 utmm

## 关键决策记录（续 2）

| # | 决策 | 理由 |
|---|------|------|
| 26 | 升级系统：Guest 自主 → Host 主控直推 | Guest 自主升级不可控（版本号变动触发全集群升级混乱），Host 直推按需触发 |
| 27 | 复用以 `upload_result` (0x17) 作为升级响应 | 格式完全一致：cmd_id + exit_code，无需新消息类型 |
| 28 | 升级 temp 文件用 `svc.tempDir()` | dpipe_file 写 `/tmp` = 跨文件系统 rename 高概率失败（特别是 macOS），升级二进制直接写 `canonicalDir()` 避免 EXDEV |
| 29 | Windows SSH 替代 SMB/RDP | 自动化部署和清理必须 SSH；Windows 10 1809+ 内置 OpenSSH Server |
| 30 | mcp.zig `guestDefaultDir()` 平台感知默认路径 | 无 host.zig 导入通路（MCP 为独立进程），使用 VM 名 "win" 前缀推断 Windows 路径 |
| 31 | deploy/clean-deploy SKILL 二进制名含版本号 | 交叉编译产物含版本后缀（如 `utmm-aarch64-macos-0.14.2`），部署时必须用实际文件名 |
| 32 | Windows `Stop-Process -Force` 替代 `taskkill /F` | `taskkill /F` 无法终止 SYSTEM 权限 utmm 进程，PowerShell `Stop-Process -Force` 有效 |

### Phase 12: v0.14.2 裸机部署验证 ✅

| # | 任务 | 状态 |
|---|------|------|
| 79 | 全量清空 5 台机器（Host + 4 VM）→ 0 残留进程/文件 | ✅ |
| 80 | 构建：单元测试 + 集成测试 (41 pass) + 4 交叉编译 | ✅ |
| 81 | 部署：Host (macOS) + linuxvm + macvm + windowsvm + winx64 | ✅ |
| 82 | Exec 测试：linuxvm/macvm/windowsvm/winx64 全部 OK | ✅ |
| 83 | Upload 测试：4 VM 全部 OK，SHA256 一致 | ✅ |
| 84 | Download 测试：4 VM 全部 OK (56 bytes)，SHA256 一致 | ✅ |
| 85 | Ping 测试：4 VM 全部 OK (RTT 0-9ms) | ✅ |

**踩坑记录**:
1. Windows `taskkill /F` 无法终止 SYSTEM 权限 utmm → 需 PowerShell `Stop-Process -Force`
2. linuxvm SSH 长命令链 exit 255 → 拆分为多个短 SSH 调用
3. winx64 `waitOldProcesses` 5s 超时 → 旧进程残留触发了超时等待
4. 交叉编译产物同时保留新旧版本后缀 → 部署时需手动选择正确版本

### Phase 13: v0.14.3 — 自动升级启用 + Windows API 进程管理 ✅

| # | 任务 | 状态 |
|---|------|------|
| 86 | 自动升级编译时开关 `AUTO_UPGRADE = true`（protocol.zig）| ✅ |
| 87 | host.zig 新增 `pushUpgrade()`（serve-dir 读取 + SHA256 + SOCKS4a 推送）| ✅ |
| 88 | host.zig 新增 `LastUpgradeMap` + `pushUpgradeThread`（120s 冷却）| ✅ |
| 89 | host.zig `tunnelManager` Phase 2 新增 LSA 版本检测 + 自动推送 | ✅ |
| 90 | ipc.zig `handleUpgrade` 重构：~110 行 → ~25 行，复用 `pushUpgrade()` | ✅ |
| 91 | svc.zig 新增 w32 命名空间：Toolhelp 进程枚举 + TerminateProcess API | ✅ |
| 92 | svc.zig `killAllUtmm` Windows 分支重写：CreateToolhelp32Snapshot → Process32FirstW/NextW → OpenProcess → TerminateProcess | ✅ |
| 93 | svc.zig `countOtherUtmmProcesses` Windows 分支重写：同上枚举计数 | ✅ |
| 94 | host.zig Windows upload 路径分隔符修复（"/" → std.fs.path.sep_str）| ✅ |
| 95 | SKILL 文件版本号批量更新（clean-deploy/deploy/utmm: 0.14.1 → 0.14.2）| ✅ |
| 96 | 清理 8 个旧构建产物 `zig-out/bin/*-0.14.1*` | ✅ |
| 97 | 版本号 bump: ver.txt 0.14.2 → 0.14.3 | ✅ |
| 98 | 8 交叉编译目标构建 + 集成测试 41/41 通过 | ✅ |

### Phase 14: v0.14.3 — linuxvm 重建 + 文档更新 ✅

| # | 任务 | 状态 |
|---|------|------|
| 99 | linuxvm 重建：UTM phantom VM 清理 + Ubuntu Desktop 24.04 重装 | ✅ |
| 100 | linuxvm SSH 配置：PermitRootLogin + PasswordAuthentication | ✅ |
| 101 | linuxvm 部署 v0.14.3 + exec/upload/download/ping 验证 | ✅ |
| 102 | 临时 Lima VM `utmm-test` 创建 + socket_vmnet 桥接网络探索 | ✅ |
| 103 | 发现 `detectUnixIp()` 多 NIC bug（eth0 先于 lima0）+ Lima VM 上修复验证 | ✅ |
| 104 | 发现 `upsert()` 不检查 MAC 变化（cosmetic bug，host.zig:969-974）| ✅ |
| 105 | CLAUDE.md + SKILL.md linuxvm IP 更新（192.168.64.2 → 192.168.64.6）| ✅ |
| 106 | progress.md + task_plan.md 更新 | ✅ |

### Phase 15: v0.14.3 — Bug 修复 ✅

| # | 任务 | 状态 |
|---|------|------|
| 107 | 修复 `detectUnixIp()` 多 NIC 偏好：新增 `isLikelyVmNat()` 跳过 VM NAT 范围 | ✅ |
| 108 | 修复 `upsert()` MAC 检测：新增 MAC 字段比对和更新 | ✅ |
| 109 | 新增 `isLikelyVmNat` 单元测试（3 组：QEMU/libvirt/Normal）| ✅ |
| 110 | 新增 `GuestTable upsert detects MAC change` 单元测试 | ✅ |
| 111 | 推送 5 个本地 commit 到 remote | ✅ |
| 112 | 临时 Lima VM `utmm-test` 清理确认（无残留）| ✅ |

**修复详情**:
1. `detectUnixIp()` (guest.zig:305-350)：从"返回第一个物理 NIC"改为"收集候选 → 优先返回非 NAT → 回退到第一个"。新增 `isLikelyVmNat()` 检查 10.0.2.0/24（QEMU/VirtualBox 默认 NAT）和 192.168.122.0/24（libvirt 默认 NAT）
2. `upsert()` (host.zig:951-1012)：新增 `existing.mac` 比对（第 975 行）和更新逻辑（第 1002-1005 行），与 ip/target/version/shell/status/role 保持一致模式

**踩坑记录**:
1. UTM bundle 可能因 QEMU 崩溃/磁盘空间不足从文件系统消失，UTM Registry 与磁盘不同步
2. Lima `socket_vmnet` symlink 被拒绝 → 必须 cp 实际二进制
3. `/etc/sudoers.d/lima` 权限 wheel → admin（dasimo 在 admin 组非 wheel）
4. `detectUnixIp()` 返回第一个物理 NIC，多 NIC VM 可能返回不可达 IP
5. Lima `lima:shared` 网络模式 = socket_vmnet + vmnet-shared，提供主机到 VM 直接 connectivity

## 关键决策记录（续 3）

| # | 决策 | 理由 |
|---|------|------|
| 33 | 自动升级 Host 端 LSA 版本检测 + 推送 | Host 已每 5s 解析所有 Guest 版本，零额外开销。编译时常量 false 时死代码消除 |
| 34 | Windows 进程杀死换用 Toolhelp + TerminateProcess API | `taskkill /F` 无法终止 SYSTEM 权限进程；原生 API 层面终止 |
| 35 | `sc.exe stop` 不可靠 → 不杀 utmmd.exe | utmmd 应通过服务管理器停止；killAllUtmm 只杀 utmm.exe 是正确的设计 |
| 36 | `detectUnixIp()` 跳过 VM NAT 地址 | 新增 `isLikelyVmNat()` 检查 10.0.2.x (QEMU/VirtualBox) 和 192.168.122.x (libvirt)。多 NIC VM 优先选择非 NAT 接口，回退到第一个物理 NIC |
| 37 | `upsert()` 检测 MAC 地址变化 | 新增 MAC 字段比对和更新逻辑。VM 重装后 MAC 变更可在 status 中正确显示 |
| 38 | 全量注释清理 | 扫描并修复 src/ 下所有 KCP/HTTP/WebUI/tunnel manager/mesh relay 过时注释。main.zig (10+), host.zig (~15), mcp.zig (2), protocol.zig (1)。41/41 测试通过 |
| 39 | ARP MAC→IP 反向发现 | 当 Guest IP 变化时（UTM 网络常见），Host 通过系统 ARP 表由已知 MAC 反查新 IP，自动恢复连接。跨平台实现：Linux `/proc/net/arp`、macOS `arp -a`、Windows `GetIpNetTable` |
| 40 | 字节级 MAC 比较 | MAC 格式差异（LSA 补零 `9e:06` vs arp 不补零 `9e:6`）导致字符串比较失败。`parseMacBytes` + `macMatch` 用 `[6]u8` 字节数组比较，彻底消除格式依赖 |
| 41 | ARP 集成测试覆盖补零差异 | 10 个集成测试覆盖 parseMacBytes/macMatch/rediscoverIp/lookupIp 全链路。`macMatch` 跨格式测试是核心回归防护：若未来有人改回字符串比较，测试立即失败 |

### Phase 16: v0.14.3 — 源码注释清理 ✅

| # | 任务 | 状态 |
|---|------|------|
| 113 | main.zig 注释更新（模块 doc、字段 doc、help text、行内注释）| ✅ |
| 114 | host.zig 注释更新（HTTP handlers、tunnel manager、pushUpgrade doc）| ✅ |
| 115 | mcp.zig 注释更新（handleVmStatus、handleVmExec）| ✅ |
| 116 | protocol.zig KCP 过时注释重写 | ✅ |
| 117 | guest.zig 注释审计（无需修改）| ✅ |
| 118 | 全量 grep 扫描确认无残留过时引用 | ✅ |
| 119 | zig build test + test-integration 验证 | ✅ |
| 120 | progress.md + task_plan.md 更新 | ✅ |

### Phase 17: v0.14.4 — ARP MAC→IP 反向发现 ✅

| # | 任务 | 状态 |
|---|------|------|
| 121 | 新建 `src/arp.zig`：跨平台 ARP 表读取（Linux `/proc/net/arp`、macOS `arp -a`、Windows `GetIpNetTable`）| ✅ |
| 122 | `parseMacBytes` + `macMatch`：字节级 MAC 比较，解决 LSA 补零 vs arp 不补零格式差异 | ✅ |
| 123 | `host.zig` 新增 `connectGuest()`：TCP 连接失败 → ARP 查 MAC → 更新 IP → 重试 | ✅ |
| 124 | `host.zig` 新增 `GuestTable.updateIp()`：运行时更新 Guest IP | ✅ |
| 125 | `ipc.zig` `handleExec`/`handleUpload`/`handleDownload` 统一使用 `connectGuest()` | ✅ |
| 126 | `utmmd.zig` Zig 0.16.0 兼容修复（`Child.init` → `std.process.run`）| ✅ |
| 127 | MCP 测试覆盖扩展（54 测试）| ✅ |
| 128 | 4 台真机部署验证（macvm/linuxvm/windowsvm/winx64）| ✅ |

**ARP 实现详情**：
- `arp.zig`（~245 行）：平台特定 ARP 表查询
  - Linux：`std.Io.Dir.cwd().openFile("/proc/net/arp")` + 逐行解析
  - macOS：`std.process.run("arp -a")` + 括号/at/on 正则解析
  - Windows：`extern "iphlpapi" GetIpNetTable` 原生 API
- `parseMacBytes()`：冒号分隔 6 段 → `[6]u8`，`parseInt(u8, part, 16)` 自动处理补零
- `macMatch()`：字节级比较，忽略 `9e:6` vs `9e:06` 差异
- `rediscoverIp()`：`lookupIp(mac)` → 比对 current_ip → 相同返回 null

**修复的关键 Bug**：
1. MAC 格式不匹配：LSA 存 `9e:06:4f:79:db:fe`（补零），macOS `arp -a` 输出 `9e:6:4f:79:db:fe`（不补零）→ 字符串比较失败。修复：字节级比较。
2. Windows `LoadLibraryA` 移除（Zig 0.16.0）→ 改用 `extern "iphlpapi"` 直接声明
3. Windows `BOOL` 是 enum → `0` 改为 `.FALSE`
4. Linux `std.fs.openFileAbsolute` 移除 → `std.Io.Dir.cwd().openFile(io, ...)`

### Phase 18: v0.14.5 — ARP 集成测试 + 发布 ✅

| # | 任务 | 状态 |
|---|------|------|
| 129 | `src/arp.zig` `parseMacBytes`/`macMatch` 改为 pub + 新增 17 个单元测试 | ✅ |
| 130 | `src/testlib.zig` 导出 arp 模块 | ✅ |
| 131 | 新建 `tests/test_arp.zig`：10 个 ARP 集成测试场景 | ✅ |
| 132 | `tests/integration_test.zig` 注册 test_arp 模块 | ✅ |
| 133 | 修复 `lookupIpLinux` Zig 0.16.0 API（`openFileAbsolute` → `openFile` + `close(io)` + `readStreaming`）| ✅ |
| 134 | v0.14.5 release：8 目标交叉编译 + utmm.zip + GitHub release | ✅ |

**ARP 集成测试覆盖（10 场景）**：
| 场景 | 内容 | 防护目标 |
|------|------|---------|
| parseMacBytes zero-padded | `9e:06:4f:79:db:fe` → 6 bytes | 解析回归 |
| parseMacBytes non-zero-padded | `9e:6:4f:79:db:fe` → 6 bytes（相同）| 格式差异 |
| parseMacBytes invalid | 非hex/4段/7段/空串 → null | 鲁棒性 |
| macMatch cross-format | LSA 补零 vs arp 不补零 → 匹配 | **核心回归**：补零差异 |
| macMatch different MAC | 不同 MAC → false | 误匹配 |
| macMatch invalid hw | 空串/垃圾 → false | 鲁棒性 |
| rediscoverIp bogus MAC | `ff:ff:ff:ff:ff:ff` → 调系统 ARP 表 | 完整调用链 |
| rediscoverIp empty MAC | 空串 → null | 边界条件 |
| rediscoverIp same-IP | 不存在 MAC → null（验证路径）| 不变检测 |
| lookupIp real macOS | 真实 `arp -a` 输出解析 | 系统集成 |
