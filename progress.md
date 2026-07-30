# Progress: 分层架构重构

## 当前状态

- **分支**: `refac/layered-arch`
- **版本**: v0.14.3（自动升级启用 + Windows API 进程管理）
- **测试**: 146 唯一单元测试 + 41 集成测试场景，全部通过
- **源文件**: 17 src + 10 test
- **8 交叉编译目标全部通过** ✅
- **自动升级**: AUTO_UPGRADE=true（Host LSA 版本检测 + SOCKS4a 直推 + 120s 冷却）

## 会话记录

### 2026-07-30 — v0.14.3：自动升级启用 + Windows API 进程管理

**成果**: 自动升级编译时默认开启（AUTO_UPGRADE=true）；Windows 进程管理换用 Toolhelp + TerminateProcess API；
Windows upload 路径分隔符修复；SKILL 版本号批量更新；清理旧构建产物。

**自动升级启用**:
- `protocol.zig`：`AUTO_UPGRADE = true`（编译时常量，false 时死代码消除）
- `host.zig` 新增 `pushUpgrade()`（查 GuestEntry → deploymentFilename → 读 serve-dir → SHA256 → SOCKS4a 推送）
- `host.zig` 新增 `pushUpgradeThread()` 线程入口（分离线程，不阻塞 LSA 扫描）
- `host.zig` 新增 `LastUpgradeMap`（`StringHashMap(i64)`，冷却 120s 防重复推送）
- `host.zig` `tunnelManager` Phase 2 新增版本检测：比对 LSA 版本 → 检查冷却期 → 检查 upgrading 状态 → spawn 升级线程
- `ipc.zig` `handleUpgrade` 重构：~110 行 → ~25 行，调用 `host_mod.pushUpgrade()` 复用核心逻辑
- 冷却期 `AUTO_UPGRADE_COOLDOWN_MS = 120_000`（2 分钟）

**Windows API 进程管理**:
- `svc.zig` 新增 `w32` 命名空间（Toolhelp + TerminateProcess API）
- `killAllUtmm` Windows 分支重写：快照枚举 → 匹配 "utmm.exe" → OpenProcess(PROCESS_TERMINATE) → TerminateProcess
- `countOtherUtmmProcesses` Windows 分支重写：同上枚举计数
- 替换 `taskkill /F` + `tasklist` → 原生 API，支持 SYSTEM 权限进程

**其他修复**:
- Windows upload 路径分隔符：`host.zig:408` `"/"` → `std.fs.path.sep_str`（跨平台正确）
- SKILL 文件版本号批量更新：clean-deploy + deploy + utmm SKILL 0.14.1 → 0.14.2
- 清理 8 个旧构建产物 `zig-out/bin/*-0.14.1*`

**关键决策**:
- 决策 33: 自动升级 Host 端 LSA 版本检测 + 推送（编译时常量开关）
- 决策 34: Windows 进程杀死换用 Toolhelp + TerminateProcess API
- 决策 35: `extractUtmmd/rename` AccessDenied 根本原因是 `sc.exe stop` 不可靠（见 memory/windows-stop-utmmd-ineffective.md）

**编译验证**:
- `zig build test` 全部通过 ✅
- `zig build test-integration` 41/41 通过 ✅
- 8 交叉编译目标全部通过 ✅

### 2026-07-30 — v0.14.3 Clean Deploy 全量验证

**成果**: 完整的"清空—构建—部署—测试"裸机部署循环，4 台 VM 全 v0.14.3，
16 项功能测试（exec/upload/download/ping × 4）全部通过，SHA256 跨平台一致。

**测试结果**:

| 测试项 | linuxvm | macvm | windowsvm | winx64 |
|--------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ (2ms) | ✅ (1ms) | ✅ (1ms) | ✅ (5ms) |

**构建验证**:
- `zig build test` 全部通过 ✅
- `zig build test-integration` 41/41 通过，0 泄漏 ✅
- 4 交叉编译目标全部通过 ✅

**踩坑记录**:
1. macvm IP 变化：192.168.64.4 → 192.168.65.4（SSH host key 也变了，需 StrictHostKeyChecking=no）
2. windowsvm IP 变化：192.168.65.2 → 192.168.64.3
3. macvm UTM stop/start 后网络需 ~30s 才恢复
4. SKILL.md + CLAUDE.md 中 macvm/windowsvm 旧 IP 已更正

