# Task Plan: v0.11.4+

## 目标
v0.11.0: Mesh + KCP 统一传输 — 移除 WebSocket，KCP tunnel 成为唯一 Guest-Host 传输层。
v0.11.1-4: Bug 修复周期 — Host 重启/reconnect exec 挂起、--kick 移除、KCP keepalive、
内存泄漏修复。

**核心架构变更：**
- 删除 wsclient.zig + wsproto.zig（WebSocket 层），tunproto.zig 替代
- KCP Tunnel 为唯一 Guest-Host 传输（无帧大小限制）
- LSA (Link State Advertisement) 替代 WebSocket announce 发现
- HTTP :2121 保留为 MCP JSON-RPC + 静态文件适配器
- KCP keepalive（TCP 风格：5s 空闲 → 探测 → 3 次失败 → dead）
- pty_signal / --kick 移除，stdin 透传 Ctrl+C

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

### Phase 26: v0.11.0 — KCP Retransmission 修复 ✅
- [x] **Bug #1**: `kcp.update()` 的 `updated` flag 导致 flush 只在首次调用 — 重传和 ACK 处理永久失效
  - 修复: 移除 `updated` 检查，每次 `update()` 都调用 `flush()`
- [x] **Bug #2**: `flush()` Step 2 更新 `resendts = current + rto` 后，Step 4 检查 `diff = current - resendts`（负值）→ `need_send` 永不成立 → 重传段永不发送
  - 修复: 合并 Step 2+4 为单次遍历，保存 `old_resendts` 先判断是否需要发送，再更新计时器并调用 `outputSegment`
- [x] **KCP 本地 loopback 测试**全部通过（含丢包重传、快速重传、乱序、大数据分段）
- [x] `waitForHostTunnel` 添加 `sessions_mutex` 锁保护 — 消除与 `mesh.run()` 的数据竞争
- [x] 调试日志降级: `periodicTasks` / `kcp_output` / `New KCP session` 从 `info` → `debug`
- **Status:** complete

### Phase 27: v0.11.0 — LSA 版本检查误升级修复 ✅
- [x] **Bug**: Guest 收到其他 Guest 的 LSA（版本不同）→ `upgrade_needed` 被设置 → Guest 触发 self-upgrade 重启 → 死循环
  - 根因: LSA 版本检查对所有远程节点生效，不区分 Host 和 peer Guest
  - 修复: Mesh.init 新增 `host_gateway_ip` 参数，LSA 处理中提取 `ip:` 字段与网关 IP 比对，仅当 LSA 来自 Host 时才触发版本检查
  - Host 端传空字符串跳过检查（Host 不自升级）
- [x] `broadcast.zig`: 新增 `extractHostIp(host_url)` 辅助函数
- [x] 验证: linuxvm + macvm 均 v0.11.0，无 `LSA version mismatch` 日志，无 self-upgrade 触发
- **Status:** complete

### Phase 28: v0.11.0 — VM 联网验证 ✅
- [x] `--status` — linuxvm + macvm 均在线 (v0.11.0)
- [x] `--exec linuxvm "echo HELLO"` — 即时响应（KCP tunnel 端到端正常）
- [x] `--exec macvm "echo HELLO"` — 即时响应
- [x] `--upload` / `--download` — 文件往返验证通过
- [x] MCP JSON-RPC `tools/list` / `vm_status` / `vm_exec` — 全部正常
- [x] 8 目标交叉编译全过
- **Status:** complete

### Phase 29: v0.11.1 — Host 重启后 exec 挂起修复 ✅ (2026-07-24)

**Bug**: Host 重启后，Guest 的 `handleKcpData` 使用 `computeConv(MAC, MAC)` 计算 KCP conv，
由于 MAC 地址不变，新旧 session 的 conv 相同。Guest 找到旧 KCP session 并喂入新 Host 的数据，
旧 KCP 因序号不匹配丢弃数据 → pty_spawn 永远无法到达 Guest → exec 永久挂起。

**根因链路**:
1. Host 重启 → 新 KCP 状态（seq=0）→ 向 Guest 发送 pty_spawn（sn=0）
2. Guest `handleKcpData`: `computeConv(host_mac, guest_mac)` = 旧 conv → 找到旧 session
3. 旧 KCP 的 `rcv_nxt` 远大于 0 → `kcp.input()` 丢弃 `sn=0` 的数据包（out of window）
4. 新 Host 的数据从未被 Guest 应用层接收 → 双方都等待

