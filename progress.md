# Progress: v0.13.0 分层架构重构

## 当前状态

- **分支**: `refac/layered-arch`
- **版本**: v0.13.0-pre（尚未发布）
- **测试**: 187/187 全通过（7/7 步骤成功）
- **源文件**: 16 个（目标 15）

## 会话记录

### 2026-07-29 — Phase 1 完成

**成果**: 4 个低风险文件合并任务全部完成，文件从 20 → 16（-4）

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 1 | tcpf.zig + socks4.zig + netconn.zig → tcp.zig | ✅ |
| Task 2 | tunproto.zig → protocol.zig | ✅ |
| Task 3 | mesh.zig + hosts_file.zig → lsa.zig | ✅ |
| Task 4 | 修复 /etc/hosts 空行累积 bug (Finding 169) | ✅ |

**Task 3 详情 (lsa.zig)**:
- 合并 mesh.zig (1330 行, LSA mesh networking) + hosts_file.zig (191 行, /etc/hosts 管理)
- 原 mesh 6 个测试 + hosts_file 5 个测试 + 新增 6 个测试 = 17 个 lsa 测试
- hosts_file.zig 的 `updateHosts` 按原样保留（逻辑不变）
- 日志标签从 `[mesh]` 更新为 `[lsa]`
- 修复: host.zig 中局部变量 `lsa` 与 import `lsa` 命名冲突 → 局部变量改为 `lsa_entry`

**Task 4 详情 (空行累积修复)**:
- 根因: `splitScalar` 按行重建时，文件末尾 `\n` 产生的尾随空串被附加为额外空行
- 修复: 用 `findMarkerLine` + 范围替换替代 splitScalar 逐行重建
- 新增 `findMarkerLine` 函数 — 按字节查找 marker 行位置
- 新增 5 个测试: findMarkerLine-basic/not found/whitespace/end marker + updateHosts 空行累积验证
- 旧版一次性修复，新版范围替换保证每次写入精确替换，不修改 block 外任何内容

**最终文件清单** (16 个):
broadcast.zig, cmdchan.zig, config.zig, fail.zig, host.zig, ipc.zig, lock.zig, lsa.zig, main.zig, mcp.zig, protocol.zig, shm.zig, state.zig, svc.zig, tcp.zig, utmmd.zig

### 2026-07-29 — 重构规划启动

**背景**: `refac.md` 设计文档已完成（commit `3ca7239`），KCP 已删除 + TCP+SOCKS4 已引入（commit `036f40f`）。

**本次会话目标**: 开始 Phase 1 文件合并

**关键文件**:
- `refac.md` — 完整重构设计（分层模型、模块接口、实施计划）
- `task_plan.md` — 更新为 v0.13.0 重构任务
- `findings.md` — 更新为重构相关发现
- `progress.md` — 本文件

---

## 历史摘要

### v0.12.2 及之前（Phase 50-79）

- KCP 隧道稳定性修复、自动升级完善
- utmmd 监督进程架构重构
- MCP stdio JSON-RPC 连接修复
- HTTP 协议彻底删除，全面转向 KCP+IPC
- 8 交叉编译目标全通过
- 166 测试通过
- 4/4 Guest 在线，全部 exec/ping 正常

### v0.13.0-pre (commit `036f40f`)

- 删除 KCP ARQ 协议 (~1300 行)
- 新增 TCP+SOCKS4 传输层 (tcpf + socks4 + netconn)
- mesh.zig 简化为纯 LSA 广播
- 20 源文件，124 测试通过
