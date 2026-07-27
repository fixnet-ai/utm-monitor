# Findings: v0.11.14

仅保留当前仍相关的重要发现。历史发现（WebSocket 时代、utmm-old、agent.zig 等）已随架构演进过时，不再收录。

---

## Phase 50: 加固优化审计发现

### Finding 68: Zig 0.16.0 `std.c.getErrno` 不存在

POSIX write() syscall 返回负数时，无法通过 `std.c.getErrno(0)` 获取 errno。Zig 0.16.0 移除了此函数。替代方案：不做 EINTR 精细判断，将负数返回值统一视为 WriteFailed，交由上层重试。

### Finding 69: Zig 0.16.0 `catch { } else |val| { }` 非法语法

`expr catch |err| { block } else |val| { block }` 在 Zig 中不存在（类 Rust 语法）。正确模式：`if (expr) |val| { } else |err| { }` — Zig 的 if 直接支持 error union 解构。

### Finding 70: Windows `BOOL` 类型跨平台不兼容

`WriteFile()` 返回 `std.os.windows.BOOL`（即 `c_int`），与 `comptime_int`（如 `0`）直接比较在 macOS 编译通过但在 Windows 交叉编译报错。必须用 `@intFromEnum()` 包裹 BOOL 返回值后再比较。已有的 `ptyRead` 函数使用了正确模式。

### Finding 71: Zig 0.16.0 `Io.Clock` 无 `.monotonic`

`std.Io.Timestamp.now(io, .monotonic)` 在 0.16.0 中报错，正确成员是 `.awake`。旧代码中的 `cleanupStaleOps` 有此问题（历史遗留，该函数从未被调用因此未被发现）。

### Finding 72: `*[]const u8` vs `[]const u8` 解引用陷阱

`active_cmd_id.*` 在函数参数（`*[]const u8`）中合法，但在同名的局部变量（`[]const u8`）中报错"index syntax required for slice type"。名称遮蔽导致混淆，编写 P2（pty_exec_done）时踩坑。

### Finding 73: 自死锁避免模式

`handleLsa` 和 `expireStale` 调用 `rebuildRoutes`，后者内部锁 `neighbors_mutex`+`lsas_mutex`+`routes_mutex`。若调用者持锁进入即自死锁。解决方案：
- `rebuildRoutes` 内部自锁（调用者不持锁）
- 调用者 block-scoped 先释放→再调用
- 锁序固定 `sessions→neighbors→lsas→routes`

### Finding 74: `errdefer` 与 `@panic`（fail.err）不兼容

`forceInstall` 使用 `fail.err()`（内部 `@panic`）实现 fail-fast，`errdefer` 在 panic 时不会执行。失败回滚必须在 `fail.err()` 前手动进行（删除已复制文件、卸载已安装服务）。

### Finding 75: `runCmdQuiet` debug 级 vs warn 级

svc.zig ~24 处 `_ = runCmd(...)` 静默吞错，但大多数是预期失败（停止未运行的服务、清理不存在的旧配置）。若全部改为 `std.log.warn` 会造成严重噪音。正确做法：debug 级别日志，兼顾可调试性和生产环境清洁。

---

## Zig 0.16.0 API 适配（Phase 48）

### Finding 62: `std.os.windows` 移除 SCM 类型

Zig 0.16.0 从 `std.os.windows` 移除了 `SERVICE_TABLE_ENTRYW`、`SetServiceStatus`、`RegisterServiceCtrlHandlerExW`、`StartServiceCtrlDispatcherW`。必须在 `src/svc.zig` 中手动声明 extern 类型和函数。

### Finding 63: `GetLastError()` 返回 enum

`std.os.windows.GetLastError()` 返回 `Win32Error` enum，非原始整数。需用 `@intFromEnum(gle)` 转换后比较和格式化。

### Finding 64: `std.c.strerror` 已移除

需通过 `@extern` 直接调用 libc:
```zig
const strerror = @extern(*const fn (c_int) callconv(.c) [*:0]const u8, .{ .name = "strerror" });
```

### Finding 65: `rename()` 签名变为 4 参数

`Dir.rename(old_path, new_dir, new_path, io)` — 目标目录和文件名分开传入。跨文件系统返回 `error.RenameAcrossMountPoints`。

### Finding 66: `++` 需 comptime-known

运行时字符串拼接需改为多个 `appendSlice` 调用。

### Finding 67: 自复制跨文件系统 rename 回退

`selfCopy()` 的 tmp→canonical rename 可能遇到 EXDEV（`/tmp` 和 `/opt/utmm` 不同文件系统）。回退方案是 copy+delete（非原子但可接受，服务已停止）。

---

## KCP 协议相关（Phase 46-47）

### Finding 55: `input()` seg.data 泄漏（Critical）

`ackPush`/`insertRcvBuf` OOM 时，`input()` 中已分配的 seg.data 泄漏。修复：errdefer 块 + seg.data = null 防 double-free。

### Finding 56: `send()` 非 stream OOM 部分片段残留（Critical）

非 stream 模式 send 在 OOM 后，部分片段已加入 snd_queue，导致接收端永久阻塞等完整消息。修复：errdefer 回滚 + catch 释放当前段数据。

### Finding 57: `input()` parseUna 不可回滚（High）

parseUna 先修改 snd_una，后续 OOM 无法恢复。设计限制文档化；keepalive 兜底。

### Finding 59: 时间戳算术溢出（Medium）

8 处 `+` 改为 `+%`（wrapping add），防止长时间运行后时间戳回绕导致逻辑错误。

