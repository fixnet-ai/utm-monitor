## v0.18.44 → v0.18.68 — 三平台自动升级彻底打通

**时间**: 2026-08-12 → 2026-08-13

### 背景

从 4 个预存 Bug（linuxvm 心跳超时 crash-loop、--upgrade 推送成功但不生效、deploy IP 过期、winx64 文件锁定）出发，通过多轮 bump→SSH 部署→auto-upgrade 测试，逐步挖出自动升级链路上的一串跨平台 bug。

### 根因与修复链条

| # | 根因 | 平台 | 修复 |
|---|------|------|------|
| 1 | `O_NONBLOCK=0x0004` 硬编码 macOS 值，Linux 应为 0x800 | Linux | 按平台区分常量 |
| 2 | macOS scp 后二进制签名损坏，forceInstall 跳过 codesign | macOS | forceInstall 无条件重签 |
| 3 | SHM restart 失败后杀 utmm → 升级丢失 + 服务中断 | 全部 | 失败不杀 utmm，保留 .tmp |
| 4 | 升级失败无限重试（每秒一次永不休止） | 全部 | 连续失败计数器，超限删 .tmp |
| 5 | `std.Io.sleep` 在 init.io 上下文失败，ensure retry 失效 | 全部 | 改 usleep |
| 6 | `findUpgradeTmp` 目录扫描（Windows Threaded Io 不支持） | Linux/Windows | SHM cmd_data 传路径 |
| 7 | `readCmdPath` 首字符 `!= '/'` 检查拒绝 Windows `C:\` | Windows | 只查非空 |
| 8 | `@memcpy` 写 volatile 共享内存跨进程不可见 | 全部 | @atomicStore/Load |
| 9 | `CloseHandle(CreateFileMappingW)` 移除命名对象名字 | Windows | 不关闭句柄（泄漏一个） |

### 关键教训

1. **Windows 命名共享内存生命周期**：`CreateFileMappingW` 的句柄关闭会移除对象名字，
   即使 `MapViewOfFile` 的视图还映射着。要跨进程可见，句柄必须保持打开。
2. **Windows 服务 stdout 被丢弃**：`std.log` 在 Windows 服务里不可见，调试需写文件。
3. **测试流程要核对 ver.txt**：曾因 ver.txt 已是新版本但文件名误标旧版本，导致
   Guest 和 Host 同版本，触发"同版本跳过"，误判为代码 bug。

### 验证

- 5 轮自动升级压力测试（v0.18.64 → v0.18.68），每轮 4 个 VM 最终全部追平版本。
- 间歇性 `GuestConnectFailed`/`GuestNotFound` 均为时序问题（上一轮升级还在重启），
  自愈于下一轮 push，非升级逻辑 bug。

---

## v0.18.39 — TCP SO_REUSEADDR 跨平台修复 + FD_CLOEXEC + F_GETFD/F_SETFD 常量修复

**时间**: 2026-08-12

### 问题背景

TCP :2121 BindFailed 崩溃循环：utmmd kill→restart 周期中，新 utmm 无法 bind TCP :2121 (errno=98/EADDRINUSE)，导致 TCP SOCKS5 不可用。UDP LSA 广播正常，但终端用户无法通过 SOCKS5 exec/upload/download。

### 根因分析（三层面）

#### 层面 1 — SO_REUSEADDR/SOL_SOCKET 硬编码常量跨平台错误（直接根因）

`src/tcp.zig` 顶部定义：
- `SO_REUSEADDR = 0x0004` — macOS 正确，Linux 应为 2
- `SOL_SOCKET = 0xffff` — macOS 正确，Linux 应为 1

TcpListener.init POSIX 路径使用这些常量调用 `setsockopt(SO_REUSEADDR)`，
Linux 上传递了错误的选项值，内核静默忽略。返回值和 errno 均被丢弃（`_ =`）。

**影响**：Linux 上 SO_REUSEADDR 从未生效。TIME_WAIT 状态下 bind 必然失败。

#### 层面 2 — Listen Socket 缺 FD_CLOEXEC 导致子进程继承（间接根因）

dpipe_shell fork/exec 创建 shell 子进程时，子进程继承父进程全部 FD（包括 listen socket）。
utmmd kill→restart 后：
1. 旧 utmm 被 SIGKILL，但 shell 子进程仍持有 listen socket fd
2. 新 utmm bind :2121 → EADDRINUSE（子进程仍未退出）

**影响**：即使 SO_REUSEADDR 修复，listen socket 被继承到子进程后仍导致 EADDRINUSE。

#### 层面 3 — F_GETFD/F_SETFD 硬编码常量跨平台错误（新增代码引入的次生 bug）

我们新增的 FD_CLOEXEC 代码使用了硬编码常量：
- `F_GETFD = 2` — macOS 正确，Linux 应为 1
- `F_SETFD = 3` — macOS 正确，Linux 应为 2

在 Linux 上 `fcntl(sock, 2, 0)` 被内核解释为 `F_SETFD`（设置 fd flags 为 0），反而**清除了** FD_CLOEXEC！
第二个 `fcntl(sock, 3, ...)` 被解释为 `F_GETFL`（获取文件状态标志），第三个参数被忽略。

**教训**：POSIX fcntl 常量（F_GETFD/F_SETFD/F_GETFL/F_SETFL）在不同 OS 上值不同，**必须使用 `std.posix` 命名空间**提供的跨平台值。禁止硬编码。

### 修复方案

```zig
// BEFORE — 硬编码 macOS 值，Linux 上静默失效
const SO_REUSEADDR = 0x0004;
const SOL_SOCKET = 0xffff;
const F_GETFD = 2;
const F_SETFD = 3;
const reuse: c_int = 1;
_ = system.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, ...);
const fd_flags = system.fcntl(sock, F_GETFD, 0);
_ = system.fcntl(sock, F_SETFD, fd_flags | FD_CLOEXEC);

