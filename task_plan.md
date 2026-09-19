# Task Plan — UTM Monitor

**版本**: v0.18.92 | **分支**: `main` | **更新**: 2026-09-14

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts；交叉编译 8/8 通过（aarch64/x86_64/x86 × 3 OS）
- **真机部署**: 5 节点 v0.18.92 serving（utmmd 自愈后全部匹配 embed）
- **Phase 45**: 遗留 L2 sshpass Windows ConPTY 假模式（正解 SSH_ASKPASS）— 45G 修复完成待发布/部署/补验
- **Phase 46 完成**: utmmd 自愈（utmm `--svc` 启动自检磁盘 utmmd 哈希，不符则替换重启，v0.18.90）
- **Phase 47**: 本地交叉编译发布 v0.18.90 + 5 节点自愈验证已完成；连续 bump 验证 --upgrade 流畅性待续
- **Phase 48 / 49 已完成**（v0.18.91 已 rollout）: utmmd IP 指纹误杀修复 + macOS 构建期正式代码签名（utmm/utmmd，替代 adhoc）；**Phase 50 完成并发布**: 服务角色一致性守卫（单名 + 角色探测）— v0.18.92 已 tag + CI 发布，5 节点已部署（2026-09-14）

## 未完成任务（最高优先级，勿丢）

| # | 待办 | 说明 | 状态 |
|---|------|------|------|
| 1 | **45G 发布 + 部署 + Windows Host 切换补验** | v0.18.84 修复（MCP download flush + sshpass tempDir）已 commit ad93aea，ver.txt→0.18.84；待发布 + 部署 + Windows Host 模式 MCP sshpass（Session 0 已由 exec 通道验证，切换 host 部署后补验） | 🔲 待办 |
| 2 | **Phase 47 连续 bump 验证 --upgrade 流畅性** | v0.18.85 起连续 bump 压测自动升级链路（45H 后续）；Windows 1067 已修，验证升级全流程 | 🔲 待办 |
| 3 | **SignPath 签名激活** | CI sign job 已写（`vars.SIGNPATH_ENABLED` 门控默认跳过）；OSS 申请批准后配 secrets/variables（激活清单见 Phase 42 段） | 🔲 待用户申请 |
| 4 | **zio PR #646 上游合并** | fixnet-ai/zio feat/x86-32 合并后 build.zig.zon 从本地 path 切 URL | 🔲 待上游 |
| 7 | **installMacOS bootstrap 缺成功校验** | 2026-09-14 macvm 观察到：`--uninstall` 后立刻 `--install`，服务未被拉起（`launchctl` 无 `com.utmmd`、无进程），`killall` 后重装才恢复。`start()` 有 3 次重试 + `launchctl list` 校验，`installMacOS()` 的 bootstrap 却只 `_ = runCmd(...)` 不看结果 → 建议把校验/重试复用到 install() | 🔲 待办 |
| 8 | **release.yml Release 正文近乎空** | `generate_release_notes: true` 致 GitHub 自动正文只剩 Full Changelog 链接（curated notes 只落在 annotated tag）；待改用 tag message 作正文，或每次发布后 `gh release edit --notes-file` 补正文 | 🔲 待办 |

## 已完成: Phase 50 — 服务角色一致性守卫（单名 + 角色探测，2026-09-14）

**状态**: ✅ 完成并发布 **v0.18.92**（tag + CI 发布，5 节点已部署）| **触发**: 用户 review 裁定「host/guest 共用服务名导致角色混淆」= 功能错误

**根因（代码证据，非推测）**: ① `isRunning(role)` 角色盲——macOS host 分支走 `checkServicePort()`（自注 Host/Guest 均监听 2121，svc.zig:842/910-962），guest 在跑也让 host 判 true；其余分支按不分角色的服务名匹配；② `install()` 无角色一致性检查（svc.zig:968-970 自注 "Always overwrites"）→ `utmm --host --install` 在 guest 机器上静默改角色；③ `stop/uninstall/disable` 的 role 参数被丢弃（svc.zig:1254/1485/2223，死参数）；④ `--host` 双来源（main.zig:875 + utmmd.zig:76）→ 实测 argv `utmm --svc --host --host`；⑤ `killAllUtmm()` 按进程名无差别杀（单名设计下属可接受）。

