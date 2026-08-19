# Findings — UTM Monitor 技术发现

持续有效的技术发现、已知限制和 Zig 0.16.0 编码经验。

## 已知限制

| # | 限制 | 影响 | 状态 |
|---|------|------|------|
| 1 | Zombie 进程 | killChild 5s WNOHANG waitpid，D 状态子进程无法收割 | v0.18.36 已修复 |
| 2 | utmmd 二进制升级缺口 | push-upgrade 只替换 utmm，utmmd 需手动更新 | 已知 |
| 3 | Windows BIND 防火墙 | Windows Firewall 阻止 BIND 动态端口入站（非代码问题） | OS 限制 |
| 4 | zio 依赖本地路径 | build.zig.zon 用 path="../zio"，待 PR 合并后切 URL | 待 zio 上游 |
| 5 | macOS zig build test --listen=- hang | Zig 0.16.0 stdio 协议 bug，build.zig 用 manual Run.create 绕过 | 已知 |
| 6 | `upsert()` 不检查 MAC 变化 | 仅 cosmetic，路由用正确的 LSA node_id | 低优先级 |

## Zig 0.16.0 关键 API 差异

持续遇到的 API 差异，记录在此避免重复踩坑：

| 旧 API | 新 API | 备注 |
|--------|--------|------|
| `std.posix.socket` | `std.Io.net` | 网络 API 全面迁移 |
| `std.net` | `std.Io.net.IpAddress.parse()` | IP 解析 |
| `@Type` | `@Int`/`@Enum`/`@Struct`/... | 类型反射拆分 |
| `@cImport` | `@cInclude` | C 头文件导入 |
| `usingnamespace` | 显式 `pub const` | 重新导出 |
| `async`/`await` | 回调/libxev | 异步模型去除 |
| `.{}` 容器初始化 | `.empty` / `.init(allocator)` | 有状态容器不能裸初始化 |
| `std.io` | `std.Io` | 大写 I |
| `std.fs.openFileAbsolute` | `std.Io.Dir.cwd().openFile(io, ...)` | 需要 io 参数 |
| `ArrayList.append(x)` | `ArrayList.append(allocator, x)` | 需要 allocator 参数 |
| `file.close()` | `file.close(io)` | 需要 io 参数 |
| `file.read(&buf)` | `file.readStreaming(io, ...)` | 流式读取 |
| `file.writeFile(io, name, data, .{})` | `file.writeFile(io, .{ .sub_path=name, .data=data })` | Options 结构体 |
| `createDir(io, name, 0o755)` | `createDir(io, name, .default_dir)` | Permissions 枚举 |
| `std.os.windows.*` | `@extern("kernel32", ...)` | Windows API 直接声明 |
| `io.Writer` | `writer(io, &buffer)` | 需要 io + 缓冲区 |
| `rename(old, new)` | `rename(old_path, new_dir, new_path, io)` | 4 参数 |
| `system.read/write` | 返回 isize（非 error union） | 需 @intCast 且不能 try/catch |

### Windows 特定

- `socket_t = *anyopaque`（指针）→ `fd_set` 不能用 `{0}` 初始化，必须 `undefined`
- `BOOL` 是 enum → `0` 改为 `.FALSE`
- `FIONBIO` aarch64-windows 值 `0x8004667e` 超出 c_int → `@bitCast(@as(ULONG, ...))`
- `callconv(.winapi)` 解决 32 位 stdcall 符号修饰（64 位自动映射 `.C`）
- `GetLastError()` 返回 `Win32Error` enum → `@intFromEnum()`
- 动态加载 DLL（iphlpapi/fwpuclnt/dnsapi）→ 不能用 Zig mingw 静态库链接
- 文件 I/O 不能用 IOCP → 必须 `std.Io.Threaded`

### macOS 特定

- 交叉编译/scp 后 ad-hoc 签名损坏 → `codesign --force --sign -`
- pty master 不支持 `tcsetattr` ECHO 禁用 → 用 `lastIndexOf` 扫描 MDELIM 标记

### 命名规范（fixnet 生态）

- 类型 PascalCase、函数 camelCase、变量/字段 snake_case
- 缩写仅首字母大写：`IpAddr` 非 `IPAddr`，`TcpStream` 非 `TCPStream`

## 最近发现

### 2026-08-18 — 过路 pong RTT 错误归因（协议设计缺陷）+ 热路径日志刷 stderr

**症状**: daemon stderr 日志出现 `rtt=2997503534ms`（≈34.7 天）垃圾值；
`/private/var/log/utmmd-err.log` 以 ≈33MB/天 增长（曾堆 625MB）。

**根因（RTT）**: pong 帧 `[responder_mac:6][timestamp:4]` **无目标字段**。
中继 ping（guest A → Host → guest C）的 pong 按 `from`（= Host）直接回复，
Host 的 `handlePong` 无法区分「自己 ping 的应答」和「过路包」，把后者回显的
**A 的开机时钟**（`nowMs()` = awake-ms 截断 u32，各机不同）当自己的时间戳，
`nowMs() -% send_ts` = 两机开机时长差（15~20 天）→ 垃圾 RTT。
同时污染 `last_pong_*`，竞态下 `pingAndWait`（MCP ping 工具）返回垃圾值。
`-%` 回绕减法本身正确——错的是**来源归因**，不是算术。

**教训**: 无连接协议里「echo 回来的时间戳」只有在**能证明是自己发的**时才可信；
帧里没有目标字段时，接收方必须维护 outstanding 时间戳集合做归属校验。

**连带发现（38F）**: 周期 sweep 对非直连节点的中继 ping 是**纯死胡同流量**——
pong 按设计回中继点（`handlePing` 用 `from` 回包），发起者永远收不到应答，
RTT 从不可测量（该"特性"从未真正工作过）。修正为 sweep 只 ping 直连邻居。
若未来需要「发起者可测中继 RTT」，pong 帧须携带目标字段并支持回程中继——
属协议演进，当前无消费方，不做。

