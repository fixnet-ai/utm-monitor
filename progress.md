# Progress: v0.12.2

## 当前状态

- **分支**: `main`
- **版本**: v0.12.2（唯一来源 `src/ver.txt`，`@embedFile` 编译期嵌入；`build.zig.zon` 永为 `0.0.0`）
- **测试**: 166/166 通过
- **部署**: macOS Host v0.12.2 ✅ | linuxvm v0.12.2 ✅ | macvm v0.12.2 ✅ | windowsvm v0.12.2 ✅ | winx64 v0.12.2 ✅
- **健康检查**: 4/4 Guest 在线，全部 v0.12.2，exec/ping 正常
- **跨平台编译**: 8/8 目标全部通过
- **MCP**: stdio 连接正常（`claude mcp add --scope user`），`vm_status`/`vm_exec`/`vm_ping` 验证通过

## Phase 79: MCP 连接修复 + 文档全面更新 ✅ (2026-07-28)

### 背景

用户报告 MCP 连接 `utm-monitor` 时报 `Failed to reconnect to utm-monitor: -32000` 错误。
问题有两层根因，需逐层排查修复。

### Task 402: 诊断 — 两层根因 ✅

**第一层 — 多行 JSON (Finding 163)**:
- `src/mcp.zig` 中 `SERVER_INFO` 和 `TOOLS_JSON` 使用 Zig `\\` 多行字符串
- 编译后字符串包含真实换行符 → MCP stdio 换行分隔 JSON 协议被破坏
- 修复后部署，用户反馈 "还是一样 `-32000`" — 说明这不是唯一根因

**第二层 — 旧 MCP 注册 (Finding 164)**:
- `claude mcp list` 显示 `node .../mcp_server.js - ✘ Failed`
- MCP 日志目录 `~/Library/Caches/claude-cli-nodejs/.../mcp-logs-utm-monitor/` 显示 `Cannot find module 'mcp_server.js'`
- 旧 `mcp_server.js`（Node.js 脚本）已删除，但 `~/.claude.json` 中的注册仍指向它
- `~/.claude.json` 优先级高于 `~/.claude/mcp.json`，手动编辑后者无效
- 修复: `claude mcp remove utm-monitor` → `claude mcp add utm-monitor -- sudo -n /opt/utmm/utmm --mcp`
- 用户确认: "成功了"

### Task 403: 修复 `src/mcp.zig` JSON 格式 ✅

**`src/mcp.zig:20-28`** (commit `a25f684`):
- `SERVER_INFO`: Zig `\\` 多行 → 单行 `\"` 转义 JSON
- `TOOLS_JSON`: 同上
- 确保每条 JSON-RPC 消息严格单行，兼容换行分隔传输协议

### Task 404-405: MCP 文档全面修订 + 作用域修正 ✅

**作用域问题 (Finding 165)**:
- 初版使用 `claude mcp add utm-monitor -- ...`（默认 `--scope local`，仅当前项目）
- 用户指出另一个 Claude Code 实例找不到此 MCP
- 修正: `claude mcp add --scope user utm-monitor -- sudo -n /opt/utmm/utmm --mcp`
- `--scope user` → `~/.claude.json` 用户级，所有项目可用

**文档变更** (commits `0bfd716`, `e29f874`):
- `mcp.json.example`: 全面修订 — 名称 `utmm`→`utm-monitor`、`--scope user`、故障排除表（`-32000`、旧注册、作用域说明）
- `README.md`: MCP 注册简化为 `claude mcp add --scope user` 一行命令
- `SKILL.md`: MCP 工具描述更新
- Memory: `mcp-http-server.md` 标记为 ABANDONED

### Task 406: 功能验证 ✅

**vm_status**: 5 节点全部在线 ✅
```
macvm (guest) aarch64-macos — v0.12.2 | status: serving
linuxvm (guest) aarch64-linux-musl — v0.12.2 | status: serving
windowsvm (guest) aarch64-windows — v0.12.2 | status: serving
winx64 (guest) x86_64-windows — v0.12.2 | status: serving
```

**vm_exec 持续输出命令**:
- `ping -c 4 127.0.0.1` on linuxvm → 成功
- `for i in 1 2 3 4 5; do echo "tick $i $(date)"; sleep 2; done` → 5 个 tick 跨越 10s 全部捕获
- `ping 127.0.0.1` (无 `-c`) → 110 个 icmp_seq 后超时退出 (exit -1)，输出完整

**vm_ping**: linuxvm RTT <1ms，正常

### 关键提交

```
e29f874 docs: use --scope user for cross-project MCP registration
0bfd716 docs: update MCP documentation — stdio transport, claude mcp add, troubleshooting
a25f684 fix: MCP stdio single-line JSON responses for newline-delimited transport
bded163 v0.12.2: bump version
```

### 背景

v0.12.1 发布后，用户报告所有 VM 的 KCP 隧道断开（Status 和 Ping 正常但 Exec 全挂）。排查过程发现两个连锁问题：

1. **Host 升级 v0.12.0→v0.12.1 时二进制被 SIGKILL** — 安装显示成功但 1 秒内 utmm+utmmd+plist 全部消失
2. **v0.11.23 Guest 跨版本自动升级不兼容** — 升级流程阻塞命令通道，所有 exec 返回 exit=-1

### v0.11.23 Guest 跨版本兼容问题

v0.11.23 Guest 的 `applyUpgradeAndRestart` 与 v0.12.0 的 utmmd shm 信令机制不兼容：
- **linuxvm**: 旧 utmmd (v0.11.23) 不调用 `waitpid` → 数百个僵尸进程泄漏 → 系统接近冻结
- **macvm**: 旧二进制顽固存活（ignore SIGTERM），kill 后 launchd throttle，走 startDirect 回退
- **winx64**: 旧 utmm.exe 被进程锁定，需上传到不同文件名再替换
- **Host 升级到 v0.12.1** 后出现重复 LSA 条目（新旧 hostname 同 MAC/IP）导致隧道 flapping

### Binary SIGKILL / 自毁排查

