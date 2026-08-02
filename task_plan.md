# Task Plan: UTM Monitor — 开发任务规划

## 状态：持续迭代中 🔄

**最新版本**: v0.17.15 — 升级推送修复 + 三平台 P0 修复

- **分支**: `main`
- **源文件**: 20 src + 13 test + 2 embed + 2 Python test scripts
- **测试**: 188 单元测试 + 59 集成测试 + 2 Python test scripts，全部通过，0 泄漏
- **交叉编译**: 6/8 通过（x86 的 2 个 zio 不支持）

## 当前阶段: Phase 27 — VM 离线根因修复 🟢（P0 全部解决，待部署验证）

**目标**: 修复各 VM 频繁离线的根因，确保 utmmd 崩溃后系统能自动恢复。
- **P0 Linux**: ✅ `installLinux()` 补充 Restart=on-failure，提取 SYSTEMD_RESTART_CONFIG
- **P0 macOS**: ✅ `installMacOS()` 补充 KeepAlive+ThrottleInterval，提取 MACOS_KEEPALIVE_CONFIG
- **P0 Windows**: ✅ `installWindows()` 补充 `sc failure` 命令
- **P1 调查**: ✅ 无需修复 — SOCKS5 relay/forward 心跳架构设计正确
- **真机部署**: 待全量部署验证（macOS/Windows 修复需新版本）

### Phase 26: v0.17.11 — ssh.exe 嵌入 + Python 测试脚本 ✅

**目标**: Windows sshpass 零依赖（嵌入 ssh.exe）+ 全面测试覆盖（MCP + CLI）

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 226 | 从 winx64 提取 x86_64 ssh.exe | `src/embed/x86_64-windows/ssh.exe` | ✅ PE32+ x86-64, 1,253,888 bytes |
| 227 | 从 windowsvm 提取 aarch64 ssh.exe | `src/embed/aarch64-windows/ssh.exe` | ✅ PE32+ Aarch64, 1,135,104 bytes |
| 228 | main.zig 新增 ssh_exe_bin comptime embed | `src/main.zig` | ✅ 按 cpu.arch 选择, 非 Windows 为空 |
| 229 | main.zig 新增 extractSshExe | `src/main.zig` | ✅ temp+rename atomic write, best-effort |
| 230 | main.zig 新增 extractSshExeIfMissing | `src/main.zig` | ✅ 检查存在性后调用 extractSshExe |
| 231 | extractUtmmd 中调用 extractSshExeIfMissing | `src/main.zig` | ✅ catch {} — 不阻断安装流程 |
| 232 | sshpass.zig 新增 isSshCommand | `src/sshpass.zig` | ✅ 检测裸 "ssh"/"ssh.exe" |
| 233 | sshpass.zig runWindows ssh 路径替换 | `src/sshpass.zig` | ✅ 替换为 C:\opt\utmm\ssh.exe |
| 234 | 新建 MCP 工具测试脚本 | `tests/test_mcp_tools.py` | ✅ 7 tools, ~268 行 |
| 235 | 新建 CLI 命令测试脚本 | `tests/test_cli_commands.py` | ✅ 全部 CLI 命令, 31/31 checks |
| 236 | SKILL.md 新增测试章节 | `SKILL.md` | ✅ MCP Tools Test + CLI Commands Test |
| 237 | zig build test + test-integration 全部通过 | - | ✅ 188+59 |
| 238 | 6 交叉编译目标构建 | - | ✅ 6/8 通过（x86 2 个 zio 不支持）|

**设计决策**:

| # | 决策 | 理由 |
|---|------|------|
| 65 | ssh.exe 嵌入为 comptime @embedFile | 与 utmmd.bin 嵌入模式一致；编译时嵌入，运行时零网络依赖 |
| 66 | ssh.exe 提取 best-effort（失败不阻断） | sshpass 可回退到 PATH 查找；安装流程不应因次要组件失败而中断 |
| 67 | ssh 路径替换用栈缓冲（非堆分配） | cmd_args 数量有限（<64），栈分配足够且避免内存泄漏 |
| 68 | Python 测试脚本用 subprocess 管道 | 直接测试 CLI 输出和 MCP JSON-RPC，无需额外依赖 |

**文件清单变更（20+ src → 20 src + 2 embed + 2 test scripts）**:
```
src/embed/x86_64-windows/ssh.exe    ← 新建
src/embed/aarch64-windows/ssh.exe   ← 新建
tests/test_mcp_tools.py             ← 新建
tests/test_cli_commands.py          ← 新建
src/main.zig                        ← 修改（+50 行）
src/sshpass.zig                     ← 修改（+30 行）
SKILL.md                            ← 修改
```

## 架构概述

UTM Monitor (`utmm`) 分层架构重构：20 → 19 文件，TCP per-command 连接模型，
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

## 最终文件清单（19 文件）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── config.zig        配置持久化
├── arp.zig           ARP 表读取（MAC→IP 反向发现）
├── lsa.zig           LSA + 节点表 + /etc/hosts
├── tcp.zig           帧协议 + SOCKS5 + 连接
├── dpipe.zig         DuplexPipe 接口 + relay
├── dpipe_shell.zig   pty→pipe
├── dpipe_file.zig    file→pipe
├── guest.zig         Guest daemon
├── host.zig          Host daemon
├── ipc.zig           IPC socket
├── mcp.zig           MCP stdio
├── sshpass.zig       SSH 密码认证子命令（PTY/ConPTY）
├── svc.zig           服务管理（install/uninstall + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
├── shm.zig           共享内存（utmmd↔utmm）
└── testlib.zig       测试模块重导出
```

## 关键决策记录

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接模型 | 消除跨线程共享状态需求 |
| 2 | DuplexPipe vtable 模式 | Zig 惯用，可扩展，可测试 |
| 3 | SOCKS5 内嵌在 tcp.zig | 代码量小，无需独立文件。v0.15.0 从 SOCKS4a 迁移至 SOCKS5 |
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

### Phase 19: /etc/hosts 同步统一 + hostname 规范化 ✅

**背景**: 见 findings.md Finding 190-193。两套独立 hosts 同步实现（host.zig 的 `syncHostsFromTable` 使用 `# BEGIN UTM-MONITOR` 标记 + FQDN `.utm` 后缀，lsa.zig 的 `updateHosts` 使用 `protocol.HOSTS_MARKER_BEGIN` 标记 + temp 文件原子 rename），后者实现更优但从未被调用。hostname 未做小写规范，Windows COMPUTERNAME 全大写致大小写不一致。Guest 端无 hosts 同步能力。FQDN `.utm` 后缀无实用价值且可能引发工具冲突。