**根因（日志）**: periodicTasks 每 ~60 tick 对全部节点 sendPing，每条
ping/pong/中继都打 info 级 → ReleaseSafe std.log 默认 .info 全量输出到
stderr → launchd StandardErrorPath 无轮转无限增长。热路径探测日志应为 debug 级。

### 2026-08-17 — MCP exec 输出丢失根因（Bug 1 + Bug 2）

**症状**: 经常发生 MCP 响应 `content[0].text` 中 stdout 为空、exit_code=-1。

**根因 1（主因）— 单帧 64KB 上限**: Guest 端把 pty 输出全量累积在内存 ArrayList，
MDELIM 标记命中后才打包成**一个** `pty_exec_output` 帧发送（`guest.zig:1112-1117`）。
Host 端 `execOnGuest` 接收缓冲只有 65536 字节（`mcp_handler.zig:91`），
`protocol.Connection.recv` 帧长超缓冲返回 `error.BufferTooSmall`（`protocol.zig:745`），
`execOnGuest` catch-all break（`mcp_handler.zig:96-100`）→ 返回空 output + exit -1。
任何输出 >64KB 的命令（编译错误刷屏、cat 大文件、测试失败日志）stdout 整体消失。
CLI（IPC）路径走同一个 `mcp_handler.execOnGuest`（`ipc.zig:657`），同样受影响。

**根因 2 — shell 异常退出丢弃已累积输出**: Guest 读循环因 `shell.read` EOF/错误退出且
MDELIM 未命中时，只发 `pty_exec_done(-1)`，`accumulated` 里的输出从不发送
（`guest.zig:1127-1131`）。触发场景：命令含 `exit`、shell 被杀、pty read 错误。

**次要发现**: Windows cmd.exe `& echo MDELIM:%errorlevel%` 的 `%errorlevel%` 在整行
**解析时**展开，恒回显 0（`protocol.zig:603`）— 退出码永远 0，不影响 stdout 展示。

**教训**: 帧缓冲大小必须与对端单帧大小解耦（流式分块发送）；catch-all break 吞掉
`BufferTooSmall` 违反"error.Unexpected 视为致命"铁律，把数据丢失伪装成正常结束。

### 2026-08-17 — download_result 哈希悬空切片（真机抓到，测试未覆盖）

`parseDownloadResult` 返回的 `sha256_hex` 是接收缓冲 `rbuf` 的切片；随后
`rbuf` 被 sockRead 循环复用读文件数据，比对时期望哈希已被覆盖成文件内容 →
真机上每次 download 都 HashMismatch（乱码 expected）。本地测试没抓到：
test_download_e2e 是协议级 loopback 模拟器，不走真实的
`mcp_handler.downloadFromGuest` / `ipc.zig handleDownload` 接收路径。
修复：解析后立即把 64 字节 hex 拷贝到固定缓冲（commit ebca5ce）。

**教训**: 帧解析结果的生命周期与接收缓冲复用必须成对审查；协议级模拟测试
无法覆盖真实接收函数的缓冲复用 bug，真机 smoke 验证不可省。

### 2026-08-17 — macOS adhoc codesign 破坏 utmmd 哈希比较 → 每次 CLI 触发升级循环（Phase 37 根因）

**症状**: 每次 `sudo utmm --status/--exec/--upgrade` 输出开头都打
"utmmd upgrade: utmmd-new → utmmd" + Host 日志每次出现 "ipc listening"
（utmm 重启）；CLI --status 只显示 host 不显示 guests；升级推送间歇
IpcNotRunning/ConnectFailed（10-30s 窗口）。

**根因链**:
1. 部署流程（forceInstall/replaceFileSafe）在 macOS 上对 utmmd 做
   `codesign --force --sign -`（adhoc，Phase 35 引入修复 SSH 部署签名损坏）
2. **adhoc 签名非确定性**：同内容两个副本独立签名 → 不同哈希（实测 a1b3... vs 58a3...）；
   同一文件重复签（"replacing existing signature"）幂等
3. **remove-signature 不可逆**：codesign 签名过程修改 Mach-O 结构
   （LC_CODE_SIGNATURE 等），剥离后字节级与原始未签名文件不同
   （实测 roundtrip a0846b26 → bddd5a93 → aea2ba71）
4. `shouldUpdateUtmmd` 比较磁盘 utmmd 哈希 vs 内嵌未签名 .sha256 →
   **永远不匹配** → 每次 CLI 都执行 upgradeUtmmd（disable→kill→replace→
   enable→start）→ utmmd/utmm 重启 → LSA nonce 变 → mesh 抖动 → 
   status 显示空 guest 表（查询恰好撞上重启窗口）

**修复** (9390a50): macOS 上 `shouldUpdateUtmmd` 恒返回 false——macOS 的
utmmd 升级由 `--install`（forceInstall 提取新 utmmd）显式完成，跳过隐式检查。
Linux/Windows 无签名，保留哈希比较。

**验证**: 连续 3 次 status 零 upgrade 日志、4 台 Guest 完整显示、
Host utmm PID 稳定、4 台 VM 升级推送全部一次成功（此前必撞 IpcNotRunning）。

**教训**: 对二进制文件做哈希比较时，任何后处理（签名、strip、打包）都会
破坏可比性。签名类操作（codesign）在 macOS 部署链上是刚需（Phase 35），
哈希比较必须在签名**之前**或使用签名不变的内容摘要（CDHash 也因随机
identifier 不可用）。

### 2026-08-17 — 升级后 mesh 瞬态窗口（GuestNotFound/ConnectFailed 间歇）

~~Host forceInstall 期间 utmm/utmmd 重启 → LSA nonce 变化 → node table
短暂缺失节点。窗口约 10-30 秒。~~ **已定位真根因**：每次 CLI 管理命令
触发 utmmd 升级循环（见上一条"macOS adhoc codesign 破坏哈希比较"），
Host utmm 随每次 CLI 重启。Phase 37 修复（9390a50）后此现象消失——
升级推送 4 台全部一次成功，无 IpcNotRunning。