**决策（用户裁定 2026-09-14）**
- 服务标识：**单名 + 角色探测** —— 保留 `com.utmmd` / `/opt/utmm/utmmd`，改动集中在 svc.zig，
  不触碰 deploy/upgrade/serve-dir 与已有部署。
- 角色冲突：**显式切换 / 隐式拒绝** —— 显式 `--host` 允许自动切换；隐式 guest 默认与只读管理
  命令一律拒绝（不静默降级 host）。

**改动清单（全 ✅）**: svc.zig `roleFromConfigText()` / `installedRole()` 三平台读取（plist / unit ExecStart / `sc qc`）+ `roleConflict()`；`isRunning` 拆 `isServiceUp()` 叠加角色判定（配置读不到 → 保持旧行为防回归）；`stop()` 角色不符记日志；main.zig 三处守卫（显式 `--host` 切换 / 管理命令拒绝 / `--install` 告警）+ `buildServiceArgs` 去冗余 `--host`（单一来源 = utmmd）；新增解析器单测 7 条。

**验证（2026-09-14，本机 macOS / 现行 host 服务）**: `zig build test` 冷编译 **18/18 steps succeeded**、237 passed / 1 skipped / **0 failed**（连跑 3 次一致）；本机实测裸 `utmm`（隐式 guest）**拒绝**并给出指引、`utmm --mcp` 正常识别 host 已在跑；plist sha256 前后一致、服务未重启；全仓无「裸 `utmm`」调用（deploy 一律 `--install [--hostname]`，`utmm sshpass …` 在角色逻辑之前返回）。

**VM 回归（v0.18.92，5 节点全量部署）**: host + 4 guest 全部 serving、`--exec` 四台全通；角色探测三平台全对（linuxvm systemd unit ExecStart / macvm launchd plist / windowsvm+winx64 `sc qc` binPath，均正确识别 `guest` 并拒绝）；角色切换 macvm 实测通过（plist `guest`→`host`，argv 去重为 `utmm --svc --host`）后 `--uninstall` + `--deploy macvm` 恢复回 guest 重新入网；Windows 控制台 em-dash 乱码改 ASCII 后复验干净。

**观察（非本次改动引入 → 未完成任务表 #7）**：macvm 恢复时 `--uninstall` 后立刻 `--deploy`，首次 `--install` 未把服务拉起来（`launchctl` 中无 `com.utmmd`）；先 `killall utmm utmmd` 再 `--install` 即恢复。根因指向 `installMacOS()` 的 `launchctl bootstrap` **无成功校验**（`start()` 有 3 次重试+校验，install 没有）。与本次改动无关：`isRunning` 经本次修改只会**更严格**，不可能把「未运行」判成「已运行」。

⚠️ **仍未覆盖**：Linux/Windows 的角色切换（`--host` 自动重装）——仅 macvm 实测了切换路径；其余两平台验证的是角色**探测**（拒绝路径）。

> 注：`zig build test` 输出的 `failed command: <path>` 行是构建系统噪音，判定以 Build Summary + exit code 为准。

## 已完成: Phase 45 — 遗留 L2: sshpass Windows ConPTY 假模式（v0.18.83+）

**状态**: ✅ 45A-45F/45H 完成；服务链正解 **45D'（SSH_ASKPASS + NUL stdin，runWindowsAskpass）** 2026-08-22 windowsvm 真机全场景通过；**45G 修复完成待发布**（未完成任务表 #1）。证据链见 findings.md「Windows Host 服务链 sshpass 正解」。

