# DESIGN.md — UTM Monitor 架构设计

## v0.11.0: Mesh+KCP 统一传输（移除 WebSocket）

### 1. 架构演进动机

v0.10.0 引入 mesh 网络后，系统中同时存在两套 Guest-Host 传输层：

| 传输层 | 用途 | 协议 |
|--------|------|------|
| TCP WebSocket | exec, upload, download, announce | wsproto.zig (16 种消息类型) |
| Mesh UDP (KCP) | LSA 路由, KCP 隧道 | mesh.zig + kcp.zig |

双协议导致的问题：

1. **代码复杂度**：`outgoing_frames` 队列、`op_states` 同步、`wake_event` TOCTOU 竞态 —
   httpd.zig 中 ~200 行同步基础设施仅用于桥接 HTTP handler 线程和 WS handler 线程
2. **64KB 帧限制**：`broadcast.zig` 的 `readFrame` 用 64KB 栈缓冲接收 WS 帧，
   `upload_req` 帧包含完整文件数据，大文件上传必定失败
3. **维护负担**：wsproto.zig（16 种 MsgType + build/parse）+ wsclient.zig（WS 握手 + 帧读写）
   共计 ~1000 行，与 mesh 协议功能重叠
4. **概念混乱**：WebSocket 和 KCP tunnel 都是可靠双向流，但系统中两者并存，
   新开发者需要理解两套完全不同的传输机制

**v0.11.0 目标**：删除 WebSocket，mesh + KCP tunnel 成为唯一 Guest-Host 传输层。
HTTP :2121 保留为外部适配器（MCP JSON-RPC + 静态文件服务 + CLI 管理 API）。

### 2. 目标架构

```
                        ┌── MCP HTTP /mcp (JSON-RPC) ← AI Agent
                        ├── CLI HTTP /exec, /upload, /download (/kick)
                        ├── CLI HTTP /api/guests
Host ──KCP Tunnel────→ Guest (pty exec, upload, download, signal)
Host ──UDP LSA ────→ Guest (discovery, 版本检测)
Host ──HTTP /bin/ ──→ Guest (静态文件 + 自动升级下载)
     ←──UDP LSA ──── Guest (node_info 响应)
```

**关键变化**：
- WebSocket 完全移除 — 零 TCP 长连接
- KCP Tunnel 承载所有 Guest-Host 通信（pty、文件传输、信号）
- LSA 承载节点发现和状态同步（无需额外的 announce/status 消息）
- HTTP :2121 仅作为外部接口适配层

### 3. 协议层次

```
┌──────────────────────────────────────────────┐
│         Application Layer                     │
│  tunproto.zig: pty_exec, upload, download    │
│  (1-byte type + null-term strings + BE ints) │
├──────────────────────────────────────────────┤
│         Transport Layer                       │
│  tunnel.zig: send/recv (TCP-like stream)     │
│  kcp.zig: reliable UDP ARQ                   │
├──────────────────────────────────────────────┤
│         Network Layer                         │
│  mesh.zig: LSA routing, KCP relay            │
├──────────────────────────────────────────────┤
│         Physical Layer                        │
│  UDP :2121 (socket.zig)                      │
└──────────────────────────────────────────────┘
```

UDP 端口 2121 的 1-byte dispatch（不变）：
- `0x01` LSA（链路状态广播，替代 announce）
- `0x02` KCP_DATA（KCP 隧道数据）
- `0x03` MESH_PING / `0x04` MESH_PONG（连通性探测）

HTTP 端口 2121（仅 Host 侧）：
- `POST /exec` — 流式 exec（chunked + x-exit-code trailer）
- `POST /upload` — 二进制上传（x-vm + x-path 请求头）
- `POST /download` — 二进制下载（x-vm + x-path 请求头）
- `POST /mcp` — MCP JSON-RPC（AI agent 接口）
- `GET /api/guests` — Guest 列表
- `GET /bin/*` — 静态文件 + 自动升级
- `POST /kick` — 强制断开 guest

### 4. 新模块：tunproto.zig

替换 wsproto.zig，定义 KCP tunnel 内部消息协议。

#### 4.1 消息类型