### 2026-08-17 — ipc.zig 测试从未运行（standalone_test_modules 遗漏）

`build.zig` 的 `standalone_test_modules` 列表（dpipe/dpipe_shell/dpipe_file/guest/shm/utmmd）
没有 ipc.zig，而 ipc.zig 的 6 个测试（readFull EAGAIN、writeAll、upload header 边界等）
也不在主测试二进制的 import 链里被收集——**这 6 个测试从写出来起就从未运行过**。
36C 加第 7 个测试（ExecIpcSink 帧编码）时发现测试数不变才暴露。已把 ipc.zig
加入 standalone 列表（commit 9ad72e5），7 个测试全过。

**教训**: 新增测试后必须确认测试数变化；`zig build test` 的结果缓存会让
"没跑测试"看起来像"测试通过"，用 `--summary all` 或检查测试名列表。

### 2026-08-17 — 手动删 .zig-cache 产物破坏缓存清单

删除 `.zig-cache/o/*/test` 二进制后，zig 报 `file_hash FileNotFound`（缓存元数据
引用已删文件），7 个 run test 步骤全部失败。正确做法：整个删 `.zig-cache`
目录重建，不要只删产物文件。

### 2026-08-17 — test_upload_e2e 二进制 hash 传参（已修复 dfa863b）

`test_upload_e2e.zig` 4 处 `buildUploadCmd` 传 32 字节二进制 SHA256，而
`buildUploadCmd` 用 `writeString`（null-term）序列化——哈希含 0 字节会截断。
模拟器比对也是逐字节二进制比对，与生产语义（hex 字符串）不一致。
修复：调用点转 hex，模拟器 hex 字符串比对。生产代码（mcp_handler/ipc）传参本就正确。

### 2026-08-17 — download 无端到端哈希校验（协议不对称）

upload 方向有完整校验（cmd 头带 file_size+sha256 → Guest 边收边算 → 读满校验 →
原子 rename）。download 方向无任何校验：Guest 流式发原始字节，Host 读到 EOF 即停，
无长度、无哈希 trailer。IPC 协议 `download_done` 的 hash 字段恒为空（`ipc.zig:928`）。
中间设备损坏/截断无法检测。

### 2026-08-17 — exec 输出已合并 stdout+stderr（验证确认）

- POSIX: `dup2(slave, 0/1/2)`（`dpipe_shell.zig:119-121`）— stdout+stderr 均进 pty。
- Windows: `si.hStdError = stdout_write`（`dpipe_shell.zig:232`）— stderr 与 stdout
  合并进同一管道。
- sshpass 工具例外：stdout/stderr 分开收集，响应中 stderr 单独代码块（`mcp.zig:694`）。
  保持分开（信息无损），不合并。

### 2026-08-13 — Windows 命名共享内存：CloseHandle(CreateFileMappingW) 移除对象名字

**症状**: Guest 的 `OpenFileMappingW("Global\utmmd-shm")` 返回 ERROR_FILE_NOT_FOUND (2)，
`shm_handle=null`，Guest 无心跳、无升级路径。Windows `--upgrade` 永远不生效。

**根因**: `createWindows` 在 `MapViewOfFile` 后调用了 `CloseHandle(h)`，注释错误地认为
"映射持有引用"。实际上 Windows 上关闭 `CreateFileMappingW` 句柄会**移除命名对象的名字**
（即使视图还映射着），导致后续 `OpenFileMappingW` 找不到。

**修复**: 不关闭句柄 `h`，让它随 utmmd 进程生命周期存活（进程退出时 OS 自动清理）。
泄漏一个句柄，换取命名对象全程可见。

**教训**: Windows 命名内核对象（section/mutex/event）的**名字**和**对象本身**生命周期不同。
名字在对象销毁时从命名空间移除，而对象由"句柄 + 视图"共同持有引用。关闭句柄即使视图
还活着，也可能导致名字提前失效。跨进程共享务必保持创建句柄打开。

### 2026-08-13 — SHM 跨进程共享内存必须用 @atomicStore/Load

`writeCmdPath` 最初用 `@memcpy` 写 `*volatile` 共享内存，`readCmdPath` 用普通读。
volatile 只防编译器缓存，不提供跨进程内存屏障。改为逐字节 `@atomicStore(.monotonic)` +
`.release` 终止符，读取侧 `@atomicLoad(.acquire)`，确保 Guest 写的路径对 utmmd 可见。

### 2026-08-13 — O_NONBLOCK 硬编码 macOS 值（历史遗留，已修复）

`tcp.zig` 的 `O_NONBLOCK = 0x0004` 是 macOS 值，Linux 应为 `0x800 (04000)`。
导致 Linux 上 TCP listen socket 实际阻塞，`accept()` 不再返回 WouldBlock，心跳停止更新，
utmmd 每 ~10s 误杀 utmm（crash-loop）。修复为按平台区分常量。

### 2026-08-12 — POSIX fcntl/socket 常量跨平台不兼容：SO_REUSEADDR 硬编码导致 Linux BindFailed 崩溃循环

**症状**: TCP :2121 间歇性 BindFailed (errno=98/EADDRINUSE)，UDP LSA 正常但所有 SOCKS5 连接失败。

**根因**: `tcp.zig` 中三个 POSIX 常量硬编码为 macOS 值，Linux 上完全错误：

| 常量 | macOS | Linux | 后果 |
|------|-------|-------|------|
| `SO_REUSEADDR` | `0x0004` | `2` | setsockopt 静默无效 |
| `SOL_SOCKET` | `0xffff` | `1` | setsockopt 静默无效 |
| `F_GETFD` | `2` | `1` | fcntl 清除而非设置 FD_CLOEXEC |
| `F_SETFD` | `3` | `2` | fcntl 执行错误操作 |

