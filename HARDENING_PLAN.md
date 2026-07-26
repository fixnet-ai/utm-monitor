# UTM Monitor — 加固优化计划

各模块异常处理和边界情况加固，按优先级分三梯队。

---

## 第一梯队：严重问题（UB / 数据竞争 / 锁泄漏）

### 1. mesh.zig — 线程安全重构（最优先）

**现状**：~1200 行，LSA 广播 + KCP 会话管理。多个 HashMap 无互斥保护，存在数据竞争。

| # | 严重度 | 位置 | 问题 | 影响 | 建议修复 |
|---|--------|------|------|------|---------|
| 1.1 | **CRITICAL** | L819,822,836 | `handleKcpData` 在 `try` 错误路径上泄漏 `sessions_mutex` — 无 `defer unlock`，OOM 时锁永不释放 | 后续所有 `sessions_mutex.lock()` 死锁，mesh 线程永久卡死 | 添加 `defer self.sessions_mutex.unlock(self.io)` |
| 1.2 | **CRITICAL** | L274 + 全文件 | `neighbors: AutoHashMap(NodeId, Neighbor)` 无互斥保护 — mesh 线程写 + 外部线程读（`routeTo`、`sendPing`、`meshKcpOutput`）| 数据竞争 → 读已释放内存、HashMap 内部状态损坏、UB | 为 `neighbors` 添加专用 `Io.Mutex`；或所有外部读改为通过消息队列 |
| 1.3 | **CRITICAL** | L276 + 全文件 | `routes: ArrayList(Route)` 无互斥保护 — `rebuildRoutes` 的 `deinit`/赋值 与外部 `routeTo` 的 `items` 读取并发 | 数据竞争 → UAF 读 ArrayList 内部缓冲区、UB | 为 `routes` 添加专用 `Io.Mutex`；或改为双缓冲（swap + 写入后更新指针） |
| 1.4 | **CRITICAL** | L275 + L602-635 | `lsas: AutoHashMap(NodeId, LsaEntry)` 无互斥保护 — mesh 线程从 `handleLsa` 写入/释放，而 `tunnelManager` 从 `host.zig:602` 读取迭代 | 数据竞争 → UAF 读 HashMap 值槽和 LSA 内容、UB | 为 `lsas` 添加专用 `Io.Mutex`；或每次扫描前快照复制 |

### 2. host.zig — 线程生命周期与内存安全

**现状**：~800 行，Host HTTP 服务器 + Mesh + 隧道管理器线程管理。

| # | 严重度 | 位置 | 问题 | 影响 | 建议修复 |
|---|--------|------|------|------|---------|
| 2.1 | **CRITICAL** | L465,572-573,594-599 | UAF/use-after-return：`tunnelManager` 线程持有 `&mesh_opt`（指向 `startHttpHost` 的栈变量），线程被 detach，`startHttpHost` 返回后栈帧被回收 | detach 线程访问已释放栈内存 → UB | 将 `mesh_opt` 放在堆上（`allocator.create`），在 tunnelManager 退出时释放；或改为 join 方式 |
| 2.2 | **CRITICAL** | L122 | JSON 解析联合体未标记访问：`const g = guest_val.object` — 仅在外部验证了顶层是 array，未检查每个元素是否为 object | 非 object 元素访问错误联合体字段 → Debug/ReleaseSafe panic，ReleaseFast/ReleaseSmall UB | 添加 `switch (guest_val) { .object => \|o\| ..., else => continue }` |
| 2.3 | **CRITICAL** | L456,572 | `state.deinit()` 在 defer 块释放 HostState，但 detached tunnelManager 仍持有 `*state` 指针 | 访问已释放的 HostState → UAF | tunnelManager 必须在线程内完成后再 deinit state；或使用引用计数 |
| 2.4 | **CRITICAL** | L560-568 + L784 | Race between `m.deinit()` 和 tunnelManager 的 5 秒睡眠唤醒 — 睡眠期间 Mesh 被释放 | 唤醒后访问已释放 Mesh → UAF | 添加 `shutdown` 原子标志 + `io.notify()` 提前唤醒 tunnelManager |
| 2.5 | **HIGH** | httpd.zig 多处 | `mutex.lock(...) catch {}; defer mutex.unlock(...)` — 锁获取失败时仍执行 unlock | `defer unlock` 在未获取锁时释放 → Io.Mutex 未定义行为 | 所有此类位置改为 `mutex.lock(...) catch return;` 或 `catch |e| { log; return; }` |

