# Progress: v0.5.0 pty Session Model

## Session 2026-07-19 (v0.2.0 zio Architecture — superseded)
v0.2.0 架构已完成并发布：
- TCP transport 协议 + zio async Runtime
- Guest/Host 重写，删除 HTTP/IPC 5 文件
- Phase 1-10 全部完成，GitHub Release v0.2.0

## Session 2026-07-21 (v0.2.6 → v0.3.0)

### v0.3.0: Unified HTTP Architecture (6 Phases)

**Phase 1-2: httpd.zig + Host HTTP Endpoints** ✅
- 创建 `src/httpd.zig`: HTTP server accept loop + Router + HostState
- 创建 `src/host_http.zig`: /announce, /exec, /exec-result, /upload, /download, /mcp, /bin/, /
- Guest HTTP announce (POST /announce) 替换 UDP broadcast
- HTTP polling 模型：Guest 每秒 POST，Host 返回 pending 命令

**Phase 3: Guest HTTP Client** ✅
- `broadcast.zig`: `httpAnnounceLoop` 替换 `broadcastLoop`
- Guest 不再运行 TCP server，纯 HTTP client

**Phase 4: CLI Commands HTTP 化** ✅
- `--status` → HTTP GET /api/guests
- `--exec` → HTTP POST /exec
- `--upload`/`--download` → HTTP POST

**Phase 5: MCP 修复** ✅
- `mcp.zig`: `processJsonRpcWithState` 直接读 HostState HashMap
- 删除 stdio MCP 模式
- `/mcp` 端点合并进主 HTTP server

**Phase 6: 清理** ✅
- 删除 `transport.zig`, `listener.zig`, `status.zig`
- 删除 `host.zig` 中 UDP listener + binary auto-upgrade 旧代码 (~530 行)
- 删除 `protocol.zig` 中文本协议构建函数
- 删除 `main.zig` --mcp 标志
- `zig build test` 全过，6 目标交叉编译通过

## Session 2026-07-22 (WebSocket Binary Protocol)

### WebSocket 替换 HTTP Polling ✅
- **创建** `src/wsproto.zig`: binary WebSocket 协议
  - 8 种消息类型: announce, exec_req/resp, upload_req/resp, download_req/resp
  - String null-terminated, binary 4B 长度前缀
  - 完整测试覆盖（含 binary data round-trip）
- **创建** `src/wsclient.zig`: Guest WebSocket 客户端
  - TCP connect + HTTP upgrade handshake (RFC 6455)
  - Mask generation (timestamp XOR, 无 std.random 依赖)
  - Frame read/write with Zig 0.16.0 Io API
- **修改** `src/host_http.zig`: `handleWebSocket`
  - HTTP upgrade → read announce → loop: drainPending → send binary → read responses → deliverResult
  - 使用 `request.upgradeRequested()` + `request.respondWebSocket()`
- **修改** `src/broadcast.zig`: `wsAnnounceLoop` 替换 `httpAnnounceLoop`
  - 持久 WS 连接，实时接收 exec/upload/download
  - Binary frame I/O，零编码开销
- **修改** `src/guest.zig`: 使用 `wsAnnounceLoop`
- **修改** `src/host.zig`: 添加 `/ws` 路由

### 构建验证 ✅
- `zig build` 通过（零错误零警告）
- `zig build test` 全过
- 6 目标交叉编译全过: x86_64/aarch64 × linux-musl/macos/windows

### 文档重写 ✅
- CLAUDE.md: 架构、数据流、协议、文件结构更新为 v0.3.0
- README.md: MCP 端口 2122→2121，架构描述更新
- findings.md: 记录 v0.3.0 架构决策和现存问题
- progress.md: 更新本会话进度
- task_plan.md: 重写为 v0.3.0 计划
- utm-vm/MANUAL.md: 协议描述更新
- utm-vm/SKILL.md: 端口和架构描述更新

## Session 2026-07-22 (Deployment & Bug Fixes)

