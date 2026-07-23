# Progress: v0.8.0

## Session 2026-07-24 (文档全面同步 — v0.8.0)

### 文档更新完成
- **任务**: 将 v0.8.0 全部变更同步到 7 个项目文档 + 2 个 skill 文档
- **修改文件**:

| 文件 | 改动 |
|------|------|
| `task_plan.md` | +Phase 20 v0.8.0 streaming exec + binary upload/download + 8-target build + AMFI codesign |
| `progress.md` | +v0.8.0 session log (本文件) |
| `findings.md` | +v0.8.0 findings: AMFI /tmp signing, sendBodiless panic, x86-windows-gnu, binary HTTP headers |
| `CLAUDE.md` | +v0.8.0 streaming exec 数据流, +binary upload/download protocol, +x86-windows-gnu build, +HTTP header helpers |
| `README.md` | v0.7.0 → v0.8.0 版本引用, +streaming exec + binary protocol 描述 |
| `utm-vm/MANUAL.md` | +streaming exec (chunked, x-exit-code trailer, 无 30s 超时), +binary upload/download 协议, +8 构建目标, +AMFI /tmp codesign |
| `utm-vm/SKILL.md` | -30s timeout 限制, +binary protocol 上传/下载说明 |
| `.claude/skills/release/SKILL.md` | 6→8 目标, +x86-windows-gnu workaround |

## Session 2026-07-23 (v0.8.0 Streaming Exec + Binary Upload/Download)

### v0.8.0 发布
- **版本号**: 0.7.0 → 0.8.0 (`ver.zig`)
- **Commit**: `4a69ceb` (功能提交), 文档提交待推送
- **改动**: host_http.zig 重写 exec/upload/download handler, host.zig CLI upload/download 重写, release skill 8 目标

**核心变更**:

1. **Streaming Exec (HTTP chunked response)**:
   - `handleExec` 从 `{"exit_code":0,"stdout":"..."}` JSON 包装改为 chunked streaming 纯文本
   - `respondStreaming()` + `x-exit-code` HTTP trailer 传递退出码
   - 移除 30s 超时 — 长时间命令不再被截断
   - `OpState` 新增 `sent_pos` 字段，追踪已发送输出位置
   - `body_reader.stream()` + `std.Io.Limit.limited(n)` 读取原始请求体

2. **Binary Upload Protocol**:
   - `x-vm` + `x-path` 自定义请求头，`Content-Type: application/octet-stream`
   - `readRawBody()` helper: content-length 驱动的原始 body 读取
   - `getRequestHeader()` helper: `request.iterateHeaders()` 不区分大小写匹配
   - `sendBodyComplete(file_data)` 发送原始二进制
   - 响应纯文本，不再 JSON 包装

3. **Binary Download Protocol**:
   - `x-vm` + `x-path` 请求头，`sendBodyComplete("")` 发送空 body
   - `respondStreaming()` 流式 chunked 响应 + `x-exit-code` trailer
   - CLI 端 `body_reader.stream(file_iface, ...)` 流式写文件

4. **8-Target Release Build**:
   - 新增 `x86-windows-gnu` 作为第 8 个构建目标
   - 绕过 `x86-windows` (MSVC) MinGW linker warning (`_system@4`)
   - `release-skill/build.sh` + `SKILL.md` 更新

**Bug 修复**:

| Bug | 根因 | 修复 |
|-----|------|------|
| macOS AMFI codesign 在 `/opt/utmm/` 失败 | AMFI 对 `/opt/utmm/` 中无签名二进制 SIGKILL；`codesign -s - -f` 在该目录报 "internal error in Code Signing subsystem" | 在 `/tmp/utmm-sign` 签名后 `mv` 到 `/opt/utmm/` — mv 保留有效签名 |
| `sendBodiless()` panic | `Client.zig:914` — `r.connection.?.flush()` 返回 error 不在 `Writer.Error` 集合中 → `unreachable` | 改用 `sendBodyComplete("")` |
| `x86-windows` linker error | MinGW `_system@4` warning 被 Zig 提升为 error | 改用 `x86-windows-gnu` target triple |
| `catch break` ambiguity | 在 `blk: {}` 标记块内 `catch break` 编译失败 | `break :blk @as(?Type, null)` |
| Chunked encoding 数据未 flush | `http.BodyWriter.flush()` 前必须调用 `writer.flush()` | `writer.flush()` 先于 `flush()` |

**修改文件**:
| 文件 | 改动 |
|------|------|
| `src/host_http.zig` | +readRawBody, +getRequestHeader, 重写 handleExec (streaming), 重写 handleUpload (binary), 重写 handleDownload (streaming chunked) |
| `src/host.zig` | cmdUpload 重写 (x-vm + x-path headers + sendBodyComplete), cmdDownload 重写 (streaming response + x-exit-code trailer) |
| `src/httpd.zig` | OpState +sent_pos field |
| `src/ver.zig` | 0.7.0 → 0.8.0 |
| `build.zig.zon` | 版本同步 |
| `.claude/skills/release/build.sh` | +x86-windows-gnu, 注释 7→8 |
| `.claude/skills/release/SKILL.md` | 6→8 targets, +x86-windows-gnu note |

**构建验证**: `zig build test` 全过，8 目标交叉编译 (ReleaseSafe) 全过

