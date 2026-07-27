# Progress: v0.11.16-dev

## 当前状态

- **分支**: `main`
- **版本**: 0.11.15 tagged; 代码已修改（自动升级修复）待 bump
- **测试**: 149/149 通过
- **部署**: macOS Host v0.11.15 ✅ | linuxvm v0.11.15 ✅ | macvm v0.11.15 ✅ | windowsvm v0.11.15 ✅ | winx64 v0.11.15 ✅
- **未提交修改**: 自动升级 IP gating 修复（mesh.zig + broadcast.zig + host.zig）

## Phase 64: 文档重写 + v0.11.15 发布 (2026-07-27)

**目标**: 重写 `skills/utmm/SKILL.md` 和 `skills/utmm/MANUAL.md`，使其与 v0.11.14 代码现状一致。

### 文档更新

**SKILL.md** (216 行):
- 架构描述：新增 IPC socket，明确无 HTTP
- MCP 工具：2→5（新增 vm_ping、vm_upload、vm_download），完整参数说明
- 新增文件传输工作流示例、Auto-Upgrade 节
- Host 路径：新增 IPC socket（`/var/run/utmm.sock`、`\\.\pipe\utmm`）

**MANUAL.md** (659 行):
- 版本号：0.11.10→0.11.14
- 端口 2121：TCP HTTP→UDP only（LSA + KCP）
- CLI/MCP 通信方式：HTTP→IPC socket
- MCP 工具数：2→5
- 升级机制：无自动升级→Guest 自主升级（完整流程）
- 源文件结构：14→15 文件（新增 ipc.zig）
- IPC socket 路径表、服务名称表、完整 CLI flags 参考

### v0.11.15 发布

- Bump 版本：0.11.14→0.11.15
- 构建 8 目标 + `./release.sh`
- 本机 Host 部署 + 观察 VM 自动升级

### 自动升级观察 — 关键 Bug 发现

**结果**：3 台 Guest 在 2+ 分钟观察期内无一自动升级（轮询 ~24 轮×5s）。

**根因**：`mesh.zig:901` — `remote_ip != self.host_gateway_ip` 条件失败。

**详细分析**：
- Host LSA 广播的 `ip:` 字段来自 `getSystemInfo().detectUnixIp()` — 找第一个物理 NIC，在多网卡 Host 上是主 IP（本机 `192.168.1.7` WiFi `en0`），bridge 接口（`bridge100`/`bridge101`）被 `isPhysicalInterface` 排除
- Guest 的 `host_gateway_ip` 是网关 IP（linuxvm/macvm: `192.168.64.1`，windowsvm: `192.168.65.1`）
- 「主 IP ≠ Guest 看到的网关 IP」→ `remote_ip != host_gateway_ip` 恒为 true → 版本检查代码从未执行

**修复**（已编码，待 bump）：
- 移除 `mesh.zig` 中的 `host_gateway_ip` 字段和 IP gating 条件
- 移除 `broadcast.zig` 中的 `extractHostIp()` 和调用
- `host.zig`: 移除 `Mesh.init()` 的 `""` 参数
- 影响：3 文件，净删除 ~30 行

**版本检查现在直接执行**：`remote_version != protocol.VERSION` — 无需 IP 匹配。
版本不匹配即触发升级。其他 Guest 都运行相同 VERSION，无虚假触发风险。

## Phase 65: 一键安装脚本 (install.sh + install.bat) ← 当前

**目标**: 创建跨平台交互式安装脚本，一行命令即可完成首次安装/升级。

**设计原则**（讨论共识）：
- 全平台强制 root/Administrator 权限检查
- 脚本交互提问 hostname/mode；`utmm` 二进制绝不交互
- 纯 `.bat`（Win7+）— 不用 `.ps1`
- 安装=升级，不分模式
- Host 模式下保留全部 8 个平台二进制（Guest 自动升级依赖）
- 支持离线安装：zip 自带 `install.sh`/`install.bat`
- README/SKILL.md/MANUAL.md 去除 UTM 限定描述，适用所有 VM + 真机

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `install.sh` | 新建 | POSIX 安装脚本，~180行 |
| `install.bat` | 新建 | Windows 安装脚本，~150行，Win7+ 兼容 |
| `.gitattributes` | 更新 | `install.sh text eol=lf` / `install.bat text eol=crlf` |
| `release.sh` | 修改 | zip 打包时追加 `install.sh install.bat` |
| `README.md` | 修改 | One-Time Setup 重写；去除 SCP/UTM 限定描述 |
| `SKILL.md` | 修改 | 安装指引同步为一键脚本 |
| `MANUAL.md` | 修改 | 安装章节重写；去除 UTM 限定描述 |
| `task_plan.md` | 更新 | Phase 65 计划 |
| `progress.md` | 更新 | 进度跟踪 |