### 模糊测试验证（Phase 47）

随机丢包/乱序/重复/损坏测试均通过，KCP 在极端网络条件下可恢复。

---

## Windows 相关

### Windows cmd.exe UTF-8 三层保障

`CreatePipe` + `CreateProcessW("cmd.exe /k")` 需三层 UTF-8 强制：SetConsoleCP(65001) + chcp 65001 + LANG 环境变量。

### Windows KCP 需阻塞接收 + 定时器线程

ARM64 Windows 上 `receiveTimeout` 路径静默丢失 KCP 数据。阻塞 receive + 独立 Win32 Sleep 定时器线程是唯一可靠方案。

### Windows .exe 文件锁定

服务运行时 .exe 被锁定，SCP 无法直接覆盖。部署流程：SCP 到临时文件 → 停服 → Move-Item -Force 覆盖。

---

## 设计决策记录

### ADR-1: 持久 pty per KCP 隧道连接

spawn 持久 shell（POSIX `posix_openpt` / Windows `CreatePipe`），命令间共享环境。`cd`/`export` 跨 exec 持久化。

### ADR-2: MDELIM 退出码标记

`; echo MDELIM:$?\n` 嵌入 pty 输出。Host 侧 `lastIndexOf` 处理命令回显（macOS/BSD pty master 不支持 ECHO disable）。`pty_exec_done` 消息提供显式退出码通道作为冗余。

### ADR-3: 自复制安装模型（Phase 48）

取消 utmm-old、agent.zig、软连接。固定路径 `/opt/utmm/utmm`（POSIX）/ `C:\opt\utmm\utmm.exe`（Windows）。安装 = 无条件强制覆盖。升级 = scp 新二进制 + `--install`。

### ADR-4: 文档合并（Phase 49）

DESIGN.md + release-skill/SKILL.md 合并到 CLAUDE.md，`utm-vm` 改名为 `utmm`。消除碎片化，单文件（CLAUDE.md）即可覆盖架构设计到发布流程。

---

## Phase 50 部署测试发现

### Finding 76: `Io.Event.reset()` 在信号线程调用导致 unreachable panic（Critical）

`wake_event.reset()` 在 `handleMeshGuest`（信号线程）中紧跟 `wake_event.set()` 之后调用，但等待线程（HTTP handler）可能尚未从 `waitTimeout()` 返回。Zig 0.16.0 `std.Io.Event` 规定 `reset()` 只能由等待线程调用。

堆栈：
```
panic: reached unreachable code
std/Io.zig:1842:23: waitTimeout: .unset => unreachable
// `reset` called before pending `wait` returned
httpd.zig:1265 → wake_event.waitTimeout()
httpd.zig:699 → dispatch → handleExec
```

**修复**：从 `handleMeshGuest` 的 4 处 `set()+reset()` 中移除 `reset()`。`reset()` 仅在等待线程（`handleExec`/`handleDownload`/`mcpHandleVmExec`[已移除，Phase 53]）的 `waitTimeout()` 返回后调用。

### Finding 77: `cleanupOpState` 自死锁（Critical）

`handleExec` 在调用 `cleanupOpState()` 前持有 `state.mutex`，但 `cleanupOpState` 内部也锁 `state.mutex`。`std.Io.Mutex` 不可重入（futex-based），导致 HTTP handler 线程自死锁，该线程永久持有 `state.mutex`，阻塞后续所有 exec 和 tunnelManager 的 `upsertGuest`。

死锁链：
1. HTTP handler：持有 `state.mutex` → `cleanupOpState` 尝试再次锁 → 自死锁
2. 后续 HTTP handler：等待 `state.mutex`（被 1 持有）
3. tunnelManager：持有 `lsas_mutex` → 等待 `state.mutex`（被 1 持有）
4. mesh.run()：等待 `lsas_mutex`（被 3 持有）

**修复**：移除 `handleExec` 中 `cleanupOpState` 前的外层锁，`cleanupOpState` 内部有自锁。

### Finding 78: 交叉编译覆盖原生二进制

`zig build -Dtarget=aarch64-linux-musl` 将输出写入 `zig-out/bin/utmm`（覆盖原生构建）。部署时须注意：先运行原生构建并备份，再交叉编译；或使用 `zig-out/bin/utmm-{target}` 文件名。

**规避方案**：交叉编译后立即运行 `zig build`（无 target）恢复原生二进制。

### Finding 79: tunnelManager 使用已释放的 Tunnel 指针导致 segfault（Critical）

`tunnelManager` 调用 `state.getGuestTunnel(hostname)` 获取 Tunnel 指针后释放 `state.mutex`。`handleMeshGuest`（独立线程）退出时 `defer` 调用 `removeGuestTunnel` + `allocator.destroy(tun)`，释放 Tunnel。tunnelManager 再调用 `existing_tun.?.isAlive()` 访问已释放内存 → segfault（地址 `0xaaaaaaaaaaaaaaaab2` — debug allocator 填充模式）。

**修复**：新增 `state.isTunnelDead(hostname)` 方法，在 `state.mutex` 锁定期间完成 lookup + `isAlive()` 检查。`existing_tun_conv` 值在锁内快照，整数比较不依赖 Tunnel 指针生命周期。

---

## Phase 51: 文件合并与 API 适配发现

### Finding 80: Zig 0.16.0 `waitpid` 新 API