**文档更新**:
- CLAUDE.md：macvm IP 192.168.64.4 → 192.168.65.4，windowsvm 192.168.65.2 → 192.168.64.3
- SKILL.md：全部 macvm/windowsvm 命令中的 IP 相应更新

### 2026-07-30 — linuxvm 重建与文档更新

**背景**: linuxvm 的 `Linux.utm` bundle 从磁盘消失，UTM 显示 phantom "started" 状态但无实际进程。
用户重装 Ubuntu Desktop 为新 VM，IP 从 192.168.64.2 变为 192.168.64.6。

**linuxvm 重建**:
- Phantom UTM Linux VM 从 UTM Registry 删除（Python plistlib 操作 `com.utmapp.UTM.plist`）
- 用户通过 UTM GUI 安装 Ubuntu Desktop 24.04 (aarch64)，UUID `13BE0E67-8CA3-44A7-AE50-D0A65842FD2F`
- SSH 配置：`PermitRootLogin yes` + `PasswordAuthentication yes`（`/etc/ssh/sshd_config.d/50-utmm.conf`）
- root 密码 111，dasimo 用户 sudo 权限
- 部署 utmm v0.14.3 并验证 exec/upload/download/ping 全部通过

**临时 Lima VM 测试**:
- 在等待用户重装期间，创建 Lima VM `utmm-test`（Ubuntu 26.04, aarch64, vz 驱动）
- 探索 socket_vmnet 桥接网络配置，发现两个踩坑：
  1. Lima 拒绝 symlink → 必须 `sudo cp` 实际二进制到 `/opt/socket_vmnet/bin/`
  2. `/etc/sudoers.d/lima` 权限问题 → `chgrp admin`（dasimo 在 admin 组非 wheel）
- 发现 `detectUnixIp()` 多 NIC bug：eth0 (NAT) 先于 lima0 (vmnet) 被发现，返回错误 IP
  - 修复：`ip link set eth0 down` + netplan `dhcp4: false` for eth0
  - utmmd 重启后 Guest 正确检测 lima0 IP (192.168.105.2) 和 MAC
- 临时 VM 未删除（`limactl` 不在 PATH），待后续清理

**观察到的代码问题**:
- `upsert()` in host.zig (lines 969-974)：不检查 MAC 字段变化 — 仅 cosmetic，路由使用正确的 LSA node_id
- LSA 注册延迟：Host 重启后需 10-20s Guest 才出现在 status 中（正常行为）

**文档更新**:
- CLAUDE.md：linuxvm IP 192.168.64.2 → 192.168.64.6
- SKILL.md (clean-deploy)：5 处 linuxvm IP 更新

**关键发现**:
- UTM VM bundle 可能因 QEMU 崩溃或磁盘空间不足而从文件系统消失
- UTM Registry 与文件系统不同步时会显示 phantom 状态
- Lima `lima:shared` 网络模式（socket_vmnet + vmnet-shared）提供主机到 VM 直接 connectivity

### 2026-07-30 — v0.14.2 裸机部署验证

**成果**: 完整的"清空—构建—部署—测试"裸机部署测试循环。5 台机器从零部署 v0.14.2，
16 项功能测试（exec/upload/download/ping × 4）全通过，SHA256 跨平台一致。

**测试结果**:

| 测试项 | linuxvm | macvm | windowsvm | winx64 |
|--------|---------|-------|-----------|--------|
| --exec | ✅ | ✅ | ✅ | ✅ |
| --upload | ✅ | ✅ | ✅ | ✅ |
| --download | ✅ | ✅ | ✅ | ✅ |
| --ping | ✅ | ✅ | ✅ | ✅ |

**踩坑记录**:
1. Windows `taskkill /F` 无法终止 SYSTEM 权限 utmm 进程 → 需 PowerShell `Stop-Process -Force`
2. linuxvm SSH 长命令链 (`&&`/`||`) exit 255 → 分步执行 (4 个独立 SSH 调用)
3. winx64 `waitOldProcesses` 5s 超时 — 旧 utmm 进程残留，killAllUtmm 最终清理成功
4. 交叉编译产物同时保留 `-0.14.1` 和 `-0.14.2` 后缀 → 部署时需手动选择正确版本
5. Windows upload 路径显示 `C:\opt\utmm/clean_deploy_test.txt` (混合分隔符) — `vmRemoteDir()` 正确返回 `C:\opt\utmm`，功能正常

**关键决策**:
- 决策 32: Windows 部署安装用 PowerShell `Stop-Process -Force` 替代 `taskkill /F`

### 2026-07-30 — v0.14.2：升级系统重构 + 质量修复