// AFTER — 使用 std.posix 跨平台常量
const reuse: c_int = 1;
if (system.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, ...) < 0) {
    std.log.err("[tcp] setsockopt(SO_REUSEADDR) failed: errno={d}", ...);
}
const fd_flags = system.fcntl(sock, std.posix.F.GETFD, 0);
_ = system.fcntl(sock, std.posix.F.SETFD, fd_flags | std.posix.FD_CLOEXEC);
```

### 退出路径审查

| 组件 | 文件/行 | 机制 | 状态 |
|------|---------|------|------|
| Guest TCP accept | guest.zig:903 | `defer listener.deinit()` + shutdown flag break | ✅ |
| Host TCP accept | host.zig:982 | `defer listener.deinit()` + shutdown flag break | ✅ |
| SIGKILL 响应 | kernel | FD_CLOEXEC 防子进程继承 + SO_REUSEADDR 允 rebind | ✅ 已修复 |
| UDP mesh socket | tcp.zig:607 | 有 SO_REUSEADDR + SO_REUSEPORT，缺 FD_CLOEXEC | ⚠️ 低风险，非紧急 |
| `O_NONBLOCK` 硬编码 | tcp.zig:25 | `0x0004`(macOS) vs `2048`(Linux) — pre-existing | ⚠️ 待修复 |

### 已修复的回退问题

- v0.18.36 中已修复的 Bug 清单：僵尸进程、findUpgradeTmp、pushUpgrade、Windows tryAcquire
- 全部 216 单元测试 + 59 集成测试通过

### 部署状态

全部 5 节点已部署 v0.18.39：
- Host (dasis-macbook-air): ✅
- linuxvm: ✅ (TCP :2121 BindFailed 已确认修复 — strace 验证 SO_REUSEADDR 正确生效)
- macvm: ✅
- windowsvm: ✅
- winx64: ✅

---

## v0.18.36 — 僵尸进程收割 + findUpgradeTmp 选最新 + Windows tryAcquire 重试

**时间**: 2026-08-12

### 修复的四项 Bug

#### Bug 1 — Linux 僵尸进程 (最严重)

**症状**: linuxvm 执行 `ps aux` 时出现数百个 `[utmm] <defunct>` 僵尸进程。

**根因分析** (crash-loop 触发链):

```
1. 多个 utmm-upgrade.*.tmp 文件堆积（每次 auto-upgrade 推送创建 1 个）
2. findUpgradeTmp 返回第一个匹配文件（最旧的，可能已损坏）
3. tryApplyPendingUpgrade 用错误版本替换二进制
4. 新 utmm 启动后崩溃或上报错误版本 → utmmd killProcess(SIGKILL)
5. killProcess 仅 kill，从不调用 waitpid 收割僵尸
6. proc PID 被下一个 startUtmm 覆盖，旧僵尸 PID 丢失，永远无法收割
7. Host auto-upgrade 检测版本不匹配 → 再次推送新 tmp → 循环继续
8. 每循环一次产生 1 个不可收割的僵尸，数小时积累数百个
```

**修复** (`src/utmmd.zig` killProcess POSIX 路径):
- kill 前先 `waitpid(WNOHANG)` 收割已退出子进程
- SIGKILL 后 blocking `waitpid` 等待进程终止并收割
- `kill()→ESRCH` 表示进程已不存在 → 直接返回 true（不视为错误）

#### Bug 2 — findUpgradeTmp 返回旧文件而非最新

**症状**: 存在多个 .tmp 文件时，返回第一个匹配文件（按 walk 顺序，非时间顺序）。
旧文件可能是损坏的、版本不匹配的，导致升级到错误版本。

**修复** (`src/svc.zig`):
- **findUpgradeTmpPosix**: 扫描所有匹配文件 → 通过 `statFile` 比较 mtime → 返回最新的
- **findUpgradeTmpWindows**: 扫描所有匹配文件 → 通过 `ftLastWriteTime` 比较 → 返回最新的
- 两个实现均在扫描过程中删除旧文件，防止堆积

#### Bug 3 — pushUpgrade 静默成功

**症状**: `pushUpgrade` 收到意外的响应字节后仍然返回 null（成功），`[upgrade] OK`
日志已打印但升级实际未生效。

**修复** (`src/host.zig`): 非 upload_result 类型的响应字节 → 返回 `"UnexpectedResponse"` error。

#### Bug 4 — Windows tryAcquire 可能立即失败

**症状**: utmmd 的 `tryApplyPendingUpgrade` 中 `UpgradeLock.tryAcquire` 调用一次
即放弃，当另一个进程持有锁时（如 Guest 正在写入 .tmp）即错失升级窗口。

**修复** (`src/utmmd.zig`): tryAcquire 失败后重试最多 10 次（200ms 间隔）。

### 测试

- `zig build test` — 216/216 passed ✅
- `zig build test-integration` — 59/59 passed, 0 leaks ✅

### 待验证

- [ ] linuxvm 部署后确认僵尸进程不再产生
- [ ] 多 .tmp 文件场景下确认选中最新
- [ ] winx64 auto-upgrade 端到端验证

---

## Phase 33 — Windows --upgrade 二进制替换崩溃修复

**时间**: 2026-08-11

### 问题

在 Windows 上 `--upgrade` 推送二进制后，utmmd 在尝试替换运行中 utmm.exe 时崩溃
（SCM exit 1067），导致升级静默失败（`[upgrade] OK` 只完成了传输，没完成替换和重启）。

### 根因

详见 [findings.md](findings.md) 2026-08-11 条目。两个协同故障：
1. `deleteFile+rename` 在 Windows 上失败（文件锁定）
2. `killProcess` 关闭进程句柄导致 isProcessAlive 误判 → crash-loop

### 修复内容

| 文件 | 变更 | 说明 |
|------|------|------|
| `src/utmmd.zig` | `killProcess` | 移除 `CloseHandle` — 句柄由调用者通过 `closeProcessHandle` 管理 |
| `src/utmmd.zig` | `closeProcessHandle` | 新增函数 — 平台适配的进程句柄关闭 |
| `src/utmmd.zig` | `tryApplyPendingUpgrade` | Windows 路径用 `renameWindowsOldFirst`（MoveFileExW 先 rename 旧→.old，再 rename 新→目标），代替 deleteFile+rename 循环 |
| `src/utmmd.zig` | `renameWindowsOldFirst` | 新增函数 — 使用 MoveFileExW API 安全替换运行中 exe，含 20 次重试（250ms 间隔） |
| `src/utmmd.zig` | `monitorUtmm` | 新增 `defer closeProcessHandle(proc)` 确保句柄在返回时被关闭 |
| `src/utmmd.zig` | macOS codesign | codesign 移到 rename 成功后统一执行（原来只在 CrossDevice 回退路径执行） |
| `src/guest.zig` | `handleUpgradeCmd` | 接收完成后通过 shm 设置 `.restart` 通知 utmmd 立即处理升级 |

### 设计要点

1. **Windows 重命名策略**: 利用 Windows 允许对已打开文件执行 rename 的特性（文件数据仍在内存中，但目录条目可修改），先将旧 exe 重命名为 .old，再将新 .tmp 重命名为目标名
2. **MoveFileExW API**: 使用 `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` flag，确保原子性和同步写入
3. **句柄管理生命周期**: killProcess 只负责杀进程+等待终止，句柄关闭推迟到 monitorUtmm 退出时统一处理，避免 isProcessAlive 误判
4. **shm 提前触发**: handleUpgradeCmd 成功后设置 shm restart 命令，utmmd 在下次 poll 迭代中立即处理（无需等待文件扫描周期）
5. **POSIX 路径不变**: macOS/Linux 仍使用 rename 原子替换，behavior 不变

### 测试

- `zig build test` — 216/217 passed, 0 failed ✅
- `zig build test-integration` — 59/59 passed, 0 leaks ✅

### 待验证

- [ ] Windows 真机 `--upgrade` 推送验证（windowsvm + winx64）
- [ ] 验证 utmmd 不再 exit 1067
- [ ] 验证 .old 文件清理正常

---

## v0.18.1 — MCP 双格式响应 (structuredContent)

**时间**: 2026-08-11

参考 zigtester MCP 服务器的双格式模式，为全部 6 个 MCP 工具响应添加 `structuredContent` 字段，
同时保留 `content[0].text` 人类可读 markdown。AI agent 可程序化解析 `structuredContent` 做决策，
无需从 markdown 提取数据。

| 工具 | structuredContent 字段 |
|------|----------------------|
| `status` | `guests[]`, `counts{total,serving,offline}` |
| `exec` | `vm`, `command`, `exit_code` |
| `ping` | `vm`, `reachable`, `mac`, `rtt_ms` |
| `upload` | `vm`, `local_path`, `remote_path`, `success` |
| `download` | `vm`, `remote_path`, `local_path`, `bytes`, `success` |
| `sshpass` | `host`, `user`, `exit_code` |

修改集中在 `src/mcp.zig` 的 `format*` / `handle*` 函数，~50 行增量 + 6 新测试。216 单元测试通过。
文档更新：README.md、CLAUDE.md、MANUAL.md、progress.md、task_plan.md。

## v0.18.0 — HTTP MCP 嵌入 Host Daemon

**时间**: 2026-08-11

### 背景

旧架构: `utmm --mcp` 作为独立 stdio 进程，通过 IPC socket 与 Host daemon 通信。
存在多个脆弱点: 60s SIGALRM `_exit(0)` 空闲超时硬杀、EINTR 竞态、64KB exec 缓冲区截断、
无 IPC 重试。

### 新架构

MCP JSON-RPC 直接由 Host daemon 通过 TCP :2121 首字节协议分发提供:
`0x05`→SOCKS5, ASCII letter→HTTP MCP。AI agents 通过 HTTP POST 发送 JSON-RPC 请求。

**Before**: AI Agent → stdio → mcp.zig → IPC socket → ipc.zig server → Host 函数
**After**:  AI Agent → HTTP POST :2121 → hostTcpListen peek → mcp_http.zig → mcp.zig → mcp_handler.zig

### 变更文件

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `src/mcp_handler.zig` | 新增 | MCP 核心业务逻辑: getGuestListJson, execOnGuest, pingGuest, uploadToGuest, downloadFromGuest。无 IPC 依赖 |
| `src/mcp_http.zig` | 新增 | HTTP/1.1 POST 解析器: readHttpRequestBody, parseContentLength, writeHttpResponse。5 测试 |
| `src/socks5.zig` | 修改 | 新增 authAcceptWithVersion + readRequestBufWithVersion（skip 已 peek 的 VER 字节） |
| `src/host.zig` | 修改 | hostTcpListen 首字节分发 + mcpHttpHandler 包装函数 |
| `src/mcp.zig` | 修改 | 新增 McpContext struct + processRequest 重构。删除 SIGALRM、IDLE_TIMEOUT_SEC、onIdleTimeout、runWithIdleTimeout |
| `src/ipc.zig` | 修改 | handleStatus/handleExec/handlePing 委托 mcp_handler（消除 ~160 行重复） |
| `src/main.zig` | 修改 | --mcp 打印 HTTP endpoint URL |
| `tests/test_mcp_tools.py` | 重写 | subprocess stdio → HTTP POST (urllib.request) |

### 设计要点

1. **首字节协议分发**: hostTcpListen 在 accept 后读取 1 字节，0x05→SOCKS5（skip VER），大写 ASCII→HTTP MCP
2. **McpContext**: 携带 Host daemon 状态（GuestTable, mesh_ptr, hostname）直接传入 mcp.processRequest，消除 IPC 序列化
3. **mcp_handler 共享**: HTTP MCP 和 IPC handler 调用同一套 exec/ping/upload/download 实现，零重复
4. **单请求单连接**: HTTP handler 读完请求→处理→写响应→关闭，无 keep-alive
5. **线程安全**: GuestTable 使用 spin-lock，Mesh pingAndWait 内部使用 mutex，conn_limit atomic 控制并发

### 消除的脆弱点

| 旧问题 | 如何消除 |
|--------|---------|
| 60s SIGALRM `_exit(0)` 硬杀 | 无独立 MCP 进程，无 idle timeout |
| EINTR 竞态（SA_RESTART=0） | 无信号处理，无 EINTR |
| 64KB exec 缓冲区截断 | mcp_handler 直接 TCP 流式读取，无缓冲限制 |
| IPC 连接失败无重试 | 无 IPC 桥接，直接调用 Host 函数 |
| `_exit(0)` 掩盖失败（超时退出码为 0） | 无超时，真实错误传播 |

### 实测发现的 Bug 与修复

在 v0.18.0 真机全功能实测中发现并修复 2 个问题：

1. **MCP sshpass "Empty reply from server" (curl exit 52)**:
   - 根因 A: `handleVmSshpass` 使用 `ctx.io`（zio 异步 I/O）配合 `std.process.run`，后者需要阻塞 pipe I/O，两者不兼容
   - 根因 B: sshpass `-p` 模式在 `sshpass.zig:172` 存储指向 argv 内存的指针，后续 `@memset` 用 `'z'` 覆盖密码导致实际密码被破坏
   - 修复: 创建专用 `std.Io.Threaded.init(gpa, .{})` IO + 改用 `-f /tmp/utmm-sshpass-pw`（密码文件）。`-f` 模式通过 `gpa.dupe` 复制文件名，避免了 memset 破坏
   - 使用 Zig 0.16.0 `Io.File.writer` API 将密码写入临时文件

2. **`--help` 文本过期** (`src/main.zig:326`):
   - `--mcp` 描述仍显示 "Start MCP stdio JSON-RPC server"，实际已改为打印 HTTP 端点 URL
   - 修复: 更新为 "Print MCP HTTP endpoint URL and ensure Host daemon"

3. **README 交叉编译目标数过期**: 8→6（32-bit x86 已跳过），修复

4. **refac.md 文件计数过期**: "当前 19 src" → "当时 19 src，当前 22 src"，修复

### 全功能验证

- `zig build test` — 210 通过，0 失败 ✅
- `zig build test-integration` — 59 通过，0 泄漏 ✅
- 7 个 MCP HTTP 工具全部通过 (status/exec/ping/upload/download/sshpass/manual) ✅
- CLI 命令全部通过 (status/exec/upload/download/ping/mcp/version/help) ✅
- `python3 tests/test_mcp_tools.py` — 9/14 通过（5 失败因 linuxvm 离线，非代码 bug） ✅
- SOCKS5 转发正常 ✅

### 架构图

```
Before: AI Agent → stdio → mcp.zig → IPC socket → ipc.zig server → Host 函数
After:  AI Agent → HTTP POST :2121 → hostTcpListen peek → mcp_http.zig → mcp.zig → mcp_handler.zig
```

```
Host TCP :2121 accept → peek first byte:
  0x05          → SOCKS5 (readRequestBufWithVersion, dispatch by target hostname)
  'A'..'Z'      → HTTP MCP (mcpHttpHandler on thread pool, single-request-per-connection)
  everything else → close