二进制 `/opt/utmm/utmm`（v0.12.1，SHA256 正确，Mach-O arm64，ad-hoc signed）运行 `--version` 立即 SIGKILL (exit 137)：
- `xattr`: 无 quarantine 属性
- launchd plist: 消失（连同二进制）
- 无 `/utmmd-shm`、无锁文件、无系统日志 kill 记录
- 旧 utmm 进程杀掉后仍 SIGKILL → 排除旧进程干扰

**关键发现**: 手动运行 utmmd 捕获到真实输出：
```
error: [host] No platform binaries found in serve-dir '/opt/utmm'
error: [host] Host version is 0.12.1 but no matching binaries exist.
[host] ERROR: Serve-dir version mismatch. Uninstalling service.
```
→ `svc.uninstall()` 删除了 `/opt/utmm/utmm` + `/opt/utmm/utmmd` + `/Library/LaunchDaemons/com.utmmd.plist`

### Bug 根因

1. `--install` 从 canonical path 执行时，`selfCopy` 检测到 src==dest → 跳过（正确）
2. `copySiblingBinariesToServeDir` 检测到 src==dest → 跳过，平台文件从未更新
3. Host 启动时 `verifyServeDirBinaries` 检查 `/opt/utmm/` 下是否有匹配 v0.12.1 的平台文件 → 找不到（只有 v0.12.0）→ 调用 `svc.uninstall()` → `exit(1)`

### Task 393: 代码修复 ✅

**`src/host.zig:776-783`** (commit `9716850`):
```
// 旧：
if (!verifyServeDirBinaries(block_io, sd)) {
    std.debug.print("[host] ERROR: Serve-dir version mismatch. Uninstalling service.\n", .{});
    svc.uninstall(block_io, gpa) catch {};
    std.process.exit(1);
}

// 新：
// 警告但继续运行 — 自毁比升级降级糟糕得多
_ = verifyServeDirBinaries(block_io, sd);
```

### Task 396-399: 全节点升级到 v0.12.1 ✅

所有 Guest 手动升级（SSH + `--install` 或 SCP 二进制 + reinstall）:
- **linuxvm**: kill 僵尸进程 → `--install` → pty 重建 → exec 恢复 ✅
- **winx64**: PowerShell `Stop-Process -Force` → `--install` → exec 恢复 ✅
- **macvm**: killAllUtmm 杀僵死 PID 23939 → `--install` → exec 恢复 ✅
- **windowsvm**: SCP `utmm-aarch64-windows-0.12.1.exe` → 替换 + `--install` → exec 恢复 ✅

### Task 400: serve-dir 平台文件 ✅

8 个 v0.12.1 平台二进制文件从 `zig-out/bin/` 复制到 `/opt/utmm/`，消除版本不匹配警告。

### Host 自注册 + 重复条目

- Host (`Dasis-MacBook-Air.local`) 自注册到 guest table — 显示在 `--status` 中
- windowsvm 存在重复条目：`WIN-Q0JNGDDBE28` (v0.12.0, 旧 COMPUTERNAME) + `windowsvm` (v0.12.1, 新 hostname) — 旧条目将随时间过期

## Phase 77: 安装脚本测试 + Bug 修复 ✅ (2026-07-28)

### 背景

v0.12.0 发布后，需验证 `install.sh`（macOS Host）和 `install.bat`（Windows Guest）从 GitHub Release 安装的完整流程。

### Task 386: install.sh macOS Host 测试 ✅

从 GitHub 安装脚本一键安装 macOS Host（通过代理 127.0.0.1:7890）：
- curl 代理下载脚本 → 交互输入（hostname + Host 模式）
- 下载 utmm.zip (19MB) → 解压 11 文件 → 文件放置
- utmmd 注入 + com.utmmd launchd 注册 → 服务启动
- `--status` 确认：Host v0.12.0 + 4 Guest 全部在线
- 成功！macOS Host 从 GitHub 一键安装完全流畅

### Task 387: install.bat Windows Guest 测试 ✅

通过 SSH 到 windowsvm (aarch64-windows) 测试 install.bat 离线模式。发现 2 个阻断 bug：

**Bug 1 (Finding 158)**: `del install.bat` 在 `--install` 命令之前执行
- 症状："The batch file cannot be found." → 安装从未执行
- 根因：Guest 模式 cleanup 阶段（第 302 行）删除自身，之后 cmd 无法读取后续行
- 与 bash 区别：bash 将脚本读入内存，删除自身可继续执行；cmd 逐行读取

**Bug 2 (Finding 159)**: install.bat LF 换行导致标签解析失败
- 症状："The system cannot find the batch label specified - resolve_binary"
- 根因：文件使用 LF 而非 CRLF，`call :label` 无法找到标签
- ZIP_BINARY 为空 → Guest cleanup 删除所有平台二进制 → 全面崩溃

### Task 388-390: Bug 修复 ✅

**`install.bat`** (commit `f1bfac3`):
- 将 `del /q install.sh install.bat` 从第 302 行（file placement cleanup）移到第 338 行（安装成功后 Guest done 消息后）
- `git add --renormalize` 强制 CRLF 行尾（.gitattributes 已配置但未生效）

**`install.sh`** (同一 commit):
- 将 `rm -f install.sh install.bat` 从第 267 行移到第 298 行，保持一致性

### Task 391: windowsvm 全流程验证 ✅

修复后完整验证：
- 清理 + 上传 + 解压 + install.bat → utmmd.exe 注入 (797KB) ✅
- UTM-MonitorD 服务注册 ✅ + 启动 ✅
- Guest 注册到 Host mesh（WIN-Q0JNGDDBE28 v0.12.0）✅
- `sc query UTM-MonitorD` → STATE: 4 RUNNING ✅

### 附带发现

**v0.11.23 → v0.12.0 跨版本自动升级兼容问题**:
- `linuxvm` + `macvm`: KCP 下载完成但 Guest 端升级未完成。macvm 恢复 serving 保持 v0.11.23
- `windowsvm` + `winx64`: 未发起升级请求
- 可能原因：v0.11.23 的 `applyUpgradeAndRestart` 与 v0.12.0 utmmd shm 信令不兼容
- windowsvm 通过 SSH 手动升级到 v0.12.0 成功