加上 `_ =` 丢弃返回值 → 全部静默失败，日志无任何警告。用了数月的代码从未在 Linux 上正确工作过。

**教训 — 跨平台 POSIX 常量铁律**：
1. **所有 `setsockopt`/`fcntl` 常量必须使用 `std.posix` 命名空间**（`std.posix.SOL.SOCKET`、`std.posix.SO.REUSEADDR`、`std.posix.F.GETFD`、`std.posix.F.SETFD`、`std.posix.FD_CLOEXEC`）
2. **绝不禁用返回值检查** — `_ = setsockopt(...)` → 必须 `if (setsockopt(...) < 0) { log errno }`
3. **每个新增的 OS 常量必须先验证跨平台值**，对照 Linux/macOS/Windows 三个平台的系统头文件

**额外发现**：`O_NONBLOCK = 0x0004` 同样是硬编码的 macOS 值（Linux 应为 `2048=04000`），**v0.18.45 已修复**（按平台区分常量 + 全部 F_GETFL/F_SETFL 改用 std.posix.F）。

### 2026-08-03 — 部署体验审计

审计 `docs/deploy-ux-audit.md`，识别 8 个用户部署障碍。P0（VM 凭据硬编码 + Windows --deploy 空操作）已修复。P1（zio 依赖文档 + deploy 缓存）已修复。详见审计文档。

### 2026-08-03 — deploy.json 配置加载

`loadDeployConfig()` 使用 `std.json.Value` 动态解析（与 mcp.zig 一致模式），错误宽松处理：文件缺失/格式错误 → 日志警告 + 回退编译时默认值。`@intFromPtr` 区分堆分配 vs 编译时常量指针。

### 2026-08-11 — Windows --upgrade 二进制替换崩溃根因

**症状**: `--upgrade` 推送到 Windows Guest 后，Host 显示 `[upgrade] OK`，但 utmmd
在尝试替换 utmm.exe 时崩溃（SCM exit 1067），升级实际未生效。

**根因 1 — 文件替换策略不兼容 Windows**:
`deleteFile(utmm.exe) + rename(.tmp, utmm.exe)` 在 Windows 上失败，因为
TerminateProcess 后 OS 可能仍在短时间内保留 exe 文件锁定。deleteFile 静默失败
（catch {}），rename 因目标仍存在而失败。10 次重试后升级被放弃。

**根因 2 — 进程句柄关闭导致 crash-loop**:
`killProcess` 在 `tryApplyPendingUpgrade` 中调用 `CloseHandle` 关闭进程句柄。
返回 `monitorUtmm` 后，`isProcessAlive(proc)` 因句柄已关闭而返回 false
→ 误判 utmm 崩溃 → 返回 .crashed → monitorLoop 启动**旧**二进制（升级未应用）
→ .tmp 文件仍在 → 下次循环再次杀→替换失败→句柄关闭... → 无限 kill-restart 循环
→ 超过 MAX_FAILURE_COUNT(5) → utmmd 退出 → SCM exit 1067。

**修复**:
1. Windows 上用 `MoveFileExW` 先 rename 旧 exe → .old（Windows 允许 rename 打开的文件），再 rename .tmp → 目标
2. `killProcess` 不再关闭句柄，由 `monitorUtmm` 的 `defer closeProcessHandle(proc)` 统一清理
3. `handleUpgradeCmd` 接收完成后通过 shm 设置 `.restart` 通知 utmmd 立即处理，消除轮询延迟
4. macOS codesign 移到 rename 成功后统一执行（之前只在 CrossDevice 回退路径执行，覆盖不全）

### 2026-08-02 — zio 网络 errno 映射缺失

`zio/src/os/net.zig` 中 5 个 errno 映射函数缺少 `NETDOWN`/`HOSTUNREACH`/`NETUNREACH` 等导致返回 `error.Unexpected`。已修复并推送 fixnet-ai/zio `feat/x86-32` 分支。PR #646 等待上游 re-review。

### 2026-08-02 — x86 32-bit 协程支持

zio coro/coroutines.zig 新增 `.x86` 架构支持（IA-32 cdecl、AT&T 汇编、16 字节栈对齐）。初版仅 Linux musl，Windows 需额外 TIB 支持。8/8 交叉编译目标已通过。

### 2026-08-12 — findUpgradeTmpPosix 静默失败：事件循环 Io 不支持文件操作

**症状**: linuxvm Guest 收到 `--upgrade` 推送后 utmm-upgrade.*.tmp 文件正常写入，
但 utmmd 持续报告 "no tmp found, return null"，升级永远不生效。重启 utmmd 服务后同样失败。

**根因**: `utmmd.zig` 的 `monitorLoop` 中 `need_threaded = builtin.os.tag == .windows`，
在 POSIX 上 `file_io` 直接复用事件循环 Io（epoll/kqueue）。`findUpgradeTmpPosix` 调用
`std.Io.Dir.openDirAbsolute(io, ...)` 时，epoll-based Io 无法执行文件系统操作，
调用静默失败（`catch return null`），导致 .tmp 文件永远不会被发现。

macOS kqueue 碰巧支持 `openDirAbsolute`（因为 kqueue 对文件描述符的兼容性更好），
所以 macvm 升级正常。Linux epoll 不支持，导致 linuxvm 升级失败。

**修复**: `utmmd.zig` — 所有平台始终创建 `std.Io.Threaded` 实例用于文件操作，
不再复用事件循环 Io。`need_threaded` 变量移除。

**教训**: 事件循环 Io（epoll/kqueue/IOCP）是为网络 I/O 设计的，文件系统操作
（openDirAbsolute、rename、deleteFile 等）必须使用 Threaded Io。这个限制不是
Windows 特有的 — 所有平台都需要。

### 2026-08-12 — WIN32_FIND_DATAW struct 布局 + FindFirstFileW 替代 Zig Io walker

#### WIN32_FIND_DATAW FILETIME 对齐陷阱

