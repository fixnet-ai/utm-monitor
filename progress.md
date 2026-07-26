# Progress: v0.11.10

## 当前状态

- **分支**: `main`（领先 origin/main 2 个提交）
- **最新提交**: `e444d46` — macOS 重试计数器永久累积修复
- **测试**: 149/149 通过
- **部署**: macOS Host ✅ | linuxvm ✅ | macvm 📋 | windowsvm 📋 | winx64 📋

## 最近提交

```
e444d46 fix: macOS retry counter accumulates permanently, blocking restart tests
1ff46ad fix: Host restart exec returning empty (0xFF keepalive pollution + stale session races)
ed7985b v0.11.10: Phase 50-52 hardening, consolidation, auto-ensure + deployment fixes
717d6e1 refactor: consolidate 19 source files into 13 by merging thin wrappers
52aa0c3 test: add 66 unit tests, coverage from 127 to 193 (+52%)
1484e5e fix: correct MCP tool descriptions and port references
1aa5de0 refactor: unified install/upgrade self-copy model + doc consolidation (#1)
```

## Phase 50: 加固优化全面审计 ✅ (2026-07-26)

**目标**: 对 13 个源文件进行全面安全/可靠性审计，识别并修复 20 个问题。

### Phase 0: 清理（1 项）
- **F3**: 删除 `src/host_http.zig`（1190 行，全项目零引用）

### Phase 1: UDP MTU + 自包含修复（11 项）
| 编号 | 文件 | 修改 |
|------|------|------|
| M1 | `kcp.zig:30` | `IKCP_MTU_DEFAULT` 1300→1266，MSS 1242 |
| M2 | `mesh.zig:873` | KCP relay 前 `data.len > 1279` 门禁 |
| M3 | `mesh.zig:754` | LSA relay 1499→1279 |
| M4 | `mesh.zig:533,639` | LSA 广播 buf `[1500]`→`[1280]`（2 处） |
| D1 | `broadcast.zig:131` | `readSysFs` buf `[64]`→`[4096]` |
| D2 | `broadcast.zig`+`host.zig` | TOCTOU: 临时文件名 `io.random()` 8 字节 hex |
| D3 | `broadcast.zig:1387` | `flush() catch {}`→error propagation |
| P1 | `broadcast.zig:1468` | sendChunkedFile 每 chunk flush，修复 ~8KB/s |
| E2 | `httpd.zig:1434` | mutex.lock catch→flag 守卫 cleanup |
| F2 | `mesh.zig:122` | encodeLsa 递归守卫（buf 不足时 0 邻居） |
| A4 | `mesh.zig:858` | sessions.put OOM→errdefer 回滚 |

### Phase 2: mesh.zig 线程安全（3 个互斥锁）
- 新增 `neighbors_mutex`、`lsas_mutex`、`routes_mutex`（`std.Io.Mutex`）
- ~30 处锁包裹，锁序 `sessions→neighbors→lsas→routes`
- 避免自死锁：`handleLsa` block-scoped 先释放→再调 `rebuildRoutes`

### Phase 3: 线程生命周期（2 处）
- **B1+B2+B3** (`host.zig`): tunnelManager detach→join，defer 5 步有序销毁
- **C1** (`broadcast.zig`): ptyReadLoop detach→join，先 signal→close→join

### Phase 4: 错误处理和代码质量（7 项）
| 编号 | 文件 | 修改 |
|------|------|------|
| E1a | `broadcast.zig:609` | ptyWrite 返回值检查 + 短写 while 重试 |
| E1b | `broadcast.zig:862` | poll EINTR→continue |
| E1c | `broadcast.zig:1483` | catch 块 try buildFileEof→if/else 安全处理 |
| P2 | `broadcast.zig`+`httpd.zig` | pty_exec_done 消息发送+接收，新增 `isOpDone()` |
| E3 | `host.zig:628` | tunnelManager 循环顶端 `cleanupStaleOps()` |
| E4 | `svc.zig` | forceInstall 失败回滚（删二进制/卸载服务），`uninstallServiceConfig()` |
| E5 | `main.zig` | 9 个 CLI 标志 `i+=1` 前先检查 `i+1<args.len` |
| F1 | `svc.zig` | `runCmdQuiet()` 替换 24 处 `_ = runCmd(...)` 静默吞错 |

