# Findings: v0.11.10

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

**修复**：从 `handleMeshGuest` 的 4 处 `set()+reset()` 中移除 `reset()`。`reset()` 仅在等待线程（`handleExec`/`handleDownload`/`mcpHandleVmExec`）的 `waitTimeout()` 返回后调用。

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
