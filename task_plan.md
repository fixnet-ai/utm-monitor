# Task Plan: v0.11.10

## 架构概述

UTM Monitor (`utmm`) — 单二进制双模式（Guest/Host），Mesh LSA + KCP 隧道为唯一 Guest-Host 传输层。自复制安装模型：二进制从任意路径运行，强制覆盖安装到固定路径。

**关键设计决策：**
- 删除 WebSocket，KCP Tunnel 为唯一传输层（v0.11.0）
- 统一服务模型：Host 和 Guest 均为系统自动启动服务（v0.12.0）
- 自复制模型：升级 = 新版本 `--install`，取消 utmm-old + agent.zig（v0.12.0）
- Fast-fail：不继续执行出错操作，打印错误退出
- 所有操作要求 root/Administrator（除 `--version`/`--help`）

## 活跃 VM

| VM | Hostname | OS | IP | 凭据 | 路径 |
|----|----------|-----|----|------|------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## 近期完成

### Phase 49: 文档合并与整理 ✅ (2026-07-26)

- DESIGN.md 内容合并到 CLAUDE.md（协议栈图、UDP 分发码、服务名表、设计决策理由）
- release-skill/SKILL.md 发布流程合并到 CLAUDE.md
- `build.sh` 改名 `release.sh`，增加 `gh release create` 调用，移到项目根目录
- 删除 `release-skill/` 目录、`DESIGN.md`
- `utm-vm` 改名 `utmm`：`.claude/skills/utmm/` + `skills/utmm` 软链
- 规划文档精简：task_plan（1042→53 行）、progress（1311→53 行）、findings（998→90 行）
- SKILL.md 重写（WebSocket→KCP 隧道）、MANUAL.md 整份重写（1245→632 行）
- README.md 更新安装/升级描述

### Phase 48: 自复制安装模型重构 ✅ (2026-07-26)

- 新建 `src/svc.zig`（统一跨平台服务管理）、`src/fail.zig`（fast-fail 工具）
- 删除 `src/agent.zig`、`src/upgrade.zig`
- 精简 `src/priv.zig`（仅 isAdmin）、`src/install.zig`（仅 genInit/Platform）
- 重写 `src/main.zig` 调度树
- 8 目标交叉编译全过，4 VM + Host 全部署验证通过

### Phase 47: KCP 可靠性第二轮深度审计 ✅ (2026-07-26)

- 7 个问题修复（2 Critical、2 High），20 个新测试，131/131 通过

### Phase 46: KCP 可靠性全面加固 ✅ (2026-07-26)

- 13 个问题修复（2 Critical），18 个新测试，111/111 通过

## 待办

_暂无_
