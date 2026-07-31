# Findings: UTM Monitor 技术发现与设计决策

记录重要的技术发现、设计决策和 Zig 0.16.0 API 笔记。

## 2026-08-01 — 工作流优化（v0.15.10→v0.15.11）

### FIONBIO 常量在 aarch64-windows 上溢出 c_int

`FIONBIO = 0x8004667e` (2147772030) 超出 `c_int` (i32, max 2147483647)。
aarch64-windows 交叉编译时报错 "type 'c_int' cannot represent integer value '2147772030'"。
x86_64-windows 不报（相同 c_int 类型），属于编译顺序问题——先失败的 target 阻断后续。

**解决**: `const FIONBIO: c_int = @bitCast(@as(std.os.windows.ULONG, 0x8004667e));`

Winsock2 ioctlsocket 的 cmd 参数类型是 `c_int`，但 FIONBIO 等 ioctl 码是 u32 高位置位，
C 中隐式转换允许，Zig 严格检查需要显式 `@bitCast`。

### std.Target.Query 字段是 optional

`build.zig` 中 `std.Target.Query` 的 `cpu_arch`、`os_tag`、`abi` 均为 optional 类型。
直接用 `@tagName(query.cpu_arch)` 报错 "expected enum or union; found '?Target.Cpu.Arch'"。
必须通过 `b.resolveTargetQuery(query)` 解析后再用 `tgt.result.cpu_arch`。

### standardOptimizeOption 只能调用一次

Zig 构建系统中 `b.standardOptimizeOption(.{})` 注册 CLI 选项 `-Doptimize`。
循环内多次调用会重复注册同名选项，触发 panic。必须在循环外调用一次，内部分复用。

### release.sh: build-test-then-tag 模式

旧模式 `tag → build → test → [失败] → 删 tag → 修 → 重 tag` 的根因是 tag 过早。
新模式 `bump ver.txt → build → test → commit + tag + push` 确保 tag 一定指向可构建版本。

关键实现细节：
- `git status --porcelain | grep -v 'src/ver.txt'` 允许 ver.txt 未提交（脚本会 auto-commit）
- `git rev-parse "$VERSION"` 检测 tag 是否已存在，避免覆盖已有 release
- `gh release view "$VERSION"` 检测 release 是否已存在

### macOS zig build test --listen=- 协议 hang

见 MANUAL.md Troubleshooting 章节详细记录。核心：
- `addRunArtifact()` 注入 `--listen=-` stdio 协议
- macOS kqueue 后端管道关闭时序问题导致死锁
- `--summary all` 同样走协议层，CI macOS runner 上应避免
- 本项目 `build.zig` 用 `Step.Run.create` + `addArtifactArg` 绕过

---

## Phase 1: 低风险合并 — 研究发现

### Finding 166: KCP 删除后的连锁简化效应

**背景**: commit `036f40f` 删除 KCP (~1300 行) + tunnel/ringbuf/completion + channel/sess*/disco/router/upgrade/json，共约 3000+ 行。

**连锁效应**:
- `mesh.zig` 不再管理 KCP session，简化为纯 LSA 广播 + Dijkstra + ping/pong
- `state.zig` 中 `guest_tunnels` 类型从 `*Tunnel` 变为 `*Connection`（TCP 连接）
- `host.zig`/`ipc.zig` 的 tunnelManager 变为 tcp.connect 模式
- `broadcast.zig` 的 `meshSessionLoop` 变为 `guestTcpLoop`
- `tunproto.zig` 的 `file_chunk`/`file_eof` 在 TCP 流式模型下不再必要

**状态**: 基础迁移已完成，文件合并待执行

### Finding 167: state.zig 的根因 — 长连接 + 跨线程共享

**根因**: KCP 时代的长连接模型导致 Guest 连接状态必须在多线程间共享（IPC 线程 vs mesh 线程 vs HTTP 线程），`state.zig` 是这种架构的必然产物。

**解决方案**: TCP per-command — 每命令一个独立 TCP 连接，无跨线程共享状态。

**影响范围**:
- `state.zig` (1386行) — 全部可删除
- `cmdchan.zig` — 跨线程命令队列不再需要
- `host.zig` ipc 请求处理 — 从查 state → 直接 tcp.connect
- `ipc.zig` — 简化，不再需要 pollOpState

