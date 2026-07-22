# Task Plan: v0.5.0 pty Session Model

## 目标
用持久 pty session 替换 "Connection = Shell Session"（每命令断连重连）模型。每个 WebSocket 连接 spawn 一个持久 shell（POSIX `posix_openpt` / Windows `CreatePipe`），命令在同一个 shell 中执行。`cd` 和 `export` 真正持久化。

**核心变更：**
- 每 WS 连接一个持久 shell session（非每命令一个进程）
- 命令通过 pty stdin 输入，输出从 pty stdout 读取
- `MDELIM:$?\n` 退出码标记嵌入输出流
- HostState 从 pending queue 模型改为 outgoing_frames queue + OpState 模型
- HTTP handler 通过 frame queue 与 WS handler 通信（非直接写 WS）

## Phases

### Phase 0: 新 pty 消息类型 ✅
- [x] wsproto.zig — 新增 pty_spawn(2), pty_input(3), pty_output(4), pty_signal(5), pty_resize(6)
- [x] 删除旧 exec_* 类型 (2,3,8,9,10,11,12)
- [x] 重新编号保留类型
- [x] build/parse 函数 + 测试
- **Status:** complete

### Phase 1: ptySpawn + ptyReadLoop ✅
- [x] **POSIX ptySpawn**: posix_openpt → grantpt/unlockpt → fork → setsid → dup2 → execve(shell, argv, std.c.environ)
- [x] **Windows ptySpawn**: CreatePipe × 2 → CreateProcessW("cmd.exe /k") with STARTF_USESTDHANDLES
- [x] **ptyReadLoop**: 独立线程 poll pty master fd，构建 pty_output 帧
- [x] POLL.HUP 检测 shell 退出，设置 pty_dead
- [x] Windows: ReadFile blocking loop，shell 退出时 break
- [x] macOS/BSD: tcsetattr ECHO disable 在 pty master 上不支持 → Host 侧 lastIndexOf 处理命令回显
- **Status:** complete

### Phase 2: wsAnnounceLoop 重写 ✅
- [x] connect WS → send announce → receive pty_spawn → ptySpawn + start ptyReadLoop
- [x] main loop: readFrame → switch msg type:
  - pty_input(3) → write to master_fd, update active_cmd_id
  - pty_signal(5) → killForegroundProcess
  - upload_req → writeFile
  - download_req → readFile + download_resp
  - pty_resize → 解析但暂不应用 (TIOCSWINSZ stub)
- [x] pty_dead → break loop → reconnect
- [x] 删除: spawnExecStream, spawnExecStreamWindows, execStdoutThread, windowsExecThread, drainStdoutToWs, killChildProcess
- **Status:** complete

### Phase 3: HostState 重构 ✅
- [x] **删除**: CmdType, CmdStatus, PendingCmd, CmdResult, pending HashMap, kicked HashMap, SignalEntry, pending_signals, drainPending, deliverResult, deliverStdoutChunk, deliverExecExit, failGuestPending, markKicked, checkKicked
- [x] **新增**: outgoing_frames (per-guest FIFO), op_states (HashMap of OpState), close_requests
- [x] **新方法**: enqueueOutgoingFrame, dequeueOutgoingFrame, createOpState, appendOpOutput, completeOpState, scanForMarker, takeOpResult, requestClose, checkCloseRequested, failAllPendingOps
- [x] scanForMarker: lastIndexOf("MDELIM:") → parse exit code → strip marker → set done
- **Status:** complete

### Phase 4: handleWebSocket 重写 ✅
- [x] Upgrade WS → read announce → upsert guest → send pty_spawn
- [x] Main loop: drain outgoing_frames → send each → readSmallMessage:
  - pty_output(4) → appendOpOutput + scanForMarker
  - upload_resp → completeOpState
  - download_resp → appendOpOutput + completeOpState
  - announce → update guest info
  - ping → pong
- [x] checkCloseRequested → return if set
- [x] defer: cleanup op_states, remove guest, sync hosts, failAllPendingOps
- **Status:** complete

### Phase 5: handleExec/Upload/Download/Kick 重写 ✅
- [x] **handleExec**: pty_input frame (cmd_id + "cmd; echo MDELIM:$?\n") → createOpState → enqueueOutgoingFrame → poll takeOpResult(30s) → JSON
- [x] **handleUpload**: upload_req frame → createOpState → enqueue → poll(30s) → JSON
- [x] **handleDownload**: download_req frame → createOpState → enqueue → poll(30s) → JSON
- [x] **handleKick**: requestClose(vm) 替代 markKicked
- [x] **删除**: handleExecResult, POST /exec-result 路由
- [x] MDELIM 标记: POSIX 用 `; echo MDELIM:$?\n`，Windows 用 `& echo MDELIM:%errorlevel%\r\n`
- **Status:** complete

### Phase 6: MCP handleVmExec 重写 ✅
- [x] pty_input frame → createOpState → enqueueOutgoingFrame → poll takeOpResult(30s)
- [x] waitTimeout 替代无限 wait
- **Status:** complete

### Phase 7: Route 清理 ✅
- [x] 删除 POST /exec-result 路由
- [x] 确认 /ws, /mcp, /exec, /upload, /download, /kick, /api/guests, /bin/, / 路由正确
- **Status:** complete

