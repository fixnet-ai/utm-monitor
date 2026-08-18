# Task Plan — UTM Monitor

**版本**: v0.18.73 | **分支**: `main` | **更新**: 2026-08-18

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: Host v0.18.73（Phase 38）；4 台 Guest 仍 v0.18.72（38 修复 Host 侧生效，无需强制同步）
- **Phase 38 完成**: ping/pong 热路径日志 + 过路 pong RTT 错误归因修复（v0.18.73）

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
