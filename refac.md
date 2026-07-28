# UTM Monitor 重构设计文档 v2

## 1. 目标与动机

### 1.1 已完成：KCP → TCP+SOCKS4

v0.13.0 已删除 KCP ARQ 协议（~1300 行）及相关模块（tunnel/channel/sess×4/disco/router/upgrade/json/ringbuf/completion），
替换为 TCP + SOCKS4a 传输层。当前 20 文件，124 测试通过。

### 1.2 当前问题

| 症状 | 严重性 | 根因 |
|------|--------|------|
| `state.zig` 是个杂货铺（1386行）— JSON工具+共享状态+连接处理+upgrade+hosts同步 | 致命 | 职责不清，历史上是 httpd.zig |
| `broadcast.zig` 名字有歧义（实为 Guest daemon） | 中 | Legacy 命名 |
| `tcpf.zig` + `socks4.zig` + `netconn.zig` 三文件互相依赖 | 低 | 可合并 |
| `tunproto.zig` 与 `protocol.zig` 职责重叠 | 低 | 各有一个 MsgType |
| `/etc/hosts` 随 LSA 同步逐次累积空行 | 高 | `splitScalar` 逐行遍历 bug |
| `mesh.zig` + `hosts_file.zig` + state Guest 表三处存节点信息 | 中 | 数据冗余 |

### 1.3 设计目标

- **每文件单一职责** — 文件做什么就叫什么名
- **最小依赖图** — 底层模块不依赖上层
- **15 文件以内** — 从 20 → 15
- **消灭 state.zig** — 不再需要跨线程共享状态

---

## 2. 新架构

### 2.1 分层模型

```
┌──────────────────────────────────────────────────────────────────┐
│  应用层                                                           │
│  guest.zig           Host daemon: LSA + IPC + command dispatch    │
│  host.zig            Guest daemon: TCP listen + dpipe relay       │
│  ipc.zig             IPC socket server (CLI/MCP entry)            │
│  mcp.zig             MCP stdio JSON-RPC                           │
├──────────────────────────────────────────────────────────────────┤
│  拓扑层                                                           │
│  lsa.zig             LSA 广播 + 节点表 + /etc/hosts（自洽闭环）    │
├──────────────────────────────────────────────────────────────────┤
│  传输层                                                           │
│  tcp.zig             帧协议 + SOCKS4 + 连接管理                    │
├──────────────────────────────────────────────────────────────────┤
│  数据管道层                                                       │
│  dpipe.zig           DuplexPipe 接口 + relay 引擎                  │
│  dpipe_shell.zig     pty ↔ DuplexPipe                             │
│  dpipe_file.zig      file ↔ DuplexPipe + SHA256                    │
├──────────────────────────────────────────────────────────────────┤
│  协议层                                                           │
│  protocol.zig         所有协议定义（常量+消息类型+序列化+VERSION）   │
├──────────────────────────────────────────────────────────────────┤
│  系统服务层                                                       │
│  install.zig         独立安装程序（可独立构建测试）                  │
│  svc.zig             服务管理库                                    │
│  utmmd.zig           监督进程                                      │
│  shm.zig             共享内存（utmmd↔utmm）                         │
├──────────────────────────────────────────────────────────────────┤
│  基础层                                                           │
│  main.zig            入口、CLI 解析、模式分发                       │
│  fail.zig            快速失败                                      │
│  lock.zig            进程互斥                                      │
│  config.zig          配置持久化                                    │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 依赖图

```
                ┌─────────────┐
                │ protocol.zig │  ← 零依赖
                └──────┬──────┘
       ┌───────────────┼───────────────┐
       ↓               ↓               ↓
  ┌─────────┐    ┌─────────┐    ┌──────────┐
  │ fail.zig │    │ tcp.zig │    │ lsa.zig  │
  └─────────┘    └────┬─────┘    └──────────┘
                      ↓
                 ┌─────────┐
                 │ dpipe   │ ← dpipe_shell / dpipe_file
                 └────┬────┘
        ┌─────────────┼─────────────┐
        ↓             ↓             ↓
   ┌────────┐   ┌────────┐   ┌────────┐
   │ guest  │   │ host   │   │  ipc   │
   └────────┘   └───┬────┘   └───┬────┘
                    │             │
                    └──────┬──────┘
                           ↓
                      ┌────────┐
                      │  main  │
                      └────────┘
