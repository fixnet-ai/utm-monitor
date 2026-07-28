# UTM Monitor 重构设计文档

## 1. 问题诊断

### 1.1 核心症状

当前架构的本质问题：**网络传输、应用会话、进程间通信三层逻辑互相缠绕，没有清晰边界**。

| 症状 | 严重性 | 根因 |
|------|--------|------|
| `state.zig:handleMeshGuest` 一个函数承载 6 种不同关切 | 致命 | 消息分发不按会话类型路由 |
| `ipc.zig:handleUpload` 从 IPC 线程直接调 KCP send | 高危 | IPC 层穿透到传输层 |
| `tunproto.zig` 的 `file_chunk`/`file_eof` 被 upload/download/upgrade 三个操作共用，靠 cmd_id 字符串前缀区分 | 高危 | 协议层缺少会话级路由 |
| 单一 `wake_event` 被 7 个 setter 和 2 个 waiter 共享 | 中危 | 事件语义过度泛化，惊群效应 |
| `broadcast.zig:meshSessionLoop` 一个循环混入升级检测、pty 生命周期、KCP 收发、文件传输 | 致命 | Guest 侧同样无分层 |

### 1.2 根因：分层缺失

当前依赖图实际上只有两层：

```
main.zig ──→ host.zig / broadcast.zig ──→ state.zig ──→ mesh.zig ──→ kcp.zig
                                               │
                                           ipc.zig ─┘（直接操作 state + tunnel）
```

`state.zig` 是事实上的"万能胶水"——所有线程、所有操作都直接读写它。这导致了我们在 v0.13.0 测试中遇到的 exec 挂起问题：IPC 线程等 `op.done`，但 `handleCmdExec` 静默失败后没人设置 `op.done`，共享的 `wake_event` 被其他操作频繁触发导致永远不超时。

---

## 2. 架构设计

### 2.1 核心概念

**Host 是虚拟路由器，不是"服务器"**。

- Guest 之间不能直接通信——所有 UDP 包都经 Host 转发
- Host 自己的 MAC 地址也只是网络上的一个目的地址
- 主标识是 **MAC 地址**，hostname 仅用于展示和 `/etc/hosts` 同步（类似 DNS）

### 2.2 四层模型

```
┌──────────────────────────────────────────────────────────────┐
│ Layer 4: 应用会话层 (session/)                                │
│ ┌──────────┐ ┌──────────────┐ ┌─────────────────────────────┐│
│ │查询会话   │ │执行会话       │ │文件传输会话                   ││
│ │status    │ │exec          │ │upload / download             ││
│ │ping      │ │shell↔channel │ │file↔channel                  ││
│ │纯内存计算 │ │双向流桥接     │ │单向流+EOF MD5校验             ││
│ └──────────┘ └──────────────┘ └─────────────────────────────┘│
│                                                               │
│  接口: Session trait — init() → run() → deinit()              │
│  每个会话 = 1 个 KCP channel + 1~2 个 I/O 线程                  │
├──────────────────────────────────────────────────────────────┤
│ Layer 3: 传输层 (channel/)                                    │
│ ┌────────────────────────────────────────────────────┐       │
│ │ KCP Channel: 可靠的、有序的、双向字节流              │       │
│ │ - send(buf): 追加到 snd_queue (SPSC, 无锁)         │       │
│ │ - recv(buf): 从 rcv_queue 取数据 (SPSC, 无锁)      │       │
│ │ - isAlive(): 死链检测                               │       │
│ │ - create(conv) / destroy()                          │       │
│ └────────────────────────────────────────────────────┘       │
│                                                               │
│  接口: send()/recv() 纯数据，不理解应用语义                      │
│  约束: snd_queue 仅 session 线程写，KCP 线程读                   │
│        rcv_queue 仅 KCP 线程写，session 线程读                   │
├──────────────────────────────────────────────────────────────┤
│ Layer 2: 网络层 (net/)                                        │
│ ┌──────────────────┐  ┌────────────────────────────┐         │
│ │ 设备发现 (ARP)    │  │ MAC 路由 (Router)           │         │
│ │ - LSA 定时广播    │  │ - MAC→channel 映射表        │         │
│ │ - MAC↔IP↔主机名  │  │ - UDP 包按 MAC 转发          │         │
│ │ - 邻居表维护      │  │ - 主机名同步 /etc/hosts     │         │
│ └──────────────────┘  └────────────────────────────┘         │
│                                                               │
│  接口: 按 MAC 收发，hostname 仅做 human-friendly alias          │
├──────────────────────────────────────────────────────────────┤
│ Layer 1: IPC 层 (ipc/)                                        │
│ ┌──────────────────────────────┐                             │
│ │ 本机进程间通信（与网络无关）    │                             │
│ │ - Unix socket / Named pipe   │                             │
│ │ - 二进制帧协议                 │                             │
│ │ - CLI / MCP 接入点            │                             │
│ └──────────────────────────────┘                             │
│                                                               │
│  接口: 通过 SessionManager 创建会话，不直接访问 KCP 或网络       │
└──────────────────────────────────────────────────────────────┘

数据传输方向（关键约束）：
  Session 线程 → channel.send() → KCP snd_queue → KCP 线程 → UDP 网络
  UDP 网络 → KCP 线程 → kcp.input() → KCP rcv_queue → channel.recv() → Session 线程

  所有跨线程访问 KCP 内部队列的操作都是 SPSC：
  - kcp.send() 和 kcp.flush() 在不同线程 → snd_queue 天然 SPSC
  - kcp.input() 和 kcp.recv() 在不同线程 → rcv_queue 天然 SPSC
  - kcp.update() 仅在 KCP 线程调用
```

