# Task Plan — UTM Monitor

**版本**: v0.18.92 | **分支**: `main` | **更新**: 2026-09-14

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点 v0.18.92 serving（utmmd 自愈后全部匹配 embed）
- **Phase 45 进行中**: 遗留 L2 — sshpass Windows ConPTY 假模式（已正解为 SSH_ASKPASS，45G 待发布/部署/补验）
- **Phase 46 完成**: utmmd 自愈 — utmm `--svc` 启动自检磁盘 utmmd 哈希，不符则替换重启（v0.18.90）
- **Phase 47 进行中**: 本地交叉编译发布 v0.18.90 + 5 节点自愈验证（已完成）；连续 bump 验证 --upgrade 流畅性待续
- **Phase 48 进行中**: 本机 macOS utmm 服务自动停止 / Claude Code 启动后连接不上 — 根因排查与修复（2026-09-11）
- **Phase 49 进行中**: macOS 构建期正式代码签名（utmm/utmmd，替代 adhoc）— 用户已续期 Apple Development 证书（2026-09-11）
- **Phase 50 完成并发布**: 服务角色一致性守卫（单名 + 角色探测）— **v0.18.92 已 tag + CI 发布**，5 节点已部署（2026-09-14）

## 未完成任务（最高优先级，勿丢）

| # | 待办 | 说明 | 状态 |
|---|------|------|------|
| 1 | **45G 发布 + 部署 + Windows Host 切换补验** | v0.18.84 修复（MCP download flush + sshpass tempDir）已 commit ad93aea，ver.txt→0.18.84；待发布 + 部署 + Windows Host 模式 MCP sshpass（Session 0 已由 exec 通道验证，切换 host 部署后补验） | 🔲 待办 |
| 2 | **Phase 47 连续 bump 验证 --upgrade 流畅性** | v0.18.85 起连续 bump 压测自动升级链路（45H 后续）；Windows 1067 已修，验证升级全流程 | 🔲 待办 |
| 3 | **SignPath 签名激活** | CI sign job 已写（`vars.SIGNPATH_ENABLED` 门控默认跳过）；OSS 申请批准后配 secrets/variables（激活清单见 Phase 42 段） | 🔲 待用户申请 |
| 4 | **zio PR #646 上游合并** | fixnet-ai/zio feat/x86-32 合并后 build.zig.zon 从本地 path 切 URL | 🔲 待上游 |
| 5 | **Windows BIND 防火墙** | OS 限制，文档已注明，无需代码修复 | ⏸ 已知限制 |
| 6 | **upsert() MAC 变化** | 仅 cosmetic，路由用 LSA node_id | ⏸ 低优先级 |
| 7 | **installMacOS bootstrap 缺成功校验** | 2026-09-14 macvm 观察到：`--uninstall` 后立刻 `--install`，服务未被拉起（`launchctl` 无 `com.utmmd`、无进程），`killall` 后重装才恢复。`start()` 有 3 次重试 + `launchctl list` 校验，`installMacOS()` 的 bootstrap 却只 `_ = runCmd(...)` 不看结果 → 建议把校验/重试复用到 install() | 🔲 待办 |

## 进行中: Phase 50 — 服务角色一致性守卫（单名 + 角色探测，2026-09-14）

**状态**: ✅ 完成并发布 **v0.18.92**（2026-09-14）| **触发**: 用户 review 裁定「host/guest 共用服务名导致角色混淆」= 功能错误

**根因（代码证据，非推测）**
1. **`isRunning(role)` 角色盲**（svc.zig:910-962）：macOS host 分支走 `checkServicePort()`，
   而该函数自注 `/// 尝试连接 localhost:2121（Host 和 Guest 均监听此端口）`（svc.zig:842）
   → guest 在跑也能让 host 判定为 true；其余分支只按服务名匹配，而服务名不分角色。
2. **`install()` 无角色一致性检查**（svc.zig:968-970 注释自认 "Always overwrites existing
   config — no checks, no comparison"）→ `utmm --host --install` 在 guest 机器上静默改角色。