**验证**: `zig build test` 128/128 通过，8 目标交叉编译零错误。
**平台兼容修复**: Windows `BOOL` vs comptime_int（`@intFromEnum`），Zig 0.16 `std.c.getErrno` 不存在，`catch {} else {}` 非法语法。

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

## Phase 50 部署测试 ✅ (2026-07-26)

**目标**: 全 VM 重新部署和验证 exec 功能。

**发现并修复 4 个 bug**:
- **Finding 76**: `wake_event.reset()` 在信号线程调用导致 `unreachable` panic（堆栈追踪确认）
- **Finding 77**: `cleanupOpState` 前持有 `state.mutex` 导致自死锁（3 线程死锁链）
- **Finding 78**: 交叉编译 `zig-out/bin/utmm` 被覆盖（流程问题）
- **Finding 79**: tunnelManager 使用已释放 Tunnel 指针导致 segfault（use-after-free）

**修复文件**: `src/httpd.zig`（+15 行 isTunnelDead 方法，-7 行 reset/双重锁），`src/host.zig`（+15/-10 行 tunnelManager 重构）

**部署状态**:
| VM | 状态 | exec 验证 |
|----|------|----------|
| linuxvm | ✅ 已部署 | `hostname`、`uptime`、`uname -a` 通过 |
| macvm | ✅ 已部署 | `uname -a`、`hostname` 通过 |
| windowsvm | ✅ 已验证 | `echo W1` 通过（运行旧二进制，Host 侧修复） |
| winx64 | ✅ 已验证 | `echo X1` 通过（运行旧二进制，Host 侧修复） |

**验证**: `zig build test` 全量通过，Host 持续运行无崩溃，4 VM 全部 exec 成功。

## Phase 51: 文件合并与测试扩充 ✅ (2026-07-26)

**目标**: 消除薄包装文件，减少文件数量、降低模块间导航成本。

**合并操作** (19→13 文件):
| 删除 | 并入 | 行数 |
|------|------|------|
| `ver.zig` | `protocol.zig` | 30 |
| `priv.zig` | `main.zig` | 72 |
| `install.zig` | `svc.zig` (`detectServiceEnv`) + `host.zig` (`Platform`/`genInit`) | 186 |
| `guest.zig` | `broadcast.zig` | 65 |
| `mcp.zig` | `httpd.zig` | 397 |
| `host_http.zig` | `httpd.zig` | 1280 (新增) |

**Zig 0.16.0 API 兼容修复** (5 处):
- `waitpid` → `process.WaitPidResult` 新 API
- `BodyWriter` → `Response.Writer` 新类型  
- `executablePath()` 新签名（返回 slice 而非错误联合）
- `Event.set(io)` 新签名（不再接受第二个参数）
- `readSliceAll` → `ReadBuffer` + `readUntilDelimiterAll`

**测试扩充** (+66 测试):
| 文件 | 变更 | 测试数 |
|------|------|--------|
| `httpd.zig` | jsonEscape, json helpers, buildCmdWithMarker, scanForMarker, HostState, OpState | 0→44 |
| `svc.zig` (原 install.zig) | defaultShell, defaultHome, genInit 细节 | 4→10 |
| `config.zig` | 替换签名测试为实际验证 | 3→9 |
| `broadcast.zig` | detectShell, isPhysicalInterface, zigTarget | 2→6 |
| `hosts_file.zig` | HostEntry 边缘情况 | 3→5 |

**验证**: `zig build test` 128/128 通过，原生构建成功，13 文件结构清晰。

## Phase 52: CLI 管理命令自动确保 Host ✅ (2026-07-26)

**目标**: 消除"先 `--host` 再管理命令"的两步操作，一步完成。

**问题**: 管理命令（`--status`/`--exec`/`--upload`/`--download`）在 Host 未运行时仅打印 `ConnectionRefused` 后 crash，用户必须手动先启动 Host。

**改造**: `main.zig` 合并分发逻辑（+6/-5 行）：
- `needs_host` 统一判断：`--host`、`--status`、`--exec`、`--upload`、`--download` 任一触发
- `svc.ensure(.host)` 幂等：已运行则跳过，未运行则自动安装+启动
- `--host` 单独使用 → ensure 后 exit（行为不变）
- 管理命令 → ensure 后 fall through 执行

**验证**: `zig build test` 128/128 通过，`zig build` 成功。

### Phase 52 部署测试与 Bug 修复 (2026-07-26)

