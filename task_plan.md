# Task Plan — UTM Monitor

**版本**: v0.18.34 | **分支**: `main` | **更新**: 2026-08-12

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **测试**: 216 单元 + 59 集成 + 2 Python (CLI 31/31 + MCP 14/14)，0 泄漏
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点全部 v0.18.33 serving
- **GitHub Release**: v0.18.34 (待发布)

## 已完成: Phase 33 — Windows --upgrade 二进制替换崩溃修复

**状态**: ✅ 完成并验证 (v0.18.33)

### Phase 33: 核心修复 (v0.18.2)

| # | 任务 | 状态 |
|---|------|------|
| 1 | Windows: 重命名旧 exe + 放置新 exe（MoveFileExW 替代 deleteFile+rename） | ✅ |
| 2 | 修复进程句柄管理：defer closeProcessHandle 统一清理 | ✅ |
| 3 | handleUpgradeCmd 通过 shm 通知 utmmd | ✅ |
| 4 | macOS codesign 修正（rename 后统一执行） | ✅ |
| 5 | 测试 | ✅ 216 unit + 59 integration passed |

### Phase 33.5: findUpgradeTmp 固化 (v0.18.33)

| # | 任务 | 状态 |
|---|------|------|
| 6 | svc.zig findUpgradeTmp 重写为 FindFirstFileW 实现 | ✅ |
| 7 | utmmd.zig 清理 inline findUpgradeTmp 调试代码 | ✅ |
| 8 | WIN32_FIND_DATAW struct 布局修正 (u32 对 替代 u64) | ✅ |
| 9 | build.zig: Windows utmmd 使用 Debug 优化 | ✅ |
| 10 | guest.zig: discardBytes 消费同版本跳过时的二进制流 | ✅ |
| 11 | host.zig: 推送前同版本检测 | ✅ |
| 12 | Windows 真机端到端验证 (windowsvm v0.18.30→0.18.33 自动升级) | ✅ |

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
