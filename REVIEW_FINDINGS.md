# Code Review Findings — refac/layered-arch (v0.13.0)

审查范围：16 个核心源文件 + 4 个集成测试文件
审查维度：exec / upload / download / upgrade / service management / mesh networking 完整业务流程

---

## 严重缺陷（Critical）

### C1. Exec 命令双重标记导致所有命令返回 exit code 0

**文件**: `src/guest.zig:858` + `src/ipc.zig:638`

**问题描述**:

Host 端 (`ipc.zig handleExec`) 在构建 `pty_exec_input` 帧之前调用 `buildCmdWithMarker` 为命令添加 MDELIM 标记：

```zig
// ipc.zig:638
const cmd_with_marker = buildCmdWithMarker(gpa, guest.shell, command);
const frame = ptcl.buildPtyExecInput(gpa, cmd_id, cmd_with_marker);
```

Guest 端 (`guest.zig handleExecCmd`) 收到已标记的命令后，**再次**调用本地 `buildCmdWithMarker`：

```zig
// guest.zig:858 — input.command 已经是带标记的命令
const cmd_with_marker = try buildCmdWithMarker(allocator, input.command);
```

**实际执行的命令**（POSIX 为例）:

```
# Host 发送:   ls -la; echo MDELIM:$?\n
# Guest 追标后: ls -la; echo MDELIM:$?\n; echo MDELIM:$?\n
```

第一个 `echo MDELIM:$?` 输出原始命令的真实 exit code（比如 1），
第二个 `echo MDELIM:$?` 输出第一个 echo 的 exit code（**永远是 0**，因为 echo 不会失败）。

`scanForMarker` 使用 `lastIndexOf` 查找最后一个 "MDELIM:"，所以只取到第二个标记的值（永远是 0）。

**影响**: **所有 exec 命令都报告 exit code 0，即使命令实际失败了**。这是数据正确性级别的回归，v0.12.x 中没有这个问题（因为旧架构中只有 Guest 端添加标记）。

**修复方向**: 二选一：
- 移除 Guest 端的 `buildCmdWithMarker` 调用（让 Host 端标记即可）— 但需确认 Host 端的 shell 检测正确
- 移除 Host 端的 `buildCmdWithMarker`（让 Guest 端标记，因为 Guest 最了解自己的 shell）

推荐后者（Guest 端标记），因为 Guest 端知道自己的真实 shell 类型。

---

### C2. GuestTable 无并发保护 — tunnelManager 和 IPC handler 之间的数据竞争

**文件**: `src/host.zig:1060-1160`（GuestTable 定义）+ `src/host.zig:964`（tunnelManager）+ `src/ipc.zig:366`（handleConnection spawn）

**问题描述**:

`GuestTable` 是一个裸的 `std.ArrayList(GuestEntry)`，没有任何内部互斥锁。

访问模式:
- **tunnelManager** (后台线程，每 5s 执行): 调用 `upsert()` 和 `setMeshMac()` — **写入**操作
  - `upsert()` 修改已有条目的字段（free + realloc 字符串）
  - `upsert()` 对新增条目调用 `self.guests.append()` — 可能触发 ArrayList 扩容（realloc）
- **IPC handler 线程** (每个连接一个): 调用 `findByHostname()` — **读取**操作
  - `indexOf()` 遍历 `self.guests.items` 切片

并发场景:
1. tunnelManager 正在 `upsert` 中 `allocator.free(existing.ip)` + `allocator.dupe(u8, ip)`
2. 同时 IPC handler 在 `findByHostname` 中读取 `self.guests.items[idx].ip`
3. → use-after-free / 读取损坏数据

ArrayList 扩容场景:
1. tunnelManager 执行 `self.guests.append()` → 触发扩容 → 释放旧 buffer
2. IPC handler 正在 `indexOf` 中遍历旧的 `self.guests.items` 指针
3. → use-after-free

**影响**: 低概率但高影响的并发 crash。实际触发条件：tunnelManager 的 5s 周期同步恰好与用户发起 `--status` 或 `--exec` 请求重合。

**修复方向**: 为 GuestTable 添加 `std.Io.Mutex`，所有公开方法（upsert、findByHostname、setMeshMac、remove）在入口处加锁。

---

## 重要缺陷（Important）

### I1. ✅ Guest 端自动升级未实现（已修复）

**文件**: `src/guest.zig:801-925` + `src/host.zig:762-882`

**修复内容**:
- Guest 端: `tryPerformUpgrade()` 函数实现完整升级流程 — 从 LSA 数据库查找 Host IP → TCP 连接 Host → 发送 upgrade_req → 接收二进制流保存到 `/opt/utmm/utmm.new` → 通过 shm 通知 utmmd 执行升级
- Host 端: `upgradeTcpListener()` 后台线程在 mesh_port 上侦听 TCP 连接 → `handleUpgradeConnection()` 接收 upgrade_req → 从 serve_dir 读取对应平台的二进制 → 流式返回给 Guest