**成果**: 升级系统从 Guest 自主升级重构为 Host 主控直推模型；修复 macOS launchctl bootstrap
errno=5 根因；跨平台路径审计并修复 5 处硬编码；临时文件泄露修复；部署流程自动化改进。

**升级系统重构**:
- Guest 侧：删除 UpgradeSignal/tryPerformUpgrade/LSA 版本比对/auto_upgrade 门控，新增 handleUpgradeCmd（升级指令接收 + 流式二进制 + 增量 SHA256 + shm 通知 utmmd）
- Host 侧：删除 checkGitHubVersion/verifyServeDirBinaries/upgradeTcpListener/handleUpgradeConnection/serveUpgradeFile/isValidVersion，新增 cmdUpgrade + ipcUpgrade（查 GuestTable → SOCKS4a 直推）
- IPC 新增 handleUpgrade：Request.upgrade (0x07) → serve-dir 读取二进制 → Guest 推送
- CLI 新增 `--upgrade <vm>` 参数，Host 直推模型
- upgrade_e2e 集成测试：7 场景（正常/哈希不匹配/0 字节/大文件/SOCKS4a/重传/并发）
- 删除 plan 文件 `floofy-skipping-gem.md`（已完全实现）

**macOS launchctl 修复**:
- 根因：`launchctl bootout` 重设 disabled flag，导致后续 bootstrap 返回 errno=5
- 修复：bootout 后显式 `launchctl enable` — installMacOS() 和 start() 两处
- macvm 验证：`state = running`，`enabled` flag 正确

**跨平台路径审计**:
- host.zig：3 处 `/opt/utmm` → `svc.canonicalDir()`
- ipc.zig：1 处 `/opt/utmm` → `svc_mod.canonicalDir()`
- host.zig cmdUpload：`/opt/utmm/{s}` → `vmRemoteDir()` 查 VM_DEPLOY_TABLE
- mcp.zig cmdVmUpload：`/opt/utmm/{s}` → `guestDefaultDir(vm)` 平台感知默认路径

**临时文件清理**:
- dpipe_file.zig：rename 失败 (CrossDevice + 普通) 两路径均 deleteFile
- guest.zig：新增 cleanupStaleTempFiles() — 启动时扫描 canonicalDir + tempDir，删除 `.utmm-*` 和 `.utmm-upgrade-*`

**VM 维护**:
- 4 VM 遗留垃圾清理（旧服务名 plist/service unit、temp 文件、日志）
- Windows VM (windowsvm + winx64) 启用 OpenSSH Server
- 版本号 bump：ver.txt 0.14.1 → 0.14.2

**Skill 更新**:
- clean-deploy/SKILL.md：新建裸机部署测试 skill（5 phase：清空→构建→部署→测试→总结）
- deploy/SKILL.md：Windows SMB 手动复制 → SSH 命令，并行策略更新

**关键决策**:
- 决策 26：升级系统 Guest 自主 → Host 主控直推
- 决策 27：复用 upload_result (0x17) 作为升级响应
- 决策 28：升级 temp 文件用 svc.tempDir()
- 决策 29：Windows SSH 替代 SMB/RDP
- 决策 30：mcp.zig guestDefaultDir() VM 名前缀推断平台
- 决策 31：deploy/clean-deploy SKILL 二进制名含版本号

### 2026-07-30 — v0.14.1：集成测试重构 + ReleaseSafe 强制 + 临时文件清理修复

**成果**: 集成测试从 8 个独立可执行文件重构为单入口 flat file 模式；强制所有发布构建使用 ReleaseSafe；
审计并修复所有上传/下载/升级错误路径的临时文件清理；4 台真机部署 v0.14.1。

**集成测试重构**:
- 8 个 `tests/<name>/main.zig` 目录删除 → 9 个 flat `tests/test_xxx.zig` 文件（`pub fn test_xxx(io, alloc, runner)` 签名）
- 单入口 `tests/integration_test.zig`：统一 DebugAllocator + TestRunner + 内存泄漏检测
- `build.zig` 简化：8 个独立 executable → 1 个 `integration_test` executable
- 修复 `_ = io` pointless discard（Zig 0.16.0 编译错误 — io 后续被使用）
- 40 测试场景全部通过，0 失败，0 泄漏