## Phase 76: macOS launchctl 遗留修复 + 文档更新 ✅ (2026-07-28)

### 背景

Phase 75 utmmd 引入后，macOS launchd 与 utmmd 的交互暴露出两个遗留问题：
1. `launchctl enable` 在 bootout 后返回 exit 64
2. `bootstrap` 间歇失败（exit 5: "Input/output error"）

同时，CLAUDE.md、README.md、MANUAL.md 等多个文档包含过时的 HTTP 协议描述、
旧安装流程（无 utmmd）、旧升级流程（无 shm）等误导信息，需要全面更新。

### Task 382: 诊断 launchctl bootstrap 失败 ✅

**发现**:
- `enable exit 64`：`enable system/<name>` 在 bootout 后调用时 service label 已不存在于 launchd 中，返回 EX_USAGE。首次安装同理。无害 — 仅表示无 disabled flag 需清除。
- `bootstrap exit 5`：根因是 **launchd throttle**（反滥用保护），非代码 bug。同一 label 短时间反复 bootout/bootstrap 超过阈值后，launchd 拒绝加载返回 EIO。持续 5-10 分钟自动解除。**新鲜 labels（如 `com.test-throttle`）工作完美**。
- `launchctl load` 回退的陷阱：load 同样失败但**返回 exit 0**（仅打印错误到 stderr），`runCmd` 误判成功。这是原有代码使用 load 作为回退的致命缺陷。
- `bootstrap` exit 0 但服务未在 list 中：launchd 内部队列处理时序，或 throttle 静默拒绝。必须验证 `launchctl list` 输出。

### Task 383: 修复 macOS launchctl 两个遗留问题 ✅

**`src/svc.zig` — installMacOS() 重排序**:
- `enable → bootout → bootstrap`：enable 必须在 bootout 之前（需要 service label 存在于 launchd 才能清 disabled flag）
- bootstrap 改为 best-effort（`_ = runCmd(...)`），不验证结果。真正的启动交给 `start()`
- 移除 verify 步骤（`fail.msg` 检查 launchctl list）—— throttle 期间会导致整个 install 失败

**`src/svc.zig` — start() macOS 路径完全重写**:
```
kickstart -k → 成功 → 验证 launchctl list → done
            → 失败 → enable → bootout → bootstrap × 3（每次 500ms 后验证 list）
                                                                    → 成功 → done
                                                                    → 全部失败 → startDirect
```
- 移除 legacy `launchctl load` 回退（exit 0 误导性，实际未启动）
- 新增 `launched_via_launchd` 标志：startDirect 场景跳过 launchctl list 验证
- startDirect 直接后台运行 utmmd（不传 `--hostname`，用系统 hostname）

**`src/shm.zig` — createPosix 重试**:
- 首次 shm_open 失败 → 2s 后重试（launchd bootstrap 环境中可能瞬时失败）

### Task 384: macvm 部署验证 ✅

在 throttle 激活的 macvm 上验证 fallback 路径：
- `bootstrap` 3 次全部失败（throttle 中）→ `startDirect` 启动 utmmd
- utmmd 正常 spawn utmm → utmm 连接 mesh → Guest 出现在 `--status` 中
- 正常路径（无 throttle）验证：`bootstrap` 首次成功，服务正常运行

### Task 385: 更新所有过时文件 ✅

**CLAUDE.md** (10 处编辑):
- Project Overview: HTTP chunked → IPC socket 流式传输
- 新增 utmmd supervisor 条目
- Two Run Modes: 增加 utmmd 管理层描述
- Data Flow 图: 新增 `utmmd ──shm── utmm` 层
- Command/Upload/Download Flow: 移除 HTTP 引用，更新为 IPC 二进制协议
- HostState: `serve_dir` 描述更新
- Auto-upgrade/Self-Copy/Runtime: 全部更新到 utmmd 架构
- Post-release: 升级流程更新

**README.md** (4 处编辑):
- 流式 exec: 移除 `x-exit-code` trailer 引用
- 自复制安装: 描述 utmmd supervisor 提取
- 自动升级: 更新到 utmmd shm 信号协调
- Data flow 图: 简化内部细节

**MANUAL.md** (4 处编辑):
- 版本号: `0.11.16` → `0.11.23`
- 架构: `dual mode` → `dual mode + utmmd supervisor`
- 自复制安装: 路径更新（utmmd 作为服务）
- 自动升级: v0.12.0 + utmmd 步骤

**SKILL.md**: 已在 Phase 76 早期新增 macOS launchctl 注意事项（line 116-150）

**Memory 文件**:
- `listener-version-update-bug.md` — 删除（listener.zig 已不存在）
- `install-symlink-resolution-bug.md` — 标记为 resolved（utmmd canonicalSvcPath 直接返回硬件路径）
- `mcp-http-server.md` — 标记为 PLAN（未实现，当前 MCP 仍为 stdio）
- `MEMORY.md` 索引 — 同步更新

## Task 377: 逐 VM 部署测试 ✅ (2026-07-28)

### 背景

完成 Task 376 安装优化后，构建完整新版本，逐个 VM 部署 Guest 验证。
用户要求：不启动本机 Host，先逐个 VM 部署 Guest，记录每个不流畅环节，bug 立即修复。

### 部署结果

| VM | 平台 | IP | utmmd | utmm | UDP :2121 | 状态 |
|----|------|-----|-------|------|-----------|------|
| macvm | aarch64-macos | 192.168.64.4 | 21963 | 21967 | ✅ | ✅ 正常运行 |
| linuxvm | aarch64-linux-musl | 192.168.64.2 | 116629 | 116630 | ✅ | ✅ 正常运行 |
| windowsvm | aarch64-windows | 192.168.65.2 | 1560 | 5060 | ✅ | ✅ 正常运行 |
| winx64 | x86_64-windows | 192.168.3.108 | 20104 | 39516 | ✅ | ✅ 正常运行 |

### 部署过程中发现并修复的 Bug