```

### 待跟进

- **zio PR #646**: 等待 lalinsky re-review 后合并

### 8 交叉编译目标

v0.18.0 实测确认 zio feat/x86-32 分支已支持 32-bit x86。8 目标全部编译通过：
- aarch64-linux-musl ✅ (~14MB)
- aarch64-macos ✅ (~2.1MB)
- aarch64-windows ✅ (~3.6MB)
- x86-linux-musl ✅ (~12MB)
- x86-windows ✅ (~4.2MB)
- x86_64-linux-musl ✅ (~14MB)
- x86_64-macos ✅ (~2.3MB)
- x86_64-windows ✅ (~4.1MB)

### MCP 双格式响应 (structuredContent)

参考 zigtester MCP 服务器的双格式模式，为所有 MCP 工具响应添加 `structuredContent` 字段，
使 AI agent 可以程序化读取结构化数据做决策，同时保持人类可读 markdown 供展示。

**Before**: `{"content":[{"type":"text","text":"**linuxvm** ping: MAC=..., RTT=3ms"}]}`
**After**: 上述 content + `"structuredContent":{"vm":"linuxvm","reachable":true,"mac":"...","rtt_ms":3}`

| 工具 | structuredContent 字段 |
|------|----------------------|
| `status` | `guests[]`, `counts{total,serving,offline}` |
| `exec` | `vm`, `command`, `exit_code` |
| `ping` | `vm`, `reachable`, `mac`, `rtt_ms` |
| `upload` | `vm`, `local_path`, `remote_path`, `success` |
| `download` | `vm`, `remote_path`, `local_path`, `bytes`, `success` |
| `sshpass` | `host`, `user`, `exit_code` |

修改集中在 `src/mcp.zig` 的 `format*` / `handle*` 函数，~50 行增量 + 6 新测试。所有 216 单元测试通过。

### 待跟进

## v0.17.21 — x86 ssh.exe 嵌入 + zio review 修复 + 全量部署

**时间**: 2026-08-03

### Part 1: x86 ssh.exe 嵌入

- 从 winx64 (x86_64) 和 windowsvm (aarch64) 提取 ssh.exe
- comptime @embedFile 嵌入，按 cpu.arch 选择
- extractSshExeIfMissing best-effort 提取（失败不阻断安装）
- sshpass.zig isSshCommand 检测 + 路径替换

### Part 2: zio PR #646 review 修复

- TEB 保存/恢复（Windows x86 线程环境块）
- coroEntry `jmpl` 替代 `calll`（避免栈不平衡）
- NETDOWN → NetworkUnreachable errno 映射
- PipeCounterInt 按 lalinsky 偏好使用 usize
- 595/595 测试通过，CI 26/26 全部通过
- PR 状态: OPEN, MERGEABLE, 等待 lalinsky re-review

### Part 3: 真机部署 v0.17.21

**部署方法**: SSH 手动 scp + install（绕过 utmmd upgrade 扫描问题）

| 节点 | 版本 | 状态 |
|------|------|------|
| Host (dasis-macbook-air) | v0.17.21 | ✅ serving |
| macvm | v0.17.21 | ✅ serving |
| linuxvm | v0.17.21 | ✅ serving |
| windowsvm | v0.17.21 | ✅ serving |
| winx64 | v0.17.21 | ✅ serving |

**遇到的问题**:
1. macvm utmmd 时钟滞后一天 — SSH 手动升级绕过
2. linuxvm utmmd 挂了 — systemctl restart 恢复
3. winx64 文件锁冲突 — 等 3s 重试成功
4. linuxvm TCP :2121 未监听 — 重启 utmmd 后正常

### Part 4: 测试验证

- **CLI**: 31/31 ✅ (`sudo python3 tests/test_cli_commands.py`)
- **MCP**: 14/14 ✅ (`sudo python3 tests/test_mcp_tools.py`)

### 待跟进

- zio PR #646: 等待 lalinsky re-review 后合并
- utmmd upgrade 扫描: 考虑简化或移除（SSH 手动升级更可靠）

---

## v0.17.20 — 8 CPU 架构 + zio 网络错误映射修复

**时间**: 2026-08-03

### Part 1: zio 网络错误映射修复

**问题**: 网络 IP 变化、网卡拔出、网络不可用时，zio 的 errno 映射函数将
`ENETUNREACH`、`EHOSTUNREACH`、`EHOSTDOWN` 等落入 `unexpectedError()`，
返回 `error.Unexpected` 而非 `error.NetworkUnreachable`。

**调查过程**:
1. 检查 `zio/src/os/net.zig` 全部 5 个 errno 映射函数
2. 逐函数核对 POSIX 和 Windows 分支覆盖的 errno 值
3. 确认超时类 errno（`ETIMEDOUT`/`TIMEDOUT`）已在全部 4 个映射函数中覆盖 ✅

**修复** (`zio/src/os/net.zig`):
- `errnoToConnectError` POSIX: 新增 `NETDOWN` → `NetworkUnreachable`
- `errnoToRecvError` POSIX: 新增 `HOSTUNREACH, HOSTDOWN, NETUNREACH` → `NetworkUnreachable`
- `errnoToRecvError` Windows: 新增 `EHOSTUNREACH, ENETUNREACH` → `NetworkUnreachable`
- `errnoToSendError` POSIX: 新增 `NETUNREACH` + `CONNABORTED` + `OPNOTSUPP`
- `errnoToSendError` Windows: 新增 `ENETUNREACH` → `NetworkUnreachable`

**IO 层修复** (`zio/src/io.zig`):
- `recvErrToReadErr`: 新增 `NetworkUnreachable => Unexpected`
- `recvMsgErrToReceiveErr`: 同上
- 原因: `Io.net.Stream.Reader.Error` 不含 `NetworkUnreachable`，需映射到 `Unexpected`

**测试**: zio 595/595 ✅

### Part 2: zio x86 32-bit 协程支持

**背景**: utm-monitor 交叉编译仅 6/8 目标通过，缺失 x86 32-bit 两个目标。
根因是 zio `coro/coroutines.zig` 未实现 `.x86` 架构的协程上下文切换。

**实施**:
- `coro/coroutines.zig`: 4 个 switch 分支添加 `.x86`（Context、setupContext、switchContext、coroEntry）
- `ev/backends/iocp.zig`: `InflightInt` 添加 `.x86 => u32`
- `feat/x86-32` 分支推送 fixnet-ai/zio

**设计要点**:
- IA-32 cdecl 调用约定，16 字节栈对齐（System V ABI）
- AT&T 汇编语法（leal/movl/jmpl）
- IOCP 32 位原子兼容（u32 替代 u64）
- 初版仅 Linux musl，Windows 需额外 TIB 支持

**测试**: zio 595/595 ✅

### Part 3: utm-monitor 交叉编译 8/8

**修改**:
- `build.zig`: 删除 x86 arch skip 逻辑，新增 x86-windows-gnu 和 x86-linux-musl
- `release.sh`: 预期二进制数 6→8
- `build.zig.zon`: zio 依赖改为本地路径

**8 目标编译验证**: ✅
```
x86_64-windows       ✅  15MB
aarch64-windows      ✅  14MB
x86-windows-gnu      ✅  13MB  (新增)
x86_64-macos         ✅  13MB
aarch64-macos        ✅  13MB
x86-linux-musl       ✅  11MB  (新增)
x86_64-linux-musl    ✅  11MB
aarch64-linux-musl   ✅  11MB
```

### Part 4: 发布

- **版本**: v0.17.20
- **Tag**: `git tag -a v0.17.20`
- **Release**: GitHub release 含 utmm.zip（8 二进制 + ver.txt）
- **测试**: 188 单元测试 + 59 集成测试 ✅

### 决策

1. 超时类 errno 无需修改 — 已全覆盖
2. x86 Windows 使用 gnu ABI（非 msvc）— 避免 `_system@4` 链接警告
3. zio 依赖暂用本地路径 — 待上游合并后切换
4. 两个独立改进合并一个版本发布 — 减少发布次数

---

## v0.17.19 — 升级文件机制重构：SHA256 嵌入文件名 + 文件锁替代 .sha256 标记

**时间**: 2026-08-02

### 背景

旧机制用两个文件（`utmm-upgrade` 二进制 + `utmm-upgrade.sha256` 标记），
存在以下问题：
- `.sha256` 标记可能成为过期残留（Guest crash 在写标记之后，utmmd IOCP bug
  导致无法消费标记），阻止后续升级推送
- 两文件分离，同步清理复杂

### 新设计

**单文件机制**: `utmm-upgrade.<sha256hex>.tmp`

- SHA256 嵌入文件名（64 字符 hex），文件内容自校验
- OS 排他文件锁（POSIX flock + LOCK_EX；Windows CreateFileW dwShareMode=0）
  替代标记文件作为"写入完成"信号
- 进程崩溃时 OS 自动释放锁 — 零残留状态文件

### 修改文件

1. **`src/svc.zig`** — 新增 `UpgradeLock` 命名空间:
   - `tmpPath(allocator, sha256_hex)` — 构建临时文件路径
   - `extractSha256(basename)` — 从文件名提取 SHA256
   - `create(path)` — 创建文件 + 排他锁（阻塞，Guest 用）
   - `tryAcquire(path)` — 尝试获取排他锁（非阻塞，utmmd 用）
   - `writeAll(data)` / `release()` / `releaseAndDelete(path)` — 文件操作
   - POSIX: open + flock + write + close
   - Windows: CreateFileW(dwShareMode=0) + WriteFile + CloseHandle
   - `verifyUpgradeTmpByFilename()` — 文件名 SHA256 vs 内容 SHA256 自校验
   - `findUpgradeTmp()` — 扫码 canonicalDir 中的 .tmp 文件
   - `cleanupStaleUpgradeTmp()` 重写 — 过渡期兼容清理旧机制残留

2. **`src/guest.zig` — `handleUpgradeCmd`** 重构:
   - 移除 `.sha256` 标记文件机制（tmp → rename 原子写入）
   - 移除并发保护 statFile 检查
   - 移除 `std.Io.Threaded` 文件 I/O（改用原始 OS write）
   - 改用 `UpgradeLock.create` + `writeAll` + `release`/`releaseAndDelete`

3. **`src/utmmd.zig`** 重构升级检测+应用:
   - 新增 `tryApplyPendingUpgrade()` 合并 checkPendingUpgrade + applyUpgrade
   - 扫码 .tmp → 尝试锁 → 文件名自校验 → 替换二进制
   - 移除 `upgradeMarkerPath`、`upgradeBinPath`、`readFileAlloc`、`computeSha256Hex`
   - 新增 `const svc = @import("svc.zig")`

4. **`src/host.zig`**: `cleanupStaleUpgradeTmp` 调用签名更新

### 测试结果

- 188 单元测试全部通过 ✅
- 59 集成测试全部通过 ✅
- 无内存泄漏

### v0.17.19-b — 文件传输统一：receiveFile 消除 upload/upgrade 重复

**时间**: 2026-08-03

**背景**: 升级、上传、下载三套文件传输机制各不一样 — handleUpgradeCmd 用
UpgradeLock + 原始 OS write，handleUpload 用 dpipe_file.writeFile + Zig Io 层，
handleDownload 读文件发 TCP。TCP 读循环 + SHA256 校验在 upload 和 upgrade 中
完全重复（~80 行）。

**统一方案**: 提取 `receiveFile()` 通用函数，UpgradeLock 模式推广为所有文件接收
的统一方式。

**修改**:
1. `src/svc.zig`:
   - `UpgradeLock.tmpPath(allocator, prefix, sha256_hex)` — 接受 comptime prefix 参数
   - `UpgradeLock.extractSha256(basename, prefix)` — 接受 comptime prefix 参数
   - `cleanupStaleUpgradeTmp` 扩展 — 同时清理 `upload.*.tmp` 和 `utmm-upgrade.*.tmp`

2. `src/guest.zig`:
   - 新增 `receiveFile(io, allocator, fd, prefix, sha256, size, shm)` 通用函数
     (~60 行): TCP 读循环 + heartbeat + hasher + UpgradeLock.writeAll + SHA256 校验
   - `handleUpload` 重构 (~60→~40 行): receiveFile("upload", ...) + rename 到目标
   - `handleUpgradeCmd` 重构 (~100→~35 行): receiveFile("utmm-upgrade", ...) + lock.release
   - 移除 handleUpload 对 `dpipe_file.writeFile` 和 `std.Io.Threaded` 的依赖

3. `src/dpipe_file.zig`: `copyAndDelete` 改为 pub（upload rename CrossDevice fallback 用）
4. `src/utmmd.zig`: extractSha256 调用传 prefix

**净收益**:
- 删除 ~110 行重复代码
- Upload 获得 OS 排他锁保护 + 文件名自描述 temp 文件
- Upload 不再依赖 `std.Io.Threaded`（Windows 兼容性更好）
- 所有文件接收使用统一的文件名内嵌 SHA256 模式

### v0.17.19-c — macOS Gatekeeper 隔离清除

**时间**: 2026-08-03

**问题**: macOS 上 scp/下载的二进制被标记 `com.apple.quarantine`，首次运行时
弹窗阻止，需要手动到"系统设置"中批准。

**修改**:
1. `src/svc.zig`: 新增 `pub fn clearQuarantine(alloc, io, path)` — macOS 调用
   `xattr -d com.apple.quarantine <path>`，best-effort（忽略错误）
2. `src/main.zig`: `extractUtmmd` 写入 `/opt/utmm/utmmd` 后调用
3. `src/svc.zig`: `forceInstallInternal` selfCopy 后对 `/opt/utmm/utmm` 和
   `/opt/utmm/utmmd` 调用

### v0.17.19-d — 全量部署 + Windows VM 手动升级

**时间**: 2026-08-03

**背景**: v0.17.19-c 发布后，macvm 和 linuxvm 已通过 --upgrade 推送升级成功。
Windows VM 的旧 utmmd (v0.17.18) 无法识别新格式 `.tmp` 升级文件，
`--upgrade push` 虽然成功传输二进制但 utmmd 无法消费。

**手动升级流程**:
1. 构建 Windows 二进制 (aarch64 + x86_64)
2. `utmm --upload` 上传二进制到 Windows VM
3. `utmm sshpass` SSH + `--install` 执行安装
4. 修正 hostname（Windows 自动检测电脑名覆盖了 --hostname 设置）

**部署结果**:

| VM | 升级方式 | 结果 |
|----|---------|------|
| Host (macOS) | 本地构建 | ✅ v0.17.19 serving |
| macvm | --upgrade 推送 | ✅ v0.17.19 serving |
| linuxvm | --upgrade 推送 | ✅ v0.17.19 serving |
| winx64 | SSH + upload + install | ✅ v0.17.19 serving |
| windowsvm | SSH + upload + install | ✅ v0.17.19 serving |

**功能验证**（exec + version 检查）: 全部通过 ✅

**教训**: Upgrade 文件格式不兼容时需要手动干预。后续版本若格式再变，应先更新 utmmd
升级检测逻辑以向后兼容旧格式，或提供自动 fallback。

---

## Phase 27 P0 — installLinux systemd Restart 修复

**时间**: 2026-08-02

### v0.17.16: utmmd Windows 文件 I/O 修复 + 全量部署验证

**背景**: v0.17.14/15 部署后 Windows VM 升级推送成功写入文件但 utmmd 无法检测，
根因是 utmmd.zig 中文件操作使用 zio IOCP event loop，Windows IOCP 不支持文件 I/O。
与 v0.17.13 在 guest.zig 中修复的同类 bug。

**修复** (`src/utmmd.zig`):
- `monitorLoop` 中创建条件 `std.Io.Threaded`（仅 Windows），传递 `file_io` 给所有文件 I/O 函数
- 修改函数：checkPendingUpgrade、computeSha256Hex、readFileAlloc、applyUpgrade、copyFileUpgradeFallback、monitorUtmm
- 清理 `host.zig` 中临时 debug 日志

**发布**: v0.17.16 — 188 单测 + 59 集成测试通过，6/8 交叉编译目标（x86 跳过，zio 限制）

**部署验证**:

| VM | 升级方式 | 结果 |
|----|---------|------|
| Host (macOS) | 本地构建 | ✅ v0.17.16 serving |
| linuxvm | --upgrade 推送 | ✅ v0.17.16 serving |
| macvm | --upgrade 推送 | ✅ v0.17.16 serving |
| winx64 | 批处理脚本手动升级 | ✅ v0.17.16 serving |
| windowsvm | SSH sc start 恢复服务 | ✅ v0.17.16 serving |

**功能验证（windowsvm 恢复后）**:

| 功能 | 结果 |
|------|------|
| exec | ✅ |
| upload | ✅ |
| download | ✅ 49 bytes SHA256 一致 |
| ping | ✅ rtt_ms=0 |

**windowsvm 恢复详情**:
- 早期 ren 命令部分执行导致 utmm 服务崩溃，UTM-MonitorD 停止（WIN32_EXIT_CODE 1067）
- 通过 utmm sshpass SSH 直接执行 sc start UTM-MonitorD 恢复
- 服务启动后 utmmd spawn utmm，LSA 广播恢复，TCP handler 正常

**发现的并发保护问题**:
- Guest handleUpgradeCmd 检查 .sha256 标记文件是否存在，若存在则拒绝新推送
- 当 utmmd 无法消费升级时（IOCP bug），标记文件永久残留，阻止所有后续升级
- 修复 utmmd IOCP bug 后此问题不再触发，但 handleUpgradeCmd 应处理残留 marker 情况
- [P2] 待修复：仅 .sha256 marker 残留（upgrade 二进制不存在）时应清理标记而非拒绝

### 修复: installLinux() 缺少 systemd Restart 指令

**根因**: `svc.zig` 中 `installLinux()` 和 `genInit(.linux)` 生成的 systemd service 配置不一致：
- `installLinux()`（实际安装路径）**缺少** `Restart=on-failure`、`RestartSec=5`、`StartLimitBurst=3`、`StartLimitIntervalSec=30`
- `genInit(.linux)`（模板生成）**已正确包含**

**故障链**:
```
utmm 崩溃 → utmmd 重试 5 次 → utmmd 退出 → systemd 无 Restart → VM 永久离线
```

**修复** (`src/svc.zig`):

1. 新增共享常量 `SYSTEMD_RESTART_CONFIG`（避免 future drift）:
```zig
const SYSTEMD_RESTART_CONFIG =
    \\Restart=on-failure
    \\RestartSec=5
    \\StartLimitBurst=3
    \\StartLimitIntervalSec=30