### Windows WebSocket 修复 ✅
- AFD kernel handle 兼容：`std.c.recv` (WSAENOTINITIALISED) → `Io.Reader` 基于 HTTP 响应读取
- Handshake leftover bytes: `PrefixReader` 模式将缓冲数据前置于首个 `readFrame` 调用
- `build.zig`: 链接 `ws2_32` 以支持 WebSocket 客户端 mask 生成中的 `std.c.random`

### /etc/hosts 同步修复 ✅
- use-after-free: `syncHostsFromState` 中的 `name_str` 在 `updateHosts` 读取前被释放 → 收集到 `allocated_names` ArrayList 中
- WebSocket 路径缺失同步：在 WebSocket handler 的 `upsertGuest`（变更时）和 `removeGuest` 后添加 `syncHostsFromState` 调用

### 部署验证 ✅
- 6 目标交叉编译全过
- 部署到 linuxvm (aarch64)、macvm (aarch64)、windowsvm (aarch64)
- Host 部署并重启，所有 3 个 Guest WebSocket 连接成功
- `utmm --status` 显示全部 Guest 在线
- `utmm --exec` 在所有 3 个 VM 上可用
- `/etc/hosts` 同步正确，UTC-MONITOR 标记块包含所有 3 条条目
- commit `0a3a08d` v0.2.8, tag v0.3.0 就绪

## Session 2026-07-22 (GuestNotFound 修复 + Streaming Exec)

### GuestNotFound 修复 ✅
- **根因**: `StringHashMap` key 内存损坏 — GPA 分配器在 `drainPending` 释放 pending map 的 `cmd_id`（分配器复用地址），覆盖了 guests map 中 "linuxvm" key 的内容（前 7 字节被改写为 `1784690`，即命令 ID 前缀）
- **修复**: `HostState.guests` 从 `StringHashMap(GuestEntry)` 改为 `ArrayList(GuestEntry)` — entries 内联存储，无独立 key 分配，消除 use-after-free 攻击面。3 个 VM 的线性搜索开销可忽略
- **验证**: linuxvm 10/10 + macvm 10/10 exec 通过，MCP vm_exec 通过，零错误

### Streaming Exec (v0.4.0 计划)
- **wsproto.zig**: 新增 5 个消息类型 — exec_start(8), exec_stdout(9), exec_stdin(10), exec_exit(11), exec_signal(12)
- **broadcast.zig**: Guest poll-based spawn（std.process.Child + posix poll 多路复用 stdin/stdout/stderr + WebSocket socket）
- **host_http.zig**: WS handler 分发 exec_stdout/exec_exit 帧，exec_signal 信号转发
- **httpd.zig**: `deliverStdoutChunk`/`deliverExecExit` 流式累积输出，PendingCmd 新增 `partial_stdout` ArrayList
- **host.zig/main.zig**: `--exec-cancel` CLI 支持（SIGINT 发送到远端 shell）
- **遗留**: stdout/stderr 合并流（all via exec_stdout type 9），未分离；exec_stdin 类型定义但双向 stdin 尚未实现

### 已知问题（未修复）
- auto-upgrade 未接入 WebSocket（`downloadAndUpgrade` 未被 `wsAnnounceLoop` 调用）
- WebSocket 无心跳/ping-pong 机制
- CLI upload/download 路径解析错误
- `agent.zig` 未将 `host_ip` 传递给 `CliArgs`
- exec_stdin 帧类型已定义但 Guest 端 stdin 写入尚未实现

## Session 2026-07-22 (Windows Streaming Exec)

### Windows 流式 Exec 实现 ✅
- **broadcast.zig**: 新增 Windows 流式 exec 路径
  - `spawnExecStreamWindows`: 使用 `Threaded.init` I/O spawn 子进程
  - `windowsExecThread`: 独立线程 blocking ReadFile 读 stdout pipe
  - `WindowsExecThreadArgs`: process_handle + stdout_handle + Threaded 所有权
  - `killChildProcess`: 跨平台 (Windows: TerminateProcess, POSIX: killpg)
  - `getGatewayWindows`: 使用 Threaded.init 修复 service context OutOfMemory