### 2.3 线程模型

```
┌─────────────────────────────────────────────────────┐
│                   KCP 线程 (单线程)                   │
│                                                     │
│  while (!shutdown) {                                │
│    poll UDP socket                                  │
│    for each received datagram:                      │
│      kcp.input(session, datagram)   // 写入 rcv_queue │
│    kcp.update(all_sessions)         // 更新 RTT/RTO │
│    kcp.flush(all_sessions)          // 读 snd_queue │
│                                     // 发送 UDP      │
│  }                                                  │
│                                                     │
│  仅此线程调用: kcp.update(), kcp.input(), kcp.flush()│
└─────────────────────────────────────────────────────┘

┌───────────────────────┐  ┌───────────────────────┐
│  ExecSession 线程对    │  │  FileSession 线程对    │
│                       │  │                       │
│  [发送线程]            │  │  [发送线程]            │
│  pty.read() →         │  │  file.read() →        │
│  channel.send() →     │  │  channel.send() →     │
│  (追加 snd_queue)      │  │  (追加 snd_queue)      │
│                       │  │                       │
│  [接收线程]            │  │  [接收线程]            │
│  channel.recv() →     │  │  channel.recv() →     │
│  pty.write()           │  │  file.write()         │
│  (消费 rcv_queue)      │  │  (消费 rcv_queue)      │
└───────────────────────┘  └───────────────────────┘

┌───────────────────────┐
│  QuerySession (同步)   │
│                       │
│  无 I/O 线程           │
│  纯内存计算 → 即时返回  │
│  status / ping        │
└───────────────────────┘

┌───────────────────────┐
│  IPC 线程              │
│                       │
│  accept() 循环         │
│  每个连接 → 解析请求   │
│  → SessionManager     │
│  .createSession()     │
│  → 等待结果 → 响应     │
│                       │
│  不直接访问 KCP/网络   │
└───────────────────────┘
```

---

## 3. 模块设计

### 3.1 文件清单 (src/) — 平铺 + 前缀

> **决策**: 采用平铺文件结构。Zig 标准库也是平铺的，项目仅 ~22 个文件，
> 子目录增加的 build.zig 复杂度与收益不匹配。文件名前缀表达分层归属。