### 3. broadcast.zig — 线程生命周期与内存安全（Guest 核心）

**现状**：~1500 行，pty 管理 + meshSessionLoop + 文件传输。发现多个 CRITICAL 问题。

| # | 严重度 | 位置 | 问题 | 影响 | 建议修复 |
|---|--------|------|------|------|---------|
| 3.1 | **CRITICAL** | L1160-1273 | detached `ptyReadLoop` 线程持有 `&active_cmd_id`、`&cmd_mutex`、`&pty_dead`、`&tunnel` — 全部指向外层循环栈变量。线程未 join；外层循环迭代后这些栈地址被新会话复用 | UAF：旧线程在新会话运行期间写入新栈变量 → `pty_dead` 被损坏导致新会话以为 PTY 已死、`cmd_mutex`/`active_cmd_id` 数据竞争、dangling `tunnel.*` 解引用 → UB | 改为 join 线程，或将共享状态移到堆上；在启动新会话前确认旧线程退出 |
| 3.2 | **CRITICAL** | L1147 | `detectShell(allocator) catch "/bin/sh"` — 错误时赋字符串字面量，然后 `defer allocator.free(shell)` | 释放 .rodata 指针 → 堆损坏、UB | 检测到错误时走错误返回路径而非继续，或检测到 OOM 后跳过 free |
| 3.3 | **CRITICAL** | L1155 | `fork()` 后无 `waitpid()` — `defer` 块只发送 SIGKILL 但不回收子进程 | 每个 PTY 会话泄漏一个僵尸进程 → 约 30000 个会话后进程表耗尽 → `fork()` 返回 EAGAIN → 整个 mesh 循环拒绝服务 | 在 defer 块中添加 `waitpid(pid, ...)` 调用 |
| 3.4 | **HIGH** | L1272 vs L909 | `tunnel.deinit()` 写入 `self.* = undefined`，同时 ptyReadLoop 线程可能调用 `tun.sendAndFlush()` | 并发读 undefined 内存 → UB | 确保 ptyReadLoop 在 deinit 前完全退出（与 3.1 共同修复） |
| 3.5 | **HIGH** | L503 + L131 | `readSysFs` 使用 64 字节缓冲区，但 `/proc/net/route` 通常为 500-2000+ 字节 | **Linux 网关检测已损坏** — 仅捕获文件头部，目标 "00000000" 永远找不到 | 增加缓冲区大小至 4096 字节，或改用合适的读取循环 |
| 3.6 | **HIGH** | L1324-1327 | `deleteFile` / `createFile` 之间存在 TOCTOU — 本地攻击者可在此期间替换 temp_path 为指向任意文件的符号链接 | 权限提升：覆盖 `createFile` 目标的任意文件 | 使用 `O_EXCL` 或原子创建标志 |
| 3.7 | **MEDIUM** | L1378 | 文件写入后 `writer.interface.flush() catch {}` 被丢弃 — flush 失败时数据可能未落盘，但代码仍验证 SHA-256 并 rename | 磁盘满或其他 I/O 错误时目标文件截断或损坏 | 传播 flush 错误而非丢弃 |
| 3.8 | **MEDIUM** | L616,618 | `ptyWrite` 丢弃 write 返回值 — 短写或错误被忽略 | 发生 PTY 写入错误或部分写入时，命令可能被截断（部分命令的 shell 解释可能产生意外结果） | 检查返回值；错误时重试或记录 warn |
| 3.9 | **MEDIUM** | L862 | `poll()` 的 EINTR 被当作致命错误 → 退出 ptyReadLoop | 任何信号都可以杀死 PTY 输出流 | 在 EINTR 上重试 poll（`continue` 而非 `break`） |
| 3.10 | **MEDIUM** | L1430-1436 | 错误处理器内部使用 `try` — `buildFileEof` 失败会传播二级错误，覆盖原始错误 | 调用者看到 OOM 而非 FileNotFound 等实际错误 | 错误处理器捕获内部错误而非传播 |

