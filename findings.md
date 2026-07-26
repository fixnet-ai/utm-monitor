# Findings: v0.11.5

## Upload/Download 优化 Discoveries (2026-07-25)

### `std.fmt.fmtSliceHexLower` 在 Zig 0.16.0 中已移除

SHA256 hex 编码需手动实现。3 个调用位置（broadcast.zig、host.zig × 2），统一使用
手动循环 `"0123456789abcdef"[b >> 4]` / `"0123456789abcdef"[b & 0x0F]`。

### `Dir.rename()` 参数顺序

Zig 0.16.0 签名: `Dir.rename(old_dir, old_path, new_dir, new_path, io)` — io 是最后一个参数。

### `Dir.Iterator.next(io)` 需要 io 参数

Zig 0.16.0 `Dir.Iterator.next()` 需要传入 `io` 参数: `iter.next(io)`。

### 单例 key 设计 — 简化为仅目标路径

原始设计 `"up:<vm>:<path>"` / `"dl:<vm>:<path>"` 区分了方向和来源。
用户反馈: 只需按目标路径去重，其他机器也可能上传/下载同一文件。
最终 key: `"<vm>:<path>"` — upload 和 download 去同一目标也共享 key
（不能同时运行）。

### Mesh 同机路由问题（已修复）

原问题: 本机双端口测试时，Host 和 Guest 使用不同 mesh 端口（2121/2122），
Guest 的 KCP output 找不到 Host 邻居（LSA 通过端口 2121 广播，Guest 监听 2122 收不到）。

修复: `handleKcpData` 创建新 session 时，自动将 `src_mac` 添加为邻居（`addr = from`）。
这样 KCP 反向通信不依赖 LSA 邻居发现。

### Windows cmd.exe UTF-8 三层保障 (2026-07-25)

`CreatePipe` + `CreateProcessW("cmd.exe /k")` 模式下，cmd.exe 没有真正 console，
默认 code page = 系统 ANSI（中文 Windows 为 936），UTF-8 命令和文件名可能乱码。

**三层修复**:
1. `SetConsoleOutputCP(65001)` + `SetConsoleCP(65001)` — utmm 有 console 时子进程继承
2. `chcp 65001 >nul` — cmd.exe 内部设置（无 console 时兜底）
3. `set LANG=en_US.UTF-8` — 跨平台工具（git、python 等）尊重此变量

### Zig 0.16.0 `respondStreaming` + 空 body panic

`cmdDownload` 使用 `sendBodyComplete("")` 发送空 body 到 POST /download，
触发 `respondStreaming` → `discardBody` → `unreachable` panic。
修复: 发送非空 body `"{}"`。

## Auto-Upgrade 阻塞读取 Bug (2026-07-24)

**现象**: v0.8.0 Guest 收到 Host v0.8.1 UDP 广播，版本不匹配被正确检测，但升级从未触发。

**根因**: `wsAnnounceLoop` 内层循环阻塞在 `conn.readFrame(&rbuf)`（等待 Host 发送 WebSocket 帧）。UDP listener 线程收到版本广播后设置 `upgrade.needed = true`（原子标志），但主循环无法检测——WebSocket read 是无超时的阻塞操作。如果没有 exec/upload 等主动操作触发帧到达，标志永远不会被检查。

**POSIX 修复**: 内层循环中 `poll()` 设置 1s 超时。在 `poll_n == 0` 路径中新增 `upgrade.needed` 检查。升级在 1 秒内检测到。

**Windows 修复**: 无 poll 机制，`readFrame` 直接阻塞。利用已有的 timer 线程（每秒写 announce 帧）：`TimerCtx` 增加 `upgrade: *UpgradeSignal` 字段；timer 线程检测到 `upgrade.needed` 时关闭 `conn.stream` → `readFrame` 报错退出 → 外层重连循环在 line 1128 检测到标志并触发升级。

**教训**: 跨线程信号传递必须有唤醒机制。原子标志是必要条件非充分条件——消费者必须在合理时间内检查标志。阻塞 I/O 操作需要超时或外部中断（socket close / shutdown）。

## Previous Findings (v0.8.0)

## Environment
- Host: macOS aarch64, Zig 0.16.0
- VMs: linuxvm (aarch64-linux-musl), macvm (aarch64-macos), windowsvm (aarch64-windows), winx64 (x86_64-windows)
- Current version: v0.8.0

## Architecture Decision Records

### ADR-1: Persistent pty over per-command exec
**Decision**: Spawn a persistent shell (POSIX `posix_openpt` / Windows `CreatePipe`)
per WebSocket connection. Feed commands via pty stdin, read output from pty stdout.
**Rationale**: Users expect `cd` and `export` to persist across commands. v0.4.0
"Connection = Shell Session" model spawned a fresh child process for each command —
no env/cd persistence.
**Consequence**: ~300 lines of exec streaming code deleted. Added ptySpawn, ptyReadLoop,
ptyWrite. Shell session lives for the WebSocket lifetime.