**修复方案**: KCP conv 嵌入 Host 启动时生成的 nonce，`handleKcpData` 从 KCP 包头直接读取 conv

| 变更 | 文件 | 说明 |
|------|------|------|
| Mesh.nonce 字段 | `mesh.zig` | PID + ASLR 栈地址熵，每次进程启动唯一 |
| `computeConv(a,b,nonce)` | `mesh.zig` | 第三个参数 nonce，XOR 进基础 conv |
| `readKcpConv()` | `mesh.zig` | 从 KCP 包头偏移 13 读取 u32 big-endian conv |
| `handleKcpData` 重写 | `mesh.zig` | 用 `readKcpConv(data)` 替代 `computeConv(src_mac, self.node_id)` |
| `connect/closeSessionFor` | `mesh.zig` | 使用 `self.nonce` |
| `generateNonce()` | `mesh.zig` | 跨平台 nonce 生成（POSIX `getpid` + Windows `GetCurrentProcessId` + 栈地址 XOR） |
| stale_count 阈值 | `broadcast.zig` | 3000→600（15s→3s），移除不可靠的 `tunnel.isAlive()` 检查 |

**验证结果**（2 次 Host 重启测试）:
- linuxvm: `21:41:07 New KCP session conv=545727302` → `21:41:08 Newer session detected, reconnecting` → 1 秒切换完成
- macvm: 同样正常恢复
- 旧 session (conv=626532558) 与新 session (conv=545727302) 的 conv 不同 → nonce 方案正确

**Status:** complete

### Phase 30: v0.11.2 — Reconnect 后 exec 挂起修复 ✅ (2026-07-25)

**Bug**: Reconnect 后 `m.connect()` 返回新 session，但 conv 与旧 session 相同（nonce 不变）。
Guest 端旧 KCP session 仍然存在，`handleKcpData` 发现有相同 conv 的 session 就喂入旧 KCP，
旧 KCP 因序号不匹配丢弃数据 → pty_spawn 无法到达 Guest → exec 永久挂起。

**修复方案**: 引入 `connect_counter`，每次 `connect()` 递增并 XOR 进 conv

| 变更 | 位置 | 说明 |
|------|------|------|
| `connect_counter: u32` | `mesh.zig` Mesh struct | 每次 connect() 递增，XOR 进 conv |
| `connect()` 重写 | `mesh.zig` | `self.connect_counter +%= 1` → `computeConv(host, guest, nonce ^ counter)` |
| `closeSessionFor()` 重写 | `mesh.zig` | 改为迭代 sessions 按 `remote` 字段查找（不再计算 conv） |

**Status:** complete

### Phase 31: v0.11.3 — 移除 --kick 命令 ✅ (2026-07-25)

**决策**: 彻底删除 `--kick` CLI 命令及相关代码。KCP keepalive 替代 kick 的
死连接检测功能，stdin 透传 Ctrl+C（pty termios 自然生成信号）替代信号发送功能。

| 文件 | 变更 | 说明 |
|------|------|------|
| `src/main.zig` | 删除 `cmd_kick`/`kick_target` | 移除 CLI 字段和解析 |
| `src/host.zig` | 删除 `cmdKick` + `/kick` 路由 | 移除 CLI 分发和 HTTP 路由 |
| `src/host_http.zig` | 删除 `handleKick` | 移除 HTTP handler |
| `src/httpd.zig` | 删除 `close_requests` + `requestClose` + `checkCloseRequested` | 移除 kick 机制 |
| `src/mesh.zig` | 更新注释 | 移除 kick 引用 |
| `src/broadcast.zig` | 更新注释 | 移除 kick 引用 |
| 所有 *.md | 删除 kick 行 | README, CLAUDE.md, DESIGN.md, MANUAL.md, SKILL.md |

**Status:** complete

### Phase 32: v0.11.4 — KCP Keepalive 死 session 跳过 + 内存泄漏修复 ✅ (2026-07-25)

**背景**: Phase 30 (KCP keepalive) 实现后，死 session 被标记 `dead = true` 但
`periodicTasks` 仍对其调用 `kcp.update()`，导致 KCP 重传触发 `meshKcpOutput` 回调，
而 neighbor 已被 `expireStale` 移除，产生大量 `[mesh] kcp_output: neighbor not found`
错误日志。

同时 `handleMeshGuest` 的 defer 清理逻辑缺少 tunnel/session/hostname 的内存释放。