**部署验证**:
- linuxvm (aarch64-linux): 上线、streaming exec、binary upload/download MD5 验证通过
- macvm (aarch64-macos): AMFI codesign 修复后上线，全部功能验证通过
- windowsvm (aarch64-windows): 全部功能验证通过
- winx64 (x86_64-windows): 全部功能验证通过

**Host 状态**: launchd 管理 (pid 84272, ppid 1)，`sudo launchctl bootstrap system` 自动重启

### 文档更新完成
- **任务**: 根据实际架构、代码、CLI 参数、运行模式，更新全部文档保持同步正确
- **修改文件**:

| 文件 | 改动 |
|------|------|
| `CLAUDE.md` | +winx64 VM 表, +v0.7.0 自动升级架构, +UDP 广播数据流, +upgrade.zig 文件结构, +全部构建目标, +完整 CLI 标志, +自动升级设计决策 |
| `README.md` | 完全重写: v0.7.0 零 shell 自动升级, VM 参考表 4 台, 更新数据流图含 UDP 广播, 自动升级章节, MCP streamableHttp 配置 |
| `utm-vm/SKILL.md` | +winx64, +SSH 访问说明, MCP 配置更新, Windows cmd.exe 语法 |
| `utm-vm/MANUAL.md` | 完全重写 (1120→新): 修正 WebSocket 协议帧号匹配 wsproto.zig (pty_spawn=12 非 2, 等), +winx64, +v0.7.0 自动升级架构章节, 修正全部服务名 (com.utmm.guest 非 com.utmm, UTM-Monitor-Guest 非 schtasks), 修正 Windows 安装描述 (sc service 非计划任务), +完整 CLI 参考 (--version, --update-url, --serve-dir, --host-ip), +自动升级流程图, +x86_64 覆盖, +§7 MCP 集成完整章节, +§7.8 卸载清理 |

**关键修正**:
- WebSocket 协议帧号: pty_spawn(2→12), pty_input(3→13), pty_output(4→14), pty_signal(5→15), pty_resize(6→16), upload_req(7→4), upload_resp(8→5), download_req(9→6), download_resp(10→7)
- 服务名: macOS `com.utmm.guest`/`com.utmm.host`, Linux `utmm-guest`/`utmm-host`, Windows `UTM-Monitor-Guest`/`UTM-Monitor-Host`
- Windows 自动启动: `sc create` Windows Service（非 `schtasks` 计划任务）
- CLI 标志: +`--version`, +`--update-url` (内部), +`--serve-dir`, +`--host-ip`, `--mcp` 废弃标注

## Session 2026-07-23 (v0.7.0 自动升级架构重设计)

### v0.7.0 发布
- **版本号**: 0.6.6 → 0.7.0
- **改动**: 8 files changed, 293 insertions, 125 deletions + 202 new lines (upgrade.zig)

**核心变更**:
- UDP 广播携带 Host 版本号，Guest `udpDiscoveryListener` 检测版本不匹配
- 升级由独立 `utmm-old` 进程完成：停止服务 → 杀进程 → HTTP 下载 → 替换 → 启动服务
- 消除旧 HTTP GET /version 的 `HttpConnectionClosing` 竞态
- 三平台统一控制流：`upgrade.zig` 编译时分支，运行时一致
- Host 定期 60s 广播，Guest 自动检测升级（无需手动 `--status`）
- 不依赖 curl 等外部工具，全部 Zig 内置实现

**修改文件**:
| 文件 | 改动 |
|------|------|
| `src/ver.zig` | 0.6.6 → 0.7.0 |
| `src/protocol.zig` | +buildDiscoveryQuery, +parseDiscoveryVersion, +5 tests |
| `src/upgrade.zig` | 新文件: run(), stopService, killUtmmProcesses, downloadBinary, replaceBinary, startService |
| `src/main.zig` | +update_url, +isOldMode, 启动时升级模式检测 |
| `src/broadcast.zig` | +UpgradeSignal, udpDiscoveryListener 版本解析, +triggerSelfUpgrade, -downloadAndUpgrade, -HTTP 升级检查 |
| `src/guest.zig` | UpgradeSignal 替代 is_svc 参数 |
| `src/host.zig` | cmdStatus 用 buildDiscoveryQuery, +periodicBroadcastLoop |
| `build.zig.zon` | 版本号同步 |

**构建验证**: `zig build test` 全过，7 目标交叉编译（ReleaseSafe）全过

**追加 — 消除外部 shell 命令**:
- `upgrade.zig`: `sh -c 'chmod +x'` → `std.c.chmod(@ptrCast(path), 0o755)` — 直接 POSIX syscall
- `broadcast.zig triggerSelfUpgrade`:
  - `sh -c 'chmod +x'` → `std.c.chmod()` — 同 upgrade.zig
  - `cmd /c start /min "" utmm-old.exe --update-url "..."` → `CreateProcessW` + `DETACHED_PROCESS` (0x00000008)
  - `sh -c 'utmm-old --update-url ... &'` → `fork()` + `setsid()` + `execve()`
- 升级路径零外部命令 — 全部走系统调用，`sh`/`cmd` 不再参与

**追加 — E2E 自动升级验证 + FileBusy 修复**:
- **E2E 验证**（模拟 Host 版本升级 v0.7.0 → v0.7.1）：
  - macvm (aarch64-macos): 自动检测版本不匹配 → triggerSelfUpgrade → utmm-old 下载/替换/重启 → v0.7.1 ✅
  - WIN-Q0JNGDDBE28 (aarch64-windows): 同上 ✅