```
Host → Guest:
  0x10 pty_spawn       触发 pty shell 创建（无 payload）
  0x11 pty_exec_input  cmd_id(NT) + command(NT)
  0x12 signal_cmd      1-byte signal (0=SIGINT, 1=SIGTERM)
  0x13 upload_data     cmd_id(NT) + path(NT) + file_data(4-byte BE len + data)
  0x14 download_cmd    cmd_id(NT) + path(NT)

Guest → Host:
  0x15 pty_exec_output  cmd_id(NT) + chunk_data
  0x16 pty_exec_done    cmd_id(NT) + exit_code(4-byte BE i32)
  0x17 upload_result    cmd_id(NT) + exit_code(4-byte BE i32)
  0x18 download_result  cmd_id(NT) + exit_code(4-byte BE i32) + file_data(4-byte BE len + data)

NT = null-terminated string
BE = big-endian
```

#### 4.2 序列化格式

与 wsproto.zig 的序列化格式完全相同（null-terminated 字符串 + 4-byte BE 长度前缀 blob + 4-byte BE i32），
区别仅在于 type byte 的值和语义。这样移植 build/parse 函数只需改 type 常量。

#### 4.3 与旧 wsproto.zig 的映射

| 旧 wsproto.MsgType | 新 tunproto.MsgType | 变化 |
|-------------------|--------------------|------|
| pty_spawn (12) | pty_spawn (0x10) | type 值变，payload 不变 |
| pty_input (13) | pty_exec_input (0x11) | type 值变，payload 不变 |
| pty_output (14) | pty_exec_output (0x15) | type 值变，payload 不变 |
| pty_signal (15) | signal_cmd (0x12) | type 值变，payload 不变 |
| upload_req (4) | upload_data (0x13) | type 值变，payload 不变 |
| upload_resp (5) | upload_result (0x17) | type 值变，payload 不变 |
| download_req (6) | download_cmd (0x14) | type 值变，payload 不变 |
| download_resp (7) | download_result (0x18) | type 值变，payload 不变 |
| (无) | pty_exec_done (0x16) | **新增**：显式退出码消息 |

#### 4.4 pty_exec_done — 新增消息类型

旧设计中，退出码通过输出流中的 `MDELIM:$?\n` 标记传递（Host 侧 `scanForMarker` 解析）。
新增 `pty_exec_done` 消息提供显式的退出码传递通道：

- Guest 在命令执行完毕后发送 `pty_exec_done`（cmd_id + exit_code）
- Host 收到后调用 `completeOpState(cmd_id, exit_code)`
- `MDELIM` 标记保留作为备选检测手段（scanForMarker 继续工作）

显式消息的优势：
1. 不需要在输出流中搜索标记字符串
2. 退出码传递不受命令回显干扰（macOS/BSD pty ECHO 问题）
3. 命令输出和退出码明确分离

### 5. Guest 侧（broadcast.zig）重设计

#### 5.1 当前架构（WebSocket 模型）

```
wsAnnounceLoop():
  while (true):
    TCP connect to Host → WS handshake → send announce
    收到 pty_spawn → ptySpawn() + ptyReadLoop(conn)
    while (true):
      conn.readFrame() → switch MsgType:
        pty_input → ptyWrite
        upload_req → 写文件 + conn.writeFrame(upload_resp)
        download_req → 读文件 + conn.writeFrame(download_resp)
        pty_signal → killForegroundProcess
      if pty_dead → break
    重连
```

#### 5.2 新架构（Mesh+KCP 模型）

```
meshSessionLoop():
  mesh = Mesh.init(node_id, node_info, upgrade_signal)
  mesh_thread = spawn mesh.run()    // LSA 广播 + KCP 数据收发

  while (true):
    // 等待 Host 建立 KCP 隧道（Host 通过 LSA 发现我们后主动连接）
    tunnel = waitForHostTunnel(mesh)
    // Host 发送 pty_spawn
    tunnel.recv() → pty_spawn
    ptySpawn() + ptyReadLoop(tunnel)  // pty 输出走 tunnel.send()

    // 命令循环
    while (true):
      tunnel.recv(&rbuf) → switch tunproto.MsgType:
        0x11 pty_exec_input → ptyWrite; 执行完毕后 tunnel.send(pty_exec_done)
        0x12 signal_cmd → killForegroundProcess
        0x13 upload_data → 写文件 + tunnel.send(upload_result)
        0x14 download_cmd → 读文件 + tunnel.send(download_result)
        0x10 pty_spawn → 重建 pty
      if pty_dead or tunnel_disconnected → break
    // tunnel 断开 → 回到外层循环，等待 Host 重连
```

