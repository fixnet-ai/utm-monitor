# 有效技术结论

> 只保留仍有效的技术结论；过程流水账已删除。**所有平台/协议机制 spec 已下沉到
> 对应代码文件头部注释**（见下方「技术结论 → 代码位置」表），此处只留指针。
> Zig 0.16 语言/编译/API 迁移经验已收集（不落本项目文件，见编排汇总）。
> **二次瘦身（2026-08-23）**：2026-08-19 及更早历史阶段已删（task_plan 历史总表
> + git log 承接）；被推翻结论、纯实验过程、废弃测试体系引用已清除。

## 技术结论 → 代码位置（已下沉代码注释，不在此重复）

| 技术结论 | 代码位置 |
|----------|---------|
| SSH_ASKPASS + NUL stdin（Session 0 密码认证正解） | `src/sshpass.zig` 头部 |
| ConPTY 在 Session 0 不可用（平台事实，5 变体实证） | `src/dpipe_shell.zig` 头部 |
| exec stdout+stderr 已合并（sshpass 除外） | `src/dpipe_shell.zig` 头部 |
| Windows OEM↔UTF-8 双向转码（GetOEMCP 多语言通解） | `src/dpipe_shell.zig` 头部 |
| 进程组整树击杀 + Job Object（Windows 孙进程） | `src/dpipe_shell.zig:53/275/603` |
| closeFn 先关 master 再 kill（macOS E-state 收割） | `src/dpipe_shell.zig:472` |
| MDELIM marker 独立行 + `set +m; ` 前缀 | `src/protocol.zig:627-642` |
| download_result 头帧（file_size+sha256，与 upload 对称） | `src/protocol.zig` buildDownloadResult |
| 流式分块发送 + partialMarkerKeepLen（≤6B 尾部保留） | `src/guest.zig` |
| 过路 pong 归属验证（OutstandingPings 环） | `src/lsa.zig:830-869` |
| 零长 exec_data 写探针 + macOS poll POLLHUP 半关闭歧义 | `src/ipc.zig:665-669` |
| SSE 流 + progress 心跳（MCP 长任务超时修复） | `src/mcp_http.zig` 头部 |
| 所有平台文件 I/O 必须 Threaded Io（事件循环 Io 不支持文件操作） | `src/utmmd.zig:922-928` |
| GetAdaptersAddresses 栈踩踏修复（16384 对齐缓冲 + panic 钩子） | `src/utmmd.zig:289/370` |
| WIN32_FIND_DATAW FILETIME u32 对 + FindFirstFileW（Threaded Io walker 不支持 Windows） | `src/svc.zig` findUpgradeTmpWindows |
| shouldUpdateUtmmd macOS 恒 false（adhoc codesign 不可比） | `src/svc.zig:2110-2120` |
| utmmd 自愈（utmm --svc 启动早期自检替换） | `src/main.zig:423` 5a 块 |
| O_NONBLOCK 平台常量（macOS 0x0004 / Linux 0x800） | `src/tcp.zig:21-24` |
| Windows 命名共享内存不关 CreateFileMappingW 句柄 | `src/shm.zig:280-283` |
| SHM 跨进程必须 @atomicStore/@atomicLoad（@memcpy 不可见） | `src/shm.zig` |
| MCP download 必须 flush+sync（Threaded Io 异步 close 落盘 0 字节） | `src/mcp.zig:581-589` |
| sshpass 密码路径用 svc.tempDir()（Windows Host 无 /tmp） | `src/mcp.zig:632` |
| Windows deploy 必须跑 --install（forceInstall 提取/哈希更新 utmmd） | `src/host.zig:549` |
| VM_DEPLOY_TABLE 兜底表须与 live mesh 实况核对 | `src/host.zig:309-330` |
| Windows utmmd 用 Debug 优化（aarch64-windows 交叉编译 bug） | `build.zig:71-78` |
| 自愈用 -Dutmmd=false 复用 embed（字节不变→哈希不变） | `build.zig:62-68` |

## 近期关键定论（2026-08-22，v0.18.84-90）

