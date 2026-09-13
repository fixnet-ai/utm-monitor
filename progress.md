# 进度摘要

> 历史阶段完成记录一律以 task_plan.md「历史完成阶段总表」+ git log 为准，本文件不重复。
> **二次瘦身（2026-08-23）**：2026-08-19 及更早会话流水已删；技术结论详见
> findings.md「技术结论 → 代码位置」表（代码头部注释）+ task_plan 历史总表。

## 当前状态

- 分支 `main`，**版本 v0.18.91**（2026-09-11 本地发版，tag v0.18.91 本地未 push），
  8/8 交叉编译（macOS 产物正式签名），5 节点全 v0.18.91 serving。
- **v0.18.91 发版记录（2026-09-11）**：含 Phase 48（utmmd IP 指纹误杀修复）+
  Phase 49（macOS 正式签名）。rollout 用 `--deploy` 逐台（utmmd 变更需全量安装）；
  macvm 双二进制 TeamIdentifier 保留。途中修了 deploy.json 缺失 + VM_DEPLOY_TABLE
  IP 过期（macvm 65.4→64.4）；`/opt/utmm/deploy.json` 已建（IP 漂移的正解通道）。
- **Phase 49（2026-09-11）macOS 构建期正式签名**：build.zig `-Dsign-identity` +
  UTMM_CODESIGN_IDENTITY + 自动探测（Developer ID→Apple Development，按哈希规避
  同名 ambiguous），utmmd 嵌入前签名（embed=磁盘哈希一致）；运行期 5 处重签点全部
  改「先验签后重签」。本机部署后 /opt/utmm 双二进制保留 TeamIdentifier 正式签名、
  字节一致；macvm --upgrade 真机验证通过。**待办**：rollout（49E）。
- **Phase 48（2026-09-11）本机 utmm 被周期性误杀修复**：根因 = utmmd IP 指纹
  ①混入虚拟接口（UTM bridge/utun 随睡眠翻转）+ ②去抖基线永不采纳 → 40-52s
  连环 kill（147 次重启）。已修（utmmd.zig 物理网卡过滤 + pending 采纳语义），
  门禁全绿，本机已部署验证，HTTP MCP 连通。证据链与修复细节见 findings.md
  「Phase 48」。**待办**：ver bump + 4 guest rollout（48F/48G）。
- **Phase 45 进行中**：sshpass Windows（SSH_ASKPASS 正解已实现），45G 待发布/部署/补验。
- **Phase 46 完成**：utmmd 自愈（v0.18.90）。
- **Phase 47 进行中**：本地交叉编译发布 v0.18.90 + 5 节点自愈验证已完成；连续 bump 压测 --upgrade 待续。

## 2026-09-14 Phase 50：服务角色一致性守卫（单名 + 角色探测）

**起因**：用户 review 裁定「host/guest 共用服务名 → 角色混淆」是**功能错误**，非文档问题。

**根因**：单服务名 + 单路径下，host 与 guest 的唯一区别是服务配置里的 `--role`，而
`isRunning(role)` 从不回读它 —— macOS host 分支靠 `checkServicePort()`（自注「Host 和 Guest
均监听此端口」），其余分支只按服务名匹配。结果 `utmm --status` 在 guest 机器上误判 host 已运行、
跳过启动后 IPC 连不上；`--host` 更是直接谎报；裸 `utmm` 在 host 上静默空转。

**改动**（svc.zig / main.zig / utmmd.zig，详见 task_plan.md Phase 50）：
- 新增 `roleFromConfigText()` / `installedRole()` / `roleConflict()` —— 三平台回读 `--role`
- `isRunning` 拆为 `isServiceUp()`（原逻辑）+ 角色判定（配置读不到则保持旧行为防回归）
- `main.zig` 加角色守卫：显式 `--host` 允许切换；隐式 guest 默认与只读管理命令一律**拒绝**
- `--install` 角色切换打警告；`buildServiceArgs` 去掉冗余 `--host`（单一来源 = utmmd）
- `utmmd.parseArgs` 按需补齐 `--host`，消除 `utmm --svc --host --host` 重复参数
- 新增 7 条解析器单测

**测试**：`zig build` ✅；`zig build test --cache-dir <fresh>` → **18/18 steps succeeded, exit 0**，
237 passed / 1 skipped / 0 failed（连跑 3 次一致）；`integration_test` → 62 passed / 0 failed / 无泄漏；
本机 host 实测「裸 `utmm` 拒绝、`--mcp` 正常」，plist 哈希与运行中服务均未变。

**VM 回归（v0.18.92，5 节点全量部署）**：host + 4 guest 全部 v0.18.92 serving，`--exec` 四台全通；
角色探测三平台全对（linuxvm systemd / macvm plist / windowsvm+winx64 `sc qc`，均正确识别 `guest` 并拒绝）；
角色切换在 macvm 实测通过（plist guest→host，argv 正确），随后 `--uninstall` + `--deploy` 恢复回 guest；
`--host` 重复参数消失（实测 `utmm --svc --host`）；Windows 控制台 em-dash 乱码已改 ASCII。

**遗留观察**：macvm 恢复时 uninstall→立刻 deploy 的首次 install 未拉起服务（launchctl 节流特征），
`killall` 后重装即恢复 → 疑 `installMacOS()` 的 bootstrap 缺成功校验（详见 task_plan Phase 50 观察段）。