#### 5.3 waitForHostTunnel

```zig
fn waitForHostTunnel(mesh: *Mesh) !Tunnel {
    while (true) {
        // 扫描 mesh.sessions，寻找 Host 创建的 session
        var it = mesh.sessions.iterator();
        while (it.next()) |entry| {
            const sess = entry.value_ptr.*;
            if (sess.kcp_inst.peekSize() > 0) {
                return Tunnel.init(allocator, io, sess);
            }
        }
        io.sleep(500 * std.Io.Time.ms) catch {};
        if (shutdown.load(.acquire)) return error.Shutdown;
    }
}
```

Host 端在 LSA 回调中主动调用 `Mesh.connect(guest_node_id)`，这会创建 KCP session
并向 Guest 发送数据。Guest 的 mesh.run() 线程在 `handleKcpData` 中创建对应的 session。
Guest 主循环扫描 sessions 发现有数据的 session → 创建 Tunnel → 进入命令循环。

### 6. Host 侧（httpd.zig + host_http.zig）重设计

#### 6.1 HostState 变化

```zig
// 删除的字段：
outgoing_frames: StringHashMap(ArrayList([]const u8))  // WS frame queue
// 删除的方法：
enqueueOutgoingFrame(), dequeueOutgoingFrame()

// 新增的字段：
guest_tunnels: StringHashMap(*Tunnel)   // hostname → KCP tunnel
on_lsa_received: ?OnLsaCallback         // LSA → guest table 同步回调

// 保留的字段（略有修改）：
guests: ArrayList(HostSideGuest)         // 不变
op_states: StringHashMap(OpState)        // 不变
wake_event: Io.Event                     // 不变
close_requests: StringHashMap(void)      // 不变
```

#### 6.2 HTTP handler 流程变化

**handleExec (旧)**:
```zig
state.createOpState(cmd_id);
state.enqueueOutgoingFrame(vm, frame);  // 放入 WS 队列
// 等 WS handler 线程发送 + 接收响应...
```

**handleExec (新)**:
```zig
state.createOpState(cmd_id);
const tun = state.getGuestTunnel(vm) orelse {
    try respondError(request, .service_unavailable, "GuestNotConnected");
    return;
};
_ = tun.send(frame) catch |err| {  // 直接通过 KCP tunnel 发送
    try respondError(request, .service_unavailable, "TunnelSendFailed");
    return;
};
// 等 handleMeshGuest 线程接收响应 → completeOpState → wake_event.set()
// streaming response 逻辑完全不变
```

#### 6.3 handleMeshGuest — 替代 handleWebSocket

```zig
fn handleMeshGuest(
    allocator: std.mem.Allocator,
    state: *HostState,
    hostname: []const u8,
    tun: *Tunnel,
) void {
    defer {
        state.failAllPendingOps();
        state.removeGuest(hostname);
        state.removeGuestTunnel(hostname);
        syncHostsFromState(state, allocator);
        if (state.on_guest_changed) |cb| cb(state);
    }

    var rbuf: [65536]u8 = undefined;
    while (true) {
        const n = tun.recv(&rbuf) catch |err| {
            std.log.err("[mesh-guest] recv error for {s}: {}", .{ hostname, err });
            return;
        };
        if (n == 0) continue;  // KCP 暂无数据，稍后重试

        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        switch (msg_type) {
            0x15 => { // pty_exec_output
                const out = tunproto.parsePtyExecOutput(payload) orelse continue;
                state.appendOpOutput(out.cmd_id, out.data);
                state.scanForMarker(out.cmd_id);
                state.wake_event.set(state.io.?);
            },
            0x16 => { // pty_exec_done
                const done = tunproto.parsePtyExecDone(payload) orelse continue;
                state.completeOpState(done.cmd_id, done.exit_code);
                state.wake_event.set(state.io.?);
            },
            0x17 => { // upload_result
                const resp = tunproto.parseUploadResult(payload) orelse continue;
                state.completeOpState(resp.cmd_id, resp.exit_code);
                state.wake_event.set(state.io.?);
            },
            0x18 => { // download_result
                const resp = tunproto.parseDownloadResult(payload) orelse continue;
                state.appendOpOutput(resp.cmd_id, resp.file_data);
                state.completeOpState(resp.cmd_id, resp.exit_code);
                state.wake_event.set(state.io.?);
            },
            else => {},
        }

        if (state.checkCloseRequested(hostname)) return;
    }
}
```