| # | Bug | 症状 | 根因 | 修复 |
|---|-----|------|------|------|
| 4 | Double free in startUtmmPosix | DebugAllocator 检测到双重释放 | `svc_arg` 在 argv 循环中已释放，又单独 `alloc.free(svc_arg)` | 移除重复的 `alloc.free(svc_arg)` |
| 5 | execve argv 缺少 NULL 终止符 | utmm 被 utmmd spawn 后静默崩溃 | `execve` 要求 argv 数组以 NULL 指针终止，但 ArrayList 未追加 | 改用 `allocSentinel(?[*:0]const u8, n, null)` 确保 NULL 终止 |
| 6 | buildServiceArgs 内存泄漏 | `--install` 时 DebugAllocator 报告 leaked memory | 各字符串 `alloc.dupe` 后从未释放，仅释放 ArrayList buffer | 在 3 处 defer 中先释放 items 再 deinit |
| 7 | shm.zig: WINAPI 已移除 | aarch64-windows 交叉编译失败 | Zig 0.16.0 `std.os.windows.WINAPI` 不存在 | 改为 `std.builtin.CallingConvention = .winapi` |
| 8 | shm.zig: 指针类型不匹配 | `&name_utf16` 无法转为 `?[*:0]const u16` | 单指针→多指针+可选+哨兵类型链需要显式转换 | `@ptrCast(&name_utf16)` |
| 9 | shm.zig: @memset 不接受单指针 | `@memset(*ShmLayout, 0)` 编译失败 | Zig 0.16.0 `@memset` 要求切片或多指针 | 改为 `@as([*]u8, ...)[0..size]` |
| 10 | shm.zig: volatile 指针不能传给 UnmapViewOfFile | 类型不匹配 | `*volatile ShmLayout` vs `?*const anyopaque` | 链式 `@ptrCast(@constCast(@volatileCast(...)))` |
| 11 | utmmd.zig: PROCESS_INFORMATION 已移除 | Windows 交叉编译失败 | Zig 0.16.0 移除此结构体 | 手动声明 extern struct |
| 12 | utmmd.zig: CreateProcessW 已移除 | 同上 | Zig 0.16.0 移除此函数 | 声明 `extern "kernel32" fn CreateProcessA`（UTF-8 路径） |
| 13 | utmmd.zig: FALSE 已移除 | 同上 | Zig 0.16.0 BOOL 改为 enum，FALSE 常量不存在 | 改用 `i32` 类型 + `0` 值 |
| 14 | utmmd.zig: TerminateProcess / WaitForSingleObject 已移除 | 同上 | Zig 0.16.0 移除此函数 | 手动声明 extern "kernel32" |
| 15 | utmmd.zig: WAIT_TIMEOUT 已移除 | 同上 | Zig 0.16.0 移除常量 | 手动声明 `const WAIT_TIMEOUT: u32 = 0x00000102` |
| 16 | shm.zig: OpenFileMappingW 调用 windows.FALSE | 同上 | 同上 | 声明改为 `i32`，调用处改为 `0` |

### 流畅环节

- **linuxvm 部署**：一次成功，系统日志清晰（journalctl 输出完整），无任何异常
- **macvm 部署（修复后）**：utmmd+utmm 稳定运行，UDP 2121 监听正常，shm 连接正确
- **windowsvm 部署**：SCP 上传+安装+验证全部流畅，Windows 服务管理正常
- **winx64 部署**：同上，x86_64 target 交叉编译+运行完全正常

### 不流畅环节（后续优化点）

1. **Debug 构建体积大** — macOS 18MB、Linux 18MB，应使用 ReleaseSafe 构建做部署测试
2. **Windows SCP 路径** — C:\tmp 需预先 mkdir，路径格式 `C:/tmp/file.exe` 不直观
3. **macOS launchctl bootstrap 不稳定** — UTM VM 中 SIP 限制，需三重回退（kickstart → legacy load → startDirect）
4. **跨平台构建逐 target 编译** — 7 个连续 Zig 0.16.0 API 修复，每次修复后重编译，流程可并行化
5. **utmmd 日志未落地** — macOS 上 utmmd 的 stdout/err 未出现在 `/var/log/utmmd.log`，仅 journalctl 有
6. **--install 过程中 DebugAllocator 检查** — 发布构建应使用 ReleaseSafe 避免泄漏误报

### 与 Task 362 关系

Task 362（Host + 全部 VM 部署验证）需要 Host 运行才能执行 `--verify`。
本任务完成了 Guest 部署部分，Host 部署留待后续。

## Phase 75: utmmd 监督进程架构重构 ✅ (2026-07-28 已完成)

### 背景

Phase 72-74 修复了自动升级的具体 bug，但根本架构问题（系统保活与自升级启动权冲突）未解决。
Phase 75 引入 utmmd 监督进程，将生命周期管理从系统服务管理器中完全剥离。

### 决议

| R1 | utmmd 不需要系统保活 | R2 | IPC 用共享内存 | R3 | 检测到升级立即执行 |
| R4 | 服务名称简化为 "utmmd" | R5 | 命名 `utmmd` | R6 | 不考虑向后兼容 |

### 任务状态

| # | 任务 | 状态 |
|---|------|------|
| 355 | 创建 `src/shm.zig` — 跨平台共享内存协议 | ✅ |
| 356 | 创建 `src/utmmd.zig` — 监督进程完整实现 | ✅ |
| 357 | 修改 `src/svc.zig` — 简化为纯 OS 服务管理 | ✅ |
| 358 | 修改 `src/main.zig` — shm 连接 + 新 install/uninstall | ✅ |
| 359 | 修改 `src/broadcast.zig` — shm 驱动升级流程 | ✅ |
| 360 | 修改 `build.zig` — 两步构建 + utmmd 嵌入 | ✅ |
| 361 | 编译 + 测试 — 166/166 通过 | ✅ |
| 362 | 部署验证 — Host + linuxvm + macvm | 📋 待部署 |

### 实现详情