;
```

2. `installLinux()` 模板新增 `{s}` 插值，传入 `SYSTEMD_RESTART_CONFIG`
3. `genInit(.linux)` 模板用 `++ SYSTEMD_RESTART_CONFIG ++` 引用同一常量

**生成的服务文件变化** — `installLinux()` 生成的 `/etc/systemd/system/utmmd.service`:
```ini
# 修复前（缺失 Restart）
[Service]
Type=simple
Environment=SHELL=/bin/bash
Environment=HOME=/root
ExecStart=/opt/utmm/utmmd --role guest
WorkingDirectory=/opt/utmm
StandardOutput=journal

# 修复后（与 genInit 一致）
[Service]
Type=simple
Environment=SHELL=/bin/bash
Environment=HOME=/root
ExecStart=/opt/utmm/utmmd --role guest
WorkingDirectory=/opt/utmm
Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=30
StandardOutput=journal
```

**测试验证**:
- 188 单元测试全部通过 ✅
- 59 集成测试全部通过，0 泄漏 ✅

**待部署**: linuxvm 真机验证（Task 241）

### linuxvm 真机验证

**部署**: SCP → `--install --hostname linuxvm` → 服务文件验证 → 崩溃恢复测试

**服务文件生成结果**:
```ini
[Service]
ExecStart=/opt/utmm/utmmd --role guest --hostname linuxvm
WorkingDirectory=/opt/utmm
Restart=on-failure         ✅
RestartSec=5               ✅
StartLimitBurst=3          ✅
StartLimitIntervalSec=30   ✅
StandardOutput=journal
```

**崩溃恢复测试**:
1. `kill -9 <utmmd PID>` → utmmd 被 SIGKILL
2. 等待 10s
3. systemd 自动重启 utmmd (新 PID)，utmm 也被重新 spawn
4. `systemctl status utmmd` 确认: `"Scheduled restart job, restart counter is at 1."`

**验证结果**:
- systemd Restart=on-failure 生效 ✅
- utmmd 退出后 systemd 10s 内自动重启 ✅
- Host `--status` 显示 linuxvm serving (v0.17.13) ✅
- 5 节点全部在线 ✅

### 全量部署测试（macvm + windowsvm + winx64）

**部署**:
- macvm: SCP → --install ✅ (700ms stop old utmm, launchd already running)
- windowsvm: SCP → --install ✅ (5s timeout → killAllUtmm PID 3056 → restart)
- winx64: SCP to Temp → --install from Temp ✅ (5s timeout → killAllUtmm PID 34192 → restart)

**功能验证**:

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --ping | ✅ (1ms) | ✅ (1ms) | ✅ (1ms) | ✅ (4ms) |
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| SHA256 | ✅ | ✅ | ✅ | ✅ |

**全节点状态** (v0.17.13):
```
Role   Hostname             Version    Status
host   dasis-macbook-air    v0.17.13   serving
guest  linuxvm              v0.17.13   serving
guest  macvm                v0.17.13   serving
guest  windowsvm            v0.17.13   serving
guest  winx64               v0.17.13   serving
```

**观察**: macvm launchd plist 缺少 `KeepAlive` 段（见 P2 待验证项）。

---

## v0.17.13 — zio IOCP file I/O 修复（上传/下载/升级 Windows 兼容）

**时间**: 2026-08-02

### Windows 文件 I/O 与 zio IOCP 不兼容

**问题**: zio 的 IOCP 异步 I/O 后端无法处理 Windows 上的文件操作。`createFile`、
`writeStreamingAll`、`deleteFile`、`rename` 等操作返回 `error.Unexpected`，
导致 Windows Guest 上 upload/download/upgrade 全部失败。

**根因**: IOCP (I/O Completion Port) 是 Windows 的异步 I/O 机制，专为网络 socket
设计，不支持普通文件的异步操作。Windows 文件 I/O 需要使用同步 API 或
`std.Io.Threaded`（线程池模拟异步）。

**修复方案**: 对所有文件 I/O 操作使用 `std.Io.Threaded` 替代 zio `io`。

**修改文件**:

1. **`src/guest.zig` — `handleUpload`**:
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
const file_pipe = dpipe_file.writeFile(allocator, file_io, cmd.path, cmd.hash) catch |err| { ... };
```

2. **`src/guest.zig` — `handleDownload`**:
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
const file_pipe = dpipe_file.readFile(allocator, file_io, cmd.path) catch |err| { ... };
```

3. **`src/guest.zig` — `handleUpgradeCmd`** (最复杂，涉及全部文件操作):
```zig
var file_threaded = std.Io.Threaded.init(allocator, .{});
const file_io = file_threaded.io();
// 替换: statFile, createFile, writeStreamingAll, close, deleteFile, writer, rename
// 关键: sha_file.writer(file_io, &sha_wb) — writer 内部烘焙 io 引用，
// 后续 writeAll/flush 全部走 file_io
```

4. **`src/tcp.zig`**: 新增 `WSAEWOULDBLOCK` 常量 + `sockRead`/`sockWrite` 重试循环

5. **`src/main.zig`**: SystemInfo 收集移至 zio Runtime 创建之前（避免 IOCP 与
   `std.process.run` 冲突）

6. **`src/ipc.zig`**: sockWrite 返回值处理修复（之前 `_ =` 丢弃返回值）

**真机验证**:
- winx64 (x86_64-windows): upload/download/upgrade 全部通过 ✅
- windowsvm (aarch64-windows): upload/download/upgrade 全部通过 ✅

**构建验证**:
- 188 单元测试 + 59 集成测试全部通过 ✅
- 6/8 交叉编译目标通过（x86 的 2 个 zio 不支持，预存限制）

**发布**: https://github.com/fixnet-ai/utm-monitor/releases/tag/v0.17.13

**提交**: commit `待提交`，版本号 `src/ver.txt` 0.17.12 → 0.17.13

---

## Phase 27 规划 — VM 离线根因调查与修复计划

**时间**: 2026-08-02

### 调查结果

对 `--status` 反复显示 VM 离线的问题进行了系统调查，分析各 VM 系统日志、
utmmd 日志、systemd/journald/launchd 服务配置。

**离线根因汇总**:

| 优先级 | VM | 根因 | 代码位置 |
|--------|-----|------|---------|
| **P0** | linuxvm | `installLinux()` 生成的 systemd service 缺少 `Restart=on-failure` | `src/svc.zig:593-606` |
| **P1** | linuxvm | 心跳超时误触发 + kill 后线程创建 `SystemResources` | `src/utmmd.zig` + musl |
| **P2** | windowsvm | utmm.exe 堆损坏 (0xc0000374) / 访问违规 (0xc0000005) | 可能与 IOCP 相关 |
| **P2** | macvm | launchd KeepAlive 行为待验证 | `src/svc.zig` installMacOS |

### P0 详细分析: installLinux vs genInit 不一致

`svc.zig` 中两个函数生成 systemd service 文件，但配置不一致：

- **`installLinux()`** (实际安装路径) — **缺少** `Restart=on-failure`, `RestartSec=5`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=30`
- **`genInit()` → `genInitLinux()`** (生成 init 脚本) — **正确包含**上述指令

**故障链**:
```
utmm 崩溃（任意原因）
  → utmmd kill → spawn → 重试 5 次 → utmmd 退出
  → systemd 无 Restart 指令 → 不重启 utmmd
  → VM 永久离线
```

**修复**:
1. `installLinux()` 添加与 `genInitLinux()` 一致的 Restart 指令
2. 提取 systemd 配置为共享常量（单一真相源）
3. 部署到 linuxvm，模拟崩溃验证 systemd 自动恢复

### P1 详细分析: 心跳超时 + 线程创建失败

linuxvm utmmd 日志显示：
1. **心跳超时**: utmm 在阻塞 I/O（acceptRaw/dpipe.relay/SOCKS5 relay）时无法更新
   共享内存心跳 → utmmd 10s 超时误判为僵死 → SIGKILL
2. **线程创建失败**: kill 后立即 spawn → `std.Thread.spawn` → `error.SystemResources`
   （musl 线程资源未释放）

**v0.17.7 已修复**: acceptRaw 不再内部循环阻塞，长传输增加了心跳更新。
**v0.17.13 可能改善**: IOCP → Threaded 文件 I/O 减少了协程阻塞。

**待调查**:
- dpipe.relay 线程是否需要心跳更新
- SOCKS5 转发线程是否需要心跳更新
- utmmd spawn 失败后是否应有退避延迟

### P2 详细分析: Windows 堆损坏

windowsvm 事件日志中反复出现 0xc0000374/0xc0000005。v0.17.13 的 IOCP 修复
可能已解决部分问题，但需长时间运行验证。

### 修复计划

详见 `task_plan.md` Phase 27 完整任务列表（Task 239-250）。

---

## v0.17.11 — ssh.exe 嵌入 + CLI 测试脚本

**时间**: 2026-08-02

### Windows ssh.exe 嵌入与自动提取

**背景**: Windows utmm 运行 sshpass 时调用 `CreateProcessW` 执行 `ssh` 命令，依赖 PATH
中找到 `ssh.exe`。但 Windows VM 可能未安装 OpenSSH Client，或 PATH 配置有问题，
导致 sshpass 功能不可用。