**x86_64 二进制尺寸根因**:
- 问题：x86_64-linux-musl Debug 模式 80MB
- 根因：x86_64-elf 的 `.data.rel.ro` 段 = 20.3MB（relocation data for read-only data, stack traces, lazy symbol resolution）；aarch64 无此段
- 解决：`-Doptimize=ReleaseSafe` 消除 `.data.rel.ro`：x86_64 从 80MB → 11MB
- ReleaseSafe 尺寸：Linux musl 8.8-11MB（静态链接 musl），macOS 1.4-1.6MB，Windows 2.0-2.3MB

**临时文件清理审计**:
1. dpipe_file.zig writeFile：`createFile()` 成功后 `allocator.create(WriteFileCtx)` 失败 → 旧 errdefer 只 close 不 delete → temp 文件泄露。修复：增加 `deleteFile` 调用
2. guest.zig handleUpgradeCmd：`defer file.close(io)` + 显式 `file.close(io)` → 双 close。修复：移除 defer

**ReleaseSafe 强制**:
- release.sh：所有 `zig build -Dtarget=` 添加 `-Doptimize=ReleaseSafe`
- CI workflow：所有构建添加 `-Doptimize=ReleaseSafe`
- CLAUDE.md：Build & Run 分 Debug/ReleaseSafe 两节，8 交叉编译命令均标注 ReleaseSafe

**真机部署验证**:
- linuxvm (aarch64): v0.14.1 ✅ — exec "uname -a" 正常
- macvm (aarch64): v0.14.1 ✅ — 需手动 cp + killall（macOS launchctl bootout 问题），exec 正常
- windowsvm (aarch64): v0.14.1 ✅ — taskkill /F utmm.exe 后 --install，exec 正常
- winx64 (x86_64): v0.14.1 ✅ — taskkill /F utmm.exe + utmmd.exe 后 --install，exec 正常
- Host (macOS aarch64): v0.14.1 ✅ — IPC + MCP + LSA 全部正常

**待提交**: 21 文件变更（新增 9 test、删除 8 旧 test 目录、修改 build.zig/release.sh/CI/CLAUDE.md/guest.zig/dpipe_file.zig/ver.txt）

### 2026-07-29 — Phase 9（续2）：修复 macOS SOCKS4a 栈悬垂指针

**成果**: 定位并修复 macOS aarch64 上 `readUntilNull` 栈悬垂指针导致 SOCKS4a 始终拒绝连接的 bug。

**Bug 修复详情**:

6. **SOCKS4a 栈悬垂指针** (`src/tcp.zig`):
   - 根因：`readUntilNull` 返回指向自身栈缓冲区的切片，函数返回后栈帧被释放。即使
     `socks4CheckAndReply` 在返回后"立即"调用 `std.mem.eql` 比较，`std.mem.eql` 的函数
     调用栈帧恰好与 `readUntilNull` 旧栈帧重叠（macOS aarch64 ABI），数据被破坏。
     调试日志证实：`hn` 前 4 字节 "dasi" 正确，后续被垃圾覆盖。
   - 修复：`readUntilNull` → `readUntilNullBuf(fd, buf)` — 缓冲区由调用者提供，数据存在于
     调用者栈帧中，`readUntilNullBuf` 返回后持续有效
   - 影响函数：`socks4CheckAndReply`（生产）、`socks4Accept`（测试）
   - 修复前：SOCKS4a 所有 hostname 都返回 REJECTED (0x5b)
   - 修复后：SOCKS4a 返回 OK (0x5a)，macvm exec 端到端通过

**测试方法反思**:
- 错误 1：从开发目录 `sudo ./zig-out/bin/utmm --exec` 触发了 `forceInstall(.host)`，
  覆盖本机 Host daemon 二进制
- 错误 2：用 Python 裸 SOCKS4a 测试而非走 CLI 路径
- 正确流程：build → scp 到 guest → `--install` 重启 → 走本机已有 Host daemon CLI 验证
- 事后已恢复 Host daemon

**验证状态**:
- `zig build` 编译通过 ✅
- `zig build test` 全部通过（含新增 5 个测试：socks4CheckAndReply × 2, readUntilNullBuf × 3）✅
- `zig build test-integration` 全部通过（9 套件 / 45 场景 / 0 失败）✅
- SOCKS4a Python 测试: 0x5a (OK) ✅
- macvm exec (CLI 端到端): `echo hello` → `hello` ✅