3. `stop(_role)` / `uninstallServiceConfig(_role)` / `disableService(_role)` 的 role 参数被丢弃
   （svc.zig:1254-1255、1485-1486、2223-2224）—— 死参数，读代码者会以为按角色过滤。
4. **`--host` 双来源**：main.zig:875-879（写入服务配置）与 utmmd.zig:76-80（按 `--role` 追加）
   → 实测子进程 argv `utmm --svc --host --host`（幂等但两层各持一半映射）。
5. `killAllUtmm()` 按进程名无差别杀（svc.zig:1569）—— 角色盲（单名设计下属可接受）。

**已观察症状 → 修复后行为**

| 场景 | 现状 | 修复后 |
|------|------|--------|
| guest 机器 `utmm --status` | `isRunning(.host)`=true（guest 占着 2121）→ 跳过启动 → 随后 IPC socket 连不上，报无关错误 | 检测到角色不符 → 明确报错并给出指引 |
| guest 机器 `utmm --host` | 打印 "utmm host service is running."（撒谎） | 显式 `--host` → 自动切换为 host |
| host 机器裸 `utmm` | `isRunning(.guest)`=true（按服务名匹配）→ 静默什么都不做 | 拒绝并提示，绝不隐式降级 host |

**决策（用户裁定 2026-09-14）**
- 服务标识：**单名 + 角色探测** —— 保留 `com.utmmd` / `/opt/utmm/utmmd`，改动集中在 svc.zig，
  不触碰 deploy/upgrade/serve-dir 与已有部署。
- 角色冲突：**显式切换 / 隐式拒绝** —— 显式 `--host` 允许自动切换；隐式 guest 默认与只读管理
  命令一律拒绝（不静默降级 host）。

**改动清单**
- [x] svc.zig: `roleFromConfigText()` 文本解析 + `installedRole()` 三平台读取（plist / unit ExecStart / `sc qc`）+ `roleConflict()`
- [x] svc.zig: `isRunning(role)` 拆出 `isServiceUp()`，叠加角色判定（配置读不到 → 保持旧行为防回归）
- [x] svc.zig: `stop()` 角色不符时记日志（诚实化死参数）
- [x] main.zig: needs_host 块加守卫（显式 `--host` 切换 / 管理命令拒绝）
- [x] main.zig: 默认 guest 块加守卫（已装 host → 拒绝）
- [x] main.zig: `--install` 角色切换告警
- [x] main.zig: `buildServiceArgs` 去掉冗余 `--host`（单一来源 = utmmd）
- [x] svc.zig: 新增解析器单元测试（plist / ExecStart / sc binPath / 无 `--role`）
- [x] `zig build test` 全绿

**验收标准**: 三平台编译通过 + 单测全绿；本机（host）实测「裸 `utmm` 拒绝、`utmm --host` 保持运行」；
guest 正常部署路径（`--deploy` → `--install`）行为不变。

**验证结果（2026-09-14，本机 macOS / 现行 host 服务）**

| 项 | 结果 |
|----|------|
| `zig build` | ✅ 通过 |
| `zig build test`（全新 `--cache-dir` 冷编译） | ✅ **Build Summary: 18/18 steps succeeded**，exit 0；聚合单测 237 passed / 1 skipped / **0 failed**（连跑 3 次一致） |
| 新增解析器单测 7 条 | ✅ 全绿（plist / ExecStart / sc binPath / 无 `--role` / `--host*` 干扰） |
| 本机实测：`utmm --mcp` | ✅ 正确识别 host 已在跑 → 打印 endpoint，无副作用 |
| 本机实测：裸 `utmm`（隐式 guest，机器是 host） | ✅ **拒绝**并给出指引，exit 1；plist sha256 前后一致、服务未重启、MCP 仍返回 7 工具 |
| 回归面：全仓调用点扫描 | ✅ 无任何「裸 `utmm`」调用；deploy 一律 `--install [--hostname]`，`utmm sshpass …` 在角色逻辑之前返回 |

