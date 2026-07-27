# Task Plan: v0.11.18

## 架构概述

UTM Monitor (`utmm`) — 单二进制双模式（Guest/Host），Mesh LSA + KCP 隧道为唯一 Guest-Host 传输层。
自复制安装模型：二进制从任意路径运行，强制覆盖安装到 `/opt/utmm/utmm`（POSIX）/ `C:\opt\utmm\utmm.exe`（Windows）。

**关键设计决策：**
- KCP Tunnel 为唯一 Guest-Host 传输层（v0.11.0 删除 WebSocket）
- Host 和 Guest 均为系统自动启动服务
- 自复制模型：升级 = 新版本 `--install`（v0.12.0）
- **Guest 自主升级**（v0.11.14）：Guest 检测 LSA 版本不匹配 → KCP 下载 → `--install`。Host 永不推送
- **一键安装脚本**（v0.11.16）：`install.sh`/`install.bat` 交互式跨平台安装/升级
- 端口 2121 UDP only（mesh LSA + KCP tunnel），CLI/MCP 走本地 IPC socket
- Fast-fail 错误处理，所有操作要求 root/Administrator

## 活跃 VM

| VM | Hostname | OS | IP | 凭据 | 路径 |
|----|----------|-----|----|------|------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | winx64 | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## 当前状态

- **版本**: v0.11.18（`src/protocol.zig`、`build.zig.zon`）
- **源文件**: 16 个（`src/*.zig`）
- **测试**: 149/149 通过
- **部署**: macOS Host v0.11.18 待部署 | 4 Guest 待自动升级验证
- **8 交叉编译目标**: aarch64/x86_64/x86 × linux-musl/macos/windows

## 已完成阶段

| Phase | 日期 | 内容 |
|-------|------|------|
| 50 | 2026-07-26 | 加固优化全面审计（20 个修复） |
| 51 | 2026-07-26 | 19→13 文件合并，127→193 测试 (+52%) |
| 52 | 2026-07-26 | CLI auto-ensure + 管理命令行为矩阵 |
| 53 | 2026-07-26 | MCP stdio + utmm.lock 进程单例锁 |
| 54 | 2026-07-26 | Host 重启 exec 空输出修复（6 协同 bug：0xFF keepalive 污染等） |
| 55 | 2026-07-27 | Windows 服务停止卡死修复（3 断裂点） |
| 56 | 2026-07-27 | 回归测试 + Windows 硬停止（放弃优雅退出，Finding 103 永久延迟） |
| 57 | 2026-07-27 | `--ping` 命令 + ping/pong mesh 协议（11B direct / 18B relayed） |
| 58 | 2026-07-27 | file_chunk MSS 对齐（8KB→1200B），消除 KCP 二次分片 |
| 59 | 2026-07-27 | macOS plist StandardErrorPath 回归修复 |
| 60 | 2026-07-27 | 清理 HTTP POST 端点死代码 |
| 61 | 2026-07-27 | **彻底删除 HTTP 协议**，全面转向 KCP+IPC |
| 62 | 2026-07-27 | Windows IPC 编译修复 + 全量部署测试（8 目标全通过） |
| 63 | 2026-07-27 | Guest 自主升级（v0.11.12→v0.11.14，修复命令循环死锁） |
| 64 | 2026-07-27 | 文档重写（SKILL.md + MANUAL.md）+ v0.11.15 发布 |
| 65 | 2026-07-27 | install.sh + install.bat + v0.11.16 发布 + IP gating bug 修复 |
| 66 | 2026-07-27 | RTT 真实毫秒 (`nowMs()`)、macOS codesign 重签、多网卡广播刷新 |
| 67 | 2026-07-27 | v0.11.17：修复 `serveUpgradeFile` `@memcpy alias` crash + 自动升级全流程测试 |
| 68 | 2026-07-27 | v0.11.18：修复 LSA restart 误判 — nonce 比较替代全 node_info 字符串比较 |

## 待修复

| Finding | 严重度 | 描述 |
|---------|--------|------|
| 123 | 🔴 CRITICAL | macOS 自动升级后 `exit(0)` + `KeepAlive SuccessfulExit=false` → 服务永久停止 |
| 124 | ✅ 已修复 | LSA restart 用全 node_info 比较 → 动态字段(status:)触发误判 → nonce 比较 |
| 129 | 🔴 | 非 Linux Guest 隧道不稳定：KCP 并发 connect() 导致会话状态不一致 |
| 125 | 📋 | `nowMs()` RTT 直连正确、中继异常（uptime 级别数值） |
| 127 | 📋 | linuxvm Journal 停止 + 升级下载无声失败 |
| 128 | 📋 | macOS `launchctl bootstrap` errno=5 在 bootout 后 |