### 4. mesh.zig — 缓冲区溢出

| # | 严重度 | 位置 | 问题 | 影响 | 建议修复 |
|---|--------|------|------|------|---------|
| 4.1 | **HIGH** | L736-746 | LSA 中继缓冲区溢出：`relay_buf: [1500]u8` 但 `data` 可达 4096 字节 | 攻击者可发送超大数据包导致 `@memcpy` panic（Debug/ReleaseSafe）或静默栈损坏（ReleaseFast 无安全检查） | 添加 `if (data.len > 1499) return` 并记录 warn |
| 4.2 | **MEDIUM** | L623,517 | `broadcastOwnLsa` 和 `broadcastOwnLsaInit` 中同样使用 1500 字节缓冲区 | 大量邻居导致 panic | 为 `encodeLsa` 添加大小校验，超过 MTU 时截断邻居列表 |

---

## 第二梯队：高优先级（鲁棒性/错误处理）

### 5. tunproto.zig — 网络数据解析加固

**现状**：420 行，18 个测试覆盖正常路径。从不可信网络解析数据。

| # | 位置 | 问题 | 建议修复 |
|---|------|------|---------|
| 4.1 | readBlob L74-82 | 长度来自不可信网络，无上限 | 添加 `max_len` 参数（建议 1MB），超过返回 null |
| 4.2 | readString L66-72 | 无长度上限（DoS 风险低但建议加固） | 添加可选最大长度限制 |
| 4.3 | 所有 parse 函数 | 无消息类型验证 — 调用者负责 | 添加类型字节 assert 或返回错误枚举 |

**预估工作量**：2-3 小时

### 6. host_http.zig — HTTP 处理器错误处理

**现状**：~500 行，三个核心端点。

| # | 位置 | 问题 | 建议修复 |
|---|------|------|---------|
| 5.1 | L123,193,232 等多处 | `state.mutex.lock(state.io.?) catch {}` 静默吞错 | 锁失败应返回 503 + 日志 err |
| 5.2 | L360-368 | Guest 检查与隧道使用间存在 TOCTOU | 合并为单次锁操作 |
| 5.3 | httpd.zig 全文件 | `catch {}; defer unlock` 模式（见 2.5）| 所有位置统一修复 |

**预估工作量**：3-4 小时

### 7. svc.zig — 服务管理静默吞错

**现状**：865 行，跨平台服务生命周期。

| # | 位置 | 问题 | 建议修复 |
|---|------|------|---------|
| 6.1 | L139,149,401,411 | `deleteFile(...) catch {}` 静默吞错 | 至少记录 warn |
| 6.2 | L504,507 | `_ = runCmd(...)` 吞错 | 记录 warn；3 次连续失败后报错 |
| 6.3 | L787 | Windows SCM `svc_name_utf16` 硬编码 `"utmm"` | 使用正确的 "UTM-Monitor-Guest"/"UTM-Monitor-Host" |
| 6.4 | forceInstall | 步骤间无回滚 | 记录当前状态，支持重入恢复 |

**预估工作量**：4-5 小时

### 8. mesh.zig — 网络输入验证