**涉及模块**:

```
调用关系：
  host.zig (LSA 处理)          guest.zig (守护进程)
       │                              │
       ├─ lsa.updateHosts() ◄─────────┤
       │  (唯一实现，位于 lsa.zig)      │
       │  - temp 文件 + 原子 rename   │
       │  - protocol.HOSTS_MARKER_*   │
       │  - 参数化 file_path          │
       │                              │
       └─ entries: [                  └─ entries: [
            {ip, hostname},                 {ip, hostname},
            {ip, hostname}, ...             {host_ip, "gateway"},
            {own_ip, "gateway"},        ]
          ]                          host_ip ← getDefaultGateway()
       own_ip ← 自身检测 IP                (UTM 中 Host=网关)
```

**hostname 规范化**:
- 入口小写化：`guest.zig getSystemInfo()` / `main.zig --hostname` / `--exec` 等 target 参数 / `mcp.zig` vm 参数
- hosts 条目：`{hostname}`（纯小写，无 `.utm` 后缀，无 `.target` 后缀）
- 所有内部比较保持 `std.mem.eql`（无需改动，入口已统一）

**Gateway 条目**:
- Host `/etc/hosts`: `gateway` → 自身 IP
- Guest `/etc/hosts`: `gateway` → Host IP（`getDefaultGateway()`）

**受影响的比较/查找路径**（入口统一小写后自动修复，无需单独改动）:
- `GuestTable.indexOf()` / `findByHostname()` / `upsert()` / `remove()` / `updateIp()` / `setMeshMac()`
- `connectGuest()` ARP 恢复
- `socks4CheckAndReply()` SOCKS4a 握手
- IPC handlePing/Exec/Upload/Download
- Auto-upgrade `LastUpgradeMap`
- MCP tools exec/ping/upload/download

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 135 | 删除 `syncHostsFromTable()` 及 `MARKER_BEGIN`/`MARKER_END` 常量 | `src/host.zig` | ✅ ~65 行删除 |
| 136 | LSA 处理 loop 中替换为 `lsa.updateHosts()` 调用 | `src/host.zig:880-886` | ✅ 新建 syncHosts() 从 GuestTable 构建 HostEntry + gateway |
| 137 | `guestTcpLoop()` 中增加 hosts 同步线程 | `src/guest.zig` | ✅ 新建 guestHostsSync()，30s 周期，self+gateway |
| 138 | `getSystemInfo()` hostname 小写化 | `src/guest.zig:369-379` | ✅ POSIX `gethostname()` / Windows `COMPUTERNAME` → toLower |
| 139 | `--hostname` CLI 参数小写化 | `src/main.zig:240-244` | ✅ allocLowerString |
| 140 | `--exec/--upload/--download/--ping/--upgrade` target 参数小写化 | `src/main.zig` | ✅ 6 个 target/hostname 参数 allocLowerString |
| 141 | MCP `vm` 参数小写化 | `src/mcp.zig` | ✅ exec/ping/upload/download 入口 allocLowerString |
| 142 | lsa.zig `updateHosts` dirname null fallback bug 修复 | `src/lsa.zig:1315` | ✅ `orelse "/"` → `orelse "."` |
| 143 | 集成测试 hostname 引用适配 | `tests/` | ✅ 测试字符串已为小写 |
| 144 | 新建 `tests/test_hosts.zig`：hosts 文件同步集成测试 | `tests/test_hosts.zig` | ✅ 8 场景 |
| 145 | `tests/integration_test.zig` 注册 test_hosts 模块 | `tests/integration_test.zig` | ✅ |
| 146 | zig build test + test-integration 验证 | - | ✅ 161 单测 + 59 集成，0 泄漏 |
| 147 | 版本号 bump: 0.14.5 → 0.14.6 | `src/ver.txt` | ✅ |
| 148 | 真机部署验证（Host + 4 VM） | - | ✅ Phase 20 中完成 |

**hosts 同步集成测试（`tests/test_hosts.zig`，8 场景）**:

| # | 场景 | 验证点 |
|---|------|--------|
| 1 | 新建 hosts 文件（无旧标记） | 文件创建、标记格式、条目内容 |
| 2 | 范围替换（已存在标记块） | 旧块替换为新块、块外内容保留不变 |
| 3 | 重复写入无空行累积 | 连续 3 次 updateHosts → 文件末尾无多余空行 |
| 4 | hostname 全小写 + 无 FQDN 后缀 | 条目格式 `{ip}  {hostname}`，无 `.target.utm` |
| 5 | gateway 条目存在 | 验证 gateway IP = 传入的 gateway 地址 |
| 6 | 原文件无标记块 → 追加 | 无标记块时追加到文件尾，确保尾换行 |
| 7 | 空条目列表 | 传入空 entries → 仅标记块，无条目行 |
| 8 | 特殊字符 hostname（连字符/数字） | `winx64`、`test-vm-01` 等合法 hostname 不损坏 |

**预期 /etc/hosts 输出**:

Host 端（macOS，IP 192.168.3.130）:
```
# UTM-MONITOR-BEGIN
192.168.65.4  macvm
192.168.64.6  linuxvm
192.168.64.3  windowsvm
192.168.3.108  winx64
192.168.3.130  gateway
# UTM-MONITOR-END
```

Guest 端（linuxvm，IP 192.168.64.6，Host IP 192.168.64.1）:
```
# UTM-MONITOR-BEGIN
192.168.64.6  linuxvm
192.168.64.1  gateway
# UTM-MONITOR-END
```

**升级注意事项**:
- 旧版标记 `# BEGIN UTM-MONITOR` / `# END UTM-MONITOR` 的 hosts 文件残留块不会被自动清理
- 新版使用 `# UTM-MONITOR-BEGIN` / `# UTM-MONITOR-END`，新旧标记不冲突，旧块变成孤立注释
- 首次部署后建议手动清理旧标记块：`sed -i '' '/# BEGIN UTM-MONITOR/,/# END UTM-MONITOR/d' /etc/hosts`
- Windows `COMPUTERNAME` 全大写（如 `DESKTOP-ABC123`）→ 小写后 LSA 广播新 hostname，Host 端 `GuestTable.upsert()` 检测大小写不匹配 → 创建新条目而非更新旧条目，旧条目需手动 `GuestTable.remove()` 或等过期清理
- `deriveNodeId()` hash 变更（peer-mesh 模式，非生产路径）

