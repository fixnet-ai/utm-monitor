# 多线程安全审计报告 — utmmd + utmm

**日期**: 2026-08-12 | **版本**: v0.18.35 | **审计范围**: shm.zig, utmmd.zig, guest.zig, host.zig, lsa.zig, ipc.zig, socks5.zig, tcp.zig

---

## 线程模型总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ utmmd (Supervisor)                                                            │
│   mainThread: monitorLoop() — 单线程，轮询 SHM + 进程监控                     │
│   Io.Threaded: 文件 I/O 线程池（v0.18.35+ 所有平台统一）                       │
│   fork() [POSIX]: 创建 utmm 子进程（fork + exec 模式）                         │
│   CreateProcessA [Win]: 创建 utmm 子进程                                      │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ utmm Guest                                                                    │
│   mainExecutor: guestTcpLoop() — TCP accept + SOCKS5 握手                    │
│     └─ inline: exec/upload/download/upgrade（阻塞 accept 循环）               │
│     └─ group.spawnBlocking: SOCKS5 BIND/UDP/localRelay → 线程池              │
│   std.Thread: LSA Mesh.run() — 独立线程                                       │
│   std.Thread: guestHostsSync() — 独立线程                                     │
│   SHM: utmm_heartbeat 写入（多处并发），cmd/cmd_status 写入（单处）            │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ utmm Host                                                                     │
│   mainExecutor: hostTcpListen() — TCP accept + 首字节分发                     │
│     └─ group.spawnBlocking: SOCKS5 + HTTP MCP + Forward → 线程池             │
│   协程 (group.spawn): hostMainLoop() — LSA 快照 + GuestTable 同步             │
│   线程池 (group.spawnBlocking): IPC 服务器 accept 循环                         │
│     └─ rt.spawnBlocking: IPC handler → 线程池                                 │
│   std.Thread: LSA Mesh.run() — 独立线程                                       │
│   SHM: utmm_heartbeat 写入（多处并发），cmd/cmd_status 读取                    │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ LSA Mesh（独立线程，Host + Guest 共享）                                        │
│   mesh_io: 专用 Io.Threaded                                                  │
│   同步原语: neighbors_mutex, lsas_mutex, routes_mutex, last_pong_mutex       │
│   Windows: std.Thread + detach() 定时器线程                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🔴 严重问题

### P0-1: SHM 使用 `volatile` 而非 `std.atomic` — 弱内存序 CPU 可见性无保证

**位置**: `src/shm.zig:58-82`, `src/utmmd.zig` 所有 `shm_ptr.* =` 赋值, `src/guest.zig` 所有 `h.* =` 赋值

**现状**: `ShmLayout` 定义为 `extern struct`，所有字段为普通整数类型。共享内存指针类型为 `*volatile ShmLayout`，但字段本身不包含任何原子类型。

```zig
pub const ShmLayout = extern struct {
    svc_state: u32 = ...,
    utmm_state: u32 = ...,
    utmm_pid: u32 = 0,
    svc_heartbeat: u64 = 0,      // ← 普通 u64，非原子
    utmm_heartbeat: u64 = 0,     // ← 同上
    cmd: u32 = ...,
    cmd_status: u32 = ...,
    // ...
};
```

**volatile 做什么**: 仅防止编译器优化掉读写操作（禁止寄存器缓存、禁止重排 `volatile` 访问之间顺序）。**不插入任何 CPU 内存屏障**。

**volatile 不做什么**:
- 不保证多核 CPU 之间的写入可见性顺序
- 不保证 64-bit 字段在 32-bit 平台上的原子性（x86 32-bit 仍然部署）
- 不防止 CPU 级别的 Store-Load 重排

**实际影响**: 在 ARM64 (aarch64) 上，以下场景可能出错：

1. **utmm 写入 `cmd` + `cmd_status`，utmmd 读取**:
   ```zig
   // guest.zig:1327-1329 (handleUpgradeCmd)
   h.cmd = @intFromEnum(shm.Cmd.restart);        // Store A
   h.cmd_status = @intFromEnum(shm.CmdStatus.pending);  // Store B
   ```
   ```zig
   // utmmd.zig monitorUtmm() 轮询
   const cmd: shm.Cmd = @enumFromInt(shm_ptr.cmd);  // Load A'
   const status: shm.CmdStatus = @enumFromInt(shm_ptr.cmd_status);  // Load B'
   ```
   ARM64 允许 utmmd 观察到 **B' 已更新（pending）但 A' 仍是旧值（none）**。修复：Store B 用 `.release`，Load A' 用 `.acquire`。

