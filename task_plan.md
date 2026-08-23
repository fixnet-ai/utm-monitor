# Task Plan — UTM Monitor

**版本**: v0.18.90 | **分支**: `main` | **更新**: 2026-08-23

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点 v0.18.90 serving（utmmd 自愈后全部匹配 embed）
- **Phase 45 进行中**: 遗留 L2 — sshpass Windows ConPTY 假模式（已正解为 SSH_ASKPASS，45G 待发布/部署/补验）
- **Phase 46 完成**: utmmd 自愈 — utmm `--svc` 启动自检磁盘 utmmd 哈希，不符则替换重启（v0.18.90）
- **Phase 47 进行中**: 本地交叉编译发布 v0.18.90 + 5 节点自愈验证（已完成）；连续 bump 验证 --upgrade 流畅性待续

## 未完成任务（最高优先级，勿丢）

| # | 待办 | 说明 | 状态 |
|---|------|------|------|
| 1 | **45G 发布 + 部署 + Windows Host 切换补验** | v0.18.84 修复（MCP download flush + sshpass tempDir）已 commit ad93aea，ver.txt→0.18.84；待发布 + 部署 + Windows Host 模式 MCP sshpass（Session 0 已由 exec 通道验证，切换 host 部署后补验） | 🔲 待办 |
| 2 | **Phase 47 连续 bump 验证 --upgrade 流畅性** | v0.18.85 起连续 bump 压测自动升级链路（45H 后续）；Windows 1067 已修，验证升级全流程 | 🔲 待办 |
| 3 | **SignPath 签名激活** | CI sign job 已写（`vars.SIGNPATH_ENABLED` 门控默认跳过）；OSS 申请批准后配 secrets/variables（激活清单见 Phase 42 段） | 🔲 待用户申请 |
| 4 | **zio PR #646 上游合并** | fixnet-ai/zio feat/x86-32 合并后 build.zig.zon 从本地 path 切 URL | 🔲 待上游 |
| 5 | **Windows BIND 防火墙** | OS 限制，文档已注明，无需代码修复 | ⏸ 已知限制 |
| 6 | **upsert() MAC 变化** | 仅 cosmetic，路由用 LSA node_id | ⏸ 低优先级 |

## 进行中: Phase 45 — 遗留 L2: sshpass Windows ConPTY 假模式（v0.18.83+）

**状态**: ✅ 45A/45B/45C 完成；45D 验证完成 → 服务链处置已实施 **45D'（runWindowsAskpass）**，2026-08-22 windowsvm 真机验证全场景通过；45E/45F 完成；**45G 修复完成待发布**；45H 完成。

**背景**（证据链见 findings.md「Windows Host 服务链 sshpass 正解」）:
runWindowsConpty 的 startup_info 是裸 STARTUPINFOW（cb=68），lpAttributeList
从未挂进 STARTUPINFOEXW → CreateProcessW 带 EXTENDED_STARTUPINFO_PRESENT +
cb 不符 → **ERROR_INVALID_PARAMETER 直接失败**。实测 `utmm sshpass` spawn 任何
子进程立即失败；MCP sshpass 在 Windows Host 同样失败。deploy Windows VM 走
macOS Host runPosix 不受影响（故自 v0.18.0 引入以来从未暴露）。

**用户裁定（2026-08-22）**:
1. Windows 必同时承担 Host/Guest 角色，ConPTY 是交互桌面会话主要路径（非删除）。
2. 老 Windows（< 1809 无 CreatePseudoConsole）按版本判断走非 ConPTY。
3. 老 Windows 不能运行 Host 模式——启动时检测到无 ConPTY 则提示后退出。
4. 服务链 ConPTY 问题先修后定（分阶段）。

**45D 真机验证关键结论（windowsvm v0.18.83 修复版）**:
- 45A 修复已生效：CreateProcessW + ConPTY 附加成功（连拒绝端口 RC=255 非 3）。
- **ConPTY 在 Session 0（无交互窗口站）不可用**：附加后整个 SSH 会话/通道阻塞挂起。
- **管道模式在 Session 0 同样不可用**：ssh.exe 无 TTY 需要密码时挂起（非失败）。
- 唯一断点 = **密码交互**环节（无 TTY + 无交互控制台 → 挂起）。
- 推论：Session 0 服务链下 Windows ssh 密码认证无论 ConPTY 还是管道都不可行。

