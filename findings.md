# Findings — UTM Monitor 技术发现

持续有效的技术发现、已知限制和 Zig 0.16.0 编码经验。

## 已知限制

| # | 限制 | 影响 | 状态 |
|---|------|------|------|
| 1 | Zombie 进程 | killChild 5s WNOHANG waitpid，D 状态子进程无法收割 | 已知 |
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
