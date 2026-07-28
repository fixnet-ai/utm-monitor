# 方案 A：单线程 KCP + 通道分离 — 架构重构设计

## 目录

1. [当前架构与瓶颈分析](#1-当前架构与瓶颈分析)
2. [目标架构](#2-目标架构)
3. [关键组件设计](#3-关键组件设计)
4. [分阶段实施计划](#4-分阶段实施计划)
5. [性能模型](#5-性能模型)
6. [风险评估](#6-风险评估)

---

## 1. 当前架构与瓶颈分析

### 1.1 线程拓扑（Host 侧）

```
主线程 (block_io)
├── Mesh 线程 (mesh_io, ThreadedIo)
│   └── mesh.run() — UDP recv + kcp.input() + periodicTasks (kcp.update/flush)
├── IPC 服务器线程 (block_io)
│   └── accept 循环 → 每个连接 spawn 独立线程 (detached)
│       └── handleExec / handleUpload / handleDownload
│           └── 直接操作 KCP（通过 sessions_mutex 同步）
└── Tunnel Manager 线程 (block_io)
    └── LSA→Guest Table 同步 + m.connect() 建立隧道
```

### 1.2 核心矛盾：`sessions_mutex` 三向竞争

```
KCP 设计：单线程调用 (send/recv/input/update/flush 全在同一线程)

我们的实现：
  Mesh 线程 ──lock──→ kcp.input(ACK)  \
  IPC 线程1 ──lock──→ kcp.send(chunks)  ├── 三方竞争同一把锁
  IPC 线程2 ──lock──→ kcp.recv()        /
```

**每次锁交接的代价**：

```
时间轴（上传 10MB）：
  0.0ms  IPC 获取锁 → send 32 chunks → flush → UDP 发出
         IPC 释放锁
         Mesh 获取锁 → kcp.input(ACK) → snd_una 前进 → cwnd 增长
         Mesh 释放锁
  5.0ms  IPC sleep 结束（白白浪费!）
  5.1ms  IPC 获取锁 → send 32 more chunks → flush
         ...
  
  总耗时: 272 batches × 5ms sleep + KCP 传输时间 ≈ 8分钟
  有效吞吐: ~20 KB/s（本机 UDP ping 0.01ms，理论可达 100+ MB/s）
```

### 1.3 全部瓶颈

| # | 瓶颈 | 严重度 | 根因 |
|---|------|--------|------|
| 1 | `sessions_mutex` 线程竞争 | **致命** | KCP 单线程模型被多线程 mutex 破坏 |
| 2 | KCP 发送窗口 IKCP_WND_SND=32 | 严重 | 在途数据上限 38KB，必须等 ACK 才能发下一批 |
| 3 | cwnd 慢启动 (0→32) | 显著 | 本机网络上纯浪费时间，需 nocwnd=true |
| 4 | 5ms sleep 硬编码让步 | 显著 | 猜测的等待时间，多数是空转 |
| 5 | 1200B 单片 chunk | 中等 | 10MB = 8700 chunks = 8700 次 send+flush+ACK |
| 6 | `sendAndFlush` 逐 chunk 调用 | 中等 | 每 chunk 独立 lock→send→flush→unlock |
| 7 | KCP interval rate limiter (100ms) | 轻微 | `flush()` 直接调用可绕过，但 `update()` 仍受限 |

---

## 2. 目标架构

### 2.1 核心原则

> **KCP 的所有操作（send/recv/input/update/flush）在唯一的一个线程中执行。**
> **其他线程通过无锁通道提交命令、传输数据、接收完成通知。**

### 2.2 线程拓扑（重构后）

```
┌──────────────────────────────────────────────────────────────┐
│                    Mesh I/O 线程 (唯一 KCP 线程)               │
│  (mesh_io, ThreadedIo)                                       │
│                                                              │
│  Event Loop: poll([UDP socket, cmd_channel_read_fd])         │
│                                                              │
│  ┌ UDP 可读:                                                 │
│  │   kcp.input(data) → 处理 ACK → snd_una 前进 → 释放窗口    │
│  │   kcp.recv() → 分发:                                      │
│  │     pty_exec_output → 写入完成通道 → signal               │
│  │     file_chunk → 写入完成通道 → signal                     │
│  │     file_eof → 完成操作                                   │
│  │   LSA/Ping/Pong (不变)                                     │
│  │                                                           │
│  ┌ cmd_channel 可读:                                          │
│  │   读取命令 → 分发:                                         │
│  │     CmdExec → kcp.send(pty_exec_input)                    │
│  │     CmdUpload → 从 ring buffer 读文件 → kcp.send()         │
│  │     CmdDownload → kcp.send(download_cmd) → 循环收 chunk    │
│  │     CmdStatus → 收集状态 → 写入完成通道                    │
│  │                                                           │
│  ┌ 定时器 (每 ~1s):                                           │
│  │   kcp.update() → kcp.flush() for ALL sessions             │
│  │   keepalive 探测                                          │
│  │   LSA 广播、路由重建                                       │
│  │   超时检测                                                 │
│  │                                                           │
│  ★ 无锁！KCP send/recv/input/update 全在同一线程              │
│  ★ ACK 即时处理（收到 UDP 包 → 立即 input → 立即 flush）       │
│  ★ cwnd 自然增长，每次 poll 迭代都能发送新数据                  │
└──────────┬───────────────────────────────────────────────────┘
           │
           │  cmd_channel: lock-free SPSC queue + eventfd
           │  data_ring:   lock-free SPSC ring buffer (256KB)
           │  completion:  per-op eventfd → IPC 线程被唤醒
           │
┌──────────┴───────────────────────────────────────────────────┐
│                    IPC 服务器线程 (block_io)                   │
│                                                              │
│  accept 连接 → 解析请求 → 创建命令 → 推入 cmd_channel          │
│  上传: 读文件 → 写入 data_ring → 等待完成                      │
│  下载: 推入命令 → 从 data_ring 读 → 流式写给客户端              │
│  执行: 推入命令 → 从 data_ring 读输出 → 流式写给客户端          │
│                                                              │
│  ★ 只做 I/O 和命令编排，不碰 KCP                               │
│  ★ 可以多个连接并发（命令排队提交）                             │
│  ★ 无需 sessions_mutex、无需 state.mutex（大部分场景）          │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 命令流详解

#### 上传 (Host → Guest, 10MB)

```
Step 1: IPC 线程
  - 解析上传请求头 (vm, dest_path, hash, file_size)
  - 分配 cmd_id = "upload_<ts>"
  - 创建 Completion 对象（含 eventfd）
  - push CmdUpload{cmd_id, vm, dest_path, file_size} → cmd_channel

Step 2: Mesh 线程（收到 CmdUpload）
  - state.getGuestTunnel(vm) → tun（单线程访问，无需锁）
  - 构建 upload_cmd 帧 → kcp.send()
  - kcp.flush()

Step 3: IPC 线程（并发，不等 Mesh 线程响应）
  - 读取文件 → 每 32KB 写入 data_ring
  - 如果 data_ring 满 → 阻塞等待 Mesh 线程消费

Step 4: Mesh 线程（循环）
  - 检查 data_ring 有数据
  - 读 32KB → 构建 file_chunk 帧 → kcp.send()
  - kcp.flush() → UDP 发出
  - 等待 ACK（自然出现在下一个 poll 周期）
  - 继续读 data_ring → send → flush
  - 文件发完 → kcp.send(file_eof)
  
Step 5: Mesh 线程（收到 Guest 的 upload_result ACK）
  - 写入 completion 结果
  - completion.event.set() → 唤醒 IPC 线程

Step 6: IPC 线程（被唤醒）
  - 读 completion 结果（exit_code）
  - 发送 OK/Error 响应给客户端

关键: Mesh 线程发送 KCP 数据的同时，ACK 由同一个事件循环即时处理。
      无需 sleep、无需 mutex、无锁竞争。
```

#### 下载 (Guest → Host, 10MB)

```
Step 1: IPC 线程
  - push CmdDownload{cmd_id, vm, remote_path} → cmd_channel
  - 等待 completion 或 stream_data 事件

Step 2: Mesh 线程
  - kcp.send(download_cmd)
  - kcp.flush()

Step 3: Mesh 线程（循环接收）
  - kcp.recv() → file_chunk
  - 写入 data_ring
  - completion.event.set() → 通知 IPC："有数据"

Step 4: IPC 线程（被通知）
  - 从 data_ring 读 chunk
  - 写二进制帧 (download_data header + raw data) 到客户端 socket
  - 继续等待下一个通知

Step 5: Mesh 线程
  - kcp.recv() → file_eof
  - 标记完成，最终 event.set()

Step 6: IPC 线程
  - 发送 download_done 帧给客户端
```

---

## 3. 关键组件设计

### 3.1 命令通道 (`src/cmdchan.zig`) — NEW

```zig
/// Lock-free SPSC (Single Producer, Single Consumer) command queue.
/// IPC thread (single producer) → Mesh thread (single consumer).
///
/// Fixed-size ring buffer with power-of-2 capacity. Uses atomic load/store
/// with acquire/release ordering for thread-safe head/tail access.
///
/// Integration with Io.Event for blocking wait:
///   - Producer: push() then event.set() to wake consumer
///   - Consumer: event.waitTimeout() then popAll() to drain

const CMD_QUEUE_CAPACITY = 256; // must be power of 2

pub const CmdQueue = struct {
    buf: [CMD_QUEUE_CAPACITY]Cmd,
    // Head: consumer (mesh thread) reads from here
    // Tail: producer (IPC thread) writes to here
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    wake_event: std.Io.Event, // signaled by producer when new commands are available

    /// Push a command. Returns false if queue is full (IPC thread should retry).
    pub fn push(self: *CmdQueue, cmd: Cmd) bool { ... }

    /// Pop all available commands. consumer_buf receives at most consumer_buf.len items.
    /// Returns count of commands popped.
    pub fn popBatch(self: *CmdQueue, consumer_buf: []Cmd) usize { ... }

    /// Block until commands are available (called by mesh thread).
    pub fn wait(self: *CmdQueue, io: std.Io, timeout: std.Io.Timeout) !void {
        try self.wake_event.waitTimeout(io, timeout);
        self.wake_event.reset();
    }
};

pub const Cmd = struct {
    tag: CmdTag,
    cmd_id: [32]u8,    // fixed-size, no heap alloc
    vm: [32]u8,
    // Inline data for small fields; large data goes through ring buffer
    arg1: [256]u8,     // path/command
    file_size: u32,
};

pub const CmdTag = enum(u8) {
    exec,
    upload,
    download,
    status,
    ping,
};
```

### 3.2 数据传输环形缓冲区 (`src/ringbuf.zig`) — NEW

```zig
/// Lock-free SPSC ring buffer for file data transfer.
///
/// IPC thread writes file data for upload (IPC→Mesh).
/// Mesh thread writes file data for download (Mesh→IPC).
///
/// Uses atomic head/tail with acquire/release ordering.
/// Fixed 256KB capacity — streaming design, not whole-file buffer.

const RING_CAPACITY: usize = 256 * 1024; // power of 2

pub const RingBuf = struct {
    buf: [RING_CAPACITY]u8,
    read_pos: std.atomic.Value(u32),   // consumer reads from here
    write_pos: std.atomic.Value(u32),  // producer writes to here
    // Both positions are monotonic counters (u32 wraps naturally)
    // usable_space = CAPACITY - (write_pos - read_pos)
    // available_data = write_pos - read_pos

    /// Write data. Returns actual bytes written (may be less if buffer is near full).
    /// Caller should loop to write all data.
    pub fn write(self: *RingBuf, data: []const u8) usize { ... }

    /// Read data. Returns actual bytes read (may be less than buf.len).
    pub fn read(self: *RingBuf, buf: []u8) usize { ... }

    /// Bytes available to read (for consumer).
    pub fn available(self: *RingBuf) usize { ... }

    /// Free space available for writing (for producer).
    pub fn free(self: *RingBuf) usize { ... }
};
```

### 3.3 完成通知通道 (`src/completion.zig`) — NEW

```zig
/// Per-operation completion handle.
/// IPC thread creates one, passes it with the command, waits on it.
/// Mesh thread writes results and signals completion.

pub const Completion = struct {
    event: std.Io.Event,    // eventfd (POSIX) / Event (Windows)
    done: std.atomic.Value(bool),
    exit_code: i32,
    // For streaming output (exec, download), data goes through RingBuf
    // rather than being buffered here.

    pub fn init(io: std.Io) !Completion { ... }
    pub fn deinit(self: *Completion, io: std.Io) void { ... }

    /// Signal completion (called by mesh thread).
    pub fn complete(self: *Completion, io: std.Io, exit_code: i32) void { ... }

    /// Wait for completion (called by IPC thread).
    pub fn wait(self: *Completion, io: std.Io, timeout: std.Io.Timeout) !i32 { ... }
};
```

### 3.4 Mesh 线程事件循环重构 (`src/mesh.zig`)

**核心变更**：事件循环从单纯 `poll(UDP)` 变为 `poll(UDP + cmd_channel)`。

```zig
/// Current (mesh.zig):
///   while !shutdown: recv(UDP) → dispatch → periodicTasks

/// After:
pub fn run(self: *Mesh, cmd_queue: *CmdQueue, ...) !void {
    var cmd_buf: [16]Cmd = undefined;

    while (!self.shutdown.load(.acquire)) {
        // Poll: UDP socket + cmd_channel eventfd
        // On POSIX: use kevent/epoll with both fds
        // On Windows: use WaitForMultipleObjects

        // 1. Check UDP
        if (udp_readable) {
            const msg = self.socket.receive(&buf) catch ...;
            self.clock_ms +%= 10;
            dispatch(msg); // handleLsa / handleKcpData / handlePing / handlePong
        }

        // 2. Check commands
        if (cmd_readable) {
            const count = cmd_queue.popBatch(&cmd_buf);
            for (cmd_buf[0..count]) |cmd| {
                self.dispatchCmd(cmd); // → handleCmdExec / handleCmdUpload / ...
            }
        }

        // 3. Periodic tasks (rate-limited by clock_ms)
        self.periodicTasks();
    }
}
```

**关键**：UDP 和 cmd_channel 在同一个 poll 中，ACK 和数据发送在同一个事件循环迭代中完成。没有线程切换延迟。

### 3.5 Tunnel 简化 (`src/tunnel.zig`)

**移除**：`lock()` / `unlock()` / `sendLocked()` / `flushLocked()` / `sessions_mutex` 依赖

```zig
/// After: All methods are single-threaded. No locking needed.

pub fn send(self: *Tunnel, data: []const u8) !usize {
    try self.session.kcp_inst.send(data);
    return data.len;
}

pub fn recv(self: *Tunnel, buf: []u8) !usize { ... }  // unchanged
pub fn flush(self: *Tunnel, current_ms: u32) void { ... }
pub fn waiting(self: *Tunnel) usize { ... }
```

### 3.6 IPC 处理器简化 (`src/ipc.zig`)

**Before**: handleUpload 直接调 tun.sendAndFlush()，锁 sessions_mutex，跑 sleep 循环

**After**: 只做 I/O + 命令编排

```zig
fn handleUpload(io, gpa, state_ptr, conn, header) void {
    // Parse header as before...
    const cmd_id = ...;
    const file_size = ...;

    // Get channels from HostState
    const state = @as(*HostState, @ptrCast(@alignCast(state_ptr)));

    // Create completion
    var completion = Completion.init(io) catch { sendError(...); return; };
    defer completion.deinit(io);

    // Push command to mesh thread
    const cmd = Cmd{
        .tag = .upload,
        .cmd_id = cmd_id,
        .vm = vm,
        .arg1 = dest_path,
        .file_size = file_size,
    };
    while (!state.cmd_queue.push(cmd)) {
        // Queue full — mesh thread is busy. Brief yield.
        std.Io.sleep(io, .fromMs(1), .awake) catch {};
    }
    state.cmd_queue.wake_event.set(io);

    // Stream file data through ring buffer
    var file_buf: [32768]u8 = undefined; // 32KB chunks
    var total: u32 = 0;
    while (total < file_size) {
        const to_read = @min(file_buf.len, file_size - total);
        const n = conn.readFull(file_buf[0..to_read]) catch { ... };
        // Write to ring buffer for mesh thread to consume
        var written: usize = 0;
        while (written < n) {
            written += state.upload_ring.write(file_buf[written..n]);
            if (written < n) {
                // Ring full, mesh thread hasn't consumed yet
                std.Io.sleep(io, .fromMs(1), .awake) catch {};
            }
        }
        total += n;
    }

    // Wait for completion
    const exit_code = completion.wait(io, .{ .duration = .{ ... } }) catch { ... };
    // Send response
}
```

### 3.7 HostState 简化 (`src/state.zig`)

**移除**：
- `op_states` HashMap（替换为 Completion 通道）
- `wake_event`（替换为 Completion 通道中的 eventfd）
- `getOpExitCode()` / `scanForMarker()` 中的 event 操作

**新增**：
- `cmd_queue: CmdQueue`
- `upload_ring: RingBuf`（IPC→Mesh）
- `download_ring: RingBuf`（Mesh→IPC）

**保留**：
- `guests` ArrayList + `mutex`（mesh 线程读写，tunnel mgr 读）
- `guest_tunnels` HashMap + `mutex`（mesh 线程写，IPC 线程读）
- `transfers` HashMap

---

## 4. 分阶段实施计划

### Phase 1: 基础组件（预计 1-2 天）

| 任务 | 文件 | 描述 |
|------|------|------|
| 1.1 | `src/cmdchan.zig` | SPSC 命令队列 + `Io.Event` 集成 |
| 1.2 | `src/ringbuf.zig` | SPSC 环形缓冲区 |
| 1.3 | `src/completion.zig` | 完成通知通道 |
| 1.4 | 测试 | 所有三个组件的并发压力测试 |

**验收标准**：
- `zig build test` 全绿，包括新的并发测试
- SPSC 队列：10^6 push/pop，无数据丢失
- Ring buffer：256KB 循环写入/读取，数据一致
- Completion：跨线程 signal/wait 正常

### Phase 2: Mesh 线程重构（预计 2-3 天）

| 任务 | 文件 | 描述 |
|------|------|------|
| 2.1 | `src/mesh.zig` | 事件循环增加 cmd_channel 轮询 |
| 2.2 | `src/mesh.zig` | 添加 `dispatchCmd()` 命令分发 |
| 2.3 | `src/tunnel.zig` | 移除 `lock/unlock/sendLocked/flushLocked` |
| 2.4 | `src/tunnel.zig` | `send()` 不再加锁 |
| 2.5 | `src/mesh.zig` | 移除 `sessions_mutex`（所有 KCP 操作单线程） |
| 2.6 | `src/host.zig` | 创建 CmdQueue，传入 mesh.run() |
| 2.7 | 测试 | 编译通过，现有测试全绿 |

**验收标准**：
- `zig build` 编译通过（可能有未使用的 IPC handler 代码）
- `zig build test` 全绿
- `sessions_mutex` 从 mesh.zig 和 tunnel.zig 中完全移除

### Phase 3: 命令处理实现（预计 2 天）

| 任务 | 文件 | 描述 |
|------|------|------|
| 3.1 | `src/mesh.zig` | `handleCmdExec` — 发送 pty_exec_input + 收集输出 |
| 3.2 | `src/mesh.zig` | `handleCmdUpload` — 从 ringbuf 读文件 + KCP 发送 |
| 3.3 | `src/mesh.zig` | `handleCmdDownload` — 发送 download_cmd + 收集 chunk |
| 3.4 | `src/mesh.zig` | `handleCmdStatus` — 收集 guest 状态 |
| 3.5 | `src/mesh.zig` | `handleCmdPing` — 发送 ping + 等 pong |
| 3.6 | `src/state.zig` | 现有的 `handleMeshGuest` 适配新架构 |

**验收标准**：
- 所有命令类型有对应的 mesh 线程处理函数
- 编译通过

### Phase 4: IPC 层改造（预计 2 天）

| 任务 | 文件 | 描述 |
|------|------|------|
| 4.1 | `src/ipc.zig` | `handleUpload` → 通道模式 |
| 4.2 | `src/ipc.zig` | `handleDownload` → 通道模式 |
| 4.3 | `src/ipc.zig` | `handleExec` → 通道模式 |
| 4.4 | `src/ipc.zig` | `handleStatus` → 通道模式 |
| 4.5 | `src/ipc.zig` | `handlePing` → 通道模式 |
| 4.6 | `src/ipc.zig` | 移除 `clientReadAll` / `readFileAlloc` 等全量缓冲 |

**验收标准**：
- 所有 IPC handler 不直接调任何 KCP 函数
- 编译通过

### Phase 5: 整合与清理（预计 1-2 天）

| 任务 | 文件 | 描述 |
|------|------|------|
| 5.1 | `src/state.zig` | 移除或简化 `op_states`、`wake_event` |
| 5.2 | `src/host.zig` | 简化 `tunnelManager`（可能并入 mesh 线程） |
| 5.3 | `src/broadcast.zig` | Guest 侧移除 5ms sleep，用 KCP 流控替代 |
| 5.4 | 全局 | 移除不再使用的 import、函数、类型 |
| 5.5 | `src/tunproto.zig` | 可选：增大 FILE_CHUNK_DATA_MAX 到 32KB |

**验收标准**：
- `zig build test` 全绿
- 无 dead code 警告
- 代码量净减少（移除的锁/轮询代码 > 新增的通道代码）

### Phase 6: 测试与性能验证（预计 1-2 天）

| 任务 | 描述 |
|------|------|
| 6.1 | 小文件上传 (1KB/10KB/100KB) — MD5 校验 |
| 6.2 | 大文件上传 (10MB/50MB) — MD5 校验 + 耗时 |
| 6.3 | 小文件下载 (1KB/10KB/100KB) — MD5 校验 |
| 6.4 | 大文件下载 (10MB/50MB) — MD5 校验 + 耗时 |
| 6.5 | 命令执行 (exec) — 功能回归 |
| 6.6 | 并发测试 — 多 CLI 同时 exec + upload |
| 6.7 | Guest 自动升级 — 端到端验证 |
| 6.8 | 长时间运行 (24h) — 内存泄漏检测 |
| 6.9 | Windows 编译 + 功能测试 |

**验收标准**：
- 所有文件传输 MD5 一致
- 10MB 上传 < 5 秒（当前 ~8 分钟）
- 10MB 下载 < 5 秒（当前 ~45 秒）
- `zig build test` 全绿，所有平台
- Windows 编译通过

---

## 5. 性能模型

### 5.1 理论分析

```
参数：
  - chunk_size = 32KB (可增大到 ~128KB)
  - KCP MSS = 1242 bytes (IKCP_MTU_DEFAULT - IKCP_OVERHEAD)
  - snd_wnd = 32 segments (IKCP_WND_SND, 编译期常量)
  - 在途数据上限 = 32 × 1242 ≈ 40KB (不变)
  - RTT = 0.01ms (本机 UDP)
  - cwnd 增长: nocwnd=true → 立即达到 snd_wnd

单 chunk (32KB) 的 KCP 分段:
  32KB / 1242 bytes = ~26 segments (frg 分片)

发送流程 (单线程):
  1. kcp.send(32KB chunk) → snd_queue 增加 26 segments
  2. kcp.flush() → snd_queue → snd_buf, 发送 26 UDP 包
  3. 对端收到 26 包 → kcp.input() → kcp.recv() → 发 26 ACK
  4. 本端收到 26 ACK → kcp.input() → snd_una 前进 → cwnd++
  5. 所有 segments 被 ACK → 窗口释放 → 下一 chunk

每轮迭代时间:
  步骤 2-4 在一个 poll 循环中完成 (UDP 写入 + ACK 接收)
  本机 poll 延迟 ≈ 10-50μs

总时间 (10MB, 32KB chunks):
  320 chunks × 50μs poll 延迟 = 16ms
  + 文件 I/O: 10MB / 500MB/s ≈ 20ms
  + KCP 编码/解码开销: 320 × 2 × 26 × 0.5μs ≈ 8ms
  ≈ 50ms (理论)
  
  实际预期 (syscall + 上下文切换): 100-500ms
  吞吐: 20-100 MB/s
```

### 5.2 与当前架构对比

| 指标 | 当前 | 重构后 | 提升 |
|------|------|--------|------|
| 10MB 上传 | ~8 min | < 5 sec | **~100×** |
| 10MB 下载 | ~45 sec | < 5 sec | **~9×** |
| 1MB exec 输出 | 即时 | 即时 | 不变 |
| 并发操作 | 串行 (1 mutex) | 排队 (channel) | 支持并发 |
| 代码复杂度 | sessions_mutex + 3 线程 | 1 线程 + 通道 | 降低 |

### 5.3 进一步优化空间

如果预期吞吐需要 > 100 MB/s，可以在后续迭代中：

1. **增大 IKCP_WND_SND** 从 32 → 128 或 256（改为运行时常量）
2. **增大 chunk size** 到 64KB 或 128KB（减少 KCP 分段开销）
3. **零拷贝文件传输**：用 `sendfile()` / `TransmitFile()` 直接从文件 fd 到 socket
4. **UDP GSO**（Generic Segmentation Offload）：内核级分段，减少 userspace 开销

但这些优化在 10-50 MB/s 已经满足需求的情况下，属于过度设计。

---

## 6. 风险评估

### 6.1 技术风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| Lock-free 队列 bug (data race) | 中 | 高 | Zig `@atomic` 显式内存序 + 压力测试 + TSAN |
| Windows eventfd 替代不可靠 | 中 | 高 | 使用 pipe 自写唤醒（已在 mesh.zig Windows timer 线程中验证） |
| cmd_channel 溢出丢命令 | 低 | 高 | 256 容量 + push 阻塞重试（1ms yield） |
| Ring buffer 死锁（满/空） | 低 | 中 | 明确的读写方向 + 超时退出 |
| Exec 响应延迟增加 | 低 | 中 | 通道提交 + poll 响应 < 1ms（本机） |
| Guest 侧也需适配 | 低 | 低 | Guest 已是单线程，只需移除 sleep hack |

### 6.2 实施风险

| 风险 | 缓解 |
|------|------|
| 重构周期过长影响其他功能 | 分 Phase 实施，每 Phase 独立可测试 |
| 引入回归难以定位 | 保留现有测试，每 Phase 后全量跑 |
| 多平台兼容 (Linux/macOS/Windows) | Phase 1 即覆盖三平台编译 |

### 6.3 不变更的模块

以下模块**完全不改动**：

- `kcp.zig` — KCP 协议实现
- `tunproto.zig` — 隧道协议编解码
- `svc.zig` — 服务管理
- `utmmd.zig` — 守护进程
- `shm.zig` — 共享内存协议
- `config.zig` — 配置文件
- `main.zig` — CLI 入口
- Guest 侧除了 `sendChunkedFile` 的 sleep 移除外不变

---

## 附录：文件清单

| 文件 | 变更类型 |
|------|---------|
| `src/cmdchan.zig` | **新增** — SPSC 命令队列 |
| `src/ringbuf.zig` | **新增** — SPSC 环形缓冲区 |
| `src/completion.zig` | **新增** — 完成通知通道 |
| `src/mesh.zig` | 修改 — 事件循环 + cmd dispatch, 移除 sessions_mutex |
| `src/tunnel.zig` | 修改 — 移除 lock/unlock/sendLocked/flushLocked |
| `src/ipc.zig` | 修改 — IPC handler 改通道模式 |
| `src/state.zig` | 修改 — 简化 op_states，新增通道字段 |
| `src/host.zig` | 修改 — 通道初始化，简化 tunnelManager |
| `src/broadcast.zig` | 修改 — Guest 侧移除 5ms sleep |