**状态**: 设计中，Phase 2 执行

### Finding 168: DuplexPipe vtable 模式的普适性

**设计**: `dpipe.zig` 用 vtable 抽象双向 I/O：
```zig
const VTable = struct {
    readFn: *const fn(*anyopaque, []u8) anyerror!usize,
    writeFn: *const fn(*anyopaque, []const u8) anyerror!void,
    closeFn: *const fn(*anyopaque) void,
};
```

**优势**:
- `tcp.Connection` 可实现 DuplexPipe → 直接用于 relay
- `dpipe_shell` pty → DuplexPipe
- `dpipe_file` file read/write → DuplexPipe
- 任意两个 DuplexPipe 可通过 `dpipe.relay()` 双向桥接
- 纯接口，无泛型，编译快

**状态**: 设计中，Phase 2 实现

### Finding 169: /etc/hosts 空行累积 bug

**根因**: `splitScalar` 逐行遍历 + 重写整个 marked block → 每次 LSA 同步追加一个空行。

**修复**: range replacement — 定位 MARKER_BEGIN/END，整体替换 marked block。
```zig
fn syncHosts(original: []const u8, entries: []const Node) []const u8 {
    const begin = std.mem.indexOf(u8, original, MARKER_BEGIN);
    const end = std.mem.indexOf(u8, original, MARKER_END);
    if (begin != null and end != null) {
        return concat(original[0..begin], newBlock, original[end+MARKER_END.len..]);
    }
    return concat(original, newBlock);
}
```

**状态**: Phase 1 Task 4 修复

### Finding 170: tunproto.zig 与 protocol.zig 职责重叠

**重叠点**:
- 各有一个 MsgType 定义
- 协议常量分散在两处
- `buildCmdWithMarker` 在 state.zig 而非 protocol.zig

**合并方案**: `tunproto.zig` 的全部内容迁入 `protocol.zig`，包括消息序列化/反序列化。

**状态**: Phase 1 Task 2 合并

---

## 历史 Findings（已关闭，参考用）

<details>
<summary>Phase 79: MCP 连接修复 (Finding 163-165)</summary>

### Finding 163: Zig `\\` 多行字符串破坏 MCP stdio JSON-RPC 传输 ✅

Zig `\\` 在编译后保留真实换行符，破坏 MCP 换行分隔 JSON 协议。
修复: 单行 `\"` 转义 JSON 字符串。

### Finding 164: `claude mcp add` 旧注册覆盖手动配置 ✅

`~/.claude.json` 优先级高于 `~/.claude/mcp.json`。修复: `claude mcp remove` + `claude mcp add --scope user`。

### Finding 165: MCP 作用域默认 `--scope local` ✅

仅当前项目可用。修复: `--scope user` 使所有项目可用。

</details>

---

## Phase 3: 系统服务 — 研究发现

### Finding 170: lock.zig CWD-相对路径是隐藏 bug

`lock.zig` 的 `LOCK_FILE = "utmm.lock"` 在 CWD 而非固定路径创建锁文件。
两个管理员从不同目录运行 `sudo utmm --install` 会创建不同锁文件，互不可见。

**解决方案**: 在 svc.zig 内联，使用固定路径 `/var/run/utmm-install.lock` (POSIX) /
`C:\opt\utmm\utmm-install.lock` (Windows)。

### Finding 171: shm 不能替代 install 锁

shm 由 utmmd 创建，而 `forceInstall`/`ensure` 在 utmmd 不存在时被调用（负责安装和启动 utmmd）。
两者处于完全不同的生命周期阶段，无法互相替代。

### Finding 172: flock 跨平台不兼容

`flock()` 是 POSIX 专用。Windows 等价物是 `LockFileEx()`（需要 OVERLAPPED 结构，即使用于锁整个文件）。
条件编译方案：POSIX `open(O_CREAT|O_RDWR) + flock(LOCK_EX)`，Windows `CreateFileW(OPEN_ALWAYS) + LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)`。

### Finding 173: install.zig 独立构建收益低

独立 `utmm-install` 可执行文件需要：
1. 重复 `@embedFile("embed/utmmd.bin")`（当前在 main.zig 中）
2. 重复 CLI args 解析
3. 发布目标翻倍（8 → 16 二进制）