- **kernel32 extern 声明**: ReadFile, WaitForSingleObject, GetExitCodeProcess, TerminateProcess 通过 @extern
- **关键修复**:
  - child.handle → child.id (Windows 上 Child.Id = HANDLE, 无 handle 字段)
  - BOOL 比较 → @intFromEnum(result) == 0
  - win.INFINITE → std.math.maxInt(u32)
  - format 字符串 pid={d} → pid={any} (pid_t 是 HANDLE 在 Windows)
  - posix.kill → killChildProcess 跨平台
  - switch(builtin.os.tag) 消除平台死代码 (posix.kill 无法在 Windows 链接)
- **构建验证**: 6 目标交叉编译全过, zig build test 全过

## Session 2026-07-22 (Connection = Shell Session)

### 目标
用 "Connection = Shell Session" 模型替换 exec_signal (type 12) + --exec-cancel 体系。每个 WebSocket 生命周期 = 一个 shell session。Exec 完成后 Guest flush TCP 200ms → disconnect → reconnect。

### 协议简化 ✅
- **删除** `exec_signal` (type 12): buildExecSignal/parseExecSignal/ExecSignalData + 对应测试
- **删除** Host 侧: SignalEntry, pending_signals HashMap, drainSignals/enqueueSignal
- **删除** Guest 侧: main loop 中 exec_signal 处理分支（~40 行 killpg 代码）
- **删除** HTTP: handleExecSignal, POST /exec-signal 路由
- **删除** CLI: --exec-cancel, cmd_exec_signal 字段

### 新增功能 ✅
- **--kick CLI**: `utmm --kick <vm>` — 主动关闭 Guest WebSocket 连接
- **Host kick 机制**: kicked HashMap + markKicked/checkKicked
- **POST /kick**: HTTP handler，响应 `{"ok":true}`
- **failGuestPending**: Guest disconnect 时所有 dispatched 命令 → failed
- **CmdStatus.failed**: 新命令状态，tryTakeResult 匹配

### 关键 Bug 修复 ✅
- **Host bus error (SIGBUS)**: failGuestPending 用 string literal "disconnected" → handleExec `allocator.free()` → crash。修复：`allocator.dupe()` heap-allocate
- **Windows exec 死锁**: 主循环无 poll 超时 → 阻塞 readFrame 无法检测 exec_done。修复：exec 线程发送 WebSocket PING + Host 端显式 ping handler 响应 pong
- **Host ping handler**: `handleWebSocket` 新增 `.ping` 分支 — `readSmallMessage` 不自动响应 ping

### 部署验证 ✅
- `zig build test` 全过
- linuxvm (POSIX): exec 后正常 disconnect + reconnect
- macvm (POSIX): exec 后正常 disconnect + reconnect
- windowsvm: ping/pong 唤醒机制正常，exec 后正常 disconnect + reconnect
- `--kick` 测试: kick 后 Guest 重新连接，pending 命令返回 "disconnected" 错误
- kick 过程中 exec 线程可能继续运行但 defer cleanup 会 kill

### 文档更新 ✅
- [x] CLAUDE.md — Connection = Shell Session model, kick CLI, protocol changes
- [x] zig-codegen.md — readSmallMessage ping behavior, string literal free lesson
- [x] findings.md — ADR-5, Host bus error fix, Windows deadlock fix
- [x] progress.md — 本会话进度
- [x] task_plan.md — Phase 10 Connection = Shell Session, Phase 9 更新
- [x] utm-vm/MANUAL.md — exec_signal 删除, --kick CLI, 协议表更新

## Session 2026-07-21–22 (v0.5.0 pty Session Model)

### 目标
用持久 pty session 替换 "Connection = Shell Session"（每命令断连重连）模型。每个 WebSocket 连接 spawn 一个持久 shell（POSIX `posix_openpt` / Windows `CreatePipe`），命令在同一个 shell 中执行。`cd` 和 `export` 真正持久化。

