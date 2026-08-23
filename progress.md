# 进度摘要

> 历史阶段完成记录一律以 task_plan.md「历史完成阶段总表」+ git log 为准，本文件不重复。
> **二次瘦身（2026-08-23）**：2026-08-19 及更早会话流水已删；技术结论详见
> findings.md「技术结论 → 代码位置」表（代码头部注释）+ task_plan 历史总表。

## 当前状态

- 分支 `main`，**版本 v0.18.90**（2026-08-22），8/8 交叉编译，5 节点 serving。
- **Phase 45 进行中**：sshpass Windows（SSH_ASKPASS 正解已实现），45G 待发布/部署/补验。
- **Phase 46 完成**：utmmd 自愈（v0.18.90）。
- **Phase 47 进行中**：本地交叉编译发布 v0.18.90 + 5 节点自愈验证已完成；连续 bump 压测 --upgrade 待续。

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

### 发布流程（Phase 47 定案：本地交叉编译替代 CI）

1. bump ver.txt + commit + tag（本地，不 push CI）
2. `zig build cross -Doptimize=ReleaseSafe`（8 目标）
3. **本机 target 需单独 `zig build`**（cross 不构建本机 target）
4. cp 产物到 /opt/utmm/ serve-dir + `codesign --force --sign -` 重签本机 utmm
5. `sudo utmm --install --host` 重启 host
6. `sudo utmm --upgrade <guest>` 逐台推 4 guest
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