**实际做法**: Platform + genInit 移至 svc.zig 与现有服务管理代码聚合，不做独立构建。

---

## Phase 4: 清理收尾 — 研究发现

### Finding 174: Zig 0.16.0 测试运行器对 stderr warn 日志敏感

当测试二进制以 `--listen=-` 协议模式运行时（`zig build test` 内部机制），
测试代码中的 `std.log.warn` 输出到 stderr 会导致父进程（build_runner）报告
"failed command"，并使整体测试步骤标记为失败。

**根因**: Zig 0.16.0 测试运行器的 `test_runner.zig` 自定义了 `std_options.logFn`，
在 `--listen=-` 协议模式下，stderr 输出可能干扰协议通信或触发测试框架的失败检测。

**修复**: dpipe_file.zig `writeFileCloseFn` 中的 hash mismatch 日志从 `warn` 改为
`debug`。hash 不匹配是可恢复的诊断事件（temp 文件删除，操作优雅失败），非系统级警告。
测试中的 `std.log.debug` 在测试运行器的默认 `.warn` 日志级别下不输出，避免干扰。

### Finding 175: shm.zig 的 10 个测试之前从未运行

shm.zig 定义了 10 个测试（ShmLayout size、magic、version、cmd、Cmd 枚举、
SvcState 枚举、UtmmState 枚举、CmdStatus 枚举、MAGIC 常量、SHM_NAME），
但从未被包含在任何测试二进制中。

**根因**: shm.zig 被 main.zig 通过 `@import("shm.zig")` 导入，但其测试
未出现在主测试二进制中。原因可能是 Zig 0.16.0 的测试收集行为与模块导入链
不完全一致 — 某些被导入模块的测试块未被主测试二进制发现。

**修复**: 将 shm.zig 加入 `standalone_test_modules` 列表，确保其测试独立编译运行。

### Finding 176: build.zig test 去重 — tcp/lsa 在主二进制和 standalone 中双重运行

tcp.zig 和 lsa.zig 的测试在主测试二进制（通过 main.zig → host.zig import 链）
和独立 refac_modules 测试二进制中均被执行，导致每次 `zig build test` 重复运行
约 23 个测试。

**修复**: 从 standalone_test_modules 中移除 tcp.zig 和 lsa.zig，仅保留主二进制
中无法被测试收集到的模块（dpipe、dpipe_shell、dpipe_file、guest、shm）。

**不可避免的残留重复**: dpipe.zig 的 5 个测试在 dpipe、dpipe_shell、dpipe_file
三个独立二进制中各执行一次。这是因为 dpipe_shell 和 dpipe_file 都 import dpipe，
且每个 standalone 模块编译为独立测试二进制。这个开销很小（10 次额外运行），可接受。

### Finding 177: 代码扫描 — 3 个 TODO，无编译警告

**2026-07-29 代码库扫描结果**:

| 位置 | 内容 | 类型 |
|------|------|------|
| `config.zig:107` | `TODO: full config file parsing implementation` | 功能缺口 |
| `guest.zig:780` | `TODO: TCP 版本自动升级` | 已部分实现 — 升级信号检测+`upgrade_req` 定义均到位，但 Guest 从未实际发送请求，Host 未处理 |
| `lsa.zig:496` | `net_receive with concurrency=true is an explicit TODO in the stdlib` | Zig 0.16.0 stdlib 问题，非本项目 |

**其他检查项**:
- `zig build` 零警告
- 无未使用导入/变量
- `std.log.warn` 共 28 处，均在非测试代码路径中（不影响 `zig build test`）
- refac.md §3.7 残留过时描述（"install.zig 可独立构建"），已修正为实际决策

**结论**: 重构阶段可彻底收工。分支可直接合并 main。

### Finding 178: auto_upgrade 开关设计 — 默认关闭避免测试干扰

**背景**: 测试过程中自动升级行为会不断干扰测试流程和结果：
- Host 侧 `checkGitHubVersion()` 发出 HTTP 请求到 GitHub API
- Host 侧 `verifyServeDirBinaries()` 在 serve-dir 缺少平台二进制时输出告警
- Guest 侧 LSA 版本比对触发升级信号，干扰正常测试输出

