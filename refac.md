# UTM Monitor 重构设计文档 v2

## 状态：已完成 ✅（历史文档 — 当时 codebase 19 src + 13 test 文件，当前 22 src）

**分支**: `refac/layered-arch` | **文件**: 20 → 19 | **测试**: 172 单元 + 59 集成，全部通过

最后更新：Phase 4 完成（代码扫描 + refac.md 修正）

---

## 1. 目标与动机

### 1.1 已完成：KCP → TCP+SOCKS4 → 分层架构

v0.13.0 完整重构历程：
1. 删除 KCP ARQ 协议（~1300 行）→ TCP+SOCKS4a 传输层
2. 分层架构重构（20 → 16 文件）：TCP per-command 模型、DuplexPipe vtable、消灭 state.zig/cmdchan.zig
3. lock.zig 进程锁 → svc.zig 内联 flock/LockFileEx
4. Platform/genInit → svc.zig 聚合

### 1.2 已解决的问题

| 症状 | 解决方案 |
|------|---------|
| `state.zig` 杂货铺（1386行）| 消灭 — GuestTable → host.zig, JSON → protocol.zig |
| `broadcast.zig` 命名歧义 | → `guest.zig` |
| `tcpf+socks4+netconn` 三文件循环依赖 | → `tcp.zig` |
| `tunproto.zig` 与 `protocol.zig` 重叠 | 合并 |
| `/etc/hosts` 空行累积 | range replacement（indexOf 替代 splitScalar）|
| `mesh+hosts_file+GuestTable` 三处冗余 | → `lsa.zig` 自洽闭环 |
| `lock.zig` PID 文件锁 CWD-相对路径 bug | → svc.zig 内联 flock/LockFileEx |
| `cmdchan.zig` 跨线程命令队列 | 删除 — TCP per-command 无需跨线程 |
| `Platform/genInit` 在 host.zig | → svc.zig（与服务管理聚合）|

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
│  svc.zig             服务管理（install/uninstall/启动+Platform/genInit+InstallLock）│
│  utmmd.zig           监督进程                                      │
│  shm.zig             共享内存（utmmd↔utmm）                         │
├──────────────────────────────────────────────────────────────────┤
│  基础层                                                           │
│  main.zig            入口、CLI 解析、模式分发                       │
│  fail.zig            快速失败                                      │
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

`svc.zig` 聚合服务管理、Platform 检测、genInit 和安装锁：

- `svc.zig`(1686行) — 服务管理库：install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock
- `utmmd.zig`(670行) — 监督进程（utmmd↔utmm 通过 shm IPC）
- `shm.zig` — 共享内存协议
- `main.zig` 中的 `extractUtmmd`/`selfCopy`/`canonicalSvcPath`(~200行)

> Task 9 决策：不做独立 install.zig 构建。Platform/genInit 移至 svc.zig 聚合，
> 独立构建收益低（发布目标翻倍 8→16，需重复 embed 和 CLI 解析），与单二进制模型冲突。

---

## 4. 实施计划

### Phase 1: 低风险合并 ✅

| # | 任务 | 状态 |
|---|------|------|
| 1 | `tcpf.zig` + `socks4.zig` + `netconn.zig` → `tcp.zig` | ✅ |
| 2 | `tunproto.zig` → `protocol.zig` | ✅ |
| 3 | `mesh.zig` + `hosts_file.zig` → `lsa.zig` | ✅ |
| 4 | 修复 `/etc/hosts` 空行累积 bug（range replacement）| ✅ |

### Phase 2: 核心重构 ✅

| # | 任务 | 状态 |
|---|------|------|
| 5 | 新建 `dpipe.zig` + `dpipe_shell.zig` + `dpipe_file.zig` | ✅ |
| 6 | `broadcast.zig` → `guest.zig`，移植到 dpipe | ✅ |
| 7 | 删除 `file_chunk`/`file_eof`，简化 wire 协议 | ✅ |
| 8 | 重构 `host.zig` + `ipc.zig`，消灭 `state.zig` + `cmdchan.zig` | ✅ |

### Phase 3: 系统服务 ✅

| # | 任务 | 状态 |
|---|------|------|
| 9 | Platform/genInit → svc.zig（不独立构建，聚合到服务管理层）| ✅ |
| 10 | `lock.zig` → svc.zig 内联 flock/LockFileEx | ✅ |

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
| 10 | `lock.zig` | → svc.zig 内联 flock/LockFileEx |