**修复 1: 跳过死 session 的 KCP update (mesh.zig)**

```zig
// periodicTasks — 对 dead session 直接 continue，跳过 kcp.update()
if (sess.dead) continue;
```

**修复 2: handleMeshGuest 释放内存 (host_http.zig)**

```zig
defer {
    // ... state cleanup ...
    // 释放 mesh session + tunnel + hostname（由 tunnelManager 分配）
    tun.session.mesh.closeSession(tun.session);
    tun.deinit();
    allocator.destroy(tun);
    allocator.free(hostname);
}
```

**修复 3: 移除 dead session 中的冗余 `if (!sess.dead)` 检查**

由于 `if (sess.dead) continue;` 在前面提前退出，后面的 `sess.dead = true` 设置
不再需要 `if (!sess.dead)` 检查。

| 文件 | 变更 | 说明 |
|------|------|------|
| `src/mesh.zig` | `periodicTasks` 加 `if (sess.dead) continue` | 死 session 跳过 kcp.update() |
| `src/host_http.zig` | `handleMeshGuest` defer 加 closeSession + destroy + free | 内存泄漏修复 |

**验证结果**:
- 本地双端口测试: exec/cd/export 正常
- kill Guest: keepalive ~16s 后检测 dead，无 "neighbor not found" 错误
- Guest 重启: tunnelManager 5s 内重连，exec 正常
- `zig build test` 全过，8 目标交叉编译全过

**Status:** complete

### Phase 33: v0.11.5 — Upload/Download 优化（扩展协议 + 单例去重 + 原子写入）✅ (2026-07-25)

**目标**: Upload/Download 功能三项优化 — 协议扩展（尺寸+hash）、单例去重、
临时文件+原子 rename。

**变更内容:**

1. **tunproto.zig 协议扩展**:
   - `upload_data` (0x13): cmd_id + path + file_size(u32 BE) + file_hash(NT) + file_data
   - `download_result` (0x18): cmd_id + exit_code + file_size(u32 BE) + file_hash(NT) + file_data
   - 新增 `writeU32`/`readU32` 辅助函数
   - 更新所有 round-trip 测试（含 hash/size 字段）

2. **httpd.zig — TransferState 跟踪**:
   - 新增 `TransferState` struct: cmd_id, file_size, bytes_transferred
   - `OpState` 新增 file_hash、file_size_meta 字段
   - `HostState` 新增 transfers HashMap + 5 个方法: findTransfer, registerTransfer,
     updateTransferProgress, removeTransfer, setOpFileMeta
   - 单例 key 格式: `"<vm>:<path>"` — 仅按目标路径去重，不区分方向
     （其他机器可能上传/下载同一文件，过严的条件反而无效）

3. **host_http.zig — HTTP handler 增强**:
   - `handleUpload`: 读取 `x-file-hash` header；单例检查 transfer_key；
     注册 transfer；传递 file_size + file_hash 到 buildUploadData
   - `handleDownload`: 单例检查；注册 transfer；读取 op.file_hash/file_size_meta
     设置 `x-file-hash`/`x-file-size` HTTP trailer
   - `handleRoot`: 扩展为目录列表 — 遍历 serve_dir 生成可点击 HTML 表格
   - `handleMeshGuest`: download_result 调用 setOpFileMeta + updateTransferProgress

4. **broadcast.zig — Guest 侧 SHA256 + 临时文件**:
   - 新增 `computeSHA256` 函数（手动 hex 编码，因 Zig 0.16.0 移除 fmtSliceHexLower）
   - `writeFile` 重写: 临时文件 (.utmm-tmp-xxx) → SHA256 验证 → Dir.rename() 原子移动
   - `readFileContent` 返回 `{ data, hash }` struct

5. **host.zig — CLI SHA256 + 临时文件**:
   - `cmdUpload`: 计算本地文件 SHA256，通过 `x-file-hash` header 发送
   - `cmdDownload`: 写入临时文件 (.utmm-tmp) → 读 x-exit-code/x-file-hash/x-file-size
     trailer → SHA256 验证 → Dir.rename() 原子移动

**验证结果**:
- `zig build test` 全过（含 tunproto round-trip 测试全部更新）
- 8 目标交叉编译全过
- 单例 key 简化为 `"<vm>:<path>"` — 仅按目标路径去重
- 本机双端口功能测试：mesh 同机路由修复后全部通过

**Status:** complete

### Phase 34: v0.11.5 — Mesh 同机双端口路由修复 ✅ (2026-07-25)