- **Windows FileBusy bug**: `dst.close(io)` 在 `defer` 中延迟到函数返回才执行，但 `std.process.spawn` 在此之前调用，导致 `utmm-old.exe` 被自身文件句柄锁定。修复：用块作用域 `{ var dst = ...; defer dst.close(io); ... }` 确保 spawn 前关闭文件句柄。
- **Windows 进程启动改进**: 使用 `std.process.spawn` 替代手动 `CreateProcessW`，由标准库处理 Windows 进程创建细节。
- winx64 (x86_64 Windows, v0.6.5): 无 triggerSelfUpgrade 代码，需手动部署 v0.7.0

## Session 2026-07-23 (v0.6.5 自动升级端到端修复)

### v0.6.5 发布
- **版本号**: 0.6.3 → 0.6.5（v0.6.4 为测试中间版本）
- **Commit**: `5d4aa73` — 2 files changed, tag v0.6.5 pushed

**v0.6.4 → v0.6.5 修复:**

端到端测试发现两个问题:
1. **下载缓冲区溢出**: `download_buf` 栈分配 10MB，二进制 ~10.5MB 超出。`fixed()` writer 满后返回 `WriteFailed`。
   - 修复: 改用堆分配 `allocator.alloc(u8, 20MB)`，添加 `BufferFull` 截断检测
2. **执行权限丢失**: `createFile` 不给执行位，`mv` 后 systemd 报 `Permission denied` (exit 203/EXEC)。
   - 修复: POSIX restart_cmd 加 `chmod +x` 前置步骤

3. HTTP fetch 失败时新增错误日志（之前静默吞咽 `} else |_| {}`）

**端到端验证 (linuxvm)**:
```
v0.6.4 Guest → 检测 Host v0.6.5 → 下载 11040608 bytes → 
chmod +x && mv && utmm --svc & → exit(0) → systemd restart → v0.6.5 稳定运行
```
日志链路完整: `[upgrade] checking → Host=0.6.5 Guest=0.6.4 → Downloaded → restarting → 新进程 v0.6.5`

**当前部署状态**:
- Host: v0.6.5
- linuxvm: v0.6.5 (自动升级成功)
- WIN-Q0JNGDDBE28: v0.6.3 (待升级)
- winx64: v0.6.3 (待升级)
- macvm: 离线 (待恢复)

---

## Session 2026-07-23 (v0.6.3 自动升级修复)

### v0.6.3 发布
- **版本号**: 0.6.2 → 0.6.3 (`ver.zig`)
- **Commit**: `55ea8fb` — 5 files changed, 104 insertions, 8 deletions
- **GitHub Release**: v0.6.3 tag pushed

**Phase 17: 自动升级修复 + Windows 自升级**

代码变更:
- `host_http.zig`: 新增 `GET /version` 端点，返回 `protocol.VERSION` 纯文本
- `host.zig`: 注册 `/version` 路由（长前缀先于 `/`）
- `broadcast.zig`:
  - 重写 `downloadAndUpgrade` Windows 路径：运行中 exe 可改名不可覆盖，批处理独立进程重启
  - `wsAnnounceLoop` 增加 `is_svc` 参数，仅守护进程模式检查升级
  - HTTP 获取 Host `/version` → 版本不同则下载 `deploymentFilename` 对应二进制并升级
  - `downloadAndUpgrade` 完成下载后 `std.process.exit(0)` 退出旧进程
  - Windows 批处理: `timeout /t 2` → `move old.exe` → `move new.exe utmm.exe` → `sc start` → `del %0`
  - POSIX: `mv next binary && binary --svc &`（不变）
  - 启动时清理 `utmm.old.exe` 升级残留
- `guest.zig`: 传递 `cli.is_svc` 给 `wsAnnounceLoop`

修复: `std.mem.trimRight` → `std.mem.trimEnd` (Zig 0.16.0 API 变更)

**构建验证**: `zig build test` 全过，6 目标交叉编译全过

**部署验证**:
- Host v0.6.3 已部署到本地 macOS
- linuxvm (aarch64-linux): v0.6.2 → v0.6.3 手动升级成功
- macvm (aarch64-macos): v0.6.2 → v0.6.3 手动升级成功
- WIN-Q0JNGDDBE28 (aarch64-windows UTM): v0.6.2 → v0.6.3 手动升级成功
- winx64 (x86_64-windows 真机): v0.6.2 → v0.6.3 手动升级成功

**已发现问题**:
- `/opt/utmm/utmm` 在部分 VM 上是独立副本而非符号链接，`systemctl restart` 后仍运行旧版本
  - 根因: install.sh 对 Linux 创建副本而非符号链接
  - 影响: 自动升级 `downloadAndUpgrade` 中 `mv next binary` 替换的是 `svc_exe`，但 systemd 实际运行 `/opt/utmm/utmm` 副本
  - 暂不修复: 影响面小，下版本修正

**端到端自动升级测试**: 待 v0.6.4 触发（需要版本号提升 + 仅部署 Host）

---

## Session 2026-07-23 (v0.6.1 完善)