Windows `WIN32_FIND_DATAW` 结构体中 `FILETIME` 是 `struct { DWORD low; DWORD high; }`
（align=4），**不能用 `u64`(align=8) 替代**。在 aarch64-windows 上 `u64` 的 8 字节
对齐要求会在每个 FILETIME 后插入 4 字节 padding，导致后续字段（`cFileName`）偏移量
比 Windows ABI 预期多出 12 字节（3 个 FILETIME × 4 字节）。

**正确声明**：
```zig
const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    _ftCreationTimeLow: u32,
    _ftCreationTimeHigh: u32,
    _ftLastAccessTimeLow: u32,
    _ftLastAccessTimeHigh: u32,
    _ftLastWriteTimeLow: u32,
    _ftLastWriteTimeHigh: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
```

**关键教训**：跨语言/跨平台的 C ABI struct 声明不能凭猜测。必须对照参考实现
（MSDN 文档 + C 头文件）逐个字段验证大小和对齐。在 x86_64-windows 上 `u64` 碰巧
工作（因为 8 字节对齐本就存在），但在 aarch64-windows 上就会出错。

#### std.Io.Dir.walk() + Threaded Io 不兼容 Windows

Zig 0.16.0 的 `Threaded` Io 在 Windows 上不支持目录迭代：
- `openDirAbsolute` — 正常工作（可以打开目录句柄）
- `dir.walk(allocator)` — 正常工作（可以创建 walker）
- `walker.next(io)` — **始终失败**（Threaded Io 不支持）

**解决方案**：直接使用 `FindFirstFileW`/`FindNextFileW` kernel32 API 绕过 Zig Io 层。

**UTF-16 文件名处理**：
- 搜索路径：`utf8ToUtf16Le` + 手动 null-terminate
- 读取文件名：`sliceTo` 找到 null terminator → `utf16LeToUtf8`
- `bufPrintZ` 自动在格式化字符串末尾追加 null byte

**注意**：这应该是临时方案。Zig 0.17+ 如果修复了 Threaded Io 的 Windows 目录迭代，
应该恢复使用 walker。

#### build.zig: Windows utmmd 用 Debug 优化

交叉编译到 aarch64-windows 时：
- `ReleaseSafe`: 崩溃 exit 1067（SCM 服务崩溃）
- `ReleaseSmall`: c0000005 ACCESS VIOLATION in ucrtbase.dll
- `Debug`: 正常工作（utmmd 仅 ~429KB，性能影响可忽略）

这是 Zig 0.16.0 交叉编译器的 bug，仅影响 aarch64-windows target。

### 2026-08-18 — VM_DEPLOY_TABLE 硬编码 IP 过期（--deploy SSH 3/4 失败根因）

**症状**: `utmm --deploy` 对 macvm/linuxvm/windowsvm SSH 超时，仅 winx64 成功。

**根因**: host.zig `VM_DEPLOY_TABLE` 兜底表（无 deploy.json 时生效）的 IP 是
旧拓扑：linuxvm .2（实 .6）、macvm .64.4（实 .65.4）、windowsvm .65.2（实 .64.3）。
SSH 本身正常——IP 修正后 4/4 部署成功。

**教训**: VM 的 DHCP 地址会变；硬编码兜底表要么定期与 mesh 实况核对，
要么优先用 deploy.json 覆盖。mesh 推送通道（--upgrade）不依赖这些 IP，
是 IP 漂移时更可靠的升级路径。

### 2026-08-18 — utmmd Windows 端 debugLogWindows 热路径写盘（待修）

**症状**: Windows Guest 的 `C:\opt\utmm\utmmd-debug.log` 持续增长（winx64 实测
88 B/s ≈ 7.4MB/天；两台 Windows VM 清理前各积 23~25MB）。

**根因**: `utmmd.zig` 的 `debugLogWindows`（Phase 33 排障期遗留）用 kernel32
WriteFile 直写 `utmmd-debug.log`，monitorLoop 每次迭代打多条
（before/after tryApplyPendingUpgrade、startUtmm 等）。Windows 服务 stdout
不可见（已知限制 #2），它是当时唯一的调试通道，但从未在排障结束后移除。

**修复方向**: 排障日志应 comptime 门控（debug 构建才编译）或仅在升级/异常
路径保留——monitorLoop 稳态循环内的逐行 trace 必须去掉。升级事件本身
（tryApplyPendingUpgrade 命中/失败）可保留，属低频生命周期事件。

**连带**: 本次清理同时删除了 serve-dir 的 386 个旧版本二进制 + 8 个
unversioned 残留（deploymentFilename 只读带版本文件名，unversioned 从不
被引用）+ 调试垃圾文件，本机 /opt/utmm 3.4GB → 62MB（仅留 canonical
utmm/utmmd + 当前版本 ×8）。

### 2026-08-18 — Windows guest 重启循环双根因（心跳冻结 + deploy 绕过安装器）

**根因 1 — 监听 socket 漏设 FIONBIO**: `TcpListener.init` 的 POSIX 分支设
O_NONBLOCK（accept 空闲返回 EAGAIN → 循环 10Hz 轮转刷心跳），Windows 分支漏设
对等的 FIONBIO → `ws2_accept` 永久阻塞 → accept 循环（顶部写 shm 心跳）停摆 →
utmmd 10s 心跳超时杀 utmm。**LSA 在独立线程照常广播，--status 一切正常，完全
掩盖了每 ~10s 一次的杀死循环**（winx64 utmm PID 持续变化才发现）。
sockAccept 还把 WSAEWOULDBLOCK 一律当 AcceptFailed，即使设了非阻塞也走不到
轮转路径。两处都修后与 POSIX 行为对齐。

**教训**: ① 心跳这类活性信号禁止依赖「可能阻塞的循环」的迭代频率——要么循环
保证非阻塞轮转，要么独立线程定时写。② 同一逻辑的跨平台分支（POSIX/Windows）
必须逐项核对 socket 选项设置，一分支有的选项另一分支漏设 = 平台特有死锁。
③ 掩蔽效应：多线程架构下一条线程死亡不等于进程死亡，表面功能正常（LSA/exec
都活着）不代表监督心跳还在写——心跳路径必须独立可验证。

