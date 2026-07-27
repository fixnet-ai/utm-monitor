# Findings: v0.11.23

记录重要的技术发现、Bug、设计决策和 Zig 0.16.0 API 笔记。

---

## Phase 71: 版本号单文件管理 + GitHub 检测 (2026-07-28)

### Finding 130: `@embedFile` 路径必须位于 package 内
Zig 0.16.0 的 `@embedFile` 拒绝 `..` 路径遍历。文件必须在 `build.zig.zon` 的 `paths` 声明目录内。解决方案：`ver.txt` 放入 `src/`，`@embedFile("ver.txt")` 从 `src/protocol.zig` 同目录引用。

### Finding 131: `std.http.Client` 默认不跟随重定向
`RequestOptions.redirect_behavior` 默认为 `.not_allowed`（0 次）。GitHub API 频繁 302 → 需 `redirect_behavior = .init(5)`。

### Finding 132: `Response.reader()` 无法用于 GET 请求体
`Response.reader()` 内部检查 `!req.method.requestHasBody()`，对 GET 返回 `.ending`（空 reader）。因为 GET 的 `requestHasBody` 为 false，但 `responseHasBody` 为 true。变通：直接使用 `req.reader.bodyReader(&buf, req.response_transfer_encoding, req.response_content_length)`。

### Finding 133: `Io.Writer.stream()` 的 `limit` 参数类型为 `Io.Limit`
不是整数，需用 `.limited(n)` 或 `.nothing` / `.unlimited`。

### Finding 134: `host.zig` 测试从未被编译
`main.zig` 的 comptime 块未包含 `@import("host.zig")`，导致 `host.zig` 中所有 `test` 块从未编译进测试二进制。加一行后新增 7 测试（Platform/genInit/isValidVersion），总测试数 149→166。

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

---

## v0.11.17 部署测试发现 (2026-07-27)

### Finding 123 (CRITICAL): macOS 自动升级后服务永久停止

**现象**: Guest 下载升级成功，`utmm-new --install` 执行完成（日志显示 "--install ok"），但服务停止后不再重启。`launchctl list` 显示 `- 0 com.utmm.guest`（未运行，退出码 0）。

**根因分析**:
1. `pkill -9 -x utmm` 没有杀掉旧进程 — 旧进程打出了 "--install ok" 确认它存活
2. `forceInstall` 的 `start` 步骤（`launchctl bootstrap`）在 `bootout` 后失败（errno=5），服务未被加载
3. 旧进程 `exit(0)` → `KeepAlive SuccessfulExit=false` → launchd 不重启干净退出的服务
4. 结果：服务永久停止，需手动 `launchctl kickstart -k` 恢复

**修复方向**:
- `applyUpgradeAndRestart` 不应依赖旧进程被杀 — 旧进程可能存活
- `exit(0)` 与 `KeepAlive SuccessfulExit=false` 不兼容 — 升级后应 `exit(42)` 或修改 plist
- `start()` 中 `kickstart -k` 失败时应尝试 `bootstrap` 后再 `kickstart`

**状态**: ✅ 已修复 (Phase 74) — killAllUtmm PID 感知排除自身、start() bootstrap 重试、exit(0)→exit(42)

### Finding 124: 非 Linux Guest 隧道不稳定 — LSA restart 误判 (✅ 已修复)

**现象**: macvm/windowsvm/winx64 在 Host 重启后频繁 `pty_spawn` → `handler exiting` → `handler started` 循环。exec 返回 `exit=-1`（`failAllPendingOps` 因隧道断开而设置）。

**根因**: `mesh.zig:819` LSA restart 检测用 `std.mem.eql(u8, decoded.node_info, existing.node_info)` 全字符串严格相等比较。但 `node_info` 包含动态字段 `status:`（`serving` ↔ `upgrading`），Guest 进入自升级流程时先改 `status:upgrading`，立即触发 Host 侧 LSA restart → 所有 KCP 会话标记 dead → 隧道断。升级失败后恢复 `status:serving`，又触发一次 LSA restart。这形成了自毁循环：升级的第一步（改 status）就断了升级需要的隧道（KCP 下载通道）。

linuxvm 稳定是因为它的升级尝试无声失败，从未进入升级循环 → `status:` 从未改变 → 不触发 LSA restart。

**修复** (commit 待提交):
1. `parseEpoch()` 扩展为同时接受 `nonce:` 和 `epoch:` 键名（向后兼容）
2. 新增 `nonceChanged()` 辅助函数 — 比较 nonce 而非全字符串
3. `handleLsa()` 重启检测改用 `nonceChanged()` — 只有 genuine 进程重启（nonce 变化）才触发
4. `updateNodeInfo()` 每次更新时自动重新附加 `nonce:{self.nonce}` — 动态字段变化不丢失身份标识
5. `init()` 统一使用 `nonce:` 键名（替代 `epoch:`）