### ADR-2: MDELIM exit-code markers for completion detection
**Decision**: Append `; echo MDELIM:$?\n` (POSIX) or `& echo MDELIM:%errorlevel%\r\n`
(cmd.exe) to every command. Host scans pty output for the marker to detect completion.
**Rationale**: pty merges stdout+stderr — no separate pipe for exit codes. Markers
embedded in the output stream are the simplest cross-platform solution.
**Consequence**: `scanForMarker` uses `lastIndexOf` to handle echoed command text on
macOS/BSD (where pty master doesn't support tcsetattr ECHO disable).

### ADR-3: Outgoing frame queue over direct write
**Decision**: HTTP handlers enqueue binary frames into `HostState.outgoing_frames`
(per-guest FIFO queue). WebSocket handler drains the queue in its main loop.
**Rationale**: WebSocket handler is single-threaded per guest. HTTP handlers run in
separate threads. Queue avoids concurrent write races.
**Consequence**: `OpState` + `wake_event` pattern: HTTP handler enqueues frame,
creates OpState, polls `takeOpResult()` with 30s timeout, sleeps on `wake_event`.

### ADR-4: Unified HTTP server on port 2121
**Decision**: Single `std.http.Server` handles all: WebSocket upgrades, REST API,
MCP JSON-RPC, static file serving. Guest is pure WebSocket client — no TCP server.
**Rationale**: Eliminates UDP broadcast discovery (v0.2.0), TCP binary protocol
server on guest (v0.2.0), and separate MCP port :2122 (v0.2.0).
**Consequence**: Net deletion of ~1100 lines. Guest auto-discovers Host via default
gateway. Single port simplifies firewall and debugging.

### ADR-5: Same binary for Host and Guest
**Decision**: Single `utmm` binary, default Guest mode, `--host` flag for Host mode.
**Rationale**: Reduces maintenance — no need to build/distribute separate host/guest
binaries.
**Consequence**: All modules compiled into one binary. `comptime` block in main.zig

### ADR-6: UDP broadcast for --status discovery (v0.6.0)
**Decision**: `utmm --status` sends UDP broadcast to 255.255.255.255:2121 instead of
HTTP GET to 127.0.0.1. Each Guest runs a UDP listener on :2121 that responds to
"ARE YOU OK?\r\n" with an ANNOUNCE text block. Sender collects responses for 5
seconds, deduplicates by hostname.
**Rationale**: Old `--status` only worked on the Host machine — it was an HTTP client
connecting to localhost. Any machine on the LAN can now discover all UTM guests
without knowing which machine is the Host.
**Consequence**: Guest gets a new background thread (`udpDiscoveryListener`). The
`--status` command no longer requires a running Host daemon. UDP port 2121 coexists
with TCP port 2121 (Host HTTP server) on the same machine without conflict.
**Protocol**: Query = "ARE YOU OK?\r\n" (12 bytes). Response = text block using
existing `GuestInfo.parse()` format (ANNOUNCE header + key:value lines).
5 broadcasts at 1-second intervals ensure delivery despite UDP unreliability.

## Platform-Specific Notes

### UDP Broadcast Discovery (Zig 0.16.0)

```zig
// Bind UDP socket for broadcast send + receive
const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
const socket = try addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
defer socket.close(io);

// Send to broadcast address
const broadcast = try std.Io.net.IpAddress.parse("255.255.255.255", 2121);
try socket.send(io, &broadcast, "ARE YOU OK?\r\n");

// Receive with timeout
const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(1), .clock = .awake } };
const msg = try socket.receiveTimeout(io, &buf, timeout);
// msg.from: IpAddress (sender address for response)
// msg.data: []u8 (received bytes, slice into caller's buffer)

// Respond to sender
try socket.send(io, &msg.from, response);
```

- `BindOptions.allow_broadcast = true` required for: sending broadcasts (Linux + macOS),
  receiving broadcasts (macOS only). Without it on macOS, `receiveTimeout` silently
  ignores broadcast packets even though tcpdump shows them arriving.
- `Socket.send()` is connectionless — specify destination on every call.
- `Timestamp.now(io, .real)` returns `Timestamp` directly (not error union).
- `Io.Duration.fromSeconds(n)` creates second-precision durations.
- `StringHashMap(T).init(gpa)` — unmanaged HashMap, uses `.init` not `.empty`.

### POSIX pty
- `posix_openpt(O_RDWR)` → `grantpt`/`unlockpt` → `fork()` → child: `setsid()`,
  `ioctl(TIOCSCTTY)`, `dup2(slave→0,1,2)`, `execve(shell, argv, environ)`
- macOS/BSD: pty master fd does NOT support `tcsetattr` (ECHO disable returns error).
  Host-side `scanForMarker` handles echoed command text via `lastIndexOf`.
  Linux: `tcsetattr` on master works normally.
- `execve` must pass `std.c.environ` (parent env), NOT `{null}` (empty env).
  Empty env means no HOME/SHELL/USER, `.bashrc`/`.zshrc` not loaded.

### Windows pty
- `CreatePipe` × 2 (stdin + stdout) → `CreateProcessW("cmd.exe /k")` with
  `STARTF_USESTDHANDLES`. `lpEnvironment=NULL` inherits parent env automatically.
- No `poll()`: main loop blocks on `readFrame`. Timer thread handles periodic
  re-announce. Exec completion signaled via WebSocket PING (wakes `readSmallMessage`).
- `CreateProcessW` + `STARTUPINFOW` must use UTF-16LE command line.
  `std.unicode.utf8ToUtf16LeWithNull` removed in 0.16.0 — manual UTF-16 encode.

### Shell compatibility
- `-l` (POSIX short option) works on all shells: dash, bash, zsh. GNU long option
  `--login` rejected by dash (Debian/Ubuntu `/bin/sh`).
- System services (systemd/launchd) have minimal environments: no HOME, no SHELL.
  `--install` now writes `Environment=SHELL=...` and `Environment=HOME=...` into
  service configs at install time.

## Bug Fixes (v0.5.0)

### CPU 100% on shell exit (all platforms)
**Root cause**: `ptyReadLoop` poll loop only checked `POLL.IN`. When shell exits,
pty master gets `POLL.HUP` — poll returns immediately but HUP was ignored, causing
busy-spin at 100% CPU.
**Fix**: Check `POLL.HUP` before `POLL.IN`, set `pty_dead=true`, break.

### waitTimeout infinite block on guest disconnect
**Root cause**: HTTP/MCP handlers called `wake_event.wait()` (no timeout). If guest
disconnected while a command was in flight, the handler thread blocked forever.
**Fix**: `wake_event.waitTimeout(30s)` in all four locations (host_http.zig × 3,
mcp.zig × 1). New `failAllPendingOps()` called on WS disconnect — marks all pending
ops as done with error, fires wake_event to unblock waiting handlers.

### `Io.Timeout` type mismatch
**Root cause**: `Io.Duration` passed where `Io.Timeout` union expected.
**Fix**: `.{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } }`.
`Io.Clock` uses `.awake` for monotonic-like clock.

### ptySpawn empty environment
**Root cause**: `execve(shell, argv, &[_:null]?[*:0]const u8{null})` passed empty
environment to child shell. HOME/SHELL/USER all empty, .bashrc/.zshrc not loaded.
**Fix**: Changed to `execve(shell, argv, std.c.environ)` — inherits parent process
environment. Windows `CreateProcessW(NULL, ..., NULL, ...)` unaffected (NULL = inherit).

### `--install` missing SHELL/HOME in service configs
**Root cause**: Generated systemd/launchd service files had no `Environment` variables.
Shell spawned by service had no HOME/SHELL.
**Fix**: Added `detectServiceEnv()` — reads `$SHELL`/`$HOME` at install time, falls
back to platform defaults (`/bin/zsh` on macOS, `/bin/bash` on Linux). Both
`genInit` and `installSelf` templates now include environment configuration.

### detectServiceEnv reads SSH environment (bogus shell)
**Root cause**: `detectServiceEnv()` read `$SHELL` from the environment. When install.sh
runs via SSH, `$SHELL=/bin/sh` (SSH daemon default), not the user's configured shell.
The service plist was generated with `/bin/sh` instead of `/bin/zsh` on macOS.
**Fix**: Rewrote `detectServiceEnv()` to always use platform defaults (`/bin/zsh`
macOS, `/bin/bash` Linux, `cmd.exe` Windows). Service environments (systemd/launchd/
schtasks) have no user shell preferences — platform defaults are always correct.
Commit: `fb9f22b`.

### macOS AMFI kills unsigned binary after curl download
**Root cause**: `curl` strips code signatures from binaries. When a launchd service
runs the binary as root, AMFI (Apple Mobile File Integrity) sends SIGKILL. Exit code
137. Symptom: `utmm --install` or any sudo invocation of the downloaded binary dies
immediately.
**Fix**: Added `sudo codesign --force --sign -` to `install.sh` for macOS Guest
deployment (line 267-269). The Host binary is self-built and linker-signed (adhoc),
so Host deployment is unaffected. Commit: `fb9f22b`.

### getifaddrs endianness (v0.6.0 UDP broadcast fix)
**Root cause**: `sin.sin_addr.s_addr` is stored by C as network byte order (big-endian).
On little-endian systems (macOS aarch64, Linux aarch64/x86_64), Zig reads the u32 in
host byte order. Bitwise ops (`ip | ~netmask`) produce correct result, but octet
extraction via `>>24/>>16/>>8/&FF` on host-byte-order u32 yields reversed bytes.
**Fix**: `@byteSwap(bc)` before extracting octets. Also filter loopback (127.0.0.0/8)
after byteSwapping. Check `bc_be == ip_be` for /32 point-to-point detection.

### Subnet-directed broadcast required for UTM bridge
**Root cause**: `255.255.255.255` (limited broadcast) is only routed out the default
route interface (en0). UTM bridge interfaces (bridge100 at 192.168.64.0/24) do not
carry limited broadcasts.
**Fix**: `getSubnetBroadcasts()` in `broadcast.zig` uses `getifaddrs()` to enumerate
all local IPv4 interfaces, computes subnet-directed broadcast (`ip | ~netmask`) for
each, and sends to all unique broadcast addresses. Windows keeps 255.255.255.255 only.

### StringHashMap dedup use-after-free
**Root cause**: When `found_existing` is true in `getOrPut`, old value is deinited
(including its hostname string). But the HashMap's stored key still points to the
freed hostname. On next `getOrPut` with the same hostname, content comparison may
fail (dangling pointer), creating duplicate entries.
**Fix**: First-wins strategy: if `found_existing`, discard the newly parsed value;
only store when it's a new hostname.

### Windows UDP Io.Threaded ConcurrencyUnavailable (v0.6.0)
**Root cause**: Zig 0.16.0 `Io.Threaded` on Windows does not support concurrent
`net_receive`. `receiveTimeout` uses `batchAwaitConcurrent` which passes `concurrency=true`
to `batchDrainSubmittedWindows`. The `net_receive` case at Threaded.zig line 3198
returns `ConcurrencyUnavailable` because overlapped I/O (APC-based) isn't integrated
yet for network operations. There's an explicit TODO: "TODO integrate with overlapped
I/O or equivalent to avoid this error".
**Fix**: On Windows, use blocking `receive()` (async path, `concurrency=false`) instead
of `receiveTimeout()`. The async path works — `batchDrainSubmittedWindows(t, b, false)`
does blocking I/O via `netReceiveOneWindows`. No timeout available, so on shutdown the
main thread closes the socket handle (`CloseHandle`) to unblock the pending receive.
UDP listener stores socket handle in atomic pointer for main thread access. POSIX
continues using `receiveTimeout` which works correctly (uses `poll`).

## v0.8.0 Findings

### macOS AMFI: codesign must happen in /tmp, not /opt/utmm/

**Problem**: macOS AMFI (Apple Mobile File Integrity) kills unsigned binaries
from `/opt/utmm/` with SIGKILL. `codesign --force --sign -` run directly in
`/opt/utmm/` fails with "internal error in Code Signing subsystem".

**Root cause**: `/opt/` is SIP-protected on some macOS configurations. The
`codesign` tool cannot modify binaries in place under `/opt/utmm/` when SIP
restrictions apply.

**Fix**: Sign the binary in `/tmp/utmm-sign`, then `mv` to `/opt/utmm/`.
`mv` (rename) preserves the valid code signature.

```bash
# Works: sign in /tmp, mv to /opt/utmm/
cp /opt/utmm/utmm-aarch64-macos /tmp/utmm-sign
codesign --force --sign - /tmp/utmm-sign
sudo mv /tmp/utmm-sign /opt/utmm/utmm-aarch64-macos
```

### sendBodiless panic with chunked encoding

**Problem**: `std.http.Client.Request.sendBodiless()` panics at `Client.zig:914`
when the connection uses chunked transfer encoding. The panic hits `unreachable`
because `r.connection.?.flush()` returns an error outside `Writer.Error` set.

**Fix**: Use `req.sendBodyComplete("")` instead of `req.sendBodiless()` for
POST requests with empty body. Works correctly with chunked encoding.

### x86-windows MinGW linker warning promoted to error

**Problem**: `x86-windows` target produces `lld-link: warning: Resolving _system@4
by linking to _system` — Zig promotes linker warnings to errors.

**Fix**: Use `x86-windows-gnu` target triple instead. Produces identical 32-bit
Windows PE executable without the MinGW linker warning.

### catch break ambiguity inside labeled blocks

**Problem**: `catch break` inside a `blk: {}` labeled block is ambiguous — the
compiler cannot determine which block to break from.

**Fix**: Use explicit `break :blk @as(?Type, null)` instead of `catch break`
inside labeled blocks.

### Chunked encoding: writer.flush() must precede BodyWriter.flush()

**Problem**: `http.BodyWriter.flush()` alone does not send chunked data.
Data remains buffered in the underlying writer.

**Fix**: Call `writer.flush()` before `BodyWriter.flush()`. The inner writer
flush pushes buffered data to the chunked encoding layer; the outer flush
finalizes the chunk.

```zig
// Correct order:
try response.writer.flush();   // flush inner writer buffer
try response.flush();           // finalize chunked encoding chunk
```

## Known Issues

### KCP / Mesh 传输层（v0.11.x）

1. **Guest 端旧 KCP session 累积**: reconnect 创建新 session（不同 conv），旧
   session 在 Host 端由 `handleMeshGuest` defer 的 `closeSession` 清理。
   Guest 端旧 session 仅在 Mesh.deinit() 时清理，长时间运行多次 reconnect 后
   内存泄漏风险。**Phase 32 已在 Host 端修复（defer 中调用 closeSession）。**

2. **KCP keepalive 死 session 跳过 (Phase 32 修复)**: 已修复 — `periodicTasks`
   对 `dead` session 跳过 `kcp.update()`，消除 "neighbor not found" 噪声日志。

3. **Phantom session from handleKcpData race**: `handleKcpData` 在 mesh.run() 线程
   运行，可能与 tunnelManager 线程的 `closeSessionFor`+`connect()` 竞态：Guest 旧
   KCP 的 keepalive 包在 `closeSessionFor` 之后到达 → `handleKcpData` 创建新 phantom
   session（旧 conv）→ `connect()` 再创建另一个 session（新 conv）。

4. **Reconnect 后 shell 状态丢失**: pty-per-connection 模型导致 reconnect 后
   `cd`、`export` 等 shell 状态全部丢失。这是设计约束，非 bug。

5. **Pty 输出混入 shell 提示符**: Reconnect 后旧 pty 的残留输出（shell 提示符、
   未完成命令的输出片段）可能混入新 session 的输出。

### 线程安全

6. **Io.Event 竞态崩溃（已知，未修复）**: `wake_event.waitTimeout()` 在多 handler
   并发时可能崩溃（`.unset => unreachable`）。upload 并发调用已触发此 bug。
   HostState 的单一 `wake_event` 被所有 handler 共享，需改为 per-op 事件或
   使用 `Io.Semaphore`。

### 未验证用例

7. **Windows VM 未验证**: windowsvm / winx64 在 Phase 30 验证期间离线。

8. **macOS Guest reconnect 未单独测试**: macvm 的基础 exec 正常，但 reconnect 场景未覆盖。

9. **大文件 upload/download**: KCP 隧道无帧大小限制（相比旧 WebSocket 的 64KB），但
   大文件（>10MB）传输未经测试。

10. **自动升级端到端**: connect_counter 变更不影响自动升级逻辑，但
   升级触发、下载、替换、重启全流程未重新验证。

### 遗留（非 mesh 相关）

11. **pty_resize is a stub**: Terminal resize message is parsed but not applied
    (TIOCSWINSZ ioctl not yet called).

12. **killForegroundProcess is a stub**: pty_signal 已移除，Ctrl+C 通过 stdin 透传。killForegroundProcess 函数已在 broadcast.zig 中删除。

13. **std.http.Server HEAD requests return 404**: Zig's `std.http.Server.respond()`
    doesn't automatically handle HEAD by stripping body. Upstream limitation.

### Phase 35 — 管理员权限检查 + 自我提权 (2026-07-25)

14. **Zig 0.16 `std.os.windows.BOOL` 已是 enum**: `Bool(c_int)` 类型，值 `.FALSE` / `.TRUE`，
    不再是原始整数。对比用 `!= .FALSE` 而非 `!= 0`。

15. **Zig 0.16 `std.ArrayList` 跨平台差异**: macOS native 上 `ArrayList(T).init(gpa)` 仍可
    编译（向后兼容别名），但 Windows 交叉编译时 `ArrayList(T)` 解析为无状态 `Aligned(T, null)`，
    无 `.init(gpa)` 方法。必须用 `.empty` 初始化并传 gpa 到每个方法调用。

16. **Zig 0.16 `@ptrCast` 对齐检测**: `[*:0]const u8` (align 1) → `[*:0]const u16` (align 2)
    需要 `@alignCast` 中间步骤。macOS native 常忽略此检测，Windows 交叉编译严格检查。

17. **extern 声明中 `null` 不可强制转换为非可选指针**: Windows API 的可空参数（如
    `ShellExecuteW` 的 `lpDirectory`）必须在 `@extern` 签名中声明为 `?LPCWSTR`。

### Phase 36 — KCP 隧道自动升级 (2026-07-25)

18. **KCP 隧道单线程架构**: Tunnel 对象的 `send()` / `recv()` 不能跨线程共享。
    Host 端 `handleMeshGuest` 在 HTTP worker 线程中运行，所有 tunnel 操作必须在
    同一函数调用链中完成。回调模式（传入 `handleMeshGuest` 到 `tunnel.run()`）
    解决了这个问题。

19. **blob-in-message 的局限性 (Phase 36 临时方案)**: 升级二进制直接嵌入消息，
    因为文件 ~5-20MB 仍在可接受范围。但此设计不适用于 GB 级文件，Phase 37 用
    分块协议替代。

### Phase 37 — 分块文件传输协议 (2026-07-25)

20. **KCP `recv` 消息完整性约束**: KCP `recv(buf)` 要求 buf ≥ 完整消息大小，
    否则返回 `BufferTooSmall`。不能分段接收一条消息。这意味着单条消息不能超过
    buf 大小，大文件传输必须分块。

21. **256KB 固定 buffer 足够**: 所有消息类型中，`file_chunk` 最大（~8KB + 少量
    协议头），`pty_output` 也远小于 256KB。撤销了 peekSize 动态分配，简化了
    接收循环——只需循环 `tunnel.recv(&rbuf)` 不需要每次分配新 buffer。

22. **增量 SHA256 消除全量 hash 的内存开销**: `Sha256.init({})` → `.update(chunk)`
    per chunk → `.final(&hash)` — 只需 32 字节 hash 状态，无需 buffer 整个文件。
    适用于所有三条路径 (upload/download/upgrade)。

23. **`std.Io.Dir.rename` 签名变更**: Zig 0.16 的 `dir.rename(old_path, new_dir,
    new_path, io)` 需要目标目录 + 文件名分开传入，非 `old_path → new_path` 的
    单一路径模式。

24. **分块协议设计选择**: 选择 `upload_cmd → file_chunk × N → file_eof` 而非
    在 `upload_cmd` 中约定 chunk 数量，因为后者需要发送方先遍历文件确认大小，
    增加一次文件系统操作。逐块发送直到 EOF 对发送方更自然。

25. **PtySession 重启导致下载结果丢失**: 下载路径 Host→Guest→Host 中，
    Guest shell 的 PtySession 可能因超时重启，导致 file_eof 到达 Host 时
    cmd_id 对应的 op_states 已清空。从 ping/pty 输出中区分 file_chunk/file_eof，
    两者使用不同的 Guest 端 dispatch 路径确保不依赖 PtySession。

### Phase 38 — KCP 协议完整重写 (2026-07-25)

26. **Zig 版 KCP 与 C 参考存在 10+ 处关键差异**: 下载 C 参考实现 (skywind3000/kcp)
    逐行对比后发现 Zig 版缺少滑动窗口核心机制：
    - `rmt_wnd` 缺失 → 无法限制发送速度以匹配接收方能力
    - 发送窗口用段计数而非 SN 比较 → 无法正确处理序列号回绕
    - 接收窗口无检查 → 重复/过期段可注入
    - 无条件 flush → 无 rate limiting，CPU 空转
    - 窗口探测检查 `rcvWnd()` 而非 `rmt_wnd` → 探测完全失效
    - ACK 在 `snd_buf >= WND_SND` 时停发 → 发送满窗口时死锁
    - xmit 初始值 1 而非 0 → RTO 计算偏离 C 行为
    - 无 shrinkBuf → snd_una 更新不正确
    - fastack 未聚合 → 快速重传计数不准
    - 无输入后拥塞控制 → cwnd 永久不增长

27. **cwnd=0 初始化导致首次发送死锁**: C 参考中 cwnd 初始值为 0，理论上是
    通过首个 ACK 的 snd_una 推进来触发拥塞控制初始化 cwnd。但首个 flush 时
    若 cwnd=0，`snd_nxt < snd_una + 0` 永远为 false → 无数据发送 → 无 ACK
    返回 → 死锁。修复：在 flush() 发送窗口计算中 `if (cwnd < 1) cwnd = 1`。

28. **KCP ACK 存储必须包含 timestamp**: C 参考用 `(sn, ts)` 对存储 ACK 列表，
    flush 时用 ts 填写 segment header。Zig 旧版只存 sn → acklist 改为
    `ArrayList([2]u32)`。

29. **flush() 批量编码提高效率**: C 参考在 flush() 中用 scratch buffer 将多个
    segment 打包到一个 MTU 大小的 UDP 数据报中。Zig 旧版每个 segment 单独调用
    output callback → 改为 `encodeSeg()` + `outputData()` 批量发送。

30. **nodelay 语义澄清**: C 参考中 `nc` 参数值为 0/1（int），`if (nc >= 0) kcp->nocwnd = nc`。
    Zig 版用 bool → `self.nocwnd = nc` 即可，无需 `if (nc)` 守卫。

31. **测试与实际使用的一致性**: KCP 单元测试使用 cross-wired 实例（直接调用
    `input()`），UDP datagram 不经过真实网络。大文件传输验证需要用实际
    exec 命令生成大输出（`dd if=/dev/urandom bs=1024 count=N`）通过 KCP tunnel
    回传来确认重写效果。

## Phase 33: sessions_mutex 死锁修复 (2026-07-25)

### 32. `catch {}` 静默吞掉 `Io.Mutex.lock` 错误导致死锁

`sessions_mutex.lock(io) catch {}` 模式在 8 个调用位置使用。当 `Io.Mutex.lock()`
返回 `error.Canceled`（macOS `__ulock_wait2` 被取消）时，代码在没有持有锁的
情况下继续执行，而 `defer unlock()` 仍然运行 —— 释放未持有的锁，永久破坏 mutex
状态。所有后续 lock 调用全部阻塞，系统死锁。

**修复**：
| 文件 | 位置 | 修复 |
|------|------|------|
| `tunnel.zig` | `send()`, `lock()`, `recv()` | `catch {}` → `try` 传播错误 |
| `tunnel.zig` | `isAlive()`, `peekSize()`, `flush()`, `enableFastMode()`, `waiting()` | 保留 `catch return <默认值>`（defer 前返回，不会 unlock） |
| `mesh.zig` | `periodicTasks()`, `handleKcpData()` | `catch { return; }` 跳过本周期（返回 void） |
| `mesh.zig` | `connect()` | `catch { return error.Canceled; }`（返回 `!*MeshSession`） |
| `mesh.zig` | `closeSession()`, `closeSessionFor()` | 保留 `catch { return; }`（返回 void） |
| `host_http.zig` | exec handler | 手动 lock+sendLocked+flushLocked+unlock → `tun.send()` + `tun.flush()` |
| `host_http.zig` | pty_spawn handler | 同上 |
| `host_http.zig` | upgrade batch send | `tun.lock()` → `tun.lock() catch return` |
| `host.zig` | tunnel manager (upgrading 分支) | `catch {}` → `catch continue` |

### 33. 跨 Io 实例 Mutex 锁不兼容

`broadcast.zig:waitForHostTunnel` 和 `upgrade.zig:connectToHost` 使用 `m.io`
（mesh 线程 Io）调用 `sessions_mutex.lock()`，但这两个函数从主线程调用，
使用的 Io 实例与 mesh 线程不同。在 Zig 0.16.0 中，不同的 Io 实例锁定
同一个 Mutex 可能失败（返回 `error.Canceled`）。

这些位置的 `catch {}` **必须保留**：
- 没有 `defer unlock()`（手动 unlock 在 return 路径中）
- 无锁读取 sessions HashMap 的风险：最多错过一个刚创建的 session，500ms 后重试
- `catch continue` 会导致死循环：锁每次失败，Guest 永远找不到 tunnel

### 34. 多 Host 进程端口冲突

两次从不同位置启动 Host（LaunchDaemon 的 `/opt/utmm/utmm` 和前景的
`zig-out/bin/utmm`）导致两个进程争用 UDP 2121 和 TCP 2121。
LaunchDaemon 自动重启加剧了冲突。macOS `launchctl kickstart -k`
会重启服务但可能导致新旧进程短暂共存。

**教训**：测试前景 Host 前必须 `launchctl bootout` 停掉 LaunchDaemon；
不要假设端口会因为进程退出而自动释放。

### 35. exec 超时是本次会话前的既有问题

~~使用 `git stash` 恢复原始代码（v0.11.1）构建并测试，exec 同样超时。
sessions_mutex 修复是必要的（防止死锁），但不足以解决 exec 超时。
根本原因在于 KCP 隧道数据流问题：pty_spawn 被发送和 ACK，但 pty_output
（shell 输出）从未到达 `handleMeshGuest` 的 `tun.recv()`。~~

**已解决**: 根因是 cross-Io mutex 问题（见 Finding #36）。`waitForHostTunnel` 使用
主线程的 `io` 创建 Tunnel，而 `sessions_mutex` 用 mesh 线程的 `m.io` 创建，
不同 Io 实例导致 `Mutex.lock()` 返回 `error.Canceled` → `tun.recv()` 失败 →
pty_output 永远无法被 Host 读取。

### 36. Zig 0.16.0 Io.Mutex 跨 Io 实例不兼容 (2026-07-25)

**发现**: `std.Io.Mutex.lock(io)` 要求传入的 `io` 与创建 mutex 时使用的 `io` 是
**同一个实例**。不同的 `Io.Threaded` 实例之间 mutex lock 会返回 `error.Canceled`。

**影响位置**: `src/broadcast.zig:1232` — `waitForHostTunnel` 创建 Tunnel 时使用
主线程的 `io`，但 `Tunnel.recv()/send()` 调用的 `sessions_mutex.lock(self.io)`
中的 mutex 是用 mesh 线程的 `m.io` 创建的。

**症状**: `tun.recv()` 立即返回 `error.Canceled`（不等待数据），导致
`handleMeshGuest` recv loop 退出，pty_spawn 被写入但 pty_output 无法被读取。

**为什么 `catch {}` 时期未暴露**:
- 旧代码: `lock() catch {}` 静默吞掉错误 → `recv()` 在无锁状态下调用 `kcp_inst.recv()`
  → 数据竞争但偶尔能读到数据（行为不确定）
- 新代码: `try lock()` 传播错误 → `recv()` 立即失败，确定性出错
- Phase 38 (KCP 重写) 将 `catch {}` 改为 `try`，使问题从静默变为 fatal

**修复**: `waitForHostTunnel` 中 `Tunnel.init(allocator, m.io, sess)` —
使用 mesh 的 Io（`m.io`），与 `sessions_mutex` 创建时一致。

**为什么 Host 侧不受影响**: Host 在 `host.zig:728` 创建 Tunnel 时已经使用 `m.io`。

**教训**: Zig 0.16.0 的 `Io.Mutex` 与 Go 的 `sync.Mutex` 不同 — Go 的 mutex
可在任意 goroutine 中 lock/unlock；Zig 的 `Io.Mutex` 绑定到特定 `Io` 实例。
跨线程共享 mutex 时必须确保所有访问者使用相同的 `Io` 实例。

---

### Finding 37: Windows ARM64 service Io 的 receiveTimeout 静默失败 — KCP 数据丢失 (v0.11.9, 2026-07-26)

**症状**: `runWindows()` 使用 `receiveTimeout(self.io, ...)`（与 POSIX 同路径）时，
Host 和 Guest 之间有 KCP keepalive 流量（UDP 收发包），但 `handleMeshGuest` 持续显示
"recv empty" — KCP 应用层数据永远不会到达。

**根因**: Zig 0.16.0 在 Windows ARM64 上，service Io（`init.io`）的 `receiveTimeout`
不会返回 `error.ConcurrencyUnavailable`（如果返回则该 bug 会被回退路径捕获）。
相反它 succeeds，但 KCP 层数据被静默丢弃。UDP 包在物理层到达 socket，但应用层
无法通过 `kcp_inst.input()` 处理。

**对比测试验证**:
| runWindows 路径 | Guest Io | 结果 |
|----------------|----------|------|
| receiveTimeout | self.io (service Io) | ❌ exec 挂起 |
| 阻塞 receive | global_single_threaded.io() | ✅ exec 正常 |

**为什么 v0.11.8 不受影响**: v0.11.8 始终使用 `global_single_threaded.io()` + 阻塞
receive + 定时器线程，从未尝试 receiveTimeout。

**修复**: 简化 `runWindows()` — 移除 receiveTimeout 尝试，始终使用
`global_single_threaded.io()` + 阻塞 receive + 定时器线程（原始 Win32 `Sleep()`）。

**教训**:
1. Windows ARM64 Zig 0.16.0 Io 行为可能与 POSIX 不同 — 不能假设一致性
2. 静默失败（无错误返回值但数据丢失）比显式错误更难排查
3. 在 Windows 上做对比测试非常重要 — 同一套代码的不同代码路径可能行为迥异

**关联**: [[cross-io-mutex]], [[pty-session-model]], Windows Mesh Patterns (CLAUDE.md)

---

### Finding 38: Host 陈旧 KCP session 状态导致新 Guest 连接异常 (v0.11.9, 2026-07-26)

**症状**: 部署新 Guest 二进制后（代码已验证在其他环境正常），exec 仍然挂起。
重启 Host 后立即恢复正常。

**根因**: Host 端陈旧 KCP session 状态未完全清理。Guest 重启后创建新 KCP session（新
conv ID），但 Host 端旧 session 的 handleMeshGuest 线程尚未退出（仍在轮询已死的
tunnel），导致新 session 的 pty_output 被丢弃或路由到错误的 handler。

**修复**: 当前通过重启 Host 规避。未来应增强 session 生命周期管理：
- `failAllPendingOps` 后立即 `closeSession`（不等 handleMeshGuest defer）
- 新 session 建立时强制关闭同 hostname 的旧 session

**教训**: 测试 KCP 隧道问题时，必须先重启 Host 清除陈旧状态，否则测试结果不可靠。

---

### Finding 39: DHCP 启动竞态 — Guest 启动时 IP 可能尚未分配 (v0.11.9, 2026-07-26)

**症状**: Guest 启动后 LSA 广播 IP 为 `0.0.0.0`，Host 无法路由 exec 到该 Guest。
重启 Guest 后恢复正常。

**诊断**: Guest `getSystemInfo()` 仅在启动时调用一次。在 UTM 桥接网络等虚拟化环境
中，DHCP 需要 1-3 秒分配 IP，而 `utmm --svc` 可能在此之前启动。

**C 代码测试**: 简单的 `getifaddrs()` C 程序在 SSH 中返回正确 IP 不等于 Guest
服务启动时返回正确 IP。Guest 服务在引导序列中更早启动。

**根因**: 三个平台的竞态条件相同：
- **macOS/Linux**: `getifaddrs()` 遍历接口时不返回有效的非环回 IPv4
- **Windows**: `route print 0.0.0.0` 的默认网关 0.0.0.0 或 PowerShell 返回空

**修复**: `src/broadcast.zig` — `getSystemInfo()` 中添加重试循环（最多 5 次 × 1s），
[commit `fba0a9f`] 仅 Unix，[commit `3fa0b5e`] 扩展至 Windows 全平台。

**教训**:
1. `getSystemInfo()` 是冷路径 — 允许在启动时等待是最简单的修复
2. 虚拟化环境（UTM）的 DHCP 延迟可能高于预期 — 2s 延迟有时都不够，需 5 次重试
3. 三种平台共享相同问题 — 统一修复优于平台特定修复

**关联**: [[zig-016-api-notes]] (std.time.sleep → std.Io.sleep), [[pty-session-model]]

---

### Finding 40: Zig 0.16.0 sleep API 迁移 (v0.11.9, 2026-07-26)

**变更**:
- `std.time.sleep(ns)` → **已移除** → `std.Io.sleep(io, Duration.fromMilliseconds(n), .awake)`
- `std.Thread.sleep(ns)` → **已移除** → 同上
- `std.Io.Duration.fromMillis()` → **不存在** → `fromMilliseconds()`
- `std.Io.Clock.monotonic` → **不存在** → `.awake`

**示例**:
```zig
// 0.15.x
std.time.sleep(1_000_000_000);

// 0.16.0
std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
```

**注意**: `std.Io.sleep` 需要 `io` 参数。在 Mesh 上下文中使用 `m.io` 或
`global_single_threaded.io()`，具体取决于上下文。在重试循环中使用顶层 `io` 参数。

**关联**: [[zig-016-api-notes]]

---

### Finding 41: Windows OpenSSH SCP 文件锁定问题 (v0.11.9, 2026-07-26)

**症状**: `scp` 部署新二进制到 Windows Guest 时失败 — 文件被 `C:\opt\utmm\utmm.exe`
锁定（Windows 保护运行中的 .exe 不被覆盖）。

**修复**: 部署脚本使用临时文件名 + 进程终止 + 临时文件覆盖：
```batch
# 1. 终止运行中的进程
taskkill /F /IM utmm.exe 2>nul
# 2. scp 到临时文件名
scp utmm-x86_64-windows.exe Administrator@192.168.3.x:C:\opt\utmm\utmm.next.exe
# 3. 通过 PowerShell 替换
powershell -Command "Move-Item -Force C:\opt\utmm\utmm.next.exe C:\opt\utmm\utmm.exe"
```

**关键**: `sc stop` 可能显示 `STOP_PENDING (NOT_STOPPABLE)` — Windows 服务终止
超时 30s 且无法强制。`taskkill /F` 或 `Stop-Process -Force` 绕过此限制。

**教训**: Windows .exe 替换与 POSIX `rename()` 语义不同。始终先终止进程再用
临时文件 + Move-Item。

---

## Phase 46: KCP 可靠性全面审计 (2026-07-26)

### Finding 42: `flush()` buffer 分配失败静默丢弃数据

**严重级别**: Critical

`flush()` line 644-646 中 buffer 分配失败（`catch null`）后，line 647 `orelse return`
静默返回。此时所有待发送 ACK、数据和窗口探测全部丢失，但 `acklist` 尚未清空（line 679
在 ACK 处理分支内），所以下次 flush 会重试。然而，`snd_queue` → `snd_buf` 的移动在
buffer 检查之后（line 737-754），不受影响。

**结论**: 当前实现中，buffer 分配失败时 acklist 未被清空（在 ACK 处理分支内清空），
所以数据不会丢失。但 `setMtu()` 分配失败可能导致 buffer 为 null。如果用户从未调用
`setMtu()`，则 buffer 在首次 flush 时延迟分配，失败后每次都尝试分配。

**加固方案**: 在 buffer 分配失败时跳过 ACK 编码和数据发送，但仍处理窗口探测（使用
`outputSegment` 回退）和 snd_queue→snd_buf 移动。acklist 不清空，下次 flush 重试。

### Finding 43: `snd_buf.append` OOM 导致 segment 丢失

**严重级别**: Critical

`flush()` line 753: `self.snd_buf.append(self.allocator, newseg) catch break;` —
segment 已从 `snd_queue.orderedRemove(0)` 取出，如果 `append` 到 `snd_buf` 失败，
segment 及其数据（堆分配）泄漏且永久丢失。调用者无感知。

**加固方案**: OOM 时将 segment 放回 snd_queue（`insert(0)`），然后 break。

### Finding 44: `send()` count 计算 64-bit 截断

**严重级别**: High

`send()` line 522: `@intCast((remaining.len + self.mss - 1) / self.mss)` — 在 64-bit
平台上，`remaining.len` 为 usize (64-bit)，除法结果可能超过 u32::MAX（约 4B 段）。
`@intCast` 在溢出时触发 panic。

**加固方案**: 在除法前检查 `remaining.len / self.mss > IKCP_WND_RCV`，提早返回错误。

### Finding 45: `flush()` 超时路径 cwnd 下溢

**严重级别**: High

`flush()` line 846: `self.ssthresh = prior_cwnd / 2;` 当 `prior_cwnd == 1` 时结果为 0，
随后 line 847-849 夹紧 `ssthresh = IKCP_THRESH_MIN (2)`，line 850 `cwnd = 1`。
最终 cwnd=1、ssthresh=2，状态正确。但 line 846 本身产生了值为 0 的中间状态。

**加固方案**: 使用 `@max(prior_cwnd / 2, 1)` 避免中间零值，防御后续代码变更引入的 bug。

### Finding 46: `check()` xmit==0 segment 的 resendts 处理

**严重级别**: Medium

`check()` line 616: `if (seg.xmit == 0) continue;` — 跳过尚未首次发送的 segment。
但新 segment 在 `flush()` step 3 中设置了 `resendts = current`，且 xmit 在 step 4
首次发送时才从 0 变为 1。如果 flush 在 step 3 之后、step 4 之前因 buffer 不足而
跳过发送，则 segment 在 snd_buf 中 xmit=0 但 resendts=current。下次 `check()` 因
`xmit == 0` 跳过，不会因 `resendts` 到期而返回 immediate。这是正确的——依赖
ts_flush timer 来驱动下次 flush。

### Finding 47: `rcv_queue` 无限累积风险

**严重级别**: Medium

消息模式下，如果 `rcv_queue` 首个 segment 的 `frg != 0`（多片段消息的首段），且后续
片段永不抵达（网络丢包），则 `recv()` 永远返回 0，`peekSize()` 永远返回 -1。
`rcv_queue` 无限增长，无超时淘汰机制。

**加固方案**: 为 rcv_queue 中不完整消息添加超时淘汰（例如 30 秒）。或至少在诊断接口
暴露此状态，让上层通过重建 KCP session 恢复。

### Finding 48: `moveRcvBuf` reconnect 检测误判风险

**严重级别**: Medium

`moveRcvBuf()` line 981: `if (sn_lt(seg.sn, self.rcv_nxt) and self.rcv_nxt > 10)`
— reconnect 检测：远程重启后 SN 回绕，旧 rcv_buf 中的高 SN 段在新 rcv_nxt 之后。
但条件 `rcv_nxt > 10` 是启发式阈值——如果 rcv_nxt ≤ 10（连接刚开始），即使 seg.sn
< rcv_nxt 也跳过检测。这意味着在连接早期收到旧 session 的残留段时，可能被错误当作
有效段插入 rcv_buf。

**当前影响**: 低。因为 nonce 机制确保新旧 session 的 conv 不同，旧 session 的段
不会到达新 KCP 实例。但防御性编程应记录此假设。

### Finding 49: `updateRtt` 整数溢出

**严重级别**: Low

`updateRtt()` line 1113: `3 * self.rx_rttval + delta` — rttval 最大约 60000
（来自 IKCP_RTO_MAX），3*60000+60000 = 240000，远小于 i32::MAX。但若未来修改
常量使其增大，存在溢出风险。line 1116: `7 * self.rx_srtt + rtt` 同理。

**加固方案**: 使用饱和运算或 `@mulWithOverflow`，或将中间变量提升为 i64。

### Finding 50: `flush()` 死链检测双路径不一致

**严重级别**: Low

Line 822-824: `if (segment.xmit >= self.dead_link) { self.state = 0xFFFFFFFF; }`
— 设置 `state` 字段。但 `isDead()` 检查 `seg.xmit >= self.dead_link`，不检查
`state`。这意味着两个死链检测路径可能不同步：
- `state = 0xFFFFFFFF` 被设置后，如果 segment 被 ACK 移除，`state` 不清零
- `isDead()` 依赖 snd_buf 中 segment 的 xmit，如果所有 segment 被 ACK，则返回 false

**加固方案**: 统一使用 `isDead()` 或 `state`，不混用。

### Finding 51: `recv()` 零长度缓冲区返回歧义

**严重级别**: Low

`recv(buf)` 当 `buf.len == 0` 且队列有数据时，返回 `error.BufferTooSmall`。
当队列无数据时，返回 0。调用者可能用 `recv(&empty_buf)` 探测是否有数据，
返回 0 表示无数据（正确），返回 `BufferTooSmall` 表示有数据（也正确）。
无歧义——调用者区分了两种情况。但若调用者不检查错误，可能将 `BufferTooSmall`
视为无数据。

### Finding 52: `setWndSize` 是空操作

**严重级别**: Low

Line 302: `pub fn setWndSize(_: *Kcp, _: u32, _: u32) void {}` — 公开 API 但无实现。
C 参考中对应函数有实现：重置 snd_wnd/rcv_wnd 常量。

**加固方案**: 实现该函数或添加 `@compileError` 提示未实现。

### Finding 53: Segment data null 安全

**严重级别**: Low

`flush()` line 815-819: 检查 `segment.len > 0` 后再检查 `segment.data`。
如果 `segment.len > 0` 但 `data == null`（状态不一致），跳过 memcpy 是安全的
（不会崩溃），但会发送带有错误长度的段。应在创建 segment 时断言 `len > 0 → data != null`。

### Finding 54: `send()` stream 模式部分发送状态不一致

**严重级别**: Info

`send()` line 496-517: stream 模式下先修改 snd_queue 最后一个 segment（扩展其 data），
然后检查剩余数据是否超过 segment 数量限制。如果限制触发 `return error.MessageTooLarge`，
已扩展的 segment 保持被修改状态。这是 C 参考的预期行为（stream 模式允许部分发送），
但调用者无法得知实际发送了多少字节。

## Phase 47: KCP 可靠性第二轮深度审计 (2026-07-26)

在 Phase 46 基础上进行了更深入的边界条件审查，重点关注错误路径内存安全、
协议状态机一致性、整数溢出全面扫描、KCP-tunnel-mesh 交互边界、模糊测试。

### Finding 55: `input()` — seg.data 泄漏在 ackPush/insertRcvBuf OOM 路径

**严重级别**: Critical

`input()` 中 PUSH segment 的数据在 line 357-359 通过 `allocator.alloc` 堆分配后，
若后续 `ackPush` (line 401) 或 `parseData` → `insertRcvBuf` (line 1037/1039) OOM，
错误向上传播，`seg`（栈变量）出作用域，`seg.data` 永久泄漏。

**根因**: Segment 的所有权模型不清晰——堆分配在 `input()` 中完成，但释放依赖于
深层函数（parseData/insertRcvBuf）的成功或显式 drop 路径。错误路径未覆盖。

**加固方案**: PUSH 处理器内部使用 `errdefer` 块保护。`ackPush` 或 `parseData`
失败时 `errdefer` 自动释放 `seg.data`。`parseData` 成功后（数据所有权转移至
`rcv_buf`），将 `seg.data = null` 防止 double-free。

### Finding 56: `send()` 非 stream 模式 OOM 部分队列残留

**严重级别**: Critical

`send()` 在非 stream 模式下将多片段消息逐个加入 `snd_queue`。若某段分配或
`append` 失败，已入队的片段留在队列中，其 `frg` 字段指示属于一个未完成的大消息。
接收端 `peekSize()` 检查 `rcv_queue.items.len < frg + 1` → 返回 -1，`recv()` 返回 0。
**rcv_queue 永久阻塞**——新消息的片段排在后面，无法被消费。

**根因**: 发送端在部分失败后没有回滚机制。已入队片段无论后续是否成功都留在队列中。

**加固方案**:
1. 循环前保存 `initial_count`，用 `errdefer` 在非 stream 模式或 stream 无部分发送
   时回滚所有新增 segment（pop + free data）。
2. `snd_queue.append` 失败时用 `catch |err|` 显式释放当前 `owned` 数据，防止
   当前 segment 数据泄漏。

### Finding 57: `input()` — 协议状态部分修改后 OOM 回滚

**严重级别**: High (设计限制)

`input()` 对每个 segment 先调用 `parseUna` + `shrinkBuf`（可修改 `snd_buf`
并释放已 ACK 的 segment 数据），再进入 command 分发。如果后续 PUSH 的
`ackPush` 或 `parseData` OOM，已从 `snd_buf` 移除的 segment 永久丢失——
发送端认为已 ACK，接收端未能成功处理数据。

**分析**: 这是 KCP 协议固有行为——UNA 是 piggyback ACK，应尽早处理。
目前 mesh 层（mesh.zig:782-784）catch 错误后仅记录日志并继续使用 session，
状态可能不一致。但 keepalive 机制（15s 超时）最终会杀死异常 session 并重建。

**加固方案**: 未修改协议逻辑，但增强了 mesh 层的错误处理意识。
`input()` 返回错误后 session 继续运行，状态不一致由 keepalive 兜底。

### Finding 58: `parseData` → `insertRcvBuf` OOM 时 seg.data 未释放

**严重级别**: High

`parseData()` 在窗口外/重复检查后调用 `insertRcvBuf(seg)`（按值传递）。
若 `insertRcvBuf` 的 `append`/`insert` OOM，seg.data 未释放，且错误传播至
`input()` → mesh 层。Finding 55 的修复通过在调用侧添加 errdefer 覆盖了此路径。

### Finding 59: 时间戳算术溢出 — ~49 天 uptime 时 debug panic

**严重级别**: Medium

`flush()` / `update()` / `check()` 中共 8 处时间戳加法使用普通 `+` 运算符：
- `segment.resendts = current + segment.rto + rtomin`（首次发送）
- `segment.resendts = current + segment.rto`（超时重传、快速重传）
- `self.ts_probe = current + self.probe_wait`（窗口探测）
- `self.ts_flush += self.interval` / `= self.current + self.interval`（更新计时）
- `return current_ms + minimal`（检查计时）

当 `current` 接近 `u32::MAX`（约 49 天运行时间）且加数为正时，结果溢出 u32。
Debug 模式 panic，Release 模式 wrapping（恰好正确）。

**根因**: 所有时间戳比较使用 `-%`（wrapping sub），但加法使用普通 `+`，不一致。

**加固方案**: 全部 8 处改为 `+%`（wrapping add），与现有的 `-%` 一致。
长会话可安全跨越 u32 回绕点。

### Finding 60: `flush()` buffer OOM 时数据段静默延迟

**严重级别**: Low (已文档化)

`flush()` line 885-893: buffer 为 null 时数据段延迟到下次 flush，无警告。
若 buffer 分配永不成功（内存极度不足），数据永远不发，上层无感知。

**分析**: `check()` 返回值仍正确（基于 ts_flush），mesh 循环继续调用 update。
死链检测（dead_link）最终触发。不可恢复但不会静默挂起——dead_link 杀死连接。

### Finding 61: `send()` stream 模式 `last.data == null` 但 `last.len > 0`

**严重级别**: Info

`send()` stream 模式 line 522-529: 检查 `last.len < self.mss` 后计算 `capacity`，
假设 `last.data != null`（通过 `if (last.data) |ld|` 守卫 memcpy）。
若 `last.data == null` 且 `last.len > 0`（状态不一致——正常操作下不应发生），
合并后的 segment 前半部分是未初始化内存。

**分析**: 当前代码中所有创建 segment 的路径都确保 `len > 0 → data != null`。
此状态仅在内存损坏或未来代码变更未维护此不变式时才可能出现。

## Phase 48: 安装/升级自复制模型重构 Discoveries (2026-07-26)

### Finding 62: Zig 0.16.0 `std.os.windows` 移除 SCM 类型

**严重级别**: Critical (Windows 构建阻断)

Zig 0.16.0 从 `std.os.windows` 移除了 Windows SCM（Service Control Manager）相关类型：
- `SERVICE_TABLE_ENTRYW` struct
- `SetServiceStatus` 函数
- `RegisterServiceCtrlHandlerExW` 函数
- `StartServiceCtrlDispatcherW` 函数

这些类型和函数在旧版 Zig 中位于 `std.os.windows`，但 0.16.0 已清除。必须手动声明
`extern "advapi32"` 函数和自定义 struct。

**修复**: 在 `src/svc.zig` 中手动声明：
```zig
const SERVICE_TABLE_ENTRYW = extern struct {
    lpServiceName: ?[*:0]const u16,
    lpServiceProc: ?SvcMainFn,
};
extern "advapi32" fn StartServiceCtrlDispatcherW(...) callconv(.winapi) u32;
extern "advapi32" fn RegisterServiceCtrlHandlerExW(...) callconv(.winapi) ?SERVICE_STATUS_HANDLE;
extern "advapi32" fn SetServiceStatus(...) callconv(.winapi) u32;
```

### Finding 63: `GetLastError()` 返回 enum 而非整数

**严重级别**: High (Windows 构建阻断)

Zig 0.16.0 中 `std.os.windows.GetLastError()` 返回 `Win32Error` enum，不再是原始整数。
比较 `if (gle != 0)` 和格式化 `{gle}` 在 enum 上失败。

**修复**: 使用 `@intFromEnum(gle)` 转换为整数后再比较和格式化。
`if (@intFromEnum(gle) != 0)` 和 `{@intFromEnum(gle)}`。

### Finding 64: `std.c.strerror` 在 Zig 0.16.0 已移除

**严重级别**: High (POSIX 构建阻断)

Zig 0.16.0 从 `std.c` 移除了 `strerror` 函数。必须通过 `@extern` 直接调用 libc：
```zig
const strerror = @extern(*const fn (c_int) callconv(.c) [*:0]const u8, .{ .name = "strerror" });
```
注意 calling convention 为 `callconv(.c)`（小写c），Zig 0.16.0 将 `.C` 改为 `.c`。

### Finding 65: `rename()` 签名变更 — 4 参数

**严重级别**: Medium

Zig 0.16.0 `Dir.rename()` 签名从 `(io, old_path, new_path)` 变为
`(old_path, new_dir, new_path, io)`。目标目录和目标文件名需要分开传入。
跨文件系统 rename 返回 `error.RenameAcrossMountPoints`，需用 copy+delete 回退。

### Finding 66: `++` 字符串拼接需 comptime-known

**严重级别**: Medium

Zig 0.16.0 中 `++` 运算符左操作数必须 comptime-known。运行时拼接需改为多个
`appendSlice` 调用：
```zig
// ❌ 0.15.x: buf.appendSlice(prefix ++ name ++ suffix)
// ✅ 0.16.0:
try buf.appendSlice(prefix);
try buf.appendSlice(name);
try buf.appendSlice(suffix);
```

### Finding 67: 自复制跨文件系统 rename 回退

**严重级别**: Low (设计决策)

`selfCopy()` 使用 tmp + rename 实现原子替换。当 tmp 文件和目标路径在不同文件系统时
（`/tmp` → `/opt/utmm/`），rename 返回 `error.RenameAcrossMountPoints`。回退方案是
copy+delete（非原子但可接受，因为此时服务已停止，无并发访问）。