`std.process.Child.wait` 在 0.16.0 中签名变更，返回 `WaitPidResult` 而非旧的 `Term` 类型。`WaitPidResult` 字段：`pid`、`status`（原始整数）。需用 `std.posix.system.WIFEXITED(status)` 等宏解析，而非旧式的 `.exited` 标签。

### Finding 81: Zig 0.16.0 `BodyWriter` → `Response.Writer`

0.16.0 HTTP 响应流类型从 `BodyWriter` 改为 `Response.Writer`，需要在合并 `host_http.zig`→`httpd.zig` 时全局替换。

### Finding 82: Zig 0.16.0 `executablePath()` 新签名

`std.process.executablePath()` 在 0.16.0 中返回 `[]const u8`（非错误联合），不再需要 `try` 前缀或 `catch` 处理。旧代码中的错误处理模式在合并时一并清理。

### Finding 83: Zig 0.16.0 `Event.set()` 单参数签名

`std.Io.Event.set()` 仅接受 `io` 参数，不再接受第二个状态参数（如 `.unset`）。合并过程中 `svc.zig` 和 `httpd.zig` 中所有 `.set(io, .unset)` 调用均需改为 `.set(io)`。

### Finding 84: Zig 0.16.0 `readSliceAll` → `ReadBuffer`

`std.Io.Reader.readSliceAll(allocator, max)` 在 0.16.0 中移除。替代方案：`ReadBuffer` + `readUntilDelimiterAll`，或使用 `stream` API 逐块读取。

---

## Phase 52: CLI 分发逻辑分析

### Finding 85: 管理命令错误消息淹没在堆栈跟踪中

`--exec`/`--status`/`--upload`/`--download` 在 Host 服务未运行时，各 `cmd*()` 函数打印 `"[exec] HTTP request failed: ConnectionRefused — is Host running?"` 后 `return err` → 错误传播至 `main()` → Zig 运行时打印堆栈跟踪。有用的错误消息被埋在噪音中。对 AI Agent 不友好——需解析错误输出识别 `"is Host running?"`。

此问题已通过 Phase 52 的自动 ensure 从根源解决——服务未运行时自动启动，不再走到 ConnectionRefused 路径。

### Finding 86: `--host` 与管理命令不可组合（已修复）

改前 `main.zig` 分发顺序：`--host` 检查（line 330）在管理命令（line 338）之前，且 `--host` 的 `return` 阻止 fall-through。所以 `utmm --host --exec vm "cmd"` 只确保 Host 运行后退出，忽略 `--exec`。

修复：合并两个分支为统一的 `needs_host` 判断 + `svc.ensure()` + 条件 return。

### Finding 87: Guest 模式无需管理命令衔接

Guest 没有本地 HTTP API——管理命令全部通过 Host。Guest 的 `svc.ensure(.guest)` 就是完整行为（确保运行 → 退出），无需 Phase 52 的 fall-through 逻辑。只有 Host 需要管理命令衔接。

### Finding 88: 管理命令全平台行为矩阵

| 命令 | Host 服务未运行 | Host 服务已运行 | 需要 Host？ |
|------|----------------|----------------|------------|
| `--status` | 改前: ❌ ConnectionRefused / 改后: ✅ 自动启动 | ✅ 正常 | 是 |
| `--exec` | 改前: ❌ ConnectionRefused / 改后: ✅ 自动启动 | ✅ 正常 | 是 |
| `--upload` | 改前: ❌ ConnectionRefused / 改后: ✅ 自动启动 | ✅ 正常 | 是 |
| `--download` | 改前: ❌ ConnectionRefused / 改后: ✅ 自动启动 | ✅ 正常 | 是 |
| `--gen-init` | ✅ 直接输出（不需要 Host） | ✅ 同左 | 否 |
| `--save-config` | ✅ 直接保存（不需要 Host） | ✅ 同左 | 否 |

三个平台（macOS/Linux/Windows）行为一致——管理命令通过 HTTP 连接 `127.0.0.1:2121`，与系统服务管理器无关。

---

## Phase 52 部署测试发现

### Finding 89: `runCmd` 忽略命令退出码（Critical）

`svc.zig` 中 `runCmd()` 始终返回 `true`，不检查 `result.term`：
```zig
fn runCmd(alloc, io, argv) bool {
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return true;  // ← 永远返回 true，忽略退出码
}
```

`runCmdCheckExit()` 已存在且正确检查退出码，但 `installMacOS` 的 `launchctl bootstrap`、`start()` 等多个关键路径用的是 `runCmd()`。导致 launchctl 失败被静默忽略。

**修复**：改为 `return result.term == .exited and result.term.exited == 0;`。同时发现 `installMacOS` 和 `start()` 都调用 `launchctl bootstrap`，重复调用导致第二次失败——`start()` 改为先 `isRunning()` 检查 + `kickstart` 回退 `bootstrap`。

### Finding 90: macOS `cp` 破坏 ad-hoc 代码签名（Critical）

在 macOS 上，`sudo cp zig-out/bin/utmm /opt/utmm/utmm` 复制二进制后，ad-hoc 代码签名失效。launchd 加载服务时 dyld 验证签名 → `SIGKILL (Code Signature Invalid)` → 进程被杀。crash report: `CODESIGNING Invalid Page`。

**症状**：`launchctl bootstrap` 返回 `Input/output error`，服务立即被 kill。

**修复**：每次 cp 部署后运行 `sudo codesign --force --sign - /opt/utmm/utmm`。更根本的修复是在 `selfCopy()` 的 copy+delete 回退路径中添加 ad-hoc re-sign 步骤（rename 路径不受影响）。