```
# ── 入口 ──
main.zig              # CLI 解析、模式分发（不变）
protocol.zig           # 常量、VERSION、部署文件名映射（不变）

# ── Layer 2: 网络层 ──
disco.zig              # 设备发现：LSA 广播，MAC↔IP↔hostname 绑定，邻居表维护
router.zig             # Host MAC 路由：MAC→channel 映射，UDP 包转发，/etc/hosts 同步

# ── Layer 3: 传输层 ──
kcp.zig                # KCP ARQ 协议（纯算法，无 I/O 线程，不变）
channel.zig            # KCP channel：生命周期 (create/destroy)，SPSC send/recv 接口

# ── Layer 4: 应用会话层 ──
sess.zig               # Session trait 定义 + SessionManager（创建/销毁/查询）
sess_exec.zig          # Type B：shell stdio ↔ channel 双向流桥接
sess_file.zig          # Type C：file ↔ channel 单向流 + EOF MD5 校验
sess_query.zig         # Type A：stateless 查询（status/ping），纯内存计算

# ── Layer 1: IPC 层 ──
ipc.zig                # IPC 服务器 + 客户端 + 二进制帧协议（重构但接口不变）
mcp.zig                # MCP stdio JSON-RPC（不变）

# ── 系统运维（独立于四层） ──
upgrade.zig            # Guest 自动升级：版本检测 → KCP 下载 → shm 信号 → utmmd 重启
svc.zig                # 跨平台服务管理（不变）
utmmd.zig              # 守护进程管理器（不变）
shm.zig                # 共享内存协议（不变）

# ── 工具（独立于四层） ──
json.zig               # JSON 序列化/反序列化 helpers（从 state.zig + mcp.zig 提取）
lock.zig               # 进程单例锁
config.zig             # 配置 + 文件日志
fail.zig               # 快速失败
hosts_file.zig         # /etc/hosts 标记块读写
cmdchan.zig            # 无锁 SPSC 命令队列
ringbuf.zig            # 无锁环形缓冲区
completion.zig         # 跨线程完成通知
```

### 3.2 模块职责与导出

#### `disco.zig` — 设备发现

```
职责: LSA 定时广播 + 邻居表维护。类似 ARP 协议。
概念: 使用 MAC 地址作为主标识，hostname 作为易读别名。

导出:
  NodeId       = [6]u8              // MAC 地址
  NodeInfo     = struct {
    id: NodeId,
    hostname: []const u8,
    ip: []const u8,
    target: []const u8,             // OS/arch
    version: []const u8,
    status: []const u8,             // "serving" | "upgrading"
    last_seen_ms: i64,
  }
  NeighborTable = struct { ... }   // NodeId → NodeInfo 映射

  Host 侧:
    init(io, port) → Disco
    start(disco) → void             // 启动 LSA 广播 + 接收线程
    neighbors(disco) → []NodeInfo   // 获取当前邻居列表

  Guest 侧:
    init(io, host_ip, port) → Disco
    advertise(disco, my_info) → void // 持续广播自身信息
```

#### `router.zig` — MAC 路由

```
职责: Host 侧 MAC 地址到 KCP channel 的路由映射。执行 UDP 包转发。

导出:
  ChannelId = u32                   // KCP conversation ID
  RouteTable = struct { ... }       // NodeId → ChannelId 映射

  init(gpa) → Router
  addRoute(router, node_id, channel_id) → void
  removeRoute(router, node_id) → void
  lookup(router, node_id) → ?ChannelId
  syncHostsFile(router, marker) → void  // 从路由表同步 /etc/hosts
```

#### `channel.zig` — KCP Channel

```
职责: KCP session 的生命周期管理和 SPSC 收发接口。不含任何应用逻辑。

导出:
  Channel = struct {
    conv: u32,
    kcp: *kcp.Kcp,

    // SPSC: 仅 session 线程调用
    send(data: []const u8) void     // 追加到 snd_queue（不阻塞、不 flush）
    recv(buf: []u8) usize           // 从 rcv_queue 读取（不阻塞）
    peekSize() usize                // rcv_queue 中可读字节数
    waiting() u32                   // snd_queue 中未确认字节数

    // 仅 KCP 线程调用
    input(data: []const u8) void    // 接收 UDP 数据，写入 rcv_queue
    update(now_ms: u32) void        // 更新 RTT/RTO
    flush(now_ms: u32) void         // 从 snd_queue 读取，通过 output 回调发送

    isAlive() bool
    close() void
  }

  关键约束:
  - send() 绝不阻塞——snd_queue 满时返回 0（调用者负责重试或流控）
  - recv() 绝不阻塞——rcv_queue 空时返回 0
  - KCP 线程独立调用 input/update/flush，与其他线程无竞争
```