**shm.zig** (~400行, Task 355):
- `ShmLayout`: 4096 字节 extern struct（magic, version, svc_state, utmm_state, utmm_pid, svc_pid, svc_heartbeat, utmm_heartbeat, cmd, cmd_status, restart_count, last_exit_code, backoff_sec, failure_count, cmd_data[1024], _reserved[3008]）
- `create(io)` / `open()` / `destroy(shm)` / `detach(shm)` / `nowMs(io)` 公共 API
- POSIX: 原始 `extern "c" fn shm_open/mmap/munmap/shm_unlink` + 原始常量（O_CREAT, PROT_READ, MAP_SHARED 等）
- Windows: `CreateFileMappingW` / `OpenFileMappingW` / `MapViewOfFile` / `UnmapViewOfFile`
- 10 测试（size=4096, 默认值, enum 值验证）

**utmmd.zig** (~600行, Task 356):
- `parseArgs()` — `--role guest|host` + `--svc` 解析
- `monitorLoop(io, alloc, shm, role)` — 主循环：startUtmm → stabilityCheck(10s) → monitorUtmm
- `startUtmm()` — fork+exec (POSIX) / CreateProcessW (Windows) 启动 utmm --svc
- `stabilityCheck(10s)` — 每秒检查 shm 心跳，10s 稳定算启动成功
- `monitorUtmm()` — 每 1s 检查心跳（10s 超时触发重启）+ 处理 shm 命令（UPGRADE/RESTART/SHUTDOWN）
- `upgradeUtmm()` — 重命名临时文件 → 规范路径，macOS codesign 重签，失败回退
- `winServiceRun()` — Windows SCM 分发，SERVICE_CONTROL_STOP 处理
- 退避算法：1s→2s→4s→8s→16s→32s→超过5次退出

**svc.zig** (重构, Task 357):
- 服务名统一：SVC_NAME_MACOS=`com.utmmd`, SVC_NAME_LINUX=`utmmd`, SVC_NAME_WINDOWS=`UTM-MonitorD`
- `svcName()` 无参数（Guest/Host 互斥，单名称）
- 新增 `canonicalSvcPath()` — `/opt/utmm/utmmd` 或 `C:\opt\utmm\utmmd.exe`
- macOS plist: 移除 `KeepAlive` dict + `ThrottleInterval`
- Linux systemd: 移除 `Restart=on-failure` + `RestartSec=5` + `StartLimitBurst=3`
- Windows: 移除 `sc failure` 配置
- 移除 SCM 集成（SvcGlobals, svcMain, svcCtrlHandler）→ 移入 utmmd.zig
- 存根函数在 Task 373 完成后清理
- `getOwnPid()` → `pub`（供 main.zig 使用）

**main.zig** (修改, Task 358):
- 新增 `@embedFile("embed/utmmd.bin")` + `extractUtmmd()` + `extractUtmmdIfMissing()`
- `--install`: 调用 extractUtmmd 强制提取，然后 svc.forceInstall
- `ensure`: 调用 extractUtmmdIfMissing（仅缺失时提取）
- `--svc`: 打开 shm → 设置 PID/状态 → 心跳线程(1s) → 运行主循环 → 清理（设置 stopping 状态 + detach）
- 新增 `heartbeatThread()` — 每秒更新 shm.utmm_heartbeat
- 新增 `copyFile()` — 用于 extractUtmmd 的 EXDEV 回退路径

**broadcast.zig** (修改, Task 359):
- `doAutoUpgrade` 签名改为返回 `!bool`（是否成功通知 utmmd）
- 下载后写 shm（cmd=UPGRADE, cmd_data=临时路径）替代执行 `--install`
- 调用方（meshSessionLoop）检查返回值：成功 → break 退出；失败 → 恢复 serving 状态继续
- 移除 `applyUpgradeAndRestart` 函数（~48 行）
- 移除 `svc.resetRetryCounter` 和 `svc.checkPendingUpgradeWindows` 调用

**host.zig** (清理, Task 359):
- 移除 `svc.resetRetryCounter` 调用

**build.zig** (修改, Task 360):
- 新增 utmmd 编译步骤 + `addSystemCommand("cp -f")` 复制到 `src/embed/utmmd.bin`
- utmm 构建步骤依赖 copy 步骤
- `src/embed/` 加入 .gitignore

### 验证

- `zig build`: 编译成功（utmmd + utmm 两步构建）
- `zig build test`: 166/166 全部通过
- macOS aarch64 原生构建验证通过

## Task 376: 安装优化 — hash 比对 + config 持久化 + 3b 仅重启路径 ✅ (2026-07-28)

### 背景

完成 Phase 75 核心实现后，识别出安装流程可进一步优化：每次 `ensure` 都走完整 forceInstall
（stop→kill→selfCopy→installService→start），即使 utmmd 未变化。引入 hash 比对和 3b 路径跳过
不必要的重装步骤。

### 变更摘要

**build.zig**:
- 新增 `hash_utmmd` 构建步骤：`shasum -a 256 utmmd.bin → src/embed/utmmd.sha256`
- utmm 编译依赖 hash 步骤（替代直接依赖 copy 步骤）
- 避免 comptime SHA256（2MB 二进制需要 >20M eval branch quota）

**`src/main.zig`**:
- `utmmd_sha256_hex`: `@embedFile("embed/utmmd.sha256")` — 构建期预计算，64 字符 hex
- `--install`: forceInstall 后调用 `svc.saveUtmmdMeta()` 持久化 hash + args
- Host ensure: 新增 `shouldUpdateUtmmd` 分支
  - 3a 路径: utmmd 需更新 → extractUtmmd + forceInstall + saveMeta
  - 3b 路径: utmmd 未变但服务未运行 → `svc.start()`（跳过重装）
  - 均未命中: 服务已在运行，无需操作
- Guest ensure: 同 Host ensure 优化逻辑

**`src/svc.zig`** (~140 行新增):
- `configFilePath()` — utmm.conf 路径
- `readConfigValue(io, alloc, key)` — 读取 key=value
- `writeConfigValue(io, alloc, key, value)` — 写入 key=value（tmp+rename 原子写）
- `readFullFile(io, alloc, path)` — 读取完整文件内容
- `fileSha256Hex(io, alloc, path)` — 运行时计算文件 SHA256 hex
- `buildArgsString(alloc, role, extra_args)` — 序列化参数用于比对
- `shouldUpdateUtmmd(io, alloc, role, extra_args, comptime hex) bool` — 三检查点:
  1. utmmd 二进制是否存在
  2. SHA256 hash 是否匹配嵌入值
  3. 存储的 args 是否匹配当前参数