#### 6.4 LSA → Guest Table 同步

Host 的 mesh.run() 线程收到 LSA 后，通过回调将 node_info 同步到 HostState.guests：

```zig
fn onLsaReceived(state: *HostState, node_id: NodeId, node_info: []const u8) void {
    const info = protocol.GuestInfo.parse(state.allocator, node_info) catch return;
    defer info.deinit(state.allocator);

    // 更新 guest table
    _ = state.upsertGuest(info.hostname, info.ip, info.target,
        mesh.formatNodeId(node_id, state.allocator) catch return,
        info.version, info.shell);

    // 如果尚无 tunnel，建立连接
    if (state.getGuestTunnel(info.hostname) == null) {
        if (state.mesh) |mesh_ptr| {
            const m: *Mesh = @ptrCast(@alignCast(mesh_ptr));
            if (m.routeTo(node_id)) |_| {
                const tun = state.allocator.create(Tunnel) catch return;
                tun.* = Tunnel.connect(state.allocator, state.io.?, m, node_id) catch {
                    state.allocator.destroy(tun);
                    return;
                };
                state.registerGuestTunnel(info.hostname, tun) catch return;

                // 发送 pty_spawn
                const spawn_frame = tunproto.buildPtySpawn(state.allocator) catch return;
                defer state.allocator.free(spawn_frame);
                _ = tun.send(spawn_frame) catch {};

                // spawn handler 线程
                const hostname_dup = state.allocator.dupe(u8, info.hostname) catch return;
                const t = std.Thread.spawn(.{}, handleMeshGuest, .{
                    state.allocator, state, hostname_dup, tun,
                }) catch return;
                t.detach();
            }
        }
    }
}
```

#### 6.5 Tunnel Manager 线程

周期性检查 guest_tunnels 健康状态：

```zig
fn tunnelManager(state: *HostState) void {
    while (!state.shutdown.load(.acquire)) {
        state.mutex.lock(state.io.?) catch continue;
        defer state.mutex.unlock(state.io.?);

        for (state.guests.items) |*guest| {
            if (state.guest_tunnels.get(guest.hostname) == null) {
                // 尝试重连
                if (state.mesh) |mesh_ptr| {
                    const m: *Mesh = @ptrCast(@alignCast(mesh_ptr));
                    // ... 尝试 Mesh.connect + pty_spawn + spawn handler ...
                }
            }
        }
        state.io.?.sleep(std.Io.Duration.fromSeconds(5), .awake) catch {};
    }
}
```

### 7. KCP 线程安全设计

#### 7.1 问题

旧 tunnel.zig 的 send/recv 都调用 `kcp_inst.update()`：

```zig
pub fn send(self: *Tunnel, data: []const u8) !usize {
    try self.session.kcp_inst.send(data);
    self.session.kcp_inst.update(current_ms);  // ← 与 mesh 线程竞争
    return data.len;
}
```

HTTP handler 线程调用 send，handleMeshGuest 线程调用 recv，
mesh.run() 线程在 periodicTasks 中也调用 update。
三个线程同时操作 KCP 内部状态 → 数据竞态。

#### 7.2 解决方案

tunnel.send/recv 不再调用 `kcp_inst.update()`。KCP update 仅由 `mesh.run()` 的
periodicTasks 调用（~10ms 间隔）。

