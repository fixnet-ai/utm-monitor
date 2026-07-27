# Progress: v0.11.16

## 当前状态

- **分支**: `main`
- **版本**: v0.11.16（`src/protocol.zig` VERSION、`build.zig.zon`）
- **测试**: 149/149 通过
- **部署**: macOS Host v0.11.16 ✅ | linuxvm ✅ | macvm ✅ | windowsvm ✅ | winx64 ✅

## Phase 66: 小修复收尾 ✅ (2026-07-27)

| # | 任务 | 状态 | 提交 |
|---|------|------|------|
| 1 | `upload_result` (0x17) handler | ✅ 已存在（commit `98409c4`）| — |
| 2 | RTT → 真实毫秒 | ✅ `nowMs()` 替代 ping/pong 时钟 | `3c6d7d4` |
| 3 | macOS codesign 重签 | ✅ EXDEV 回退路径加 `codesign --force --sign -` | `3c6d7d4` |
| 4 | 多网卡 LSA 广播可达性 | ✅ 每 30s 回调刷新广播地址列表 | `3c6d7d4` |

**已取消**: httpd.zig 测试编译（httpd 已废弃）、Windows 优雅退出 Finding 103（永久延迟）

## Phase 61-65 摘要

### Phase 61: 删除 HTTP 协议 → KCP+IPC ✅
HTTP 服务器全面删除。端口 2121 仅保留 UDP（mesh LSA + KCP tunnel）。CLI/MCP 走 IPC socket（`/var/run/utmm.sock`）。httpd.zig 1750→680 行（-61%）。

### Phase 62: Windows IPC 编译修复 + 全量部署 ✅
修复 Zig 0.16.0 Windows Named Pipe API 移除（手动 `extern "kernel32"` + `callconv(.winapi)`）。8 目标全通过，4 Guest 全量功能验证通过（status/ping/exec/upload/download）。

### Phase 63: Guest 自主升级 ✅
v0.11.12: Guest 检测版本不匹配 → `upgrade_req` → KCP 下载 → `--install`。
v0.11.13: 移除 Host 推送升级代码（~223 行），Host 仅响应 `upgrade_req`。
v0.11.14: 修复命令循环死锁 — 升级检查需在内外两层循环都存在（Finding 120）。

### Phase 64: 文档重写 + v0.11.15 ✅
SKILL.md + MANUAL.md 全面更新至 v0.11.14 代码现状。发布 v0.11.15 后发现 IP gating bug 阻止自动升级。

### Phase 65: install.sh + install.bat + v0.11.16 ✅
跨平台一键安装脚本（POSIX 272 行 / Windows 332 行）。v0.11.16 附带 IP gating 修复（`mesh.zig` 移除 `host_gateway_ip` 依赖）。全部 Guest 手动升级至 v0.11.16。

## 历史阶段 (Phase 50-60)

| Phase | 关键成果 |
|-------|---------|
| 50 | 加固审计：20 修复（Finding 68-79） |
| 51 | 文件合并 19→13、API 适配 Zig 0.16.0、测试 +52% |
| 52 | CLI auto-ensure：管理命令自动启动 Host 服务 |
| 53 | MCP stdio JSON-RPC + `utmm.lock` PID 文件单例锁 |
| 54 | Host 重启 exec 空输出修复：6 协同 bug（0xFF keepalive 污染、peekSize/recv 不对称等） |
| 55 | Windows 服务停止：signalShutdown 不提前关 socket、pty 管道 CloseHandle |
| 56 | 回归测试 + Windows 硬停止（放弃优雅退出） |
| 57 | `--ping` 命令：mesh ping/pong（11B direct / 18B relayed） |
| 58 | file_chunk MSS 对齐 8KB→1200B + 关键代码注释 |
| 59 | macOS plist StandardErrorPath 回归修复 |
| 60 | 清理 HTTP POST 端点 + fallback 函数死代码 |

## 最近提交

```
3c6d7d4 feat: RTT real ms, macOS codesign re-sign, multi-NIC broadcast refresh
b5bc849 docs: mark Phase 66 complete, update planning files
3006806 fix: replace host_gateway_ip with self-role check in epoch tracking
a94b6a7 v0.11.16: install.sh + install.bat, fix auto-upgrade IP gating bug
a001fa3 v0.11.15: rewrite SKILL.md and MANUAL.md for v0.11.14+ architecture
```