### Finding 91: `selfCopy` copy+delete 路径也破坏签名

`selfCopy()` 在 `/tmp` 和 `/opt/utmm` 不同文件系统时走 copy+delete 回退（EXDEV）。此路径和 `cp` 一样会破坏签名，导致后续 `launchctl bootstrap` 失败。rename 路径（同文件系统）不受影响。

**修复方案**：在 `selfCopy()` 的 copy+delete 回退路径中，copy 完成后调用 `codesign --force --sign -` 重新签名。需在 `svc.zig` 中实现。

### Finding 92: `launchctl enable` 不足于清除 disabled 状态

`launchctl enable system/com.utmm.host` 设置 disabled 标志为 `enabled`，但 `launchctl bootstrap` 仍可能返回 `Input/output error`。需用 `/usr/libexec/PlistBuddy -c "Delete" /private/var/db/com.apple.xpc.launchd/disabled.plist` 完全删除条目。

**修复**：在 `installMacOS` 的 `launchctl enable` 之后添加 PlistBuddy 删除作为额外保障。但 PlistBuddy 路径可能随 macOS 版本变化；更好的方案是引导用户手动清理。

### Finding 93: KCP 隧道在 Host 重启后 exec 不返回输出

Host 重启后，所有 VM 重新连接（LSA 正常，status 显示在线），但 exec 返回空输出（200 OK + 5 秒超时 + exit=-1）。winx64 在某些情况下（Guest 复用旧 session）能正常工作。

**原因分析**：Host 和 Guest 各自调用 `m.connect()` 创建 KCP 会话，conv ID 不同。Host 重启后 tunnelManager 创建新会话，但 Guest 仍用旧会话。数据在不同会话间无法互通——"dual-session mismatch"。

tunnelManager 有检测逻辑（搜索 Guest-initiated session），但在 Host 重启后 Guest 的 session 可能还未重建。此问题早于 Phase 52，属于 KCP 隧道管理的设计 bug。

**更新 (2026-07-26)**: 此问题的根因分析不完整。真正根因是 6 个协同问题（详见 Phase 54）：0xFF keepalive 污染数据通道 + 缺少 pty_spawn + tunnel 层 peekSize/recv 过滤不对称 + waitForHostTunnel 选过期 session + ptyReadLoop 不检查 pty_dead + macOS 重试计数器不重置。已在提交 `1ff46ad` 和 `e444d46` 中全部修复。

---

## Phase 54: Task #254 — Host 重启 exec 空输出修复 (2026-07-26)

### Finding 94: 0xFF Keepalive 通过 KCP 数据通道污染应用层（Critical）

`mesh.zig:periodicTasks` 每 1s 通过 `kcp.send(&[_]u8{0xFF})` 发送 keepalive 探针。`0xFF` 作为完整的 KCP 消息（1 字节，type=255）传递到对端应用层，与 tunproto 消息（pty_exec_input=0x10、file_chunk=0x1c 等）混在同一通道。

**影响链**：
- `tunnel.peekSize()` 返回 1 → `handleMeshGuest` 分配 1 字节缓冲区
- `tunnel.recv()` 有过滤但 `peekSize()` 没有 → 不对称
- 下次 real message（>1 字节）被读到 1 字节缓冲区 → KCP BufferTooSmall → handler crash
- `waitForHostTunnel` 选中有 0xFF 数据的 session → 读到 type=255 → 忽略 → 永远处理不了 exec 数据

**修复** (`tunnel.zig`): `recv()` 和 `peekSize()` 同时过滤 `0xFF`。keepalive 检测仍通过 `kcp_inst.peekSize()` 直接访问，不受 tunnel 层过滤影响。

### Finding 95: peekSize/recv 过滤不对称导致 BufferTooSmall 级联

`tunnel.recv()` 在 while 循环中过滤 0xFF，但 `tunnel.peekSize()` 是 `kcp_inst.peekSize()` 的简单透传。`handleMeshGuest` 的模式是 `peekSize()` → 分配缓冲区 → `recv()`：peekSize 返回 1（0xFF）→ 分配 1 字节 buf → recv() 过滤 0xFF 后尝试读 real message → KCP 内部缓冲区足够但用户 buf 不够 → BufferTooSmall。

**教训**：成对的 peek/read 方法必须保持过滤逻辑一致。peek 应消费被过滤的消息，而非仅报告其大小。

### Finding 96: macOS launchd 重试计数器永久累积

`svc.zig:checkRetryLimit()` 每次服务启动时读取 `/var/run/utmm-host.retry`，递增计数器，>3 则 exit。`resetRetryCounter()` 定义但从未调用。每次重启都累积计数，测试时快速重启 4 次即被 launchd 拒绝。

**修复**：
1. 在 `host.zig` 和 `broadcast.zig` 的 mesh 启动成功后调用 `resetRetryCounter()`
2. 在 `checkRetryLimit()` 中添加 120s 时间窗口：如果计数器文件 mtime > 120s 前，说明上次运行成功持续了有意义的时间，重置计数

### Finding 97: 轮询测试模式替代固定等待

固定 `sleep 20` 等待 Host 就绪 → 不可靠（有时未就绪）、慢（8s 就绪也要等 20s）。轮询模式：每 2s 尝试 exec，HTTP 200 即进入下一轮。典型就绪 ~8s，可靠性从 ~70% 提升到 100%。

### Finding 98: Zig 0.16.0 `zig build test` 管道模式 EndOfStream