```

### 2.3 TCP per-command 模型

KCP 时代的核心痛苦来源：长连接+LSA→KCP tunnel→显式连接管理→跨线程共享状态。

TCP per-command 模型下：**每命令一个独立 TCP 连接**。

```
exec:  cli → ipc → tcp.connect(vm) → send(pty_exec_input) → recv stream → close
upload: cli → ipc → tcp.connect(vm) → send(upload_cmd) → send file bytes → recv result → close
download: cli → ipc → tcp.connect(vm) → send(download_cmd) → recv file bytes → close

Guest 侧：
accept → recv first frame → switch type:
  exec → dpipe.relay(conn, dpipe_shell.create())
  upload → dpipe.relay(conn, dpipe_file.writeFile())
  download → dpipe.relay(conn, dpipe_file.readFile())
```

每命令独立连接 = 无跨线程共享状态 = 不需要 state.zig。

---

## 3. 模块设计

### 3.1 protocol.zig

合并 `tunproto.zig`，废除 `file_chunk`/`file_eof`。

```zig
// 消息类型
pub const MsgType = enum(u8) {
    pty_spawn = 0x10,
    pty_exec_input = 0x11,
    download_cmd = 0x14,
    pty_exec_output = 0x15,
    pty_exec_done = 0x16,
    upload_result = 0x17,
    upgrade_req = 0x19,
    upload_cmd = 0x1b,
    // 0x1c (file_chunk) — 已删除，TCP 流式传输替代
    // 0x1d (file_eof)  — 已删除
};

pub const DEFAULT_PORT: u16 = 2121;
pub const VERSION: []const u8 = ...;  // @embedFile("ver.txt")
pub fn buildCmdWithMarker(...) ...;   // 从 state.zig 迁入
pub fn deploymentFilename(...) ...;
```

### 3.2 tcp.zig

合并 `tcpf.zig` + `socks4.zig` + `netconn.zig`（~530 行）。

```zig
// 帧协议（内部）
fn sendFrame(fd, data) !void;
fn recvFrame(fd, buf) !usize;

// 对外接口
pub const Listener = struct { ... };
pub const Connection = struct {
    pub fn send(self, data) !void;
    pub fn recv(self, buf) !usize;
    pub fn isAlive(self) bool;
    pub fn deinit(self) void;
    pub fn duplex(self) DuplexPipe;  // 适配 dpipe 接口
};
pub fn listen(io, port) !Listener;
pub fn accept(listener) !*Connection;    // SOCKS4a accept
pub fn connect(io, hostname, port) !*Connection;  // SOCKS4a connect
```

### 3.3 lsa.zig

合并 `mesh.zig` + `hosts_file.zig`，自洽闭环。

```zig
pub const Node = struct { hostname, ip, target, mac, version, ... };
pub fn start(io, allocator, port) !*Lsa;   // 启动广播线程
pub fn nodes(self: *Lsa) []const Node;       // 节点列表副本
pub fn onChanged(self: *Lsa, callback) void; // 变化回调 → hosts 同步
pub fn ping(self: *Lsa, hostname) !u64;      // mesh ping
pub fn deinit(self: *Lsa) void;
```

内部自主管理：LSA 广播（2s 间隔）→ 解析→更新节点表→触发 hosts 同步。

**hosts 同步 bug 修复**：用 range replacement 替代逐行遍历。
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

### 3.4 dpipe 体系

#### dpipe.zig — 接口 + relay 引擎

```zig
const VTable = struct {
    readFn: *const fn(*anyopaque, []u8) anyerror!usize,
    writeFn: *const fn(*anyopaque, []const u8) anyerror!void,
    closeFn: *const fn(*anyopaque) void,
};

