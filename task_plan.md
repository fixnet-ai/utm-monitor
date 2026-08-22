# Task Plan — UTM Monitor

**版本**: v0.18.82（Phase 45 目标 v0.18.83） | **分支**: `main` | **更新**: 2026-08-22

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点 v0.18.82 serving
- **Phase 41 完成**: Windows exec OEM↔UTF-8 转码 + marker 独立行修复（v0.18.79）
- **Phase 42 完成**: CI 修复 (zio clone) + CI 接管发布 + MIT + SignPath 步骤待启用 (PR #6)
- **Phase 43 完成**: exec 断连取消传播 + 进程树整杀 + Guest 并发化（v0.18.80-82）
- **Phase 44 完成**: MCP 长任务超时修复（SSE 流式响应 + progress 心跳）
- **Phase 45 进行中**: 遗留 L2 — sshpass runWindowsConpty 假模式（Windows 10/11 sshpass 实测完全不可用）

## 进行中: Phase 45 — 遗留 L2: sshpass Windows ConPTY 假模式（v0.18.83 目标）

**状态**: ✅ 45A/45B/45C 完成；45D 验证完成 → 服务链处置已实施 **45D'（runWindowsAskpass）**，2026-08-22 windowsvm 真机验证全场景通过 → 下一步 45E

**背景**（证据链见 findings.md 2026-08-22 T3 研究段 + 下方实测）:
runWindowsConpty（sshpass.zig:918）的 startup_info 是裸 STARTUPINFOW
（cb=68），lpAttributeList 从未挂进 STARTUPINFOEXW → CreateProcessW 带
EXTENDED_STARTUPINFO_PRESENT + cb 不符 → **ERROR_INVALID_PARAMETER 直接失败**。
**实测**（windowsvm v0.18.82）: `utmm sshpass -p test ssh ... 127.0.0.1 -p 1`
→ exit 3 (runtime_error)。→ **Windows 10/11 上 `utmm sshpass` spawn 任何
子进程都立即失败**；MCP sshpass 工具在 Windows Host 上同样失败。deploy
Windows VM 走 macOS Host runPosix，不受影响（故自 v0.18.0 引入以来从未暴露）。

**用户裁定（2026-08-22）**:
1. Windows 必同时承担 Host/Guest 角色，**ConPTY 是主要且必须支持**——不是删除，而是**修复**。
2. 老 Windows（< 1809 无 CreatePseudoConsole）**按版本判断**走非 ConPTY（pipe）。
3. 老 Windows **不能运行 Host 模式**——启动时检测到无 ConPTY 则提示后退出。
4. 服务链 ConPTY（MCP sshpass on Windows Host 跑 Session 0）问题：**先修后定（分阶段）**
   ——先修 ConPTY 附加 + 老 Windows 分层，真机验证后视结果再定服务链处置。

**45D 真机验证结论（2026-08-22，windowsvm v0.18.83 修复版，关键）**:
- **45A 修复已生效**: 连拒绝端口 `ssh 127.0.0.1 -p 1` → RC=255 + "banner exchange: Connection refused"
  （修复前恒 exit 3/CreateProcessW 失败）。CreateProcessW + ConPTY 附加成功。
- **ConPTY 在 Session 0（无交互窗口站）不可用**: 内层 ConPTY 附加的命令导致整个
  SSH 会话/通道阻塞挂起（test1.bat 连 `echo ===` 都无输出；mcp exec transport dropped）。
- **管道模式在 Session 0 同样不可用**: PowerShell 纯管道测试（事件驱动匹配 password:
  后注入 111）→ ssh.exe 10s 零输出 + 15s TIMEOUT；`ssh.exe -v` 连真实 sshd 同样挂起。
- **ssh.exe 本身可用**: `ssh.exe -V` exit 0；连拒绝端口立即失败退出（非挂起）。
  唯一断点 = **密码交互**环节（无 TTY + 无交互控制台 → 挂起而非失败）。
- **推论**: Session 0 服务链下 Windows ssh 密码认证**无论 ConPTY 还是管道都不可行**。
  "ConPTY 是主要且必须支持"在**交互式桌面会话**成立，但在 Session 0 服务链不成立。
  完整证据链见 findings.md「2026-08-22 45D 真机验证」。

**服务链处置（用户裁定 2026-08-22 = C: 深挖 Session 0 ConPTY）——深挖结论 + 新方案**:
- **深挖推翻前提（决定性）**: Win32-OpenSSH sshpty.c `WIN32_FIXME` 分支**根本不用
  ConPTY**（ptyfd=0/ttyfd=0 = stdin/stdout 直通）→ `ssh -tt` 的成功是管道直通而非
  ConPTY → "复现 OpenSSH ConPTY 机制"是死路。ConPTY 在 Session 0 不可用是**平台事实**。
- **新正解 = SSH_ASKPASS + stdin EOF**（2026-08-22 windowsvm Session 0 实测全通过）:
  Win32 OpenSSH read_passphrase 检查 `SSH_ASKPASS` 环境变量 → 走 ssh_askpass 程序
  （CreatePipe + CreateProcess(`"askpass" "msg"`) + ReadFile 读密码）→ **完全避开 TTY/
  ConPTY**。ssh.exe 的 stdin 重定向为 NUL（`< nul`，立即 EOF）→ 根治"认证成功 + 命令
  完成后退出挂起"（Win32-OpenSSH issue #1769/#1427，stdin 保持打开所致）。
- **验证证据链**（windowsvm Session 0，mcp exec 上下文）:
  - `read_passphrase: requested to askpass` + `Authenticated ... using "password"` + `Exit status 0` + **RC=0**
  - 多行输出（LINE1/2/3）+ 非零退出码传播（远程 `exit 42` → RC=42）
  - 无残留 ssh.exe 进程
- **实施方向（45D'）**: sshpass.zig runWindows 增加 `hasConsole()` 检测 →
  **无控制台（Session 0 服务链）→ runWindowsAskpass**（SSH_ASKPASS + NUL stdin +
  SSHPASS 环境变量传密码，全部 Windows 版本可用）；有控制台 + ConPTY → runWindowsConpty
  （交互式保留）；有控制台 + 无 ConPTY（老 Windows）→ runWindowsAskpass（不依赖 ConPTY）。
  askpass 实现复用 ssh.exe 环境：SSH_ASKPASS 指向固定 askpass.bat（`@echo %SSHPASS%`），
  无需每次生成临时文件。**待用户确认后实施**。

**实施步骤**:

| # | 任务 | 说明 | 状态 |
|---|------|------|------|
| 45A | 修复 runWindowsConpty ConPTY 附加：自定义 STARTUPINFOEXW（StartupInfo + lpAttributeList，@sizeOf=112）+ cb=@sizeOf(STARTUPINFOEXW) + lpAttributeList 挂载 + CreateProcessW 传 &StartupInfo（EXTENDED_STARTUPINFO_PRESENT） | Zig 0.16 无 STARTUPINFOEXW，extern struct 自定义；ConPTY 真正附加后密码提示/交互认证可用 | ✅ 代码完成；真机验证 CreateProcessW 成功（连拒绝端口 RC=255 非 3） |
| 45B | 老 Windows 分层：conptyAvailable()==false 时 —— sshpass 调度走 runWindowsPipe（Guest/CLI 场景，已有）；**Host 模式启动时检测并提示退出**（host.zig cmdHost / utmmd ensure? 定位 Host 入口） | 老 Windows 不能当 Host；提示信息含 build 要求（Windows 10 1809+） | ✅ 代码完成（host.zig 启动检测） |
| 45C | 交叉编译 aarch64-windows + x86_64-windows + 单元/集成测试门禁（zig build test + test-integration 全绿） | 门禁先行再真机 | ✅ 230 单测 + 62 集成全绿 |
| 45D | **先单机验证**（Phase 41 部署纪律）: deploy windowsvm → 实测 `utmm sshpass` 连真实 sshd（正确密码 exit 0 / 错误密码 exit 5 / 主机不可达） | 45A 附加生效✅；ConPTY 与管道在 Session 0 均无法密码认证（挂起）；**SSH_ASKPASS + stdin EOF 方案实测全通过**（正确密码 RC=0 / exit 42 → RC=42） | ✅ 验证完成 → 新方案 45D' 待用户确认 |
| 45D' | **实施 SSH_ASKPASS 模式**（runWindowsAskpass）：ssh 命令永远走 askpass（不依赖控制台）+ SSH_ASKPASS/SSHPASS 环境变量 + NUL stdin + 读输出回传 + "Permission denied"→exit 5；.pass 分支必须 dupe（否则密码隐藏 @memset(argv,'z') 覆写同一内存 → SSHPASS="zzz" 认证失败） | **✅ 已实施 + windowsvm 真机验证全通过**（2026-08-22）：正确密码 RC=0 / 错误密码 RC=5 / 主机不可达 RC=255 / 多行输出完整透传 / 远程 exit 7 → RC=7。修复前 Permission denied（SSHPASS 被覆写为 zzz），diag 诊断定位 root cause | ✅ 完成 |
| 45D'' | （新增）交叉编译 + 门禁测试确认无回归（.pass dupe + 检测逻辑改动） | 单测 230 通过无泄漏 + 集成 62 通过无泄漏（2026-08-22）；泄漏修复：-p password 测试补 defer free + .pass dupe 加函数级 errdefer（块内 errdefer 在 case 块结束时失效，无法覆盖块外 NoCommand 错误返回） | ✅ 完成 |
| 45E | winx64 第二台验证 + MCP sshpass 工具全路径 + status 列确认 | **✅ 完成**（2026-08-22）：winx64（x86_64-windows）全场景与 windowsvm 一致（RC=0/5/多行/RC=7）；MCP sshpass 工具 macOS host→windowsvm/winx64 正确密码 exit 0 + 错误密码 exit 5；status 5 节点全 serving。**待办**：Windows Host 模式下的 MCP sshpass（Session 0 服务链）已由 exec 通道验证覆盖（同 runWindowsAskpass 底层），切换 host 部署后补验 | ✅ |
| 45F | 版本 bump v0.18.83 + 文档（README/MANUAL/TOOLS_JSON/SKILL/DESIGN/host.zig 注释更正 Windows ConPTY→SSH_ASKPASS）+ 发布 | **✅ 完成**（2026-08-22）：代码+文档+bump 完成，门禁全绿（单测 230 + 集成 62 无泄漏）；用户批准发布 → commit 4870f57 → release.sh v0.18.83 → tag push → CI 全绿（unit+integration 测试、8 目标构建、Release 创建），GitHub Release v0.18.83 含 utmm.zip。待办：部署到 VM（`utmm --deploy` + `utmm --upgrade`，CI 绿后） | ✅ |

## 已完成: Phase 44 — MCP 长任务超时修复（SSE 流式响应 + progress 心跳）

**背景**（证据见 findings.md 2026-08-22 Phase 44 段）:
utmm 自身的 exec/download/upload/sshpass 与 zigtester 有相同的 MCP 超时问题。
POST 请求走单 JSON 响应（mcp_http.zig:99 writeHttpResponse + :251 Content-Type:
application/json），processRequest 同步阻塞（mcp_http.zig:91），长任务
（exec 大输出 / download 大文件 / sshpass 慢命令）期间客户端收不到任何字节 →
撞 Claude Code per-request 超时（Timer A 60s）。McpContext（mcp.zig:30-40）
无 progressToken/progress 机制。zigtester 已用 `json_response=False`（SSE 流
+ report_progress 心跳）解决，本 Phase 在 utmm 的 mcp_http.zig 层复刻同一模式。

**方案**（只在 mcp_http.zig 改，不碰 mcp.zig / mcp_handler.zig）:
POST 响应从单 JSON 改为 SSE 流（Content-Type: text/event-stream）：
1. 立即写 SSE 头 + priming 注释（首字节秒到，客户端进入流式模式）
2. spawn 心跳线程，每 HEARTBEAT_MS=5s 发 `notifications/progress` SSE 事件
   （progress 单调递增 + message 已运行秒数），线程分片 sleep（50ms）保证
   join 快速返回不给响应加尾延迟
3. processRequest 完成后 done+join 心跳，写最终 `event: message` 事件，关连接
4. progressToken 从 `params._meta.progressToken`（fallback 顶层 `_meta`）提取；
   无 token 时心跳退化为 SSE 注释 keepalive（流仍活跃，避免超时）

| # | 任务 | 说明 | 状态 |
|---|------|------|------|
| 44A | SSE 基础设施：writeSsePostHead / writeSseMessageEvent / writeProgressEvent / extractProgressToken | 复用 protocol.jsonGetString/jsonGetNestedObject 提取 token；token gpa.dupe 副本（parsed.deinit 释放原串） | ✅ |
| 44B | Heartbeat 结构 + heartbeatThread（50ms 分片 threadSleepMs，累计到 5s 发 progress，done 原子门控） | 心跳只写 fd，与 HttpProbe 读 fd 全双工无冲突 | ✅ |
| 44C | handleHttpMcp 重构：token 提取 → SSE 头 → spawn 心跳 → processRequest → done+join → 最终 message 事件 | 错误响应也走 SSE 事件；readHttpRequestBody 失败仍走 writeHttpResponse（协议错误，SSE 头之前） | ✅ |
| 44D | 单测 + zig build test 全绿 + zigtester 集成 | 新增 SSE 格式/心跳/token 提取单测；230 单测全绿 + 62 集成全绿（mcp_http test 未被收集——预先存在，见 findings） | ✅ |

## 已完成: Phase 43 — exec 断连取消传播（连接生命周期 = 命令生命周期）

**背景**（证据见 findings.md 2026-08-19 Phase 43 段）: AI agent 中途取消 exec /
CLI Ctrl-C 后，命令在 Guest 上失控继续跑——链路三层（Guest handleExecCmd /
Host ExecIpcSink / Host HTTP MCP）均无取消传播，且 Guest 帧命令内联串行阻塞
accept 循环。**关键实测**: macOS poll 对半关闭也上报 POLLHUP → IPC 路径弃用
读侧检测，改零长 exec_data 帧写探测（全版本无害）。

**方案**（完整批准计划见 ~/.claude/plans/adaptive-jumping-teacup.md）:

| # | 任务 | 说明 | 状态 |
|---|------|------|------|
| 43A | dpipe_shell: killChild 进程组击杀 `kill(-pid)` + 公开 `requestKill` 入口 | 孙进程（nohup 型）一并清除；watcher 线程安全 | ✅ |
| 43B | guest.zig: 帧命令移出 accept 循环（std.Thread.spawn detach + conn_limit 名额转移）+ exec 断连 watcher（250ms 轮询 sockPollReadable → requestKill） | 解除长 exec 串行阻塞；done.store 先于 sockShutdown 防误判 | ✅ |
| 43C | mcp_handler: ClientWatch 可插拔检测接口（checkFn 带 done 参数，等待分片 ≤50ms 保证 join 快速）+ execWatchThread + on_output 返回 bool | abort 检查置于 @panic 之前；join 先于 tcp_conn.deinit | ✅ |
| 43D | ipc.zig: ExecIpcLink 写探测（零长 exec_data 帧探针 2s 周期 + std.Io.Mutex 序列化双写者） | CLI 零改动、server 读逻辑零改动；检测延迟 ≤2s（有输出即时） | ✅ |
| 43E | tcp.zig sockPollReadable（POSIX poll / Windows ws2_select）+ threadSleepMs + mcp_http HttpProbe + McpContext.client_watch | HTTP 检测延迟 ≤50ms 分片轮询 | ✅ |
| 43F | 测试 + 门禁 + 版本 + 文档 + 真机 | 单测 230 全绿；集成 62 全绿 ×3；三平台交叉编译过；发布 v0.18.80/81/82 三连（真机验证驱动迭代）；**四平台真机验证矩阵全绿**（linuxvm MCP abort/CLI 死亡/孙进程、macvm 孙进程、windowsvm Job Object 整树）；附带修复存量 macOS pty closeFn 5s 隐性延迟（E-state）；v0.18.82 最终态：`set +m; ` 前缀（argv +m 被交互式 shell 覆盖）+ Windows Job Object | ✅ |

**版本混部矩阵**（全安全）: 新 Host+旧 Guest=现行为退化；旧 CLI+新 daemon=探针
无害跳过；新 CLI+旧 daemon=CLI 零改动。零协议消息变更。

## 已完成: Phase 42 — CI 调通 + 发布接管 + MIT LICENSE + SignPath 签名（2026-08-19）

**背景**（证据见 findings.md 2026-08-19 CI 段）:
1. **Release workflow 连续 15+ 次全失败**（每次 tag push 必挂）——根因：
   `build.zig.zon` 声明本地 sibling 依赖 `.zio = .{ .path = "../zio" }`（fixnet-ai/zio
   fork feat/x86-32 分支），CI checkout 后不存在 → `unable to open '../zio': FileNotFound`
   → `zig build test` 阶段即死。仓库 PUBLIC、zio fork PUBLIC 均可直接克隆。
2. **发布双轨撞车**: 本地 release.sh 与 CI 都会创建 GitHub Release，CI 修好后必然冲突。
3. **SignPath OSS 免费代码签名前置缺失**: 仓库无 LICENSE 文件（OSI 许可证是硬性要求）。

**用户裁定（2026-08-19）**:
- LICENSE 用 **MIT**
- 发布 **CI 全接管**（本地只 bump + tag + push；测试/构建/签名/发布全在 CI）
- SignPath **还没申请**——CI 签名步骤先写好，用 repository variable 门控（默认跳过），
  批准后配 secrets + variable 即生效。申请为人工流程（约 1 周），AI 无法代办。

**方案**:

| # | 任务 | 说明 | 状态 |
|---|------|------|------|
| 42A | LICENSE (MIT, fixnet-ai) | SignPath OSS 申请前置 | ✅ |
| 42B | 重写 `release.yml`：clone zio 步骤 + `-Dutmmd=true`（源码即真相，免 stale supervisor guard）+ workflow_dispatch 手动触发（发布步骤仅 tag 时执行）+ SignPath 签名 job（`vars.SIGNPATH_ENABLED` 门控，默认跳过）+ release job 发布签名后产物 | tag → test → 8 目标 → 签名（可选）→ release | ✅ |
| 42C | 新增 `ci.yml`：push/PR 触发 test-only（zig build test + test-integration） | 提前暴露构建问题，不再等到 tag 才发现；public repo macOS runner 免费 | ✅ |
| 42D | release.sh thin 化：只做校验 ver.txt + clean tree + commit + tag(带 notes) + push，删除本地测试/构建/打包/发布/utmmd 模式判定 | utmmd 模式判定随 CI `-Dutmmd=true` 固定而退役 | ✅ |
| 42E | 文档同步：CLAUDE.md Release Process 章节改写（CI 全接管流程 + SignPath 启用清单） | README/MANUAL 若涉发布流程一并核对 | ✅ |
| 42F | 验证：分支 push 触发 ci.yml 绿 → workflow_dispatch 手动跑 release.yml 构建链绿 → 合并 → 真实 tag 端到端发布 | ci.yml 绿 (PR #6, 1m17s)；release.yml 构建链绿 (dispatch 6m30s, sign/release 门控 skip 符合设计, dist artifact 20.8MB)；PR #6 rebase 合并 main (331ee0b)；真实 tag 端到端留待下次发布 | ✅ |

**SignPath 签名设计**（42B 内实现，待用户申请批准后激活）:

```
build job (macos-latest, GitHub 托管 = SignPath OSS 硬性要求)
  → 测试 + zig build cross -Dutmmd=true + 收集 8 二进制 + utmm.zip
  → upload-artifact: dist（全部产物）
sign job（if vars.SIGNPATH_ENABLED == 'true'）
  → download dist → upload-artifact: 3 个 Windows .exe（unsigned）
  → SignPath/github-action-submit-signing-request@v2
      (SIGNPATH_API_TOKEN / SIGNPATH_ORGANIZATION_ID / project=utm-monitor
       / signing-policy=release-signing / wait-for-completion / output-artifact-directory)
  → 签名后 exe 覆盖回 dist → upload-artifact: signed-dist
release job（tag only）
  → download（signed-dist 优先，fallback dist）→ utmm.zip → softprops/action-gh-release
```

**用户侧 SignPath 激活清单**（申请批准后，写入 CLAUDE.md）:
1. signpath.org 提交 OSS 申请（项目 utm-monitor，MIT，公开仓库）
2. SignPath 后台：添加 Trusted Build System "GitHub.com" + 安装 SignPath GitHub App 授权本仓库
3. SignPath 项目配置 Artifact Configuration（zip 根元素内 3 个 `utmm-*.exe`）+ signing policy `release-signing`
4. GitHub repo settings：Secrets 加 `SIGNPATH_API_TOKEN`、`SIGNPATH_ORGANIZATION_ID`；
   Variables 加 `SIGNPATH_ENABLED=true`

**风险**:

| # | 风险 | 对策 |
|---|------|------|
| R1 | CI 构建时长（8 目标 ReleaseSafe + utmmd 重建，估 10-25 分钟） | public repo 免费，无成本问题；tag 发布从即时变异步，deploy 路径不受影响（本地构建） |
| R2 | SignPath GitHub App 未安装时 signing job 误触发 | 门控变量默认不存在 → job 跳过 |
| R3 | CI 重建 utmmd 与仓库 embed 字节不一致（若 Zig 构建非确定） | CI 发布产物以源码重建为准（永远新鲜）；仓库 embed 仅作本地 deploy 路径用途 |
| R4 | release notes 来源变化（原 release.sh 传参） | tag annotation 携带 notes（annotated tag -m），CI release 用 tag message |

## 已完成: Phase 41 — Windows exec 多语言转码 + exit_code marker 修复（v0.18.79，2026-08-19）

**背景**（实测证据见 findings.md 2026-08-19）:
1. **乱码**: 中文系统 winx64 上 exec 输出乱码——老命令（ipconfig 等）无视
   chcp 65001 按 ANSI/OEM(GBK) 输出 → 字节透传 → MCP JSON invalid UTF-8；
   且 chcp 65001 下 cmd 管道 stdin 逐字节解码，UTF-8 中文输入毁成 U+FFFD×N。
   目标机内码不定（中日韩），按内码转码不可行。
2. **exit_code 失真**: `buildCmdWithMarker` Windows 用 `& echo MDELIM:%errorlevel%`
   拼一行——交互式 cmd 整行解析时展开 %errorlevel%（命令执行前）→ marker
   永远报告旧值（实测 `cmd /c exit 7 & echo EXPANDED=%errorlevel%` → 0）。

**最终方案**（pipe + Guest 侧 GetOEMCP 自适应转码）:
cmd.exe /k 会话保持系统本地 OEM 代码页；dpipe_shell readFn/writeFn 做双向
转码（输出 OEM→UTF-8 / 输入 UTF-8→OEM，DBCS/UTF-8 跨块 pending）。
`GetOEMCP()` 对中日韩（936/932/949）自动匹配 → 多语言通解，零环境依赖。
**ConPTY 方案被实测否决**：Session 0 服务链下所有 API 成功但 cmd 拿不到
伪控制台（零输出，5 个实现变体全灭，含微软 EchoCon 精确复刻）；sshd 同
环境工作但机制未复现。详见 findings 2026-08-19。

| # | 任务 | 说明 | 状态 |
|---|------|------|------|
| 41A | marker 修复: Windows 分支 `{s}\r\necho MDELIM:%errorlevel%\r\n`（独立行） | cmd 逐行读取，marker 行展开时上一行已执行完 → 新值 | ✅ |
| 41B | dpipe_shell Windows pipe 模式：去 chcp 65001/LANG + readFn/writeFn OEM↔UTF-8 双向转码（DBCS/UTF-8 跨块 pending） | GetOEMCP 自适应多语言；ConPTY 分支实现后被实测否决删除 | ✅ |
| 41C | （随 ConPTY 否决而取消）stripVtSequences 函数+测试保留在 protocol.zig 备用 | — | ✅ |
| 41D | 单元测试 + 集成测试门禁 | 新增 14 单测（marker 格式 2 + VT 剥离 7 + 转码纯函数 2 + 原有）；229 单元 + 60 集成 0 泄漏 | ✅ |
| 41E | 真机验证 winx64 + windowsvm | ipconfig「以太网」正确 UTF-8、中文输入正确、exit 7/9009/5 传播、&&/\| 回归全过；net user 机器名缺失为无 console 管道固有行为 | ✅ |

**遗留问题**（另行处理）:
| # | 问题 | 说明 |
|---|------|------|
| L1 | `--upgrade` 推送后 utmmd 未实际替换二进制（本次两次复现：ConPTY→转码、转码→诊断版，`[upgrade] OK` 但磁盘 utmm.exe mtime/size 不变） | 排查 utmmd tryApplyPendingUpgrade 链路；期间版本升级一律 scp + `--install` |
| L2 | sshpass.zig 的 runWindowsConpty 属性列表未挂 STARTUPINFOEXW（cb=sizeof(STARTUPINFOW)）——该「ConPTY 模式」从未真正走 ConPTY | sshpass 实际一直走 pipe fallback；修复或删除该分支待定 |
| L3 | 混合编码场景（agent 显式 `chcp 65001 & <cmd>` 后命令输出 UTF-8 会被误按 OEM 转码） | 文档说明；实际 agent 场景罕见 |

## 已完成: Phase 40 — 发布脚本 utmmd 构建模式 + 升级通道约定（v0.18.77）

**状态**: ✅ 完成（用户裁定：utmmd 没变就不更新，避免复杂更新；AI agent 须能自行判断）

| # | 变更 | 说明 |
|---|------|------|
| 40A | release.sh 强制 utmmd 模式参数：`--utmmd`（重建重嵌）/ `--no-utmmd`（复用现有 embed 字节）；缺省打 help（含 AI agent 判定流程） | help 给出决策命令：diff supervisor 源文件 vs `src/embed/UTMMD-BUILT-FROM` |
| 40B | 双重防护：--no-utmmd 时 embed 缺失→报错（新克隆须 --utmmd）；supervisor 源（utmmd/shm/svc.zig）漂移→报错拒绝发旧 supervisor | 溯源文件在每次 --utmmd 构建成功后写入当前 commit |
| 40C | build.zig `-Dutmmd` 选项门控两处构建点（单目标 + cross step），默认 true（裸 `zig build` 行为不变） | -Dutmmd=false 实测 embed 字节级不变（ec2ab207 前后一致） |
| 40D | CLAUDE.md：发布流程写入模式判定规则；**升级通道约定——版本升级一律 `--deploy`**（`--upgrade` 只推 utmm，单独使用致 supervisor 漂移） | Phase 39 教训固化为规范 |

**追加（v0.18.78，同日）**: `extractUtmmd` 字节级比较——磁盘 utmmd 与内嵌字节
相同即跳过重写（--install 幂等无痕）。验证：v0.18.78 --no-utmmd 发布部署后，
两台 Windows VM 的 utmmd.exe **mtime 分毫未动**（23:54:55 / 08:54:53 前后一致）
且哈希 == embed（EC2AB207…）。README/MANUAL 同步升级通道约定与发布模式流程。

**验证**: v0.18.77 以 `--no-utmmd` 发布（守卫放行 `utmmd unchanged since 64f9213`）→
部署后 winx64 utmmd.exe 哈希 == embed 哈希（ec2ab207…逐字节一致，零漂移），
全队 5 节点 v0.18.77 serving。utmmd.exe mtime 变化系 `--install` 的 extractUtmmd
无条件重写同内容字节——内容零变化，服务重启本就是 utmm 更新所必需，无额外复杂度。
附带：两台 Windows VM 的 C:\opt\utmm 历史调试残留（utmm-fix*/v0xx/prev 等 exe +
test/deploy 杂物）按保留清单清理至最小集（utmm/utmmd/ssh*/lock/log）。

## 已完成: Phase 39 — Windows guest 重启循环根因修复 + utmmd 日志治理（v0.18.75/76）

**状态**: ✅ 完成，5 节点 v0.18.76 全收敛

**症状链**: debugLogWindows 热路径写盘（88 B/s）→ 深挖发现 winx64 utmm 每 ≤30s 重启
→ v0.18.75 加事件探针（时间戳 + 心跳超时 hb/now/age）→ 日志实锤
`heartbeat timeout (hb frozen since 0.4s after spawn)` → 代码定位双重根因。

| # | 根因 | 修复 | 版本 |
|---|------|------|------|
| 1 | **Windows 监听 socket 漏设 FIONBIO**（POSIX 有 O_NONBLOCK）→ ws2_accept 永久阻塞 → accept 循环（顶部写 shm 心跳）停摆 → utmmd 10s 超时杀 utmm。LSA 在独立线程照常广播，掩盖了循环 | `makeNonBlocking(s)` + `sockAccept` WSAEWOULDBLOCK→WouldBlock，循环 10Hz 轮转与 POSIX 对齐 | 0.18.76 |
| 2 | **Windows deploy 绕过安装器**（只 move + sc start）→ 内嵌 utmmd 从未提取/更新，自 08-12 起一直旧版（utmm 一直新） | deploy 改跑 `utmm --install --hostname <vm>`（与 POSIX 对齐），forceInstall 含 utmmd 哈希更新 | 0.18.76 |
| 3 | debugLogWindows 无时间戳 + 稳态 trace 刷盘 | 每行 [GetTickCount64 ms] 前缀；删每迭代 trace；致死路径（心跳超时/自退/稳定期死亡）补为可见事件行 | 0.18.75 |

**验证**: winx64/windowsvm PID 40s/30s 采样稳定不变（此前 ≤30s 必死）；utmmd-debug.log
零增长、无 heartbeat timeout 事件；utmmd.exe 时间戳刷新（23:17）；5 节点 0.18.76 serving。
注：`std.time.milliTimestamp` 在 0.16.0 已移除，改 kernel32 GetTickCount64。

## 已完成: Phase 38 — ping/pong 热路径日志 + 过路 pong RTT 错误归因（2026-08-18）

**状态**: ✅ 完成（本机 Host 已部署 v0.18.73 并验证）

**症状**:
1. Host `/private/var/log/utmmd-err.log` 持续增长（曾堆至 625MB，≈33MB/天），
   12 分钟实测 3054 行全部来自 `[lsa] ping/pong` 三类 info 日志
   （pong from 1481 + ping direct 1052 + ping relay fwd 521）
2. 日志出现 `rtt=2997503534ms`（≈34.7 天）垃圾值，同批还夹杂正常 `rtt=1~3ms`

**根因**:
1. 周期探测（periodicTasks 每 ~60 tick 对全部节点 sendPing）+ 每条 ping/pong/中继
   都打 info 级日志 → std.log ReleaseSafe 默认 .info → 全量写 daemon stderr →
   launchd StandardErrorPath。违反日志规范「禁止热路径打印」
2. pong 帧 `[responder_mac:6][timestamp:4]` **无目标字段**：guest A 经 Host 中继
   ping guest C 时，C 的 pong 直接回中继点（`handlePing` 用 `from` 回包）→
   Host `handlePong` 把过路 pong 当自己 ping 的应答，拿 C 回显的 **A 的时钟**
   （guest awake-ms 截断 u32）与 Host 自己的时钟相减 → 开机时长差 15~20 天
   = 垃圾 RTT。且污染 `last_pong_src/rtt/time` → `pingAndWait` 竞态下
   MCP ping 工具会把垃圾 RTT 返回给 AI agent

**修复方案**:

| # | 修复 | 位置 |
|---|------|------|
| 38A | 8 处热路径 info → debug（ping direct/relay/relay fwd/reached target/no route、pong from、LSA restart detected、Ignoring stale high-seq） | lsa.zig:724/736/833/859/888/932/947/966 |
| 38B | `OutstandingPings` 环（64 槽 ts+at+valid，15s 过期，u32 回绕安全）：sendPing 记录（direct+relayed 两路径，锁外记录避免 neighbors→last_pong 嵌套），handlePong 仅接受命中环的 pong，未命中即过路包丢弃 | lsa.zig Mesh + handlePong + sendPing |

**备选否决**: pong 帧加 dst_mac 字段——改线格式，滚动升级新旧混布期间不兼容；
且新 Host 收旧格式 pong 仍需时间戳过滤兜底。ts 环零协议变更、全版本兼容，严格更优。

**验证计划**: OutstandingPings 单元测试（记录/命中/过期/回绕/valid 哨兵）+
`zig build test` + `zig build test-integration` 全绿（部署门禁）+ 本机升级后
观察 utmmd-err.log 增长归零 + `--ping` RTT 恢复个位数毫秒。

**版本**: v0.18.72 → v0.18.73

**追加改进（同日，用户裁定「mesh 探测本不该 info 级落盘」后扩展）**:

| # | 改进 | 理由 |
|---|------|------|
| 38E | 邻居生命周期 info 日志：`handleLsa` getOrPut 首见打 `node up: mac=...`（每状态转换一条，非每 LSA）；`expireStale` 淘汰时打 `node down: mac=... (no LSA > 15000ms)` | 规范语义：info=生命周期事件（连接建立/关闭）。生产可观察 mesh 健康度，天然低频 |
| 38F | 周期 sweep 只 ping **直连邻居**（改遍历 neighbors 表，原遍历 lsas 全表含中继远端） | 中继 ping 的 pong 按设计回中继点不回发起者（pong 无目标字段），发起者永远测不到 RTT——原 sweep 对远端节点的中继 ping 是纯死胡同流量，从未产生过可用测量 |

**追加验证**: 部署后启动日志恰好 4 条 `node up`（每 guest 一条一次性事件）；75 秒完整探测周期稳态零增长（仅 852B 一次性启动事件）；ping 1/1/1/4ms 正常。

**审计结论（无其他刷屏向量）**: host.zig/utmmd.zig 全部 info/warn 为事件驱动（配置加载、进程启停、升级事件）；`handleLsa failed` err 级实为内存分配失败（协议解析失败走 `orelse return` 静默丢弃），级别归属正确，不改。

## 已完成: Phase 37 — macOS utmmd 升级循环 + CLI status 缺失（根因修复）

**状态**: ✅ 完成（commit 9390a50 + 7f6cced）

**症状**: 每次 CLI 管理命令触发 utmmd 升级循环（utmmd/utmm 重启）；
CLI --status 只显示 host；升级推送间歇 IpcNotRunning。

**根因**: macOS 部署流程对 utmmd 做 adhoc codesign（Phase 35 引入），
签名非确定性且 remove-signature 不可逆 → 磁盘 utmmd 哈希永远 ≠ 内嵌
未签名哈希 → `shouldUpdateUtmmd` 永远 true → 每次 CLI 触发完整 upgrade
循环 → mesh 抖动、status 空 guest 表。

**修复**: macOS 上 `shouldUpdateUtmmd` 恒返回 false——macOS 的 utmmd
升级由 `--install`（forceInstall 提取）显式完成。Linux/Windows 保留哈希比较。

**验证**: 连续 3 次 status 零 upgrade 日志；4 台 Guest 完整显示；
Host utmm PID 稳定；4 台 VM 升级推送全部一次成功。

## 已完成: Phase 36 — exec 输出流式化 + download 哈希校验 (v0.18.68 → v0.18.69)

**状态**: ✅ 完成并发布 v0.18.69

**状态**: 🔄 规划完成，待确认后实施

### 背景

三个已知缺陷（详见 findings.md 2026-08-17）：
1. **Bug 1**: Guest 单帧发送全量输出 → Host 64KB 帧缓冲溢出 → stdout 整体丢失 + exit -1
2. **Bug 2**: shell 异常退出（EOF 无 MDELIM）时 Guest 丢弃已累积输出
3. download 方向无端到端哈希校验（与 upload 不对称）

### 架构决策（用户已确认，2026-08-17 修订）

| # | 决策 | 理由 |
|---|------|------|
| D1 | exec 输出 **流式分块发送**：Guest 每 4KB 读块立即发帧，仅保留 ≤7B 尾部（可能是 MDELIM: 前缀） | 帧大小与输出总量解耦，修 Bug 1；执行中输出实时可见 |
| D2 | **同步响应模型**：CLI 和 MCP 都是一次调用拿完整输出。MCP 同步全量响应；CLI 通过 IPC **流式转发**（边收边发 exec_data 帧，收完发 exec_done） | 用户修订：两段式（session_id + 轮询）让 AI agent 无所适从（不知何时有数据）。实时性 = 底层流式传输，不是交互层异步 |
| D3 | **不做**落盘/spool/会话表/read_output 工具/TTL | 用户修订：落盘动机只是"缓冲不够"，36B 流式分块后已无单帧 64KB 问题；Host 端 ArrayList 动态无上限（天然优于固定 128MB 上限）。同步响应下全量在内存是模型固有属性，用户拍板接受 |
| D4 | download 哈希校验采用 **头帧**（file_size + sha256）而非 trailer | 原始字节流中任意 4 字节都可能像帧头，长度先行则数据边界精确；与 upload 对称 |

### 子阶段

#### Phase 36A: download 端到端哈希校验 ✅ 完成

- [x] `protocol.zig`: `download_result = 0x1c` + `buildDownloadResult` + `parseDownloadResult` + `DownloadResultData`（commit 1196e1e）
- [x] `guest.zig` handleDownload: stat → hash pre-pass → 发 download_result → 流式发原始字节（commit 18ed965，与 36B 同 commit 混入）
- [x] `mcp_handler.downloadFromGuest` + `ipc.zig` download 路径: 收帧 → 增量 SHA256 → 读满 file_size → 比对（HashMismatch / TruncatedDownload）
- [x] 测试: round-trip 单元测试；集成测试（正确哈希 + 篡改不匹配，download 四项全过）
- [x] 门禁: zig build test exit 0 + 60 集成通过 0 泄漏

#### Phase 36B: Guest 流式分块 + Bug 2 修复 + Host 防御（Bug 1 修复）✅ 完成

- [x] `guest.zig` handleExecCmd: 流式分块（partialMarkerKeepLen 保留 ≤6B 尾部）+ EOF/错误路径补发 accumulated + done(-1)（commit 18ed965）
- [x] `mcp_handler.execOnGuest`: BufferTooSmall 改 panic；ConnectionClosed 保持 break
- [x] 测试: partialMarkerKeepLen 单元测试 3 个 + >64KB 大输出 e2e 场景
- [x] 门禁: 218 单元 + 60 集成通过
- [x] 追加修复: test_upload_e2e 二进制 hash 传参 → hex（commit dfa863b）

#### Phase 36C: CLI exec 流式转发（修订版）✅ 完成

- [x] `mcp_handler.zig`: 新增 `execOnGuestStream(io, gpa, state, vm, command, on_output, ctx)`——
  每块 pty_exec_output 立即回调；execOnGuest 变薄为 OutputCollector 封装（commit 9ad72e5）
- [x] `ipc.zig` handleExec: ExecIpcSink 回调逐块发 exec_data IPC 帧（broken 标志处理 CLI 断开），收完发 exec_done
- [x] `ipc.zig` ipcExec 客户端: 流式解析响应帧（exec_data 边读边写 stdout + flush，不再 clientReadAll 全量缓冲）
- [x] 测试: ExecIpcSink 帧编码单元测试
- [x] 修复存量问题: ipc.zig 加入 build.zig standalone_test_modules（原 6 个 ipc 测试从未运行过）
- [x] 门禁: 218 单元 + 7 ipc standalone + 60 集成通过，0 泄漏

#### Phase 36D: 测试更新 + 全量验证 + 部署 ✅ 基本完成（release 待发）

- [x] 交叉编译 8/8 目标（ReleaseSafe，含交叉编译错误修复 689243c/7c3a426）
- [x] 版本 bump v0.18.69（7f07273）
- [x] 全节点部署：Host + 4 VM 全部 v0.18.69 serving
- [x] 真机验证：
  - CLI exec 流式（START 在 sleep 5 期间实时到达终端）
  - exec >64KB 输出完整（linuxvm seq 1 20000 md5 与本地一致）
  - download 端到端哈希（CLI + MCP 双路径 md5 一致，linuxvm/windowsvm 4.97MB）
  - Windows 双平台 exec + download 正常
- [x] 真机抓出悬空切片 bug 并修复（ebca5ce）+ 重新部署 Host 验证
- [ ] tag v0.18.69 + release.sh 发布
- [ ] push main + tags

#### Phase 36D: 测试更新 + 全量验证 + 部署

- [ ] 集成测试: exec 异步（running → done 状态转换、offset 分段读取、结束后读全量）
- [ ] `tests/test_mcp_tools.py` 更新: exec 改为异步流程（exec → 轮询 read_output）
- [ ] `tests/test_cli_commands.py` 确认 CLI 同步路径不变
- [ ] `zig build test` + `zig build test-integration` 全绿（部署门禁）
- [ ] 交叉编译 8 目标 + 真机部署验证（macvm/linuxvm/windowsvm/winx64）
- [ ] 版本 bump + release

### 风险与已知限制

| # | 风险 | 对策 |
|---|------|------|
| R1 | 同步响应模型下 Host 端输出全量在内存（超大输出吃内存） | 用户拍板接受：ArrayList 动态无上限，现实输出远小于该量级 |
| R2 | IPC 流式转发下每块一帧，帧数多（4KB 块） | IPC 帧头开销小（5B/帧），CLI 读取循环已有流式协议支持 |
| R3 | 二进制/非 UTF-8 输出在 JSON 响应中的处理 | 沿用 jsonEscape 既有行为（与现状一致） |

## 已完成: Phase 35 — 三平台自动升级彻底打通 (v0.18.44 → v0.18.68)

**状态**: ✅ 完成，5 轮自动升级压力测试全通过

本次会话从 4 个预存 Bug 出发，逐步挖出并修复了自动升级链路上的多个跨平台 bug，
最终实现 Linux/macOS/Windows 三平台 `--upgrade` 自动升级全部可靠工作。

| # | 任务 | 状态 | 版本 |
|---|------|------|------|
| 1 | O_NONBLOCK 跨平台修复（Linux 心跳超时 crash-loop 根因） | ✅ | v0.18.45 |
| 2 | macOS forceInstall 无条件 codesign（SSH 部署后签名损坏） | ✅ | v0.18.45 |
| 3 | SHM restart 处理不杀 utmm（升级失败不中断服务） | ✅ | v0.18.46 |
| 4 | 升级连续失败计数器（防无限重试） | ✅ | v0.18.46 |
| 5 | ensure 重试用 usleep（isRunning 检测 init.io 上下文失败） | ✅ | v0.18.48 |
| 6 | SHM cmd_data 路径机制（绕过 findUpgradeTmp 目录扫描） | ✅ | v0.18.52 |
| 7 | readCmdPath 去掉 '/' 检查（Windows C:\ 路径被拒） | ✅ | v0.18.58 |
| 8 | @atomicStore 跨进程可见性（SHM 路径写） | ✅ | v0.18.59 |
| 9 | Windows SHM 不关闭 CreateFileMappingW 句柄（名字被移除根因） | ✅ | v0.18.61 |
| 10 | Windows 升级流程重设计（PID 精准杀 + taskkill 兜底） | ✅ | v0.18.54 |
| 11 | utmmd 自升级流程（disable→stop→kill→replace→enable→start） | ✅ | v0.18.56 |
| 12 | 5 轮自动升级压力测试（v0.18.64→68，全部追平） | ✅ | v0.18.68 |

## 已完成: Phase 34 — POSIX findUpgradeTmp Threaded Io 修复 + 全节点升级验证

**状态**: ✅ 完成 (v0.18.35)

| # | 任务 | 状态 |
|---|------|------|
| 1 | 发现 POSIX need_threaded bug（io 复用导致 openDirAbsolute 静默失败） | ✅ |
| 2 | utmmd.zig: 所有平台始终创建 Threaded Io 进行文件操作 | ✅ |
| 3 | Windows utmmd 崩溃恢复（sc.exe start 手动重启） | ✅ |
| 4 | linuxvm TCP 服务崩溃恢复（utmctl stop/start 重启 VM） | ✅ |
| 5 | 全节点升级到 v0.18.34 并验证 exec | ✅ |

## 已完成: Phase 33 — Windows --upgrade 二进制替换崩溃修复

**状态**: ✅ 完成并验证 (v0.18.33)

### Phase 33: 核心修复 (v0.18.2)

| # | 任务 | 状态 |
|---|------|------|
| 1 | Windows: 重命名旧 exe + 放置新 exe（MoveFileExW 替代 deleteFile+rename） | ✅ |
| 2 | 修复进程句柄管理：defer closeProcessHandle 统一清理 | ✅ |
| 3 | handleUpgradeCmd 通过 shm 通知 utmmd | ✅ |
| 4 | macOS codesign 修正（rename 后统一执行） | ✅ |
| 5 | 测试 | ✅ 216 unit + 59 integration passed |

### Phase 33.5: findUpgradeTmp 固化 (v0.18.33)

| # | 任务 | 状态 |
|---|------|------|
| 6 | svc.zig findUpgradeTmp 重写为 FindFirstFileW 实现 | ✅ |
| 7 | utmmd.zig 清理 inline findUpgradeTmp 调试代码 | ✅ |
| 8 | WIN32_FIND_DATAW struct 布局修正 (u32 对 替代 u64) | ✅ |
| 9 | build.zig: Windows utmmd 使用 Debug 优化 | ✅ |
| 10 | guest.zig: discardBytes 消费同版本跳过时的二进制流 | ✅ |
| 11 | host.zig: 推送前同版本检测 | ✅ |
| 12 | Windows 真机端到端验证 (windowsvm v0.18.30→0.18.33 自动升级) | ✅ |

## 关键设计决策（持续有效）

| # | 决策 | 理由 |
|---|------|------|
| 1 | TCP per-command 连接 | 无跨线程共享状态 |
| 2 | DuplexPipe vtable 抽象 | 可扩展、可测试 |
| 3 | 单二进制双模式（Guest/Host） | 减少维护 |
| 4 | 自复制安装模型（stop→kill→copy→start） | 网络无关，零脚本 |
| 5 | SOCKS5 Hub-Spoke（Host 唯一中转） | 简单拓扑，无环路 |
| 6 | MDELIM 退出码标记 | 跨 shell 兼容 |
| 7 | deploy.json 配置文件 | 外部用户无需改源码 |
| 8 | serve-dir 缓存跳过编译 | --deploy 首次编译后零开销 |
| 9 | HTTP MCP 嵌入 Host Daemon | 消除 IPC 桥接、空闲超时、缓冲区截断 |
| 10 | 首字节协议分发（0x05/ASCII→HTTP） | 单端口承载 SOCKS5 + HTTP MCP |
| 11 | mcp_handler 共享业务逻辑 | HTTP MCP 和 IPC handler 零重复 |
| 12 | Windows 文件扫描用 FindFirstFileW（不用 Zig Io walker） | Threaded Io 不支持 Windows 目录迭代 |
| 13 | WIN32_FIND_DATAW FILETIME 用 u32 对（不用 u64） | aarch64-windows align=8 会偏移 cFileName |
| 14 | Windows utmmd 用 Debug 优化 | 避免 ReleaseSafe/ReleaseSmall 交叉编译 bug |
| 15 | 所有平台文件 I/O 必须用 Threaded Io | 事件循环 Io（epoll/kqueue/IOCP）不支持文件操作，POSIX 复用 io 导致 findUpgradeTmp 静默失败 |
| 16 | 升级 .tmp 全路径通过 SHM cmd_data 传递 | 绕过 findUpgradeTmp 目录扫描（Windows Threaded Io walker 不支持） |
| 17 | SHM 跨进程共享内存用 @atomicStore/Load | @memcpy 对 *volatile 可能被优化掉，跨进程不可见 |
| 18 | Windows SHM 不关闭 CreateFileMappingW 句柄 | 关闭句柄会移除命名对象名字，utmm 打开失败 |
| 19 | utmmd 自升级用强杀（killAllUtmm 跳过 self） | 不用 stop() 优雅停止，避免触发 utmmd shutdown 回调杀 utmm |
| 20 | exec 输出流式分块发送（Guest 4KB 块 + ≤6B 尾部保留） | 帧大小与输出总量解耦，修 >64KB 输出丢失；执行中实时可见 |
| 21 | download 校验用头帧（download_result: file_size + sha256_hex） | 原始字节流无法可靠区分 trailer 帧头；长度先行边界精确，与 upload 对称 |
| 22 | exec 同步响应模型（CLI 经 IPC 流式转发；MCP 同步全量） | 两段式（session_id + 轮询）让 AI agent 无所适从；实时性 = 底层流式传输 |
| 23 | macOS shouldUpdateUtmmd 恒 false（utmmd 升级靠 --install） | adhoc codesign 非确定且不可逆，磁盘哈希永远 ≠ 内嵌哈希；比较必触发升级循环 |

## 架构（v0.18.0+）

```
Application:  guest.zig / host.zig / ipc.zig / mcp.zig / mcp_handler.zig / mcp_http.zig / sshpass.zig
Topology:     lsa.zig / arp.zig
Transport:    tcp.zig / socks5.zig
Data Pipe:    dpipe.zig / dpipe_shell.zig / dpipe_file.zig
Protocol:     protocol.zig
System:       svc.zig / utmmd.zig / shm.zig
Foundation:   main.zig / fail.zig / config.zig
```