#### `sess.zig` — 会话管理

```
职责: 会话类型定义、SessionManager（创建/销毁/查询）

导出:
  SessionType = enum { query, exec, upload, download }
  SessionId = [32]u8

  Session = union(SessionType) {
    query: QuerySession,
    exec: ExecSession,
    upload: UploadSession,
    download: DownloadSession,
  }

  SessionResult = struct {
    exit_code: i32,
    output: ?[]const u8,            // query 类型的结果（allocator 分配）
    file_hash: ?[32]u8,             // file 类型的 MD5
  }

  SessionManager = struct {
    // IPC 线程调用
    createQuery(kind, params) → SessionId
    createExec(vm_mac, command) → SessionId
    createUpload(vm_mac, file_path, file_size, file_hash) → SessionId
    createDownload(vm_mac, remote_path) → SessionId
    waitResult(session_id, timeout_ms) → SessionResult
    cancel(session_id) → void

    // KCP 线程回调
    onChannelData(channel_id, data) → void  // 路由到对应 session
  }
```

#### `sess_exec.zig` — 执行会话

```
职责: shell stdio ↔ channel 的双向流桥接。

Guest 侧:
  spawn(shell_cmd) → ExecSession
    → fork + execve shell
    → 创建 Channel
    → 启动 send_thread: pty.master.read() → channel.send()
    → 启动 recv_thread: channel.recv() → pty.master.write()
    → MDELIM 标记注入 + 检测
    → waitpid → 记录 exit_code → 发送 exec_done 帧

Host 侧:
  create(channel, cmd_id) → ExecSession
    → 启动 recv_thread: channel.recv() → 流式输出到 SessionResult
    → 检测 MDELIM 标记 → 提取 exit_code
    → exit_code 已确定 → 标记 session 完成

帧协议（channel 内）:
  0x01 [cmd_id] [data]        exec_input
  0x02 [cmd_id] [data]        exec_output
  0x03 [cmd_id] [exit_code]   exec_done
```

#### `sess_file.zig` — 文件传输会话

```
职责: file ↔ channel 的单向流 + EOF MD5 校验。

Upload (Host→Guest):
  Host 侧:
    create(channel, cmd_id, path, size, hash) → UploadSession
      → 启动 send_thread: file.read() → channel.send()
      → 全量发送完毕 → 发送 file_eof(exit_code=0, hash=原样传递)
      → 等待 upload_result

  Guest 侧:
    收到 upload_cmd → UploadSession
      → 创建 temp_file
      → recv_thread: channel.recv() → file.write()
      → 收到 file_eof → 关闭文件 → hashFile() 校验
      → 校验通过 → rename temp → dest_path
      → 发送 upload_result(exit_code)

Download (Guest→Host):
  概念: 实际上是 upload 的触发器——Host 发 download_cmd，
        Guest 执行 sendChunkedFile，Host 执行 receiveChunkedFile。

  Guest 侧:
    收到 download_cmd → DownloadSession
      → openFile(path) → 计算 hash
      → send_thread: file.read() → channel.send()
      → 发送 file_eof(exit_code=0, hash=实际计算值)

  Host 侧:
    create(channel, cmd_id) → DownloadSession
      → recv_thread: channel.recv() → 流式输出 + 写本地文件
      → 收到 file_eof → 校验 hash → 标记完成

帧协议（channel 内）:
  0x11 [cmd_id] [path] [size] [hash]           upload_cmd
  0x12 [cmd_id] [path]                         download_cmd
  0x13 [cmd_id] [exit_code]                    upload_result
  0x14 [cmd_id] [data]                         file_chunk (1200B MSS-aligned)
  0x15 [cmd_id] [exit_code] [size] [hash]      file_eof

关键简化:
  - file_chunk/file_eof 不再被三种操作共用——每个 session 实例独占一个 channel
  - cmd_id 仅用于 session 匹配，不再用于区分操作类型
  - Hash 传递: Host→Guest 传原值，Guest 落盘后流式校验
```