`zig build test` 使用内部 `--listen=-` 管道模式与测试 runner 通信时，偶尔报 `error.EndOfStream`。绕过方案：直接运行测试二进制 `./.zig-cache/o/<hash>/test --seed=0x1`。

---

## Phase 55: Windows 服务停止卡死修复 (2026-07-27)

### Finding 99: `signalShutdown()` 提前关闭 socket 阻止 self-wake（Critical）

`mesh.zig:signalShutdown()` 在 Windows 上调用 `self.socket.close(self.io)` 试图中断 mesh 线程的阻塞 `receive()`。但这同时阻止了定时器线程的 self-wake 数据包——`self.socket.send()` 对已关闭的 socket 失败（被 `catch {}` 静默吞掉）。ARM64 上 AFD close 不保证中断 receive → 三重失败：close 不中断 + self-wake 无法发送 + timer join 永久阻塞。

**修复**: `signalShutdown()` 只设置 `self.shutdown = true`，不关闭 socket。定时器线程（1s 周期）检测标志位后发送 self-wake UDP 包到 127.0.0.1:2121。Socket 在 `t.join()` 返回后由调用者的 defer 块关闭。

**关键洞察**: 修复前的问题不是定时器线程不工作，而是 `signalShutdown()` 销毁了定时器线程需要的工作资源（socket）。

### Finding 100: POSIX `close()` 在 Windows 上是空操作

`broadcast.zig` 在 defer 块和命令循环退出后调用 `_ = close(pty.master_fd)` 关闭 pty 管道。但 `extern "c" fn close(fd: std.posix.fd_t) c_int` 调用的是 C 运行时的 `_close()`，期望 CRT 文件描述符。`CreatePipe` 返回的是 `HANDLE`（`*anyopaque`），传给 `_close()` 无效——管道不被关闭，`ReadFile` 继续保持阻塞。

Zig 0.16.0 在 Windows 上 `std.posix.fd_t` = `HANDLE` = `*anyopaque`，但不能假设所有 POSIX 函数都正确处理它。`@ptrCast(fd)` → `CloseHandle` 是正确的 Windows 管道关闭方式。

**修复**: 新建 `closePtyFd()` 辅助函数，Windows 上用 `CloseHandle(@ptrCast(fd))`。

### Finding 101: `ReadFile` 不能被 `CloseHandle` 可靠中断（ARM64）

即使正确调用了 `CloseHandle`，ARM64 Windows 上 `CloseHandle` 从另一个线程关闭管道不一定能中断当前线程的阻塞 `ReadFile`。这与 AFD socket `CloseHandle` 不中断 `receive()` 的问题类似——ARM64 内核的 I/O 取消机制与 x86_64 有微妙差异。

**修复**: 在 `ptyReadLoop` Windows 路径中使用 `PeekNamedPipe` + `Sleep(100)` 轮询，替代阻塞 `ReadFile`。每 100ms 检查一次 `pty_dead` 标志位，100ms 内即可响应关闭信号。

**架构意义**: 这个修复将 Windows pty 读取从"被动阻塞模式"改为"主动轮询模式"，与 POSIX `poll(fd, 100)` 的设计一致——两者都在 100ms 内可响应关闭信号。

### Finding 102: 服务停止的完整线程依赖链

Windows 服务停止 (`sc stop`) 涉及 4 个线程的协调退出：

```
SCM → svcCtrlHandler → shutdown_flag = true
  → 主线程 (meshSessionLoop): 命令循环检测 shutdown_flag
    → pty_dead = true + closePtyFd → ptyReadLoop 退出
    → defer: signalShutdown() → mesh.shutdown = true
    → 定时器线程: 检测 mesh.shutdown → self-wake 包
    → mesh 线程: receive 被 self-wake 唤醒 → 检测 shutdown → 退出
  → svcMain: SetServiceStatus(STOPPED)
```

任意一环断裂都导致 STOP_PENDING。Phase 55 修复了其中 3 个断裂点：
1. socket 提前关闭 → self-wake 无法发送
2. POSIX close() 不工作 → pty 管道不关闭
3. CloseHandle 不中断 ReadFile → ptyReadLoop 不退出

### Finding 103: Phase 55 优雅退出仍失败 — waitForHostTunnel + ReadFile 竞态 (2026-07-27)

Phase 55 部署后 windowsvm 和 winx64 的 `sc stop` 仍卡 STOP_PENDING。两个额外根因：

1. **`waitForHostTunnel` 无 shutdown 检查**: Guest 在重连等待中（`waitForHostTunnel` 的 `while(true)` 循环）时收到停止通知，外部主循环的 `checkShutdown` 永远无法调到 → 永不退出。

2. **`PeekNamedPipe` + `ReadFile` 竞态**: `ptyReadLoop` 在 `PeekNamedPipe` 报告数据可用后、`ReadFile` 调用前存在竞态窗口。若主线程在此期间调用 `CloseHandle`，ARM64 AFD 不取消 pending ReadFile → `t.join()` 死锁。

**最终方案**: 放弃优雅退出。`svcCtrlHandler` 收到 STOP 后直接报告 `SERVICE_STOPPED` + `exit(0)`。副作用（`sc stop` error 109 pipe broken）是 cosmetic 的，服务实际已正确停止。

**修复提交**: `3cc95ab`

**状态**: ⛔ **永久延迟** (2026-07-27) — Windows ARM64 多线程协调退出受 AFD 行为限制，硬停止方案工作稳定，不值得投入更多精力追求优雅退出。