**设计**:
- `config.auto_upgrade: bool = false` — 默认关闭
- `--auto-upgrade` CLI flag — 部署时显式启用
- `lsa.Mesh.upgrade_needed` 改为 `?*std.atomic.Value(bool)` — null 时完全跳过版本比对
- 所有自动升级相关代码路径（Guest 升级信号检查、Host GitHub 版本轮询、serve-dir 校验）均按开关门控

**影响文件**: config.zig, main.zig, lsa.zig, guest.zig, host.zig（5 文件）

### Finding 179: Zig 0.16.0 `system.read` / `system.write` 非 error union

**背景**: 编写集成测试时需要直接调用 POSIX `read`/`write` 进行原始字节流传输（upload/download/upgrade 的文件数据在帧协议之后以裸流形式传输）。

**发现**:
- `std.posix.system.read(fd, buf, len)` 返回 `isize`（C 风格返回值），**不是 error union**
- `std.posix.system.write(fd, buf, len)` 返回 `isize`，同样不是 error union
- `-1` 表示错误，需手动检查 `<= 0`
- `system.write` 的 `buf` 参数类型为 `[*]const u8`（C 指针），非 `[]const u8`

**错误模式**:
```zig
// ❌ 错误：system.read/system.write 不返回 error union，不能用 try/catch
const n = try system.read(fd, &rbuf, len);
_ = try system.write(fd, data, data.len);

// ❌ 错误：[]const u8 不能隐式转换为 [*]const u8
_ = system.write(fd, some_slice, len);
```

**正确模式**:
```zig
// ✅ 正确：检查返回值，@intCast 转换
const raw_n = system.read(fd, &rbuf, len);
if (raw_n <= 0) return; // 或 break
const n: usize = @intCast(raw_n);

// ✅ 使用 .ptr 获取 [*]const u8
_ = system.write(fd, some_slice.ptr, some_slice.len);
```

**影响**: upload_e2e、download_e2e、upgrade_e2e 三个测试文件（共 ~10 处调用点）。

### Finding 180: Zig 0.16.0 `ArrayList.fromOwnedSlice` API 变更

**背景**: 集成测试中需要复制帧数据到 ArrayList 进行 MDELIM 扫描。

**发现**:
- `std.ArrayList(T).fromOwnedSlice(allocator, slice)` 在 Zig 0.16.0 中参数签名已变更
- 应使用 `.empty` + `.appendSlice(allocator, slice)` 替代
- deinit 需传入 allocator：`defer list.deinit(alloc)` （因为 ArrayList 现在是 unmanaged 版本）

**正确模式**:
```zig
// ✅ Zig 0.16.0
var list: std.ArrayList(u8) = .empty;
try list.appendSlice(alloc, data);
defer list.deinit(alloc);
```

**影响**: exec_e2e 测试（4 处）。

### Finding 181: 部署门禁 — 代码变更后集成测试先行

**背景**: REVIEW_FINDINGS.md 指出的多个缺陷（C1 双重标记、C2 并发竞争、I2 genInit 过时等）如果在真机调测前有集成测试，可在几秒内发现，而非在物理 VM 上耗费数小时排查。

**决策**: 在 CLAUDE.md 新增 `Deployment Gating Rule`：
- 修改代码后必须先通过 `zig build test` + `zig build test-integration`
- 全部场景 0 失败才能上真机
- 无例外 — "trivial" 变更同样可能引入协议回归（如 C1 就是一行 Host 端 buildCmdWithMarker 调用导致的）

**关联**: [[Finding 175]]（测试覆盖不足）、[[Finding 177]]（代码扫描结论）

---

## Phase 8: Windows 跨平台 Socket 抽象层 — 研究发现

### Finding 182: `callconv(.winapi)` — 解决 32 位 Windows stdcall 符号修饰

**背景**: x86-windows-gnu 交叉编译时链接器报告 6 个未定义 Winsock2 符号：
`socket`、`listen`、`accept`、`send`、`recv`、`closesocket`、`shutdown`。
但 64 位目标（aarch64-windows、x86_64-windows）编译正常。

**根因**: `extern "ws2_32"` 声明默认使用 C 调用约定（cdecl），生成无修饰符号（如 `_send`）。
32 位 Windows `stdcall` 调用约定需要 `@n` 名称修饰（如 `_send@16`），未修饰符号与 DLL
导出表不匹配，导致链接失败。64 位 Windows 的 `.winapi` = `.C`（无操作），所以 64 位目标不受影响。