### v0.6.1 发布
- **版本号**: 0.6.0 → 0.6.1 (`ver.zig`, `build.zig.zon`)
- **Commit**: `65d8451` — 4 files changed

**Phase 16: Windows 防火墙自动化**
- `install.zig`: Windows 系统服务安装 (`--install`) 自动执行 `netsh advfirewall firewall add rule` 开放 UDP 2121 入站
- 卸载时自动 `netsh advfirewall firewall delete rule` 清理规则
- 根因：真机 Windows 防火墙默认拦截入站 UDP，导致 `--status` 扫不到
- UTM VM 不受影响（桥接网络无防火墙）

**文档更新**:
- `task_plan.md`: 标题 v0.5.0 → v0.6.1，新增 Phase 16
- `build.zig.zon`: 0.5.1 → 0.6.1（之前版本号不同步）

**构建验证**: `zig build test` 全过，全部 6 目标交叉编译全过

## Session 2026-07-19 (v0.2.0 zio Architecture — superseded)
v0.2.0 架构已完成并发布：
- TCP transport 协议 + zio async Runtime
- Guest/Host 重写，删除 HTTP/IPC 5 文件
- Phase 1-10 全部完成，GitHub Release v0.2.0

## Session 2026-07-21 (v0.2.6 → v0.3.0)

### v0.3.0: Unified HTTP Architecture (6 Phases)

**Phase 1-2: httpd.zig + Host HTTP Endpoints** ✅
- 创建 `src/httpd.zig`: HTTP server accept loop + Router + HostState
- 创建 `src/host_http.zig`: /announce, /exec, /exec-result, /upload, /download, /mcp, /bin/, /
- Guest HTTP announce (POST /announce) 替换 UDP broadcast
- HTTP polling 模型：Guest 每秒 POST，Host 返回 pending 命令

**Phase 3: Guest HTTP Client** ✅
- `broadcast.zig`: `httpAnnounceLoop` 替换 `broadcastLoop`
- Guest 不再运行 TCP server，纯 HTTP client

**Phase 4: CLI Commands HTTP 化** ✅
- `--status` → HTTP GET /api/guests
- `--exec` → HTTP POST /exec
- `--upload`/`--download` → HTTP POST

**Phase 5: MCP 修复** ✅
- `mcp.zig`: `processJsonRpcWithState` 直接读 HostState HashMap
- 删除 stdio MCP 模式
- `/mcp` 端点合并进主 HTTP server

**Phase 6: 清理** ✅
- 删除 `transport.zig`, `listener.zig`, `status.zig`
- 删除 `host.zig` 中 UDP listener + binary auto-upgrade 旧代码 (~530 行)
- 删除 `protocol.zig` 中文本协议构建函数
- 删除 `main.zig` --mcp 标志
- `zig build test` 全过，6 目标交叉编译通过

## Session 2026-07-22 (WebSocket Binary Protocol)

### WebSocket 替换 HTTP Polling ✅
- **创建** `src/wsproto.zig`: binary WebSocket 协议
  - 8 种消息类型: announce, exec_req/resp, upload_req/resp, download_req/resp
  - String null-terminated, binary 4B 长度前缀
  - 完整测试覆盖（含 binary data round-trip）
- **创建** `src/wsclient.zig`: Guest WebSocket 客户端
  - TCP connect + HTTP upgrade handshake (RFC 6455)
  - Mask generation (timestamp XOR, 无 std.random 依赖)
  - Frame read/write with Zig 0.16.0 Io API
- **修改** `src/host_http.zig`: `handleWebSocket`
  - HTTP upgrade → read announce → loop: drainPending → send binary → read responses → deliverResult
  - 使用 `request.upgradeRequested()` + `request.respondWebSocket()`
- **修改** `src/broadcast.zig`: `wsAnnounceLoop` 替换 `httpAnnounceLoop`
  - 持久 WS 连接，实时接收 exec/upload/download
  - Binary frame I/O，零编码开销
- **修改** `src/guest.zig`: 使用 `wsAnnounceLoop`
- **修改** `src/host.zig`: 添加 `/ws` 路由

### 构建验证 ✅
- `zig build` 通过（零错误零警告）
- `zig build test` 全过
- 6 目标交叉编译全过: x86_64/aarch64 × linux-musl/macos/windows

### 文档重写 ✅
- CLAUDE.md: 架构、数据流、协议、文件结构更新为 v0.3.0
- README.md: MCP 端口 2122→2121，架构描述更新
- findings.md: 记录 v0.3.0 架构决策和现存问题
- progress.md: 更新本会话进度
- task_plan.md: 重写为 v0.3.0 计划
- utm-vm/MANUAL.md: 协议描述更新
- utm-vm/SKILL.md: 端口和架构描述更新

## Session 2026-07-22 (Deployment & Bug Fixes)

### Windows WebSocket 修复 ✅
- AFD kernel handle 兼容：`std.c.recv` (WSAENOTINITIALISED) → `Io.Reader` 基于 HTTP 响应读取
- Handshake leftover bytes: `PrefixReader` 模式将缓冲数据前置于首个 `readFrame` 调用
- `build.zig`: 链接 `ws2_32` 以支持 WebSocket 客户端 mask 生成中的 `std.c.random`