**教训**: Windows ARM64 上多线程协调退出的可靠性受 AFD 行为限制，某些场景下"硬停止"比"优雅退出"更可靠。此方案同时适用于 Guest 和 Host（Host 同理在停止时直接 exit，让 SCM 或 watchdog 自动重启）。

---

## Phase 57: `--ping` 命令实现与自动升级测试 (2026-07-27)

### Finding 104: `setGuestMeshMac()` 定义但从未调用（Critical）

`httpd.zig:343` 中 `setGuestMeshMac()` 方法已定义，但全项目零调用。`GuestEntry.mesh_mac` 字段永远为 `null`。导致 `/ping` handler 在 `handlePing` 中查找 Guest 时始终走到 `"guest not found or no mesh MAC"` 错误。

**修复**: 在 `host.zig` 的 tunnelManager 中，`registerGuestTunnel` 之后调用 `state.setGuestMeshMac(hostname, saved_node_id)`。`saved_node_id` 来自 LSA 数据库的 MAC 地址，tunnelManager 循环中已可用。

### Finding 105: `pingAndWait` 用事件计数器做超时（clock_ms）

原实现用 `self.clock_ms +% 5000` 做 5 秒 deadline。但 `clock_ms` 是事件计数器（+10/收包、+1000/1秒超时），不是真实毫秒。Host 上 `clock_ms` 约 1000-2000 tick/秒，5000 tick 约 2.5-5 秒。而周期性 ping 每 60 tick 触发一次，周期过长无法在 5 秒窗口内命中。

**修复**: 改为真实时间轮询：200 次迭代 × 50ms sleep = 10 秒。每次迭代检查 `last_pong_*` 是否匹配目标 MAC。

**已知局限**: RTT 值仍为 `clock_ms` 事件计数（非真实毫秒）。Guest 将原始时间戳复制回 pong，Host 用 `clock_ms -% send_ts` 计算差值。对于本地 VM，RTT 通常为 10-50 "tick"。

### Finding 106: `zig build -Dtarget=...` 覆盖 `zig-out/bin/utmm`

每次交叉编译（`zig build -Dtarget=aarch64-linux-musl` 等）会将输出写入 `zig-out/bin/utmm`，覆盖上一次构建。部署到本机时必须使用命名目标二进制（如 `utmm-aarch64-macos`），而非 `utmm`。

**规避**: 交叉编译后运行 `zig build`（无 target）恢复原生二进制；或始终从命名文件部署。

### Finding 107: SSH `--install` 不可靠 — pkill/taskkill 杀掉自身

`--install` 流程包含 `stop → kill → copy → install → start`。`kill` 步骤（POSIX `pkill utmm`、Windows `taskkill /f /im utmm.exe`）会杀掉所有 utmm 进程，包括 SSH 会话中正在执行 `--install` 的进程。服务重配置（写 systemd/launchd/sc 配置、重启服务）被中断。

**症状**: Guest 升级后服务配置文件缺少 `--hostname` 参数（服务未完成重配置），Guest 启动后使用自动检测的主机名而非配置的主机名。

**规避**: 
- Linux: 直接用 `systemctl` 修改服务文件 + daemon-reload + restart
- macOS: 手动 bootout + bootstrap + kickstart 序列
- Windows: `sc config` 单独修改 binPath + `sc start`，不在 SSH 中执行 `--install`

### Finding 108: 升级后 Guest 丢失 hostname 导致 mesh 重连使用自动检测名

Phase 50-56 中 Guest 通过 `--install --hostname <name>` 部署，服务配置含 hostname。通过 SSH `--install` 升级时（Finding 107），`pkill` 中断 SSH 会话导致 service config 未更新，Guest 重启后使用自动检测的主机名（如 ubuntu、WIN-Q0JNGDDBE28、MODASIAIPC）。

Host 的 `--status` 显示新旧两条记录（旧 hostname 的 stale entry 和新的自动检测名 entry），exec/upload 命令需用新主机名。Host 的 `guestIndex` 按 hostname 精确匹配，`/ping` 端点也按 hostname 查找。

**解决方案**: 升级后手动修复服务配置（systemd unit / launchd plist / sc config），重启服务以使用正确 hostname。或改进 `--install` 流程避免 pkill 自伤。

---

## IPC 迁移部署测试发现 (2026-07-27)

### Finding 109: `parseFileEof` type byte 污染导致 download 永久失败（Critical）

`httpd.zig:handleMeshGuest` 的 `file_eof` 分支调用 `tunproto.parseFileEof(data)` 传入完整数据（含 type byte `0x1D`）。`parseFileEof` 从 `pos=0` 开始解析，将 `0x1D` 当作 `cmd_id` 的第一个字节。解析出的 `cmd_id` 为 `\x1Ddownload_<ts>` 而非 `download_<ts>`，导致 `completeOpState` 操作了错误的 op state。download handler 永远等不到正确的 op state 完成 → 超时 → `exit_code=-1`。

对比其他分支：
- `file_chunk` handler: `var pos: usize = 1;`（正确跳过 type byte）
- `pty_exec_done` handler: `parsePtyExecDone(data[1..])`（正确跳过 type byte）
- `file_eof` handler: `parseFileEof(data)` ← **遗漏了 `[1..]`**

此 bug 自 chunked file transfer 引入以来一直存在，仅影响 download（Guest→Host），不影响 upload（Host→Guest，Guest 忽略 file_eof）。IPC 迁移前下载同样失败。

**修复**: `parseFileEof(data)` → `parseFileEof(data[1..])`（提交 `a3b4672`）