**VM 回归（2026-09-14，v0.18.92，5 节点全量部署）**

| 项 | 结果 |
|----|------|
| 部署 | ✅ host + 4 guest 全部 v0.18.92 serving；`--exec` 四台全通 |
| LINUXVM 角色探测（systemd unit ExecStart） | ✅ `--status` 正确识别 `guest` 并拒绝 |
| MACVM 角色探测（launchd plist） | ✅ 同上 |
| WINDOWSVM / WINX64 角色探测（`sc qc` binPath） | ✅ 同上 |
| 角色切换（macvm `--host`） | ✅ plist `guest`→`host`，进程变 `utmmd --role host` + `utmm --svc --host` |
| 恢复（`--uninstall` + `--deploy macvm`） | ✅ 回到 guest 并重新入网 |
| `--host` 去重（实测 argv） | ✅ host 与 macvm 均为 `utmm --svc --host`（旧为 `--svc --host --host`） |
| Windows 控制台消息渲染 | ✅ em-dash 乱码 → 改 ASCII 后复验干净 |

**观察（非本次改动引入，记为待办）**：macvm 恢复时 `--uninstall` 后立刻 `--deploy macvm`，首次 `--install`
未把服务拉起来（`launchctl` 中无 `com.utmmd`）；按 deploy skill 先 `killall utmm utmmd` 再 `--install`
即恢复。根因指向 `installMacOS()` 的 `launchctl bootstrap` **无成功校验**（`start()` 有 3 次重试+校验，
install 没有）。行为与本次改动无关：`isRunning` 经本次修改只会**更严格**（原 `isServiceUp` 逻辑原样保留 +
叠加角色判定），不可能把「未运行」判成「已运行」。

⚠️ **仍未覆盖**：Linux/Windows 的角色切换（`--host` 自动重装）—— 仅 macvm 实测了切换路径；
其余两平台验证的是角色**探测**（拒绝路径）。

> 注：`zig build test` 输出里的 `failed command: <path>` 行是**构建系统噪音**（同一份输出同时给出
> `18/18 steps succeeded`、exit 0，且直接运行这些 test 二进制均 exit 0；该行对 ipc/dpipe/guest/shm
> 等本次未改动的步骤同样出现）。判定以 Build Summary + exit code 为准。

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

## 进行中: Phase 49 — macOS 构建期正式代码签名（2026-09-11）

**目标**: mac 版 utmm/utmmd 构建期用正式开发者证书签名（替代 adhoc），目标设备安装不再因
签名问题失败。**关键约束**: ① 证书同名双本（旧 EF2B.../续期 A9AA...），按名称签名会
ambiguous 失败 → 自动探测按**哈希**取；② utmmd 必须**嵌入前**签名（embed=磁盘字节一致
→ utmmd.sha256 一致）；③ 运行期 4 处 adhoc 重签必须改**先验签后重签**，否则构建期正式
签名会被覆盖降级。

| # | 任务 | 状态 |
|---|------|------|
| 49A | build.zig：`-Dsign-identity` 选项 + 解析链（显式→env UTMM_CODESIGN_IDENTITY→自动探测 Developer ID/Apple Development→adhoc 兜底）；utmmd 嵌入前签名 + native/cross utmm 签名（macOS 目标） | ✅ |
| 49B | 运行期重签点改验签优先：svc.zig codesignValid 辅助 + **5 处**（selfCopy/forceInstall×2/replaceFile + main.zig extractUtmmd + utmmd.zig 升级路径） | ✅ |
| 49C | 门禁：单测 230 全绿 + 集成 62/62 无泄漏 | ✅ |
| 49D | 本机部署验证：/opt/utmm/utmm+utmmd 均保留正式签名（字节一致），5 节点 serving；macvm 推送真机验证通过（老 utmmd 安装新签名二进制正常，落地 adhoc 属预期） | ✅ |
| 49E | v0.18.91 本地发版：8 目标 cross + 本机 ReleaseSafe + 5 节点 rollout 全 serving；macvm 双二进制保留 TeamIdentifier 签名 | ✅ |
| 49F | 发布流水账：deploy.json 缺失暴露内置表 IP 过期（macvm 65.4→实际 64.4）→ 已建 /opt/utmm/deploy.json + 修正 VM_DEPLOY_TABLE；macvm sshd 曾不在监听，经 mesh exec bootstrap 恢复 | ✅ |