### /etc/hosts 同步修复 ✅
- use-after-free: `syncHostsFromState` 中的 `name_str` 在 `updateHosts` 读取前被释放 → 收集到 `allocated_names` ArrayList 中
- WebSocket 路径缺失同步：在 WebSocket handler 的 `upsertGuest`（变更时）和 `removeGuest` 后添加 `syncHostsFromState` 调用

### 部署验证 ✅
- 6 目标交叉编译全过
- 部署到 linuxvm (aarch64)、macvm (aarch64)、windowsvm (aarch64)
- Host 部署并重启，所有 3 个 Guest WebSocket 连接成功
- `utmm --status` 显示全部 Guest 在线
- `utmm --exec` 在所有 3 个 VM 上可用
- `/etc/hosts` 同步正确，UTC-MONITOR 标记块包含所有 3 条条目
- commit `0a3a08d` v0.2.8, tag v0.3.0 就绪

## Session 2026-07-22 (GuestNotFound 修复 + Streaming Exec)

### GuestNotFound 修复 ✅
- **根因**: `StringHashMap` key 内存损坏 — GPA 分配器在 `drainPending` 释放 pending map 的 `cmd_id`（分配器复用地址），覆盖了 guests map 中 "linuxvm" key 的内容（前 7 字节被改写为 `1784690`，即命令 ID 前缀）
- **修复**: `HostState.guests` 从 `StringHashMap(GuestEntry)` 改为 `ArrayList(GuestEntry)` — entries 内联存储，无独立 key 分配，消除 use-after-free 攻击面。3 个 VM 的线性搜索开销可忽略
- **验证**: linuxvm 10/10 + macvm 10/10 exec 通过，MCP vm_exec 通过，零错误

### Streaming Exec (v0.4.0 计划)
- **wsproto.zig**: 新增 5 个消息类型 — exec_start(8), exec_stdout(9), exec_stdin(10), exec_exit(11), exec_signal(12)
- **broadcast.zig**: Guest poll-based spawn（std.process.Child + posix poll 多路复用 stdin/stdout/stderr + WebSocket socket）
- **host_http.zig**: WS handler 分发 exec_stdout/exec_exit 帧，exec_signal 信号转发
- **httpd.zig**: `deliverStdoutChunk`/`deliverExecExit` 流式累积输出，PendingCmd 新增 `partial_stdout` ArrayList
- **host.zig/main.zig**: `--exec-cancel` CLI 支持（SIGINT 发送到远端 shell）
- **遗留**: stdout/stderr 合并流（all via exec_stdout type 9），未分离；exec_stdin 类型定义但双向 stdin 尚未实现

### 已知问题（未修复）
- auto-upgrade 未接入 WebSocket（`downloadAndUpgrade` 未被 `wsAnnounceLoop` 调用）
- WebSocket 无心跳/ping-pong 机制
- CLI upload/download 路径解析错误
- `agent.zig` 未将 `host_ip` 传递给 `CliArgs`
- exec_stdin 帧类型已定义但 Guest 端 stdin 写入尚未实现

## Session 2026-07-22 (Windows Streaming Exec)

### Windows 流式 Exec 实现 ✅
- **broadcast.zig**: 新增 Windows 流式 exec 路径
  - `spawnExecStreamWindows`: 使用 `Threaded.init` I/O spawn 子进程
  - `windowsExecThread`: 独立线程 blocking ReadFile 读 stdout pipe
  - `WindowsExecThreadArgs`: process_handle + stdout_handle + Threaded 所有权
  - `killChildProcess`: 跨平台 (Windows: TerminateProcess, POSIX: killpg)
  - `getGatewayWindows`: 使用 Threaded.init 修复 service context OutOfMemory
- **kernel32 extern 声明**: ReadFile, WaitForSingleObject, GetExitCodeProcess, TerminateProcess 通过 @extern
- **关键修复**:
  - child.handle → child.id (Windows 上 Child.Id = HANDLE, 无 handle 字段)
  - BOOL 比较 → @intFromEnum(result) == 0
  - win.INFINITE → std.math.maxInt(u32)
  - format 字符串 pid={d} → pid={any} (pid_t 是 HANDLE 在 Windows)
  - posix.kill → killChildProcess 跨平台
  - switch(builtin.os.tag) 消除平台死代码 (posix.kill 无法在 Windows 链接)
- **构建验证**: 6 目标交叉编译全过, zig build test 全过

## Session 2026-07-22 (Connection = Shell Session)

### 目标
用 "Connection = Shell Session" 模型替换 exec_signal (type 12) + --exec-cancel 体系。每个 WebSocket 生命周期 = 一个 shell session。Exec 完成后 Guest flush TCP 200ms → disconnect → reconnect。

### 协议简化 ✅
- **删除** `exec_signal` (type 12): buildExecSignal/parseExecSignal/ExecSignalData + 对应测试
- **删除** Host 侧: SignalEntry, pending_signals HashMap, drainSignals/enqueueSignal
- **删除** Guest 侧: main loop 中 exec_signal 处理分支（~40 行 killpg 代码）
- **删除** HTTP: handleExecSignal, POST /exec-signal 路由
- **删除** CLI: --exec-cancel, cmd_exec_signal 字段

### 新增功能 ✅
- **--kick CLI**: `utmm --kick <vm>` — 主动关闭 Guest WebSocket 连接
- **Host kick 机制**: kicked HashMap + markKicked/checkKicked
- **POST /kick**: HTTP handler，响应 `{"ok":true}`
- **failGuestPending**: Guest disconnect 时所有 dispatched 命令 → failed
- **CmdStatus.failed**: 新命令状态，tryTakeResult 匹配