**发布 v0.18.92（2026-09-14）**：`./release.sh v0.18.92` → tag + push → CI Release run **成功**
（Test + build 8 targets 9m56s / release 18s / sign skipped）。发布物 `utmm.zip`（20.6MB）。
⚠️ 注意 `release.yml` 用 `generate_release_notes: true` → GitHub 自动生成的正文**近乎空**（只有
Full Changelog 链接）；curated notes 只落在 annotated tag 里，本次已用 `gh release edit --notes-file`
把 tag 文案补进 Release 正文。**待办**：要么把 `release.yml` 改成用 tag message 作正文，要么每次发布后补这一步。

## 2026-08-22 近期定论（细节见 findings.md）

- **Windows utmmd 反复崩溃 1067 根因**（45H）：GetAdaptersAddresses 栈踩踏 →
  声明 `?*anyopaque` + `[16384]u8 align(8)` 缓冲 + panic 钩子落盘 → windowsvm/
  winx64 部署后 RUNNING、PID 稳定、无 PANIC。
- **Windows Host 服务链 sshpass 正解**（45D/45D'）：SSH_ASKPASS + NUL stdin，
  Session 0 密码认证全通过（RC=0/5/255/多行/exit 7→RC=7）；.pass dupe 修复
  （密码隐藏覆写 argv root cause）。
- **45G 两 bug**：MCP download 落盘 0 字节（Threaded Io 异步 close → flush+sync，
  test_mcp_tools 13/14→14/14）+ sshpass 密码路径硬编码 /tmp（→ svc.tempDir）。
- **Round 2（v0.18.88）**：linuxvm 升级后 utmmd integer overflow panic = `--upgrade`
  只推 utmm 不推 utmmd → saturating 防御 + 手动推 utmmd。
- **Round 3（v0.18.90）utmmd 自愈**：utmm --svc 启动早期自检磁盘 vs 内嵌哈希，
  不符则替换重启（永久闭合 utmmd 手动部署缺口）。5 节点验证：Windows 两台 utmmd
  哈希匹配 embed（4e31db17/a44ec58c）、linuxvm be19d088、macvm 差异为 adhoc
  codesign 预期行为（决策 #23）。

## 仍有效基线（勿动）

### 测试门禁（发布前置）

- `zig build test` 230 单测全绿；`zig build test-integration` 62 集成全绿 0 泄漏。
- 门禁数字增长：单测 216→218→229→230 / 集成 59→60→62。
- 真机验证纪律：standalone → 单机 → 全量；升级三要素 = 磁盘二进制 mtime + size + 行为。

### 发布流程（Phase 47 定案：本地交叉编译替代 CI；Phase 49 签名更新）

1. bump ver.txt + commit + tag（本地，不 push CI）
2. `zig build cross -Doptimize=ReleaseSafe`（8 目标；macOS 产物自动正式签名，
   身份解析：`-Dsign-identity` / env `UTMM_CODESIGN_IDENTITY` / 自动探测，无证书回退 adhoc）
3. **本机 target 需单独 `zig build -Doptimize=ReleaseSafe`**（cross 不构建本机 target；⚠️ 本项目
   standardOptimizeOption 无默认值，漏传 -Doptimize 会构建 Debug 版）
4. cp 产物到 /opt/utmm/ serve-dir（macOS 产物已带正式签名，**无需**再 adhoc 重签；
   运行期重签点全部验签优先，不会降级正式签名）
5. `sudo utmm --install --host` 重启 host
6. `sudo utmm --upgrade <guest>` 逐台推 4 guest（老 utmmd 会 adhoc 重签落地——保留
   正式签名需先 --deploy 推新 utmmd，再 --upgrade 推后续版本）
7. `--status` 验证 5 节点全 serving

### 升级通道约定（CLAUDE.md 固化）

- 版本升级一律 `--deploy`（`--upgrade` 只推 utmm，单独使用致 supervisor 漂移）。
- utmmd 变更 = 自愈（v0.18.90+）或 `--deploy`；`-Dutmmd=false` 复用 embed
  （字节不变→哈希不变）。

### 部署纪律

- VM IP 会漂移：VM_DEPLOY_TABLE 定期与 live mesh 核对（最近同步 2026-08-18），
  或优先 deploy.json 覆盖。
- macOS `sudo cp` 覆盖保留旧 inode → AMFI 签名缓存失效 SIGKILL → 先 `rm -f` 再 cp
  或 codesign 重签。

## 待办追踪（未完成，勿丢）

| # | 待办 | 说明 | 状态 |
|---|------|------|------|
| 1 | 45G 发布 + 部署 + Windows Host 切换补验 | v0.18.84 修复（download flush + sshpass tempDir）已 commit ad93aea，ver.txt→0.18.84 | 待办 |
| 2 | Phase 47 连续 bump 验证 --upgrade 流畅性 | v0.18.85 起压测自动升级链路（45H 后续） | 待办 |
| 3 | SignPath 签名激活 | CI sign job 已写（vars.SIGNPATH_ENABLED 门控），待 OSS 申请批准后配 secrets/variables | 待用户申请 |
| 4 | zio PR #646 上游合并 | fixnet-ai/zio feat/x86-32 合并后 build.zig.zon 切 URL | 待上游 |
| 5 | Windows BIND 防火墙 | OS 限制，文档已注明 | 已知限制 |
| 6 | upsert MAC 变化 | 仅 cosmetic，低优先级 | 低优先级 |