**教训**: 序列化/反序列化成对函数应保持一致的起始位置约定。添加新消息类型时，应检查同一 dispatch 块中其他分支的 pos 起始值。

### Finding 110: macOS launchd plist 升级后丢失 StandardErrorPath

macvm Guest 和本机 Host 的 launchd plist 在通过 SSH `--install` 或 `--svc` 安装时，未设置 `StandardErrorPath`。导致所有 `std.log` 输出（包括 `err` 级别）进入 ASL 系统日志而非文件日志，关键错误信息无法通过文件监控获取。

**修复**: 手动用 `PlistBuddy -c 'Add :StandardErrorPath string ...'` 补充配置。应在 `svc.zig` 的 `installMacOS` 中总是设置 `StandardErrorPath`。

### Finding 111: `cmdDownload` 双重 close 导致 unreachable panic

`cmdDownload` 中 `tmp_file.close(block_io)` 显式关闭 + `defer tmp_file.close(block_io)` 延迟关闭，同一 fd 关闭两次触发 `std.Io.Threaded.BADF → unreachable` panic。

**修复**: 移除显式关闭，仅保留 defer 关闭（提交 `a3b4672`）。

### IPC 命令验证结果 (2026-07-27)

| 命令 | 状态 | 说明 |
|------|------|------|
| `--status` | ✅ | 4 guests 全部正确显示 |
| `--ping` | ✅ | JSON 响应正确（修复了 buffer 污染 + mesh_ptr 转换） |
| `--exec` | ✅ | 命令输出正确 |
| `--upload` | ✅ | 上传+sha256验证通过（修复了 KCP send+flush 竞态） |
| `--download` | ✅ | 文件下载正确（修复了 parseFileEof type byte 污染） |

IPC 协议通过 Unix Domain Socket `/var/run/utmm.sock` 工作正常。HTTP endpoint 保留用于未来 WebUI。

---

## Phase 58-59 发现 (2026-07-27)

### Finding 112: `--install` 重写 macOS plist 时 StandardErrorPath 必然回归

Finding 110 的手动修复（`PlistBuddy -c 'Add :StandardErrorPath ...'`）在 `--install` 部署新版本后**必然丢失**，因为 `svc.zig:installMacOS()` 的 plist 模板从未包含 `StandardErrorPath`。

**影响**: 每次 `--install` 部署后，所有 `std.log` 输出（包括 `err` 级别）进入 ASL 系统日志而非文件。调试时完全看不到 Host 日志。

**修复**: `svc.zig:installMacOS()` plist 模板新增 `<key>StandardErrorPath</key>`，路径同 stdout + `-err` 后缀。同时覆盖 Guest plist。

**教训**: 手动修复 OS 配置文件不可持续 — 必须在代码生成路径中固化。

### Finding 113: `handleMeshGuest` 缺少 `upload_result` (0x17) 处理分支

Host 日志周期性出现 `error: [tun-hdl] unknown msg type 0x17 for macvm`。`upload_result` 是 Guest→Host 的 upload 完成通知，但 Host 的 `handleMeshGuest` switch 中没有对应分支。

**影响**: 不影响功能 — upload 走 fire-and-forget（Host 发送完 chunks+eof 后立即返回 OK，不等待 Guest 的 upload_result）。但日志刷屏干扰排查。

**状态**: 🔴 Phase 66 待修 — 添加 `upload_result` 处理分支（至少静默消费）。

### Finding 114: httpd.zig 测试未被编译入测试套件

httpd.zig 包含约 31 个测试（jsonEscape、jsonGetString、jsonGetInt、buildCmdWithMarker、scanForMarker、HostState、Router 等），但 `zig build test` 仅报 149 个测试，未包含 httpd.zig 的任何测试。git HEAD (a3b4672) 同样如此，说明此问题早于 Phase 60。

**可能原因**: httpd.zig 被 `@import` 但 Zig 编译器可能因某些原因未收集其 test 块。`mcp.zig` 有自己的 `jsonEscape` 副本（含独立测试）。

**状态**: ❌ **已取消** (2026-07-27) — httpd 已在 Phase 61 废弃（HTTP 协议全面删除），httpd.zig 仅保留 HostState + handleMeshGuest 等 KCP 侧功能，Router/jsonEscape 等 HTTP 代码已删除。此任务自动取消。

---

## Phase 62: Windows IPC 编译修复发现 (2026-07-27)

### Finding 115: Zig 0.16.0 移除 Named Pipe API 需手动 extern

`std.os.windows` 在 Zig 0.16.0 中移除了以下 API：`CreateNamedPipeA`、`ConnectNamedPipe`、`CreateFileA`、`ReadFile`、`WriteFile`、`SetNamedPipeHandleState`、Win32 常量（`PIPE_ACCESS_DUPLEX`、`GENERIC_READ` 等）、`.Win64` 调用约定。

`broadcast.zig` 已使用 `@extern(*const fn(...) callconv(.winapi) ..., .{ .name = "...", .library_name = "kernel32" })` 模式声明这些 API。`ipc.zig` 需要同样的声明。

### Finding 116: `callconv(.winapi)` 是 32-bit MinGW 必需

6 个 `extern "kernel32"` 声明在没有 `callconv(.winapi)` 的情况下，64-bit Windows 构建正常（x86_64/aarch64 只有一种调用约定），但 32-bit MinGW (`x86-windows-gnu`) 链接失败：
- `_CreateFileA`、`_ReadFile`、`_WriteFile` 等 6 个符号未定义
- 原因：32-bit kernel32 使用 `__stdcall` 约定（`_FuncName@bytes`），`extern` 默认 C 约定（`_FuncName`）