**实施要点**：① installArtifact 的 Copy 与签名步骤是并行兄弟，必须 `addInstallArtifact`
+ 显式 `dependOn(sign)` 否则可能拷出未签产物；② codedb 搜索漏过 selfCopy 的重签点，
改码后必须全量复查 `codesign` 触点；③ 本项目 `standardOptimizeOption` 无默认值，
本机部署必须显式 `-Doptimize=ReleaseSafe`（Phase 48 曾误部署 Debug 版，49D 已纠正）。

**证书现状**（2026-09-11 实测）：`A9AADC7D32C15F9C7DD77A58A68C83663796D48A`
"Apple Development: ***@163.com (GXX2L7J5WB)" 续期版、2027-09-10 到期（推荐）；
同名旧证 2027-07 到期仍有效。无 Developer ID 证书——Apple Development 签名对本
mesh 直推部署（无 quarantine）足够；对外分发需 Developer ID + 公证。

## 已完成: Phase 48 — 本机 macOS utmm 服务自动停止排查（2026-09-11）

**结论**: ✅ 全部闭环。48A-48G 完成；v0.18.91 已全舰队 rollout；跨睡眠周期长期
观察通过（10.5h 整夜睡眠循环零误杀零重启）。

**现象**: utmm 服务总是自动停止；每次 Claude Code 启动后连接不上。
**根因**（证据链见 findings.md「Phase 48」）:
1. **utmmd IP 指纹误杀**：指纹覆盖所有接口 IPv4（含 UTM bridge/utun/awdl，随
   睡眠/VM 挂起翻转）+ 去抖基线永不采纳（偏离即计数，IP_STABLE_CHECKS=2 → 20s
   即杀，计数器不回零）→ 日志实证 147 次重启 / 40-52s 连环 kill cycle。
2. **Claude Code stdio MCP 残留配置**：`~/.claude.json` 仍为 pre-v0.18.0 stdio
   注册，`--mcp` 现在只打印 endpoint 秒退 → MCP 必连不上（独立于 #1）。

**排查路径**:
| # | 步骤 | 状态 |
|---|------|------|
| 48A | 现场取证：launchd / 进程 / utmmd 日志 / pmset 睡眠记录 / 崩溃报告 | ✅ |
| 48B | 代码审计：monitorUtmm 超时/IP 检测 + 指纹实现 + guest.zig 网卡规则对照 | ✅ |
| 48C | 根因定位：IP 指纹误判（检测目标错 + 基线不采纳）+ stdio 配置残留 | ✅ |
| 48D | 修复：① 指纹加物理网卡名过滤（对齐 guest.zig）② 去抖改采纳语义 + stdio→http 迁移 | ✅ |
| 48D' | 门禁：zig build + test + test-integration 全绿（单测含 utmmd 11/11；集成 62/62 无泄漏；test_mcp_tools 14/14） | ✅ |
| 48E | 本机部署验证：01:12 换新 utmmd+utmm，5 节点 serving，HTTP MCP initialize/ping 全通 | ✅ |
| 48F | v0.18.91 发布 + 4 guest rollout（--deploy，全舰队 0.18.91 serving） | ✅ |
| 48G | 长期观察：跨睡眠周期 utmm PID 稳定、日志无 IP-change 误杀 | ✅ 2026-09-11 13:06 验证：部署后 10.5h（含整夜 Maintenance Sleep/DarkWake 循环）IP-change 误杀 0、heartbeat timeout 0、utmm 重启 0，PID 稳定 |

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