2. **utmmd 写入 `svc_heartbeat`，utmm 读取用于 debug**: 心跳写入和退出码/状态写入之间的重排可能导致 utmm 观察到不一致的快照。

3. **x86 32-bit 部署**: `u64` heartbeat 在 32-bit x86 上读/写不是原子的。一次写入可能被拆分为两个 32-bit store，utmmd 读取时可能读到"一半旧值一半新值"的混合时间戳。虽然实际用途仅用于超时判断（10s 量级），不太可能导致误判，但在理论上是不正确的。

**推荐修复**:
```zig
pub const ShmLayout = extern struct {
    magic: u32 = MAGIC,
    version: u32 = VERSION,
    svc_state: std.atomic.Value(u32) = ...,
    utmm_state: std.atomic.Value(u32) = ...,
    utmm_pid: u32 = 0,              // fork 后只写一次，安全
    svc_pid: u32 = 0,
    svc_heartbeat: std.atomic.Value(u64) = ...,
    utmm_heartbeat: std.atomic.Value(u64) = ...,
    cmd: std.atomic.Value(u32) = ...,
    cmd_status: std.atomic.Value(u32) = ...,
    // ... 其余字段类似
};
```

但 `std.atomic.Value` 不是零大小的——它会改变 struct 布局。最简修复方案：保持 `extern struct` 的普通字段，但在所有跨进程写入处使用 `@fence(.release)`，在读取处使用 `@fence(.acquire)`。

---

### P0-2: 多处并发写入 `utmm_heartbeat` — 竞争条件

**位置**: Guest 和 Host 的多处 heartbeat 写入点

**Guest 写入点**（同一进程内的多个执行上下文）:
| 文件:行 | 上下文 | 线程 |
|---------|--------|------|
| `guest.zig:920` | accept 循环顶部 | 主协程 |
| `guest.zig:1099` | handleExecCmd shell 读取循环 | 主协程（但阻塞） |
| `guest.zig:1178` | receiveFile 文件接收循环 | 主协程（但阻塞） |
| `guest.zig:1364` | handleDownload 文件发送循环 | 主协程（但阻塞） |

**Host 写入点**:
| 文件:行 | 上下文 | 线程 |
|---------|--------|------|
| `host.zig:993` | TCP accept 循环顶部 | 主协程 |
| `host.zig:1421` | hostMainLoop 每 5s 循环 | 协程 |
| `host.zig:942` | mcpHttpHandler | 线程池 |

**分析**: Guest 的四个写入点实际上都在主协程中执行（Guest 的 exec/upload/download 是 inline 处理），不存在竞争。但 Host 有三个不同的并发执行上下文同时写入同一个字段。虽然是单调递增的时间戳，并发写入可能导致读到稍旧的值，但不会导致崩溃。**实际上 utmmd 仅需要 heartbeat 不超时（< 10s），并发写入「时间戳略旧」不会触发错误超时**。从实际影响看，这不是 bug，但代码意图不清晰。

**推荐**: 将 heartbeat 写入收敛到单一位置（如 accept 循环顶部 + hostMainLoop 循环顶部），移除其他地方的写入。

---

## 🟡 中等问题

### P1-1: ConnLimit 存在 TOCTOU 竞争条件

**位置**: `src/tcp.zig:312-320`

```zig
pub fn tryAcquire(self: *ConnLimit) bool {
    const current = self.count.load(.monotonic);
    if (current >= self.max) return false;
    _ = self.count.fetchAdd(1, .monotonic);
    return true;
}
```

**问题**: `load` 和 `fetchAdd` 之间无原子性保证。两个线程可以同时通过 `current >= self.max` 检查，导致连接数超过限额。

**当前影响**: `DEFAULT_MAX_CONNS = 1000`，在实际使用中不太可能遇到精确的并发竞争。但如果存在大量并发连接（DDoS 场景），限额的精确性会降低。

**修复**:
```zig
pub fn tryAcquire(self: *ConnLimit) bool {
    const prev = self.count.fetchAdd(1, .monotonic);
    if (prev >= self.max) {
        _ = self.count.fetchSub(1, .monotonic);
        return false;
    }
    return true;
}
```

---

### P1-2: IPC 连接无限并发 — 无连接限制

**位置**: `src/ipc.zig:433`, `src/ipc.zig:483`

```zig
_ = rt.spawnBlocking(handleConnection, .{ io, gpa, state_ptr, mesh_ptr, conn }) catch {
    // 仅日志，不阻塞
};
```

**问题**: TCP SOCKS5 连接有 `ConnLimit`（1000），但 IPC 连接没有。如果大量 CLI 命令被并发调用（理论上不太可能，IPC socket 是 root-only 的），线程数可能无限增长。