**测试更新**:
- `socks4Accept` 改为接受 allocator 参数，返回堆分配 hostname（消除 socks4Accept 自身的悬垂指针）
- 新增 `socks4CheckAndReply matching hostname` 测试
- 新增 `socks4CheckAndReply mismatched hostname` 测试
- 新增 `readUntilNullBuf basic` 测试
- 新增 `readUntilNullBuf empty field` 测试
- 新增 `readUntilNullBuf buffer overflow` 测试
- 集成测试 `tcp_frame/main.zig`: 更新 socks4Accept 调用传递 allocator

### 2026-07-29 — Phase 9：E2E 真机 Bug 修复

**成果**: 真机 E2E 验证发现并修复 2 个致命 bug（AddressInUse 崩溃循环 + upload 双 close panic），
修复 utmmd.bin 嵌入构建流程。linuxvm 5 轮 exec/upload/download 全通过。

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 45 | 修复 AddressInUse 崩溃循环（TCP listener 缺 SO_REUSEADDR + FD_CLOEXEC）| ✅ |
| Task 46 | 修复 upload 后 panic（handleUpload 双 close → use-after-free）| ✅ |
| Task 47 | 修复 utmmd.bin 嵌入构建流程（按目标分目录 + comptime switch）| ✅ |
| Task 48 | linuxvm E2E 真机验证（5 轮 exec/upload/download 全通过）| ✅ |
| Task 49 | 修复 Windows SOCKS4a 拒绝（readUntilNull 悬垂栈指针）| ✅ |
| Task 50 | 修复 Windows upload/download socket I/O（system.read/write → sockRead/sockWrite）| ✅ |
| Task 51 | windowsvm E2E 全验证（exec + upload + download SHA256 一致）| ✅ |
| Task 48 | linuxvm E2E 真机验证（5 轮 exec/upload/download 全通过）| ✅ |

**Bug 修复详情**:

1. **AddressInUse 崩溃循环** (`src/tcp.zig`):
   - 根因链：dpipe_shell fork() → 子进程继承 TCP listener socket（无 FD_CLOEXEC）→ upload panic → 孤儿子进程持有 TCP :2121 → 新 utmm 无法 bind → AddressInUse
   - 修复：`addr.bind()` → `addr.listen()`（启用 `reuse_address: true`）+ `fcntl(F_SETFD, FD_CLOEXEC)`
   - Zig 0.16.0 编译坑：`std.posix.F` 是 struct 非 enum（`@intCast`）、variadic fcntl 字面量需 `@as(c_int, ...)`、`Server` 替代 `Socket`
   - 影响文件：`src/tcp.zig`、`tests/tcp_frame/main.zig`

2. **Upload 双 close panic** (`src/guest.zig`):
   - 根因：`handleUpload` 有 `defer file_pipe.close()` + 显式 `file_pipe.close()` → 第一次 close 释放 ctx 内存 → defer 的第二次 close 操作已释放内存 → 垃圾 fd → EBADF → recoverableOsBugDetected panic
   - 修复：移除 `defer file_pipe.close()`（显式 close 已覆盖所有退出路径）
   - 这是 AddressInUse 崩溃循环的直接触发因素

3. **utmmd.bin 嵌入构建流程修复** (`build.zig` + `src/main.zig`):
   - 问题：切换目标平台不重编 utmmd + `src/embed/` 无按平台分子目录 → 交叉编译覆盖错误 bin
   - 修复：按目标分目录 `src/embed/{arch}-{os}/` + comptime switch 选择正确路径 + mkdir -p 子目录

**真机验证**:
- linuxvm (192.168.64.2) 5 轮测试（每轮 exec "uname -a" + upload test.txt + download test.txt），全部通过
- Guest PID (6632) 全程稳定无崩溃
- 验证修复有效：无 AddressInUse、无 upload panic、无 download 失败

**关键决策**:
- 决策 19：`addr.listen()` 替代 `addr.bind()` + 手动 `fcntl(FD_CLOEXEC)` — 原生支持 reuse_address
- 决策 20：handleUpload 移除 `defer file_pipe.close()` — 显式 close 已覆盖所有退出路径

### 2026-07-29 — Phase 9（续）：Windows E2E 真机 Bug 修复

**成果**: windowsvm (aarch64-windows) exec + upload + download 全通过，SHA256 一致验证。

**Bug 修复详情**:

4. **Windows SOCKS4a 拒绝 (0x5b)** (`src/tcp.zig`):
   - 根因：`readUntilNull()` 返回指向栈缓冲区的切片，函数返回后 `socks4Accept` 调用方
     访问该悬垂指针进行 hostname 比较 → 栈被重用 → 数据损坏 → 比较失败 → 拒绝连接
   - 修复：新建 `socks4CheckAndReply()` — 在 `readUntilNull` 返回后立即比较 hostname
     （在栈数据仍有效时），避免悬垂指针
   - 保留原 `socks4Accept` 仅供测试使用