**问题**: Host 和 Guest 在同一台机器上使用不同 mesh 端口时，KCP 双向通信失败。
Guest 能收到 Host 的 KCP 数据并创建 session，但 `meshKcpOutput` 发送 ACK 时
找不到 Host 的邻居条目（因为 Host 的 LSA 通过端口 2121 广播，Guest 监听 2122
收不到），导致 `neighbor not found for next_hop`，KCP 会话单向失效。

**根因**: `handleKcpData(from)` 忽略了 `from` 参数。当 LSA 无法直接到达时，
接收方无法建立返向邻居关系。

**修复** (`src/mesh.zig`):
- `handleKcpData` 不再忽略 `from` 参数
- 创建新 session 时，自动将 `src_mac` 添加为邻居（`addr = from`, `cost = 1`）
- 这样 KCP ACK/output 可以直接发回源地址，不依赖 LSA 邻居发现

**验证结果**:
| 测试 | 结果 |
|------|------|
| `zig build test` | ✅ |
| 本机双端口 exec | ✅ `echo hello` |
| 本机双端口 upload + SHA256 | ✅ hash 验证通过 |
| 本机双端口单例去重 | ✅ `transfer_in_progress` |
| 本机双端口 download + SHA256 | ✅ 内容+hash 匹配 |
| 本机双端口 GET / 目录列表 | ✅ Guests + Files 表格 |
| download `sendBodyComplete("")` panic | ✅ 改为发送 `"{}"` body |

**Status:** complete

### Phase 35: v0.11.5 — Windows cmd.exe UTF-8 强制设置 ✅ (2026-07-25)

**问题**: `ptySpawnWindows` 启动 `cmd.exe /k`，默认 code page 是系统 ANSI
（中文 Windows 为 936）。命令和文件名中的中文会乱码。

**修复** (`src/broadcast.zig` `ptySpawnWindows`):

三层 UTF-8 保障：

| 层 | 机制 | 生效条件 |
|----|------|---------|
| 1 | `SetConsoleOutputCP(65001)` + `SetConsoleCP(65001)` | utmm 有 console（前台运行），子进程继承 |
| 2 | cmd 命令行 `chcp 65001 >nul` | cmd.exe 内部执行（无 console 时兜底） |
| 3 | `set LANG=en_US.UTF-8` | 跨平台工具（git、python 等）尊重此变量 |

- 启动命令从 `cmd.exe /k` → `cmd.exe /k chcp 65001 >nul & set LANG=en_US.UTF-8`
- `PtySession.shell` 同步更新（`buildCmdWithMarker` 通过 `indexOf("cmd.exe")` 子串匹配正确识别）

**验证结果**:
- `zig build test` ✅
- `aarch64-windows` + `x86_64-windows` 交叉编译 ✅

**Status:** complete

### Phase 36: KCP 隧道自动升级 ✅ (2026-07-25)

**问题**: WebSocket 移除 (v0.11.0) 后，自动升级路径断了。旧代码通过 WS binary
frame 传输升级二进制 (`upgrade_bin`)，新 KCP 隧道使用 tunproto 消息格式。

**修复**:

| 文件 | 变更 |
|------|------|
| `src/tunproto.zig` | 新增 `upgrade_req` (0x17) / `upgrade_bin` (0x1a) 消息类型，build/parse 函数 + 测试 |
| `src/broadcast.zig` | `performUpgrade()` 重写：tunnel.send upgrade_req → recv loop 收 upgrade_bin → SHA256 全量校验 → selfReplace(data) |
| `src/host_http.zig` | `handleUpgradeReq()` 新增：收到 upgrade_req → 读 serve_dir 二进制 → SHA256 → 发送 upgrade_bin |
| `src/host.zig` | KCP tunnel 在 `startHost()` 中初始化，传入 `handleMeshGuest` 回调 |

**关键决策**:
- upgrade_bin 使用 blob-in-message 模式（二进制直接嵌入消息），因为升级文件 ~5-20MB 尚可接受
- Upgrade 流程: Guest 发 upgrade_req → Host 读二进制 + SHA256 → 发送 upgrade_bin → Guest 校验 + selfReplace

**验证结果**:
- `zig build test` ✅
- 8/8 目标交叉编译 ✅

**Status:** complete

### Phase 37: 分块文件传输协议 (替代一次性大消息) ✅ (2026-07-25)