### I2. genInit 模板使用旧服务名和旧二进制路径

**文件**: `src/svc.zig:1540-1597`

genInit 生成的模板与实际安装的服务不一致：

| 项目 | genInit 模板 | 实际安装 |
|------|-------------|---------|
| 二进制路径 | `/opt/utmm/utmm --svc` | `/opt/utmm/utmmd --role guest\|host` |
| macOS 服务名 | `com.utmm.guest` | `com.utmmd` |
| Linux 服务名 | `utmm-guest` | `utmmd` |
| Windows 服务名 | `UTM-Monitor-Guest` | `UTM-MonitorD` |

**影响**: 用户按 genInit 输出创建的服务配置无法正常工作，因为：
- `utmm --svc` 不是有效的启动命令（正确的守护进程是 `utmmd`）
- 服务名不匹配导致 `isRunning()` 检测失败
- 卸载时无法清理旧服务

**修复方向**: 更新 genInit 模板，使用当前的 utmmd 守护进程模型和服务名。

### I3. 三个 `buildCmdWithMarker` 实现不一致

**文件**: `src/protocol.zig:581-586`, `src/guest.zig:1008-1013`, `src/ipc.zig:909-913`

| 实现位置 | Windows 命令格式 | POSIX 命令格式 | 是否被调用 |
|---------|-----------------|---------------|----------|
| protocol.zig | `{s} & echo MDELIM:%errorlevel%\r\n` | `{s}; echo MDELIM:$?\n` | **否**（死代码） |
| ipc.zig | `{s} & echo MDELIM:%errorlevel%\r\n` | `{s}; echo MDELIM:$?\n` | 是（Host 端） |
| guest.zig | `{s}\r\necho MDELIM:%ERRORLEVEL%\r\n` | `{s}; echo MDELIM:$?\n` | 是（Guest 端，造成 C1） |

Windows 版本的差异:
- ipc.zig/protocol.zig: 用 `&` 连接符，在一行内执行
- guest.zig: 用 `\r\n` 换行符，分成两行

**影响**: 
1. 标记注入行为不一致
2. protocol.zig 的实现未被任何代码调用（死代码）
3. guest.zig 的版本在 C1 修复时需要统一

**修复方向**: 只保留一处实现（建议 `protocol.zig` 中），其他地方通过 `@import("protocol.zig")` 调用。

### I4. 两个 `scanForMarker` 实现不一致

**文件**: `src/protocol.zig:597-607` + `src/guest.zig:1016-1023`

| 特性 | protocol.zig | guest.zig |
|------|-------------|----------|
| 参数 | `*std.ArrayList(u8)` | `[]const u8` |
| 返回 | `MarkerResult{exit_code, found}` | `?i32` |
| 解析 | 逐字符验证数字 + `-` | `parseInt(i32, ...) catch null` |
| 副作用 | 从 ArrayList 中剥离标记 | 无（调用者手动剥离） |
| 被调用 | **否**（死代码） | 是（Guest 端） |

**影响**: 
1. guest.zig 的版本对无效输入更宽容（parseInt 对非数字返回 null，不验证字符）
2. protocol.zig 有更严格的退出码验证但无人使用

**修复方向**: 统一到 protocol.zig 的实现（更严格、更完整），删除 guest.zig 的本地版本。

---

## 次要缺陷（Minor）

### M1. config.zig saveConfig 重复输出 port 行

**文件**: `src/config.zig:91-92`

```zig
try writer.interface.print("port={d}\n", .{config.port});
try writer.interface.print("port={d}\n", .{config.port});  // 重复
```

**修复**: 删除重复行。

### M2. ✅ config.zig loadConfig 是空桩（已修复）

**文件**: `src/config.zig:106-112`

loadConfig 现在返回 `error.Unimplemented`，明确告知调用者配置加载未实现，而非静默返回空 Config。

### M3. heartbeatThread 在 sleep 失败时静默退出

**文件**: `src/main.zig:603-608`

```zig
fn heartbeatThread(h: *volatile shm.ShmLayout, io: std.Io) void {
    while (true) {
        const now = shm.nowMs(io);
        h.utmm_heartbeat = now;
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch break;  // 静默退出
    }
}
```

`io.sleep` 失败时 `catch break` 会静默退出线程。此后心跳停止更新，utmmd 会在 10s 超时后认为 utmm 崩溃并重启它。

**影响**: 概率极低（sleep 很少失败），但发生时会导致不必要的进程重启。

**修复**: 在 break 前记录错误日志：
```zig
std.Io.sleep(...) catch {
    std.log.err("[main] heartbeat sleep failed, exiting", .{});
    break;
};
```

### M4. ✅ tunnelManager 锁持有时间过长（已修复）

**文件**: `src/host.zig:1093-1162`