**当前影响**: 低。IPC socket 是本地 root-only socket，且 CLI 命令是单次调用，不会同时大量连接。但严格来说这是不对称的设计。

**推荐**: 添加 IPC 连接计数，或复用 TCP 的 ConnLimit。

---

### P1-3: LSA Mesh 的 `updateNodeInfo()` 无锁保护

**位置**: `src/lsa.zig:424-434`

```zig
pub fn updateNodeInfo(self: *Mesh, new_info: []const u8) void {
    self.allocator.free(self.node_info);       // 释放旧值
    // ...allocPrint 可能失败...
    self.node_info = with_nonce;               // 设置新值
}
```

**问题**: `node_info` 字符串在多个地方被读取：
- Mesh 线程的 `broadcastOwnLsa()` 使用它构建 LSA 广播
- Host 的 `hostMainLoop` 可能通过外部代码读取

没有 mutex 保护。如果在 `free` 之后但 `allocPrint` 之前有另一个执行上下文读取 `self.node_info`，会触发 use-after-free。

**当前影响**: 在 Host 模式下，`updateNodeInfo` 仅在 Guest 状态变更时调用，且调用者可能在主执行器协程中，与 Mesh 线程形成竞争。在 Guest 模式下，utmmd 不会直接调用 `updateNodeInfo`。

**推荐**: 添加 mutex 保护 `node_info` 的读写，或使用 atomic 指针交换（CAS）。

---

### P1-4: Windows LSA 定时器线程竞争 `clock_ms` + `periodicTasks()`

**位置**: `src/lsa.zig:495-557`

```zig
// 主线程（runWindows）
self.clock_ms +%= 10;
self.periodicTasks();

// 定时器线程（runWindowsTimer）
self.clock_ms +%= 1000;
self.periodicTasks();
```

**问题**: 两个线程同时执行 `periodicTasks()`，该函数内部获取 `neighbors_mutex`、`lsas_mutex` 等。这本身不是 bug（mutex 被正确使用），但：

1. `clock_ms +%= 10` 和 `clock_ms +%= 1000` 在 ARM64 上不是原子操作（读-改-写），两个线程可能同时读写，导致一个更新被另一个覆盖。
2. 两个线程同时竞争 mutex，但 `periodicTasks()` 持有锁的时间很短——LSA 广播 + keepalive 发送。不会死锁，但增加了不必要的锁竞争。

**当前影响**: `clock_ms` 用于 LSA 过期检测（`now - last_seen > 6000` 即 3 个周期），偶尔丢失 1s 级别的更新不影响功能。但定时器线程设计增加了不必要的复杂性。

**推荐**: 改为单个线程 + `receiveTimeout`（类似 POSIX 实现）。当前 Windows 用定时器线程的原因是 Zig 0.16.0 `Io.Threaded` 不支持 Windows 的 `receiveTimeout`。可以考虑用更简单的方案：主循环中 sleep + recv 交替，使用非阻塞 recv。

---

## 🟢 低优先级问题

### P2-1: `std.Io.Mutex` 的 `lock()` 方法需要 io 参数

**位置**: `src/host.zig:1431`, `src/lsa.zig` 多处

```zig
m.lsas_mutex.lock(m.io) catch continue;
```

**问题**: `std.Io.Mutex.lock(io)` 内部使用 `io.futexWait()` —— 这在某些 Io 实现上可能失败。所有调用点都用 `catch continue` 处理，意味着如果 futexWait 失败，锁不会被获取，跳过一次循环迭代。

**当前影响**: 低。`io.futexWait` 在 Threaded Io 上不太可能失败。即使失败也只是跳过一次 LSA 同步。

---

### P2-2: Guest 的 inline 命令处理阻塞 accept 循环

**位置**: `src/guest.zig:980-985`

```zig
// self:2121 — utmm frame protocol, inline handling blocks accept
socks5.replyOk(fd);
var conn = protocol.Connection{ .fd = fd, .alive = true };
handleOneCommand(io, allocator, info, &conn, shutdown, shm_handle) catch |err| {
    std.log.err("[guest] handleOneCommand: {}", .{err});
};
conn.deinit();
```

**问题**: 长时间运行的 exec 命令阻塞整个 accept 循环。但要注意 BIND/UDP_ASSOCIATE/localRelay 已经通过 `group.spawnBlocking` 异步处理了 — 只有 frame protocol 命令是 inline 的。

这是一个设计选择而非 bug（简化模型，无状态），但对长时间 exec（如 `tail -f`）会阻塞新的 SOCKS5 连接。

