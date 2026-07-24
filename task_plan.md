# Task Plan: v0.8.1+

## 目标
v0.8.0: HTTP 层性能优化 — exec 输出流式传输（chunked + trailer），上传/下载二进制协议（自定义请求头 + 原始 body），消除 JSON 包装开销。

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

### Phase 13: UDP Broadcast Discovery (--status 重写) ✅ (2025-07-23)
- [x] **13.0 前置研究**: 验证 Zig 0.16.0 `std.Io.net.Socket` UDP API
  - `Socket.send(io, dest, data)` — 发送数据报
  - `Socket.receiveTimeout(io, buffer, timeout)` — 带超时接收，返回 `IncomingMessage{ .from, .data }`
  - `BindOptions.allow_broadcast = true` — macOS 收发广播均需要
- [x] **13.1 Guest UDP 监听线程**: `broadcast.zig` 新增 `udpDiscoveryListener()`
  - bind UDP 0.0.0.0:2121，收到 "ARE YOU OK?" 回 ANNOUNCE
  - 重用 `protocol.GuestInfo.parse()` 格式
  - `std.atomic.Value(bool)` shutdown flag + `receiveTimeout(1s)` 优雅关闭
  - 在 `wsAnnounceLoop()` 入口 spawn，defer join
- [x] **13.2 --status 重写**: `host.zig:cmdStatus()` 用 UDP broadcast 替换 HTTP GET
  - bind 随机端口 UDP，send 5 次 broadcast 到 255.255.255.255:2121
  - 5 秒收集窗口，`GuestInfo.parse()` 解析响应，hostname 去重
  - 保留现有表格输出格式不变
- [x] **13.3 协议常量**: `protocol.zig` 新增 `DISCOVERY_QUERY`、`DISCOVERY_RESPONSE_PREFIX`、`GuestInfo.deinit()`
- [x] **构建验证**: `zig build test` 全过，6 目标交叉编译全过
- **Status:** complete


### Phase 14: UDP 子网定向广播修复 ✅ (2025-07-23)
- [x] **14.1 根因定位**: 255.255.255.255 limited broadcast 只走默认路由接口（en0），UTM bridge 网络（bridge100: 192.168.64.0/24）收不到。Python 验证：子网广播 192.168.64.255 可达所有 VM，255.255.255.255 不可达。
- [x] **14.2 getSubnetBroadcasts()**: `broadcast.zig` 新增函数，POSIX 用 `getifaddrs()` 枚举所有 IPv4 接口，计算子网定向广播地址（`ip | ~netmask`）。Windows 只返回 255.255.255.255。跳过 loopback、/32 链路、重复地址。
- [x] **14.3 字节序修复**: `sin.sin_addr.s_addr` u32 在 macOS aarch64 (LE) 为 host byte order，需 `@byteSwap` 转为 big-endian 后提取 octet。Ip4Address.bytes 存储格式为 big-endian。
- [x] **14.4 cmdStatus() 多广播**: 替换单一 broadcast_addr 为广播地址列表。每轮依次向所有地址发送，send/rebind 逻辑适配。
- [x] **14.5 去重 bug 修复**: `found_existing` 时 deinit 旧值导致 stored key 悬空 → 后续 getOrPut 匹配失败 → 重复条目。改为 first-wins：已有则丢弃新值。
- [x] **构建验证**: `zig build test` 全过，6 目标交叉编译全过。
- [x] **运行时验证**: `utmm --status` 发现 linuxvm + macvm + windowsvm，无重复，干净输出。
- **Status:** complete

### Phase 15: Windows UDP Listener ConcurrencyUnavailable 修复 ✅ (2025-07-23)
- [x] **15.1 根因定位**: Zig 0.16.0 `Io.Threaded` Windows 上 `net_receive` 并发路径未实现（Threaded.zig line 3198: "TODO integrate with overlapped I/O"）。`receiveTimeout` 走 `batchAwaitConcurrent` → `concurrency=true` → `net_receive` 返回 `ConcurrencyUnavailable`。
- [x] **15.2 修复方案**: Windows 上用阻塞 `receive()`（走非并发路径，`concurrency=false`）替代 `receiveTimeout`。POSIX 保持 `receiveTimeout`。shutdown 时主线程关闭 socket handle 以解除阻塞 `receive()`。
- [x] **15.3 实现**: `udpDiscoveryListener` 加 `socket_handle_out: *?net.Socket.Handle` 参数。Windows 分支将 handle 写入 atomic 指针供主线程关闭。`wsAnnounceLoop` 在 join 前关闭 socket handle。
- [x] **构建验证**: `zig build test` 全过，全部 6 目标交叉编译全过。
- [x] **运行时验证**: Windows VM 部署新二进制后 `utmm --status` 成功发现全部 3 台 VM。
- **Status:** complete