**设计原则**: 进程身份（nonce）≠ 进程状态（status/ip），LSA restart 检测只应依赖身份。

**补充修复**: 版本检测 (`upgrade.needed`) 扫描所有 LSA，未过滤 `role:host`。滚动升级期间已升级的 Guest（v0.11.18）看到其他 Guest（v0.11.17）的 LSA → 误触发升级信号 → 无限升级循环。修复：仅 `role:host` LSA 触发版本检测。

**状态**: ✅ 已修复

### Finding 129: 非 Linux Guest 隧道不稳定 — KCP 并发 connect() 状态不一致

**现象**: linuxvm exec 正常，但 macvm/windowsvm/winx64 的 exec 命令被 Guest 执行、输出通过 KCP 发送，但 Host CLI 收不到。Host 日志显示 keepalive dead 循环（每 ~3.5s），Guest 日志显示 `Tunnel dead (keepalive), reconnecting`。

**诊断过程**:
1. macvm Guest 日志确认命令已收到并执行（`echo hello_from_host` → `hello_from_host` 出现在 pty 输出中）
2. Guest 通过 `kcp_output` 发送了大的 KCP 数据包（93-159B），但 Host 只记录收到小包（38-61B 的 keepalive）
3. Host 的 `tunnelManager.connect()` 和 Guest 的 `handleKcpData` 可能创建竞态 KCP 会话

**推测根因**: Host 和 Guest 各自独立创建/重建 KCP 会话。`connect()` 创建全新 KCP 实例（seq=0），但 Guest 可能已有运行中会话（seq=N）。新 KCP 实例的数据因 seq 不匹配被 Guest 拒绝，旧会话因 keepalive 超时被 Host 丢弃 → 双向死锁。

**为什么 linuxvm 正常**: Linux 启动速度或网络时序差异使其侥幸避开竞态窗口。

**修复** (Phase 73, 2026-07-28):
- `m.connect()` 不再销毁旧 session + 使用 `session_gen` 计数器产生唯一 conv
- epoch 检查改为范围验证 `diff < 256`
- `waitForHostTunnel()` mutex 解锁移到 `Tunnel.init()` 之后
- `tunnel.deinit()` 加 `closeSession()` 消除泄露
- 验证: macvm exec 4/4 成功（之前 exit=-1）

**状态**: ✅ 已修复 (Phase 73)

### Finding 125: `nowMs()` RTT — 直连正确，中继异常

**现象**: 直接 ping/pong RTT 正确（2ms, 7ms），但中继 ping/pong RTT 为 uptime 级别（7 亿 ms ~ 13 亿 ms ≈ macOS 已启动天数）。

**分析**: `nowMs()` 使用 `std.Io.Timestamp.now(.awake)` 返回系统启动以来的毫秒数。直接 ping 由 Host 发时间戳、Guest 原样回传 → RTT = now - send_ts ≈ 正确。中继路径可能使用了不同的时钟源（`clock_ms` 事件计数器）或时间戳在某处被替换。

**状态**: 📋 已知，不影响核心功能（直接 ping 用于隧道 keepalive）

### Finding 126: DebugAllocator 泄漏 — `buildServiceArgs`

**现象**: 交叉编译的 debug 二进制在 `--install` 退出时报内存泄漏：
```
main.zig:396:35: dupe__anon in buildServiceArgs
main.zig:393:35: dupe__anon in buildServiceArgs
```

**影响**: 仅 debug 构建。ReleaseFast/ReleaseSafe 使用系统分配器无此问题。`--install` 调用 `exit(0)` 而非正常返回，这些泄漏实际上被 OS 回收。

**状态**: 📋 低优先级（仅 debug 构建）

### Finding 127: linuxvm 日志停止 + 升级下载无声失败

**现象**: linuxvm journal 从 Jul 25 07:52 后无任何日志（进程持续运行 2 天）。升级时 Host 成功发送 8MB 二进制，Guest 侧无任何反应 — 无临时文件、无日志、无错误。

**可能原因**: stderr 缓冲未刷新、日志级别变化、或进程在某种阻塞状态。升级下载在 `receiveUpgradeFile` 的 `tun.recv()` 中超时或 `file_eof` 未送达。

**状态**: 📋 待调查

### Finding 128: macOS `launchctl bootstrap` 在 bootout 后失败 (errno=5)