**根因与正解**: runWindowsConpty 的 startup_info 是裸 STARTUPINFOW（cb=68），lpAttributeList 从未挂进 STARTUPINFOEXW → CreateProcessW 带 EXTENDED_STARTUPINFO_PRESENT + cb 不符 → ERROR_INVALID_PARAMETER 直接失败（deploy Windows VM 走 macOS Host runPosix 不受影响，故自 v0.18.0 引入以来从未暴露）。45D 真机结论：ConPTY 与管道模式在 Session 0（无交互窗口站）均不可用，唯一断点 = 密码交互；深挖推翻前提：Win32-OpenSSH sshpty.c `WIN32_FIXME` 分支根本不用 ConPTY（stdin/stdout 直通），复现 OpenSSH ConPTY 是死路 → 正解 = SSH_ASKPASS + stdin EOF（完全避开 TTY/ConPTY，根治「认证成功后退出挂起」，Win32-OpenSSH issue #1769/#1427）；实施 45D'：`hasConsole()` 检测 → ssh 命令恒走 runWindowsAskpass（SSH_ASKPASS/SSHPASS env + NUL stdin + 读输出回传 + 退出码透传 + Permission denied→exit 5），非 ssh 命令有控制台+ConPTY → runWindowsConpty。

**用户裁定（2026-08-22）**: ① Windows 必同时承担 Host/Guest 角色，ConPTY 是交互桌面会话主要路径（非删除）；② 老 Windows（< 1809 无 CreatePseudoConsole）按版本判断走非 ConPTY；③ 老 Windows 不能运行 Host 模式（启动检测提示后退出）；④ 服务链 ConPTY 问题先修后定（分阶段）。

**实施步骤表（精简）**:

| # | 任务 | 状态 |
|---|------|------|
| 45A-C | ConPTY 附加修复（STARTUPINFOEXW+cb+lpAttributeList）/ 老 Windows 分层（<1809 走 pipe、Host 启动检测退出）/ 交叉编译 + 门禁 | ✅ 230 单测 + 62 集成全绿 |
| 45D-D'' | 单机验证定位 Session 0 密码交互死点 → **45D' SSH_ASKPASS 正解**（runWindowsAskpass + .pass dupe 修复）windowsvm 真机全通过（RC=0/5/255/多行/RC=7）+ 门禁无回归 | ✅ |
| 45E-F | winx64 第二台验证 + MCP sshpass 全路径 + v0.18.83 发布部署 | ✅ 5 节点全 v0.18.83 serving；Windows Host 模式补验并入待办 #1 |
| 45G | v0.18.84：MCP download flush+sync（0 字节）+ sshpass tempDir（/tmp 硬编码） | 🔲 修复完成（commit ad93aea，门禁全绿），待发布+部署+Windows Host 切换补验 |
| 45H | Windows utmmd 反复崩溃 1067：GetAdaptersAddresses 栈踩踏 + panic 钩子 | ✅ windowsvm/winx64 RUNNING、PID 稳定、无 PANIC |

## 已完成: Phase 46 — utmmd 自愈（v0.18.90，2026-08-22）

`--upgrade` 只推 utmm、从不推 utmmd → 用户指令：utmm 启动后若磁盘 utmmd 哈希与内嵌不符，立即停服替换再启服（main.zig `--svc` 5a 块，shm.open 前；macOS 恒 false 自动跳过 = 决策 #23）。闭环：升级一次无循环 / 端口 shm 无冲突 / replace 失败回滚旧 utmmd / monitorLoop 指数退避 + MAX_FAILURE_COUNT=5 兜底。验证：test 230 + 集成 62 全绿；5 节点自愈后 utmmd 哈希全部匹配 embed。

## 已完成: Phase 49 — macOS 构建期正式代码签名（utmm/utmmd，替代 adhoc，2026-09-11）