#### `sess_query.zig` — 查询会话

```
职责: stateless 查询，纯内存计算，无外部 I/O。

导出:
  QueryKind = enum { status, ping }

  (此模块不创建线程，是同步函数调用)

  handleStatus(router) → []GuestInfo    // 遍历路由表 + 邻居表
  handlePing(node_id, router) → PingResult {
    rtt_ms: u32,
    node_id: NodeId,
  }
```

#### `upgrade.zig` — 自动升级

```
职责: Guest 自动升级——版本检测 → KCP 下载 → shm 信号 → utmmd 重启。
      独立于四层会话模型，因为升级不是用户命令，是系统运维操作。

导出:
  checkVersion(guest_ver, host_ver) → bool
  doUpgrade(channel, target, serve_dir) → void
    // 内部: upgrade_req → file_chunk × N → file_eof → 保存 → shm 信号

注意: 升级内部复用 sess_file.zig 的文件传输能力（通过组合）。
```

#### `json.zig` — JSON 工具

```
职责: JSON 序列化/反序列化 helpers。从 state.zig + mcp.zig 提取合并。

导出:
  // 序列化
  buildJson(allocator, fmt, args) → []const u8
  jsonEscape(allocator, s) → []const u8
  jsonBuildResponse(allocator, id, result_json) → []const u8
  jsonBuildError(allocator, id, code, message) → []const u8
  jsonAppendId(list, allocator, id) → void

  // 反序列化
  jsonGetString(obj, key) → ?[]const u8
  jsonGetInt(obj, key) → ?i64
  jsonGetNestedObject(obj, key) → ?ObjectMap

注意: ipc.zig 不依赖 json.zig（ipc.zig 只做二进制帧协议）。
      host.zig 和 mcp.zig 各自 import。
```

### 3.3 文件映射：旧→新

| 旧文件 | 拆分到 | 说明 |
|--------|--------|------|
| `state.zig` (1431行) | `router.zig` + `sess.zig` + `sess_exec.zig` + `sess_file.zig` | **最大重构项**。JSON helpers 移到 ipc 层 |
| `mesh.zig` (1823行) | `disco.zig` + `channel.zig` + `router.zig` | LSA → disco, KCP session → channel, 路由 → router |
| `broadcast.zig` (2025行) | `disco.zig`(Guest侧) + `sess_exec.zig`(Guest侧) + `sess_file.zig`(Guest侧) | 按会话类型拆分 pty/文件/升级 |
| `tunproto.zig` (679行) | `sess_exec.zig` + `sess_file.zig` | 帧协议随会话类型内聚 |
| `tunnel.zig` (310行) | `channel.zig` | 概念重命名，接口简化 |
| `host.zig` (1334行) | `router.zig` + `sess.zig` + `ipc.zig` | startHost 拆入各层 |
| `ipc.zig` (1519行) | `ipc/ipc.zig` | 移除 handleUpload/handleDownload 中的 KCP 直接调用 |
| 其他 | 不变或仅移动 | kcp, mcp, svc, utmmd, shm, lock, config, fail, cmdchan, ringbuf, completion |

---

## 4. 关键数据流

### 4.1 Exec 命令端到端

```
CLI: utmm --exec linuxvm "ls -la"

  1. IPC Client (ipc.zig)
     → connect(/var/run/utmm.sock)
     → send: [0x02]["linuxvm"]["ls -la"]
     → shutdown(SHUT_WR)

  2. IPC Server (ipc.zig, accept 线程)
     → 解析请求: type=exec, vm="linuxvm", cmd="ls -la"
     → Router.lookup("linuxvm") → node_id (MAC)
     → Router.lookupChannel(node_id) → channel_id
     → sess_mgr.createExec(channel_id, cmd_id, "ls -la; echo MDELIM:$?\n")
       → 创建 ExecSession
       → 启动 recv_thread: channel.recv() → SessionResult.output
     → sess_mgr.waitResult(cmd_id, 30s)
       → recv_thread 检测到 MDELIM → 提取 exit_code
       → 返回 SessionResult{ .exit_code = 0 }
     → IPC 响应: [exec_data][output]...[exec_done][0]

  3. KCP 线程 (独立)
     → channel.flush() → 读取 snd_queue → UDP 发送 exec_input 帧
     → UDP 接收 → channel.input() → 写入 rcv_queue
     → (session recv_thread 从 rcv_queue 消费 exec_output)

  4. Guest 侧 (sess_exec.zig)
     → recv_thread: channel.recv() → 收到 exec_input
     → pty.master.write("ls -la; echo MDELIM:$?\n")
     → send_thread: pty.master.read() → "file1 file2\nMDELIM:0\n"
     → channel.send(exec_output frame)
     → 检测到 MDELIM:0 → 发送 exec_done(exit_code=0)

关键: IPC 线程不接触 channel/kcp/网络，仅通过 SessionManager 接口操作
```