| # | 位置 | 问题 | 建议修复 |
|---|------|------|---------|
| 7.1 | L762-763,842-849 | 无远程 MAC 地址验证 — 攻击者可注入任意邻居 | 仅接受来自已知邻居或具有有效 LSA 的节点的 MAC |
| 7.2 | L779 | 无 KCP 会话 ID 验证 | 验证会话 ID 是否与源 MAC 对应的已知会话匹配 |
| 7.3 | L190-200 | LSA 邻居计数可达 255；位置由攻击者控制的 `info_len` 决定 | 添加 n_info 长度合理性检查 |
| 7.4 | L415-416,480 | `periodicTasks` 中的 OOM 会终止整个 mesh 运行循环 | 在 `periodicTasks` 内部捕获 OOM 而非传播 |
| 7.5 | L782-784,833-835 | KCP 输入错误被静默丢弃 — 状态可能不一致 | 记录错误；若连续多次失败则关闭会话 |

**预估工作量**：5-7 小时

---

## 第三梯队：中优先级（数据完整性/代码质量）

### 9. broadcast.zig — 剩余低优先级项

> **注**：CRITICAL 问题（UAF、字符串字面量释放、僵尸进程泄漏）已迁移至第一梯队 §3。此处仅余次要项。

| # | 问题 | 建议修复 |
|---|------|---------|
| 9.1 | KCP 输出回调为 `void` 无错误信号 | 无法通知 KCP 发送失败；影响重传逻辑 |
| 9.2 | UpgradeSignal 竞态 | 原子化版本检查与主循环间的信号传递 |

### 10. host.zig — CLI 命令处理鲁棒性

| # | 位置 | 问题 | 建议修复 |
|---|------|------|---------|
| 9.1 | L203 | cmdExec exit code 解析失败默认 0（成功）—— 掩盖命令失败 | 默认 127（命令未找到约定）或标记为错误 |
| 9.2 | L378 | `@intCast(u32)` 在 ≥4GiB 文件时静默截断 | 改用 `u64` 或添加上限检查并报错 |
| 9.3 | L122 | JSON .object 未标记访问（同 2.2） | 添加 switch 类型检查 |
| 9.4 | L54-59 | 从 CLI 的 serve_dir 无路径验证 | 禁止 `..` 组件，限制绝对路径 |

**预估工作量**：2-3 小时

### 11. httpd.zig — HostState 生命周期

| # | 问题 | 建议修复 |
|---|------|---------|
| 10.1 | OpState 孤立：客户端断开后无清理 | 添加 5 分钟无活动自动清理 |
| 10.2 | transfers HashMap 无上限 | 添加上限（如 16 个并发传输） |
| 10.3 | jsonEscape：0x7F (DEL) 未特殊处理 | 与其他控制字符保持一致处理 |

**预估工作量**：2-3 小时

### 12. main.zig — CLI 参数解析

| # | 问题 | 建议修复 |
|---|------|---------|
| 11.1 | `cli.exec_target.?` 等可选解包 — 若重构破坏守卫则 panic | 改为 `orelse` 提供明确错误消息 |
| 11.2 | parseArgs 中 `i += 1` 边界检查不一致 | 统一守卫模式 |

**预估工作量**：1-2 小时

---

## 第四梯队：低优先级（代码质量/防御性）

### 13. config.zig

| # | 问题 | 建议修复 |
|---|------|---------|
| 12.1 | `loadConfig` 是 TODO stub | 实现 key=value 解析 |
| 12.2 | Logger 使用 `std.debug.print` 绕过日志基础设施 | 替换为 `std.log`（见 CLAUDE.md 日志规范） |
| 12.3 | `saveConfig` L87 重复写 `port={d}` | 删除重复行 |

**预估工作量**：2-3 小时

### 13. hosts_file.zig + guest.zig + tunnel.zig

| # | 模块 | 问题 | 建议修复 |
|---|------|------|---------|
| 13.1 | hosts_file.zig | rename 使用 cwd() — CWD 变化导致路径不一致 | 使用绝对路径 |
| 13.2 | guest.zig | `_ = chdir(...)` 静默吞错 | 记录 warn |
| 13.3 | tunnel.zig | `deinit` 设置 `self.* = undefined` — UAF 风险 | 添加 debug 模式哨兵，或改为 `deinit` 接受指针 |

