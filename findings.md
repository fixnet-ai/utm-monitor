# Findings: v0.11.16

记录重要的技术发现、Bug、设计决策和 Zig 0.16.0 API 笔记。

---

## Zig 0.16.0 API 适配

### Finding 62: `std.os.windows` 移除 SCM 类型
Zig 0.16.0 从 `std.os.windows` 移除了 `SERVICE_TABLE_ENTRYW`、`SetServiceStatus` 等。须在 `src/svc.zig` 中手动声明 extern。

### Finding 63: `GetLastError()` 返回 enum
`std.os.windows.GetLastError()` 返回 `Win32Error` enum，需 `@intFromEnum(gle)` 转换。

### Finding 64: `std.c.strerror` 已移除
需 `@extern` 直接调用 libc。

### Finding 65: `rename()` 签名变为 4 参数
`Dir.rename(old_path, new_dir, new_path, io)`。跨文件系统返回 `error.RenameAcrossMountPoints`。

### Finding 66: `++` 需 comptime-known
运行时字符串拼接需多个 `appendSlice` 调用。

### Finding 67: 自复制跨文件系统 rename 回退
`selfCopy()` 的 tmp→canonical rename 可能遇到 EXDEV。回退方案是 copy+delete。macOS 上 copyFile 破坏签名 → Phase 66 在回退路径加入 `codesign --force --sign -`。

### Finding 68: `std.c.getErrno` 不存在
POSIX write() 返回负数时无法获取 errno。替代：统一视为 WriteFailed，上层重试。

### Finding 69: `catch { } else |val| { }` 非法语法
Zig 的 if 直接支持 error union 解构：`if (expr) |val| { } else |err| { }`。

### Finding 70: Windows `BOOL` 类型跨平台不兼容
必须用 `@intFromEnum()` 包裹 BOOL 返回值后再比较。

### Finding 71: `Io.Clock` 无 `.monotonic`
正确成员是 `.awake`。`std.Io.Timestamp.now(io, .awake)`。

### Finding 72: `*[]const u8` vs `[]const u8` 解引用陷阱
名称遮蔽导致混淆 — 函数参数和局部变量同名时行为不同。

### Finding 73: 自死锁避免模式
`rebuildRoutes` 内部自锁。调用者必须 block-scoped 先释放→再调用。锁序固定 `sessions→neighbors→lsas→routes`。

### Finding 74: `errdefer` 与 `@panic`（fail.err）不兼容
`fail.err()` 内部 `@panic`，`errdefer` 不执行。失败回滚必须在 `fail.err()` 前手动进行。

### Finding 75: `runCmdQuiet` debug 级 vs warn 级
svc.zig 中 `_ = runCmd(...)` 大多是预期失败（停止未运行的服务），用 debug 日志而非 warn 避免噪音。

### Finding 80: `waitpid` 新 API
0.16.0 `Child.wait` 返回 `WaitPidResult`，字段 `pid`、`status`（原始整数），需用 `WIFEXITED` 等宏解析。

### Finding 81: `BodyWriter` → `Response.Writer`
0.16.0 HTTP 响应流类型变更。

### Finding 82: `executablePath()` 新签名
返回 `[]const u8`（非错误联合），不再需要 `try`。

### Finding 83: `Event.set()` 单参数签名
仅接受 `io` 参数，不再接受第二个状态参数。

### Finding 84: `readSliceAll` → `ReadBuffer`
替代方案：`ReadBuffer` + `readUntilDelimiterAll`。

### Finding 98: `zig build test` 管道模式 EndOfStream
`--listen=-` 管道模式与测试 runner 通信偶报 `error.EndOfStream`。绕过：直接运行测试二进制 `./.zig-cache/o/<hash>/test --seed=0x1`。

### Finding 115-118: Windows Named Pipe API 需手动 extern
Zig 0.16.0 移除 `CreateNamedPipeA`、`ConnectNamedPipe` 等。`callconv(.winapi)` 是 32-bit MinGW 必需。`null` 无类型需 `?HANDLE`。`@ptrCast` 不能将 slice 转 sentinel 指针。

---

## KCP 协议

### Finding 55: `input()` seg.data 泄漏（Critical）
`ackPush`/`insertRcvBuf` OOM 时已分配 seg.data 泄漏。修复：errdefer + seg.data = null 防 double-free。