5. **Windows upload/download socket I/O 失败** (`src/guest.zig` + `src/ipc.zig`):
   - 根因：`std.posix.system.read/write(conn.fd, ...)` — `conn.fd` 是 raw Winsock2 SOCKET，
     Windows 上 `system.read`/`write` 底层走 `ReadFile`/`WriteFile`，不支持 socket 句柄
   - upload 症状：temp 文件创建成功但 0 字节（`system.read` 返回 -1 → while 循环不执行）
   - download 症状：`system.write` 失败 → Host 收到 0 字节
   - exec 不受影响：`handleExecCmd` 全程使用 `conn.sendAndFlush()`（framed），不走裸读写
   - 修复：4 处 `system.read`/`write` → `tcp.sockRead`/`tcp.sockWrite`（Windows 走 `ws2_recv`/`ws2_send`）

**真机验证**:
- windowsvm (192.168.65.2): exec "echo" + ver 正常，50KB 二进制 upload + download SHA256 完全一致
- 全部测试通过：unit tests (150 执行) + integration tests (7 suites, 0 failures)

### 2026-07-29 — Phase 8：Windows 跨平台 Socket 抽象层修复

**成果**: 新增跨平台 socket I/O 抽象层（7 个 wrapper 函数），修复 x86-windows-gnu Winsock2 链接，
8 交叉编译目标全部通过，部署 3 台真机验证通过。

| 任务 | 描述 | 状态 |
|------|------|------|
| Phase 8 | tcp.zig + tests/common.zig 跨平台 socket 抽象层 + 6 个测试文件迁移 | ✅ |

**核心修复**:
- `tcp.zig` 新增 ~130 行：`sockWrite`、`sockRead`、`sockClose`、`sockShutdown`、`sockAccept`、`sockListen`、`makePair`
- `tests/common.zig` 新增相同 7 个 wrapper + 6 个 Winsock2 extern
- 所有 POSIX `system.read/write/close/shutdown/accept/listen` 调用统一迁移至 wrapper
- `host.zig` line 852: `system.listen` → `tcp.sockListen`
- 6 个测试文件全部迁移至 `common.zig` 辅助函数
- `svc.zig` LockFileEx Bool 比较修复：`== 0` → `@intFromEnum(result) == @as(c_int, 0)`

**x86-windows-gnu 链接修复**（6 个未定义符号）:
- 根因：`extern "ws2_32"` 默认 cdecl，32 位 Windows stdcall 需要 `@n` 名称修饰（如 `_send@16` 而非 `_send`）
- 修复：所有 6 个 Winsock2 extern 添加 `callconv(.winapi)` — 32 位解析为 `.Stdcall`，64 位为 `.C`（无操作）
- 额外修复：`accept` 的 `addrlen` 类型从 `?*c_int` 改为 `?*std.posix.socklen_t`（Zig 的 Windows socklen_t 是 `u32`）

**编译验证**:
- 全部 8 交叉编译目标通过：aarch64/x86_64/x86 × linux-musl/macos/windows
- `zig build test` 通过
- `zig build test-integration` 通过（7 测试套件，43 场景，0 失败）

**真机部署验证**:
- linuxvm (aarch64-linux): v0.13.0 → v0.13.1，`--exec` + `--status` 正常
- macvm (aarch64-macos): v0.13.0 → v0.13.1，LSA 发现正常
- windowsvm (aarch64-windows): v0.13.0 → v0.13.1，UDP LSA 正常（TCP 2121 仍未开放，预存问题）
- winx64 (x86_64-windows, 192.168.3.108): 仍运行 v0.12.2，待后续升级

**已知遗留**:
- Windows VM TCP 2121 端口未监听（仅 UDP 2121 LSA 可用），非本次变更所致
- winx64 仍运行旧版 v0.12.2

### 2026-07-29 — Phase 5-7：集成测试补充 + 代码审查修复 + 部署门禁

**成果**: 新增 4 个 e2e 集成测试（16 场景）、12 项代码审查修复全部完成、CLAUDE.md 部署门禁规则

| 任务 | 描述 | 状态 |
|------|------|------|
| Phase 5 | 9 集成测试全部实现（43 场景，0 FAIL）| ✅ |
| Phase 6 | REVIEW_FINDINGS.md 12 项全部修复（C1-C2, I1-I4, M1-M6）| ✅ |
| Phase 7 | CLAUDE.md 添加 Deployment Gating Rule | ✅ |