**修复**: 所有 6 个 Winsock2 extern 声明添加 `callconv(.winapi)`：
```zig
// ✅ 正确：callconv(.winapi) 在 32 位 = .Stdcall（@n 修饰），64 位 = .C（无操作）
extern "ws2_32" fn send(s: socket_t, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn recv(s: socket_t, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn accept(s: socket_t, addr: ?*anyopaque, addrlen: ?*std.posix.socklen_t) callconv(.winapi) c_int;
extern "ws2_32" fn listen(s: socket_t, backlog: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(s: socket_t) callconv(.winapi) c_int;
extern "ws2_32" fn shutdown(s: socket_t, how: c_int) callconv(.winapi) c_int;
```

**影响文件**: `src/tcp.zig`、`tests/common.zig`

### Finding 183: `std.posix.socket_t` 的平台差异

**发现**: `std.posix.socket_t` 在 POSIX 是 `c_int`（文件描述符），在 Windows 是 `*anyopaque`（SOCKET 句柄）。
这要求所有 socket I/O 操作使用跨平台抽象而非裸系统调用。

**影响**: Windows 上 `accept()` 返回 `c_int` → `c_uint`（`@bitCast`）→ `usize` → `@ptrFromInt` 转为 `socket_t`。
POSIX 上直接使用 `system.accept` 返回的 `c_int`。

### Finding 184: Zig 0.16.0 Windows `Bool` 类型变更

**背景**: `svc.zig` 中 `LockFileEx` 返回 `std.os.windows.Bool`（内部是 `c_int` 的 enum），
不能直接与整数 `== 0` 比较。

**修复**:
```zig
// ❌ 旧代码
if (LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped) == 0) { ... }

// ✅ 修复
const result = LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped);
if (@intFromEnum(result) == @as(c_int, 0)) { ... }
```

### Finding 185: 跨平台 socket I/O 抽象层的设计原则

**设计**: `tcp.zig` 中新增 7 个 `sock*` wrapper 函数，`tests/common.zig` 中复制相同函数。
测试可执行文件独立编译不能依赖主二进制，所以需要复制。

**Wrapper 清单**:
| 函数 | POSIX 底层 | Windows 底层 |
|------|-----------|-------------|
| `sockWrite` | `system.write()` | `send()` via ws2_32 |
| `sockRead` | `system.read()` | `recv()` via ws2_32 |
| `sockClose` | `system.close()` | `closesocket()` via ws2_32 |
| `sockShutdown` | `system.shutdown()` | `shutdown()` via ws2_32 |
| `sockAccept` | `system.accept()` | `accept()` via ws2_32（含类型转换）|
| `sockListen` | `system.listen()` | `listen()` via ws2_32 |
| `makePair` | `socketpair()` | TCP loopback 替代 |

**编译时零开销**: 全部使用 `builtin.os.tag == .windows` comptime 分支，
非目标平台的代码路径完全消除。

---

## Phase 9: E2E 真机 Bug 修复（续）

### Finding 181: Windows socket fd 不可用 std.posix.system.read/write

**背景**: windowsvm 上传报告 "OK" 但文件未创建（0 字节 temp 文件），下载返回 0 字节。

**根因**: `guest.zig` 的 `handleUpload` 和 `handleDownload` 使用 `std.posix.system.read(conn.fd, ...)` /
`std.posix.system.write(conn.fd, ...)` 读写 socket 数据。`conn.fd` 是 raw Winsock2 SOCKET（来自
`sockAccept` → `ws2_accept`），而 `std.posix.system.read` 在 Windows 上底层走 `ReadFile`，
`ReadFile` 不支持 socket 句柄。同样，`ipc.zig` Host daemon 的 `handleUpload` / `handleDownload`
也使用 `system.read` / `system.write` 读写 TCP socket，存在同样问题（虽然当前 Host 跑在 macOS 上
未触发）。

**症状**:
- upload: `system.read(conn.fd, ...)` 在 Windows 上返回 -1 或 0 → `handleUpload` 的 while
  循环不执行 → temp 文件保持 0 字节 → `file_pipe.close()` SHA256 不匹配 → temp 文件被删除
- download: `system.write(conn.fd, ...)` 在 Windows 上失败 → 数据无法发送 → Host 收到 0 字节