**根因 2 — deploy Windows 分支绕过安装器**: SSH 安装命令只做
`sc stop → taskkill → move utmm.exe → sc start`，从不跑 `--install`，而 utmmd 的
提取/哈希比较/替换逻辑全在 forceInstall 里。POSIX 分支一直正确（chmod +x &&
utmm-new --install）。后果：**Windows 两台 VM 的 utmmd 自 08-12 起从未更新**，
utmm/utmmd 版本漂移六天无人察觉。修复：Windows 对齐 POSIX 跑完整安装器。

**教训**: 同一功能（deploy 安装）的跨平台双实现必须共享语义核心——两分支
各自手写命令序列必然漂移；「部署成功」的判定标准应包含关键文件的时效验证
（如 utmmd.exe mtime），本例中若有此检查六天前就会报警。

### 2026-08-19 — Windows 中文乱码机制实锤 + ConPTY 通解验证（Phase 41 前置调查）

**乱码双路径实锤**（winx64，中文系统 InstallLanguage=0804/OEM=CP936）:
1. **输出路径**: ipconfig 等老命令用 ANSI API 输出，**无视 chcp 65001** ——
   抓 MCP 原始响应字节 = GBK 原样透传（`Ethernet adapter \xd2\xd4\xcc\xab\xcd\xf8`
   =「以太网」），JSON 变 invalid UTF-8。chcp 只改 console CP，管不到命令输出编码；
   utmm 链路（jsonEscape 等）纯字节透传不转码。chcp 936 下同样 GBK → 改代码页治不了。
2. **输入路径**: chcp 65001 下 cmd 对管道 stdin **逐字节解码** —— agent 发
   `echo 中文`（6 字节 UTF-8），Guest 返回 6×U+FFFD（每字节独立替换）。
3. net user 在 65001 会话行为异常（丢机器名 + "one or more errors"，65001 下
   net.exe 已知病症）。

**ConPTY 通解验证**（微软契约: 输入管道 UTF-8 → INPUT_RECORD；输出统一 UTF-8 VT）:
ConPTY 内部 console 默认 CP = 系统本地 OEM（中日韩自动匹配）→ 老命令本地编码
被正确解码 UTF-16 → 输出统一 UTF-8，**宿主无需知道目标内码**。实机对照（同一
`ipconfig /all`）: utmm exec（pipe+chcp 65001）❌ GBK；`ssh -T`（sshd 纯管道）❌ GBK；
`ssh -tt`（sshd 内部创建 ConPTY）✅ **valid UTF-8 + 字节级正确「以太网」+ 全中文
标签正常**。sshd 本身是 Session 0 服务 → 服务环境创建 ConPTY 有生产先例。

**exit_code marker bug**: `buildCmdWithMarker` Windows 分支 `{s} & echo
MDELIM:%errorlevel%` —— 交互式 cmd **整行解析时展开** %errorlevel%（执行前）
→ marker 报旧值。实测 `cmd /c exit 7 & echo EXPANDED=%errorlevel%` → `EXPANDED=0`。
影响: Windows 所有命令 exit_code 恒 0（`nonexist_command_xyz` 也报 0）。
修法: marker 独立成行 `{s}\r\necho MDELIM:%errorlevel%\r\n`（cmd 逐行读取，
读到 marker 行时上一行已执行完，展开新值）。

**CreateProcessW 无 per-process 编码/语言参数**: dwCreationFlags 与
STARTUPINFOEX 属性列表均无编码相关项；CRT 代码页从系统 locale 继承、MUI 语言
从用户配置继承，均不能按进程覆盖。系统级唯一开关 = 控制面板「Beta: Use
Unicode UTF-8」（全局 + 重启）。per-process 控制台编码的唯一现代机制就是 ConPTY。

### 2026-08-19 — ConPTY 在 Session 0 服务链不可用（Phase 41 排障记录）

**现象**: spawnWindowsConpty 全链 API 成功（CreatePipe/CreatePseudoConsole S_OK/
attr list/CreateProcessW 返回 pid，cmd 进程 STILL_ACTIVE）但 cmd **零输出、
不执行 stdin 命令**（探针文件不出现）——attach 伪控制台失败。

**排查矩阵**（5 个实现变体 + 2 个环境全部失败）:
- 变体: sa.bInheritHandle=TRUE/FALSE × bInheritHandles=TRUE/FALSE × 立即关/
  不关 PTY 端句柄 × cmd/powershell × 微软 EchoCon 示例精确复刻（sa=NULL +
  CreatePseudoConsole 后立即关 PTY 端 + FALSE）——全部同样症状。
- 结构体布局已验证正确（STARTUPINFOW=104/STARTUPINFOEXW=112/HANDLE=8）。
- 环境: sshd 用户会话跑 standalone 失败；schtasks SYSTEM 任务同样失败（stdin
  命令能到达 cmd 执行、stdout 管道读不到输出 → 读循环挂）。
- 对照: `ssh -tt`（sshd 内部建 ConPTY）同机工作正常（UTF-8 中文正确），Session 0
  也有 conhost 运行——**sshd 的成功机制未复现**（OpenSSH conpty.c 未定位到）。

**连带发现**:
1. sshpass.zig runWindowsConpty 的属性列表从未挂进 STARTUPINFOEXW（startup_info
   是裸 STARTUPINFOW，attr_list_buf 独立变量，cb 只声明 STARTUPINFOW 大小）——
   该「ConPTY 模式」从未真正走 ConPTY，一直靠密码提示匹配的 pipe fallback 工作。
2. `--upgrade` 推送显示 OK 但 utmmd 不实际替换二进制（同日两次复现）——版本
   升级期间一律 scp + `--install` 通道。