**推荐**: 如果这成为问题，可以将 exec 也异步处理，但需要引入连接追踪来确保命令完成后关闭。

---

### P2-3: `guestHostsSync` 线程使用与 accept 循环相同的 `io`

**位置**: `src/guest.zig:896`

```zig
hosts_sync_handle = std.Thread.spawn(.{}, guestHostsSync, .{ io, allocator, info, shutdown }) catch null;
```

**问题**: `guestHostsSync` 接收了 accept 循环的 `io`，但内部实际使用的是自己创建的 `Io.Threaded`（因为需要 `std.process.run`）。传入的 `io` 参数被重命名为 `zio_io_unused` 并被忽略。代码是正确的，但接口容易引起误解。

---

## 非问题（已验证安全）

以下模式经审查确认是线程安全的：

### ✅ GuestTable::lockTable() 自旋锁

虽使用 busy-wait 而非 futex，但在 Host 的锁持有时间极短（字符串比较 + 赋值），且仅在 Host 进程中使用。不会导致性能问题。

### ✅ hostMainLoop 双重锁持有（lsas_mutex + GuestTable）

```zig
m.lsas_mutex.lock(m.io) catch continue;   // 先获取 lsas_mutex
defer m.lsas_mutex.unlock(m.io);
// ... 处理 snapshot ...
state.upsert(...);                        // 内部获取 GuestTable mutex
```

锁顺序始终一致（lsas_mutex → GuestTable），不会死锁。`lsas_mutex` 在 snapshot 完成后释放，然后在锁外处理数据——标准的快照模式。

### ✅ fork() + exec() 安全

`startUtmmPosix` 在 fork 之前准备了所有 argv，fork 后子进程立即调用 `execvpeZ`，不分配内存、不获取锁。如果 exec 失败则直接 `exit(1)` 不返回。这是正确的 fork+exec 模式。

### ✅ LSA Mesh 线程独立 Io

Mesh 线程使用自己的 `Io.Threaded`，不与 Host/Guest 的 Io 共享。线程间通信通过：
- mutex 保护的数据结构（neighbors, lsas, routes maps）
- `shutdown: std.atomic.Value(bool)` 用于信号

所有数据共享路径都有正确的同步。

### ✅ SOCKS5 链路转发 — ctx 堆分配 + detach 释放

```zig
const ctx = allocator.create(guest.ForwardCtx) catch {...};
ctx.* = .{...};
group.spawnBlocking(guest.forwardThreadFn, .{ctx}) catch {
    allocator.destroy(ctx);
    // ...
};
// forwardThreadFn:
fn forwardThreadFn(ctx: *ForwardCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.allocator.free(ctx.hostname);
    defer ctx.maybeReleaseLimit();
    socks5.forward(...);
}
```

分配和释放路径正确：spawnBlocking 失败 → 直接 destroy；spawnBlocking 成功 → 线程内 defer 释放。

---

## 修复优先级建议

| 优先级 | 问题 | 预计工作量 | 风险 |
|--------|------|-----------|------|
| **P0** | SHM volatile → atomic/fence | 1-2 天 | 修改 SHM 字段类型可能影响 ABI |
| **P0** | heartbeat 多处并发写入整理 | 半天 | 低风险，仅删除冗余写入 |
| **P1** | ConnLimit TOCTOU 修复 | 10 分钟 | 极低风险 |
| **P1** | IPC 连接限制 | 1 小时 | 低风险 |
| **P1** | updateNodeInfo 无锁 | 1 小时 | 需仔细测试在线升级场景 |
| **P1** | Windows LSA 定时器线程 | 2-4 小时 | 需在 Windows 真机上测试 |
| **P2** | 其他低优先级 | — | 可延后 |

---

## 总体评估

代码库的多线程安全水平**高于平均水平**——所有已知的数据竞争路径都有 mutex 保护，线程生命周期管理正确（defer join/destroy），SOCKS5 relay 的 ctx 堆分配和释放路径正确。

**最大的实际风险是 SHM 的 volatile vs atomic 问题**。在生产环境中（所有 VM 都是 ARM64），弱内存序的 CPU 重排可能导致升级流程中的命令丢失（utmmd 看不到 utmm 设置的 cmd）。当前没有观察到生产问题可能有两个原因：
1. 竞争窗口极小（两个连续的 store 之间几乎没有时间间隙）
2. utmmd 的 1 秒轮询间隔足够长，跨过了可见性延迟

但这不改变问题的本质——在 ARM64 上使用 `volatile` 而非 `atomic` 做跨进程同步是不正确的。