- `saveUtmmdMeta(io, alloc, role, extra_args, comptime hex)` — 保存 hash+args 到 utmm.conf

### 设计决策

- SHA256 在构建期预计算（`build.zig` shasum 步骤），避免 comptime 哈希的 eval branch quota 问题
- utmm.conf 使用 key=value 纯文本格式，简单可靠
- 文件写入使用 tmp+rename 原子模式
- `shouldUpdateUtmmd` 三检查点中任一项不匹配即触发全量重装

### 验证

- `zig build`: 编译成功（utmmd + hash + utmm 三步构建）
- `zig build test`: 166/166 全部通过

## Phase 74: 自动升级 forceInstall 修复 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 350 | killAllUtmm PID 感知 — pgrep/tasklist 枚举 + 排除自身（Finding 139） | ✅ |
| 351 | waitForProcessExit — stop 后轮询等待进程退出（Finding 135） | ✅ |
| 352 | macOS start() 重试 — 500ms 延迟 + bootstrap 3 次重试（Finding 123） | ✅ |
| 353 | exit(0) → exit(42) — applyUpgradeAndRestart 非零退出码 | ✅ |
| 354 | zig build + 166/166 测试通过 | ✅ |

### 变更摘要

- **`src/svc.zig`**: `getOwnPid()` + `killAllUtmm()` 重写（PID 感知）+ `countOtherUtmmProcesses()` + `waitForProcessExit()` + `forceInstallInternal()` 步骤 1.5 等待 + `start()` macOS bootstrap 重试
- **`src/broadcast.zig`**: `applyUpgradeAndRestart()` — `exit(0)` → `exit(42)`

### 验证结果

- 166/166 测试通过
- zig build 编译成功
- 待部署验证: macvm (Finding 123), linuxvm (Finding 135), Host (Finding 139)

## Phase 73: KCP Tunnel 稳定性 + 下载性能修复 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 345 | 3 条 KCP 日志 info→debug（Finding 138） | ✅ |
| 346 | session_gen 计数 + 移除旧 session 销毁 + epoch 范围（Finding 129） | ✅ |
| 347 | waitForHostTunnel mutex 解锁顺序修复 | ✅ |
| 348 | tunnel.deinit 加 closeSession() | ✅ |
| 349 | 部署验证（Host + macvm + linuxvm） | ✅ |

### 变更摘要

- **`src/mesh.zig`**: session_gen 字段、connect() 重写、2 处 epoch 检查改为范围验证、3 条日志降级、死 session 清理
- **`src/broadcast.zig`**: waitForHostTunnel() mutex 移到 Tunnel.init() 之后
- **`src/tunnel.zig`**: deinit() 调用 closeSession()

### 验证结果

- macvm exec 4/4 成功（修复前 exit=-1）
- linuxvm exec 无回归
- 日志 10 秒 3.5KB（修复前 96MB/数分钟）
- Windows VM 仍 v0.11.22，显示旧行为（符合预期）

## Phase 72: 自动升级 rollback 修复 + 全流程部署测试 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 339 | `forceInstallInternal()` 步骤 5 删除回滚逻辑 | ✅ |
| 340 | v0.11.21→v0.11.22→v0.11.23 构建 + Host 部署 | ✅ |
| 341 | macvm 自动升级观察 | ✅ 下载成功，bootstrap errno=2，二进制+配置保留 |
| 342 | linuxvm 自动升级观察 | ✅ 下载成功，selfCopy 未更新（Text file busy），手动修复 |
| 343 | windowsvm 自动升级观察 | ✅ 下载成功，install 失败，优雅回退 |
| 344 | winx64 自动升级观察 | ✅ 未检测到升级信号 |

### 变更摘要

**`src/svc.zig` — forceInstallInternal() 步骤 5**:
- 删除 start 失败时的回滚逻辑（uninstallServiceConfig + deleteFile）
- 改为保留二进制和配置，仅日志 err + fail.err 退出
- 理由: 自动升级时旧进程已被 kill，删除一切 = VM 彻底失联

### 自动升级结果矩阵

| Guest | 下载 | install | 最终版本 | 根因 | Finding |
|-------|------|---------|---------|------|---------|
| macvm | ✅ 12.6MB | ⚠️ bootstrap errno=2 | v0.11.23 | launchctl bootstrap 间歇失败 | 92, 128 |
| linuxvm | ✅ 12.6MB | ❌ selfCopy 未更新 | v0.11.23 (手动) | Text file busy — 服务未完全停止 | 135 |
| windowsvm | ✅ 6MB | ❌ install 失败 | v0.11.22 | 待调查（优雅回退） | 137 |
| winx64 | ❌ 未触发 | — | v0.11.22 | LSA 升级信号未检测到 | 136 |

### 关键发现

1. **rollback 修复验证成功** — macvm 场景是最佳证明：bootstrap 失败后二进制+配置保留，旧代码会删除一切
2. **linuxvm selfCopy** — `systemctl stop` 异步，进程未完全退出前 selfCopy 遇到 "Text file busy"
3. **KCP 下载性能** — info 级别 mesh 数据包日志导致 96MB 日志文件，有效吞吐 ~15KB/s
4. **Host 自 kill** — `pkill -9 -x utmm` 匹配安装器自身进程
5. **winx64 子网隔离** — 192.168.3.x 与 64.x/65.x 之间的 LSA 可达性待验证

## Phase 71: 版本号单文件管理 + GitHub 新版本检测 (2026-07-28)

| # | 任务 | 状态 |
|---|------|------|
| 334 | `src/ver.txt`（0.11.18 无换行）+ `build.zig.zon` → `0.0.0` | ✅ |
| 335 | `protocol.zig`: `@embedFile("ver.txt")` + comptime strip 换行 | ✅ |
| 336 | `release.sh` 打包 ver.txt；`install.sh`/`install.bat` 动态读版本 | ✅ |
| 337 | `checkGitHubVersion()` — OS 线程 fire-and-forget，5 redirect，格式校验 | ✅ |
| 338 | 构建+测试 166/166 通过 | ✅ |