### Finding 56: `send()` 非 stream OOM 部分片段残留（Critical）
非 stream 模式 send OOM 后部分片段已入 snd_queue，接收端永久阻塞。修复：errdefer 回滚 + catch 释放。

### Finding 57: `input()` parseUna 不可回滚（High）
parseUna 先修改 snd_una，后续 OOM 无法恢复。设计限制，keepalive 兜底。

### Finding 59: 时间戳算术溢出（Medium）
8 处 `+` 改为 `+%`（wrapping add），防长时间运行后回绕。

---

## Windows 平台

### cmd.exe UTF-8 三层保障
`CreatePipe` + `CreateProcessW("cmd.exe /k")` 需 SetConsoleCP(65001) + chcp 65001 + LANG 环境变量。

### KCP 需阻塞接收 + 定时器线程
ARM64 Windows 上 `receiveTimeout` 静默丢失 KCP 数据。阻塞 receive + 独立 Win32 Sleep 定时器线程是唯一可靠方案。

### .exe 文件锁定
服务运行时 .exe 被锁定，不能直接覆盖。部署流程：SCP 到临时文件 → 停服 → 覆盖。

### Finding 99: `signalShutdown()` 提前关闭 socket 阻止 self-wake（Critical）
`socket.close()` 同时阻止定时器线程的 self-wake 数据包。修复：只设 `shutdown = true`，定时器线程检测后发 self-wake。

### Finding 100: POSIX `close()` 在 Windows 上是空操作
`CreatePipe` 返回 HANDLE，`_close()` 不处理。正确方式：`CloseHandle(@ptrCast(fd))`。

### Finding 101: `ReadFile` 不能被 `CloseHandle` 可靠中断（ARM64）
ARM64 上 `CloseHandle` 不一定中断阻塞 `ReadFile`。修复：`PeekNamedPipe` + `Sleep(100)` 轮询。

### Finding 102: 服务停止的完整线程依赖链
4 线程协调退出：SCM → 主线程 → ptyReadLoop → mesh 线程。任意一环断裂 = STOP_PENDING。

### Finding 103: 优雅退出永久延迟
Windows ARM64 多线程协调退出受 AFD 行为限制。硬停止方案工作稳定，不值得更多投入。

---

## 设计决策 (ADR)

### ADR-1: 持久 pty per KCP 隧道连接
POSIX `posix_openpt` / Windows `CreatePipe`。命令间共享环境（`cd`/`export` 持久化）。

### ADR-2: MDELIM 退出码标记
`; echo MDELIM:$?\n` 嵌入 pty 输出。Host 侧 `lastIndexOf` 处理命令回显（macOS/BSD pty master 不支持 ECHO disable）。`pty_exec_done` 消息提供显式退出码冗余通道。

### ADR-3: 自复制安装模型
固定路径 `/opt/utmm/utmm`（POSIX）/ `C:\opt\utmm\utmm.exe`（Windows）。安装 = 无条件强制覆盖。升级 = scp 新二进制 + `--install`。

### ADR-4: 文档合并
DESIGN.md + release-skill/SKILL.md 合并到 CLAUDE.md。单文件覆盖架构到发布流程。

---

## 关键 Bug 及修复

### Finding 76: `Io.Event.reset()` 信号线程调用导致 unreachable panic（Critical）
`wake_event.reset()` 只能由等待线程调用。修复：从 `handleMeshGuest` 的 set()+reset() 中移除 reset()。

### Finding 77: `cleanupOpState` 自死锁（Critical）
`handleExec` 持 `state.mutex` 调 `cleanupOpState` 内部再次锁 → 自死锁 → 阻塞所有 exec + tunnelManager。修复：移除外层锁。

### Finding 79: tunnelManager 使用已释放 Tunnel 指针 segfault（Critical）
`state.mutex` 释放后 Tunnel 被其他线程释放。修复：在锁内完成 lookup + `isAlive()` 检查。

### Finding 89: `runCmd` 忽略命令退出码（Critical）
`runCmd()` 始终返回 `true`，不检查 `result.term`。修复：检查 `term == .exited and term.exited == 0`。

### Finding 90: macOS `cp` 破坏 ad-hoc 代码签名（Critical）
外部 `sudo cp` 复制二进制后 launchd 杀进程（`CODESIGNING Invalid Page`）。Phase 66 在 `selfCopy()` EXDEV 路径加入自动重签。

### Finding 91: `selfCopy` copy+delete 路径也破坏签名
Phase 66 修复：EXDEV 回退路径 copyFile 后自动 `codesign --force --sign -`。
**状态**: ✅ 已修复（commit `3c6d7d4`）