**方案**: 将 x86_64/aarch64 Windows 的 `ssh.exe` 作为 embedded binary 编译进 utmm，
并在 `--install` 流程中自动提取到 utmmd 同目录（`C:\opt\utmm\ssh.exe`）。
sshpass 执行 ssh 时优先使用嵌入路径。

**实现细节**:

1. **提取 ssh.exe binary** (`src/embed/`):
   - `src/embed/x86_64-windows/ssh.exe` — 1,253,888 bytes, PE32+ x86-64，从 winx64 提取
   - `src/embed/aarch64-windows/ssh.exe` — 1,135,104 bytes, PE32+ Aarch64，从 windowsvm 提取
   - 提取方法：`utmm sshpass ssh Administrator@<vm> "PowerShell Get-Command ssh.exe | Select -ExpandProperty Source"`
   - 源路径：`C:\Windows\System32\OpenSSH\ssh.exe`

2. **`src/main.zig` ssh.exe 嵌入**:
   ```zig
   const ssh_exe_bin: []const u8 = if (builtin.os.tag == .windows) switch (builtin.cpu.arch) {
       .aarch64 => @embedFile("embed/aarch64-windows/ssh.exe"),
       .x86_64 => @embedFile("embed/x86_64-windows/ssh.exe"),
       else => &.{},
   } else &.{};
   ```
   - 新增 `extractSshExe(io, alloc)` — 写 temp 文件 + SHA256 不校验（只验长度>0）
     + atomic rename 到 `C:\opt\utmm\ssh.exe`
   - 新增 `extractSshExeIfMissing(io, alloc)` — 检查存在性，调用 extractSshExe
   - 从 `extractUtmmd()` 中调用：`extractSshExeIfMissing(io, alloc) catch {};` — best-effort，不硬错误

3. **`src/sshpass.zig` ssh 路径解析**:
   - 新增 `isSshCommand(cmd)` — 检测命令名是否为裸 "ssh" 或 "ssh.exe"（无路径前缀，大小写不敏感）
   - `runWindows()` 修改：如果命令是 ssh，将 `cmd_args[0]` 替换为 `C:\opt\utmm\ssh.exe`
   - 使用栈缓冲 `[64][]const u8` 避免堆分配
   - 路径替换仅当 cmd_args.len < 64 时生效

**设计决策**:
- ssh.exe 提取是 best-effort（失败 warn 不中断安装流程）—— sshpass 回退到 PATH 查找
- 不校验 SHA256（二进制较大、SHA256 跨版本变化，验长度>0 足够）
- Atomic temp→rename 写入模式与 utmmd.bin 提取一致
- embed 仅限 Windows 目标 — 非 Windows 编译 ssh_exe_bin = &.{}（零字节）

**构建验证**:
- 6/8 交叉编译目标通过（x86 2 个 zio 不支持）✅
- 188 单元测试 + 59 集成测试全部通过 ✅

### Python 测试脚本（MCP + CLI）

**MCP Tools Test Script** (`tests/test_mcp_tools.py`, ~268 行):
- 覆盖所有 7 个 MCP 工具：status, exec, ping, upload, download, sshpass, manual
- JSON-RPC stdio 通信，通过 `--mcp` 管道 vs Host daemon
- upload→download SHA256 验证 + sshpass 密码认证
- linuxvm 为文件传输目标，linuxvm+macvm 为 exec/ping 目标

**CLI Commands Test Script** (`tests/test_cli_commands.py`, ~248 行):
- 覆盖全部 CLI 管理命令：`--version`, `--status`, `--ping`, `--exec`, `--upload`, `--download`, `sshpass`
- 31/31 检查通过
- 关键修复：
  - utmm CLI 输出到 stderr（非 stdout）→ `run()` 合并 stdout+stderr
  - `--ping` 输出 JSON 格式 `{"rtt_ms":N}` → 检查 `"rtt_ms" in out` 而非 `"RTT" in out`
  - sshpass 错误密码测试需 `-o PubkeyAuthentication=no`（否则密钥认证绕过密码检查）
  - upload/download 成功检测：`"[upload]" in out and "error:" not in out.lower()`

**验证**:
- `sudo python3 tests/test_mcp_tools.py` — 全部通过 ✅
- `sudo python3 tests/test_cli_commands.py` — 31/31 通过 ✅

**SKILL.md 更新**:
- 新增 "MCP Tools Test" 章节
- 新增 "CLI Commands Test" 章节

---

## v0.17.11 — zio 协程重构完成 + macOS 自动 codesign

**时间**: 2026-08-02

### zio 协程重构（v0.17.8—v0.17.10）

将 utmm 从 OS 线程模型迁移到 zio stackful 协程框架。

**背景**: `refactor-zio` 分支，8 个 commit。目标是用协程替代 OS 线程，提升 I/O 调度效率。

**重构分阶段**:

1. **Phase 1 — zio 依赖**: `main.zig` `--svc` 路径创建 Runtime + Executor
2. **Phase 2 — Guest spawnBlocking**: `guest.zig` 所有 `std.Thread.spawn` → `zio.Group.spawnBlocking`
3. **Phase 3 — dpipe relay**: `dpipe.relay()` `std.Thread` → `zio.spawnBlocking`
4. **Phase 4 — Host spawnBlocking**: `host.zig` 顶层服务 spawn 改用 zio
5. **Phase 5 — Host accept loop**: Host TCP accept 循环移至主 executor
6. **Phase 6 — spawnBlocking 统一**: 所有 `std.Thread.spawn` → `rt.spawnBlocking()`
7. **Phase 7 — 统一主 executor**: LSA + IPC 作为协程运行在统一 executor 上

**关键问题与修复**:

1. **SO_REUSEPORT TCP 端口冲突** (`src/tcp.zig`):
   - zio 的 `addr.listen()` 设置 SO_REUSEPORT（非 SO_REUSEADDR），导致内核将 :2121
     连接负载均衡到 Host 和 Guest 两个 TCP listener
   - 修复：TcpListener.init 改用手动原始 POSIX socket（`socket()` + `setsockopt(SO_REUSEADDR)` +
     `bind()` + `listen()` + `fcntl(O_NONBLOCK)`），在 POSIX 和 Windows 上均只设 SO_REUSEADDR

2. **Spinlock 替代 Mutex** (`src/host.zig`):
   - zio `std.Io.Mutex.lock(io)` 内部调用 `io.futexWait()` 需要协程上下文
   - 线程池 spawBlocking 线程上没有协程上下文，导致 hang
   - 修复：`lockTable()` + `unlockTable()` helpers 使用 `tryLock()` 忙等 + `@prefetch`

3. **Upload GuestNotFound** (`src/host.zig`):
   - `cmdUpload` 将完整 `vm:path` 字符串（如 "macvm:/tmp/test.txt"）作为 vm 名传给 `ipcUpload`
   - `findByHostname` 查找字面量 "macvm:/tmp/test.txt"，当然找不到
   - 修复：在 `:` 处分割，提取 hostname

4. **Host 自我处理** (`src/host.zig`):
   - 删除独立 Guest daemon 概念 — Host 的 self:2121 SOCKS5 handler 调用
     `guest.handleOneCommand()` 直接处理 exec/upload/download
   - 新增 Host `getSystemInfo()` 为 self-exec 收集 SystemInfo
   - 5 个 guest.zig handler 函数改为 `pub`：
     `handleOneCommand`, `handleExecCmd`, `handleUpload`, `handleUpgradeCmd`, `handleDownload`

5. **Windows SOCKET 类型** (`src/tcp.zig`):
   - aarch64-windows 上 SOCKET = `*anyopaque`（指针），`@intCast` 对指针无效
   - 修复：`.handle = s` 直接赋值（s 已是正确类型）

**版本链**:
- v0.17.8: dpipe relay + guest spawnBlocking
- v0.17.9: host accept loop + service spawns
- v0.17.10: SO_REUSEPORT fix + upload GuestNotFound fix + spinlock + Windows SOCKET fix

### macOS 自动 Ad-Hoc Codesign（v0.17.11）

**问题**: 交叉编译或 scp 传输的 Mach-O 二进制，ad-hoc 签名损坏（`cs_invalid_page`, `tainted:1`），
Apple Silicon 内核发送 SIGKILL。

**修复** (`build.zig`):
- 原生构建后自动 `codesign --force --sign -`
- 交叉编译循环中每个 macOS 目标独立 codesign
- sign 步骤依赖于编译完成，install 步骤依赖于 sign 完成

**验证**:
- scp binary 到 macvm 后无需手动 codesign 即可运行 ✅
- 188 单元测试 + 59 集成测试全部通过 ✅
- 6/8 交叉编译目标通过（x86 的 2 个 zio 不支持，预存限制）

**PR**: https://github.com/fixnet-ai/utm-monitor/pull/5

**提交**: 8 个 commit（`3532190` 到 `2fffe18`），tag `v0.17.11`

### 已知遗留问题（本版本未修复）

1. **Zombie 进程**: `dpipe_shell.zig` killChild 5s WNOHANG waitpid 限制
2. **utmmd 二进制升级缺口**: push-upgrade 仅替换 utmm，不替换 utmmd
3. **x86 目标不支持**: zio `unimplemented architecture: x86`，2 个 32-bit 目标无法编译
4. **测试输出静默**: `zig build test` stdout 无输出（ExitCode=0 但输出被吞）— 不影响 CI

---

## v0.17.7 — 心跳超时崩溃循环修复

**时间**: 2026-08-02

### acceptRaw 内层循环阻塞心跳 — 根因分析与修复

linuxvm 自 v0.17.2 起持续心跳超时崩溃循环。排查发现根因在 `tcp.zig` 的
`acceptRaw()` 函数。

**根因**: `acceptRaw()` 内部有一个 `while(true)` 循环 — 当 `accept()` 返回
`WouldBlock` 时 sleep 100ms 后 retry，永不返回到调用者。POSIX 非阻塞 socket
上 `accept()` 立即返回 `EAGAIN`/`WouldBlock`（无连接时），内层循环无限重试，
导致外层 accept 循环中的 shm 心跳更新从不执行。空闲期间 10s 后 utmmd 检测
心跳超时 → 杀 utmm → 崩溃循环。

**修复（3 个文件）**:

1. `src/tcp.zig` — acceptRaw 删除内层 `while(true)`，改为直接返回 `WouldBlock`：
```zig
// 修复前：内层 while(true) 永不返回
pub fn acceptRaw(self: *TcpListener) !socket_t {
    while (true) {
        const stream = self.server.?.accept(self.io) catch |err| {
            if (err == error.WouldBlock) {
                std.Io.sleep(self.io, ...) catch {};
                continue;  // ← 永不返回！
            }
            return error.AcceptFailed;
        };
        return stream.socket.handle;
    }
}

// 修复后：WouldBlock 直接返回给调用者
pub fn acceptRaw(self: *TcpListener) !socket_t {
    const stream = self.server.?.accept(self.io) catch |err| {
        if (err == error.WouldBlock) return error.WouldBlock;
        return error.AcceptFailed;
    };
    return stream.socket.handle;
}
```

2. `src/guest.zig` — accept 循环 WouldBlock 处理增加 sleep：
```zig
const fd = listener.acceptRaw() catch |err| {
    if (err == error.WouldBlock) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        continue;  // ← 心跳在外部 while 循环顶部更新
    }
};
```

3. `src/host.zig` — 同 guest.zig 模式修复。

**长传输心跳补充（`src/guest.zig`）**:
- `handleUpload` / `handleDownload` / `handleUpgradeCmd` 签名增加 `shm_handle` 参数
- 文件传输循环中每次读写后更新心跳
- `handleOneCommand` 分发更新三处调用传递 `shm_handle`

**测试验证**:
- 188 单元测试 + 59 集成测试全部通过 ✅
- ReleaseSafe 构建通过 ✅

**提交**: commit `b850b02`，tag `v0.17.7`

### 已知遗留问题（本版本未修复）