**修复**: 所有 `extern "kernel32" fn` 添加 `callconv(.winapi)`。

### Finding 117: `null` 在 Zig 0.16.0 中无类型

`CreateFileA(..., null)` 中 `null` 参数无法匹配 `hTemplateFile: HANDLE`（即 `*anyopaque`）。Zig 0.16.0 的 `null` 是无类型值，需要显式类型注解。

**修复**: 参数类型改为 `?HANDLE`（`?*anyopaque`），与 Windows API 语义一致（hTemplateFile 可为 NULL）。

### Finding 118: `@ptrCast` 不能将 slice 转为 sentinel 指针

`@ptrCast(path)` 无法将 `[]const u8`（slice）转换为 `[*:0]const u8`（null-terminated 指针）。字符串字面量本身已是 `*const [N:0]u8`，可直接强制转换为 `[*:0]const u8`。

**修复**: 新建 `socketPathZ()` 函数，直接返回字符串字面量（利用 Zig 的 sentinel 强制转换）。所有 C API 调用（`unlink`、`chmod`、`CreateNamedPipeA`、`CreateFileA`）改用 `socketPathZ()`。

### Finding 119: 交叉编译覆盖 `zig-out/bin/utmm`

与 Finding 78 和 106 相同问题：`zig build -Dtarget=x86-linux-musl` 将输出写入 `zig-out/bin/utmm`（同大小 7453740 bytes），覆盖原生 Mach-O aarch64 二进制。部署前最后一个 `zig build` 必须无 `-Dtarget`。

### MSS-aligned chunk 部署验证 (2026-07-27)

FILE_CHUNK_DATA_MAX = 1200 bytes，MSS 对齐，部署测试全部通过：

| 命令 | 结果 |
|------|------|
| `--status` | ✅ 4 guests Online |
| `--ping macvm` | ✅ `rtt_ms:10` |
| `--exec macvm "uname -a"` | ✅ Darwin arm64 |
| `--upload test.txt macvm` | ✅ OK |
| `--download macvm test.txt` | ✅ 56B, FILES MATCH |

---

## Phase 63: Guest 自主升级方案发现 (2026-07-27)

### Finding 120: 升级信号在命令循环中死锁（Critical）

Guest `meshSessionLoop` 的结构是两层循环：
- **外层**: `while(true)` → `waitForHostTunnel()` → `ptySpawn()` → 进入内层
- **内层**: `while (!pty_dead.load(.acquire))` → 处理命令（pty_exec_input/upload_cmd/download_cmd）

`upgrade.needed` 的检查只在**外层循环**中（`waitForHostTunnel` 之前）。Guest 成功连接到 Host 后进入内层命令循环，永不退出。LSA handler 设置了 `upgrade.needed = true`，但内层循环永远看不到这个信号 → **升级信号死锁**。

**症状**: Guest 和 Host 版本不同（LSA 日志可见），但 Guest 从不触发升级。v0.11.11/v0.11.12 Guest 均受此 bug 影响。

**修复** (v0.11.14, commit `7178fb2`): 在内层命令循环的 `checkShutdown` 之后、`tunnel.isAlive()` 之前添加：
```zig
if (upgrade.needed.load(.acquire)) {
    std.log.info("[guest-mesh] Upgrade signal detected, exiting command loop", .{});
    break;
}
```

**教训**: 嵌套事件循环中，信号检查必须在**所有层级**都存在。仅在外层检查，内层永不退出时会永远丢失信号。

### Finding 121: Host 推送升级方案过度复杂且不可靠

v0.11.12 的初始实现（commit `578f55c`）尝试 Host 推送升级：Host 检测 Guest 版本过旧 → 设置 status:upgrading → KCP 上传新二进制 → exec `--install --hostname <name>`。存在多个根本性问题：

1. **pkill 自伤**: `--install` 内部的 `kill()` 步骤（POSIX `pkill utmm`、Windows `taskkill /f /im utmm.exe`）会杀掉所有 utmm 进程，包括 Host 自身的进程管理器 → 不可预测的行为
2. **多 Guest 并发竞争**: 多个 Guest 同时检测到版本不匹配 → Host 资源竞争（KCP 带宽、同时上传）
3. **错误恢复困难**: Host 推送失败后需要重试机制、冷却时间、状态追踪 → 复杂的状态机
4. **难以测试调试**: 升级逻辑分散在 Host 和 Guest 两侧，端到端测试需要完整 mesh 环境

**设计修正**: 用户明确要求简化为 Guest 自主方案（Host 永不推送）。Guest 端完成升级这个"原子操作"：检测版本不匹配 → 下载新二进制 → `--install`。方案简洁可靠，可独立测试每个环节。

### Finding 122: `tunnelManager` upgrading 特殊逻辑导致死锁

v0.11.12 的 `tunnelManager` 有"Phase 2"逻辑：当 Guest 状态为 upgrading 时，Host 搜索 Guest 主动发起的 KCP session（而非调用 `m.connect()` 创建新会话）。但 Guest 在 `doAutoUpgrade()` 中调用 `waitForHostTunnel()` 等待 Host 创建隧道 → Host 等待 Guest 创建隧道 → 双方互相等待 → **死锁**。

**修复** (v0.11.13, commit `98409c4`): 移除 upgrading 特殊逻辑，升级期间统一使用 `m.connect()` 建立隧道。升级是 Guest 自主的——Guest 通过正常隧道发送 `upgrade_req`，Host 响应文件数据。