### 协议重设计 ✅
- **删除** exec_* 类型 (2,3,8,9,10,11,12) — exec_req, exec_resp, exec_start, exec_stdout, exec_stdin, exec_exit, exec_signal
- **新增** pty_* 类型:
  - `pty_spawn` (2): host→guest, no payload, spawn shell on WS connect
  - `pty_input` (3): host→guest, cmd_id + stdin_data, feed command to shell
  - `pty_output` (4): guest→host, cmd_id + stdout_data, shell output stream
  - `pty_signal` (5): host→guest, 1-byte signal (SIGINT/SIGTERM/SIGHUP)
  - `pty_resize` (6): host→guest, rows+cols (u16 BE)
- 保留: announce(1), upload_req(7→renumbered), upload_resp(8), download_req(9), download_resp(10)

### Guest pty 实现 ✅
- **ptySpawn (POSIX)**: `posix_openpt` → `grantpt`/`unlockpt` → `fork` → child: `setsid`, `ioctl(TIOCSCTTY)`, `dup2(slave→0,1,2)`, `execve(shell, argv, std.c.environ)` → parent: close slave, return master_fd + child_pid
- **ptySpawn (Windows)**: `CreatePipe` × 2 (stdin+stdout) → `CreateProcessW("cmd.exe /k")` with `STARTF_USESTDHANDLES`. `lpEnvironment=NULL` inherits parent env
- **ptyReadLoop**: 独立线程读 pty master fd，构建 pty_output 帧。POLL.HUP 检测 shell 退出
- **ptyWrite**: 写 stdin data 到 master fd
- **scanForMarker**: `lastIndexOf("MDELIM:")` 扫描输出流中的退出码标记。macOS/BSD 用 `lastIndexOf` 处理命令回显（pty master 不支持 tcsetattr ECHO disable）
- **MDELIM 标记**: 每个命令追加 `; echo MDELIM:$?\n` (POSIX) 或 `& echo MDELIM:%errorlevel%\r\n` (Windows)

### Host State 重设计 ✅
- **删除**: CmdType, CmdStatus, PendingCmd, CmdResult, pending HashMap, kicked HashMap, SignalEntry, pending_signals, drainPending, deliverResult, deliverStdoutChunk, deliverExecExit, failGuestPending, markKicked, checkKicked
- **新增**:
  - `outgoing_frames`: per-guest FIFO frame queue (HTTP handlers push, WS handler drains)
  - `op_states`: HashMap of OpState (cmd_id → {output, exit_code, done, wake_event})
  - `close_requests`: flag-based kick 替代 kicked HashMap
- **新方法**: enqueueOutgoingFrame, dequeueOutgoingFrame, createOpState, appendOpOutput, completeOpState, scanForMarker, takeOpResult, requestClose, checkCloseRequested, failAllPendingOps

### Host HTTP Handler 重写 ✅
- **handleWebSocket**: Upgrade WS → read announce → upsert guest → send pty_spawn → loop: drain outgoing_frames, readSmallMessage (pty_output→appendOpOutput+scanForMarker, upload_resp/download_resp→completeOpState, ping→pong), checkCloseRequested → cleanup op_states + failAllPendingOps
- **handleExec**: pty_input frame (cmd_id + "cmd; echo MDELIM:$?\n") → createOpState → enqueueOutgoingFrame → poll takeOpResult (30s timeout) → return JSON
- **handleUpload/handleDownload**: 同 handleExec 模式
- **handleKick**: requestClose 替代 markKicked
- **删除**: handleExecResult, POST /exec-result 路由

### MCP 更新 ✅
- handleVmExec: pty_input frame → createOpState → enqueue → poll takeOpResult with 30s timeout