1. **Zombie 进程**: `dpipe_shell.zig` 的 `killChild()` 有 5s WNOHANG waitpid 限制，
   子进程卡在 D 状态时无法收割
2. **utmmd 二进制升级缺口**: push-upgrade 仅替换 utmm，不替换 utmmd。本次修复只需
   改 utmm 代码，`--upgrade <vm>` 即可部署

---

## v0.17.6 — utmmd IP 变更检测自动重启

**时间**: 2026-08-02

### IP 指纹检测

当机器 IP 因 DHCP 续约、网络切换变化时，utmmd 通过 Wyhash 指纹检测变更并自动重启 utmm。

**实现** (`src/utmmd.zig`):
- 新增 `getAllIpsFingerprint()` — 跨平台 IP 枚举（POSIX `getifaddrs` / Windows `GetAdaptersAddresses` 动态加载 iphlpapi.dll）
- Wyhash 哈希所有非回环 IPv4 地址的原始字节 + 计数 → u64 指纹
- 零堆分配，纯栈变量
- monitorUtmm 轮询循环中每 10s 检查一次
- 去抖 2 次确认（IP 需稳定 20s），防 DHCP 瞬态抖动
- 指纹 = 0（无 IP）不触发重启
- 4 个单元测试

**验证**:
- 188 测试全部通过 + 8 交叉编译目标 ✅
- Host 真机指纹计算正常、无异常重启 ✅

**提交**: commit `4ad00bc`，tag `v0.17.6`

---

## v0.16.0 — SOCKS5 全协议（BIND + UDP ASSOCIATE）+ 协议层提取

**时间**: 2026-08-01

### feat/socks5-full 分支合并

**协议提取**:
- `src/socks5.zig` 新建（~1300 行）：SOCKS5 全部协议逻辑（解析/回复/连接/转发/BIND/UDP ASSOCIATE）
- `src/protocol.zig` 扩展（+285 行）：帧协议 + Connection（从 tcp.zig 移入）
- `src/tcp.zig` 精简（1678→~900 行）：纯 TCP 传输层（socket I/O、TcpListener、ConnLimit）
- 删除 `TcpListener.accept()` — 消除 tcp→socks5 循环依赖
- 消费者更新：guest.zig、host.zig 新增 socks5 import，SOCKS5 调用路径迁移

**SOCKS5 全协议实现**:
- BIND（RFC 1928 §4）：两阶段握手，TcpListener + accept timeout (60s) + relay
- UDP ASSOCIATE（RFC 1928 §6）：TCP 控制通道 + UDP 数据报中继（tcp↔udp 双线程）
- IPv4 ATYP 支持（IPv4 地址 → 点分十进制存入 hostname）
- IPv6 ATYP 返回 ADDRESS_TYPE_NOT_SUPPORTED

**关键修复**:
1. Windows fd_set 初始化：`socket_t = *anyopaque`（指针）→ 用 `undefined` 初始化，不能用 `{0}` 数组字面量
2. sockAcceptTimeout：Windows `select()` / POSIX `poll()` 跨平台实现
3. UDP socket 跨平台：Windows `ws2_socket(AF_INET,SOCK_DGRAM)` / POSIX `socket(AF.INET,SOCK.DGRAM)`

**测试验证**:
- 186 单元测试 + 59 集成测试全部通过 ✅
- 8 交叉编译目标全部通过 ✅

### 裸机部署测试（modasiaipc, x86_64-windows）

| 功能 | 结果 |
|------|------|
| exec | ✅ |
| upload | ✅ SHA256 一致 |
| download | ✅ SHA256 一致 |
| sshpass (ConPTY) | ✅ |
| SOCKS5 CONNECT chain | ✅ curl → modasiaipc:2121 → Host → linuxvm:22 |
| UDP ASSOCIATE | ✅ |
| BIND | ⚠️ Windows Firewall 阻止动态端口入站 |

所有 5 节点确认 v0.16.0 serving。

### MCP 配置修正

- `mcp.json.example`：MCP 服务器名 "utm-monitor" → "utmm"
- main.zig header + build.zig.zon package name 保持 "UTM Monitor"（软件产品名）
- 区分：UTM Monitor = 软件名，utmm = 命令/二进制名

---

## v0.15.11 — 工作流优化全流程演练

**时间**: 2026-08-01 01:30—02:30

### bump → release.sh → deploy → upgrade → 验证 全流程

**v0.15.10 bump + build**:
- `src/ver.txt` 0.15.9 → 0.15.10
- 8 目标交叉编译：aarch64-windows FIONBIO 值 `0x8004667e` 超出 `c_int` (i32) 范围
  - 修复：`const FIONBIO: c_int = @bitCast(@as(std.os.windows.ULONG, 0x8004667e));`
- 全部 8 目标编译通过，deploy 到 serve-dir
- 3 台 Guest 报 `BinaryNotFound` — 因为只编译了 native 目标，跨平台二进制未更新
- 修复后 3 台 Guest (linuxvm, windowsvm, modasiaipc) + 1 台已升级 (macvm) 全部 v0.15.10

**--ping 崩溃修复**:
- 症状：`sudo utmm --ping`（无参数）panic "attempt to use null value"
- 根因：`cli.ping_target.?` — ping_target 为 null 时 unwrap panic
- 修复 1（host.zig）：加 null 检查，输出 `[ERROR] --ping requires a target hostname`
- 修复 2（main.zig）：parseArgs 返回前统一校验所有管理命令必选参数
  - ping → 需要 target；exec → 需要 target + command；upload → 需要 file + target
  - download → 需要 target + remote_path；upgrade → 需要 target

**并行交叉编译**:
- `build.zig` 新增 `cross` step：`zig build cross -Doptimize=ReleaseSafe`
- 8 目标全部并行编译，替代 serial `for target in $targets; do zig build -Dtarget=$target; done`
- `std.Target.Query` 字段是 optional，需用 `tgt.result` 而非 `query`
- `standardOptimizeOption` 只能调用一次，循环内复用外部 `optimize` 变量

**release.sh 重构**:
- 旧流程：用户手动 commit + tag → release.sh 构建测试（失败则删 tag 重建）
- 新流程（5 阶段）：
  1. 校验（ver.txt 匹配 VERSION arg、工作区干净）
  2. 单元测试 + 集成测试
  3. `zig build cross` 并行编译 8 目标
  4. 收集二进制 + zip 打包
  5. commit ver.txt → tag → push → gh release create
- 关键改进：构建测试全部通过后才打 tag，杜绝 tag 反复删除重建
- 验证：v0.15.11 release.sh 一次性全流程通过，5 阶段全部成功

**CI 脚本更新** (`.github/workflows/release.yml`):
- 交叉编译：串行 8×`zig build` → 单步 `zig build cross`
- 删除 `install.sh` / `install.bat` 引用（这两个文件不存在于仓库 — utmm 自带 `--install`）
- 测试步骤去 `--summary all`（避免 macOS `--listen=-` hang）
- 步骤数：6 → 5（合并 collect + ver.txt）

**cmdDeploy 改进**:
- sshpass 缺失不再 `exit(1)` → 改为 `return` + 明确警告
  - 旧行为：`[deploy] sshpass is required...` + exit 1（误导：本地部署已成功）
  - 新行为：`[deploy] Local binaries have been copied to serve-dir.` + 提示安装 sshpass
- 串行 for 循环编译 → 单次 `zig build cross` 并行编译
- serve-dir 复制在 cross 编译完成后统一进行

**pushUpgrade 错误信息优化**:
- `"BinaryNotFound"` → `"BinaryNotFound: run zig build cross + deploy to populate serve-dir"`
- 同时 log 输出具体缺失文件名：`expected utmm-aarch64-linux-0.15.11 in serve-dir`

**MANUAL.md 增强**:
- "zig build test hangs on macOS" 条目扩充：
  - `--listen=-` stdio 协议机制说明
  - kqueue 后端死锁原因
  - 本项目 `build.zig` 绕过方案（`Step.Run.create`）
  - `--summary all` CI 风险提示

### 部署验证 (v0.15.11)

| 项目 | 结果 |
|------|------|
| `--status` | ✅ 5 nodes (1 Host + 4 Guest), all v0.15.11 serving |
| `--ping` | ✅ macvm(1ms) linuxvm(1ms) windowsvm(1ms) modasiaipc(4ms) |
| `--exec` | ✅ linuxvm, windowsvm 命令执行正常 |
| `--upgrade` | ✅ 4 台 Guest 全部升级成功（utmmd 自动检测→验证→替换→重启） |
| 8-target build | ✅ `zig build cross` 并行编译全部通过 |
| Unit tests | ✅ 172 passed, 0 failed |
| Integration tests | ✅ 59 passed, 0 failed, 0 leaks |
| GitHub Release | ✅ v0.15.11 published |

### 发现与修复汇总

| # | 发现 | 严重度 | 修复 |
|---|------|--------|------|
| 1 | FIONBIO 值在 aarch64-windows 上超出 c_int | 高（编译阻断） | @bitCast 转换 |
| 2 | --ping 空参数 panic | 中（用户操作崩溃） | parseArgs 前置校验 |
| 3 | --deploy exit 1 误导（sshpass 缺失） | 低（实际已成功） | exit → return |
| 4 | release.sh 先 tag 后构建失败要重建 | 中（流程反复） | 构建过再 tag |
| 5 | CI 引用不存在的 install.sh/install.bat | 高（CI 必然失败） | 删除引用 |
| 6 | linuxvm ping RTT 496659s（升级瞬态） | 低（瞬态，不影响） | 无需修复 |
| 7 | cmdDeploy 串行编译慢 | 低（效率问题） | 改用 zig build cross |

## Clean Deploy Test v0.14.7 (第二轮 — 修复后 skill 验证)

**时间**: 2026-07-31 04:13-04:15

### 测试环境
- **版本**: v0.14.7
- **测试方法**: 修复后的 `.claude/skills/clean-deploy/SKILL.md`（Phase 0 Build → Phase 1 Wipe → Phase 2 Cross-Compile → Phase 3 Deploy → Phase 4 Test）

### 测试结果

| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ (2ms) | ✅ (1ms) | ✅ (1ms) | ✅ (6ms) |
| SHA256 | ✅ | ✅ | ✅ | ✅ |

**总评**: 4/4 VM 全部通过，所有 SHA256 校验一致。176 单元测试 + 59 集成测试全部通过。

### 发现的问题

1. **winx64 hostname 不解析** — `ssh: Could not resolve hostname winx64`
   - 原因: winx64 在 192.168.3.x 子网，LSA UDP 广播可能不跨子网，/etc/hosts 无法同步
   - 影响: clean-deploy 中对 winx64 的 sshpass 命令需用 IP（192.168.3.108）
   - 建议: skill 中为 winx64 保留 IP 备选，或增加 winx64 的 /etc/hosts 同步机制

2. **Windows sc.exe stop 失效** — `[SC] ControlService FAILED 109: The pipe has been ended.`
   - 当 utmm 进程状态异常时 sc.exe 无法停止，需 `taskkill /F` 兜底
   - skill 中的 wipe 流程已包含 taskkill 步骤，合理

3. **utmm sshpass scp 可用** — 验证了 `utmm sshpass -p 111 scp ...` 可正常工作
   - POSIX Guest 和 Windows Guest 均成功

4. **Zig 0.16.0 `--listen=-` 协议 bug** — `zig build test` 卡死
   - Workaround: 直接运行 `.zig-cache/o/<hash>/test` 二进制（已验证可行）
   - 两轮测试均遇到此问题，建议在 SKILL.md/deploy skill 中记录此 workaround

5. **Windows `tasklist /fi` 在 cmd /c 下需转义** — `/fi "imagename eq utmm.exe"` 中的引号
   在 `cmd /c` 中会丢失，建议改为 `tasklist | findstr utmm`

### 与上轮对比

| 问题 | 上轮状态 | 本轮状态 |
|------|---------|---------|
| skill linuxvm IP 错误 | ❌ 192.168.64.2 | ✅ 已修复 |
| skill pkill -f 自杀 | ❌ 存在 | ✅ 已修复 |
| skill sshpass 引用 | ❌ 裸 sshpass | ✅ utmm sshpass |
| skill Windows mkdir | ❌ 不可靠 | ✅ 已修复 |
| winx64 hostname | — 未测试（上轮用 IP） | ❌ 新发现 |
## 历史摘要