**问题**: KCP `recv(buf)` 要求 buf ≥ 完整消息大小。旧设计把文件数据嵌入单条消息
(`upload_data` / `download_result` / `upgrade_bin`)，导致：
1. 接收方必须分配文件大小的内存，GB 级文件不可接受
2. 升级二进制 5-20MB 全量加载到内存

**方案**: 文件按 8KB 分块，每块作为独立 KCP 消息发送。固定 256KB buffer，撤销
peekSize 动态分配。增量 SHA256 (`init`/`update`/`final`) 逐块计算。

**新增 tunproto 消息**:

| 类型 | 值 | 方向 | 载荷 |
|------|-----|------|------|
| `upload_cmd` | 0x1b | Host→Guest | cmd_id + path + file_size + file_hash |
| `file_chunk` | 0x1c | 双向 | cmd_id + data (8KB 文件片段) |
| `file_eof` | 0x1d | 双向 | cmd_id + exit_code + file_size + file_hash |

**移除/废弃**:

| 类型 | 原因 |
|------|------|
| `upload_data` (0x13) | 被 upload_cmd + file_chunk × N + file_eof 替代 |
| `download_result` (0x18) | 被 file_chunk × N + file_eof 替代 |
| `upgrade_bin` (0x1a) | 被 file_chunk × N + file_eof 替代 |

**三条传输路径**:

| 路径 | 旧（blob-in-message） | 新（分块） |
|------|----------------------|-----------|
| Upload (Host→Guest) | readRawBody → buildUploadData | 流式读 body 8KB → file_chunk × N → file_eof |
| Download (Guest→Host) | readFileContent → buildDownloadResult | 流式读文件 8KB → file_chunk × N → file_eof |
| Upgrade (Host→Guest) | 读二进制 → buildUpgradeBin | 流式读二进制 8KB → file_chunk × N → file_eof |

**变更文件**:

| 文件 | 变更 |
|------|------|
| `src/tunproto.zig` | 新增 upload_cmd/file_chunk/file_eof 枚举值 + struct + build/parse 函数 + 7 个测试；删除旧 blob-in-message 函数和结构体；162 行旧代码移除 |
| `src/broadcast.zig` | 新增 `receiveChunkedFile()` / `sendChunkedFile()` / `hexHash()`；重写 `performUpgrade()`（分块收 + 增量 SHA256）；`selfReplace()` 签名改为 temp 文件路径；恢复 256KB 固定 buffer |
| `src/host_http.zig` | `handleUpload` 流式读取 + 增量 SHA256；`handleDownload` 适配 file_chunk/file_eof 接收；`handleMeshGuest` 新增 file_chunk/file_eof dispatch；`handleUpgradeReq` 流式 serve_dir 读取 + 增量 SHA256；恢复 256KB 固定 buffer |
| `src/httpd.zig` | 注释修正：download_result → file_eof |

**验证结果**:
- `zig build test` ✅（含 6 个 round-trip 测试 + 1 个 flow 测试）
- 8/8 目标交叉编译 ✅
- 支持 >1GB 文件，内存占用恒定 ~256KB

**Status:** complete

### Phase 38: KCP 协议完整重写 — 匹配 C 参考实现 ✅ (2026-07-25)

**问题**: 自升级 KCP 文件传输在 ~38KB 后停滞。诊断发现 Zig 版 KCP 实现与 C 参考
(skywind3000/kcp) 存在 10+ 处关键差异，导致滑动窗口无法正常工作。

**10 个关键差异与修复**:

| # | 差异 | C 参考行为 | 旧 Zig 实现 | 修复 |
|---|------|-----------|-----------|------|
| 1 | `rmt_wnd` | 从每个 segment header 读取，限制发送窗口 | 缺失 | 新增字段，input() 中逐段更新 |
| 2 | 发送窗口 | `snd_nxt < snd_una + cwnd`（SN 比较） | `snd_buf.items.len < snd_wnd_max`（段计数） | flush() 改用 SN 比较 |
| 3 | 接收窗口检查 | `sn < rcv_nxt + rcv_wnd` 且 `sn >= rcv_nxt` | 无窗口检查 | parseData() 新增双重检查 |
| 4 | rate limiting | `ts_flush + interval` 限制 flush 频率 | 无条件调用 flush() | update() 用 ts_flush rate-limit |
| 5 | 窗口探测 | `rmt_wnd == 0` 触发探测 | 错误检查 `rcvWnd()`（自身窗口） | flush() 修正为 rmt_wnd |
| 6 | ACK 发送守卫 | C 无守卫；Zig 在 `snd_buf >= WND_SND` 时停止 | ACK 停发导致死锁 | 移除守卫，无条件发送所有 ACK |
| 7 | xmit 初始值 | 段创建时 xmit=0 | xmit=1 | send() 设 xmit=0，flush() 首次发送时递增 |
| 8 | shrink_buf | parse_una 后从 snd_buf[0] 更新 snd_una | 缺失 | 新增 shrinkBuf()，input()/parseAck() 后调用 |
| 9 | fastack 聚合 | 聚合 maxack/latest_ts，每包调用一次 parse_fastack | 每段调用 | input() 末尾聚合后单次调用 |
| 10 | 拥塞控制 after input | snd_una 推进后更新 cwnd（30+ 行） | 缺失 | input() 末尾新增完整 cwnd 更新逻辑 |