### Windows utmmd 反复崩溃 1067 = GetAdaptersAddresses 栈踩踏（45H）

`getAllIpsFingerprintWindows` 第 4 参声明为 `*?*IP_ADAPTER_ADDRESSES_LH` 并传
`&addrs`（8 字节栈指针变量地址），API 按 size(15KB) 往该地址写结构数组 →
15KB 栈踩踏 → Debug 构建崩溃（utmmd Windows 用 Debug）→ UTM-MonitorD 反复
STOPPED(1067)。**POSIX getifaddrs（API 分配返回指针）与 Windows
GetAdaptersAddresses（写调用者缓冲区）语义不同，不可混用**。修复：声明
`?*anyopaque` + `[16384]u8 align(8)` 缓冲传 `&buf` + Windows panic 钩子落盘。

### Windows Host 服务链 sshpass 正解 = SSH_ASKPASS + stdin EOF（45D'）

- **深挖推翻前提**：Win32-OpenSSH sshpty.c `WIN32_FIXME` 分支根本不用 ConPTY
  （ptyfd=0/ttyfd=0 = stdin/stdout 直通）→ `ssh -tt` 的成功是管道直通 → 复现
  OpenSSH ConPTY 是死路。
- **正解**：Win32 OpenSSH read_passphrase 检测 `SSH_ASKPASS` → 走 askpass 程序，
  完全避开 TTY/ConPTY；ssh.exe stdin 重定向 NUL（立即 EOF）根治「认证成功 +
  命令完成后退出挂起」（Win32-OpenSSH issue #1769/#1427，stdin 保持打开所致）。
- **实施**：sshpass.zig runWindows 加 `hasConsole()` 检测 → 无控制台（Session 0）
  或 ssh 命令 → **恒走 runWindowsAskpass**（SSH_ASKPASS/SSHPASS env + NUL stdin +
  读输出回传 + 退出码透传 + Permission denied→exit 5）。
- **Permission denied root cause**：密码隐藏 `@memset(argv[密码],'z')` 覆写 argv
  内存，`.pass` 分支不 dupe → 共用同一内存被覆写成 "zzz"。修复 `.pass` 必须 dupe
  + 函数级 errdefer（块内 errdefer 在 case 块结束时失效）。
- 真机全过：正确密码 RC=0 / 错误密码 RC=5 / 主机不可达 RC=255 / 多行透传 /
  远程 exit 7 → RC=7。

### utmmd 自愈（v0.18.90）— 永久解决 utmmd 手动部署缺口

`--upgrade` 只推 utmm、从不推 utmmd（已知限制 #2）→ v0.18.89 时 windowsvm/
winx64 utmmd 仍是旧版需手动逐台部署。**用户裁定**：utmm 启动时若磁盘 utmmd
哈希与内嵌不符则立即替换重启。实现：main.zig `--svc` 分支 5a 块（shm.open 前）
`shouldUpdateUtmmd` 比较 → 不符则 extractUtmmdToTemp + buildServiceArgs +
upgradeUtmmd（disable→kill→replace→enable→start）→ exit(0)，新 utmmd spawn
新 utmm 接管。**闭环验证**：无无限循环（新 utmm 再检哈希已匹配）、端口/shm
无冲突（自检在绑定前）、失败回滚（replace 失败 enable+start 旧 utmmd）、
monitorLoop 指数退避 + MAX_FAILURE_COUNT=5 兜底。

### Round 2 教训：升级后 utmmd integer overflow panic（v0.18.88）

linuxvm 升级后 utmmd panic `integer overflow`——根因是 `--upgrade` 只推 utmm
不推 utmmd，磁盘 utmmd 还是含 bug 的旧版。代码层 u32 时钟减法改 saturating +
`hb > now` 时钟错位防御；部署层 utmmd 需手动推送。**该缺口由 v0.18.90 自愈
永久闭合**（决策 #24）。

## 有效架构决策（代码级定论）

### Hub-Spoke 拓扑（SOCKS5 唯一中转）

