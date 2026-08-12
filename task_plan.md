# Task Plan — UTM Monitor

**版本**: v0.18.68 | **分支**: `main` | **更新**: 2026-08-13

## 当前状态

- **源文件**: 22 src + 13 test + 2 embed + 2 Python test scripts
- **交叉编译**: 8/8 通过 (aarch64/x86_64/x86 × 3 OS)
- **真机部署**: 5 节点全部 v0.18.68 serving（三平台自动升级全通）
- **GitHub Release**: v0.18.68（本次发布）

## 已完成: Phase 35 — 三平台自动升级彻底打通 (v0.18.44 → v0.18.68)

**状态**: ✅ 完成，5 轮自动升级压力测试全通过

本次会话从 4 个预存 Bug 出发，逐步挖出并修复了自动升级链路上的多个跨平台 bug，
最终实现 Linux/macOS/Windows 三平台 `--upgrade` 自动升级全部可靠工作。

| # | 任务 | 状态 | 版本 |
|---|------|------|------|
| 1 | O_NONBLOCK 跨平台修复（Linux 心跳超时 crash-loop 根因） | ✅ | v0.18.45 |
| 2 | macOS forceInstall 无条件 codesign（SSH 部署后签名损坏） | ✅ | v0.18.45 |
| 3 | SHM restart 处理不杀 utmm（升级失败不中断服务） | ✅ | v0.18.46 |
| 4 | 升级连续失败计数器（防无限重试） | ✅ | v0.18.46 |
| 5 | ensure 重试用 usleep（isRunning 检测 init.io 上下文失败） | ✅ | v0.18.48 |
| 6 | SHM cmd_data 路径机制（绕过 findUpgradeTmp 目录扫描） | ✅ | v0.18.52 |
| 7 | readCmdPath 去掉 '/' 检查（Windows C:\ 路径被拒） | ✅ | v0.18.58 |
| 8 | @atomicStore 跨进程可见性（SHM 路径写） | ✅ | v0.18.59 |
| 9 | Windows SHM 不关闭 CreateFileMappingW 句柄（名字被移除根因） | ✅ | v0.18.61 |
| 10 | Windows 升级流程重设计（PID 精准杀 + taskkill 兜底） | ✅ | v0.18.54 |
| 11 | utmmd 自升级流程（disable→stop→kill→replace→enable→start） | ✅ | v0.18.56 |
| 12 | 5 轮自动升级压力测试（v0.18.64→68，全部追平） | ✅ | v0.18.68 |

## 已完成: Phase 34 — POSIX findUpgradeTmp Threaded Io 修复 + 全节点升级验证

**状态**: ✅ 完成 (v0.18.35)

| # | 任务 | 状态 |
|---|------|------|
| 1 | 发现 POSIX need_threaded bug（io 复用导致 openDirAbsolute 静默失败） | ✅ |
| 2 | utmmd.zig: 所有平台始终创建 Threaded Io 进行文件操作 | ✅ |
| 3 | Windows utmmd 崩溃恢复（sc.exe start 手动重启） | ✅ |
| 4 | linuxvm TCP 服务崩溃恢复（utmctl stop/start 重启 VM） | ✅ |
| 5 | 全节点升级到 v0.18.34 并验证 exec | ✅ |

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
| 15 | 所有平台文件 I/O 必须用 Threaded Io | 事件循环 Io（epoll/kqueue/IOCP）不支持文件操作，POSIX 复用 io 导致 findUpgradeTmp 静默失败 |
| 16 | 升级 .tmp 全路径通过 SHM cmd_data 传递 | 绕过 findUpgradeTmp 目录扫描（Windows Threaded Io walker 不支持） |
| 17 | SHM 跨进程共享内存用 @atomicStore/Load | @memcpy 对 *volatile 可能被优化掉，跨进程不可见 |
| 18 | Windows SHM 不关闭 CreateFileMappingW 句柄 | 关闭句柄会移除命名对象名字，utmm 打开失败 |
| 19 | utmmd 自升级用强杀（killAllUtmm 跳过 self） | 不用 stop() 优雅停止，避免触发 utmmd shutdown 回调杀 utmm |

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