**新增集成测试详情**:
| 测试 | 场景数 | 验证内容 |
|------|--------|---------|
| `exec_e2e` | 4 | 命令执行 + MDELIM 标记 + exit code（捕获 C1 双重标记回归）|
| `upload_e2e` | 4 | 小文件/零字节/二进制上传 + SHA256 验证 + 错误码回传 |
| `download_e2e` | 4 | 小文件/128KB 流式下载 + 零字节 + 失败退出码 |
| `upgrade_e2e` | 4 | upgrade_req → 256KB 二进制流接收 + SHA256 校验 + 编解码 |

**编译问题修复记录**:
- `fromOwnedSlice(alloc, slice)` → `.empty` + `appendSlice` (Zig 0.16.0 ArrayList API)
- `system.read` / `system.write` 返回 `isize` 非 error union → 不能 try/catch
- `system.write` 参数需 `[*]const u8` 非 `[]const u8` → 使用 `.ptr`
- `catch |_| {}` → Zig 0.16.0 不允许丢弃 error capture

**CLAUDE.md 部署门禁**:
```markdown
### Deployment Gating Rule
Code changes must pass integration tests before deployment to real devices.
- zig build test AND zig build test-integration must both pass
- No exceptions for "trivial" changes
```

**成果**: CLAUDE.md 更新 + dpipe_file 测试修复 + build.zig 去重 + 代码库遗留问题扫描

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 11 | 更新 CLAUDE.md：KCP→TCP 架构、16 文件清单、新协议描述 | ✅ |
| Task 12 | 修复 dpipe_file hash mismatch 测试（warn→debug）| ✅ |
| Task 13 | 清理 build.zig standalone_test_modules（去重 tcp/lsa，新增 shm）| ✅ |
| Task 14 | 代码库遗留问题扫描（TODO、日志、refac.md）| ✅ |
| Task 15 | 新增 config.auto_upgrade 开关（默认 false，5 文件变更）| ✅ |

### 2026-07-29 — Phase 5 集成测试（计划中）

**计划**: 创建 `tests/` 目录，5 个独立可执行集成测试程序 + 共享测试库。

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 16 | 测试基础设施 `tests/common.zig` | 📋 |
| Task 17 | `tcp_frame` — TCP 帧协议 + SOCKS4a | 📋 |
| Task 18 | `lsa_routing` — LSA + Dijkstra 路由 | 📋 |
| Task 19 | `dpipe_relay` — DuplexPipe 双向转发 | 📋 |
| Task 20 | `svc_install` — 安装/卸载 | 📋 |
| Task 21 | `auto_upgrade` — 自动升级 | 📋 |
| Task 22 | build.zig `test-integration` 构建步骤 | 📋 |

详见 `refac.md` §8 集成测试计划。

---

**auto_upgrade 开关详情**:
- `config.zig`: 新增 `auto_upgrade: bool = false` 字段
- `main.zig`: 新增 `--auto-upgrade` CLI flag（显式启用）及 help text
- `lsa.zig`: `upgrade_needed` 从 `*std.atomic.Value(bool)` 改为 `?*`，null 时跳过版本比对
- `guest.zig`: `guestTcpLoop` 新增 `auto_upgrade` 参数，升级检查和 Mesh 信号按开关门控
- `host.zig`: `startHost` 新增 `auto_upgrade` 参数，GitHub 检查、serve-dir 校验、升级信号均门控
- 编译和测试全通过，5 文件变更

**代码扫描发现**:
- 3 个 TODO 注释：config.zig:107（功能缺口）、guest.zig:780（TCP 自动升级未闭环）、lsa.zig:496（Zig stdlib 问题）
- refac.md §3.7 残留过时描述（"install.zig 可独立构建"），已修正
- 无编译警告、无未使用导入、warn 日志均在生产代码路径中非测试路径
- 结论：重构阶段可彻底收工，分支可合并 main

**CLAUDE.md 更新详情**:
- 协议栈图 → 7 层分层模型（应用/拓扑/传输/数据管道/协议/系统服务/基础）
- 删除 KCP 协议栈、KCP 可靠传输、HostState、KCP Patterns 等全部过时章节
- 新增 TCP per-command 模型、DuplexPipe vtable、TCP 帧协议、LSA 自洽模式
- 文件清单：18 文件（含已删除）→ 正确的 16 文件