### 4.2 Upload 命令端到端

```
CLI: utmm --upload file.bin linuxvm

  1. IPC Client (ipc.zig)
     → 读取本地文件，计算 SHA256
     → connect → send header: [0x04]["linuxvm"]["/opt/utmm/file.bin"][hash][size]
     → 流式发送 body: 64KB 分块 write

  2. IPC Server (ipc.zig)
     → 解析 header → Router.lookupChannel(node_id)
     → sess_mgr.createUpload(channel_id, cmd_id, path, size, hash)
       → 创建 UploadSession
       → 启动 send_thread: IPC body → channel.send()
     → 等待 upload_result → 响应 OK

  3. KCP 线程
     → channel.flush() → UDP 发送 upload_cmd + file_chunk × N + file_eof

  4. Guest 侧 (sess_file.zig)
     → 收到 upload_cmd → 创建 temp_file
     → recv_thread: channel.recv() → file.write()
     → 收到 file_eof → 关闭文件 → hashFile() → rename
     → 发送 upload_result(exit_code=0)

关键: IPC 线程不调 channel.send()——通过 UploadSession 的接口推入数据
```

---

## 5. 技术风险与缓解

### 5.1 KCP 线程性能瓶颈

**风险**: 单线程 KCP 处理所有 session 的 update/flush/input，在高并发时可能成为瓶颈。

**缓解**:
- 当前实际负载：4 个 Guest，最多同时 2-3 个活跃 session（1 exec + 1 upload/download）
- KCP update 是 O(n) 遍历 snd_buf，flush 是批量编码，每个 session 的耗时在微秒级
- 如果未来 session 数增长，可以按 `conv % N` 分片到多个 KCP 线程

**结论**: 暂不需要处理，单线程足够。

### 5.2 KCP 队列跨线程访问

**风险**: channel.send()（session 线程）和 kcp.flush()（KCP 线程）并发访问
snd_queue；channel.recv() 和 kcp.input() 并发访问 rcv_queue。

**缓解（已决策）**: 保持 KCP 内部 ArrayList 队列不变，在 channel 层加 per-session
spinlock 保护 send/recv 操作。
- `send()` 和 `flush()` 共享 `snd_lock`，临界区极短（一次 ArrayList append vs 一次 drain）
- `recv()` 和 `input()` 共享 `rcv_lock`
- snd_lock 和 rcv_lock 独立，send 和 recv 不互斥
- 不改 KCP 内部实现，保持与 C 参考实现的对应关系

**结论**: ArrayList + spinlock，不改 KCP。

### 5.3 每命令一个 KCP Session 的开销

**风险**: 短命令（如 `echo hello`）如果每次创建新 KCP session，慢启动（cwnd 从 1 开始）会增加延迟。

**缓解**:
- 方案 A: 保持一个常驻 KCP session 用于短命令（exec），长传输（upload/download）才创建新 session。短命令延迟不受影响。
- 方案 B: 所有命令创建新 session，接受首次 RTT 的额外延迟（~5-20ms on LAN）。

**建议**: 方案 A（常驻 session 用于 exec + 信令），方案 B 的延迟在 LAN 环境下可忽略但设计更简洁。**倾向方案 B**——每个命令独立 session 使得资源管理（创建/销毁）完全解耦，bug 面更小。

### 5.4 MAC 寻址与 hostname 迁移