**现象**: `launchctl bootout system com.utmm.guest` 后立即 `bootstrap system /Library/LaunchDaemons/com.utmm.guest.plist` 返回错误 5 (Input/output error)。需先 `enable` 再 `bootstrap`，或使用 `kickstart -k`。

这是 Finding 92 的变体 — errno=5 是新的错误模式，不同于之前的 errno=2。

**状态**: 📋 规避方案（`kickstart -k` 替代 `bootstrap`）

---

## v0.11.23 自动升级全流程测试发现 (2026-07-28)

### Finding 135 (CRITICAL): linuxvm selfCopy 无法覆盖运行中二进制

**现象**: v0.11.23 自动升级测试中，linuxvm 通过 KCP 下载 `utmm-new` = v0.11.23 成功（12.6MB），`applyUpgradeAndRestart()` 执行 `utmm-new --install`。但规范路径 `/opt/utmm/utmm` 仍为 v0.11.22，`/opt/utmm/utmm-new` 为 v0.11.23。

**诊断**: 手动 `cp /opt/utmm/utmm-new /opt/utmm/utmm` 时得到 "Text file busy" 错误。服务进程持有的文件描述符阻止覆盖。

**根因分析**: `forceInstall()` 序列：stop → kill → selfCopy → install → start。步骤 1 (stop) `systemctl stop utmm-guest` 应停止服务，步骤 3 (selfCopy) 才复制二进制。但步骤 1 可能：
1. systemctl stop 返回成功但进程尚未完全退出（异步停止）
2. 旧进程未完全释放文件锁，selfCopy 时的 tmp+rename 路径成功但 copyFile 到规范路径失败
3. 16MB 二进制较大，selfCopy 时序窗口更长

**影响**: 自动升级半完成 — 新二进制已下载但未部署，Guest 继续运行旧版本。Host 侧认为升级成功（命令流正常），但下次 LSA 版本检测仍不匹配 → 无限循环尝试升级。

**修复** (Phase 74): `forceInstallInternal()` 在 stop() 后插入 `waitForProcessExit()`（5s 超时/100ms 轮询），确保 systemctl stop 异步退出完成后再 selfCopy。`killAllUtmm` 改为 PID 感知实现，排除自身。

**状态**: ✅ 已修复 (Phase 74)

### Finding 136 (CRITICAL): winx64 自动升级信号未检测到

**现象**: v0.11.23 测试中 winx64 全程未触发自动升级，`utmm --status` 显示仍为 v0.11.22 serving。其他三台 Guest 均检测到并尝试升级。

**可能原因**:
1. LSA 广播未到达 winx64（网络路径问题 — winx64 在 192.168.3.x 子网，其他 VM 在 192.168.64.x/65.x）
2. `upgrade.needed` 标志未被设置 — LSA 收到但版本比较逻辑未触发
3. winx64 的 `meshSessionLoop` 升级检测代码路径与其他平台不同
4. Guest 处于某种状态（如正在执行命令）导致升级检查被跳过

**影响**: 该 Guest 永远不会自动升级，需手动干预。

**状态**: 🔴 待调查

### Finding 137: windowsvm 自动升级 install 失败，优雅回退

**现象**: v0.11.23 测试中 windowsvm 通过 KCP 下载完成（~6MB），但 `applyUpgradeAndRestart()` 中的 `--install` 步骤失败。Guest 优雅回退到 v0.11.22 继续服务，未丢失。

**积极面**:
- Guest 未因升级失败而崩溃或失联
- 下载的二进制未破坏运行中服务
- 自动恢复到旧版本继续接受命令

**对比 macvm/linuxvm**: 两者升级失败后需要手动恢复，windowsvm 自动恢复 — Windows 的 .exe 文件锁定反而成了保护机制。

**状态**: 🟡 待调查（优雅回退是期望行为，但 install 失败根因需查）

### Finding 138: KCP 自动升级下载性能瓶颈

**现象**: 12.6MB 二进制下载耗时 13+ 分钟，有效吞吐仅 ~15KB/s。同时 Host 日志 `/var/log/utmm-host-err.log` 增长到 96MB。

**根因**: `[mesh-kcp]` 和 `kcp_output` 日志以 info 级别打印每个 UDP 数据包的收发细节。对于 12.6MB 文件传输，1200B/chunk → ~10,500 chunks → 每个 chunk 触发多条日志 → 数十万条日志行写入磁盘。磁盘 I/O 成为瓶颈，拖慢整个事件循环。