**关键约束**: ① 证书同名双本（旧 EF2B.../续期 A9AA...）按名称签名 ambiguous 失败 → 自动探测按**哈希**取；② utmmd 必须**嵌入前**签名（embed=磁盘字节一致 → utmmd.sha256 一致）；③ 运行期 adhoc 重签点（5 处）改**先验签后重签**（svc.codesignValid），否则构建期正式签名被覆盖降级。

**完成（49A-49F 全 ✅，v0.18.91）**: build.zig `-Dsign-identity` 解析链（显式→env UTMM_CODESIGN_IDENTITY→自动探测 Developer ID/Apple Development→adhoc 兜底）+ utmmd 嵌入前签名；门禁 230 单测 + 62 集成全绿；本机部署 /opt/utmm 双二进制保留 TeamIdentifier 签名（字节一致）；v0.18.91 本地发版 + 5 节点 rollout 全 serving；49F 修 deploy.json 缺失 + VM_DEPLOY_TABLE IP 过期（macvm 65.4→64.4，`/opt/utmm/deploy.json` 已建为 IP 漂移正解通道；macvm sshd 曾不在监听，经 mesh exec bootstrap 恢复）。

**实施要点**: ① installArtifact 的 Copy 与签名步骤是并行兄弟，必须 `addInstallArtifact` + 显式 `dependOn(sign)`，否则可能拷出未签产物；② codedb 搜索漏过 selfCopy 重签点，改码后必须全量复查 `codesign` 触点；③ 本项目 `standardOptimizeOption` 无默认值，本机部署必须显式 `-Doptimize=ReleaseSafe`（Phase 48 曾误部署 Debug 版，49D 已纠正）。

**证书现状**（2026-09-11 实测）：`A9AADC7D32C15F9C7DD77A58A68C83663796D48A` "Apple Development: ***@163.com (GXX2L7J5WB)" 续期版、2027-09-10 到期（推荐）；同名旧证 2027-07 到期仍有效。无 Developer ID 证书——Apple Development 签名对本 mesh 直推部署（无 quarantine）足够；对外分发需 Developer ID + 公证。

## 已完成: Phase 48 — 本机 macOS utmm 服务自动停止排查（2026-09-11）

**结论**: ✅ 48A-48G 全部闭环；v0.18.91 已全舰队 rollout。

**根因**（证据链见 findings.md「Phase 48」）: ① **utmmd IP 指纹误杀**——指纹覆盖所有接口 IPv4（含 UTM bridge/utun/awdl，随睡眠/VM 挂起翻转）+ 去抖基线永不采纳（IP_STABLE_CHECKS=2 → 20s 即杀、计数器不回零）→ 日志实证 147 次重启 / 40-52s 连环 kill cycle；② **Claude Code stdio MCP 残留配置**——`~/.claude.json` 仍为 pre-v0.18.0 stdio 注册，`--mcp` 现只打印 endpoint 秒退 → MCP 必连不上（独立于 ①）。

**48G 长期观察**: 部署后 10.5h（含整夜 Maintenance Sleep/DarkWake 循环）IP-change 误杀 0、heartbeat timeout 0、utmm 重启 0，PID 稳定。

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
| 15 | 所有平台文件 I/O 必须用 Threaded Io | 事件循环 Io（epoll/kqueue/IOCP）不支持文件操作 |
| 16 | 升级 .tmp 全路径通过 SHM cmd_data 传递 | 绕过 findUpgradeTmp 目录扫描 |
| 17 | SHM 跨进程共享内存用 @atomicStore/Load | @memcpy 对 *volatile 可能被优化掉 |
| 18 | Windows SHM 不关闭 CreateFileMappingW 句柄 | 关闭句柄会移除命名对象名字 |
| 19 | utmmd 自升级用强杀（killAllUtmm 跳过 self） | 避免触发 utmmd shutdown 回调杀 utmm |
| 20 | exec 输出流式分块发送（Guest 4KB 块 + ≤6B 尾部保留） | 帧大小与输出总量解耦，修 >64KB 输出丢失 |
| 21 | download 校验用头帧（download_result: file_size + sha256_hex） | 原始字节流无法可靠区分 trailer 帧头；与 upload 对称 |
| 22 | exec 同步响应模型（CLI 经 IPC 流式转发；MCP 同步全量） | 两段式让 AI agent 无所适从；实时性 = 底层流式传输 |
| 23 | macOS shouldUpdateUtmmd 恒 false（utmmd 升级靠 --install） | adhoc codesign 非确定且不可逆，磁盘哈希永远 ≠ 内嵌哈希 |
| 24 | utmmd 自愈：utmm `--svc` 启动早期自检磁盘 utmmd 哈希 | utmm 内嵌 utmmd 知道正确版本；`--upgrade` 只推 utmm 从不推 utmmd，让 utmm 启动时自愈替换（v0.18.90） |