**实现步骤**：
1. 创建 `install.sh`（POSIX：curl/wget download + unzip + 交互 + --install）
2. 创建 `install.bat`（Windows：curl/certutil download + tar/COM unzip + 交互 + --install）
3. 更新 `.gitattributes` 强制 LF/CRLF 行尾
4. 修改 `release.sh`，zip 追加 install 脚本
5. 更新 `README.md` One-Time Setup 为一键命令
6. 更新 `SKILL.md` / `MANUAL.md` 安装章节
7. 更新 `build.zig.zon` + `src/protocol.zig` VERSION bump
8. 构建 → 测试 → 发布 v0.11.16 → 部署观察自动升级

## Phase 63: Guest 自主升级方案 ✅ (2026-07-27)

**目标**: 将升级从 Host 推送模式简化为 Guest 自主完成，实现可靠的原子化自升级。

### v0.11.12 — Guest 自动升级初版 (commit `6ee2155`)

**新增功能** (`src/broadcast.zig`):
- `doAutoUpgrade()`: 检测 `upgrade.needed` → KCP 下载 → `--install`
- `receiveUpgradeFile()`: 接收 file_chunk×N + file_eof，SHA256 校验
- `applyUpgradeAndRestart()`: `chmod +x` → `std.process.run` 执行 `--install --hostname <name>`

**协议**: Guest 发送 `upgrade_req` (0x19) → Host `serveUpgradeFile()` 响应 file_chunk + file_eof

**Bug**: 升级检查只在外层循环，内层命令循环无法检测 → 升级信号死锁 (Finding 120)

### v0.11.13 — 简化 Host 侧 (commit `98409c4`)

**host.zig 移除** (~223 行):
- `pushUpgradeToGuest()` 函数（~183 行）
- `upgrade_cooldown` 状态变量和初始化
- 推送触发逻辑（~40 行）

**tunnelManager 简化**:
- 删除 upgrading 特殊逻辑（Phase 2 搜索 Guest-initiated session → 死锁 Finding 122）
- 统一 `m.connect()` 建立隧道
- 添加注释说明：Auto-upgrade is Guest-initiated

**设计原则确立**: Host 永不推送升级，Guest 完全自主。

### v0.11.14 — 修复命令循环死锁 (commit `7178fb2`)

**Critical Fix** (`src/broadcast.zig`):
- 内层命令循环添加 `upgrade.needed.load(.acquire)` 检查
- Guest 检测到升级信号后 `break` 退出命令循环，外层循环处理升级

**版本发布**:
- `src/protocol.zig`: VERSION "0.11.12" → "0.11.13" → "0.11.14"
- `build.zig.zon`: version 同步更新
- GitHub Release v0.11.14 已发布

**Bootstrap 部署** (v0.11.11/v0.11.12 Guest 无法自动升级):
| Guest | 方式 | 结果 |
|-------|------|------|
| linuxvm | SSH scp + sudo --install | ✅ |
| macvm | SSH scp + sudo --install + 手动 launchctl bootstrap | ✅ (errno=2 后手动修复) |
| windowsvm | SSH scp + --install | ✅ |
| winx64 | 离线 | ⏸️ |

**升级后验证**:
| 命令 | linuxvm | macvm | windowsvm |
|------|---------|-------|-----------|
| `--status` | ✅ Online | ✅ Online | ✅ Online |
| `--exec uname/ver` | ✅ Linux | ✅ Darwin | ✅ Windows |
| `--ping` | ✅ | ✅ | ✅ |

**hostname 持久化验证**: `--install --hostname <name>` 在所有平台上正确写入服务配置文件（systemd unit / launchd plist / sc binPath）。Guest 重启后保持原始 hostname。

### 最终升级架构

