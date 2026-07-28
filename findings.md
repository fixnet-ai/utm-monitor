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