Host 是唯一中转（非 peer-mesh）。Guest IP 同步到每台 /etc/hosts 的 `gateway`
hostname；Guest 收到非本机目标直接 REJECT，统一走 Host 中转。

### TCP :2121 首字节协议分发

Host accept 后 peek 1 字节：`0x05`→SOCKS5 / 大写 ASCII→HTTP MCP / 其他→close。
单端口承载 SOCKS5 + HTTP MCP。

### MCP 长任务 SSE 流 + progress 心跳（Phase 44）

POST 响应从单 JSON 改 SSE 流（`text/event-stream` + priming 注释首字节秒到）+
心跳线程每 5s 发 `notifications/progress`（progressToken 从 `_meta` 提取，
gpa.dupe 副本防 parsed.deinit 释放）。事件字段用 `\n`（非 `\r\n`）分隔。

### exec 连接生命周期 = 命令生命周期（Phase 43）

零协议变更；macOS poll 对半关闭也上报 POLLHUP → IPC 弃读侧检测，改零长
exec_data 帧写探测（全版本无害）。版本混部矩阵全安全。

## 已知限制（仍有效）

| # | 限制 | 影响 | 状态 |
|---|------|------|------|
| 1 | Windows BIND 动态端口 | Windows Firewall 阻止入站（非代码问题） | OS 限制 |
| 2 | zio 依赖本地路径 | build.zig.zon 用 path="../zio"，PR #646 合并后切 URL | 待 zio 上游 |
| 3 | macOS `zig build test --listen=-` hang | Zig 0.16 stdio 协议 bug，build.zig 用 manual Run.create 绕过 | 已知 |
| 4 | `upsert()` 不检查 MAC 变化 | 仅 cosmetic，路由用正确的 LSA node_id | 低优先级 |
| 5 | mcp_http.zig 单测未被 `zig build test` 收集 | import 链 + standalone 循环依赖，编译 EXIT=0 + 集成 + 真机 SSE 兜底 | 预先存在 |
| 6 | Windows Host MCP sshpass 补验 | Session 0 已由 exec 通道验证（同 runWindowsAskpass 底层），切换 host 部署后补验 | 待办 |

## 错误方向记录（勿再追）

- **「ConPTY 是主要且必须支持」在 Session 0 不成立**：5 个实现变体 + EchoCon
  精确复刻全灭，所有 API 成功但 cmd 零输出（Phase 41/45D 实证）。服务链正解 =
  SSH_ASKPASS。
- **「argv +m 关闭作业控制」无效**：交互式 shell 初始化强制开启作业控制覆盖
  argv 初值；正确姿势 = 命令前缀 `set +m; `（buildCmdWithMarker POSIX 分支）。
- **「--upgrade 推送 OK 即生效」错误**：OK 只代表字节送达，必须核对磁盘二进制的
  **mtime + size + 行为**三要素（L1 遗留 + Round 1 实测）。
- **「Windows 文件锁定 deleteFile+rename」初版方向**：真解法 = MoveFileExW
  先 rename 旧→.old 再 rename 新→目标（Windows 允许 rename 打开的文件）。
- **「getifaddrs 与 GetAdaptersAddresses 可混用」假设**：两者缓冲区语义相反
  （API 分配 vs 调用者分配），混用导致 15KB 栈踩踏。
- **「ipc 测试一直在跑」假设**：standalone_test_modules 遗漏 ipc.zig，6 个测试
  从未运行过——新增测试后必须确认测试数变化。

## 测试/调试基建经验

- 手动删 `.zig-cache/o/*/test` 二进制 → `file_hash FileNotFound` 缓存清单破坏；
  应整个删 `.zig-cache` 重建。
- `SSHPASS_LEN=3` 这类只量长度不读值的诊断有误导性；askpass.bat 写值诊断才是
  决定性证据（Permission denied root cause 定位关键）。
- 测试脚本的 download 内容校验（非仅 bytes 报告）是抓「Threaded Io 异步 close
  落盘 0 字节」这类 bug 的关键。