pub const DuplexPipe = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn read(self, buf: []u8) !usize { return self.vtable.readFn(self.ctx, buf); }
    pub fn write(self, data: []const u8) !void { return self.vtable.writeFn(self.ctx, data); }
    pub fn close(self) void { self.vtable.closeFn(self.ctx); }
};

/// 双向 relay：a→b + b→a，双线程，任一侧关闭即退出
pub fn relay(io: std.Io, a: DuplexPipe, b: DuplexPipe) !void;
```

#### dpipe_shell.zig — pty ↔ pipe

```zig
pub fn create(io: std.Io, allocator: std.mem.Allocator, shell_cmd: []const u8) !DuplexPipe;
// 内部: posix_openpt + fork + setsid + execve
// read() → pty master read
// write() → pty master write
// close() → kill + close
```

#### dpipe_file.zig — file ↔ pipe

```zig
pub fn readFile(io: std.Io, path: []const u8) !DuplexPipe;
// read() → read from file, send data
// write() → error (read-only)
// close() → close fd

pub fn writeFile(io: std.Io, path: []const u8, expected_hash: ?[]const u8) !DuplexPipe;
// read() → error (write-only)
// write() → write to temp file, accumulate SHA256
// close() → verify hash (if provided), atomic rename
```

### 3.5 guest.zig

原名 `broadcast.zig`。Guest daemon：

```zig
pub fn guestDaemon(io, allocator, config) !void {
    var lsa = try lsa.start(io, allocator, config.mesh_port);
    defer lsa.deinit();

    var listener = try tcp.listen(io, config.port);

    while (true) {
        var conn = try tcp.accept(listener);
        // 每个连接独立线程
        const thread = try std.Thread.spawn(.{}, handleConnection, .{io, allocator, conn});
        thread.detach();
    }
}