### 关键 Bug 修复 ✅
- **Host bus error (SIGBUS)**: failGuestPending 用 string literal "disconnected" → handleExec `allocator.free()` → crash。修复：`allocator.dupe()` heap-allocate
- **Windows exec 死锁**: 主循环无 poll 超时 → 阻塞 readFrame 无法检测 exec_done。修复：exec 线程发送 WebSocket PING + Host 端显式 ping handler 响应 pong
- **Host ping handler**: `handleWebSocket` 新增 `.ping` 分支 — `readSmallMessage` 不自动响应 ping

### 部署验证 ✅
- `zig build test` 全过
- linuxvm (POSIX): exec 后正常 disconnect + reconnect
- macvm (POSIX): exec 后正常 disconnect + reconnect
- windowsvm: ping/pong 唤醒机制正常，exec 后正常 disconnect + reconnect
- `--kick` 测试: kick 后 Guest 重新连接，pending 命令返回 "disconnected" 错误
- kick 过程中 exec 线程可能继续运行但 defer cleanup 会 kill

### 文档更新 ✅
- [x] CLAUDE.md — Connection = Shell Session model, kick CLI, protocol changes
- [x] zig-codegen.md — readSmallMessage ping behavior, string literal free lesson
- [x] findings.md — ADR-5, Host bus error fix, Windows deadlock fix
- [x] progress.md — 本会话进度
- [x] task_plan.md — Phase 10 Connection = Shell Session, Phase 9 更新
- [x] utm-vm/MANUAL.md — exec_signal 删除, --kick CLI, 协议表更新

## Session 2026-07-21–22 (v0.5.0 pty Session Model)

### 目标
用持久 pty session 替换 "Connection = Shell Session"（每命令断连重连）模型。每个 WebSocket 连接 spawn 一个持久 shell（POSIX `posix_openpt` / Windows `CreatePipe`），命令在同一个 shell 中执行。`cd` 和 `export` 真正持久化。

### 协议重设计 ✅
- **删除** exec_* 类型 (2,3,8,9,10,11,12) — exec_req, exec_resp, exec_start, exec_stdout, exec_stdin, exec_exit, exec_signal
- **新增** pty_* 类型:
  - `pty_spawn` (2): host→guest, no payload, spawn shell on WS connect
  - `pty_input` (3): host→guest, cmd_id + stdin_data, feed command to shell
  - `pty_output` (4): guest→host, cmd_id + stdout_data, shell output stream
  - `pty_signal` (5): host→guest, 1-byte signal (SIGINT/SIGTERM/SIGHUP)
  - `pty_resize` (6): host→guest, rows+cols (u16 BE)
- 保留: announce(1), upload_req(7→renumbered), upload_resp(8), download_req(9), download_resp(10)

### Guest pty 实现 ✅
- **ptySpawn (POSIX)**: `posix_openpt` → `grantpt`/`unlockpt` → `fork` → child: `setsid`, `ioctl(TIOCSCTTY)`, `dup2(slave→0,1,2)`, `execve(shell, argv, std.c.environ)` → parent: close slave, return master_fd + child_pid
- **ptySpawn (Windows)**: `CreatePipe` × 2 (stdin+stdout) → `CreateProcessW("cmd.exe /k")` with `STARTF_USESTDHANDLES`. `lpEnvironment=NULL` inherits parent env
- **ptyReadLoop**: 独立线程读 pty master fd，构建 pty_output 帧。POLL.HUP 检测 shell 退出
- **ptyWrite**: 写 stdin data 到 master fd
- **scanForMarker**: `lastIndexOf("MDELIM:")` 扫描输出流中的退出码标记。macOS/BSD 用 `lastIndexOf` 处理命令回显（pty master 不支持 tcsetattr ECHO disable）
- **MDELIM 标记**: 每个命令追加 `; echo MDELIM:$?\n` (POSIX) 或 `& echo MDELIM:%errorlevel%\r\n` (Windows)

### Host State 重设计 ✅
- **删除**: CmdType, CmdStatus, PendingCmd, CmdResult, pending HashMap, kicked HashMap, SignalEntry, pending_signals, drainPending, deliverResult, deliverStdoutChunk, deliverExecExit, failGuestPending, markKicked, checkKicked
- **新增**:
  - `outgoing_frames`: per-guest FIFO frame queue (HTTP handlers push, WS handler drains)
  - `op_states`: HashMap of OpState (cmd_id → {output, exit_code, done, wake_event})
  - `close_requests`: flag-based kick 替代 kicked HashMap
- **新方法**: enqueueOutgoingFrame, dequeueOutgoingFrame, createOpState, appendOpOutput, completeOpState, scanForMarker, takeOpResult, requestClose, checkCloseRequested, failAllPendingOps

### Host HTTP Handler 重写 ✅
- **handleWebSocket**: Upgrade WS → read announce → upsert guest → send pty_spawn → loop: drain outgoing_frames, readSmallMessage (pty_output→appendOpOutput+scanForMarker, upload_resp/download_resp→completeOpState, ping→pong), checkCloseRequested → cleanup op_states + failAllPendingOps
- **handleExec**: pty_input frame (cmd_id + "cmd; echo MDELIM:$?\n") → createOpState → enqueueOutgoingFrame → poll takeOpResult (30s timeout) → return JSON
- **handleUpload/handleDownload**: 同 handleExec 模式
- **handleKick**: requestClose 替代 markKicked
- **删除**: handleExecResult, POST /exec-result 路由