**风险**: CLI 用户习惯用 hostname（如 `linuxvm`），改为 MAC 寻址后用户体验可能下降。

**缓解（已决策）**:
- MAC 寻址仅用于内部路由。CLI 和 MCP 接口保持使用 hostname。
- `Router.lookup(hostname)` → MAC → channel。hostname 是 DNS 角色。
- 对外接口（CLI/MCP）完全不变。

**结论**: 无风险，仅内部重构。

### 5.5 构建系统

**决策**: 平铺文件结构，`build.zig` 无需变更。Zig 的 `@import` 直接按文件名
解析，不依赖目录结构。新增的 `disco.zig`、`router.zig`、`channel.zig`、
`sess_*.zig`、`json.zig`、`upgrade.zig` 均由 `main.zig` 或各消费者直接导入。

**结论**: 无构建复杂度增加。

---

## 6. 迁移策略

### 6.1 原则

1. **渐进式，不激进**: 每一步都保持可编译、可测试
2. **先分层接口，后迁移实现**: 先定义 Session trait / Channel 接口 / Router 接口，再逐步迁移现有代码
3. **Guest 和 Host 独立迁移**: 可以先重构 Host 侧，Guest 保持兼容

### 6.2 阶段划分

| 阶段 | 内容 | 预计影响文件 | 可测试性 |
|------|------|-------------|---------|
| **P0: 接口定义** | 定义 Channel/Session/Router 的公开接口，写 doc comment | 仅新增文件，不修改现有代码 | `zig build` 通过 |
| **P1: Channel 层** | 从 `tunnel.zig` 提取 `channel.zig`，将 KCP snd/rcv_queue 替换为 SPSC ringbuf | kcp.zig, tunnel.zig → channel.zig | 现有 KCP 测试 + 新增 channel 测试 |
| **P2: 网络层** | 从 `mesh.zig` 提取 `disco.zig` + `router.zig`，MAC 寻址 | mesh.zig → disco.zig + router.zig | LSA 测试 + 路由表测试 |
| **P3: 会话层 - query** | 实现 Type A (status/ping)，替换 handleMeshGuest 中的对应分支 | state.zig → sess_query.zig | status/ping 端到端测试 |
| **P4: 会话层 - exec** | 实现 Type B (exec)，Host 侧 session + Guest 侧 pty 桥接 | state.zig + broadcast.zig → sess_exec.zig | exec 端到端测试 |
| **P5: 会话层 - file** | 实现 Type C (upload/download)，Host/Guest 侧文件流桥接 | state.zig + broadcast.zig → sess_file.zig | upload/download 端到端测试 |
| **P6: IPC 层清理** | 从 ipc.zig 移除直接 KCP 调用，改为通过 SessionManager | ipc.zig | 全部 CLI/MCP 命令测试 |
| **P7: 清理** | 删除旧代码（state.zig, mesh.zig, broadcast.zig, tunproto.zig, tunnel.zig） | 旧文件删除 | 全量回归测试 |
| **P8: 跨平台** | 验证 8 个编译目标，Windows 测试 | build.zig | CI 构建 |

### 6.3 每阶段验证标准

每个阶段完成后必须满足：
1. `zig build` 编译通过（native）
2. `zig build test` 全部通过
3. 受影响的 CLI 命令端到端测试通过（通过 `utmm` skill 在真实 VM 上验证）

---

## 7. 已决策

| # | 问题 | 选择 | 关键理由 |
|---|------|------|---------|
| 1 | session 复用策略 | **B: 每命令独立 session** | 简化并发模型，消除 wake_event 惊群，资源管理无状态 |
| 2 | KCP 队列跨线程访问 | **A: ArrayList + per-session spinlock** | 不改 KCP 内部实现，争用窗口极短 |
| 3 | 目录结构 | **B: 平铺 + 文件名前缀** | Zig 惯用风格，build.zig 零变更 |
| 4 | 升级协议归属 | **B: 独立 upgrade.zig** | 系统运维 ≠ 用户命令，内部组合 sess_file 能力 |
| 5 | JSON helpers 归属 | **B: 新建 json.zig** | 独立关切，ipc.zig 不依赖 JSON |