**修复**: 将 4 处 `std.posix.system.read`/`write` 替换为 `tcp.sockRead`/`tcp.sockWrite`：
- `src/guest.zig:1065`: `std.posix.system.read(conn.fd, ...)` → `tcp.sockRead(conn.fd, ...)`
- `src/guest.zig:1118`: `std.posix.system.write(conn.fd, ...)` → `tcp.sockWrite(conn.fd, ...)`
- `src/ipc.zig:795`: `std.posix.system.write(tcp_conn.fd, ...)` → `tcp_mod.sockWrite(tcp_conn.fd, ...)`
- `src/ipc.zig:881`: `std.posix.system.read(tcp_conn.fd, ...)` → `tcp_mod.sockRead(tcp_conn.fd, ...)`

**exec 为何不受影响**: `handleExecCmd` 全程使用 `conn.sendAndFlush()`（framed）收发数据，
不走 `system.read`/`write`，因此 exec 在修复前已经正常工作。

**验证**: windowsvm 上 exec/upload/download 全通过，50KB 二进制文件上传+下载 SHA256 完全一致。

---

## Phase 9: E2E 真机 Bug 修复 — 研究发现

### Finding 186: AddressInUse 崩溃循环 — 根因 FD_CLOEXEC 缺失

**症状**: linuxvm 上 download 永远失败（exec+upload 成功），Guest 陷入崩溃循环：
```
utmm 启动 → bind TCP :2121 OK → 处理 exec（fork pty 子进程）→
处理 upload → utmm crash → 新 utmm: LSA UDP :2121 OK, TCP :2121 AddressInUse →
崩溃循环
```

**根因链**:
```
dpipe_shell fork() → 子进程继承 TCP listener socket (无 FD_CLOEXEC)
→ upload 的 double-close bug 导致 utmm panic 崩溃
→ 孤儿子进程（init 收养）仍持有 TCP :2121
→ 新 utmm 无法 bind TCP → AddressInUse
→ utmmd retry 循环（backoff 2s→60s）
```

**修复** (`src/tcp.zig`):
1. `addr.bind()` → `addr.listen()` 启用 `reuse_address: true`（SO_REUSEADDR），加速 TIME_WAIT 恢复
2. 通过 `fcntl(fd, F_SETFD, FD_CLOEXEC)` 防止子进程继承 listener socket

**技术细节**:
- Zig 0.16.0 `std.Io.net.IpAddress.listen()` 支持 `ListenOptions.reuse_address`
- `std.posix.F` 在 0.16.0 中是 struct（非 enum），`GETFD`/`SETFD` 是 `comptime_int`，需 `@as(c_int, ...)` 转换
- `std.c.fcntl` 是 variadic 函数，Zig 0.16.0 要求所有字面量参数强制类型转换
- `Server` 类型 (`std.Io.net.Server`) 替代原始 `Socket`，拥有 `deinit()` 和 `accept()` → `Stream` 方法
- `Server.accept()` 返回 `Stream`，其 `socket.handle` 等于 `socket_t`（`std.posix.fd_t == socket_t`）

**影响文件**: `src/tcp.zig`、`tests/tcp_frame/main.zig`（字段 `socket` → `server`）

### Finding 187: handleUpload 双 close → use-after-free panic

**症状**: `handleUpload` 完成文件写入后 panic：
```
dpipe_file.zig:173 → writeFileCloseFn → file.close(io) → closeFd → recoverableOsBugDetected → unreachable
```
Host 端 upload 显示 "OK"（因 `close()` 前数据已写入），但 Guest 因 panic 崩溃。

**根因**: `handleUpload` 中 `file_pipe.close()` 被调用两次：
```zig
defer file_pipe.close();   // line 1058 — 函数返回时执行
// ... 读取 TCP 数据写入文件 ...
file_pipe.close();          // line 1078 — 显式关闭
// ↓ 函数返回时 defer 再次 close → ctx 已释放 → 垃圾 fd → BADF → panic
```

第一次 close 通过 `writeFileCloseFn` → `allocator.destroy(self)` 释放了 ctx 内存。
defer 的第二次 close 对已释放的 ctx 操作：`self.file` 字段为垃圾值 → close 垃圾 fd → EBADF → panic。