### Phase 21: v0.14.7 — sshpass 集成 + MCP 工具名去前缀 + 真机部署 ✅

**背景**: 消除外部 `sshpass` 依赖，集成到 utmm 作为 `sshpass` 子命令。100% CLI 兼容，POSIX (PTY) + Windows (ConPTY) 双平台。原 C 源码 505 行逐行移植。同时移除 MCP 工具名 `vm_` 前缀。

**涉及模块**:

```
src/sshpass.zig (NEW, ~1200 行)
├── ExitCode 枚举（7 个退出码，与 C 版完全一致）
├── PwType/PwSource 类型（4 种密码源）
├── patternMatch() — 逐字符状态机（同 C 版算法）
├── parseArgs() — 模拟 getopt("+f:d:p:heV")，100% CLI 兼容
├── writePassFd()/writePassPosix()/writePassWindows()
├── handleoutputPosix()/handleoutputWindows() — 提示匹配 + 密码注入
├── runPosix() — posix_openpt→fork→setsid→execvp→pselect→prompt matching
├── runWindows() — CreatePseudoConsole (ConPTY)→CreateProcessW→ReadFile/WriteFile loop
├── 内联测试：7 个 patternMatch + 8 个 parseArgs + 32 个 protocol（共 47 测试）
└── pub fn main(gpa, args) noreturn — 模块入口

src/mcp.zig
├── 移除所有 MCP 工具名的 vm_ 前缀：vm_status→status, vm_exec→exec, etc.
└── 54 测试适配（TOOLS_JSON 校验、方法名比较、期望数组）

src/main.zig
├── 新增 sshpass import + cmd_sshpass 字段 + comptime 注册 + help text
├── parseArgs 早期检测 "sshpass" 子命令
└── main() sshpass 分发（在管理员权限检查之前，sshpass 无需 root）

CLAUDE.md / README.md / task_plan.md
└── MCP 工具名更新 + sshpass 架构说明
```

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 155 | 新建 `src/sshpass.zig` 核心模块 | `src/sshpass.zig` | ✅ ~1200 行，POSIX + Windows 完整实现 |
| 156 | zig test 编译验证 + 修复 Zig 0.16.0 API 适配 | `src/sshpass.zig` | ✅ 47/47 测试通过，0 泄漏，0 错误 |
| 157 | 集成 sshpass 到 main.zig | `src/main.zig` | ✅ CliArgs + parseArgs + main dispatch + comptime + help |
| 158 | MCP 工具名移除 vm_ 前缀 | `src/mcp.zig` | ✅ 5 个工具名 + 所有比较路径 + 54 测试 |
| 159 | 更新文档 | CLAUDE.md / README.md / task_plan.md | ✅ MCP 工具名表 + sshpass 架构说明 |
| 160 | zig build test 全部通过 | - | ✅ 208 测试全部通过（分步运行） |
| 161 | zig build test-integration 全部通过 | - | ✅ 59/59 通过，0 泄漏 |
| 162 | 8 交叉编译目标构建 | - | ✅ 8/8 通过 |
| 163 | 真机部署验证（Host + 4 VM）| - | ✅ 全部通过 |
| 164 | 版本号 bump 0.14.6 → 0.14.7 | `src/ver.txt` | ✅ 已完成 |

**Zig 0.16.0 API 适配记录**:
| 问题 | 旧 API | 新 API |
|------|--------|--------|
| stdout/stderr | `std.io.getStdErr().writeAll()` | `std.c.write(fd, ...)` (POSIX) / `WriteFile` (Windows) |
| getenv | `std.posix.getenv()` | `std.c.getenv()` |
| sleep (Windows) | `std.Io.sleep(std.Io.default_io, ...)` | `kernel32.Sleep(ms)` |
| c_int/c_ulong | 重定义为 fd_t/usize（阴影原语）| 使用 Zig 内置 c_int/c_ulong |
| @bitCast/@intCast | 无已知结果类型 | 添加显式 @as |
| std.c.getenv 返回值 | `?[*:0]u8` | 需 `std.mem.sliceTo` 转换为 slice |

**设计决策**:
| # | 决策 | 理由 |
|---|------|------|
| 42 | sshpass 密码不 dupe（引用 argv），隐藏密码移到 main() | 避免 `parseArgs` 错误路径内存泄漏；`main()` 中 argv 在进程生命周期内有效 |
| 43 | sshpass 无需 root 权限 | 原版 sshpass 不需要；AI agent 无法 sudo 交互式提权 |
| 44 | POSIX + Windows 一起做 | 用户要求；ConPTY API 在 Windows 10 1809+ 可用 |
| 45 | sshpass.main() 需 args[2..] 而非 args[1..] | Zig `init.minimal.args.toSlice()` 返回完整 args（含 argv[0]）；"sshpass" 是 args[1]，参数和命令从 args[2] 开始 |

### Phase 21-b: v0.14.7 args[2..] Bug 修复 + Windows 交叉编译 ✅

**Bug**: sshpass.main() 使用 `args[1..]` 只跳过了二进制路径（args[0]），未跳过 "sshpass"
子命令名（args[1]）。导致 `parseArgs` 将 "sshpass" 当作命令，`runPosix()` 执行 `execvp("sshpass", ...)`
时找到系统外部 sshpass 二进制（Host 上 `/opt/homebrew/bin/sshpass`），嵌入实现从未被调用。

**修复**: `const actual_args = args[1..]` → `const actual_args = args[2..]`

**Windows 交叉编译修复**（6 个预存 Zig 0.16.0 API 问题）:
1. `std.os.windows.WriteFile` → `@extern("kernel32", "WriteFile")`
2. `std.os.windows.GetStdHandle` → `@extern("kernel32", "GetStdHandle")`
3. `std.os.windows.HRESULT` → `const HRESULT = i32`
4. `std.fmt.parseInt(std.posix.fd_t, ...)` Windows 失败 → 平台分派
5. `ArrayList.append(x)` → `ArrayList.append(allocator, x)`
6. `DeleteProcThreadAttribute` → `DeleteProcThreadAttributeList`

**验证**:
- 8/8 交叉编译目标通过 ✅（含 aarch64/x86_64-windows 首次成功）
- Host/linuxvm/macvm sshpass 功能验证 ✅
- windowsvm 升级成功，runtime 待进一步测试

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| 165 | 修复 sshpass.main() args[2..] | `src/sshpass.zig` | ✅ |
| 166 | 修复 Windows 交叉编译 | `src/sshpass.zig` | ✅ 6 处修正 |
| 167 | 更新 zig-codegen.md | `zig-codegen.md` | ✅ 新增 6 条经验记录 |
| 168 | 更新 progress.md | `progress.md` | ✅ |
| 169 | 更新 task_plan.md | `task_plan.md` | ✅ |