fn handleConnection(io, allocator, conn) void {
    defer conn.deinit();
    const first_frame = conn.recv(&buf) catch return;
    const msg_type: MsgType = @enumFromInt(first_frame[0]);

    switch (msg_type) {
        .pty_exec_input => {
            const shell = dpipe_shell.create(io, allocator, detectShell(allocator)) catch return;
            defer shell.close();
            dpipe.relay(io, conn.duplex(), shell) catch {};
        },
        .upload_cmd => {
            const file = dpipe_file.writeFile(io, path, hash) catch return;
            defer file.close();
            dpipe.relay(io, conn.duplex(), file) catch {};
        },
        .download_cmd => {
            const file = dpipe_file.readFile(io, path) catch return;
            defer file.close();
            dpipe.relay(io, conn.duplex(), file) catch {};
        },
        else => {},
    }
}
```

### 3.6 host.zig

```zig
pub fn hostDaemon(io, allocator, config) !void {
    var lsa = try lsa.start(io, allocator, config.mesh_port);
    defer lsa.deinit();

    var ipc_server = try ipc.start(io, allocator);
    defer ipc_server.deinit();

    // 主循环：IPC 请求 → tcp.connect(vm) → 发送命令 → 流式返回
    while (ipc_server.nextRequest()) |req| {
        switch (req.type) {
            .exec => handleExec(io, allocator, req),
            .upload => handleUpload(io, allocator, req),
            .download => handleDownload(io, allocator, req),
            .status => handleStatus(lsa.nodes(), req),
            .ping => handlePing(lsa, req),
        }
    }
}
```

### 3.7 系统服务层

`install.zig` 可独立构建：

```zig
// build.zig:
const installer = b.addExecutable({ .name = "utmm-install", ... });
installer.root_module.addImport("svc", svc_module);
const install_test = b.step("installer", "Build standalone install test binary");
```

整合当前分散的代码：
- `svc.zig`(1387行) — 服务管理库
- `main.zig` 中的 `extractUtmmd`/`selfCopy`/`canonicalSvcPath`(~200行)
- `utmmd.zig`(670行) — 监督进程（作为 install 的嵌入或独立）

---

## 4. 实施计划

### Phase 1: 低风险合并（文件合并，逻辑不变）

| # | 任务 | 产出 | 测试 |
|---|------|------|------|
| 1 | `tcpf.zig` + `socks4.zig` + `netconn.zig` → `tcp.zig` | 530行，统一对外接口 | 12 测试→tcp.zig |
| 2 | `tunproto.zig` → `protocol.zig` | 协议定义合一 | 合并测试 |
| 3 | `mesh.zig` + `hosts_file.zig` → `lsa.zig` | 自洽 LSA | 合并测试 |
| 4 | 修复 `/etc/hosts` 空行累积 bug | range replacement | 新增测试 |

### Phase 2: 核心重构

| # | 任务 | 产出 | 测试 |
|---|------|------|------|
| 5 | 新建 `dpipe.zig` + `dpipe_shell.zig` + `dpipe_file.zig` | DuplexPipe 体系 | 边界测试 |
| 6 | `broadcast.zig` → `guest.zig`，移植到 dpipe | TCP accept + relay | 功能测试 |
| 7 | 简化 `tunproto` → 删除 `file_chunk`/`file_eof` | 精简 wire 协议 | 更新测试 |
| 8 | 重构 `host.zig` + `ipc.zig`，消灭 `state.zig` | IPC 直接操作 tcp.Connection | 功能测试 |

### Phase 3: 系统服务

| # | 任务 | 产出 | 测试 |
|---|------|------|------|
| 9 | `install.zig` 独立构建 | 可独立测试的安装程序 | 大量边界测试 |
| 10 | 更新 `build.zig` 适配新模块 | 编译+测试全绿 | CI |

---

## 5. 删除文件清单

| # | 文件 | 原因 |
|---|------|------|
| 1 | `state.zig` | 拆散，TCP per-command 无需共享状态 |
| 2 | `broadcast.zig` | → `guest.zig`（重命名，职责清晰） |
| 3 | `mesh.zig` | → `lsa.zig` |
| 4 | `hosts_file.zig` | → `lsa.zig` |
| 5 | `tunproto.zig` | → `protocol.zig` |
| 6 | `tcpf.zig` | → `tcp.zig` |
| 7 | `socks4.zig` | → `tcp.zig` |
| 8 | `netconn.zig` | → `tcp.zig` |
| 9 | `cmdchan.zig` | TCP per-command 无需跨线程命令队列 |

## 6. 最终文件清单（15 文件）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── lock.zig          进程互斥
├── config.zig        配置持久化
├── lsa.zig           LSA + 节点表 + /etc/hosts
├── tcp.zig           帧协议 + SOCKS4 + 连接
├── dpipe.zig         DuplexPipe 接口 + relay
├── dpipe_shell.zig   pty→pipe
├── dpipe_file.zig    file→pipe
├── guest.zig         Guest daemon
├── host.zig          Host daemon
├── ipc.zig           IPC socket
├── mcp.zig           MCP stdio
└── svc.zig           服务管理（含 install/shutdown/uninstall）
    utmmd.zig         监督进程（嵌入 main）
    shm.zig           共享内存（utmmd 用）
```

> 注：`svc.zig` + `utmmd.zig` + `shm.zig` 三者构成系统服务层。`install.zig` 若独立构建则作为单独入口。
> 最终计数取决于 install 是否独立文件。

---

## 7. 关键决策记录

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接模型 | 消除跨线程共享状态需求 |
| 2 | DuplexPipe vtable 模式 | Zig 惯用，可扩展，可测试 |
| 3 | SOCKS4a 内嵌在 tcp.zig | 代码量小(120行)，无需独立文件 |
| 4 | 删除 file_chunk/file_eof | TCP 可靠传输无需分块校验 |
| 5 | lsa.zig 自洽 | LSA + 节点表 + hosts 三者合一，消除数据冗余 |
| 6 | state/cmdchan 删除 | TCP per-command 无共享状态 |
| 7 | ipc+shm 保留两个 | 生命周期、数据量、可靠性需求根本不同 |
| 8 | per-command shell（不保留 cd/export） | 简单，匹配独立连接模型 |