**教训**:
1. **部署纪律**: 未在单机验证的实现绝不全量 deploy——本次 ConPTY 版直接推 4 台，
   导致 Windows exec 全挂 + 心跳冻结崩溃循环 + 孤儿 cmd 堆积（windowsvm 疑似
   因此资源耗尽死机重启）。正确顺序: standalone 验证 → 单机验证 → 全量。
2. **挂起的 exec 是全局毒药**: Guest exec read 永久阻塞 → 心跳冻结 → utmmd 杀
   utmm 循环；且 Host 侧等待线程堆积可拖死 MCP 线程池（status 正常但 upload/
   exec 全超时——LSA/UDP 独立线程掩盖 TCP 侧死亡，排查时勿被 serving 状态迷惑）。
3. **升级验证三要素**: 推送后必须核对磁盘 utmm.exe 的 **mtime + size + 行为**，
   `[upgrade] OK` 只代表字节送达。

**最终方案**（已实施 v0.18.79）: pipe + cmd.exe /k（会话保持本地 OEM）+
dpipe_shell 双向转码（输出 GetOEMCP→UTF-8 / 输入 UTF-8→GetOEMCP，DBCS/UTF-8
跨块 pending）。真机验证: ipconfig「以太网」/中文标签全部正确 UTF-8、
exit 7/9009/5 传播、UTF-8 中文输入正确回显、&&/|/net user 中文正常。

## 2026-08-19 (Phase 42) — CI 失败根因 + SignPath 调研

**CI 失败根因**（`gh run view 32201183126 --log-failed`）:
```
unable to open '/Users/runner/work/utm-monitor/utm-monitor/../zio': FileNotFound
error: the following build command failed with exit code 1 (zig build test)
```
`build.zig.zon` 声明 `.zio = .{ .path = "../zio" }`（fork 注释：x86-32 支持在
fixnet-ai/zio feat/x86-32 分支，等 PR #646 合并后转上游 URL）。CI checkout
只拉本仓库 → sibling 目录不存在 → `zig build test` 必挂。**连续 15+ 次 tag
发布 CI 全部 failure**（v0.18.36 起），此前发布实际全靠本地 release.sh，
GitHub Releases 上的 utmm.zip 是本地构建的。

**zio fork 状态**: fixnet-ai/zio PUBLIC，分支 feat/x86-32 存在（本地即该分支，
HEAD 5907d1f "fix: address PR #646 review feedback"）。CI 修复 = checkout 后
`git clone -b feat/x86-32 https://github.com/fixnet-ai/zio.git ../zio`。

**SignPath 调研结论**（docs.signpath.io/trusted-build-systems/github）:
- OSS 免费：OV 证书签给 SignPath Foundation（非个人），条件之一是 **OSI 开源
  许可证、无商业双许可** → 本仓库缺 LICENSE，必须先补（用户选 MIT）
- Trusted Build System 机制：GitHub App 验证 origin 不可伪造；artifact 必须
  先经 actions/upload-artifact 存在 GitHub 服务器上；**OSS 要求全部前置 job
  在 GitHub 托管 runner**（macos-latest 满足）
- workflow 用法：`upload-artifact@v7` → `SignPath/github-action-submit-signing-request@v2`
  （api-token / organization-id / project-slug / signing-policy-slug /
  github-artifact-id / wait-for-completion: true / output-artifact-directory）
  → action 自动下载解压签名后产物
- 签名范围决策：**只签 3 个 Windows .exe**（Authenticode 消 SmartScreen/杀软
  误报——远程调试工具无签名最易被标记）。macOS 保持 adhoc（自部署 VM 场景
  够用，SignPath macOS 签名需自备 Apple 开发者证书，无增益）
- 申请为人工审批（社区案例约 1 周），AI 无法代办 → CI 用
  `vars.SIGNPATH_ENABLED` repository variable 门控签名 job，批准前整段跳过

## 2026-08-19 (Phase 43) — exec 断连后命令失控（三层无取消传播）+ macOS POLLHUP 半关闭歧义实测

**问题链**（AI agent 中途取消 exec / CLI Ctrl-C 后，Guest 命令失控继续跑）:

1. **Guest** `handleExecCmd`（guest.zig:1123-1166）: 主循环阻塞在 `shell.read`，
   `sendAndFlush` 失败仅 warn 后继续；`defer shell.close()`（SIGKILL）只在命令
   自然结束后执行——kill 逻辑永远不会中途触发；从不检测 TCP conn 断开。
2. **Host IPC** `ExecIpcSink.broken`（ipc.zig:637-656）: 只停转发不中止执行；
   命令无输出时永远发现不了 CLI 已死。
3. **Host HTTP MCP** `execOnGuest`（mcp_handler.zig:154-163）: OutputCollector
   全量累积输出在 Host 内存直到命令结束——取消后线程池槽 + 无上限内存被
   僵尸 exec 占据整个命令时长。

**关键实测（决定检测方式）**: macOS poll 对**半关闭也上报 POLLHUP**
（unix socketpair 与 TCP loopback 的 `SHUT_WR` 全测得 `IN|HUP`，2026-08-19
python 探针）→ 读侧信号无法区分 CLI 的 `SHUT_WR` 半关闭（server 依赖它判断
请求结束，ipc.zig:1099）与进程死亡 → IPC 路径弃用读侧检测。
（Linux 有 POLLRDHUP 可区分，但 macOS 无此标志，不能跨平台依赖。）

**最终设计**: 连接生命周期 = 命令生命周期，零协议变更：
- **IPC 路径写探测**: 周期向 CLI 写零长度 `exec_data` 帧（`0x11`+4B len=0，
  所有版本 CLI 无害跳过——ipcExec 解析 len=0 → remaining=0 → 读下一帧），
  EPIPE/BROKEN_PIPE = CLI 死亡。写探测无歧义（半关闭不影响写）。