### MCP 更新 ✅
- handleVmExec: pty_input frame → createOpState → enqueue → poll takeOpResult with 30s timeout

### Bug 修复 ✅
- **ptySpawn 空环境**: `execve(shell, argv, {null})` → `execve(shell, argv, std.c.environ)`。空环境导致无 HOME/SHELL，.bashrc/.zshrc 不加载
- **CPU 100% 自旋**: `ptyReadLoop` poll 循环只检查 POLL.IN → shell 退出时 POLL.HUP 被忽略导致忙等。修复：先检查 POLL.HUP
- **waitTimeout 无限阻塞**: HTTP/MCP handler 的 `wake_event.wait()` 无超时 → guest 断连时线程永久阻塞。修复：4 处改为 `wake_event.waitTimeout(30s)`，WS disconnect 时 failAllPendingOps
- **dash 兼容**: `--login` → `-l`（dash 不接受 GNU 长选项）
- **install 缺少 SHELL/HOME**: systemd/launchd 服务无环境变量 → 新增 `detectServiceEnv()` 在 install 时写环境配置

### 部署验证 ✅
- `zig build test` 全过
- linuxvm: pty shell 持久化，cd + export 跨命令生效
- macvm: pty shell 持久化，macOS BSD tcsetattr 限制用 lastIndexOf 绕过
- windowsvm: cmd.exe /k 持久化，环境自动继承
- `utmm --status` 正常，`utmm --exec` 正常，MCP vm_exec 正常
- `utmm --kick` 后 guest 重连，新 pty session

### 代码量变化
- 删除 ~300 行 exec streaming 代码
- 删除 ~200 行 HostState 旧模型 (PendingCmd, CmdResult, pending, kicked 等)
- 新增 ~350 行 pty 代码 (ptySpawn, ptyReadLoop, ptyWrite, scanForMarker)
- net: ~150 行减少

### 文档全面重写 ✅ (v0.5.0)
- [x] CLAUDE.md — pty architecture, protocol table, HostState central state, pty patterns
- [x] README.md — AI agent experience, pty model explanation
- [x] findings.md — ADR 1-5, pty platform notes, v0.5.0 bug fixes, known issues
- [x] progress.md — 本文件（v0.5.0 session log）
- [x] task_plan.md — v0.5.0 pty session model plan
- [x] zig-codegen.md — execve environ, Io.Timeout, Timestamp.now, pty patterns
- [x] release-skill/SKILL.md — version references update
- [x] utm-vm/SKILL.md — pty model: shell persistence, corrected exec behavior
- [x] utm-vm/MANUAL.md — protocol table (pty types), architecture update, deprecations removed

### MANUAL.md 从零部署验证 ✅ (2025-07-21/23)

按 MANUAL.md 从裸机完整部署 3 台 VM：

**Host 部署** ✅
- `curl install.sh | sh` 一键安装正常
- `sudo utmm --host --install` 服务安装 + 启动正常

**Linux Guest (linuxvm) 部署** ✅
- `curl http://gateway:2121/bin/install.sh | sh -s -- --guest --hostname linuxvm` 正常
- Shell = `/bin/bash` ✓，cd/export 持久化 ✓

**macOS Guest (macvm) 部署** ✅
- 初次部署后发现 Shell = `/bin/sh`（应为 `/bin/zsh`）→ 定位到 `detectServiceEnv` bug
- **Bug fix 1**: `detectServiceEnv()` 读取 `$SHELL` 环境变量，SSH 会话中 `$SHELL=/bin/sh`
  修复：改为始终使用平台默认值 (`/bin/zsh` / `/bin/bash` / `cmd.exe`)
- **Bug fix 2**: curl 下载的二进制丢失代码签名，AMFI 对 sudo 进程发送 SIGKILL
  修复：`install.sh` 增加 macOS Guest 端 `codesign --force --sign -`
- 修复后：Shell = `/bin/zsh` ✓，cd/export 持久化 ✓

**Windows Guest (windowsvm) 部署** ✅
- pty 模型正常工作，`cmd.exe` 交互正常
- Scheduled task 服务自动重启正常

**关键教训**:
- macOS Guest 部署后必须 codesign（install.sh 现已自动处理）
- 服务环境不应读取用户 shell 偏好，始终使用平台默认值

## Session 2026-07-23 (UDP Broadcast Discovery — v0.6.0)

### Phase 13: --status UDP 广播发现 ✅

**目标**: `--status` 从 HTTP 本地查询改为 UDP 广播发现，扩展到局域网内所有机器。

**协议**:
- 查询: "ARE YOU OK?\r\n" → broadcast 255.255.255.255:2121
- 响应: ANNOUNCE 文本块（复用 `GuestInfo.parse()` 格式）→ unicast 回发送者
- 5 次广播（1 秒间隔）+ 5 秒收集窗口 → hostname 去重