**修复** (`src/guest.zig`): 移除 `defer file_pipe.close()`。显式 `file_pipe.close()` 已覆盖所有退出路径（正常路径 + while-break 的 `remaining > 0` 路径）。

**影响文件**: `src/guest.zig`（1 行删除）

### Finding 188: utmmd.bin 嵌入构建流程修复

**问题 1**: 切换目标平台时 utmmd 不会重新构建（copy_utmmd step 依赖 utmmd step，但 utmmd step 只在输出变化时重编）
**问题 2**: `src/embed/` 无按平台分子目录 → 交叉编译不同目标时互相覆盖错误的 utmmd.bin

**修复** (`build.zig`):
- `src/embed/` 改为按目标分目录：`src/embed/{arch}-{os}/utmmd.bin`
- 增加 `mkdir -p` 步骤确保子目录存在
- SHA256 hash 同目录输出

**修复** (`main.zig`):
- `@embedFile` 使用 comptime switch 按 `builtin.cpu.arch` + `builtin.os.tag` 选择正确路径
- Binary embed 各分支 coerces 到 `[]const u8`；SHA256 embed 各分支返回相同大小的 `*const [64:0]u8`

**影响文件**: `build.zig`、`src/main.zig`（2 文件）

### Finding 189: SOCKS4a 栈悬垂指针 — macOS aarch64 上 readUntilNull 返回后栈被 std.mem.eql 覆盖

**根因**: `readUntilNull` 将数据读入局部 `var buf: [MAX_HOSTNAME+64]u8`，返回 `buf[0..pos]` 切片。
函数返回后栈帧被弹出，切片成为悬垂指针。`socks4CheckAndReply` 虽"立即"调用
`std.mem.eql(u8, hn, self_hostname)` 比较，但 `std.mem.eql` 本身是函数调用，会使用栈空间。
在 macOS aarch64 上，其栈帧恰好与 `readUntilNull` 的旧栈帧重叠，`buf` 数据被破坏。

**症状**: SOCKS4a 始终返回 `0x5b` (REJECTED)，日志显示 `self_hostname` 正确但比较失败。
调试日志显示 `hn` 前 4 字节正确（"dasi"），后续被破坏为垃圾字节（null + 栈残留数据）。

**为何 linuxvm/windowsvm 不受影响**: 不同平台/编译器的 ABI 约定不同，栈帧布局和寄存器分配
影响悬垂指针是否被覆盖。linuxvm (aarch64-linux) 和 windowsvm (aarch64-windows) 恰好
不受影响，但这是未定义行为，纯属运气。

**修复** (`src/tcp.zig`):
- `readUntilNull` → `readUntilNullBuf(fd, buf: []u8)` — 缓冲区由调用者提供
- `socks4CheckAndReply` 和 `socks4Accept` 使用本地 `hn_buf` / `userid_buf`，
  数据存在调用者栈帧中，`readUntilNullBuf` 返回后仍然有效
- 消除了整个 `readUntilNull` 栈帧复用问题

**影响文件**: `src/tcp.zig`、`tests/tcp_frame/main.zig`

**后续修复**: `socks4Accept` 同样存在悬垂指针问题 — `hn_buf` 在其栈帧中，返回的
`Socks4Request.hostname` 指向已释放栈。改为接受 `allocator` 参数，堆分配 hostname，
调用者负责释放。同步更新单元测试和集成测试。

**验证**: SOCKS4a 返回 0x5a，macvm exec 端到端通过。
`zig build test` + `zig build test-integration` 全部通过（新增 5 个测试）

---

## Phase 19: /etc/hosts 同步统一 + hostname 规范化 — 研究发现

### Finding 190: /etc/hosts 同步存在两套重复实现

**发现**: 代码库中存在两套独立的 `/etc/hosts` 同步实现，使用不同的标记、不同的写入策略：

