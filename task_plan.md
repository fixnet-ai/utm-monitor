# Task Plan — UTM Monitor

**版本**: v0.18.1 | **分支**: `main` | **更新**: 2026-08-11

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **测试**: 216 单元 + 59 集成 + 2 Python (CLI 31/31 + MCP 14/14)，0 泄漏
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点全部 v0.18.1 serving
- **GitHub Release**: v0.18.1 published

## 进行中: Phase 33 — Windows --upgrade 二进制替换崩溃修复

**状态**: 代码修改完成，测试通过，待 Windows 真机验证

### 修复任务

| # | 任务 | 状态 |
|---|------|------|
| 1 | Windows: 重命名旧 exe + 放置新 exe（MoveFileExW 替代 deleteFile+rename） | ✅ |
| 2 | 修复进程句柄管理：defer closeProcessHandle 统一清理 | ✅ |
| 3 | handleUpgradeCmd 通过 shm 通知 utmmd | ✅ |
| 4 | macOS codesign 修正（rename 后统一执行） | ✅ |
| 5 | 测试 | ✅ 216 unit + 59 integration passed |
| 6 | Windows 真机验证 | ⏳ 待部署 |

### 待跟进

- **Windows 真机**: 部署到 windowsvm + winx64 验证 --upgrade 推送全流程

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