### Phase 8: 删除废弃代码 ✅
- [x] wsproto.zig — 删除旧 exec_* 类型 + 测试
- [x] broadcast.zig — 删除 exec streaming 函数 (~300 行)
- [x] httpd.zig — 删除旧 HostState 模型 (~200 行)
- [x] host_http.zig — 删除 handleExecResult + exec-result 路由
- [x] main.zig — 删除 --exec-cancel CLI
- **Status:** complete

### Phase 9: Bug 修复 ✅
- [x] **ptySpawn 空环境**: execve(..., {null}) → execve(..., std.c.environ)
- [x] **CPU 100% 自旋**: POLL.HUP 检测先于 POLL.IN
- [x] **waitTimeout 无限阻塞**: 4 处 wake_event.waitTimeout(30s) + failAllPendingOps
- [x] **dash 兼容**: --login → -l
- [x] **install SHELL/HOME**: detectServiceEnv() → 写环境变量到 service config
- **Status:** complete

### Phase 10: 版本号 + 构建验证 ✅
- [x] ver.zig: 0.4.0 → 0.5.0
- [x] build.zig.zon: version → 0.5.0
- [x] `zig build test` 全过
- [x] 6 目标交叉编译全过
- **Status:** complete

### Phase 11: 文档全面重写 ✅
- [x] CLAUDE.md — pty architecture, protocol table, HostState, pty patterns
- [x] README.md — pty model explanation, AI agent experience
- [x] findings.md — ADRs 1-5, platform notes, bug fixes, known issues
- [x] progress.md — v0.5.0 session log
- [x] task_plan.md — 本文件
- [x] zig-codegen.md — execve environ, Io.Timeout, pty patterns
- [x] release-skill/SKILL.md — version references
- [x] utm-vm/SKILL.md — shell persistence, corrected exec behavior
- [x] utm-vm/MANUAL.md — protocol table, architecture update
- **Status:** complete

### Phase 12: v0.5.1 裸机部署修复 ✅ (2025-07-21 ~ 2025-07-23)
- [x] **detectServiceEnv SSH 环境污染修复**: `detectServiceEnv()` 改为始终使用平台默认值
  (`/bin/zsh` macOS, `/bin/bash` Linux, `cmd.exe` Windows)。SSH 会话中 `$SHELL=/bin/sh`
  会导致 macOS launchd 服务使用错误 shell。
- [x] **macOS AMFI codesign 修复**: `install.sh` Guest 模式增加 `codesign --force --sign -`。
  curl 下载的二进制丢失代码签名，AMFI 对 sudo 进程发送 SIGKILL (exit 137)。
- [x] **MANUAL.md 从零部署验证**: Host + Linux Guest + macOS Guest + Windows Guest
  全平台从头部署一次通过。cd/export 持久化验证。`/etc/hosts` 同步验证。
- [x] **v0.5.1 发布**: 版本号 0.5.0 → 0.5.1，6 目标交叉编译 + utmm.zip，
  GitHub Release 含修复后的 install.sh + 全部二进制。
- [x] **文档更新**: findings.md（2 个新 bug），progress.md（部署验证记录），task_plan.md（本 Phase）
- **Status:** complete

## 已删除的组件

| 组件 | 行数 | 替代 |
|------|------|------|
| exec_req/exec_resp (types 2,3) | 60 | pty_input/pty_output |
| exec_start/exec_stdout/exec_exit (types 8-11) | 120 | pty model (no per-command spawn) |
| exec_signal (type 12) | 50 | pty_signal (renumbered) |
| spawnExecStream (POSIX) | 80 | ptySpawn (POSIX) |
| spawnExecStreamWindows | 60 | ptySpawn (Windows) |
| execStdoutThread + windowsExecThread | 70 | ptyReadLoop |
| drainStdoutToWs + killChildProcess | 40 | 删除 |
| CmdType/CmdStatus/PendingCmd/CmdResult | 60 | OpState |
| pending HashMap + drainPending | 50 | outgoing_frames queue |
| SignalEntry + pending_signals + drainSignals | 60 | close_requests flag |
| deliverResult/deliverStdoutChunk/deliverExecExit | 50 | scanForMarker/completeOpState |
| failGuestPending/markKicked/checkKicked | 40 | failAllPendingOps/requestClose/checkCloseRequested |
| handleExecResult + POST /exec-result | 40 | 删除 |
| --exec-cancel CLI | 30 | --kick CLI |

## 技术参考

- [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455) — WebSocket Protocol
- [Zig 0.16.0 std.http.Server](https://ziglang.org/documentation/0.16.0/std/#std.http.Server)
- [posix_openpt man page](https://man7.org/linux/man-pages/man3/posix_openpt.3.html)
- [Windows CreatePseudoConsole](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole) (Win10 1809+)
- macOS/BSD: pty master fd 不支持 tcsetattr — ECHO disable 必须在 slave 侧完成，或在 Host 侧 lastIndexOf 处理命令回显
- Zig 0.16.0 `Io.Timeout`: `{ none, duration: { raw: Duration, clock: .awake }, deadline: Timestamp }`
- execve 第三个参数必须是 `std.c.environ`（继承父进程环境），不能用 `{null}`（空环境）