tunnelManager 重构为两阶段：
1. **加锁、快照**: 在 lsas_mutex 保护下遍历 LSA 表，复制所有 node_id + node_info 到本地 ArrayList
2. **释放锁、处理**: 遍历本地快照，解析 guest 信息、更新 GuestTable、同步 hosts 文件

锁持有时间从整个处理循环（含 allocPrint、upsert、syncHostsFromTable 等重量操作）缩短为仅遍历+复制阶段。

### M5. svc.zig remove 中的条目释放不完整

**文件**: `src/host.zig:1162-1168`

```zig
pub fn remove(self: *GuestTable, hostname: []const u8) void {
    const idx = self.indexOf(hostname) orelse return;
    const entry = self.guests.swapRemove(idx);
    self.allocator.free(entry.hostname);
    self.allocator.free(entry.ip);
    self.allocator.free(entry.target);
    self.allocator.free(entry.mac);
    // shell/status/role 没有释放！
```

`hostname`, `ip`, `target`, `mac` 释放了，但 `version`, `shell`, `status`, `role` 没有释放。对比 `deinit` 方法（line 1071-1083）会释放所有字段。

**影响**: 内存泄漏。`remove` 目前在代码中未被调用（搜索确认），但如果将来使用会造成泄漏。

**修复**: 与 `deinit` 保持一致，释放所有堆分配的字段。

### M6. protocol.zig buildCmdWithMarker 和 scanForMarker 是死代码

**文件**: `src/protocol.zig:581-607`

这两个函数是 `pub` 的，定义在 protocol.zig 中，但没有任何调用者。它们被 guest.zig 和 ipc.zig 的本地实现遮蔽了。

**修复**: 见 I3 和 I4 的统一方案。

---

## 架构级观察（非缺陷）

### A1. TCP 流和帧协议混合使用的文件传输

在 upload/download 流程中，TCP 连接上先是帧协议（upload_cmd / download_cmd），然后是原始字节流（文件内容），最后又是帧协议（upload_result / download 完成）。这种"帧→原始→帧"的混合模式在当前代码中是通过直接读写 `conn.fd` 来实现的：

- `src/ipc.zig` handleUpload: 帧发送 upload_cmd → `std.posix.system.write(tcp_conn.fd, file_data)` → 帧接收 upload_result
- `src/guest.zig` handleUpload: 帧接收 upload_cmd → `std.posix.system.read(conn.fd, buf)` → 帧发送 upload_result

这种模式依赖于双方对"何时切换到原始流"的精确同步。当前实现之所以正确，是因为 upload_cmd 中包含 `file_size`，Guest 知道要读多少字节，之后自动回到帧模式。但如果未来引入更多混合帧/原始的命令类型，容易出错。

**建议**: 在 `tcp.zig` 或 `protocol.zig` 中添加文档注释，说明混合模式的约定。

### A2. shutdown 顺序

`src/host.zig:916-939` 的 shutdown 序列是正确的:
1. IPC shutdown flag → 停止接受新连接
2. mesh.shutdown → tunnelManager 检测并退出
3. join IPC thread → 等待现有连接处理完成
4. join tunnelManager → 等待同步完成
5. join mesh thread → 最后停止 mesh
6. mesh.deinit → 释放 mesh 资源

顺序无问题。但 Windows 上的 IPC shutdown 方式不同（不支持 SHUT_WR），通过 pipe EOF 触发。这在 `ipc.zig` 中有处理。

### A3. 测试覆盖不足

集成测试（`tests/`）覆盖了:
- TCP 帧协议 + SOCKS4a（`tcp_frame`）
- LSA 编解码 + 路由（`lsa_routing`）
- DuplexPipe relay（`dpipe_relay`）
- 自动升级协议（`auto_upgrade`）

**缺失的关键集成测试**:
- **端到端 exec 流程**（Host→Guest 命令执行 + 输出回传）— 这能发现 C1 的双重标记 bug
- **端到端 upload/download 流程**（文件传输 + SHA256 验证）
- **GuestTable 并发安全性**（stress test）

---

## 总结

| 严重度 | 数量 | 关键发现 |
|--------|------|---------|
| Critical | 2 | C1: 双重标记导致 exit code 恒 0；C2: GuestTable 无并发保护 |
| Important | 4 | I1: 升级未实现；I2: genInit 模板过时；I3/I4: 重复/不一致实现 |
| Minor | 6 | M1-M6: 死代码、内存泄漏、日志缺失等 |

**建议优先修复**:
1. **C1**（双重标记）— 影响所有 exec 命令的正确性
2. **C2**（GuestTable 并发）— 低概率但高影响 crash
3. **I2**（genInit 模板）— 用户可见的错误文档
4. **I1**（升级未实现）— 或删除 TODO 注释，或实现完整流程
5. **I3/I4**（合并重复实现）— 减少维护负担
