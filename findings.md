# Findings: v0.8.1+

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

1. **Kick 后 reconnect 延迟 ~3s**: Guest 端 `stale_count > 600`（600 × 5ms = 3s）
   才检测到旧 tunnel 失活。在此期间 exec 命令在 KCP send buffer 中排队，reconnect
   完成后才会被处理。可优化为更快的失活检测（更低的阈值或显式通知机制）。

2. **旧 KCP session 在 Guest 端累积**: 每次 kick 创建新 session（不同 conv），但旧
   session 仅在 Mesh.deinit() 时清理。长时间运行多次 kick 后内存泄漏风险。Host 端
   `closeSessionFor` 已正确清理旧 session，但 Guest 端缺乏对等清理逻辑。

3. **Phantom session from handleKcpData race**: `handleKcpData` 在 mesh.run() 线程
   运行，可能与 tunnelManager 线程的 `closeSessionFor`+`connect()` 竞态：Guest 旧
   KCP 的 keepalive 包在 `closeSessionFor` 之后到达 → `handleKcpData` 创建新 phantom
   session（旧 conv）→ `connect()` 再创建另一个 session（新 conv）。两者共存但
   phantom session 仅浪费资源，不导致功能错误。

4. **Kick 后 shell 状态丢失**: Kick 强制 Guest 重 spawn pty，`cd`、`export` 等
   shell 状态全部丢失。这是 pty-per-connection 模型的设计约束，需在文档中说明。

5. **Pty 输出混入 shell 提示符**: Kick+reconnect 后，旧 pty 的残留输出（shell 提示符、
   未完成命令的输出片段）可能混入新 session 的输出。`scanForMarker` 使用
   `lastIndexOf` 缓解了 macOS 命令回显问题，但跨 session 的输出污染未解决。

### 线程安全

6. **Io.Event 竞态崩溃（已知，未修复）**: `wake_event.waitTimeout()` 在多 handler
   并发时可能崩溃（`.unset => unreachable`）。upload 并发调用已触发此 bug。
   HostState 的单一 `wake_event` 被所有 handler 共享，需改为 per-op 事件或
   使用 `Io.Semaphore`。

### 未验证用例

7. **Windows VM 未验证**: windowsvm / winx64 在 Phase 30 验证期间离线。Kick+reconnect
   修复在 Windows 上的行为未确认。

8. **macOS Guest kick 未单独测试**: 仅 linuxvm 进行了 kick+reconnect 验证。macvm 的
   基础 exec 正常，但 kick 场景未覆盖。

9. **大文件 upload/download**: KCP 隧道无帧大小限制（相比旧 WebSocket 的 64KB），但
   大文件（>10MB）传输未经测试。

10. **自动升级端到端**: Phase 30 的 connect_counter 变更不影响自动升级逻辑，但
    升级触发、下载、替换、重启全流程未重新验证。

### 遗留（非 mesh 相关）

11. **pty_resize is a stub**: Terminal resize message is parsed but not applied
    (TIOCSWINSZ ioctl not yet called).

12. **killForegroundProcess is a stub**: pty_signal supports per-signal values but
    currently only sends SIGKILL/TerminateProcess to the shell child.

13. **std.http.Server HEAD requests return 404**: Zig's `std.http.Server.respond()`
    doesn't automatically handle HEAD by stripping body. Upstream limitation.
