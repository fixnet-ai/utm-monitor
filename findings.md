# Findings: v0.13.0 分层架构重构

记录重要的技术发现、设计决策和 Zig 0.16.0 API 笔记。

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