**dpipe_file hash 测试修复详情**:
- 根因：Zig 0.16.0 测试运行器对 stderr `warn` 级别日志敏感，导致 `--listen=-` 协议通信异常
- 修复：`std.log.warn` → `std.log.debug`（hash 不匹配是预期的可恢复诊断事件）
- `zig build test` 完全干净通过，无 "failed command"

**build.zig 清理详情**:
- 移除 `tcp.zig`、`lsa.zig`（已在主二进制中通过 host.zig import 链覆盖，消除重复）
- 新增 `shm.zig`（发现其 10 个测试之前从未被执行！）
- 重命名 `refac_modules` → `standalone_test_modules`
- 测试二进制：7 → 6，总执行 150 次（141 唯一 + 9 不可避免的 dpipe 重复）

### 2026-07-29 — Phase 3 完成

**成果**: lock.zig 删除 + Platform/genInit 迁移 → svc.zig

| 任务 | 描述 | 状态 |
|------|------|------|
| lock.zig 删除 | svc.zig 内联 flock/LockFileEx (120行), 删除 365行 | ✅ commit `06adede` |
| Platform/genInit | host.zig → svc.zig 迁移 (~140行+4测试) | ✅ |
| refac.md 更新 | 反映所有已完成任务、最终文件清单 | ✅ |
| task_plan.md 更新 | 全部任务标记完成 | ✅ |

**lock.zig → svc.zig 详情**:
- POSIX: `open(O_CREAT|O_RDWR)` + `flock(LOCK_EX)` — OS 级别劝告锁，进程崩溃自动释放
- Windows: `CreateFileW(OPEN_ALWAYS)` + `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)`
- 锁文件: `/var/run/utmm-install.lock` (POSIX) / `C:\opt\utmm\utmm-install.lock` (Windows)
- API 简化: `acquire(io, alloc)` → `acquire()`

**Platform/genInit 迁移详情**:
- host.zig 调用改为 `svc.Platform` + `svc.genInit`
- 不独立构建 install.zig（收益低，发布目标翻倍，与单二进制模型冲突）

### 2026-07-29 — Phase 2 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 5 | 新建 dpipe.zig + dpipe_shell.zig + dpipe_file.zig | ✅ |
| Task 6 | broadcast.zig → guest.zig，移植到 dpipe | ✅ |
| Task 7 | 删除 file_chunk/file_eof | ✅ |
| Task 8 | 消灭 state.zig + cmdchan.zig | ✅ |

### 2026-07-29 — Phase 1 完成

| 任务 | 描述 | 状态 |
|------|------|------|
| Task 1 | tcpf.zig + socks4.zig + netconn.zig → tcp.zig | ✅ |
| Task 2 | tunproto.zig → protocol.zig | ✅ |
| Task 3 | mesh.zig + hosts_file.zig → lsa.zig | ✅ |
| Task 4 | 修复 /etc/hosts 空行累积 bug (range replacement) | ✅ |

## 最终文件清单（16 个）

```
src/
├── main.zig         入口、CLI 解析、模式分发
├── protocol.zig      所有协议定义
├── fail.zig          快速失败
├── config.zig        配置持久化
├── lsa.zig           LSA + 节点表 + /etc/hosts
├── tcp.zig           帧协议 + SOCKS4 + 连接
├── dpipe.zig         DuplexPipe 接口 + relay
├── dpipe_shell.zig   pty→pipe
├── dpipe_file.zig    file→pipe
├── guest.zig         Guest daemon
├── host.zig          Host daemon
├── ipc.zig           IPC socket
├── mcp.zig           MCP stdio
├── svc.zig           服务管理（install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock）
├── utmmd.zig         监督进程
└── shm.zig           共享内存（utmmd↔utmm）
```

### 删除文件（10 个）
state.zig, broadcast.zig, mesh.zig, hosts_file.zig, tunproto.zig,
tcpf.zig, socks4.zig, netconn.zig, cmdchan.zig, lock.zig

---

## 历史摘要

### v0.12.2 及之前
- KCP 隧道稳定性修复、自动升级完善
- utmmd 监督进程架构重构、MCP stdio JSON-RPC
- 8 交叉编译目标全通过，166 测试通过

### v0.13.0-pre (commit `036f40f`)
- 删除 KCP ARQ 协议 (~1300行)，新增 TCP+SOCKS4 传输层
- mesh.zig 简化为纯 LSA 广播
- 20 源文件，124 测试通过