### Bug 修复 ✅
- **ptySpawn 空环境**: `execve(shell, argv, {null})` → `execve(shell, argv, std.c.environ)`。空环境导致无 HOME/SHELL，.bashrc/.zshrc 不加载
- **CPU 100% 自旋**: `ptyReadLoop` poll 循环只检查 POLL.IN → shell 退出时 POLL.HUP 被忽略导致忙等。修复：先检查 POLL.HUP
- **waitTimeout 无限阻塞**: HTTP/MCP handler 的 `wake_event.wait()` 无超时 → guest 断连时线程永久阻塞。修复：4 处改为 `wake_event.waitTimeout(30s)`，WS disconnect 时 failAllPendingOps
- **dash 兼容**: `--login` → `-l`（dash 不接受 GNU 长选项）
- **install 缺少 SHELL/HOME**: systemd/launchd 服务无环境变量 → 新增 `detectServiceEnv()` 在 install 时写环境配置

### 部署验证 ✅
- `zig build test` 全过
- linuxvm: pty shell 持久化，cd + export 跨命令生效
- macvm: pty shell 持久化，macOS BSD tcsetattr 限制用 lastIndexOf 绕过
- windowsvm: cmd.exe /k 持久化，环境自动继承
- `utmm --status` 正常，`utmm --exec` 正常，MCP vm_exec 正常
- `utmm --kick` 后 guest 重连，新 pty session

### 代码量变化
- 删除 ~300 行 exec streaming 代码
- 删除 ~200 行 HostState 旧模型 (PendingCmd, CmdResult, pending, kicked 等)
- 新增 ~350 行 pty 代码 (ptySpawn, ptyReadLoop, ptyWrite, scanForMarker)
- net: ~150 行减少

### 文档全面重写 ✅ (v0.5.0)
- [x] CLAUDE.md — pty architecture, protocol table, HostState central state, pty patterns
- [x] README.md — AI agent experience, pty model explanation
- [x] findings.md — ADR 1-5, pty platform notes, v0.5.0 bug fixes, known issues
- [x] progress.md — 本文件（v0.5.0 session log）
- [x] task_plan.md — v0.5.0 pty session model plan
- [x] zig-codegen.md — execve environ, Io.Timeout, Timestamp.now, pty patterns
- [x] release-skill/SKILL.md — version references update
- [x] utm-vm/SKILL.md — pty model: shell persistence, corrected exec behavior
- [x] utm-vm/MANUAL.md — protocol table (pty types), architecture update, deprecations removed

### MANUAL.md 从零部署验证 ✅ (2025-07-21/23)

按 MANUAL.md 从裸机完整部署 3 台 VM：

**Host 部署** ✅
- `curl install.sh | sh` 一键安装正常
- `sudo utmm --host --install` 服务安装 + 启动正常

**Linux Guest (linuxvm) 部署** ✅
- `curl http://gateway:2121/bin/install.sh | sh -s -- --guest --hostname linuxvm` 正常
- Shell = `/bin/bash` ✓，cd/export 持久化 ✓

**macOS Guest (macvm) 部署** ✅
- 初次部署后发现 Shell = `/bin/sh`（应为 `/bin/zsh`）→ 定位到 `detectServiceEnv` bug
- **Bug fix 1**: `detectServiceEnv()` 读取 `$SHELL` 环境变量，SSH 会话中 `$SHELL=/bin/sh`
  修复：改为始终使用平台默认值 (`/bin/zsh` / `/bin/bash` / `cmd.exe`)
- **Bug fix 2**: curl 下载的二进制丢失代码签名，AMFI 对 sudo 进程发送 SIGKILL
  修复：`install.sh` 增加 macOS Guest 端 `codesign --force --sign -`
- 修复后：Shell = `/bin/zsh` ✓，cd/export 持久化 ✓

**Windows Guest (windowsvm) 部署** ✅
- pty 模型正常工作，`cmd.exe` 交互正常
- Scheduled task 服务自动重启正常

**关键教训**:
- macOS Guest 部署后必须 codesign（install.sh 现已自动处理）
- 服务环境不应读取用户 shell 偏好，始终使用平台默认值
- `--install` 不带 `--hostname` 会使用 OS hostname，导致 Host 端识别名变化