**额外改进**:

| 项目 | 说明 |
|------|------|
| RTO jitter | flush() 中 nodelay=0 时 `resendts = current + rto + rtomin`（rtomin = rx_rto >> 3） |
| acklist 格式 | 从 `ArrayList(u32)` 改为 `ArrayList([2]u32)`，存储 (sn, ts) 对 |
| 流模式合并 | send() 中追加到 snd_queue 最后一个段（避免碎片化） |
| 批量编码 | 新增 `encodeSeg()` + `outputData()`，flush() 中批量编码到 MTU 包 |
| ssthresh/cwnd 更新 | 快速重传时 `ssthresh = inflight/2, cwnd = ssthresh + resent`；超时时 `ssthresh = cwnd/2, cwnd = 1` |

**变更文件**:

| 文件 | 变更 |
|------|------|
| `src/kcp.zig` | 完整重写 — struct 新增 5 字段、acklist 格式变更、send/input/update/check/flush 全部重写、新增 shrinkBuf/outputData/encodeSeg、所有 parse 函数重写、ackPush 改为 (sn,ts) 对 |

**验证结果**:
- `zig build test` — 91/91 测试通过 ✅
- 7/8 目标交叉编译通过 ✅（x86-windows-gnu 已知 `_system@4` 链接器警告）

**Status:** complete

### Phase 39: v0.11.6 — cross-Io mutex 导致 exec 超时修复 ✅ (2026-07-25)

**Bug**: KCP 重写 (Phase 38) 部署后，`utmm --exec` 在所有 VM 上超时。Host 侧
`handleMeshGuest` recv loop 持续收到 0 字节（`recv empty x17000`），Guest 收到
pty_spawn 但 pty 输出无法到达 Host。

**根因链路**:
1. `broadcast.zig:waitForHostTunnel` 接收主线程的 `io` 参数
2. `Tunnel.init(allocator, io, sess)` 将主线程的 `io` 存入 `self.io`
3. `Tunnel.recv()` 调用 `sessions_mutex.lock(self.io)` — 但 `self.io` 是主线程的 Io
4. `sessions_mutex` 由 `Mesh.init()` 用 `m.io`（mesh 线程的 `Io.Threaded`）创建
5. Zig 0.16.0 `Io.Mutex.lock()` 要求调用者使用与创建时**相同的 Io 实例**
6. 不同 Io 实例 → `error.Canceled` → `tun.recv()` 返回错误
7. `handleMeshGuest` recv 错误退出 → pty_spawn 被成功写入但 pty 输出无法到达 Host → exec 超时

**为什么 Host 侧不受影响**: Host 在 `host.zig:728` 创建 Tunnel 时使用 `m.io`（mesh
线程的 Io），与 `sessions_mutex` 创建时使用的 Io 一致。只有 Guest 在 `waitForHostTunnel`
中错误地传入主线程的 `io`。

**为什么之前未暴露**: `tunnel.zig` 的 `send()/recv()` 之前使用 `catch {}` 静默吞掉
锁失败错误。Phase 38 期间改为 `try`（传播错误），使 cross-Io 问题从静默无数据
变为 fatal 错误。

**修复**: 单行修改 `src/broadcast.zig:1232`

```diff
- return tunnel_mod.Tunnel.init(allocator, io, sess);
+ return tunnel_mod.Tunnel.init(allocator, m.io, sess);
```

**验证结果**（部署到 linuxvm + macvm + windowsvm 后）:

| VM | 测试 | 结果 |
|-----|------|------|
| linuxvm | `uname -a` | ✅ |
| linuxvm | `cd /tmp && pwd`（持久 shell） | ✅ |
| linuxvm | `ps aux`（多行输出） | ✅ |
| macvm | `sw_vers` | ✅ |
| macvm | `export FOO && echo $FOO`（持久 shell） | ✅ |
| macvm | `ls -la /opt/utmm/` | ✅ |
| windowsvm | `ver` | ✅ |
| windowsvm | `echo WIN_OK` | ✅ |
| windowsvm | `whoami`（返回 SYSTEM） | ✅ |
| windowsvm | `cd C:\opt\utmm && cd`（持久 shell） | ✅ |
| windowsvm | `dir C:\opt\utmm\*.exe`（多行输出） | ✅ |

**Status:** complete

### Phase 40: v0.11.6 — Windows 服务优雅关闭修复 ✅ (2026-07-25)

**Bug**: `sc stop` 在 Windows 上返回 error 109 (ERROR_BROKEN_PIPE)。旧版
`svcCtrlHandler` 收到 `SERVICE_CONTROL_STOP` 后直接调用 `std.process.exit(0)`，
其在 Windows 上调用 `ExitProcess()` — 硬终止进程，破坏了 SCM 管道。

**修复**: 用原子标志位实现优雅关闭，6 个文件修改：

1. `src/main.zig:svcCtrlHandler` — 替代 `std.process.exit(0)`：
   - 报告 `SERVICE_STOP_PENDING` + 设置 `shutdown_flag.store(true, .release)`
   - 新增 `SERVICE_STOP_PENDING = 0x00000003` 常量
   - 新增 `SvcGlobals.shutdown_flag: std.atomic.Value(bool)`
   - `svcMain` 在 `runWithIo` 返回后报告 `SERVICE_STOPPED`

2. `src/guest.zig` — `runWithIo` + `run` 新增 `shutdown: ?*std.atomic.Value(bool)` 参数，
   传递给 `meshSessionLoop`

3. `src/broadcast.zig:meshSessionLoop` — 新增 `shutdown` 参数 + `checkShutdown` 辅助函数。
   在 3 个位置检查标志：外层 while 循环、pty_spawn 等待循环、命令调度循环

4. `src/agent.zig` — 两处 `guest.runWithIo` 调用新增 `null` 参数（前端不需要 shutdown 标志）

5. `src/host.zig` — `runWithIo`/`run`/`startHttpHost` 新增 `shutdown` 参数，传递给 `httpd.serve`

6. `src/httpd.zig:serve` — accept 循环前新增 shutdown 检查

**同时修复**: `src/host.zig:224` — `@intCast(exit_code)` panic（Windows 错误码如 1060
超出 u8 范围）。改为 clamp: `exit_code <= 0 or exit_code > 255 → 1`。

**验证结果**（部署到 windowsvm）:

| 测试 | 结果 |
|------|------|
| `sc query` 显示 STOPPABLE | ✅ STATE: 4 RUNNING (STOPPABLE) |
| `sc stop` → STOP_PENDING 被报告 | ✅ STATE: 3 (STOP_PENDING), CHECKPOINT: 1 |
| 服务停止后 WIN32_EXIT_CODE | ✅ 0 (无错误，旧版报 109) |
| `sc start` 后服务恢复 | ✅ RUNNING, STOPPABLE |
| KCP exec 功能 | ✅ 正常 |

**7/7 目标编译**: ✅ aarch64/x86_64/x86 × linux-musl/macos/windows

**Status:** complete

### Phase 41: v0.11.8 — Windows KCP stall 定时器线程修复 ✅ (2026-07-26)

**Bug**: Windows Guest `runWindows()` 使用阻塞 `receive()` 无超时。KCP flush、
keepalive、ACK、LSA 广播仅在收到外部包时执行。空闲连接上 pty_output 永远卡在 KCP
snd_queue 中无人 flush，所有 exec 命令 hang。

**根因**: POSIX `runPosix()` 用 `receiveTimeout(1s)`，超时时驱动 `periodicTasks()`。
Windows 没有实现超时机制。

**修复**:
1. `runWindows()` — spawn 独立定时器线程 `runWindowsTimer()`，每秒执行 `periodicTasks()`
2. `tunnel.zig` — 新增 `sendAndFlush()`：pty output 帧立即 flush（不等 1s 定时器）
3. `mesh.zig` — 定时器线程与主 receive 线程通过 `sessions_mutex` 同步
4. 9 个 `send()` 调用点 → 改为 `sendAndFlush()`（ptyReadLoop 关键路径）