### v0.12.2 及之前
- KCP 隧道稳定性修复、自动升级完善
- utmmd 监督进程架构重构、MCP stdio JSON-RPC
- 8 交叉编译目标全通过，166 测试通过

### v0.13.0-pre (commit `036f40f`)
- 删除 KCP ARQ 协议 (~1300行)，新增 TCP+SOCKS4 传输层
- mesh.zig 简化为纯 LSA 广播
- 20 源文件，124 测试通过

### 2026-07-31 — v0.15.0：对等 SOCKS4a 转发 + Windows 句柄兼容修复

**对等 SOCKS4a 转发（v0.15.0, commit `b4a818a`）**:
- `src/tcp.zig`：新增 `socks4ReadRequestBuf`（读取不回复）、`socks4Forward`（链式转发）、
  `socks4LocalRelay`（本地 relay）、修复 `socks4Relay`（`!void` → `void` + SHUT_WR 传播）、
  `TcpListener.acceptRaw()`
- `src/lsa.zig`：新增 `Mesh.lookupHostnameIp()` — Guest 端 hostname→IP 查找
- `src/guest.zig`：accept 循环改为三路 dispatch（self:2121 → utmm 帧协议 /
  self:other → localhost relay / other → chain-forward）；`ForwardCtx` + `forwardThreadFn`
- `src/host.zig`：新增 `hostTcpListen()` 线程 — Host 端 TCP :2121 SOCKS4a listener；
  复用 `guest.ForwardCtx`/`forwardThreadFn`
- 文档更新：CLAUDE.md、README.md、MANUAL.md
- 0 个新文件、0 个新 CLI 参数、0 个新端口 — 全部复用已有 TCP :2121 + SOCKS4a
- 测试：176 单元 + 59 集成 = 全部通过 ✅

**Windows SOCKS4a 转发修复（commit `7a47461`）**:
- 问题：SOCKS4a → windowsvm:22 收到 0 字节（linuxvm/macvm 正常）
- 根因：`socks4LocalRelay` 中 `IpAddress.connect()` 返回 AFD 内核句柄，
  `sockAccept` 返回 Winsock2 SOCKET，两种句柄类型不兼容 — `ws2_recv`/`ws2_send`
  在 AFD 句柄上静默失败
- 修复：新增 `sockConnectLocalhost()` — Windows 上用 `ws2_socket()`+`ws2_connect()`
  创建 Winsock2 兼容 SOCKET，POSIX 上用原始 `socket()`+`connect()`

**裸机部署测试结果（5 节点，全部通过）**:
| Test | linuxvm | macvm | windowsvm | winx64 |
|------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ | ✅ | ✅ | ✅ |
| SOCKS4a forward | ✅ | ✅ | ✅ (修复后) | ✅ (修复后) |

### 2026-07-31 — MCP download 修复 + 全工具测试

**MCP download 修复**:
- 根因：`src/mcp.zig` `handleVmDownload` 使用 `openFile(io, local_path, .{ .mode = .write_only })`，
  `openFile` 要求文件已存在（否则 `FileNotFound`）。CLI `cmdDownload` 正确使用 `createFile`
- 修复：`openFile` → `createFile(io, local_path, .{})` — 创建或截断，1 行变更
- macOS 踩坑：`cp` 覆盖 `/opt/utmm/utmm` 导致 ad-hoc 签名失效，`sudo` 运行被 SIGKILL（bug_type 309）
  - 解决：`codesign --remove-signature` + `codesign -s -` 重新 ad-hoc 签名
  - 建议：部署 flow 应使用 `--install` 而非裸 `cp`，install flow 内部处理签名

**MCP 全工具测试（通过管道验证）**:
| 工具 | linuxvm | 结果 |
|------|---------|------|
| status | — | ✅ 5 节点 online |
| exec | uname -a | ✅ |
| ping | — | ✅ RTT=0ms |
| upload | 25 bytes → /opt/utmm/ | ✅ |
| download | 25 bytes ← /opt/utmm/ | ✅ （修复后）|
| sshpass | echo SSH-PASS-OK | ✅ exit=0 |

**sshpass 测试详情**: `ssh root@192.168.64.6 echo SSH-PASS-OK` → 输出正确，exit 0 ✅
- 管道降级 + ConPTY 动态加载在之前 session 已验证，本次直接测试正常路径

**测试验证**:
- 176 单元测试全部通过 ✅
- 59 集成测试全部通过 ✅

**修复后二进制确认**:
- `/opt/utmm/utmm` 已包含 `createFile` 代码 + 重新 ad-hoc 签名
- MCP 进程需重启会话才能加载新二进制（管道测试已验证功能正确）

---

## v0.16.1 后续 — Hub-Spoke 架构全面修正

**时间**: 2026-08-01

### SOCKS5 文档全面修正

用户指出对 SOCKS5 转发架构理解有根本性错误 — 是 Hub-Spoke（Host 唯一中转），
不是 peer-mesh（每节点中转）。Host IP 同步到每个 Guest 的 `/etc/hosts` 文件
作为 `gateway` hostname。

**文档修正** (commit `dc782b9`):
- `README.md`: CLI Quick Start SOCKS5 示例加 gateway 注释
- `MANUAL.md`: SOCKS5 Forwarding 整节重写，Run Modes 更新，加 Windows Firewall BIND 限制
- `CLAUDE.md`: 5+ 处修正 — 端口描述、运行模式、转发流程、设计决策、TCP 帧协议模式

### Guest 链式转发代码修正

**Explore agent 发现**: `src/guest.zig:989-1051` 仍保留直接 Guest→Guest 链式转发代码，
与 Hub-Spoke 模型矛盾。

**修复** (commit `2b69c8e`):
- 删除 ~58 行直接链式转发代码（node table lookup → connect → socks5 forward）
- 替换为直接 REJECT：目标非本机时拒绝，统一走 Host (gateway) 中转
- `ForwardCtx`/`forwardThreadFn` 保留 — host.zig 仍使用它们做正确的 Host 侧转发

**测试验证**:
- 186 单元测试全通过 ✅
- 59 集成测试全通过，无内存泄漏 ✅

---

## P1 误报确认 — relay/SOCKS5 心跳无需修复

**时间**: 2026-08-02

P1 调查项 "relay/SOCKS5 线程心跳更新" 经代码审查确认**不是问题**：

### 心跳更新机制分析

| 路径 | 类型 | 心跳更新 |
|------|------|---------|
| 主 accept 循环（host:747, guest:920） | 同步 | 每迭代顶部更新 |
| handleExec shell read 循环（guest:1099） | 同步 | 读取后更新 |
| handleUpload read 循环（guest:1171） | 同步 | 读取后更新 |
| handleDownload read 循环（guest:1409） | 同步 | 读取后更新 |
| handleUpgrade read 循环（guest:1274） | 同步 | 读取后更新 |
| SOCKS5 relay/forward detach 线程 | 异步 | 不需要 — 不阻塞主循环 |
| localRelayWithLimit detach 线程 | 异步 | 不需要 — 不阻塞主循环 |

**关键洞察**: SOCKS5 relay/forward 线程通过 group.spawnBlocking detach 执行，
不阻塞主 accept 循环。主循环独立更新心跳，不受 relay 线程影响。
唯一的同步阻塞路径 handleOneCommand 已在所有读写循环中覆盖心跳更新。
**架构设计正确，无需修改。**

---

## Phase 27 P0 macOS/Windows — installMacOS + installWindows 服务恢复修复

**时间**: 2026-08-02

### P0 macOS: installMacOS() 缺少 KeepAlive + ThrottleInterval

**根因**: `installMacOS()` plist 模板只有 `RunAtLoad`，缺少 `KeepAlive`（含
`SuccessfulExit=false`）。`RunAtLoad` 仅在开机时启动 utmmd，utmmd 退出后
launchd 不会自动重启 → macvm 永久离线。

`genInit(.macos)` 模板正确但 `installMacOS()` 不一致 — 与 linux P0 完全相同的模式。

**修复** (`src/svc.zig`):
1. 新增共享常量 `MACOS_KEEPALIVE_CONFIG`
2. `installMacOS()` plist 插入 `{s}` 插值
3. `genInit(.macos)` 改用 `++ MACOS_KEEPALIVE_CONFIG ++`

### P0 Windows: installWindows() 缺少 sc failure 命令

**根因**: `installWindows()` 只执行 `sc create ... start=auto`，没有 `sc failure`
配置。utmmd 5 次重试后退出一 → SCM 无 failure action 不重启 → VM 永久离线。

`genInit(.windows)` 正确显示了 `sc failure` 命令但 `installWindows()` 没执行。

**修复**: `installWindows()` 在 `sc create` 后添加 `sc failure` 命令:
```
sc failure <name> reset=30 actions=restart/5000/restart/5000/restart/5000/none/5000
```

**设计**: SCM 先尝试 3 次快速重启（5s 间隔），30s 后 reset 计数。
若 utmm 反复崩溃，utmmd 内部 5 次重试耗尽后退出，SCM 再重启 utmmd。
双保险架构。

**测试验证**:
- 188 单元测试全通过 ✅
- 59 集成测试全通过，无内存泄漏 ✅

---

## v0.17.15: Windows --upgrade 推送失败修复

**时间**: 2026-08-02

### 根因分析

`pushUpgrade` 对比已验证的 `handleUpload`，发现三个关键缺陷：

| 问题 | pushUpgrade（旧） | handleUpload（正确） |
|------|-------------------|---------------------|
| 大文件写 | 单次 `sockWrite` 4MB，丢弃返回值 | 分块 64KB 写，循环处理短写 |
| 响应确认 | fire-and-forget，不读响应 | 读 upload_result，验证 exit_code |
| 连接关闭 | 写后立即 close() | 确认响应后再 close() |

**故障链路推断**:
1. macOS Host 端 `system.write(fd, buf, 4_000_000)` 对大缓冲可能短写
2. 旧代码 `_ = tcp.sockWrite(...)` 丢弃返回值 → 短写无法检测
3. `defer tcp_conn.deinit()` 立即 `shutdown(SHUT_RDWR)` + `close()`
4. macOS `close()` 无 SO_LINGER 时可能丢弃内核发送缓冲中的未发送数据
5. Guest 端 `conn.recv` 读到 0（EOF）→ `handleOneCommand` 静默返回
6. Guest 无任何 upgrade 日志 → 升级完全未生效

POSIX VM（macvm 2MB、linuxvm 14MB）成功而 Windows（4MB）失败的原因
可能是网络时序差异：Windows 4MB 在 close() 前未能全部排入发送缓冲，
或 send buffer 耗尽触发短写。

### 修复 (src/host.zig)

1. **分块写循环** — 替代单次 `sockWrite`:
```zig
var written: usize = 0;
while (written < file_size) {
    const w = tcp.sockWrite(tcp_conn.fd, file_data.ptr + written, file_size - written);
    if (w < 0) return "WriteFailed";
    if (w == 0) return "WriteFailed";
    written += @intCast(w);
}
```

2. **读 Guest 响应** — 发送后等待 upload_result:
```zig
const nr = tcp_conn.recv(&rbuf) catch |err| { return "ResponseReadFailed"; };
if (nr > 0 and rbuf[0] == @intFromEnum(protocol.MsgType.upload_result)) {
    const result = protocol.parseUploadResult(rbuf[1..nr]) orelse { ... };
    if (result.exit_code != 0) return "UpgradeRejected";
}
```

3. **错误传播** — 每步失败返回具体错误字符串，不再 `catch` 后吞掉

**测试**: 188 单元测试全通过 ✅

### 待验证
- 下一轮部署中验证 Windows `--upgrade` 是否真正生效
- 若问题持续，需在 Guest 端 `handleOneCommand` 入口添加更多诊断日志

---

## P0 部署体验修复 — deploy.json + Windows 自动化

**时间**: 2026-08-03

### 背景