### Finding 92: `launchctl enable` 不足于清除 disabled 状态
需 PlistBuddy 删除 disabled.plist 条目。PlistBuddy 路径随 macOS 版本变化。

### Finding 94: 0xFF Keepalive 污染 KCP 数据通道（Critical）
periodicTasks 每 1s 发 `0xFF` keepalive，与 tunproto 消息混在同一通道。修复：`tunnel.zig` 的 `recv()` 和 `peekSize()` 同时过滤 0xFF。

### Finding 95: peekSize/recv 过滤不对称导致 BufferTooSmall 级联
修复：成对的 peek/read 方法保持过滤逻辑一致。

### Finding 96: macOS launchd 重试计数器永久累积
修复：mesh 启动成功后调用 `resetRetryCounter()` + 120s 时间窗口自动清零。

### Finding 97: 轮询测试模式替代固定等待
每 2s 尝试 exec，HTTP 200 即就绪。可靠性 70%→100%，典型就绪 ~8s。

### Finding 104: `setGuestMeshMac()` 定义但从未调用（Critical）
`mesh_mac` 永远为 null → `/ping` 始终返回 "guest not found"。修复：tunnelManager 注册 tunnel 后调用。
**状态**: ✅ 已修复

### Finding 105: `pingAndWait` 用事件计数器做超时
Phase 66 引入 `nowMs()`（`std.Io.Timestamp.now(.awake)`）提供真实毫秒。ping/pong 时间戳全部改用真实单调时钟。
**状态**: ✅ 已修复（commit `3c6d7d4`）

### Finding 107: SSH `--install` 不可靠 — pkill/taskkill 杀掉自身
`kill` 步骤会杀掉 SSH 会话中正在执行 `--install` 的进程。规避：手动 systemctl/launchctl/sc config。

### Finding 108: 升级后 Guest 丢失 hostname
pkill 中断导致服务配置未更新，Guest 用自动检测主机名。解决：升级后手动修复服务配置。

### Finding 109: `parseFileEof` type byte 污染导致 download 永久失败（Critical）
`file_eof` 分支传 `data` 而非 `data[1..]`，type byte `0x1D` 污染 cmd_id。修复：`parseFileEof(data[1..])`。
**教训**: 序列化/反序列化成对函数保持一致起始位置约定。

### Finding 110/112: macOS plist StandardErrorPath 必丢失
`--install` 重写 plist 时不含 `StandardErrorPath`。修复：`svc.zig:installMacOS()` plist 模板固化此字段。
**状态**: ✅ 已修复

### Finding 111: `cmdDownload` 双重 close 导致 unreachable panic
修复：移除显式 close，仅保留 defer 关闭。

### Finding 113: `handleMeshGuest` 缺少 `upload_result` (0x17) 处理
Host 日志 `unknown msg type 0x17` 刷屏。不影响功能（upload fire-and-forget）。
**状态**: ✅ 已修复（commit `98409c4`）

### Finding 114: httpd.zig 测试未被编译
httpd 在 Phase 61 废弃，此任务自动取消。

### Finding 120: 升级信号在命令循环中死锁（Critical）
升级检查只在外层循环，内层命令循环永不退出 → 升级信号死锁。修复：内层循环也检测 `upgrade.needed`。
**教训**: 嵌套事件循环中信号检查必须在所有层级都存在。

### Finding 121: Host 推送升级方案过度复杂且不可靠
v0.11.13 简化为 Guest 自主方案（Host 永不推送）。

### Finding 122: `tunnelManager` upgrading 特殊逻辑导致死锁
Host 等 Guest 建隧道、Guest 等 Host 建隧道 → 死锁。修复：统一 `m.connect()`。

---

## 已知问题

| # | 问题 | 状态 |
|---|------|------|
| 78/106 | 交叉编译覆盖 `zig-out/bin/utmm` — 部署前最后一个 build 必须无 `-Dtarget` | 📋 规避方案 |
| 107 | SSH `--install` 被 pkill 自伤 | 📋 规避方案（手动配服务） |
| 108 | 升级后 Guest hostname 丢失 | 📋 规避方案（手动修复） |
| 92 | macOS launchctl bootstrap 间歇 errno=2/5 | 📋 launchd 自动重启兜底 |
| 103 | Windows 优雅退出 | ⛔ 永久延迟（硬停止稳定） |