**修复方向**:
- 将 mesh KCP 数据包日志降至 debug 级别
- 或添加采样日志（每 N 个包打印一次）
- 文件传输进度日志应独立于数据包日志

**修复** (Phase 73, 2026-07-28): 3 条日志 `std.log.info` → `std.log.debug`。验证: 10 秒仅 3.5KB（之前 96MB）。

**状态**: ✅ 已修复 (Phase 73)

### Finding 139: Host 自 kill — `pkill -9 -x utmm` 杀死安装器自身

**现象**: 当 Host 二进制位于规范路径 `/opt/utmm/utmm` 时，`sudo /opt/utmm/utmm --host --install` 在 `forceInstall` 的 kill 步骤（`pkill -9 -x utmm`）中匹配并杀死了正在执行的安装器进程自身。进程在 selfCopy 之前即被终止，安装中断。

**规避方案**: 先将新二进制 `cp` 到规范路径（绕过 selfCopy），再用系统命令直接启动服务（绕过 `--install` 的 kill 步骤）。

**与 Finding 107 的关系**: Finding 107 描述了 SSH 远程执行 `--install` 时被 pkill 自伤的同一问题。Finding 139 确认此问题同样影响 Host 本地安装。

**修复** (Phase 74): `killAllUtmm()` 改为 PID 感知实现 — pgrep/tasklist 枚举 PID，过滤自身，kill -9 每个。pkill/taskkill /im 保留为 pgrep/tasklist 不可用时的回退。

**状态**: ✅ 已修复 (Phase 74)

### Finding 123 更新: rollback 修复验证

**原问题**: `forceInstallInternal()` 步骤 5（start）失败时触发回滚 — uninstall 服务配置 + deleteFile 删除二进制。自动升级场景中旧 Guest 进程已被步骤 2（kill）终止，回滚后 VM 彻底失联。

**修复内容** (Phase 72): 删除步骤 5 的回滚逻辑。start 失败时保留二进制和服务配置，仅日志 err + fail.err 退出。

**v0.11.23 测试验证**: macvm 上 launchctl bootstrap errno=2 后，二进制 v0.11.23 和 .plist 均保留。旧代码会删除两者 → VM 失联。修复生效。

**Phase 74 修复**:
1. `killAllUtmm()` 改为 PID 感知 — pgrep 枚举 + 过滤自身 PID + kill -9 每个，替代不可靠的 pkill
2. `start()` macOS 路径 — kickstart 失败后 500ms 延迟 + bootstrap 3 次重试（间隔 1s）
3. `exit(0)` → `exit(42)` — 非零退出码可靠触发 launchd/systemd 重启

**状态**: ✅ 已修复 (Phase 74)

---

## 已知问题

| # | 问题 | 状态 |
|---|------|------|
| **123** | macOS 自动升级后服务永久停止 | ✅ 已修复 (Phase 74) |
| **129** | 非 Linux Guest 隧道不稳定：KCP 并发 connect() 导致会话状态不一致 | ✅ 已修复 (Phase 73) |
| **135** | linuxvm selfCopy 无法覆盖运行中二进制（Text file busy） | ✅ 已修复 (Phase 74) |
| **136** | winx64 自动升级信号未检测到 | 🔴 待调查（网络隔离） |
| **137** | windowsvm 自动升级 install 失败，优雅回退 | 🟡 待调查 |
| **138** | KCP 自动升级下载性能瓶颈（~15KB/s，日志 I/O 阻塞） | ✅ 已修复 (Phase 73) |
| **139** | Host 自 kill：`pkill -9 -x utmm` 杀死安装器自身 | ✅ 已修复 (Phase 74) |
| 124 | 非 Linux Guest 隧道不稳定 | ✅ 已修复 (Finding 124) |
| 125 | `nowMs()` RTT 中继路径异常 | 📋 不影响核心功能 |
| 126 | DebugAllocator 泄漏 (`buildServiceArgs`) | 📋 仅 debug 构建 |
| 127 | linuxvm 日志停止 | 📋 待调查 |
| 128 | macOS bootstrap errno=5 在 bootout 后 | 📋 规避方案 |
| 78/106 | 交叉编译覆盖 `zig-out/bin/utmm` | 📋 规避方案 |
| 107 | SSH `--install` 被 pkill 自伤 | 📋 规避方案（手动配服务） |
| 108 | 升级后 Guest hostname 丢失 | 📋 规避方案（手动修复） |
| 92 | macOS launchctl bootstrap 间歇 errno=2/5 | 📋 launchd 自动重启兜底 |
| 103 | Windows 优雅退出 | ⛔ 永久延迟（硬停止稳定） |