| 维度 | `host.zig` `syncHostsFromTable()` | `lsa.zig` `updateHosts()` |
|------|-----------------------------------|---------------------------|
| 位置 | `host.zig:1098-1158` | `lsa.zig:1233-1365` |
| 使用状态 | **生产中调用**（LSA 处理 loop） | **死代码**（仅测试调用） |
| 写入安全 | 直接 truncate 覆写，崩溃不安全 | temp 文件 + 原子 rename，崩溃安全 |
| 错误处理 | `void`，错误静默吞掉 | `!void`，错误传播给调用者 |
| 标记检测 | 字节级子串（非行感知） | `findMarkerLine()` 行感知，容错空白 |
| 空行累积 Bug | 存在 | 已修复（显式跳过尾部 \r\n） |
| 路径 | 硬编码 `/etc/hosts` | 参数化 `file_path` |
| 标记 | `# BEGIN UTM-MONITOR` / `# END UTM-MONITOR`（与 protocol 常量不同） | `protocol.HOSTS_MARKER_BEGIN` / `END` |
| hostname 格式 | `{ip} {hostname}.{target}.utm`（FQDN + .utm 后缀） | `{ip}  {name}`（双空格，调用者提供） |
| CLI `--hosts-file` | 不尊重 | 支持（未连线） |
| CLI `--marker` | 不尊重 | 支持（未连线） |

**结论**: `lsa.zig` 的实现全面优于 `host.zig`，应作为唯一实现源。`host.zig` 版本全部删除。

### Finding 191: hostname 未做小写规范化

**现状**: 系统中有 3 个 hostname 入口，均未做大小写规范化：

| 入口 | 文件:行 | 行为 |
|------|---------|------|
| OS 主机名 | `guest.zig:369-379` | POSIX `gethostname()` / Windows `COMPUTERNAME`（全大写）— 原样存储 |
| `--hostname` CLI | `main.zig:240-244` | 无校验、无规范 — 原样存储 |
| `--exec/--upload/--download` target | `main.zig` | 原样传递到 `connectGuest()` |

**所有比较使用 `std.mem.eql`（大小写敏感）**，分布在：
- `GuestTable.indexOf()` → `findByHostname()` (host.zig)
- `updateIp()` / `remove()` / `setMeshMac()` (host.zig)
- `connectGuest()` ARP 恢复 (host.zig)
- `socks4CheckAndReply()` SOCKS4a 握手 (tcp.zig)
- IPC handlePing/Exec/Upload/Download (ipc.zig)
- Auto-upgrade `LastUpgradeMap` (host.zig)

**影响评估**:
- Windows `COMPUTERNAME` 典型全大写（如 `DESKTOP-ABC123`），导致与其他系统交互时大小写不一致
- `deriveNodeId()` 使用 DJB2 hash(hostname)，大小写变化 = 不同 NodeId（仅影响 peer-mesh 模式）
- LSA node_info 字符串原样传输 hostname，不做规范化
- MCP 工具 `vm` 参数大小写敏感——用户传 `"LinuxVM"` 会查不到 `"linuxvm"`

**修复原则**: 在入口处统一转小写，所有内部比较自动一致。比较代码（`std.mem.eql`）无需改动。

### Finding 192: Guest 端无 hosts 同步能力

**发现**: Guest 端完全未实现 `/etc/hosts` 同步。Guest 运行完整 LSA mesh（广播 + 接收），但从不将节点信息写入 hosts 文件。

**Guest 端关键能力**:
- 通过 `detectUnixIp()`/`getWindowsIp()` 获取自身 IP
- 通过 `getDefaultGateway()` (`guest.zig:499`) 获取默认网关 IP — **UTM 中 Host 即为网关**
- 运行 `lsa.Mesh`（完整 LSA 节点表：neighbors + lsas + routes）
- `--host-ip` CLI 参数已解析但**从未被 Guest 运行时读取**（休眠字段）

**Gateway 条目设计方案**:
- **Host 端**: `gateway` → 自身 IP（Host 自己的地址）
- **Guest 端**: `gateway` → Host IP（即 `getDefaultGateway()` 返回值，UTM 中 Host = 网关）

### Finding 193: FQDN .utm 后缀可能引发系统冲突

**分析**: `syncHostsFromTable()` 生成的格式 `{hostname}.{target}.utm` 产生类似 `linuxvm.aarch64-linux-musl.utm` 的条目。`.utm` 不是 IANA 注册 TLD，在 `/etc/hosts` 中无害，但与某些软件的 FQDN 解析可能冲突。更重要的问题是：
- `/etc/hosts` 条目本应是简单的 hostname→IP 映射，不需要伪造 FQDN
- `{target}` 是编译目标标识（如 `aarch64-linux-musl`），与 hostname 无关
- 去除后缀后可以简化 DNS/SSH 等工具的使用