## 6. 最终文件清单（16 文件）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
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
├── svc.zig           服务管理（install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
└── shm.zig           共享内存（utmmd↔utmm）
```

> 系统服务层：`svc.zig` + `utmmd.zig` + `shm.zig`。lock.zig 已删除（svc.zig 内联 flock/LockFileEx）。
> Task 9 未做独立 install.zig 构建 — Platform/genInit 移至 svc.zig 聚合。

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
| 9 | lock.zig → svc.zig 内联 flock/LockFileEx | OS 级别锁自动随进程退出释放，无 stale lock；固定路径替代 CWD 相对路径 |
| 10 | Platform/genInit → svc.zig（不独立构建 install）| 独立构建收益低（发布目标翻倍、@embedFile 依赖），聚合到服务管理层即可 |
| 11 | auto_upgrade 默认 false | 避免自动升级在测试中干扰；部署时 --auto-upgrade 显式启用 |
| 12 | 独立测试目录 tests/ | 跨模块集成测试程序固化功能需求，防止回归 |


## 8. 集成测试计划

### 8.1 动机

当前测试全部是模块内单元测试（`test "..." {}` 块），没有跨模块验证端到端流程的测试。
这导致修改一个模块时，常常无声地破坏另一个模块的协议兼容性 —— "按下葫芦起来瓢"。

**目标**: 创建 `tests/` 目录，放置独立可执行、跨平台的集成测试程序，每个测试针对特定业务流程，
具备清晰固化的功能需求。不要求 root 权限，不依赖真实 VM。

### 8.2 目录结构

```
tests/
  common.zig              共享测试基础设施（TestRunner、TestCase、TempDir）
  tcp_frame/main.zig       TCP 帧协议 + SOCKS4a 环回测试
  lsa_routing/main.zig     LSA 编解码 + Dijkstra 路由（无网络）
  dpipe_relay/main.zig     DuplexPipe relay + 真实 socket 对
  svc_install/main.zig     安装/卸载：锁、自拷贝、genInit、二进制提取
  auto_upgrade/main.zig    自动升级：版本检测、信号流、upgrade_req 协议