### 变更摘要

**版本号单文件管理**:
- `src/ver.txt` — 版本号唯一来源，内容 `0.11.18`（无末尾换行）
- `build.zig.zon` — 永为 `0.0.0`，不再改动
- `protocol.zig` — `@embedFile("ver.txt")` 编译期嵌入，comptime strip 末尾换行
- `release.sh` — `cp src/ver.txt release/`
- `install.sh`/`install.bat` — 从 `ver.txt` 动态读版本，curl 流程回退 `"latest"`

**GitHub 新版本检测** (`src/host.zig`):
- `checkGitHubVersion()` — 独立 OS 线程，spawn+detach，fire-and-forget
- 支持 302 重定向（`redirect_behavior = .init(5)`）
- `isValidVersion()` 格式校验 — 纯数字 `X.Y.Z`，拒绝人机校验页面
- 日志：`[host] New version X.Y.Z available on github`（仅新版本时）

**附带修复**:
- `src/main.zig` comptime 块加 `@import("host.zig")` → 7 个遗漏测试生效

## Phase 70: `--status` 增强 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 330 | GuestEntry 加 role 字段：struct + upsertGuest + deinit + removeGuest | ✅ |
| 331 | handleStatus JSON 输出全部 9 字段（+role/+status/+last_seen） | ✅ |
| 332 | host.zig：tunnelManager 移除 role:host 过滤 + Host 自注册 + cmdStatus 表格 + cmdVerify 跳过 Host | ✅ |
| 333 | formatStatusMCP markdown 加 role/status | ✅ |

### 变更摘要

**GuestEntry 加 role 字段** (`src/httpd.zig`):
- `role: []const u8` — "host" | "guest" 标识节点类型
- `upsertGuest()` 签名加 `role` 参数，update/insert 路径均处理
- `deinit()` / `removeGuest()` 释放 role 内存

**handleStatus 完整字段** (`src/ipc.zig`):
- JSON 从 6 字段扩展到 9 字段：hostname, role, target, ip, mac, version, shell, status, last_seen

**Host 自注册 + 过滤移除** (`src/host.zig`):
- `startHost()`：mesh 初始化后 upsertGuest 写入 Host 自身（role=host, MAC=全零）
- `tunnelManager`：移除 `role == "host" continue` 过滤
- `upsertGuest` 调用传递 role 参数

**cmdStatus 表格更新** (`src/host.zig`):
- 加 Role、Status、Last 三列（8 列紧凑单行）
- last_seen 使用相对时间格式化（now/Ns/Nm/Nh/Nd）

**cmdVerify 跳过 Host** (`src/host.zig`):
- Host 无自身 KCP 隧道，ping/exec 必然失败 → 跳过 role=host 的条目

**formatStatusMCP 更新** (`src/mcp.zig`):
- 每个节点显示 role 标签：`**hostname** (role) — ...`
- 加 status 字段：`| status: serving`

## Phase 69: 开发效率提升 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 326 | 二进制类型校验 — selfCopy 前检查文件魔数 | ✅ |
| 327 | `--verify` 健康检查命令 | ✅ |
| 328 | `--deploy` 一键部署命令 | ✅ |
| 329 | `deploy` Claude Code skill | ✅ |

### 变更摘要

**Task 326 — 二进制类型校验** (`src/svc.zig`):
- 新增 `validateBinaryType()` 函数：读二进制前 4 字节，比较平台魔数
- 新增 `describeBinary()` 辅助函数：魔数 → 可读格式名称
- 在 `selfCopy()` 中调用，复制前验证平台匹配
- 魔数常量：ELF `\x7fELF`、Mach-O `\xcf\xfa\xed\xfe`、PE `MZ`
- 10 个新测试（describeBinary 7 + magic constants 3）
- 防止 ELF-on-macOS 类部署错误

**Task 327 — `--verify` 健康检查** (`src/main.zig`、`src/host.zig`):
- 新增 `--verify` CLI 命令
- 对全部在线 Guest 执行三重检查：Status（LSA 在线）+ Ping（mesh 可达）+ Exec echo（隧道+shell 正常）
- ANSI 彩色矩阵输出（绿✓/红✗/黄−）
- 任一检查失败 → exit(1)；全部通过 → exit(0)

**Task 328 — `--deploy` 一键部署** (`src/main.zig`、`src/host.zig`):
- 新增 `--deploy [TARGET]` CLI 命令
- 硬编码 4 VM 配置表（linuxvm/macvm/windowsvm/winx64）
- 自动交叉编译 → sshpass+scp 上传 → sshpass+ssh 安装
- Windows 目标跳过 SCP/SSH（提示手动步骤）
- 成功/失败计数摘要输出
- 依赖 `sshpass`（检查并提示安装）

**Task 329 — deploy skill** (`.claude/skills/deploy/SKILL.md`):
- VM 配置表 + 部署流程文档
- macOS bootstrap 常见问题处理（errno=5/2、codesign）
- 手动/自动部署两种方式
- 安全注意事项

### 性能影响
- 无运行时开销（所有新增代码仅在 CLI 管理命令中执行）
- `validateBinaryType` 仅在 `selfCopy` 时调用，读 4 字节
- `--verify` 串行检查每台 Guest（ping + exec echo），~5s/台

## Phase 68: 修复 LSA restart 误判 (Finding 124) (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 325 | 实现 nonce 比较替代全 node_info 字符串比较 | ✅ |

### 修复摘要

**根因**: LSA restart 检测用全 node_info 字符串比较，但 `status:serving↔upgrading` 变化被误判为进程重启 → KCP 会话被杀 → 隧道循环断开。这是自毁循环：升级第一步（改 status）就断了升级需要的隧道。

**fix**: `nonceChanged()` 用 nonce 比较替代全字符串比较；`updateNodeInfo()` 自动重新附加 nonce 保身份不丢失；`parseEpoch()` 兼容 `nonce:` 和 `epoch:` 键名。

**测试**: 149/149 通过