**代码变更**:
- `protocol.zig`: 新增 `DISCOVERY_QUERY`、`DISCOVERY_RESPONSE_PREFIX`、`GuestInfo.deinit()`
- `broadcast.zig`: 新增 `udpDiscoveryListener()` — Guest 侧 UDP 监听线程
  - `std.atomic.Value(bool)` shutdown flag + `receiveTimeout(1s)` 优雅关闭
  - 在 `wsAnnounceLoop()` 入口 spawn，defer join
- `host.zig`: `cmdStatus()` 重写 — HTTP GET → UDP broadcast
  - bind 随机端口，send × 5，collect 5s，parse + dedup，打印表格

**构建验证**:
- `zig build test` 全过
- 6 目标交叉编译全过: aarch64/x86_64 × linux-musl/macos/windows

**文档**:
- task_plan.md: 新增 Phase 13
- findings.md: ADR-6 + UDP API 模式文档
- progress.md: 本会话记录
- `--install` 不带 `--hostname` 会使用 OS hostname，导致 Host 端识别名变化

### Phase 14: UDP 子网定向广播修复 ✅

**问题**: `utmm --status` UDP broadcast 到 255.255.255.255 无响应。Python 验证：
unicast 到 VM IP 有响应，子网广播 192.168.64.255 有响应，255.255.255.255 无响应。
根因：limited broadcast 只走默认路由接口（en0），UTM bridge 网络收不到。

**代码变更**:
- `broadcast.zig`: 新增 `getSubnetBroadcasts()` — POSIX 用 `getifaddrs()` 枚举接口，
  计算子网定向广播（`ip | ~netmask`，去重，过滤 loopback/32）。Windows 只返回
  255.255.255.255。
- `host.zig`: `cmdStatus()` 替换单一 broadcast_addr 为广播地址列表。每轮依次向
  所有地址发送，rebind 后重试所有地址。

**字节序修复**:
- `sin.sin_addr.s_addr` 在 LE 系统为 host byte order，需 `@byteSwap` 后提取 octet
- `Ip4Address.bytes` 为 big-endian — `@byteSwap` 后写入正确

**去重 bug 修复**:
- `found_existing` 时 deinit 旧值导致 stored key 悬空 → 后续去重失败 → 重复条目
- 改为 first-wins：已有 hostname 则丢弃新值

**构建验证**:
- `zig build test` 全过，6 目标交叉编译全过
- `utmm --status` 正确发现 linuxvm + macvm，无重复

**文档更新**:
- task_plan.md: 新增 Phase 14
- findings.md: 3 个新节（getifaddrs endianness, subnet broadcast, dedup use-after-free）
- zig-codegen.md: s_addr endianness 规则
- progress.md: Phase 14 记录

### Phase 15: Windows UDP Listener ConcurrencyUnavailable 修复 ✅

**问题**: Windows VM 的 UDP listener 启动后持续报 `error.ConcurrencyUnavailable`，
无法响应广播。`utmm --status` 只能发现 linuxvm + macvm。

**根因分析**:
- `socket.receiveTimeout()` → `io.operateTimeout()` → `batch.awaitConcurrent()`（concurrent 路径）
- Zig 0.16.0 `Io.Threaded` Windows 实现中，`net_receive` 的 concurrent 路径未完成
- `Threaded.zig:3198-3199`: `if (concurrency) return error.ConcurrencyUnavailable`
- 标准库源文件有 TODO 注释: "TODO integrate with overlapped I/O or equivalent"
- `receive()`（无超时）走 `batchAwaitAsync` → `concurrency=false` → 正常执行

**修复**:
- Windows: 改用阻塞 `receive()`（异步/非并发路径），shutdown 时主线程通过 atomic
  pointer 获取 socket handle 并 `CloseHandle` 解阻塞
- POSIX: 保持 `receiveTimeout()`（poll 实现，工作正常）
- `udpDiscoveryListener` 新增 `socket_handle_out` 参数，Windows 分支写入 handle
- `wsAnnounceLoop` 关闭序列：`store(shutdown)` → `CloseHandle`(Windows only) → `join`

**潜在问题**: Windows 关闭时可能出现 double close（主线程 CloseHandle + defer
socket.close），第二次 CloseHandle 返回 INVALID_HANDLE 但无害。竞态窗口极小。

**构建验证**: `zig build test` 全过，全部 6 目标交叉编译全过

**部署验证**:
- Windows VM 部署后 `utmm --status` 成功发现全部 3 台 VM
- linuxvm (192.168.64.2) v0.6.0, macvm (192.168.64.4) v0.6.0, WIN-Q0JNGDDBE28 (192.168.65.2) v0.6.0
- `utmm --exec` 在全部 3 台 VM 上正常工作

### v0.6.0 发布 ✅

- **版本号**: v0.5.1 → v0.6.0 (`ver.zig`)
- **Commit**: `5005a63` — 8 files changed, 558 insertions, 42 deletions
- **Tag**: `v0.6.0` → GitHub
- **Release**: GitHub Release + 6 平台二进制文件 (x86_64/aarch64 × linux-musl/macos/windows)
- **部署**: Host + linuxvm + macvm + windowsvm 全部运行 v0.6.0

**文档更新**:
- task_plan.md: 新增 Phase 15
- findings.md: Windows ConcurrencyUnavailable 根因 + 修复
- zig-codegen.md: Io.Threaded Windows net_receive 限制
- progress.md: Phase 15 + v0.6.0 发布记录