```

### 8.3 设计原则

1. **独立可执行程序** — 每个测试有 `pub fn main()`，可脱离构建系统直接运行
2. **独立构建步骤** — `zig build test-integration` 运行集成测试，与 `zig build test` 分离
3. **子目录隔离** — 每个测试独立子目录，可附加辅助文件不冲突
4. **共享测试库** — `tests/common.zig` 提供 TestRunner / TestCase / TempDir / findFreePort

### 8.4 测试清单

#### Test 1: `tcp_frame` — TCP 帧协议 + SOCKS4a

**涉及模块**: tcp.zig, protocol.zig  
**优先级**: 最高（所有 Guest-Host 通信的基础传输层）

| # | 场景 | 验证方式 |
|---|------|---------|
| 1 | SOCKS4a 完整握手 | TcpListener 监听 127.0.0.1:0 → 客户端 socks4Connect → 服务端 socks4Accept → 验证 hostname/port → 两端确认 SOCKS_REP_OK |
| 2 | TCP 帧协议 | 已连接 TCP 对 → sendFrame → recvFrame → 精确比对内容。含 64KB 大帧 |
| 3 | Connection + 协议消息 | buildPtyExecInput → Connection.sendAndFlush → Connection.recv → parsePtyExecInput → 验证字段一致 |
| 4 | 连接关闭检测 | 客户端 close → 服务端 recv 返回 0 → isAlive() 返回 false |
| 5 | TcpListener 拒绝错误 hostname | 客户端以 "wronghost" 连接 → 服务端 socks4Accept 返回 SOCKS_REP_REJECTED |

**网络**: TCP 环回，无需 root。跨平台（含 Windows ws2_32）。

#### Test 2: `lsa_routing` — LSA 编解码 + Dijkstra 路由

**涉及模块**: lsa.zig  
**优先级**: 高（Mesh 发现骨干，纯逻辑，完全跨平台）

| # | 场景 | 验证方式 |
|---|------|---------|
| 1 | encodeLsa/decodeLsa 往返 | 构造含邻居的 LSA → 编码 → 解码 → 全部字段一致 |
| 2 | NodeId 解析/格式化一致性 | "aa:bb:cc:dd:ee:ff" → parseNodeId → formatNodeId → 原串一致 |
| 3 | Dijkstra 路由（3 节点线形） | A-B-C 拓扑 → rebuildRoutes → routeTo(C) = B |
| 4 | LSA 重启检测（nonce） | 同 nonce→无变更；不同 nonce→检测到变更；缺失 nonce→回退对比 |
| 5 | 邻居过期 | 添加邻居 → 推进时钟 20s → expireStale → 邻居已删除 |
| 6 | LSA 序列号去重 | seq=5 → 拒绝 seq=3（更低）→ 拒绝 seq=5（相同）→ 接受 seq=7（更高）|

#### Test 3: `dpipe_relay` — DuplexPipe 双向转发

**涉及模块**: dpipe.zig, tcp.zig  
**优先级**: 中高（文件上传/下载流式传输核心）

| # | 场景 | 验证方式 |
|---|------|---------|
| 1 | BytePipe 读写 | 写入 "hello"+" world" → 读取验证 → 再读返回 0 (EOF) |
| 2 | BytePipe 大数据 | 写入 128KB → 4KB 分块读 → 验证全部数据 |
| 3 | TCP socket → DuplexPipe 适配 | socket pair → 一端包装为 DuplexPipe → 另一端写入 → DuplexPipe.read 验证 |
| 4 | relay() 双向转发 | 两个 socket pair → relay(A, B) → A 写入 "hello A" → B 读取验证 |
| 5 | relay() EOF 终止 | socket pair → 一端提前关闭 → relay 应正常返回不挂起 |

**网络**: socketpair() (POSIX) / TCP 环回 (Windows)。不支持的子测试标记 SKIP。

#### Test 4: `svc_install` — 安装/卸载

**涉及模块**: svc.zig, main.zig, fail.zig  
**优先级**: 高（部署基础操作，曾出过 lock.zig CWD bug 和 genInit 服务名多次变更）

| # | 场景 | 验证方式 |
|---|------|---------|
| 1 | InstallLock 获取/释放 | 临时锁文件测试 acquire→锁存在→release→再次 acquire 成功。POSIX flock + Windows LockFileEx 双路径 |
| 2 | genInit 脚本生成（3 平台） | 生成 linux/macos/windows 脚本 → 验证服务名 utmmd、二进制路径、--role 参数等模板关键字 |
| 3 | extractUtmmd 二进制提取 | 嵌入的 utmmd.bin → 提取到临时目录 → SHA256 验证 → POSIX 权限位 0o755 |
| 4 | selfCopy 自拷贝完整性 | 自拷贝到临时目录 → 源与目标逐字节比对 → 文件大小一致 |
| 5 | canonicalSvcPath 路径 | POSIX → /opt/utmm/utmm，Windows → C:\opt\utmm\utmm.exe |

**权限**: 无需 root（锁文件用临时目录替代系统路径）。

#### Test 5: `auto_upgrade` — 自动升级

**涉及模块**: lsa.zig, guest.zig, protocol.zig, host.zig  
**优先级**: 高（最复杂的跨模块流程，当前有未完成的 TODO）

| # | 场景 | 验证方式 |
|---|------|---------|
| 1 | LSA 版本不匹配检测 | 注入 "role:host\nversion:9.9.9" → upgrade_needed 被置 true。注入相同版本 → 保持 false |
| 2 | 非 Host LSA 不触发升级 | 注入 "role:guest\nversion:9.9.9" → upgrade_needed 不变（仅 Host 版本触发） |
| 3 | upgrade_req 消息编解码 | buildUpgradeReq → parseUpgradeReq → cmd_id + target 字段一致 |
| 4 | auto_upgrade=false 门控 | upgrade_needed 传 null → 注入版本不匹配 LSA → 不崩溃、无操作 |
| 5 | 版本号格式验证 | isValidVersion("0.11.19")=true; "v0.11.19"=false; "1.2"=false |

### 8.5 构建集成

```zig
const integration_tests = [_]struct { name, path, needs_utmmd: bool }{
    .{ .name = "tcp_frame_int",    .path = "tests/tcp_frame/main.zig",    .needs_utmmd = false },
    .{ .name = "lsa_routing_int",  .path = "tests/lsa_routing/main.zig",  .needs_utmmd = false },
    .{ .name = "dpipe_relay_int",  .path = "tests/dpipe_relay/main.zig",  .needs_utmmd = false },
    .{ .name = "svc_install_int",  .path = "tests/svc_install/main.zig",  .needs_utmmd = true  },
    .{ .name = "auto_upgrade_int", .path = "tests/auto_upgrade/main.zig", .needs_utmmd = false },
};
```

`needs_utmmd: true` 的测试依赖构建管道中的 `hash_utmmd` 步骤，确保 `src/embed/utmmd.bin` + `utmmd.sha256` 已就绪。

### 8.6 实现顺序

| Phase | 内容 | 文件 |
|-------|------|------|
| 1 | 测试基础设施 | `tests/common.zig` |
| 2 | tcp_frame 测试 | `tests/tcp_frame/main.zig` + build.zig |
| 3 | lsa_routing 测试 | `tests/lsa_routing/main.zig` |
| 4 | dpipe_relay 测试 | `tests/dpipe_relay/main.zig` |
| 5 | svc_install 测试 | `tests/svc_install/main.zig` |
| 6 | auto_upgrade 测试 | `tests/auto_upgrade/main.zig` |