### Phase 16: v0.6.1 完善 — Windows 防火墙 + 版本号同步 ✅ (2025-07-23)
- [x] **16.1 Windows 防火墙自动化**: `install.zig` 的 Windows 系统服务安装流程中加入 `netsh advfirewall firewall add rule`，开放 UDP 2121 入站。卸载时自动删除规则。解决真机 Windows 部署时 `--status` 扫不到的问题（防火墙默认拦截入站 UDP）。
- [x] **16.2 版本号统一**: `ver.zig` → 0.6.1, `build.zig.zon` → 0.6.1。
- [x] **16.3 task_plan.md 标题更新**: v0.5.0 → v0.6.1。
- **Status:** complete

### Phase 17: v0.6.3 — 自动升级修复 + Windows 自升级 ✅ (2026-07-23)
- [x] **17.1 GET /version 端点**: `host_http.zig` + `host.zig` 注册路由，返回 `protocol.VERSION` 纯文本
- [x] **17.2 downloadAndUpgrade 重写**: Windows 路径用改名+批处理独立进程，POSIX 路径不变
- [x] **17.3 wsAnnounceLoop 接入升级检查**: `is_svc` 参数控制，仅守护进程模式检查。HTTP 获取 Host 版本 → 不匹配则下载 `deploymentFilename` 对应二进制并调用 `downloadAndUpgrade`
- [x] **17.4 启动时清理旧版残留**: `utmm.old.exe` 在 Win 上作为上次升级垃圾，启动时删除
- [x] **17.5 构建验证**: `zig build test` 全过，6 目标交叉编译全过
- [x] **17.6 部署验证**: Host + 4台VM 全部手动升级至 v0.6.3
- **Status:** complete
- **已知问题:** `/opt/utmm/utmm` 在部分 VM 上是独立副本而非符号链接，自动升级后 `systemctl restart` 仍运行旧版本。根因: install.sh 创建副本。v0.7.0 重设计修复。

### Phase 18: v0.7.0 — 自动升级架构重设计 ✅ (2026-07-23)
- [x] **18.1 UDP 广播协议扩展**: `protocol.zig` 新增 `buildDiscoveryQuery()` + `parseDiscoveryVersion()`，广播携带 Host 版本号，向后兼容旧格式
- [x] **18.2 升级模式模块**: `upgrade.zig` — utmm-old 进程核心逻辑：停止服务 → 杀进程 → HTTP 下载 → 替换二进制 → 启动服务。三平台统一控制流
- [x] **18.3 CLI + 启动检测**: `main.zig` 新增 `--update-url` 参数，`isOldMode()` 检测 exe 名含 `-old`，启动时路由到 `upgrade.run()`
- [x] **18.4 Guest UDP 升级检测**: `broadcast.zig` 新增 `UpgradeSignal` 原子标志，`udpDiscoveryListener` 解析版本号检测不匹配，`wsAnnounceLoop` 检查标志触发 `triggerSelfUpgrade`
- [x] **18.5 triggerSelfUpgrade**: 复制自身为 `utmm-old[.exe]`，chmod +x，独立进程启动 `utmm-old --update-url=...`，退出
- [x] **18.6 删除旧代码**: 移除 `downloadAndUpgrade`（~80行）、`wsAnnounceLoop` HTTP 升级检查（~50行）、`is_svc` 参数
- [x] **18.7 Host 定期广播**: `host.zig` 新增 `periodicBroadcastLoop`，每 60s 向所有子网广播带版本号的发现查询，`cmdStatus` 使用 `buildDiscoveryQuery`
- [x] **18.8 构建验证**: `zig build test` 全过，7 目标交叉编译全过，版本号 0.7.0
- [x] **18.9 消除外部 shell 命令**: 升级流程中所有 `sh -c` / `cmd /c` 调用替换为直接系统调用
  - `upgrade.zig`: `sh -c 'chmod +x'` → `std.c.chmod()`
  - `broadcast.zig triggerSelfUpgrade`:
    - `sh -c 'chmod +x'` → `std.c.chmod()`
    - `cmd /c start /min` → `CreateProcessW` + `DETACHED_PROCESS`
    - `sh -c '... &'` → `fork()` + `setsid()` + `execve()`
  - 外部命令依赖归零 — 升级路径仅依赖系统调用