**文件变更**: `src/mesh.zig` (+64/-6), `src/tunnel.zig` (+24/-0), `src/broadcast.zig` (9 处 send→sendAndFlush)

**验证**: 10+ 连续 exec 在 windowsvm 上全部成功

**版本**: 0.11.7 → 0.11.8

**Status:** complete

### Phase 42: v0.11.9 — Windows mesh runWindows 简化 ✅ (2026-07-26)

**背景**: Phase 41 后，v0.11.8 Debug Guest (阻塞+定时器) + Host 在 windowsvm 上 exec
正常工作 4+ 次。但代码重构为两阶段方案（先 receiveTimeout 后回退）后 exec 挂起。

**迭代 1 — 两阶段方案 (8eaafa5)**:
- 先尝试 `receiveTimeout`（同 POSIX），失败则回退到阻塞+定时器
- `break` → `continue` 修复：`error.ConcurrencyUnavailable` handler 中的 `break`
  退出外层 while 循环而非进入回退路径

**迭代 2 — 对比测试发现 (d9bed65)**:
- 强制 `use_blocking = true`（旧方案）→ exec 立即正常工作
- 默认 `use_blocking = false`（receiveTimeout 路径）→ exec 挂起
- **根因**: service Io 的 `receiveTimeout` 在 ARM64 Windows 上静默失败 —
  UDP 包到达 socket 但 KCP 应用层数据无法被读取

**最终修复**: 简化为始终使用阻塞+定时器（与 v0.11.8 一致），移除 receiveTimeout 尝试路径。
`runWindowsTimer` 改用原始 Win32 `Sleep()` 消除 Io 依赖。

**关键教训**:
1. Host 陈旧状态会干扰新 Guest 连接 — 测试前需重启 Host
2. Windows ARM64 service Io 行为与 POSIX Io 不同 — 不能假设 receiveTimeout 可用
3. 阻塞 receive + 独立定时器线程是最可靠的 Windows 方案

**文件变更**: `src/mesh.zig` (28+/84-, 净减少 56 行), `src/ver.zig` (0.11.8→0.11.9)

**验证**: 10/10 连续 exec windowsvm 成功，`zig build test` 全绿

**Status:** complete

### Phase 43: v0.11.9 — KCP tunnel session 匹配 + 重连竞态修复 ✅ (2026-07-26)

**背景**: v0.11.9 部署后，`--exec` 到物理 Windows Guest 挂起。

**Root Cause 1 — LSA ephemeral source port** (`src/mesh.zig`):  
物理 Windows `sendto()` 可能从临时端口发送 LSA 广播。Host 将 LSA 源端口存储为
KCP 目标 → KCP 数据发往错误端口。  
**修复**: `handleLsa` neighbor address 始终使用 `protocol.DEFAULT_PORT` (2121)。

**Root Cause 2 — 重连竞态** (`src/broadcast.zig`):  
Host 重启后 Guest 旧命令循环消耗 `pty_spawn` (0x10)，下一帧 `pty_exec_input`
(0x11) 非预期 → 永远卡住。  
**修复**: pty_spawn 读取循环同时接受 pty_exec_input 作为隐式 spawn 触发器，
缓冲 exec 命令待 pty 就绪后投递。

**Root Cause 3 — 双会话 conv 不匹配** (`src/host.zig`):  
Host `m.connect()` 和 Guest 各自使用不同 nonce → 不同 conv ID →
双会话独立运行 → 输出无法到达 Host。  
**修复**: tunnelManager 统一搜索 Guest 发起的会话表条目，优先使用而非创建 Host 会话。

**验证** (2026-07-26, 全部 4 Guest):
- linuxvm: ✅ persistent shell (cd /tmp, export) 正常
- macvm: ✅
- windowsvm (UTM bridge): ✅
- MODASIAIPC (物理 Windows x86_64): ✅

**Commit**: `adffa15` (+98/-22: mesh.zig, broadcast.zig, host.zig)

**遗留问题**:
1. `host_http.zig:respondError` → `discardBody` panic — zig 0.16.0 `endChunked`
   在 client 断开时触发 std/http/Server.zig:628 unreachable
2. Host log `/var/log/utmm-host.log` 始终为空 — stdout 缓冲
3. macOS Guest CLI exec 在 pty 会话终止时偶尔 Writer panic

**Status:** complete