## Phase 67: v0.11.17 部署 + 自动升级测试 (2026-07-27)

| # | 任务 | 状态 |
|---|------|------|
| 320 | Bump 版本 v0.11.16→v0.11.17 | ✅ |
| 321 | 构建 8 目标 + 149/149 tests | ✅ |
| 322 | Host v0.11.17 部署 | ✅ `launchctl bootstrap` errno=2，kickstart 恢复 |
| 323 | 自动升级观察 | ❌ 全部失败 — 4 台 Guest 下载成功，但 `--install` 均未生效 |
| 324 | 手动升级 + 功能验证 | ✅ linuxvm (SCP+--install)、macvm (kickstart)、Windows (SCP+--install) |

### 自动升级问题汇总

| Guest | 下载 | --install | 最终状态 | 根因 |
|-------|------|-----------|---------|------|
| linuxvm | ✅ (8MB) | ❌ 无声失败，无日志 | 手动 SCP 恢复 | receiveUpgradeFile 未完成；Journal 停止 |
| macvm | ✅ (4MB, 第3次) | ⚠️ 成功但服务停止 | 手动 kickstart | Finding 123: exit(0)+KeepAlive |
| windowsvm | ✅ (3.5MB) | ❌ --install 未生效 | 手动 SCP 恢复 | 待调查 |
| winx64 | ✅ (3.6MB) | ❌ --install 未生效 | 手动 SCP 恢复 | 待调查 |

### 关键 Bug 发现

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 123 | 🔴 CRITICAL | macOS 自动升级后服务永久停止 |
| 124 | 🔴 | 非 Linux Guest 隧道不稳定，exec 失败 |
| 125 | 📋 | `nowMs()` RTT 中继路径异常 |
| 126 | 📋 | DebugAllocator 泄漏（仅 debug 构建） |
| 127 | 📋 | linuxvm 日志停止 + 升级无声失败 |
| 128 | 📋 | macOS bootstrap errno=5 在 bootout 后 |

### 功能验证 (手动升级后)

| Guest | exec | upload | download |
|-------|------|--------|----------|
| linuxvm | ✅ | ✅ | ✅ |
| macvm | ❌ exit=-1 | — | — |
| windowsvm | ✅ | — | — |
| winx64 | ❌ exit=-1 | — | — |

## Phase 66: 小修复收尾 ✅ (2026-07-27)

| # | 任务 | 状态 | 提交 |
|---|------|------|------|
| 1 | `upload_result` (0x17) handler | ✅ 已存在（commit `98409c4`）| — |
| 2 | RTT → 真实毫秒 | ✅ `nowMs()` 替代 ping/pong 时钟 | `3c6d7d4` |
| 3 | macOS codesign 重签 | ✅ EXDEV 回退路径加 `codesign --force --sign -` | `3c6d7d4` |
| 4 | 多网卡 LSA 广播可达性 | ✅ 每 30s 回调刷新广播地址列表 | `3c6d7d4` |

**已取消**: httpd.zig 测试编译（httpd 已废弃）、Windows 优雅退出 Finding 103（永久延迟）

## Phase 61-65 摘要

### Phase 61: 删除 HTTP 协议 → KCP+IPC ✅
HTTP 服务器全面删除。端口 2121 仅保留 UDP（mesh LSA + KCP tunnel）。CLI/MCP 走 IPC socket（`/var/run/utmm.sock`）。httpd.zig 1750→680 行（-61%）。

### Phase 62: Windows IPC 编译修复 + 全量部署 ✅
修复 Zig 0.16.0 Windows Named Pipe API 移除（手动 `extern "kernel32"` + `callconv(.winapi)`）。8 目标全通过，4 Guest 全量功能验证通过（status/ping/exec/upload/download）。

### Phase 63: Guest 自主升级 ✅
v0.11.12: Guest 检测版本不匹配 → `upgrade_req` → KCP 下载 → `--install`。
v0.11.13: 移除 Host 推送升级代码（~223 行），Host 仅响应 `upgrade_req`。
v0.11.14: 修复命令循环死锁 — 升级检查需在内外两层循环都存在（Finding 120）。

### Phase 64: 文档重写 + v0.11.15 ✅
SKILL.md + MANUAL.md 全面更新至 v0.11.14 代码现状。发布 v0.11.15 后发现 IP gating bug 阻止自动升级。

### Phase 65: install.sh + install.bat + v0.11.16 ✅
跨平台一键安装脚本（POSIX 272 行 / Windows 332 行）。v0.11.16 附带 IP gating 修复（`mesh.zig` 移除 `host_gateway_ip` 依赖）。全部 Guest 手动升级至 v0.11.16。

## 历史阶段 (Phase 50-60)

| Phase | 关键成果 |
|-------|---------|
| 50 | 加固审计：20 修复（Finding 68-79） |
| 51 | 文件合并 19→13、API 适配 Zig 0.16.0、测试 +52% |
| 52 | CLI auto-ensure：管理命令自动启动 Host 服务 |
| 53 | MCP stdio JSON-RPC + `utmm.lock` PID 文件单例锁 |
| 54 | Host 重启 exec 空输出修复：6 协同 bug（0xFF keepalive 污染、peekSize/recv 不对称等） |
| 55 | Windows 服务停止：signalShutdown 不提前关 socket、pty 管道 CloseHandle |
| 56 | 回归测试 + Windows 硬停止（放弃优雅退出） |
| 57 | `--ping` 命令：mesh ping/pong（11B direct / 18B relayed） |
| 58 | file_chunk MSS 对齐 8KB→1200B + 关键代码注释 |
| 59 | macOS plist StandardErrorPath 回归修复 |
| 60 | 清理 HTTP POST 端点 + fallback 函数死代码 |

## 最近提交

```
e29f874 docs: use --scope user for cross-project MCP registration
0bfd716 docs: update MCP documentation — stdio transport, claude mcp add, troubleshooting
a25f684 fix: MCP stdio single-line JSON responses for newline-delimited transport
bded163 v0.12.2: bump version
f672594 docs: update planning files with Phase 78 findings and v0.12.1 deployment status
9716850 fix: remove auto-uninstall on serve-dir version mismatch
```