```
Guest LSA handler: Host version ≠ protocol.VERSION → upgrade.needed = true
Guest 命令循环: upgrade.needed? → break
Guest 外层循环: doAutoUpgrade()
  → waitForHostTunnel()
  → 发送 upgrade_req(0x19, target)
  → Host serveUpgradeFile() → deploymentFilename(target) → file_chunk×N + file_eof
  → Guest receiveUpgradeFile() → temp path + SHA256 验证
  → applyUpgradeAndRestart(temp_path, hostname)
    → chmod +x (POSIX)
    → std.process.run: <temp> --install --hostname <name>
    → forceInstall: stop → kill → copy → install(service config) → start
```

**关键原则**:
- Host 永不推送升级 — Guest 完全自主
- `--install --hostname <name>` 保留原始 hostname（写入服务配置文件）
- KCP 隧道复用正常命令通道，不创建特殊升级通道
- 升级失败自动重试：下次 LSA 广播重新触发

## 最近提交

```
7178fb2 v0.11.14: fix upgrade check in command loop
98409c4 v0.11.13: simplify auto-upgrade to Guest-initiated download + --install
578f55c feat: Host-initiated upgrade push for legacy Guests via KCP upload+exec
13b4a03 fix: ++ concat requires comptime-known left operand in Zig 0.16.0
6ee2155 v0.11.12: guest auto-upgrade via KCP tunnel with --install self-deployment
a3b4672 fix: download + IPC command verification - 3 critical fixes
```

## Phase 62: Windows IPC 编译修复 + 全量部署测试 ✅ (2026-07-27)

**目标**: 修复 Phase 61 HTTP 删除后 Windows 交叉编译问题，构建所有 8 目标并部署到全部 VM。

**Windows IPC 编译修复** (`src/ipc.zig`):

Zig 0.16.0 移除了大量 `std.os.windows` API，需要在 `ipc.zig` 中手动声明：
- `extern "kernel32"` 声明 7 个 Win32 API（CreateNamedPipeA、ConnectNamedPipe、CreateFileA、ReadFile、WriteFile、SetNamedPipeHandleState）
- `callconv(.winapi)` 必需 — 32-bit MinGW (x86-windows-gnu) 没有此约定会导致 `_CreateFileA` 等符号未定义
- `hTemplateFile: ?HANDLE`（可空类型）— Zig 0.16.0 中 `null` 无类型，不能隐式转换
- `socketPathZ()` 返回 `[*:0]const u8` — 字符串字面量直接强制转换为 sentinel 指针，无需 `@ptrCast`

**构建验证**: 8 目标全部通过 (aarch64/x86_64/x86 × linux-musl/macos/windows)。

**部署测试结果**:

| VM | Status | Ping | Exec | Upload | Download |
|----|--------|------|------|--------|----------|
| linuxvm | ✅ | ✅ | ✅ | ✅ 30B MATCH | ✅ 30B MATCH |
| macvm | ✅ | ✅ | ✅ | ✅ 30B MATCH | ✅ 30B MATCH |
| windowsvm | ✅ | ✅ | ✅ | ✅ 30B MATCH | ✅ 30B MATCH |
| winx64 | ✅ | ✅ | ✅ | ✅ 30B MATCH | ✅ 30B MATCH |

**macOS launchctl bootstrap 已知问题**: `--install` 最后一步 `launchctl bootstrap` 偶尔返回 errno=2/5，但 launchd 会自动重启服务（二进制已复制到位）。手动 `bootout` + `bootstrap` 可解决。

## Phase 59: StandardErrorPath plist 回归修复 ✅ (2026-07-27)

**问题**: `--install` 重写 macOS plist 时未包含 `StandardErrorPath`（Finding 110/112 回归）。
每次 `--install` 部署后 stderr 日志丢失，严重阻碍问题排查。

**修复**: `svc.zig:installMacOS()` plist 模板新增 `<key>StandardErrorPath</key>` + 对应日志路径。

**部署测试**: 修复后本机 Host 部署成功，日志正常写入 `/var/log/utmm-host-err.log`。

## Phase 58: 关键代码注释 + file_chunk MSS 对齐 ✅ (2026-07-27)

**目标**: 防止代码误读（Finding 109 教训）；消除 file_chunk 的 KCP 层二次分片。

**注释**: 4 文件添加技术细节注释（parse* 约定、MTU/MSS/frg、dispatch 分派约定、chunk 大小设计理由）。

**file_chunk MSS 对齐**:

| 指标 | 旧 (8KB) | 新 (MSS-aligned) |
|------|---------|-----------------|
| 数据/chunk | 8192 B | 1200 B |
| KCP frame 大小 | ~8217 B | ~1229 B |
| KCP segment/chunk | 7 (frg 6→0) | **1** |
| 丢失 1 segment 影响 | 阻塞整个 8KB chunk | 仅丢失 1 个 chunk |
| 应用层开销 | ~0.4% | ~2% |

**部署测试** (本机 Host + macvm Guest): 全部 5 个命令通过。
- `--status` / `--ping` / `--exec` / `--upload` / `--download` ✅
- MSS-aligned chunk 在 upload/download 中正确工作（56B 文件上传下载 FILES MATCH）

**新增 Finding**:
- F112: macOS plist `StandardErrorPath` 回归 — `--install` 重写 plist 时丢失 stderr 日志

**发现已存在的 bug**:
- `handleMeshGuest` 缺少 `upload_result` (0x17) 处理 — Host log 中 `unknown msg type 0x17` 刷屏（upload 走 fire-and-forget 故不影响功能）

## Phase 57: `--ping` 命令 + 全量自动升级测试 ✅ (2026-07-27)

**目标**: 实现 `utmm --ping <hostname>` CLI 命令，通过 mesh ping 验证 Guest 连通性。测试 v0.11.10→v0.11.11 自动升级。

**实现**:

| 文件 | 变更 | 行数 |
|------|------|------|
| `src/protocol.zig` | VERSION 0.11.10→0.11.11 | +1/-1 |
| `build.zig.zon` | version 0.8.2→0.11.11 | +1/-1 |
| `src/main.zig` | `--ping` 参数解析、needs_host、dispatch、帮助文本 | +10/-2 |
| `src/host.zig` | `cmdPing()` HTTP 客户端、`setGuestMeshMac()` 调用、ping 路由 | +55/-0 |
| `src/httpd.zig` | `handlePing()` HTTP handler、`readHeader`→`getRequestHeader` 修复 | +47/-4 |
| `src/mesh.zig` | `pingAndWait()` 重写（真实时间轮询）、`sendPing()` 加直接 ping 日志、`fromMillis`→`fromMilliseconds` 修复 | +10/-15 |

**部署流程**:

1. Bump 版本 0.11.10→0.11.11
2. 构建 8 目标（全部通过）
3. 部署 Host（aarch64-macos）→ 重启服务
4. 升级 Guest（linuxvm→macvm→windowsvm→winx64）via SSH scp + `--install`
5. 修复升级后丢失的 hostname（手动改 systemd/launchd/sc 配置）
6. 验证 `--ping` 和 exec 全功能

**关键 Bug 修复**:

| # | 问题 | 严重度 | 状态 |
|---|------|--------|------|
| F104 | `setGuestMeshMac()` 从未调用 → mesh_mac 永远 null | Critical | ✅ |
| F105 | `pingAndWait` 用 clock_ms 事件计数器做超时 | High | ✅ |
| F3 | `fromMillis` Zig 0.16.0 API 不存在 | Medium | ✅ |
| F4 | `readHeader` 不存在 → `getRequestHeader` | Medium | ✅ |
| F5 | `Discarding.init()` 需要 buffer 参数 | Medium | ✅ |
| F107 | SSH `--install` 被 pkill 自伤 | Medium | 📋 规避方案 |
| F108 | 升级后 Guest hostname 丢失 | Medium | 📋 已手动修复 |

**Ping 验证结果** (2026-07-27):

| Guest | Hostname | --ping | RTT (ticks) | exec |
|-------|----------|--------|-------------|------|
| linuxvm | linuxvm | ✅ `{"hostname":"linuxvm","mac":"16:a0:6c:ba:ae:fa","rtt_ms":10}` | 10 | ✅ |
| macvm | macvm | ✅ `{"hostname":"macvm","mac":"1a:97:6d:38:0c:6c","rtt_ms":10}` | 10 | ✅ |
| windowsvm | windowsvm | ✅ `{"hostname":"windowsvm","mac":"66:dc:da:ec:a1:59","rtt_ms":10}` | 10 | ✅ |
| winx64 | winx64 | ✅ `{"hostname":"winx64","mac":"00:ff:4d:91:87:0b","rtt_ms":10}` | 10 | ✅ |