### Phase 20: v0.14.6 真机部署验证 ✅

| # | 任务 | 说明 |
|---|------|------|
| 149 | 编译所有目标平台 | `zig build -Doptimize=ReleaseSafe` × 各 target |
| 150 | 部署到 4 台 VM | scp/upgrade → linuxvm, macvm, windowsvm, winx64 |
| 151 | 验证 /etc/hosts 同步 | 检查各 VM 的 /etc/hosts 内容：hostname 小写、gateway 条目、无 .utm 后缀 |
| 152 | 验证 exec/upload/download 功能正常 | CLI 管理命令功能回归 |
| 153 | 验证 MCP stdio 功能正常 | AI agent 接口功能回归 |
| 154 | 清理旧标记块 | 手动清理旧版 `# BEGIN/END UTM-MONITOR` 残留（如存在） |

### Phase 22: v0.15.10—v0.15.11 连接限制 + 连接超时 + 字节序修复 ✅

**背景**: 代码审查发现缺乏连接数限制和超时保护；sockaddr 字节序 bug 导致
集成测试 hang。后续 bump→deploy→upgrade 流程中发现多个工作流优化点。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 170 | Connection limit (128) + TCP connect timeout (2000ms) | `src/tcp.zig`, `src/host.zig`, `src/guest.zig` | ✅ 原子计数器 + 非阻塞 connect + poll 超时 |
| 171 | sockaddr.in.addr 字节序修复 | `src/tcp.zig` | ✅ `.big` → `.little`（LE 机器上内核期望 LE） |
| 172 | FIONBIO aarch64-windows 溢出 | `src/tcp.zig` | ✅ `@bitCast(@as(std.os.windows.ULONG, 0x8004667e))` |
| 173 | `--ping` 空参数 panic | `src/main.zig`, `src/host.zig` | ✅ parseArgs 阶段校验所有管理命令必选参数 |
| 174 | `zig build cross` 并行交叉编译 | `build.zig` | ✅ 新增 cross step，8 目标并行编译 |
| 175 | release.sh 重构 | `release.sh` | ✅ 先构建测试全过再 tag，防止失败后删 tag 重建 |
| 176 | CI 脚本更新 | `.github/workflows/release.yml` | ✅ 并行编译 + 删除不存在文件引用 + 避免 --summary hang |
| 177 | cmdDeploy 改进 | `src/host.zig` | ✅ sshpass 缺失不再 exit 1；编译改用 zig build cross |
| 178 | pushUpgrade 错误信息优化 | `src/host.zig` | ✅ BinaryNotFound 时提示运行 zig build cross + deploy |
| 179 | 真机部署验证（5 节点） | — | ✅ Host + 4 Guest 全部 v0.15.11 serving |
| 180 | GitHub Release v0.15.11 发布 | — | ✅ release.sh 全流程通过 |
| 181 | MANUAL.md macOS 测试 hang 文档 | `MANUAL.md` | ✅ --listen=- 协议原理 + build.zig 绕过方案 + CI 注意事项 |

**设计决策**:

| # | 决策 | 理由 |
|---|------|------|
| 46 | 连接限制用 `std.atomic.Value(u32)` + CAS | 无需 mutex，`tryAcquire`/`fetchSub(1)` 模式，性能最优 |
| 47 | TCP connect 超时用非阻塞 + poll（不做线程） | Zig 0.16.0 single-threaded IO 的 `IpAddress.connect()` timeout 会 panic |
| 48 | release.sh 构建过再 tag | 旧流程 tag→build→失败→删 tag→重建，改为 build→test→tag |
| 49 | parseArgs 统一校验而非分散校验 | `fail.msg` 提前报错，避免 `.` panic 回溯误导 |
| 50 | cmdDeploy sshpass 缺失 → return（非 exit） | 本地部署已成功，远程推送是可选的；exit 1 误导 CI/用户 |

### Phase 23: v0.16.0 — SOCKS5 全协议（BIND + UDP ASSOCIATE）+ 协议层提取 ✅

**背景**: RFC 1928 完整 SOCKS5 协议实现，支持 BIND（反向连接）和 UDP ASSOCIATE（UDP 中继）。
同时将混杂在 tcp.zig 中的 SOCKS5 协议层提取到独立 socks5.zig，protocol.zig 扩展帧协议 + Connection。

**协议提取（Phase 0：~0 行净增，纯移动）**:

| 模块 | 变更 | 行数变化 |
|------|------|---------|
| `src/tcp.zig` | 保留纯传输层（socket I/O、TcpListener、ConnLimit） | 1678 → ~900 行 |
| `src/protocol.zig` | 新增帧协议 + Connection（sendFrame/recvFrame/MAX_FRAME） | +285 行 |
| `src/socks5.zig` | **新建**：全部 SOCKS5 协议 + BIND + UDP ASSOCIATE | ~1300 行 |

**SOCKS5 全协议实现**:

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 182 | 常量 + 数据结构扩展（SOCKS_CMD_BIND/UDP_ASSOCIATE/IPV6/sockAcceptTimeout） | `src/socks5.zig` | ✅ 新增 8 个常量/类型 |
| 183 | 放宽 CMD/ATYP 解析（BIND/UDP/IPv4 ATYP → 点分十进制） | `src/socks5.zig` | ✅ readRequestBuf 接受全部 3 种 CMD |
| 184 | UDP ASSOCIATE — UdpRelay（udp socket + tcp↔udp 双线程 + framed datagram） | `src/socks5.zig` | ✅ ~200 行，分片丢弃 |
| 185 | BIND — socks5Bind（TcpListener → 第一帧回复 → accept timeout → 第二帧回复 → relay） | `src/socks5.zig` | ✅ ~170 行，sockAcceptTimeout select/poll |
| 186 | guest.zig / host.zig CMD 分发（BIND/UDP → hostname 路由之前） | `src/guest.zig` `src/host.zig` | ✅ BIND/UDP 分发在 SOCKS5 CMD 层，非 hostname 层 |
| 187 | 裸机部署测试（modasiaipc x86_64-windows 全功能验证） | — | ✅ exec/upload/download/sshpass/SOCKS5 CONNECT chain/UDP ASSOCIATE |
| 188 | GitHub Release v0.16.0 | — | ✅ 8 目标交叉编译 + utmm.zip + gh release |