- **Status:** complete

**架构要点:**
- UDP 广播版本检测替代 HTTP GET /version，消除 WebSocket+HTTP 共用端口导致的 `HttpConnectionClosing` 竞态
- utmm-old 独立进程：停止服务、杀进程、下载、替换、启动服务，不依赖 curl
- `pkill -x utmm`（POSIX）/ `taskkill /im utmm.exe`（Windows）精确匹配，不误杀 utmm-old
- 不依赖外部工具，Zig `std.http.Client` 完成 HTTP 下载
- **零外部命令**: chmod/detached launch 全部走直接系统调用（`std.c.chmod` / `fork+execve` / `CreateProcessW`），`sh`/`cmd` 不再参与升级流程

### Phase 19: 文档全面同步 ✅ (2026-07-23)
- [x] **CLAUDE.md**: +winx64, +v0.7.0 自动升级架构, +UDP 数据流, +upgrade.zig, +全部 CLI 标志
- [x] **README.md**: 完全重写 — v0.7.0 零 shell 自动升级, 4 VM 参考表, UDP 广播数据流图
- [x] **utm-vm/SKILL.md**: +winx64, +SSH 访问, MCP 配置更新
- [x] **utm-vm/MANUAL.md**: 完全重写 — 修正 WS 协议帧号, +自动升级架构, 修正全部服务名, +winx64, +x86_64, +MCP 完整章节
- **Status:** complete

### Phase 20: v0.8.0 — Streaming Exec + Binary Upload/Download ✅ (2026-07-23)
- [x] **20.1 Streaming Exec HTTP 响应**: `handleExec` 从 JSON 包装改为 chunked streaming
  - `respondStreaming()` + `x-exit-code` trailer（同下载模式）
  - 移除 30s 超时 — 命令想跑多久跑多久
  - 移除 JSON 包装 — 响应体直接是 pty 原始输出
  - `OpState` 新增 `sent_pos` 字段追踪流式发送进度
  - `body_reader.stream()` + `std.Io.Limit.limited(n)` 读取原始 body
  - `request.iterateHeaders()` + `HeaderIterator.next()` 读取自定义请求头
  - `http.BodyWriter`: 必须先 `writer.flush()` 再 `flush()`，chunked encoding 才能正常工作
- [x] **20.2 Binary Upload Protocol**: JSON 包装 → 原始二进制 HTTP
  - `x-vm` + `x-path` 自定义请求头，`Content-Type: application/octet-stream`
  - `readRawBody()` helper: content-length 驱动的原始 body 读取
  - `getRequestHeader()` helper: `request.iterateHeaders()` 不区分大小写匹配
  - `sendBodyComplete(file_data)` 发送原始二进制
  - 响应纯文本（非 JSON）
- [x] **20.3 Binary Download Protocol**: JSON 包装 → 流式 chunked 响应
  - `x-vm` + `x-path` 请求头，`sendBodyComplete("")`（不能用 `sendBodiless` — panic）
  - `respondStreaming()` + `x-exit-code` trailer
  - CLI 端 `body_reader.stream(file_iface, ...)` 流式写文件
- [x] **20.4 8 目标发布构建**: +`x86-windows-gnu` 第 8 个目标
  - `x86-windows` (MSVC) 有 MinGW linker warning (`_system@4`)，Zig 将 warning 升级为 error
  - `x86-windows-gnu` 避免该 linker warning — 成功构建 32-bit Windows exe
  - `release-skill/build.sh` + `SKILL.md` 从 6→7→8 目标更新
