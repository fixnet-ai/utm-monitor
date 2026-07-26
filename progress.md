# Progress: v0.11.10

## 当前状态

- **分支**: `refactor/install-upgrade-selfcopy`（已推送到 GitHub）
- **最新提交**: `868a9e1` — fix: pkill -x exact match and --hostname persistence in service config
- **所有 4 VM + Host**: 运行自复制模型，验证通过

## 最近提交

```
868a9e1 fix: pkill -x exact match and --hostname persistence in service config
c71dead docs: update planning docs for Phase 48 refactoring + KCP hardening
ca1d7fe refactor: unified install/upgrade via self-copy model, remove privilege elevation
4cbb61f fix: launchctl bootstrap reliability + RunResult memory leaks in install.zig
0cfbb11 docs: Phase 43-45 planning docs update — KCP tunnel fixes, IP retry, ensureAdmin skip
```

## Phase 49: 文档合并与整理 ✅ (2026-07-26)

**目标**: 消除文档碎片化，精简到可维护体量。

**合并操作**:
- `DESIGN.md` → CLAUDE.md（协议栈图、服务名表、设计决策）
- `release-skill/SKILL.md` → CLAUDE.md（完整发布流程 5 步）

**文件操作**:
- `build.sh` → `release.sh`，增加 `gh release create`，移到项目根目录
- 删除 `release-skill/` 目录、`DESIGN.md`
- 删除 `utm-vm/MANUAL.md`、`utm-vm/SKILL.md`（旧副本）
- `utm-vm/` 目录删除，`.claude/skills/utmm/` + `skills/utmm` 软链

**重写文档**:
| 文件 | 变更 | 行数 |
|------|------|------|
| task_plan.md | 精简，仅保留 Phase 46-49 | 1042→58 |
| progress.md | 精简，仅保留 Phase 46-49 | 1311→59 |
| findings.md | 精简，仅保留当前相关发现 | 998→90 |
| SKILL.md | WebSocket→KCP，scp+install 替代 install.sh | 237→129 |
| MANUAL.md | 整份重写，7 章 | 1245→632 |
| README.md | scp+install 替代 curl install.sh | 195→163 |
| CLAUDE.md | 合并 DESIGN + release skill | 345→487 |

**验证**: `zig build test` 131/131 通过，全项目零处 `utm-vm`/`WebSocket`/`utmm-old`/`agent.zig` 残留。

## Phase 48: 自复制安装模型重构 ✅ (2026-07-26)

**文件变更**: `src/svc.zig` 新建、`src/fail.zig` 新建、`src/main.zig` 重写、`src/agent.zig` 删除、`src/upgrade.zig` 删除。+1078/-2143 行。

**关键发现** (Findings #62-67): Zig 0.16.0 SCM 类型、GetLastError enum、strerror 移除、rename 4 参数、`++` comptime-only、跨文件系统 EXDEV。

**部署**: 4 VM + Host SCP + `--install --hostname <name>`，全部通过。

## Phase 47: KCP 第二轮审计 ✅ (2026-07-26)

7 个问题（2 Critical），20 个新测试，131/131 通过。

## Phase 46: KCP 可靠性加固 ✅ (2026-07-26)

13 个问题（2 Critical），18 个新测试，111/111 通过。