- **HTTP 路径读侧检测**: 等响应的 HTTP 客户端不会半关闭 → poll + recv==0 即死。
- **Host 检测到断开** → shutdown Guest TCP → **Guest watcher**（阻塞 sockRead
  1B，Host 发完首帧后 conn 任何可读事件=断开）→ `killChild`。
- **进程组击杀**: `kill(-pid, SIGKILL)`（子进程 setsid 是组长）回退
  `kill(pid)`——孙进程（nohup 型守护）一并清除。
- 版本混部矩阵全安全（新 Host+旧 Guest=现行为；旧 CLI+新 daemon=探针被无害
  跳过；新 CLI+旧 daemon=CLI 零改动）。

**附带发现**: Guest utmm 帧命令（exec/upload/download）在 accept 循环线程
内联串行处理（guest.zig:995-1010）——一条长 exec 阻塞该 Guest 所有后续
命令（agent 取消后重跑的命令排队等旧命令跑完）。本次一并改为每连接
`std.Thread.spawn`（detach，先例 guest.zig:898/902 hosts_sync；理由：分钟级
阻塞任务不能占 zio 线程池槽）。

**行为变更**: CLI Ctrl-C 现在真正终止远端命令（旧行为：本机 CLI 死、远端
失控继续）。Windows TerminateProcess 只杀 cmd.exe 直系，孙进程残留为已知
限制（无进程组概念）。

**实施中发现 1 — macOS pty E-state（存量 bug，本次附带修复）**:
SIGKILL 一个阻塞在 pty slave read 的 shell，进程卡 E(exiting) 状态 ~4.5s，
直到 master 关闭才真正退出（ps 实测：`Ss+` → `?Es` ×4.5s → `Z`）。旧
closeFn 顺序（kill → waitpid 轮询 5s → close master）使**每次 macOS exec
的善后都白烧 ~5s**（done 帧已发但线程/limit 名额被占）。修复：closeFn 先
close master（slave read 立即 EOF → shell 干净退出）再 kill+收割，~100ms
完成。注意 shell 阻塞在 waitpid（前台任务运行中）时 SIGKILL 秒杀无此问题
——只有 idle 在 read 的 shell 受影响。

**实施中发现 3 — 真机验证抓出的作业控制盲区（v0.18.81→0.18.82 修复）**:
真机测试 C（`(sleep 300) & sleep 300` 取消）暴露：**交互式 shell 的作业控制
给每个 `&` 作业创建独立进程组**，`kill(-bash_pgid)` 够不到，master 关闭的
SIGHUP 又因 bash `huponexit=off` 不发给后台组 → 后台作业幸存（实测 pgid
自成一组的进程在取消后存活，每次取消残留 +1）。

**两次修复迭代**（第一版无效）:
- ❌ argv `+m`（`bash -l +m`）：真机实测残留依旧——**交互式 shell 初始化
  强制开启作业控制，覆盖 argv 初值**（单测/本地 pty 无法暴露：恰好通过）。
- ✅ 命令前缀 `set +m; `（buildCmdWithMarker POSIX 分支）：运行时关闭，
  后代全部留在本组。linuxvm(bash)/macvm(zsh) 真机验证 2→0。

**Windows 孙进程残留（v0.18.82 Job Object 修复）**:
TerminateProcess 只杀 cmd.exe 直系，PING.EXE 等子进程残留（实测取消 5s 后
仍存活）。修复：spawnWindowsPipe 创建 Job Object（`KILL_ON_JOB_CLOSE`）+
AssignProcessToJobObject；killChild Windows 分支改 TerminateJobObject 整树
击杀（job 创建失败降级 TerminateProcess）；closeFn 关闭 job 句柄兜底
（utmm 崩溃也全灭）。真机 windowsvm 验证 1→0。
注意 0.16 的 `std.os.windows.HANDLE` 是**非可选** `*anyopaque`，null 判断
用 `INVALID_HANDLE_VALUE` 比较（ipc.zig 惯例）。

**附带观察**: 部署后立刻 exec 可能瞬态 `Socks5AuthFailed`（两台 Windows VM
部署重启窗口各复现一次，~1min 自愈）——服务切换期旧监听残留，暂不处理。

**实施中发现 4 — 两处 argv/格式化低级 bug（+m 改造过程中踩中）**:
1. `var argv: [3:null]?[*:0]const u8 = undefined` 的**哨兵槽不初始化**
   （undefined=0xAA），`argv[0..argc :null]` 切片断言 panic → 子进程秒退
   （集成测试 bash 无输出退出、单测碰巧栈零通过）。正确姿势：数组字面量
   初始化（哨兵自动就位），execve 传完整数组（首个 null 即终止）。
2. tests/common.zig TempDir（历史死代码）：`{x}` 格式化 u48 **高位为零时
   不足 12 位不补零**，剩余 undefined 字节混入路径 → `error.BadPathName`
   （1/40 概率，1000 次循环 standalone 定位）。修复：缓冲预填 '0'。

**实施中发现 2 — Zig 0.16.0 API**:
- `std.Thread.Mutex` 不存在 → 用 `std.Io.Mutex`（`lockUncancelable(io)`/
  `unlock(io)`，需 io 参数；lsa.zig 先例）
- `std.Thread.sleep` 不存在 → tcp.zig 新增 `threadSleepMs`（POSIX nanosleep
  / Windows kernel32 Sleep，先例 dpipe_shell/lsa）
- `std.time.nanoTimestamp`/`milliTimestamp` 已移除 → 用 `std.Io.Timestamp.now(io, .awake)`
- `Io.Dir.createDir` 直接收 `Permissions`（`.default_dir`），不是 options struct
- `Io.Dir.iterate()` 不接 io，`Iterator.next(io)` 接 — common.zig TempDir
  死代码修正（连同 bufPrint 16 字节缓冲 NoSpaceLeft panic）
- spawnPosix 忽略传入 shell 参数、实际用 `$SHELL`（集成测试中是 /bin/bash
  而非 /bin/zsh — 影响测试假设）