- [x] **20.5 macOS AMFI codesign 修复**: 二进制在 `/tmp` 签名后 `mv` 到 `/opt/utmm/`
  - AMFI 对 `/opt/utmm/` 中的无签名二进制发送 SIGKILL
  - `codesign -s - -f` 直接在 `/opt/utmm/` 中运行失败："internal error in Code Signing subsystem"
  - 变通方案: 在 `/tmp/utmm-sign` 签名，然后 `mv` 到 `/opt/utmm/` — `mv` 保留有效签名
- [x] **20.6 构建验证**: `zig build test` 全过，8 目标交叉编译全过
- [x] **20.7 部署验证**: 所有 4 台 VM 升级到 v0.8.0，上传/下载 MD5 验证通过
- [x] **20.8 文档更新**: task_plan.md (本 Phase), progress.md, findings.md, CLAUDE.md, README.md, utm-vm/MANUAL.md, utm-vm/SKILL.md, release-skill/SKILL.md
- **Status:** complete

**架构要点:**
- exec 响应从 `{"exit_code":0,"stdout":"..."}` 变为流式 chunked 纯文本 + `x-exit-code` HTTP trailer
- 上传/下载不再经过 JSON 编码 — 原始二进制直接走 HTTP body，`x-vm`/`x-path` 自定义请求头标识目标
- `sendBodiless()` 与 chunked encoding 冲突导致 panic（`unreachable` at Client.zig:914），改用 `sendBodyComplete("")`
- macOS AMFI: 直接在 `/opt/utmm/` 中签名失败，必须在 `/tmp` 签名后 `mv`
- 32-bit Windows: `x86-windows-gnu` 绕过 MinGW `_system@4` linker warning

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

---

## v0.8.1 — 文档清理 + Auto-Upgrade 修复

### Phase 21: v0.8.1 发布 ✅
- [x] ver.zig 版本号 0.8.0 → 0.8.1
- [x] 8 目标完全重建 + GitHub Release
- [x] 全部 4 台机器部署验证通过
- **Status:** complete

### Phase 22: 文档消噪 ✅
- [x] README.md 重写 — 去除版本历史杂音，突出 VM+真机支持
- [x] CLAUDE.md 清理 — 去除 v0.5.0/v0.7.0/v0.8.0 版本号打头的特性描述
- [x] zig-codegen.md — 移除过时内容
- [x] mcp.json.example — 添加 Claude Code MCP 安装指南
- **Status:** complete

### Phase 23: Auto-Upgrade 阻塞读取修复 ✅
- [x] 根因: wsAnnounceLoop 阻塞在 readFrame，UDP listener 设置 upgrade.needed 后主循环无法检测
- [x] POSIX: poll 超时路径增加 upgrade.needed 检查（1 秒内检测）
- [x] Windows: TimerCtx 增加 upgrade 指针，timer 线程检测到升级信号时关闭 socket 唤醒 readFrame
- [x] 测试通过 + 交叉编译验证
- **Status:** complete

### Phase 24: v0.8.2 发布 ✅
- [x] Host serve_dir 验证正常（无需修复）
- [x] test_all.sh sshpass → 软依赖（密钥认证优先，sshpass 可选）
- [x] release-skill/build.sh 注释修正 + native 重建
- [x] 全 .md 文档版本引用同步至 v0.8.2
- [x] GitHub Release + 全部 4 台机器部署
- **Status:** complete

### Phase 25: v0.9.0 — 跨平台 Host 支持 ✅
- [x] `upgrade.zig`: stopService/startService 增加 Host 服务管理（三平台）
- [x] `config.zig`: 移除硬编码 VM 配置（`[3]VmConfig` → `[]const VmConfig` 空切片）
- [x] `main.zig`: hosts_file 按平台默认值（Windows: `C:\Windows\System32\drivers\etc\hosts`）
- [x] `install.zig`: Windows Host 模式添加防火墙规则 + 提示
- [x] `host.zig`: 端口 < 1024 权限提升提示
- [x] README.md: 跨平台 Host 安装说明
- [x] SKILL.md: Host Paths 表更新为三平台
- [x] MANUAL.md: 2.3 节更新为跨平台 Host 安装指南
- **Status:** complete