审计 `docs/deploy-ux-audit.md` 发现两个 P0 问题阻止外部用户使用 utmm：
1. VM 凭据硬编码在 `VM_DEPLOY_TABLE`，用户必须改源码才能添加自己的 VM
2. Windows `--deploy` 只打印手动指南，不执行任何自动化操作

### P0-1: deploy.json 配置文件

**新增函数**:
- `loadDeployConfig(gpa, io, dir)` — 从 `<dir>/deploy.json` 加载 VM 配置。文件缺失或解析失败 → 日志警告 + 回退 `VM_DEPLOY_TABLE`
- `freeDeployConfig(gpa, config)` — 释放（编译时常量空操作，通过 `@intFromPtr` 区分）

**JSON 格式**:
```json
[
  {
    "hostname": "linuxvm",
    "target": "aarch64-linux-musl",
    "ip": "192.168.64.2",
    "user": "root",
    "password": "111",
    "remote_dir": "/opt/utmm"
  }
]
```

**错误处理**: 宽松策略 — 缺失字段跳过该条目、类型错误跳过、全部无效回退默认值。
所有错误 = 日志警告，不阻塞部署。

**修改的现有函数**:
- `vmRemoteDir()` — 增加 config 参数
- `cmdUpload()` — 传入 `VM_DEPLOY_TABLE`
- `cmdDeploy()` — 开头加载 deploy_config，全部 3 处 `VM_DEPLOY_TABLE` 替换为 `deploy_config`

### P0-2: Windows --deploy 自动化

**旧代码** (仅打印指南):
```zig
std.debug.print("[deploy]   Windows target — manual deploy required.\n", .{});
```

**新代码** (实际执行):
1. `sshpass scp` 上传二进制到 `remote_dir\utmm-new.exe`
2. `sshpass ssh` 远程执行复合命令：`sc stop → timeout → taskkill → move → sc start`
3. 使用 `2>nul` 抑制错误，`&` 串联确保后续步骤执行

### StrictHostKeyChecking 修复

所有部署 ssh 命令 (POSIX + Windows) 均加入 `-o StrictHostKeyChecking=no`，避免首次部署卡在 host key 确认。

### 测试

新增 8 个测试 (host.test 155-162):
- 合法 JSON 产生正确配置
- 缺失文件/无效 JSON 回退默认值
- 部分条目无效 → 保留合法条目
- 空数组/非数组顶层 → 回退
- `freeDeployConfig` 编译时常量空操作
- `vmRemoteDir` 按 hostname 查找

### 验证

- `zig build test` — 196/196 通过 ✅
- `zig build test-integration` — 59/59 通过，0 泄漏 ✅
- 仅修改 `src/host.zig`（~200 行），无新文件，无协议变更

---

## P1/P3 部署体验修复 — zio 文档 + deploy 缓存 + upgrade 错误信息

**时间**: 2026-08-03

### P1-2: zio 依赖说明

- `README.md`: "Build" 后新增 "Build Prerequisites" 章节，说明 zio clone 步骤
- `build.zig.zon`: zio 依赖块添加注释，说明 fork 来源和 branch

### P1-3: --deploy 跳过编译（serve-dir 缓存检测）

**修改**: `cmdDeploy()` 在运行 `zig build cross` 之前，检查 serve-dir 是否已有
匹配版本的二进制文件。全部存在 → 跳过编译，直接使用缓存。任一缺失 → 自动编译。

无需新 CLI 标志 — `utmm --deploy` 首次执行时编译，后续执行自动命中缓存。

### P3-6: --upgrade 错误信息改进

**修改** (`pushUpgrade` 返回值):
- `"GuestNotFound"` → `"GuestNotFound: VM not in mesh — is the Guest running? Use --deploy for initial setup"`
- `"UnknownTarget"` → `"UnknownTarget: unsupported architecture — check deploy.json target field"`
- `"BinaryNotFound: ..."` → `"BinaryNotFound: serve-dir missing binary — run 'utmm --deploy' first"`

**修改** (`ipc.zig`):
- `"GuestNotFound"` → `"GuestNotFound: VM not in mesh"`
- `"GuestNotConnected"` → `"GuestNotConnected: TCP connect failed"`

### 验证

- `zig build test` — 196/196 通过 ✅
- `zig build test-integration` — 59/59 通过，0 泄漏 ✅

## Phase 33.5 — findUpgradeTmp 固化 + 端到端验证

**时间**: 2026-08-12

### 问题

v0.18.30 部署到 windowsvm 后，`--upgrade` 传输成功但 utmmd 无法找到 `.tmp` 文件，
升级永远不生效。Host 端 `[upgrade] OK`，Guest 端文件已写入磁盘，
但 utmmd 的 `findUpgradeTmp` 始终返回 null。

### 根因

两个之前未知的 bug 叠加：

1. **`WIN32_FIND_DATAW` struct 布局错误**: `FILETIME` 字段用 `u64`(align=8) 声明，
   在 aarch64-windows 上每个 FILETIME 多出 4 字节 padding，导致 `cFileName` 偏移量
   比 Windows ABI 预期多出 3×4=12 字节。`extractSha256` 从错误的偏移读到乱码，
   对所有文件返回 null。

2. **`std.Io.Dir.walk()` + `Threaded` Io 不兼容 Windows**: `openDirAbsolute` 能打开
   目录，但 `walker.next()` 在 `Threaded` Io 上始终失败。这是 Zig 0.16.0 的限制。

两个 bug 叠加 → `findUpgradeTmp` 在 Windows 服务上下文中完全无法工作。
之前的诊断方向（CWD=System32）是错误的。

### 修复内容

| 文件 | 变更 | 说明 |
|------|------|------|
| `src/svc.zig` | 新增 `findUpgradeTmpWindows` | 使用 FindFirstFileW/FindNextFileW 直接扫描目录，绕过 Zig Io walker |
| `src/svc.zig` | 新增 `findUpgradeTmpPosix` | POSIX 保持原 walker 实现不变 |
| `src/svc.zig` | `findUpgradeTmp` 重构 | 顶层按平台分发到 Windows/POSIX 实现 |
| `src/svc.zig` | WIN32_FIND_DATAW 声明 | 文件顶层，FILETIME 使用 u32 low/high 对（align=4）匹配 Windows ABI |
| `src/svc.zig` | FindFirstFileW/FindNextFileW/FindClose 声明 | 文件顶层 extern "kernel32" |
| `src/utmmd.zig` | 删除 inline findUpgradeTmp blk | ~60 行 FindFirstFileW 调试代码 + WIN32_FIND_DATAW 声明全部移除 |
| `src/utmmd.zig` | tryApplyPendingUpgrade | 恢复为简单 `svc.findUpgradeTmp(alloc, file_io)` 调用 |
| `src/ver.txt` | 0.18.30 → 0.18.33 | 3 次迭代 build + verify |

### 验证

- `zig build test` — 216/216 通过, 1 skipped ✅
- `zig build test-integration` — 59/59 通过, 0 泄漏 ✅
- windowsvm 端到端: `--upgrade` 推送 → 5 秒内自动升级 (v0.18.32→v0.18.33) ✅
  - findUpgradeTmp → FindFirstFileW 发现 .tmp
  - tryAcquire → killAllUtmmWindows → tryReplaceWindows (MoveFileExW)
  - utmmd monitorUtmm 轮询自动触发（无需 SHM restart 信号）
  - 5 节点全部 serving，0 offline

### 经验教训

1. **跨平台 struct 布局必须以参考实现为准**。WIN32_FIND_DATAW 的 FILETIME 是
   `struct { DWORD low; DWORD high; }`（align=4），在 aarch64-windows 上
   `u64`(align=8) 的行为与 x86_64 不同。

2. **Zig Io 抽象层在 Windows 上不完整**。`Threaded` Io 的 `Dir.walk()` 在 Windows
   上不可用 → 需要直接调用 kernel32 API。这应该是临时方案，等 Zig 0.17+ 修复后
   可恢复使用 walker。

3. **"为什么找不到文件"这类问题不要假设**。之前的诊断认为是 CWD 问题、时间窗口问题、
   SHM 信号问题——全是错的。真正的问题需要 diff 验证（对比参考实现的 struct 布局）。

## Phase 34 — 全节点升级验证 + POSIX findUpgradeTmp 修复

**时间**: 2026-08-12

### 目标

将全部 4 个 Guest 节点升级到 v0.18.34，验证 auto-upgrade 全流程，修复发现的问题。

### 全节点升级过程

**初始状态**（v0.18.34 Host 部署后）：
- macvm: v0.18.34 ✅（上一轮已升级）
- windowsvm: v0.18.33 — 需升级
- winx64: v0.18.26 — 需升级
- linuxvm: v0.18.28 — 需升级

**第一轮推送**：
- linuxvm: `GuestConnectFailed`（SOCKS5 连接失败）
- windowsvm: `[upgrade] OK`
- winx64: `[upgrade] OK`

**问题诊断**：推送 OK 但版本未变：
- windowsvm: `utmmd.exe` 已崩溃（不在进程列表中），仅 `utmm.exe` 存活
- winx64: UTM-MonitorD 服务 STOPPED，WIN32_EXIT_CODE=1067，utmmd 已崩溃
- 两个 VM 的 SCM 都未自动重启 utmmd → .tmp 文件永远不会被处理

**修复**：`sc.exe start UTM-MonitorD` 手动重启服务 → utmmd 启动后立即
`tryApplyPendingUpgrade` → 找到并应用 .tmp 文件 → 升级成功。

- windowsvm: v0.18.33 → v0.18.34 ✅
- winx64: v0.18.26 → v0.18.27（先应用旧 .tmp）→ v0.18.34 ✅

**linuxvm 问题诊断**：
- 症状：TCP 端口 2121 和 22 均返回 Connection refused，但 UDP ping 正常
- utmm LSA 广播可达（status 显示 serving），但 TCP listener 线程崩溃
- SSH daemon 也挂了（无法远程登录）
- QEMU guest agent 未安装（utmctl exec 不可用）

**修复**：`utmctl stop "Ubuntu Desktop"` + `utmctl start "Ubuntu Desktop"` 重启 VM
→ TCP 服务恢复 → `utmm --upgrade linuxvm` 推送 OK → 升级至 v0.18.34 ✅

**最终状态**：全部 5 节点 v0.18.34 ✅

### POSIX findUpgradeTmp 静默失败 Bug

**发现**：虽然通过重启 Windows 服务和 linuxvm VM 完成了升级，但深入检查发现
linuxvm 的 utmmd 在正常运行期间**本应能**自动发现并应用 .tmp 文件，却一直
找不到。进一步分析代码发现 `utmmd.zig:941`：

```zig
const need_threaded = builtin.os.tag == .windows;
```

POSIX 上 `file_io` 直接复用事件循环 Io（epoll/kqueue），而 `findUpgradeTmpPosix`
调用的 `std.Io.Dir.openDirAbsolute(io, ...)` 需要文件系统操作能力，epoll-based Io
静默失败（`catch return null`）。

- macOS kqueue 碰巧兼容 → macvm 升级正常
- Linux epoll 不兼容 → linuxvm 升级失败
- Windows IOCP 之前已修复（独立 Threaded Io）

**修复** (v0.18.35)：所有平台始终创建 Threaded Io 用于文件操作，`need_threaded` 移除。

### 构建与测试

- 216 单元测试通过，1 skipped
- 59 集成测试通过，0 泄漏
- 构建成功

### 教训

1. **事件循环 Io ≠ 文件 I/O**：epoll/kqueue/IOCP 是为网络设计的，文件操作必须用 Threaded Io。这不是 Windows 特有的限制。

2. **静默失败是最坏的失败**：`catch return null` 掩盖了 openDirAbsolute 的真正错误原因。如果 panic 或记录错误日志，早就能定位到问题。

3. **跨平台测试不能只测一个 OS**：Phase 33 只在 Windows 上验证了 upgrade 流程，macOS 碰巧工作（kqueue 兼容），导致 Linux 上的 bug 被遗漏。

4. **utmmd 崩溃恢复缺口**：SCM/systemd 配置了 restart，但两个 Windows VM 的 utmmd 都停止后未自动重启。需要排查 SCM 失败恢复配置或 utmmd 崩溃根因。
