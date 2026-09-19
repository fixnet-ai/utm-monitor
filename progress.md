# 进度摘要

> 历史阶段完成记录一律以 task_plan.md「历史完成阶段总表」+ git log 为准，本文件不重复。
> **二次瘦身（2026-08-23）**：2026-08-19 及更早会话流水已删；技术结论详见
> findings.md「技术结论 → 代码位置」表（代码头部注释）+ task_plan 历史总表。

## 当前状态

- 分支 `main`，**版本 v0.18.92**（2026-09-14 发布：`./release.sh v0.18.92` → tag + push → CI Release 成功），
  8/8 交叉编译（macOS 产物正式签名），5 节点全 v0.18.92 serving。
- **v0.18.91 发版记录（2026-09-11）**：含 Phase 48（utmmd IP 指纹误杀修复）+ Phase 49（macOS 正式签名，
  含 49E rollout —— 5 节点全 serving）。rollout 用 `--deploy` 逐台（utmmd 变更需全量安装）；macvm 双
  二进制 TeamIdentifier 保留。途中修 deploy.json 缺失 + VM_DEPLOY_TABLE IP 过期（macvm 65.4→64.4）；
  `/opt/utmm/deploy.json` 已建（IP 漂移的正解通道）。
- Phase 45/46/47：45G 修复完成待发布/部署/补验；utmmd 自愈完成（v0.18.90）；连续 bump 压测 --upgrade
  待续 —— 未完成项统一见 task_plan.md「未完成任务表」（本文件不再逐条追踪）。

## 2026-09-14 Phase 50：服务角色一致性守卫（单名 + 角色探测）

**起因**：用户 review 裁定「host/guest 共用服务名 → 角色混淆」是**功能错误**。根因/改动/验证明细见
task_plan.md Phase 50 + findings.md Phase 50 定论（svc.zig 角色回读解析器 + isRunning 角色判定 +
main.zig 三处守卫 + `--host` 单一来源化；单测 237 passed / 0 failed，集成 62/62 无泄漏；5 节点
v0.18.92 部署后角色探测三平台全对，角色切换 macvm 实测通过后恢复回 guest）。

**发布 v0.18.92（2026-09-14）**：CI Release run **成功**（Test + build 8 targets 9m56s / release 18s /
sign skipped），发布物 `utmm.zip`（20.6MB）。⚠️ `release.yml` 用 `generate_release_notes: true` →
Release 正文近乎空（只有 Full Changelog 链接；curated notes 只落在 annotated tag），本次已用
`gh release edit --notes-file` 补进正文 —— 改进待办已登记 task_plan.md「未完成任务表」#8。

## 2026-08-22 近期定论（Windows utmmd 1067 / SSH_ASKPASS / 45G / Round 2-3 utmmd 自愈）

细节统一见 findings.md「2026-08-22 定论（v0.18.84-90）」。

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

## 待办追踪

未完成项统一见 task_plan.md「未完成任务表」（原表与 task_plan 逐行重复，已去重删除）。