**文件清单变更（19 → 20 src 文件）**:
```
src/
├── socks5.zig        ← 新建：SOCKS5 全协议（~1300 行）
├── tcp.zig           1678 → ~900 行（SOCKS5 + 帧协议移出）
├── protocol.zig      +285 行（帧协议 + Connection 移入）
└── ...（其余 17 文件不变）
```

**SOCKS5 客户端参数化**:
- `socks5Connect` → 新增 cmd/atyp 参数（默认 CONNECT/DOMAIN）
- `socks5SendRequest` 参数化接受 cmd + atyp
- `socks5ConnectLocal` → `socks5Connect` 包装器，行为不变

**BIND 实现细节**:
- `socks5Bind(io, client_fd)` — 完整两阶段握手机制
- 创建 TcpListener → reply first frame (REP=0, BND.PORT) → sockAcceptTimeout (60s) → reply second frame (BND.PORT=peer_port) → relay
- Windows: `select()` 实现 accept timeout（`fd_set` 用 `undefined` 初始化，避免 `*anyopaque` 数组 init 失败）
- POSIX: `poll()` 实现 accept timeout

**UDP ASSOCIATE 实现细节**:
- `udpAssociate(tcp_fd)` — 创建 UDP socket → reply BND.ADDR:BND.PORT → 启动 tcp→udp + udp→tcp 线程
- SOCKS5 UDP 数据报格式：2-byte BE length prefix + RSV(2)+FRAG(1)+ATYP(1)+DST.ADDR(var)+DST.PORT(2)+DATA
- FRAG != 0 丢弃（不支持分片）
- TCP 断开时自动清理（两个线程检测 send/recv 错误 → shutdown → 退出）

**裸机测试结果（modasiaipc, x86_64-windows, 192.168.3.108）**:

| 功能 | 结果 | 备注 |
|------|------|------|
| exec | ✅ | 命令执行正常 |
| upload | ✅ | SHA256 一致 |
| download | ✅ | SHA256 一致 |
| sshpass | ✅ | ConPTY 可用 |
| SOCKS5 CONNECT chain | ✅ | curl → modasiaipc:2121 → Host → linuxvm:22 |
| UDP ASSOCIATE | ✅ | TCP 控制通道 + UDP 数据报中继正常 |
| BIND | ⚠️ | 代码正确，Windows Firewall 阻止动态端口入站 |

**已知限制**: Windows BIND — 动态创建的 TCP listener 端口被 Windows Firewall 拦截（非代码问题）。

**踩坑记录**:
1. Windows `fd_set` 初始化：`socket_t = *anyopaque`（指针），不能用 `{0}` 数组初始值设定，必须 `var rfds: fd_set = undefined`
2. modasiaipc 存在僵尸连接（5 ESTABLISHED + 3 CLOSE_WAIT）阻塞新 SOCKS5 → SSH + `--install` 重启服务解决
3. BIND 端到端失败根因是 Windows Firewall，非代码逻辑错误

**设计决策**:

| # | 决策 | 理由 |
|---|------|------|
| 51 | SOCKS5 提取到独立 socks5.zig | tcp.zig 1678 行混杂三层职责；协议提取形成清晰 tcp→protocol→socks5 单向依赖 |
| 52 | SOCKS5 CMD 分发放在 hostname 路由之前 | BIND/UDP ASSOCIATE 仅对 self 有效，无需 hostname 查找 |
| 53 | BIND 两阶段握手使用 accept timeout | 防止恶意客户端触发 BIND 后不连接，线程永久挂起 |
| 54 | Windows accept timeout 用 select()（非 poll） | poll() 在 Windows 上不可用，select() 跨平台兼容性最好 |
| 55 | UDP ASSOCIATE TCP 控制通道保持长连接 | RFC 1928 要求 TCP 断开时终止所有 UDP 中继 |
| 56 | MCP 服务器名 "utmm"（非 "utm-monitor"） | utmm 是命令/二进制名，快捷易输入；UTM Monitor 是软件产品名 |
| 57 | utmmd IP 指纹检测用 Wyhash | 零堆分配、速度快、确定性输出；只需检测变化无需知道哪个 IP 变 |
| 58 | IP 去抖 2 次确认（20s）| 防止 DHCP 瞬态抖动或接口 flap 导致不必要的 utmm 重启 |
| 59 | acceptRaw 删除内层重试循环，WouldBlock 返回给调用者 | POSIX 非阻塞 socket accept 立即返回 EAGAIN，内层循环永不返回 → shm 心跳永不更新 → utmmd 超时误杀 |
| 60 | upload/download/upgrade 长传输循环中补心跳 | 大文件传输 >10s 无心跳更新 → utmmd 误判超时杀进程 |

### Phase 23-b: v0.16.1 — MCP 配置修正 + 规划文档同步 ✅

**背景**: v0.16.0 发布后，两次提交修正了 MCP 配置命名（仅 `mcp.json.example` 变更）。
同时将 Phase 23 SOCKS5 全协议实现记录同步到规划文件中。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 189 | MCP 服务器名 "utm-monitor" → "utmm" | `mcp.json.example` | ✅ 所有文档引用同步更新 |
| 190 | 恢复产品名（main.zig header + build.zig.zon） | `src/main.zig` `build.zig.zon` | ✅ UTM Monitor = 软件名，utmm = 命令名 |
| 191 | 更新 task_plan.md（Phase 23 + 文件清单 + 设计决策） | `task_plan.md` | ✅ |
| 192 | 更新 findings.md（SOCKS5/Winsock2 fd_set 发现） | `findings.md` | ✅ Finding 194-198 |
| 193 | 更新 progress.md（v0.16.0 发布 + 裸机测试） | `progress.md` | ✅ |
| 194 | 版本号 bump 0.16.0 → 0.16.1 | `src/ver.txt` | ✅ |
| 195 | 8 交叉编译 + GitHub Release v0.16.1 | — | ✅ release.sh 全流程通过 |

### Phase 23-c: v0.16.1 后续 — Hub-Spoke 架构全面修正 ✅