**目标**: 部署到 Host + 4 VM，验证 auto-ensure 端到端行为。

**部署过程发现并修复的 Bug**:

| 编号 | 问题 | 文件 | 修复 |
|------|------|------|------|
| F89 | `runCmd()` 永远返回 true 不检查退出码 | `svc.zig:66-70` | 改为检查 `result.term` |
| F90 | macOS `cp` 破坏 ad-hoc 代码签名 → SIGKILL | 部署流程 | 部署后 `codesign --force --sign -` |
| F91 | `selfCopy` copy+delete 路径也破坏签名 | `svc.zig` | 文档化，待修复 |
| F92 | `launchctl enable` 不足于清除 disabled 状态 | `svc.zig` | installMacOS 添加 enable + PlistBuddy 兜底 |
| F93 | `installMacOS` + `start()` 双重 bootstrap | `svc.zig:514-544` | start() 改为 isRunning→kickstart→bootstrap |

**start() macOS 重构** (F93):
- 先 `isRunning()` 检查 → 已运行则直接返回（幂等）
- `launchctl kickstart -k` 优先（重启已加载的服务）
- `launchctl enable` + `launchctl bootstrap` 回退（加载未安装的服务）
- 验证步骤：`launchctl list` 确认服务出现

**installMacOS 增强** (F92):
- `launchctl enable` 在 bootstrap 之前调用，清除 disabled 标志

**部署状态**:
| 目标 | 二进制 | 状态 |
|------|--------|------|
| Host (macOS) | `/opt/utmm/utmm` | ✅ 已签名，服务运行中 |
| linuxvm | `utmm-aarch64-linux` | ✅ 已部署 |
| macvm | `utmm-aarch64-macos` | ✅ 已部署 |
| windowsvm | `utmm-aarch64-windows.exe` | ✅ 已部署 |
| winx64 | `utmm-x86_64-windows.exe` | ✅ 已部署 |

**已知遗留问题**:
- KCP 隧道在 Host 重启后 exec 返回空输出（dual-session mismatch，F93）
- `selfCopy()` 的 copy+delete 路径未重新签名（F91）
- 4 个 DebugAllocator 内存泄漏（`buildServiceArgs` CLI 短生命周期，OS 回收）

## Phase 54: Task #254 — Host 重启 exec 空输出修复 ✅ (2026-07-26)

**目标**: 修复 Host 重启后 exec 返回 HTTP 200 空 body + x-exit-code: -1 的长期 bug。

**根因**（6 个协同问题）:
1. 0xFF keepalive 污染 KCP 数据通道 — 1 字节探针作为应用消息传递，触发 BufferTooSmall
2. Host 不发送 pty_spawn — Guest 依赖隐式触发
3. waitForHostTunnel 忙等 — lock 失败跳过 sleep，CPU 100%
4. ptyReadLoop 不检查 pty_dead — 资源泄漏
5. tunnelManager 选过期 session — 有 keepalive 的旧 session 被优先选中
6. macOS launchd 重试计数器不重置 — 测试重启被拒绝

**提交**:

| 提交 | 内容 | 文件 |
|------|------|------|
| `1ff46ad` | Fix 1-5: 0xFF 过滤 + pty_spawn + 忙等修复 + pty_dead + session 选择 | `tunnel.zig`, `broadcast.zig`, `host.zig` |
| `e444d46` | Fix 6: 重试计数器 120s 时间窗重置 + mesh 启动后 resetRetryCounter | `svc.zig`, `host.zig`, `broadcast.zig` |

**验证**:
| 项目 | 结果 |
|------|------|
| `zig build test` | 149/149 通过 |
| `zig build` (aarch64-macos) | ✅ 无错误 |
| Host 重启循环（轮询模式） | 10/10 通过 |
| 0xFF 错误（日志） | 0 出现 |
| 重试计数器 | 10 次快速重启未触发 |

**部署**:
| 目标 | 状态 |
|------|------|
| macOS Host | ✅ 已部署，PID 75841 |
| linuxvm Guest | ✅ 已部署，服务 active |
| macvm、windowsvm、winx64 | 📋 待部署（用户指示：本机测试完善后） |

**遗留**:
- 待推送到 origin/main
- debug 日志过于冗长（`scan: sessions=X`）
- `selfCopy()` copy+delete 路径未重新签名（F91）