## 历史完成阶段总表（阶段 27-44，细节以 git log 为准）

| 阶段 | 标题 | 一句话结果 | 锚点 |
|------|------|-----------|------|
| 27 | VM 离线根因修复 | installLinux 缺 systemd Restart + 心跳超时误判（acceptRaw 内层循环）+ Windows 堆损坏 | git log v0.17.7-17.21 |
| 33 | Windows --upgrade 崩溃修复 | MoveFileExW 先 rename 旧→.old 再 rename 新→目标 + 句柄管理生命周期 | v0.18.33 |
| 33.5 | findUpgradeTmp 固化 | FindFirstFileW + WIN32_FIND_DATAW u32 对（aarch64 布局修正）+ Windows Debug 优化 | v0.18.33 |
| 34 | POSIX findUpgradeTmp Threaded Io 修复 | 事件循环 Io 不支持文件操作 → 全平台 Threaded Io；全节点升级验证 | v0.18.35 |
| 35 | 三平台自动升级彻底打通 | O_NONBLOCK/macOS codesign/SHM restart/失败计数/@atomicStore/CreateFileMappingW 句柄 12 项修复，5 轮压测 | v0.18.44-68 |
| 36 | exec 流式化 + download 哈希校验 | 4KB 流式分块修 >64KB 丢失；download_result 头帧端到端校验；CLI IPC 流式转发 | v0.18.69 |
| 37 | macOS utmmd 升级循环 + CLI status 缺失 | adhoc codesign 非确定 → shouldUpdateUtmmd macOS 恒 false（决策 #23） | v0.18.72 |
| 38 | ping/pong 热路径日志 + 过路 pong RTT 归因 | 8 处热路径 info→debug；OutstandingPings 环归属验证（pong 无目标字段） | v0.18.73 |
| 39 | Windows guest 重启循环双根因 + 日志治理 | Windows 监听 socket 漏设 FIONBIO（心跳冻结）+ deploy 绕过安装器 | v0.18.75/76 |
| 40 | 发布脚本 utmmd 构建模式 + 升级通道约定 | release.sh --utmmd/--no-utmmd 双模式 + build.zig -Dutmmd gate；升级一律 --deploy | v0.18.77 |
| 41 | Windows exec 多语言转码 + marker 修复 | pipe + GetOEMCP 双向转码（ConPTY 5 变体 Session 0 否决）；MDELIM 独立行 | v0.18.79 |
| 42 | CI 调通 + 发布接管 + MIT + SignPath | ../zio 本地依赖 CI 缺失根因；release.yml 重写 + ci.yml + SignPath 门控；docs 主页 | PR #6 → 331ee0b |
| 43 | exec 断连取消传播 + 进程树整杀 + Guest 并发化 | 零长探针 + `set +m; ` 前缀 + Job Object；macOS E-state 收割 | v0.18.80-82 |
| 44 | MCP 长任务超时修复 | SSE 流 + progress 心跳（mcp_http.zig 层复刻 zigtester 模式） | ca5941e → v0.18.83 |

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