**背景**: 用户指出对 SOCKS5 转发架构理解有根本性错误 — 是 Hub-Spoke（Host 唯一中转），
不是 peer-mesh（每节点中转）。Host IP 同步到每个 Guest 的 `/etc/hosts` 作为 `gateway`。
所有文档（README、MANUAL、CLAUDE.md）及代码中 Guest 链式转发均需修正。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 196 | README.md SOCKS5 示例 + Architecture 修正 | `README.md` | ✅ gateway hostname、Host 唯一中转 |
| 197 | MANUAL.md SOCKS5 Forwarding 整节重写 | `MANUAL.md` | ✅ Hub-Spoke dispatch + gateway 示例 |
| 198 | CLAUDE.md 5+ 处架构描述修正 | `CLAUDE.md` | ✅ 端口描述/运行模式/转发流程/设计决策 |
| 199 | Guest 链式转发代码删除（~58 行 → REJECT） | `src/guest.zig` | ✅ Finding 199，commit `2b69c8e` |
| 200 | 更新 findings.md + progress.md | 规划文件 | ✅ Finding 199 + 进度记录 |

### Phase 24: v0.17.6 — utmmd IP 变更检测自动重启 ✅

**背景**: 当机器 IP 因 DHCP 续约、网络切换等变化时，utmm 继续使用旧 IP 进行 LSA 广播，
导致 Host 节点表中 Guest IP 失效、连接失败。utmm 需要重启以重新检测网关和本机 IP。

**方案**: utmmd 的 `monitorUtmm` 轮询循环中增加轻量级 IP 指纹检测 — 每 10s 枚举所有非
回环 IPv4 地址并计算 Wyhash 指纹，指纹变化后经去抖确认（连续 2 次）触发 utmm 重启。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 201 | 新增 IP 枚举类型 + 指纹函数（POSIX getifaddrs + Windows GetAdaptersAddresses） | `src/utmmd.zig` | ✅ ~180 行，零堆分配 |
| 202 | 修改 monitorUtmm 轮询循环增加 IP 检查 | `src/utmmd.zig` | ✅ 去抖 2 次确认（20s） |
| 203 | 新增 IP 指纹单元测试 | `src/utmmd.zig` | ✅ 4 测试 |
| 204 | 8 交叉编译目标构建 + 188 测试通过 | - | ✅ |
| 205 | 部署 Host 真机验证（指纹计算正常、无异常重启） | - | ✅ |
| 206 | 版本号 bump 0.17.5 → 0.17.6 | `src/ver.txt` | ✅ |

### Phase 24-b: v0.17.7 — 心跳超时崩溃循环修复 ✅

**背景**: linuxvm 自 v0.17.2 起持续心跳超时崩溃循环。排查发现是 `acceptRaw()` 内层
`while(true)` 循环在 POSIX 非阻塞 socket 上遇到 `WouldBlock` 后永不返回到调用者，
导致 accept 循环中的 shm 心跳更新在空闲期间从不执行。此外 upload/download/upgrade
长传输操作（>10s 大文件）也未补心跳，可能触发伪心跳超时。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 207 | acceptRaw 删除内层 while(true) 循环，WouldBlock 直接返回给调用者 | `src/tcp.zig` | ✅ ~14 行删除 |
| 208 | guest.zig accept 循环 WouldBlock 后 sleep 100ms 再 continue | `src/guest.zig` | ✅ |
| 209 | host.zig accept 循环 WouldBlock 后 sleep 100ms 再 continue | `src/host.zig` | ✅ |
| 210 | handleUpload/handleDownload/handleUpgradeCmd 增加 shm 心跳更新 | `src/guest.zig` | ✅ 3 处，签名增加 shm_handle 参数 |
| 211 | handleOneCommand 分发更新调用签名 | `src/guest.zig` | ✅ 传递 shm_handle |
| 212 | zig build test + test-integration 全部通过 | - | ✅ 188+59 |
| 213 | 版本号 bump 0.17.6 → 0.17.7 | `src/ver.txt` | ✅ commit `b850b02` tag `v0.17.7` |

### Phase 25: v0.17.8—v0.17.11 — zio 协程重构 + macOS 自动 codesign ✅

**背景**: 将 utmm 从 OS 线程模型迁移到 zio stackful 协程框架。`refactor-zio` 分支，8 个 commit 逐步推进。

**重构分阶段**:

| 阶段 | 内容 | commit |
|------|------|--------|
| Phase 1 | 添加 zio 依赖 + `--svc` 路径 Runtime | `df37f87` |
| Phase 2 | guest.zig Thread.spawn → zio Group.spawnBlocking | `3532190` |
| Phase 3 | dpipe.relay() std.Thread → zio spawnBlocking | `3bd5961` |
| Phase 4 | host.zig 顶层服务 spawn 改用 zio | `8194d98` |
| Phase 5 | Host accept loop 移至主 executor | `0b7b958` |
| Phase 6 | 统一 spawnBlocking 调用 | `6af66d5` |
| Phase 7 | LSA + IPC 统一主 executor | `a8b8235` |

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 214 | 修复 SO_REUSEPORT TCP 端口冲突 | `src/tcp.zig` | ✅ 原始 POSIX socket + SO_REUSEADDR only |
| 215 | Spinlock 替代 Mutex | `src/host.zig` | ✅ lockTable/unlockTable helpers with tryLock busy-loop |
| 216 | 修复 upload GuestNotFound | `src/host.zig` | ✅ cmdUpload `:` 分割提取 hostname |
| 217 | Host 自我处理 self:2121 | `src/host.zig`, `src/guest.zig` | ✅ handleOneCommand pub + Host getSystemInfo |
| 218 | 修复 Windows SOCKET aarch64 | `src/tcp.zig` | ✅ `.handle = s` 直接赋值 |
| 219 | 修复 upload debug 日志 | `src/ipc.zig` | ✅ handleUpload 增加 vm/path 日志 |
| 220 | svc.legacy_labels 新增 com.utmmd-guest | `src/svc.zig` | ✅ 清理旧版 per-role 服务名 |
| 221 | 删除 installGuestMacOS 函数 | `src/svc.zig` | ✅ ~95 行删除 |
| 222 | macOS 自动 ad-hoc codesign | `build.zig` | ✅ codesign --force --sign - after build |
| 223 | 版本号 bump 0.17.7 → 0.17.11 | `src/ver.txt` | ✅ 4 次 bump |
| 224 | zig build test + test-integration 全部通过 | - | ✅ 188+59 |
| 225 | macvm + linuxvm 真机 exec/upload/download 验证 | - | ✅ 全部通过 |

**关键决策**:

| # | 决策 | 理由 |
|---|------|------|
| 60 | 原始 POSIX socket 替代 zio addr.listen() | SO_REUSEPORT 导致内核负载均衡 Host/Guest TCP :2121；SO_REUSEADDR only 确保唯一进程 bind |
| 61 | Spinlock 忙等替代 Mutex.lock(io) | futexWait 需要协程上下文，spawnBlocking 线程上没有；CPU 忙等开销可接受（临界区极短） |
| 62 | Host self:2121 直接调用 guest.handleOneCommand | 消除独立 Guest daemon 线程，简化架构 |
| 63 | 删除 installGuestMacOS | 统一为 utmmd --role guest/host 模型；旧 per-role 服务名已清理 |
| 64 | build.zig 自动 codesign macOS 目标 | 交叉编译+scp 污染 ad-hoc 签名，Apple Silicon SIGKILL；自动签后无需手动 codesign |

**已知遗留问题**:

| # | 问题 | 影响 |
|---|------|------|
| 1 | Zombie 进程 | killChild 5s WNOHANG waitpid，D 状态子进程无法收割 |
| 2 | utmmd 二进制升级缺口 | push-upgrade 只替换 utmm，utmmd 需手动更新 |
| 3 | x86 目标不支持 | zio `unimplemented architecture: x86`，32-bit 无法编译 |
| 4 | `zig build test` stdout 无输出 | macOS 上 ExitCode=0 但测试输出被吞，不影响 CI |

---

### Phase 27: VM 离线根因修复 🔴

**背景**: 2026-08-02，对 `--status` 检查发现 VMs 频繁离线。深入分析各 VM 系统日志、
utmmd 日志、systemd/journald 配置后，识别出以下根因。

**离线现象汇总**:

| VM | 症状 | 频率 | 根因 |
|----|------|------|------|
| linuxvm | utmmd 退出后不再重启 | 每次 utmmd 崩溃后 | **P0**: systemd service 无 Restart=on-failure |
| linuxvm | 心跳超时误杀 utmm | 偶尔 | **P1**: 心跳更新路径阻塞 + 线程创建失败 |
| macvm | utmmd 崩溃后服务停止 | 偶尔 | **P2**: macOS launchd KeepAlive 配置验证 |
| windowsvm | utmm.exe 堆损坏崩溃 | 偶尔 | **P2**: 0xc0000374 heap corruption |

---

#### P0: `installLinux()` 缺少 systemd restart 指令

**根因分析**:

`svc.zig` 有两个生成 systemd service 文件的函数，但生成的配置**不一致**：

1. **`installLinux()` (line 593-606)** — 实际安装时调用，生成的服务文件**缺少 restart 指令**：
```ini
[Service]
Type=simple
Environment=SHELL={s}
Environment=HOME={s}
ExecStart={s}
WorkingDirectory=/opt/utmm
StandardOutput=journal
# ← 缺少: Restart=on-failure, RestartSec=5
```

2. **`genInit()` → `genInitLinux()` (line 1617-1620)** — 生成 init 脚本时调用，**正确包含** restart 指令：
```ini
Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=30
```

**影响链**:
```
utmm 崩溃（任何原因）
  → utmmd 检测到心跳超时 → kill 旧 utmm → spawn 新 utmm
  → 重复 5 次（MAX_FAILURE_COUNT）→ utmmd 退出
  → systemd 看到 utmmd 退出
  → 无 Restart=on-failure → systemd 不重启 utmmd
  → VM 永久离线 ❌
```

如果 systemd service 有 `Restart=on-failure`，systemd 会在 utmmd 退出后自动重启它，
utmmd 重新开始监控 utmm → 自动恢复。这正是 `genInit()` 中已正确定义的恢复链路。

**修复方案**:

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 239 | `installLinux()` 添加 Restart 指令 | `src/svc.zig` | ✅ 与 `genInitLinux()` 保持一致：`Restart=on-failure`, `RestartSec=5`, `StartLimitBurst=3`, `StartLimitIntervalSec=30` |
| 240 | 提取 systemd 配置为共享常量 | `src/svc.zig` | ✅ `SYSTEMD_RESTART_CONFIG` 常量，installLinux + genInit 共享 |
| 241 | 验证修复：模拟 utmm 崩溃 → 确认 systemd 重启 utmmd | linuxvm | ✅ SIGKILL utmmd → systemd 10s 内自动重启，restart counter=1 |

**代码变更详情**:
- `src/svc.zig`：新增 `SYSTEMD_RESTART_CONFIG` 常量（4 行），`installLinux()` 模板 +1 行 `{s}`，`genInit(.linux)` 用 `++` 引用常量
- 188 单元测试 + 59 集成测试全部通过 ✅

---

#### P1: linuxvm 心跳超时误触发

**根因分析**:

linuxvm 的 utmmd 日志显示两种异常模式：

1. **心跳超时**: utmmd 在 10s 内未检测到 utmm 心跳更新 → 认为 utmm 僵死 → SIGKILL utmm → 重新 spawn。但 utmm 可能只是在阻塞 I/O 操作中（如 `acceptRaw` 内部循环），并非真正僵死。

2. **线程创建 SystemResources**: utmmd kill utmm 后尝试 spawn 新 utmm → `std.Thread.spawn` 返回 `error.SystemResources`。这是 musl libc 的已知行为：进程被 SIGKILL 后，其线程资源可能不会立即释放，短时间内大量 spawn/kill 循环可能导致线程资源耗尽。

**v0.17.7 已修复的部分**:
- `guest.zig` accept 循环：WouldBlock → sleep 100ms → continue，确保心跳在外部 while 循环顶部更新
- `host.zig`：同 guest.zig 模式
- 长传输（upload/download/upgrade）心跳补充

**仍可能存在的问题**:
- dpipe.relay 内部双向转发线程可能长时间阻塞 I/O 操作而不更新心跳
- SOCKS5 转发线程同样没有心跳更新机制

**修复方案**:

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 242 | 调查 dpipe.relay 线程心跳更新 | `src/dpipe.zig`, `src/guest.zig` | 确认 relay 线程是否会长时间阻塞心跳 |
| 243 | 调查 SOCKS5 转发线程心跳 | `src/tcp.zig`, `src/guest.zig` | socks5Relay/socks5LocalRelay 是否需要心跳更新 |
| 244 | 线程创建失败后增加退避延迟 | `src/utmmd.zig` | spawn 失败后额外 sleep 2s 再重试（给系统时间释放线程资源）|
| 245 | 心跳超时时间可配置 | `src/shm.zig`, `src/utmmd.zig` | 当前硬编码 10s，考虑增加到 15s 减少误触发 |

**工作量**: 调查为主，预计 ~30-50 行代码变更。