**Host 日志确认直接 ping→pong 完整链路**:
```
[mesh] ping direct: → 16:a0:6c:ba:ae:fa addr=192.168.64.2:2121    (linuxvm)
[mesh] ping direct: → 1a:97:6d:38:0c:6c addr=192.168.64.4:2121    (macvm)
[mesh] ping direct: → 66:dc:da:ec:a1:59 addr=192.168.65.2:2121    (windowsvm)
[mesh] ping direct: → 00:ff:4d:91:87:0b addr=192.168.3.108:2121   (winx64)
[mesh] pong from 16:a0:6c:ba:ae:fa rtt=20ms
[mesh] pong from 1a:97:6d:38:0c:6c rtt=30ms
[mesh] pong from 66:dc:da:ec:a1:59 rtt=40ms
[mesh] pong from 00:ff:4d:91:87:0b rtt=50ms
```

**遗留**:
- RTT 为 `clock_ms` 事件计数（非真实毫秒），后续可改用 `std.Io.Timestamp.awake`
- F91: `selfCopy()` copy+delete 路径 macOS codesign 重新签名
- Windows 优雅退出方案延后（Finding 103）

## Phase 60: HTTP 废弃端点清理 ✅ (2026-07-27)

**目标**: 移除 CLI→IPC 迁移后的 HTTP 死代码（POST 端点 + HTTP fallback 函数）。

**httpd.zig 移除** (约 500 行):
- `parseJson()` — 已被 mcp.zig 的 JSON 解析替代
- `readBody()` / `readRawBody()` / `getRequestHeader()` — POST body 读取辅助
- `handlePing()` / `handleExec()` / `handleUpload()` / `handleDownload()` — 4 个 POST 端点
- `parseJson` 测试 (2 个)
- `respondError()` / `respondErrorDirect()` → 恢复保留（`handleBin()` 使用）

**host.zig 移除** (约 410 行):
- 4 条 POST 路由注册
- 5 个 HTTP fallback 函数: `cmdStatusHttp()` / `cmdPingHttp()` / `cmdExecHttp()` / `cmdUploadHttp()` / `cmdDownloadHttp()`

**验证**: `zig build test` 149/149 通过，与 git HEAD 一致。

**发现**: httpd.zig 测试（jsonEscape、jsonGetString、scanForMarker、HostState 等约 31 个）从未被编译入测试套件 — 等待排查。

## Phase 61: 彻底删除 HTTP 协议 ✅ (2026-07-27)

**目标**: HTTP 服务器所有 GET 端点均无活跃消费者，删除整个 HTTP 服务栈。

**httpd.zig** (1750→680 行, -61%):
- 删除: HTTP 路由器 (Router/HandlerFn)、serve() accept 循环、respondJson/Error/Direct、handleBin/Version/ApiGuests/Root、DEFAULT_PORT
- 保留: HostState + 状态管理、buildCmdWithMarker、handleMeshGuest、serveUpgradeFile (KCP)、syncHostsFromState、JSON 辅助函数、测试

**host.zig** (~-170 行):
- `startHttpHost` → `startHost`，移除 HTTP 路由注册、serve() 调用
- 阻塞机制改为 shutdown flag 轮询

**mcp.zig** (~-170 行):
- 删除 `handleVmStatusHttp` / `handleVmExecHttp` 死代码
- 移除 `const http = std.http;` import

**端口 2121**: 仅保留 UDP (mesh LSA + KCP tunnel)，不再使用 TCP HTTP。

**验证**: `zig build test` 149/149 通过。

## 历史阶段

Phase 50-56 详情见 [progress.md history](progress.md)。关键里程碑：

| Phase | 日期 | 内容 |
|-------|------|------|
| 56 | 2026-07-27 | 回归测试 + Windows 硬停止修复 |
| 55 | 2026-07-27 | Windows 服务停止卡死修复 |
| 54 | 2026-07-26 | Host 重启 exec 空输出修复（6 个协同 bug） |
| 53 | 2026-07-26 | MCP stdio + utmm.lock 单例锁 |
| 52 | 2026-07-26 | CLI auto-ensure + 部署测试 |
| 51 | 2026-07-26 | 19→13 文件合并 + 测试 +52% |
| 50 | 2026-07-26 | 加固优化全面审计（20 个修复） |