**服务链处置（深挖 + 新正解）**:
- **深挖推翻前提（决定性）**: Win32-OpenSSH sshpty.c `WIN32_FIXME` 分支根本不用
  ConPTY（ptyfd=0/ttyfd=0 = stdin/stdout 直通）→ "复现 OpenSSH ConPTY 机制"是死路。
- **新正解 = SSH_ASKPASS + stdin EOF**（windowsvm Session 0 实测全通过）:
  Win32 OpenSSH read_passphrase 检查 `SSH_ASKPASS` → 走 askpass 程序 → **完全避开
  TTY/ConPTY**。ssh.exe 的 stdin 重定向为 NUL（立即 EOF）→ 根治"认证成功 + 命令
  完成后退出挂起"（Win32-OpenSSH issue #1769/#1427）。
- **实施（45D'）**: sshpass.zig runWindows 加 `hasConsole()` 检测 → ssh 命令恒走
  runWindowsAskpass（SSH_ASKPASS/SSHPASS env + NUL stdin + 读输出回传 + 退出码
  透传 + Permission denied→exit 5）；非 ssh 命令有控制台+ConPTY → runWindowsConpty。

**实施步骤表**:

| # | 任务 | 状态 |
|---|------|------|
| 45A | 修复 runWindowsConpty ConPTY 附加：自定义 STARTUPINFOEXW + cb + lpAttributeList 挂载 | ✅ 真机 CreateProcessW 成功 |
| 45B | 老 Windows 分层：conptyAvailable()==false → 调度走 runWindowsPipe；Host 启动检测提示退出 | ✅ host.zig 启动检测 |
| 45C | 交叉编译 aarch64/x86_64-windows + 门禁 | ✅ 230 单测 + 62 集成全绿 |
| 45D | 单机验证（deploy windowsvm → 实测 sshpass 连真实 sshd） | ✅ 验证完成 → 45D' 正解 |
| 45D' | 实施 SSH_ASKPASS 模式（runWindowsAskpass）+ .pass dupe 修复 | ✅ windowsvm 真机全通过（RC=0/5/255/多行/RC=7） |
| 45D'' | 交叉编译 + 门禁确认无回归（.pass dupe + 检测逻辑） | ✅ 230+62 无泄漏 |
| 45E | winx64 第二台验证 + MCP sshpass 全路径 + status 确认 | ✅ winx64 全场景一致；待办：Windows Host 模式补验 |
| 45F | v0.18.83 版本 + 文档 + 发布 + 部署 | ✅ 4 guest deploy + host install 全 v0.18.83 serving |
| 45G | v0.18.84：MCP download flush+sync（0 字节）+ sshpass tempDir（/tmp 硬编码） | 🔲 修复完成（commit ad93aea，门禁全绿），待发布+部署+Windows Host 切换补验 |
| 45H | Windows utmmd 反复崩溃 1067：GetAdaptersAddresses 栈踩踏 + panic 钩子 | ✅ windowsvm/winx64 RUNNING、PID 稳定、无 PANIC；门禁 230+62 全绿 |

## 已完成: Phase 46 — utmmd 自愈（v0.18.90，2026-08-22）

**背景**: `--upgrade` 只推 utmm、从不推 utmmd（findings 已知限制 #2）。v0.18.89
发布时 windowsvm/winx64 的 utmmd.exe 仍是旧版需手动逐台部署。用户指令：
"utmm 启动后若发现磁盘 utmmd 哈希与自身内嵌不符，立即停服替换再启服"。

**实现**: main.zig `--svc` 分支 5a 块（shm.open 前）——`shouldUpdateUtmmd`
比较磁盘 vs 内嵌哈希（macOS 恒 false）→ 不符则 extractUtmmdToTemp +
buildServiceArgs + upgradeUtmmd（disable→kill→replace→enable→start）→ exit(0)，
新 utmmd spawn 新 utmm 接管。

**闭环验证**（设计层面）:
- 升级一次、无循环：新 utmm 再检测哈希已匹配 → 正常 serve。
- 端口/shm 无冲突：自检在 shm.open 前、未绑定 2121。
- 失败回滚：replace 失败 enable+start 旧 utmmd；start 失败保留新二进制重试一次。
- 循环兜底：upgradeUtmmd 失败 panic → utmmd monitorLoop 指数退避（1s→60s）+
  MAX_FAILURE_COUNT=5。
- macOS 恒 false（决策 #23），自愈自动跳过。

**验证**: zig build ✅ / test 230 ✅ / test-integration 62 ✅；5 节点自愈验证
（windowsvm 2119168 / winx64 2177024 / linuxvm be19d088 哈希匹配 embed）。

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