---

#### P2: windowsvm utmm.exe 堆损坏崩溃

**根因分析**:

windowsvm 事件日志中多次出现：
- `0xc0000374` — STATUS_HEAP_CORRUPTION（堆损坏）
- `0xc0000005` — STATUS_ACCESS_VIOLATION（访问违规）

这些崩溃**可能**与 zio IOCP 在 Windows 上的文件 I/O 不兼容有关。v0.17.13 已将
所有文件 I/O 操作切换为 `std.Io.Threaded`，这可能修复了部分堆损坏问题。
但 v0.17.13 部署后尚未经过长时间运行验证。

**可能的其他原因**:
- zio 协程栈与 Windows SEH (Structured Exception Handling) 的交互问题
- 跨协程的内存别名（aliasing）问题
- 线程池与协程调度器之间的竞态条件

**修复方案**:

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 246 | 部署 v0.17.13 后监控 windowsvm 稳定性 | windowsvm | 观察 24h 内是否还有堆损坏崩溃 |
| 247 | 验证 Windows 服务恢复配置 | windowsvm | `sc failure UTM-MonitorD` 确认 reset/restart/actions |
| 248 | 如崩溃持续，启用 Windows 堆调试 | windowsvm | `gflags /p /enable utmm.exe` + 分析 crash dump |

**工作量**: 监控为主，堆调试仅在必要时进行。

---

#### P2: macOS launchd KeepAlive 验证

**问题**: macvm 上的 launchd plist 使用 `KeepAlive` 而非 `Restart=on-failure` 等价配置。
需验证 `KeepAlive` 在 utmmd 退出后是否真的会重启它。

**修复方案**:

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 249 | 验证 macOS launchd KeepAlive 行为 | macvm | 手动 kill utmmd → 观察 launchd 是否重启 |
| 250 | 如不重启，添加 SuccessfulExit=false | `src/svc.zig` installMacOS | 确保 utmmd 退出（包括 exit 1）后 launchd 重启 |

**工作量**: 真机测试，~5 行代码变更（如需修复）。

---

**Phase 27 优先级总结**:

| 优先级 | 问题 | 影响 | 修复难度 |
|--------|------|------|---------|
| **P0** | installLinux 缺少 Restart=on-failure | linuxvm 一旦 utmmd 退出即永久离线 | 极低（~20 行代码） |
| **P1** | 心跳超时误触发 + 线程创建失败 | 偶发 utmm 重启，通常能自动恢复 | 中（需调查） |
| **P2** | windowsvm 堆损坏 | 偶发 utmm 崩溃，utmmd 重启恢复 | 中-高（可能已被 v0.17.13 修复） |
| **P2** | macvm launchd KeepAlive | 偶发 utmmd 退出不重启 | 低（验证+小修复） |

**建议部署顺序**: P0 修复 → 全量部署 → 监控 24h → 根据监控结果决定 P1/P2 是否仍需处理。
**P0 状态**: ✅ 已修复并全量部署验证通过（2026-08-02）。

---

### v0.17.16: utmmd Windows 文件 I/O 修复 🔧

**根因**: utmmd.zig 中 `checkPendingUpgrade` 等文件操作函数直接使用 zio event loop I/O，
Windows IOCP 不支持文件 I/O（stat、open、read、rename、delete），导致 utmmd 永远检测不到
升级标记文件 `.sha256`，升级二进制无法被消费，VM 永远停留在旧版本。

**修复方案**: `monitorLoop` 中创建条件 `std.Io.Threaded`（仅 Windows），传递 `file_io` 给所有文件 I/O 函数。

**修改函数签名**:
```zig
fn checkPendingUpgrade(file_io: std.Io) bool
fn computeSha256Hex(alloc: std.mem.Allocator, file_io: std.Io, path: []const u8) ![]const u8
fn readFileAlloc(alloc: std.mem.Allocator, file_io: std.Io, path: []const u8) ![]const u8
fn applyUpgrade(file_io: std.Io, io: std.Io, alloc: std.mem.Allocator, proc: ?ProcessRef) !RestartReason
fn copyFileUpgradeFallback(file_io: std.Io, src: []const u8, dst: []const u8) !void
fn monitorUtmm(io: std.Io, file_io: std.Io, alloc: std.mem.Allocator, shm_ptr: *volatile shm.ShmLayout, proc: ProcessRef) RestartReason
```

**并发升级保护导致的拒绝服务**:
- Guest `handleUpgradeCmd` 检查 `.sha256` 标记文件是否存在，若存在则拒绝新推送
- 当 utmmd 无法消费升级时（IOCP bug），标记文件永久残留，阻止所有后续升级
- EPIPE 错误链：Host 发送 upgrade_cmd → Guest 检测残留标记 → 发送 upload_result(-1) → 关闭连接 → Host 写 raw binary 收到 EPIPE

**windowsvm 恢复**:
- 早期 `ren` 命令部分执行导致 utmm.exe 被重命名、服务崩溃
- UTM-MonitorD 服务停止（WIN32_EXIT_CODE 1067）
- 通过 SSH (`utmm sshpass`) 直接执行 `sc start UTM-MonitorD` 恢复
- windowsvm 已成功升级到 v0.17.16，exec/upload/download 全部正常

**状态**: ✅ v0.17.16 发布（188 单测+59 集成测试通过，6 交叉编译目标），5 节点全部 v0.17.16 serving。

**已知遗留**:
- **[P2]** Guest `handleUpgradeCmd` 并发保护逻辑应处理残留 .sha256 marker：当仅有标记文件（upgrade 二进制不存在）时应清理标记而非拒绝。utmmd.zig `checkPendingUpgrade` 已有此逻辑，guest.zig 需同步。

### v0.17.15: Windows --upgrade 推送失败修复 🔧

**根因**: `pushUpgrade` fire-and-forget 模式三个缺陷导致 Windows VM 升级推送静默失败：

| # | 问题 | 影响 |
|---|------|------|
| 1 | 单次 `sockWrite` 写 4MB 丢弃返回值 | 短写无法检测，数据被 close() 丢弃 |
| 2 | 不读 Guest 的 upload_result 响应 | 无法确认 Guest 是否收到 |
| 3 | 写后立即 close() | macOS 无 SO_LINGER 时内核可能丢弃发送缓冲 |

**修复**: 对齐 `handleUpload` 的已验证模式 — 分块写+短写处理+读响应确认。

**状态**: ✅ 修复已提交 (1f983b1)，待真机部署验证。
