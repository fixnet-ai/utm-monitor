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