**预估工作量**：1-2 小时

---

## 总览

| 梯队 | 模块 | 问题数 | 预估工时 |
|------|------|--------|---------|
| **1** | mesh.zig 线程安全 | 4 CRITICAL | 8-12h |
| **1** | host.zig 线程生命周期 | 4 CRITICAL + 1 HIGH | 6-10h |
| **1** | broadcast.zig 线程/内存 | 3 CRITICAL + 3 HIGH + 4 MEDIUM | 8-12h |
| **1** | mesh.zig 缓冲区溢出 | 1 HIGH + 1 MEDIUM | 1-2h |
| **2** | tunproto.zig | 3 | 2-3h |
| **2** | host_http.zig | 3 | 3-4h |
| **2** | svc.zig | 4 | 4-5h |
| **2** | mesh.zig 输入验证 | 5 | 5-7h |
| **3** | broadcast.zig 剩余 | 2 | 1-2h |
| **3** | host.zig CLI | 4 | 2-3h |
| **3** | httpd.zig | 3 | 2-3h |
| **3** | main.zig | 2 | 1-2h |
| **4** | config.zig | 3 | 2-3h |
| **4** | hosts_file / guest / tunnel | 3 | 1-2h |
| **合计** | **13 模块** | **53 问题** | **46-70h** |

---

## 建议执行顺序

### 阶段 1：修复数据竞争和 UB（必须首先完成）

这些问题是互相耦合的——在修复线程安全问题之前无法可靠地测试其他修复：

1. **mesh.zig `handleKcpData` 锁泄漏** (1.1) — 单行修复，最高收益
2. **host.zig tunnelManager use-after-return** (2.1) — 架构修复：将 mesh_opt 移到堆上
3. **host.zig JSON 联合体访问** (2.2) — 单行修复
4. **host.zig + httpd.zig mutex `catch {}` 后 unlock** (2.5) — 系统性修复所有实例
5. **mesh.zig HashMap 线程安全** (1.2-1.4) — 最大重构项，为每个结构添加互斥锁或消息队列
6. **host.zig `state.deinit()` / `m.deinit()` 竞态** (2.3-2.4) — 生命周期协调

### 阶段 2：网络边界加固

7. **mesh.zig 缓冲区溢出** (3.1-3.2) — 添加大小检查
8. **mesh.zig 输入验证** (7.1-7.5) — MAC/邻居/KCP 验证
9. **tunproto.zig 边界检查** (4.1-4.3) — 大小限制

### 阶段 3：错误处理加固

10. **host_http.zig 静默吞锁** (5.1-5.3)
11. **svc.zig 静默吞错** (6.1-6.4)
12. **broadcast.zig** (8.1-8.4)

### 阶段 4：代码质量

13. **host.zig + main.zig CLI** (9, 11)
14. **httpd.zig 生命周期** (10)
15. **config.zig + 其他** (12, 13)

---

## 跨领域关注点（所有模块均需检查）

这些模式在多个文件中反复出现，应在整个代码库中进行系统化处理：

1. **`mutex.lock() catch {}` + `defer unlock`** — 在 httpd.zig、host.zig、tunnel.zig 中出现 ~20 次。每次出现都是潜在的 UB。需要：`mutex.lock() catch return error.LockFailed;`
2. **`_ = f(...) catch {}`** — 在 svc.zig、mesh.zig 中出现 ~15 次。静默丢弃错误。需要：区分可忽略错误与必须记录/传播的错误。
3. **未受限制的 HashMap 增长** — lsas、neighbors、sessions、op_states、transfers。恶意或行为失常的对端可能导致无限制的内存增长。需要：为所有集合添加上限。
4. **`clock_ms` 回绕** — u32 在最大负载下约 49.7 天后回绕。影响 keepalive 和超时计算。需要：使用 `u64` 或使用带符号差分比较（`@subWithOverflow`）。
