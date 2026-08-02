# Task Plan — UTM Monitor

**版本**: v0.17.21 | **分支**: `main` | **更新**: 2026-08-03

## 当前状态

- **源文件**: 20 src + 13 test + 2 embed + 2 Python test scripts
- **测试**: 196 单元 + 59 集成 + 2 Python (CLI 31/31 + MCP 14/14)，0 泄漏
- **交叉编译**: 8/8 通过
- **真机部署**: 5 节点全部 v0.17.22 serving
- **GitHub Release**: v0.17.22 published

## 下一阶段: Phase 30 — 部署体验改进（进行中）

审计 `docs/deploy-ux-audit.md` 发现 8 个障碍，优先级处理：

| 障碍 | 优先级 | 状态 |
|------|--------|------|
| VM 凭据硬编码 → deploy.json | P0 | ✅ `loadDeployConfig()` |
| Windows --deploy 空操作 → 自动化 | P0 | ✅ sshpass scp + 远程安装 |
| zio 依赖不可解析 → README + 注释 | P1 | ✅ Build Prerequisites 章节 |
| deploy 要求 Zig 工具链 → serve-dir 缓存 | P1 | ✅ 跳过重复编译 |
| --upgrade 错误信息差 → 可操作指引 | P3 | ✅ GuestNotFound/BinaryNotFound 改进 |
| Guest bootstrap（从零部署到裸 VM） | P2 | 待讨论 |
| zip 无文档 + 版本号不一致 | P2/P3 | 不做 |
| MANUAL.md 更新 deploy.json/serve-dir/sshpass | P2 | ✅ 已更新 |
| cmdDeploy 用 utmm sshpass 去外部依赖 | P2 | ✅ e3e78c8 |

### 待讨论: Guest Bootstrap

用户有一台新 VM（无 utmm），希望一键部署。当前流程需手动 SCP + SSH + install。

选项：
- A: `utmm --bootstrap <ip> --user root --hostname <name>` → SCP + SSH install 一体化
- B: 生成自包含 bootstrap 脚本（base64 内嵌二进制）
- C: 依赖外部工具（MCP / Ansible / 手動）

### 待跟进

- **zio PR #646**: 等待 lalinsky re-review 后合并，之后 build.zig.zon 切回 URL
- ~~**utmmd upgrade 扫描**: 考虑简化或移除（SSH 手动升级更可靠）~~

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

## 架构（v0.16.0+）

```
Application:  guest.zig / host.zig / ipc.zig / mcp.zig / sshpass.zig
Topology:     lsa.zig / arp.zig
Transport:    tcp.zig / socks5.zig
Data Pipe:    dpipe.zig / dpipe_shell.zig / dpipe_file.zig
Protocol:     protocol.zig
System:       svc.zig / utmmd.zig / shm.zig
Foundation:   main.zig / fail.zig / config.zig
```