```zig
// tunnel.zig - 修改后
pub fn send(self: *Tunnel, data: []const u8) !usize {
    try self.session.kcp_inst.send(data);
    // 注意：不调用 kcp_inst.update() — mesh.run() 负责
    return data.len;
}

pub fn recv(self: *Tunnel, buf: []u8) !usize {
    return self.session.kcp_inst.recv(buf);
    // 注意：不调用 kcp_inst.update()
}
```

**为什么安全**：
- `kcp.send(data)` 仅往 `snd_queue` 追加 → 无竞态（追加操作）
- `kcp.recv(buf)` 仅从 `rcv_queue` 读取 → 无竞态（消费操作）
- `kcp.update(ms)` 在 mesh.run() 线程中单线程调用 → 发送/重传/ACK 逻辑线程安全
- KCP 的内部队列（snd_queue, snd_buf, rcv_queue, rcv_buf）设计为单生产者/单消费者

#### 7.3 recv 返回 0 的处理

`kcp.recv()` 在无完整消息时返回 0。调用者需要配合轮询：

```zig
// handleMeshGuest 中的 recv 循环
while (true) {
    const n = tun.recv(&rbuf) catch |err| { ... };
    if (n == 0) {
        // 无数据，短暂等待 KCP update 推送新数据
        io.sleep(1 * std.Io.Time.ms) catch {};
        continue;
    }
    // 处理消息...
}
```

1ms sleep 足以让 mesh.run() 的 periodicTasks（10ms 间隔）推送新数据到达。

### 8. MDELIM 标记保留策略

`MDELIM:$?\n` 标记机制保留，但 `pty_exec_done` 消息提供更可靠的退出码检测：

- **Guest 侧**：命令执行后，echo MDELIM 到 pty + 发送 pty_exec_done 消息
- **Host 侧**：scanForMarker 继续在输出中检测标记；pty_exec_done 收到时直接 completeOpState
- **时序**：pty_exec_done 在 MDELIM 之后发送（确保命令输出已全部发送）

这两个机制共存提供了冗余：如果 pty_exec_done 丢失（tunnel 丢包），MDELIM 标记仍然可用；
如果 MDELIM 被命令回显干扰，pty_exec_done 提供准确的退出码。

### 9. 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/tunproto.zig` | **新建** | 隧道协议 build/parse，替代 wsproto.zig |
| `src/wsclient.zig` | **删除** | WebSocket 客户端（WsConn 类型） |
| `src/wsproto.zig` | **删除** | WebSocket 二进制协议（16 种 MsgType） |
| `src/broadcast.zig` | **重写** | wsAnnounceLoop → meshSessionLoop |
| `src/httpd.zig` | **简化** | 移除 outgoing_frames 及相关方法 |
| `src/host_http.zig` | **重写** | 删除 handleWebSocket，新增 handleMeshGuest |
| `src/mcp.zig` | **适配** | wsproto → tunproto |
| `src/host.zig` | **适配** | 移除 /ws + /announce 路由，新增 LSA 回调 |
| `src/tunnel.zig` | **修改** | send/recv 移除 kcp.update() 调用 |
| `src/mesh.zig` | **扩展** | 新增 LSA 回调机制 |
| `src/protocol.zig` | **扩展** | 无新增 UDP dispatch type（tunnel 消息不在此定义） |
| `src/main.zig` | **更新** | comptime block 移除 wsclient/wsproto |

### 10. 验证顺序

严格按以下顺序验证，每一层通过后再进入下一层：

```
第 1 层：单元测试 + 交叉编译
  zig build test → 全绿
  8 目标交叉编译 → 全过

第 2 层：本机双端口 Mock 协议测试
  Host（端口 A）+ Guest（端口 B）→ 同一台机器
  测试：--status, --exec, --upload, --download

第 3 层：本机 MCP 接入测试
  curl POST /mcp → tools/list, vm_status, vm_exec

第 4 层：安装/卸载/自动升级测试
  --install / --uninstall / --install --user / --uninstall --user
  版本 bump → Guest 自动升级

第 5 层：真实 VM 网络测试
  全部 4 台 VM → 完整功能验证
```
