# Findings: v0.11.10

仅保留当前仍相关的重要发现。历史发现（WebSocket 时代、utmm-old、agent.zig 等）已随架构演进过时，不再收录。

---

## Zig 0.16.0 API 适配（Phase 48）

### Finding 62: `std.os.windows` 移除 SCM 类型

Zig 0.16.0 从 `std.os.windows` 移除了 `SERVICE_TABLE_ENTRYW`、`SetServiceStatus`、`RegisterServiceCtrlHandlerExW`、`StartServiceCtrlDispatcherW`。必须在 `src/svc.zig` 中手动声明 extern 类型和函数。

### Finding 63: `GetLastError()` 返回 enum

`std.os.windows.GetLastError()` 返回 `Win32Error` enum，非原始整数。需用 `@intFromEnum(gle)` 转换后比较和格式化。

### Finding 64: `std.c.strerror` 已移除

需通过 `@extern` 直接调用 libc:
```zig
const strerror = @extern(*const fn (c_int) callconv(.c) [*:0]const u8, .{ .name = "strerror" });
```

### Finding 65: `rename()` 签名变为 4 参数

`Dir.rename(old_path, new_dir, new_path, io)` — 目标目录和文件名分开传入。跨文件系统返回 `error.RenameAcrossMountPoints`。

### Finding 66: `++` 需 comptime-known

运行时字符串拼接需改为多个 `appendSlice` 调用。

### Finding 67: 自复制跨文件系统 rename 回退

`selfCopy()` 的 tmp→canonical rename 可能遇到 EXDEV（`/tmp` 和 `/opt/utmm` 不同文件系统）。回退方案是 copy+delete（非原子但可接受，服务已停止）。

---

## KCP 协议相关（Phase 46-47）

### Finding 55: `input()` seg.data 泄漏（Critical）

`ackPush`/`insertRcvBuf` OOM 时，`input()` 中已分配的 seg.data 泄漏。修复：errdefer 块 + seg.data = null 防 double-free。

### Finding 56: `send()` 非 stream OOM 部分片段残留（Critical）

非 stream 模式 send 在 OOM 后，部分片段已加入 snd_queue，导致接收端永久阻塞等完整消息。修复：errdefer 回滚 + catch 释放当前段数据。

### Finding 57: `input()` parseUna 不可回滚（High）

parseUna 先修改 snd_una，后续 OOM 无法恢复。设计限制文档化；keepalive 兜底。

### Finding 59: 时间戳算术溢出（Medium）

8 处 `+` 改为 `+%`（wrapping add），防止长时间运行后时间戳回绕导致逻辑错误。

### 模糊测试验证（Phase 47）

随机丢包/乱序/重复/损坏测试均通过，KCP 在极端网络条件下可恢复。

---

## Windows 相关

### Windows cmd.exe UTF-8 三层保障

`CreatePipe` + `CreateProcessW("cmd.exe /k")` 需三层 UTF-8 强制：SetConsoleCP(65001) + chcp 65001 + LANG 环境变量。

### Windows KCP 需阻塞接收 + 定时器线程

ARM64 Windows 上 `receiveTimeout` 路径静默丢失 KCP 数据。阻塞 receive + 独立 Win32 Sleep 定时器线程是唯一可靠方案。

### Windows .exe 文件锁定

服务运行时 .exe 被锁定，SCP 无法直接覆盖。部署流程：SCP 到临时文件 → 停服 → Move-Item -Force 覆盖。

---

## 设计决策记录

### ADR-1: 持久 pty per KCP 隧道连接

spawn 持久 shell（POSIX `posix_openpt` / Windows `CreatePipe`），命令间共享环境。`cd`/`export` 跨 exec 持久化。

### ADR-2: MDELIM 退出码标记

`; echo MDELIM:$?\n` 嵌入 pty 输出。Host 侧 `lastIndexOf` 处理命令回显（macOS/BSD pty master 不支持 ECHO disable）。`pty_exec_done` 消息提供显式退出码通道作为冗余。

### ADR-3: 自复制安装模型（Phase 48）

取消 utmm-old、agent.zig、软连接。固定路径 `/opt/utmm/utmm`（POSIX）/ `C:\opt\utmm\utmm.exe`（Windows）。安装 = 无条件强制覆盖。升级 = scp 新二进制 + `--install`。

### ADR-4: 文档合并（Phase 49）

DESIGN.md + release-skill/SKILL.md 合并到 CLAUDE.md，`utm-vm` 改名为 `utmm`。消除碎片化，单文件（CLAUDE.md）即可覆盖架构设计到发布流程。
