# Progress: v0.11.11

## 当前状态

- **分支**: `main`（未推送）
- **版本**: v0.11.11（`src/protocol.zig` VERSION、`build.zig.zon`）
- **测试**: 193/193 通过（EXIT=0）
- **部署**: macOS Host ✅ | linuxvm ✅ | macvm ✅ | windowsvm ✅ | winx64 ✅

## 最近提交

```
(未提交 — Phase 57 变更待提交)
```

## Phase 57: `--ping` 命令 + 全量自动升级测试 ✅ (2026-07-27)

**目标**: 实现 `utmm --ping <hostname>` CLI 命令，通过 mesh ping 验证 Guest 连通性。测试 v0.11.10→v0.11.11 自动升级。

**实现**:

| 文件 | 变更 | 行数 |
|------|------|------|
| `src/protocol.zig` | VERSION 0.11.10→0.11.11 | +1/-1 |
| `build.zig.zon` | version 0.8.2→0.11.11 | +1/-1 |
| `src/main.zig` | `--ping` 参数解析、needs_host、dispatch、帮助文本 | +10/-2 |
| `src/host.zig` | `cmdPing()` HTTP 客户端、`setGuestMeshMac()` 调用、ping 路由 | +55/-0 |
| `src/httpd.zig` | `handlePing()` HTTP handler、`readHeader`→`getRequestHeader` 修复 | +47/-4 |
| `src/mesh.zig` | `pingAndWait()` 重写（真实时间轮询）、`sendPing()` 加直接 ping 日志、`fromMillis`→`fromMilliseconds` 修复 | +10/-15 |

**部署流程**:

1. Bump 版本 0.11.10→0.11.11
2. 构建 8 目标（全部通过）
3. 部署 Host（aarch64-macos）→ 重启服务
4. 升级 Guest（linuxvm→macvm→windowsvm→winx64）via SSH scp + `--install`
5. 修复升级后丢失的 hostname（手动改 systemd/launchd/sc 配置）
6. 验证 `--ping` 和 exec 全功能

**关键 Bug 修复**:

| # | 问题 | 严重度 | 状态 |
|---|------|--------|------|
| F104 | `setGuestMeshMac()` 从未调用 → mesh_mac 永远 null | Critical | ✅ |
| F105 | `pingAndWait` 用 clock_ms 事件计数器做超时 | High | ✅ |
| F3 | `fromMillis` Zig 0.16.0 API 不存在 | Medium | ✅ |
| F4 | `readHeader` 不存在 → `getRequestHeader` | Medium | ✅ |
| F5 | `Discarding.init()` 需要 buffer 参数 | Medium | ✅ |
| F107 | SSH `--install` 被 pkill 自伤 | Medium | 📋 规避方案 |
| F108 | 升级后 Guest hostname 丢失 | Medium | 📋 已手动修复 |

**Ping 验证结果** (2026-07-27):

| Guest | Hostname | --ping | RTT (ticks) | exec |
|-------|----------|--------|-------------|------|
| linuxvm | linuxvm | ✅ `{"hostname":"linuxvm","mac":"16:a0:6c:ba:ae:fa","rtt_ms":10}` | 10 | ✅ |
| macvm | macvm | ✅ `{"hostname":"macvm","mac":"1a:97:6d:38:0c:6c","rtt_ms":10}` | 10 | ✅ |
| windowsvm | windowsvm | ✅ `{"hostname":"windowsvm","mac":"66:dc:da:ec:a1:59","rtt_ms":10}` | 10 | ✅ |
| winx64 | winx64 | ✅ `{"hostname":"winx64","mac":"00:ff:4d:91:87:0b","rtt_ms":10}` | 10 | ✅ |

**Host 日志确认直接 ping→pong 完整链路**:
```
[mesh] ping direct: → 16:a0:6c:ba:ae:fa addr=192.168.64.2:2121    (linuxvm)
[mesh] ping direct: → 1a:97:6d:38:0c:6c addr=192.168.64.4:2121    (macvm)
[mesh] ping direct: → 66:dc:da:ec:a1:59 addr=192.168.65.2:2121    (windowsvm)
[mesh] ping direct: → 00:ff:4d:91:87:0b addr=192.168.3.108:2121   (winx64)
[mesh] pong from 16:a0:6c:ba:ae:fa rtt=20ms
[mesh] pong from 1a:97:6d:38:0c:6c rtt=30ms
[mesh] pong from 66:dc:da:ec:a1:59 rtt=40ms
[mesh] pong from 00:ff:4d:91:87:0b rtt=50ms
```

**遗留**:
- RTT 为 `clock_ms` 事件计数（非真实毫秒），后续可改用 `std.Io.Timestamp.awake`
- F91: `selfCopy()` copy+delete 路径 macOS codesign 重新签名
- Windows 优雅退出方案延后（Finding 103）

## 历史阶段

Phase 50-56 详情见 [progress.md history](progress.md)。关键里程碑：

| Phase | 日期 | 内容 |
|-------|------|------|
| 56 | 2026-07-27 | 回归测试 + Windows 硬停止修复 |
| 55 | 2026-07-27 | Windows 服务停止卡死修复 |
| 54 | 2026-07-26 | Host 重启 exec 空输出修复（6 个协同 bug） |
| 53 | 2026-07-26 | MCP stdio + utmm.lock 单例锁 |
| 52 | 2026-07-26 | CLI auto-ensure + 部署测试 |
| 51 | 2026-07-26 | 19→13 文件合并 + 测试 +52% |
| 50 | 2026-07-26 | 加固优化全面审计（20 个修复） |
